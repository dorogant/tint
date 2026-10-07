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

    var errorDescription: String? { String(localized: "Your Spotify library isn't connected.") }
}

/// PKCE tokens for Floe's own client ID, persisted in the Keychain and refreshed as needed.
actor UserTokenProvider: TokenProvider {
    private struct Stored: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    private var stored: Stored?
    private var refreshTask: Task<Stored, Error>?
    private var loaded = false

    var isAuthorized: Bool {
        loadIfNeeded()
        return stored != nil
    }

    /// Opens the browser for consent (one time) and stores the tokens.
    func authorize() async throws {
        let token = try await SpotifyOAuth.authorize(.webAPI)
        guard let refresh = token.refreshToken else { throw TokenError.notAuthorized }
        save(Stored(accessToken: token.accessToken, refreshToken: refresh,
                    expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn))))
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
        stored = nil
        refreshTask = nil
        Keychain.delete(Keychain.Account.webAPI)
    }

    private func refreshed(_ current: Stored) async throws -> Stored {
        if let refreshTask { return try await refreshTask.value }
        let task = Task {
            let token = try await SpotifyOAuth.refresh(.webAPI, refreshToken: current.refreshToken)
            return Stored(accessToken: token.accessToken,
                          refreshToken: token.refreshToken ?? current.refreshToken,
                          expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)))
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            save(fresh)
            return fresh
        } catch let SpotifyOAuth.Failure.tokenRequest(status, _) where status == 400 {
            // invalid_grant: the refresh token was revoked; ask the user to reconnect.
            signOut()
            throw TokenError.notAuthorized
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = Keychain.read(Keychain.Account.webAPI) {
            stored = try? JSONDecoder().decode(Stored.self, from: data)
        }
    }

    private func save(_ value: Stored) {
        stored = value
        loaded = true
        if let data = try? JSONEncoder().encode(value) {
            Keychain.write(data, account: Keychain.Account.webAPI)
        }
    }
}
