import SwiftUI

@main
struct FloeApp: App {
    @ViewState private var model = PlayerModel()

    var body: some Scene {
        Window("Floe", id: "main") {
            PlayerView(model: model)
                .task {
                    await model.restoreSession()
                    if SelfTest.isEnabled { await SelfTest.run(model) }
                }
        }
        .windowResizability(.contentSize)
    }
}
