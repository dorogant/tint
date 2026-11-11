# Animation plans

Plans 001–005 were written by the improve-animations audit at commit e102e24 (2026-10-19), 006–009 at 95ea037 (2026-11-11). Each plan is self-contained.

| # | Plan | Severity | Status |
|---|---|---|---|
| 001 | [Keep Library mounted and make the surface switch light](001-mounted-library-light-surface-switch.md) | HIGH | DONE |
| 002 | [Lyrics open on the current line; lighter lyrics swap](002-lyrics-open-on-current-line.md) | MEDIUM | DONE |
| 003 | [Resize the crawling cover without rebuilding its motion](003-crawling-cover-cheap-resize.md) | HIGH | DONE |
| 004 | [With Reduce Motion, fade instead of cutting](004-reduce-motion-fades-not-cuts.md) | HIGH | DONE |
| 005 | [Feel polish: like star, mini-player extras, shelf cards, cover dip](005-feel-polish.md) | MEDIUM | DONE |
| 006 | [Back and keyboard navigation land at once](006-back-and-keyboard-navigation-land-at-once.md) | MEDIUM | DONE |
| 007 | [Row covers: no shadow at rest, and fade it in instead of growing it](007-row-cover-shadows-fade-in.md) | LOW | DONE |
| 008 | [First run: one sign-in card that carries through, and a soft arrival](008-first-run-one-card-and-a-soft-arrival.md) | MEDIUM | DONE |
| 009 | [Bridge four pops: live background, visualizer, pinned playlists, unliked rows](009-bridge-four-pops.md) | LOW | DONE |

Plans 006–009 come from the second audit and the opportunity sweep (2026-11-11).

**Order and dependencies:** 001 → 004 → 002 touch `Motion.swift`, `RootView.swift` and `LyricsView.swift` and ran in that order (004 needs 001's `SurfaceTransition(still:)`). 003 and 005 touched other files.

006–009 were carried out on 2026-11-11, with these differences from the plans as written:
- 007 fills the shape behind a cover with the panel's grey (`Color(white: 0.11)`), not black, so a cover still loading doesn't go dark under the pointer.
- 008 also opens the card for step 2's instructions on the same spring, and fades step 2 in as it becomes available.
- 009 (b), the visualizer toggle in Now Playing, animates the cover's size. It hasn't been seen on screen: if the scalloped rim steps while the size eases, drop the two `.animation` lines on `settings.showVisualizer` and `settings.style` in `NowPlayingView.swift` and keep the transitions.

None of them has had its feel check: that needs the running app.

**Found while doing them (2026-11-11):** dragging the pointer down a playlist held the main thread at about 15 ms a frame. See "Hover" in `Sources/Floe/Views/AGENTS.md` for what caused it and the rules that came out of it (opacity over opaque text instead of a colour that animates; a gradient view under a clip instead of a gradient-filled shape; rows light only after the pointer stays 30 ms).

**Considered and left alone (second audit):**
- Sorting or filtering a track list moves thousands of rows the user is reading: no animation.
- Search results changing while typing: keyboard-driven, no animation.
- The page reveal's length (0.42 s spring, 30 ms stagger) on a click: a deliberate part of the design; 006 only removes it where the page isn't new.
- ⇧⌘L (lyrics column) animates although it is a keyboard shortcut: it is rare, and the motion explains a large layout change.
- The queue popover's rows on a song change: the popover is rarely open at that moment, and its rows would first need stable identities for duplicate entries.
- Timings typed at call sites instead of `FloeMotion` tokens (0.45 s backdrop and glow changes, the lyric row's own press spring and 0.15 s fade, 0.12 s for the hover Play button's exit): they work; folding them into tokens is tidying, not feel.
- Shuffle's press keyframes restart from rest on a double press mid-animation (up to 24° of rotation cut): rare enough to leave.
