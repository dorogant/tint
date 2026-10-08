import SwiftUI

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case visualizer = "Visualizer", background = "Background", playback = "Playback"
        case downloads = "Downloads", appearance = "Appearance", about = "About"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .visualizer: "waveform"
            case .background: "sparkles"
            case .playback: "play.circle"
            case .downloads: "arrow.down.circle"
            case .appearance: "paintpalette"
            case .about: "info.circle"
            }
        }
    }
    @AppStorage("settingsSection") private var section = Section.visualizer
    @Environment(AppSettings.self) private var settings
    @Environment(VisualSettings.self) private var visuals
    @Environment(PlayerModel.self) private var player
    @AppStorage("accentFromCover") private var accentFromCover = false
    @AppStorage("reduceMotion") private var reduceMotion = false

    /// The standard Settings window: toolbar tabs over grouped forms.
    var body: some View {
        // Tab titles are resolved below, so re-render them when the language changes.
        let _ = settings.language
        TabView(selection: $section) {
            ForEach(Section.allCases) { item in
                Tab(value: item) {
                    Form { contents(item) }.formStyle(.grouped)
                } label: {
                    // Tabs are drawn by AppKit, so resolve them in the app's chosen language.
                    Label(L10n.string(String.LocalizationValue(item.rawValue)), systemImage: item.symbol)
                }
            }
        }
        .frame(width: 560, height: 470)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func contents(_ section: Section) -> some View {
        @Bindable var visuals = visuals
        switch section {
        case .visualizer:
            SwiftUI.Section {
                VisualizerOptions()
            } footer: {
                note("Visual only. Audio is sampled about 30 times per second while Floe is active. Playback volume is unchanged.")
            }
        case .background:
            SwiftUI.Section {
                BackgroundOptions()
                LabeledContent("Blur") { Slider(value: $visuals.backgroundBlur, in: 0...18).labelsHidden() }
            } footer: {
                note("Blur is applied once to each cover. Live backgrounds use extra energy and stop on pause or with Reduce Motion.")
            }
        case .playback:
            playbackOptions
        case .downloads:
            SwiftUI.Section {
                Label("Streaming only", systemImage: "wifi")
            } footer: {
                note("Offline downloads are unavailable. Floe does not save audio to disk.")
            }
        case .appearance:
            appearanceOptions
        case .about:
            aboutContent
        }
    }

    @ViewBuilder private var playbackOptions: some View {
        @Bindable var settings = settings
        SwiftUI.Section {
            Picker("Streaming quality", selection: $settings.bitrate) {
                ForEach(PlaybackConfiguration.supportedBitrates, id: \.self) { bitrate in
                    let title = "\(bitrate) kbps"
                    Text(LocalizedStringKey(title)).tag(bitrate)
                }
            }
            Toggle("Normalize volume", isOn: $settings.normalization)
            Toggle("Gapless playback", isOn: $settings.gapless)
            LabeledContent("Crossfade") { Text("Unavailable") }
        } footer: {
            note("This playback engine supports gapless playback but does not support crossfade.")
        }
        if player.activeConfiguration != settings.playbackConfiguration {
            SwiftUI.Section {
                Text("Playback changes apply after reconnecting or restarting Floe.").foregroundStyle(.orange)
                Button("Apply and reconnect") { player.reconnectPlayback() }.disabled(!player.isConnected)
            } footer: {
                note("Reconnecting keeps the current song and position. Manually queued songs may be reset.")
            }
        }
    }

    @ViewBuilder private var appearanceOptions: some View {
        @Bindable var settings = settings
        SwiftUI.Section {
            Toggle("Accent from cover", isOn: $accentFromCover)
            Picker("Fixed accent", selection: $settings.fixedAccent) {
                Text("Green").tag("green"); Text("Blue").tag("blue")
                Text("Violet").tag("violet"); Text("Amber").tag("amber")
            }.disabled(accentFromCover)
            LabeledContent("Glass intensity") {
                Slider(value: $settings.glassOpacity, in: AppSettings.glassOpacityRange).labelsHidden()
            }
        }
        SwiftUI.Section {
            Toggle("Reduce motion", isOn: $reduceMotion)
        } footer: {
            note("The Mac's Reduce Motion setting is always respected.")
        }
        SwiftUI.Section {
            Picker("Language", selection: $settings.language) {
                Text("System").tag("system"); Text("English").tag("en"); Text("Українська").tag("uk")
            }
        } footer: {
            note("Song titles, artist names and lyrics stay in their original language.")
        }
    }

    @ViewBuilder private var aboutContent: some View {
        SwiftUI.Section {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Floe").font(.title2.bold())
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            note("A native Spotify client for macOS. Spotify Premium is required. Not affiliated with Spotify.")
        }
        SwiftUI.Section {
            Link("Playback engine: librespot", destination: URL(string: "https://github.com/librespot-org/librespot")!)
            Link("Lyrics: LRCLIB", destination: URL(string: "https://lrclib.net")!)
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
