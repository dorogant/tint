# 004 — With Reduce Motion, fade instead of cutting

- **Status**: DONE
- **Commit**: e102e24
- **Severity**: HIGH
- **Category**: Accessibility
- **Estimated scope**: 3 files (`Motion.swift`, `LyricsView.swift`, `RootView.swift`), ~10 lines
- **Depends on**: 001 (SurfaceTransition already takes `still` there)

## Problem

`floeAnimation` drops animation entirely under Reduce Motion, contradicting the app's own rule (`Motion.swift:38`: "With Reduce Motion nothing moves or scales, but colour and opacity still fade"). Result: hard cuts on the whole-window backdrop at every track change (`Components.swift:58-59`), page swaps (`RootView.swift:73`), lyrics content, Settings sections, hiding an artist.

```swift
// Sources/Floe/Views/Motion.swift:11 — current
content.animation(reduceMotion ? nil : .spring(duration: duration, bounce: bounce), value: value)
```

Once that fades, three transitions it drives would start *moving* under Reduce Motion, because they aren't motion-aware:

```swift
// Sources/Floe/Views/LyricsView.swift:14 — current
.transition(.blurReplace)
// Sources/Floe/Views/LyricsView.swift:27 — current
.transition(.move(edge: .bottom).combined(with: .opacity))
// Sources/Floe/Views/RootView.swift:86 — current
.transition(.opacity.combined(with: .move(edge: .bottom)))
```

## Target

```swift
// Motion.swift:11 — target
content.animation(reduceMotion ? FloeMotion.fade : .spring(duration: duration, bounce: bounce), value: value)
```
- `LyricsView` gains `@ReducedMotion private var still`; line 14 becomes `.transition(still ? .opacity : .blurReplace)`; line 27 becomes `.transition(still ? .opacity : .move(edge: .bottom).combined(with: .opacity))`.
- `RootView.swift:86` becomes `.transition(still ? .opacity : .opacity.combined(with: .move(edge: .bottom)))` (`still` already exists in MainView).
- Update the doc comment on `floeAnimation` to say it falls back to a fade.

## Repo conventions to follow

- `FloeTimed` (`Motion.swift:73-80`) is the exemplar: `reduceMotion ? FloeMotion.fade : animation`.

## Steps

1. Edit `Motion.swift:11` and the `floeAnimation` doc comment.
2. Edit the three transitions as above.
3. `grep -rn "floeAnimation" Sources` and read each call site: if any relies on "no animation at all with Reduce Motion" for correctness (e.g. scroll positioning), report it rather than changing it.
4. `swift build -c release`.

## Boundaries

- Do NOT change any non-Reduce-Motion timing.
- On drift, STOP and report.

## Verification

- **Mechanical**: build passes.
- **Feel check** (owner): turn on Settings > Reduce motion. Skip tracks: the backdrop crossfades (no cut). Switch surfaces and pages: crossfades, nothing slides, scales or blurs. Open Lyrics on a new song: content crossfades. Turn Reduce motion off: everything moves as before.
- **Done when**: no `nil` Reduce-Motion fallback remains in `Motion.swift`, and the three transitions are opacity-only when `still`.
