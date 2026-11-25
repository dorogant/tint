import AppKit
import Foundation
import os

/// Spawns and controls Spotify's official headless client (`soloist`) over its
/// local loopback WebSocket API (`--ws 127.0.0.1:0`), translating events into
/// Tint's `CoreEvent`s. Works on every Spotify Premium account (including newer
/// accounts refused by Spotify's legacy `librespot` audio-key endpoint).
@MainActor
final class SoloistBackend {
    static let downloadsURL = URL(string: "https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates")!
    static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!
    static let homebrewCommand = "brew install --cask spotify-soloist"
    static let upgradeCommand = "brew upgrade --cask spotify-soloist"

    var onEvent: ((CoreEvent) -> Void)?
    private(set) var processIdentifier: pid_t?

    private var process: Process?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var protocolState = SoloistProtocol.State()
    private var generation = 0
    private var stopping = false
    private var stderrTail = ""
    private nonisolated(unsafe) var terminateObserver: NSObjectProtocol?
    private let session = URLSession(configuration: .ephemeral)
    private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "soloist")

    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Floe/Soloist", isDirectory: true)
    }

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.antonchurchyn.floe/Soloist", isDirectory: true)
    }

    /// Searches standard install locations for the `soloist` binary.
    nonisolated static func findBinary() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["FLOE_SOLOIST_PATH"], !env.isEmpty {
            candidates.append(env)
        }
        if let custom = UserDefaults.standard.string(forKey: "soloistBinaryPath"), !custom.isEmpty {
            candidates.append(custom)
        }
        let home = NSHomeDirectory()
        candidates += [
            "/opt/homebrew/bin/soloist",
            "/usr/local/bin/soloist",
            "\(home)/Library/Application Support/Floe/Soloist/bin/soloist",
            "\(home)/.local/bin/soloist",
        ]
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                candidates.append("\(dir)/soloist")
            }
        }
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    nonisolated static func findHomebrew() -> URL? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Reads `soloist --version` off the main actor.
    @concurrent nonisolated static func installedVersion() async -> String? {
        guard let binary = findBinary() else { return nil }
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--version"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text.split(separator: "\n").first.map(String.init)
    }

    /// Installs or upgrades `spotify-soloist` via Homebrew off the main actor.
    @concurrent nonisolated static func installViaHomebrew(upgrade: Bool = false) async -> Result<URL, Error> {
        guard let brew = findHomebrew() else {
            return .failure(NSError(domain: "SoloistBackend", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Homebrew was not found. Install Spotify Soloist from developer.spotify.com."
            ]))
        }
        let proc = Process()
        proc.executableURL = brew
        proc.arguments = [upgrade ? "upgrade" : "install", "--cask", "spotify-soloist"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if proc.terminationStatus == 0, let binary = findBinary() {
                return .success(binary)
            }
            let tail = output.split(separator: "\n").suffix(3).joined(separator: " ")
            return .failure(NSError(domain: "SoloistBackend", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: tail.isEmpty ? "Homebrew install failed (exit \(proc.terminationStatus))." : tail
            ]))
        } catch {
            return .failure(error)
        }
    }

    init() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

    // MARK: - Lifecycle

    func start(apiKey: String, volume: UInt16) {
        stop()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            onEvent?(.loginFailed(L10n.string("Enter your Spotify Soloist API key to connect."), refused: true))
            return
        }
        guard let binary = Self.findBinary() else {
            onEvent?(.loginFailed(L10n.string("Spotify Soloist isn't installed yet. Install it with Homebrew or from developer.spotify.com."), refused: true))
            return
        }

        generation += 1
        let gen = generation
        stopping = false
        protocolState = SoloistProtocol.State()
        stderrTail = ""
        onEvent?(.connecting)

        let dataDir = Self.dataDirectory
        let cacheDir = Self.cacheDirectory
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } catch {
            onEvent?(.loginFailed(error.localizedDescription, refused: true))
            return
        }

        // Remove stale runtime discovery files before spawning a fresh daemon.
        let addrFile = dataDir.appendingPathComponent("ws.addr")
        let portFile = dataDir.appendingPathComponent("ws.port")
        try? FileManager.default.removeItem(at: addrFile)
        try? FileManager.default.removeItem(at: portFile)

        let initialPercent = min(100, max(0, Int((Double(volume) / 65535.0 * 100.0).rounded())))
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "--device-name", "Tint",
            "--api-key", key,
            "--data-dir", dataDir.path,
            "--cache-dir", cacheDir.path,
            "--cache-size", "1024",
            "--initial-volume", "\(initialPercent)",
            "--ws", "127.0.0.1:0",
        ]
        let stderrPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = stderrPipe

        let handle = stderrPipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { fh.readabilityHandler = nil; return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.stderrTail = (self.stderrTail + chunk).suffix(600).description
            }
        }

        proc.terminationHandler = { [weak self] terminated in
            handle.readabilityHandler = nil
            let code = terminated.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.handleTermination(status: code)
            }
        }

        do {
            try proc.run()
        } catch {
            onEvent?(.loginFailed("Couldn't start Spotify Soloist: \(error.localizedDescription)", refused: true))
            return
        }

        process = proc
        processIdentifier = proc.processIdentifier
        log.notice("Started soloist pid \(proc.processIdentifier)")

        connectTask = Task { [weak self] in
            await self?.discoverAndConnect(addrFile: addrFile, portFile: portFile, generation: gen)
        }
    }

    func stop() {
        stopping = true
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        if let proc = process {
            proc.terminationHandler = nil
            if proc.isRunning { proc.terminate() }
        }
        process = nil
        processIdentifier = nil
        protocolState = SoloistProtocol.State()
    }

    func logOut() {
        stop()
        // Clearing Soloist's data directory removes the stored Spotify Connect session.
        try? FileManager.default.removeItem(at: Self.dataDirectory)
        onEvent?(.loggedOut)
    }

    // MARK: - Commands

    @discardableResult
    func load(_ request: PlayRequest) -> Bool {
        guard socket != nil, protocolState.isLoggedIn else { return false }
        let targetURI: String?
        if let start = request.startURI, !start.isEmpty {
            targetURI = start
        } else if let context = request.contextURI, !context.isEmpty {
            targetURI = context
        } else if let tracks = request.tracks, !tracks.isEmpty {
            let idx = min(max(request.startIndex ?? 0, 0), tracks.count - 1)
            targetURI = tracks[idx]
        } else {
            return false
        }
        guard let targetURI else { return false }
        send(SoloistProtocol.setShuffle(request.shuffle))
        if let repeatMode = RepeatMode(rawValue: request.repeatMode) {
            for cmd in SoloistProtocol.setRepeatCommands(repeatMode) { send(cmd) }
        }
        send(SoloistProtocol.play(uri: targetURI))
        if let tracks = request.tracks, tracks.count > 1,
           let startIndex = tracks.firstIndex(of: targetURI) {
            for nextURI in tracks.dropFirst(startIndex + 1).prefix(12) {
                send(SoloistProtocol.addToQueue(uri: nextURI))
            }
        }
        if let pos = request.positionMs, pos > 0 {
            send(SoloistProtocol.seek(positionMs: pos))
        }
        if !request.startPlaying {
            send(SoloistProtocol.pause())
        }
        return true
    }

    func play() { send(SoloistProtocol.play()) }
    func pause() { send(SoloistProtocol.pause()) }
    func next() { send(SoloistProtocol.skipNext()) }
    func previous() { send(SoloistProtocol.skipPrev()) }
    func seek(toMs ms: UInt32) { send(SoloistProtocol.seek(positionMs: ms)) }
    func setShuffle(_ on: Bool) { send(SoloistProtocol.setShuffle(on)) }
    func setRepeat(_ mode: RepeatMode) {
        for cmd in SoloistProtocol.setRepeatCommands(mode) { send(cmd) }
    }
    func setVolume(_ volume: UInt16) { send(SoloistProtocol.setVolume(volume)) }
    func transferPlayback() { send(SoloistProtocol.activate()) }

    @discardableResult
    func addToQueue(_ uri: String) -> Bool {
        guard socket != nil, protocolState.isLoggedIn else { return false }
        send(SoloistProtocol.addToQueue(uri: uri))
        return true
    }

    // MARK: - WebSocket loop

    private func discoverAndConnect(addrFile: URL, portFile: URL, generation gen: Int) async {
        // Wait up to 8 s for soloist to bind its local WebSocket port and write ws.addr/ws.port.
        var endpoint: URL?
        for _ in 0..<160 {
            guard !Task.isCancelled, self.generation == gen else { return }
            if let addr = try? String(contentsOf: addrFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let port = try? String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !addr.isEmpty, !port.isEmpty,
               let url = URL(string: "ws://\(addr):\(port)") {
                endpoint = url
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled, self.generation == gen else { return }
        guard let endpoint else {
            let detail = stderrHint() ?? "Spotify Soloist didn't open its local WebSocket server."
            onEvent?(.loginFailed(detail, refused: false))
            stop()
            return
        }

        let ws = session.webSocketTask(with: endpoint)
        socket = ws
        ws.resume()
        send(SoloistProtocol.getAuthState())

        receiveTask = Task { [weak self] in
            await self?.readLoop(ws, generation: gen)
        }
    }

    private func readLoop(_ ws: URLSessionWebSocketTask, generation gen: Int) async {
        while !Task.isCancelled, self.generation == gen {
            do {
                let message = try await ws.receive()
                guard self.generation == gen else { return }
                let data: Data
                switch message {
                case let .string(text): data = Data(text.utf8)
                case let .data(raw): data = raw
                @unknown default: continue
                }
                let decoded = SoloistProtocol.decode(json: data, state: &protocolState)
                if let err = decoded.errorMessage {
                    log.warning("Soloist error: \(err, privacy: .public)")
                }
                for event in decoded.events {
                    onEvent?(event)
                }
                if decoded.shouldFetchState {
                    send(SoloistProtocol.getState())
                    send(SoloistProtocol.getQueue(limit: 10))
                }
            } catch {
                guard !Task.isCancelled, self.generation == gen, !stopping else { return }
                log.notice("Soloist WebSocket closed: \(error.localizedDescription, privacy: .public)")
                if process?.isRunning == true {
                    // Transient local socket drop while daemon is alive: reconnect.
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled, self.generation == gen else { return }
                    let addrFile = Self.dataDirectory.appendingPathComponent("ws.addr")
                    let portFile = Self.dataDirectory.appendingPathComponent("ws.port")
                    await discoverAndConnect(addrFile: addrFile, portFile: portFile, generation: gen)
                }
                return
            }
        }
    }

    private func send(_ text: String?) {
        guard let text, let socket else { return }
        socket.send(.string(text)) { [log] error in
            if let error { log.warning("Soloist send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func handleTermination(status: Int32) {
        process = nil
        processIdentifier = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
        guard !stopping else { return }

        if status == 10 {
            onEvent?(.loginFailed(
                L10n.string("Your Spotify Soloist build expired (90-day limit). Update it with `brew upgrade --cask spotify-soloist` and reconnect."),
                refused: true
            ))
            return
        }
        if protocolState.isLoggedIn {
            onEvent?(.disconnected)
        } else {
            let hint = stderrHint() ?? L10n.string("Spotify Soloist exited (code \(status)). Check your Soloist API key.")
            let lower = hint.lowercased()
            let refused = lower.contains("api key") || lower.contains("unauthorized") || lower.contains("invalid") || status == 10
            onEvent?(.loginFailed(hint, refused: refused))
        }
    }

    private func stderrHint() -> String? {
        let lines = stderrTail
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last
    }
}
