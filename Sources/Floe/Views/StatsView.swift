import SwiftUI

/// Your own listening in numbers, from two sources that are kept apart and
/// labelled: what played in Tint on this Mac (the listening history, which
/// knows how long each song was listened to), and Spotify's own ranking of the
/// account, which covers every device and goes back further than Tint does.
struct StatsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @Environment(ListeningRecorder.self) private var listening
    @Environment(StatsModel.self) private var stats
    @Environment(\.interfaceScale) private var scale
    @Environment(\.isOnstage) private var onstage
    @Environment(\.locale) private var locale
    /// Room for the top lists side by side and the tiles in one row.
    @ViewState private var wide = true
    /// Ten of Spotify's songs at first; the rest on request.
    @ViewState private var shownSongs = StatsView.firstSongs

    private static let firstSongs = 10

    var body: some View {
        @Bindable var stats = stats
        let factor = scale.factor
        VStack(alignment: .leading, spacing: scale.sectionGap) {
            Text("Stats")
                .floeFont(size: 32, weight: .heavy)
                .tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
                .reveal("title")

            VStack(alignment: .leading, spacing: scale(20)) {
                SourceBar(badge: "In Tint", note: tintNote, stacked: !wide) {
                    Picker("Period", selection: $stats.period) {
                        ForEach(ListeningStats.Period.allCases) { Text($0.label).tag($0) }
                    }
                }
                if let summary = stats.summary {
                    if summary.since == nil {
                        MessageView(systemImage: "chart.bar", message: L10n.string("Tint counts a song once you've listened to it here for 30 seconds. Play something and your numbers start today."),
                                    title: "Nothing counted yet")
                    } else {
                        own(summary[stats.period])
                    }
                }
            }
            .reveal("tint", order: 1)

            VStack(alignment: .leading, spacing: scale(20)) {
                SourceBar(badge: "On Spotify", note: L10n.string("Spotify's own ranking of your account, from everything you play with it on any device."),
                          stacked: !wide) {
                    Picker("Range", selection: $stats.range) {
                        ForEach(TopRange.allCases) { Text($0.label).tag($0) }
                    }
                }
                ranking
            }
            .reveal("spotify", order: 2)
        }
        .revealScope()
        .onGeometryChange(for: Bool.self) { $0.size.width / factor >= 800 } action: { wide = $0 }
        // Worked out again when a play is stored while the page shows, and on coming back to it.
        .task(id: "\(listening.revision)#\(onstage)") {
            if onstage { await stats.load(listening.history) }
        }
        .task(id: "\(stats.range.rawValue)#\(library.connection == .connected)#\(onstage)") {
            shownSongs = Self.firstSongs
            if onstage, library.connection == .connected { await stats.loadRanking(stats.range, api: library.api) }
        }
    }

    /// Says since when Tint has been counting: the history began the day this page shipped.
    private var tintNote: String {
        let what = L10n.string("What you listened to in Tint on this Mac, for 30 seconds or more.")
        guard let since = stats.summary?.since else { return what }
        let day = Calendar.current.isDateInToday(since)
            ? L10n.string("Counting since today.")
            : L10n.string("Counting since \(since.formatted(.dateTime.day().month(.wide).year().locale(locale))).")
        return "\(what) \(day)"
    }

    // MARK: - In Tint

    @ViewBuilder
    private func own(_ numbers: ListeningStats) -> some View {
        let tiles: [(LocalizedStringKey, String)] = [
            ("Time listened", StatsFormat.time(numbers.seconds)),
            ("Plays", numbers.plays.formatted(.number.locale(locale))),
            ("Different songs", numbers.songs.formatted(.number.locale(locale))),
            ("Different artists", numbers.artists.formatted(.number.locale(locale))),
        ]
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: scale(12)), count: wide ? 4 : 2), spacing: scale(12)) {
            ForEach(tiles.indices, id: \.self) { StatTile(title: tiles[$0].0, value: tiles[$0].1) }
        }
        ListeningChart(bars: numbers.bars, step: numbers.step)
        if numbers.plays == 0 {
            let nothing: LocalizedStringKey = numbers.period == .today ? "Nothing played in Tint today yet." : "Nothing played in Tint in these days."
            Text(nothing)
                .floeFont(size: 13)
                .foregroundStyle(Theme.secondary)
        } else {
            let lists = Group {
                VStack(alignment: .leading, spacing: scale.headerGap) {
                    SectionHeader(title: "Top artists") { ListNote(text: "By time listened") }
                    VStack(spacing: 2 * scale.plate) {
                        ForEach(numbers.topArtists.enumerated(), id: \.element.id) { index, artist in
                            ArtistStatRow(rank: index + 1, artist: artist, most: numbers.topArtists.first?.seconds ?? 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: scale.headerGap) {
                    SectionHeader(title: "Top songs") { ListNote(text: "By plays") }
                    VStack(spacing: 2 * scale.plate) {
                        ForEach(numbers.topSongs.enumerated(), id: \.element.id) { index, song in
                            SongStatRow(rank: index + 1, song: song) { play(song, among: numbers.topSongs) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if wide {
                HStack(alignment: .top, spacing: scale(40)) { lists }.padding(.top, scale(12))
            } else {
                VStack(alignment: .leading, spacing: scale.sectionGap) { lists }.padding(.top, scale(12))
            }
        }
    }

    /// Plays the list from this song, so next and previous move through it.
    private func play(_ song: ListeningStats.Song, among songs: [ListeningStats.Song]) {
        player.play(PlayRequest(tracks: songs.map(\.uri), startURI: song.uri), selectedTrack: song.track)
    }

    // MARK: - On Spotify

    @ViewBuilder private var ranking: some View {
        let range = stats.range
        if library.connection != .connected {
            MessageView(systemImage: "person.crop.circle.badge.questionmark",
                        message: L10n.string("Connect your Spotify library to see how Spotify ranks your listening."))
        } else if let ranking = stats.rankings[range] {
            if ranking.artists.isEmpty && ranking.tracks.isEmpty {
                MessageView(systemImage: "chart.bar", message: L10n.string("Spotify has no ranking for this stretch yet."))
            }
            Shelf(title: "Top artists", items: ranking.artists) { artist in
                Card(images: artist.images, title: artist.name, circle: true, size: 128) {
                    navigator.push(.artist(artist.id))
                } play: {
                    player.play(PlayRequest(contextURI: artist.uri))
                }
            }
            if !ranking.tracks.isEmpty {
                VStack(alignment: .leading, spacing: scale.headerGap) {
                    SectionHeader(title: "Top songs") {
                        if shownSongs < ranking.tracks.count {
                            ShowMoreButton(busy: false) { shownSongs = ranking.tracks.count }
                        }
                    }
                    let entries = ranking.tracks.prefix(shownSongs).enumerated().map { TrackEntry(id: $0, track: $1) }
                    TrackListView(entries: entries) { entry in
                        player.play(PlayRequest(tracks: ranking.tracks.map(\.uri), startURI: entry.track.uri), selectedTrack: entry.track)
                    }
                }
            }
        } else if let error = stats.rankingErrors[range] {
            MessageView(systemImage: "exclamationmark.triangle", message: error, tint: .orange, actionTitle: "Try Again") {
                Task { await stats.loadRanking(range, api: library.api, again: true) }
            }
        } else {
            LoadingView()
        }
    }
}

extension ListeningStats.Period {
    var label: LocalizedStringKey {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All time"
        }
    }
}

extension TopRange {
    var label: LocalizedStringKey {
        switch self {
        case .weeks: "4 weeks"
        case .months: "6 months"
        case .year: "About a year"
        }
    }
}

extension ListeningStats.Song {
    /// Enough of a track for the player to show while the song loads.
    var track: Track {
        let aligned = artistURIs.count == artists.count
        let credited = artists.enumerated().map { index, name in
            let uri = aligned ? artistURIs[index] : nil
            return ArtistRef(id: uri?.split(separator: ":").last.map(String.init), uri: uri, name: name)
        }
        let art = cover.map { [SpotifyImage(url: $0.absoluteString, width: 640, height: 640)] }
        return Track(id: uri.split(separator: ":").last.map(String.init), uri: uri, name: name, durationMs: durationMs, explicit: nil,
                     artists: credited, album: AlbumRef(id: "", uri: "", name: album ?? "", images: art, artists: nil, releaseDate: nil,
                                                        totalTracks: nil, albumType: nil),
                     trackNumber: nil, discNumber: nil, isLocal: false, isPlayable: true)
    }
}

enum StatsFormat {
    /// "3 hr 12 min", "48 min", and seconds under a minute so a first song isn't "0 min".
    static func time(_ seconds: Int) -> String {
        if seconds >= 3600 { return L10n.string("\(seconds / 3600) hr \(seconds % 3600 / 60) min") }
        if seconds >= 60 || seconds == 0 { return L10n.string("\(seconds / 60) min") }
        return L10n.string("\(seconds) s")
    }
}

/// Heads one source's part of the page: which source it is, what that means,
/// and the stretch of time it's showing. On a quiet plate, so the two parts
/// read as two things.
private struct SourceBar<Control: View>: View {
    let badge: LocalizedStringKey
    let note: String
    /// The note under the badge and the control, where there's no room beside them.
    let stacked: Bool
    @ViewBuilder var control: Control
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: scale(12), style: .continuous)
        let picker = control.pickerStyle(.segmented).labelsHidden().fixedSize()
        let text = Text(note)
            .floeFont(size: 12)
            .foregroundStyle(Theme.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: scale(10)) {
                    HStack(spacing: scale(12)) {
                        Badge(text: badge)
                        Spacer(minLength: 0)
                        picker
                    }
                    text
                }
            } else {
                HStack(spacing: scale(12)) {
                    Badge(text: badge)
                    text
                    Spacer(minLength: scale(12))
                    picker
                }
            }
        }
        .padding(.horizontal, scale(14))
        .padding(.vertical, scale(10))
        .background(.white.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.05)))
    }
}

private struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: scale(12), style: .continuous)
        VStack(alignment: .leading, spacing: scale(6)) {
            Text(title)
                .floeFont(size: 12, weight: .medium)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Text(value)
                .floeFont(size: 26, weight: .heavy)
                .tracking(-0.4)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(scale(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }
}

/// How a list is ranked, beside its title.
private struct ListNote: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text).floeFont(size: 12).foregroundStyle(Theme.tertiary)
    }
}

/// Time listened per hour, day, week or month as plain bars. Every step of the
/// period gets its place, so a history of one day reads as a week that has just
/// begun. Flat shapes laid out once per change of the numbers; nothing here moves.
private struct ListeningChart: View {
    let bars: [ListeningStats.Bar]
    let step: ListeningStats.Step
    @Environment(\.coverPalette) private var palette
    @Environment(\.interfaceScale) private var scale
    @Environment(\.locale) private var locale

    var body: some View {
        let most = bars.map(\.seconds).max() ?? 0
        let height = scale(112)
        let busiest = bars.max { $0.seconds < $1.seconds }
        VStack(alignment: .leading, spacing: scale(10)) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).floeFont(size: 13, weight: .semibold)
                Spacer()
                if let busiest, most > 0 {
                    Text("Most: \(name(busiest.start, full: true)), \(StatsFormat.time(most))")
                        .floeFont(size: 12)
                        .foregroundStyle(Theme.tertiary)
                }
            }
            VStack(spacing: scale(6)) {
                HStack(alignment: .bottom, spacing: bars.count > 40 ? scale(2) : scale(4)) {
                    ForEach(bars, id: \.start) { bar in
                        let filled = bar.seconds > 0
                        RoundedRectangle(cornerRadius: scale(3), style: .continuous)
                            .fill(filled ? palette.accent : Color.white.opacity(0.08))
                            // A bar that has anything in it is tall enough to be seen as one.
                            .frame(height: filled ? max(scale(6), height * CGFloat(bar.seconds) / CGFloat(max(most, 1))) : scale(3))
                            .frame(maxWidth: scale(48))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .contentShape(Rectangle())
                            .help(Text(verbatim: "\(name(bar.start, full: true)): \(StatsFormat.time(bar.seconds))"))
                    }
                }
                .frame(height: height)
                HStack(spacing: 0) {
                    ForEach(bars.enumerated(), id: \.element.start) { index, bar in
                        // Wider than its bar where bars are thin; only every few are named then.
                        Color.clear.frame(maxWidth: .infinity).frame(height: scale(12))
                            .overlay { if labelled(index) { Text(name(bar.start, full: false)).fixedSize() } }
                    }
                }
                .floeFont(size: 10, weight: .medium)
                .foregroundStyle(Theme.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
    }

    private var title: LocalizedStringKey {
        switch step {
        case .hour: "Listening by the hour"
        case .day: "Listening by the day"
        case .week: "Listening by the week"
        case .month: "Listening by the month"
        }
    }

    /// Counted back from the newest bar, so "now" is always named.
    private func labelled(_ index: Int) -> Bool {
        let every = step == .hour ? 6 : max(1, Int((Double(bars.count) / 8).rounded(.up)))
        return step == .hour ? index % every == 0 : (bars.count - 1 - index) % every == 0
    }

    private func name(_ date: Date, full: Bool) -> String {
        let style: Date.FormatStyle = switch step {
        case .hour: .dateTime.hour()
        case .day: full ? .dateTime.weekday(.abbreviated).day().month(.abbreviated) : (bars.count <= 7 ? .dateTime.weekday(.abbreviated) : .dateTime.day())
        case .week: .dateTime.day().month(.abbreviated)
        case .month: full ? .dateTime.month(.wide).year() : .dateTime.month(.abbreviated)
        }
        return date.formatted(style.locale(locale))
    }
}

/// An artist of the listener's own top list: place, name, time, and a thin
/// measure against the first. Opens the artist, or searches for a name stored
/// without a link.
private struct ArtistStatRow: View {
    let rank: Int
    let artist: ListeningStats.Artist
    /// The first artist's seconds.
    let most: Int
    @Environment(\.coverPalette) private var palette
    @Environment(Navigator.self) private var navigator
    @Environment(SearchModel.self) private var search
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: scale(12)) {
                Text("\(rank)")
                    .monospacedDigit().floeFont(size: 12)
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: scale(20), alignment: .trailing)
                VStack(alignment: .leading, spacing: scale(6)) {
                    HStack(alignment: .firstTextBaseline, spacing: scale(8)) {
                        Text(artist.name).floeFont(size: 13, weight: .medium).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(StatsFormat.time(artist.seconds))
                            .monospacedDigit().floeFont(size: 12)
                            .secondaryText(lit: hovering)
                    }
                    // A flat layer scaled along its length: nothing is drawn again when the row lights up.
                    Rectangle().fill(palette.accent)
                        .scaleEffect(x: max(0.02, CGFloat(artist.seconds) / CGFloat(max(most, 1))), anchor: .leading)
                        .frame(height: scale(3))
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
            .frame(height: scale(36))
            .hoverPlate(hovering, radius: scale(6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.floeRow)
        .onHover { hovering = $0 }
        .floeHover(hovering)
    }

    private func open() {
        if let uri = artist.uri {
            navigator.open(uri: uri)
        } else {
            search.text = artist.name
            navigator.showSearch()
        }
    }
}

/// A song of the listener's own top list: place, cover, names and how many
/// times it played. A click plays it.
private struct SongStatRow: View {
    let rank: Int
    let song: ListeningStats.Song
    let play: () -> Void
    @Environment(\.coverPalette) private var palette
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    var body: some View {
        let current = player.displayTrack?.uri == song.uri
        let radius = scale(6)
        HStack(spacing: scale(12)) {
            Button(action: play) {
                HStack(spacing: scale(12)) {
                    Text("\(rank)")
                        .monospacedDigit().floeFont(size: 12)
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: scale(20), alignment: .trailing)
                    ArtworkView(url: song.cover, size: scale(36), cornerRadius: radius)
                        .overlay {
                            RoundedRectangle(cornerRadius: radius)
                                .fill(.black.opacity(0.4))
                                .overlay(Image(systemName: "play.fill").floeFont(size: 12).foregroundStyle(.white))
                                .opacity(hovering ? 1 : 0)
                        }
                    VStack(alignment: .leading, spacing: scale(2)) {
                        Text(song.name)
                            .floeFont(size: 13, weight: .medium)
                            .foregroundStyle(current ? palette.highlight : .white)
                        Text(song.artistLine).floeFont(size: 12).secondaryText(lit: hovering)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.floeRow)
            LikeButton(uri: song.uri, revealed: hovering)
            Text(verbatim: "\(song.plays)×")
                .monospacedDigit().floeFont(size: 12)
                .secondaryText(lit: hovering)
                .frame(minWidth: scale(28), alignment: .trailing)
                .help(Text(verbatim: StatsFormat.time(song.seconds)))
        }
        .frame(height: scale(36))
        .hoverPlate(hovering, radius: radius)
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .contextMenu {
            Button("Play", action: play)
            Button("Add to Queue") { player.addToQueue(song.uri) }
            let title: LocalizedStringKey = library.isLiked(song.uri) == true ? "Remove from Liked Songs" : "Save to Liked Songs"
            Button(title) { Task { await library.toggleLike(song.uri) } }
            if let id = song.track.id {
                Divider()
                CopySongLinkButton(id: id)
            }
        }
        .onAppear { library.requestLikedState(song.uri) }
    }
}
