import SwiftUI

/// Recoverable errors remain visible above the player without covering the library.
struct PlaybackStatusView: View {
    @Environment(PlayerModel.self) private var player
    var body: some View {
        if player.hasConnected && !player.isConnected {
            HStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                Text("Playback connection lost. Floe will try to reconnect.").font(.callout)
                Spacer()
                Button("Reconnect now") { player.reconnectPlayback() }
                Button("Sign in again") { player.logIn() }.disabled(player.session == .authorizing)
            }.padding(12).glassPanel(cornerRadius: 10).foregroundStyle(.orange)
        } else if let error = player.lastError {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                Text(error).font(.callout)
                Spacer()
                Button("Next song") { player.next(); player.dismissError() }
                Button { player.dismissError() } label: { Image(systemName: "xmark") }
                    .help("Dismiss")
            }.padding(12).glassPanel(cornerRadius: 10).foregroundStyle(.orange)
        }
    }
}
