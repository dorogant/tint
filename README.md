# Tint

A native Spotify client for macOS. It covers everyday listening (your library, search,
playback, lyrics, Spotify Connect) without the embedded browser the official app is
built on, and uses about a sixth of its memory.

![Tint playing a song: the visualizer around the cover, synced lyrics beside it](docs/screenshots/now-playing.jpg)

https://github.com/user-attachments/assets/d1be912e-72f9-47e6-bd91-8671f65c4938

https://github.com/user-attachments/assets/71409bcd-6803-4178-b1d2-96befeec9820

Built with SwiftUI, Core Animation and Metal on top of
[Spotify Soloist](https://developer.spotify.com/documentation/soloist) (with optional
[librespot](https://github.com/librespot-org/librespot) fallback). Needs Spotify Premium.

## Features

- Home, playlists, albums, artists, Liked Songs and search
- Official **Spotify Soloist** playback engine by default (works on all Spotify Premium accounts, lossless audio, crossfade & local cache), with optional `librespot` fallback
- A Spotify Connect device: control it from your phone, see the queue, move playback
  between devices
- Synced lyrics that follow the song; click a line to jump to it
- Visualizers and live backgrounds (Fluid and Beams) that take their colours from the album cover and react to audio via macOS Core Audio Process Tap
- A ten-band equalizer with presets
- Mixes made to order (mood, energy, no liked or already-heard songs) that you steer while they play
- Your own listening stats
- Media keys and the Control Center player
- English and Ukrainian

## What's new in 0.4.1

- **Tint updates itself**: a newer version is offered in the sidebar and under **Settings → About**, and installed with one click. Only builds carrying Tint's own signature are accepted.
- **A ten-band equalizer** with presets, under **Settings → Playback** (Spotify Soloist).
- **Beams reworked**: patterns mirror about the centre, six beams rise from the floor, and the strobe keeps to the beat.
- **Live backgrounds hear more**: the haze follows the song's lead voice or instrument, and snares and hi-hats are found in dense mixes.

## What's new in 0.4.0

- **Spotify Soloist as the default playback engine**: replaces `librespot` as the default so Tint works on **every** Spotify Premium account (including newer accounts where Spotify blocks `librespot` audio keys with `error audio key 0 1`), with one-click Homebrew install in onboarding, local WebSocket control, and a Core Audio Process Tap (`CATapDescription`) so the visualizer and live background stay audio-reactive.
- **Optional `librespot` fallback**: still available in Onboarding and **Settings → Playback** for older accounts.
- **0.3.0 performance & polish included**: 13–25% faster Metal live backgrounds, ~41% faster synced lyrics layouts with hover dwell, ~3.5× faster `Now Playing → Library` transitions, full idle gating when hidden/minimized, and refreshed sound-disc icon.

<p>
  <img src="docs/screenshots/live-background.jpg" width="49%" alt="The live background, lit in the colours of the cover">
  <img src="docs/screenshots/visual-options.jpg" width="49%" alt="The options for the visualizer and the live background">
</p>

## Compared with the official app

The same song playing in both apps, with lyrics on screen:

| | Tint 0.2.0 | Spotify 1.3.10 |
|---|---|---|
| Memory | **190 MB** | 1,135 MB |
| CPU, share of one core | **5.4%** | 12.3% |
| Memory, paused | **188 MB** | 877 MB |
| CPU, paused | **0.0%** | 0.5% |
| Processes | 1 | 7 |

Measured on a MacBook Air (M3, 16 GB) with [`scripts/measure-app.sh`](scripts/measure-app.sh),
which adds up every process of an app over a minute. Tint's visualizer and live
background were off. It is one run per app, so expect your own numbers to differ.
Themes such as Spicetify run inside the official app and start from its numbers.

## Install

You need a Mac with Apple Silicon, macOS 26 or later, and Spotify Premium.

1. [Download Tint](https://github.com/dorogant/tint/releases/latest/download/Tint.zip),
   unzip it and move Tint to Applications.
2. Open Tint. macOS stops it the first time, because the build isn't notarized: choose
   **Done**, then open **System Settings → Privacy & Security** and click **Open Anyway**
   (or run `xattr -dr com.apple.quarantine /Applications/Tint.app` in Terminal).
3. Set up **Spotify Soloist** (Step 1 in Tint): install `soloist` (`brew install --cask spotify-soloist` or via the button in Tint), paste your free **Spotify Soloist API Key** from [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard), press **Connect**, and select **Tint** once in Spotify's Devices menu.
4. Connect your **Library** (Step 2 in Tint) with the Client ID of a free Spotify developer app, which the setup screen walks you through creating.

From then on Tint updates itself: it offers a newer version in the sidebar and under
**Settings → About**, and installs it when you ask.

To build it yourself instead, with the Xcode Command Line Tools and
[Rust](https://rustup.rs) installed:

```sh
git clone https://github.com/dorogant/tint.git
cd tint
scripts/build-app.sh --install --open
```

## Good to know

Tint is unofficial. It is not affiliated with, endorsed by or connected to Spotify;
"Spotify" is a trademark of Spotify AB. By default Tint controls [Spotify Soloist](https://developer.spotify.com/documentation/soloist),
Spotify's official headless Connect client (which users install directly from Spotify or Homebrew;
builds expire every 90 days and can be updated via `brew upgrade --cask spotify-soloist`).
An optional legacy `librespot` engine is also available in Settings for older accounts, though
Spotify no longer issues `librespot` audio keys to newer accounts.

Tint only streams: no downloads and no offline playback. Lyrics come from
[LRCLIB](https://lrclib.net) and belong to their rights holders.

## More

[docs/REFERENCE.md](docs/REFERENCE.md) has everything else: how Tint works, signing and
build settings, the measurements behind its design, and the tests.

MIT licensed; see [LICENSE](LICENSE). The libraries Tint builds on keep their own
licences, listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
