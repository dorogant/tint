import Foundation

// Only the I/O boundary is synthetic: PlayerModel and its event/metadata types
// are compiled from production. No login, saved credentials, audio engine or network.
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
    var engine: PlaybackEngine = .librespot
    var usesLocalAudioOutput: Bool { true }
    private(set) var commands = [Command]()
    private(set) var loads = [PlayRequest]()
    var sessionClientID: String { "synthetic-client" }

    func reset() { commands = []; loads = []; onEvent = nil }
    func deliver(_ event: CoreEvent) { onEvent?(event) }
    func startSoloist(apiKey: String, volume: UInt16) { preconditionFailure("Unexpected soloist start") }
    func stopSoloist() {}
    func setSoloistTapRunning(_ running: Bool) {}
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
    /// The newest model's, so a test can ask whether its engine is running.
    private(set) static var latest: AudioOutput?
    private(set) var isRunning = false
    var volume: Float = 0
    init() { Self.latest = self }
    func start() { isRunning = true }
    func pause() { isRunning = false }
}

@MainActor final class NowPlayingController {
    init(model: PlayerModel) {}
    func update() {}
}

final class CredentialStore: Sendable {
    enum Account { case playbackSession, soloistAPIKey }
    static let shared = CredentialStore()
    func read(_ account: Account) -> Data? { preconditionFailure("Unexpected credential read") }
    func write(_ data: Data, account: Account) { preconditionFailure("Unexpected credential write") }
    func delete(_ account: Account) { preconditionFailure("Unexpected credential delete") }
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
