# 001 — Keep Library mounted and make the surface switch light

- **Status**: TODO
- **Commit**: e102e24
- **Severity**: HIGH
- **Category**: Performance / Interruptibility / Easing & duration
- **Estimated scope**: 2 files (`Sources/Floe/Views/RootView.swift` MainView + SurfaceSwitcher, `Sources/Floe/Views/Motion.swift`), ~60 lines

## Problem

Switching Library ↔ Now Playing ↔ Lyrics stutters "from time to time". Three causes, all in the switch itself:

1. Every switch destroys the visible surface and builds the next one in the transition's first frame, because the whole surface group is re-identified:

```swift
// Sources/Floe/Views/RootView.swift:46-83 — current
Group {
    switch navigator.surface {
    case .library:
        HStack(spacing: Theme.margin) {
            SidebarView().frame(width: 240).glassPanel()
            ZStack { /* ScrollView { page … }.id(navigator.current).transition(.opacity) */ }
            /* … */
        }
    case .nowPlaying:
        NowPlayingView().glassPanel()
    case .lyrics:
        LyricsView().frame(maxWidth: 780).frame(maxWidth: .infinity).glassPanel()
    }
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
.id(navigator.surface)
.transition(SurfaceTransition(raised: navigator.surface != .library))
```
   Returning to Library rebuilds the sidebar and page, replays section reveals and loses the page's scroll position.

2. The Library is blurred 10 pt and scaled as a whole every frame while it leaves or returns — an offscreen re-render plus a ~20 px Gaussian blur over most of the window, uncacheable because the scale changes each frame:

```swift
// Sources/Floe/Views/Motion.swift:132-147 — current
struct SurfaceTransition: Transition {
    var raised: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let scale: CGFloat = raised ? 0.97 : (phase == .didDisappear ? 0.95 : 1)
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .scaleEffect(phase.isIdentity ? 1 : scale)
            .offset(y: phase.isIdentity || !raised ? 0 : 40)
            .blur(radius: phase.isIdentity || raised ? 0 : 10)
    }
}
```

3. The spring is long and bouncy for a very frequent action, and the toolbar pill moves on a different spring for the same event:

```swift
// Sources/Floe/Views/RootView.swift:91 — current
.floeAnimation(value: navigator.surface, duration: 0.45, bounce: 0.12)
// Sources/Floe/Views/RootView.swift:189 — current (SurfaceSwitcher)
.animation(still ? FloeMotion.fade : FloeMotion.glide, value: selection)
// Sources/Floe/Views/Motion.swift:33 — current
static let glide = Animation.spring(duration: 0.4, bounce: 0.12)
```

## Target

- Library is always mounted. When another surface is up, Library sits underneath at opacity 0, takes no hits and is hidden from VoiceOver. It is never scaled or blurred (a documented earlier bug: scaling its scroll views left pages resting a few points scrolled — opacity only).
- Now Playing / Lyrics are inserted above it with a light transition: opacity 0→1, scale 0.98→1, offset y 16→0. No blur. With Reduce Motion: opacity only.
- One token drives the panel and the toolbar pill: `FloeMotion.surface = .spring(duration: 0.32, bounce: 0)`.
- `FloeMotion.glide` becomes `.spring(duration: 0.3, bounce: 0.08)` (sidebar selection, active device, mute also use it).

```swift
// Motion.swift — target additions/changes inside enum FloeMotion
static let glide = Animation.spring(duration: 0.3, bounce: 0.08)
/// Library ↔ Now Playing ↔ Lyrics, and the toolbar pill that names them.
static let surface = Animation.spring(duration: 0.32, bounce: 0)
```

```swift
// Motion.swift — target SurfaceTransition (replaces the current one and its doc comment)
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
```

## Repo conventions to follow

- Motion tokens live in `enum FloeMotion` (`Sources/Floe/Views/Motion.swift:27-48`); add `surface` there with a one-line doc comment like its neighbours.
- `@ReducedMotion private var still` is already declared in MainView (`RootView.swift:41`) and SurfaceSwitcher (`:171`). Reduce Motion falls back to `FloeMotion.fade`, never `nil` (see `Motion.swift:38` comment).
- Short "why" comments above non-obvious code; keep the existing long comments about the 1-pt scroll inset intact.

## Steps

1. `Motion.swift`: change `glide` to `.spring(duration: 0.3, bounce: 0.08)`; add `surface` as above; replace `SurfaceTransition` (struct + its doc comment) with the target version.
2. `RootView.swift` MainView body: extract the current `case .library:` HStack (sidebar + page ZStack, unchanged inside, including `.floeAnimation(value: navigator.current)`) into `private var libraryPanel: some View`. Replace the `Group { switch … }.frame(…).id(…).transition(…)` block with:
```swift
ZStack {
    // Library stays mounted under Now Playing and Lyrics, so raising one never
    // rebuilds it, and coming back is instant and keeps its scroll position.
    libraryPanel
        .opacity(navigator.surface == .library ? 1 : 0)
        .allowsHitTesting(navigator.surface == .library)
        .accessibilityHidden(navigator.surface != .library)
    if navigator.surface != .library {
        raisedSurface
            .id(navigator.surface)
            .transition(SurfaceTransition(still: still))
    }
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
```
   and add
```swift
@ViewBuilder private var raisedSurface: some View {
    switch navigator.surface {
    case .library: EmptyView()
    case .nowPlaying: NowPlayingView().glassPanel()
    case .lyrics: LyricsView().frame(maxWidth: 780).frame(maxWidth: .infinity).glassPanel()
    }
}
```
3. `RootView.swift:91`: replace `.floeAnimation(value: navigator.surface, duration: 0.45, bounce: 0.12)` with `.animation(still ? FloeMotion.fade : FloeMotion.surface, value: navigator.surface)`.
4. `RootView.swift:189` (SurfaceSwitcher): replace `FloeMotion.glide` with `FloeMotion.surface`.
5. `swift build -c release` must pass. Grep for any other `SurfaceTransition(raised:` call site and update it to `SurfaceTransition(still:)`.

## Boundaries

- Do NOT touch the page-level `ScrollView … .id(navigator.current).transition(.opacity)` or its comments.
- Do NOT touch `MiniPlayerView`'s insert/remove (plan 004 handles its Reduce Motion), OnboardingView, toolbar content, or the hero cover.
- Do NOT add `.disabled` to the hidden library (it would re-evaluate every button body on each switch).
- If the code at the cited lines differs from the excerpts (drift), STOP and report.

## Verification

- **Mechanical**: `swift build -c release` passes; `scripts/test-layers.sh` prints PASS.
- **Feel check** (owner, on the real app): Library → Now Playing → Lyrics → Library with the toolbar switcher and with clicks on the mini cover:
  - The first frame moves immediately; no hitch at the start or at the end.
  - Returning to Library shows the page exactly where it was scrolled, with no section re-reveal.
  - Clicking Library/Now Playing rapidly never shows a frozen or doubled panel.
  - The pill and the panel arrive together.
  - With Settings > Reduce motion on: surfaces only crossfade.
  - With Library hidden, scroll wheel and clicks over Now Playing never scroll or hit the library.
- **Done when**: the build passes, no blur remains in `SurfaceTransition`, and `navigator.surface` changes no longer re-identify Library.
