//! PCM hand-off from librespot's player thread to the Core Audio render thread.
//!
//! librespot decodes into [`FloeSink::write`] on its own player thread. Samples go
//! into a lock-free SPSC ring (interleaved stereo f32 at 44.1 kHz) that Swift's
//! `AVAudioSourceNode` drains through `floe_render`.
//!
//! Pause and seek must not wait for the ring to drain:
//! - the *gate* makes the render side output silence immediately on pause, and
//! - [`Pcm::flush`] drops buffered audio immediately on seek/load.

use std::{
    sync::{
        Arc, Mutex, MutexGuard,
        atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering},
    },
    thread,
    time::Duration,
};

use crate::analysis::AnalysisTap;

use librespot_playback::{
    audio_backend::{Sink, SinkResult},
    convert::Converter,
    decoder::AudioPacket,
};

pub const SAMPLE_RATE: usize = 44_100;
pub const CHANNELS: usize = 2;

/// Half a second. Pause and seek don't wait for it, so it only absorbs jitter.
const RING_SAMPLES: usize = SAMPLE_RATE / 2 * CHANNELS;

/// While the gate is closed the sink parks samples instead of blocking, so the
/// player thread stays free to receive the pause command. This caps the parking.
const MAX_PARKED_SAMPLES: usize = SAMPLE_RATE * CHANNELS * 2;

pub struct Pcm {
    pub analysis: AnalysisTap,
    // Each half is only ever touched by one thread at a time (player thread /
    // render thread); the mutexes are uncontended except during `flush`.
    producer: Mutex<rtrb::Producer<f32>>,
    consumer: Mutex<rtrb::Consumer<f32>>,
    buffered: AtomicUsize,
    gate_open: AtomicBool,
    epoch: AtomicU64,
    frames_rendered: AtomicU64,
    /// Times playback ran dry after having audio (render thread only).
    underruns: AtomicU64,
    fed: AtomicBool,
    peak_bits: AtomicU32,
}

#[derive(Debug, Default, Clone, Copy)]
pub struct Stats {
    pub frames_rendered: u64,
    pub underruns: u64,
    pub peak: f32,
    pub buffered_ms: u32,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Pcm {
    pub fn new() -> Arc<Self> {
        let (producer, consumer) = rtrb::RingBuffer::new(RING_SAMPLES);
        Arc::new(Self {
            analysis: AnalysisTap::new(),
            producer: Mutex::new(producer),
            consumer: Mutex::new(consumer),
            buffered: AtomicUsize::new(0),
            gate_open: AtomicBool::new(false),
            epoch: AtomicU64::new(0),
            frames_rendered: AtomicU64::new(0),
            underruns: AtomicU64::new(0),
            fed: AtomicBool::new(false),
            peak_bits: AtomicU32::new(0),
        })
    }

    pub fn set_gate(&self, open: bool) {
        self.gate_open.store(open, Ordering::Release);
        if !open {
            self.analysis.reset();
        }
    }

    /// Drops everything buffered (seek, new track, logout).
    pub fn flush(&self) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        self.analysis.reset();
        let mut consumer = lock(&self.consumer);
        let n = consumer.slots();
        if n > 0 {
            if let Ok(chunk) = consumer.read_chunk(n) {
                chunk.commit_all();
            }
            self.buffered.fetch_sub(n, Ordering::AcqRel);
        }
    }

    /// Render thread: fills `left`/`right` and returns how many frames came from
    /// the ring (the rest is silence). Never blocks or allocates.
    pub fn render(&self, left: &mut [f32], right: &mut [f32]) -> usize {
        let frames = left.len().min(right.len());
        left.fill(0.0);
        right.fill(0.0);
        if !self.gate_open.load(Ordering::Acquire) {
            return 0;
        }
        // Only `flush` can hold this lock, and then a cycle of silence is fine.
        let Ok(mut consumer) = self.consumer.try_lock() else {
            return 0;
        };
        let n = (consumer.slots() / CHANNELS).min(frames);
        // Count transitions into starvation, not every empty cycle while a track loads.
        let starved = n < frames;
        if self.fed.swap(!starved, Ordering::Relaxed) && starved {
            self.underruns.fetch_add(1, Ordering::Relaxed);
        }
        if n == 0 {
            return 0;
        }
        let Ok(chunk) = consumer.read_chunk(n * CHANNELS) else {
            return 0;
        };
        let (a, b) = chunk.as_slices();
        let mut peak = 0f32;
        for (i, &s) in a.iter().chain(b).enumerate() {
            peak = peak.max(s.abs());
            if i % CHANNELS == 0 {
                left[i / CHANNELS] = s;
            } else {
                right[i / CHANNELS] = s;
            }
        }
        self.analysis.capture(&left[..n], &right[..n]);
        chunk.commit_all();
        self.buffered.fetch_sub(n * CHANNELS, Ordering::AcqRel);
        self.frames_rendered.fetch_add(n as u64, Ordering::Relaxed);
        // Non-negative floats order the same as their bit patterns.
        self.peak_bits.fetch_max(peak.to_bits(), Ordering::Relaxed);
        n
    }

    /// Pushes whole frames from `data`; returns how many samples were taken.
    fn push(&self, data: &[f32]) -> usize {
        let mut producer = lock(&self.producer);
        let n = producer.slots().min(data.len()) / CHANNELS * CHANNELS;
        if n == 0 {
            return 0;
        }
        let Ok(mut chunk) = producer.write_chunk(n) else {
            return 0;
        };
        let (a, b) = chunk.as_mut_slices();
        a.copy_from_slice(&data[..a.len()]);
        b.copy_from_slice(&data[a.len()..n]);
        // Count before publishing so the consumer side never subtracts first.
        self.buffered.fetch_add(n, Ordering::AcqRel);
        chunk.commit_all();
        n
    }

    /// Returns counters since the last call (peak is reset on read).
    pub fn take_stats(&self) -> Stats {
        let buffered = self.buffered.load(Ordering::Acquire);
        Stats {
            frames_rendered: self.frames_rendered.load(Ordering::Relaxed),
            underruns: self.underruns.load(Ordering::Relaxed),
            peak: f32::from_bits(self.peak_bits.swap(0, Ordering::Relaxed)),
            buffered_ms: (buffered / CHANNELS * 1000 / SAMPLE_RATE) as u32,
        }
    }
}

/// The librespot `Sink` that feeds [`Pcm`].
pub struct FloeSink {
    pcm: Arc<Pcm>,
    pending: Vec<f32>,
    epoch: u64,
}

impl FloeSink {
    pub fn new(pcm: Arc<Pcm>) -> Self {
        let epoch = pcm.epoch.load(Ordering::Acquire);
        Self {
            pcm,
            pending: Vec::new(),
            epoch,
        }
    }

    /// Anything still pending from before a flush is stale.
    fn drop_stale(&mut self) {
        let epoch = self.pcm.epoch.load(Ordering::Acquire);
        if epoch != self.epoch {
            self.epoch = epoch;
            self.pending.clear();
        }
    }
}

impl Sink for FloeSink {
    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        // `Raw` only comes from the passthrough decoder, which we never enable.
        let AudioPacket::Samples(samples) = packet else {
            return Ok(());
        };
        self.drop_stale();
        self.pending.extend(converter.f64_to_f32(&samples));
        loop {
            self.drop_stale();
            let taken = self.pcm.push(&self.pending);
            self.pending.drain(..taken);
            if self.pending.is_empty() {
                return Ok(());
            }
            // Ring is full. When paused, park the rest and return so the player
            // can process the pause command instead of blocking here.
            let paused = !self.pcm.gate_open.load(Ordering::Acquire);
            if paused && self.pending.len() < MAX_PARKED_SAMPLES {
                return Ok(());
            }
            // Sleep about as long as it takes to drain room for what's pending,
            // instead of waking every few ms to push a sliver.
            let frames = self.pending.len() / CHANNELS;
            let ms = (frames * 1000 / SAMPLE_RATE).clamp(5, 50) as u64;
            thread::sleep(Duration::from_millis(ms));
        }
    }
}
