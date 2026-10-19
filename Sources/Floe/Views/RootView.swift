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
    @Environment(Navigator.self) private var navigator
    @Environment(PlayerModel.self) private var player

    @Namespace private var hero
    @ViewState private var showingConnect: ConnectSection?
    @ViewState private var showingVisuals = false
    @AppStorage("accentFromCover") private var accentFromCover = false
    @AppStorage("reduceMotion") private var reduceMotion = false
    @ReducedMotion private var still

    var body: some View {
        VStack(spacing: Theme.margin) {
            PlaybackStatusView()
            Group {
                switch navigator.surface {
                case .library:
                    HStack(spacing: Theme.margin) {
                        SidebarView().frame(width: 240).glassPanel()
                        ZStack {
                            // Every page starts on the same guides: content on the
                            // gutter, plates and full-bleed shelves reaching past it.
                            ScrollView {
                                page.padding(.horizontal, Theme.gutter).padding(.top, Theme.gutter - 1).padding(.bottom, 32)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // A scroll view touching the toolbar's edge reaches up under
                            // it and insets its content to match. When a banner or a
                            // transition moved the panel, that inset changed mid-flight
                            // and left the page resting a few points scrolled. One point
                            // of room (taken back from the top padding) keeps it out.
                            .padding(.top, 1)
                            .id(navigator.current)
                            // A fade only: the page's sections rise in on their own
                            // (`reveal`), and moving the scroll view itself left it
                            // resting a few points scrolled, off the page's guides.
                            .transition(.opacity)
                        }
                        // Shelves scroll to the panel's edge; keep them inside its corners.
                        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        .glassPanel()
                        .floeAnimation(value: navigator.current)
                    }
                case .nowPlaying:
                    NowPlayingView().glassPanel()
                case .lyrics:
                    LyricsView().frame(maxWidth: 780).frame(maxWidth: .infinity).glassPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(navigator.surface)
            .transition(SurfaceTransition(raised: navigator.surface != .library))
            if navigator.surface != .nowPlaying {
                MiniPlayerView().frame(height: 76).glassPanel()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding([.horizontal, .bottom], Theme.margin)
        .environment(\.heroNamespace, hero)
        .floeAnimation(value: navigator.surface, duration: 0.45, bounce: 0.12)
        // A status banner's room opens on the same spring it drops in on.
        .animation(still ? nil : FloeMotion.enter, value: PlaybackStatusView.key(player))
        .toolbar { toolbarContent }
        // The one search field: the toolbar's own, trailing, so it's there on every surface.
        .modifier(ToolbarSearch())
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    /// A standard unified toolbar: macOS supplies the glass grouping, overflow
    /// menu and alignment with the window controls.
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        @Bindable var navigator = navigator
        ToolbarItem(placement: .navigation) {
            Button { navigator.back() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(navigator.surface != .library || !navigator.canGoBack)
                .help("Back")
        }
        ToolbarItem(placement: .principal) {
            SurfaceSwitcher(selection: $navigator.surface)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showingVisuals.toggle() } label: {
                Label { Text("Visuals") } icon: { ToolbarSymbol(systemImage: "waveform", open: showingVisuals) }
            }
            .help("Visuals")
            .popover(isPresented: $showingVisuals) { VisualControls() }
            ForEach(ConnectSection.allCases) { section in
                connectButton(section)
            }
            Menu {
                Toggle("Accent from cover", isOn: $accentFromCover)
                Toggle("Reduce motion", isOn: $reduceMotion)
            } label: { Label("Appearance", systemImage: "paintpalette") }
            .menuIndicator(.hidden)
            .help("Appearance")
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .help("Settings")
        }
    }

    private func connectButton(_ section: ConnectSection) -> some View {
        Button { showingConnect = section } label: {
            Label { Text(LocalizedStringKey(section.title)) } icon: {
                ToolbarSymbol(systemImage: section.symbol, open: showingConnect == section)
            }
        }
        .help(LocalizedStringKey(section.title))
        .popover(isPresented: Binding(
            get: { showingConnect == section },
            set: { if !$0, showingConnect == section { showingConnect = nil } }
        )) { ConnectPanel(section: section) }
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

/// Library, Now Playing and Lyrics as one control: a pill glides to the chosen
/// view and the others brighten under the pointer. VoiceOver gets the
/// segmented picker it replaces.
///
/// The toolbar's glass capsule hugs an item exactly as tall as the platter
/// (36 pt) but centres a shorter one, which left the pill 3 pt from the sides
/// and 5 pt from the top and bottom. Filling the platter makes the inset the
/// same all round, and the pill, a capsule too, concentric with it. (Hiding
/// the shared glass to draw our own capsule was tried: SwiftUI glass and
/// translucent fills draw flat inside a bare toolbar item.)
private struct SurfaceSwitcher: View {
    @Binding var selection: Navigator.Surface
    @Namespace private var pill
    @ReducedMotion private var still

    /// Between the pill and the glass's edge, all round.
    static let inset: CGFloat = 4
    /// The toolbar's platter height, which the switcher fills.
    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Navigator.Surface.allCases, id: \.self) { surface in
                // With Reduce Motion each pill is its own, so they crossfade instead.
                SurfaceSegment(title: surface.title, selected: selection == surface, pill: pill,
                               pillID: still ? surface.rawValue : "pill") {
                    selection = surface
                }
            }
        }
        .padding(Self.inset)
        .animation(still ? FloeMotion.fade : FloeMotion.glide, value: selection)
        .accessibilityRepresentation {
            Picker("View", selection: $selection) {
                ForEach(Navigator.Surface.allCases, id: \.self) { surface in
                    Text(surface.title).tag(surface)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct SurfaceSegment: View {
    let title: LocalizedStringKey
    let selected: Bool
    let pill: Namespace.ID
    let pillID: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            // The toolbar flattens translucent text colours, so dim with opacity.
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .opacity(selected ? 1 : (hovering ? 0.88 : 0.6))
                .padding(.horizontal, 16)
                .frame(height: SurfaceSwitcher.height - 2 * SurfaceSwitcher.inset)
                .background {
                    if selected {
                        Capsule().fill(.white.opacity(0.15))
                            .overlay(HairlineCapsule().fill(.white.opacity(0.1), style: FillStyle(eoFill: true)))
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                            .matchedGeometryEffect(id: pillID, in: pill)
                    } else {
                        Capsule().fill(Theme.hover).opacity(hovering ? 1 : 0)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(TactileButtonStyle(pressedScale: 0.97))
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The pill's 1 pt edge as a filled ring. A stroked capsule drew a sliver
/// beside each end of the pill in the toolbar.
private struct HairlineCapsule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Capsule().path(in: rect)
        path.addPath(Capsule().path(in: rect.insetBy(dx: 1, dy: 1)))
        return path
    }
}

private extension Navigator.Surface {
    var title: LocalizedStringKey {
        switch self {
        case .library: "Library"
        case .nowPlaying: "Now Playing"
        case .lyrics: "Lyrics"
        }
    }
}

/// A toolbar icon that answers its panel: it bounces as the panel opens and
/// takes the accent while it's up. The toolbar draws the hover highlight.
private struct ToolbarSymbol: View {
    let systemImage: String
    let open: Bool
    @Environment(\.coverPalette) private var palette
    @ReducedMotion private var still
    @ViewState private var opens = 0

    var body: some View {
        Image(systemName: systemImage)
            .symbolEffect(.bounce, options: .speed(1.3), value: opens)
            .foregroundStyle(open ? AnyShapeStyle(palette.highlight) : AnyShapeStyle(.primary))
            .onChange(of: open) { if open && !still { opens += 1 } }
            .animation(FloeMotion.fade, value: open)
    }
}
