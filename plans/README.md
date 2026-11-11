# Animation plans

Plans 001–005 were written by the improve-animations audit at commit e102e24 (2026-10-19), 006–009 at 95ea037 (2026-11-11). Each plan is self-contained.

| # | Plan | Severity | Status |
|---|---|---|---|
| 001 | [Keep Library mounted and make the surface switch light](001-mounted-library-light-surface-switch.md) | HIGH | DONE |
| 002 | [Lyrics open on the current line; lighter lyrics swap](002-lyrics-open-on-current-line.md) | MEDIUM | DONE |
| 003 | [Resize the crawling cover without rebuilding its motion](003-crawling-cover-cheap-resize.md) | HIGH | DONE |
| 004 | [With Reduce Motion, fade instead of cutting](004-reduce-motion-fades-not-cuts.md) | HIGH | DONE |
| 005 | [Feel polish: like star, mini-player extras, shelf cards, cover dip](005-feel-polish.md) | MEDIUM | DONE |
| 006 | [Back and keyboard navigation land at once](006-back-and-keyboard-navigation-land-at-once.md) | MEDIUM | TODO |
| 007 | [Row covers: no shadow at rest, and fade it in instead of growing it](007-row-cover-shadows-fade-in.md) | LOW | TODO |
| 008 | [First run: one sign-in card that carries through, and a soft arrival](008-first-run-one-card-and-a-soft-arrival.md) | MEDIUM | TODO |
| 009 | [Bridge four pops: live background, visualizer, pinned playlists, unliked rows](009-bridge-four-pops.md) | LOW | TODO |

Plans 006–009 come from the second audit and the opportunity sweep (2026-11-11).

**Order and dependencies:** 001 → 004 → 002 touch `Motion.swift`, `RootView.swift` and `LyricsView.swift` and ran in that order (004 needs 001's `SurfaceTransition(still:)`). 003 and 005 touched other files.

006 and 008 both edit `RootView.swift` (006 `MainView.libraryPanel`, 008 `RootView` itself) and can run in either order, one after the other. 007 and 009 both edit `Sidebar.swift` (different lines); run them one after the other too. 009 is four independent parts; its part (b) needs a look on screen before it is kept. Each plan's feel check needs the running app, so it is the owner's to do.

**Considered and left alone (second audit):**
- Sorting or filtering a track list moves thousands of rows the user is reading: no animation.
- Search results changing while typing: keyboard-driven, no animation.
- The page reveal's length (0.42 s spring, 30 ms stagger) on a click: a deliberate part of the design; 006 only removes it where the page isn't new.
- ⇧⌘L (lyrics column) animates although it is a keyboard shortcut: it is rare, and the motion explains a large layout change.
- The queue popover's rows on a song change: the popover is rarely open at that moment, and its rows would first need stable identities for duplicate entries.
- Timings typed at call sites instead of `FloeMotion` tokens (0.45 s backdrop and glow changes, the lyric row's own press spring and 0.15 s fade, 0.12 s for the hover Play button's exit): they work; folding them into tokens is tidying, not feel.
- Shuffle's press keyframes restart from rest on a double press mid-animation (up to 24° of rotation cut): rare enough to leave.
