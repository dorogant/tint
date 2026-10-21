import Foundation

/// The auto preset offline: genre mapping, the sound classifier on synthetic
/// songs, hysteresis, manual override, persistence and the genre cache. No
/// login, network or audio; the Web API is a stub.
@main
@MainActor
struct AutoPresetTests {
    static func main() async {
        genreMapping()
        classifier()
        await controllerFromGenres()
        await hysteresis()
        manualOverride()
        persistence()
        await genreCache()
        print("All auto preset tests passed")
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition {
            print("FAIL: \(message())")
            exit(1)
        }
    }

    // MARK: - Genres

    static func genreMapping() {
        let cases: [(String, BackgroundPreset?, Bool)] = [
            ("deep house", .club, true), ("tech house", .club, true), ("melodic techno", .club, true),
            ("edm", .club, true), ("progressive trance", .club, true), ("psytrance", .club, true),
            ("drum and bass", .club, true), ("liquid funk", .balanced, false), ("dubstep", .club, true),
            ("uk garage", .club, true), ("nu disco", .club, true), ("ukrainian electronic", .club, true),
            ("hip hop", .hipHop, true), ("Hip-Hop", .hipHop, true), ("rap", .hipHop, true), ("trap", .hipHop, true),
            ("uk drill", .hipHop, true), ("drift phonk", .hipHop, true), ("grime", .hipHop, true),
            ("ukrainian hip hop", .hipHop, true), ("russian trap", .hipHop, true), ("russian drill", .hipHop, true),
            ("russian emo rap", .hipHop, true), ("ukrainian trap", .hipHop, true), ("contemporary r&b", .hipHop, true),
            ("jazz rap", .hipHop, true), ("reggaeton", .hipHop, true), ("dancehall", .hipHop, true),
            ("rock", .rock, true), ("alternative metal", .rock, true), ("pop punk", .rock, true), ("grunge", .rock, true),
            ("indie rock", .rock, true), ("krautrock", .rock, true), ("metalcore", .rock, true),
            ("russian post-punk", .rock, true), ("ukrainian rock", .rock, true), ("rap rock", .rock, true),
            ("nu metal", .rock, true), ("garage rock", .rock, true), ("folk rock", .rock, true), ("emo", .rock, true),
            ("ambient", .chill, true), ("lo-fi beats", .chill, true), ("lofi hip hop", .chill, true),
            ("chillwave", .chill, true), ("downtempo", .chill, true), ("new age", .chill, true),
            ("trip hop", .chill, true), ("soundtrack", .chill, true), ("video game score", .chill, true),
            ("electronica", .chill, true),
            ("acoustic pop", .acoustic, true), ("indie folk", .acoustic, true), ("ukrainian folk", .acoustic, true),
            ("classical", .acoustic, true), ("neoclassical", .acoustic, true), ("jazz", .acoustic, true),
            ("singer-songwriter", .acoustic, true), ("russian bard", .acoustic, true), ("bossa nova", .acoustic, true),
            ("pop", .balanced, false), ("ukrainian pop", .balanced, false), ("russian pop", .balanced, false),
            ("k-pop", .balanced, false), ("indie", .balanced, false), ("neo soul", .balanced, false),
            ("polka", nil, false), ("", nil, false), ("scrapcore", nil, false),
        ]
        for (genre, expected, specific) in cases {
            let result = GenrePresets.preset(for: genre)
            check(result?.preset == expected, "\"\(genre)\" should map to \(expected?.rawValue ?? "nothing"), got \(result?.preset.rawValue ?? "nothing")")
            if expected != nil { check(result?.isSpecific == specific, "\"\(genre)\" specific should be \(specific)") }
        }
        print("PASS: \(cases.count) genre strings map to presets")

        // Real artists' genre lists, as Spotify has returned them.
        let artists: [([String], BackgroundPreset?, String?)] = [
            (["french house", "filter house", "electro"], .club, "french house"),                     // Daft Punk
            (["ukrainian hip hop", "ukrainian pop"], .hipHop, "ukrainian hip hop"),
            (["russian hip hop", "russian trap", "russian pop"], .hipHop, "russian hip hop"),
            (["ukrainian rock", "ukrainian pop", "ukrainian indie"], .rock, "ukrainian rock"),        // Okean Elzy
            (["pop", "dance pop"], .club, "dance pop"),
            (["art pop", "pop"], .balanced, "art pop"),
            (["indie pop", "chill pop", "bedroom pop"], .chill, "chill pop"),
            (["alternative rock", "modern rock", "permanent wave", "rock"], .rock, "alternative rock"), // Radiohead-ish
            (["rap", "hip hop", "pop rap", "trap", "rock"], .hipHop, "rap"),
            (["rock", "trap"], .rock, "rock"), // a tie goes to the genre listed first
            ([], nil, nil),
            (["polka"], nil, nil),
        ]
        for (genres, expected, genre) in artists {
            let match = GenrePresets.match(genres)
            check(match?.preset == expected && match?.genre == genre,
                  "\(genres) should match \(expected?.rawValue ?? "nothing") from \(genre ?? "-"), got \(String(describing: match))")
        }
        check(GenrePresets.match(["pop"])?.isSpecific == false, "pop alone is a weak match")
        print("PASS: artists' genre lists (incl. empty) choose one preset, with the genre to show")
    }

    // MARK: - Sound

    static func classifier() {
        let expected: [(SongSynth.Style, BackgroundPreset)] = [
            (.groove, .club), (.club, .club), (.trap, .hipHop), (.boomBap, .hipHop), (.rock, .rock),
            (.pad, .chill), (.quietPad, .chill), (.acoustic, .acoustic),
        ]
        for (gain, clip) in [(Float(0.3), false), (Float(1), false), (Float(3), true)] {
            for (style, preset) in expected {
                var classifier = SoundClassifier()
                for frame in SongSynth.frames([(style, 10)], gain: gain, clip: clip) { classifier.add(frame) }
                check(classifier.isComplete, "\(style) should complete a window in 10 s")
                let chosen = SoundClassifier.preset(for: classifier.features)
                check(chosen == preset, "\(style) at gain \(gain) should sound like \(preset.rawValue), got \(chosen.rawValue): \(classifier.features)")
            }
        }
        var silent = SoundClassifier()
        for frame in SongSynth.frames([(.silence, 20)]) { silent.add(frame) }
        check(!silent.isComplete, "silence must never decide")
        // A quiet intro doesn't count toward the window.
        var late = SoundClassifier()
        for frame in SongSynth.frames([(.silence, 8), (.club, 9)]) { late.add(frame) }
        check(!late.isComplete, "silent seconds must not count toward the window")
        print("PASS: the classifier tells club, hip-hop, rock, chill and acoustic apart at three loudnesses; silence never decides")

        // No allocation per frame: the classifier is all scalars.
        check(MemoryLayout<SoundClassifier>.size < 256, "the classifier should stay a handful of scalars")
        let frames = SongSynth.frames([(.club, 10)])
        var timed = SoundClassifier()
        var sink: Float = 0
        let start = Date()
        for _ in 0..<20 {
            for frame in frames { timed.add(frame) }
            sink += timed.features.bass // keeps the optimizer from skipping the work
            timed.reset(restartTempo: false)
        }
        let perFrame = Date().timeIntervalSince(start) / Double(20 * frames.count) * 1e6
        check(sink > 0, "the club song has bass")
        check(perFrame < 5, "a frame should cost well under 5 µs, took \(perFrame) µs")
        print(String(format: "PASS: classifying costs %.2f µs a frame", perFrame))
    }

    // MARK: - Controller

    final class GenreStub: @unchecked Sendable {
        var genres: [String: [String]] = [:]
        var delay: Duration = .zero
        private(set) var asked: [[String]] = []
        func answer(_ ids: [String]) async -> ArtistGenres.Answer {
            asked.append(ids)
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let id = ids.first(where: { !(genres[$0] ?? []).isEmpty }) else { return ArtistGenres.Answer() }
            return ArtistGenres.Answer(artistID: id, genres: genres[id] ?? [])
        }
    }

    static func makeSettings() -> (VisualSettings, UserDefaults) {
        let defaults = TestDefaults.make()
        return (VisualSettings(defaults: defaults), defaults)
    }

    static func song(_ name: String, artists: [String] = ["a"]) -> AutoPresetController.Song {
        AutoPresetController.Song(uri: "spotify:track:\(name)", artistIDs: artists, artistNames: artists)
    }

    static func controllerFromGenres() async {
        let stub = GenreStub()
        stub.genres = ["daft": ["french house", "electro"], "pop": ["pop"], "nobody": []]
        let (settings, _) = makeSettings()
        settings.liveBackground = true
        settings.autoPreset = true
        settings.strobe = false
        var listening: [Bool] = []
        let controller = AutoPresetController(settings: settings, genres: { await stub.answer($0) }, logging: false)
        controller.setListening = { listening.append($0) }

        await controller.update(song("one", artists: ["daft"]), enabled: true)
        check(settings.backgroundPreset == .club && settings.autoStatus == .genre(.club, "french house"),
              "a house artist picks Club from its genre, got \(settings.backgroundPreset) \(String(describing: settings.autoStatus))")
        check(settings.autoPreset && !settings.strobe, "the auto preset stays on and never turns on the strobe")
        check(listening.isEmpty, "a specific genre needs no listening")

        await controller.update(song("two", artists: ["nobody"]), enabled: true)
        check(settings.autoStatus == .choosing && listening == [true], "no genres: it listens instead")
        check(settings.backgroundPreset == .club, "while listening, the look stays as it was")
        for frame in SongSynth.frames([(.pad, 11)]) { controller.hear(frame) }
        check(settings.backgroundPreset == .chill && settings.autoStatus == .sound(.chill),
              "a pad with no genre picks Chill from the sound, got \(settings.backgroundPreset)")

        // A weak genre applies Balanced at once; the sound may refine it.
        await controller.update(song("three", artists: ["pop"]), enabled: true)
        check(settings.backgroundPreset == .balanced && settings.autoStatus == .genre(.balanced, "pop"), "pop applies Balanced")
        check(listening.last == true, "a weak genre still listens")
        for frame in SongSynth.frames([(.club, 11)]) { controller.hear(frame) }
        check(settings.backgroundPreset == .club && settings.autoStatus == .sound(.club), "a four-on-the-floor pop song becomes Club")

        // Turned off: nothing is applied and the caption goes.
        listening.removeAll()
        await controller.update(song("four", artists: ["daft"]), enabled: false)
        settings.autoPreset = false
        check(settings.autoStatus == nil && listening == [false], "off: no caption and no listening")
        settings.choose(.rock)
        await controller.update(song("five", artists: ["daft"]), enabled: false)
        check(settings.backgroundPreset == .rock, "off: the look never changes")

        // The self-test log alone changes nothing either.
        let logOnly = AutoPresetController(settings: settings, genres: { await stub.answer($0) }, logging: true)
        await logOnly.update(song("six", artists: ["daft"]), enabled: false)
        check(settings.backgroundPreset == .rock && settings.autoStatus == nil, "logging alone must not apply presets")

        // A skip during the lookup drops the old song's answer.
        settings.autoPreset = true
        stub.delay = .milliseconds(200)
        let skipped = Task { await controller.update(song("seven", artists: ["daft"]), enabled: true) }
        try? await Task.sleep(for: .milliseconds(20))
        skipped.cancel()
        stub.delay = .zero
        await controller.update(song("eight", artists: ["pop"]), enabled: true)
        await skipped.value
        check(settings.backgroundPreset == .balanced, "a skipped song's genre must not land on the next one, got \(settings.backgroundPreset)")

        // Reduce Motion: no analysis to listen with, so it says so.
        let still = AutoPresetController(settings: settings, genres: { await stub.answer($0) }, logging: false, reduceMotion: { true })
        await still.update(song("nine", artists: ["nobody"]), enabled: true)
        check(settings.autoStatus == .noGenre(.balanced), "with Reduce Motion and no genre the look stays, got \(String(describing: settings.autoStatus))")
        print("PASS: genres pick the preset, empty genres fall back to the sound, off and log-only change nothing, skips drop stale answers")
    }

    static func hysteresis() async {
        let (settings, _) = makeSettings()
        settings.liveBackground = true
        settings.autoPreset = true
        var listening: [Bool] = []
        var changes: [BackgroundPreset] = []
        let controller = AutoPresetController(settings: settings, genres: { _ in ArtistGenres.Answer() }, logging: false)
        controller.setListening = { listening.append($0) }

        // A steady club track decides once and never flips, then stops listening.
        await controller.update(song("steady"), enabled: true)
        var last = settings.backgroundPreset
        for frame in SongSynth.frames([(.club, 70)]) {
            controller.hear(frame)
            if settings.backgroundPreset != last { changes.append(settings.backgroundPreset); last = settings.backgroundPreset }
        }
        check(changes == [.club], "a club track picks Club once, got \(changes)")
        check(listening == [true, false], "it stops listening after a minute at most, got \(listening)")

        // A calm intro, then a drop: Chill first, then Club once the beat holds
        // for two windows, and never again after that.
        changes.removeAll()
        listening.removeAll()
        await controller.update(song("drop"), enabled: true)
        last = settings.backgroundPreset
        for frame in SongSynth.frames([(.pad, 12), (.club, 40), (.pad, 20), (.rock, 30)]) {
            controller.hear(frame)
            if settings.backgroundPreset != last { changes.append(settings.backgroundPreset); last = settings.backgroundPreset }
        }
        check(changes == [.chill, .club], "a drop revises Chill to Club once and then holds, got \(changes)")
        check(settings.autoStatus == .sound(.club), "the caption follows the revision")
        check(listening == [true, false], "it stops listening after the revision")

        // One busy window in a calm song isn't a drop.
        changes.removeAll()
        await controller.update(song("fill"), enabled: true)
        last = settings.backgroundPreset
        for frame in SongSynth.frames([(.acoustic, 11), (.club, 8), (.acoustic, 45)]) {
            controller.hear(frame)
            if settings.backgroundPreset != last { changes.append(settings.backgroundPreset); last = settings.backgroundPreset }
        }
        check(changes == [.acoustic], "a single busy window must not flip the preset, got \(changes)")
        print("PASS: the sound decides once, revises at most once after a drop, ignores a single busy window and stops listening")
    }

    // MARK: - Settings

    static func manualOverride() {
        let (settings, defaults) = makeSettings()
        settings.choose(.subtle)
        settings.glow = 1.7 // Custom now, with this glow kept as the custom look
        settings.autoPreset = true
        settings.applyAutomatically(.club)
        check(settings.autoPreset && settings.backgroundPreset == .club, "an automatic choice keeps auto on")
        check(settings.glow == BackgroundPreset.club.look?.glow, "an automatic choice sets the preset's knobs")
        check(settings.customLook.glow == 1.7, "leaving Custom automatically still keeps the hand-tuned look")

        settings.choose(.rock)
        check(!settings.autoPreset && settings.backgroundPreset == .rock, "picking a preset by hand turns auto off")

        settings.autoPreset = true
        settings.autoStatus = .sound(.rock)
        settings.choose(.rock)
        check(!settings.autoPreset && settings.autoStatus == nil, "re-picking the same preset by hand still turns auto off and clears the caption")

        settings.autoPreset = true
        settings.applyAutomatically(.hipHop)
        settings.reactivity = 0.4
        check(!settings.autoPreset && settings.backgroundPreset == .custom, "moving a slider turns auto off (and makes it Custom)")

        settings.autoPreset = true
        settings.backgroundKind = .fluid
        check(!settings.autoPreset, "switching the kind turns auto off")

        settings.autoPreset = true
        settings.strobe = true
        check(settings.autoPreset, "the strobe isn't part of a preset, so it leaves auto on")
        for preset in BackgroundPreset.allCases where preset != .custom {
            settings.applyAutomatically(preset)
            check(settings.strobe, "an automatic preset never changes the strobe")
        }
        settings.strobe = false
        for preset in BackgroundPreset.allCases where preset != .custom {
            settings.applyAutomatically(preset)
            check(!settings.strobe, "an automatic preset never turns the strobe on")
        }
        _ = defaults
        print("PASS: a preset or slider by hand turns auto off; automatic choices keep it on and never touch the strobe")
    }

    static func persistence() {
        let (settings, defaults) = makeSettings()
        check(!settings.autoPreset, "auto preset is off by default")
        settings.autoPreset = true
        settings.applyAutomatically(.chill)
        settings.autoStatus = .genre(.chill, "ambient")
        let reopened = VisualSettings(defaults: defaults)
        check(reopened.autoPreset && reopened.backgroundPreset == .chill, "auto preset and its choice persist")
        check(reopened.autoStatus == nil, "the caption is per song and doesn't persist")
        reopened.choose(.intense)
        check(!VisualSettings(defaults: defaults).autoPreset, "turning it off persists")
        print("PASS: the auto preset setting persists, off by default")
    }

    // MARK: - Genre cache

    final class FetchStub: @unchecked Sendable {
        var genres: [String: [String]] = [:]
        var error: Error?
        var delay: Duration = .zero
        private(set) var requests: [String] = []
        func fetch(_ id: String) async throws -> [String] {
            requests.append(id)
            if delay > .zero { try await Task.sleep(for: delay) }
            if let error { throw error }
            return genres[id] ?? []
        }
    }

    final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    static func genreCache() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tint-genres-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = FetchStub(), clock = Clock()
        stub.genres = ["house": ["deep house"], "rapper": ["ukrainian hip hop"]]
        let cache = ArtistGenres(file: file, now: { clock.date }, fetch: { try await stub.fetch($0) })

        check(ArtistGenres.artistID(fromURI: "spotify:artist:4tZwfgrHOc3mvqYlEYSvVi") == "4tZwfgrHOc3mvqYlEYSvVi"
              && ArtistGenres.artistID(fromURI: "spotify:local:x") == nil && ArtistGenres.artistID(fromURI: nil) == nil,
              "artist IDs come from Spotify artist URIs only")

        var answer = await cache.genres(for: ["house", "rapper"])
        check(answer.genres == ["deep house"] && answer.artistID == "house" && stub.requests == ["house"],
              "the primary artist's genres, one request")
        answer = await cache.genres(for: ["house"])
        check(answer.genres == ["deep house"] && stub.requests == ["house"], "a known artist costs no request")

        // Empty genres (Development Mode) are cached; the next artist gets asked
        // on a later song, never two requests for one song.
        answer = await cache.genres(for: ["dev", "rapper"])
        check(answer.genres.isEmpty && stub.requests == ["house", "dev"], "one request per song, even when it comes back empty")
        answer = await cache.genres(for: ["dev", "rapper"])
        check(answer.genres == ["ukrainian hip hop"] && answer.artistID == "rapper" && stub.requests == ["house", "dev", "rapper"],
              "the empty artist is cached, so the featured artist is asked next time")

        // On disk: a new instance answers without asking.
        let reopened = ArtistGenres(file: file, now: { clock.date }, fetch: { try await stub.fetch($0) })
        answer = await reopened.genres(for: ["house"])
        check(answer.genres == ["deep house"] && stub.requests.count == 3, "the cache survives a relaunch")

        // Empty answers expire after days, genres after a month.
        clock.date += 4 * 86_400
        _ = await reopened.genres(for: ["dev"])
        check(stub.requests.last == "dev" && stub.requests.count == 4, "an empty answer is asked again after a few days")
        _ = await reopened.genres(for: ["house"])
        check(stub.requests.count == 4, "genres stay fresh for weeks")
        clock.date += 31 * 86_400
        _ = await reopened.genres(for: ["house"])
        check(stub.requests.count == 5, "genres are refreshed after a month")

        // A rate limit pauses requests for as long as Spotify asks.
        stub.error = WebAPI.Failure.rateLimited(retryAfter: 120)
        _ = await reopened.genres(for: ["new1"])
        stub.error = nil
        _ = await reopened.genres(for: ["new2"])
        check(stub.requests.suffix(2) == ["house", "new1"], "no requests while rate-limited, got \(stub.requests)")
        clock.date += 121
        answer = await reopened.genres(for: ["new2"])
        check(stub.requests.last == "new2", "requests resume after Retry-After")

        // A refusal (the endpoint closed to Development Mode) pauses for an hour.
        stub.error = WebAPI.Failure.http(status: 403, message: "Forbidden")
        _ = await reopened.genres(for: ["new3"])
        stub.error = nil
        _ = await reopened.genres(for: ["new4"])
        check(stub.requests.last == "new3", "a 403 stops asking for a while")
        clock.date += 3601
        _ = await reopened.genres(for: ["new4"])
        check(stub.requests.last == "new4", "and asks again an hour later")

        // A skip cancels the request and caches nothing.
        stub.delay = .milliseconds(300)
        let skipped = Task { await reopened.genres(for: ["slow"]) }
        try? await Task.sleep(for: .milliseconds(30))
        skipped.cancel()
        let dropped = await skipped.value
        stub.delay = .zero
        check(dropped.genres.isEmpty, "a cancelled lookup answers nothing")
        stub.genres["slow"] = ["ambient"]
        answer = await reopened.genres(for: ["slow"])
        check(answer.genres == ["ambient"], "a cancelled lookup isn't cached as empty")

        // Expired answers are dropped when the file is read, and gone from it at the next save.
        clock.date += 40 * 86_400
        let later = ArtistGenres(file: file, now: { clock.date }, fetch: { try await stub.fetch($0) })
        _ = await later.genres(for: ["fresh"])
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check(saved.map { Array($0.keys) } == ["fresh"], "only fresh answers are kept on disk, got \(saved?.keys.sorted() ?? [])")
        print("PASS: genres are cached per artist in memory and on disk, one request per song, with rate-limit and refusal pauses")
    }
}
