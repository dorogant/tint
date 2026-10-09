import Foundation
import os
import SwiftUI

/// Picks the live background's preset for each song while Auto preset is on:
/// from the artist's Spotify genres when there are any, otherwise from the
/// sound. Runs once per song change; listening, when needed, rides on the
/// analysis frames the background already gets and stops once decided.
///
/// The sound decides once after about ten seconds of music and may change its
/// mind once, if a calm start turns into a steady beat (a drop) for two windows
/// in a row; after a minute of music it stops listening.
@MainActor
final class AutoPresetController {
    struct Song: Equatable, Sendable {
        var uri: String
        var artistIDs: [String]
        var artistNames: [String]
    }

    typealias GenreSource = @Sendable ([String]) async -> ArtistGenres.Answer

    private enum Stage { case idle, first, watching(windows: Int, candidate: BackgroundPreset?), done }

    /// `-FloeSelfTestAutoPreset YES`: logs each song's genres and choice to
    /// stdout, even with the auto preset off (it then changes nothing).
    static var isLogging: Bool { UserDefaults.standard.bool(forKey: "FloeSelfTestAutoPreset") }
    /// Windows heard after the first decision before giving up on a drop.
    static let maximumWindows = 5

    private let settings: VisualSettings
    private let genres: GenreSource
    private let reduceMotion: () -> Bool
    private let logging: Bool
    /// Turns the frame feed on and off; set by whoever owns the analysis.
    var setListening: ((Bool) -> Void)?
    private var classifier = SoundClassifier()
    private var stage = Stage.idle
    private var enabled = false
    /// The genre matched only the catch-all, so the sound may still refine it.
    private var genreIsWeak = false
    private var song: Song?
    private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "autopreset")

    init(settings: VisualSettings, genres: @escaping GenreSource, logging: Bool = AutoPresetController.isLogging,
         reduceMotion: @escaping () -> Bool = { false }) {
        self.settings = settings
        self.genres = genres
        self.logging = logging
        self.reduceMotion = reduceMotion
    }

    /// Call on every song change and whenever the auto preset turns on or off;
    /// cancel the previous call's task first (a skip drops its request).
    func update(_ song: Song?, enabled: Bool) async {
        stopListening()
        self.song = song
        self.enabled = enabled
        genreIsWeak = false
        guard let song, enabled || logging else {
            if !enabled { settings.autoStatus = nil }
            return
        }
        if enabled { settings.autoStatus = .choosing }
        let answer = await genres(song.artistIDs)
        guard !Task.isCancelled, self.song == song else { return }
        let match = GenrePresets.match(answer.genres)
        say("song \(song.uri) by \(song.artistNames.joined(separator: ", "))")
        for line in answer.trail { say("  artist \(line)") }
        say("  genres \(answer.genres) → \(Self.describe(match))")
        if let match {
            apply(match.preset, .genre(match.preset, match.genre))
            guard !match.isSpecific else { return }
            genreIsWeak = true
        }
        if !enabled || !reduceMotion() {
            stage = .first
            classifier.reset()
            setListening?(true)
        } else if match == nil {
            settings.autoStatus = .noGenre(settings.backgroundPreset)
        }
    }

    /// One analysis frame (30 Hz) while listening.
    func hear(_ frame: SpectrumFrame) {
        switch stage {
        case .idle, .done: return
        case .first, .watching: break
        }
        classifier.add(frame)
        if classifier.isComplete { decide() }
    }

    private func decide() {
        let features = classifier.features
        let preset = SoundClassifier.preset(for: features)
        classifier.reset(restartTempo: false)
        say("  sound \(features) → \(preset.rawValue)")
        switch stage {
        case .first:
            // A weak genre (pop) stays unless the sound is sure of something else.
            if !(genreIsWeak && preset == .balanced) { apply(preset, .sound(preset)) }
            stage = .watching(windows: 0, candidate: nil)
        case let .watching(windows, candidate):
            let calm: Set<BackgroundPreset> = [.chill, .acoustic, .balanced, .subtle]
            let pulse: Set<BackgroundPreset> = [.club, .hipHop, .rock]
            if calm.contains(settings.backgroundPreset), pulse.contains(preset), candidate == preset {
                apply(preset, .sound(preset))
                return finish()
            }
            guard windows + 1 < Self.maximumWindows else { return finish() }
            stage = .watching(windows: windows + 1, candidate: pulse.contains(preset) ? preset : nil)
        case .idle, .done:
            break
        }
    }

    private func finish() {
        stopListening()
        stage = .done
    }

    private func stopListening() {
        if case .idle = stage {} else { setListening?(false) }
        stage = .idle
    }

    /// Glides the sliders as a choice by hand does (unless Reduce Motion), and
    /// only while the auto preset is on; the self-test log alone changes nothing.
    private func apply(_ preset: BackgroundPreset, _ status: AutoPresetStatus) {
        guard enabled, settings.autoPreset else { return }
        withAnimation(reduceMotion() ? nil : .easeOut(duration: 0.2)) { settings.applyAutomatically(preset) }
        settings.autoStatus = status
    }

    private static func describe(_ match: GenrePresets.Match?) -> String {
        guard let match else { return "no match" }
        let strength = match.isSpecific ? "" : " (weak)"
        return "\(match.preset.rawValue) from \"\(match.genre)\"" + strength
    }

    private func say(_ text: @autoclosure () -> String) {
        guard logging else { return }
        let line = "[autopreset] \(text())"
        print(line)
        fflush(stdout)
        log.notice("\(line, privacy: .public)")
    }
}

extension AutoPresetController.Song {
    init(_ track: TrackInfo) {
        uri = track.uri
        artistIDs = track.artists.compactMap { ArtistGenres.artistID(fromURI: $0.uri) }
        artistNames = track.artists.map(\.name)
    }
}
