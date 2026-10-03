import Foundation
import Testing
@testable import HeyInky

@MainActor
@Suite("Inky follow-ups")
struct InkySessionFollowUpTests {
    @Test func undoRemovesTheLastTurnsMarksAndSendsContext() async throws {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "Follow-ups", paper: .blank)
        let editor = PageEditorModel(notebookID: notebook.id, page: notebook.pages[0], store: store)
        let highlight = InkyAction.highlight(HighlightAction(region: NormRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05), color: .yellow, note: nil))
        let client = ScriptedClient([
            ScriptedClient.answer([.say(SayAction(text: "Highlighted.")), highlight]),
            ScriptedClient.answer([.say(SayAction(text: "Removed it."))], remove: ["m1"]),
        ])
        let session = InkySession(client: ValidatingInkyModelClient(base: client))

        for question in ["highlight the title", "undo that"] {
            session.summon(editor: editor)
            session.question = question
            session.submit(editor: editor)
            while session.phase == .thinking { try await Task.sleep(for: .milliseconds(20)) }
        }

        #expect(editor.annotations.isEmpty)
        let second = try #require(client.requests.last)
        #expect(second.pageAnnotations.count == 1)
        #expect(second.history.map(\.question) == ["highlight the title"])
        #expect(second.history.first?.createdAnnotationIDs == second.pageAnnotations.map(\.id))
        #expect(session.toast?.text == "Removed it.")
    }
}
