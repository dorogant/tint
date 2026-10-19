import SwiftUI

/// Whether a track list is scrolling. Mid-scroll every animation frame costs
/// an update of the whole window, so while the list moves its rows hold back
/// hover (rows passing under a resting pointer would each light up and fade)
/// and covers that arrive skip their fade. Not observed: reading it redraws nothing.
@MainActor final class ListMotion {
    /// Still this long after the last movement means at rest.
    static let settle = Duration.milliseconds(150)
    private var lastMove = ContinuousClock.now - .seconds(1)
    /// Rows the pointer settled on mid-scroll, lit once the list stops.
    private var held: [Int: () -> Void] = [:]
    private var settling: Task<Void, Never>?

    var isMoving: Bool { ContinuousClock.now - lastMove < Self.settle }

    func moved() {
        lastMove = .now
        #if SCROLL_BENCHMARK
        ScrollProbe.moves += 1
        #endif
    }

    /// Runs `light` once the list settles, unless the row is released first.
    func hold(_ row: Int, _ light: @escaping () -> Void) {
        held[row] = light
        guard settling == nil else { return }
        settling = Task { [weak self] in
            while let self, self.isMoving { try? await Task.sleep(for: Self.settle) }
            guard let self else { return }
            let lights = held.values
            held = [:]
            settling = nil
            lights.forEach { $0() }
        }
    }

    func release(_ row: Int) { held[row] = nil }
}

private struct ListMotionKey: EnvironmentKey {
    static var defaultValue: ListMotion? { nil }
}

extension EnvironmentValues {
    /// The enclosing track list's motion; nil outside one.
    var listMotion: ListMotion? {
        get { self[ListMotionKey.self] }
        set { self[ListMotionKey.self] = newValue }
    }
}
