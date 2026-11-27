import SwiftUI

/// What friends are listening to, through ListenBrainz: a card per friend, the
/// ones listening now first. Spotify gives apps no way to see friends'
/// listening, so friends are ListenBrainz names, and anyone who connected
/// their Spotify to ListenBrainz can be followed here. The page asks only
/// while it is the one showing (`FriendsModel.keepFresh` in this view's task).
struct FriendsView: View {
    @Environment(FriendsModel.self) private var friends
    @Environment(\.interfaceScale) private var scale
    @Environment(\.isOnstage) private var onstage
    @Environment(\.windowVisible) private var windowVisible
    @Environment(\.scenePhase) private var scenePhase
    /// Room for two columns of cards.
    @ViewState private var wide = false

    var body: some View {
        let factor = scale.factor
        let ordered = friends.ordered
        // The page is in front (not under Now Playing or Lyrics), its window shows, and Tint is the active app.
        let watching = Watching(active: onstage && windowVisible && scenePhase == .active, request: friends.refreshRequests)
        VStack(alignment: .leading, spacing: scale.sectionGap) {
            VStack(alignment: .leading, spacing: scale(16)) {
                HStack(alignment: .firstTextBaseline, spacing: scale(10)) {
                    Text("Friends")
                        .floeFont(size: 32, weight: .heavy)
                        .tracking(-0.6)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if friends.isRefreshing {
                        ProgressView().controlSize(.small).centeredOnSectionTitle()
                    }
                    IconButton(systemImage: "arrow.clockwise", size: 14, help: "Refresh") { friends.requestRefresh() }
                        .disabled(friends.friends.isEmpty)
                        .centeredOnSectionTitle()
                        .padding(.trailing, -scale.plate)
                }
                Text("What your friends are listening to, from ListenBrainz, a free and open service. Their names are the only thing Tint sends to it.")
                    .floeFont(size: 13)
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(2)
                    .frame(maxWidth: scale(640), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                AddFriend()
                if let problem = friends.problem, !friends.friends.isEmpty {
                    Notice(systemImage: "wifi.exclamationmark", text: problem == .busy
                        ? "ListenBrainz asked Tint to slow down. What's shown is from its last answer; Tint asks again by itself."
                        : "ListenBrainz can't be reached. What's shown is from its last answer; Tint asks again by itself.")
                }
            }
            .reveal("header")

            if ordered.isEmpty {
                MessageView(systemImage: "person.2",
                            message: L10n.string("Add a friend by their ListenBrainz name to see what they're playing, their last songs and their artists of the week."),
                            title: "No friends here yet")
                    .reveal("empty", order: 1)
            } else if wide {
                // Two columns filled in turn, so the first two cards are the two listening most recently.
                HStack(alignment: .top, spacing: scale(16)) {
                    ForEach(0..<2, id: \.self) { column in
                        LazyVStack(spacing: scale(16)) {
                            ForEach(ordered.enumerated().filter { $0.offset % 2 == column }.map(\.element)) { FriendCard(friend: $0, asOf: friends.asOf) }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .reveal("cards", order: 1)
            } else {
                LazyVStack(spacing: scale(16)) {
                    ForEach(ordered) { FriendCard(friend: $0, asOf: friends.asOf) }
                }
                .reveal("cards", order: 1)
            }

            BeingSeen().reveal("seen", order: 2)
        }
        .revealScope()
        .onGeometryChange(for: Bool.self) { $0.size.width / factor >= 800 } action: { wide = $0 }
        // Refreshes on opening and every minute after, and stops the moment the page isn't being looked at.
        .task(id: watching) {
            if watching.active { await friends.keepFresh() }
        }
    }

    private struct Watching: Equatable {
        let active: Bool
        /// A refresh by hand starts the task over.
        let request: Int
    }
}

enum FriendsFormat {
    /// "5 minutes ago" or, short, "5 min. ago", counted from the page's last refresh.
    static func ago(_ date: Date, asOf now: Date, locale: Locale, short: Bool = false) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return L10n.string("Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = short ? .short : .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func profile(_ name: String) -> URL? {
        URL(string: "https://listenbrainz.org/user/\(ListenBrainzClient.escaped(name))/")
    }
}

extension FriendListen {
    /// Enough of a track for the player to show while the song loads.
    var track: Track? {
        guard let spotifyID, let uri else { return nil }
        let artists = spotifyArtists.isEmpty
            ? [ArtistRef(id: nil, uri: nil, name: artist)]
            : spotifyArtists.map { ArtistRef(id: $0.id, uri: "spotify:artist:\($0.id)", name: $0.name) }
        return Track(id: spotifyID, uri: uri, name: title, durationMs: durationMs ?? 0, explicit: nil, artists: artists, album: nil,
                     trackNumber: nil, discNumber: nil, isLocal: false, isPlayable: true)
    }
}

// MARK: - Adding

/// A capsule text field in the page's own style.
private struct NameField: View {
    let prompt: LocalizedStringKey
    let systemImage: String
    @Binding var text: String
    let submit: () -> Void
    @Environment(\.coverPalette) private var palette
    @Environment(\.interfaceScale) private var scale
    @FocusState private var focused: Bool
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: scale(6)) {
            Image(systemName: systemImage).foregroundStyle(focused ? Theme.secondary : Theme.tertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .autocorrectionDisabled()
                .onSubmit(submit)
        }
        .floeFont(size: 12)
        .padding(.horizontal, scale(10))
        .frame(width: scale(230), height: scale(28))
        .background(.white.opacity(focused ? 0.1 : (hovering ? 0.09 : 0.07)), in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? palette.accent.opacity(0.5) : .clear))
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .floeState(value: focused)
    }
}

private struct CapsuleButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    let action: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        Button(action: action) {
            HStack(spacing: scale(5)) {
                Text(title)
                if let systemImage { Image(systemName: systemImage).floeFont(size: 10, weight: .bold) }
            }
            .floeFont(size: 12.5, weight: .semibold)
            .padding(.horizontal, scale(14))
            .padding(.vertical, scale(6))
            .glassControl(in: .capsule)
        }
        .buttonStyle(.floe)
    }
}

/// The field a friend's ListenBrainz name goes in. The name is asked of
/// ListenBrainz before it's kept, and a refusal says why beside the field.
private struct AddFriend: View {
    @Environment(FriendsModel.self) private var friends
    @Environment(\.interfaceScale) private var scale
    @ViewState private var name = ""

    var body: some View {
        HStack(spacing: scale(10)) {
            NameField(prompt: "A friend's ListenBrainz name", systemImage: "person.badge.plus", text: $name, submit: add)
            CapsuleButton(title: "Add", action: add)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || friends.isAdding)
            if friends.isAdding {
                ProgressView().controlSize(.small)
            } else if let problem = friends.addProblem {
                Text(Self.text(problem))
                    .floeFont(size: 12)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .onChange(of: name) { if friends.addProblem != nil { friends.addProblem = nil } }
        .floeState(value: friends.addProblem)
    }

    private func add() {
        let asked = name
        Task {
            if await friends.add(asked), name == asked { name = "" }
        }
    }

    private static func text(_ problem: FriendsModel.AddProblem) -> String {
        switch problem {
        case let .noSuchUser(name): L10n.string("ListenBrainz has no account named “\(name)”.")
        case let .alreadyAdded(name): L10n.string("\(name) is already here.")
        case .full: L10n.string("The page holds \(FriendsModel.limit) friends. Remove one to add another.")
        case .failed(.busy): L10n.string("ListenBrainz asked Tint to slow down. Try again in a minute.")
        case .failed(.network): L10n.string("ListenBrainz can't be reached, so the name couldn't be checked.")
        case .failed: L10n.string("ListenBrainz couldn't check the name. Try again later.")
        }
    }
}

/// A line that says something went wrong for the whole page, quietly.
private struct Notice: View {
    let systemImage: String
    let text: LocalizedStringKey
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: scale(10), style: .continuous)
        HStack(spacing: scale(10)) {
            Image(systemName: systemImage).foregroundStyle(.orange)
            Text(text).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .floeFont(size: 12)
        .padding(.horizontal, scale(12))
        .padding(.vertical, scale(9))
        .background(.white.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.05)))
    }
}

// MARK: - A friend

private struct FriendCard: View {
    let friend: Friend
    /// The moment "now" and "ago" are counted from.
    let asOf: Date
    @Environment(FriendsModel.self) private var friends
    @Environment(PlayerModel.self) private var player
    @Environment(Navigator.self) private var navigator
    @Environment(SearchModel.self) private var search
    @Environment(\.coverPalette) private var palette
    @Environment(\.interfaceScale) private var scale
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @ReducedMotion private var still

    var body: some View {
        let listening = friend.isListening(asOf: asOf)
        let shape = RoundedRectangle(cornerRadius: scale(14), style: .continuous)
        VStack(alignment: .leading, spacing: scale(14)) {
            HStack(spacing: scale(12)) {
                Text(String(friend.name.prefix(1)).uppercased())
                    .floeFont(size: 15, weight: .bold)
                    .foregroundStyle(Theme.secondary)
                    .frame(width: scale(38), height: scale(38))
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(palette.highlight, lineWidth: 2).opacity(listening ? 1 : 0))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: scale(2)) {
                    Text(friend.name).floeFont(size: 15, weight: .semibold).lineLimit(1)
                    HStack(spacing: scale(5)) {
                        if listening {
                            LoopingSymbol.playing(pointSize: scale.text(10), color: palette.highlight, running: !still)
                        }
                        Text(status(listening: listening))
                            .floeFont(size: 12)
                            .foregroundStyle(listening ? palette.highlight : Theme.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Open on ListenBrainz") { FriendsFormat.profile(friend.name).map { openURL($0) } }
                    Divider()
                    Button("Remove from Friends", role: .destructive) { friends.remove(friend) }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.secondary).frame(width: scale(22), height: scale(22))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            content
        }
        .padding(scale(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(listening ? 0.12 : 0.05)))
    }

    @ViewBuilder private var content: some View {
        if let headline = friend.headline {
            VStack(alignment: .leading, spacing: 2 * scale.plate) {
                FriendSongRow(listen: headline, lead: true) { play(headline, $0) }
                let earlier = friend.earlier.prefix(4)
                if !earlier.isEmpty {
                    Caption(text: "Before that").padding(.top, scale(4))
                    ForEach(earlier.enumerated(), id: \.offset) { _, listen in
                        FriendSongRow(listen: listen, lead: false,
                                      when: listen.listenedAt.map { FriendsFormat.ago($0, asOf: asOf, locale: locale, short: true) }) {
                            play(listen, $0)
                        }
                    }
                }
            }
            if !friend.topArtists.isEmpty {
                VStack(alignment: .leading, spacing: scale(6)) {
                    Caption(text: friend.topRange == .lastWeek ? "Top artists last week" : "Top artists this week")
                    Text(artists)
                        .floeFont(size: 12)
                        .lineSpacing(3)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let count = friend.listenCount {
                Text("Listens on ListenBrainz: \(count.formatted(.number.locale(locale)))")
                    .floeFont(size: 11)
                    .foregroundStyle(Theme.tertiary)
            }
            if case let .failed(problem) = friend.state {
                Text(Self.explanation(problem, hasSongs: true)).floeFont(size: 12).foregroundStyle(Theme.tertiary)
            }
        } else {
            switch friend.state {
            case .loading:
                // Where the first song will land.
                HStack(spacing: scale(12)) {
                    RoundedRectangle(cornerRadius: scale(6)).fill(Theme.well).frame(width: scale(48), height: scale(48))
                    VStack(alignment: .leading, spacing: scale(7)) {
                        RoundedRectangle(cornerRadius: scale(4)).fill(Theme.well).frame(width: scale(150), height: scale(11))
                        RoundedRectangle(cornerRadius: scale(4)).fill(Theme.well).frame(width: scale(96), height: scale(10))
                    }
                }
                .accessibilityHidden(true)
            case .loaded:
                explanation("Nothing listened to yet. Once they connect Spotify or another player to ListenBrainz, it shows here.")
            case let .failed(problem):
                explanation(Self.explanation(problem, hasSongs: false))
                if problem == .noSuchUser {
                    CapsuleButton(title: "Remove from Friends") { friends.remove(friend) }
                }
            }
        }
    }

    private func explanation(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .floeFont(size: 12.5)
            .foregroundStyle(Theme.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func explanation(_ problem: Friend.Problem, hasSongs: Bool) -> LocalizedStringKey {
        switch problem {
        case .noSuchUser: "ListenBrainz has no account by this name. It may have been renamed or deleted."
        case .hidden: "This account doesn't show its listening."
        case .network, .busy: hasSongs ? "Not refreshed: ListenBrainz couldn't be reached." : "Not loaded yet: ListenBrainz couldn't be reached."
        case .service: hasSongs ? "Not refreshed: ListenBrainz had a problem answering for this account."
            : "ListenBrainz had a problem answering for this account. Tint asks again by itself."
        }
    }

    private func status(listening: Bool) -> String {
        if listening { return L10n.string("Listening now") }
        if let last = friend.lastActive { return FriendsFormat.ago(last, asOf: asOf, locale: locale) }
        switch friend.state {
        case .loading: return L10n.string("Loading…")
        case .loaded: return L10n.string("No listens yet")
        case .failed(.noSuchUser): return L10n.string("No such account")
        case .failed(.hidden): return L10n.string("Not shared")
        case .failed: return L10n.string("Not loaded")
        }
    }

    /// "Morphine 16 · Saint Howl 5": names bright, counts quiet.
    private var artists: AttributedString {
        var line = AttributedString()
        for (index, artist) in friend.topArtists.enumerated() {
            if index > 0 {
                var dot = AttributedString("  ·  ")
                dot.foregroundColor = Theme.tertiary
                line += dot
            }
            var name = AttributedString(artist.name)
            name.foregroundColor = .white.opacity(0.82)
            var count = AttributedString("\u{00A0}\(artist.listens.formatted(.number.locale(locale)))")
            count.foregroundColor = Theme.tertiary
            line += name + count
        }
        return line
    }

    /// A song with a Spotify link plays, with the friend's other linked songs
    /// after it; one without opens Search on its artist and title.
    private func play(_ listen: FriendListen, _ resolved: Track?) {
        guard let uri = listen.uri else {
            search.text = listen.searchText
            navigator.showSearch()
            return
        }
        var seen = Set<String>()
        let uris = ([friend.headline].compactMap { $0 } + friend.earlier).compactMap(\.uri).filter { seen.insert($0).inserted }
        player.play(PlayRequest(tracks: uris, startURI: uri), selectedTrack: resolved ?? listen.track)
    }
}

/// A small heading inside a card, in the style of a track list's column titles.
private struct Caption: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text).floeFont(size: 11, weight: .semibold).foregroundStyle(Theme.tertiary)
    }
}

/// A song a friend is playing or played. A click plays it when ListenBrainz
/// knows its Spotify track (the cover shows Play under the pointer), and
/// otherwise searches for it (the cover shows a magnifying glass). The star is
/// there for songs with a track, as on any other row.
private struct FriendSongRow: View {
    let listen: FriendListen
    /// The card's first song: larger, and looked up on Spotify for its real cover.
    let lead: Bool
    var when: String?
    let play: (Track?) -> Void
    @Environment(\.coverPalette) private var palette
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @Environment(SearchModel.self) private var search
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false
    @ViewState private var looked: Track?

    var body: some View {
        let size = scale(lead ? 48 : 32)
        let radius = scale(6)
        let current = listen.uri != nil && player.displayTrack?.uri == listen.uri
        // Spotify's record of the song, once it has answered for this one.
        let track = looked?.id == listen.spotifyID ? looked : listen.spotifyID.flatMap { FriendTracks.shared.cached($0) }
        HStack(spacing: scale(10)) {
            Button { play(track) } label: {
                HStack(spacing: scale(12)) {
                    Group {
                        if let images = track?.album?.images, !images.isEmpty {
                            ArtworkView(images: images, size: size, cornerRadius: radius)
                        } else {
                            ArtworkView(url: listen.cover, size: size, cornerRadius: radius)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius)
                            .fill(.black.opacity(0.45))
                            .overlay(Image(systemName: listen.uri == nil ? "magnifyingglass" : "play.fill")
                                .floeFont(size: lead ? 14 : 11, weight: .semibold).foregroundStyle(.white))
                            .opacity(hovering ? 1 : 0)
                    }
                    VStack(alignment: .leading, spacing: scale(2)) {
                        Text(listen.title)
                            .floeFont(size: lead ? 14 : 13, weight: lead ? .semibold : .medium)
                            .foregroundStyle(current ? palette.highlight : .white)
                        Text(listen.artist).floeFont(size: 12).secondaryText(lit: hovering)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.floeRow)
            .help(listen.uri == nil ? "Search for this song in Tint" : "Play")
            if let uri = listen.uri {
                LikeButton(uri: uri, revealed: hovering)
            }
            if let when {
                Text(when).monospacedDigit().floeFont(size: 11).foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize()
            }
        }
        .hoverPlate(hovering, radius: radius)
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .contextMenu {
            if let uri = listen.uri {
                Button("Play") { play(track) }
                Button("Add to Queue") { player.addToQueue(uri) }
                let title: LocalizedStringKey = library.isLiked(uri) == true ? "Remove from Liked Songs" : "Save to Liked Songs"
                Button(title) { Task { await library.toggleLike(uri) } }
                Divider()
            }
            Button("Search for this song in Tint") {
                search.text = listen.searchText
                navigator.showSearch()
            }
            if let id = listen.spotifyID { CopySongLinkButton(id: id) }
        }
        .onAppear { if let uri = listen.uri { library.requestLikedState(uri) } }
        .task(id: lead ? listen.spotifyID : nil) {
            guard lead, let id = listen.spotifyID, library.connection == .connected else { return }
            let found = await FriendTracks.shared.track(id, api: library.api)
            if !Task.isCancelled { looked = found }
        }
    }
}

// MARK: - Being seen

/// How friends can see the listener, since Tint itself sends nothing; and the
/// listener's own ListenBrainz name, which is only used to offer the people
/// that account follows.
private struct BeingSeen: View {
    @Environment(FriendsModel.self) private var friends
    @Environment(\.interfaceScale) private var scale
    @Environment(\.openURL) private var openURL
    @ViewState private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: scale.headerGap) {
            SectionHeader("Letting friends see you")
            VStack(alignment: .leading, spacing: scale(14)) {
                Text("Tint doesn't send what you play anywhere. To show up for friends, make a free ListenBrainz account, connect Spotify to it on its site, and give them your name. From then on ListenBrainz hears what you play from Spotify itself, in Tint or anywhere else.")
                    .floeFont(size: 13)
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(2)
                    .frame(maxWidth: scale(640), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                CapsuleButton(title: "Connect Spotify on ListenBrainz", systemImage: "arrow.up.right") {
                    openURL(URL(string: "https://listenbrainz.org/settings/music-services/details/")!)
                }
                HStack(spacing: scale(10)) {
                    NameField(prompt: "Your ListenBrainz name (optional)", systemImage: "person", text: $name, submit: save)
                    CapsuleButton(title: friends.myName.isEmpty || name != friends.myName ? "Find who I follow" : "Check again", action: save)
                        .disabled(friends.isLoadingFollowed || (name.trimmingCharacters(in: .whitespaces).isEmpty && friends.myName.isEmpty))
                    if friends.isLoadingFollowed { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }
                .padding(.top, scale(4))
                following
            }
        }
        .onAppear { name = friends.myName }
    }

    @ViewBuilder private var following: some View {
        let suggestions = friends.suggestions
        if let problem = friends.followedProblem {
            note(problem == .noSuchUser ? L10n.string("ListenBrainz has no account named “\(friends.myName)”.")
                 : L10n.string("ListenBrainz couldn't say whom \(friends.myName) follows. Try again later."), warning: true)
        } else if let followed = friends.followed {
            if !suggestions.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: scale(12)) {
                    note(L10n.string("You follow people who aren't here yet: \(Self.names(suggestions))."), warning: false)
                    CapsuleButton(title: "Add them") { friends.addSuggestions() }
                        .disabled(friends.isFull)
                    Spacer(minLength: 0)
                }
            } else {
                note(followed.isEmpty ? L10n.string("\(friends.myName) doesn't follow anyone on ListenBrainz yet.")
                     : L10n.string("Everyone \(friends.myName) follows on ListenBrainz is already here."), warning: false)
            }
        }
    }

    private func note(_ text: String, warning: Bool) -> some View {
        Text(text)
            .floeFont(size: 12)
            .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(Theme.secondary))
            .lineSpacing(2)
            .frame(maxWidth: scale(520), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The first few by name, the rest counted.
    private static func names(_ all: [String]) -> String {
        let shown = all.prefix(4).joined(separator: ", ")
        return all.count > 4 ? L10n.string("\(shown) and \(all.count - 4) more") : shown
    }

    private func save() {
        let asked = name
        Task { await friends.setMyName(asked) }
    }
}
