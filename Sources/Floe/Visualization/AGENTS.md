# Visualization — guide for agents

Audio analysis and everything drawn from it: the visualizer around or under the cover
and the three live backgrounds. The views that draw are in `../Views`
(`VisualizerView.swift`, `ReactiveBackground.swift`).

## Flow

```
Core Audio render thread (core/src/pcm.rs) -> stereo tap, 32 KiB ring (core/src/analysis.rs)
  -> SpectrumAnalyzer on a utility queue, ~30 Hz: FFT, 48 bands, 96 waveform points, RMS
  -> VisualizationModel.frame (not observed)
       -> VisualizerLayerView: redraws its shape layers per analysis frame
       -> BackgroundRenderer: takes the newest frame on its display link
            -> BeatDetector -> BackgroundAnimator (BackgroundMotion.swift) -> BeamRig / BloomRig / fluid
            -> ReactiveShader (Metal, compiled at runtime) -> MTKView drawable
       -> AutoPresetController / SoundClassifier: only while a song still needs classifying
```

File | Holds
---|---
`SpectrumAnalyzer.swift` | `SpectrumFrame`, the FFT and adaptive band levels
`VisualizationModel.swift` | starts and stops analysis, hands frames to listeners
`BeatDetector.swift` | kicks, snares, hats, tempo, builds and drops from frames
`BackgroundMotion.swift` | `BackgroundConfiguration`, `BackgroundAnimator`: one frame's state for the shaders
`BeamRig.swift`, `BloomRig.swift` | how Beams and Bloom answer the music
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
- **Frame rates are deliberate**: Beams 60 Hz, Fluid and Bloom 30 Hz
  (`BackgroundRenderer.frameRate`). Pixel budgets per kind are in
  `BackgroundRenderer.pixelBudget` and `bloomFieldBudget`.
- **Bloom's field textures are large** (26 bytes per field pixel: 34 MB at High
  detail). They are kept by size, not by dive, so a handover reuses them; released
  when nothing is drawing (paused, hidden) and when another kind draws. Bloom works
  every frame out afresh, so releasing loses nothing.
- **Flashing is bounded**: the strobe never exceeds three flashes a second, and tests
  hold Bloom to a flicker bound and to white-text contrast over it. Don't loosen
  these to make an effect livelier.
- Shaders compile at runtime (the Command Line Tools have no Metal compiler). The
  system caches the result, so only the first launch after a shader change pays
  (~0.7 s once, ~2 ms after).

## Checking a change

```sh
scripts/test-phase4.sh                        # analyzer and shader compile, seconds
FLOE_BLOOM_ONLY=1 scripts/test-background.sh  # Bloom's checks and GPU cost, about a minute
scripts/test-background.sh                    # everything: renderer, palette, Beams, Fluid, Bloom
scripts/test-layers.sh                        # the Core Animation visualizer, cover and progress track
scripts/test-autopreset.sh                    # genre table, sound classifier, cache
```

`FLOE_BACKGROUND_PREVIEWS=<dir>` and `FLOE_BLOOM_RENDERS=<dir>` write the rendered
frames as PNGs: look at them when a change is visual. The tests render the
production pipelines offscreen (`OffscreenRenderer` in `Tests/BackgroundTestSupport.swift`).
