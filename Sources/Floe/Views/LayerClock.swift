import QuartzCore

extension CALayer {
    /// Freezes this layer's animations, and its sublayers', where they are.
    func pauseClock() {
        guard speed != 0 else { return }
        timeOffset = convertTime(CACurrentMediaTime(), from: nil)
        speed = 0
    }

    /// Resumes animations from where `pauseClock()` stopped them.
    func resumeClock() {
        guard speed == 0 else { return }
        let pausedAt = timeOffset
        speed = 1
        timeOffset = 0
        beginTime = 0
        beginTime = convertTime(CACurrentMediaTime(), from: nil) - pausedAt
    }
}
