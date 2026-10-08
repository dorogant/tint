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
                           displayedValue: Text("\(Int(settings.sensitivity * 100))%"))
        }.disabled(!settings.showVisualizer)
    }
}

/// Rows that don't apply to the selected kind stay in place, disabled, so
/// switching kinds doesn't make the popover jump.
struct BackgroundOptions: View {
    @Environment(VisualizationModel.self) private var visualization
    @Environment(VisualSettings.self) private var settings
    var body: some View {
        @Bindable var settings = settings
        Toggle("Live background", isOn: $settings.liveBackground)
        Group {
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
            SettingsSlider("Shake", value: $settings.shake, range: VisualSettings.shakeRange,
                           displayedValue: percent(settings.shake))
                .disabled(settings.backgroundKind != .fluid)
            Group {
                Stepper(value: $settings.beamCount, in: VisualSettings.beamCountRange) {
                    LabeledContent("Beam count") { Text("\(settings.beamCount)").monospacedDigit() }
                }
                Toggle("Strobe on the beat", isOn: $settings.strobe)
            }.disabled(settings.backgroundKind != .beams)
        }.disabled(!settings.liveBackground)
        if settings.liveBackground, let error = visualization.backgroundFailure {
            Text(error).font(.callout).foregroundStyle(.orange)
        }
    }

    private func percent(_ value: Double) -> Text { Text("\(Int((value * 100).rounded()))%") }
}

struct VisualControls: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Visuals").font(.title3.bold())
            VisualizerOptions()
            Divider()
            // Tighter than the sections around it: the background has the most rows.
            VStack(alignment: .leading, spacing: 9) { BackgroundOptions() }
            Text("Motion stops when playback pauses or Floe is in the background. Reduce Motion keeps the effects still. Live backgrounds use extra energy.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(width: 340)
    }
}
