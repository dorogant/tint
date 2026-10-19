# Animation plans

Written by the improve-animations audit at commit e102e24 (2026-10-19). Each plan is self-contained.

| # | Plan | Severity | Status |
|---|---|---|---|
| 001 | [Keep Library mounted and make the surface switch light](001-mounted-library-light-surface-switch.md) | HIGH | DONE |
| 002 | [Lyrics open on the current line; lighter lyrics swap](002-lyrics-open-on-current-line.md) | MEDIUM | DONE |
| 003 | [Resize the crawling cover without rebuilding its motion](003-crawling-cover-cheap-resize.md) | HIGH | TODO |
| 004 | [With Reduce Motion, fade instead of cutting](004-reduce-motion-fades-not-cuts.md) | HIGH | DONE |
| 005 | [Feel polish: like star, mini-player extras, shelf cards, cover dip](005-feel-polish.md) | MEDIUM | TODO |

**Order and dependencies:** 001 → 004 → 002 touch `Motion.swift`, `RootView.swift` and `LyricsView.swift` and run in that order (004 needs 001's `SurfaceTransition(still:)`). 003 and 005 touch other files and can run in parallel with them.

**Not planned yet (from the audit, lower leverage):**
- Back (⌘[) replays the page's section reveal because `.id(navigator.current)` makes a new reveal ledger; the page container crossfades the old and new pages over each other.
- The lyric pill (`matchedGeometryEffect`, ease-out 0.3) and the list scroll (ease-in-out 0.35) may drift apart mid-glide — needs a 0.25× screen recording to confirm.
- Lyric rows keep per-row blur and a 12 pt glow inside panels whose opacity animates; GPU frame time during a surface switch was never measured.
- Starting audio analysis exactly as Now Playing opens (`FloeApp.swift:47`) — could wait for the transition to settle.
- One-off timings outside `FloeMotion` (0.45 s ×5, lyric-row hover/press copies that drifted from the tokens).
- Missed opportunities: onboarding steps cut with no motion; the live background and visualizer strip pop in/out when toggled; changing sort order teleports rows.
