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
    @ViewState private var section = Section.visualizer
    @Environment(AppSettings.self) private var settings
    @Environment(VisualSettings.self) private var visuals
    @Environment(PlayerModel.self) private var player
    @AppStorage("accentFromCover") private var accentFromCover = false
    @AppStorage("reduceMotion") private var reduceMotion = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Floe").font(.system(size: 22, weight: .bold)).padding(.bottom, 20)
                ForEach(Section.allCases) { item in
                    Button { section = item } label: {
                        Label(LocalizedStringKey(item.rawValue), systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(section == item ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(20).frame(width: 180).background(.white.opacity(0.025))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(LocalizedStringKey(section.rawValue)).font(.system(size: 26, weight: .bold))
                    contents
                }.frame(maxWidth: .infinity, alignment: .leading).padding(30)
            }
        }
        .frame(width: 740, height: 580)
        .background(Theme.base).preferredColorScheme(.dark)
    }

    @ViewBuilder private var contents: some View {
        @Bindable var visuals = visuals
        switch section {
        case .visualizer:
            VisualizerOptions()
            note("Visual only. Audio is sampled about 30 times per second while Floe is active. Playback volume is unchanged.")
        case .background:
            BackgroundOptions()
            HStack { Text("Blur"); Slider(value: $visuals.backgroundBlur, in: 0...18) }
            note("Blur is applied once to each cover. Live backgrounds use extra energy and stop on pause or with Reduce Motion.")
        case .playback:
            playbackOptions
        case .downloads:
            Label("Streaming only", systemImage: "wifi").font(.headline)
            note("Offline downloads are unavailable. Floe does not save audio to disk.")
        case .appearance:
            appearanceOptions
        case .about:
            aboutContent
        }
    }

    @ViewBuilder private var playbackOptions: some View {
        @Bindable var settings = settings
        Picker("Streaming quality", selection: $settings.bitrate) {
            ForEach(PlaybackConfiguration.supportedBitrates, id: \.self) { bitrate in
                let title = "\(bitrate) kbps"
                Text(LocalizedStringKey(title)).tag(bitrate)
            }
        }
        Toggle("Normalize volume", isOn: $settings.normalization)
        Toggle("Gapless playback", isOn: $settings.gapless)
        if player.activeConfiguration != settings.playbackConfiguration {
            Text("Playback changes apply after reconnecting or restarting Floe.").font(.callout).foregroundStyle(.orange)
            Button("Apply and reconnect") { player.reconnectPlayback() }.disabled(!player.isConnected)
            note("Reconnecting keeps the current song and position. Manually queued songs may be reset.")
        }
        HStack { Text("Crossfade"); Spacer(); Text("Unavailable").foregroundStyle(Theme.secondary) }
        note("This playback engine supports gapless playback but does not support crossfade.")
    }

    @ViewBuilder private var appearanceOptions: some View {
        @Bindable var settings = settings
        Toggle("Accent from cover", isOn: $accentFromCover)
        Picker("Fixed accent", selection: $settings.fixedAccent) {
            Text("Green").tag("green"); Text("Blue").tag("blue")
            Text("Violet").tag("violet"); Text("Amber").tag("amber")
        }.disabled(accentFromCover)
        HStack { Text("Glass intensity"); Slider(value: $settings.glassOpacity, in: AppSettings.glassOpacityRange) }
        Toggle("Reduce motion", isOn: $reduceMotion)
        note("The Mac's Reduce Motion setting is always respected.")
        Picker("Language", selection: $settings.language) {
            Text("System").tag("system"); Text("English").tag("en"); Text("Українська").tag("uk")
        }
        note("Song titles, artist names and lyrics stay in their original language.")
    }

    @ViewBuilder private var aboutContent: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text("Floe").font(.system(size: 24, weight: .bold))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                    .font(.callout).foregroundStyle(Theme.secondary)
            }
        }
        note("A native Spotify client for macOS. Spotify Premium is required. Not affiliated with Spotify.")
        Link("Playback engine: librespot", destination: URL(string: "https://github.com/librespot-org/librespot")!)
        Link("Lyrics: LRCLIB", destination: URL(string: "https://lrclib.net")!)
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.callout).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
