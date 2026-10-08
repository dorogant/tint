import SwiftUI

/// Recoverable errors remain visible above the player without covering the library.
/// A banner drops in from just above its place and leaves faster; `MainView`
/// springs the content below aside to make room (see `key`).
struct PlaybackStatusView: View {
    @Environment(PlayerModel.self) private var player
    @ReducedMotion private var still

    /// Which banner is up, so the window can animate the room it takes.
    static func key(_ player: PlayerModel) -> String? {
        if player.hasConnected && !player.isConnected { return "lost" }
        return player.lastError
    }

    var body: some View {
        if player.hasConnected && !player.isConnected {
            HStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                Text("Playback connection lost. Tint will try to reconnect.").font(.callout)
                Spacer()
                Button("Reconnect now") { player.reconnectPlayback() }
                Button("Sign in again") { player.logIn() }.disabled(player.session == .authorizing)
            }
            .padding(12).glassPanel(cornerRadius: 10).foregroundStyle(.orange)
            .transition(banner)
        } else if let error = player.lastError {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                Text(error).font(.callout)
                Spacer()
                Button("Next song") { player.next(); player.dismissError() }
                Button { player.dismissError() } label: { Image(systemName: "xmark") }
                    .help("Dismiss")
            }
            .padding(12).glassPanel(cornerRadius: 10).foregroundStyle(.orange)
            .transition(banner)
        }
    }

    /// In from 97% and 8 pt above with a little blur on a soft spring; out in
    /// about half the time. Reduce Motion keeps the fade.
    private var banner: AnyTransition {
        let dropped = AnyTransition.modifier(active: BannerPhase(shown: false, still: still),
                                             identity: BannerPhase(shown: true, still: still))
        return .asymmetric(insertion: dropped.animation(still ? FloeMotion.fade : FloeMotion.enter),
                           removal: dropped.animation(still ? FloeMotion.fade : FloeMotion.exit))
    }
}

private struct BannerPhase: ViewModifier {
    let shown: Bool
    let still: Bool

    func body(content: Content) -> some View {
        let moved = !shown && !still
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(moved ? 0.97 : 1, anchor: .top)
            .offset(y: moved ? -8 : 0)
            .blur(radius: moved ? 3 : 0)
    }
}
