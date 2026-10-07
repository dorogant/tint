# Floe

A lightweight native Spotify client for macOS (Apple Silicon): SwiftUI on top of
[librespot](https://github.com/librespot-org/librespot) in Rust. It replaces the
Chromium-based official app for everyday listening, with a target of **≤150 MB RAM**
during playback and ~0% CPU when idle. See [PLAN.md](PLAN.md) for the full plan.

**Status:** Phase 2 (library & navigation) done. Measured on a MacBook Air (2026-10-08),
release build: ~60 MB physical footprint on Home, ~82 MB while playing, and a stable
~105 MB after visiting every page (no growth over repeated visits); 0.0% CPU when paused.
RSS is ~145 MB, of which ~40 MB is shared system frameworks. The official app uses ~450 MB.

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
assembles the bundle (Info.plist, generated placeholder icon) and signs it (see below).

On first launch Floe asks for two approvals in the browser: **playback** (librespot,
Spotify's own client ID) and **library** (the Web API, through your own developer app).

### Signing

Floe keeps its Spotify credentials in the Keychain, which only lets the app that
created an item read it back. An ad-hoc signature changes on every build, so each
rebuild would prompt for your password. To avoid that, create a local code-signing
certificate once; the build script uses it automatically (or set `FLOE_SIGN_IDENTITY`):

1. Open **Keychain Access** (Spotlight, or `/System/Library/CoreServices/Applications/`).
2. Menu **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name `Floe Local Signing`, Identity Type **Self-Signed Root**, Certificate Type
   **Code Signing** → **Create**. It is stored in your login keychain.

The first build after that asks whether `codesign` may use the key (choose **Always
Allow**). The first launch then asks once for the existing Floe item; choose **Always
Allow** again. Without the certificate the script falls back to ad-hoc signing.

If the certificate has another name (Keychain Access pre-fills your full name), put
its name or SHA-1 (from `security find-identity -p codesigning`) in a git-ignored
`.signing-identity` file at the repo root.

### Self-test

Plays music, so don't touch playback while it runs. It checks the library API, search,
Liked Songs context playback, next/previous, audio flow and Now Playing, and logs to stdout:

```sh
build/Floe.app/Contents/MacOS/Floe -FloeSelfTest YES
```

Options: `-FloeSelfTestWrites YES` likes and then unlikes one song (no net change);
`-FloeSelfTestTour YES` visits every page (`-FloeSelfTestTourRounds N` repeats it, to
watch memory); `-FloeSnapshotDir <dir>` saves PNGs of each page (and on
`notifyutil -p com.antonchurchyn.floe.snapshot`), since Screen Recording isn't needed for that.

## Layout

```
core/                 Rust staticlib: librespot session + Spirc + player, C ABI (src/lib.rs)
Sources/CFloeCore/    C header + modulemap for the Rust library
Sources/Floe/         SwiftUI app
  App/                app entry, self-test, snapshot hook
  Core/               Swift wrapper over the C ABI, event decoding
  Playback/           PlayerModel, AVAudioEngine output, Now Playing + media keys
  API/                Web API client and models
  Auth/               OAuth PKCE (loopback redirect), token provider, Keychain
  Library/            library state (playlists, pins, liked songs), navigation
  Images/             artwork cache (downsampled, disk-backed)
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
- **Playing context.** Floe runs librespot's Spirc, so it is a Spotify Connect device
  ("Floe"): playlists, albums, artists and Liked Songs play as *contexts*, and Spotify's
  own logic handles queue, shuffle, repeat and autoplay, exactly as in the official apps.
  It can be controlled from the phone, and Play takes over from another device. Chosen
  over an own queue in Swift, which would re-implement all of that and still not be a
  Connect device.
- **Bridge.** A plain C ABI (`Sources/CFloeCore/floe_core.h`) of about twenty functions.
  Results come back as JSON events through one callback. UniFFI would add a code
  generator for no real gain at this size.
- **Login.** librespot's session must be authorised with *Spotify's own* client ID
  (`streaming` scope): Spotify rejects third-party client IDs there. Floe runs the PKCE
  flow in the browser with a one-shot listener on `127.0.0.1:5588/login`, gets
  reusable credentials back from librespot, and stores only those in the Keychain.
  The Web API uses Floe's own client ID with PKCE on `127.0.0.1:8898/callback`; its
  refresh token is in the Keychain too. No client secret is used or stored anywhere.
- **Web API limits (Development Mode, 2026).** Floe uses only endpoints still open to
  Development Mode apps. Consequences: playlists you don't own show their header and
  Play but no track list; Spotify-made playlists 404 (Play still works); no artist top
  tracks; search and artist albums return at most 10 per request; `market=from_token`
  needs a scope Floe doesn't request (and isn't needed with a user token).
  PLAN.md's fallback of Web API tokens from the librespot session no longer works
  (tested 2026-10-08): keymaster answers 403, and api.spotify.com throttles login5
  tokens (429, `Retry-After` up to 86400 s). Floe doesn't send them.
- **librespot version.** Pinned to a commit on `dev` (see `core/Cargo.toml`): the 0.8.0
  release doesn't build from crates.io (librespot-org/librespot#1760). Bump it on purpose.

### Command Line Tools quirks

- In the current SDK, `@State` is a macro whose compiler plugin ships only with Xcode.
  Use `@ViewState` instead (an alias for the same property wrapper, in
  `Sources/Floe/Support/ViewState.swift`). `#Preview`, `@Entry` and `@Animatable`
  are unavailable for the same reason.
- `core/.cargo/config.toml` makes cargo fetch git dependencies with the git CLI, so
  a global `https://github.com/` → SSH rewrite works.
