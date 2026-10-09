import SwiftUI

/// Rows only, so the same controls sit in the Visuals popover and in a Settings `Form`.
struct VisualizerOptions: View {
    @Environment(VisualSettings.self) private var settings
    var body: some View {
        @Bindable var settings = settings
        Toggle("Show visualizer", isOn: $settings.showVisualizer)
        Group {
            Picker("Style", selection: $settings.style) {
                Text("Normal").tag(VisualSettings.Style.normal)
                Text("Circular").tag(VisualSettings.Style.circular)
            }.pickerStyle(.segmented)
            Picker("Shape", selection: $settings.shape) {
                Text("Bars").tag(VisualSettings.Shape.bars)
                Text("Wave").tag(VisualSettings.Shape.wave)
            }.pickerStyle(.segmented)
            SettingsSlider("Sensitivity", value: $settings.sensitivity, range: 0.25...3,
                           displayedValue: percent(settings.sensitivity))
        }.disabled(!settings.showVisualizer)
    }
}

/// Rows that don't apply to the selected kind stay in place, disabled, so
/// switching kinds doesn't make the popover jump.
struct BackgroundOptions: View {
    @Environment(VisualizationModel.self) private var visualization
    @Environment(VisualSettings.self) private var settings
    @ReducedMotion private var reduceMotion
    var body: some View {
        @Bindable var settings = settings
        Toggle("Live background", isOn: $settings.liveBackground)
        Group {
            presets
            autoPreset
            Picker("Kind", selection: $settings.backgroundKind) {
                Text("Fluid").tag(VisualSettings.BackgroundKind.fluid)
                Text("Beams").tag(VisualSettings.BackgroundKind.beams)
            }.pickerStyle(.segmented)
            SettingsSlider("Reactivity", value: $settings.reactivity, range: 0...2,
                           displayedValue: percent(settings.reactivity))
            SettingsSlider("Speed", value: $settings.motionSpeed, range: VisualSettings.speedRange,
                           displayedValue: percent(settings.motionSpeed))
            SettingsSlider("Glow", value: $settings.glow, range: VisualSettings.glowRange,
                           displayedValue: percent(settings.glow))
            SettingsSlider("Vividness", value: $settings.vividness, range: VisualSettings.vividnessRange,
                           displayedValue: percent(settings.vividness))
            SettingsSlider("Bass punch", value: $settings.punch, range: VisualSettings.punchRange,
                           displayedValue: percent(settings.punch))
            Group {
                SettingsStepper("Beam count", value: $settings.beamCount, range: VisualSettings.beamCountRange)
                Toggle("Strobe on the beat", isOn: $settings.strobe)
            }.disabled(settings.backgroundKind != .beams)
        }.disabled(!settings.liveBackground)
        if settings.liveBackground, let error = visualization.backgroundFailure {
            Text(error).font(.callout).foregroundStyle(.orange)
        }
    }

    /// One click per preset, so looks can be compared quickly. The sliders below
    /// glide to the preset's values, and touching one switches to Custom, which
    /// keeps the last hand-tuned values to come back to.
    private var presets: some View {
        Picker("Preset", selection: Binding(get: { settings.backgroundPreset }, set: { preset in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { settings.choose(preset) }
        })) {
            Section("General") {
                ForEach(BackgroundPreset.general) { Text(LocalizedStringKey($0.title)).tag($0) }
            }
            Section("Genres") {
                ForEach(BackgroundPreset.genres) { Text(LocalizedStringKey($0.title)).tag($0) }
            }
            Divider()
            Text("Custom").tag(BackgroundPreset.custom)
        }
        .pickerStyle(.menu)
    }

    /// Picks the preset per song. Choosing a preset or moving a slider by hand
    /// unticks it (rather than pausing it for one song), so the checkbox always
    /// says whether the look will change on the next song.
    @ViewBuilder private var autoPreset: some View {
        @Bindable var settings = settings
        Toggle("Auto preset", isOn: $settings.autoPreset)
            .help("Picks a preset for each song from its genre on Spotify, or from how it sounds. Choosing a preset or moving a slider turns it off.")
        if settings.autoPreset, let status = settings.autoStatus {
            caption(status)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caption(_ status: AutoPresetStatus) -> Text {
        switch status {
        case .choosing: Text("Choosing a preset for this song…")
        case let .genre(preset, genre): Text("\(Text(LocalizedStringKey(preset.title))) · from genre: \(genre)")
        case let .sound(preset): Text("\(Text(LocalizedStringKey(preset.title))) · from the sound")
        case let .noGenre(preset): Text("\(Text(LocalizedStringKey(preset.title))) · no genre found")
        }
    }
}

/// A slider's value as a whole percentage, rounded (1.149 reads 115%, not 114%).
private func percent(_ value: Double) -> Text { Text("\(Int((value * 100).rounded()))%") }

struct VisualControls: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Visuals").font(.title3.bold())
            VisualizerOptions()
            Divider()
            // Tighter than the sections around it: the background has the most rows.
            VStack(alignment: .leading, spacing: 9) { BackgroundOptions() }
            Text("Motion stops when playback pauses or Tint is in the background. Reduce Motion keeps the effects still. Live backgrounds use extra energy.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .environment(\.settingsLabelWidth, 92) // one label column, so the sliders line up
        .padding(20).frame(width: 340)
    }
}
