import AppCore
import SwiftUI

@main
struct BlockworkApp: App {
    @State private var app = AppModel()
    private let store = ProjectStore(directory: ProjectStore.defaultDirectory())

    var body: some Scene {
        WindowGroup {
            HomeView(store: store)
                .environment(app)
                .preferredColorScheme(.dark)
        }
    }
}
