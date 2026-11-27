import Foundation

/// The Stats page's own numbers against a history written by hand: every
/// figure of every period, where the periods begin in the listener's time
/// zone (across a clock change too), ties, and what the chart's bars cover.
@main
struct StatsTests {
    nonisolated(unsafe) static var checks = 0

    /// Kyiv: two hours ahead of UTC in winter, three in summer, clocks back on 25 October 2026.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        calendar.locale = Locale(identifier: "uk_UA")
        return calendar
    }()

    /// "2026-11-20 09:00" or "2026-11-20 09:00:59", on the listener's clock.
    static func at(_ text: String) -> Date {
        let parts = text.split(whereSeparator: { "- :".contains($0) }).compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4],
                                                  second: parts.count > 5 ? parts[5] : 0))!
    }

    static func play(_ id: String, _ name: String, by artists: [String], uris: [String]? = nil, _ when: String, seconds: Int) -> Play {
        Play(uri: "spotify:track:\(id)", name: name, artists: artists,
             artistURIs: uris ?? artists.map { "spotify:artist:\($0.lowercased())" }, album: "Album \(id)",
             cover: URL(string: "https://i.scdn.co/image/\(id)"), durationMs: 200_000, playedAt: at(when), listenedSeconds: seconds)
    }

    static func main() async {
        periods()
        ties()
        charts()
        await history()
        print("PASS: \(checks) stats checks (every period's numbers at local day boundaries, top lists and ties, the chart's bars, an empty history, plays that went on)")
    }

    static func periods() {
        let now = at("2026-11-20 15:30")
        let plays = [
            play("a", "Alpha", by: ["X"], "2026-11-20 09:00", seconds: 200),
            play("a", "Alpha", by: ["X"], "2026-11-20 10:00", seconds: 100),            // the same song again
            play("b", "Beta", by: ["X", "Y"], "2026-11-20 00:00", seconds: 60),          // the first second of today
            play("c", "Gamma", by: ["Z"], uris: [], "2026-11-19 23:59:59", seconds: 300), // the last of yesterday, and it ran past midnight
            play("d", "Delta", by: ["Y"], "2026-11-14 00:00", seconds: 120),             // the first second of the seven days
            play("e", "Epsilon", by: ["W"], "2026-11-13 23:59:59", seconds: 500),        // one second too old for them
            play("f", "Zeta", by: ["W"], "2026-10-22 00:00", seconds: 30),               // the first second of the thirty days, in summer time
            play("g", "Eta", by: ["V"], "2026-10-21 23:59:59", seconds: 1000),           // one second too old for those
        ]
        // Order mustn't matter.
        let summary = ListeningSummary(plays: plays.shuffled(), now: now, calendar: calendar)

        check(ListeningStats.start(of: .today, now: now, calendar: calendar) == at("2026-11-20 00:00")
              && ListeningStats.start(of: .week, now: now, calendar: calendar) == at("2026-11-14 00:00")
              && ListeningStats.start(of: .month, now: now, calendar: calendar) == at("2026-10-22 00:00"),
              "periods must begin at the listener's midnights, across the clock change too")

        let today = summary[.today]
        check(today.plays == 3 && today.seconds == 360 && today.songs == 2 && today.artists == 2,
              "today: 3 plays, 6 minutes, 2 songs, 2 artists (\(today.plays), \(today.seconds), \(today.songs), \(today.artists))")
        check(today.topSongs.map(\.name) == ["Alpha", "Beta"] && today.topSongs[0].plays == 2 && today.topSongs[0].seconds == 300,
              "a song played twice is one song with two plays (\(today.topSongs.map { "\($0.name) \($0.plays)" }))")
        check(today.topArtists.map(\.name) == ["X", "Y"] && today.topArtists[0].seconds == 360 && today.topArtists[0].plays == 3
              && today.topArtists[1].seconds == 60, "a featured artist is credited with the song too (\(today.topArtists))")

        let week = summary[.week]
        check(week.plays == 5 && week.seconds == 780 && week.songs == 4 && week.artists == 3,
              "seven days: 5 plays, 13 minutes, 4 songs, 3 artists (\(week.plays), \(week.seconds), \(week.songs), \(week.artists))")
        check(week.topArtists.map(\.name) == ["X", "Z", "Y"] && week.topArtists.map(\.seconds) == [360, 300, 180],
              "artists go by time listened, not by plays (\(week.topArtists.map { "\($0.name) \($0.seconds)" }))")
        check(week.topSongs.map(\.name) == ["Alpha", "Gamma", "Delta", "Beta"],
              "songs go by plays, then by time (\(week.topSongs.map(\.name)))")
        check(week.topArtists[1].uri == nil && week.topArtists[0].uri == "spotify:artist:x", "an artist stored without a link has none to open")

        let month = summary[.month]
        check(month.plays == 7 && month.seconds == 1310 && month.songs == 6 && month.artists == 4,
              "thirty days: 7 plays, 1310 s, 6 songs, 4 artists (\(month.plays), \(month.seconds), \(month.songs), \(month.artists))")
        check(month.topArtists.first?.name == "W" && month.topArtists.first?.seconds == 530 && month.topArtists.first?.plays == 2,
              "an artist's time adds up over their songs (\(String(describing: month.topArtists.first)))")

        let all = summary[.all]
        check(all.plays == 8 && all.seconds == 2310 && all.songs == 7 && all.artists == 5 && all.topArtists.first?.name == "V",
              "all time: 8 plays, 2310 s, 7 songs, 5 artists (\(all.plays), \(all.seconds), \(all.songs), \(all.artists))")
        check(summary.since == at("2026-10-21 23:59:59"), "counting since the oldest play (\(String(describing: summary.since)))")

        // The bars.
        check(today.step == .hour && today.bars.count == 24 && today.bars[0].start == at("2026-11-20 00:00")
              && today.bars.map(\.seconds).enumerated().filter { $0.element > 0 }.map { "\($0.offset):\($0.element)" } == ["0:60", "9:200", "10:100"],
              "today is drawn by the hour (\(today.bars.map(\.seconds)))")
        check(week.step == .day && week.bars.map(\.start) == (14...20).map { at("2026-11-\($0) 00:00") }
              && week.bars.map(\.seconds) == [120, 0, 0, 0, 0, 300, 360] && week.bars.map(\.plays) == [1, 0, 0, 0, 0, 1, 3],
              "a week is seven days, the empty ones included, each play on the day it began (\(week.bars.map(\.seconds)))")
        check(month.step == .day && month.bars.count == 30 && month.bars[0].start == at("2026-10-22 00:00") && month.bars[0].seconds == 30
              && month.bars[22].start == at("2026-11-13 00:00") && month.bars[22].seconds == 500 && month.bars[29].seconds == 360,
              "thirty days begin at local midnights before and after the clocks changed (\(month.bars.map(\.seconds)))")
        check(month.bars.reduce(0) { $0 + $1.seconds } == month.seconds && month.bars.reduce(0) { $0 + $1.plays } == month.plays,
              "the bars add up to the totals")
        check(all.step == .day && all.bars.count == 31 && all.bars[0].start == at("2026-10-21 00:00") && all.bars[0].seconds == 1000,
              "a month of history is drawn by the day, from its first (\(all.bars.count) bars)")

        // An empty history: zeros and empty bars, never a crash or a missing chart.
        let empty = ListeningSummary(plays: [], now: now, calendar: calendar)
        check(empty.since == nil && ListeningStats.Period.allCases.allSatisfy {
            let stats = empty[$0]
            return stats.plays == 0 && stats.seconds == 0 && stats.songs == 0 && stats.artists == 0 && stats.topArtists.isEmpty
                && stats.topSongs.isEmpty && stats.bars.allSatisfy { $0.seconds == 0 && $0.plays == 0 }
        }, "an empty history is all zeros")
        check(empty[.today].bars.count == 24 && empty[.week].bars.count == 7 && empty[.month].bars.count == 30 && empty[.all].bars.count == 7,
              "and still has its empty bars (\(ListeningStats.Period.allCases.map { empty[$0].bars.count }))")

        // The first day of a history: all time is a week with one day in it.
        let first = ListeningSummary(plays: [play("a", "Alpha", by: ["X"], "2026-11-20 09:00", seconds: 45)], now: now, calendar: calendar)
        check(first[.all].bars.count == 7 && first[.all].bars.map(\.seconds) == [0, 0, 0, 0, 0, 0, 45] && first.since == at("2026-11-20 09:00"),
              "a history begun today is seven bars with the last one filled (\(first[.all].bars.map(\.seconds)))")
    }

    static func ties() {
        let now = at("2026-11-20 15:30")
        var plays = [
            play("z", "Zed", by: ["Quinn"], "2026-11-20 09:00", seconds: 100),
            play("y", "abe", by: ["paula"], "2026-11-20 10:00", seconds: 100),
            play("x", "Mid", by: ["Paula"], uris: ["spotify:artist:other"], "2026-11-20 11:00", seconds: 100),
        ]
        var stats = ListeningStats(plays: plays, period: .today, now: now, calendar: calendar)
        check(stats.topSongs.map(\.name) == ["abe", "Mid", "Zed"], "songs level on plays and time go by name, whatever the case (\(stats.topSongs.map(\.name)))")
        check(stats.topArtists.map(\.id) == ["spotify:artist:other", "spotify:artist:paula", "spotify:artist:quinn"],
              "artists level on time go by name, and namesakes by their links (\(stats.topArtists.map(\.id)))")
        check(stats == ListeningStats(plays: plays.reversed(), period: .today, now: now, calendar: calendar), "the order plays come in changes nothing")

        // One artist under two spellings of the name: the link decides, the newest play names them.
        plays = [
            play("a", "One", by: ["Röyksopp"], uris: ["spotify:artist:r"], "2026-11-20 09:00", seconds: 50),
            play("b", "Two", by: ["Royksopp"], uris: ["spotify:artist:r"], "2026-11-20 10:00", seconds: 70),
            // Two artists and one link: nobody can say whose it is, so both go by name.
            play("c", "Three", by: ["Solo", "Guest"], uris: ["spotify:artist:guest"], "2026-11-20 11:00", seconds: 40),
        ]
        stats = ListeningStats(plays: plays, period: .today, now: now, calendar: calendar)
        check(stats.artists == 3 && stats.topArtists.first == .init(id: "spotify:artist:r", name: "Royksopp", uri: "spotify:artist:r", seconds: 120, plays: 2),
              "one link is one artist (\(stats.topArtists))")
        check(stats.topArtists.dropFirst().allSatisfy { $0.uri == nil } && stats.topSongs.first { $0.uri == "spotify:track:c" }?.artistURIs == [],
              "links that don't pair up with the names are dropped")

        // More than the lists hold.
        plays = (0..<15).map { play("s\($0)", "Song \($0)", by: ["Artist \($0)"], "2026-11-20 09:00", seconds: 30 + $0) }
        stats = ListeningStats(plays: plays, period: .today, now: now, calendar: calendar)
        check(stats.topArtists.count == 10 && stats.topSongs.count == 10 && stats.songs == 15 && stats.artists == 15
              && stats.topArtists.first?.name == "Artist 14", "the lists hold ten; the counts count everything")
    }

    static func charts() {
        // The day the clocks go back has 25 hours, the day they go forward 23.
        let autumn = ListeningStats(plays: [play("a", "A", by: ["X"], "2026-10-25 12:00", seconds: 60)], period: .today,
                                    now: at("2026-10-25 20:00"), calendar: calendar)
        check(autumn.bars.count == 25 && autumn.bars.reduce(0) { $0 + $1.plays } == 1 && autumn.bars[13].plays == 1,
              "the day the clocks go back is 25 bars, noon in the fourteenth (\(autumn.bars.count))")
        let spring = ListeningStats(plays: [], period: .today, now: at("2026-03-29 20:00"), calendar: calendar)
        check(spring.bars.count == 23, "the day they go forward is 23 (\(spring.bars.count))")

        // Two months of history go by the week, from the week of the first play to this one.
        let now = at("2026-11-20 15:30") // a Friday; weeks begin on Monday here
        var plays = [play("a", "A", by: ["X"], "2026-09-23 18:00", seconds: 100), play("b", "B", by: ["X"], "2026-11-20 09:00", seconds: 50),
                     play("c", "C", by: ["X"], "2026-11-15 23:00", seconds: 25)]
        var stats = ListeningStats(plays: plays, period: .all, now: now, calendar: calendar)
        check(stats.step == .week && stats.bars.first?.start == at("2026-09-21 00:00") && stats.bars.last?.start == at("2026-11-16 00:00")
              && stats.bars.count == 9, "two months are drawn by the week, Monday to Monday (\(stats.bars.count) bars from \(String(describing: stats.bars.first?.start)))")
        check(stats.bars.first?.seconds == 100 && stats.bars.last?.seconds == 50 && stats.bars[7].seconds == 25
              && stats.bars.reduce(0) { $0 + $1.plays } == 3, "each play in its week (\(stats.bars.map(\.seconds)))")

        // Over half a year goes by the month.
        plays.append(play("d", "D", by: ["X"], "2025-10-31 23:30", seconds: 75))
        stats = ListeningStats(plays: plays, period: .all, now: now, calendar: calendar)
        check(stats.step == .month && stats.bars.count == 14 && stats.bars.first?.start == at("2025-10-01 00:00") && stats.bars.first?.seconds == 75
              && stats.bars.last?.start == at("2026-11-01 00:00") && stats.bars.last?.seconds == 75 && stats.bars[11].seconds == 100,
              "a year is drawn by the month (\(stats.bars.count) bars, \(stats.bars.map(\.seconds)))")
        // The other periods keep their shape however old the history is.
        check(ListeningStats(plays: plays, period: .week, now: now, calendar: calendar).bars.count == 7, "a week stays seven bars")
    }

    /// Through the store itself: a play that goes on is written again, and counts once with its last length.
    static func history() async {
        let store = ListeningHistory(file: nil)
        let now = at("2026-11-20 15:30")
        await store.record(play("a", "Alpha", by: ["X"], "2026-11-20 09:00", seconds: 31))
        await store.record(play("a", "Alpha", by: ["X"], "2026-11-20 09:00", seconds: 180))
        await store.record(play("a", "Alpha", by: ["X"], "2026-11-20 09:10", seconds: 40))
        await store.record(play("b", "Beta", by: ["Y"], "2026-11-19 22:00", seconds: 60))
        let summary = ListeningSummary(plays: await store.plays(), now: now, calendar: calendar)
        check(summary[.today].plays == 2 && summary[.today].seconds == 220 && summary[.today].topSongs.first?.plays == 2,
              "a play that went on counts once, at its full length (\(summary[.today].plays) plays, \(summary[.today].seconds) s)")
        check(summary[.week].plays == 3 && summary[.week].seconds == 280 && summary.since == at("2026-11-19 22:00"), "and the day before is in the week")

        // The size the history can reach: the page's whole summary must not take long.
        let many = (0..<ListeningHistory.limit).map { index in
            Play(uri: "spotify:track:t\(index % 3000)", name: "Song \(index % 3000)", artists: ["Artist \(index % 400)", "Guest \(index % 37)"],
                 artistURIs: ["spotify:artist:a\(index % 400)", "spotify:artist:g\(index % 37)"], album: nil, cover: nil, durationMs: 200_000,
                 playedAt: now.addingTimeInterval(-Double(index) * 1700), listenedSeconds: 60 + index % 200)
        }
        let started = Date()
        let large = ListeningSummary(plays: many, now: now, calendar: calendar)
        let took = Date().timeIntervalSince(started)
        check(large[.all].plays == ListeningHistory.limit && large[.all].songs == 3000 && large[.all].step == .month && took < 2,
              "a full history of 20,000 plays must be summarised quickly (\(String(format: "%.0f", took * 1000)) ms)")
        print(String(format: "  20,000 plays, four periods: %.0f ms", took * 1000))
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition {
            print("FAIL: \(message())")
            exit(1)
        }
    }
}
