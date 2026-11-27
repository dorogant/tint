import Foundation

/// The listener's own numbers for one stretch of time, worked out from what
/// Tint remembers playing (`ListeningHistory`). A play belongs to the moment
/// it started: a song begun at 23:58 counts for that day, however long it ran.
struct ListeningStats: Equatable, Sendable {
    /// Each ends now and starts on a day boundary of the listener's own calendar.
    enum Period: String, CaseIterable, Identifiable, Sendable {
        /// Since midnight.
        case today
        /// Today and the six days before it.
        case week
        /// Today and the twenty-nine days before it.
        case month
        case all

        var id: Self { self }
    }

    /// What one bar of the chart covers.
    enum Step: Equatable, Sendable { case hour, day, week, month }

    struct Artist: Equatable, Sendable, Identifiable {
        /// The Spotify URI, or the name where a play didn't carry one.
        var id: String
        var name: String
        var uri: String?
        var seconds: Int
        var plays: Int
    }

    struct Song: Equatable, Sendable, Identifiable {
        var id: String { uri }
        var uri: String
        var name: String
        var artists: [String]
        /// Empty unless every artist of the play had one.
        var artistURIs: [String]
        var album: String?
        var cover: URL?
        var durationMs: Int
        var plays: Int
        var seconds: Int

        var artistLine: String { artists.joined(separator: ", ") }
    }

    struct Bar: Equatable, Sendable {
        var start: Date
        var seconds = 0
        var plays = 0
    }

    var period: Period
    /// Time listened.
    var seconds = 0
    var plays = 0
    /// Different songs and different artists.
    var songs = 0
    var artists = 0
    /// By time listened; an artist featured on a song is credited with all of it.
    var topArtists: [Artist] = []
    /// By plays, then by time listened.
    var topSongs: [Song] = []
    /// Oldest first, every step of the period, including the empty ones.
    var bars: [Bar] = []
    var step = Step.day

    static let topCount = 10

    /// When `period` began.
    static func start(of period: Period, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        switch period {
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: return calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .all: return .distantPast
        }
    }

    /// `plays` in any order; those before the period are left out.
    init(plays all: [Play], period: Period, now: Date, calendar: Calendar) {
        self.period = period
        let start = Self.start(of: period, now: now, calendar: calendar)
        let plays = all.filter { $0.playedAt >= start }
        self.plays = plays.count

        var songs: [String: Song] = [:]
        var artists: [String: Artist] = [:]
        // The newest play of a song names it, so a retitled song shows its current title.
        for play in plays.sorted(by: { $0.playedAt > $1.playedAt }) {
            seconds += play.listenedSeconds
            // URIs were stored only for artists that had one; unless every one did, there's no telling whose is whose.
            let aligned = play.artistURIs.count == play.artists.count
            if var song = songs[play.uri] {
                song.plays += 1
                song.seconds += play.listenedSeconds
                songs[play.uri] = song
            } else {
                songs[play.uri] = Song(uri: play.uri, name: play.name, artists: play.artists, artistURIs: aligned ? play.artistURIs : [],
                                       album: play.album, cover: play.cover, durationMs: play.durationMs, plays: 1, seconds: play.listenedSeconds)
            }
            for (index, name) in play.artists.enumerated() {
                let uri = aligned ? play.artistURIs[index] : nil
                let key = uri ?? "name:\(name.lowercased())"
                var artist = artists[key] ?? Artist(id: key, name: name, uri: uri, seconds: 0, plays: 0)
                artist.seconds += play.listenedSeconds
                artist.plays += 1
                artists[key] = artist
            }
        }
        self.songs = songs.count
        self.artists = artists.count
        topArtists = Array(artists.values.sorted {
            ($0.seconds, $0.plays) != ($1.seconds, $1.plays) ? ($0.seconds, $0.plays) > ($1.seconds, $1.plays) : Self.before($0.name, $1.name, $0.id, $1.id)
        }.prefix(Self.topCount))
        topSongs = Array(songs.values.sorted {
            ($0.plays, $0.seconds) != ($1.plays, $1.seconds) ? ($0.plays, $0.seconds) > ($1.plays, $1.seconds) : Self.before($0.name, $1.name, $0.uri, $1.uri)
        }.prefix(Self.topCount))

        (step, bars) = Self.bars(for: period, oldest: plays.map(\.playedAt).min(), now: now, calendar: calendar)
        let starts = bars.map(\.start)
        for play in plays {
            // The last bar that starts at or before the play.
            var low = 0, high = starts.count
            while low < high {
                let middle = (low + high) / 2
                if starts[middle] <= play.playedAt { low = middle + 1 } else { high = middle }
            }
            guard low > 0 else { continue }
            bars[low - 1].seconds += play.listenedSeconds
            bars[low - 1].plays += 1
        }
    }

    /// Ties go by name, so a list doesn't reshuffle between two looks at it.
    private static func before(_ a: String, _ b: String, _ idA: String, _ idB: String) -> Bool {
        let order = a.localizedCaseInsensitiveCompare(b)
        return order == .orderedSame ? idA < idB : order == .orderedAscending
    }

    /// The empty bars of a period. Today goes by the hour, a week and a month
    /// by the day. All time goes by the day while that is a month's worth at
    /// most (never fewer than seven, so a history begun today is a week with
    /// one day in it rather than a single bar), then by the week up to half a
    /// year, then by the month.
    private static func bars(for period: Period, oldest: Date?, now: Date, calendar: Calendar) -> (Step, [Bar]) {
        let today = calendar.startOfDay(for: now)
        func days(_ count: Int) -> [Bar] {
            (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }.map { Bar(start: $0) }
        }
        switch period {
        case .today:
            // Counted from midnight in real hours, so a day the clocks change has 23 or 25.
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return (.hour, []) }
            return (.hour, stride(from: today, to: tomorrow, by: 3600).map { Bar(start: $0) })
        case .week:
            return (.day, days(7))
        case .month:
            return (.day, days(30))
        case .all:
            let first = calendar.startOfDay(for: min(oldest ?? now, now))
            let span = (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1
            if span <= 31 { return (.day, days(max(span, 7))) }
            let unit: Calendar.Component = span <= 182 ? .weekOfYear : .month
            guard var start = calendar.dateInterval(of: unit, for: first)?.start else { return (.day, days(7)) }
            var result: [Bar] = []
            while start <= now, let next = calendar.date(byAdding: unit, value: 1, to: start) {
                result.append(Bar(start: start))
                start = next
            }
            return (unit == .month ? .month : .week, result)
        }
    }
}

/// Every period at once, so changing the period on the page is instant.
struct ListeningSummary: Equatable, Sendable {
    var periods: [ListeningStats.Period: ListeningStats]
    /// When the oldest play kept was listened to: since when Tint has been counting.
    var since: Date?

    init(plays: [Play], now: Date, calendar: Calendar) {
        periods = Dictionary(uniqueKeysWithValues: ListeningStats.Period.allCases.map {
            ($0, ListeningStats(plays: plays, period: $0, now: now, calendar: calendar))
        })
        since = plays.map(\.playedAt).min()
    }

    subscript(period: ListeningStats.Period) -> ListeningStats {
        periods[period] ?? ListeningStats(plays: [], period: period, now: .now, calendar: .current)
    }
}
