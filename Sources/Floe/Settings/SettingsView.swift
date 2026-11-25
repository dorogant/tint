import SwiftUI

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case visualizer = "Visualizer", background = "Background", playback = "Playback"
        case downloads = "Downloads", appearance = "Appearance", account = "Account", about = "About"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .visualizer: "waveform"
            case .background: "sparkles"
            case .playback: "play.circle"
            case .downloads: "arrow.down.circle"
            case .appearance: "paintpalette"
            case .account: "person.crop.circle"
            case .about: "info.circle"
            }
        }
        var summary: LocalizedStringKey {
            switch self {
            case .visualizer: "Make the music visible."
            case .background: "Set the atmosphere behind your music."
            case .playback: "Choose how your music sounds and flows."
            case .downloads: "Your music streams directly from Spotify."
            case .appearance: "Make Tint feel like yours."
            case .account: "How Tint signs in to Spotify."
            case .about: "A small, native home for your music."
            }
        }
    }
    @AppStorage("settingsSection") private var section = Section.visualizer
    @Environment(AppSettings.self) private var settings
    @Environment(VisualSettings.self) private var visuals
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @AppStorage("accentFromCover") private var accentFromCover = false
    @AppStorage("reduceMotion") private var reduceMotion = false
    @Environment(\.coverPalette) private var palette

    /// A native sidebar keeps every category readable, including longer translations.
    var body: some View {
        NavigationSplitView {
            List(selection: Binding<Section?>(get: { section }, set: { if let value = $0 { section = value } })) {
                ForEach(Section.allCases) { item in
                    Label(L10n.string(String.LocalizationValue(item.rawValue)), systemImage: item.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.vertical, 5)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Tint")
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 230)
        } detail: {
            ZStack {
                VStack(spacing: 0) {
                    sectionHeader
                    Form { contents(section) }
                        .formStyle(.grouped)
                        .scrollContentBackground(.hidden)
                }
                // At once, as System Settings does: arrow keys move through the list.
                .id(section)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.base)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(palette.highlight)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 600)
        .preferredColorScheme(.dark)
    }

    private var sectionHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: section.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(palette.highlight)
                .frame(width: 48, height: 48)
                .background(palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(String.LocalizationValue(section.rawValue)))
                    .font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(section.summary).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    @ViewBuilder private func contents(_ section: Section) -> some View {
        @Bindable var visuals = visuals
        switch section {
        case .visualizer:
            SwiftUI.Section {
                VisualizerOptions()
            } header: {
                Text("Display")
            } footer: {
                note("Visual only. Audio is sampled about 30 times per second while Tint is active. Playback volume is unchanged.")
            }
        case .background:
            SwiftUI.Section {
                BackgroundOptions()
            } header: {
                Text("Motion")
            } footer: {
                note("Each kind splits the music into layers. Beams: kicks punch the outer beams, hi-hats light the middle ones, vocals fill the haze with color, and sweeps turn on the beat. Fluid swirls the cover's colors like ink and breathes with the bass. Bass punch sets how hard kicks move the light. The strobe never flashes more than three times a second.")
            }
            SwiftUI.Section {
                SettingsSlider("Blur", value: $visuals.backgroundBlur, range: 0...18,
                               displayedValue: Text("\(Int(visuals.backgroundBlur))"))
            } header: {
                Text("Cover backdrop")
            } footer: {
                note("Blur is applied once to each cover. Live backgrounds use extra energy and stop on pause or with Reduce Motion.")
            }
        case .playback:
            playbackOptions
        case .downloads:
            SwiftUI.Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "wifi").font(.title2).foregroundStyle(palette.highlight)
                    settingLabel("Streaming only", detail: "Offline downloads are unavailable. Tint does not save audio to disk.")
                }.padding(.vertical, 8)
            }
        case .appearance:
            appearanceOptions
        case .account:
            accountContent
        case .about:
            aboutContent
        }
    }

    @ViewBuilder private var playbackOptions: some View {
        @Bindable var settings = settings
        SwiftUI.Section {
            Picker("Playback engine", selection: $settings.engine) {
                Text("Spotify Soloist (Recommended)").tag(PlaybackEngine.soloist)
                Text("librespot (Legacy)").tag(PlaybackEngine.librespot)
            }.pickerStyle(.menu)
        } header: {
            Text("Engine")
        } footer: {
            note(settings.engine == .soloist
                 ? "Spotify Soloist is Spotify's official headless client. It works on every Premium account and manages lossless quality, normalization, gapless playback and crossfade natively."
                 : "librespot is an unofficial Rust client. Spotify only issues audio keys for older accounts that used it previously.")
        }
        if settings.engine == .soloist {
            SoloistSettingsSection()
        } else {
            SwiftUI.Section {
                Picker("Streaming quality", selection: $settings.bitrate) {
                    ForEach(PlaybackConfiguration.supportedBitrates, id: \.self) { bitrate in
                        let title = "\(bitrate) kbps"
                        Text(LocalizedStringKey(title)).tag(bitrate)
                    }
                }.pickerStyle(.menu)
                Toggle(isOn: $settings.normalization) {
                    settingLabel("Normalize volume", detail: "Keep loud and quiet tracks at a similar volume.")
                }
            } header: {
                Text("Audio")
            } footer: {
                note("320 kbps is librespot's highest streaming quality. Lossless is unavailable in librespot.")
            }
            SwiftUI.Section {
                Toggle(isOn: $settings.gapless) {
                    settingLabel("Gapless playback", detail: "Let consecutive tracks play without a gap.")
                }
                LabeledContent("Crossfade") { Text("Unavailable") }
            } header: {
                Text("Transitions")
            } footer: {
                note("librespot supports gapless playback but does not support crossfade.")
            }
            if player.activeConfiguration != settings.playbackConfiguration {
                SwiftUI.Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Changes waiting to apply", systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline).foregroundStyle(palette.highlight)
                        note("Playback changes apply after reconnecting or restarting Tint.")
                        Button("Apply and reconnect") { player.reconnectPlayback() }
                            .buttonStyle(.borderedProminent).disabled(!player.isConnected)
                    }.padding(.vertical, 4)
                } footer: {
                    note("Reconnecting keeps the current song and position. Manually queued songs may be reset.")
                }
            }
        }
    }

    @ViewBuilder private var appearanceOptions: some View {
        @Bindable var settings = settings
        SwiftUI.Section("Accent") {
            Toggle("Accent from cover", isOn: $accentFromCover)
            Picker("Fixed accent", selection: $settings.fixedAccent) {
                Text("Green").tag("green"); Text("Blue").tag("blue")
                Text("Violet").tag("violet"); Text("Amber").tag("amber")
            }.pickerStyle(.segmented).disabled(accentFromCover)
        }
        SwiftUI.Section {
            Picker("Interface size", selection: $settings.interfaceSize) {
                Text("Compact").tag(InterfaceSize.compact)
                Text("Standard").tag(InterfaceSize.standard)
                Text("Large").tag(InterfaceSize.large)
            }.pickerStyle(.segmented)
        } header: {
            Text("Size")
        } footer: {
            note("Sets the size of text, artwork and spacing in the main window.")
        }
        SwiftUI.Section {
            SettingsSlider("Glass intensity", value: $settings.glassOpacity, range: AppSettings.glassOpacityRange,
                           displayedValue: Text("\(Int(settings.glassOpacity * 100))%"))
            Toggle("Reduce motion", isOn: $reduceMotion)
        } header: {
            Text("Interface")
        } footer: {
            note("The Mac's Reduce Motion setting is always respected.")
        }
        SwiftUI.Section {
            Picker("Language", selection: $settings.language) {
                Text("System").tag("system"); Text("English").tag("en"); Text("Українська").tag("uk")
            }.pickerStyle(.menu)
        } header: {
            Text("Language")
        } footer: {
            note("Song titles, artist names and lyrics stay in their original language.")
        }
        SwiftUI.Section {
            if library.hiddenArtists.isEmpty {
                Text("No hidden artists").foregroundStyle(.secondary)
            }
            ForEach(library.hiddenArtists) { artist in
                LabeledContent(artist.name) {
                    Button("Show") { library.unhide(artist) }
                }
            }
        } header: {
            Text("Hidden artists")
        } footer: {
            note("To hide an artist from Your top artists on Home, Control-click it. Spotify's own ranking doesn't change.")
        }
    }

    @ViewBuilder private var aboutContent: some View {
        SwiftUI.Section {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tint").font(.title2.bold())
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            note("A native Spotify client for macOS. Spotify Premium is required. Not affiliated with Spotify.")
        }
        SwiftUI.Section {
            Link("Playback engine: Spotify Soloist", destination: URL(string: "https://developer.spotify.com/documentation/soloist")!)
            Link("Legacy engine: librespot", destination: URL(string: "https://github.com/librespot-org/librespot")!)
            Link("Lyrics: LRCLIB", destination: URL(string: "https://lrclib.net")!)
        }
    }

    @ViewBuilder private var accountContent: some View {
        SwiftUI.Section {
            LabeledContent("Library") {
                if library.connection == .connected {
                    Text(verbatim: library.profile?.displayName ?? L10n.string("Connected"))
                } else {
                    Text("Not connected")
                }
            }
            if library.connection == .connected {
                Button("Disconnect Library") { Task { await library.disconnect() } }
            }
        } header: {
            Text("Spotify")
        } footer: {
            note("Playback signs in with Spotify's own app. Your library goes through a Spotify developer app.")
        }
        DeveloperAppSettings()
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func settingLabel(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 3)
    }
}

private struct SettingsLabelWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}
extension EnvironmentValues {
    /// A minimum label width for slider and stepper rows outside a `Form`, so
    /// stacked sliders start in one column.
    var settingsLabelWidth: CGFloat? {
        get { self[SettingsLabelWidthKey.self] }
        set { self[SettingsLabelWidthKey.self] = newValue }
    }
}

/// Native slider with a stable readout and an explicit VoiceOver name/value.
/// Its label dims with the slider, as a toggle's does.
struct SettingsSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let displayedValue: Text
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsLabelWidth) private var labelWidth

    init(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, displayedValue: Text) {
        self.title = title
        _value = value
        self.range = range
        self.displayedValue = displayedValue
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                Slider(value: $value, in: range).labelsHidden()
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(displayedValue)
                displayedValue.monospacedDigit().foregroundStyle(isEnabled ? .secondary : .tertiary)
                    .frame(width: 46, alignment: .trailing)
                    .accessibilityHidden(true)
            }.frame(maxWidth: 280)
        } label: {
            Text(title).foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(minWidth: labelWidth, alignment: .leading)
        }
    }
}

/// A small count with a stepper, laid out and dimmed like `SettingsSlider`.
struct SettingsStepper: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: LocalizedStringKey, value: Binding<Int>, range: ClosedRange<Int>) {
        self.title = title
        _value = value
        self.range = range
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text("\(value)").monospacedDigit().foregroundStyle(isEnabled ? .secondary : .tertiary)
                    .accessibilityHidden(true)
                Stepper(title, value: $value, in: range).labelsHidden()
                    .accessibilityValue(Text("\(value)"))
            }.frame(maxWidth: .infinity, alignment: .trailing)
        } label: {
            Text(title).foregroundStyle(isEnabled ? .primary : .tertiary)
        }
    }
}

/// Which Spotify developer app the library signs in through (see `SpotifyClientID`).
/// Tokens belong to the app that issued them, so switching disconnects the library.
private struct DeveloperAppSettings: View {
    @Environment(LibraryModel.self) private var library
    /// Mirrors `SpotifyClientID.defaultsKey`, so the section follows changes.
    @AppStorage(SpotifyClientID.defaultsKey) private var customID = ""
    @ViewState private var draft = ""

    var body: some View {
        SwiftUI.Section {
            LabeledContent("Client ID") {
                if let current = SpotifyClientID.valid(customID) ?? SpotifyClientID.builtIn {
                    Text(verbatim: current).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                } else {
                    Text("None")
                }
            }
            LabeledContent("Redirect URI") {
                HStack(spacing: 8) {
                    Text(verbatim: SpotifyOAuth.Config.webAPIRedirectURI.absoluteString)
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    CopyButton(text: SpotifyOAuth.Config.webAPIRedirectURI.absoluteString)
                }
            }
            HStack {
                TextField("Another Client ID", text: $draft)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit(use)
                Button("Use", action: use).disabled(SpotifyClientID.valid(draft) == nil)
            }
            if SpotifyClientID.valid(customID) != nil, SpotifyClientID.builtIn != nil {
                Button("Use the Built-in App") { switchApp(to: nil) }
            }
        } header: {
            Text("Developer app")
        } footer: {
            note
        }
    }

    private var note: some View {
        let source: LocalizedStringKey = SpotifyClientID.valid(customID) != nil
            ? "This is your own app." : SpotifyClientID.builtIn != nil
            ? "This app is built into this copy of Tint." : "No app yet: Tint asks for one when you connect your library."
        return VStack(alignment: .leading, spacing: 4) {
            Text(source)
            Text("Changing the app disconnects your library; connect it again in the main window.")
        }
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func use() {
        guard let id = SpotifyClientID.valid(draft) else { return }
        draft = ""
        switchApp(to: id)
    }

    private func switchApp(to id: String?) {
        SpotifyClientID.setCustom(id)
        Task { await library.disconnect() }
    }
}

/// Spotify Soloist binary status, Homebrew install/update, and API key management.
private struct SoloistSettingsSection: View {
    @Environment(PlayerModel.self) private var player
    @ViewState private var binaryPath = SoloistBackend.findBinary()?.path
    @ViewState private var versionText: String?
    @ViewState private var keyDraft = ""
    @ViewState private var busy = false
    @ViewState private var errorMessage: String?

    init() {}

    var body: some View {
        SwiftUI.Section {
            LabeledContent("Binary") {
                if let binaryPath {
                    Text(verbatim: versionText ?? binaryPath)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Not installed").foregroundStyle(.orange)
                }
            }
            HStack(spacing: 10) {
                if SoloistBackend.findHomebrew() != nil {
                    Button(busy ? "Working…" : (binaryPath == nil ? "Install with Homebrew" : "Update with Homebrew")) {
                        runBrew(upgrade: binaryPath != nil)
                    }
                    .disabled(busy)
                }
                Link("Spotify Soloist Downloads", destination: SoloistBackend.downloadsURL)
            }
            HStack {
                SecureField("New Soloist API Key", text: $keyDraft)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit(saveKey)
                Button("Save & Connect", action: saveKey)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || binaryPath == nil)
            }
            if player.isConnected {
                Button("Reconnect Soloist") { player.reconnectPlayback() }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Spotify Soloist")
        } footer: {
            Text("Soloist builds expire after 90 days; use Update with Homebrew or download a fresh build from Spotify when prompted. Audio visualization uses macOS System Audio Recording permission to tap Soloist's audio.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task {
            binaryPath = SoloistBackend.findBinary()?.path
            versionText = await SoloistBackend.installedVersion()
        }
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keyDraft = ""
        player.connectSoloist(apiKey: trimmed)
    }

    private func runBrew(upgrade: Bool) {
        busy = true
        errorMessage = nil
        Task {
            let result = await SoloistBackend.installViaHomebrew(upgrade: upgrade)
            busy = false
            switch result {
            case let .success(url):
                binaryPath = url.path
                versionText = await SoloistBackend.installedVersion()
                if player.isConnected { player.reconnectPlayback() }
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
