import Foundation
import Observation
import UIKit

/// Drives one conversation turn with Inky: summon -> (lasso) -> ask -> think -> act.
@MainActor
@Observable
final class InkySession {
    enum Phase: Equatable {
        case idle
        case composing
        case thinking
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    struct SidebarContent: Identifiable, Equatable {
        let id = UUID()
        var markdown: String
        var speakable: Bool
        var question: String
    }

    private(set) var phase: Phase = .idle
    var question = ""
    /// Where to show the ask popover (page-area coordinates); nil = default corner.
    private(set) var anchor: CGPoint?
    private(set) var toast: Toast?
    var sidebar: SidebarContent?
    /// Number of actions applied in the current/last turn (for tests and status).
    private(set) var appliedActionCount = 0

    let client: any InkyModelClient
    let speechInput = SpeechInput()
    let speechOutput = SpeechOutput()
    var notebookTitle: String?
    /// Follow-up memory per page ("now explain why", "undo that").
    let conversation = InkyConversation()
    /// Set by the notebook: adds a page after the current one, shows it, returns its editor.
    @ObservationIgnored var onAddPage: ((AddPageAction.Paper) -> PageEditorModel?)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(client: any InkyModelClient) {
        self.client = client
    }

    var characterState: InkyCharacterState {
        switch phase {
        case .thinking: .thinking
        case .composing: speechInput.isListening ? .listening : .idle
        case .idle: speechOutput.isSpeaking ? .speaking : .idle
        }
    }

    /// `characterState`, but `.writing` while Inky is out drawing on this page (and not listening/thinking).
    func characterState(on editor: PageEditorModel?) -> InkyCharacterState {
        let state = characterState
        guard state == .idle, editor?.choreographer.isOnStage == true else { return state }
        return .writing
    }

    // MARK: Flow

    func summon(editor: PageEditorModel, anchor: CGPoint? = nil) {
        guard phase != .thinking else { return }
        self.anchor = anchor
        editor.selectedAnnotationID = nil
        editor.selectedImageID = nil
        editor.isInkyMode = true
        phase = .composing
        InkyFeedback.play(.summon)
    }

    func dismiss(editor: PageEditorModel?) {
        task?.cancel()
        task = nil
        speechInput.stop()
        phase = .idle
        editor?.isInkyMode = false
        editor?.clearLasso()
    }

    func toggleListening() {
        if speechInput.isListening {
            speechInput.stop()
        } else {
            speechInput.start { [weak self] text in
                self?.question = text
            }
        }
    }

    func submit(editor: PageEditorModel) {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, phase == .composing else { return }
        speechInput.stop()
        phase = .thinking
        appliedActionCount = 0
        InkyFeedback.play(.send)

        task = Task { [weak self] in
            guard let self else { return }
            let (image, lines) = await editor.snapshotForInky()
            let skeleton = InkSkeleton.paths(in: editor.drawing, pageSize: editor.page.size, handwriting: lines.map(\.box))
            let request = await InkyContextBuilder.makeRequest(
                question: asked,
                pageImage: image,
                recognizedText: lines,
                lassoRegion: editor.lassoRegion,
                lassoPath: editor.lassoPath,
                pageAspectRatio: editor.page.width / editor.page.height,
                notebookTitle: notebookTitle,
                annotations: editor.annotations.map { annotation in
                    InkyPageAnnotation(
                        id: annotation.id, action: annotation.action,
                        bounds: InkyAnnotationGeometry.bounds(for: annotation, pageSize: editor.page.size),
                        isHidden: annotation.isHidden, question: annotation.question
                    )
                },
                history: conversation.history(for: editor.page.id),
                inkPaths: skeleton,
                inkAtoms: BondLayout.atoms(skeleton: skeleton, pageSize: editor.page.size)
            )
            await self.run(request, editor: editor)
        }
    }

    /// Streams the response and applies actions as they arrive. An `addPage` moves the rest of
    /// the answer onto a new page (`onAddPage`).
    func run(_ request: InkyRequest, editor: PageEditorModel) async {
        var applied = 0
        var actions: [InkyAction] = []
        var removed: [UUID] = []
        let snapshot = editor.annotations
        let before = Set(snapshot.map(\.id))
        /// Where actions go now (changes after `addPage`).
        var target = editor
        // One undo step per Inky turn (all of its marks and removals), however it ends.
        defer {
            editor.registerAnnotationUndo(restoring: snapshot, actionName: "Inky")
            if target !== editor { target.registerAnnotationUndo(restoring: [], actionName: "Inky") }
        }
        func handle(_ action: InkyAction) async {
            if case .addPage(let page) = action, let next = onAddPage?(page.paper) {
                target = next
                // Let the new page come on screen so Inky can perform there.
                try? await Task.sleep(for: .milliseconds(450))
            } else {
                apply(action, editor: target, question: request.question)
            }
            actions.append(action)
            applied += 1
        }
        do {
            for try await event in client.respond(to: request) {
                switch event {
                case .action(let action):
                    await handle(action)
                case .completed(let response):
                    for action in response.actions.dropFirst(applied) { await handle(action) }
                    removed = response.removedAnnotationIDs
                    for id in removed { editor.deleteAnnotation(id, undoable: false) }
                case .textDelta:
                    break
                }
            }
            appliedActionCount = applied
            conversation.record(InkyTurn(
                question: request.question, actions: actions,
                createdAnnotationIDs: editor.annotations.map(\.id).filter { !before.contains($0) },
                removedAnnotationIDs: removed
            ), pageID: editor.page.id)
            if applied == 0 && removed.isEmpty { showToast("Inky had nothing to add.", isError: false) }
            question = ""
            phase = .idle
            editor.isInkyMode = false
            editor.clearLasso()
        } catch InkyClientError.cancelled {
            // dismissed by the user
        } catch {
            guard !Task.isCancelled else { return }
            appliedActionCount = applied
            phase = .composing
            InkyFeedback.play(.error)
            showToast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, isError: true)
        }
    }

    func apply(_ action: InkyAction, editor: PageEditorModel, question: String?) {
        switch action {
        case .say(let say):
            // Inky replies once it has finished drawing on the page.
            editor.choreographer.afterPerformance { [weak self] in self?.showToast(say.text, isError: false) }
        case .openSidebar(let sidebar):
            self.sidebar = SidebarContent(markdown: sidebar.markdown, speakable: sidebar.speakable, question: question ?? "")
        case .addPage:
            break  // handled in `run` (needs the notebook)
        default:
            editor.showsInkyLayer = true
            let count = editor.annotations.count
            editor.addAnnotation(action, question: question)
            // (The editor may adjust the action, e.g. move a drawing's writing off other text.)
            if editor.annotations.count > count, let added = editor.annotations.last {
                editor.choreographer.perform(added, pageSize: editor.page.size)
            }
        }
    }

    func showToast(_ text: String, isError: Bool) {
        toast = Toast(text: text, isError: isError)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 6 : 4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }
}
