//! Bounded stereo tap of the samples actually rendered by Core Audio.
//! The render thread only attempts a lock and copies into a preallocated SPSC ring.
//! An independent analysis reader can fall behind without interrupting playback.
use std::sync::{
    Mutex,
    atomic::{AtomicBool, AtomicU64, Ordering},
};

const CAPACITY: usize = 4096 * 2; // 93 ms of stereo PCM, 32 KiB

struct Reader {
    consumer: rtrb::Consumer<f32>,
    generation: u64,
}

pub struct AnalysisTap {
    producer: Mutex<rtrb::Producer<f32>>,
    reader: Mutex<Reader>,
    enabled: AtomicBool,
    generation: AtomicU64,
}

impl AnalysisTap {
    pub fn new() -> Self {
        let (producer, consumer) = rtrb::RingBuffer::new(CAPACITY);
        Self {
            producer: Mutex::new(producer),
            reader: Mutex::new(Reader {
                consumer,
                generation: 0,
            }),
            enabled: AtomicBool::new(false),
            generation: AtomicU64::new(0),
        }
    }

    pub fn set_enabled(&self, enabled: bool) {
        self.enabled.store(enabled, Ordering::Release);
        self.reset();
    }

    pub fn reset(&self) {
        self.generation.fetch_add(1, Ordering::AcqRel);
    }

    /// Audio render thread only: never waits, allocates or performs signal analysis.
    pub fn capture(&self, left: &[f32], right: &[f32]) {
        if !self.enabled.load(Ordering::Acquire) {
            return;
        }
        let Ok(mut producer) = self.producer.try_lock() else { return; };
        let frames = left.len().min(right.len()).min(producer.slots() / 2);
        if frames == 0 {
            return;
        }
        let Ok(mut chunk) = producer.write_chunk(frames * 2) else { return; };
        let (a, b) = chunk.as_mut_slices();
        for (i, sample) in a.iter_mut().chain(b).enumerate() {
            *sample = if i % 2 == 0 { left[i / 2] } else { right[i / 2] };
        }
        chunk.commit_all();
    }

    /// Analysis queue only. Keep the newest samples, discard stale track/seek data.
    pub fn read_latest(&self, left: &mut [f32], right: &mut [f32]) -> (usize, u64) {
        let generation = self.generation.load(Ordering::Acquire);
        let mut reader = self.reader.lock().unwrap_or_else(|p| p.into_inner());
        if reader.generation != generation || !self.enabled.load(Ordering::Acquire) {
            let stale = reader.consumer.slots();
            if let Ok(chunk) = reader.consumer.read_chunk(stale) {
                chunk.commit_all();
            }
            reader.generation = generation;
            return (0, generation);
        }
        let available = reader.consumer.slots() / 2;
        let frames = available.min(left.len()).min(right.len());
        let discard = (available - frames) * 2;
        if discard > 0 {
            if let Ok(chunk) = reader.consumer.read_chunk(discard) {
                chunk.commit_all();
            }
        }
        if frames > 0 {
            if let Ok(chunk) = reader.consumer.read_chunk(frames * 2) {
                let (a, b) = chunk.as_slices();
                for (i, sample) in a.iter().chain(b).enumerate() {
                    if i % 2 == 0 {
                        left[i / 2] = *sample;
                    } else {
                        right[i / 2] = *sample;
                    }
                }
                chunk.commit_all();
            }
        }
        (frames, generation)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_tap_and_generation_reset_discard_samples() {
        let tap = AnalysisTap::new();
        let mut l = [0.; 8];
        let mut r = [0.; 8];
        tap.capture(&[1.; 8], &[2.; 8]);
        assert_eq!(tap.read_latest(&mut l, &mut r).0, 0);
        tap.set_enabled(true);
        tap.read_latest(&mut l, &mut r); // acknowledges the new generation
        tap.capture(&[1.; 8], &[-1.; 8]);
        assert_eq!(tap.read_latest(&mut l, &mut r).0, 8);
        assert_eq!(l, [1.; 8]);
        assert_eq!(r, [-1.; 8]);
        tap.capture(&[3.; 8], &[4.; 8]);
        tap.reset();
        assert_eq!(tap.read_latest(&mut l, &mut r).0, 0);
        tap.capture(&[5.; 8], &[6.; 8]);
        assert_eq!(tap.read_latest(&mut l, &mut r).0, 8);
        assert_eq!(l, [5.; 8]);
    }

    #[test]
    fn reader_keeps_latest_whole_stereo_frames() {
        let tap = AnalysisTap::new();
        tap.set_enabled(true);
        let mut l = [0.; 2];
        let mut r = [0.; 2];
        tap.read_latest(&mut l, &mut r);
        tap.capture(&[1., 2., 3., 4.], &[10., 20., 30., 40.]);
        assert_eq!(tap.read_latest(&mut l, &mut r).0, 2);
        assert_eq!(l, [3., 4.]);
        assert_eq!(r, [30., 40.]);
    }

    #[test]
    fn full_ring_never_blocks_playback_and_recovers() {
        let tap = AnalysisTap::new();
        tap.set_enabled(true);
        let mut l = [0.; 64];
        let mut r = [0.; 64];
        tap.read_latest(&mut l, &mut r);
        for _ in 0..200 {
            tap.capture(&[0.5; 64], &[-0.5; 64]);
        }
        assert_eq!(tap.read_latest(&mut l, &mut r).0, 64);
        assert_eq!(tap.read_latest(&mut l, &mut r).0, 0);
        tap.capture(&[1.; 64], &[0.; 64]);
        assert_eq!(tap.read_latest(&mut l, &mut r).0, 64);
        assert_eq!(l, [1.; 64]);
    }
}
