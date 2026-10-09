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
    time::{Duration, Instant},
};

use crate::{analysis::AnalysisTap, stereo};

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

/// An ignored skip must not make a later automatic transition discard its tail.
/// Slower loads are covered by `switching` after the engine emits Loading.
const SKIP_CONFIRMATION_WINDOW: Duration = Duration::from_secs(2);

pub struct Pcm {
    pub analysis: AnalysisTap,
    // Each half is only ever touched by one thread at a time (player thread /
    // render thread); the mutexes are uncontended except during `flush`.
    producer: Mutex<rtrb::Producer<f32>>,
    consumer: Mutex<rtrb::Consumer<f32>>,
    buffered: AtomicUsize,
    gate_open: AtomicBool,
    switching: AtomicBool,
    /// Only command/event threads touch this marker; never the render callback.
    skip_requested: Mutex<Option<Instant>>,
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

/// Poisoning only means another thread panicked mid-update; the data is still usable.
pub fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
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
            switching: AtomicBool::new(false),
            skip_requested: Mutex::new(None),
            epoch: AtomicU64::new(0),
            frames_rendered: AtomicU64::new(0),
            underruns: AtomicU64::new(0),
            fed: AtomicBool::new(false),
            peak_bits: AtomicU32::new(0),
        })
    }

    pub fn set_gate(&self, open: bool) {
        let open = open && !self.switching.load(Ordering::Acquire);
        self.gate_open.store(open, Ordering::Release);
        if !open {
            self.analysis.reset();
        }
    }

    /// Remember a manual skip without silencing a seek or ignored command.
    pub fn prepare_skip(&self) {
        *lock(&self.skip_requested) = Some(Instant::now());
    }

    pub fn finish_skip(&self) {
        lock(&self.skip_requested).take();
    }

    /// A deliberate selection should silence the old track immediately.
    pub fn begin_switch(&self) {
        self.finish_skip();
        self.switching.store(true, Ordering::Release);
        self.set_gate(false);
        self.flush();
    }

    /// Drop any old packets decoded while the new context was resolving.
    /// Automatic, preloaded gapless transitions keep their buffered tail.
    pub fn track_changed(&self) {
        let skipped = lock(&self.skip_requested).take()
            .is_some_and(|requested| requested.elapsed() <= SKIP_CONFIRMATION_WINDOW);
        if self.switching.swap(false, Ordering::AcqRel) || skipped {
            self.flush();
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
        let n = self.render_audio(&mut left[..frames], &mut right[..frames]);
        left[n..].fill(0.0);
        right[n..].fill(0.0);
        n
    }

    /// Fills the first frames from the ring and returns how many; `render` silences the rest.
    fn render_audio(&self, left: &mut [f32], right: &mut [f32]) -> usize {
        if !self.gate_open.load(Ordering::Acquire) {
            return 0;
        }
        // Only `flush` can hold this lock, and then a cycle of silence is fine.
        let Ok(mut consumer) = self.consumer.try_lock() else {
            return 0;
        };
        let frames = left.len();
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
        let (left, right) = (&mut left[..n], &mut right[..n]);
        stereo::deinterleave(chunk.as_slices(), left, right);
        chunk.commit_all();
        self.analysis.capture(left, right);
        self.buffered.fetch_sub(n * CHANNELS, Ordering::AcqRel);
        self.frames_rendered.fetch_add(n as u64, Ordering::Relaxed);
        // Non-negative floats order the same as their bit patterns.
        let peak = stereo::peak(left).max(stereo::peak(right));
        self.peak_bits.fetch_max(peak.to_bits(), Ordering::Relaxed);
        n
    }

    /// Pushes whole frames from `data`, converted to f32; returns how many samples were taken.
    fn push<T: Copy>(&self, data: &[T], to_f32: impl Fn(T) -> f32) -> usize {
        let mut producer = lock(&self.producer);
        let n = producer.slots().min(data.len()) / CHANNELS * CHANNELS;
        if n == 0 {
            return 0;
        }
        let Ok(mut chunk) = producer.write_chunk(n) else {
            return 0;
        };
        let (a, b) = chunk.as_mut_slices();
        let (first, rest) = data[..n].split_at(a.len());
        a.iter_mut().zip(first).for_each(|(slot, &s)| *slot = to_f32(s));
        b.iter_mut().zip(rest).for_each(|(slot, &s)| *slot = to_f32(s));
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

    /// Anything still pending from before a flush is stale. Returns true if it was dropped.
    fn drop_stale(&mut self) -> bool {
        let epoch = self.pcm.epoch.load(Ordering::Acquire);
        if epoch == self.epoch {
            return false;
        }
        self.epoch = epoch;
        self.pending.clear();
        true
    }
}

impl Sink for FloeSink {
    /// Converts straight into the ring; only samples that don't fit are kept
    /// (as f32) in `pending`, so a steady stream allocates nothing per packet.
    fn write(&mut self, packet: AudioPacket, _: &mut Converter) -> SinkResult<()> {
        // `Raw` only comes from the passthrough decoder, which we never enable.
        let AudioPacket::Samples(samples) = packet else {
            return Ok(());
        };
        self.drop_stale();
        if self.pcm.switching.load(Ordering::Acquire) {
            self.pending.clear();
            // Keep the old decoder paced while context resolution is in flight,
            // but return often enough for the player to receive the new load.
            let ms = (samples.len() / CHANNELS * 1000 / SAMPLE_RATE).clamp(1, 20);
            thread::sleep(Duration::from_millis(ms as u64));
            return Ok(());
        }
        // librespot's converter casts f64 to f32 without dithering; so does this.
        let mut fresh = &samples[..];
        loop {
            if self.drop_stale() || self.pcm.switching.load(Ordering::Acquire) {
                self.pending.clear();
                return Ok(());
            }
            // Parked samples go first, so the stream stays in order.
            if !self.pending.is_empty() {
                let taken = self.pcm.push(&self.pending, |s| s);
                self.pending.drain(..taken);
            }
            if self.pending.is_empty() {
                let taken = self.pcm.push(fresh, |s| s as f32);
                fresh = &fresh[taken..];
                if fresh.is_empty() {
                    return Ok(());
                }
            }
            // Ring is full. When paused, park the rest and return so the player
            // can process the pause command instead of blocking here.
            let waiting = self.pending.len() + fresh.len();
            let paused = !self.pcm.gate_open.load(Ordering::Acquire);
            if paused && waiting < MAX_PARKED_SAMPLES {
                self.pending.extend(fresh.iter().map(|&s| s as f32));
                return Ok(());
            }
            // Sleep about as long as it takes to drain room for what's waiting,
            // instead of waking every few ms to push a sliver.
            let frames = waiting / CHANNELS;
            let ms = (frames * 1000 / SAMPLE_RATE).clamp(5, 50) as u64;
            thread::sleep(Duration::from_millis(ms));
        }
    }
}

#[cfg(test)]
impl Pcm {
    pub fn push_f32(&self, data: &[f32]) -> usize {
        self.push(data, |s| s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn switching_does_not_block_the_player_on_old_packets() {
        let pcm = Pcm::new();
        pcm.begin_switch();
        let (tx, rx) = std::sync::mpsc::channel();
        let worker = thread::spawn(move || {
            let mut sink = FloeSink::new(pcm.clone());
            let mut converter = Converter::new(None);
            let old_audio = vec![0.25; RING_SAMPLES + MAX_PARKED_SAMPLES + 2];
            sink.write(AudioPacket::Samples(old_audio), &mut converter).unwrap();
            tx.send((sink.pending.is_empty(), pcm.take_stats().buffered_ms)).unwrap();
        });
        assert_eq!(rx.recv_timeout(Duration::from_secs(1)).unwrap(), (true, 0));
        worker.join().unwrap();
    }

    #[test]
    fn manual_switch_silences_and_discards_old_audio() {
        let pcm = Pcm::new();
        let mut left = [0.0; 4];
        let mut right = [0.0; 4];
        pcm.set_gate(true);
        pcm.push_f32(&[0.25; 8]);
        pcm.begin_switch();
        // Old decoding may continue while the new context is being resolved.
        pcm.push_f32(&[0.25; 8]);
        pcm.set_gate(true); // an old position correction must not reopen output
        assert_eq!(pcm.render(&mut left, &mut right), 0);
        assert_eq!(left, [0.0; 4]);
        pcm.track_changed();
        pcm.push_f32(&[0.75; 8]);
        pcm.set_gate(true);
        assert_eq!(pcm.render(&mut left, &mut right), 4);
        assert_eq!(left, [0.75; 4]);
        assert_eq!(right, [0.75; 4]);
    }

    #[test]
    fn automatic_gapless_switch_keeps_the_buffered_tail() {
        let pcm = Pcm::new();
        pcm.set_gate(true);
        pcm.push_f32(&[0.25; 8]);
        pcm.track_changed();
        let mut left = [0.0; 4];
        let mut right = [0.0; 4];
        assert_eq!(pcm.render(&mut left, &mut right), 4);
        assert_eq!(left, [0.25; 4]);
    }

    /// Timing only: `cargo test --release -- --ignored --nocapture bench_`.
    #[test]
    #[ignore]
    fn bench_render_and_sink_write() {
        const FRAMES: usize = 512;
        const ROUNDS: usize = 20_000;
        let pcm = Pcm::new();
        pcm.set_gate(true);
        pcm.analysis.set_enabled(true);
        let mut left = [0.0; FRAMES];
        let mut right = [0.0; FRAMES];
        let block: Vec<f32> = (0..FRAMES * CHANNELS).map(|i| (i as f32 * 0.001).sin()).collect();
        let start = Instant::now();
        for _ in 0..ROUNDS {
            pcm.push_f32(&block);
            std::hint::black_box(pcm.render(&mut left, &mut right));
        }
        let render = start.elapsed().as_nanos() as f64 / ROUNDS as f64;

        // librespot hands the sink packets of about 4096 f64 samples.
        let mut sink = FloeSink::new(pcm.clone());
        let mut converter = Converter::new(None);
        let packet: Vec<f64> = (0..4096).map(|i| (i as f64 * 0.001).sin()).collect();
        let start = Instant::now();
        for _ in 0..ROUNDS / 4 {
            sink.write(AudioPacket::Samples(packet.clone()), &mut converter).unwrap();
            while pcm.render(&mut left, &mut right) > 0 {}
        }
        let write = start.elapsed().as_nanos() as f64 / (ROUNDS / 4) as f64;
        println!("BENCH push+render {FRAMES} frames (tap on): {render:.0} ns; sink write 4096 samples + drain: {write:.0} ns");
    }

    #[test]
    fn skip_marker_does_not_silence_audio_and_expires_without_harming_gapless() {
        let pcm = Pcm::new();
        pcm.set_gate(true);
        pcm.prepare_skip();
        pcm.push_f32(&[0.25; 8]);
        let mut left = [0.0; 4];
        let mut right = [0.0; 4];
        assert_eq!(pcm.render(&mut left, &mut right), 4);
        assert_eq!(left, [0.25; 4]);
        *lock(&pcm.skip_requested) = Some(Instant::now() - SKIP_CONFIRMATION_WINDOW - Duration::from_millis(1));
        pcm.push_f32(&[0.5; 8]);
        pcm.track_changed();
        assert_eq!(pcm.render(&mut left, &mut right), 4);
        assert_eq!(left, [0.5; 4]);
    }
}
