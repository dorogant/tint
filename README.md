# Floe

A lightweight native Spotify client for macOS (Apple Silicon): SwiftUI on top of
[librespot](https://github.com/librespot-org/librespot) in Rust. It replaces the
Chromium-based official app for everyday listening, with a target of **≤150 MB RAM**
during playback and ~0% CPU when idle. See [PLAN.md](PLAN.md) for the full plan.

**Status:** Phase 4 (visualizers and live background) implemented. Library,
navigation, playback, macOS media controls, cover-driven Now Playing and LRCLIB
synced lyrics work. The waveform toolbar button opens **Visuals**: circular or
normal visualizers, bars or wave, sensitivity, and an optional reactive Metal
background. Preferences persist between launches. Phase 5 (settings and polish)
is next.

Measured on this MacBook Air on 2026-10-08, release build, restored large window
(1710×1052 points), without screenshots: stable circular visualization used
~149–152 MiB RSS and ~195 MiB physical footprint; the optional live background
in Library used ~154 MiB RSS and ~187 MiB footprint. CPU samples were roughly
11–21% of one core during visualization and 13–15% with the background. Paused
CPU settled to 0%; RSS fell to ~125 MiB after a minute. These are short samples,
not a guaranteed ceiling: the ≤150 MiB RSS target still needs tuning, and physical
footprint includes compressed memory. The live background defaults off.

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

### Now Playing and lyrics

Use the top-right **Now Playing** or **Lyrics** button. Timed lyrics follow playback;
click a line to seek to it. Scrolling manually stops automatic following until you
click **Follow lyrics**. Untimed lyrics, instrumental songs, missing lyrics and
request failures have separate states.

LRCLIB matches the track title, first artist, album and duration in seconds, with a
±2-second duration tolerance. Floe preserves version names to avoid syncing a live,
remixed or slowed recording to another version. Lyrics have a bounded, expiring
memory cache and never go to disk, logs or snapshots. The newer `hasWordSync` and
`lyricsfile` fields are ignored; this phase uses line timing from `syncedLyrics`.
Requests are serialized, spaced, and respect `Retry-After`. See [LRCLIB docs](https://lrclib.net/docs).

Run the synthetic parser, response, caching, rate-limit and cover-color tests:

```sh
scripts/test-phase3.sh
```

The live Phase 3 self-test plays a Daft Punk track, waits for its cover and synced
lyrics, checks seeking, plays for 20 seconds and pauses. It reports counts and
memory only, never lyric text:

```sh
build/Floe.app/Contents/MacOS/Floe -FloeSelfTest YES -FloeSelfTestPhase3 YES
```

For visual QA, add `-FloeVisualTest YES -FloeSnapshotDir /tmp/floe-shots` after creating
the output directory. Only synthetic lyrics are captured. Snapshot capture refuses
real-lyrics views even when triggered manually. These tests need only Command Line
Tools; XCTest is unavailable in the CLT-only installation.

### Visualizers and live background

Open **Visuals** using the waveform icon in the top toolbar. The default is a
circular bar visualizer around the cover; **Normal** places it across the bottom.
Both styles support **Bars** and **Wave**. Sensitivity changes only the visual
response. The optional **Live background** adds slow, audio-reactive color clouds
behind the cover backdrop; **Reactivity** controls their response.

Analysis runs at about 30 Hz only while an effect is visible and Floe is active.
The Metal background draws at 15 Hz into a small surface stretched behind the
glass. Both clocks stop on pause, when effects are disabled, or with app/system
Reduce Motion. Hidden visualizers stop analysis unless the live background needs
it. Self-tests temporarily bypass the foreground requirement.

```sh
scripts/test-phase4.sh
build/Floe.app/Contents/MacOS/Floe -FloeSelfTest YES -FloeSelfTestPhase4 YES
```

The offline checks cover the bounded stereo tap, FFT frequency response, silence,
antiphase/right-only stereo, rolling windows, reset/decay and Metal compilation.
The live check measures real PCM, cadence and audio underruns, exercises every
style/shape, and verifies pause, hiding, disabled effects and Reduce Motion. Add
`-FloeVisualTest YES -FloeSnapshotDir /tmp/floe-shots` for synthetic-only visual QA.
The live test restores visual preferences afterward and leaves playback paused.

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
  Images/             artwork cache, cover palette and pre-blurred backdrop
  Lyrics/             LRCLIB service, memory cache, LRC parser and view state
  Visualization/      vDSP FFT, bounded PCM sampling, visual preferences, Metal shader
  Views/              UI
Support/Info.plist    bundle metadata
scripts/              build-app.sh, make-icon.swift
```

## How it works

- **Audio path.** librespot decodes on its own thread into a custom `Sink`, which writes
  interleaved f32 PCM into a lock-free ring buffer. An `AVAudioSourceNode` pulls from it
  on the render thread (`floe_render`). Pause closes a gate so audio stops immediately
  rather than after the buffer drains; seek and load flush the buffer. Volume lives
  in Swift. A separate 32 KiB stereo tap copies rendered samples before mixer volume
  without allocating or waiting on the render thread. A utility queue reads the
  newest samples into a rolling 2048-frame Hann window, computes stereo FFT power
  using vDSP, and publishes 48 log-spaced bands, 96 waveform points and RMS. A full
  analysis ring drops visual samples without disrupting playback. Seek, track,
  pause and enable changes reset the analysis generation; PCM never goes to disk.
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
