# 006 — Back and keyboard navigation land at once

- **Status**: TODO
- **Commit**: 95ea037
- **Severity**: MEDIUM
- **Category**: Purpose & frequency
- **Estimated scope**: 4 files, ~35 lines

## Problem

Every change of page in the Library crossfades the old page into the new one and
replays the new page's section entrance:

```swift
// Sources/Floe/Views/RootView.swift — MainView.libraryPanel, current
                .padding(.top, 1)
                .id(navigator.current)
                // A fade only: the page's sections rise in on their own
                // (`reveal`), and moving the scroll view itself left it
                // resting a few points scrolled, off the page's guides.
                .transition(.opacity)
            }
            // Shelves scroll to the panel's edge; keep them inside its corners.
            .clipShape(RoundedRectangle(cornerRadius: scale.corner, style: .continuous))
            .glassPanel()
            .floeAnimation(value: navigator.current)
```

`floeAnimation` is a 0.24 s spring. `.id(navigator.current)` builds the page anew, so
its `revealScope()` gets an empty ledger and every `.reveal(…)` section fades up
again (`FloeMotion.reveal`: 0.42 s spring, 30 ms stagger per section,
`Sources/Floe/Views/Motion.swift`, `private struct Reveal`).

That is right for a click on a link or a sidebar row: the page is new. It is wrong for:

1. **Back** (the toolbar button and ⌘[): the user returns to a page they just left.
   Seeing it "arrive" again for half a second reads as the app reloading it.
2. **Keyboard-initiated navigation**: ⌘[ and ⌘F / typing in the search field
   (`Navigator.showSearch()`). Keyboard actions get no animation.

The Settings window has the same fault on a smaller scale:

```swift
// Sources/Floe/Settings/SettingsView.swift:55-67 — current
            ZStack {
                VStack(spacing: 0) {
                    sectionHeader
                    Form { contents(section) }
                        .formStyle(.grouped)
                        .scrollContentBackground(.hidden)
                }
                .id(section)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.base)
            .floeAnimation(value: section, duration: 0.18)
```

Moving through the sidebar list with the arrow keys crossfades two whole forms over
each other for 0.18 s per key press. System Settings switches panes at once.

## Target

### a) The navigator says how it arrived

```swift
// Sources/Floe/Library/Navigator.swift — add inside `final class Navigator`
    /// How the current page was reached. A page opened by a click is new and
    /// makes an entrance; one returned to (Back) or reached from the keyboard
    /// (search) is simply there.
    enum Arrival { case fresh, instant }
    /// Set before the stack changes, so the view that sees the new page sees this too.
    @ObservationIgnored private(set) var arrival = Arrival.fresh
```

Set it as the first statement of each method that changes `stack`:

| Method | Value |
|---|---|
| `select(_:)`, in the `else` branch (`stack = [route]`) | `arrival = .fresh` |
| `push(_:)` | `arrival = .fresh` |
| `back()` | `arrival = .instant` |
| `showSearch()` | `arrival = .instant` |
| `closeSearch()` | `arrival = .instant` |

### b) The page neither crossfades nor replays its entrance on an instant arrival

```swift
// Sources/Floe/Views/RootView.swift — MainView.libraryPanel, target
// (`still` is MainView's existing `@ReducedMotion private var still`)
                ScrollView {
                    page.padding(.horizontal, scale.gutter).padding(.top, scale.gutter - 1).padding(.bottom, scale(32))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.revealsAtOnce, navigator.arrival == .instant)
                }
                …unchanged…
            .glassPanel()
            .animation(navigator.arrival == .instant ? nil : (still ? FloeMotion.fade : .spring(duration: 0.24, bounce: 0)),
                       value: navigator.current)
```

(The last line replaces `.floeAnimation(value: navigator.current)`; 0.24 s and no
bounce are `floeAnimation`'s defaults, written out because the animation is now conditional.)

```swift
// Sources/Floe/Views/Motion.swift — next to `RevealLedgerKey`
private struct RevealsAtOnceKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {
    /// Set on a page that was returned to: its sections show without their entrance.
    var revealsAtOnce: Bool {
        get { self[RevealsAtOnceKey.self] }
        set { self[RevealsAtOnceKey.self] = newValue }
    }
}
```

```swift
// Sources/Floe/Views/Motion.swift — `private struct Reveal`, target
    @Environment(\.revealLedger) private var ledger
    @Environment(\.revealsAtOnce) private var atOnce
    @ReducedMotion private var reduceMotion
    @ViewState private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || atOnce || ledger?.contains(key) == true
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 10)
            .onAppear {
                if atOnce, !shown {
                    // Keep it shown if the flag changes while this page is up.
                    ledger?.claim(key)
                    shown = true
                    return
                }
                guard !visible else { return }
                ledger?.claim(key)
                let animation = reduceMotion ? FloeMotion.fade : FloeMotion.reveal.delay(FloeMotion.stagger(order))
                withAnimation(animation) { shown = true }
            }
    }
```

### c) Settings panes switch at once

In `Sources/Floe/Settings/SettingsView.swift` delete the two lines
`.transition(.opacity)` (after `.id(section)`) and
`.floeAnimation(value: section, duration: 0.18)`. Keep `.id(section)`: it resets the
form's scroll position per pane.

## Repo conventions to follow

- Environment keys in `Motion.swift` follow `RevealLedgerKey` / `HeroNamespaceKey`
  (a private `EnvironmentKey` struct and a computed property on `EnvironmentValues`).
- `@State` is spelled `@ViewState` in this repo (no Xcode macro plugin).
- State that views must not observe is `@ObservationIgnored` (see `searchFocusHandled`
  in `Navigator.swift`).
- Reduce Motion: `still ? FloeMotion.fade : <moving animation>`; never `nil` for a
  pointer-driven change (plan 004).

## Steps

1. `Navigator.swift`: add `Arrival` and `arrival`; set it in the five methods as in the table.
2. `Motion.swift`: add `RevealsAtOnceKey` and `revealsAtOnce`; change `Reveal` as shown.
3. `RootView.swift`: add the `.environment(\.revealsAtOnce, …)` line on `page…` inside the
   `ScrollView`; replace `.floeAnimation(value: navigator.current)` with the conditional `.animation`.
4. `SettingsView.swift`: delete the two lines in (c).
5. `swift build -c release --product Floe`.

## Boundaries

- Do NOT change `FloeMotion` tokens, the `reveal` API or any page's `.reveal(…)` calls.
- Do NOT touch the Library ↔ Now Playing ↔ Lyrics switch (`navigator.surface`), which
  has its own animation in the same file.
- Do NOT make sidebar clicks or link clicks instant; only the five methods in the table.
- If the code doesn't match these excerpts, STOP and report.

## Verification

- **Mechanical**: `swift build -c release --product Floe` succeeds; `scripts/test-layout.sh`
  passes (it navigates with `navigator.select` and checks the pages' resting positions).
- **Feel check** (in the running app, by the owner):
  - Open a playlist from Home, then press ⌘[: Home is there at once, no fade, no sections rising.
  - Click the toolbar's Back button: same.
  - Click a playlist in the sidebar: the page still crossfades and its header, tools and list rise in.
  - Press ⌘F and type: results appear without a crossfade from the previous page.
  - Settings: arrow up and down through the sidebar; each pane is there on the key press.
  - With Reduce Motion on, a sidebar click still fades (0.18 s) and nothing moves.
- **Done when**: the build and layout test pass and Back shows no entrance.
