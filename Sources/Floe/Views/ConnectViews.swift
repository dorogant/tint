import SwiftUI

extension ConnectSection {
    var title: String { self == .queue ? "Queue" : "Devices" }
    var symbol: String { self == .queue ? "list.bullet" : "hifispeaker" }
}

struct ConnectPanel: View {
    @Environment(\.coverPalette) private var palette
    @Environment(ConnectModel.self) private var connect
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.interfaceScale) private var scale
    let section: ConnectSection
    /// The device a transfer was requested for, until the device list confirms it.
    @ViewState private var pendingDevice: String?
    /// The active-device highlight is shared, so it glides to the new device.
    @Namespace private var activeDevice

    var body: some View {
        VStack(alignment: .leading, spacing: scale(16)) {
            HStack {
                Text(LocalizedStringKey(section.title))
                    .floeFont(size: 18, weight: .bold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if connect.isLoading {
                    ProgressView().controlSize(.small).transition(.opacity)
                }
                IconButton(systemImage: "arrow.clockwise", size: 13, help: "Refresh") {
                    Task { await connect.refresh(section) }
                }
                .disabled(connect.isLoading)
            }
            if connect.needsPermission {
                notice(systemImage: "lock.open", tint: palette.highlight,
                       text: Text("Connect Queue and Devices to read your upcoming songs and switch Spotify Connect devices."))
                Button("Connect Queue and Devices") { Task { await connect.connect(section) } }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .disabled(connect.isLoading)
            }
            if let error = connect.error {
                notice(systemImage: "exclamationmark.triangle", tint: .orange, text: Text(error))
                Button("Reconnect Queue and Devices") { Task { await connect.connect(section) } }
                    .disabled(connect.isLoading)
            }
            if !connect.needsPermission {
                switch section {
                case .queue: queueContents
                case .devices: deviceContents
                }
            }
        }
        .padding(scale(20)).frame(width: scale(390))
        .environment(\.locale, settings.locale)
        .floeState(value: connect.isLoading)
        .task(id: section == .queue ? player.track?.uri : "devices") { await connect.refresh(section) }
    }

    private func notice(systemImage: String, tint: Color, text: Text) -> some View {
        HStack(alignment: .top, spacing: scale(10)) {
            Image(systemName: systemImage)
                .floeFont(size: 13, weight: .semibold)
                .foregroundStyle(tint)
                .frame(width: scale(28), height: scale(28))
                .background(tint.opacity(0.14), in: Circle())
            text
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var queueContents: some View {
        VStack(alignment: .leading, spacing: scale(8)) {
            if let current = connect.current {
                caption("Now playing")
                QueueRow(track: current, current: true)
            }
            caption("Up next").padding(.top, scale(connect.current == nil ? 0 : 6))
            if connect.queue.isEmpty && !connect.isLoading {
                HStack(spacing: scale(10)) {
                    Image(systemName: "text.badge.plus")
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: scale(36), height: scale(36))
                        .background(Theme.well, in: RoundedRectangle(cornerRadius: scale(6)))
                    Text("No queued songs.").foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, scale(8))
            }
            ScrollView {
                LazyVStack(spacing: scale(2)) {
                    ForEach(Array(connect.queue.enumerated()), id: \.offset) { _, track in QueueRow(track: track) }
                }
            }
            .frame(maxHeight: scale(340))
            Text("Only songs are shown.").font(.caption).foregroundStyle(Theme.tertiary)
        }
    }

    private var deviceContents: some View {
        VStack(alignment: .leading, spacing: scale(10)) {
            VStack(spacing: scale(2)) {
                ForEach(connect.devices, id: \.id) { device in
                    DeviceRow(device: device, pending: connect.transferring && pendingDevice == device.id,
                              namespace: activeDevice) {
                        pendingDevice = device.id
                        Task {
                            await connect.transfer(device)
                            pendingDevice = nil
                        }
                    }
                }
            }
            .floeGlide(value: connect.devices.first(where: \.isActive)?.id)
            if connect.devices.isEmpty && !connect.isLoading {
                Text("No devices found.").foregroundStyle(Theme.secondary).padding(.horizontal, scale(8))
            }
            Divider().padding(.vertical, 4)
            Button("Play on Tint") { player.resume() }.disabled(!player.isConnected)
            caption("Tint volume")
            VolumeControl()
            Text("To change your Mac's audio output, use Control Center.")
                .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .floeFont(size: 10.5, weight: .semibold)
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, scale(8))
            .accessibilityAddTraits(.isHeader)
    }
}

/// A queued song. Highlights under the pointer; the context menu has the usual
/// song actions. The playing song carries an accent wash.
private struct QueueRow: View {
    @Environment(\.coverPalette) private var palette
    let track: Track
    var current = false
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: scale(10)) {
            ArtworkView(images: track.album?.images, size: scale(36), cornerRadius: scale(5))
            VStack(alignment: .leading, spacing: scale(3)) {
                Text(track.name)
                    .floeFont(size: 12, weight: .semibold)
                    .foregroundStyle(current ? palette.highlight : .white)
                    .lineLimit(1)
                Text(track.artistLine).floeFont(size: 11).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer()
            Text(Format.duration(ms: Double(track.durationMs)))
                .font(.caption).monospacedDigit().foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, scale(8))
        .padding(.vertical, scale(5))
        .background {
            let shape = RoundedRectangle(cornerRadius: scale(8), style: .continuous)
            if current {
                shape.fill(palette.accent.opacity(hovering ? 0.18 : 0.12))
            } else {
                shape.fill(Theme.hover).opacity(hovering ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .contextMenu { TrackMenuItems(track: track) }
        .accessibilityElement(children: .combine)
    }
}

/// A Spotify Connect device. The active one sits on an accent wash that glides
/// to the new device after a transfer; others highlight under the pointer.
private struct DeviceRow: View {
    @Environment(\.coverPalette) private var palette
    let device: ConnectDevice
    let pending: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    private var symbol: String {
        switch device.type.lowercased() {
        case "computer": "desktopcomputer"
        case "smartphone": "iphone"
        case "tablet": "ipad"
        case "tv": "tv"
        case "automobile": "car"
        case "gameconsole": "gamecontroller"
        default: "hifispeaker"
        }
    }

    var body: some View {
        let active = device.isActive
        Button(action: action) {
            HStack(spacing: scale(12)) {
                Image(systemName: symbol)
                    .floeFont(size: 14, weight: .medium)
                    .foregroundStyle(active ? palette.highlight : (hovering ? .white : Theme.secondary))
                    .frame(width: scale(32), height: scale(32))
                    .background(active ? palette.accent.opacity(0.2) : Color.white.opacity(0.07), in: Circle())
                Text(device.name)
                    .floeFont(size: 13, weight: active ? .semibold : .medium)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: scale(8))
                if pending {
                    ProgressView().controlSize(.small)
                } else if active {
                    // Trailing, so rows keep their layout and only colour changes hands.
                    HStack(spacing: scale(6)) {
                        Text("Active device").floeFont(size: 11, weight: .medium)
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .foregroundStyle(palette.highlight)
                    .transition(.opacity)
                } else if device.isRestricted {
                    Image(systemName: "lock.fill").floeFont(size: 11).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, scale(8))
            .padding(.vertical, scale(6))
            .background {
                let shape = RoundedRectangle(cornerRadius: scale(10), style: .continuous)
                ZStack {
                    shape.fill(Theme.hover).opacity(hovering && !active ? 1 : 0)
                    if active {
                        shape.fill(palette.accent.opacity(0.12))
                            .overlay(shape.strokeBorder(palette.accent.opacity(0.28)))
                            .floeMatched("active", in: namespace)
                    }
                }
            }
            .contentShape(Rectangle())
            .opacity(device.isRestricted ? 0.5 : 1)
        }
        .buttonStyle(.floeRow)
        .disabled(device.isRestricted || pending || active)
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .help(LocalizedStringKey(device.isRestricted ? "This device does not accept remote control." : "Switch playback to this device"))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
