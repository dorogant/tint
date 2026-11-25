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
    @ViewState private var visualization: VisualizationModel
    @ViewState private var visuals: VisualSettings
    @ViewState private var autoPreset: AutoPresetController
    @ViewState private var presence = WindowPresence()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false
    @ViewState private var appearance = CoverAppearance()
    @AppStorage("accentFromCover") private var accentFromCover = false

    init() {
        let api = WebAPI(user: UserTokenProvider())
        _library = ViewState(wrappedValue: LibraryModel(api: api))
        _connect = ViewState(wrappedValue: ConnectModel(api: api))
        let visualization = VisualizationModel(), visuals = VisualSettings(), genres = ArtistGenres(api: api)
        let autoPreset = AutoPresetController(settings: visuals, genres: { await genres.genres(for: $0) }) {
            UserDefaults.standard.bool(forKey: "reduceMotion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        // Listens only while a song still needs its sound classified.
        autoPreset.setListening = { [weak autoPreset, weak visualization] on in
            guard let autoPreset, let visualization else { return }
            visualization.setFrameListener(for: autoPreset, on ? { [weak autoPreset, weak visualization] in
                if let visualization { autoPreset?.hear(visualization.frame) }
            } : nil)
        }
        _visualization = ViewState(wrappedValue: visualization)
        _visuals = ViewState(wrappedValue: visuals)
        _autoPreset = ViewState(wrappedValue: autoPreset)
    }

    /// The auto preset only chooses while there's a live background to show it.
    private var autoPresetActive: Bool { visuals.autoPreset && visuals.liveBackground }

    private var needsAnalysis: Bool {
        player.isPlaying && ((scenePhase == .active && presence.isVisible) || SelfTest.isEnabled)
            && !reduceMotion && !systemReduceMotion
            && (visuals.liveBackground || (visuals.showVisualizer && navigator.surface == .nowPlaying))
    }

    var body: some Scene {
        Window("Tint", id: "main") {
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
                .environment(\.interfaceScale, settings.interfaceSize.scale)
                .environment(\.windowVisible, presence.isVisible || SelfTest.isEnabled)
                .environment(\.coverPalette, accentFromCover ? appearance.palette : CoverPalette.fixed(settings.fixedAccent))
                .onChange(of: needsAnalysis, initial: true) {
                    visualization.setRunning(needsAnalysis)
                    FloeCore.shared.setSoloistTapRunning(needsAnalysis)
                }
                .onChange(of: settings.playbackConfiguration, initial: true) { player.configurePlayback(settings.playbackConfiguration) }
                .onChange(of: settings.engine) { player.switchEngine(to: settings.engine) }
                .task(id: "\(player.displayTrack?.coverURL?.absoluteString ?? "")#\(visuals.backgroundBlur)") {
                    await appearance.load(player.displayTrack?.coverURL, blur: visuals.backgroundBlur)
                }
                .task(id: player.displayTrack.map(LyricsRequest.init)) { await lyrics.load(player.displayTrack) }
                // Playing with no window in sight is how Tint spends most of its time:
                // after half a minute of that, the covers kept for browsing (up to 48 MB) go.
                .task(id: presence.isVisible) {
                    guard !presence.isVisible, (try? await Task.sleep(for: .seconds(30))) != nil else { return }
                    ArtworkCache.shared.trim()
                }
                .task(id: "\(player.displayTrack?.uri ?? "")#\(autoPresetActive)") {
                    await autoPreset.update(player.displayTrack.map(AutoPresetController.Song.init), enabled: autoPresetActive)
                }
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
        .windowToolbarStyle(.unified(showsTitle: false))
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
                .environment(library)
                .environment(visualization)
                .environment(\.locale, settings.locale)
                .environment(\.coverPalette, accentFromCover ? appearance.palette : CoverPalette.fixed(settings.fixedAccent))
        }
        .defaultSize(width: 820, height: 600)
        .windowResizability(.contentMinSize)

    }
}

/// What a lyrics lookup depends on. The selected row's metadata hands over to the
/// engine's when playback starts; extra featured artists or another cover size
/// there must not restart the lookup (a loading flash and a cancelled request).
private struct LyricsRequest: Hashable {
    let uri: String
    let signature: LyricsService.Signature

    init(_ track: TrackInfo) {
        uri = track.uri
        signature = LyricsService.Signature(track)
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
            guard event.keyCode == 49, modifiers.isEmpty, NSApp.keyWindow?.title == "Tint",
                  !(NSApp.keyWindow?.firstResponder is NSText)
            else { return event }
            player.togglePlayPause()
            return nil
        }
    }
}
