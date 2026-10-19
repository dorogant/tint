# 002 — Lyrics open on the current line; lighter lyrics swap

- **Status**: DONE
- **Commit**: e102e24
- **Severity**: MEDIUM
- **Category**: Performance / Purpose
- **Estimated scope**: 1 file (`Sources/Floe/Views/LyricsView.swift`), ~15 lines

## Problem

A freshly shown synced lyrics list (opening Lyrics, or Now Playing's lyrics column) renders at line 0 and only jumps to the current line when `.task` runs after the first frame — inside the surface transition. The jump makes the lazy stack build rows up to that line and re-evaluate every visible row's `distance` mid-animation.

```swift
// Sources/Floe/Views/LyricsView.swift:82-83, 125 — current
@ViewState private var active: Int?
@ViewState private var position = ScrollPosition(idType: Int.self)
…
.task(id: player.playbackAnchor) { await followPlayback() }
```

The lyrics content swap is also slow for something that runs twice per song (idle → loading → loaded):

```swift
// Sources/Floe/Views/LyricsView.swift:30 — current
.floeAnimation(value: phaseKey, duration: 0.45)
```

## Target

- On appear, before the first frame, `SyncedLyricsView` computes the active line and scrolls to it without animation. The first `followPlayback()` iteration then finds `index == active` and does nothing.
- The lyrics content swap settles in 0.3 s: `.floeAnimation(value: phaseKey, duration: 0.3)`.

## Repo conventions to follow

- `advance(to:animated:)` (`LyricsView.swift:164-171`) already applies a non-animated jump with `transaction.disablesAnimations`. Reuse it.
- `Self.lead` (0.15 s) and `LRC.activeIndex(in:at:)` are how the active line is computed in `followPlayback()` (`:143-144`).

## Steps

1. In `SyncedLyricsView.body`, on the `GeometryReader` (the same level as `.task`), add before `.task(id:)`:
```swift
// Open on the current line, so a newly shown list never lands on line 0
// and then jumps mid-transition.
.onAppear {
    let now = player.positionMs(at: Date()) / 1000 + Self.lead
    advance(to: LRC.activeIndex(in: lines, at: now), animated: false)
}
```
2. `LyricsView.swift:30`: change `duration: 0.45` to `duration: 0.3`.
3. `swift build -c release`.

## Boundaries

- Do NOT change `followPlayback()`, row animations, blur, glow or the edge mask.
- Do NOT touch the `.transition(.blurReplace)` / follow-button transitions (plan 004 owns those lines).
- On drift, STOP and report.

## Verification

- **Mechanical**: `swift build -c release` passes; `scripts/benchmark-lyrics.sh` still runs if it is hermetic (read it first; skip if it needs login or audio).
- **Feel check** (owner): during playback mid-song, switch to Lyrics and toggle Now Playing's lyrics column (⇧⌘L): the current line is already in place on the first frame, with no scroll jump during the fade. Paused mid-song: same.
- **Done when**: the list is positioned by `onAppear`, not by the first `.task` iteration.
