import SwiftUI
import WebKit

/// Full-screen Ketcher (bundled, offline) for editing a card's structure. Calls `onFinish`
/// with the new SMILES on Done, or `nil` on Cancel.
struct KetcherEditorView: View {
    let smiles: String
    let onFinish: (String?) -> Void

    @State private var bridge = KetcherBridge()
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ZStack {
                KetcherWebView(bridge: bridge)
                    .ignoresSafeArea(edges: .bottom)
                if !bridge.isReady {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Opening the editor…")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.canvasBackground)
                }
            }
            .navigationTitle("Edit structure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinish(nil) }
                        .accessibilityIdentifier("inky.ketcher.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(!bridge.isReady || saving)
                        .accessibilityIdentifier("inky.ketcher.done")
                }
            }
            .alert("Can't use this structure", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("Keep editing", role: .cancel) { problem = nil }
            } message: {
                Text(problem ?? "")
            }
        }
        .tint(Theme.accent)
        .task { await bridge.open(smiles: smiles) }
        .accessibilityIdentifier("inky.ketcher")
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let edited = try await bridge.smiles().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !edited.isEmpty else {
                problem = "Draw a structure first, or tap Cancel to keep the original."
                return
            }
            // Make sure RDKit can read what Ketcher wrote before replacing the card's molecule.
            let check = try await MoleculeEngine.shared.analyze(smiles: edited)
            guard check.ok else {
                problem = check.error ?? "RDKit couldn't read the edited structure."
                return
            }
            onFinish(edited)
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Talks to Ketcher's `window.ketcher` through `ketcher-bridge.js`.
@MainActor
@Observable
final class KetcherBridge {
    var isReady = false
    private var webView: WKWebView?

    func makeWebView() -> WKWebView {
        if let webView { return webView }
        let config = ChemistryWebResources.configuration()
        if let url = ChemistryWebResources.root?.appendingPathComponent("ketcher-bridge.js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        view.isInspectable = true
        #endif
        view.load(URLRequest(url: ChemistryWebResources.url("ketcher/index.html")))
        webView = view
        return view
    }

    func open(smiles: String) async {
        let view = makeWebView()
        // Ketcher boots asynchronously (its Indigo WASM is inlined); `load` waits for it.
        for _ in 0..<600 where !isReady {
            if let ok = try? await view.callAsyncJavaScript("return window.inkyKetcher ? await window.inkyKetcher.load(smiles) : false;",
                                                         arguments: ["smiles": smiles], in: nil, contentWorld: .page) as? Bool, ok {
                isReady = true
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func smiles() async throws -> String {
        guard let webView else { return "" }
        return (try await webView.callAsyncJavaScript("return await window.inkyKetcher.smiles();", arguments: [:], in: nil, contentWorld: .page) as? String) ?? ""
    }
}

private struct KetcherWebView: UIViewRepresentable {
    let bridge: KetcherBridge

    func makeUIView(context: Context) -> WKWebView { bridge.makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
