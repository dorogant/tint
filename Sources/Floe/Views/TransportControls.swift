import SwiftUI

/// Shared transport for the mini player and Now Playing.
struct TransportControls: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        HStack(spacing: 4) {
            IconButton(systemImage: "shuffle", size: 14, active: player.shuffle, help: "Shuffle") {
                player.toggleShuffle()
            }
            IconButton(systemImage: "backward.fill", size: 15, help: "Previous") { player.previous() }
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 42, height: 42)
                    .background(Theme.accent, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause" : "Play")
            IconButton(systemImage: "forward.fill", size: 15, help: "Next") { player.next() }
            IconButton(systemImage: player.repeatMode == .track ? "repeat.1" : "repeat", size: 14,
                       active: player.repeatMode != .off, help: "Repeat") {
                player.cycleRepeat()
            }
        }
    }

}
