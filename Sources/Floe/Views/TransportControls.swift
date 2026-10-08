import SwiftUI

/// Shared transport for the mini player and Now Playing.
struct TransportControls: View {
    @Environment(\.coverPalette) private var palette
    var playSize: CGFloat = 42
    @Environment(PlayerModel.self) private var player

    var body: some View {
        HStack(spacing: 4) {
            IconButton(systemImage: "shuffle", size: 14, active: player.shuffle, help: "Shuffle") {
                player.toggleShuffle()
            }
            IconButton(systemImage: "backward.fill", size: 15, help: "Previous") { player.previous() }
            Button(action: player.togglePlayPause) {
                Group {
                    if player.isLoading {
                        ProgressView().controlSize(.small).tint(palette.onAccent)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                    .font(.system(size: playSize * 0.4, weight: .bold))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: playSize, height: playSize)
                    .background(palette.accent, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(player.isPlaying || player.isLoading ? "Pause" : "Play")
            IconButton(systemImage: "forward.fill", size: 15, help: "Next") { player.next() }
            IconButton(systemImage: player.repeatMode == .track ? "repeat.1" : "repeat", size: 14,
                       active: player.repeatMode != .off, help: "Repeat") {
                player.cycleRepeat()
            }
        }
    }
}
