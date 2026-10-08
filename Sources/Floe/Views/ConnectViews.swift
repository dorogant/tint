import SwiftUI

extension ConnectSection {
    var title: String { self == .queue ? "Queue" : "Devices" }
    var symbol: String { self == .queue ? "list.bullet" : "hifispeaker" }
}

struct ConnectPanel: View {
    @Environment(ConnectModel.self) private var connect
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    let section: ConnectSection

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(LocalizedStringKey(section.title)).font(.system(size: 18, weight: .bold))
                Spacer()
                Button { Task { await connect.refresh(section) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh").disabled(connect.isLoading)
            }
            if connect.needsPermission {
                Text("Connect Queue and Devices to read your upcoming songs and switch Spotify Connect devices.")
                    .font(.callout).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Connect Queue and Devices") { Task { await connect.connect(section) } }
                    .disabled(connect.isLoading)
            }
            if connect.isLoading { ProgressView().controlSize(.small) }
            if let error = connect.error {
                Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
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
        .padding(20).frame(width: 390)
        .environment(\.locale, settings.locale)
        .task(id: section == .queue ? player.track?.uri : "devices") { await connect.refresh(section) }
    }

    private var queueContents: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current = connect.current {
                Text("Now playing").font(.caption).foregroundStyle(Theme.secondary)
                song(current)
            }
            Text("Up next").font(.caption).foregroundStyle(Theme.secondary)
            if connect.queue.isEmpty && !connect.isLoading {
                Text("No queued songs.").foregroundStyle(Theme.secondary)
            }
            Text("Only songs are shown.").font(.caption).foregroundStyle(Theme.tertiary)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(connect.queue.enumerated()), id: \.offset) { _, track in song(track) }
                }
            }.frame(maxHeight: 340)
        }
    }

    private var deviceContents: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(connect.devices, id: \.id) { device in
                Button { Task { await connect.transfer(device) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: device.type.lowercased() == "computer" ? "desktopcomputer" : (device.type.lowercased() == "smartphone" ? "iphone" : "hifispeaker"))
                        Text(device.name).lineLimit(1)
                        Spacer()
                        if device.isActive { Image(systemName: "checkmark.circle.fill") }
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain).disabled(device.isRestricted || connect.transferring || device.isActive)
                    .help(LocalizedStringKey(device.isRestricted ? "This device does not accept remote control." : "Switch playback to this device"))
            }
            if connect.devices.isEmpty && !connect.isLoading { Text("No devices found.").foregroundStyle(Theme.secondary) }
            Divider()
            Button("Play on Floe") { player.resume() }.disabled(!player.isConnected)
            Text("Floe volume").font(.caption).foregroundStyle(Theme.secondary)
            VolumeControl()
            Text("To change your Mac's audio output, use Control Center.")
                .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func song(_ track: Track) -> some View {
        HStack(spacing: 10) {
            ArtworkView(images: track.album?.images, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(track.artistLine).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer()
            Text(Format.duration(ms: Double(track.durationMs))).font(.caption).monospacedDigit().foregroundStyle(Theme.secondary)
        }
    }
}
