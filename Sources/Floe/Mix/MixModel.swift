import Foundation
import Observation

/// The user's side of a mix: what Tint has played on this Mac and their
/// Spotify library. The app's is `MixSpotifyLibrary`; tests use a stub.
protocol MixLibrary: Sendable {
    /// Track IDs of what Tint played since `date`, newest first, one for each play.
    func listened(since date: Date) async -> [String]
    /// Track IDs of everything Tint has ever played.
    func heard() async -> Set<String>
    /// Track IDs of Spotify's recently played, newest first.
    func recentlyPlayed() async throws -> [String]
    /// One page of fifty liked songs, newest first, and how many there are.
    func likedSongs(offset: Int) async throws -> (tracks: [Track], total: Int)
    /// Which of these track IDs are liked.
    func liked(among ids: [String]) async throws -> Set<String>
    /// The song as Spotify has it, for its cover, album and artist links.
    func track(_ id: String) async throws -> Track
}

/// The two things a mix asks of the player. `PlayerModel` in the app.
@MainActor protocol MixPlayer: AnyObject {
    var playingURI: String? { get }
    /// Starts this one song now. False when nothing can play.
    func start(_ song: MixSong, details: Track?) -> Bool
    /// Adds the song to Spotify's queue. False when it couldn't be sent.
    func queue(_ song: MixSong) -> Bool
}

/// What the player reports when its song or its playing changes.
struct MixNowPlaying: Equatable, Sendable {
    var uri: String
    var title = ""
    var artists: [String] = []
    var isPlaying = true
    /// Within a few seconds of the song's end.
    var atEnd = false
}

/// A mix made to order: songs near what you've been listening to, chosen by
/// the questionnaire's answers and chosen again whenever a control is pressed
/// while it plays.
///
/// Spotify's queue can be added to but not cleared, so it only ever holds the
/// next two songs (`lookahead`). Everything further ahead lives here, where a
/// change of mind replaces it at once. The model belongs to the app, not the
/// page: it keeps feeding the queue with the window hidden. It runs no timer;
/// it acts when the player reports a new song, and does nothing while
/// playback is stopped.
@MainActor @Observable final class MixModel {
    enum Phase: Equatable {
        /// The questionnaire.
        case idle
        /// Gathering songs after the button was pressed.
        case preparing
        /// The first song was sent to the player and hasn't started yet.
        case starting
        case running
    }

    /// Why the last mix is over, for a line above the questionnaire.
    enum Ending: Equatable {
        /// It reached the length asked for.
        case complete
        /// Something that isn't the mix's started playing.
        case replaced
    }

    /// Where the songs the mix starts from really came from.
    enum Origin: Equatable { case today, week, liked, recentlyPlayed }

    enum Problem: Error, Equatable {
        /// No history, nothing recently played and no liked songs.
        case nothingToStartFrom
        case noLikedSongs
        /// The service knows none of the songs the mix would start from.
        case unknownSongs
        /// Songs came back, and the answers leave none of them.
        case nothingFits
        /// The player refused the first song.
        case cannotPlay
        case unreachable(String)
        case busy
        case service(String)
        case spotify(String)
    }

    /// Songs kept in Spotify's queue beyond the one playing. They can't be
    /// taken back, so this is how long a change takes to be heard.
    static let lookahead = 2
    /// Fewer songs than this still to play, and another batch is fetched.
    static let lowWater = 10
    /// How far ahead the mix chooses.
    static let ahead = 20
    /// Fetches in one go while too few songs fit. Each is one recommendation
    /// request and up to three for features.
    static let fetchesAtOnce = 3
    /// Fewer distinct songs than this in the history is too thin to start from.
    static let thinHistory = 5
    /// Candidates kept for choosing again; the oldest go first.
    static let poolLimit = 300
    private static let likedPage = 50

    /// The questionnaire's answers, remembered between launches.
    var draft: MixRecipe {
        didSet { if draft != oldValue { draft.save(in: defaults) } }
    }
    /// The running mix's answers, which its live controls change.
    private(set) var recipe = MixRecipe()
    private(set) var phase = Phase.idle
    private(set) var ending: Ending?
    private(set) var problem: Problem?
    /// Set when it differs from what was asked ("today" that was too thin).
    private(set) var origin: Origin?
    /// Liked songs were to be left out and Spotify couldn't say which they are.
    private(set) var likedUnchecked = false
    /// A fetch is under way.
    private(set) var isChoosing = false
    private(set) var current: MixSong?
    /// Handed to Spotify and not played yet: at most `lookahead`.
    private(set) var queued: [MixSong] = []
    /// Chosen and still the mix's own, so a control can replace them.
    private(set) var upcoming: [MixSong] = []
    /// Milliseconds of the songs before the one playing.
    private(set) var playedMs = 0
    /// Songs as Spotify has them, looked up for the rows on screen.
    private(set) var details: [String: Track] = [:]

    @ObservationIgnored private let catalog: any MixCatalog
    @ObservationIgnored private let library: any MixLibrary
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    /// Picks which page of liked songs to read next; tests make it predictable.
    @ObservationIgnored var randomPage: (Range<Int>) -> Int = { Int.random(in: $0) }
    @ObservationIgnored private weak var player: (any MixPlayer)?

    // The session. Everything below is reset by `clear()`.
    /// Bumped whenever a mix starts or ends, so work begun for an earlier one stops.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var seeds = MixSeeds()
    @ObservationIgnored private var seedFeatures: [String: MixFeatures]?
    /// Every candidate that hasn't been handed out or removed, chosen or not.
    @ObservationIgnored private var pool: [MixCandidate] = []
    @ObservationIgnored private var batch = 0
    /// Every song given to the player, in order.
    @ObservationIgnored private var handed: [MixSong] = []
    @ObservationIgnored private var position: Int?
    /// Handed-out songs that have played or were skipped past.
    @ObservationIgnored private var done: Set<String> = []
    @ObservationIgnored private var handedMs = 0
    @ObservationIgnored private var removed: Set<String> = []
    @ObservationIgnored private var heard: Set<String> = []
    @ObservationIgnored private var likedIDs: Set<String> = []
    @ObservationIgnored private var likedChecked: Set<String> = []
    @ObservationIgnored private var featuresAsked: Set<String> = []
    /// Other IDs Spotify played a handed-out song under.
    @ObservationIgnored private var aliases: [String: String] = [:]
    @ObservationIgnored private var likedTotal: Int?
    @ObservationIgnored private var likedPagesRead: Set<Int> = []
    /// Nothing more can be fetched: every liked page read, or no seed left.
    @ObservationIgnored private var exhausted = false
    /// What was playing when the mix began, which isn't a reason to end it.
    @ObservationIgnored private var playingBefore: String?
    @ObservationIgnored private var refillPending = false

    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var lookups: Task<Void, Never>?
    @ObservationIgnored private var lookupQueue: [String] = []
    @ObservationIgnored private var lookupFailed: Set<String> = []

    init(catalog: any MixCatalog, library: any MixLibrary, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.catalog = catalog
        self.library = library
        self.defaults = defaults
        self.now = now
        draft = MixRecipe.saved(in: defaults)
    }

    func attach(_ player: any MixPlayer) {
        self.player = player
    }

    var isActive: Bool { phase == .starting || phase == .running }
    /// The length asked for, in milliseconds; nil keeps going.
    var lengthMs: Int? { recipe.length.milliseconds }
    /// Everything the length allows has been handed to the player.
    var lengthReached: Bool { lengthMs.map { handedMs >= $0 } ?? false }

    // MARK: - Starting and stopping

    /// The questionnaire's button: gathers songs and starts the first.
    func create() {
        guard phase == .idle else { return }
        clear()
        recipe = draft
        ending = nil
        problem = nil
        phase = .preparing
        let run = generation
        enqueue { await $0.prepare(run) }
    }

    /// Back to the questionnaire. Playback is left alone: the songs already in
    /// Spotify's queue still play, and nothing more is added.
    func stop() {
        guard phase != .idle else { return }
        clear()
        ending = nil
        problem = nil
        phase = .idle
    }

    func dismissProblem() { problem = nil }

    /// After a fetch failed while the mix plays.
    func retry() {
        guard isActive, !refillPending else { return }
        problem = nil
        refill()
    }

    private func finish(_ ending: Ending) {
        clear()
        self.ending = ending
        problem = nil
        phase = .idle
    }

    private func clear() {
        generation += 1
        seeds = MixSeeds()
        seedFeatures = nil
        pool = []
        batch = 0
        handed = []
        position = nil
        done = []
        handedMs = 0
        removed = []
        heard = []
        likedIDs = []
        likedChecked = []
        featuresAsked = []
        aliases = [:]
        likedTotal = nil
        likedPagesRead = []
        exhausted = false
        playingBefore = nil
        refillPending = false
        origin = nil
        likedUnchecked = false
        isChoosing = false
        current = nil
        queued = []
        upcoming = []
        playedMs = 0
    }

    private func prepare(_ run: Int) async {
        heard = await library.heard()
        guard run == generation else { return }
        if recipe.liked != .only {
            do {
                try await gatherSeeds(run)
            } catch {
                return fail(run, error)
            }
        }
        await stock(run, always: true)
        guard run == generation else { return }
        guard let first = upcoming.first else {
            return fail(run, problem ?? Problem.nothingFits)
        }
        upcoming.removeFirst()
        hand(first)
        playingBefore = player?.playingURI
        phase = .starting
        if player?.start(first, details: details[first.id]) != true { fail(run, Problem.cannotPlay) }
    }

    /// A mix that couldn't begin: back to the questionnaire, with the reason.
    private func fail(_ run: Int, _ error: any Error) {
        guard run == generation, let reason = Self.problem(for: error) else { return }
        clear()
        problem = reason
        phase = .idle
    }

    // MARK: - The songs to start from

    /// "Today" and "this week" come from Tint's own history. Too thin (it is
    /// empty the day this ships), and Spotify's recently played joins it; with
    /// nothing there either, the newest liked songs. `origin` says which.
    private func gatherSeeds(_ run: Int) async throws {
        var listened: [String] = []
        switch recipe.source {
        case .today, .week:
            let since = recipe.source == .today
                ? Calendar.current.startOfDay(for: now())
                : now().addingTimeInterval(-7 * 86_400)
            listened = await library.listened(since: since)
            origin = recipe.source == .today ? .today : .week
            if Set(listened).count < Self.thinHistory {
                if let recent = try? await library.recentlyPlayed(), !recent.isEmpty {
                    listened += recent
                    origin = .recentlyPlayed
                } else if listened.isEmpty, let liked = try? await likedSeeds(), !liked.isEmpty {
                    listened = liked
                    origin = .liked
                }
            }
        case .liked:
            do {
                listened = try await likedSeeds()
            } catch {
                throw Problem.spotify(error.localizedDescription)
            }
            origin = .liked
        }
        try check(run)
        seeds = MixSeeds(listened: listened)
        if seeds.isEmpty { throw Problem.nothingToStartFrom }
    }

    /// The newest fifty liked songs and, in a larger library, one more page
    /// from anywhere in it.
    private func likedSeeds() async throws -> [String] {
        let first = try await library.likedSongs(offset: 0)
        var tracks = first.tracks
        let pages = (first.total + Self.likedPage - 1) / Self.likedPage
        if pages > 1, let more = try? await library.likedSongs(offset: randomPage(1..<pages) * Self.likedPage) {
            tracks += more.tracks
        }
        return tracks.compactMap(\.id)
    }

    // MARK: - Fetching

    /// Fetches until enough songs fit, at most `fetchesAtOnce` times, choosing
    /// after each. With `always`, at least once: a refill always brings songs
    /// from other seeds, so the mix doesn't circle the same neighbours. A
    /// refill adds to what's chosen; after a steer (`replacing`) each fetch
    /// chooses everything again, so better fits take the place of the best
    /// there was a moment ago.
    private func stock(_ run: Int, always: Bool, replacing: Bool = false) async {
        var fetches = 0
        while run == generation, !exhausted, !planIsFull, fetches < Self.fetchesAtOnce,
              (always && fetches == 0) || isShort {
            isChoosing = true
            do {
                try await fetch(run)
                problem = nil
            } catch {
                guard run == generation else { return }
                problem = Self.problem(for: error)
                if replacing { rechoose() } else { extend() }
                break
            }
            fetches += 1
            if replacing { rechoose() } else { extend() }
        }
        guard run == generation else { return }
        isChoosing = false
        refillPending = false
        if upcoming.isEmpty, queued.isEmpty, problem == nil, !lengthReached { problem = .nothingFits }
        topUp()
    }

    private func fetch(_ run: Int) async throws {
        if recipe.liked == .only {
            try await fetchLiked(run)
        } else {
            try await fetchRecommended(run)
        }
        // The oldest leftovers go first; what's already chosen stays.
        if pool.count > Self.poolLimit {
            let chosen = Set(upcoming.map(\.id))
            var extra = pool.count - Self.poolLimit
            pool.removeAll { candidate in
                guard extra > 0, !chosen.contains(candidate.song.id) else { return false }
                extra -= 1
                return true
            }
        }
    }

    /// One recommendation request, then the features of what's new in it and,
    /// if liked songs are left out, which of them are liked.
    private func fetchRecommended(_ run: Int) async throws {
        if recipe.steers, seedFeatures == nil {
            // The best forty of the source are enough to find the ones that fit: one request.
            seedFeatures = try await catalog.features(for: seeds.source.prefix(ReccoBeats.featureBatch).map(\.id))
            try check(run)
        }
        var songs: [MixSong] = []
        while true {
            let ids = seeds.next(for: recipe, features: seedFeatures ?? [:], stones: stones())
            guard !ids.isEmpty else {
                exhausted = true
                throw Problem.unknownSongs
            }
            do {
                songs = try await catalog.recommendations(seeds: ids, valence: recipe.mood.target, energy: recipe.energy.target)
                try check(run)
                break
            } catch ReccoBeats.Failure.unknownSeeds {
                try check(run)
                seeds.drop(ids)
            }
        }
        batch += 1
        add(songs)
        try await ensureFeatures(run)
        if recipe.liked == .leaveOut { await ensureLikedKnown(run) }
        try check(run)
    }

    /// "Only liked songs" needs no recommendations: two pages of the library
    /// from anywhere in it, and their features only if the mix steers. With
    /// mood and energy on Any nothing is sent to ReccoBeats at all.
    private func fetchLiked(_ run: Int) async throws {
        do {
            var read = 0
            if likedTotal == nil {
                try await readLikedPage(0, run)
                read += 1
            }
            let pages = ((likedTotal ?? 0) + Self.likedPage - 1) / Self.likedPage
            while read < 2 {
                let unread = (0..<pages).filter { !likedPagesRead.contains($0) }
                guard !unread.isEmpty else { break }
                try await readLikedPage(unread[randomPage(0..<unread.count)], run)
                read += 1
            }
            if likedPagesRead.count >= pages { exhausted = true }
        } catch let error where !(error is CancellationError) {
            throw Problem.spotify(error.localizedDescription)
        }
        if likedTotal == 0 { throw Problem.noLikedSongs }
        if recipe.steers { try await ensureFeatures(run) }
    }

    private func readLikedPage(_ page: Int, _ run: Int) async throws {
        let answer = try await library.likedSongs(offset: page * Self.likedPage)
        try check(run)
        likedTotal = answer.total
        likedPagesRead.insert(page)
        batch += 1
        let playable = answer.tracks.filter { $0.isPlayable != false && $0.isLocal != true }
        for track in playable { if let id = track.id { details[id] = track } }
        add(playable.compactMap(MixSong.init))
    }

    private func add(_ songs: [MixSong]) {
        var known = Set(pool.map(\.song.id)).union(handed.map(\.id)).union(removed)
        let fresh = songs.filter { known.insert($0.id).inserted }
        pool += fresh.enumerated().map { MixCandidate(song: $1, features: nil, batch: batch, order: $0) }
    }

    /// Features for every candidate not asked about yet. Songs the service
    /// doesn't know stay without, and aren't asked about again.
    private func ensureFeatures(_ run: Int) async throws {
        let ids = pool.map(\.song.id).filter { !featuresAsked.contains($0) }
        guard !ids.isEmpty else { return }
        let features = try await catalog.features(for: ids)
        try check(run)
        featuresAsked.formUnion(ids)
        for index in pool.indices {
            if let found = features[pool[index].song.id] { pool[index].features = found }
        }
    }

    /// A failure here doesn't stop the mix; the page says liked songs may slip in.
    private func ensureLikedKnown(_ run: Int) async {
        let ids = pool.map(\.song.id).filter { !likedChecked.contains($0) }
        guard !ids.isEmpty else { return }
        do {
            let liked = try await library.liked(among: ids)
            guard run == generation else { return }
            likedIDs.formUnion(liked)
            likedChecked.formUnion(ids)
            likedUnchecked = false
        } catch {
            guard run == generation else { return }
            likedUnchecked = true
        }
    }

    private func check(_ run: Int) throws {
        if run != generation { throw CancellationError() }
    }

    private static func problem(for error: any Error) -> Problem? {
        switch error {
        case let problem as Problem: problem
        case is CancellationError: nil
        case ReccoBeats.Failure.unknownSeeds: .unknownSongs
        case ReccoBeats.Failure.busy: .busy
        case let ReccoBeats.Failure.rejected(detail): .service(detail)
        case let ReccoBeats.Failure.server(status): .service("HTTP \(status)")
        case ReccoBeats.Failure.unreadable: .service("")
        case let error as URLError: .unreachable(error.localizedDescription)
        default: .service(error.localizedDescription)
        }
    }

    // MARK: - Choosing

    private var exclusions: MixChooser.Exclusions {
        MixChooser.Exclusions(ids: seeds.ids.union(handed.map(\.id)).union(removed), liked: likedIDs, heard: heard)
    }

    private var upcomingMs: Int { upcoming.reduce(0) { $0 + $1.durationMs } }
    /// What's handed out and what's chosen already fill the length asked for.
    private var planIsFull: Bool { lengthMs.map { handedMs + upcomingMs >= $0 } ?? false }
    /// Too few songs that fit are left to keep the mix going.
    private var isShort: Bool {
        !planIsFull && queued.count + MixChooser.fitting(pool, recipe, exclusions) < Self.lowWater
    }
    /// Too few songs are left to play, whatever the pool holds.
    private var isLow: Bool { !planIsFull && queued.count + upcoming.count < Self.lowWater }

    /// The songs found so far that are nearest to what's asked, as seeds for a
    /// fetch that steps further toward it when nothing in the source has the
    /// mood. They needn't fit yet: of 88 songs around three pop hits none was
    /// both sad and calm, and the nearest ones are the way there.
    private func stones() -> [String] {
        guard recipe.steers else { return [] }
        return pool.compactMap { candidate in candidate.features.map { (candidate.song.id, $0) } }
            .filter { !recipe.mood.refusesMisfits || recipe.mood.fits($0.1.valence) }
            .sorted { MixChooser.distance($0.1, to: recipe) < MixChooser.distance($1.1, to: recipe) }
            .prefix(2 * ReccoBeats.seedLimit).map(\.0)
    }

    /// Adds to what's chosen, keeping the songs already listed where they are.
    private func extend() {
        let chosen = Set(upcoming.map(\.id))
        let ranked = MixChooser.ranked(pool.filter { !chosen.contains($0.song.id) }, recipe, exclusions)
        let budget = lengthMs.map { $0 - handedMs - upcomingMs }
        upcoming += MixChooser.pick(ranked, count: Self.ahead - upcoming.count, after: upcoming.last ?? handed.last,
                                    budgetMs: budget).map(\.song)
    }

    /// Chooses everything not handed to Spotify again, from all the candidates.
    private func rechoose() {
        let ranked = MixChooser.ranked(pool, recipe, exclusions)
        upcoming = MixChooser.pick(ranked, count: Self.ahead, after: handed.last,
                                   budgetMs: lengthMs.map { $0 - handedMs }).map(\.song)
    }

    // MARK: - Steering

    /// A live control: one stop sadder, the "nothing I've heard" switch and so
    /// on. Everything not yet handed to Spotify is chosen again at once from
    /// the songs already found, and more are fetched if too few of them fit.
    func steer(_ change: (inout MixRecipe) -> Void) {
        guard isActive else { return }
        var changed = recipe
        change(&changed)
        // The source and the length belong to the questionnaire.
        changed.source = recipe.source
        changed.length = recipe.length
        if recipe.liked == .only { changed.liked = .only } else if changed.liked == .only { changed.liked = recipe.liked }
        guard changed != recipe else { return }
        recipe = changed
        problem = nil
        rechoose()
        let run = generation
        enqueue { await $0.resettle(run) }
    }

    /// The network's part of a steer: what the new answers need to know about
    /// the candidates, then more candidates if they don't fit.
    private func resettle(_ run: Int) async {
        guard run == generation else { return }
        isChoosing = true
        if recipe.liked == .leaveOut { await ensureLikedKnown(run) }
        if recipe.steers { try? await ensureFeatures(run) }
        guard run == generation else { return }
        rechoose()
        await stock(run, always: false, replacing: true)
    }

    /// Takes a song out of what's next, for good.
    func remove(_ song: MixSong) {
        guard upcoming.contains(song) else { return }
        removed.insert(song.id)
        upcoming.removeAll { $0.id == song.id }
        pool.removeAll { $0.song.id == song.id }
    }

    // MARK: - Following the player

    /// The player's song or its playing changed. This is the mix's only clock.
    func playerChanged(_ now: MixNowPlaying?) {
        guard isActive, let now else { return }
        guard let index = handedIndex(of: now) else {
            // The song from before the mix can report once more while the first one loads.
            if phase == .starting, now.uri == playingBefore { return }
            // Something else plays: the user's choice. Let go, and add nothing more.
            return finish(lengthReached && queued.isEmpty ? .complete : .replaced)
        }
        phase = .running
        position = index
        for song in handed[...index] { done.insert(song.id) }
        current = handed[index]
        playedMs = handed[..<index].reduce(0) { $0 + $1.durationMs }
        refreshQueued()
        if lengthReached, queued.isEmpty, upcoming.isEmpty, !now.isPlaying, now.atEnd { return finish(.complete) }
        topUp()
        // Nothing is fetched while playback is stopped.
        if now.isPlaying, isLow { refill() }
    }

    private func refill() {
        guard !refillPending, !exhausted else { return }
        refillPending = true
        let run = generation
        enqueue { await $0.stock(run, always: true) }
    }

    private func handedIndex(of now: MixNowPlaying) -> Int? {
        if let index = handed.firstIndex(where: { $0.uri == now.uri || aliases[now.uri] == $0.id }) { return index }
        // Spotify can play a queued song under another ID. Among the songs still
        // owed, the same title by the same artist is that song.
        guard let index = handed.firstIndex(where: { !done.contains($0.id) && MixChooser.same($0, title: now.title, artists: now.artists) })
        else { return nil }
        aliases[now.uri] = handed[index].id
        return index
    }

    private func refreshQueued() {
        let after = position.map { $0 + 1 } ?? 0
        queued = handed.dropFirst(after).filter { !done.contains($0.id) }
    }

    /// Keeps Spotify's queue at `lookahead` songs, while the mix is what plays.
    private func topUp() {
        guard phase == .running, let player else { return }
        while queued.count < Self.lookahead, !lengthReached, let next = upcoming.first {
            guard player.queue(next) else { break }
            upcoming.removeFirst()
            hand(next)
        }
    }

    private func hand(_ song: MixSong) {
        handed.append(song)
        handedMs += song.durationMs
        pool.removeAll { $0.song.id == song.id }
        refreshQueued()
    }

    // MARK: - Covers and links for the rows on screen

    /// A row came on screen. Songs are looked up on Spotify one at a time and
    /// kept for the session; the candidates never shown are never asked about.
    func wantDetails(for song: MixSong) {
        guard details[song.id] == nil, !lookupFailed.contains(song.id), !lookupQueue.contains(song.id) else { return }
        lookupQueue.append(song.id)
        guard lookups == nil else { return }
        lookups = Task { [weak self] in await self?.runLookups() }
    }

    private func runLookups() async {
        while let id = lookupQueue.first {
            if let track = try? await library.track(id) {
                // Under the mix's own ID, whichever one Spotify answered with.
                details[id] = track
            } else {
                lookupFailed.insert(id)
            }
            lookupQueue.removeAll { $0 == id }
        }
        lookups = nil
    }

    // MARK: - One thing at a time

    /// Network work runs in turn, in the order it was asked for, so two
    /// fetches never choose over each other. Each piece checks `generation`
    /// and stops if its mix is over.
    private func enqueue(_ operation: @escaping @MainActor (MixModel) async -> Void) {
        let previous = work
        work = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
        }
    }

    /// Returns once nothing is in flight. For tests and renders.
    func settled() async {
        while let running = work {
            await running.value
            if work == running { work = nil }
        }
        await lookups?.value
    }
}

extension MixSong {
    /// A song of the user's library, as a mix candidate.
    init?(_ track: Track) {
        guard let id = track.id, MixSong.isTrackID(id), track.isCatalogTrack else { return nil }
        self.init(id: id, title: track.name, artists: track.artists.map(\.name), durationMs: track.durationMs)
    }
}
