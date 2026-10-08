import AppKit
import SwiftUI

/// The "playing" speaker whose waves fill in a loop, animated by AppKit. A
/// SwiftUI `.symbolEffect(.variableColor.iterative)` never finishes, so it
/// re-rendered and re-laid out the whole window every frame while a playing row
/// was on screen (~35% CPU on a page of search results); here only the symbol
/// moves, and SwiftUI updates when its colour, size or running state changes.
struct PlayingSymbol: NSViewRepresentable {
    let pointSize: CGFloat
    let color: Color
    let animating: Bool

    func makeNSView(context: Context) -> PlayingSymbolView { PlayingSymbolView() }

    func updateNSView(_ view: PlayingSymbolView, context: Context) {
        view.update(pointSize: pointSize, color: NSColor(color), animating: animating)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlayingSymbolView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

final class PlayingSymbolView: NSImageView {
    private var pointSize: CGFloat = 0
    private var animating = false

    init() {
        super.init(frame: .zero)
        imageScaling = .scaleNone
        setAccessibilityLabel(L10n.string("Playing"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(pointSize: CGFloat, color: NSColor, animating: Bool) {
        contentTintColor = color
        if pointSize != self.pointSize {
            self.pointSize = pointSize
            image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        }
        guard animating != self.animating else { return }
        self.animating = animating
        if animating { addSymbolEffect(.variableColor.iterative) } else { removeAllSymbolEffects() }
    }
}
