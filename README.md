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
A design pass adds a standard macOS toolbar and Settings window, Liquid Glass
controls, smooth transitions, redesigned lyrics and reference-style visualizers
(see [Design and motion](#design-and-motion)).

Limitations: the pinned engine has no crossfade support, so Settings labels it
unavailable. Offline downloads remain unavailable. Queue/device requests need
additional Spotify consent. Live queue and device-list requests pass with that
permission; response decoding, access gating and transfer requests also pass
offline tests. Device transfer has not been exercised against another live device.

Measured on this MacBook Air on 2026-10-08 with the release build, playing music
in a visible window. Each figure is Floe's own CPU over 10–30 s, from the
`-FloeSelfTestPerf` mode described under [Design and motion](#design-and-motion):

| Scenario | CPU before → after | Footprint |
|---|---|---|
| Library, effects off | 2.2% → 2.4% | ~90–110 MiB |
| Now Playing, effects off | 16–20% → 2.4–2.6% | ~95–115 MiB |
| Now Playing, circular bars | ~18% → 4.5% (one run) | ~100–110 MiB |
| Library, live background | 14–16.5% → 7.2% | ~155–165 MiB |
| Now Playing, bars and live background | 22–25% → 13.5% | ~160–175 MiB |
| Lyrics view | ~2.2% | ~105–110 MiB |
| Paused, effects on | 0–0.7% | ~95–110 MiB |

Most of the saving comes from moving continuous motion out of SwiftUI. Each SwiftUI
update re-lays out the whole window (~1.5 ms on the main thread), so animating the
cover and progress wave through SwiftUI cost ~15% of a core. The crawling cover rim,
the progress wave and the visualizer now run on Core Animation layers, and the live
background reads analysis frames itself. Lyric line changes still animate through
SwiftUI with a short spring; in a dense section they add a few percent while they run.
The live background defaults off.

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
scripts/build-app.sh --install # install/update Applications + Desktop icon
```

The script runs `cargo build --release` for the Rust core, `swift build` for the app,
assembles the bundle (Info.plist, generated native icon) and signs it (see below).

### Desktop launch icon

Double-click **Floe** on the Desktop to open the app without a terminal. The icon
points to `~/Applications/Floe.app`, a signed copy of the native macOS app bundle.
Rebuild with `scripts/build-app.sh --install` to update that copy while keeping the
same Desktop icon. To install an already-built app, run `scripts/install-app.sh`.
The installer verifies its signature before replacing an existing Floe bundle and
does not overwrite unrelated items with the same name.

If macOS asks to access your saved Spotify login, unlock your login Keychain and
choose **Always Allow** for Floe. This system dialog requires your own password;
the installer does not read or change credentials.

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
Window capture can't draw Liquid Glass, so snapshot runs draw glass controls as flat
tints and composite the toolbar on top; check the real window for the glass itself.

### Now Playing and lyrics

Use **Now Playing** or **Lyrics** in the toolbar's centre switcher. Timed lyrics follow playback;
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
response. The optional **Live background** turns the backdrop into a light show:
twelve beams rise from the bottom edge, bass in the middle. Each reaches higher and
glows brighter with its part of the spectrum as the beams sway, a bass bloom pulses
from below, and colour clouds drift behind. **Reactivity** scales the response.

Analysis runs at about 30 Hz only while an effect is visible and Floe is active.
The Metal background draws at 30 Hz into a small surface stretched behind the
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

### Design and motion

Floe follows macOS conventions where they fit. The window has a standard unified
toolbar beside the window controls: Back, a Library / Now Playing / Lyrics switcher,
and one group of Visuals, Queue, Devices, Appearance and Settings buttons, all in
the system's Liquid Glass. Settings is a standard tabbed window with grouped forms.
The Play buttons and the search field use interactive glass, and SF Symbols morph
or bounce for play/pause, like, repeat, transport presses and the volume level.
Large panels stay tinted rather than live-blurred, which keeps GPU and memory use down.

Motion is short and event-driven, and app or system Reduce Motion turns it off.
Going from Library to Now Playing, the cover flies out of the mini player into place
(and back again). Library recedes and softens while Now Playing and Lyrics rise
over it, and the visualizer ring fades in once the cover lands. Clicking the mini
player's cover also opens Now Playing. On a new song the title and mini-player
details roll up into place and the cover dips and springs back. Shelves ease cards
in at their edges as they scroll, artwork lifts on hover, and the playing indicators
in the sidebar and track lists animate. Volume and the mini player's progress are
soft capsules that thicken under the pointer.

The quote button at the top right of Now Playing (**⇧⌘L**) hides the lyrics; the
cover and visualizer slide to the centre and grow.

On Now Playing the cover sits in a 22-petal scalloped mask with a tinted rim. The
cover stays upright; only the scalloped edge crawls around it and slowly breathes,
and both stop on pause. The circular visualizer scales with
the cover. **Bars** are mirrored radial bars with bass at the top; **Wave** is a
filled halo whose lobes follow the spectrum. Along the bottom, **Bars** are mirrored
around the middle (bass at the centre). **Wave** is a twisted ribbon of round beads
that drifts sideways; each bead swells with the part of the spectrum it passes.
Colors run from pale at the top to the cover accent at the bottom, and all motion
freezes with the analysis on pause.

The visualizers and the live background draw adaptive levels rather than raw
loudness. Each band is measured against its own last couple of seconds, so kicks,
snares and hi-hats each flare their own part of the ring. A band that's simply
always loud, like the bass in most songs, settles mid-way instead of pinning the
top, so each song gets its own shape. The bead ribbon drifts faster when the music
is louder.

In synced lyrics the current line sits on a frosted pill that glides to the next
line and glows softly, tinted toward the cover. Upcoming lines settle one after
another with a short easing curve; lines further away dim, shrink and soften. The line
clock wakes only when the next line is due, about 150 ms early so the motion lands
with the vocal. Neighbouring lines glide, while opening the view or a long seek
jumps straight there. Hover highlights a line, and clicking it seeks. After a manual
scroll, a glass **Follow lyrics** button resumes following.

`-FloeSelfTest YES -FloeSelfTestDesign YES` plays a liked song and runs the
real-audio effect checks; add `-FloeVisualTest YES -FloeSnapshotDir <dir>` for
synthetic-only snapshots of every visualizer style and the lyrics view.
`-FloeSelfTest YES -FloeSelfTestPerf YES` holds each visual scenario for 10 s and
logs CPU, analysis and background frame rates, and footprint. It also checks that
the cover rim and progress wave move while playing and stop on pause, and compares
raw and adaptive equalizer shapes on two of your liked songs.
`-FloeSelfTestPerfOnly <name>` holds matching scenarios instead, for 30 s when only
one matches (useful with `sample`). It restores every preference afterwards.

Window snapshots can't show Core Animation masks or motion, so `scripts/test-layers.sh`
renders the real cover, visualizer and progress-wave layers offscreen with
`CARenderer`, inside a top-down parent as SwiftUI hosts them. It checks pixels: the
cover is upright and shows a new image even while paused, bass sits at the top of the
ring, bottom bars stand on the floor, the halo is pale on top, and the wave fills only
the elapsed part. Additional checks cover height-only progress resizing and the
bead ribbon's overlap. Its dim rear ribbon is now clipped by Core Animation rather
than a polygon subtraction on every frame. Synthetic path-generation time fell
from 0.411–0.433 ms to 0.051 ms/frame (~88%); this excludes compositor/GPU work and
is not a new whole-app CPU measurement.

`scripts/test-background.sh` exercises the production Metal renderer with synthetic
colors and spectrum data, including GPU pixel readback. Paused cover/accent changes
and window resizing redraw one static frame; unchanged settings stay idle. Changes
that arrive during GPU work coalesce into the latest replacement frame.

`scripts/benchmark-lyrics.sh` opens a separate native window with synthetic timed
lines, measures CPU during steady/changing/paused lyrics, checks line-clock wakeups,
then closes it. It needs neither Spotify nor Keychain access. An optional first
argument selects another `LyricsView.swift` to benchmark against the same fixture.
The production lyric clock now sleeps until the next line, and stops waking after
the final line or during pauses. Progress motion also stops while Floe is inactive
and with Reduce Motion. Now Playing bounds the cover and visualizer by the available
column width so they fit in tall, narrow windows.

The lyric blur/glow treatment is retained: removing it alone did not reduce CPU in
the isolated test. Bounded 0.35 s scrolling and 0.3 s row transitions settle before
the next dense line change. With synthetic changes every 1.25 s, the final view
measured 31.7–33.1% CPU; the old view measured 35.6% after warmup and 66.6% in a
changing-only run. Warmup variance is substantial, and these figures describe the
isolated lyric window, not whole-app playback. Final steady/paused samples were
0.02%, with no clock reads. Changing lines required 16 reads over 20 s, versus 32
before the clock change.

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
