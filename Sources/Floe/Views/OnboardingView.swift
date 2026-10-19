import AppKit
import SwiftUI

/// The two browser approvals Tint needs before the main window: playback (librespot,
/// Spotify's own client ID) and library (the Web API, through a developer app).
struct OnboardingView: View {
    @Environment(\.coverPalette) private var palette
    enum Step { case playback, library }

    let step: Step
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    /// The pasted Client ID; saved when Connect is pressed.
    @ViewState private var clientID = SpotifyClientID.custom ?? ""
    /// A build with its own client ID keeps the how-to folded away.
    @ViewState private var showsDeveloperApp = SpotifyClientID.builtIn == nil || SpotifyClientID.custom != nil
    @ViewState private var connecting: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(palette.accent)
                Text("Welcome to Tint").font(.system(size: 26, weight: .heavy))
            }
            Text("Spotify asks for two approvals, both in your browser. Tint never sees your password.")
                .foregroundStyle(Theme.secondary)

            stepRow(number: 1, title: "Playback", detail: "Lets Tint stream music as a Spotify Connect device.",
                    done: step == .library, busy: player.session == .authorizing || player.session == .connecting,
                    error: playbackError, action: player.logIn)
            VStack(alignment: .leading, spacing: 14) {
                stepRow(number: 2, title: "Library",
                        detail: "Lets Tint read your playlists, saved music and history through your developer app.",
                        done: false, busy: library.connection == .connecting,
                        error: libraryError, enabled: step == .library, actionEnabled: canConnectLibrary,
                        cancel: { connecting?.cancel() }, action: connectLibrary)
                if step == .library { developerApp }
            }
        }
        .padding(30)
        .frame(width: 520)
        .glassPanel(cornerRadius: 24)
        .floeAnimation(value: showsDeveloperApp)
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
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .bold))
                }
            }
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
