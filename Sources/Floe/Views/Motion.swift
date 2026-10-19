import SwiftUI

/// Short, event-driven motion; hover and navigation never start their own timer.
private struct FloeAnimation<Value: Equatable>: ViewModifier {
    let value: Value
    var duration: Double
    var bounce: Double
    @ReducedMotion private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? FloeMotion.fade : .spring(duration: duration, bounce: bounce), value: value)
    }
}

extension View {
    /// A spring that settles in `duration`; a little `bounce` suits larger moves.
    /// With Reduce Motion it falls back to a fade.
    func floeAnimation<Value: Equatable>(value: Value, duration: Double = 0.24, bounce: Double = 0) -> some View {
        modifier(FloeAnimation(value: value, duration: duration, bounce: bounce))
    }

    /// The playing cover flies between the mini player and Now Playing.
    func heroCover() -> some View { modifier(HeroCover()) }
}

/// The shared timings, so browsing and playback surfaces move alike. Hover
/// arrives quickly and leaves a little slower; a press dips fast and is
/// released on a spring; indicators and reveals glide.
enum FloeMotion {
    static let hoverIn = Animation.spring(duration: 0.16, bounce: 0)
    static let hoverOut = Animation.spring(duration: 0.24, bounce: 0)
    static let press = Animation.spring(duration: 0.14, bounce: 0)
    static let release = Animation.spring(duration: 0.3, bounce: 0.12)
    static let glide = Animation.spring(duration: 0.3, bounce: 0.08)
    static let reveal = Animation.spring(duration: 0.42, bounce: 0)
    /// Library ↔ Now Playing ↔ Lyrics, and the toolbar pill that names them.
    static let surface = Animation.spring(duration: 0.32, bounce: 0)
    /// Things that arrive (banners, a new song's title) and leave; exits are quicker.
    static let enter = Animation.spring(duration: 0.4, bounce: 0.1)
    static let exit = Animation.spring(duration: 0.22, bounce: 0)
    /// With Reduce Motion nothing moves or scales, but colour and opacity still fade.
    static let fade = Animation.easeOut(duration: 0.18)

    static func hover(_ hovering: Bool) -> Animation { hovering ? hoverIn : hoverOut }
    static func press(_ pressed: Bool) -> Animation { pressed ? press : release }

    /// Stagger for the first few items only; later ones arrive with the last.
    static func stagger(_ index: Int) -> Double { Double(min(max(index, 0), 8)) * 0.03 }
}

/// True when either the app's or the system's Reduce Motion is on. Views use it
/// to drop movement and scale while keeping colour and opacity changes.
@MainActor
@propertyWrapper
struct ReducedMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @AppStorage("reduceMotion") private var app = false

    init() {}

    var wrappedValue: Bool { system || app }
}

private struct FloeHover: ViewModifier {
    let hovering: Bool
    @ReducedMotion private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? FloeMotion.fade : FloeMotion.hover(hovering), value: hovering)
    }
}

private struct FloeTimed<Value: Equatable>: ViewModifier {
    let value: Value
    let animation: Animation
    @ReducedMotion private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? FloeMotion.fade : animation, value: value)
    }
}

/// Shares one indicator between rows so it glides; with Reduce Motion each row
/// keeps its own, which simply fades.
private struct FloeMatched: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    @ReducedMotion private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if reduceMotion { content } else { content.matchedGeometryEffect(id: id, in: namespace) }
    }
}

extension View {
    /// A selection or active-item indicator that glides between rows.
    func floeMatched(_ id: String, in namespace: Namespace.ID) -> some View {
        modifier(FloeMatched(id: id, namespace: namespace))
    }

    /// Hover in fast, out a little slower; a plain fade with Reduce Motion.
    func floeHover(_ hovering: Bool) -> some View {
        modifier(FloeHover(hovering: hovering))
    }

    /// Gliding indicators (selection, active device); a fade with Reduce Motion.
    func floeGlide<Value: Equatable>(value: Value) -> some View {
        modifier(FloeTimed(value: value, animation: FloeMotion.glide))
    }

    /// Quick state changes such as selection colour; a fade with Reduce Motion
    /// rather than none, so the change still reads.
    func floeState<Value: Equatable>(value: Value, duration: Double = 0.2) -> some View {
        modifier(FloeTimed(value: value, animation: .spring(duration: duration, bounce: 0)))
    }
}

private struct HeroNamespaceKey: EnvironmentKey {
    static var defaultValue: Namespace.ID? { nil }
}

extension EnvironmentValues {
    var heroNamespace: Namespace.ID? {
        get { self[HeroNamespaceKey.self] }
        set { self[HeroNamespaceKey.self] = newValue }
    }
}

private struct HeroCover: ViewModifier {
    @Environment(\.heroNamespace) private var namespace
    @ViewBuilder func body(content: Content) -> some View {
        if let namespace { content.matchedGeometryEffect(id: "cover", in: namespace) } else { content }
    }
}

/// Now Playing and Lyrics rise a little over the Library as they fade in and
/// sink back as they leave. No blur: blurring a whole panel re-rendered it
/// offscreen every frame. With Reduce Motion they only fade.
struct SurfaceTransition: Transition {
    var still: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let moved = !phase.isIdentity && !still
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .scaleEffect(moved ? 0.98 : 1)
            .offset(y: moved ? 16 : 0)
    }
}

// MARK: - Reveal

/// Remembers which sections of a page have already made their entrance, so a
/// refresh that rebuilds one shows it in place instead of replaying it.
@MainActor
final class RevealLedger {
    private var shown: Set<String> = []
    func contains(_ key: String) -> Bool { shown.contains(key) }
    func claim(_ key: String) { shown.insert(key) }
}

private struct RevealLedgerKey: EnvironmentKey {
    static var defaultValue: RevealLedger? { nil }
}

extension EnvironmentValues {
    var revealLedger: RevealLedger? {
        get { self[RevealLedgerKey.self] }
        set { self[RevealLedgerKey.self] = newValue }
    }
}

private struct RevealScope: ViewModifier {
    @ViewState private var ledger = RevealLedger()
    func body(content: Content) -> some View { content.environment(\.revealLedger, ledger) }
}

/// Fades a section up into place on its first appearance. Without a scope it
/// replays whenever the view is rebuilt.
private struct Reveal: ViewModifier {
    let key: String
    let order: Int
    @Environment(\.revealLedger) private var ledger
    @ReducedMotion private var reduceMotion
    @ViewState private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || ledger?.contains(key) == true
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 10)
            .onAppear {
                guard !visible else { return }
                ledger?.claim(key)
                let animation = reduceMotion ? FloeMotion.fade : FloeMotion.reveal.delay(FloeMotion.stagger(order))
                withAnimation(animation) { shown = true }
            }
    }
}

extension View {
    /// Applied once per page so its sections reveal only the first time.
    func revealScope() -> some View { modifier(RevealScope()) }

    /// A short entrance on first appearance, staggered by `order` (30 ms steps,
    /// first eight only). Opacity only with Reduce Motion.
    func reveal(_ key: String, order: Int = 0) -> some View {
        modifier(Reveal(key: key, order: order))
    }
}

// MARK: - Buttons

/// The app-wide press and hover feel: a gentle brightening and lift under the
/// pointer, a quick dip on press that springs back on release.
struct FloeButtonStyle: ButtonStyle {
    /// Growth under the pointer. Rows, and cards that lift their own artwork, use 1.
    var hoverScale: CGFloat = 1.03
    var pressScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        FloeButtonBody(configuration: configuration, hoverScale: hoverScale, pressScale: pressScale)
    }
}

private struct FloeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let hoverScale: CGFloat
    let pressScale: CGFloat
    @Environment(\.isEnabled) private var enabled
    @ReducedMotion private var reduceMotion
    @ViewState private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed && enabled
        let lit = hovering && enabled
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (pressed ? pressScale : (lit ? hoverScale : 1)))
            .brightness(lit && !pressed ? 0.04 : 0)
            .opacity(pressed ? 0.88 : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? FloeMotion.fade : FloeMotion.press(pressed), value: pressed)
            .floeHover(lit)
    }
}

extension ButtonStyle where Self == FloeButtonStyle {
    static var floe: FloeButtonStyle { FloeButtonStyle() }
    /// Full-width rows: no growth on hover, a shallower press.
    static var floeRow: FloeButtonStyle { FloeButtonStyle(hoverScale: 1, pressScale: 0.985) }
}
