import Foundation

// Only the I/O boundary is synthetic: PlayerModel and its event/metadata types
// are compiled from production. No login, Keychain, audio engine or network.
struct PlayRequest: Sendable {
    var contextURI: String?
    var tracks: [String]?
    var startURI: String?
    var startIndex: Int?
    var shuffle = false
    var repeatMode = 0
    var positionMs: UInt32?
    var startPlaying = true
}

@MainActor final class FloeCore {
    enum Command: Equatable {
        case previous, next, seek(UInt32), play, pause, transfer
    }

    static let shared = FloeCore()
    var onEvent: ((CoreEvent) -> Void)?
    private(set) var commands = [Command]()
    private(set) var loads = [PlayRequest]()
    var sessionClientID: String { "synthetic-client" }

    func reset() { commands = []; loads = []; onEvent = nil }
    func deliver(_ event: CoreEvent) { onEvent?(event) }
    func previous() { commands.append(.previous) }
    func next() { commands.append(.next) }
    func seek(toMs ms: UInt32) { commands.append(.seek(ms)) }
    func play() { commands.append(.play) }
    func pause() { commands.append(.pause) }
    func transferPlayback() { commands.append(.transfer) }
    func load(_ request: PlayRequest) -> Bool { loads.append(request); return true }
    func configure(_ configuration: PlaybackConfiguration) {}
    func setShuffle(_ value: Bool) {}
    func setRepeat(_ value: RepeatMode) {}
    func setVolume(_ value: UInt16) {}
    func addToQueue(_ uri: String) -> Bool { true }
    func logIn(accessToken: String, volume: UInt16) { preconditionFailure("Unexpected login") }
    func logIn(storedCredentials: Data, volume: UInt16) { preconditionFailure("Unexpected login") }
    func logOut() { preconditionFailure("Unexpected logout") }
}

@MainActor final class AudioOutput {
    var volume: Float = 0
    func start() {}
    func pause() {}
}

@MainActor final class NowPlayingController {
    init(model: PlayerModel) {}
    func update() {}
}

enum Keychain {
    enum Account { static let playbackSession = "synthetic-session" }
    static func read(_ account: String) -> Data? { preconditionFailure("Unexpected Keychain read") }
    static func write(_ data: Data, account: String) { preconditionFailure("Unexpected Keychain write") }
    static func delete(_ account: String) { preconditionFailure("Unexpected Keychain delete") }
}

enum SpotifyOAuth {
    struct Config: Sendable {
        static func playbackSession(clientID: String) -> Self { Self() }
    }
    struct Token: Sendable { let accessToken: String }
    static func authorize(_ config: Config) async throws -> Token {
        preconditionFailure("Unexpected authorization")
    }
}

enum L10n {
    static let language = "en"
    static func string(_ value: String) -> String { value }
}
