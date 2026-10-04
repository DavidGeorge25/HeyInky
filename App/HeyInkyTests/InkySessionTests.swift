import Testing
import UIKit
@testable import HeyInky

@MainActor
@Suite("Inky session and localization")
struct InkySessionTests {
    func makeEditor() throws -> PageEditorModel {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let url = try SampleContent.writeSamplePDF()
        let (notebook, _) = try store.importPDF(from: url, title: "Sample")
        return PageEditorModel(notebookID: notebook.id, page: notebook.pages[0], store: store)
    }

    @Test func appliesAnnotationsToastAndSidebar() async throws {
        let editor = try makeEditor()
        let actions = try Fixtures.response("all_actions").actions
        let session = InkySession(client: MockInkyModelClient(delay: .zero, fixedActions: actions))
        session.summon(editor: editor)
        #expect(editor.isInkyMode)

        await session.run(Fixtures.sampleRequest(), editor: editor)
        #expect(session.phase == .idle)
        #expect(!editor.isInkyMode)
        #expect(session.appliedActionCount == 11)
        #expect(editor.annotations.count == 8, "7 marks + the drawing; addPage is not a mark")
        #expect(session.toast?.text == "Highlighted the title.")
        #expect(session.sidebar?.speakable == true)

        // Persisted.
        #expect(editor.store.annotations(for: editor.page.id, in: editor.notebookID).count == 8)
    }

    @Test func errorsKeepTheQuestionAndShowAToast() async throws {
        struct FailingClient: InkyModelClient {
            func respond(to request: InkyRequest) -> AsyncThrowingStream<InkyStreamEvent, Error> {
                AsyncThrowingStream { $0.finish(throwing: InkyClientError.network("offline")) }
            }
        }
        let editor = try makeEditor()
        let session = InkySession(client: FailingClient())
        session.summon(editor: editor)
        session.question = "highlight the title"
        await session.run(Fixtures.sampleRequest(), editor: editor)
        #expect(session.phase == .composing)
        #expect(session.question == "highlight the title")
        #expect(session.toast?.isError == true)
    }

    @Test func snapshotIncludesPDFTextWithAccurateBoxes() async throws {
        let editor = try makeEditor()
        let (image, lines) = await editor.snapshotForInky()
        #expect(abs(image.size.width / image.size.height - editor.page.width / editor.page.height) < 0.01)
        let title = try #require(lines.first { $0.text.contains("Lecture 7") })
        #expect(title.box.intersectionOverUnion(SampleContent.titleRegion) > 0.5)
    }

    @Test func localizationProducesGridImagesAndCrop() async throws {
        let editor = try makeEditor()
        let (image, _) = await editor.snapshotForInky()
        let full = InkyLocalization.modelImages(pageImage: image, lasso: nil)
        #expect(full.count == 1)
        let decoded = try #require(UIImage(data: full[0].pngData))
        #expect(max(decoded.size.width, decoded.size.height) == InkyLocalization.tuning.fullPageLongEdge)

        // Grid line at x = 0.5 is drawn in blue-ish over white paper, low on the page.
        let gridX = decoded.size.width * 0.5
        let p = decoded.pixel(at: CGPoint(x: gridX, y: decoded.size.height * 0.95))
        #expect(p.b > p.r + 0.05, "grid line tinted blue")

        let withLasso = InkyLocalization.modelImages(pageImage: image, lasso: NormRect(x: 0.1, y: 0.05, width: 0.5, height: 0.08))
        #expect(withLasso.count == 2)
        #expect(withLasso[1].caption.contains("lasso"))
    }

    @Test func lassoPathBecomesRegion() throws {
        let editor = try makeEditor()
        editor.setLasso(path: [NormPoint(x: 0.2, y: 0.3), NormPoint(x: 0.6, y: 0.25), NormPoint(x: 0.5, y: 0.5), NormPoint(x: 0.15, y: 0.45)])
        let region = try #require(editor.lassoRegion)
        #expect(abs(region.x - 0.15) < 1e-9 && abs(region.y - 0.25) < 1e-9)
        #expect(abs(region.maxX - 0.6) < 1e-9 && abs(region.maxY - 0.5) < 1e-9)
        editor.clearLasso()
        #expect(editor.lassoRegion == nil)
    }

    @Test func markdownBlocksAndPlainText() {
        let md = "# Title\n\nSome **bold** text\nwrapped.\n\n- one\n- two\n1. first\n```\ncode\n```"
        let blocks = MarkdownText.blocks(md)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text wrapped."),
            .bullet("one"), .bullet("two"),
            .numbered(index: "1", text: "first"),
            .code("code"),
        ])
        #expect(!MarkdownText.plainText(md).contains("**"))
    }
}
