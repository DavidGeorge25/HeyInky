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
            }
        }
        .alert("Edit", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Text", text: $editText)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") {
                if let annotation = editing { editor.updateAnnotation(Self.replacingText(in: annotation, with: editText)) }
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
        case .openSidebar, .say: ""
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

    var body: some View {
        switch annotation.action {
        case .highlight(let a):
            HighlightMark(action: a, scale: scale, progress: progress)
        case .circle(let a):
            CircleMark(action: a, scale: scale, seed: CircleMark.seed(for: annotation.id), progress: progress)
        case .star:
            StarMark(progress: progress)
        case .label(let a):
            LabelMark(action: a, pageSize: pageSize, bounds: InkyAnnotationGeometry.baseBounds(for: annotation.action, pageSize: pageSize), scale: scale, progress: progress)
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
        case .openSidebar, .say:
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
