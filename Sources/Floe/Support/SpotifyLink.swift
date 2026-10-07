import Foundation

enum SpotifyLink {
    /// Accepts `spotify:track:ID` or a share link such as
    /// `https://open.spotify.com/intl-uk/track/ID?si=…` and returns the URI.
    static func uri(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("spotify:") { return text }
        guard let url = URL(string: text), url.host()?.hasSuffix("spotify.com") == true else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
        guard parts.count >= 2 else { return nil }
        return "spotify:\(parts[0]):\(parts[1])"
    }
}
