import SwiftUI

/// Settings ▸ Playback ▸ Equalizer: ten bands, presets, and a word on what it
/// does to the sound's path. Only shown for Soloist (see `FloeCore.equalizer`).
struct EqualizerSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SwiftUI.Section {
            Toggle("Equalizer", isOn: $settings.equalizer.isOn)
            Picker("Preset", selection: preset) {
                ForEach(Equalizer.Preset.chosen) { Text(LocalizedStringKey($0.title)).tag($0) }
                if settings.equalizer.preset == .custom {
                    Divider()
                    Text("Custom").tag(Equalizer.Preset.custom)
                }
            }
            .pickerStyle(.menu)
            .disabled(!settings.equalizer.isOn)
            EqualizerBands(equalizer: $settings.equalizer)
                .disabled(!settings.equalizer.isOn)
        } header: {
            Text("Equalizer")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("While the equalizer is on, Tint plays Soloist's sound itself, about 30 ms later. Boosts lower the overall level so loud songs don't distort; turn the volume up to match.")
                if settings.equalizer.isOn, EqualizerStatus.shared.state == .listening {
                    Text("Waiting to hear Soloist. If the sound stays unchanged while music plays, allow Tint to record system audio in System Settings → Privacy & Security.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var preset: Binding<Equalizer.Preset> {
        Binding { settings.equalizer.preset } set: { settings.equalizer.choose($0) }
    }
}

/// The ten sliders, lows on the left, each with its gain above and its
/// frequency below.
struct EqualizerBands: View {
    @Binding var equalizer: Equalizer
    @Environment(\.isEnabled) private var isEnabled
    private static let travel: CGFloat = 132

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // The scale the sliders are read against.
            VStack(alignment: .trailing) {
                Text(verbatim: "+12")
                Spacer()
                Text(verbatim: "0")
                Spacer()
                Text(verbatim: "−12")
            }
            .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            .frame(height: Self.travel - 6)
            .padding(.trailing, 6)
            .accessibilityHidden(true)
            ForEach(Equalizer.frequencies.indices, id: \.self) { band in
                VStack(spacing: 6) {
                    Text(verbatim: Self.readout(equalizer.gains[band]))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(isEnabled ? .secondary : .tertiary)
                    // A native slider turned on its side: AppKit's own vertical
                    // slider isn't offered by SwiftUI, and this keeps its look,
                    // keyboard handling and VoiceOver.
                    Slider(value: gain(band), in: Double(Equalizer.gainRange.lowerBound)...Double(Equalizer.gainRange.upperBound))
                        .labelsHidden()
                        .frame(width: Self.travel)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 26, height: Self.travel)
                        .accessibilityLabel(Text(verbatim: Self.spoken(Equalizer.frequencies[band])))
                        .accessibilityValue(Text(verbatim: Self.readout(equalizer.gains[band]) + " dB"))
                    Text(verbatim: Self.label(Equalizer.frequencies[band]))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(isEnabled ? .primary : .tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }

    /// Half-decibel steps: finer than anyone hears, and the readout stays short.
    private func gain(_ band: Int) -> Binding<Double> {
        Binding { Double(equalizer.gains[band]) } set: { equalizer.setGain(Float(($0 * 2).rounded() / 2), band: band) }
    }

    static func readout(_ gain: Float) -> String {
        let text = abs(gain).formatted(.number.precision(.fractionLength(gain == gain.rounded() ? 0 : 1)))
        return gain > 0 ? "+" + text : (gain < 0 ? "−" + text : "0")
    }

    static func label(_ frequency: Float) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }

    private static func spoken(_ frequency: Float) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000)) kHz" : "\(Int(frequency)) Hz"
    }
}
