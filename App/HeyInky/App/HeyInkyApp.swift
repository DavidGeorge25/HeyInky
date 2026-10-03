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
    ///   (DEBUG) -InkyUITestLibrary / -InkyUITestScenario / -InkyUITestImage: see `UITestScenarios`
    static func makeForLaunch() -> AppModel {
        let defaults = UserDefaults.standard
        let store = testLibraryRoot(defaults).map { NotebookStore(rootURL: $0) } ?? NotebookStore()
        if store.notebooks.isEmpty, !defaults.bool(forKey: "InkySkipSample") {
            SampleContent.seed(into: store)
        }
        #if DEBUG
        if let scenarios = defaults.string(forKey: "InkyUITestScenario") {
            UITestScenarios.seed(scenarios, into: store, imagePath: defaults.string(forKey: "InkyUITestImage"))
        }
        #endif
        return AppModel(store: store, client: InkyClientFactory.makeDefault())
    }

    /// A temporary library for UI tests (nil = the real one).
    private static func testLibraryRoot(_ defaults: UserDefaults) -> URL? {
        let reset = defaults.bool(forKey: "InkyUITestReset")
        #if DEBUG
        if let name = defaults.string(forKey: "InkyUITestLibrary"), !name.isEmpty {
            return UITestScenarios.libraryRoot(named: name, reset: reset)
        }
        #endif
        return reset ? FileManager.default.temporaryDirectory.appendingPathComponent("UITest-\(UUID().uuidString)") : nil
    }
}
