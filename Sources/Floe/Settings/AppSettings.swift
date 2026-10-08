import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    static let glassOpacityRange = 0.2...0.9

    var bitrate: Int { didSet { defaults.set(bitrate, forKey: "bitrate") } }
    var normalization: Bool { didSet { defaults.set(normalization, forKey: "normalization") } }
    var gapless: Bool { didSet { defaults.set(gapless, forKey: "gapless") } }
    var language: String { didSet { defaults.set(language, forKey: "appLanguage") } }
    var glassOpacity: Double { didSet { defaults.set(glassOpacity, forKey: "glassOpacity") } }
    var fixedAccent: String { didSet { defaults.set(fixedAccent, forKey: "fixedAccent") } }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let playback = PlaybackConfiguration.default
        let quality = defaults.object(forKey: "bitrate") as? Int ?? playback.bitrate
        bitrate = PlaybackConfiguration.supportedBitrates.contains(quality) ? quality : playback.bitrate
        normalization = defaults.object(forKey: "normalization") as? Bool ?? playback.normalization
        gapless = defaults.object(forKey: "gapless") as? Bool ?? playback.gapless
        let language = defaults.string(forKey: "appLanguage") ?? "system"
        self.language = ["system", "en", "uk"].contains(language) ? language : "system"
        glassOpacity = min(Self.glassOpacityRange.upperBound,
                           max(Self.glassOpacityRange.lowerBound, defaults.object(forKey: "glassOpacity") as? Double ?? 0.62))
        let accent = defaults.string(forKey: "fixedAccent") ?? "green"
        fixedAccent = ["green", "blue", "violet", "amber"].contains(accent) ? accent : "green"
    }

    var playbackConfiguration: PlaybackConfiguration {
        PlaybackConfiguration(bitrate: bitrate, normalization: normalization, gapless: gapless)
    }

    var locale: Locale {
        Locale(identifier: language == "system" ? L10n.language : language)
    }
}

struct PlaybackConfiguration: Equatable, Sendable {
    static let `default` = Self(bitrate: 320, normalization: false, gapless: true)
    static let supportedBitrates = [96, 160, 320]

    var bitrate: Int
    var normalization: Bool
    var gapless: Bool
}
