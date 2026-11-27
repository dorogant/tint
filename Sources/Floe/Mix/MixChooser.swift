import Foundation

/// What was asked for: the questionnaire's answers, and while a mix plays, its
/// live controls.
struct MixRecipe: Codable, Equatable, Sendable {
    enum Source: String, Codable, CaseIterable, Sendable { case today, week, liked }
    enum Liked: String, Codable, CaseIterable, Sendable { case leaveOut, allow, only }
    enum Length: String, Codable, CaseIterable, Sendable {
        case halfHour, hour, twoHours, endless

        /// nil keeps going.
        var milliseconds: Int? {
            switch self {
            case .halfHour: 30 * 60_000
            case .hour: 60 * 60_000
            case .twoHours: 120 * 60_000
            case .endless: nil
            }
        }
    }

    /// Five stops from sad to happy. Each has the valence it aims at and the
    /// band that counts as fitting it:
    ///
    ///     Sad     aims at 0 (the sadder the better), fits up to 0.40, and refuses everything above
    ///     Mellow  aims at 0.35, fits 0.15…0.55
    ///     Any     no aim
    ///     Bright  aims at 0.65, fits 0.45…0.85
    ///     Happy   aims at 1, fits from 0.60, and refuses everything below
    ///
    /// Only the two ends refuse: a mix asked to be sad never plays a cheerful
    /// song, however little else there is. The stops between rank by distance
    /// and take the nearest, so they always have something to play.
    enum Mood: Int, Codable, CaseIterable, Sendable {
        case sad, mellow, any, bright, happy

        var target: Double? {
            switch self {
            case .sad: 0
            case .mellow: 0.35
            case .any: nil
            case .bright: 0.65
            case .happy: 1
            }
        }

        func fits(_ valence: Double) -> Bool {
            switch self {
            case .sad: valence <= 0.40
            case .mellow: (0.15...0.55).contains(valence)
            case .any: true
            case .bright: (0.45...0.85).contains(valence)
            case .happy: valence >= 0.60
            }
        }

        var refusesMisfits: Bool { self == .sad || self == .happy }
        var sadder: Mood { Mood(rawValue: rawValue - 1) ?? self }
        var happier: Mood { Mood(rawValue: rawValue + 1) ?? self }
    }

    /// Calm aims at an energy of 0 (the calmer the better) and fits up to 0.50;
    /// Energetic aims at 1 and fits from 0.60. Neither refuses: they rank and
    /// take the nearest.
    enum Energy: Int, Codable, CaseIterable, Sendable {
        case calm, any, energetic

        var target: Double? {
            switch self {
            case .calm: 0
            case .any: nil
            case .energetic: 1
            }
        }

        func fits(_ energy: Double) -> Bool {
            switch self {
            case .calm: energy <= 0.50
            case .any: true
            case .energetic: energy >= 0.60
            }
        }

        var calmer: Energy { Energy(rawValue: rawValue - 1) ?? self }
        var livelier: Energy { Energy(rawValue: rawValue + 1) ?? self }
    }

    var source = Source.today
    var liked = Liked.leaveOut
    var skipHeard = true
    var mood = Mood.any
    var energy = Energy.any
    var length = Length.hour

    /// Whether songs have to be judged by how they sound.
    var steers: Bool { mood != .any || energy != .any }

    init() {}

    /// Lenient, so answers saved by an older build still load: a field that's
    /// missing or no longer understood takes its default.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? values.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        source = read(.source, source)
        liked = read(.liked, liked)
        skipHeard = read(.skipHeard, skipHeard)
        mood = read(.mood, mood)
        energy = read(.energy, energy)
        length = read(.length, length)
    }

    static let defaultsKey = "mixRecipe"

    static func saved(in defaults: UserDefaults) -> MixRecipe {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(MixRecipe.self, from: $0) } ?? MixRecipe()
    }

    func save(in defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// A song a mix could play: where it came from and, once asked for, how it sounds.
struct MixCandidate: Equatable, Sendable {
    var song: MixSong
    var features: MixFeatures?
    /// Which fetch brought it; later ones were seeded differently.
    var batch = 0
    /// Its place in that fetch's answer.
    var order = 0
}

/// Choosing songs for a mix: what may play, how well it fits, and in which
/// order. Pure, so every rule is tested without a network or a player.
enum MixChooser {
    /// What a mix leaves out whatever the mood.
    struct Exclusions: Equatable, Sendable {
        /// Track IDs: the songs the mix started from, the songs it has played or
        /// queued, and the ones removed by hand.
        var ids: Set<String> = []
        /// Track IDs of liked songs, left out when the recipe says so.
        var liked: Set<String> = []
        /// Track IDs of songs Tint has played before, left out when the recipe says so.
        var heard: Set<String> = []
    }

    /// How far a song is from what was asked: the gaps in valence and in
    /// energy, added. Zero when nothing was asked.
    static func distance(_ features: MixFeatures, to recipe: MixRecipe) -> Double {
        (recipe.mood.target.map { abs(features.valence - $0) } ?? 0)
            + (recipe.energy.target.map { abs(features.energy - $0) } ?? 0)
    }

    /// Inside the bands of the mood and the energy asked for. A song nobody has
    /// features for fits only a recipe that doesn't steer.
    static func fits(_ features: MixFeatures?, _ recipe: MixRecipe) -> Bool {
        guard let features else { return !recipe.steers }
        return recipe.mood.fits(features.valence) && recipe.energy.fits(features.energy)
    }

    /// Whether a song may play at all.
    static func allowed(_ candidate: MixCandidate, _ recipe: MixRecipe, _ exclusions: Exclusions) -> Bool {
        let id = candidate.song.id
        if exclusions.ids.contains(id) { return false }
        if recipe.liked == .leaveOut && exclusions.liked.contains(id) { return false }
        if recipe.skipHeard && exclusions.heard.contains(id) { return false }
        // Can't be judged, so it plays only when nothing is being judged.
        guard let features = candidate.features else { return !recipe.steers }
        if recipe.mood.refusesMisfits && !recipe.mood.fits(features.valence) { return false }
        return true
    }

    /// The songs that may play, best first: nearest to the mood and energy,
    /// then from the latest fetch (new neighbours before old leftovers), then
    /// in the order the service gave.
    static func ranked(_ pool: [MixCandidate], _ recipe: MixRecipe, _ exclusions: Exclusions) -> [MixCandidate] {
        pool.filter { allowed($0, recipe, exclusions) }
            .map { (candidate: $0, distance: $0.features.map { distance($0, to: recipe) } ?? 0) }
            .sorted { a, b in
                if a.distance != b.distance { return a.distance < b.distance }
                if a.candidate.batch != b.candidate.batch { return a.candidate.batch > b.candidate.batch }
                return a.candidate.order < b.candidate.order
            }
            .map(\.candidate)
    }

    /// How many of the songs that may play sit inside the bands asked for.
    static func fitting(_ pool: [MixCandidate], _ recipe: MixRecipe, _ exclusions: Exclusions) -> Int {
        pool.count { allowed($0, recipe, exclusions) && fits($0.features, recipe) }
    }

    /// The most songs one artist gets in a pick.
    static let perArtist = 2

    /// Up to `count` songs from `ranked`, kept in rank order except where that
    /// would put one artist twice in a row; no artist gets more than two. `after`
    /// is the song the first pick follows. With a `budgetMs`, picking stops at
    /// the song that reaches it, so a mix runs a little over its length, not under.
    static func pick(_ ranked: [MixCandidate], count: Int, after previous: MixSong? = nil, budgetMs: Int? = nil) -> [MixCandidate] {
        var remaining = ranked
        var picked: [MixCandidate] = []
        var songs: [String: Int] = [:]
        var last = Set((previous?.artists ?? []).map(artistKey))
        var spent = 0
        if let budgetMs, budgetMs <= 0 { return [] }
        while picked.count < count {
            // The best song left that neither repeats the artist before it nor is a third by its artist.
            guard let index = remaining.firstIndex(where: { candidate in
                let artists = candidate.song.artists.map(artistKey)
                return !artists.contains { last.contains($0) || songs[$0, default: 0] >= perArtist }
            }) else { break }
            let next = remaining.remove(at: index)
            let artists = next.song.artists.map(artistKey)
            for artist in Set(artists) { songs[artist, default: 0] += 1 }
            last = Set(artists)
            picked.append(next)
            spent += next.song.durationMs
            if let budgetMs, spent >= budgetMs { break }
        }
        return picked
    }

    static func artistKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The song playing as one a mix handed out, when Spotify plays it under
    /// another ID (the same recording licensed for another country): same
    /// title and at least one artist in common.
    static func same(_ song: MixSong, title: String, artists: [String]) -> Bool {
        guard !song.title.isEmpty, artistKey(song.title) == artistKey(title) else { return false }
        let theirs = Set(artists.map(artistKey))
        return song.artists.contains { theirs.contains(artistKey($0)) }
    }
}

/// One song a mix can start from, with how much it was listened to.
struct MixSeed: Equatable, Sendable {
    var id: String
    /// Times it appears in the source.
    var plays = 1
}

/// The songs a mix starts from and which of them seed each fetch.
///
/// ReccoBeats answers with songs around the seeds and ignores the mood asked
/// for (see `ReccoBeats`), so the seeds are how a mix gets anywhere: while it
/// steers, the songs of the source that already fit are the seeds, and when
/// none does, the nearest songs found so far are ("stones": each fetch steps
/// further toward the mood). Every fetch takes the seeds used longest ago, so
/// no two in a row ask about the same neighbourhood.
struct MixSeeds: Equatable, Sendable {
    /// Best first.
    private(set) var source: [MixSeed] = []
    /// The fetch each seed last went into; never used is 0.
    private var lastUsed: [String: Int] = [:]
    /// Seeds the service said it doesn't know.
    private(set) var unknown: Set<String> = []
    private var round = 0

    init() {}

    /// `listened` is every play, newest first; a song played more than once
    /// appears more than once.
    init(listened: [String]) {
        source = Self.ordered(listened)
    }

    var isEmpty: Bool { !source.contains { !unknown.contains($0.id) } }
    /// Every song of the source, for leaving them out of the mix.
    var ids: Set<String> { Set(source.map(\.id)) }

    /// The most listened and the most recent first: a song scores its number
    /// of plays plus up to two points for recency (2 for the latest, 1 for the
    /// one before, ⅔, ½ …), so three plays this morning outrank one play just
    /// now, and among songs played once the latest leads.
    static func ordered(_ listened: [String]) -> [MixSeed] {
        var plays: [String: Int] = [:]
        var firstSeen: [String] = []
        for id in listened where MixSong.isTrackID(id) {
            if plays[id] == nil { firstSeen.append(id) }
            plays[id, default: 0] += 1
        }
        return firstSeen.enumerated()
            .map { recency, id in (seed: MixSeed(id: id, plays: plays[id] ?? 1), recency: recency) }
            .sorted { a, b in
                let scoreA = Double(a.seed.plays) + 2 / Double(1 + a.recency)
                let scoreB = Double(b.seed.plays) + 2 / Double(1 + b.recency)
                return scoreA != scoreB ? scoreA > scoreB : a.recency < b.recency
            }
            .map(\.seed)
    }

    /// Up to five seeds for the next fetch; empty when the service knows none
    /// of the source. `features` are the source's, as far as they're known, and
    /// `stones` the songs the mix has found nearest to what's asked, nearest first.
    mutating func next(for recipe: MixRecipe, features: [String: MixFeatures] = [:], stones: [String] = []) -> [String] {
        let known = source.map(\.id).filter { !unknown.contains($0) }
        guard !known.isEmpty else { return [] }
        var candidates = known
        if recipe.steers {
            let fitting = known.filter { id in features[id].map { MixChooser.fits($0, recipe) } ?? false }
            let stepping = stones.filter { !unknown.contains($0) }
            if !fitting.isEmpty {
                candidates = fitting
            } else if !stepping.isEmpty {
                candidates = stepping
            }
        }
        round += 1
        let chosen = candidates.enumerated()
            .sorted { a, b in
                let usedA = lastUsed[a.element] ?? 0, usedB = lastUsed[b.element] ?? 0
                return usedA != usedB ? usedA < usedB : a.offset < b.offset
            }
            .prefix(ReccoBeats.seedLimit).map(\.element)
        for id in chosen { lastUsed[id] = round }
        return chosen
    }

    /// The service knows none of these.
    mutating func drop(_ ids: [String]) {
        unknown.formUnion(ids)
    }
}
