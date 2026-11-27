import Foundation

/// The Friends page without the app or the network: what ListenBrainz's
/// answers mean (from answers it really gave, `FriendsFixtures`), the one paced
/// line of requests on a clock the test moves, and the list of friends, its
/// order and its refreshing.
@main
@MainActor
struct FriendsTests {
    static var checks = 0

    static func main() async {
        parsing()
        await client()
        await pacing()
        await list()
        await refreshing()
        await keepingFresh()
        print("PASS: \(checks) friends checks (ListenBrainz answers, pacing and rate limits, the list, its order, refreshing only when asked)")
    }

    // MARK: - Answers

    static func parsing() {
        func listens(_ text: String) -> [FriendListen] { (try? ListenBrainz.listens(in: Data(text.utf8))) ?? [] }

        check((try? ListenBrainz.listens(in: Data(FriendsFixtures.nothingPlaying.utf8))) == [], "nothing playing must be an empty list, not an error")

        let playing = listens(FriendsFixtures.playingNow)
        check(playing.count == 1 && playing[0].title == "There There" && playing[0].artist == "Radiohead"
              && playing[0].album == "Hail to the Thief", "the playing song must be read (\(playing))")
        check(playing[0].listenedAt == nil && playing[0].spotifyID == nil && playing[0].cover == nil && playing[0].durationMs == 323_000,
              "a playing song has no time, and this one neither link nor cover (\(playing))")

        let mapped = listens(FriendsFixtures.listensMapped)
        check(mapped.count == 2 && mapped[0].title == "Some Resolve" && mapped[0].artist == "Röyksopp"
              && mapped[0].listenedAt == Date(timeIntervalSince1970: 1_771_414_109), "a matched listen must be read (\(mapped))")
        check(mapped[0].spotifyID == "7H7RaiZoTNPwjNLygV4fXQ" && mapped[1].spotifyID == "2IptkwA6pNq5DxQoP4N0AJ",
              "a Spotify link among the release's links must be found (\(mapped.map(\.spotifyID)))")
        check(mapped[0].cover?.absoluteString == "https://coverartarchive.org/release/f1418001-7f1e-46af-bfdb-95faeded8841/32916450708-250.jpg",
              "the cover must come from the matched release (\(String(describing: mapped[0].cover)))")
        check(mapped[0].uri == "spotify:track:7H7RaiZoTNPwjNLygV4fXQ" && mapped[0].spotifyArtists.isEmpty && mapped[0].durationMs == 402_390,
              "a listen from a media server has a track to play but no Spotify artists")

        let unmapped = listens(FriendsFixtures.listensUnmapped)
        check(unmapped.count == 4 && unmapped.allSatisfy { $0.spotifyID == nil && $0.cover == nil },
              "a Bandcamp page isn't a Spotify link, and a bare or missing mapping has no cover (\(unmapped))")
        check(unmapped[0].title == "Piano Womper" && unmapped[0].album == nil && unmapped[0].durationMs == 363_000,
              "a length in seconds must be read as one (\(String(describing: unmapped[0].durationMs)))")
        check(unmapped[1].title == "Tambury Suite Pt. II" && unmapped[1].album == "Green Electric Chapel" && unmapped[1].durationMs == 156_453,
              "a listen with no mapping at all must still be shown (\(unmapped[1]))")
        check(unmapped[0].searchText == "Better Late Piano Womper", "a song with no link is searched for by artist and title")

        let spotify = listens(FriendsFixtures.listensFromSpotify)
        check(spotify.count == 3 && spotify[0].spotifyID == "5iCY0TXNImK4hyKfcplQsg" && spotify[0].title == "Baarishein",
              "a listen from Spotify must carry its track (\(spotify))")
        check(spotify[0].spotifyArtists == [.init(id: "4gdMJYnopf2nEUcanAwstx", name: "Anuv Jain")]
              && spotify[1].spotifyArtists.map(\.name) == ["Sachin-Jigar", "Shreya Ghoshal", "Tochi Raina"]
              && spotify[1].spotifyArtists.map(\.id) == ["1mBydYMVBECdDmMfE2sEUO", "0oOet2f43PA68X5RxKobEy", "6k6dimE4a6OFnD0HWmkIUW"],
              "and its artists, each with their own link (\(spotify.map(\.spotifyArtists)))")
        check(spotify[0].cover != nil, "a listen from Spotify that was matched has a cover too")
        check(listens(FriendsFixtures.listensFromSpotifyOlder).first?.spotifyID == "7HVkDgjIDN9TCyjzjZu1Fs",
              "`spotify_id` alone, without `origin_url`, is enough")

        let youtube = listens(FriendsFixtures.listensFromYouTube)
        check(youtube.count == 2 && youtube.allSatisfy { $0.spotifyID == nil && $0.album == nil && $0.cover != nil },
              "a YouTube listen has no Spotify track and may have no album (\(youtube))")
        check(youtube[0].durationMs == 270_000 && youtube[1].durationMs == nil, "a listen may have no length at all")

        let artists = (try? ListenBrainz.topArtists(in: Data(FriendsFixtures.topArtistsLastWeek.utf8))) ?? []
        check(artists.count == 5 && artists[0] == FriendArtist(name: "Morphine", listens: 16)
              && artists[3] == FriendArtist(name: "Kikagaku Moyo/幾何学模様", listens: 6),
              "top artists must be read, with or without an MBID (\(artists))")
        check((try? ListenBrainz.topArtists(in: Data(FriendsFixtures.topArtistsThisWeek.utf8)))?.first?.name == "Morphine", "this week's too")
        check((try? ListenBrainz.listenCount(in: Data(FriendsFixtures.listenCount.utf8))) == 220_287, "the listen count must be read")
        let following = (try? ListenBrainz.following(in: Data(FriendsFixtures.following.utf8))) ?? []
        check(following.count == 7 && following.first == "Zastai" && following.contains("Ruud v A"), "followed names must be read (\(following))")

        check((try? ListenBrainz.listens(in: Data(FriendsFixtures.noSuchUser.utf8))) == nil, "an error's body isn't a list of listens")
        check((try? ListenBrainz.listens(in: Data())) == nil && (try? ListenBrainz.topArtists(in: Data("[]".utf8))) == nil,
              "an empty or foreign body must be refused, not read as nothing")

        // Whatever a player sends: text for numbers, missing names, links in every spelling.
        let odd = listens(#"""
        {"payload":{"listens":[
          {"listened_at":1700000000,"track_metadata":{"track_name":"A","artist_name":"B","additional_info":{"duration_ms":"215000","spotify_id":"spotify:track:0123456789abcdefghijKL"}}},
          {"listened_at":1700000001,"track_metadata":{"track_name":"","artist_name":"B"}},
          {"listened_at":1700000002,"track_metadata":{"artist_name":"B"}},
          {"track_metadata":{"track_name":"C","artist_name":"D","release_name":"","additional_info":{"origin_url":"https://open.spotify.com/intl-de/track/0123456789abcdefghijKL?si=abc","spotify_artist_ids":["https://open.spotify.com/artist/0123456789abcdefghijKL"],"artist_names":["D","E"]},"mbid_mapping":{"caa_id":12,"caa_release_mbid":"../../evil"}}},
          "not a listen"
        ]}}
        """#)
        check(odd.count == 2 && odd[0].durationMs == 215_000 && odd[0].spotifyID == "0123456789abcdefghijKL",
              "a length sent as text and a `spotify:` URI must be read; listens without a name are skipped (\(odd))")
        check(odd[1].spotifyID == "0123456789abcdefghijKL" && odd[1].album == nil && odd[1].spotifyArtists.isEmpty && odd[1].cover == nil,
              "a country prefix and a query don't hide the ID; artists that don't pair up and a release that isn't an MBID are dropped (\(odd))")
        check(ListenBrainz.spotifyID(of: "track", in: "https://open.spotify.com/album/0123456789abcdefghijKL") == nil
              && ListenBrainz.spotifyID(of: "track", in: "https://open.spotify.com/track/short") == nil
              && ListenBrainz.spotifyID(of: "track", in: "https://1980recordings.bandcamp.com/track/piano-womper") == nil,
              "only a Spotify track's address gives a track")
    }

    // MARK: - Client

    static func client() async {
        let clock = FakeClock(), stub = StubTransport(clock: clock)
        let client = ListenBrainzClient(transport: stub, clock: clock)

        stub.answer = { _ in (200, FriendsFixtures.nothingPlaying) }
        let nothing = await result { try await client.playingNow("Ruud v A") }
        check(nothing == .some(nil), "nothing playing is an answer, not a failure")
        let request = stub.requests.last
        check(request?.url?.absoluteString == "https://api.listenbrainz.org/1/user/Ruud%20v%20A/playing-now",
              "a name with spaces must be escaped in the address (\(request?.url?.absoluteString ?? "none"))")
        let agent = request?.value(forHTTPHeaderField: "User-Agent") ?? ""
        check(agent.range(of: #"^Tint/[0-9.]+ \( https://\S+ \)$"#, options: .regularExpression) != nil,
              "every request must name the app and a way to reach it, as ListenBrainz asks (\(agent))")
        check(request?.value(forHTTPHeaderField: "Authorization") == nil && request?.httpBody == nil && request?.httpMethod == "GET",
              "requests are plain reads with no key and no body")

        stub.answer = { _ in (200, FriendsFixtures.listensFromSpotify) }
        let listens = try? await client.listens("dpmittal", count: 5)
        check(listens?.count == 3 && stub.requests.last?.url?.absoluteString == "https://api.listenbrainz.org/1/user/dpmittal/listens?count=5",
              "listens are asked for by count (\(stub.requests.last?.url?.absoluteString ?? "none"))")

        stub.answer = { _ in (204, "") }
        let uncalculated = await result { try await client.topArtists("rob", range: .lastWeek, count: 5) }
        check(uncalculated == .some(nil), "statistics not calculated yet (204) are an answer: none")
        check(stub.requests.last?.url?.absoluteString == "https://api.listenbrainz.org/1/stats/user/rob/artists?count=5&range=week",
              "last week is ListenBrainz's `week` (\(stub.requests.last?.url?.absoluteString ?? "none"))")
        stub.answer = { _ in (200, FriendsFixtures.topArtistsThisWeek) }
        let week = await result { try await client.topArtists("mr_monkey", range: .thisWeek, count: 5) }
        check(week??.first == FriendArtist(name: "Morphine", listens: 16)
              && stub.requests.last?.url?.query == "count=5&range=this_week", "this week's artists are read")

        func failure(_ status: Int, _ body: String) async -> ListenBrainzClient.Failure? {
            stub.answer = { _ in (status, body) }
            do { _ = try await client.playingNow("nobody"); return nil } catch { return error as? ListenBrainzClient.Failure }
        }
        check(await failure(404, FriendsFixtures.noSuchUser) == .noSuchUser, "404 means there is no such user")
        check(await failure(400, FriendsFixtures.badRange) == .http(400), "a refused request is told apart from a missing user")
        check(await failure(503, "") == .http(503), "a server error is its own failure")
        check(await failure(401, "") == .hidden, "an account that doesn't show its listening is its own failure")
        check(await failure(200, "<html>") == .malformed, "an answer that isn't the API's is malformed, not empty")
        stub.fails = URLError(.notConnectedToInternet)
        let offline: ListenBrainzClient.Failure?
        do { _ = try await client.listenCount("rob"); offline = nil } catch { offline = error as? ListenBrainzClient.Failure }
        check(offline == .network, "no connection is a network failure")
        stub.fails = nil
        stub.answer = { _ in (200, FriendsFixtures.listenCount) }
        check((try? await client.listenCount("rob")) == 220_287, "and the next request works again")
        stub.answer = { _ in (200, FriendsFixtures.following) }
        check((try? await client.following("rob"))?.count == 7, "followed names are read")
    }

    static func pacing() async {
        var clock = FakeClock(), stub = StubTransport(clock: clock)
        var client = ListenBrainzClient(transport: stub, clock: clock)
        stub.answer = { _ in (200, FriendsFixtures.nothingPlaying) }

        // Twelve asked for at once, as a page of friends would be.
        let fired = client
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 { group.addTask { _ = try? await fired.playingNow("friend\(index)") } }
        }
        check(stub.times == (0..<12).map(Double.init), "requests asked for together must leave one a second (\(stub.times))")
        check(stub.overlap == 1, "never two requests at a time (\(stub.overlap))")

        // The window used up: the next waits for as long as the headers say.
        stub.answer = { _ in (200, FriendsFixtures.nothingPlaying) }
        stub.headers = ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset-In": "7"]
        _ = try? await client.playingNow("a")
        stub.headers = ["X-RateLimit-Remaining": "29", "X-RateLimit-Reset-In": "10"]
        let before = stub.times.last ?? 0
        _ = try? await client.playingNow("b")
        check((stub.times.last ?? 0) - before == 7, "with nothing remaining, the next request waits out the window (\((stub.times.last ?? 0) - before) s)")
        _ = try? await client.playingNow("c")
        check(stub.times.suffix(2).last! - stub.times.suffix(2).first! == 1, "and then the pace is one a second again")

        // 429: wait as told, ask once more.
        (clock, stub) = { let clock = FakeClock(); return (clock, StubTransport(clock: clock)) }()
        client = ListenBrainzClient(transport: stub, clock: clock)
        var answers = [(429, "", ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset-In": "4"]), (200, FriendsFixtures.nothingPlaying, [:])]
        stub.scripted = { answers.removeFirst() }
        let retried = await result { try await client.playingNow("a") }
        check(retried == .some(nil) && stub.times == [0, 4], "a 429 must be waited out and asked again once (\(stub.times))")

        answers = [(429, "", ["X-RateLimit-Reset-In": "2"]), (429, "", ["X-RateLimit-Reset-In": "3"])]
        var thrown: ListenBrainzClient.Failure?
        do { _ = try await client.playingNow("a") } catch { thrown = error as? ListenBrainzClient.Failure }
        check(thrown == .rateLimited(retryIn: 3) && stub.times == [0, 4, 5, 7], "a second 429 gives up rather than ask a third time (\(stub.times), \(String(describing: thrown)))")

        // A 429 with no header at all still backs off.
        answers = [(429, "", [:]), (200, FriendsFixtures.nothingPlaying, [:])]
        _ = try? await client.playingNow("a")
        check(stub.times.suffix(2) == [10, 20], "a 429 that doesn't say how long is given ten seconds (\(stub.times))")

        // A long ban fails at once, and so does everything after it, without a request.
        answers = [(429, "", ["X-RateLimit-Reset-In": "600"])]
        thrown = nil
        let slept = clock.slept
        do { _ = try await client.playingNow("a") } catch { thrown = error as? ListenBrainzClient.Failure }
        check(thrown == .rateLimited(retryIn: 600) && clock.slept == slept + 1, "a long wait must fail the request, not hold the line (\(String(describing: thrown)), \(clock.slept - slept) s slept)")
        let sent = stub.times.count
        thrown = nil
        do { _ = try await client.listens("b", count: 5) } catch { thrown = error as? ListenBrainzClient.Failure }
        check(stub.times.count == sent && thrown == .rateLimited(retryIn: 600), "while banned nothing is sent at all (\(String(describing: thrown)))")
        clock.advance(600)
        stub.scripted = nil
        stub.answer = { _ in (200, FriendsFixtures.nothingPlaying) }
        let resumed = await result { try await client.playingNow("a") }
        check(resumed == .some(nil), "once the wait is over requests go out again")

        // A request that fails is paced like any other.
        stub.fails = URLError(.timedOut)
        _ = try? await client.playingNow("a")
        _ = try? await client.playingNow("b")
        let last = stub.times.suffix(2)
        check(last.last! - last.first! == 1, "failures keep the pace too (\(last))")
    }

    // MARK: - The list

    static func list() async {
        let world = World()
        let defaults = TestDefaults.make()
        var model = world.model(defaults)
        check(model.friends.isEmpty && model.myName.isEmpty, "the list starts empty")

        check(await model.add("nobody") == false && model.addProblem == .noSuchUser("nobody") && model.friends.isEmpty,
              "a name ListenBrainz doesn't know must be refused with a reason (\(String(describing: model.addProblem)))")
        check(defaults.stringArray(forKey: "friendsListenBrainzNames") == nil, "and not kept")

        check(await model.add("  @rob ") && model.friends.map(\.name) == ["rob"] && model.addProblem == nil, "a name is kept once ListenBrainz knows it")
        check(model.friends[0].state == .loaded && model.friends[0].recent.count == 2 && model.friends[0].listenCount == 220_287,
              "and its card is filled at once (\(model.friends[0]))")
        check(await model.add("ROB") == false && model.addProblem == .alreadyAdded("rob"), "the same name in other letters is the same friend")
        check(await model.add("https://listenbrainz.org/user/mr_monkey/stats/?range=week") && model.friends.map(\.name) == ["rob", "mr_monkey"],
              "a profile's address gives its name (\(model.friends.map(\.name)))")
        check(await model.add("   ") == false && model.addProblem == nil, "an empty name is nothing to add")
        check(defaults.stringArray(forKey: "friendsListenBrainzNames") == ["rob", "mr_monkey"], "the list is kept in the settings")

        world.offline = true
        check(await model.add("dpmittal") == false && model.addProblem == .failed(.network) && model.friends.count == 2,
              "offline, a name can't be checked and isn't added (\(String(describing: model.addProblem)))")
        world.offline = false

        model = world.model(defaults)
        check(model.friends.map(\.name) == ["rob", "mr_monkey"] && model.friends.allSatisfy { $0.state == .loading },
              "a new run has the same friends, not yet asked about")
        model.remove(model.friends[0])
        check(model.friends.map(\.name) == ["mr_monkey"] && defaults.stringArray(forKey: "friendsListenBrainzNames") == ["mr_monkey"],
              "a removed friend is gone from the settings too")

        // Whom the listener's own account follows.
        await model.setMyName("rob")
        check(model.myName == "rob" && defaults.string(forKey: "friendsMyListenBrainzName") == "rob", "the listener's own name is kept")
        check(model.suggestions == ["Zastai", "Zas", "iliekcomputers", "ishaanshah", "Damselfish", "choake", "Ruud v A"],
              "the people that account follows are offered (\(model.suggestions))")
        await model.add("zas")
        check(!model.suggestions.contains("Zas") && model.suggestions.count == 6, "someone already a friend isn't offered again")
        await model.setMyName("nobody")
        check(model.followed == nil && model.followedProblem == .noSuchUser && model.suggestions.isEmpty, "a name of one's own that doesn't exist says so")
        await model.setMyName("rob")
        model.addSuggestions()
        check(model.friends.map(\.name) == ["mr_monkey", "zas", "Zastai", "iliekcomputers", "ishaanshah", "Damselfish", "choake", "Ruud v A"]
              && model.suggestions.isEmpty && model.refreshRequests == 1, "all of them are added in one go, and a refresh asked for (\(model.friends.map(\.name)))")
        await model.setMyName("")
        check(model.myName.isEmpty && model.followed == nil && defaults.string(forKey: "friendsMyListenBrainzName") == "", "the own name can be taken back")

        // The list is bounded: each friend is two requests a pass.
        let crowded = TestDefaults.make()
        crowded.set((0..<40).map { "friend\($0)" }, forKey: "friendsListenBrainzNames")
        model = world.model(crowded)
        check(model.friends.count == FriendsModel.limit && model.isFull, "the list holds \(FriendsModel.limit) (\(model.friends.count))")
        check(await model.add("rob") == false && model.addProblem == .full, "a full list says so")
        world.following["me"] = ["a", "b", "c"]
        model.remove(model.friends[0])
        await model.setMyName("me")
        model.addSuggestions()
        check(model.friends.count == FriendsModel.limit && model.friends.last?.name == "a", "suggestions fill the room there is and no more")
    }

    static func refreshing() async {
        let world = World()
        let defaults = TestDefaults.make()
        defaults.set(["rob", "listener", "dpmittal", "gone", "quiet"], forKey: "friendsListenBrainzNames")
        let model = world.model(defaults)
        world.users["quiet"] = World.User(listens: World.noListens)

        await model.refresh()
        let paths = world.stub.requests.compactMap { $0.url?.path.replacingOccurrences(of: "/1/", with: "") }
        check(Array(paths.prefix(9)) == ["user/rob/playing-now", "user/rob/listens", "user/listener/playing-now", "user/listener/listens",
                                         "user/dpmittal/playing-now", "user/dpmittal/listens", "user/gone/playing-now",
                                         "user/quiet/playing-now", "user/quiet/listens"],
              "a pass asks what every friend plays first, and a missing account costs one request (\(paths.prefix(9)))")
        check(Array(paths.dropFirst(9)) == ["stats/user/rob/artists", "stats/user/rob/artists", "user/rob/listen-count",
                                            "stats/user/listener/artists", "user/listener/listen-count",
                                            "stats/user/dpmittal/artists", "stats/user/dpmittal/artists", "user/dpmittal/listen-count",
                                            "stats/user/quiet/artists", "stats/user/quiet/artists", "user/quiet/listen-count"],
              "then the weekly numbers, last week's where this week has none (\(paths.dropFirst(9)))")
        check(world.stub.times == (0..<world.stub.times.count).map(Double.init) && world.stub.overlap == 1,
              "the whole pass is one stream at one request a second (\(world.stub.times))")
        check(world.stub.requests.allSatisfy { $0.url?.host == "api.listenbrainz.org" }, "and goes nowhere but ListenBrainz")

        let byName = Dictionary(uniqueKeysWithValues: model.friends.map { ($0.name, $0) })
        check(byName["listener"]?.playing?.title == "There There" && byName["listener"]?.isListening(asOf: model.asOf) == true,
              "someone playing a song is listening now")
        check(byName["listener"]?.topArtists.first?.name == "Morphine" && byName["listener"]?.topRange == .thisWeek, "with this week's artists")
        check(byName["rob"]?.state == .loaded && byName["rob"]?.playing == nil && byName["rob"]?.headline?.title == "Some Resolve"
              && byName["rob"]?.earlier.map(\.title) == ["Tell Him"], "someone not playing leads with their last song (\(String(describing: byName["rob"]?.headline)))")
        check(byName["rob"]?.topArtists.isEmpty == true && byName["rob"]?.topRange == nil && byName["rob"]?.listenCount == 220_287,
              "statistics ListenBrainz hasn't worked out are simply absent")
        check(byName["dpmittal"]?.topRange == .lastWeek && byName["dpmittal"]?.topArtists.count == 5, "last week's artists stand in for an empty week")
        check(byName["gone"]?.state == .failed(.noSuchUser) && byName["gone"]?.headline == nil, "an account that is gone says so on its own card")
        check(byName["quiet"]?.state == .loaded && byName["quiet"]?.headline == nil && byName["quiet"]?.lastActive == nil,
              "an account with no listens is loaded and empty, not failed")
        check(model.problem == nil && !model.isRefreshing, "a pass that reached ListenBrainz leaves no page-wide problem")

        // Listening now, then by how recently, then the ones nothing is known of, by name.
        check(model.ordered.map(\.name) == ["listener", "rob", "dpmittal", "gone", "quiet"], "the order of the page (\(model.ordered.map(\.name)))")
        world.users["rob"]?.playing = FriendsFixtures.playingNow
        world.users["listener"]?.playing = FriendsFixtures.nothingPlaying
        world.users["listener"]?.listens = FriendsFixtures.listensUnmapped
        world.stub.reset()
        world.now.advance(60)
        await model.refresh()
        check(model.ordered.map(\.name) == ["rob", "listener", "dpmittal", "gone", "quiet"],
              "the order follows what changed (\(model.ordered.map(\.name)))")
        check(world.stub.requests.count == 9, "the weekly numbers aren't asked for again within their three hours (\(world.stub.requests.count) requests)")
        let robNow = model.friends.first { $0.name == "rob" }
        check(robNow?.headline?.title == "There There" && robNow?.earlier.map(\.title) == ["Some Resolve", "Tell Him"],
              "the playing song leads and the listens follow")
        // A player that reports the song as listened while it still plays.
        var twice = Friend(name: "x", playing: FriendListen(title: "Some Resolve", artist: "Röyksopp"), recent: robNow?.recent ?? [])
        check(twice.earlier.map(\.title) == ["Tell Him"], "the playing song isn't listed again under itself")
        twice.playing = nil
        check(twice.earlier.map(\.title) == ["Tell Him"] && twice.headline?.title == "Some Resolve", "and leads on its own once it stops")

        // Offline: one failed request ends the pass, what was shown stays, and nobody is "listening now" for ever.
        world.offline = true
        world.stub.reset()
        world.now.advance(60)
        await model.refresh()
        check(world.stub.requests.count == 1 && model.problem == .network, "offline, a pass stops at its first request (\(world.stub.requests.count))")
        check(model.friends.first { $0.name == "rob" }?.playing != nil && model.friends.first { $0.name == "dpmittal" }?.state == .loaded,
              "and keeps what it showed")
        check(model.ordered.first?.name == "rob", "a song heard playing a minute ago still counts as now")
        world.stub.reset()
        world.now.advance(600)
        await model.refresh()
        check(model.friends.first { $0.name == "rob" }?.isListening(asOf: model.asOf) == false && model.ordered.map(\.name).prefix(2) == ["rob", "listener"],
              "eleven minutes without an answer it no longer does, though rob was still the last heard (\(model.ordered.map(\.name)))")

        // A friend added while offline never loaded: the card says why.
        let fresh = TestDefaults.make()
        fresh.set(["rob"], forKey: "friendsListenBrainzNames")
        let unreached = world.model(fresh)
        await unreached.refresh()
        check(unreached.friends[0].state == .failed(.network) && unreached.problem == .network, "a friend never reached shows the network problem")
        world.offline = false
        world.now.advance(60)
        await unreached.refresh()
        check(unreached.friends[0].state == .loaded && unreached.problem == nil, "and loads once the network is back")

        // ListenBrainz asking to slow down for minutes is a page-wide state, not a failure per friend.
        world.stub.reset()
        world.stub.scripted = { (429, "", ["X-RateLimit-Reset-In": "900"]) }
        world.now.advance(60)
        await unreached.refresh()
        check(unreached.problem == .busy && unreached.friends[0].state == .loaded && world.stub.requests.count == 1,
              "a long rate limit stops the pass and keeps the cards (\(String(describing: unreached.problem)))")
        world.stub.scripted = nil

        // A server error is the one friend's.
        world.clock.advance(900)
        world.users["rob"]?.status = 503
        world.now.advance(60)
        await unreached.refresh()
        check(unreached.friends[0].state == .failed(.service(503)) && unreached.friends[0].recent.count == 2 && unreached.problem == nil,
              "a server error marks the friend and keeps their songs (\(unreached.friends[0].state))")

        // Three hours on, the weekly numbers are asked for again.
        world.users["rob"]?.status = 200
        world.stub.reset()
        world.now.advance(3 * 3600)
        await unreached.refresh()
        check(world.stub.requests.count == 5, "after three hours the weekly numbers are asked for again (\(world.stub.requests.count) requests)")
    }

    /// The loop the page runs: a pass at once, another every interval, none
    /// once the page lets go, and none on coming straight back.
    static func keepingFresh() async {
        let world = World()
        let defaults = TestDefaults.make()
        defaults.set(["rob"], forKey: "friendsListenBrainzNames")
        let model = world.model(defaults)
        FriendsModel.interval = 0.4
        FriendsModel.statsLife = 3600
        defer { FriendsModel.interval = 60 }
        func passes() -> Int { world.stub.requests.filter { $0.url?.path.hasSuffix("/playing-now") == true }.count }
        // The page's clock is real here; the model's dates follow it.
        world.now.followsSystem = true

        var page = Task { await model.keepFresh() }
        try? await Task.sleep(for: .milliseconds(200))
        check(passes() == 1, "opening the page passes at once (\(passes()))")
        try? await Task.sleep(for: .milliseconds(1000))
        let whileOpen = passes()
        check((3...4).contains(whileOpen), "and again every interval while it shows (\(whileOpen) passes in 1.2 s at 0.4 s)")
        page.cancel()
        await page.value
        try? await Task.sleep(for: .milliseconds(900))
        check(passes() == whileOpen, "with the page away nothing is asked (\(passes() - whileOpen) more)")

        // Back within moments of the last pass: it isn't repeated.
        FriendsModel.interval = 2
        page = Task { await model.keepFresh() }
        try? await Task.sleep(for: .milliseconds(100))
        let back = passes()
        check(back == whileOpen + 1, "coming back later passes at once (\(back - whileOpen))")
        page.cancel()
        await page.value
        page = Task { await model.keepFresh() }
        try? await Task.sleep(for: .milliseconds(100))
        check(passes() == back, "coming straight back doesn't ask again (\(passes() - back) more)")
        // A refresh by hand does, at once.
        page.cancel()
        await page.value
        model.requestRefresh()
        page = Task { await model.keepFresh() }
        try? await Task.sleep(for: .milliseconds(100))
        check(passes() == back + 1, "a refresh by hand passes at once (\(passes() - back))")
        page.cancel()
        await page.value

        // Leaving mid-pass: the pass ends there and isn't counted as one.
        world.stub.reset()
        world.stub.delay = .milliseconds(300)
        model.requestRefresh()
        page = Task { await model.keepFresh() }
        try? await Task.sleep(for: .milliseconds(100))
        page.cancel()
        await page.value
        check(world.stub.requests.count == 1 && !model.isRefreshing && model.problem == nil,
              "a pass cut short stops after the request in flight, with no error shown (\(world.stub.requests.count) requests)")
    }

    /// The value, or nil if it threw: unlike `try?`, an answer that is itself nil stays an answer.
    static func result<T: Sendable>(_ work: () async throws -> T) async -> T? {
        do { return try await work() } catch { return nil }
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition {
            print("FAIL: \(message())")
            exit(1)
        }
    }
}

// MARK: - Stand-ins

/// Time the test moves: sleeping returns at once and moves it on.
final class FakeClock: PacingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var total: TimeInterval = 0

    var now: TimeInterval { lock.withLock { time } }
    /// Seconds slept in all.
    var slept: TimeInterval { lock.withLock { total } }

    func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { time += seconds; total += seconds }
    }

    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

/// The date the model reads.
final class FakeNow: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_795_766_000)
    var followsSystem = false

    var value: Date { lock.withLock { followsSystem ? Date() : date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

/// Answers in place of the network, and notes when each request left.
final class StubTransport: ListenBrainzTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: FakeClock
    private var sent: [(URLRequest, TimeInterval)] = []
    private var inFlight = 0
    private var most = 0
    /// Status and body for a request.
    var answer: (URLRequest) -> (Int, String) = { _ in (200, "") }
    /// Status, body and headers, taking the place of `answer` while set.
    var scripted: (() -> (Int, String, [String: String]))?
    var headers = FriendsFixtures.headers
    var fails: URLError?
    var delay: Duration?

    init(clock: FakeClock) { self.clock = clock }

    var requests: [URLRequest] { lock.withLock { sent.map(\.0) } }
    /// When each request left, on the fake clock.
    var times: [TimeInterval] { lock.withLock { sent.map(\.1) } }
    /// The most requests ever in flight together.
    var overlap: Int { lock.withLock { most } }
    func reset() { lock.withLock { sent = []; most = 0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            sent.append((request, clock.now))
            inFlight += 1
            most = max(most, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        // Let anything else that is ready run, so overlapping requests would show.
        await Task.yield()
        if let delay { try await Task.sleep(for: delay) }
        if let fails { throw fails }
        let (status, body, headers) = scripted.map { $0() } ?? { let (status, body) = answer(request); return (status, body, self.headers) }()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: headers)!)
    }
}

/// A small ListenBrainz: a few accounts answering from the captured fixtures.
@MainActor
final class World {
    struct User {
        var playing = FriendsFixtures.nothingPlaying
        var listens = FriendsFixtures.listensMapped
        var thisWeek: String?
        var lastWeek: String?
        var count = FriendsFixtures.listenCount
        var status = 200
    }

    static let noListens = #"{"payload":{"count":0,"latest_listen_ts":0,"listens":[],"oldest_listen_ts":0,"user_id":"quiet"}}"#

    let clock = FakeClock()
    let now = FakeNow()
    let stub: StubTransport
    nonisolated(unsafe) var users: [String: User] = [
        "rob": User(),
        "listener": User(playing: FriendsFixtures.playingNow, listens: FriendsFixtures.listensUnmapped, thisWeek: FriendsFixtures.topArtistsThisWeek),
        "dpmittal": User(listens: FriendsFixtures.listensFromSpotify, lastWeek: FriendsFixtures.topArtistsLastWeek),
        "mr_monkey": User(listens: FriendsFixtures.listensUnmapped, lastWeek: FriendsFixtures.topArtistsLastWeek),
        "zas": User(),
    ]
    nonisolated(unsafe) var following: [String: [String]] = ["rob": ["Zastai", "Zas", "iliekcomputers", "ishaanshah", "Damselfish", "choake", "Ruud v A"]]
    var offline = false { didSet { stub.fails = offline ? URLError(.notConnectedToInternet) : nil } }

    init() {
        stub = StubTransport(clock: clock)
        stub.answer = { [unowned self] request in self.answer(request) }
    }

    func model(_ defaults: UserDefaults) -> FriendsModel {
        FriendsModel(defaults: defaults, client: ListenBrainzClient(transport: stub, clock: clock), now: { [now] in now.value })
    }

    private nonisolated func answer(_ request: URLRequest) -> (Int, String) {
        let parts = (request.url?.path ?? "").split(separator: "/").map(String.init) // 1, user|stats, …
        let stats = parts.dropFirst().first == "stats"
        let name = (stats ? parts.dropFirst(3).first : parts.dropFirst(2).first) ?? ""
        let key = name.lowercased()
        if parts.last == "following" {
            guard let names = following[key], let data = try? JSONSerialization.data(withJSONObject: ["following": names, "user": name]) else {
                return (404, FriendsFixtures.noSuchUser)
            }
            return (200, String(decoding: data, as: UTF8.self))
        }
        // Names nobody made up an account for answer like one that listens to nothing in particular.
        guard key != "nobody", key != "gone" else { return (404, FriendsFixtures.noSuchUser) }
        let user = users[key] ?? User()
        guard user.status == 200 else { return (user.status, "") }
        switch parts.last {
        case "playing-now": return (200, user.playing)
        case "listens": return (200, user.listens)
        case "listen-count": return (200, user.count)
        case "artists":
            let range = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "range" }?.value
            return (range == "this_week" ? user.thisWeek : user.lastWeek).map { (200, $0) } ?? (204, "")
        default: return (400, FriendsFixtures.badRange)
        }
    }
}
