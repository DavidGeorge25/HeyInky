import Foundation
import Testing
@testable import HeyInky

/// The toolbar's Undo/Redo cover Inky's marks: a whole Inky turn is one step, and so is each
/// delete / hide / move / clear from the Inky layer.
@MainActor
@Suite("Inky annotation undo")
struct AnnotationUndoTests {
    func makeEditor() -> PageEditorModel {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "Undo", paper: .blank)
        return PageEditorModel(notebookID: notebook.id, page: notebook.pages[0], store: store)
    }

    /// UndoManager groups registrations per run-loop event; let the current event end.
    func endEvent() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    let highlight = InkyAction.highlight(HighlightAction(region: NormRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05), color: .yellow, note: nil))
    let star = InkyAction.star(StarAction(point: NormPoint(x: 0.5, y: 0.5)))

    @Test func anInkyTurnUndoesAndRedoesAsOneStep() async {
        let editor = makeEditor()
        let session = InkySession(client: MockInkyModelClient(delay: .zero, fixedActions: [.say(SayAction(text: "Done.")), highlight, star]))
        await session.run(Fixtures.sampleRequest(), editor: editor)
        endEvent()
        #expect(editor.annotations.count == 2)
        #expect(editor.undoManager.undoActionName == "Inky")

        editor.undo()
        #expect(editor.annotations.isEmpty)
        #expect(editor.store.annotations(for: editor.page.id, in: editor.notebookID).isEmpty, "undo is persisted")
        endEvent()
        editor.redo()
        #expect(editor.annotations.map(\.action) == [highlight, star])
    }

    @Test func deleteHideMoveAndClearAreEachUndoable() {
        let editor = makeEditor()
        editor.addAnnotation(highlight, question: nil)
        editor.addAnnotation(star, question: nil)
        let first = editor.annotations[0].id, second = editor.annotations[1].id

        editor.deleteAnnotation(first); endEvent()
        editor.setHidden(second, true); endEvent()
        editor.moveAnnotation(second, by: NormPoint(x: 0.1, y: 0)); endEvent()
        #expect(editor.annotations.map(\.id) == [second])

        editor.undo(); endEvent()
        #expect(editor.annotations[0].offset == NormPoint(x: 0, y: 0))
        editor.undo(); endEvent()
        #expect(editor.annotations[0].isHidden == false)
        editor.undo(); endEvent()
        #expect(editor.annotations.map(\.id) == [first, second], "deleted mark is back, in place")

        editor.clearAnnotations(); endEvent()
        #expect(editor.annotations.isEmpty)
        editor.undo()
        #expect(editor.annotations.count == 2)
    }

    @Test func cardEditsDontFloodTheUndoStack() {
        let editor = makeEditor()
        editor.addAnnotation(highlight, question: nil)
        var edited = editor.annotations[0]
        edited.question = "slider moved"
        editor.updateAnnotation(edited)
        #expect(!editor.undoManager.canUndo)
    }
}
