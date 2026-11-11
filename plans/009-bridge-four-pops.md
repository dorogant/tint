# 009 — Bridge four pops: live background, visualizer, pinned playlists, unliked rows

- **Status**: TODO
- **Commit**: 95ea037
- **Severity**: LOW
- **Category**: Missed opportunities (preventing a jarring change)
- **Estimated scope**: 4 files, ~20 lines

Four occasional actions change a large part of the window in one frame. Each gets
the smallest bridge that makes the change legible. They are independent; do them in
any order and stop after any of them.

## a) Live background on/off

```swift
// Sources/Floe/Views/Components.swift:31-42 — current
                if visuals.liveBackground {
                    // The album's own colours, even when the interface uses a fixed accent.
                    let cover = appearance.coverURL == nil ? palette : appearance.palette
                    ReactiveBackground(colors: cover.colors, neutral: cover.isNeutral)
                        .allowsHitTesting(false)
                }
                RadialGradient(colors: [palette.accent.opacity(0.22), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 700)
                Color.black.opacity(0.28)
            }
            .floeAnimation(value: appearance.backgroundURL, duration: 0.45)
            .floeAnimation(value: palette.rgb, duration: 0.45)
```

The toggle (Visuals popover, Settings) makes a full-window light show appear or
vanish at once, while every other change to the backdrop takes 0.45 s.

**Target**: add `.transition(.opacity)` after `.allowsHitTesting(false)`, and a third line
`.floeAnimation(value: visuals.liveBackground, duration: 0.45)` after the two existing
ones. Opacity only, so it is the same with Reduce Motion (`floeAnimation` falls back
to `FloeMotion.fade`, 0.18 s).

## b) Visualizer on/off and Normal/Circular in Now Playing

```swift
// Sources/Floe/Views/NowPlayingView.swift — current
                            CoverStage(size: coverSize, ring: ring) {
                                if circular { VisualizerView(circular: true).opacity(ringShown ? 1 : 0) }
                            }
…
                    if normal { VisualizerView().frame(height: scale(84)).padding(.horizontal, scale(24)) }
                }
                .padding(scale.margin)
                .animation(still ? nil : FloeMotion.enter, value: showLyrics)
```

Toggling "Show visualizer" or its style makes the ring or the bottom strip pop, and
the cover jumps to its new size (the strip takes 96 pt of height, the ring scales
the cover's room).

**Target**:
- ring: `if circular { VisualizerView(circular: true).opacity(ringShown ? 1 : 0).transition(.opacity) }`
- strip: append `.transition(still ? .opacity : .opacity.combined(with: .move(edge: .bottom)))`
- after the existing `.animation(…, value: showLyrics)` line add
  `.animation(still ? FloeMotion.fade : FloeMotion.enter, value: settings.showVisualizer)` and
  `.animation(still ? FloeMotion.fade : FloeMotion.enter, value: settings.style)`
  (`FloeMotion.enter`: spring 0.4 s, bounce 0.1; `settings` is the view's `VisualSettings`).

The cover is a Core Animation view; plan 003 made its resize cheap, so animating
`coverSize` is allowed. **This one must be looked at**: if the cover's scalloped rim
visibly lags or steps while the size animates, keep the two transitions and drop
the two `.animation` lines (the strip then fades while the cover still jumps).

## c) Pinning and unpinning a playlist

```swift
// Sources/Floe/Views/Sidebar.swift:22-41 — current
                    if !pinned.isEmpty {
                        GroupTitle(title: "Pinned Playlists", systemImage: "pin.fill")
                        ForEach(pinned) {
                            PlaylistRow(playlist: $0, selection: selection, showsSelection: true)
                        }
                    }
…
            .padding(.top, 1)
            .floeGlide(value: navigator.section)
```

A pin inserts a row (the first pin also a group title) above "All Playlists" and the
whole list jumps down; an unpin jumps it up.

**Target**: add `.floeGlide(value: library.pinnedIDs)` after the existing `.floeGlide`
line (`FloeMotion.glide`: spring 0.3 s, bounce 0.08; a 0.18 s fade with Reduce
Motion). Rows keep SwiftUI's default opacity transition; the rows below slide.

## d) A song leaving Liked Songs

```swift
// Sources/Floe/Views/CollectionPages.swift — SongsView.reconcile(), current
        entries = fresh.map { saved in
            addedID -= 1
            return TrackEntry(id: addedID, track: saved.track, addedAt: saved.addedAt)
        } + kept
        revision += 1
```

Unliking a song on the Liked Songs page removes its row and every row below jumps up 56 pt.

**Target**: add `@ReducedMotion private var still` to `SongsView`, and wrap those
two statements:

```swift
        withAnimation(still ? FloeMotion.fade : FloeMotion.glide) {
            entries = fresh.map { saved in
                addedID -= 1
                return TrackEntry(id: addedID, track: saved.track, addedAt: saved.addedAt)
            } + kept
            revision += 1
        }
```

## Repo conventions to follow

- Tokens come from `FloeMotion` (`Sources/Floe/Views/Motion.swift`); the `floe…` modifiers
  apply the Reduce Motion fallback themselves, hand-written `withAnimation` must (as above).
- Exemplar for an animated list change: `HomeView`'s
  `.floeAnimation(value: library.hiddenArtists)` on the Top Artists shelf
  (`Sources/Floe/Views/DiscoverPages.swift`).

## Steps

1. (a) `Components.swift`: two lines. 2. (b) `NowPlayingView.swift`: four lines. 3. (c) `Sidebar.swift`:
one line. 4. (d) `CollectionPages.swift`: the property and the `withAnimation`. 5. `swift build -c release --product Floe`.

## Boundaries

- Do NOT animate a change of sort order or of the filter text in a track list: those
  move thousands of rows the user is reading.
- Do NOT touch `ReactiveBackground.swift`, `CrawlingCover.swift` or `VisualizerView.swift`.
- Do NOT add stagger to any of these.
- If the code doesn't match these excerpts, STOP and report.

## Verification

- **Mechanical**: the build succeeds; `scripts/test-background.sh` still passes (it hosts
  `ReactiveBackground` in SwiftUI); `scripts/test-layout.sh` passes (sidebar and pages).
- **Feel check** (owner, in the app):
  - (a) Toggle Live background while a song plays: it fades in and out over under half a
    second with the rest of the backdrop; no black frame at either end.
  - (b) Toggle Show visualizer, then switch Normal/Circular: the strip rises in from the
    bottom edge, the ring fades, the cover eases to its new size without the rim stepping.
  - (c) Pin a playlist from its page: the sidebar's rows slide down to make room and
    the new row fades in. Unpin: the reverse. The selection indicator still glides.
  - (d) On Liked Songs, click a row's star: the row fades and the rows below close up
    in 0.3 s. The scroll position holds.
  - Each with Reduce Motion on: a short fade, nothing slides.
- **Done when**: the build and the two test scripts pass and each change no longer cuts.
