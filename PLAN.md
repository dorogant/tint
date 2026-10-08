# Floe — native macOS Spotify client

The app name is **Floe** (now shipped as Tint). Goal: a lightweight **native** Spotify client for macOS (Apple Silicon) that replaces the official Chromium-based app for everyday listening.

**Design direction:** modelled on a QML Linux Spotify client shown in a short video ("QML Spotify client, no webviews"). That video is **the** visual and feature reference (see "Reference UI" below). This is *not* a port of a WebView theme. Build an original implementation of that look and feel; don't copy assets or code.

## Why

- The official client is Chromium (CEF) inside. Measured on this Mac on 2026-10-07: **~450 MB RSS across 8 processes** (main app, 6 helpers, 2 renderers) while idle, and it grows with use.
- Target for the new app: **≤150 MB RSS** during normal playback, idle CPU close to 0%.
- Theming the official client means injecting CSS into its WebView. The aim is a real native app instead.

## Decisions already made

| Topic | Decision | Reason |
|---|---|---|
| UI tech | **SwiftUI** (AppKit where needed), not QML | Mac-only; native blur materials, Metal shaders, Accelerate FFT, media keys; no Qt runtime (~100 MB) |
| Playback | **librespot** (Rust) linked into the app | the only realistic way to stream natively without the official client; same approach as the reference app |
| Metadata | **Spotify Web API** (OAuth PKCE, the user's own developer client ID) | official, stable |
| Lyrics | **LRCLIB** (`https://lrclib.net/api/get`), synced LRC | Spotify's lyrics endpoint is internal |
| Build | SwiftPM + a script that assembles and ad-hoc signs the `.app` | full Xcode is **not** installed; only Command Line Tools |
| Account | **Spotify Premium** | required by librespot |
| Client ID | each user's own developer app with Web API enabled; a Client ID is public, not a secret. **Never** ask for or store the Client secret: PKCE doesn't need it | Spotify's Developer Terms don't allow sharing one |
| Redirect URI | `http://127.0.0.1:8898/callback` (registered in the user's Spotify developer app) | the app runs a one-shot loopback listener on port 8898 for the OAuth PKCE callback |

## Environment facts (checked 2026-10-07)

- macOS 27.0, arm64. Swift 6.4 (CLT only; `xcodebuild` unavailable). Homebrew 7.0.8 is installed.
- **Rust is installed via rustup.** The build script uses `~/.cargo/bin`.
- Qt is not installed and isn't needed.
- Make strings localisable (English first, Ukrainian later).

## Constraints & risks (tell the user, don't hide)

1. **Spotify Premium is required** (librespot can't play on Free).
2. librespot is **unofficial**: it breaks Spotify's ToS. Bans are rare but possible, and Spotify protocol/auth changes can break playback until librespot updates. Pin a librespot version and keep the integration thin so upgrades are easy.
3. **No offline downloads** (DRM).
4. Development Mode (since Feb–Mar 2026): the **app owner needs Premium**, up to **5 authorised users**, and only a **reduced set of endpoints** is available. Check which endpoints Development Mode allows before designing a screen around one.
5. Older Web API limits for new or development-mode apps: Spotify removed several endpoints for new apps in late 2024 (recommendations, audio-features/analysis, related artists, featured/category playlists, 30-second previews). Build Home from the user's own data (recently played, top items, saved albums, playlists, liked songs). Check current docs before relying on any endpoint.
6. Spotify **no longer accepts `localhost` redirect URIs**; use a loopback IP such as `http://127.0.0.1:<port>/callback`. Verify against current docs.
7. The user must create the Spotify developer app themselves (developer.spotify.com → Create app → add the redirect URI → copy the Client ID). Never create accounts or handle their password; store tokens in the **Keychain**.
8. **Developer app.** The dashboard's Web API box stays greyed out until the account has a verified email. Use **Path A**: the user's own Client ID with PKCE.
   - Keep the token source behind one Swift protocol (`TokenProvider`). The fallback, **Path B**, is Web API tokens from the librespot session's token provider (the way spotify-player and ncspot do it). Use it only if Development Mode endpoint limits block something important.

## Architecture

```
App.app (SwiftUI)
 ├─ UI layer ────────── sidebar, home, search, playlist/album/artist pages,
 │                       mini player, Now Playing, lyrics, settings window
 ├─ SpotifyAPI (Swift) ─ Web API client, OAuth PKCE, paging, image cache
 ├─ Player (Swift) ───── AVAudioEngine output, volume, FFT tap (Accelerate/vDSP),
 │                       MPNowPlayingInfoCenter + MPRemoteCommandCenter (media keys)
 ├─ Lyrics (Swift) ───── LRCLIB fetch + LRC parse + time sync
 └─ Core (Rust staticlib, C ABI or UniFFI)
       └─ librespot: session/auth, load/play/pause/seek/next, Spotify Connect device,
          custom audio Sink → PCM (f32) handed to Swift through a callback/ring buffer
```

- **Audio path:** librespot decodes, a custom `Sink` pushes PCM into a lock-free ring buffer, Swift pulls it in an `AVAudioSourceNode`. One path covers playback, volume and visualizer, so the visualizer reacts to the **real** audio.
- **Bridge:** prefer UniFFI (or cbindgen + C ABI if simpler). Build the Rust crate as an arm64 staticlib; link it from a SwiftPM target. Keep the FFI surface small: `login`, `play(uri, context)`, `pause`, `resume`, `seek(ms)`, `next`, `prev`, `setVolume`, an event stream (track changed, position, state, errors) and a PCM callback.
- **Auth:** librespot needs its own session auth (see the current `librespot-oauth` docs for the recommended flow and scopes). The Web API uses the user's own client ID via PKCE. Keep both tokens in the Keychain and refresh them automatically.
- **Playing context:** to play a playlist or album with queue, shuffle and repeat, let librespot handle the context (as spotifyd/ncspot do) or register the app as a Connect device and drive it through the Web API player endpoints. Choose one and document why.

## Reference UI (from the video, described; do not copy assets)

**Overall:** dark rounded window with floating frosted-glass panels. A blurred cover-art backdrop is tinted per song. Green (Spotify-like) accent by default, with an optional setting to take the accent from the cover. A small pill toolbar at the top right switches between Library, Now Playing, Lyrics, Theme and Settings.

**Library view**
- Left sidebar: Home, Search, Songs; "Pinned Playlists" (pin icon); All Playlists; the account at the bottom with a "connected" status.
- Search: pill input with a clear button; a "Songs" result list (cover, title, artist, album, like star, more menu, duration).
- Playlist page: 2×2 mosaic cover, "Playlist" badge, title, owner · track count · duration, a green **Play** pill, shuffle, download (disabled or hidden: no offline), toolbar (back, add, edit, share, sort, "Find in playlist", menu).
- Mini player (bottom): shuffle, previous, green play, next, repeat; cover and title in the centre; on the right a waveform-style volume slider plus device, queue and lyrics buttons.
- Optional right column: synced lyrics, with the current line bold white and the others dimmed.

**Now Playing (full screen)**
- Large cover in a **morphing blob/flower-shaped mask**, with a **circular visualizer** radiating behind it.
- Title, artist · album, a **wavy (squiggly) progress bar**, round controls, volume.
- Right side: **synced lyrics**, smoothly auto-scrolling; the current line sits on a soft frosted pill and the rest fade.
- Optional full-width bottom visualizer: **bars** or **wave**, tinted from the cover.

**Settings window** (separate window; sections: Visualizer, Background, Playback, Downloads, Appearance, About)
- Visualizer: show toggle; Style **Normal / Circular**; Shape **Bars / Wave**; Sensitivity slider (default ~120%); a note that it's visual-only and sampled about 30×/s.
- Background: **Live background** toggle (an animated Metal shader that reacts to audio, paused when playback pauses); **Blur** slider; **Reactivity** slider; a note about the CPU/battery cost.
- Playback: crossfade, normalisation, streaming quality (librespot bitrate 96/160/320).
- Appearance: accent from cover vs fixed colour; glass intensity; reduce motion.

## Phases (each ends with something runnable; verify before moving on)

**0. Setup**
- Confirm Premium and the Rust install, and propose app names. Ask the user to create the Spotify developer app and give you the Client ID.
- `git init`, `.gitignore`, a README explaining the build.
- A build script: `cargo build --release` for the Rust core, then `swift build -c release`, then assemble the `.app` (Info.plist, icon placeholder, ad-hoc `codesign`).

**1. Playback core.** *Done when:* log in, play a hard-coded track URI, hear audio, and see pause/seek working from a bare SwiftUI window. Measure RAM.

**2. Library & navigation.** *Done when:* the sidebar, Home (recently played, playlists, saved albums), search, and playlist/album/artist pages work; clicking a track plays it in context; the mini player works; liked songs can be toggled; media keys and Control Center Now Playing work.

**3. Now Playing & lyrics.** Done (2026-10-08): shared transport, cover-derived palette with readable button text, a pre-blurred backdrop, a slow blob mask, wavy seeking, LRCLIB fetch/cache and line sync. Cover/wave motion pauses with playback; both app and system Reduce Motion are respected. Verified with 12 synthetic parser/color/service tests, real playback with 134 synced lines and lyric seeking, and screenshots with synthetic text only. Physical footprint was ~147 MiB; steady playback RSS ~155 MiB, so the original RSS target still needs tuning. *Done when:* there's a cover-art glass background with an accent from the cover, the blob cover mask (slow morph, respecting Reduce Motion), the wavy progress bar, and LRCLIB synced lyrics with a frosted current-line pill and smooth scrolling (with an "instrumental / no lyrics" state).

**4. Visualizer & live background.** Implemented and verified (2026-10-08): bounded rendered-stereo PCM tap, utility-queue vDSP FFT at 30 Hz, circular/normal bars and waves, persisted visual controls, and an optional 15 Hz Metal background. Real playback passed cadence, audio-flow/no-new-underrun, pause, hidden/disabled effects and Reduce Motion checks; 3 Rust tap tests, 9 synthetic FFT checks and Metal compilation passed. Synthetic-only screenshots cover all four visualizer combinations. Clean-run circular RSS was ~149–152 MiB (~195 MiB physical footprint); live background in Library ~154 MiB RSS (~187 MiB footprint). Paused CPU settled to 0%. The ≤150 MiB RSS target remains a tuning item; the background defaults off. *Done when:* an FFT from the real PCM (vDSP) drives circular, bars and wave visualizers, there's an optional Metal shader background, and both pause when playback pauses. Keep CPU and RAM within budget.

**5. Settings & polish.** Implemented (2026-10-08) with explicit limitations: native six-section settings, persisted visual/background/appearance controls, English/Ukrainian UI and plural forms, a native flower/rhythm icon, quality/normalization/gapless configuration, context/position/pause-preserving reconnect, session/token/unavailable-track recovery, and opt-in queue/device panels. Five Rust tests, offline API/recovery/cancellation tests, Ukrainian plural checks and all 12 lyric regressions pass. Live playback/reconfiguration/resume/pause checks pass (~133 MiB paused physical footprint, CPU settles to 0%). With the extra Spotify consent granted, live queue/device-list checks pass; transfer requests are verified offline. Existing library access is preserved. The pinned engine lacks crossfade; its row is unavailable, as are offline downloads. Memory tuning remains open. *Done when:* the settings window has every section above wired to UserDefaults, plus queue view, device/volume, error states (session lost, token expiry, region-unavailable tracks), Ukrainian localisation, and an app icon.

## Working rules for the agent

- Verify each phase by running the app. RAM: check with `ps -o rss` or `footprint`; report the numbers.
- Commit at the end of each phase with clear messages. Ask before any push or remote.
- Never put the client secret or tokens in the repo. PKCE needs no secret.
- Don't use Spotify's private endpoints beyond what librespot itself needs.
- Don't render lyrics anywhere except the live in-app view (no logging or dumping lyric text).
