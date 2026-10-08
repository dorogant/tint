# Floe

A lightweight native Spotify client for macOS (Apple Silicon): SwiftUI on top of
[librespot](https://github.com/librespot-org/librespot) in Rust. It replaces the
Chromium-based official app for everyday listening, with a target of **≤150 MB RAM**
during playback and ~0% CPU when idle. See [PLAN.md](PLAN.md) for the full plan.

**Status:** Phase 5 settings and polish implemented. The gear button or **⌘,**
opens a native settings window with Visualizer, Background, Playback, Downloads,
Appearance and About. English and Ukrainian interface text is bundled; choose a
language in Appearance. Queue and Devices have dedicated toolbar panels and an
opt-in Spotify permission flow. Playback quality, normalization and gapless
settings now reach librespot, and reconnecting preserves the song, position and
pause state. Floe has a new native flower-and-rhythm icon (version 0.2.0).

Limitations: the pinned engine has no crossfade support, so Settings labels it
unavailable. Offline downloads remain unavailable. Queue/device requests need
additional Spotify consent. Live queue and device-list requests pass with that
permission; response decoding, access gating and transfer requests also pass
offline tests. Device transfer has not been exercised against another live device.

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
assembles the bundle (Info.plist, generated native icon) and signs it (see below).

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

### Settings and recovery

The native Settings window shares the same visual preferences as the toolbar
popover. Background blur is computed from a tiny cover thumbnail, with slider
changes coalesced; glass intensity and four fixed accent colors apply immediately.
English/Ukrainian switching changes interface text, including count plurals;
catalogue metadata and lyrics retain their original language.

Streaming quality (96/160/320 kbps), normalization and gapless playback take effect
on the next playback session. **Apply and reconnect** preserves the current song,
position and whether it was paused, and reloads Floe's context. Manually queued
songs may be reset. Session loss stops the UI clock and retries with backoff;
**Reconnect now** and **Sign in again** provide recovery. Unavailable tracks show a
human-readable, dismissible error with **Next song**. Expired/revoked library tokens
lead back to library authorization; stale refreshes cannot reinstall signed-out
credentials.

Queue/Devices fetch only when opened, on track changes in Queue, or on **Refresh**.
Queue shows songs (episode/local entries without usable song metadata are skipped),
retaining duplicate entries. Restricted devices cannot receive transfers. Transfers
preserve the current play/pause state. The volume control applies to Floe; use macOS
Control Center to choose the Mac's audio output.

Use **Connect Queue and Devices** once to grant `user-read-playback-state`,
`user-read-currently-playing` and `user-modify-playback-state` with the existing
PKCE client. Restoring an existing library session never opens a new consent flow.
These are the documented scopes for [queue access](https://developer.spotify.com/documentation/web-api/reference/get-queue),
[devices](https://developer.spotify.com/documentation/web-api/reference/get-a-users-available-devices)
and [transfer](https://developer.spotify.com/documentation/web-api/reference/transfer-a-users-playback).

```sh
scripts/test-phase5.sh
scripts/test-artwork.sh
build/Floe.app/Contents/MacOS/Floe -FloeSelfTest YES -FloeSelfTestPhase5 YES
```

Offline checks use synthetic tokens, devices and metadata: configuration and paused
reload, 401 refresh/repeated rejection, Retry-After, transfer JSON, mixed queue
entries, access gating, restricted devices, cancellation/stale responses and
Ukrainian plural forms. The live check exercises a connection-loss event, applies
160 kbps with normalization, restores the original playback preferences and
verifies resume/position/pause and real audio flow. It leaves playback paused.
On this Mac, its paused sample was ~133 MiB physical footprint; CPU settled to 0%.
The queue/device live checks run only after permission is granted.

Song selection updates the title, row highlight and loading indicator from the
clicked row immediately. Cover/lyrics loading starts at selection time; the full
cover can appear before its blurred backdrop is ready. The playback clock stays
stopped until the engine confirms playback. The core prepares a known selected
track while Spirc resolves its context, silences old audio on manual switches,
and preserves buffered audio for automatic gapless transitions.

```sh
build/Floe.app/Contents/MacOS/Floe -FloeSelfTest YES -FloeSelfTestSwitching YES
```

This opt-in live check plays four liked songs, checks rapid selections and monitors
30 seconds of audio flow and underruns, leaving playback paused. On 2026-10-08,
the pre-tuning baseline started the first song in 1,106 ms and subsequent songs in
740/739/839 ms. After tuning, these measured 1,391 ms and 628/622/520 ms respectively
(100 ms polling resolution, four samples per run). Later switches averaged 24% less
time; the first song was slower, so these network-dependent samples are not a
latency guarantee. Selection state updated in 0.1–10 ms in the tuned run. Rapid
selection and the 30-second audio checks passed with no new underruns, including
additional manual song changes during the monitoring period. Steady playback RSS
was ~115 MiB before those extra interactions; footprint after browsing/switching
was ~221 MiB. Earlier rapid stress tests logged temporary Connect state-update 429s.

The pinned librespot player waits for its **during-playback** read-ahead window
before starting audio. Floe reduces this window from five seconds to one, which
fits inside the initial 64 KiB compressed-data request at 320 kbps. Adaptive
prefetch, decoder block size and network timeouts retain upstream defaults. This
also reduces the explicit read-ahead during playback; congested networks have not
been benchmarked. For a diagnostic comparison with upstream buffering, launch with
`FLOE_AUDIO_READ_AHEAD_MS=5000` (valid range 1000–5000; normal launches use 1000).

Artwork sizes now share one in-flight HTTP download per URL; decoded variants
remain in the existing bounded cache, and raw bytes are not kept after processing.
Control Center retains a pending artwork task across metadata updates. Synthetic
tests verify concurrent sizes, memory hits, failed-request recovery and cancelled
callers. Ten Rust tests cover configuration, analysis and switch/gapless buffering;
offline API checks and all 12 synthetic lyric regressions pass.

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
  Settings/           persisted playback/appearance preferences and native settings window
  Views/              UI
Support/Localizations/ English/Ukrainian interface strings and plural rules
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
