import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    var bitrate: Int { didSet { defaults.set(bitrate, forKey: "bitrate") } }
    var normalization: Bool { didSet { defaults.set(normalization, forKey: "normalization") } }
    var gapless: Bool { didSet { defaults.set(gapless, forKey: "gapless") } }
    var language: String { didSet { defaults.set(language, forKey: "appLanguage") } }
    var glassOpacity: Double { didSet { defaults.set(glassOpacity, forKey: "glassOpacity") } }
    var fixedAccent: String { didSet { defaults.set(fixedAccent, forKey: "fixedAccent") } }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let quality = defaults.object(forKey: "bitrate") as? Int ?? 320
        bitrate = [96, 160, 320].contains(quality) ? quality : 320
        normalization = defaults.bool(forKey: "normalization")
        gapless = defaults.object(forKey: "gapless") as? Bool ?? true
        let language = defaults.string(forKey: "appLanguage") ?? "system"
        self.language = ["system", "en", "uk"].contains(language) ? language : "system"
        glassOpacity = min(0.9, max(0.2, defaults.object(forKey: "glassOpacity") as? Double ?? 0.62))
        let accent = defaults.string(forKey: "fixedAccent") ?? "green"
        fixedAccent = ["green", "blue", "violet", "amber"].contains(accent) ? accent : "green"
    }

    var playbackConfiguration: PlaybackConfiguration {
        PlaybackConfiguration(bitrate: bitrate, normalization: normalization, gapless: gapless)
    }
}

struct PlaybackConfiguration: Equatable, Sendable {
    var bitrate: Int
    var normalization: Bool
    var gapless: Bool
}
