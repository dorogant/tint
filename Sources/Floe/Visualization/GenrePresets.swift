import Foundation

/// Which live-background preset suits a song, from its artist's Spotify genres.
///
/// Spotify genres are free-form micro-genres ("deep house", "ukrainian hip hop",
/// "russian post-punk"), so this matches keywords rather than exact names. A
/// keyword counts only at a word's start or end ("rock" in "krautrock",
/// "metal" in "metalcore", "chill" in "chillwave"), never buried mid-word.
enum GenrePresets {
    struct Match: Equatable {
        var preset: BackgroundPreset
        /// The genre string it came from, as Spotify wrote it, for the caption.
        var genre: String
        /// False for the catch-all (pop and the like): a weak hint, so the sound
        /// may still refine it.
        var isSpecific: Bool
    }

    /// First matching keyword wins, so the exceptions to broader keywords come
    /// first ("trip hop" is Chill, not Hip-hop; "rap rock" is Rock, not Hip-hop;
    /// "lo-fi hip hop" is Chill). Keywords are already normalized (see `normalize`).
    static let rules: [(keyword: String, preset: BackgroundPreset)] = [
        // Exceptions to the broad keywords below.
        ("lo fi", .chill), ("lofi", .chill), ("trip hop", .chill), ("electronica", .chill),
        ("dream pop", .chill), ("emo rap", .hipHop), ("jazz rap", .hipHop), ("rap rock", .rock),
        ("rap metal", .rock), ("trap metal", .rock), ("nu metal", .rock), ("garage rock", .rock),
        ("dancehall", .hipHop), ("folk rock", .rock), ("folk metal", .rock), ("folk punk", .rock),
        ("blues rock", .rock), ("country rock", .rock), ("hardcore techno", .club), ("happy hardcore", .club),
        // Chill: ambient textures, slow and soft.
        ("chill", .chill), ("ambient", .chill), ("downtempo", .chill), ("new age", .chill),
        ("soundtrack", .chill), ("score", .chill), ("meditation", .chill), ("sleep", .chill),
        ("lounge", .chill), ("vaporwave", .chill), ("drone", .chill),
        // Hip-hop: 808s, half-time grooves.
        ("hip hop", .hipHop), ("rap", .hipHop), ("trap", .hipHop), ("drill", .hipHop),
        ("phonk", .hipHop), ("grime", .hipHop), ("boom bap", .hipHop), ("r&b", .hipHop),
        ("rnb", .hipHop), ("reggaeton", .hipHop), ("urbano", .hipHop), ("afroswing", .hipHop),
        // Club: four on the floor and bass music.
        ("house", .club), ("techno", .club), ("edm", .club), ("trance", .club), ("drum and bass", .club),
        ("dnb", .club), ("jungle", .club), ("dubstep", .club), ("electro", .club), ("dance", .club),
        ("hardstyle", .club), ("garage", .club), ("breakbeat", .club), ("bass music", .club),
        ("big room", .club), ("disco", .club), ("eurobeat", .club), ("synthwave", .club),
        ("hyperpop", .club), ("rave", .club),
        // Rock: guitars, live drums, cymbals.
        ("rock", .rock), ("metal", .rock), ("punk", .rock), ("grunge", .rock), ("emo", .rock),
        ("post hardcore", .rock), ("shoegaze", .rock), ("britpop", .rock), ("hardcore", .rock),
        ("djent", .rock), ("screamo", .rock),
        // Acoustic: few drums, little bass, the playing's own dynamics.
        ("acoustic", .acoustic), ("folk", .acoustic), ("classical", .acoustic), ("jazz", .acoustic),
        ("singer songwriter", .acoustic), ("piano", .acoustic), ("bossa nova", .acoustic),
        ("blues", .acoustic), ("country", .acoustic), ("bluegrass", .acoustic), ("orchestra", .acoustic),
        ("opera", .acoustic), ("choral", .acoustic), ("baroque", .acoustic), ("chamber", .acoustic),
        ("string quartet", .acoustic), ("flamenco", .acoustic), ("fado", .acoustic), ("bard", .acoustic),
        ("chanson", .acoustic), ("bandura", .acoustic), ("a cappella", .acoustic), ("romance", .acoustic),
    ]

    /// Genres that say only "mainstream": the look stays Balanced.
    static let general = ["pop", "indie", "alternative", "estrada", "schlager", "soul", "funk", "afrobeats", "latin"]

    /// The preset for one genre string, or nil if no keyword matches.
    static func preset(for genre: String) -> (preset: BackgroundPreset, isSpecific: Bool)? {
        let text = normalize(genre)
        if let rule = rules.first(where: { contains(text, $0.keyword) }) { return (rule.preset, true) }
        if general.contains(where: { contains(text, $0) }) { return (.balanced, false) }
        return nil
    }

    /// The preset for an artist's genres. Each genre votes; Spotify lists the
    /// most characteristic genres first, so earlier ones count a little more
    /// and break ties. Specific genres outvote the catch-all.
    static func match(_ genres: [String]) -> Match? {
        var scores: [BackgroundPreset: Double] = [:]
        var first: [BackgroundPreset: (index: Int, genre: String)] = [:]
        var fallback: Match?
        for (index, genre) in genres.enumerated() {
            guard let (preset, specific) = preset(for: genre) else { continue }
            guard specific else {
                if fallback == nil { fallback = Match(preset: preset, genre: genre, isSpecific: false) }
                continue
            }
            scores[preset, default: 0] += 1 + 0.5 / Double(index + 1)
            if first[preset] == nil { first[preset] = (index, genre) }
        }
        // Equal scores go to the preset whose genre came first.
        var best: (preset: BackgroundPreset, score: Double, index: Int)?
        for (preset, score) in scores {
            let index = first[preset]?.index ?? .max
            if let current = best, current.score > score || (current.score == score && current.index < index) { continue }
            best = (preset, score, index)
        }
        guard let best, let genre = first[best.preset]?.genre else { return fallback }
        return Match(preset: best.preset, genre: genre, isSpecific: true)
    }

    /// Lowercase, with hyphens and underscores as spaces: "Lo-Fi Hip-Hop" → "lo fi hip hop".
    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    /// `keyword` at a word's start or end in `text`.
    private static func contains(_ text: String, _ keyword: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: keyword, range: searchStart..<text.endIndex) {
            let startsWord = range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter
            let endsWord = range.upperBound == text.endIndex || !text[range.upperBound].isLetter
            if startsWord || endsWord { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }
}
