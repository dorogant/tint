# 005 — Feel polish: like star, mini-player extras, shelf cards, cover dip

- **Status**: DONE
- **Commit**: e102e24
- **Severity**: MEDIUM
- **Category**: Purpose & frequency / Accessibility / Cohesion
- **Estimated scope**: 4 files, ~25 lines

## Problems and targets

### a) The like star bounces when data arrives, not when the user clicks
```swift
// Sources/Floe/Views/TrackList.swift:331-338 — current
let liked = library.isLiked(uri) ?? false
Button {
    Task { await library.toggleLike(uri) }
} label: {
    Image(systemName: liked ? "star.fill" : "star")
        .font(.system(size: size))
        .contentTransition(.symbolEffect(.replace))
        .symbolEffect(.bounce, value: liked)
```
Rows request liked state on appear, so liked rows bounce while scrolling; the mini player's star bounces on track changes. It also ignores Reduce Motion.
**Target**: follow `IconButton` (`Sources/Floe/Views/Components.swift:195-203`): add `@ViewState private var presses = 0` and `@ReducedMotion private var reduceMotion` to the star's view; increment `presses` in the button action before the Task; use `.symbolEffect(.bounce, value: reduceMotion ? 0 : presses)`. Keep `.contentTransition(.symbolEffect(.replace))`.

### b) Mini player's hover extras use the 400 ms arrival spring
```swift
// Sources/Floe/Views/MiniPlayer.swift:111 — current
.animation(still ? FloeMotion.fade : (shown ? FloeMotion.enter : FloeMotion.exit), value: shown)
```
They appear every time the pointer crosses the mini player. **Target**: `.floeHover(shown)` (0.16 s in / 0.24 s out, fade with Reduce Motion). Keep the `.offset(x: shown || still ? 0 : 6)` and opacity lines.

### c) Shelf cards scale while scrolling even with Reduce Motion
```swift
// Sources/Floe/Views/Cards.swift:193-195 — current
content(item).scrollTransition(.interactive, axis: .horizontal) { card, phase in
    card.scaleEffect(phase.isIdentity ? 1 : 0.9).opacity(phase.isIdentity ? 1 : 0.5)
}
```
**Target**: `card.scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.9).opacity(phase.isIdentity ? 1 : 0.5)` (`reduceMotion` is already declared in `Shelf`). If Swift complains about capturing it, copy it to a local `let still = reduceMotion` before the `ForEach`.

### d) The cover dip is far bouncier than the rest of the app (every skip, incl. ⌘→)
```swift
// Sources/Floe/Views/NowPlayingView.swift:227-230 — current
KeyframeTrack {
    CubicKeyframe(0.93, duration: 0.14)
    SpringKeyframe(1, duration: 0.6, spring: .bouncy)
}
```
**Target**:
```swift
KeyframeTrack {
    CubicKeyframe(0.97, duration: 0.1)
    SpringKeyframe(1, duration: 0.35, spring: Spring(duration: 0.35, bounce: 0.15))
}
```
Update the comment above (`// A new cover dips and springs back as it arrives.`) only if it no longer fits.

## Repo conventions to follow

- `IconButton` (`Components.swift:195-203`) is the exemplar for press-driven symbol bounces gated on Reduce Motion.
- `floeHover` is defined in `Motion.swift:96-98`.

## Steps

1. a) TrackList.swift star view. 2. b) MiniPlayer.swift:111. 3. c) Cards.swift:194. 4. d) NowPlayingView.swift:227-230. 5. `swift build -c release`.

## Boundaries

- Only these four spots. Do NOT touch layout, sizes, other animations, `Motion.swift`, `RootView.swift`, `LyricsView.swift`, `CrawlingCover.swift`.
- On drift, STOP and report.

## Verification

- **Mechanical**: build passes.
- **Feel check** (owner): scroll Liked Songs — stars don't bounce; click a star — it bounces once. Hover the mini player — extras arrive quickly and leave a bit slower. Turn on Reduce motion and scroll a shelf — cards only dim at the edges. Skip tracks on Now Playing — the cover dips subtly and settles without wobble.
- **Done when**: all four targets are in place and the build passes.
