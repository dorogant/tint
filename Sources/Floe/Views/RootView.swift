import SwiftUI

/// Onboarding until both logins exist, then the main window.
struct RootView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library

    var body: some View {
        ZStack {
            Backdrop()
            if !player.hasConnected {
                if player.session == .connecting {
                    ProgressView("Connecting to Spotify…").controlSize(.small)
                } else {
                    OnboardingView(step: .playback)
                }
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
        .preferredColorScheme(.dark)
        .frame(minWidth: 940, minHeight: 600)
    }
}

struct MainView: View {
    @Environment(\.coverPalette) private var palette
    @Environment(Navigator.self) private var navigator
    @Environment(SearchModel.self) private var search

    @Environment(\.openSettings) private var openSettings
    @ViewState private var showingConnect: Bool?
    @ViewState private var showingVisuals = false
    @AppStorage("accentFromCover") private var accentFromCover = false
    @AppStorage("reduceMotion") private var reduceMotion = false

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Floe").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.secondary)
                Spacer()
                surfaceButton("Library", icon: "square.grid.2x2", surface: .library)
                surfaceButton("Now Playing", icon: "play.circle", surface: .nowPlaying)
                surfaceButton("Lyrics", icon: "text.quote", surface: .lyrics)
                Button { showingVisuals.toggle() } label: {
                    Image(systemName: "waveform").frame(width: 30, height: 30)
                }
                .buttonStyle(.plain).help("Visuals")
                .popover(isPresented: $showingVisuals) { VisualControls() }
                Button { showingConnect = true } label: { Image(systemName: "list.bullet").frame(width: 30, height: 30) }
                    .buttonStyle(.plain).help("Queue")
                    .popover(isPresented: Binding(get: { showingConnect == true }, set: { if !$0 { showingConnect = nil } })) { ConnectPanel(queue: true) }
                Button { showingConnect = false } label: { Image(systemName: "hifispeaker").frame(width: 30, height: 30) }
                    .buttonStyle(.plain).help("Devices")
                    .popover(isPresented: Binding(get: { showingConnect == false }, set: { if !$0 { showingConnect = nil } })) { ConnectPanel(queue: false) }
                Button { openSettings() } label: { Image(systemName: "gearshape").frame(width: 30, height: 30) }
                    .buttonStyle(.plain).help("Settings")
                Menu {
                    Toggle("Accent from cover", isOn: $accentFromCover)
                    Toggle("Reduce motion", isOn: $reduceMotion)
                } label: { Image(systemName: "paintpalette").frame(width: 30, height: 30) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Appearance")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            PlaybackStatusView()
            Group {
                switch navigator.surface {
                case .library:
                    HStack(spacing: 10) {
                        SidebarView().frame(width: 236).glassPanel()
                        VStack(spacing: 0) {
                            topBar
                            ScrollView {
                                page.padding(.horizontal, 18).padding(.bottom, 24)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(navigator.current)
                        }.glassPanel()
                    }
                case .nowPlaying:
                    NowPlayingView().glassPanel()
                case .lyrics:
                    LyricsView().frame(maxWidth: 780).frame(maxWidth: .infinity).glassPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if navigator.surface != .nowPlaying {
                MiniPlayerView().frame(height: 76).glassPanel()
            }
        }
        .padding(10)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func surfaceButton(_ title: LocalizedStringKey, icon: String, surface: Navigator.Surface) -> some View {
        Button { navigator.surface = surface } label: {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(navigator.surface == surface ? .white.opacity(0.12) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            IconButton(systemImage: "chevron.left", size: 13, help: "Back") { navigator.back() }
                .disabled(!navigator.canGoBack)
                .opacity(navigator.canGoBack ? 1 : 0.35)
            if navigator.current == .search {
                SearchField(search: search)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    @ViewBuilder
    private var page: some View {
        switch navigator.current {
        case .home: HomeView()
        case .search: SearchView()
        case .songs: SongsView()
        case let .playlist(id): PlaylistView(id: id)
        case let .album(id): AlbumView(id: id)
        case let .artist(id): ArtistView(id: id)
        }
    }
}

struct OnboardingView: View {
    @Environment(\.coverPalette) private var palette
    enum Step { case playback, library }

    let step: Step
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(palette.accent)
                Text("Welcome to Floe").font(.system(size: 26, weight: .heavy))
            }
            Text("Spotify asks for two approvals, both in your browser. Floe never sees your password.")
                .foregroundStyle(Theme.secondary)

            stepRow(number: 1, title: "Playback", detail: "Lets Floe stream music as a Spotify Connect device.",
                    done: step == .library, busy: player.session == .authorizing || player.session == .connecting,
                    error: playbackError, action: player.logIn)
            stepRow(number: 2, title: "Library",
                    detail: "Lets Floe read your playlists, saved music and history through your developer app.",
                    done: false, busy: library.connection == .connecting,
                    error: libraryError, enabled: step == .library) {
                Task { await library.connect() }
            }
        }
        .padding(30)
        .frame(width: 520)
        .glassPanel(cornerRadius: 24)
    }

    private var playbackError: String? {
        if case let .failed(message) = player.session { message } else { nil }
    }

    private var libraryError: String? {
        if case let .failed(message) = library.connection { message } else { nil }
    }

    private func stepRow(number: Int, title: LocalizedStringKey, detail: LocalizedStringKey, done: Bool,
                         busy: Bool, error: String?, enabled: Bool = true,
                         action: @escaping () -> Void) -> some View {
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
                ProgressView().controlSize(.small)
            } else if !done {
                Button(error == nil ? "Connect" : "Try Again", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .disabled(!enabled)
            }
        }
        .opacity(enabled || done ? 1 : 0.5)
    }
}
