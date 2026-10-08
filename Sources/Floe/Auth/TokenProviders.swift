import Foundation

/// Where Web API access tokens come from: Floe's own client ID via PKCE.
///
/// PLAN.md's fallback ("Path B": tokens from the librespot session) was tried on
/// 2026-10-08 and doesn't work: keymaster answers 403 "Invalid request", and
/// api.spotify.com throttles login5 tokens (429, Retry-After up to 86400 s).
/// Kept behind this protocol in case another source becomes viable.
protocol TokenProvider: Sendable {
    func accessToken() async throws -> String
    /// Called after a 401 so the next `accessToken()` fetches a fresh one.
    func invalidate() async
}

enum TokenError: LocalizedError {
    case notAuthorized

    var errorDescription: String? { L10n.string("Your Spotify library isn't connected.") }
}

/// PKCE tokens for Floe's own client ID, persisted in `CredentialStore` and refreshed as needed.
actor UserTokenProvider: TokenProvider {
    private struct Stored: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var scope: String?
    }

    private var stored: Stored?
    private var refreshTask: Task<Stored, Error>?
    private var loaded = false
    private var generation = 0
    private var authorizationExpired: (@MainActor @Sendable () -> Void)?

    var isAuthorized: Bool {
        loadIfNeeded()
        return stored != nil
    }

    /// Opens the browser for consent (one time) and stores the tokens.
    func authorize(playbackControls: Bool = false) async throws {
        generation += 1
        let epoch = generation
        refreshTask?.cancel()
        refreshTask = nil
        let token = try await SpotifyOAuth.authorize(playbackControls ? .playbackControls : .webAPI)
        guard epoch == generation else { throw CancellationError() }
        guard let refresh = token.refreshToken else { throw TokenError.notAuthorized }
        save(Stored(accessToken: token.accessToken, refreshToken: refresh,
                    expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)), scope: token.scope))
    }

    var hasPlaybackControls: Bool {
        loadIfNeeded()
        let scopes = Set((stored?.scope ?? "").split(separator: " ").map(String.init))
        return scopes.isSuperset(of: ["user-read-playback-state", "user-modify-playback-state"])
    }

    func setAuthorizationExpiredHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        authorizationExpired = handler
    }
    func reportAuthorizationExpired() {
        if let authorizationExpired { Task { await authorizationExpired() } }
    }

    func accessToken() async throws -> String {
        loadIfNeeded()
        guard let current = stored else { throw TokenError.notAuthorized }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        return try await refreshed(current).accessToken
    }

    func invalidate() {
        stored?.expiresAt = .distantPast
    }

    func signOut() {
        generation += 1
        loaded = true
        refreshTask?.cancel()
        stored = nil
        refreshTask = nil
        CredentialStore.shared.delete(.webAPI)
    }

    private func refreshed(_ current: Stored) async throws -> Stored {
        let epoch = generation
        if let refreshTask {
            let value = try await refreshTask.value
            guard epoch == generation else { throw CancellationError() }
            return value
        }
        let task = Task {
            let token = try await SpotifyOAuth.refresh(.webAPI, refreshToken: current.refreshToken)
            return Stored(accessToken: token.accessToken,
                          refreshToken: token.refreshToken ?? current.refreshToken,
                          expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)), scope: token.scope ?? current.scope)
        }
        refreshTask = task
        defer { if epoch == generation { refreshTask = nil } }
        do {
            let fresh = try await task.value
            guard epoch == generation else { throw CancellationError() }
            save(fresh)
            return fresh
        } catch let SpotifyOAuth.Failure.tokenRequest(status, body) where status == 400 && body.contains("invalid_grant") {
            // invalid_grant: the refresh token was revoked; ask the user to reconnect.
            if epoch == generation { signOut(); reportAuthorizationExpired() }
            throw TokenError.notAuthorized
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = CredentialStore.shared.read(.webAPI) {
            stored = try? JSONDecoder().decode(Stored.self, from: data)
        }
    }

    private func save(_ value: Stored) {
        stored = value
        loaded = true
        if let data = try? JSONEncoder().encode(value) {
            CredentialStore.shared.write(data, account: .webAPI)
        }
    }
}
