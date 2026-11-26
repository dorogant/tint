import CoreGraphics
import Foundation

@main
final class Phase3Tests {
    static func main() async throws {
        let tests = Phase3Tests()
        tests.testRepeatedTagsAndLateOffset()
        tests.testBlankLinesAndInvalidTimestamps()
        tests.testNegativeOffsetAndClamping()
        tests.testStableDuplicateTimestampsAndSeeking()
        try tests.testResponseUsesSyncedAndIgnoresNewFields()
        try tests.testResponseFallbackAndInstrumental()
        tests.testRequestPreservesVersionMetadataAndDuration()
        tests.testGreyCoverFallsBackAndNavyUsesWhiteText()
        tests.testVividPatchWinsOverDarkCover()
        try await tests.testMissingLyricsAreCached()
        try await tests.testRateLimitBlocksFurtherRequests()
        try await tests.testWrongDurationIsRejected()
        try await tests.testSearchFallbackFindsSyncedLyrics()
        print("PASS: 13 synthetic Phase 3 tests")
    }

    func testRepeatedTagsAndLateOffset() {
        let lines = LRC.parse("[ar:Fixture]\n[00:02.00][01:02.500] repeat\n[00:04.123] next\n[offset:+250]")
        expectEqual(lines.map(\.time), [1.75, 3.873, 62.25])
        expectEqual(lines.map(\.text), ["repeat", "next", "repeat"])
    }

    func testBlankLinesAndInvalidTimestamps() {
        let lines = LRC.parse("\u{FEFF}[00:03]\n[00:60] invalid\n[-1:02] invalid\n[NaN:01] invalid\n[00:04.2] <00:04.2>synthetic <00:04.8>words")
        expectEqual(lines.count, 2)
        expectEqual(lines[0].text, "")
        expectEqual(lines[1].text, "synthetic words")
    }

    func testNegativeOffsetAndClamping() {
        expectEqual(LRC.parse("[offset:-500]\n[00:01] x").first?.time, 1.5)
        expectEqual(LRC.parse("[offset:+2000]\n[00:01] x").first?.time, 0)
    }

    func testStableDuplicateTimestampsAndSeeking() {
        let lines = LRC.parse("[00:03] first\n[00:03] second\n[00:05]\n[00:07] last")
        expectEqual(lines.map(\.id), [0, 1, 2, 3])
        expectNil(LRC.activeIndex(in: lines, at: 2.99))
        expectEqual(LRC.activeIndex(in: lines, at: 3), 1)
        expectEqual(LRC.activeIndex(in: lines, at: 6), 2)
        expectEqual(LRC.activeIndex(in: lines, at: 99), 3)
        expectNil(LRC.activeIndex(in: lines, at: 0))
        expectNil(LRC.activeIndex(in: [], at: 3))
    }

    func testResponseUsesSyncedAndIgnoresNewFields() throws {
        let data = Data(#"{"duration":123,"instrumental":false,"syncedLyrics":"[00:01] Synthetic line","plainLyrics":"Synthetic line","hasWordSync":true,"lyricsfile":"unused fixture"}"#.utf8)
        let record = try JSONDecoder().decode(LyricsService.Record.self, from: data)
        guard case let .synced(lines) = record.content else { fail("expected line timing") }
        expectEqual(lines.count, 1)
        expectEqual(lines.first?.time, 1)
    }

    func testResponseFallbackAndInstrumental() throws {
        let decoder = JSONDecoder()
        let plain = try decoder.decode(LyricsService.Record.self, from: Data(#"{"instrumental":false,"syncedLyrics":"[ar:fixture]","plainLyrics":"  Synthetic words  "}"#.utf8))
        expectEqual(plain.content, .plain("Synthetic words"))
        let instrumental = try decoder.decode(LyricsService.Record.self, from: Data(#"{"instrumental":true,"plainLyrics":"ignored"}"#.utf8))
        expectEqual(instrumental.content, .instrumental)
        let missing = try decoder.decode(LyricsService.Record.self, from: Data(#"{"instrumental":false}"#.utf8))
        expectEqual(missing.content, .missing)
    }

    func testRequestPreservesVersionMetadataAndDuration() {
        let track = TrackInfo(uri: "spotify:track:fixture", name: "A & B (Live)",
                              artists: [.init(name: "Artist + One", uri: nil)], album: "Album / Deluxe",
                              durationMs: 123456, explicit: false, coverURL: nil)
        let request = LyricsService.request(for: .init(track))
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        expectEqual(query.first { $0.name == "track_name" }?.value, track.name)
        expectEqual(query.first { $0.name == "artist_name" }?.value, "Artist + One")
        expectEqual(query.first { $0.name == "duration" }?.value, "123.456")
        expectTrue(request.value(forHTTPHeaderField: "User-Agent")!.hasPrefix("Tint"))
    }

    func testGreyCoverFallsBackAndNavyUsesWhiteText() {
        expectNil(CoverColorExtractor.extract(of: image { ctx in
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }))
        let navy = CoverColorExtractor.extract(of: image { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.1, blue: 0.35, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        })
        expectNotNil(navy)
        expectFalse(navy!.usesDarkText)
        expectGreaterThan(navy!.b, navy!.r)
        expectTrue(RGB.fallback.usesDarkText)
    }

    func testVividPatchWinsOverDarkCover() {
        let chosen = CoverColorExtractor.extract(of: image { ctx in
            ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 30, y: 30, width: 40, height: 40))
        })
        expectNotNil(chosen)
        expectGreaterThan(chosen!.r, chosen!.b)
        expectGreaterThan(chosen!.b, chosen!.g)
    }

    func testMissingLyricsAreCached() async throws {
        let service = fixtureService(status: 404)
        let signature = fixtureSignature()
        let first = try await service.lyrics(for: signature)
        let countAfterFirst = FixtureProtocol.fixture.requestCount
        let second = try await service.lyrics(for: signature)
        expectEqual(first, .missing)
        expectEqual(second, .missing)
        expectEqual(FixtureProtocol.fixture.requestCount, countAfterFirst)
    }

    func testRateLimitBlocksFurtherRequests() async throws {
        let service = fixtureService(status: 429, headers: ["Retry-After": "120"])
        for _ in 0..<2 {
            do {
                _ = try await service.lyrics(for: fixtureSignature())
                fail("rate limit should throw")
            } catch LyricsService.Failure.rateLimited(let date) {
                expectTrue(date.timeIntervalSinceNow > 110)
            }
        }
        expectEqual(FixtureProtocol.fixture.requestCount, 1)
    }

    func testWrongDurationIsRejected() async throws {
        let service = fixtureService(status: 200,
            data: Data(#"{"duration":150,"instrumental":false,"syncedLyrics":"[00:02] Synthetic wrong version"}"#.utf8))
        let content = try await service.lyrics(for: fixtureSignature())
        expectEqual(content, .missing)
    }

    func testSearchFallbackFindsSyncedLyrics() async throws {
        expectEqual(LyricsService.cleanTitle("Bohemian Rhapsody - Remastered 2011"), "Bohemian Rhapsody")
        expectEqual(LyricsService.cleanTitle("Song Name (feat. Someone)"), "Song Name")
        let searchPayload = Data(#"[{"duration":125,"instrumental":false,"syncedLyrics":"[00:02] Found via search","plainLyrics":"Found via search"},{"duration":190,"instrumental":false,"syncedLyrics":"[00:02] Wrong length"}]"#.utf8)
        let records = try JSONDecoder().decode([LyricsService.Record].self, from: searchPayload)
        guard case let .synced(lines)? = LyricsService.bestMatch(in: records, for: fixtureSignature()) else {
            fail("expected synced match within tolerance")
        }
        expectEqual(lines.first?.text, "Found via search")
    }

    private func fixtureSignature() -> LyricsService.Signature {
        .init(TrackInfo(uri: "spotify:track:fixture", name: "Fixture", artists: [.init(name: "Fixture artist", uri: nil)],
                        album: "Fixture album", durationMs: 123000, explicit: false, coverURL: nil))
    }

    private func fixtureService(status: Int, headers: [String: String] = [:], data: Data = Data()) -> LyricsService {
        FixtureProtocol.fixture.configure(status: status, headers: headers, data: data)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return LyricsService(session: URLSession(configuration: config))
    }

    private func image(_ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }
}

// CLT-only Macs don't ship XCTest. Use preconditions (enabled in -O builds).
private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    precondition(a == b, "values differ", file: file, line: line)
}
private func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "expected nil", file: file, line: line)
}
private func expectNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value != nil, "expected non-nil", file: file, line: line)
}
private func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "expected true", file: file, line: line)
}
private func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value, "expected false", file: file, line: line)
}
private func expectGreaterThan(_ a: Double, _ b: Double, file: StaticString = #file, line: UInt = #line) {
    precondition(a > b, "expected greater", file: file, line: line)
}
private func fail(_ message: String) -> Never { fatalError(message) }

private final class FixtureResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var status = 200
    private var headers: [String: String] = [:]
    private var data = Data()
    var requestCount: Int { lock.withLock { count } }
    func configure(status: Int, headers: [String: String], data: Data) {
        lock.withLock { self.status = status; self.headers = headers; self.data = data; count = 0 }
    }
    func take() -> (Int, [String: String], Data) {
        lock.withLock { count += 1; return (status, headers, data) }
    }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = FixtureResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, data) = Self.fixture.take()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
