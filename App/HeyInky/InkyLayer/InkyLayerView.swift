import SwiftUI

/// The Inky layer: annotations drawn above the user's ink. Hosted inside the zooming
/// canvas, sized to the page at the current zoom. Touches only reach it where
/// `PageEditorModel.overlayWantsTouch` says so; everywhere else they go to PencilKit.
struct InkyLayerView: View {
    @Bindable var editor: PageEditorModel
    @State private var editing: InkyAnnotation?
    @State private var editText = ""
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let pageSize = editor.page.size
            let scale = geo.size.width / pageSize.width
            ZStack(alignment: .topLeading) {
                if editor.selectedAnnotationID != nil || editor.selectedImageID != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editor.selectedAnnotationID = nil
                            editor.selectedImageID = nil
                        }
                }

                ForEach(editor.visibleAnnotations.filter { !editor.choreographer.isPending($0.id) }) { annotation in
                    let isSelected = editor.selectedAnnotationID == annotation.id
                    let rect = InkyAnnotationGeometry.bounds(for: annotation, pageSize: pageSize).cgRect(in: geo.size)
                    InkyRevealingAnnotationView(annotation: annotation, pageSize: pageSize, scale: scale, choreographer: editor.choreographer)
                        .environment(\.moleculeCardContext, moleculeCardContext(for: annotation, pageSize: pageSize, scale: scale))
                        .environment(\.graphCardHost, graphCardHost(for: annotation, pageSize: pageSize))
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                    .padding(-6)
                                    .allowsHitTesting(false)
                            }
                        }
                        .contentShape(Rectangle().inset(by: -InkyAnnotationGeometry.hitSlop * scale))
                        .position(x: rect.midX, y: rect.midY)
                        .offset(isSelected ? dragTranslation : .zero)
                        .onTapGesture {
                            editor.selectedImageID = nil
                            editor.selectedAnnotationID = isSelected ? nil : annotation.id
                        }
                        .gesture(isSelected ? moveGesture(annotation, viewSize: geo.size) : nil)
                        // Cards are interactive: keep their controls reachable (VoiceOver, UI tests).
                        .accessibilityElement(children: annotation.action.isCard ? .contain : .combine)
                        .accessibilityIdentifier("inky.annotation.\(annotation.action.type.rawValue)")
                        .accessibilityLabel(Self.accessibilityLabel(for: annotation.action))
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity)
                }

                InkyPerformerView(choreographer: editor.choreographer, pageSize: pageSize, viewSize: geo.size)

                if let id = editor.selectedAnnotationID, let annotation = editor.annotations.first(where: { $0.id == id }) {
                    let rect = InkyAnnotationGeometry.bounds(for: annotation, pageSize: pageSize).cgRect(in: geo.size)
                    selectionToolbar(for: annotation)
                        .position(x: min(max(rect.midX, 110), geo.size.width - 110), y: rect.minY > 60 ? rect.minY - 30 : rect.maxY + 30)
                        .offset(dragTranslation)
                }

                if let id = editor.selectedImageID, let image = editor.page.images.first(where: { $0.id == id }) {
                    ImageSelectionOverlay(editor: editor, image: image, viewSize: geo.size)
                }

                if editor.isSelectMode {
                    SelectionOverlay(editor: editor, viewSize: geo.size)
                }

                if let id = editor.editingTextBoxID, let box = editor.page.textBoxes.first(where: { $0.id == id }) {
                    TextBoxEditor(editor: editor, box: box, viewSize: geo.size, scale: scale)
                        .id(id)
                }
            }
        }
        .alert("Edit", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Text", text: $editText)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") {
                if let annotation = editing { editor.updateAnnotation(Self.replacingText(in: annotation, with: editText), undoable: true) }
                editing = nil
            }
        }
    }

    /// Lets a molecule card persist its edits (Ketcher, stars, highlight toggles) and resize itself.
    private func moleculeCardContext(for annotation: InkyAnnotation, pageSize: CGSize, scale: CGFloat) -> MoleculeCardContext {
        guard case .insertMoleculeCard = annotation.action else { return MoleculeCardContext(scale: scale) }
        let id = annotation.id
        return MoleculeCardContext(scale: scale, pageSize: pageSize, commit: { [editor] action in
            guard var current = editor.annotations.first(where: { $0.id == id }) else { return }
            current.action = .insertMoleculeCard(action)
            editor.updateAnnotation(current)
        })
    }

    /// Lets a graph card persist its edits, resize itself and flatten into an image.
    private func graphCardHost(for annotation: InkyAnnotation, pageSize: CGSize) -> GraphCardHost? {
        guard case .insertGraphCard = annotation.action else { return nil }
        let id = annotation.id
        return GraphCardHost(
            pageSize: pageSize,
            update: { [editor] action in
                guard var current = editor.annotations.first(where: { $0.id == id }) else { return }
                current.action = .insertGraphCard(action)
                editor.updateAnnotation(current)
            },
            flatten: { [editor] image in editor.replaceAnnotationWithImage(id, image: image) }
        )
    }

    private func moveGesture(_ annotation: InkyAnnotation, viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragTranslation) { value, state, _ in state = value.translation }
            .onEnded { value in
                editor.moveAnnotation(annotation.id, by: NormPoint(
                    x: value.translation.width / viewSize.width,
                    y: value.translation.height / viewSize.height
                ))
            }
    }

    private func selectionToolbar(for annotation: InkyAnnotation) -> some View {
        HStack(spacing: 2) {
            if let text = Self.editableText(of: annotation.action) {
                toolbarButton("Edit", systemImage: "pencil", id: "inky.selection.edit") {
                    editText = text
                    editing = annotation
                }
            }
            toolbarButton("Hide", systemImage: "eye.slash", id: "inky.selection.hide") {
                editor.setHidden(annotation.id, true)
            }
            toolbarButton("Delete", systemImage: "trash", id: "inky.selection.delete") {
                editor.deleteAnnotation(annotation.id)
            }
        }
        .padding(4)
        .inkySurface(cornerRadius: 12)
    }

    private func toolbarButton(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(title == "Delete" ? Color.red : Color.primary)
        .accessibilityIdentifier(id)
    }

    static func editableText(of action: InkyAction) -> String? {
        switch action {
        case .label(let a): a.text
        case .fillText(let a): a.text
        case .highlight(let a): a.note ?? ""
        case .insertMoleculeCard(let a): a.caption ?? ""
        default: nil
        }
    }

    static func replacingText(in annotation: InkyAnnotation, with text: String) -> InkyAnnotation {
        var copy = annotation
        switch annotation.action {
        case .label(var a): a.text = text; copy.action = .label(a)
        case .fillText(var a): a.text = text; copy.action = .fillText(a)
        case .highlight(var a): a.note = text.isEmpty ? nil : text; copy.action = .highlight(a)
        case .insertMoleculeCard(var a): a.caption = text.isEmpty ? nil : text; copy.action = .insertMoleculeCard(a)
        default: break
        }
        return copy
    }

    static func accessibilityLabel(for action: InkyAction) -> String {
        switch action {
        case .highlight(let a): "Inky highlight\(a.note.map { ": \($0)" } ?? "")"
        case .circle: "Inky circle"
        case .star: "Inky star"
        case .label(let a): "Inky label: \(a.text)"
        case .fillText(let a): "Inky text: \(a.text)"
        case .insertMoleculeCard(let a): "Molecule card \(a.caption ?? a.smiles)"
        case .insertGraphCard(let a): "Graph card \(a.spec.title ?? "")"
        case .draw(let a):
            "Inky drawing" + (a.caption.map { ": \($0)" } ?? "")
                + { let t = a.shapes.compactMap { $0.kind == .text ? $0.text : nil }; return t.isEmpty ? "" : " — " + t.joined(separator: ", ") }()
        case .addPage, .openSidebar, .say: ""
        }
    }
}

/// Picks the renderer for an annotation. The view fills the annotation's bounds.
/// `progress` < 1 while Inky is drawing it (stroke-reveal).
struct InkyAnnotationView: View {
    let annotation: InkyAnnotation
    let pageSize: CGSize
    let scale: CGFloat
    var progress: CGFloat = 1

    /// The note tag's spot (`InkyLayout`) relative to the highlight, in view points.
    private func noteOffset(_ a: HighlightAction) -> CGPoint? {
        let candidates = InkyLayout.noteCandidates(a, pageSize: pageSize)
        guard let note = candidates[safe: annotation.labelPlacement ?? 0] ?? candidates.first else { return nil }
        return CGPoint(x: (note.x - a.region.x) * pageSize.width * scale, y: (note.y - a.region.y) * pageSize.height * scale)
    }

    var body: some View {
        switch annotation.action {
        case .highlight(let a):
            HighlightMark(action: a, scale: scale, progress: progress, noteOffset: noteOffset(a))
        case .circle(let a):
            CircleMark(action: a, scale: scale, seed: CircleMark.seed(for: annotation.id), progress: progress)
        case .star:
            StarMark(progress: progress)
        case .label(let a):
            let placement = annotation.labelPlacement ?? 0
            LabelMark(action: a, pageSize: pageSize, placement: placement,
                      bounds: InkyAnnotationGeometry.baseBounds(for: annotation.action, pageSize: pageSize, labelPlacement: placement),
                      scale: scale, progress: progress)
        case .fillText(let a):
            FillTextMark(action: a, scale: scale, progress: progress)
        case .insertMoleculeCard(let a):
            InkyCardContainer(title: a.caption ?? "Molecule", systemImage: "atom", scale: scale) {
                MoleculeCardView(action: a)
            }
            .cardReveal(progress)
        case .insertGraphCard(let a):
            InkyCardContainer(title: a.spec.title ?? "Graph", systemImage: "chart.xyaxis.line", scale: scale) {
                GraphCardView(action: a)
            }
            .cardReveal(progress)
        case .draw(let a):
            DrawMark(action: a, seed: CircleMark.seed(for: annotation.id), pageSize: pageSize, scale: scale, progress: progress)
        case .addPage, .openSidebar, .say:
            EmptyView()
        }
    }
}

/// An annotation on the layer. While Inky is drawing it, re-renders every frame with the
/// choreographer's progress; otherwise renders once, fully drawn.
struct InkyRevealingAnnotationView: View {
    let annotation: InkyAnnotation
    let pageSize: CGSize
    let scale: CGFloat
    let choreographer: InkyChoreographer

    var body: some View {
        // One structure whether or not Inky is drawing it (a paused timeline), so a card's web
        // view / engine task isn't torn down and rebuilt when the reveal finishes.
        let drawing = choreographer.isDrawing(annotation.id)
        TimelineView(.animation(paused: !drawing)) { timeline in
            InkyAnnotationView(annotation: annotation, pageSize: pageSize, scale: scale,
                               progress: drawing ? choreographer.drawProgress(at: timeline.date) : 1)
        }
    }
}

/// Move / resize / delete for a placed image.
struct ImageSelectionOverlay: View {
    let editor: PageEditorModel
    let image: PlacedImage
    let viewSize: CGSize
    @GestureState private var move: CGSize = .zero
    @GestureState private var resize: CGSize = .zero

    var body: some View {
        let base = image.frame.cgRect(in: viewSize)
        let aspect = base.width / max(base.height, 1)
        let grownWidth = max(40, base.width + max(resize.width, resize.height * aspect))
        let rect = CGRect(x: base.minX + move.width, y: base.minY + move.height, width: grownWidth, height: grownWidth / aspect)

        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Theme.accent, lineWidth: 1.5)
                .contentShape(Rectangle())
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .gesture(
                    DragGesture()
                        .updating($move) { v, s, _ in s = v.translation }
                        .onEnded { v in commit(dx: v.translation.width, dy: v.translation.height, grow: 0) }
                )
                .accessibilityIdentifier("page.image.selection")

            Circle()
                .fill(Theme.accent)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .offset(x: rect.maxX - 11, y: rect.maxY - 11)
                .gesture(
                    DragGesture()
                        .updating($resize) { v, s, _ in s = v.translation }
                        .onEnded { v in commit(dx: 0, dy: 0, grow: max(v.translation.width, v.translation.height * aspect)) }
                )

            HStack(spacing: 2) {
                Button(role: .destructive) { editor.deleteImage(image.id) } label: {
                    Label("Delete", systemImage: "trash").padding(.horizontal, 10).padding(.vertical, 6)
                }
                .accessibilityIdentifier("page.image.delete")
                Button { editor.selectedImageID = nil } label: {
                    Text("Done").fontWeight(.semibold).padding(.horizontal, 10).padding(.vertical, 6)
                }
                .accessibilityIdentifier("page.image.done")
            }
            .font(.system(size: 13, design: .rounded))
            .buttonStyle(.plain)
            .padding(4)
            .inkySurface(cornerRadius: 12)
            .fixedSize()
            .offset(x: max(0, rect.minX), y: max(0, rect.minY - 44))
        }
    }

    private func commit(dx: CGFloat, dy: CGFloat, grow: CGFloat) {
        var updated = image
        let base = image.frame.cgRect(in: viewSize)
        let aspect = base.width / max(base.height, 1)
        let width = max(40, base.width + grow)
        let rect = CGRect(x: base.minX + dx, y: base.minY + dy, width: width, height: width / aspect)
        updated.frame = NormRect(rect, in: viewSize)
        editor.updateImage(updated)
    }
}

/// The Select tool on the page: dashed box (drag to move), corner handle (drag to resize),
/// and a toolbar — Ask Inky, Copy, Cut, Duplicate, Delete. With nothing selected, a tap on
/// empty paper offers Paste there.
struct SelectionOverlay: View {
    let editor: PageEditorModel
    let viewSize: CGSize
    @State private var converting = false
    @State private var conversionFailed = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let selection = editor.selection {
                let rect = selection.bounds.cgRect(in: viewSize).insetBy(dx: -8, dy: -8)
                box(rect)
                handle(rect)
                toolbar
                    .fixedSize()
                    .position(x: min(max(rect.midX, 190), viewSize.width - 190),
                              y: rect.minY > 56 ? rect.minY - 30 : rect.maxY + 30)
            } else if let anchor = editor.pasteAnchor {
                let p = anchor.cgPoint(in: viewSize)
                Button { editor.paste(at: anchor) } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("select.paste")
                    .padding(4)
                    .inkySurface(cornerRadius: 12)
                    .fixedSize()
                    .position(x: p.x + 50, y: max(24, p.y - 30))
            }
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
        .alert("Couldn't read that handwriting", isPresented: $conversionFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try selecting just the writing, or write a little larger.")
        }
    }

    private func box(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent.opacity(0.05)))
            .contentShape(Rectangle())
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        editor.beginSelectionTransform()
                        editor.updateSelectionTransform(translation: normalized(value.translation), scale: 1)
                    }
                    .onEnded { _ in editor.endSelectionTransform() }
            )
            .accessibilityElement()
            .accessibilityLabel("Selection")
            .accessibilityIdentifier("select.box")
    }

    /// Bottom-right corner: uniform scale about the top-left corner.
    private func handle(_ rect: CGRect) -> some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .padding(10)
            .contentShape(Rectangle())
            .position(x: rect.maxX, y: rect.maxY)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        editor.beginSelectionTransform()
                        let w = max(rect.width, 1), h = max(rect.height, 1)
                        // Project the drag onto the box's diagonal so the corner follows the finger.
                        let scale = 1 + (value.translation.width * w + value.translation.height * h) / (w * w + h * h)
                        editor.updateSelectionTransform(translation: NormPoint(x: 0, y: 0), scale: max(0.15, scale))
                    }
                    .onEnded { _ in editor.endSelectionTransform() }
            )
            .accessibilityLabel("Resize")
            .accessibilityIdentifier("select.resize")
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Button {
                editor.lassoSelectionForInky()
                editor.onAskInkyAboutSelection?()
            } label: {
                Label("Ask Inky", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("select.askInky")
            if !(editor.selection?.strokeIndices.isEmpty ?? true) {
                Button {
                    converting = true
                    Task {
                        let ok = await editor.convertSelectedInkToText()
                        converting = false
                        if !ok { conversionFailed = true }
                    }
                } label: {
                    Group {
                        if converting { ProgressView().controlSize(.small) } else { Image(systemName: "character.cursor.ibeam") }
                    }
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(converting)
                .accessibilityLabel("Convert to Text")
                .accessibilityIdentifier("select.convertToText")
            }
            if editor.selectedDrawingCount > 0 {
                button("Make it my ink", "scribble", id: "select.makeInk") { editor.convertSelectedDrawingsToInk() }
            }
            button("Copy", "doc.on.doc", id: "select.copy") { editor.copySelection() }
            button("Cut", "scissors", id: "select.cut") { editor.cutSelection() }
            button("Duplicate", "plus.square.on.square", id: "select.duplicate") { editor.duplicateSelection() }
            button("Delete", "trash", id: "select.delete", role: .destructive) { editor.deleteSelection() }
        }
        .padding(4)
        .inkySurface(cornerRadius: 12)
    }

    private func button(_ title: String, _ systemImage: String, id: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    private func normalized(_ translation: CGSize) -> NormPoint {
        NormPoint(x: translation.width / max(viewSize.width, 1), y: translation.height / max(viewSize.height, 1))
    }
}

/// Typing into a text box on the page: the text sits exactly where it will be drawn, with a
/// small formatting bar above (size, typed/handwriting, color, delete, done).
struct TextBoxEditor: View {
    let editor: PageEditorModel
    let box: PageTextBox
    let viewSize: CGSize
    let scale: CGFloat
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let rect = box.frame.cgRect(in: viewSize)
        ZStack(alignment: .topLeading) {
            TextField("Type here", text: $text, axis: .vertical)
                .font(Font(PageRenderer.font(for: box, scale: scale)))
                .foregroundStyle(Color(PageRenderer.uiColor(box.color)))
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(width: rect.width, alignment: .topLeading)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .offset(x: rect.minX - 4, y: rect.minY - 4)
                .accessibilityIdentifier("text.editor")
                .onChange(of: text) { _, new in
                    var updated = box
                    updated.text = new
                    editor.updateTextBox(updated)
                }

            formatBar
                .fixedSize()
                .offset(x: min(max(rect.minX - 4, 4), max(4, viewSize.width - 360)), y: max(4, rect.minY - 52))
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
        .onAppear {
            text = box.text
            focused = true
        }
    }

    private var formatBar: some View {
        HStack(spacing: 2) {
            barButton("Smaller", "textformat.size.smaller", id: "text.smaller") { change { $0.fontSize = max(10, $0.fontSize - 2) } }
            barButton("Larger", "textformat.size.larger", id: "text.larger") { change { $0.fontSize = min(72, $0.fontSize + 2) } }
            barButton(box.style == .typed ? "Handwriting style" : "Typed style",
                      box.style == .typed ? "pencil.and.scribble" : "textformat", id: "text.style") {
                change { $0.style = $0.style == .typed ? .handwriting : .typed }
            }
            ForEach(PageTextBox.Color.allCases, id: \.self) { color in
                Button { change { $0.color = color } } label: {
                    Circle()
                        .fill(Color(PageRenderer.uiColor(color)))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.primary.opacity(box.color == color ? 0.6 : 0), lineWidth: 2).padding(-3))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.rawValue.capitalized)
                .accessibilityIdentifier("text.color.\(color.rawValue)")
            }
            barButton("Delete", "trash", id: "text.delete", destructive: true) { editor.deleteTextBox(box.id) }
            Button("Done") { editor.endTextEditing() }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .accessibilityIdentifier("text.done")
        }
        .padding(4)
        .inkySurface(cornerRadius: 12)
    }

    private func change(_ edit: (inout PageTextBox) -> Void) {
        var updated = editor.page.textBoxes.first { $0.id == box.id } ?? box
        edit(&updated)
        editor.updateTextBox(updated)
    }

    private func barButton(_ title: String, _ symbol: String, id: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? Color.red : Color.primary)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}
