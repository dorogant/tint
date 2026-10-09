//! Interleaved stereo ring chunks to and from planar channels.
//!
//! A ring chunk can wrap, so it arrives as two halves. Every read and write
//! moves whole frames into rings of even capacity, so each half holds whole
//! frames too. Plain zipped loops let the compiler drop bounds checks and
//! vectorize; these run on the audio render thread.

/// Copies the frames in `halves` to the start of `left` and `right`.
pub fn deinterleave((a, b): (&[f32], &[f32]), left: &mut [f32], right: &mut [f32]) {
    debug_assert!(a.len() % 2 == 0 && b.len() % 2 == 0);
    let split = a.len() / 2;
    let (left_a, left_b) = left.split_at_mut(split.min(left.len()));
    let (right_a, right_b) = right.split_at_mut(split.min(right.len()));
    for ((l, r), frame) in left_a.iter_mut().zip(right_a).zip(a.chunks_exact(2)) {
        *l = frame[0];
        *r = frame[1];
    }
    for ((l, r), frame) in left_b.iter_mut().zip(right_b).zip(b.chunks_exact(2)) {
        *l = frame[0];
        *r = frame[1];
    }
}

/// Fills `halves` with frames from the start of `left` and `right`.
pub fn interleave(left: &[f32], right: &[f32], (a, b): (&mut [f32], &mut [f32])) {
    debug_assert!(a.len() % 2 == 0 && b.len() % 2 == 0);
    let split = (a.len() / 2).min(left.len()).min(right.len());
    let (left_a, left_b) = left.split_at(split);
    let (right_a, right_b) = right.split_at(split);
    for ((&l, &r), frame) in left_a.iter().zip(right_a).zip(a.chunks_exact_mut(2)) {
        frame[0] = l;
        frame[1] = r;
    }
    for ((&l, &r), frame) in left_b.iter().zip(right_b).zip(b.chunks_exact_mut(2)) {
        frame[0] = l;
        frame[1] = r;
    }
}

/// Largest absolute sample.
pub fn peak(samples: &[f32]) -> f32 {
    samples.iter().fold(0.0, |peak, s| peak.max(s.abs()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrapped_chunks_round_trip_in_frame_order() {
        let a = [1., -1., 2., -2.];
        let b = [3., -3.];
        let (mut left, mut right) = ([0.; 4], [0.; 4]);
        deinterleave((&a, &b), &mut left, &mut right);
        assert_eq!(left, [1., 2., 3., 0.]);
        assert_eq!(right, [-1., -2., -3., 0.]);
        let (mut x, mut y) = ([0.; 2], [0.; 4]);
        interleave(&left[..3], &right[..3], (&mut x, &mut y));
        assert_eq!(x, [1., -1.]);
        assert_eq!(y, [2., -2., 3., -3.]);
        assert_eq!(peak(&[0.25, -0.5, 0.125]), 0.5);
    }
}
