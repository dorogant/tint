import Foundation
import Observation

/// What the Stats page shows, kept between visits: the listener's own numbers
/// from Tint's history, and Spotify's ranking of the account. The two are
/// different things (one is what played here, the other what Spotify counted
/// everywhere) and are never mixed.
@MainActor
@Observable
final class StatsModel {
    /// Spotify's top artists and songs over one stretch.
    struct Ranking: Sendable {
        var artists: [Artist]
        var tracks: [Track]
        var loaded: Date
    }

    /// From Tint's history; nil until first worked out.
    private(set) var summary: ListeningSummary?
    private(set) var rankings: [TopRange: Ranking] = [:]
    private(set) var rankingErrors: [TopRange: String] = [:]
    private(set) var loadingRanges: Set<TopRange> = []
    var period: ListeningStats.Period { didSet { defaults.set(period.rawValue, forKey: "statsPeriod") } }
    var range: TopRange { didSet { defaults.set(range.rawValue, forKey: "statsSpotifyRange") } }

    @ObservationIgnored private let defaults: UserDefaults
    /// Spotify refreshes its ranking about once a day.
    private static let rankingLife: TimeInterval = 3600

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        period = defaults.string(forKey: "statsPeriod").flatMap(ListeningStats.Period.init) ?? .week
        range = defaults.string(forKey: "statsSpotifyRange").flatMap(TopRange.init) ?? .weeks
    }

    /// Works the history out again, off the main actor: it can hold 20,000
    /// plays (25 ms for all four periods, measured by scripts/test-stats.sh).
    func load(_ history: ListeningHistory, now: Date = Date(), calendar: Calendar = .current) async {
        let fresh = await Self.summarize(history, now: now, calendar: calendar)
        if !Task.isCancelled, fresh != summary { summary = fresh }
    }

    @concurrent private nonisolated static func summarize(_ history: ListeningHistory, now: Date, calendar: Calendar) async -> ListeningSummary {
        ListeningSummary(plays: await history.plays(), now: now, calendar: calendar)
    }

    /// Spotify's ranking over `range`, unless it was loaded within the hour.
    func loadRanking(_ range: TopRange, api: WebAPI, again: Bool = false) async {
        if !again, let known = rankings[range], Date().timeIntervalSince(known.loaded) < Self.rankingLife { return }
        guard loadingRanges.insert(range).inserted else { return }
        defer { loadingRanges.remove(range) }
        rankingErrors[range] = nil
        do {
            async let artists = api.topArtists(over: range)
            async let tracks = api.topTracks(over: range)
            rankings[range] = Ranking(artists: try await artists, tracks: try await tracks, loaded: Date())
        } catch is CancellationError {
        } catch {
            rankingErrors[range] = error.localizedDescription
        }
    }
}
