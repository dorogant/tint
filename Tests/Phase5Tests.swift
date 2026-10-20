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
    func playbackDevices() -> [ConnectDevice] {
        [ConnectDevice(id: "tint", name: "Tint", type: "computer", isActive: true, isRestricted: false, volumePercent: 70, supportsVolume: true),
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
        precondition(albums.count == 100 && pages.offsets == [0, 50], "stops at the cap, got \(pages.offsets)")
        PagingStub.reset(total: 30)
        let short = try await paged.myPlaylists()
        precondition(short.count == 30 && PagingStub.snapshot.offsets == [0], "one page")
        print("PASS: paged lists load their remaining pages together, in order, up to a cap "
              + "(7 pages of 50 ms in \(elapsed.formatted(.units(allowed: [.milliseconds]))))")

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
