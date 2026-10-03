import Foundation
import Testing
@testable import HeyInky

/// Real end-to-end check through the local proxy and OpenAI. Opt-in because it costs money
/// and needs the proxy running:
///
///     (cd proxy && npm start) &
///     TEST_RUNNER_INKY_LIVE=1 xcodebuild test ... -only-testing:HeyInkyTests/LiveProxyIntegrationTests
@MainActor
@Suite("Live proxy (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["INKY_LIVE"] == "1"))
struct LiveProxyIntegrationTests {
    @Test(.timeLimit(.minutes(2)))
    func highlightTheTitleLandsOnTheTitle() async throws {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let (notebook, _) = try store.importPDF(from: SampleContent.writeSamplePDF(), title: "Sample")
        let editor = PageEditorModel(notebookID: notebook.id, page: notebook.pages[0], store: store)

        if let dump = ProcessInfo.processInfo.environment["INKY_DUMP_DIR"] {
            // Debug aid: write the exact request body for replaying with curl.
            let (image, lines) = await editor.snapshotForInky()
            let request = InkyRequest(question: "highlight the title of this page", images: InkyLocalization.modelImages(pageImage: image, lasso: nil),
                                      recognizedText: lines, lassoRegion: nil, pageAspectRatio: editor.page.width / editor.page.height, notebookTitle: "Sample")
            let body = try InkyPromptBuilder.bodyData(for: request)
            try body.write(to: URL(fileURLWithPath: dump).appendingPathComponent("inky_request.json"))
            try request.images[0].pngData.write(to: URL(fileURLWithPath: dump).appendingPathComponent("inky_page.png"))
        }
        let base = ProcessInfo.processInfo.environment["INKY_PROXY_URL"].flatMap(URL.init(string:)) ?? InkyConfig.defaultProxyURL
        let session = InkySession(client: ProxyInkyModelClient(baseURL: base, token: nil))
        session.summon(editor: editor)
        session.question = "highlight the title of this page"
        let started = Date()
        session.submit(editor: editor)
        while session.phase == .thinking {
            try await Task.sleep(for: .milliseconds(100))
        }
        let elapsed = Date().timeIntervalSince(started)
        print("Live Inky answered in \(String(format: "%.1f", elapsed)) s with \(editor.annotations.count) annotation(s)")
        for annotation in editor.annotations {
            print("Live action: \(String(data: try JSONEncoder().encode(annotation.action), encoding: .utf8) ?? "")")
        }
        print("Live toast: \(session.toast?.text ?? "-")")

        #expect(session.toast?.isError != true, "error: \(session.toast?.text ?? "")")
        let highlight = try #require(editor.annotations.compactMap { annotation -> HighlightAction? in
            if case .highlight(let h) = annotation.action { return h } else { return nil }
        }.first)
        let iou = highlight.region.intersectionOverUnion(SampleContent.titleRegion)
        print("Highlight \(InkyPromptBuilder.format(highlight.region)) vs title \(InkyPromptBuilder.format(SampleContent.titleRegion)) IoU \(iou)")
        #expect(iou > 0.5)
    }
}
