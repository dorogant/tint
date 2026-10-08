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
        var summary: LocalizedStringKey {
            switch self {
            case .visualizer: "Make the music visible."
            case .background: "Set the atmosphere behind your music."
            case .playback: "Choose how your music sounds and flows."
            case .downloads: "Your music streams directly from Spotify."
            case .appearance: "Make Floe feel like yours."
            case .about: "A small, native home for your music."
            }
        }
    }
    @AppStorage("settingsSection") private var section = Section.visualizer
    @Environment(AppSettings.self) private var settings
    @Environment(VisualSettings.self) private var visuals
    @Environment(PlayerModel.self) private var player
    @AppStorage("accentFromCover") private var accentFromCover = false
    @AppStorage("reduceMotion") private var reduceMotion = false
    @Environment(\.coverPalette) private var palette

    /// A native sidebar keeps all six categories readable, including longer translations.
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
            .navigationTitle("Floe")
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 230)
        } detail: {
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
                note("Visual only. Audio is sampled about 30 times per second while Floe is active. Playback volume is unchanged.")
            }
        case .background:
            SwiftUI.Section("Motion") {
                BackgroundOptions()
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
                    settingLabel("Streaming only", detail: "Offline downloads are unavailable. Floe does not save audio to disk.")
                }.padding(.vertical, 8)
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
            }.pickerStyle(.menu)
            Toggle(isOn: $settings.normalization) {
                settingLabel("Normalize volume", detail: "Keep loud and quiet tracks at a similar volume.")
            }
        } header: {
            Text("Audio")
        } footer: {
            note("320 kbps is Floe's highest streaming quality. Lossless is unavailable in this playback engine.")
        }
        SwiftUI.Section {
            Toggle(isOn: $settings.gapless) {
                settingLabel("Gapless playback", detail: "Let consecutive tracks play without a gap.")
            }
            LabeledContent("Crossfade") { Text("Unavailable") }
        } header: {
            Text("Transitions")
        } footer: {
            note("This playback engine supports gapless playback but does not support crossfade.")
        }
        if player.activeConfiguration != settings.playbackConfiguration {
            SwiftUI.Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Changes waiting to apply", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline).foregroundStyle(palette.highlight)
                    note("Playback changes apply after reconnecting or restarting Floe.")
                    Button("Apply and reconnect") { player.reconnectPlayback() }
                        .buttonStyle(.borderedProminent).disabled(!player.isConnected)
                }.padding(.vertical, 4)
            } footer: {
                note("Reconnecting keeps the current song and position. Manually queued songs may be reset.")
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

/// Native slider with a stable readout and an explicit VoiceOver name/value.
struct SettingsSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let displayedValue: Text

    init(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, displayedValue: Text) {
        self.title = title
        _value = value
        self.range = range
        self.displayedValue = displayedValue
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: $value, in: range).labelsHidden()
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(displayedValue)
                displayedValue.monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
                    .accessibilityHidden(true)
            }.frame(maxWidth: 280)
        }
    }
}
