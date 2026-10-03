import SwiftUI

@main
struct HeyInkyApp: App {
    @State private var app = AppModel.makeForLaunch()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(app)
                .tint(Theme.accent)
                // v1: paper is white and PencilKit inverts ink in dark mode; keep it calm and light.
                .preferredColorScheme(.light)
        }
    }
}

/// App-wide dependencies.
@MainActor
@Observable
final class AppModel {
    let store: NotebookStore
    let client: any InkyModelClient

    init(store: NotebookStore, client: any InkyModelClient) {
        self.store = store
        self.client = client
    }

    /// Launch arguments (see CLAUDE.md):
    ///   -InkyUITestReset YES   fresh temporary library seeded with the sample notebook
    ///   -InkyUseMockClient YES canned Inky responses, no network
    ///   -InkyProxyURL <url>    proxy location (default http://127.0.0.1:8787)
    static func makeForLaunch() -> AppModel {
        let defaults = UserDefaults.standard
        let store: NotebookStore
        if defaults.bool(forKey: "InkyUITestReset") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("UITest-\(UUID().uuidString)")
            store = NotebookStore(rootURL: root)
        } else {
            store = NotebookStore()
        }
        if store.notebooks.isEmpty, !defaults.bool(forKey: "InkySkipSample") {
            SampleContent.seed(into: store)
        }
        return AppModel(store: store, client: InkyClientFactory.makeDefault())
    }
}
