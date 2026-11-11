# Tests — guide for agents

There is no test framework here (no Xcode). Each suite is an executable with a
`@main`: a `scripts/*.sh` file compiles it with `swiftc` together with the production
sources it tests, runs it, and the suite prints `PASS: …` lines or stops on a
`precondition`. Everything is offline: no login, network, audio device or visible
window. Offscreen windows sit at (-30000, -30000).

## Which script for which change

You touched | Run | Time
---|---|---
`Playback/PlayerModel.swift`, `Core/CoreEvent.swift` | `scripts/test-transport.sh` | seconds
`Images/Artwork.swift` | `scripts/test-artwork.sh` | seconds
`API/`, `Auth/TokenProviders.swift`, `Playback/ConnectModel.swift`, strings | `scripts/test-phase5.sh` | seconds
`Lyrics/`, `Images/CoverPalette.swift` | `scripts/test-phase3.sh`, `scripts/test-palette.sh` | seconds
`Auth/CredentialStore.swift` | `scripts/test-credentials.sh` | seconds
`Visualization/SpectrumAnalyzer.swift`, shaders, `core/src/analysis.rs` | `scripts/test-phase4.sh` | seconds
`Views/CrawlingCover.swift`, `ProgressTrack.swift`, `VisualizerView.swift` | `scripts/test-layers.sh` | seconds
auto preset, genres, `SoundClassifier` | `scripts/test-autopreset.sh` | seconds
`Views/LyricsView.swift` | `scripts/test-lyrics-follow.sh`, `scripts/benchmark-lyrics.sh` | a few minutes
`Views/ReactiveBackground.swift`, `Visualization/Background*`, `BeamRig`, `ReactiveShader` | `scripts/test-background.sh` | a minute or two
page layout, guides, sidebar, toolbar | `scripts/test-layout.sh` (PNGs in /tmp/tint-layout) | a minute
track rows, covers in lists, `LibraryModel` liked state | `scripts/benchmark-scroll.sh` | ~3 minutes
`core/src/*.rs` | `cd core && cargo test --release` | seconds once built
anything | `swift build -c release --product Floe` | ~50 s

`.github/workflows/build.yml` runs the build and the fast suites; the rendering ones
are advisory there because CI GPUs differ.

## Benchmarks and what their numbers mean

- `scripts/benchmark-scroll.sh` scrolls a 600-track playlist in the real window.
  Read "main thread busy", the p95 frame time and "frames over 8.3 ms". Baseline on
  an M3 Air (2026-11-11): cold p50 1.8 ms / p95 4.9 ms; warm p50 1.7 ms / p95 9.7 ms.
  `FLOE_SCROLL_ONLY=cold,warm,hover,flick,sweep,cold-liked` picks runs (`sweep` drags a
  stand-in pointer up and down the resting list, at 1.5 × `FLOE_SCROLL_SPEED`);
  `FLOE_SCROLL_VIEWS=1` counts AppKit views and layer shadows;
  `FLOE_SCROLL_BACKING=1` lists the layers holding the most pixels (memory);
  `FLOE_SCROLL_REDRAWS=1` lists layers redrawn during the run. To profile, build the
  binary as the script does, start it, and run `sample <pid> 8 1` during a pass.
- `scripts/benchmark-core.sh`: cover decoding, per-song cover work, core-event
  decoding and the Rust audio path.
- `scripts/benchmark-lyrics.sh`: CPU, window layouts and clock wakeups of the lyric view.
- Offscreen, SwiftUI runs an animation as fast as the main thread allows instead of
  once per display refresh, so while anything animates "main thread busy" reads near
  100% and the layouts per second are in the thousands. Compare the time per window
  layout (the sweep prints it; otherwise busy time ÷ layouts), not the busy share.
- Timings move by 10–20% between runs. Compare a before and an after taken in the
  same sitting, with nothing else building.

## Writing a test

- Add to the suite that already compiles the file you changed; a new suite needs a
  new script and a line in the table above and in the workflow.
- The scripts list their sources by hand. When production code gains a dependency on
  another file, add that file to every script that compiles the dependent one
  (`grep -l Artwork.swift scripts/*.sh`).
- Suites replace the I/O edge with a stub declared in a `…Support.swift` file and
  compile production code against it: `PlaybackTransportTestSupport.swift` (core,
  audio output, credentials), `BackgroundTestSupport.swift` (`VisualizationModel`,
  `OffscreenRenderer`), `LayoutRenderSupport.swift` (fixture HTTP for the Web API).
  A production type that grows a method used by tested code needs it in the stub.
- Settings in tests come from `TestDefaults.make()`, never `UserDefaults.standard`,
  so a run can't write to the app's real preferences.
- Timing-dependent code takes its delay from a `static var` the test shortens
  (`PlayerModel.unansweredPlay`), rather than the test sleeping for real seconds.
- Compile-time switches reach production code as `-D` flags: `SCROLL_BENCHMARK`
  (counters in rows), `LYRICS_FOLLOW_TESTING` (probes in lyric rows).
- Check pixels, not intentions, for anything drawn: the layer and background suites
  render with `CARenderer` or Metal into a texture and read it back.

## Live checks (owner only)

`build/Tint.app/Contents/MacOS/Tint -FloeSelfTest YES …` plays music and drives the
real app; README lists the modes (`-FloeSelfTestPerf YES` measures CPU and footprint
per visual scenario). Don't run these unasked.
