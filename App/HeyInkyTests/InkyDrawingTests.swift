import PencilKit
import Testing
import UIKit
@testable import HeyInky

/// Inky drawing on the page: stroke geometry, real ink, the nib/reveal contract, ink skeleton
/// context, layout of text, and `addPage`.
@MainActor
@Suite("Inky draws")
struct InkyDrawingTests {
    let pageSize = CGSize(width: 816, height: 1056)

    func shape(_ kind: DrawAction.Shape.Kind, _ points: [(Double, Double)], text: String? = nil, size: DrawAction.Shape.Size = .medium) -> DrawAction.Shape {
        .init(kind: kind, points: points.map { NormPoint(x: $0.0, y: $0.1) }, text: text, size: size)
    }

    func makeEditor() -> PageEditorModel {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "Draw", paper: .blank)
        return PageEditorModel(notebookID: notebook.id, page: notebook.pages[0], store: store)
    }

    // MARK: Geometry

    @Test func strokesStartAndEndExactlyWhereTheModelSaid() {
        // Bonds must meet atoms: the wobble never moves stroke ends.
        let action = DrawAction(ink: .pen, color: .indigo, shapes: [shape(.line, [(0.3, 0.5), (0.36, 0.46)])], caption: nil)
        let layout = DrawInk.layout(action, pageSize: pageSize, seed: 7)
        let points = layout.segments[0].points
        #expect(points.first == CGPoint(x: 0.3 * 816, y: 0.5 * 1056))
        #expect(hypot(points.last!.x - 0.36 * 816, points.last!.y - 0.46 * 1056) < 0.01)
        // …while the middle has a gentle hand wobble.
        let straight = points.map { p -> CGFloat in
            let a = points.first!, b = points.last!
            return abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / hypot(b.x - a.x, b.y - a.y)
        }
        #expect(straight.max()! > 0.05 && straight.max()! < 2, "wobble is subtle")
    }

    @Test func arrowsGetHeadsAndDashesBreak() {
        let action = DrawAction(ink: .pen, color: .red, shapes: [
            shape(.arrow, [(0.1, 0.1), (0.3, 0.1)]),
            shape(.dashedLine, [(0.1, 0.2), (0.4, 0.2)]),
            shape(.curvedArrow, [(0.1, 0.3), (0.3, 0.3)]),
            shape(.ellipse, [(0.5, 0.5), (0.7, 0.6)]),
        ], caption: nil)
        let layout = DrawInk.layout(action, pageSize: pageSize)
        // arrow: shaft + head; dashed: many dashes; curved: curve + head; ellipse: one loop.
        #expect(layout.segments.count > 2 + 6 + 2)
        let head = layout.segments[1].points
        #expect(hypot(head[head.count / 2].x - 0.3 * 816, head[head.count / 2].y - 0.1 * 1056) < 2, "the head's tip is the arrow's end")
        // The curved arrow bows away from the straight line.
        let curve = layout.segments.first { $0.points.contains { abs($0.y - 0.3 * 1056) > 20 } }
        #expect(curve != nil)
        // Ellipse spans its box.
        #expect(layout.bounds.maxX >= 0.7 * 816 && layout.bounds.maxY >= 0.6 * 1056)
    }

    @Test func rendersRealPencilKitInkAndRevealsUnderTheNib() {
        let action = DrawAction(ink: .pen, color: .indigo, shapes: [
            shape(.line, [(0.1, 0.1), (0.5, 0.1)]),
            shape(.line, [(0.1, 0.3), (0.5, 0.3)]),
            shape(.text, [(0.1, 0.4)], text: "H"),
        ], caption: nil)
        let layout = DrawInk.layout(action, pageSize: pageSize)
        #expect(DrawInk.drawing(layout, action: action).strokes.count == 2)
        let half = DrawInk.drawing(layout, action: action, progress: 0.3)
        #expect(half.strokes.count == 1, "the second line isn't drawn yet")
        // The nib is at the end of what's revealed.
        let nib = DrawInk.nib(layout, at: 0.3)
        let lastPoint = half.strokes[0].path.last!.location
        #expect(hypot(nib.x - lastPoint.x, nib.y - lastPoint.y) < 8)
        #expect(DrawInk.textProgress(layout, progress: 0.3)[2] == 0, "text comes last")
        #expect(DrawInk.textProgress(layout, progress: 1)[2] == 1)

        let image = DrawMark.image(layout, action: action, progress: 1, scale: 1, seed: 0)
        #expect(image != nil)
    }

    @Test func drawingIsAnAnnotationWithBoundsAndAStroke() throws {
        let editor = makeEditor()
        let action = DrawAction(ink: .marker, color: .orange, shapes: [shape(.polygon, [(0.2, 0.2), (0.4, 0.2), (0.3, 0.35)])], caption: "triangle")
        editor.addAnnotation(.draw(action), question: "draw a triangle")
        let annotation = try #require(editor.annotations.first)
        let bounds = InkyAnnotationGeometry.bounds(for: annotation, pageSize: pageSize)
        #expect(bounds.minX < 0.2 && bounds.maxX > 0.4 && bounds.maxY > 0.35)
        let stroke = try #require(InkyStroke(annotation: annotation, pageSize: pageSize))
        #expect(stroke.kind == .draw)
        #expect(hypot(stroke.start.x - 0.2 * 816, stroke.start.y - 0.2 * 1056) < 1, "Inky starts where the pen starts")
        #expect(stroke.duration > 0.3 && stroke.duration <= 7)
    }

    // MARK: Ink skeleton

    @Test func skeletonReducesAHexagonToItsCornersAndSkipsHandwriting() {
        let center = CGPoint(x: 300, y: 400)
        var hexagon = (0...6).map { i -> CGPoint in
            let angle = CGFloat(i) * .pi / 3
            return CGPoint(x: center.x + 50 * cos(angle), y: center.y + 50 * sin(angle))
        }
        hexagon = DrawInk.densify(hexagon, spacing: 2)
        let writing = DrawInk.densify([CGPoint(x: 600, y: 100), CGPoint(x: 640, y: 110)], spacing: 2)
        func stroke(_ points: [CGPoint]) -> PKStroke {
            PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points.enumerated().map {
                PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: .now))
        }
        let drawing = PKDrawing(strokes: [stroke(hexagon), stroke(writing)])
        let textLine = NormRect(x: 590.0 / 816, y: 90.0 / 1056, width: 70.0 / 816, height: 35.0 / 1056)
        let paths = InkSkeleton.paths(in: drawing, pageSize: pageSize, handwriting: [textLine])
        #expect(paths.count == 1, "the handwriting stroke is left out")
        #expect((6...8).contains(paths[0].count), "a hexagon's corners (got \(paths[0].count))")
    }

    @Test func requestTextListsStrokeCorners() {
        var request = Fixtures.sampleRequest()
        request.inkPaths = [[NormPoint(x: 0.3, y: 0.4), NormPoint(x: 0.35, y: 0.38)]]
        let text = InkyPromptBuilder.userText(for: request)
        #expect(text.contains("s1: (0.300, 0.400) (0.350, 0.380)"))
    }

    // MARK: Validation

    @Test func validatorRejectsBrokenShapes() {
        let bad = DrawAction(ink: .pen, color: .indigo, shapes: [shape(.curvedArrow, [(0.1, 0.1)])], caption: nil)
        #expect(InkyResponseValidator.drawProblem(bad)?.contains("curvedArrow") == true)
        let good = DrawAction(ink: .pen, color: .indigo, shapes: [shape(.text, [(0.1, 0.1)], text: "x = 4")], caption: nil)
        #expect(InkyResponseValidator.drawProblem(good) == nil)
    }

    // MARK: addPage

    @Test func addPageMovesTheRestOfTheAnswerToTheNewPage() async {
        let editor = makeEditor()
        let store = editor.store
        let second = store.addPage(to: editor.notebookID, background: .paper(.grid))!
        let newEditor = PageEditorModel(notebookID: editor.notebookID, page: second, store: store)
        let star = InkyAction.star(StarAction(point: NormPoint(x: 0.5, y: 0.5)))
        let session = InkySession(client: MockInkyModelClient(delay: .zero, fixedActions: [
            .say(SayAction(text: "On a new page.")), .highlight(HighlightAction(region: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05), color: .yellow, note: nil)),
            .addPage(AddPageAction(paper: .grid)), star,
        ]))
        var requested: AddPageAction.Paper?
        session.onAddPage = { paper in requested = paper; return newEditor }
        await session.run(Fixtures.sampleRequest(), editor: editor)
        #expect(requested == .grid)
        #expect(editor.annotations.map(\.action.type) == [.highlight])
        #expect(newEditor.annotations.map(\.action) == [star])
    }

    // MARK: Layout

    @Test func notesOfNeighbouringHighlightsDontCoverEachOther() {
        let editor = makeEditor()
        // Three adjacent highlights on one line, each with a note (what crowded the molecule page).
        for (i, note) in ["amide", "aromatic ring", "phenol (OH)"].enumerated() {
            editor.addAnnotation(.highlight(HighlightAction(region: NormRect(x: 0.2 + Double(i) * 0.12, y: 0.4, width: 0.12, height: 0.06), color: .yellow, note: note)), question: nil)
        }
        let rects = editor.annotations.compactMap { InkyLayout.textRect(for: $0, pageSize: pageSize) }
        #expect(rects.count == 3)
        for i in rects.indices { for j in rects.indices where i < j { #expect(!rects[i].intersects(rects[j]), "\(i) vs \(j)") } }
    }

    @Test func labelsAvoidTheStudentsInk() {
        let editor = makeEditor()
        // Ink right where the default label spot would be (above-right of the anchor).
        let blocker = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: DrawInk.densify(
            [CGPoint(x: 0.42 * 816, y: 0.37 * 1056), CGPoint(x: 0.65 * 816, y: 0.42 * 1056)], spacing: 3
        ).enumerated().map { PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) * 0.01, size: CGSize(width: 30, height: 30), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }, creationDate: .now))
        editor.drawingDidChange(PKDrawing(strokes: [blocker]))
        let label = LabelAction(anchor: NormPoint(x: 0.4, y: 0.45), text: "carbonyl", arrow: true)
        editor.addAnnotation(.label(label), question: nil)
        let text = InkyLayout.textRect(for: editor.annotations[0], pageSize: pageSize)!
        let ink = NormRect(blocker.renderBounds, in: pageSize)
        #expect(InkyLayout.overlap(text, ink) < 0.05, "label moved off the ink (placement \(editor.annotations[0].labelPlacement ?? 0))")
    }
}

/// Readability of what the real model drew (`shared/fixtures/draw_hydrogens_live.json`: the hidden
/// hydrogens of a hand-drawn methylcyclohexane, captured from gpt-5.4-mini).
@MainActor
@Suite("Inky draws readably")
struct InkyDrawingReadabilityTests {
    let pageSize = CGSize(width: 816, height: 1056)

    func liveHydrogens() throws -> DrawAction {
        guard case .draw(let a) = try #require(Fixtures.response("draw_hydrogens_live").actions.first) else {
            throw CancellationError()
        }
        return a
    }

    @Test func atomLabelsDontOverlapEachOther() throws {
        let layout = DrawInk.layout(try liveHydrogens(), pageSize: pageSize)
        let rects = layout.segments.compactMap { $0.text?.rect }
        #expect(rects.count == 14)
        for i in rects.indices {
            for j in rects.indices where i < j {
                let o = rects[i].intersection(rects[j])
                #expect(o.isNull || o.width * o.height < 0.08 * rects[i].width * rects[i].height, "H \(i) and H \(j) overlap")
            }
        }
    }

    @Test func eachHSitsJustPastItsBondEnd() throws {
        let action = try liveHydrogens()
        let layout = DrawInk.layout(action, pageSize: pageSize)
        // Bond ends as drawn (lengthened where a label had to move out).
        let bondEnds = layout.segments.filter { $0.text == nil }.compactMap(\.points.last)
        for text in layout.segments.compactMap(\.text) {
            let center = CGPoint(x: text.rect.midX, y: text.rect.midY)
            let nearest = bondEnds.map { hypot($0.x - center.x, $0.y - center.y) }.min()!
            #expect(nearest < 26, "an H floats \(nearest) pt from its bond")
            #expect(!bondEnds.contains { text.rect.insetBy(dx: 2, dy: 2).contains($0) } || nearest > 4, "H written over its bond end")
        }
    }

    @Test func circlesSnapAroundTheTextTheyEnclose() {
        // The model's ellipse was a little left of "x = -1/2" and cut through it.
        let action = DrawAction(ink: .pen, color: .indigo, shapes: [
            .init(kind: .text, points: [NormPoint(x: 0.1, y: 0.5)], text: "x = -1/2", size: .medium),
            .init(kind: .ellipse, points: [NormPoint(x: 0.065, y: 0.49), NormPoint(x: 0.2, y: 0.53)], text: nil, size: .medium),
        ], caption: nil)
        let layout = DrawInk.layout(action, pageSize: pageSize)
        let text = layout.segments.compactMap(\.text).first!.rect
        let loop = layout.segments.first { $0.text == nil }!.points
        let xs = loop.map(\.x), ys = loop.map(\.y)
        let loopBox = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        #expect(loopBox.insetBy(dx: -2, dy: -2).contains(text), "the circle encloses the text (\(loopBox) vs \(text))")
    }

    @Test func workingStepsMoveOffInkysOtherText() throws {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "T", paper: .blank)
        let editor = PageEditorModel(notebookID: notebook.id, page: notebook.pages[0], store: store)
        // What happened on the equilibrium page: a fill-in "left", then notes written over it.
        editor.addAnnotation(.fillText(FillTextAction(region: NormRect(x: 0.6, y: 0.37, width: 0.05, height: 0.025), text: "left", handwritingStyle: true)), question: nil)
        editor.addAnnotation(.draw(DrawAction(ink: .pen, color: .indigo, shapes: [
            .init(kind: .text, points: [NormPoint(x: 0.62, y: 0.37)], text: "↑T → shift left", size: .medium),
        ], caption: nil)), question: nil)
        guard case .draw(let placed) = editor.annotations[1].action else { Issue.record("draw"); return }
        let text = DrawInk.layout(placed, pageSize: pageSize).segments.compactMap(\.text).first!.rect
        let fill = NormRect(x: 0.6, y: 0.37, width: 0.05, height: 0.025).cgRect(in: pageSize)
        #expect(text.intersection(fill).isNull || text.intersection(fill).width * text.intersection(fill).height < 0.08 * fill.width * fill.height)
    }
}

@MainActor
@Suite("Bond layout")
struct BondLayoutTests {
    let pageSize = CGSize(width: 816, height: 1056)

    /// The seeded methylcyclohexane as its skeleton (ring + branch), normalized.
    func skeleton() -> [[NormPoint]] {
        let center = CGPoint(x: 300, y: 380), r: CGFloat = 62
        let ring = (0...6).map { i -> CGPoint in
            let t = -CGFloat.pi / 2 + CGFloat(i) * .pi / 3
            return CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
        }
        let branch = [ring[1], CGPoint(x: ring[1].x + r * cos(-.pi / 6), y: ring[1].y + r * sin(-.pi / 6))]
        return [ring, branch].map { $0.map { NormPoint(x: $0.x / pageSize.width, y: $0.y / pageSize.height) } }
    }

    @Test func junctionsCountTheLinesMeetingAtEachAtom() {
        let atoms = BondLayout.atoms(skeleton: skeleton(), pageSize: pageSize)
        #expect(atoms.count == 7, "6 ring carbons (the closing point merges) + the methyl")
        #expect(atoms.map(\.bonds).sorted() == [1, 2, 2, 2, 2, 2, 3])
        var request = Fixtures.sampleRequest()
        request.inkAtoms = atoms
        request.inkPaths = skeleton()
        #expect(InkyPromptBuilder.userText(for: request).contains("3 lines"))
    }

    @Test func duplicatedHydrogensAreDroppedByValence() throws {
        // gpt-5.4 drew one CH₂'s hydrogens twice (16 H's for C₇H₁₄).
        guard case .draw(let raw) = try Fixtures.response("draw_hydrogens_duplicated").actions[0] else { return }
        #expect(raw.shapes.filter { $0.text == "H" }.count == 16)
        let refined = BondLayout.refine(raw, skeleton: skeleton(), pageSize: pageSize)
        #expect(refined.shapes.filter { $0.text == "H" }.count == 14)
        #expect(refined.shapes.filter { $0.kind == .line }.count == 14)
        // Per carbon: what methylcyclohexane needs.
        let atoms = BondLayout.atoms(skeleton: skeleton(), pageSize: pageSize).map { $0.point.cgPoint(in: pageSize) }
        let starts = refined.shapes.filter { $0.kind == .line }.map { $0.points[0].cgPoint(in: pageSize) }
        let perAtom = atoms.map { a in starts.filter { hypot($0.x - a.x, $0.y - a.y) < 1 }.count }
        let degrees = BondLayout.atoms(skeleton: skeleton(), pageSize: pageSize).map(\.bonds)
        #expect(zip(perAtom, degrees).allSatisfy { $0 == 4 - $1 }, "\(perAtom) vs degrees \(degrees)")
    }

    @Test func spreadFillsTheLargestGap() {
        // A terminal carbon (one bond pointing left): three H's spread right, none on the bond.
        let dirs = BondLayout.spread(count: 3, around: [.pi])
        #expect(dirs.allSatisfy { abs(cos($0 - .pi) - 1) > 0.2 })
        // Ring CH₂ (bonds at ±60° from straight down-left/right): two H's outside.
        let ring = BondLayout.spread(count: 2, around: [CGFloat.pi / 6, 5 * CGFloat.pi / 6])
        #expect(ring.allSatisfy { sin($0) < 0.2 }, "both point away from the ring below")
    }

    @Test func modelsHydrogensGetCleanAnglesOnTheStudentsSkeleton() throws {
        guard case .draw(let raw) = try Fixtures.response("draw_hydrogens_live").actions[0] else { return }
        let refined = BondLayout.refine(raw, skeleton: skeleton(), pageSize: pageSize)
        let skeletonPoints = skeleton().flatMap { $0 }.map { $0.cgPoint(in: pageSize) }
        let lines = refined.shapes.filter { $0.kind == .line }.map { $0.points.map { $0.cgPoint(in: pageSize) } }
        #expect(lines.count == 14)
        for line in lines {
            let start = line[0], end = line[1]
            let length = hypot(end.x - start.x, end.y - start.y)
            #expect(length > 62 * 0.5 && length < 62 * 0.8, "bond length \(length)")
            // No new bond runs along an existing one.
            let angle = atan2(end.y - start.y, end.x - start.x)
            for p in skeletonPoints where hypot(p.x - start.x, p.y - start.y) > 20 && hypot(p.x - start.x, p.y - start.y) < 70 {
                let other = atan2(p.y - start.y, p.x - start.x)
                #expect(abs(sin((angle - other) / 2)) > sin(.pi / 10), "an H bond lies on a skeleton bond")
            }
        }
        // And the H labels moved with their bonds.
        let layout = DrawInk.layout(refined, pageSize: pageSize)
        let texts = layout.segments.compactMap(\.text)
        #expect(texts.count == 14)
    }
}

@Suite("Reasoning effort")
struct ReasoningEffortTests {
    @Test func drawingAndWorkingGetMoreThought() {
        #expect(InkyConfig.reasoningEffort(for: "draw in all the hidden hydrogens") == "medium")
        #expect(InkyConfig.reasoningEffort(for: "Explain why the equilibrium shifts") == "medium")
        #expect(InkyConfig.reasoningEffort(for: "highlight the title") == "low")
        let body = InkyPromptBuilder.body(for: Fixtures.sampleRequest(question: "solve for x"))
        #expect((body["reasoning"] as? [String: String])?["effort"] == "medium")
    }
}
