import Foundation

/// Translates Spotify Soloist's local WebSocket JSON protocol into Tint's `CoreEvent`s
/// and encodes control/query commands back to Soloist.
/// Reference: https://developer.spotify.com/documentation/soloist/reference/websocket-api
enum SoloistProtocol {
    struct State: Sendable {
        var currentURI: String?
        var lastPositionMs: Double = 0
        var lastTimestampMs: Double = 0
        var lastSpeed: Double = 0
        var isLoggedIn = false
    }

    // MARK: - Command encoding

    static func command(_ name: String, fields: [String: Any] = [:]) -> String? {
        var payload = fields
        payload["type"] = "command"
        payload["command"] = name
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func getAuthState() -> String? { command("get_auth_state") }
    static func getState() -> String? { command("get_state") }
    static func getQueue(limit: Int = 10) -> String? { command("get_queue", fields: ["limit": limit]) }
    static func play(uri: String? = nil) -> String? {
        uri.map { command("play", fields: ["uri": $0]) } ?? command("play")
    }
    static func pause() -> String? { command("pause") }
    static func skipNext() -> String? { command("skip_next") }
    static func skipPrev() -> String? { command("skip_prev") }
    static func seek(positionMs: UInt32) -> String? { command("seek", fields: ["position_ms": Int(positionMs)]) }
    static func setVolume(_ rawSpotifyVolume: UInt16) -> String? {
        let percent = min(100, max(0, Int((Double(rawSpotifyVolume) / 65535.0 * 100.0).rounded())))
        return command("set_volume", fields: ["volume": percent])
    }
    static func setShuffle(_ enabled: Bool) -> String? { command("set_shuffle", fields: ["enabled": enabled]) }
    static func setRepeatCommands(_ mode: RepeatMode) -> [String] {
        switch mode {
        case .off:
            [command("set_repeat_track", fields: ["enabled": false]),
             command("set_repeat_context", fields: ["enabled": false])].compactMap { $0 }
        case .context:
            [command("set_repeat_track", fields: ["enabled": false]),
             command("set_repeat_context", fields: ["enabled": true])].compactMap { $0 }
        case .track:
            [command("set_repeat_context", fields: ["enabled": false]),
             command("set_repeat_track", fields: ["enabled": true])].compactMap { $0 }
        }
    }
    static func addToQueue(uri: String) -> String? { command("add_to_queue", fields: ["uri": uri]) }
    static func activate() -> String? { command("activate") }

    // MARK: - Event decoding

    struct Decoded: Sendable {
        var events: [CoreEvent] = []
        /// True when Soloist just transitioned to logged in and Tint should query state/queue.
        var shouldFetchState = false
        var errorMessage: String?
    }

    static func decode(
        json data: Data,
        state: inout State,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) -> Decoded {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return Decoded() }

        var result = Decoded()
        switch type {
        case "auth_state":
            let loggedIn = obj["logged_in"] as? Bool ?? false
            let deviceName = (obj["device_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Tint"
            if loggedIn {
                if !state.isLoggedIn { result.shouldFetchState = true }
                state.isLoggedIn = true
                result.events.append(.connected(username: deviceName))
            } else {
                state.isLoggedIn = false
                result.events.append(.awaitingPairing(deviceName: deviceName))
            }

        case "playback_state":
            if let item = obj["item"] as? [String: Any], let track = parseTrack(item) {
                state.currentURI = track.uri
                result.events.append(.track(track))
            }
            let pos = updatePosition(from: obj["position"] as? [String: Any], state: &state, nowMs: nowMs)
            if let status = obj["status"] as? String,
               let event = statusEvent(status, positionMs: pos, uri: state.currentURI) {
                result.events.append(event)
            }
            if let volume = (obj["volume"] as? NSNumber)?.doubleValue {
                result.events.append(.volume(spotifyVolume(fromPercent: volume)))
            }
            if let options = obj["options"] as? [String: Any] {
                result.events.append(contentsOf: parseOptions(options))
            }
            if let active = obj["is_active"] as? Bool, !active {
                result.events.append(.deviceInactive)
            }

        case "track_changed":
            if let item = obj["item"] as? [String: Any], let track = parseTrack(item) {
                state.currentURI = track.uri
                result.events.append(.track(track))
            }

        case "playback_changed":
            let pos = currentPosition(state: state, nowMs: nowMs)
            if let status = obj["status"] as? String,
               let event = statusEvent(status, positionMs: pos, uri: state.currentURI) {
                if status != "playing" {
                    state.lastPositionMs = pos
                    state.lastTimestampMs = nowMs
                    state.lastSpeed = 0
                }
                result.events.append(event)
            }

        case "position_sync":
            let pos = updatePosition(from: obj["position"] as? [String: Any], state: &state, nowMs: nowMs)
            result.events.append(.position(positionMs: pos))

        case "volume_changed":
            if let volume = (obj["volume"] as? NSNumber)?.doubleValue {
                result.events.append(.volume(spotifyVolume(fromPercent: volume)))
            }

        case "options_changed":
            if let options = obj["options"] as? [String: Any] {
                result.events.append(contentsOf: parseOptions(options))
            }

        case "device_changed":
            if let active = obj["is_active"] as? Bool, !active {
                result.events.append(.deviceInactive)
            }

        case "queue_changed":
            if let uri = state.currentURI, !uri.isEmpty {
                let previous = obj["previous"] as? [[String: Any]] ?? []
                result.events.append(.navigation(uri: uri, hasPrevious: !previous.isEmpty))
            }

        case "error":
            result.errorMessage = obj["message"] as? String ?? "Soloist command failed"

        default:
            break
        }
        return result
    }

    // MARK: - Helpers

    private static func spotifyVolume(fromPercent percent: Double) -> UInt16 {
        UInt16(min(65535, max(0, (percent / 100.0 * 65535.0).rounded())))
    }

    private static func currentPosition(state: State, nowMs: Double) -> Double {
        guard state.lastSpeed > 0, state.lastTimestampMs > 0 else { return state.lastPositionMs }
        let elapsed = max(0, nowMs - state.lastTimestampMs)
        return max(0, state.lastPositionMs + elapsed * state.lastSpeed)
    }

    private static func updatePosition(from posObj: [String: Any]?, state: inout State, nowMs: Double) -> Double {
        guard let posObj else { return currentPosition(state: state, nowMs: nowMs) }
        let posMs = (posObj["position_ms"] as? NSNumber)?.doubleValue ?? state.lastPositionMs
        let tsMs = (posObj["timestamp_ms"] as? NSNumber)?.doubleValue ?? nowMs
        let speed = (posObj["speed"] as? NSNumber)?.doubleValue ?? 0
        state.lastPositionMs = posMs
        state.lastTimestampMs = tsMs
        state.lastSpeed = speed
        let elapsed = speed > 0 ? max(0, nowMs - tsMs) : 0
        return max(0, posMs + elapsed * speed)
    }

    private static func statusEvent(_ status: String, positionMs: Double, uri: String?) -> CoreEvent? {
        switch status {
        case "playing": .playing(positionMs: positionMs)
        case "paused": .paused(positionMs: positionMs)
        case "buffering": .loading(positionMs: positionMs)
        case "idle": .stopped(uri: uri)
        default: nil
        }
    }

    private static func parseOptions(_ options: [String: Any]) -> [CoreEvent] {
        var events: [CoreEvent] = []
        if let shuffle = options["shuffle"] as? Bool {
            events.append(.shuffle(shuffle))
        }
        if let repeatName = options["repeat"] as? String {
            let mode: RepeatMode = switch repeatName {
            case "context": .context
            case "track": .track
            default: .off
            }
            events.append(.repeatMode(mode))
        }
        return events
    }

    static func parseTrack(_ entity: [String: Any]) -> TrackInfo? {
        guard let uri = entity["uri"] as? String, !uri.isEmpty else { return nil }
        let decorations = entity["decorations"] as? [String: Any]
        let identity = decorations?["identity"] as? [String: Any]
        let name = (identity?["name"] as? String) ?? (entity["name"] as? String) ?? ""
        guard !name.isEmpty else { return nil }

        let creators = decorations?["creators"] as? [[String: Any]] ?? []
        let artists: [TrackInfo.Artist] = creators.compactMap { rawCreator in
            let creator = (rawCreator["entity"] as? [String: Any]) ?? rawCreator
            let dec = creator["decorations"] as? [String: Any]
            let id = dec?["identity"] as? [String: Any]
            let artistName = (id?["name"] as? String)
                ?? (creator["name"] as? String)
                ?? (rawCreator["name"] as? String)
                ?? ""
            guard !artistName.isEmpty else { return nil }
            let artistURI = ((creator["uri"] as? String) ?? (rawCreator["uri"] as? String))
                .flatMap { $0.isEmpty ? nil : $0 }
            return TrackInfo.Artist(name: artistName, uri: artistURI)
        }

        let parentObj = decorations?["parent"] as? [String: Any]
        let parent = (parentObj?["entity"] as? [String: Any]) ?? parentObj
        let parentDec = parent?["decorations"] as? [String: Any]
        let album = (parentDec?["identity"] as? [String: Any])?["name"] as? String
            ?? (parent?["name"] as? String)

        let playback = decorations?["playback"] as? [String: Any]
        let durationMs = (playback?["duration_ms"] as? NSNumber)?.doubleValue
            ?? (decorations?["duration_ms"] as? NSNumber)?.doubleValue
            ?? (entity["duration_ms"] as? NSNumber)?.doubleValue
            ?? 0
        let ratings = (playback?["content_ratings"] as? [String])
            ?? (decorations?["content_ratings"] as? [String])
            ?? []
        let explicit = ratings.contains("explicit")

        let visual = decorations?["visual_identity"] as? [String: Any]
        let covers = (visual?["cover"] as? [[String: Any]])
            ?? (visual?["images"] as? [[String: Any]])
            ?? []
        let coverURL = bestCoverURL(in: covers)

        return TrackInfo(
            uri: uri,
            name: name,
            artists: artists,
            album: album,
            durationMs: durationMs,
            explicit: explicit,
            coverURL: coverURL
        )
    }

    private static func bestCoverURL(in covers: [[String: Any]]) -> URL? {
        func rank(_ size: String?) -> Int {
            switch size {
            case "xlarge": 4
            case "large": 3
            case "default": 2
            case "small": 1
            default: 0
            }
        }
        return covers
            .compactMap { entry -> (Int, URL)? in
                guard let raw = entry["url"] as? String, let url = URL(string: raw) else { return nil }
                return (rank(entry["size"] as? String), url)
            }
            .max { $0.0 < $1.0 }?.1
    }
}
