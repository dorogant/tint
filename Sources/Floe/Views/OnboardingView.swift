import AppKit
import SwiftUI

/// The two approvals Tint needs before the main window: playback (Spotify Soloist
/// by default, or optional librespot) and library (the Web API, through a developer app).
struct OnboardingView: View {
    @Environment(\.coverPalette) private var palette
    enum Step { case playback, library }

    let step: Step
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @ReducedMotion private var still
    /// The pasted Client ID; saved when Connect is pressed.
    @ViewState private var clientID = SpotifyClientID.custom ?? ""
    /// A build with its own client ID keeps the how-to folded away.
    @ViewState private var showsDeveloperApp = SpotifyClientID.builtIn == nil || SpotifyClientID.custom != nil
    @ViewState private var connecting: Task<Void, Never>?
    @ViewState private var soloistKey = ""
    @ViewState private var soloistInstalled = SoloistBackend.findBinary() != nil
    @ViewState private var installingSoloist = false
    @ViewState private var installError: String?

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(palette.accent)
                Text("Welcome to Tint").font(.system(size: 26, weight: .heavy))
            }
            Text(settings.engine == .soloist
                 ? "Tint plays audio through Spotify Soloist and reads your library through the Spotify Web API. Tint never sees your password."
                 : "Spotify asks for two approvals, both in your browser. Tint never sees your password.")
                .foregroundStyle(Theme.secondary)

            VStack(alignment: .leading, spacing: 14) {
                stepRow(number: 1, title: "Playback",
                        detail: settings.engine == .soloist
                            ? "Connects via Spotify Soloist (official engine, works on all Premium accounts)."
                            : "Lets Tint stream music via librespot (older Premium accounts only).",
                        done: step == .library,
                        busy: isPlaybackBusy,
                        error: playbackError,
                        actionEnabled: canConnectPlayback,
                        cancel: isAwaitingPairing ? { player.logOut() } : nil,
                        action: connectPlayback)
                if step == .playback { playbackSetup }
            }
            VStack(alignment: .leading, spacing: 14) {
                stepRow(number: 2, title: "Library",
                        detail: "Lets Tint read your playlists, saved music and history through your developer app.",
                        done: false, busy: library.connection == .connecting || library.connection == .checking,
                        error: libraryError, enabled: step == .library, actionEnabled: canConnectLibrary,
                        cancel: { connecting?.cancel() }, action: connectLibrary)
                if step == .library { developerApp }
            }
        }
        .padding(30)
        .frame(width: 540)
        .glassPanel(cornerRadius: 24)
        .floeAnimation(value: showsDeveloperApp)
        .floeAnimation(value: settings.engine)
        .floeAnimation(value: soloistInstalled)
        // Step 2's instructions open the card rather than replacing it.
        .floeAnimation(value: step)
        .onAppear { soloistInstalled = SoloistBackend.findBinary() != nil }
    }

    private var isAwaitingPairing: Bool {
        if case .awaitingPairing = player.session { true } else { false }
    }

    private var isPlaybackBusy: Bool {
        switch player.session {
        case .authorizing, .connecting, .awaitingPairing: true
        default: false
        }
    }

    private var trimmedSoloistKey: String { soloistKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canConnectPlayback: Bool {
        switch settings.engine {
        case .soloist: soloistInstalled && !trimmedSoloistKey.isEmpty
        case .librespot: true
        }
    }

    private func connectPlayback() {
        switch settings.engine {
        case .soloist: player.connectSoloist(apiKey: trimmedSoloistKey)
        case .librespot: player.logIn()
        }
    }

    @ViewBuilder private var playbackSetup: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 10) {
            if settings.engine == .soloist {
                if case let .awaitingPairing(deviceName) = player.session {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "hifispeaker.fill").foregroundStyle(palette.highlight)
                        Text("Open Spotify on your phone or computer and select \"\(deviceName)\" under Devices to finish pairing.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    if !soloistInstalled {
                        instruction(1, "Install Spotify Soloist (official macOS playback daemon):")
                        HStack(spacing: 8) {
                            if SoloistBackend.findHomebrew() != nil {
                                Button(installingSoloist ? "Installing…" : "Install with Homebrew") {
                                    installSoloist()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(palette.accent)
                                .disabled(installingSoloist)
                                .controlSize(.small)
                            }
                            Text(verbatim: SoloistBackend.homebrewCommand)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                            CopyButton(text: SoloistBackend.homebrewCommand)
                        }
                        .padding(.leading, 16)
                        HStack(spacing: 12) {
                            Link("Or download from Spotify", destination: SoloistBackend.downloadsURL)
                            Button("Check Again") { soloistInstalled = SoloistBackend.findBinary() != nil }
                                .buttonStyle(.link)
                        }
                        .padding(.leading, 16)
                        if let installError {
                            Text(installError).font(.system(size: 11.5)).foregroundStyle(.red)
                                .padding(.leading, 16)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Spotify Soloist is installed.")
                        }
                    }
                    instruction(2, "Open [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) → Spotify Soloist API Key, generate a key, and paste it here:")
                    SecureField("Soloist API Key", text: $soloistKey)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canConnectPlayback { connectPlayback() } }
                        .padding(.leading, 16)
                    Text("Then press Connect and pick \"Tint\" once in Spotify's Devices menu.")
                        .foregroundStyle(Theme.secondary)
                        .padding(.leading, 16)
                }
            }
            Picker("Engine", selection: $settings.engine) {
                Text("Spotify Soloist").tag(PlaybackEngine.soloist)
                Text("librespot (Legacy)").tag(PlaybackEngine.librespot)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.top, 2)
        }
        .font(.system(size: 12.5))
        .padding(.leading, 42)
    }

    private func installSoloist() {
        installingSoloist = true
        installError = nil
        Task {
            let result = await SoloistBackend.installViaHomebrew(upgrade: false)
            installingSoloist = false
            switch result {
            case .success:
                soloistInstalled = true
            case let .failure(error):
                installError = error.localizedDescription
            }
        }
    }

    private var playbackError: String? {
        if case let .failed(message) = player.session { message } else { nil }
    }

    private var libraryError: String? {
        if case let .failed(message) = library.connection { message } else { nil }
    }

    // MARK: - Developer app

    private var pastedClientID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Connect needs a valid pasted ID, or an empty field and one built in.
    private var canConnectLibrary: Bool {
        guard showsDeveloperApp else { return SpotifyClientID.current != nil }
        return pastedClientID.isEmpty ? SpotifyClientID.builtIn != nil : SpotifyClientID.valid(pastedClientID) != nil
    }

    private func connectLibrary() {
        if showsDeveloperApp { SpotifyClientID.setCustom(pastedClientID.isEmpty ? nil : pastedClientID) }
        connecting = Task { await library.connect() }
    }

    /// How to make a developer app of one's own. Spotify's Development Mode only lets
    /// accounts the app's owner added sign in, so a shared copy of Tint may need it.
    @ViewBuilder private var developerApp: some View {
        if showsDeveloperApp {
            VStack(alignment: .leading, spacing: 10) {
                instruction(1, "Open [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) and choose Create app. Any name and description will do.")
                VStack(alignment: .leading, spacing: 6) {
                    instruction(2, "Under Redirect URIs, add exactly this address:")
                    HStack(spacing: 8) {
                        Text(verbatim: SpotifyOAuth.Config.webAPIRedirectURI.absoluteString)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        CopyButton(text: SpotifyOAuth.Config.webAPIRedirectURI.absoluteString)
                    }
                    .padding(.leading, 16)
                }
                instruction(3, "Tick Web API, accept the terms and save.")
                VStack(alignment: .leading, spacing: 6) {
                    instruction(4, "Paste the Client ID from the app's Basic Information:")
                    TextField("Client ID", text: $clientID)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canConnectLibrary { connectLibrary() } }
                        .padding(.leading, 16)
                    if !pastedClientID.isEmpty && SpotifyClientID.valid(pastedClientID) == nil {
                        Text("A Client ID is 32 letters and digits.")
                            .foregroundStyle(.red)
                            .padding(.leading, 16)
                    }
                }
                Text("Only you and people you add under User Management can sign in through your app.")
                    .foregroundStyle(Theme.secondary)
            }
            .font(.system(size: 12.5))
            .padding(.leading, 42)
            .disabled(library.connection == .connecting)
            .transition(.opacity)
        } else {
            Button("Use your own Spotify developer app") { showsDeveloperApp = true }
                .buttonStyle(.link)
                .font(.system(size: 12.5))
                .padding(.leading, 42)
        }
    }

    private func instruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(number).").monospacedDigit().foregroundStyle(Theme.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Steps

    private func stepRow(number: Int, title: LocalizedStringKey, detail: LocalizedStringKey, done: Bool,
                         busy: Bool, error: String?, enabled: Bool = true, actionEnabled: Bool = true,
                         cancel: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
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
            // Seen once, on first run: the tick may arrive with a little bounce.
            .animation(still ? FloeMotion.fade : .spring(duration: 0.4, bounce: 0.3), value: done)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
                }
            }
            Spacer()
            if busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    // The browser may show an error and never come back (a wrong Client ID
                    // or redirect URI), so the wait can be called off.
                    if let cancel { Button("Cancel", action: cancel) }
                }
            } else if !done {
                Button(error == nil ? "Connect" : "Try Again", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .disabled(!enabled || !actionEnabled)
            }
        }
        .opacity(enabled || done ? 1 : 0.5)
        .animation(FloeMotion.fade, value: busy)
        .animation(FloeMotion.fade, value: enabled)
    }
}

/// Copies a short text, such as the redirect URI, and says so for a moment.
struct CopyButton: View {
    let text: String
    @ViewState private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .controlSize(.small)
        .floeState(value: copied)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
