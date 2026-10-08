import AppKit
import SwiftUI

@main
struct FloeApp: App {
    @ViewState private var player = PlayerModel()
    @ViewState private var library: LibraryModel
    @ViewState private var connect: ConnectModel
    @ViewState private var settings = AppSettings()
    @ViewState private var navigator = Navigator()
    @ViewState private var search = SearchModel()
    @ViewState private var lyrics = LyricsModel()
    @ViewState private var visualization = VisualizationModel()
    @ViewState private var visuals = VisualSettings()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false
    @ViewState private var appearance = CoverAppearance()
    @AppStorage("accentFromCover") private var accentFromCover = false

    init() {
        let api = WebAPI(user: UserTokenProvider())
        _library = ViewState(wrappedValue: LibraryModel(api: api))
        _connect = ViewState(wrappedValue: ConnectModel(api: api))
    }

    private var needsAnalysis: Bool {
        player.isPlaying && (scenePhase == .active || SelfTest.isEnabled) && !reduceMotion && !systemReduceMotion
            && (visuals.liveBackground || (visuals.showVisualizer && navigator.surface == .nowPlaying))
    }

    var body: some Scene {
        Window("Floe", id: "main") {
            RootView()
                .environment(player)
                .environment(library)
                .environment(navigator)
                .environment(search)
                .environment(lyrics)
                .environment(appearance)
                .environment(visualization)
                .environment(visuals)
                .environment(settings)
                .environment(connect)
                .environment(\.locale, settings.locale)
                .environment(\.coverPalette, accentFromCover ? appearance.palette : CoverPalette.fixed(settings.fixedAccent))
                .onChange(of: needsAnalysis, initial: true) { visualization.setRunning(needsAnalysis) }
                .onChange(of: settings.playbackConfiguration, initial: true) { player.configurePlayback(settings.playbackConfiguration) }
                .task(id: "\(player.track?.coverURL?.absoluteString ?? "")#\(visuals.backgroundBlur)") {
                    await appearance.load(player.track?.coverURL, blur: visuals.backgroundBlur)
                }
                .task(id: player.track) { await lyrics.load(player.track) }
                .task {
                    SpaceToPlay.install(player)
                    Snapshot.canCapture = { navigator.surface == .library || lyrics.isSynthetic }
                    Snapshot.installTrigger()
                    await player.restoreSession()
                    await library.start()
                    if SelfTest.isEnabled {
                        await SelfTest.run(player: player, library: library, navigator: navigator, search: search, lyrics: lyrics, appearance: appearance, visualization: visualization, visuals: visuals, settings: settings, connect: connect)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1220, height: 800)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Back") { navigator.back() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Search") { navigator.select(.search) }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Playback") {
                Button("Play/Pause (Space)") { player.togglePlayPause() }
                Button("Next") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Volume Up") { player.setVolume(player.volume + 0.1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Volume Down") { player.setVolume(player.volume - 0.1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Divider()
                Button("Shuffle") { player.toggleShuffle() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Repeat") { player.cycleRepeat() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }
        Settings {
            SettingsView()
                .environment(settings)
                .environment(visuals)
                .environment(player)
                .environment(visualization)
                .environment(\.locale, settings.locale)
        }

    }
}

/// Space toggles playback unless a text field is being edited. A local event
/// monitor (not a key equivalent) so typing a space in Search still works.
@MainActor
enum SpaceToPlay {
    private static var installed = false

    static func install(_ player: PlayerModel) {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 49, modifiers.isEmpty, NSApp.keyWindow?.title == "Floe",
                  !(NSApp.keyWindow?.firstResponder is NSText)
            else { return event }
            player.togglePlayPause()
            return nil
        }
    }
}
