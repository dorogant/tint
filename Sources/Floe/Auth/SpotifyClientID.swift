import Foundation

/// Which Spotify developer app the Web API login goes through. Spotify only lets
/// accounts the app's owner allow-listed sign in to a Development Mode app, so
/// everyone else brings their own. A client ID is public (PKCE needs no secret),
/// so it lives in UserDefaults.
///
/// Order: the ID the user pasted, then the one the build baked into Info.plist
/// (`FloeSpotifyClientID`, from scripts/build-app.sh), then none: onboarding asks.
enum SpotifyClientID {
    static let defaultsKey = "spotifyClientID"
    static let infoPlistKey = "FloeSpotifyClientID"

    static var current: String? { custom ?? builtIn }

    /// Pasted in onboarding or Settings.
    static var custom: String? { valid(UserDefaults.standard.string(forKey: defaultsKey)) }

    /// Built into this copy of Tint, if any.
    static var builtIn: String? { valid(Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String) }

    /// Saves a pasted ID, or forgets it with nil. Returns false if it isn't one.
    @discardableResult
    static func setCustom(_ text: String?) -> Bool {
        guard let text else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return true
        }
        guard let id = valid(text) else { return false }
        UserDefaults.standard.set(id, forKey: defaultsKey)
        return true
    }

    /// Spotify client IDs are 32 hex characters; pasting often brings spaces along.
    static func valid(_ text: String?) -> String? {
        guard let id = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              id.count == 32, id.allSatisfy(\.isHexDigit) else { return nil }
        return id
    }
}
