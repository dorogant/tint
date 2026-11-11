# core — guide for agents

`floe_core`: a Rust static library that wraps librespot and exposes a small C ABI.
Swift links `core/target/release/libfloe_core.a` (see `Package.swift`).

File | Holds
---|---
`src/lib.rs` | the `extern "C"` functions, the tokio runtime (2 workers), session and Spirc lifecycle, session events
`src/events.rs` | librespot `PlayerEvent` -> the JSON events Swift decodes
`src/pcm.rs` | `FloeSink` (librespot's player thread writes here), the lock-free ring, `floe_render` for the audio thread
`src/analysis.rs` | the stereo tap the visualizer reads, bounded, never blocks the render thread
`src/stereo.rs` | interleaved <-> planar copies used on the audio thread
`src/fetch.rs` | read-ahead settings (1 s instead of librespot's 5 s; `FLOE_AUDIO_READ_AHEAD_MS` overrides)

## Three things to keep in step

1. **The C ABI**: `src/lib.rs` (`#[unsafe(no_mangle)] extern "C"`), the header
   `Sources/CFloeCore/floe_core.h`, and the Swift wrapper `Sources/Floe/Core/FloeCore.swift`.
2. **The events**: JSON built in `src/lib.rs` and `src/events.rs`, decoded in
   `Sources/Floe/Core/CoreEvent.swift`. A new or changed field needs both sides, and
   `Tests/PlaybackTransportTests.swift` decodes the wire shapes.
3. **The stubs**: `Tests/PlaybackTransportTestSupport.swift` stands in for `FloeCore`
   and `AudioOutput`. A new `FloeCore` method that `PlayerModel` calls needs a stub there.

## Rules

- The render callback (`floe_render`) and the tap run on Core Audio's real-time
  thread: no allocation, no blocking lock (only `try_lock`), no logging.
- librespot is pinned to one commit across all its crates in `Cargo.toml`. Bump it on
  purpose and as a whole; the 0.8.0 crates.io release doesn't build.
- librespot's player makes its own tokio runtime; Tint's is capped at two workers.
- Swift owns volume and when the audio engine runs; the core owns decoding, the
  buffer and Spotify Connect state. `PlayerModel` believes only events, never its
  own commands: a skip or Play that Spirc ignores must change nothing.

## Build and test

```sh
cd core && cargo build --release      # run from core/ so rust-toolchain.toml applies
cd core && cargo test --release       # config, analysis, transport events, stereo, buffering
scripts/benchmark-core.sh             # audio path timings (push+render ~260 ns per 512 frames, sink write ~1.5 µs)
```

The release profile is `lto = true`, `codegen-units = 1`. The first build fetches
librespot and takes a few minutes; `scripts/build-app.sh` runs it for you.
