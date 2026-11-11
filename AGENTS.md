# Tint — guide for agents

Tint is a native macOS Spotify client: SwiftUI + Core Animation + Metal on top of
librespot (Rust). README.md is the full reference (design, measurements, every
test); this file is the short map. Read the nested guide before working in a folder:

- [Sources/Floe/Views/AGENTS.md](Sources/Floe/Views/AGENTS.md) — UI, motion tokens, what may animate
- [Sources/Floe/Visualization/AGENTS.md](Sources/Floe/Visualization/AGENTS.md) — analysis, visualizer, Metal backgrounds
- [core/AGENTS.md](core/AGENTS.md) — the Rust playback core and its C ABI
- [Tests/AGENTS.md](Tests/AGENTS.md) — the offline tests and benchmarks, and which to run

## Names

The app is **Tint**. Everything you don't see keeps the old name **Floe**: the Swift
module and package (`Floe`), the bundle ID (`com.antonchurchyn.floe`), the Rust crate
(`floe_core`), launch flags (`-FloeSelfTest`), environment variables (`FLOE_…`) and
the folder `~/Library/Application Support/Floe`. Don't rename any of them: saved
logins and settings hang on them.

## Build and check

```sh
scripts/build-app.sh                      # cargo + swift build + bundle + sign -> build/Tint.app
swift build -c release --product Floe     # compile check only, ~50 s (needs core/target/release built once)
scripts/test-transport.sh                 # one offline suite; see Tests/AGENTS.md for the rest
```

- Only the Command Line Tools are installed: no Xcode, `xcodebuild`, XCTest or Swift
  Testing. Tests are standalone executables that the `scripts/test-*.sh` files compile
  with `swiftc` from an explicit list of sources.
- **A new source file that a test-compiled file depends on must be added to those
  scripts' lists**, or the scripts stop compiling. `grep -l <File>.swift scripts/*.sh`
  shows who compiles a file.
- `@State`, `#Preview`, `@Entry` and `@Animatable` need Xcode's macro plugin. Use
  `@ViewState` (Sources/Floe/Support/ViewState.swift) in place of `@State`.
- Swift 6 language mode, toolchain 6.4, macOS 26 only, Apple Silicon only.

## Don't launch the app to check your work

The owner is usually listening in it. The live self-tests (`-FloeSelfTest YES …`)
play audio, change the playing song and can stall on a system dialog when nobody
is at the Mac. Verify with the offline scripts; they need no login, network, audio
device or visible window. If a change can only be judged on screen (how a motion
feels, how Liquid Glass looks), say so instead of guessing, and leave it to the owner.

## Where things are

```
core/                    Rust staticlib: librespot session, Spirc, player, PCM ring, C ABI
Sources/CFloeCore/       floe_core.h + modulemap for it
Sources/Floe/
  App/                   FloeApp (scene, environment, when analysis runs), SelfTest, Snapshot, WindowPresence
  Core/                  FloeCore (Swift over the C ABI), CoreEvent (JSON events decoded)
  Playback/              PlayerModel (all playback state), AudioOutput (AVAudioEngine), NowPlaying (media keys), ConnectModel (queue, devices)
  API/                   WebAPI client, Models (Web API objects), PlaybackAPI (queue/device objects)
  Auth/                  OAuth PKCE, loopback redirect, token provider, CredentialStore (files, not Keychain)
  Library/               LibraryModel (playlists, pins, liked state), Navigator (routes + surface), SearchModel, ArtistGenres
  Images/                ArtworkCache + ArtworkView, CoverAppearance (cover, backdrop, palette per song), CoverPalette
  Lyrics/                LyricsService (LRCLIB, rate limits, cache), LyricsModel, LRC parser
  Visualization/         analyzer, visualizer model, live backgrounds (Fluid, Beams, Bloom), presets
  Settings/              AppSettings, the Settings window
  Support/               InterfaceScale, ViewState, ListMotion, Localization, MemoryFootprint
  Views/                 every view
Support/                 Info.plist, en/uk strings
Tests/, scripts/         offline test and benchmark executables and the scripts that build them
plans/                   motion plans from the improve-animations audits (README.md there has the status)
```

To change… | start in
---|---
what happens on play, pause, skip, seek, reconnect | `Playback/PlayerModel.swift` (state machine over `CoreEvent`s), then `core/src/lib.rs`
a page (Home, playlist, album, artist, Liked Songs, Search) | `Views/DiscoverPages.swift`, `CollectionPages.swift`, `SearchView.swift`; rows in `TrackList.swift`, cards in `Cards.swift`
the window's frame, toolbar, Library / Now Playing / Lyrics switch | `Views/RootView.swift`
the bottom bar, progress, volume | `Views/MiniPlayer.swift`, `ProgressTrack.swift`, `TransportControls.swift`
synced lyrics following | `Views/LyricsView.swift` (pinned frame by frame by `scripts/test-lyrics-follow.sh`)
cover loading, memory used by covers | `Images/Artwork.swift`
colours taken from the cover | `Images/CoverPalette.swift` (`scripts/test-palette.sh`)
a setting | `Settings/AppSettings.swift` or `Visualization/VisualSettings.swift`, UI in `Settings/SettingsView.swift` and `Views/VisualOptions.swift`
interface text | both `Support/Localizations/*.lproj/Localizable.strings` (and `.stringsdict` for plurals)

## Rules that cost time when broken

1. **Nothing that changes every frame may be read in a SwiftUI `body`.** Each SwiftUI
   update lays the whole window out again (about 1.7 ms of main thread), so 30 Hz
   through SwiftUI cost ~15% of a core. Continuous motion lives in Core Animation
   (`CrawlingCover`, `ProgressTrack`, `VisualizerLayerView`, `LoopingSymbol`) or in
   Metal (`ReactiveBackground`), which read the model themselves. State that changes
   often but needn't redraw is kept in plain classes (`ListMotion`, `ShelfMetrics`,
   `ListLayout`) or marked `@ObservationIgnored`.
2. **Clocks stop when nobody is looking**: paused, window covered or minimised
   (`WindowPresence`), app or system Reduce Motion. A new timer, display link or task
   loop needs the same gates (`FloeApp.needsAnalysis` is the pattern).
3. **Closures handed to a system framework from `@MainActor` code** (audio render
   block, artwork handler, Metal callbacks) trap when the framework calls them off
   the main thread. Build them in a `nonisolated static` function
   (`AudioOutput.makeSourceNode` is the pattern).
4. **Liquid Glass only through `glassControl(tint:in:)`** (`Views/Components.swift`).
   Window snapshots can't draw glass and that helper swaps in a flat tint for them.
5. **Sizes in views are Compact points** and pass through `@Environment(\.interfaceScale)`:
   `scale(12)`, `scale.gutter`, `.floeFont(size:)`. A bare literal ignores the interface size.
6. **Memory is a feature** (target: under 150 MB while playing). Images are decoded at
   display size only; a gradient-filled SwiftUI shape gets a bitmap as large as its
   bounds; one tall `Text` gets one tall layer. `FLOE_SCROLL_BACKING=1
   scripts/benchmark-scroll.sh` lists the layers holding the most pixels.
7. **Measure before and after** a performance change with the script that covers it
   (Tests/AGENTS.md), and put the numbers in the comment or commit. Guesses have been
   wrong here in both directions.
8. Spotify's Development Mode limits what the Web API answers (README, "Web API
   limits"). Check there before building on an endpoint.

## Conventions

- Comments say why, in plain sentences, with the measurement when there is one. No
  restating of what the code does.
- Value types for data; `@MainActor @Observable final class` for models; `actor` only
  where state is truly shared off the main actor (`ArtworkCache`, `LyricsService`).
- Commit messages are one plain sentence in the imperative ("Stop the playing symbols
  in the Library while it's hidden"). There is no git remote; never push or add one
  without asking.
- Work on a branch off `integrate-redesign`; parallel agents work in git worktrees
  (symlink `core/target/release` from the main checkout so they build).
