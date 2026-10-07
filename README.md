# Floe

A lightweight native Spotify client for macOS (Apple Silicon): SwiftUI on top of
[librespot](https://github.com/librespot-org/librespot) in Rust. It replaces the
Chromium-based official app for everyday listening, with a target of **≤150 MB RAM**
during playback and ~0% CPU when idle. See [PLAN.md](PLAN.md) for the full plan.

> Floe uses librespot, an **unofficial** Spotify client library. That is against
> Spotify's terms of use; bans are rare but possible, and protocol changes can break
> playback until librespot catches up. It needs **Spotify Premium**, and offline
> downloads are not possible. Floe is not affiliated with Spotify.

## Requirements

- macOS 26+ on Apple Silicon
- Xcode **Command Line Tools** (full Xcode is not needed): `xcode-select --install`
- Rust via [rustup](https://rustup.rs) (1.85+)

## Build and run

```sh
scripts/build-app.sh          # -> build/Floe.app (release, ad-hoc signed)
scripts/build-app.sh --open   # build, then launch
```

The script runs `cargo build --release` for the Rust core, `swift build` for the app,
assembles the bundle (Info.plist, generated placeholder icon) and ad-hoc signs it.

**Self-test** (play → pause → seek → resume, with audio counters and RAM, logged to stdout):

```sh
build/Floe.app/Contents/MacOS/Floe -FloeSelfTest YES [-FloeSelfTestTrack spotify:track:…]
```

## Layout

```
core/                 Rust staticlib: librespot session + player, C ABI (src/lib.rs)
Sources/CFloeCore/    C header + modulemap for the Rust library
Sources/Floe/         SwiftUI app
  App/                app entry, PlayerModel, self-test
  Core/               Swift wrapper over the C ABI, event decoding
  Audio/              AVAudioEngine output fed from the core
  Auth/               OAuth PKCE (loopback redirect), Keychain
  Views/              UI
Support/Info.plist    bundle metadata
scripts/              build-app.sh, make-icon.swift
```

## How it works

- **Audio path.** librespot decodes on its own thread into a custom `Sink`, which writes
  interleaved f32 PCM into a lock-free ring buffer. An `AVAudioSourceNode` pulls from it
  on the render thread (`floe_render`). Pause closes a gate so audio stops immediately
  rather than after the buffer drains; seek and load flush the buffer. Volume (and later
  the visualizer) live on the Swift side of this path.
- **Bridge.** A plain C ABI (`Sources/CFloeCore/floe_core.h`) of about a dozen functions.
  Results come back as JSON events through one callback. UniFFI would add a code
  generator for no real gain at this size.
- **Login.** librespot's session must be authorised with *Spotify's own* client ID
  (`streaming` scope): Spotify rejects third-party client IDs there. Floe runs the PKCE
  flow in the browser with a one-shot listener on `127.0.0.1:5588/login`, gets
  reusable credentials back from librespot, and stores only those in the Keychain.
  The Web API (Phase 2) uses Floe's own client ID with PKCE on `127.0.0.1:8898/callback`.
  No client secret is used or stored anywhere.
- **librespot version.** Pinned to a commit on `dev` (see `core/Cargo.toml`): the 0.8.0
  release doesn't build from crates.io (librespot-org/librespot#1760). Bump it on purpose.

### Command Line Tools quirks

- In the current SDK, `@State` is a macro whose compiler plugin ships only with Xcode.
  Use `@ViewState` instead (an alias for the same property wrapper, in
  `Sources/Floe/Support/ViewState.swift`). `#Preview`, `@Entry` and `@Animatable`
  are unavailable for the same reason.
- `core/.cargo/config.toml` makes cargo fetch git dependencies with the git CLI, so
  a global `https://github.com/` → SSH rewrite works.
