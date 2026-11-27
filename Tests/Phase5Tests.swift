import Foundation

private actor TestTokens: TokenProvider {
    private(set) var invalidations = 0
    func accessToken() -> String { "synthetic-test-token" }
    func invalidate() { invalidations += 1 }
}

private final class StubHTTP: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var statuses = [Int]()
    nonisolated(unsafe) static var requests = [URLRequest]()
    static func reset(_ statuses: [Int]) {
        lock.lock(); defer { lock.unlock() }
        self.statuses = statuses; requests = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            var data = Data(), bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&bytes, maxLength: bytes.count)
                if n <= 0 { break }
                data.append(contentsOf: bytes.prefix(n))
            }
            stream.close()
            captured.httpBody = data
        }
        Self.lock.lock()
        Self.requests.append(captured)
        let status = Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: status == 429 ? ["Retry-After": "120"] : [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

/// A paged list of `total` playlists or saved albums, each page answered after
/// a delay, counting how many requests overlap.
private final class PagingStub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var total = 0
    nonisolated(unsafe) static var offsets = [Int]()
    nonisolated(unsafe) static var inFlight = 0
    nonisolated(unsafe) static var mostInFlight = 0
    static func reset(total: Int) {
        lock.withLock { self.total = total; offsets = []; inFlight = 0; mostInFlight = 0 }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value.flatMap(Int.init) }
        let offset = value("offset") ?? 0, limit = value("limit") ?? 20
        let total = Self.lock.withLock {
            Self.offsets.append(offset)
            Self.inFlight += 1
            Self.mostInFlight = max(Self.mostInFlight, Self.inFlight)
            return Self.total
        }
        let albums = url.path.hasSuffix("me/albums")
        let items: [[String: Any]] = (offset..<min(offset + limit, total)).map { index in
            let ref: [String: Any] = ["id": "\(index)", "uri": "spotify:x:\(index)", "name": "\(index)", "owner": ["id": "u"]]
            return albums ? ["album": ref] : ref
        }
        let next: Any = offset + limit < total ? "https://api.spotify.com/v1\(url.path)?offset=\(offset + limit)&limit=\(limit)" : NSNull()
        let body = try! JSONSerialization.data(withJSONObject: ["items": items, "total": total, "offset": offset, "next": next])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            Self.lock.withLock { Self.inFlight -= 1 }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
    static var snapshot: (offsets: [Int], mostInFlight: Int) { lock.withLock { (offsets.sorted(), mostInFlight) } }
}

private actor MockPlayback: PlaybackAPI {
    var permission = true
    var delay = false
    var failure = false
    private(set) var reads = 0
    private(set) var transferred: String?
    private var holdTransfer = false
    private var pendingTransfer: CheckedContinuation<Void, Error>?
    private var transferStarted: CheckedContinuation<Void, Never>?
    var hasPlaybackPermission: Bool { permission }
    func authorizePlaybackControls() { permission = true }
    func setPermission(_ value: Bool) { permission = value }
    func setDelay() { delay = true }
    func setFailure() { failure = true }
    func playbackQueue() async throws -> PlaybackQueue {
        reads += 1
        if delay { try await Task.sleep(for: .milliseconds(120)) }
        if failure { throw TokenError.notAuthorized }
        let payload = "{\"currentlyPlaying\":null,\"queue\":[{\"id\":\"test\",\"uri\":\"spotify:track:test\",\"name\":\"Synthetic\",\"durationMs\":1000,\"artists\":[]}]}"
        return try JSONDecoder().decode(PlaybackQueue.self, from: Data(payload.utf8))
    }
    private(set) var deviceReads = 0
    private(set) var started = [(playback: PlaybackStart, device: String)]()
    private var startStatuses = [Int]()
    private var tintID = "tint"
    func failStarts(_ statuses: [Int]) { startStatuses = statuses }
    func renameDevice(_ id: String) { tintID = id }
    func startPlayback(_ playback: PlaybackStart, on deviceID: String) throws {
        started.append((playback, deviceID))
        if !startStatuses.isEmpty {
            throw WebAPI.Failure.http(status: startStatuses.removeFirst(), message: "synthetic")
        }
    }
    func playbackDevices() -> [ConnectDevice] {
        deviceReads += 1
        return [ConnectDevice(id: tintID, name: "Tint", type: "computer", isActive: true, isRestricted: false, volumePercent: 70, supportsVolume: true),
         ConnectDevice(id: "blocked", name: "Restricted", type: "speaker", isActive: false, isRestricted: true, volumePercent: nil, supportsVolume: false),
         ConnectDevice(id: nil, name: "Unknown", type: "speaker", isActive: false, isRestricted: false, volumePercent: nil, supportsVolume: false)]
    }
    func holdTransfers() { holdTransfer = true }
    func waitForTransfer() async {
        if pendingTransfer != nil { return }
        await withCheckedContinuation { transferStarted = $0 }
    }
    func failTransfer() {
        pendingTransfer?.resume(throwing: TokenError.notAuthorized)
        pendingTransfer = nil
    }
    func transfer(to id: String) async throws {
        transferred = id
        if holdTransfer {
            try await withCheckedThrowingContinuation {
                pendingTransfer = $0
                transferStarted?.resume()
                transferStarted = nil
            }
        }
    }
}

@main
struct Phase5Tests {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHTTP.self]
        let tokens = TestTokens()
        let api = WebAPI(user: UserTokenProvider(), tokens: tokens, http: URLSession(configuration: config))
        StubHTTP.reset([401, 200])
        _ = try await api.send("GET", "me/player/queue")
        let invalidations = await tokens.invalidations
        precondition(invalidations == 1 && StubHTTP.captured().count == 2)
        print("PASS: HTTP 401 refresh")
        StubHTTP.reset([401, 401])
        do { _ = try await api.send("GET", "me"); preconditionFailure("repeated 401 must require reconnect") }
        catch TokenError.notAuthorized {}
        print("PASS: repeated HTTP 401")
        StubHTTP.reset([429])
        do { _ = try await api.send("GET", "me"); preconditionFailure("long Retry-After must not be ignored") }
        catch WebAPI.Failure.rateLimited(let seconds) { precondition(seconds == 120) }
        print("PASS: Retry-After")
        StubHTTP.reset([204])
        try await api.transfer(to: "synthetic-device")
        let sent = StubHTTP.captured().first!
        let body = try JSONSerialization.jsonObject(with: sent.httpBody!) as! [String: Any]
        precondition(sent.httpMethod == "PUT" && sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        precondition(body["device_ids"] as? [String] == ["synthetic-device"] && body["play"] as? Bool == false)

        print("PASS: device transfer body")
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let song = "{\"id\":\"test\",\"uri\":\"spotify:track:test\",\"name\":\"Synthetic\",\"duration_ms\":1000,\"artists\":[]}"
        let payload = "{\"currently_playing\":{\"type\":\"episode\"},\"queue\":[null,\(song),{\"type\":\"episode\"},\(song)]}"
        let queue = try decoder.decode(PlaybackQueue.self, from: Data(payload.utf8))
        precondition(queue.currentlyPlaying == nil && queue.queue.count == 2, "skip unsupported entries, retain duplicates")

        print("PASS: mixed queue decoding")
        let selected = try decoder.decode(Track.self, from: Data("""
        {"id":"selected","uri":"spotify:track:selected","name":"Synthetic selection",
         "duration_ms":120000,"explicit":true,"artists":[{"name":"Synthetic artist","uri":"spotify:artist:test"}],
         "album":{"id":"album","uri":"spotify:album:test","name":"Synthetic album",
                  "images":[{"url":"https://example.test/small","width":64},
                            {"url":"https://example.test/cover","width":640}]}}
        """.utf8))
        let immediate = TrackInfo(selected)
        precondition(immediate.uri == selected.uri && immediate.name == selected.name
                     && immediate.artistLine == "Synthetic artist" && immediate.album == "Synthetic album"
                     && immediate.durationMs == 120000 && immediate.explicit
                     && immediate.coverURL?.absoluteString == "https://example.test/cover")
        print("PASS: selected-track metadata")

        let pagingConfig = URLSessionConfiguration.ephemeral
        pagingConfig.protocolClasses = [PagingStub.self]
        let paged = WebAPI(user: UserTokenProvider(), tokens: tokens, http: URLSession(configuration: pagingConfig))
        PagingStub.reset(total: 333)
        let started = ContinuousClock.now
        let playlists = try await paged.myPlaylists()
        let elapsed = ContinuousClock.now - started
        var pages = PagingStub.snapshot
        precondition(playlists.map(\.id) == (0..<333).map { "\($0)" }, "every playlist, in order")
        precondition(pages.offsets == [0, 50, 100, 150, 200, 250, 300], "each page once, got \(pages.offsets)")
        precondition((2...4).contains(pages.mostInFlight), "later pages overlap, a few at a time; got \(pages.mostInFlight)")
        PagingStub.reset(total: 333)
        let albums = try await paged.savedAlbums()
        pages = PagingStub.snapshot
        precondition(albums.map(\.id) == (0..<333).map { "\($0)" } && pages.offsets == [0, 50, 100, 150, 200, 250, 300],
                     "every saved album, not the first hundred; got \(albums.count)")
        PagingStub.reset(total: 333)
        let releases = try await paged.artistAlbums("synthetic")
        pages = PagingStub.snapshot
        precondition(releases.count == 30 && pages.offsets == [0, 10, 20], "stops at the cap, got \(pages.offsets)")
        PagingStub.reset(total: 30)
        let short = try await paged.myPlaylists()
        precondition(short.count == 30 && PagingStub.snapshot.offsets == [0], "one page")
        print("PASS: paged lists load their remaining pages together, in order, up to a cap "
              + "(7 pages of 50 ms in \(elapsed.formatted(.units(allowed: [.milliseconds]))))")

        // An artist's Popular list: what search is asked, and how its pages add up.
        let kanye = Artist(id: "a1", uri: "spotify:artist:a1", name: "Ye \"Kanye\" West", images: nil, genres: nil)
        StubHTTP.reset([])
        _ = try await api.songs(by: kanye, offset: 20)
        let asked = URLComponents(url: StubHTTP.captured()[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let item = { (name: String) in asked.first { $0.name == name }?.value }
        precondition(item("q") == "artist:\"Ye  Kanye  West\"" && item("type") == "track"
                     && item("limit") == "10" && item("offset") == "20", "search query, got \(asked)")
        func popularSong(_ id: Int, _ name: String) -> Track {
            Track(id: "\(id)", uri: "spotify:track:\(id)", name: name, durationMs: 1, explicit: nil,
                  artists: [ArtistRef(id: "a1", uri: nil, name: "x")], album: nil, trackNumber: nil,
                  discNumber: nil, isLocal: nil, isPlayable: nil)
        }
        var popular = PopularSongs()
        popular.add([popularSong(1, "Runaway"), popularSong(2, "Stronger"), popularSong(3, "RUNAWAY")], pages: 2)
        precondition(popular.tracks.map(\.id) == ["1", "2"] && popular.nextOffset == 20 && popular.hasMore,
                     "a name counts once; the offset moves by the pages asked")
        popular.add([popularSong(4, "Stronger")], pages: 2)
        precondition(popular.tracks.count == 2 && popular.nextOffset == 40 && !popular.hasMore, "nothing new ends the list")
        var full = PopularSongs()
        full.add((0..<80).map { popularSong($0, "Song \($0)") }, pages: 2)
        precondition(full.tracks.count == PopularSongs.most && !full.hasMore, "stops at the cap")
        print("PASS: an artist's Popular list: search query, one entry per song name, end and cap")

        // What the Web API is asked to start, for the requests Spotify Soloist can't express.
        let list = (0..<500).map { "spotify:track:\($0)" }
        let fromSong = PlaybackStart(contextURI: "spotify:playlist:p", tracks: list, startURI: "spotify:track:7", startIndex: nil)
        precondition(fromSong?.contextURI == "spotify:playlist:p" && fromSong?.offset?.uri == "spotify:track:7"
                     && fromSong?.uris == nil, "a playlist starts at the chosen song as a context")
        let liked = PlaybackStart(contextURI: "spotify:user:u:collection", tracks: list, startURI: "spotify:track:120", startIndex: nil)
        precondition(liked?.contextURI == nil && liked?.uris?.count == PlaybackStart.listLimit
                     && liked?.uris?.first == "spotify:track:70" && liked?.offset?.position == 50,
                     "Liked Songs takes no offset: the songs around the chosen one play as a list")
        let nearEnd = PlaybackStart(contextURI: nil, tracks: list, startURI: "spotify:track:499", startIndex: nil)
        precondition(nearEnd?.uris?.last == "spotify:track:499" && nearEnd?.uris?.count == PlaybackStart.listLimit
                     && nearEnd?.offset?.position == PlaybackStart.listLimit - 1, "the window stays full at the end")
        let twice = ["spotify:track:a", "spotify:track:b", "spotify:track:a"]
        precondition(PlaybackStart(contextURI: nil, tracks: twice, startURI: "spotify:track:a", startIndex: 2)?.offset?.position == 2,
                     "the second copy of a song starts where it was chosen")
        precondition(PlaybackStart(contextURI: nil, tracks: twice, startURI: nil, startIndex: nil, positionMs: 9000)
                        == PlaybackStart(contextURI: nil, tracks: twice, startURI: nil, startIndex: 0, positionMs: 9000))
        precondition(PlaybackStart(contextURI: "spotify:album:a", tracks: nil, startURI: nil, startIndex: nil) == nil
                     && PlaybackStart(contextURI: "spotify:user:u:collection", tracks: list, startURI: nil, startIndex: nil) == nil
                     && PlaybackStart(contextURI: "spotify:artist:a", tracks: nil, startURI: "spotify:track:1", startIndex: nil) == nil
                     && PlaybackStart(contextURI: nil, tracks: ["spotify:track:1"], startURI: "spotify:track:1", startIndex: nil) == nil
                     && PlaybackStart(contextURI: nil, tracks: list, startURI: "spotify:track:gone", startIndex: nil) == nil,
                     "one URI, or a song that isn't in the list, is left to the engine")
        StubHTTP.reset([204])
        try await api.startPlayback(PlaybackStart(contextURI: "spotify:album:a", tracks: nil, startURI: "spotify:track:3",
                                                  startIndex: nil, positionMs: 12000)!, on: "synthetic device")
        let start = StubHTTP.captured().first!
        let startBody = try JSONSerialization.jsonObject(with: start.httpBody!) as! [String: Any]
        precondition(start.httpMethod == "PUT" && start.url!.path.hasSuffix("/v1/me/player/play")
                     && start.url!.query == "device_id=synthetic%20device")
        precondition(startBody["context_uri"] as? String == "spotify:album:a" && startBody["position_ms"] as? Int == 12000
                     && (startBody["offset"] as? [String: Any])?["uri"] as? String == "spotify:track:3"
                     && startBody["uris"] == nil && (startBody["offset"] as? [String: Any])?.count == 1)
        print("PASS: Web API playback start: context at a song, windowed lists, request body")

        let remote = MockPlayback(), starter = PlaybackStarter(api: remote)
        await remote.setPermission(false)
        do { try await starter.start(fromSong!, onDeviceNamed: "Tint"); preconditionFailure("needs playback permission") }
        catch PlaybackStarter.Failure.notPermitted {}
        var remoteReads = await remote.deviceReads
        precondition(remoteReads == 0, "nothing is asked without permission")
        await remote.setPermission(true)
        try await starter.start(fromSong!, onDeviceNamed: "Tint")
        try await starter.start(liked!, onDeviceNamed: "Tint")
        remoteReads = await remote.deviceReads
        var starts = await remote.started
        precondition(starts.map(\.device) == ["tint", "tint"] && starts[1].playback == liked && remoteReads == 1,
                     "the device is looked up by name once")
        await remote.renameDevice("tint-2"); await remote.failStarts([404])
        try await starter.start(fromSong!, onDeviceNamed: "Tint")
        starts = await remote.started; remoteReads = await remote.deviceReads
        precondition(starts.suffix(2).map(\.device) == ["tint", "tint-2"] && remoteReads == 2,
                     "an ID Spotify no longer knows is looked up again")
        await remote.failStarts([403])
        do { try await starter.start(fromSong!, onDeviceNamed: "Tint"); preconditionFailure("a refusal is the caller's to handle") }
        catch let failure as WebAPI.Failure { precondition(failure.status == 403) }
        do { try await starter.start(fromSong!, onDeviceNamed: "Restricted"); preconditionFailure("restricted devices take no commands") }
        catch PlaybackStarter.Failure.deviceNotFound {}
        print("PASS: playback starts on the named device: permission, cached ID, stale ID, refusal")

        let deniedAPI = MockPlayback(); await deniedAPI.setPermission(false)
        let denied = ConnectModel(api: deniedAPI)
        await denied.refresh(.queue)
        let deniedReads = await deniedAPI.reads
        precondition(denied.needsPermission && deniedReads == 0)
        await denied.connect(.queue)
        precondition(!denied.needsPermission && !denied.isLoading)

        let mock = MockPlayback(), model = ConnectModel(api: MockPlayback())
        await model.refresh(.devices)
        precondition(model.devices.count == 2)
        let transferModel = ConnectModel(api: mock)
        await transferModel.refresh(.devices)
        await transferModel.transfer(transferModel.devices[1])
        var transferred = await mock.transferred
        precondition(transferred == nil, "restricted devices must not receive commands")
        await transferModel.transfer(transferModel.devices[0])
        transferred = await mock.transferred
        precondition(transferred == "tint" && !transferModel.transferring)
        await mock.setFailure(); await transferModel.refresh(.queue)
        precondition(transferModel.error?.contains("expired") == true && !transferModel.isLoading)

        let slow = MockPlayback(); await slow.setDelay()
        let raced = ConnectModel(api: slow)
        let old = Task { await raced.refresh(.queue) }
        try await Task.sleep(for: .milliseconds(10))
        await raced.refresh(.devices)
        await old.value
        precondition(raced.devices.count == 2 && raced.queue.isEmpty && !raced.isLoading && raced.error == nil)
        let cancelled = Task { await raced.refresh(.queue) }
        try await Task.sleep(for: .milliseconds(10)); cancelled.cancel(); await cancelled.value
        precondition(raced.error == nil && !raced.isLoading)

        // A transfer can finish after the user has opened a different panel.
        let slowTransfer = MockPlayback()
        await slowTransfer.holdTransfers()
        let switching = ConnectModel(api: slowTransfer)
        await switching.refresh(.devices)
        let device = switching.devices[0]
        let oldTransfer = Task { await switching.transfer(device) }
        await slowTransfer.waitForTransfer()
        await switching.refresh(.queue)
        await slowTransfer.failTransfer()
        await oldTransfer.value
        precondition(switching.error == nil && switching.queue.count == 1 && !switching.transferring,
                     "old transfer errors must not replace the current panel")
        let cancelledTransfer = Task { await switching.transfer(device) }
        await slowTransfer.waitForTransfer()
        cancelledTransfer.cancel()
        await slowTransfer.failTransfer()
        await cancelledTransfer.value
        precondition(switching.error == nil && !switching.transferring,
                     "cancelled transfers must not publish errors")
        print("PASS: stale and cancelled device transfers")
        let root = CommandLine.arguments[1]
        let ukrainian = Bundle(path: root + "/Support/Localizations/uk.lproj")!
        for (count, expected) in [(1, "1 пісня"), (2, "2 пісні"), (5, "5 пісень"), (21, "21 пісня")] {
            let rendered = String(localized: "\(count) songs", bundle: ukrainian, locale: Locale(identifier: "uk"))
            precondition(rendered == expected, "Ukrainian plural: \(rendered)")
        }
        let settingsTitle = String(localized: "Settings", bundle: ukrainian, locale: Locale(identifier: "uk"))
        precondition(settingsTitle == "Налаштування")
        print("PASS: Ukrainian resources and plural forms")
        print("PASS: token refresh/repeated 401, Retry-After, transfer JSON, mixed queue decoding, permission gating, restricted devices, recovery, stale/cancelled requests")
    }
}
