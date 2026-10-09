import AppKit
import SwiftUI

/// A symbol whose effect loops for as long as it runs, animated by AppKit. A
/// never-ending SwiftUI `.symbolEffect` re-renders and re-lays out the whole
/// window every frame: the playing speaker cost ~35% CPU on a page of search
/// results, and the lyrics' breathing "…" laid the window out thousands of
/// times a second offscreen. Here only the symbol moves; SwiftUI updates when
/// its colour, size or running state changes. Clicks pass through to the row.
struct LoopingSymbol: NSViewRepresentable {
    enum Effect { case waves, breathe }

    let systemName: String
    let pointSize: CGFloat
    var weight: NSFont.Weight = .regular
    let color: Color
    let effect: Effect
    let running: Bool
    let label: String

    /// The "playing" speaker whose waves fill in a loop.
    static func playing(pointSize: CGFloat, color: Color, running: Bool) -> LoopingSymbol {
        LoopingSymbol(systemName: "speaker.wave.3.fill", pointSize: pointSize, color: color, effect: .waves,
                      running: running, label: L10n.string("Playing"))
    }

    /// The instrumental gap in synced lyrics, breathing while it's the current line.
    static func instrumental(pointSize: CGFloat, running: Bool) -> LoopingSymbol {
        LoopingSymbol(systemName: "ellipsis", pointSize: pointSize, weight: .bold, color: .white, effect: .breathe,
                      running: running, label: L10n.string("Instrumental"))
    }

    func makeNSView(context: Context) -> LoopingSymbolView { LoopingSymbolView() }

    func updateNSView(_ view: LoopingSymbolView, context: Context) {
        view.update(self)
    }

    /// The image's own size, as a SwiftUI `Image` lays out. (The view's intrinsic
    /// size is its alignment rect, which made the lyric gap's row 7 pt taller.)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LoopingSymbolView, context: Context) -> CGSize? {
        nsView.image?.size
    }
}

final class LoopingSymbolView: NSImageView {
    private var symbol: (name: String, pointSize: CGFloat, weight: NSFont.Weight)?
    private var running = false

    init() {
        super.init(frame: .zero)
        imageScaling = .scaleNone
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ spec: LoopingSymbol) {
        contentTintColor = NSColor(spec.color)
        setAccessibilityLabel(spec.label)
        if symbol?.name != spec.systemName || symbol?.pointSize != spec.pointSize || symbol?.weight != spec.weight {
            symbol = (spec.systemName, spec.pointSize, spec.weight)
            // A new image drops any running effect; start it again below.
            removeAllSymbolEffects(animated: false)
            running = false
            image = NSImage(systemSymbolName: spec.systemName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: spec.pointSize, weight: spec.weight))
        }
        guard spec.running != running else { return }
        running = spec.running
        switch (running, spec.effect) {
        case (false, _): removeAllSymbolEffects()
        case (true, .waves): addSymbolEffect(.variableColor.iterative)
        case (true, .breathe): addSymbolEffect(.breathe)
        }
    }
}
