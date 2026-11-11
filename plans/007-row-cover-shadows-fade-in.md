# 007 — Row covers: no shadow at rest, and fade it in instead of growing it

- **Status**: TODO
- **Commit**: 95ea037
- **Severity**: LOW
- **Category**: Performance
- **Estimated scope**: 2 files, ~20 lines

## Problem

Every track row's cover and every sidebar playlist's cover carries a shadow modifier
all the time, with a transparent colour while the row isn't hovered:

```swift
// Sources/Floe/Views/TrackList.swift:129-131 — current
                ArtworkView(images: track.album?.images, size: scale(40), cornerRadius: scale(6))
                    .shadow(color: .black.opacity(hovering ? 0.45 : 0), radius: hovering ? 6 : 0, y: 2)
                    .scaleEffect(hovering && !still ? 1.03 : 1)
```

```swift
// Sources/Floe/Views/Sidebar.swift:183-184 — current
                ArtworkView(images: playlist.images, size: metrics.column, cornerRadius: metrics.coverRadius)
                    .shadow(color: .black.opacity(hovering || selected ? 0.35 : 0), radius: 4, y: 2)
```

Two costs:

1. **A shadow layer per row at rest.** `FLOE_SCROLL_VIEWS=1 scripts/benchmark-scroll.sh`
   reports `7 shadows and 29 invisible ones without a path` (2026-11-11): 29 layers
   have a Core Animation shadow whose colour is fully transparent, one per cover on
   screen. A layer shadow without a path is worked out from the layer's alpha in an
   offscreen pass. Whether the render server skips that for a clear colour isn't
   documented, and these layers move on every frame of a scroll.
2. **The hover animates the shadow's radius** (0 → 6). A radius change draws the
   shadow again on each frame of the animation. Hovering rows is the most frequent
   pointer interaction in the app; it should animate opacity and transform only.

This plan doesn't claim a measured gain: the app's own main thread doesn't do this
work (the window server does), so the scroll benchmark can't see it. It removes the
layers and the radius animation, which is safe either way.

## Target

The shadow becomes a shape behind the cover that exists only while it shows, with a
fixed radius, faded by opacity.

```swift
// Sources/Floe/Views/TrackList.swift — target
                ArtworkView(images: track.album?.images, size: scale(40), cornerRadius: scale(6))
                    // Behind the cover and only while hovered: a row at rest has no
                    // shadow layer, and the shadow fades in rather than growing.
                    .background {
                        if hovering {
                            RoundedRectangle(cornerRadius: scale(6)).fill(.black)
                                .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                                .transition(.opacity)
                        }
                    }
                    .scaleEffect(hovering && !still ? 1.03 : 1)
```

```swift
// Sources/Floe/Views/Sidebar.swift — target
                ArtworkView(images: playlist.images, size: metrics.column, cornerRadius: metrics.coverRadius)
                    .background {
                        if hovering || selected {
                            RoundedRectangle(cornerRadius: metrics.coverRadius).fill(.black)
                                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                                .transition(.opacity)
                        }
                    }
```

Both rows already animate on `hovering` (`.floeHover(hovering)`: 0.16 s in, 0.24 s
out, a 0.18 s fade with Reduce Motion), which drives the `.opacity` transition. The
sidebar's selection changes inside `.floeGlide(value: navigator.section)` on its
scroll view, which animates the `selected` case.

## Repo conventions to follow

- Hover-only parts of a row are built only while hovered: see the row's "…" menu,
  `Sources/Floe/Views/TrackList.swift` (`if hovering { Menu { … } }` with `.transition(.opacity)`).
- Sizes pass through `scale(…)`; the corner radii above are the covers' own.

## Steps

1. `TrackList.swift`: replace the `.shadow(…)` line on the row's `ArtworkView` with the `.background { … }` block.
2. `Sidebar.swift`: the same on `PlaylistRow`'s `ArtworkView`.
3. `swift build -c release --product Floe`.
4. `FLOE_SCROLL_VIEWS=1 FLOE_SCROLL_ONLY=cold,warm,hover scripts/benchmark-scroll.sh`.

## Boundaries

- Do NOT change `Card`'s shadow (`Cards.swift:36`), `MiniCover`'s (`MiniPlayer.swift:166`)
  or the page headers' glow: those always show, and are few.
- Do NOT touch the row's other hover effects (the wash, the number-to-Play swap).
- Do NOT add the shadow back as a second modifier "for safety".
- If the code doesn't match these excerpts, STOP and report.

## Verification

- **Mechanical**: the build succeeds. In the benchmark's census line,
  `invisible ones without a path` falls from 29 to 4 or fewer. Main-thread numbers stay
  within run-to-run noise of the baseline (warm: busy 38%, p50 1.74 ms, p95 9.74 ms;
  hover: busy 42%, p95 9.25 ms).
- **Feel check** (owner, in the app):
  - Move the pointer over a track row: the cover lifts 3% and a soft shadow fades in
    under it in about 0.16 s; moving off, it fades out a little slower. No pop, no dark flash.
  - A cover that is still loading (grey placeholder) turns black under the pointer.
    If that reads badly, fill the shape with `Color(white: 0.11)` (the panel's tint) instead.
  - Sidebar: the hovered and the selected playlist's cover keep their small shadow.
  - Sweep quickly down a long list: a short soft wake, as before.
- **Done when**: the census shows the shadow layers gone and the hover looks as it did.
