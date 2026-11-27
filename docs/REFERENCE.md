# Tint reference

How Tint is built, what was measured and how each part is tested. The short
introduction is the [README](../README.md); [PLAN.md](../PLAN.md) is the original plan.

Internal names keep the project's earlier name, Floe: the Swift module, the Rust
`floe_core` crate, the `FLOE_…` build variables and the `-Floe…` development flags.

**Status:** Phase 5 settings and polish implemented. The gear button or **⌘,**
opens a native settings window with Visualizer, Background, Playback, Downloads,
Appearance, Account and About. English and Ukrainian interface text is bundled; choose a
language in Appearance. Queue and Devices have dedicated toolbar panels and an
opt-in Spotify permission flow. Playback quality, normalization and gapless
settings now reach librespot, and reconnecting preserves the song, position and
pause state. Tint's icon is its scalloped cover shape holding bands of indigo sound,
on a pale body.
A design pass adds a standard macOS toolbar and Settings window, Liquid Glass
controls, smooth transitions, redesigned lyrics and reference-style visualizers
(see [Design and motion](#design-and-motion)).

Limitations: the pinned engine has no crossfade support, so Settings labels it
unavailable. Offline downloads remain unavailable. Queue/device requests need
additional Spotify consent. Live queue and device-list requests pass with that
permission; response decoding, access gating and transfer requests also pass
offline tests. Device transfer has not been exercised against another live device.

Measured on a MacBook Air (M3) on 2026-10-08 with the release build, playing music
in a visible window. Each figure is Tint's own CPU over 10–30 s, from the
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
the progress playhead's glide and the visualizer now run on Core Animation layers, and the live
background reads analysis frames itself. Lyric line changes still animate through
SwiftUI with a short spring; in a dense section they add a few percent while they run.
The live background defaults off.

## Requirements

- A Mac with Apple Silicon and macOS 26 or later. Intel Macs aren't supported.
- Xcode **Command Line Tools** with Swift 6.2+ and the macOS 26 SDK. Full Xcode is not
  needed. Install them with `xcode-select --install`; Software Update keeps them current.
- Rust via [rustup](https://rustup.rs). The first build installs the Rust release pinned
  in `core/rust-toolchain.toml` by itself.
- **Spotify Premium**, and a free Spotify developer app for your library (see below).

`scripts/build-app.sh` checks the tools first and says what's missing.

## Build and run

```sh
scripts/build-app.sh            # -> build/Tint.app (release)
scripts/build-app.sh --open     # build, then launch
scripts/build-app.sh --install  # also copy it to ~/Applications/Tint.app
scripts/build-app.sh --zip      # also pack build/Tint-<version>.zip to share
```

The script runs `cargo build --release` for the Rust core, `swift build` for the app,
assembles the bundle (Info.plist, generated native icon) and signs it (see
[Signing](#signing)). The first build fetches librespot and takes a few minutes.
`scripts/build-app.sh --help` lists the options and settings.

Universal builds aren't supported: `swift build` needs full Xcode for more than one
`--arch`, and the Rust core would need a second target and `lipo`.

### Spotify developer app

Tint reads your library (playlists, saved music, history) through the Spotify Web API,
which needs a developer app. Spotify only lets the app's owner and the accounts they
add sign in to it, so everyone uses their own. It's free and takes a minute:

1. Open [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) and
   choose **Create app**. Any name and description will do.
2. Under **Redirect URIs**, add exactly `http://127.0.0.1:8898/callback`.
3. Tick **Web API**, accept the terms and save.
4. Copy the **Client ID** from the app's Basic Information. Tint never needs the
   Client secret.

Paste the Client ID into Tint on first launch, in step 2. To change it later, open
Settings → Account; that disconnects the library until you connect it again.

To build your Client ID into the app instead, put it in a git-ignored
`.spotify-client-id` file at the repo root (or set `FLOE_SPOTIFY_CLIENT_ID`). Onboarding
then folds the field away. A Client ID is public, not a secret. The one Tint uses is
the one pasted in the app, then the built-in one.

### First launch

Tint asks for two approvals in the browser: **Playback** (librespot, with Spotify's own
client ID, nothing to set up) and **Library** (the Web API, through your developer app).
If the browser shows `INVALID_CLIENT`, the Client ID or the redirect URI doesn't match
the dashboard. Press **Cancel** in Tint, fix it and connect again.

Tint keeps both logins in private files (see *Credentials* under How it works), not
the Keychain, so rebuilds and changing signatures never ask for your password. Builds
before that used the Keychain: the first launch after updating may ask once for each
of the two saved logins while Tint moves them out. Choose **Allow**; it doesn't ask
again.

### Install

`scripts/build-app.sh --install` copies the app to `~/Applications/Tint.app`;
`scripts/install-app.sh` does the same for an already-built app. The installer verifies
the signature before replacing an existing Tint bundle and does not overwrite unrelated
items with the same name. `scripts/install-app.sh --desktop-icon` also puts a Tint icon
on the Desktop that keeps pointing at the installed app after updates. The installer
does not read or change credentials.

### Signing

Without a certificate the script signs ad-hoc, which is fine on your own Mac. An ad-hoc
signature changes on every build; Tint's logins don't depend on it.

A local certificate keeps the same code identity across builds, and lets Tint delete
the Keychain items of builds from before the files without asking. Create it once:

1. Open **Keychain Access** (Spotlight, or `/System/Library/CoreServices/Applications/`).
2. Menu **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Any name, Identity Type **Self-Signed Root**, Certificate Type **Code Signing** →
   **Create**. It is stored in your login keychain.
4. Put its name or SHA-1 (from `security find-identity -p codesigning`) in a git-ignored
   `.signing-identity` file at the repo root, or set `FLOE_SIGN_IDENTITY`.

The first build after that asks whether `codesign` may use the key (choose **Always
Allow**). If the certificate isn't in the keychain, the script says so and signs ad-hoc.

With a paid Apple Developer account, the build can be signed with Developer ID and
notarized, so it opens on other Macs without a warning. Both steps are skipped unless
their variables are set:

```sh
xcrun notarytool store-credentials tint-notary --apple-id you@example.com --team-id TEAMID
FLOE_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
FLOE_NOTARY_PROFILE=tint-notary scripts/build-app.sh --zip
```

That signs with the hardened runtime, sends the zip to Apple, staples the ticket to
the app and packs the zip again.

### Sharing a build

`scripts/build-app.sh --zip` packs `build/Tint-<version>.zip` (`scripts/package-app.sh`
does it for an already-built app). Send that file. The other person needs an Apple
Silicon Mac with macOS 26 and Spotify Premium.

For anyone you don't know personally, share a build **without** a Client ID built in
(no `.spotify-client-id` file and no `FLOE_SPOTIFY_CLIENT_ID`). They paste their own in
onboarding; the setup screen walks them through creating one. Spotify's Developer Terms
don't allow handing out your Client ID, so never publish a build that contains yours.

A build with your Client ID is only for people you add to your developer app: put their
Spotify account's email in the dashboard under **User Management**. Development Mode
allows at most 5 users per app. They can still choose **Use your own Spotify developer
app** in onboarding instead.

A build that isn't notarized is blocked the first time it opens. To open it anyway:

1. Unzip it, move **Tint** to Applications and double-click it. macOS says it can't
   verify the app; choose **Done**.
2. Open **System Settings → Privacy & Security**, scroll to **Security** and click
   **Open Anyway** next to the message about Tint. Confirm with your password.

That's needed once per copy. Control-click → Open no longer skips the check on macOS 15
and later. As a last resort, `xattr -dr com.apple.quarantine /Applications/Tint.app` in
Terminal removes the download mark.

### Build settings

All optional. Each is an environment variable; the first two can also live in a
git-ignored one-line file at the repo root.

| Variable | File | What it does |
|---|---|---|
| `FLOE_SPOTIFY_CLIENT_ID` | `.spotify-client-id` | Client ID built into the app; without one, Tint asks |
| `FLOE_SIGN_IDENTITY` | `.signing-identity` | local signing certificate (name or SHA-1); else ad-hoc |
| `FLOE_DEVELOPER_ID` | | Developer ID identity; signs with the hardened runtime |
| `FLOE_NOTARY_PROFILE` | | `notarytool` keychain profile; notarizes with `--zip` |
| `FLOE_BUNDLE_ID` | | bundle ID, default `com.antonchurchyn.floe` |

The default bundle ID is the original one, so existing settings carry over. With
another bundle ID Tint starts with fresh settings; saved logins in
`~/Library/Application Support/Floe` are shared.

`.github/workflows/build.yml` builds the app on GitHub Actions (ad-hoc signed) and runs
the offline tests: no Spotify account, network login or audio device involved.

### Self-test

Plays music, so don't touch playback while it runs. It checks the library API, search,
Liked Songs context playback, next/previous, audio flow and Now Playing, and logs to stdout:

```sh
build/Tint.app/Contents/MacOS/Tint -FloeSelfTest YES
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
±2-second duration tolerance. Tint preserves version names to avoid syncing a live,
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
build/Tint.app/Contents/MacOS/Tint -FloeSelfTest YES -FloeSelfTestPhase3 YES
```

For visual QA, add `-FloeVisualTest YES -FloeSnapshotDir /tmp/floe-shots` after creating
the output directory. Only synthetic lyrics are captured. Snapshot capture refuses
real-lyrics views even when triggered manually. These tests need only Command Line
Tools; XCTest is unavailable in the CLT-only installation.

### Visualizers and live background

Open **Visuals** using the waveform icon in the top toolbar. The default is a
circular bar visualizer around the cover; **Normal** places it across the bottom.
Both styles support **Bars** and **Wave**. Sensitivity changes only the visual
response. The optional **Live background** turns the backdrop into a light show
that plays along in layers. **Beams**: bass lights, widens and punches the outer
beams on each kick; hi-hats light the middle beams and glint in the haze; snares
flick the middle pairs across; sustained vocals tint the smoke. Beams move on
damped springs, turn on the beat, change look every eight bars or on a drop, and
come to rest in silence. **Fluid** swirls the cover's colours and breathes with the
bass. **Bass punch** scales the kick response; black-and-white covers draw clean
white light. Colours always come from the cover.

Analysis runs at about 30 Hz only while an effect is visible and Tint is active;
it splits the spectrum into bass, low-mids, mids and highs and detects kicks,
snares, hats and the tempo. The Metal background draws at about one pixel per point
on the display's refresh (Beams 60 Hz, Fluid 30 Hz), with the haze at quarter
resolution, on a thread of its own so the interface can't hold up its frames. Both clocks stop on pause, when effects are disabled, or with app/system
Reduce Motion. Hidden visualizers stop analysis unless the live background needs
it. Self-tests temporarily bypass the foreground requirement.

```sh
scripts/test-phase4.sh
build/Tint.app/Contents/MacOS/Tint -FloeSelfTest YES -FloeSelfTestPhase4 YES
```

The offline checks cover the bounded stereo tap, FFT frequency response, silence,
antiphase/right-only stereo, rolling windows, reset/decay and Metal compilation.
The live check measures real PCM, cadence and audio underruns, exercises every
style/shape, and verifies pause, hiding, disabled effects and Reduce Motion. Add
`-FloeVisualTest YES -FloeSnapshotDir /tmp/floe-shots` for synthetic-only visual QA.
The live test restores visual preferences afterward and leaves playback paused.

### Design and motion

Tint follows macOS conventions where they fit. The window has a standard unified
toolbar beside the window controls: Back, a Library / Now Playing / Lyrics switcher,
and one group of Visuals, Queue, Devices, Appearance and Settings buttons, all in
the system's Liquid Glass. Settings is a standard tabbed window with grouped forms.
The Play buttons use interactive glass, search lives in the toolbar
(⌘F), and SF Symbols morph
or bounce for play/pause, like, repeat, transport presses and the volume level.
Shuffle has a half-second crossover twist, elastic squeeze and fading accent
ripple on each press. It dispatches playback immediately, adds no idle animation,
and falls back to a quiet state change with app or system Reduce Motion enabled.
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

Going back (the toolbar's Back or **⌘[**) and searching from the keyboard show the
page at once: no crossfade, and its sections don't make their entrance again. A
track row lights up once the pointer has stayed on it for 30 ms, so dragging the
pointer down a playlist costs nothing: before, each row crossed took about 4 ms of
main thread to light and its fade redrew the row's gradient wash and text on the
CPU every frame (15 ms a frame in `scripts/benchmark-scroll.sh`'s `sweep` run, with
the live background, which then drew on the main thread, dropping frames). Rows now
fade through opacity and transforms only, and the live background draws on a thread
of its own: with the main thread blocked for half a second it still shows all 30 of
its frames (none before). At launch the window fades in; on first
run the sign-in card stays up through both steps.

The quote button at the top right of Now Playing (**⇧⌘L**) hides the lyrics; the
cover and visualizer slide to the centre and grow.

The screen button beside it (**⇧⌘H**) puts the controls away: the toolbar, the
progress bar, transport, volume and the panel's tint go, the cover grows, and the
cover, the song's name, the lyrics and the background are all that's left. Moving
the pointer shows a **Show controls** button and the window's buttons for 2.5 s;
once it rests they go again, and the pointer with them. Escape, ⇧⌘H or any other
surface brings the controls back. The star beside the song's name saves it to
Liked Songs.

On Now Playing the cover sits in a 22-petal scalloped mask with a tinted rim. The
cover stays upright; only the scalloped edge crawls around it and slowly breathes,
and both stop on pause. Visuals ▸ Cover swaps the flower for a **Card**: a rounded
square standing in perspective over its reflection, swaying 19° to each side every
11 seconds. Core Animation runs both, and **Cover motion** turns either off (the
card then holds a 12° turn). Nothing can ring the card, so its visualizer is always
the strip along the bottom. The circular visualizer scales with
the cover. **Rays**, the default, are 168 hairlines that brighten as they grow, so a
quiet passage leaves a faint rim; **Bars** are mirrored radial bars with bass at the
top; **Wave** is a filled halo whose lobes follow the spectrum. Along the bottom,
**Rays** grow both ways from the middle line and **Bars** stand on the floor, both
mirrored around the middle (bass at the centre). **Wave** is a twisted ribbon of round beads
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
with the vocal. The first line after an intro fades and glides into focus, just
like neighbouring lines, while opening the view or a long seek
jumps straight there. Hover highlights a line, and clicking it seeks. After a manual
scroll, a glass **Follow lyrics** button resumes following.

`-FloeSelfTest YES -FloeSelfTestDesign YES` plays a liked song and runs the
real-audio effect checks; add `-FloeVisualTest YES -FloeSnapshotDir <dir>` for
synthetic-only snapshots of every visualizer style and the lyrics view.
`-FloeSelfTest YES -FloeSelfTestPerf YES` holds each visual scenario for 10 s and
logs CPU, analysis and background frame rates, and footprint. It also checks that
the cover rim and progress playhead move while playing and stop on pause, and compares
raw and adaptive equalizer shapes on two of your liked songs.
`-FloeSelfTestPerfOnly <name>` holds matching scenarios instead, for 30 s when only
one matches (useful with `sample`). It restores every preference afterwards.

Window snapshots can't show Core Animation masks or motion, so `scripts/test-layers.sh`
renders the real cover, visualizer and progress-track layers offscreen with
`CARenderer`, inside a top-down parent as SwiftUI hosts them. It checks pixels: the
cover is upright and shows a new image even while paused, bass sits at the top of the
ring, bottom bars stand on the floor, the halo is pale on top, and the progress fill covers only
the elapsed part. Additional checks cover height-only progress resizing, the track
thickening with a thumb only under the pointer (and with Reduce Motion), the playhead
gliding only while playing, and the bead ribbon's overlap. The card must be upright
and in perspective over a reflection that fades out, and a short ray must be fainter
than a long one (`FLOE_LAYER_PREVIEWS=<dir>` writes both as PNGs). Its dim rear ribbon is now clipped by Core Animation rather
than a polygon subtraction on every frame. Synthetic path-generation time fell
from 0.411–0.433 ms to 0.051 ms/frame (~88%); this excludes compositor/GPU work and
is not a new whole-app CPU measurement.

`scripts/test-background.sh` exercises the production Metal renderer with synthetic
colors and spectrum data, including GPU pixel readback. Paused cover/accent changes
and window resizing redraw one static frame; unchanged settings stay idle. Changes
that arrive during GPU work coalesce into the latest replacement frame. It also feeds
synthetic songs (kicks, snares, hats, vocals, drops, silence) through the real
analyzer and checks the layer mapping, motion limits, crisp edges and flash rate.

**Auto preset** (off by default) picks the live-background preset for each song: from
the artist's Spotify genres when available (cached per artist), otherwise from about
10 s of the sound (tempo, steady kick, bass weight, hats). Choosing a preset or moving
a slider turns it off; it never enables the strobe. `scripts/test-autopreset.sh` checks
the genre table, the sound classifier and the cache; `-FloeSelfTestAutoPreset YES` logs
what Spotify returned for each playing song and the preset chosen, without playing
anything itself.

`scripts/test-palette.sh` runs cover colour extraction on drawn covers (black and
white, sepia, dark red, navy, pastel, neon specks) and checks that neutral covers
stay neutral, dark ones keep their hue and nothing turns green that isn't.
`scripts/test-layout.sh` renders the real window offscreen with a fake library at
three sizes and checks alignment guides, scroll resting positions and search focus;
PNGs go to /tmp/tint-layout.

`scripts/benchmark-lyrics.sh` renders lyrics offscreen with synthetic timed lines
(steady, changing, a playing instrumental gap, paused) and measures CPU, window
layouts and line-clock wakeups; `FLOE_LYRICS_LOOK_DIR=<dir>` saves the gap's look. It needs neither Spotify nor saved credentials. An optional first
argument selects another `LyricsView.swift` to benchmark against the same fixture.
The production lyric clock now sleeps until the next line, and stops waking after
the final line or during pauses. Progress motion also stops while Tint is inactive
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
position and whether it was paused, and reloads Tint's context. Manually queued
songs may be reset. Session loss stops the UI clock and retries with backoff (a saved login that
Spotify refuses isn't retried; the banner asks to sign in again);
**Reconnect now** and **Sign in again** provide recovery. Unavailable tracks show a
human-readable, dismissible error with **Next song**. Expired/revoked library tokens
lead back to library authorization; stale refreshes cannot reinstall signed-out
credentials.

Queue/Devices fetch only when opened, on track changes in Queue, or on **Refresh**.
Queue shows songs (episode/local entries without usable song metadata are skipped),
retaining duplicate entries. Restricted devices cannot receive transfers. Transfers
preserve the current play/pause state. The volume control applies to Tint; use macOS
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
build/Tint.app/Contents/MacOS/Tint -FloeSelfTest YES -FloeSelfTestPhase5 YES
```

Offline checks use synthetic tokens, devices and metadata: configuration and paused
reload, 401 refresh/repeated rejection, Retry-After, transfer JSON, mixed queue
entries, access gating, restricted devices, cancellation/stale responses and
Ukrainian plural forms. The live check exercises a connection-loss event, applies
160 kbps with normalization, restores the original playback preferences and
verifies resume/position/pause and real audio flow. It leaves playback paused.
On the same Mac, its paused sample was ~133 MiB physical footprint; CPU settled to 0%.
The queue/device live checks run only after permission is granted.

Song selection updates the title, row highlight and loading indicator from the
clicked row immediately. Cover/lyrics loading starts at selection time; the full
cover can appear before its blurred backdrop is ready. The playback clock stays
stopped until the engine confirms playback. The core prepares a known selected
track while Spirc resolves its context, silences old audio on manual switches,
and preserves buffered audio for automatic gapless transitions.

Previous and Next wait for actual engine events before showing loading or stopping
the clock. A seek-only or ignored command therefore cannot leave a permanent
spinner or close audio output. Manual skips flush the old audio at the confirmed
track change, including ready preloads which omit a loading event. At the first
song, Previous restarts at zero and preserves play/pause. If history is temporarily
unknown and the engine stops at that boundary, Tint reloads the same song once;
an intervening Connect takeover cancels that recovery.

The audio engine runs only while there is something to play: it stops 2 s after
playback does, and a Play or a load that the engine never answers (no session, or
nothing to take over) gives it back after 10 s or 30 s instead of leaving it
rendering silence, which also kept the Mac from idle sleep. Play without a session
does nothing.

Liking or unliking a song while Liked Songs is open updates the list where it
stands (the row leaves, new songs join at the top) instead of loading it again from
the first page. Liked-state checks for rows run one request at a time, newest rows
first, and drop rows flung past long ago.

```sh
scripts/test-transport.sh
build/Tint.app/Contents/MacOS/Tint -FloeSelfTest YES -FloeSelfTestTransport YES
```

The offline suite exercises the production playback model using synthetic events,
including rapid Previous, paused boundaries, stale history, duplicate song URIs
and takeover-safe recovery. The opt-in live check uses the first two songs of a
playable playlist, verifies audio after double Previous and a forward/back round
trip, then leaves playback paused. It does not edit the library or capture lyrics.

```sh
build/Tint.app/Contents/MacOS/Tint -FloeSelfTest YES -FloeSelfTestSwitching YES
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
before starting audio. Tint reduces this window from five seconds to one, which
fits inside the initial 64 KiB compressed-data request at 320 kbps. Adaptive
prefetch, decoder block size and network timeouts retain upstream defaults. This
also reduces the explicit read-ahead during playback; congested networks have not
been benchmarked. For a diagnostic comparison with upstream buffering, launch with
`FLOE_AUDIO_READ_AHEAD_MS=5000` (valid range 1000–5000; normal launches use 1000).

Artwork sizes now share one in-flight HTTP download per URL; decoded variants
remain in the existing bounded cache, and raw bytes are not kept after processing.
The playing song's 640 px covers (1.6 MB each) have a small cache of their own, four
at most, so a long listening session no longer fills the 48 MB browsing cache with
them; and once no Tint window has been visible for 30 s the browsing covers are let
go (views on screen keep theirs, the rest decode again from disk when scrolled to).
Control Center retains a pending artwork task across metadata updates and shows
the 720 px cover Now Playing already decoded. Covers decode in parallel, off the
cache's actor. Synthetic tests verify concurrent sizes, memory hits, failed-request
recovery and cancelled callers. Seventeen Rust tests cover configuration, analysis,
transport events, stereo copying and switch/gapless buffering; offline API checks
and all 12 synthetic lyric regressions pass.

`scripts/benchmark-core.sh` times the non-visual hot spots offline: the Rust audio
path (render callback and sink), decoding a page of covers, the per-song cover work
(backdrop blur and palette) and core-event decoding. On the same M3 (2026-10-09),
before → after the round-3 refactor: push+render of 512 frames 1270 → 254 ns, a
4096-sample sink write 6.0 → 1.5 µs with no allocation per packet, 32 covers
21–50 → 7–11 ms, the cover work 14–16 → 1–3 ms per song (one blur context instead
of one per song). The audio graph is built on the first play rather than at launch
(~50 ms of main thread).

## Layout

```
core/                 Rust staticlib: librespot session + Spirc + player, C ABI (src/lib.rs);
                      vendor/ is librespot's player crate with Tint's one change
Sources/CFloeCore/    C header + modulemap for the Rust library
Sources/Floe/         SwiftUI app
  App/                app entry, self-test, snapshot hook
  Core/               Swift wrapper over the C ABI, event decoding
  Playback/           PlayerModel, AVAudioEngine output, Now Playing + media keys
  API/                Web API client and models
  Auth/               OAuth PKCE (loopback redirect), token provider, credential store
  Library/            library state (playlists, pins, liked songs), navigation
  Images/             artwork cache, cover palette and pre-blurred backdrop
  Lyrics/             LRCLIB service, memory cache, LRC parser and view state
  Visualization/      vDSP FFT, bounded PCM sampling, visual preferences, Metal shader
  Settings/           persisted playback/appearance preferences and native settings window
  Views/              UI
Support/Localizations/ English/Ukrainian interface strings and plural rules
Support/Info.plist    bundle metadata
scripts/              build-app.sh, package-app.sh, install-app.sh, make-icon.swift, test-*.sh
.github/workflows/    CI: build and offline tests
```

## How it works

- **Spotify Soloist playback backend (default since 0.4.0).** `SoloistBackend` spawns
  the user-installed `soloist` binary with `--ws 127.0.0.1:0` and its own private data
  and cache directories, discovers `ws.addr`/`ws.port`, and speaks Soloist's JSON
  WebSocket protocol (`SoloistProtocol`) translated directly into `CoreEvent`s.
  `SoloistAudioTap` uses macOS's Core Audio Process Tap (`CATapDescription` +
  `AudioHardwareCreateProcessTap`) to tap Soloist's child PID and feed stereo float32
  PCM into `floe_push_analysis` only while visual effects are active. The Soloist API key
  is stored in `CredentialStore` (`soloist-api-key`, 0600). `librespot` remains available
  as an opt-in legacy engine in Onboarding and Settings → Playback.
- **Starting a list with Soloist.** Soloist's `play` takes one URI and its queue can only
  be added to, so it can't start a playlist at a chosen song or play a list of songs.
  Those requests go through the Web API instead (`PUT me/player/play` on Tint's own
  Connect device, `PlaybackStart` / `PlaybackStarter`): an album or playlist with an
  offset, anything else (Liked Songs, search results, a filtered or sorted list) as up to
  200 URIs around the chosen song. This needs the playback permission that Queue and
  Devices asks for; without it, or if Spotify refuses, Soloist plays the chosen song alone.
  0.4.0 added the following songs to the queue instead, where they stayed ahead of
  everything played later (search results cut into Liked Songs).
- **Audio path (librespot).** librespot decodes on its own thread into a custom `Sink`, which writes
  interleaved f32 PCM into a lock-free ring buffer. An `AVAudioSourceNode` pulls from it
  on the render thread (`floe_render`). Pause closes a gate so audio stops immediately
  rather than after the buffer drains; seek and load flush the buffer. Volume lives
  in Swift. A separate 32 KiB stereo tap copies rendered samples before mixer volume
  without allocating or waiting on the render thread. A utility queue reads the
  newest samples into a rolling 2048-frame Hann window, computes stereo FFT power
  using vDSP, and publishes 48 log-spaced bands, 96 waveform points and RMS. A full
  analysis ring drops visual samples without disrupting playback. Seek, track,
  pause and enable changes reset the analysis generation; PCM never goes to disk.
- **Audio cache.** A song that has downloaded completely (in practice, one played to
  the end) is kept, still encrypted as it arrived, in
  `~/Library/Caches/com.antonchurchyn.floe/Audio`. The cache holds 1 GiB, about a
  hundred songs at 320 kbps; past that librespot deletes the ones played longest ago.
  The next play reads the file from disk: no CDN lookup, no download, and seeking never
  waits for the network. Spotify is still asked for the track and its key, so this is
  not offline playback. Deleting the folder is safe.
- **Playing context.** Tint runs librespot's Spirc, so it is a Spotify Connect device
  ("Tint"): playlists, albums, artists and Liked Songs play as *contexts*, and Spotify's
  own logic handles queue, shuffle, repeat and autoplay, exactly as in the official apps.
  It can be controlled from the phone, and Play takes over from another device. Chosen
  over an own queue in Swift, which would re-implement all of that and still not be a
  Connect device.
- **Bridge.** A plain C ABI (`Sources/CFloeCore/floe_core.h`) of about twenty functions.
  Results come back as JSON events through one callback. UniFFI would add a code
  generator for no real gain at this size.
- **Login.** librespot's session must be authorised with *Spotify's own* client ID
  (`streaming` scope): Spotify rejects third-party client IDs there. Tint runs the PKCE
  flow in the browser with a one-shot listener on `127.0.0.1:5588/login`, gets
  reusable credentials back from librespot, and stores only those. The Web API uses
  the client ID of your own developer app (pasted in the app, else built in) with PKCE
  on `127.0.0.1:8898/callback`; its refresh token is stored too, with the client ID that
  issued it. No client secret is used or stored anywhere.
- **Credentials.** Both logins are files in `~/Library/Application Support/Floe/Credentials`
  (folder 0700, files 0600, written atomically, excluded from backups). Any process
  running as you can read them, as with Spotify's own desktop client; FileVault
  protects them at rest. The Keychain would be stricter, but without a developer
  Team ID macOS ties its items to each build's code hash, so it asked for your
  password after every rebuild. Builds before this kept both logins in the Keychain;
  Tint moves each one into its file on first read and deletes the old item, once.
  `scripts/test-credentials.sh` checks this offline, with a temporary folder and a
  fake Keychain.
- **Web API limits (Development Mode, 2026).** Tint uses only endpoints still open to
  Development Mode apps. Consequences: playlists you don't own show their header and
  Play but no track list; Spotify-made playlists 404 (Play still works); no artist top
  tracks; search and artist albums return at most 10 per request; `market=from_token`
  needs a scope Tint doesn't request (and isn't needed with a user token).
  PLAN.md's fallback of Web API tokens from the librespot session no longer works
  (tested 2026-10-08): keymaster answers 403, and api.spotify.com throttles login5
  tokens (429, `Retry-After` up to 86400 s). Tint doesn't send them.
- **librespot version.** Pinned to a commit on `dev` (see `core/Cargo.toml`): the 0.8.0
  release doesn't build from crates.io (librespot-org/librespot#1760). Bump it on purpose.
  The player crate alone is built from `core/vendor/librespot-playback`, that same commit
  with one change: the audio key is requested together with the file, not after it has
  opened, so a song that isn't preloaded starts one round trip sooner
  (`core/vendor/README.md`). Its effect on start time is not measured yet;
  `-FloeSelfTestSwitching YES` prints the start times to compare.
- **0.3.0 performance pass (2026-11-25, Apple M3, offline suites).**
  - Live background Metal shaders (`scripts/test-background.sh`): hoisted Fluid blob
    orbits and Beams head directions to CPU uniforms, switched color/blending paths to
    `half` + `exp2`, added early-outs for beam cores/motes and off-region lens flares,
    and switched the main render pass to `loadAction = .dontCare`. Fluid GPU fell from
    0.53 ms → 0.40 ms (−25% at 1500×950); Beams GPU fell from 0.68 ms → 0.59 ms (−13% at
    1500×950) and 3.25 ms → 2.79 ms (−14% at full Retina 3456×2234).
  - Lyrics (`scripts/benchmark-lyrics.sh`): switched `LyricRow` to opaque white + layer
    `.opacity` (adjusting `ListLayout.glides` start offset to 1 frame) and added
    `ListMotion` hover dwell/scroll suppression; per-layout time fell from 3.09 ms →
    1.82 ms (−41%).
  - Surface transitions (`NowPlaying → Library`): layered `NowPlayingView` over the
    fixed-size Library + MiniPlayer stack, kept `MiniPlayerView` mounted, and replaced
    8-piece `PanelEdge.fill(LinearGradient)` with a Core Animation `strokeBorder` + 1 pt
    GPU sheen; main-thread CPU per transition layout fell from 2.23–3.11 ms → 0.78 ms
    (~3.5× faster), peak layout from 16–37 ms → 5.5–7.3 ms.
  - Idle gating & memory bounds: propagated `windowVisible` (`WindowPresence`) to pause
    `ProgressBar`, `CrawlingCover`, `LoopingSymbol` and `SyncedLyricsView` when occluded;
    stopped 30 Hz main-thread analysis dispatches when only the live background runs;
    skipped downsampling for cancelled fast-scroll artwork tasks; capped `LibraryModel.liked`
    (4,000) and `Navigator.stack` (64); aborted timed-out `spirc_task` on teardown.

### Command Line Tools quirks

- In the current SDK, `@State` is a macro whose compiler plugin ships only with Xcode.
  Use `@ViewState` instead (an alias for the same property wrapper, in
  `Sources/Floe/Support/ViewState.swift`). `#Preview`, `@Entry` and `@Animatable`
  are unavailable for the same reason.
- `core/.cargo/config.toml` makes cargo fetch git dependencies with the git CLI, so
  a global `https://github.com/` → SSH rewrite works.
