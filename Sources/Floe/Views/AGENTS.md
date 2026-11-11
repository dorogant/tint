# Views — guide for agents

Every view of the main window and the Settings window's shared controls. The models
they read live one folder up (`Playback/`, `Library/`, `Images/`, `Lyrics/`, `Visualization/`).

## Files

File | Holds
---|---
`RootView.swift` | `RootView` (onboarding or main), `MainView` (panels, toolbar, mini player), the Library / Now Playing / Lyrics switcher
`Components.swift` | `Theme`, `Backdrop`, `glassPanel`, `glassControl`, `PlayPill`, `IconButton`, `SectionHeader`, `LoadingView`, `MessageView`, `Format`
`Motion.swift` | `FloeMotion` tokens, `@ReducedMotion`, `floeHover` / `floeAnimation` / `floeGlide` / `floeState`, `reveal`, `SurfaceTransition`, `FloeButtonStyle`
`PlaybackMotion.swift` | `TactileButtonStyle`, the track-change transition
`Sidebar.swift` | navigation rows, playlists, account row
`DiscoverPages.swift` | Home and its tiles, artist page
`CollectionPages.swift` | playlist, album, Liked Songs; list filter and sort
`TrackList.swift` | `TrackListView`, `TrackRow`, `LikeButton`, link texts, track menus
`Cards.swift` | `Card`, `Shelf` (horizontal shelves), hover Play button
`PageHeader.swift` | header shared by collection pages, cover glow, page placeholder
`SearchView.swift` | results page and the toolbar search field's behaviour
`MiniPlayer.swift` | bottom bar, `ProgressBar`, `VolumeControl`
`TransportControls.swift` | shuffle, previous, play/pause, next, repeat
`NowPlayingView.swift` | the Now Playing surface and its cover stage
`LyricsView.swift` | plain and synced lyrics; the follow logic
`ConnectViews.swift` | Queue and Devices popovers
`OnboardingView.swift` | the two sign-in steps
`VisualOptions.swift` | visualizer and live-background controls (popover and Settings)
`CrawlingCover.swift`, `ProgressTrack.swift`, `VisualizerView.swift`, `LoopingSymbol.swift`, `ScrubReadout.swift`, `ReactiveBackground.swift` | AppKit / Core Animation / Metal views wrapped for SwiftUI; all continuous motion is here
`LayerClock.swift`, `BlobShape.swift`, `ShufflePressFeedback.swift` | small helpers for the above

## Cost model

- One SwiftUI update of this window costs about 1.7 ms of main thread, whatever
  changed, because the hosting view lays the window out again. An animation driven
  by SwiftUI is one such update per frame for as long as it runs.
- So: SwiftUI animates short, event-driven changes (hover, press, selection, a new
  song's title). Anything that runs for seconds or loops belongs in a
  `CALayer`/`NSView` wrapper, which animates in the render server at no cost to the app.
- A scrolling track list already costs one update per frame. `ListMotion` tells rows
  the list is moving; while it is, rows don't start hover or fade animations.
- A new `TrackRow` costs a few milliseconds to create and measure (profiled: nearly
  all of it is SwiftUI measuring the row's stacks and text). Every view added to a row
  is paid for on each row that scrolls in. Build hover-only parts only while hovered,
  as the row's "…" menu is.
- Keep a row's state in the row (`@ViewState private var hovering`) so one row
  redraws, and read models as narrowly as possible: `library.isLiked(uri)` observes
  one track's flag, not the library.

## Motion

Use the tokens in `Motion.swift`; don't type a new duration at a call site.

Token | Value | For
---|---|---
`FloeMotion.hoverIn` / `hoverOut` | spring 0.16 s / 0.24 s, no bounce | hover, through `.floeHover(hovering)`
`FloeMotion.press` / `release` | spring 0.14 s / 0.3 s bounce 0.12 | press dips, through `.buttonStyle(.floe)` or `TactileButtonStyle`
`FloeMotion.glide` | spring 0.3 s bounce 0.08 | selection indicators that move between rows (`.floeGlide`)
`FloeMotion.surface` | spring 0.32 s | Library ↔ Now Playing ↔ Lyrics
`FloeMotion.enter` / `exit` | spring 0.4 s bounce 0.1 / 0.22 s | things that arrive and leave; exits are faster
`FloeMotion.reveal` | spring 0.42 s, +30 ms per section for the first eight | a page's sections on first appearance (`.reveal(key, order:)` inside `.revealScope()`)
`FloeMotion.fade` | ease-out 0.18 s | every Reduce Motion fallback
`FloeMotion.lyricGlide` | ease-in-out 0.35 s | the lyric list, its rows and the pill, which must share one curve

Rules:

- Ask first whether it should animate. Keyboard-driven actions (Space, ⌘←/→, volume
  keys, ⌘F) and anything seen hundreds of times a day get no animation. Hover gets
  the fast tokens only. Rare moments (first run, empty states) may have more.
- Animate transform (`scaleEffect`, `offset`) and `opacity`. Animating a shadow's
  radius, a blur's radius or a frame redraws or re-lays out every frame.
- Never enter from `scale(0)`; 0.95–0.98 with opacity.
- Every moving animation needs its Reduce Motion form: read `@ReducedMotion private var
  still` and keep the opacity/colour change while dropping scale and offset. The
  `floe…` modifiers do this for you; hand-written `withAnimation` must do it itself.
- Exits are faster than entrances (`enter` 0.4 s, `exit` 0.22 s).
- Looping symbols use `LoopingSymbol`, never an endless SwiftUI `.symbolEffect`
  (measured at ~35% CPU for one page of rows).

`plans/README.md` lists what the motion audits found and what is still open.

## Layout

- Sizes are Compact points through `@Environment(\.interfaceScale) private var scale`:
  `scale(12)`, `scale.gutter`, `scale.plate`, `scale.corner`, `.floeFont(size:weight:)`.
- Pages start on shared guides: content on `scale.gutter`, hover plates reaching
  `scale.plate` past it. `scripts/test-layout.sh` renders the window at three sizes and
  checks the guides.
- Large panels are tinted, not live-blurred (`glassPanel`). Small controls take Liquid
  Glass through `glassControl` only.
- Interface text is `Text("…")` with a key present in both `Localizable.strings`
  files, or `L10n.string("…")` where a `String` is needed.
