import SwiftUI

/// Whether a track list is scrolling, and which row the pointer is on.
/// Mid-scroll every animation frame costs an update of the whole window, so
/// while the list moves its rows hold back hover (rows passing under a resting
/// pointer would each light up and fade) and covers that arrive skip their
/// fade. Not observed: reading it redraws nothing.
@MainActor final class ListMotion {
    /// Still this long after the last movement means at rest.
    static let settle = Duration.milliseconds(150)
    /// The pointer has to stay on a row this long before it lights up. Lighting
    /// a row costs about 4 ms of main thread (its views are worked out again,
    /// its menu is built), so a pointer dragged down the list, crossing fifty
    /// rows a second, held the main thread and the live background that draws
    /// on it. Two frames go unnoticed under the 160 ms the highlight takes to
    /// fade in; rows only passed over now do no work at all.
    static var dwell = Duration.milliseconds(30)
    private var lastMove = ContinuousClock.now - .seconds(1)
    /// Rows the pointer settled on mid-scroll, lit once the list stops.
    private var held: [Int: () -> Void] = [:]
    private var settling: Task<Void, Never>?
    /// The row the pointer is on but hasn't stayed on yet.
    private var entering: (row: Int, task: Task<Void, Never>)?

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

    func release(_ row: Int) {
        held[row] = nil
        if entering?.row == row {
            entering?.task.cancel()
            entering = nil
        }
    }

    /// Runs `light` once the pointer has stayed on `row` for `dwell`, unless
    /// the row is released first.
    func enter(_ row: Int, _ light: @escaping () -> Void) {
        entering?.task.cancel()
        entering = (row, Task { [weak self] in
            guard (try? await Task.sleep(for: Self.dwell)) != nil, let self, self.entering?.row == row else { return }
            self.entering = nil
            light()
        })
    }
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
