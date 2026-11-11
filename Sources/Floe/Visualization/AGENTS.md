# Visualization — guide for agents

Audio analysis and everything drawn from it: the visualizer around or under the cover
and the two live backgrounds, Fluid and Beams. The views that draw are in `../Views`
(`VisualizerView.swift`, `ReactiveBackground.swift`).

## Flow

```
Core Audio render thread (core/src/pcm.rs) -> stereo tap, 32 KiB ring (core/src/analysis.rs)
  -> SpectrumAnalyzer on a utility queue, ~30 Hz: FFT, 48 bands, 96 waveform points, RMS
  -> VisualizationModel.frame (not observed)
       -> VisualizerLayerView: redraws its shape layers per analysis frame
       -> BackgroundRenderer: takes the newest frame on its display link
            -> BeatDetector -> BackgroundAnimator (BackgroundMotion.swift) -> BeamRig / FluidMotion
            -> ReactiveShader (Metal, compiled at runtime) -> MTKView drawable
       -> AutoPresetController / SoundClassifier: only while a song still needs classifying
```

File | Holds
---|---
`SpectrumAnalyzer.swift` | `SpectrumFrame`, the FFT and adaptive band levels
`VisualizationModel.swift` | starts and stops analysis, hands frames to listeners
`BeatDetector.swift` | kicks, snares, hats and tempo from frames
`BackgroundMotion.swift` | `BackgroundConfiguration`, `BackgroundAnimator`: one frame's state for the shaders
`BeamRig.swift` | how Beams answers the music (Fluid's motion is in `BackgroundMotion.swift`)
`ReactiveShader.swift` | all Metal shader source, as Swift strings
`VisualSettings.swift` | persisted visual preferences, presets
`AutoPresetController.swift`, `GenrePresets.swift`, `SoundClassifier.swift` | the per-song auto preset

## Invariants

- **Per-frame values never reach SwiftUI.** Only `VisualizationModel.isRunning` and
  `backgroundFailure` are observed. Views register a frame listener instead.
- **Analysis runs only when something visible needs it** (`FloeApp.needsAnalysis`):
  playing, window visible, no Reduce Motion, an effect on. Everything downstream stops
  with it; a paused background draws one still frame and then nothing.
- **No allocation per frame.** Uniforms are tuples and `InlineArray`s; textures and
  passes are cached by size. `Tests/AllocationCounter.swift` checks this in
  `scripts/test-background.sh`; a `map` or a new array in a per-frame path fails it.
- **Frame rates are deliberate**: Beams 60 Hz, Fluid 30 Hz
  (`BackgroundRenderer.frameRate`). Pixel budgets per kind are in
  `BackgroundRenderer.pixelBudget`.
- **The display link and its draws run on the main thread.** Anything that keeps the
  main thread busy (a burst of SwiftUI updates, a hover animation per row) shows up
  as dropped background frames. Keep main-thread work per frame small.
- **Flashing is bounded**: the strobe never exceeds three flashes a second, and tests
  hold the backgrounds to a luminance limit that keeps white text readable. Don't
  loosen these to make an effect livelier.
- A third kind, Bloom (a Mandelbrot dive), was removed on 2026-11-11 with the
  pitch, brightness, build and drop analysis that only it used. Don't bring it back
  piecemeal; `git log -- Sources/Floe/Visualization/BloomRig.swift` has it.
- Shaders compile at runtime (the Command Line Tools have no Metal compiler). The
  system caches the result, so only the first launch after a shader change pays
  (~0.7 s once, ~2 ms after).

## Checking a change

```sh
scripts/test-phase4.sh                        # analyzer and shader compile, seconds
scripts/test-background.sh                    # renderer, palette, Beams, Fluid, flash rate, a minute or two
scripts/test-layers.sh                        # the Core Animation visualizer, cover and progress track
scripts/test-autopreset.sh                    # genre table, sound classifier, cache
```

`FLOE_BACKGROUND_PREVIEWS=<dir>` writes the rendered frames as PNGs: look at them
when a change is visual. The tests render the
production pipelines offscreen (`OffscreenRenderer` in `Tests/BackgroundTestSupport.swift`).
