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

private actor MockPlayback: PlaybackAPI {
    var permission = true
    var delay = false
    var failure = false
    private(set) var reads = 0
    private(set) var transferred: String?
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
        [ConnectDevice(id: "floe", name: "Floe", type: "computer", isActive: true, isRestricted: false, volumePercent: 70, supportsVolume: true),
         ConnectDevice(id: "blocked", name: "Restricted", type: "speaker", isActive: false, isRestricted: true, volumePercent: nil, supportsVolume: false),
         ConnectDevice(id: nil, name: "Unknown", type: "speaker", isActive: false, isRestricted: false, volumePercent: nil, supportsVolume: false)]
    }
    func transfer(to id: String) { transferred = id }
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
        let deniedAPI = MockPlayback(); await deniedAPI.setPermission(false)
        let denied = ConnectModel(api: deniedAPI)
        await denied.refresh(queue: true)
        let deniedReads = await deniedAPI.reads
        precondition(denied.needsPermission && deniedReads == 0)
        await denied.connect(queue: true)
        precondition(!denied.needsPermission && !denied.isLoading)

        let mock = MockPlayback(), model = ConnectModel(api: MockPlayback())
        await model.refresh(queue: false)
        precondition(model.devices.count == 2)
        let transferModel = ConnectModel(api: mock)
        await transferModel.refresh(queue: false)
        await transferModel.transfer(transferModel.devices[1])
        var transferred = await mock.transferred
        precondition(transferred == nil, "restricted devices must not receive commands")
        await transferModel.transfer(transferModel.devices[0])
        transferred = await mock.transferred
        precondition(transferred == "floe" && !transferModel.transferring)
        await mock.setFailure(); await transferModel.refresh(queue: true)
        precondition(transferModel.error?.contains("expired") == true && !transferModel.isLoading)

        let slow = MockPlayback(); await slow.setDelay()
        let raced = ConnectModel(api: slow)
        let old = Task { await raced.refresh(queue: true) }
        try await Task.sleep(for: .milliseconds(10))
        await raced.refresh(queue: false)
        await old.value
        precondition(raced.devices.count == 2 && raced.queue.isEmpty && !raced.isLoading && raced.error == nil)
        let cancelled = Task { await raced.refresh(queue: true) }
        try await Task.sleep(for: .milliseconds(10)); cancelled.cancel(); await cancelled.value
        precondition(raced.error == nil && !raced.isLoading)
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
