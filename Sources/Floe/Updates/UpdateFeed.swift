import Foundation

/// A dotted version as releases are numbered: "0.4.1", or the tag "v0.4.1".
/// Anything else ("0.5.0-beta", "nightly") is not a version Tint moves to.
struct AppVersion: Comparable, Hashable, Codable, Sendable, CustomStringConvertible {
    /// Without trailing zeros, so 0.4 and 0.4.0 are the same version.
    let parts: [Int]

    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(fields.count) else { return nil }
        var parts: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.count <= 6, field.allSatisfy(\.isASCII), field.allSatisfy(\.isNumber), let number = Int(field) else { return nil }
            parts.append(number)
        }
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        self.parts = parts
    }

    static func < (a: Self, b: Self) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let (x, y) = (index < a.parts.count ? a.parts[index] : 0, index < b.parts.count ? b.parts[index] : 0)
            if x != y { return x < y }
        }
        return false
    }

    /// At least three numbers, as in the About box.
    var description: String {
        (parts + [Int](repeating: 0, count: max(0, 3 - parts.count))).map(String.init).joined(separator: ".")
    }
}

/// A published release, as far as updating is concerned.
struct UpdateRelease: Codable, Equatable, Sendable {
    var version: AppVersion
    /// Its page, for reading what changed and for downloading by hand.
    var page: URL
    /// The zipped app and the signature of that zip. A release without both
    /// (0.4.0 and earlier) can only be downloaded by hand.
    var archive: URL?
    var signature: URL?

    var isInstallable: Bool { archive != nil && signature != nil }
}

/// Why a check or an install stopped. Each has its own words in Settings.
enum UpdateProblem: Error, Equatable, Sendable {
    /// No answer: offline, or GitHub is down.
    case unreachable
    /// GitHub allows 60 questions an hour from one address and this one has had them.
    case busy
    /// An answer Tint can't read.
    case unexpected
    /// The archive isn't signed with Tint's update key.
    case badSignature
    /// The archive doesn't hold a working copy of Tint.
    case damaged
    /// The archive holds a version that is no newer than the one running.
    case notNewer
    /// macOS is running this copy from a hidden read-only place, as it does
    /// for an app opened straight from Downloads.
    case translocated
    /// Tint's folder can't be changed by this user.
    case notWritable
    /// macOS stopped Tint from replacing itself (Privacy & Security ▸ App Management).
    case refused
}

/// How the feed and the downloads reach the network; a stand-in in tests.
/// A type of its own, not an extension of `URLSession`: a method added there
/// can shadow the system's own of the same name for the whole app.
protocol UpdateTransport: Sendable {
    /// The body and the HTTP status.
    func fetch(_ request: URLRequest) async throws -> (Data, Int)
    /// Saves the body to `file`; the HTTP status.
    func download(_ request: URLRequest, to file: URL) async throws -> Int
}

struct UpdateSession: UpdateTransport {
    /// No cache or cookies: the answer has to be today's, and nothing of the
    /// visit should stay behind.
    static let session = URLSession(configuration: .ephemeral)

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await Self.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func download(_ request: URLRequest, to file: URL) async throws -> Int {
        let (temporary, response) = try await Self.session.download(for: request)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// Tint's releases on GitHub: which is the latest, and its files.
struct UpdateFeed: Sendable {
    static let latest = URL(string: "https://api.github.com/repos/dorogant/tint/releases/latest")!
    static let archiveName = "Tint.zip"
    static let signatureName = "Tint.zip.sig"
    /// A signature is 88 characters; an app twenty times today's size is not Tint.
    static let signatureLimit = 1024
    static let archiveLimit = 150_000_000

    var transport: any UpdateTransport = UpdateSession()
    var endpoint = Self.latest
    /// GitHub turns away requests without one. The version says nothing about the person.
    var userAgent = "Tint"

    /// The latest release, or nil when there is none that carries a version.
    func latest() async throws(UpdateProblem) -> UpdateRelease? {
        var request = self.request(endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, status) = try await answer { try await transport.fetch(request) }
        switch status {
        case 200: return try Self.parse(data)
        // A repository with no releases yet.
        case 404: return nil
        case 403, 429: throw .busy
        default: throw status >= 500 ? .unreachable : .unexpected
        }
    }

    func signature(at url: URL) async throws(UpdateProblem) -> Data {
        let (data, status) = try await answer { try await transport.fetch(request(url)) }
        guard status == 200, data.count <= Self.signatureLimit else { throw status >= 500 ? .unreachable : .unexpected }
        guard let signature = Data(base64Encoded: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .badSignature
        }
        return signature
    }

    func download(_ url: URL, to file: URL) async throws(UpdateProblem) {
        let status = try await answer { try await transport.download(request(url), to: file) }
        guard status == 200 else { throw status >= 500 ? .unreachable : .unexpected }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
        guard let size, size > 0, size <= Self.archiveLimit else { throw .damaged }
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func answer<T: Sendable>(_ ask: () async throws -> T) async throws(UpdateProblem) -> T {
        do { return try await ask() } catch { throw .unreachable }
    }

    /// GitHub's "release" object. Links that aren't https are left out, so a
    /// release can't point a download at a plain or local address.
    static func parse(_ data: Data) throws(UpdateProblem) -> UpdateRelease? {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: String }
            let tag_name: String
            let html_url: String
            let assets: [Asset]?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data), let page = secure(release.html_url) else { throw .unexpected }
        guard let version = AppVersion(release.tag_name) else { return nil }
        func asset(_ name: String) -> URL? {
            release.assets?.first { $0.name == name }.flatMap { secure($0.browser_download_url) }
        }
        return UpdateRelease(version: version, page: page, archive: asset(archiveName), signature: asset(signatureName))
    }

    private static func secure(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}
