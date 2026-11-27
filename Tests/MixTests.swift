import Foundation

/// The mix without the app: the ReccoBeats client against answers captured
/// from the real service, the choosing rules, and a whole session driven by a
/// fake player and stub sources. No network and no player.
@main @MainActor
struct MixTests {
    static var checks = 0

    static func main() async {
        clientChecks()
        await transportChecks()
        recipeChecks()
        seedChecks()
        filterChecks()
        rankingChecks()
        artistChecks()
        await sessionChecks()
        await refillChecks()
        await steeringChecks()
        await lengthChecks()
        await lettingGoChecks()
        await sourceChecks()
        await likedOnlyChecks()
        await failureChecks()
        await detailChecks()
        print("PASS: \(checks) mix checks (ReccoBeats answers and errors, requests, seeds and their rotation, filters, mood and energy ranking, artist rules, refills, the length, steering, letting go, sources, only liked songs, failures, lookups)")
    }

    // MARK: - The client

    static func clientChecks() {
        let songs = (try? ReccoBeats.songs(in: MixFixtures.recommendation)) ?? []
        check(songs.count == 5, "a captured answer of five songs must give five (\(songs.count))")
        check(songs.first == MixSong(id: "1IyV9GwfMVEVMymw8N4nsI", title: "0801", artists: ["Stray Kids"], durationMs: 204_026),
              "a song must come with its Spotify ID, title, artists and length (\(String(describing: songs.first)))")
        check(songs.first?.uri == "spotify:track:1IyV9GwfMVEVMymw8N4nsI", "a song's URI is built from its ID")
        check(songs.allSatisfy { MixSong.isTrackID($0.id) && !$0.title.isEmpty && !$0.artists.isEmpty && $0.durationMs > 0 },
              "every song of the answer must be complete")

        let features = (try? ReccoBeats.features(in: MixFixtures.features)) ?? [:]
        check(features.count == 3 && features["0000000000000000000000"] == nil, "an ID the service doesn't know is simply missing (\(features.count))")
        check(features["7qiZfU4dY1lWllzX7mPBI3"] == MixFeatures(valence: 0.931, energy: 0.652, speechiness: 0.0802),
              "features must carry valence and energy (\(String(describing: features["7qiZfU4dY1lWllzX7mPBI3"])))")
        check((try? ReccoBeats.features(in: MixFixtures.nothing)) == [:], "an empty answer is no features, not an error")
        check((try? ReccoBeats.songs(in: Data("<html>".utf8))) == nil, "a body that isn't the answer must be an error")
        // One entry without a link costs only itself.
        let odd = Data(#"{"content":[{"trackTitle":"No link"},{"trackTitle":"Fine","artists":[{"name":"A"}],"durationMs":1000,"href":"https://open.spotify.com/track/7qiZfU4dY1lWllzX7mPBI3"},{"trackTitle":"Again","href":"https://open.spotify.com/track/7qiZfU4dY1lWllzX7mPBI3"}]}"#.utf8)
        check((try? ReccoBeats.songs(in: odd))?.map(\.title) == ["Fine"], "a broken entry and a repeated song are skipped")

        check(ReccoBeats.failure(status: 400, body: MixFixtures.unknownSeeds) == .unknownSeeds, "status 4002 means the seeds aren't known")
        check(ReccoBeats.failure(status: 400, body: MixFixtures.tooManySeeds) == .rejected("getRecommendation.seeds: size must be between 1 and 5"),
              "status 4004 carries what was wrong (\(ReccoBeats.failure(status: 400, body: MixFixtures.tooManySeeds)))")
        check(ReccoBeats.failure(status: 400, body: MixFixtures.sizeTooLarge) == .rejected("getRecommendation.size: must be less than or equal to 100"),
              "a size over 100 is named too")
        check(ReccoBeats.failure(status: 429, body: Data()) == .busy, "429 is the service being busy")
        check(ReccoBeats.failure(status: 503, body: Data("gateway".utf8)) == .server(503), "5xx is the server's fault")

        let seeds = (0..<7).map { tid("seed", $0) }
        let request = ReccoBeats.recommendationRequest(seeds: seeds + [seeds[0], "spotify:local:x", ""], valence: 0.35, energy: nil)
        let url = request?.url?.absoluteString ?? ""
        check(url == "https://api.reccobeats.com/v1/track/recommendation?size=100&seeds=\(seeds.prefix(5).joined(separator: ","))&valence=0.35",
              "a request asks for 100 around at most five distinct track IDs (\(url))")
        check(ReccoBeats.recommendationRequest(seeds: ["not an id"], valence: nil, energy: nil) == nil, "without a track ID there is no request")
        let both = ReccoBeats.recommendationRequest(seeds: [seeds[0]], size: 500, valence: 1.7, energy: 0.25)?.url?.query ?? ""
        check(both == "size=100&seeds=\(seeds[0])&valence=1.00&energy=0.25", "size and targets stay inside what the service takes (\(both))")
        let batches = ReccoBeats.featureRequests(ids: (0..<93).map { tid("f", $0) } + [tid("f", 3), "nope"])
        let sizes = batches.map { $0.url?.query?.split(separator: ",").count ?? 0 }
        check(sizes == [40, 40, 13], "features are asked for forty at a time, each ID once (\(sizes))")
        check(batches.first?.url?.absoluteString.hasPrefix("https://api.reccobeats.com/v1/audio-features?ids=\(tid("f", 0)),") == true, "features go to the audio-features endpoint")
        check(ReccoBeats.featureRequests(ids: []).isEmpty, "no IDs, no request")
        check(MixSong.trackID(in: "spotify:track:7qiZfU4dY1lWllzX7mPBI3") == "7qiZfU4dY1lWllzX7mPBI3"
                && MixSong.trackID(in: "https://open.spotify.com/track/7qiZfU4dY1lWllzX7mPBI3?si=1") == "7qiZfU4dY1lWllzX7mPBI3"
                && MixSong.trackID(in: "spotify:episode:7qiZfU4dY1lWllzX7mPBI3") == nil && MixSong.trackID(in: "spotify:local:a:b:c:1") == nil,
              "only catalogue tracks have an ID to send")
    }

    static func transportChecks() async {
        let transport = StubTransport()
        let client = ReccoBeats(transport: transport)
        transport.answer = { request in
            request.url?.path.hasSuffix("recommendation") == true ? (MixFixtures.recommendation, 200) : (MixFixtures.features, 200)
        }
        let songs = try? await client.recommendations(seeds: [tid("s", 1)], valence: nil, energy: 0.8)
        check(songs?.count == 5 && transport.requests.last?.url?.query == "size=100&seeds=\(tid("s", 1))&energy=0.80",
              "the client sends one request and reads the songs")
        let features = try? await client.features(for: (0..<81).map { tid("f", $0) })
        check(features?.count == 3 && transport.requests.count == 4, "81 songs take three feature requests (\(transport.requests.count - 1))")
        check(transport.requests.allSatisfy { $0.url?.host == "api.reccobeats.com" && $0.httpMethod == "GET" && $0.httpBody == nil },
              "everything goes to ReccoBeats as a GET with nothing but the query")

        func failure(_ status: Int, _ body: Data) async -> ReccoBeats.Failure? {
            transport.answer = { _ in (body, status) }
            do {
                _ = try await client.recommendations(seeds: [tid("s", 1)], valence: nil, energy: nil)
                return nil
            } catch {
                return error as? ReccoBeats.Failure
            }
        }
        check(await failure(400, MixFixtures.unknownSeeds) == .unknownSeeds, "unknown seeds reach the caller as such")
        check(await failure(400, MixFixtures.tooManySeeds) == .rejected("getRecommendation.seeds: size must be between 1 and 5"), "a refused request reaches the caller with its reason")
        check(await failure(200, Data("{}".utf8)) == .unreadable, "a 200 without songs is unreadable")
        check(await failure(502, Data()) == .server(502), "a server error reaches the caller")
    }

    // MARK: - The recipe

    static func recipeChecks() {
        let defaults = TestDefaults.make()
        let fresh = MixRecipe.saved(in: defaults)
        check(fresh.source == .today && fresh.liked == .leaveOut && fresh.skipHeard && fresh.mood == .any && fresh.energy == .any && fresh.length == .hour,
              "the questionnaire starts on today, no liked songs, nothing heard, any mood, any energy, an hour")
        var recipe = MixRecipe()
        recipe.source = .week
        recipe.liked = .only
        recipe.skipHeard = false
        recipe.mood = .sad
        recipe.energy = .energetic
        recipe.length = .endless
        recipe.save(in: defaults)
        check(MixRecipe.saved(in: defaults) == recipe, "answers must come back as they were saved")
        defaults.set(Data(#"{"mood":4,"length":"a fortnight","liked":"allow"}"#.utf8), forKey: MixRecipe.defaultsKey)
        let partial = MixRecipe.saved(in: defaults)
        check(partial.mood == .happy && partial.liked == .allow && partial.length == .hour && partial.source == .today,
              "answers saved by another build keep what is understood and default the rest")
        check(MixRecipe.Mood.sad.sadder == .sad && MixRecipe.Mood.sad.happier == .mellow && MixRecipe.Mood.happy.happier == .happy
                && MixRecipe.Energy.any.calmer == .calm && MixRecipe.Energy.energetic.livelier == .energetic,
              "the live controls move one stop and stop at the ends")
        check(MixRecipe.Length.halfHour.milliseconds == 1_800_000 && MixRecipe.Length.endless.milliseconds == nil, "lengths are half an hour, one, two, or none")
        check(!MixRecipe().steers && recipe.steers, "a recipe steers once a mood or an energy is asked for")
    }

    // MARK: - Seeds

    static func seedChecks() {
        let a = tid("a", 0), b = tid("b", 0), c = tid("c", 0), d = tid("d", 0)
        // Newest first: d once just now, c once before it, a three times earlier, b once at the start.
        let ordered = MixSeeds.ordered([d, c, a, a, a, b, "spotify:local", ""]).map(\.id)
        check(ordered == [a, d, c, b], "three plays outrank one newer play, then the newer first (\(ordered.map { $0.prefix(1) }))")
        check(MixSeeds.ordered([d, c, a, a, a, b]).first?.plays == 3, "a seed knows how often it was played")

        let ids = (0..<12).map { tid("s", $0) }
        var seeds = MixSeeds(listened: ids)
        let any = MixRecipe()
        let first = seeds.next(for: any), second = seeds.next(for: any), third = seeds.next(for: any), fourth = seeds.next(for: any)
        check(first == Array(ids[0..<5]) && second == Array(ids[5..<10]), "each fetch takes the next five of the source (\(first.count), \(second.count))")
        check(Set(third).isDisjoint(with: second) == false || third.count == 5, "a third fetch still has five seeds")
        check(third == [ids[10], ids[11], ids[0], ids[1], ids[2]], "then the two never used and the three used longest ago (\(third.map { $0.prefix(3) }))")
        check(Set(fourth).isDisjoint(with: third), "no two fetches in a row share a seed while the source allows (\(fourth.map { $0.prefix(3) }))")
        check(seeds.ids == Set(ids), "every song of the source is known, to keep it out of the mix")

        var small = MixSeeds(listened: Array(ids[0..<3]))
        check(small.next(for: any) == Array(ids[0..<3]) && small.next(for: any).count == 3, "a source of three gives all three every time")
        small.drop([ids[0], ids[1]])
        check(small.next(for: any) == [ids[2]] && !small.isEmpty, "seeds the service doesn't know are never offered again")
        small.drop([ids[2]])
        check(small.next(for: any).isEmpty && small.isEmpty, "with no seed left there is nothing to ask")
        check(MixSeeds(listened: []).isEmpty, "an empty source has no seeds")

        // Steering: the songs of the source that already fit lead; without any, the stones.
        var sad = MixRecipe()
        sad.mood = .sad
        let features = [ids[7]: MixFeatures(valence: 0.1, energy: 0.3), ids[9]: MixFeatures(valence: 0.3, energy: 0.9),
                        ids[0]: MixFeatures(valence: 0.9, energy: 0.9)]
        var steering = MixSeeds(listened: ids)
        check(steering.next(for: sad, features: features) == [ids[7], ids[9]], "a sad mix is seeded by the sad songs of the source")
        check(steering.next(for: sad, features: features, stones: [tid("x", 1)]) == [ids[7], ids[9]], "and keeps to them while there are any")
        let stones = (0..<7).map { tid("stone", $0) }
        var stepping = MixSeeds(listened: ids)
        let cheerful = [ids[0]: MixFeatures(valence: 0.9, energy: 0.9)]
        let step1 = stepping.next(for: sad, features: cheerful, stones: stones)
        let step2 = stepping.next(for: sad, features: cheerful, stones: stones)
        check(step1 == Array(stones[0..<5]) && step2 == [stones[5], stones[6], stones[0], stones[1], stones[2]],
              "with nothing sad in the source, the best-fitting songs found so far seed the next fetch, in rotation")
        check(stepping.next(for: sad, features: cheerful) == Array(ids[0..<5]), "with neither, the source as it is")
        check(stepping.next(for: any, features: features, stones: stones).allSatisfy(ids.contains), "a mix that doesn't steer always starts from the source")
    }

    // MARK: - Filters, ranking, artists

    static func candidate(_ id: String, valence: Double? = nil, energy: Double = 0.5, artists: [String]? = nil,
                          batch: Int = 1, order: Int = 0, ms: Int = 200_000) -> MixCandidate {
        MixCandidate(song: MixSong(id: id, title: "Title \(id)", artists: artists ?? ["Artist \(id)"], durationMs: ms),
                     features: valence.map { MixFeatures(valence: $0, energy: energy) }, batch: batch, order: order)
    }

    static func filterChecks() {
        let seed = tid("seed", 1), played = tid("played", 1), liked = tid("liked", 1), heard = tid("heard", 1), plain = tid("plain", 1)
        let exclusions = MixChooser.Exclusions(ids: [seed, played], liked: [liked], heard: [heard])
        var recipe = MixRecipe()
        // Talk isn't music, whatever was asked: a chapter of an audiobook is
        // as calm and as sad as anything, and a quiet mix used to rank it first.
        let chapter = MixCandidate(song: MixSong(id: plain, title: "Kapitel 14", artists: ["Hörspiel"], durationMs: 185_000),
                                   features: MixFeatures(valence: 0.2, energy: 0.2, speechiness: 0.93))
        let rap = MixCandidate(song: MixSong(id: plain, title: "Verse", artists: ["MC"], durationMs: 185_000),
                               features: MixFeatures(valence: 0.2, energy: 0.2, speechiness: 0.4))
        var quiet = MixRecipe()
        quiet.mood = .sad
        check(!MixChooser.allowed(chapter, quiet, MixChooser.Exclusions()) && !MixChooser.allowed(chapter, MixRecipe(), MixChooser.Exclusions()),
              "a track that is all speech must never play")
        check(MixChooser.allowed(rap, quiet, MixChooser.Exclusions()), "a song with a lot of words is still a song")

        func allowed(_ id: String, valence: Double? = 0.5) -> Bool {
            MixChooser.allowed(candidate(id, valence: valence), recipe, exclusions)
        }
        check(allowed(plain), "a new song may play")
        check(!allowed(seed), "the songs the mix starts from are left out")
        check(!allowed(played), "a song already in the mix is left out")
        check(!allowed(liked) && !allowed(heard), "liked and heard songs are left out by default")
        recipe.liked = .allow
        recipe.skipHeard = false
        check(allowed(liked) && allowed(heard), "and let in when the answers say so")
        check(!allowed(seed) && !allowed(played), "the seeds and the songs already in the mix stay out whatever the answers")
        check(allowed(plain, valence: nil), "a song without features plays when mood and energy are both Any")
        recipe.energy = .calm
        check(!allowed(plain, valence: nil), "and not once the mix steers by energy")
        recipe.energy = .any
        recipe.mood = .mellow
        check(!allowed(plain, valence: nil) && allowed(plain, valence: 0.95), "Mellow ranks a cheerful song low but doesn't refuse it")
        recipe.mood = .sad
        check(allowed(plain, valence: 0.40) && !allowed(plain, valence: 0.41), "Sad refuses everything above 0.40")
        recipe.mood = .happy
        check(allowed(plain, valence: 0.60) && !allowed(plain, valence: 0.59), "Happy refuses everything below 0.60")
        recipe.mood = .any
        recipe.energy = .energetic
        check(allowed(plain, valence: 0.5) && !MixChooser.fits(MixFeatures(valence: 0.5, energy: 0.5), recipe)
                && MixChooser.fits(MixFeatures(valence: 0.5, energy: 0.6), recipe), "Energetic fits from 0.60 and refuses nothing")
        check(MixChooser.fits(nil, MixRecipe()) && !MixChooser.fits(nil, recipe), "a song without features fits only a mix that doesn't steer")
        let bands: [(MixRecipe.Mood, ClosedRange<Double>)] = [(.sad, 0...0.40), (.mellow, 0.15...0.55), (.any, 0...1), (.bright, 0.45...0.85), (.happy, 0.60...1)]
        for (mood, band) in bands {
            let fitting = (0...100).map { Double($0) / 100 }.filter { mood.fits($0) }
            check(abs((fitting.first ?? -1) - band.lowerBound) < 0.001 && abs((fitting.last ?? -1) - band.upperBound) < 0.001,
                  "\(mood) fits \(band) (\(fitting.first ?? -1)…\(fitting.last ?? -1))")
        }
    }

    static func rankingChecks() {
        var recipe = MixRecipe()
        let none = MixChooser.Exclusions()
        // Any: the latest fetch first, each in the order the service gave.
        let mixed = [candidate(tid("a", 1), valence: 0.9, batch: 1, order: 1), candidate(tid("b", 1), valence: 0.1, batch: 2, order: 1),
                     candidate(tid("c", 1), valence: 0.5, batch: 2, order: 0), candidate(tid("d", 1), valence: nil, batch: 1, order: 0)]
        check(MixChooser.ranked(mixed, recipe, none).map { String($0.song.id.prefix(1)) } == ["c", "b", "d", "a"],
              "with nothing asked the newest fetch leads, in the service's order")
        recipe.mood = .sad
        recipe.energy = .calm
        let pool = MixFixtures.pop.enumerated().map { index, row in
            MixCandidate(song: MixSong(id: row.id, title: row.title, artists: row.artists, durationMs: row.durationMs),
                         features: MixFeatures(valence: row.valence, energy: row.energy), batch: 1, order: index)
        }
        let ranked = MixChooser.ranked(pool, recipe, none)
        let distances = ranked.map { MixChooser.distance($0.features!, to: recipe) }
        check(!ranked.isEmpty && ranked.count < 30 && ranked.allSatisfy { $0.features!.valence <= 0.40 },
              "of 88 real pop songs only the sad ones are left for a sad mix (\(ranked.count))")
        check(distances == distances.sorted(), "and they come nearest to sad and calm first")
        check(abs(MixChooser.distance(MixFeatures(valence: 0.25, energy: 0.45), to: recipe) - 0.70) < 0.0001, "distance adds the gaps in valence and in energy")
        check(MixChooser.fitting(pool, recipe, none) < 5, "almost none of them is calm as well (\(MixChooser.fitting(pool, recipe, none)))")
        recipe.mood = .any
        recipe.energy = .energetic
        let lively = MixChooser.ranked(pool, recipe, none)
        check(lively.count == 88 && lively[0].features!.energy >= lively[87].features!.energy
                && lively.prefix(15).allSatisfy { $0.features!.energy >= 0.6 },
              "Energetic keeps all 88 and puts the liveliest first")
        check(MixChooser.distance(MixFeatures(valence: 0.3, energy: 0.9), to: MixRecipe()) == 0, "with nothing asked every song is equally near")
    }

    static func artistChecks() {
        let same = (0..<5).map { candidate(tid("x", $0), valence: 0.5, artists: ["Bad Bunny"], order: $0) }
        let others = (0..<6).map { candidate(tid("y", $0), valence: 0.5, artists: ["Other \($0)"], order: 10 + $0) }
        let picked = MixChooser.pick(same + others, count: 8)
        let artists = picked.map { $0.song.artists[0] }
        check(artists.filter { $0 == "Bad Bunny" }.count == 2, "one artist gets two songs of a pick, not five (\(artists))")
        check(zip(artists, artists.dropFirst()).allSatisfy { $0 != $1 }, "and never two in a row (\(artists))")
        check(picked.first?.song.id == tid("x", 0) && picked.count == 8, "the best-ranked still leads, and the pick is full")
        let after = MixChooser.pick(same + others, count: 3, after: same[4].song)
        check(after.first?.song.artists == ["Other 0"], "a pick doesn't open with the artist of the song before it")
        let featured = [candidate(tid("f", 1), valence: 0.5, artists: ["A", "B"]), candidate(tid("f", 2), valence: 0.5, artists: ["C", "b "]),
                        candidate(tid("f", 3), valence: 0.5, artists: ["D"]), candidate(tid("f", 4), valence: 0.5, artists: ["B"]),
                        candidate(tid("f", 5), valence: 0.5, artists: ["E", "B"])]
        let names = MixChooser.pick(featured, count: 5).map { "f" + $0.song.id.suffix(1) }
        check(names == ["f1", "f3", "f2"], "a featured artist counts, however the name is cased (\(names))")
        check(MixChooser.pick(same, count: 5).count == 1, "with one artist only, one song is all a pick can take")
        let timed = (0..<10).map { candidate(tid("t", $0), valence: 0.5, order: $0, ms: 240_000) }
        check(MixChooser.pick(timed, count: 10, budgetMs: 600_000).count == 3, "a pick stops at the song that reaches the time left (3 × 4 min for 10 min)")
        check(MixChooser.pick(timed, count: 10, budgetMs: 0).isEmpty && MixChooser.pick(timed, count: 0).isEmpty, "no time or no room, no pick")
        // The real answer has two artists twice; neither ends up back to back.
        let real = MixFixtures.pop.enumerated().map { index, row in
            MixCandidate(song: MixSong(id: row.id, title: row.title, artists: row.artists, durationMs: row.durationMs), features: nil, batch: 1, order: index)
        }
        let realPick = MixChooser.pick(real, count: 88)
        var counts: [String: Int] = [:]
        for song in realPick.map(\.song) { for artist in Set(song.artists.map(MixChooser.artistKey)) { counts[artist, default: 0] += 1 } }
        check(realPick.count > 70 && counts.values.allSatisfy { $0 <= 2 }, "a real answer keeps to two songs an artist (\(realPick.count) picked)")
        check(zip(realPick, realPick.dropFirst()).allSatisfy { a, b in Set(a.song.artists.map(MixChooser.artistKey)).isDisjoint(with: b.song.artists.map(MixChooser.artistKey)) },
              "and never the same artist twice running")
        check(MixChooser.same(MixSong(id: tid("a", 1), title: "Blinding Lights", artists: ["The Weeknd"], durationMs: 1), title: "blinding lights ", artists: ["Someone", "the weeknd"])
                && !MixChooser.same(MixSong(id: tid("a", 1), title: "Blinding Lights", artists: ["The Weeknd"], durationMs: 1), title: "Blinding Lights", artists: ["A cover band"]),
              "a song is recognised under another ID by its title and an artist, not by its title alone")
    }

    // MARK: - A session

    /// A mix with stand-ins for everything around it.
    @MainActor final class Rig {
        let catalog = StubCatalog()
        let library = StubLibrary()
        let player = FakePlayer()
        let defaults = TestDefaults.make()
        let mix: MixModel
        let source = (0..<12).map { tid("src", $0) }

        init(_ answers: (inout MixRecipe) -> Void = { _ in }) {
            let library = library
            mix = MixModel(catalog: catalog, library: library, defaults: defaults, now: { library.now })
            mix.attach(player)
            mix.randomPage = { $0.lowerBound }
            // Twelve songs listened to this morning.
            library.plays = source.enumerated().map { ($1, Double($0) * 240) }
            var recipe = MixRecipe()
            answers(&recipe)
            mix.draft = recipe
        }

        /// Presses the button and waits for the first song to be sent to the player.
        func create() async {
            mix.create()
            await mix.settled()
        }

        /// Presses the button, and the first song starts playing.
        func start() async {
            await create()
            mix.playerChanged(player.begin())
            await mix.settled()
        }

        /// The song playing ends; Spotify moves on to its queue.
        @discardableResult func next() async -> Bool {
            guard let now = player.advance() else { return false }
            mix.playerChanged(now)
            await mix.settled()
            return true
        }

        func steer(_ change: (inout MixRecipe) -> Void) async {
            mix.steer(change)
            await mix.settled()
        }

        func features(of song: MixSong) -> MixFeatures? { catalog.features[song.id] }
    }

    static func sessionChecks() async {
        let rig = Rig { $0.length = .endless }
        check(rig.mix.phase == .idle && rig.catalog.seedLog.isEmpty, "nothing is asked of anyone before the button is pressed")
        rig.mix.create()
        check(rig.mix.phase == .preparing, "pressing the button starts gathering")
        await rig.mix.settled()
        check(rig.catalog.seedLog == [Array(rig.source[0..<5])], "one recommendation request, seeded by the five latest songs (\(rig.catalog.seedLog))")
        check(rig.catalog.targetLog.first?.valence == nil && rig.catalog.targetLog.first?.energy == nil, "with any mood no target is sent")
        check(rig.catalog.featureLog.count == 1 && rig.catalog.featureLog[0].count == 90, "then features for the songs that came back")
        check(rig.library.likedChecks.flatMap { $0 }.count == 90, "and which of them are liked, since liked songs are left out")
        check(rig.mix.phase == .starting && rig.player.started.count == 1 && rig.player.queue.isEmpty,
              "the first song is started by itself and nothing is queued until it plays")
        check(rig.mix.upcoming.count == MixModel.ahead - 1 && rig.mix.origin == .today, "twenty songs are chosen, from today's listening (\(rig.mix.upcoming.count))")
        let chosen = [rig.player.started[0]] + rig.mix.upcoming
        check(Set(chosen.map(\.id)).count == chosen.count && chosen.allSatisfy { !rig.source.contains($0.id) }, "no song twice, and none of the songs it started from")

        rig.mix.playerChanged(rig.player.begin())
        await rig.mix.settled()
        check(rig.mix.phase == .running && rig.mix.current == chosen[0], "once the first song plays the mix is running")
        check(rig.player.queue == Array(chosen[1...2]) && rig.mix.queued == rig.player.queue, "and the next two are in Spotify's queue, in order")
        check(rig.mix.upcoming == Array(chosen[3...]), "the rest stays with the mix")

        // Song after song: the queue never holds more than two, and each change adds one.
        var order = [chosen[0]]
        for step in 1...6 {
            await rig.next()
            order.append(rig.mix.current!)
            check(rig.player.queue.count == MixModel.lookahead && rig.mix.queued == rig.player.queue, "after song \(step) the queue holds two again (\(rig.player.queue.count))")
        }
        check(order == Array(chosen[0...6]), "songs play in the order they were chosen")
        check(rig.mix.playedMs == 6 * 200_000, "the mix knows how much of it has played (\(rig.mix.playedMs))")
        check(rig.player.started.count == 1, "the mix starts playback once and never takes it again")

        // Pause and resume on the same song change nothing.
        let queueBefore = rig.player.everQueued.count
        var paused = MixNowPlaying(uri: rig.mix.current!.uri)
        paused.isPlaying = false
        rig.mix.playerChanged(paused)
        paused.isPlaying = true
        rig.mix.playerChanged(paused)
        await rig.mix.settled()
        check(rig.player.everQueued.count == queueBefore && rig.mix.current == order.last, "pausing and resuming adds nothing")

        // Previous: back to a song already played. What's queued is still owed, nothing is added.
        rig.mix.playerChanged(MixNowPlaying(uri: order[5].uri))
        await rig.mix.settled()
        check(rig.mix.current == order[5] && rig.mix.queued == rig.player.queue && rig.player.everQueued.count == queueBefore,
              "going back to an earlier song keeps the queue as it is")
        // Skipping straight to the second queued song: the one passed over is done with.
        let skippedTo = rig.player.queue[1]
        _ = rig.player.advance()
        rig.mix.playerChanged(rig.player.advance())
        await rig.mix.settled()
        check(rig.mix.current == skippedTo && rig.player.queue.count == 2 && rig.mix.queued == rig.player.queue,
              "jumping over a queued song refills the queue to two")

        // A row taken out by hand never plays.
        let unwanted = rig.mix.upcoming[2]
        rig.mix.remove(unwanted)
        check(!rig.mix.upcoming.contains(unwanted), "a removed song leaves what's next")
        rig.mix.remove(rig.player.queue[0])
        check(rig.mix.queued.count == 2, "a song already handed to Spotify can't be removed")
        for _ in 0..<30 { await rig.next() }
        check(!rig.player.everQueued.contains(unwanted), "and a removed song never comes back, through refills either")
        check(Set(rig.player.everQueued.map(\.id)).count == rig.player.everQueued.count, "no song is queued twice in forty songs")
    }

    static func refillChecks() async {
        let rig = Rig { $0.length = .endless }
        await rig.start()
        // 1 playing + 2 queued + 17 chosen. Another batch is due once fewer than ten remain unplayed.
        var fetchedAt: [Int] = []
        for step in 1...40 {
            let before = rig.catalog.seedLog.count
            await rig.next()
            if rig.catalog.seedLog.count > before { fetchedAt.append(step) }
            check(rig.player.queue.count <= MixModel.lookahead, "the queue never holds more than two (step \(step))")
            check(rig.mix.queued.count + rig.mix.upcoming.count >= MixModel.lowWater - 1, "the mix never runs low (step \(step): \(rig.mix.upcoming.count) chosen)")
        }
        check(fetchedAt.first == 10, "the first refill comes when nine songs remain (\(fetchedAt))")
        check(rig.catalog.seedLog.count >= 4 && rig.catalog.seedLog.allSatisfy { $0.count == 5 }, "forty songs take several fetches, five seeds each (\(rig.catalog.seedLog.count))")
        check(zip(rig.catalog.seedLog, rig.catalog.seedLog.dropFirst()).allSatisfy { Set($0).isDisjoint(with: $1) },
              "each fetch is seeded differently from the one before")
        check(Set(rig.catalog.seedLog.flatMap { $0 }) == Set(rig.source), "and between them they use the whole source")
        check(rig.mix.phase == .running && rig.mix.problem == nil, "a mix that keeps going is still going after forty songs")
        // Songs from the newest fetch come next, ahead of leftovers from the first.
        let newest = rig.catalog.seedLog.count
        check(rig.mix.upcoming.last?.id.hasPrefix("b\(newest)n") == true, "the newest songs join the end of what's next (\(rig.mix.upcoming.last?.id ?? ""))")

        // Songs heard before and liked songs are left out of what the service answers.
        let picky = Rig()
        let firstBatch = Synthetic.rows(batch: 1)
        picky.library.heardIDs = Set(firstBatch[0..<10].map(\.id))
        picky.library.likedIDs = Set(firstBatch[10..<20].map(\.id))
        await picky.start()
        let offered = [picky.player.started[0]] + picky.player.queue + picky.mix.upcoming
        check(offered.first?.id == firstBatch[20].id && offered.allSatisfy { !picky.library.heardIDs.contains($0.id) && !picky.library.likedIDs.contains($0.id) },
              "a mix opens with the first song that is neither heard nor liked (\(offered.first?.title ?? ""))")
        await picky.steer { $0.skipHeard = false }
        check(picky.mix.upcoming.first?.id == firstBatch[0].id, "switching 'nothing I've heard' off lets the heard songs in at once (\(picky.mix.upcoming.first?.title ?? ""))")
        await picky.steer { $0.liked = .allow }
        check(picky.mix.upcoming.contains { $0.id == firstBatch[10].id }, "and allowing liked songs lets those in")
        check(picky.player.started.count == 1 && picky.player.queue.count == 2, "neither switch touches what Spotify already has")

        // Liked songs allowed from the start: nobody is asked which songs are liked.
        let open = Rig { $0.liked = .allow }
        await open.start()
        check(open.library.likedChecks.isEmpty, "with liked songs allowed their state is never asked for")
        await open.steer { $0.liked = .leaveOut }
        check(open.library.likedChecks.flatMap { $0 }.count == 87, "switching 'no liked songs' on asks about the candidates left (\(open.library.likedChecks.flatMap { $0 }.count))")

        // Spotify can't say which songs are liked: the mix plays on and says so.
        let blind = Rig()
        blind.library.plays = blind.source.enumerated().map { ($1, Double($0) * 240) }
        blind.library.spotifyFails = true
        await blind.start()
        check(blind.mix.phase == .running && blind.mix.likedUnchecked, "a mix still plays when liked songs can't be checked, and says so")
    }

    static func steeringChecks() async {
        // The source is pop; the service answers pop for it and quiet songs for anything quiet.
        let popIDs = Set(MixFixtures.pop.map(\.id))
        let rig = Rig { $0.length = .endless }
        let source = Set(rig.source)
        rig.catalog.respond = { seeds, _ in seeds.allSatisfy(source.contains) ? MixFixtures.pop : MixFixtures.calm }
        await rig.start()
        let handedBefore = rig.player.queue
        let chosenBefore = rig.mix.upcoming
        check(chosenBefore.allSatisfy { popIDs.contains($0.id) }, "an unsteered mix plays what the service gave, in its order")

        await rig.steer { $0.mood = $0.mood.sadder.sadder }
        check(rig.mix.recipe.mood == .sad && rig.mix.draft.mood == .any, "a live control changes the running mix, not the questionnaire")
        check(rig.player.queue == handedBefore && rig.mix.queued == handedBefore && rig.player.started.count == 1,
              "steering leaves the two songs Spotify already has")
        check(!rig.mix.upcoming.isEmpty && rig.mix.upcoming.allSatisfy { (rig.features(of: $0)?.valence ?? 1) <= 0.40 },
              "everything not yet handed out is chosen again: only sad songs are next")
        check(rig.mix.upcoming != chosenBefore, "what was next before is replaced")
        let valences = rig.mix.upcoming.prefix(8).compactMap { rig.features(of: $0)?.valence }
        check(rig.catalog.seedLog.count == 1, "enough of the songs already found are sad, so nothing is fetched (\(rig.catalog.seedLog.count))")
        check(valences == valences.sorted() && (valences.first ?? 1) < 0.1, "the saddest comes first (\(valences))")

        // Calm as well: two of 88 pop songs are calm, so the mix has to look further.
        await rig.steer { $0.energy = $0.energy.calmer }
        check(rig.catalog.seedLog.count >= 2, "too few songs fit sad and calm, so more are fetched (\(rig.catalog.seedLog.count))")
        check(rig.catalog.featureLog.contains { Set($0).isSubset(of: source) && !$0.isEmpty }, "the source's own features are asked for once the mix steers")
        check(rig.catalog.seedLog[1].allSatisfy(popIDs.contains) && rig.catalog.seedLog[1].count <= 5,
              "with nothing sad and calm in the source, the best-fitting songs found so far are the seeds (\(rig.catalog.seedLog[1].count))")
        check(rig.catalog.targetLog.last?.valence == 0 && rig.catalog.targetLog.last?.energy == 0, "the targets are sent along")
        let next = rig.mix.upcoming.prefix(10)
        check(next.count == 10 && next.allSatisfy { song in
            guard let features = rig.features(of: song) else { return false }
            return features.valence <= 0.40 && features.energy <= 0.50
        }, "and what's next is sad and calm")
        check(rig.player.queue == handedBefore, "still without touching Spotify's queue")
        // The change is heard after the two queued songs.
        await rig.next()
        await rig.next()
        await rig.next()
        check((rig.features(of: rig.mix.current!)?.valence ?? 1) <= 0.40 && (rig.features(of: rig.mix.current!)?.energy ?? 1) <= 0.50,
              "the third song after the change is the first chosen under it")

        // Happier, all the way: cheerful songs only, and the sad ones gone.
        await rig.steer { $0.mood = .happy; $0.energy = .any }
        check(rig.mix.upcoming.count >= 10 && rig.mix.upcoming.allSatisfy { (rig.features(of: $0)?.valence ?? 0) >= 0.60 },
              "Happy leaves only cheerful songs next (\(rig.mix.upcoming.count))")
        await rig.steer { $0.source = .liked; $0.length = .halfHour; $0.liked = .only }
        check(rig.mix.recipe.source == .today && rig.mix.recipe.length == .endless && rig.mix.recipe.liked == .leaveOut,
              "the source, the length and 'only liked songs' can't be changed while a mix plays")

        // A source with a quiet song in it: that song seeds the calm mix, not the pop around it.
        let quiet = Rig { $0.energy = .calm }
        let quietSource = Set(quiet.source)
        quiet.catalog.features[quiet.source[8]] = MixFeatures(valence: 0.2, energy: 0.2)
        for id in quiet.source where id != quiet.source[8] { quiet.catalog.features[id] = MixFeatures(valence: 0.7, energy: 0.9) }
        quiet.catalog.respond = { seeds, _ in seeds == [quiet.source[8]] ? MixFixtures.calm : MixFixtures.pop }
        _ = quietSource
        await quiet.start()
        check(quiet.catalog.seedLog.first == [quiet.source[8]], "a calm mix is seeded by the calm song of the source (\(quiet.catalog.seedLog.first?.count ?? 0) seeds)")
        check(quiet.catalog.featureLog.first.map(Set.init) == quietSource, "after one request for the source's features")
        check(([quiet.player.started[0]] + quiet.player.queue + quiet.mix.upcoming).allSatisfy { (quiet.features(of: $0)?.energy ?? 1) <= 0.50 },
              "and plays calm songs from the first one")

        // A press while a fetch is still out: it applies, and the answer is chosen under it.
        let slow = Rig { $0.length = .endless }
        slow.catalog.respond = { _, _ in MixFixtures.pop }
        await slow.start()
        for _ in 0..<9 { await slow.next() }
        slow.catalog.holds = true
        _ = slow.player.advance().map(slow.mix.playerChanged)
        while !slow.catalog.isWaiting { try? await Task.sleep(for: .milliseconds(1)) }
        check(slow.mix.isChoosing, "a refill under way shows")
        slow.mix.steer { $0.mood = .happy }
        check(slow.mix.upcoming.allSatisfy { (slow.features(of: $0)?.valence ?? 0) >= 0.60 }, "a press during a fetch re-chooses at once")
        slow.catalog.release()
        await slow.mix.settled()
        check(!slow.mix.isChoosing && slow.mix.upcoming.allSatisfy { (slow.features(of: $0)?.valence ?? 0) >= 0.60 },
              "and the songs that arrive are chosen under the new answers")
    }

    static func lengthChecks() async {
        // Half an hour of 3:20 songs is nine songs.
        let rig = Rig { $0.length = .halfHour }
        await rig.start()
        check(1 + rig.player.queue.count + rig.mix.upcoming.count == 9, "half an hour is planned as nine songs (\(1 + rig.player.queue.count + rig.mix.upcoming.count))")
        var played = 1
        while await rig.next() { played += 1 }
        check(played == 9 && rig.mix.lengthReached && rig.mix.upcoming.isEmpty && rig.mix.queued.isEmpty, "nine songs play and nothing is left (\(played))")
        check(rig.catalog.seedLog.count == 1, "a mix that fits in one batch fetches once")
        check(rig.mix.phase == .running, "the last song is still the mix")
        var ended = MixNowPlaying(uri: rig.mix.current!.uri)
        ended.isPlaying = false
        rig.mix.playerChanged(ended)
        check(rig.mix.phase == .running, "pausing the last song doesn't end the mix")
        ended.atEnd = true
        rig.mix.playerChanged(ended)
        check(rig.mix.phase == .idle && rig.mix.ending == .complete, "the last song ending does")
        check(rig.player.everQueued.count == 8 && rig.player.started.count == 1, "nine songs were handed out in all")

        // Whatever plays after the last song isn't a reason to call the mix interrupted.
        let other = Rig { $0.length = .halfHour }
        await other.start()
        while await other.next() {}
        other.mix.playerChanged(MixNowPlaying(uri: "spotify:track:\(tid("autoplay", 1))"))
        check(other.mix.phase == .idle && other.mix.ending == .complete, "a song after the last one ends the mix as complete")

        // An hour is eighteen songs: one batch can't cover that with fewer than ten in hand, so a second comes.
        let hour = Rig()
        await hour.start()
        var count = 1
        while await hour.next() { count += 1 }
        check(count == 18 && hour.mix.lengthReached, "an hour of 3:20 songs is eighteen (\(count))")
        check(hour.mix.playedMs == 17 * 200_000, "seventeen of them are behind the last")
    }

    static func lettingGoChecks() async {
        let rig = Rig { $0.length = .endless }
        await rig.start()
        await rig.next()
        let queuedBefore = rig.player.everQueued.count
        let fetchesBefore = rig.catalog.seedLog.count
        // The user plays an album: a song the mix never handed out.
        rig.mix.playerChanged(MixNowPlaying(uri: "spotify:track:\(tid("album", 1))", title: "Something else", artists: ["Someone else"]))
        check(rig.mix.phase == .idle && rig.mix.ending == .replaced, "a song that isn't the mix's ends it")
        check(rig.mix.upcoming.isEmpty && rig.mix.queued.isEmpty && rig.mix.current == nil, "and empties it")
        // The two songs Spotify still holds play later; the mix doesn't come back for them.
        for song in rig.player.queue { rig.mix.playerChanged(MixNowPlaying(uri: song.uri)) }
        await rig.mix.settled()
        check(rig.player.everQueued.count == queuedBefore && rig.player.started.count == 1 && rig.catalog.seedLog.count == fetchesBefore,
              "after letting go nothing is queued, started or fetched")
        check(rig.mix.phase == .idle, "its own leftover songs don't revive it")

        // Stop mix: the same, by hand.
        let stopped = Rig { $0.length = .endless }
        await stopped.start()
        stopped.mix.stop()
        check(stopped.mix.phase == .idle && stopped.mix.ending == nil && stopped.mix.upcoming.isEmpty, "Stop returns to the questionnaire")
        let before = stopped.player.everQueued.count
        while await stopped.next() {}
        check(stopped.player.everQueued.count == before, "and nothing is added to the queue afterwards")

        // The song from before the mix reports again while the first one loads: not a reason to end.
        let loading = Rig()
        loading.player.playingURI = "spotify:track:\(tid("before", 1))"
        await loading.create()
        var old = MixNowPlaying(uri: loading.player.playingURI!)
        old.isPlaying = false
        loading.mix.playerChanged(old)
        check(loading.mix.phase == .starting, "the song that was playing before doesn't end a mix that is starting")
        loading.mix.playerChanged(loading.player.begin())
        await loading.mix.settled()
        check(loading.mix.phase == .running && loading.player.queue.count == 2, "and the mix runs once its first song plays")

        // Spotify plays a queued song under another ID (the same recording, relinked).
        let owed = loading.player.queue[0]
        _ = loading.player.advance()
        loading.mix.playerChanged(MixNowPlaying(uri: "spotify:track:\(tid("relinked", 1))", title: owed.title.uppercased(), artists: owed.artists))
        await loading.mix.settled()
        check(loading.mix.phase == .running && loading.mix.current == owed && loading.player.queue.count == 2,
              "a queued song played under another ID is still the mix's song")
        loading.mix.playerChanged(MixNowPlaying(uri: "spotify:track:\(tid("relinked", 1))", title: "", artists: []))
        check(loading.mix.phase == .running, "and is remembered under that ID")

        // Stopped while the first fetch is out: the answer is dropped.
        let early = Rig()
        early.catalog.holds = true
        early.mix.create()
        while !early.catalog.isWaiting { try? await Task.sleep(for: .milliseconds(1)) }
        early.mix.stop()
        early.catalog.release()
        await early.mix.settled()
        check(early.mix.phase == .idle && early.player.started.isEmpty && early.mix.upcoming.isEmpty && early.mix.problem == nil,
              "a mix stopped while gathering never starts")
        await early.start()
        check(early.mix.phase == .running && early.player.started.count == 1, "and a new one can be made right after")
    }

    // MARK: - Where a mix starts

    static func sourceChecks() async {
        // "Today" takes today's plays only.
        let today = Rig()
        today.library.plays = today.source.enumerated().map { ($1, $0 < 6 ? 3600 : 30 * 3600) }
        await today.create()
        check(today.mix.origin == .today && Set(today.catalog.seedLog[0]) == Set(today.source[0..<5]),
              "today's mix starts from songs played since midnight")
        let week = Rig { $0.source = .week }
        week.library.plays = week.source.enumerated().map { ($1, $0 < 8 ? Double($0 + 1) * 86_400 * 0.8 : 30 * 86_400) }
        for _ in 0..<3 { week.library.plays.append((week.source[5], 86_400)) }
        await week.create()
        check(week.mix.origin == .week && week.catalog.seedLog[0].first == week.source[5] && !week.catalog.seedLog[0].contains(week.source[9]),
              "this week's mix starts from the last seven days, the most played first")

        // Nothing played today: Spotify's recently played stands in, and the page can say so.
        let recent = (0..<8).map { tid("rec", $0) }
        let empty = Rig()
        empty.library.plays = []
        empty.library.recent = recent + [recent[0]]
        await empty.start()
        check(empty.mix.origin == .recentlyPlayed && empty.mix.phase == .running, "an empty history falls back to Spotify's recently played")
        check(empty.catalog.seedLog[0] == Array(recent[0..<5]), "seeded by its latest songs (\(empty.catalog.seedLog[0].map { $0.prefix(4) }))")
        check(empty.library.likedPagesAsked.isEmpty, "liked songs aren't read when recently played has enough")

        // Two songs today is too thin: they lead, and recently played fills in.
        let thin = Rig()
        thin.library.plays = [(thin.source[0], 60), (thin.source[1], 120)]
        thin.library.recent = recent
        await thin.create()
        check(thin.mix.origin == .recentlyPlayed && thin.catalog.seedLog[0] == [thin.source[0], thin.source[1], recent[0], recent[1], recent[2]],
              "a thin history keeps its own songs first and adds recently played")

        // Neither: the newest liked songs.
        let liked = Rig()
        liked.library.plays = []
        liked.library.likedTracks = (0..<120).map { Synthetic.track(tid("lik", $0)) }
        await liked.start()
        check(liked.mix.origin == .liked && liked.mix.phase == .running, "with nothing played anywhere, liked songs are the start")
        check(liked.library.likedPagesAsked == [0, 50] && liked.catalog.seedLog[0] == (0..<5).map { tid("lik", $0) },
              "the newest liked songs, and one more page of the library (\(liked.library.likedPagesAsked))")

        // Asked for liked songs outright.
        let asked = Rig { $0.source = .liked }
        asked.library.likedTracks = (0..<30).map { Synthetic.track(tid("lik", $0)) }
        await asked.create()
        check(asked.mix.origin == .liked && asked.library.likedPagesAsked == [0] && asked.catalog.seedLog[0].allSatisfy { $0.hasPrefix("lik") },
              "'my liked songs' starts from them whatever was played today")

        // Nothing at all.
        let nothing = Rig()
        nothing.library.plays = []
        await nothing.create()
        check(nothing.mix.phase == .idle && nothing.mix.problem == .nothingToStartFrom && nothing.catalog.seedLog.isEmpty,
              "with no history, no recent plays and no liked songs the page says there's nothing to start from")
        // Spotify unreachable, but Tint remembers three songs: enough to start.
        let offline = Rig { $0.liked = .allow }
        offline.library.plays = [(offline.source[0], 60), (offline.source[1], 120), (offline.source[2], 180)]
        offline.library.spotifyFails = true
        await offline.create()
        check(offline.mix.origin == .today && offline.mix.phase == .starting, "a thin history is still used when Spotify can't add to it")

        // The service knows none of the first seeds: they're dropped and the next ones tried.
        let partial = Rig()
        partial.catalog.unknownSeeds = Set(partial.source[0..<5])
        await partial.start()
        check(partial.catalog.seedLog.count == 2 && partial.catalog.seedLog[1] == Array(partial.source[5..<10]) && partial.mix.phase == .running,
              "seeds the service doesn't know are dropped and others tried (\(partial.catalog.seedLog.map(\.count)))")
        for _ in 0..<12 { await partial.next() }
        check(partial.catalog.seedLog.dropFirst().allSatisfy { Set($0).isDisjoint(with: partial.catalog.unknownSeeds) }, "and never sent again")
        let unknown = Rig()
        unknown.catalog.unknownSeeds = Set(unknown.source)
        await unknown.create()
        check(unknown.mix.phase == .idle && unknown.mix.problem == .unknownSongs && unknown.player.started.isEmpty,
              "when it knows none of them the page says so (\(String(describing: unknown.mix.problem)))")
        check(unknown.catalog.seedLog.count == 3, "after trying every seed once (\(unknown.catalog.seedLog.count) requests)")
    }

    static func likedOnlyChecks() async {
        let rig = Rig { $0.liked = .only; $0.length = .endless }
        rig.library.likedTracks = (0..<230).map { index in
            Synthetic.track(tid("lik", index), name: "Liked \(index)", artist: "Artist \(index % 60)")
        }
        for index in 0..<230 { rig.catalog.features[tid("lik", index)] = MixFeatures(valence: Double(index % 10) / 10, energy: 0.5) }
        rig.library.heardIDs = [tid("lik", 0)]
        await rig.start()
        check(rig.mix.phase == .running && rig.catalog.seedLog.isEmpty && rig.catalog.featureLog.isEmpty,
              "only liked songs with any mood asks ReccoBeats nothing at all")
        check(rig.library.likedPagesAsked == [0, 50] && rig.library.likedChecks.isEmpty, "it reads two pages of liked songs and doesn't ask which are liked")
        let offered = [rig.player.started[0]] + rig.player.queue + rig.mix.upcoming
        check(offered.allSatisfy { $0.id.hasPrefix("lik") } && !offered.contains { $0.id == tid("lik", 0) },
              "every song is a liked one, without the one already heard")
        check(rig.mix.details[offered[0].id]?.name == offered[0].title && rig.library.lookups.isEmpty, "liked songs come with their covers, so none is looked up")
        await rig.steer { $0.mood = .happy }
        check(rig.catalog.featureLog.flatMap { $0 }.count >= 97 && rig.catalog.seedLog.isEmpty, "steering asks for the features of the liked songs read so far, and still no recommendations")
        check(!rig.mix.upcoming.isEmpty && rig.mix.upcoming.allSatisfy { (rig.features(of: $0)?.valence ?? 0) >= 0.6 }, "and picks the cheerful ones")
        for _ in 0..<40 { await rig.next() }
        check(Set(rig.library.likedPagesAsked) == [0, 50, 100, 150, 200], "more pages are read as the mix goes on, each once (\(rig.library.likedPagesAsked))")
        check(rig.library.likedPagesAsked.count == 5, "no page is read twice")

        let none = Rig { $0.liked = .only }
        await none.create()
        check(none.mix.phase == .idle && none.mix.problem == .noLikedSongs, "with no liked songs the page says so")
        let few = Rig { $0.liked = .only; $0.mood = .sad }
        few.library.likedTracks = (0..<6).map { Synthetic.track(tid("lik", $0)) }
        for index in 0..<6 { few.catalog.features[tid("lik", index)] = MixFeatures(valence: 0.9, energy: 0.5) }
        await few.create()
        check(few.mix.phase == .idle && few.mix.problem == .nothingFits, "six cheerful liked songs can't make a sad mix, and the page says nothing fits")
    }

    // MARK: - Failures and lookups

    static func failureChecks() async {
        let offline = Rig()
        offline.catalog.failure = URLError(.notConnectedToInternet)
        await offline.create()
        if case .unreachable = offline.mix.problem {} else { check(false, "no network is reported as unreachable (\(String(describing: offline.mix.problem)))") }
        check(offline.mix.phase == .idle && offline.player.started.isEmpty, "and no mix starts")
        offline.catalog.failure = nil
        await offline.start()
        check(offline.mix.phase == .running && offline.mix.problem == nil, "trying again once the network is back works")

        let busy = Rig()
        busy.catalog.failure = ReccoBeats.Failure.busy
        await busy.create()
        check(busy.mix.problem == .busy, "a busy service is reported as busy")
        let refused = Rig()
        refused.catalog.failure = ReccoBeats.Failure.rejected("getRecommendation.size: must be less than or equal to 100")
        await refused.create()
        check(refused.mix.problem == .service("getRecommendation.size: must be less than or equal to 100"), "a refused request carries its reason")

        // The network drops while a mix plays: it keeps what it has, says so, and recovers.
        let rig = Rig { $0.length = .endless }
        await rig.start()
        for _ in 0..<9 { await rig.next() }
        rig.catalog.failure = URLError(.timedOut)
        await rig.next()
        check(rig.mix.phase == .running && rig.mix.problem != nil && !rig.mix.upcoming.isEmpty, "a failed refill leaves the mix playing what it has")
        check(!rig.mix.isChoosing, "and isn't shown as still fetching")
        rig.catalog.failure = nil
        rig.mix.retry()
        await rig.mix.settled()
        check(rig.mix.problem == nil && rig.mix.upcoming.count >= MixModel.lowWater, "Try Again fetches and clears the message (\(rig.mix.upcoming.count))")

        // Not connected: the first song can't start.
        let silent = Rig()
        silent.player.connected = false
        await silent.create()
        check(silent.mix.phase == .idle && silent.mix.problem == .cannotPlay, "a player that refuses the first song is reported")
        // The connection drops mid-mix: songs stay with the mix until the queue takes them.
        let dropped = Rig { $0.length = .endless }
        await dropped.start()
        dropped.player.connected = false
        let chosen = dropped.mix.upcoming
        await dropped.next()
        check(dropped.mix.upcoming == chosen && dropped.mix.queued.count == 1, "a song the queue refused stays with the mix")
        dropped.player.connected = true
        await dropped.next()
        check(dropped.mix.queued.count == 2 && dropped.mix.upcoming == Array(chosen.dropFirst(2)), "and is handed out when the queue takes songs again")

        // Nothing sad anywhere near: three fetches, then the page says nothing fits.
        let cheerful = Rig { $0.mood = .sad }
        cheerful.catalog.respond = { _, fetch in Synthetic.rows(batch: fetch).map { ($0.id, $0.title, $0.artists, $0.durationMs, 0.8, $0.energy) } }
        await cheerful.create()
        check(cheerful.mix.phase == .idle && cheerful.mix.problem == .nothingFits && cheerful.catalog.seedLog.count == MixModel.fetchesAtOnce,
              "a mood nothing fits is given up on after three fetches (\(cheerful.catalog.seedLog.count))")

        // The questionnaire's answers are saved as they change, not the live ones.
        let saved = Rig { $0.mood = .bright; $0.length = .twoHours }
        check(MixRecipe.saved(in: saved.defaults).mood == .bright && MixRecipe.saved(in: saved.defaults).length == .twoHours, "answers are remembered as they're given")
        await saved.start()
        await saved.steer { $0.mood = .sad }
        check(MixRecipe.saved(in: saved.defaults).mood == .bright, "steering a running mix doesn't rewrite the remembered answers")
    }

    static func detailChecks() async {
        let rig = Rig()
        await rig.start()
        check(rig.library.lookups.isEmpty && rig.mix.details.isEmpty, "no song is looked up on Spotify until a row asks")
        let shown = [rig.mix.current!] + rig.mix.queued + rig.mix.upcoming.prefix(3)
        for song in shown { rig.mix.wantDetails(for: song) }
        for song in shown { rig.mix.wantDetails(for: song) }
        await rig.mix.settled()
        check(rig.library.lookups == shown.map(\.id), "the rows on screen are looked up once each, in order (\(rig.library.lookups.count))")
        check(shown.allSatisfy { rig.mix.details[$0.id] != nil }, "and kept")
        rig.mix.wantDetails(for: shown[0])
        await rig.mix.settled()
        check(rig.library.lookups.count == shown.count, "a song looked up once isn't asked for again")
        rig.library.spotifyFails = true
        let missing = rig.mix.upcoming[5]
        rig.mix.wantDetails(for: missing)
        await rig.mix.settled()
        rig.library.spotifyFails = false
        rig.mix.wantDetails(for: missing)
        await rig.mix.settled()
        check(rig.mix.details[missing.id] == nil && rig.library.lookups.count == shown.count, "a lookup that failed isn't retried on every redraw")
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition {
            print("FAIL: \(message())")
            exit(1)
        }
    }
}
