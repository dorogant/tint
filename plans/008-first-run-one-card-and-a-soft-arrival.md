# 008 — First run: one sign-in card that carries through, and a soft arrival

- **Status**: DONE (2026-11-11; the feel checks are still the owner's to do)
- **Commit**: 95ea037
- **Severity**: MEDIUM
- **Category**: Missed opportunities (preventing a jarring change; first-run delight)
- **Estimated scope**: 2 files, ~45 lines

## Problem

The window's root swaps between five things with no transition:

```swift
// Sources/Floe/Views/RootView.swift:10-29 — current
        ZStack {
            Backdrop()
            if !player.hasConnected {
                if player.session == .connecting {
                    ProgressView("Connecting to Spotify…").controlSize(.small)
                } else if player.hasCheckedStoredSession {
                    OnboardingView(step: .playback)
                }
                // Else the saved login is still being read: only the backdrop for that moment.
            } else if library.connection != .connected {
                if library.connection == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    OnboardingView(step: .library)
                }
            } else {
                MainView()
            }
        }
```

1. **Every launch**: the small "Connecting to Spotify…" spinner is replaced by the whole
   main window in one frame.
2. **First run** (the only time anyone sees onboarding): after the browser approves
   step 1, the card disappears for a spinner (`session == .connecting`), then for
   another spinner (`library.connection == .checking`), and then a *different* card
   appears for step 2. `OnboardingView(step: .playback)` and `OnboardingView(step: .library)`
   are two views in two branches, so nothing can animate between them: step 1's
   number becomes a tick with no motion at all.

The card already knows how to look busy, so it never needed to leave:

```swift
// Sources/Floe/Views/OnboardingView.swift:30-32 — current
            stepRow(number: 1, title: "Playback", detail: "Lets Tint stream music as a Spotify Connect device.",
                    done: step == .library, busy: player.session == .authorizing || player.session == .connecting,
                    error: playbackError, action: player.logIn)
```

```swift
// Sources/Floe/Views/OnboardingView.swift:129-136 — current (inside stepRow)
            ZStack {
                Circle().fill(done ? palette.accent : .white.opacity(0.1)).frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .bold))
                }
            }
```

## Target

### a) One card, kept up from the moment it shows until both logins exist

```swift
// Sources/Floe/Views/RootView.swift — RootView, target
struct RootView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(\.interfaceScale) private var scale
    @ReducedMotion private var still
    /// Set once the sign-in card has shown: from then on it stays up, looking
    /// busy, instead of giving way to a spinner between its two steps.
    @ViewState private var signingIn = false

    private enum Phase: Equatable { case blank, waiting, onboarding, main }

    private var phase: Phase {
        if !player.hasConnected {
            if signingIn { return .onboarding }
            if player.session == .connecting { return .waiting }
            return player.hasCheckedStoredSession ? .onboarding : .blank
        }
        if library.connection != .connected {
            if signingIn { return .onboarding }
            return library.connection == .checking ? .waiting : .onboarding
        }
        return .main
    }

    var body: some View {
        ZStack {
            Backdrop()
            switch phase {
            case .blank:
                EmptyView()
            case .waiting:
                ProgressView("Connecting to Spotify…").controlSize(.small)
                    .transition(.opacity)
            case .onboarding:
                OnboardingView(step: player.hasConnected ? .library : .playback)
                    .onAppear { signingIn = true }
                    .transition(still ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            case .main:
                MainView()
                    .transition(.opacity)
            }
        }
        // The app arriving, on the spring the surfaces move on (0.32 s, no bounce).
        .animation(still ? FloeMotion.fade : FloeMotion.surface, value: phase)
        .preferredColorScheme(.dark)
        .frame(minWidth: scale(940), minHeight: scale(600))
    }
}
```

Notes for the executor:
- `OnboardingView` is now one call site, so SwiftUI keeps it (and its `@ViewState`)
  when `step` changes from `.playback` to `.library`.
- A returning user never sees the card: `signingIn` stays false, so launch goes
  `.blank` → `.waiting` → `.main`.
- `MainView` only fades. Its pages make their own entrance (`reveal`), and scaling a
  view that owns the window toolbar isn't worth the risk.

### b) Step 2 looks busy while the library is being checked

```swift
// Sources/Floe/Views/OnboardingView.swift — step 2's row, target (one argument changes)
                        done: false, busy: library.connection == .connecting || library.connection == .checking,
```

Otherwise step 2 shows an enabled Connect button for the instant between step 1
finishing and the stored library login being found.

### c) The step's tick arrives (first run only, so a little bounce is allowed)

```swift
// Sources/Floe/Views/OnboardingView.swift — inside stepRow, target
            ZStack {
                Circle().fill(done ? palette.accent : .white.opacity(0.1)).frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                        .transition(still ? .opacity : .opacity.combined(with: .scale(scale: 0.5)))
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .bold))
                        .transition(.opacity)
                }
            }
            .animation(still ? FloeMotion.fade : .spring(duration: 0.4, bounce: 0.3), value: done)
```

Add `@ReducedMotion private var still` to `OnboardingView`'s properties.

Also animate the trailing control swapping between Connect, the spinner and nothing:
on the `HStack` that `stepRow` returns, add
`.animation(FloeMotion.fade, value: busy)` (0.18 s ease-out; opacity only, so it is
the same with Reduce Motion).

## Repo conventions to follow

- `@ViewState` instead of `@State`; `@ReducedMotion private var still` for Reduce Motion
  (`Sources/Floe/Views/Motion.swift`).
- Surfaces arrive on `FloeMotion.surface`; Reduce Motion falls back to `FloeMotion.fade`.
  Exemplar: `MainView`'s `.animation(still ? FloeMotion.fade : FloeMotion.surface, value: navigator.surface)`
  in the same file.
- Never enter from scale 0: 0.97 for the card, 0.5 for the 12 pt tick (small enough
  that anything nearer 1 doesn't read as arriving).

## Steps

1. `RootView.swift`: replace `RootView`'s properties and `body` with the target in (a).
2. `OnboardingView.swift`: change step 2's `busy:` argument (b).
3. `OnboardingView.swift`: add `@ReducedMotion private var still`; change the `ZStack` in
   `stepRow` and add the two `.animation` modifiers (c).
4. `swift build -c release --product Floe`.

## Boundaries

- Do NOT change `PlayerModel` or `LibraryModel`; `hasCheckedStoredSession` already exists.
- Do NOT change `MainView` or anything below it.
- Do NOT add a welcome animation, confetti or a delay before the app shows.
- If the code doesn't match these excerpts, STOP and report.

## Verification

- **Mechanical**: the build succeeds; `scripts/test-layout.sh` and
  `scripts/benchmark-scroll.sh` still build (they host `MainView` directly, not `RootView`).
- **Feel check** (owner; first run needs the saved logins moved aside, so only do it on request):
  - Normal launch: the spinner gives way to the window in a soft 0.3 s fade; the
    Welcome card never shows.
  - First run: press Connect on step 1, approve in the browser. The card stays; step 1
    shows its spinner, then its number becomes a tick with a small pop; step 2's
    button enables. Approve step 2: the card fades and shrinks 3% as the app fades in.
  - Cancel in the middle of step 2: the card is still there with step 2's Connect back.
  - Reduce Motion: every change above is a 0.18 s fade, nothing scales.
- **Done when**: the build passes and a normal launch fades in.
