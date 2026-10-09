import AppKit
import CryptoKit
import Foundation

/// OAuth 2.0 authorization-code flow with PKCE against accounts.spotify.com,
/// completed on a loopback redirect. No client secret is involved, ever.
enum SpotifyOAuth {
    struct Config: Sendable {
        let clientID: String
        let redirectURI: URL
        let scopes: [String]

        /// Tint's own developer app, used for the Web API. The client ID
        /// is public; PKCE needs no secret. The redirect is registered in that app.
        static let webAPI = Config(
            clientID: "YOUR_SPOTIFY_CLIENT_ID",
            redirectURI: URL(string: "http://127.0.0.1:8898/callback")!,
            scopes: [
                "playlist-read-private", "playlist-read-collaborative",
                "user-library-read", "user-library-modify",
                "user-read-recently-played", "user-top-read", "user-follow-read",
            ]
        )

        /// Added only when the user connects Queue and Devices; never requested on restore.
        static let playbackControls = Config(clientID: webAPI.clientID, redirectURI: webAPI.redirectURI,
            scopes: webAPI.scopes + ["user-read-playback-state", "user-read-currently-playing", "user-modify-playback-state"])

        /// librespot's session login: Spotify's own client ID, `streaming` scope.
        /// Its registered redirect is `http://127.0.0.1:<port>/login`; 5588 is librespot's default.
        static func playbackSession(clientID: String) -> Config {
            Config(
                clientID: clientID,
                redirectURI: URL(string: "http://127.0.0.1:5588/login")!,
                scopes: ["streaming"]
            )
        }
    }

    struct Token: Codable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    enum Failure: LocalizedError {
        case denied(String)
        case stateMismatch
        case tokenRequest(status: Int, body: String)

        var errorDescription: String? {
            switch self {
            case let .denied(reason): L10n.string("Spotify login was not completed (\(reason)).")
            case .stateMismatch: L10n.string("Login response didn't match the request; try again.")
            case let .tokenRequest(status, _): L10n.string("Spotify authorization failed (HTTP \(status)). Try signing in again.")
            }
        }
    }

    /// Opens the browser for consent and returns the token once Spotify redirects back.
    @MainActor
    static func authorize(_ config: Config) async throws -> Token {
        let verifier = randomURLSafe(byteCount: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = randomURLSafe(byteCount: 16)

        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: config.redirectURI.absoluteString),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: config.scopes.joined(separator: " ")),
        ]

        let server = try LoopbackRedirectServer(
            port: UInt16(config.redirectURI.port ?? 80),
            path: config.redirectURI.path
        )
        try await server.start()
        NSWorkspace.shared.open(url.url!)
        let query = try await server.redirect(timeout: 300)

        if let error = query["error"] { throw Failure.denied(error) }
        guard query["state"] == state else { throw Failure.stateMismatch }
        guard let code = query["code"] else { throw Failure.denied("no code") }

        return try await requestToken(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI.absoluteString,
            "client_id": config.clientID,
            "code_verifier": verifier,
        ])
    }

    /// Spotify may rotate the refresh token; callers keep the old one if none comes back.
    static func refresh(_ config: Config, refreshToken: String) async throws -> Token {
        try await requestToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
        ])
    }

    private static func requestToken(form: [String: String]) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(form).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Error bodies are small JSON like {"error":"invalid_grant"}; no secrets in them.
            throw Failure.tokenRequest(status: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try JSONDecoder().decode(Token.self, from: data)
    }

    private static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
    }

    private static func randomURLSafe(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator() // CSPRNG on Apple platforms
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URLEncoded()
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
