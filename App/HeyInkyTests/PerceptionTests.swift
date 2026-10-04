import PencilKit
import Testing
import UIKit
@testable import HeyInky

/// The perception pipeline (image/ink → structure with exact atoms) and the geometry Inky draws
/// from it. Fixture: `shared/fixtures/images/acetaminophen_hand.png`, a hand-drawn acetaminophen
/// on grid paper (the case from the field: "add the hidden hydrogens").
@MainActor
@Suite("Perception and precise structure marks", .serialized)
struct PerceptionTests {
    static func fixtureImage() throws -> UIImage {
        let url = try #require(Bundle(for: PerceptionBundleToken.self).url(forResource: "acetaminophen_hand", withExtension: "png", subdirectory: "fixtures/images"))
        return try #require(UIImage(contentsOfFile: url.path))
    }

    /// A page with the fixture image placed on it.
    static func imageEditor() throws -> PageEditorModel {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "Organic structures", paper: .grid)
        let data = try #require(try fixtureImage().pngData())
        _ = try store.addImage(data, to: notebook.pages[0].id, in: notebook.id)
        let page = try #require(store.notebook(id: notebook.id)?.pages[0])
        return PageEditorModel(notebookID: notebook.id, page: page, store: store)
    }

    // MARK: Raster → graph

    @Test func handDrawnImageBecomesTheRightBondGraph() throws {
        let cg = try #require(try Self.fixtureImage().cgImage)
        let (bitmap, _) = try #require(InkBitmap.threshold(cg))
        let graph = StructureRecognizer.recognize(LineArt(bitmap: bitmap))
        #expect(graph.atoms.count == 11)
        #expect(graph.bonds.count == 11)
        #expect(graph.glyphs.count == 3, "O, NH and OH")
        #expect(graph.bonds.filter { $0.order == 2 }.count == 4, "C=O plus three ring double bonds")
        #expect(graph.components().count == 1)
        #expect(StructureRecognizer.looksLikeStructure(graph, atoms: graph.components()[0]))
    }

    @Test func atomLabelsAreReadFromTheirShape() async throws {
        let cg = try #require(try Self.fixtureImage().cgImage)
        let (bitmap, _) = try #require(InkBitmap.threshold(cg))
        let graph = StructureRecognizer.recognize(LineArt(bitmap: bitmap))
        var readings: [String] = []
        for atom in graph.atoms {
            guard let g = atom.glyph else { continue }
            let p = atom.point
            let dirs = graph.neighbors(of: graph.atoms.firstIndex { $0.point == p }!).map { atan2(graph.atoms[$0].point.y - p.y, graph.atoms[$0].point.x - p.x) }
            readings.append(await AtomLabelReader.read(bitmap: bitmap, box: graph.glyphs[g].box, bondDirections: dirs).element)
        }
        #expect(readings.sorted() == ["N", "O", "O"])
    }

    @Test func ocrConfusionsMapToAtomLabels() {
        #expect(AtomLabelReader.normalizeOCR("Но-") == "HO")
        #expect(AtomLabelReader.normalizeOCR("zOH") == "OH")
        #expect(AtomLabelReader.normalizeOCR("HN.") == "HN")
        #expect(AtomLabelReader.normalizeOCR("0") == "O")
        #expect(AtomLabelReader.normalizeOCR("cl") == "Cl")
        #expect(AtomLabelReader.parse("NH₂")?.writtenHydrogens == 2)
    }

    // MARK: Page → structures

    @Test func findsAcetaminophenInAPlacedImage() async throws {
        let editor = try Self.imageEditor()
        PageStructureFinder.clearCache()
        let structures = await PageStructureFinder.find(editor: editor, text: [])
        #expect(structures.count == 1)
        let s = try #require(structures.first)
        #expect(s.id == "S1")
        #expect(s.source == .image)
        #expect(s.smiles == "CC(=O)Nc1ccc(O)cc1")
        #expect(s.atoms.reduce(0) { $0 + $1.hiddenHydrogens } == 7, "4 aromatic CH + CH3")
        #expect(s.atoms.filter { $0.element == "C" && $0.hiddenHydrogens == 3 }.count == 1)
        // Atom positions are inside the placed image.
        let frame = editor.page.images[0].frame
        #expect(s.atoms.allSatisfy { frame.insetBy(dx: -0.01, dy: -0.01).contains($0.point) })
        #expect(s.bondLength > 10)
    }

    @Test func findsAStructureDrawnInInk() async throws {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "Ink", paper: .blank)
        store.saveDrawing(Self.isoamylAlcoholInk(), for: notebook.pages[0].id, in: notebook.id)
        let editor = PageEditorModel(notebookID: notebook.id, page: notebook.pages[0], store: store)
        PageStructureFinder.clearCache()
        let structures = await PageStructureFinder.find(editor: editor, text: [])
        let s = try #require(structures.first { $0.source == .ink })
        #expect(s.smiles == "CC(C)CCO")
        #expect(s.atoms.reduce(0) { $0 + $1.hiddenHydrogens } == 11)
    }

    // MARK: Precise marks

    @Test func hydrogensAttachExactlyAndDontCrowd() async throws {
        let editor = try Self.imageEditor()
        PageStructureFinder.clearCache()
        let s = try #require(await PageStructureFinder.find(editor: editor, text: []).first)
        let action = AnnotateStructureAction(structure: "S1", relabel: [], hydrogens: ["all"], lonePairs: [], charges: [],
                                             highlights: [], labels: [], arrows: [], color: .indigo)
        let out = StructureAnnotator.compile(action, structure: s, pageSize: editor.page.size)
        #expect(out.problems.isEmpty)
        guard case .draw(let drawing) = try #require(out.actions.first) else { Issue.record("expected a drawing"); return }
        let lines = drawing.shapes.filter { $0.kind == .line }
        let labels = drawing.shapes.filter { $0.kind == .text }
        #expect(lines.count == 7)
        #expect(labels.count == 7 && labels.allSatisfy { $0.text == "H" })

        let size = editor.page.size
        let atomPoints = s.atoms.map { $0.point.cgPoint(in: size) }
        let ends = lines.map { $0.points[1].cgPoint(in: size) }
        for line in lines {
            let start = line.points[0].cgPoint(in: size), end = line.points[1].cgPoint(in: size)
            // Starts exactly on a carbon of the drawing.
            let nearest = atomPoints.map { hypot($0.x - start.x, $0.y - start.y) }.min() ?? .infinity
            #expect(nearest < 0.5)
            // Bond length matches the drawing (60% of its bonds).
            #expect(abs(hypot(end.x - start.x, end.y - start.y) - 0.6 * s.bondLength) < 0.5)
            // The new H isn't on top of another atom of the structure.
            let clearance = atomPoints.map { hypot($0.x - end.x, $0.y - end.y) }.min() ?? 0
            #expect(clearance > 0.45 * s.bondLength)
        }
        // H's don't pile onto each other.
        for i in ends.indices { for j in ends.indices where j > i {
            #expect(hypot(ends[i].x - ends[j].x, ends[i].y - ends[j].y) > 0.3 * s.bondLength)
        } }
    }

    @Test func lonePairsChargesArrowsAndHighlights() async throws {
        let editor = try Self.imageEditor()
        PageStructureFinder.clearCache()
        let s = try #require(await PageStructureFinder.find(editor: editor, text: []).first)
        let carbonylO = try #require(s.atoms.first { atom in atom.element == "O" && s.bonds.contains { ($0.a == s.atomIndex(atom.id) || $0.b == s.atomIndex(atom.id)) && $0.order == 2 } })
        let nitrogen = try #require(s.atoms.first { $0.element == "N" })
        let action = AnnotateStructureAction(
            structure: "S1", relabel: [], hydrogens: [], lonePairs: ["all"],
            charges: [.init(atom: carbonylO.id, text: "δ−")],
            highlights: [.init(atoms: [nitrogen.id, carbonylO.id], group: nil, color: .yellow, note: "amide")],
            labels: [.init(atom: nitrogen.id, text: "lone pair donor")],
            arrows: [.init(from: nitrogen.id, to: "\(nitrogen.id)-a1", kind: .curved)], color: .indigo)
        let out = StructureAnnotator.compile(action, structure: s, pageSize: editor.page.size)
        #expect(out.problems.isEmpty)
        let drawings = out.actions.compactMap { if case .draw(let d) = $0 { d } else { nil } }
        // 2 + 2 + 1 lone pairs (two O's, one N) = 10 dots.
        let dots = drawings.flatMap(\.shapes).filter { $0.kind == .ellipse }
        #expect(dots.count == 10)
        #expect(drawings.contains { $0.ink == .marker && $0.color == .yellow })
        #expect(drawings.contains { $0.color == .red && $0.shapes.contains { $0.kind == .polyline } })
        #expect(out.actions.contains { if case .label(let l) = $0 { l.text == "lone pair donor" } else { false } })
    }

    @Test func unknownAtomsAreReportedNotGuessed() throws {
        let s = PageStructure(id: "S1", source: .ink, region: .unit, smiles: "CC", bondLength: 40,
                              atoms: [.init(id: "a1", element: "C", label: nil, point: NormPoint(x: 0.4, y: 0.5), labelBox: nil, hydrogens: 3, writtenHydrogens: 0, charge: 0, aromatic: false, unsure: false),
                                      .init(id: "a2", element: "C", label: nil, point: NormPoint(x: 0.45, y: 0.5), labelBox: nil, hydrogens: 3, writtenHydrogens: 0, charge: 0, aromatic: false, unsure: false)],
                              bonds: [.init(a: 0, b: 1, order: 1)])
        let action = AnnotateStructureAction(structure: "S1", relabel: [], hydrogens: ["a9"], lonePairs: [], charges: [], highlights: [], labels: [], arrows: [], color: .indigo)
        let out = StructureAnnotator.compile(action, structure: s, pageSize: CGSize(width: 816, height: 1056))
        #expect(out.actions.isEmpty)
        #expect(out.problems.contains { $0.contains("a9") })

        // Ethane: 3 + 3 H's, the two CH3's fanned on opposite sides.
        let all = AnnotateStructureAction(structure: "S1", relabel: [], hydrogens: ["all"], lonePairs: [], charges: [], highlights: [], labels: [], arrows: [], color: .indigo)
        guard case .draw(let d) = StructureAnnotator.compile(all, structure: s, pageSize: CGSize(width: 816, height: 1056)).actions.first else { Issue.record("no drawing"); return }
        #expect(d.shapes.filter { $0.text == "H" }.count == 6)
    }

    @Test func validatorChecksStructureIdsAgainstTheRequest() {
        var request = Fixtures.sampleRequest()
        request.structures = [PageStructure(id: "S1", source: .image, region: .unit, smiles: "CC", bondLength: 30,
                                            atoms: [.init(id: "a1", element: "C", label: nil, point: NormPoint(x: 0.1, y: 0.1), labelBox: nil, hydrogens: 3, writtenHydrogens: 0, charge: 0, aromatic: false, unsure: false)],
                                            bonds: [])]
        func action(_ s: String, _ h: [String]) -> InkyAction {
            .annotateStructure(.init(structure: s, relabel: [], hydrogens: h, lonePairs: [], charges: [], highlights: [], labels: [], arrows: [], color: .indigo))
        }
        if case .invalid = InkyResponseValidator.check(action("S1", ["all"]), request: request) { Issue.record("valid action rejected") }
        if case .valid = InkyResponseValidator.check(action("S2", ["all"]), request: request) { Issue.record("unknown structure accepted") }
        if case .valid = InkyResponseValidator.check(action("S1", ["a7"]), request: request) { Issue.record("unknown atom accepted") }
        if case .valid = InkyResponseValidator.check(action("S1", []), request: request) { Issue.record("empty annotation accepted") }
    }

    // MARK: Figures

    @Test func resonanceSchemeAlignsFormsAndKeepsAtomMaps() async throws {
        let steps = ["[O-:1][C:2]1=CC=CC=C1", "[O:1]=[C:2]1[CH-:3]C=CC=C1", "[O:1]=[C:2]1C=C[CH-:4]C=C1"]
        let analysis = try await MoleculeEngine.shared.scheme(steps: steps)
        #expect(analysis.ok)
        #expect(analysis.steps.map { $0.maps["1"] } == [0, 0, 0])
        #expect(analysis.steps[1].maps["3"] != nil)
        let action = InsertChemSchemeAction(near: NormRect(x: 0.1, y: 0.6, width: 0.8, height: 0.2), title: "Phenoxide resonance",
                                            steps: steps.map { .init(smiles: $0, label: nil) },
                                            connectors: [.init(kind: .resonance, above: nil, below: nil), .init(kind: .resonance, above: nil, below: nil)],
                                            arrows: [.init(step: 0, from: "1", to: "1-2", kind: .curved)], lonePairs: [.init(step: 0, atom: "1")],
                                            highlights: [], caption: nil)
        let layout = ChemSchemeLayout(analysis: analysis, action: action, maxWidth: ChemSchemeLayout.preferredMaxWidth(pageWidth: 816))
        #expect(layout.steps.count == 3)
        #expect(layout.connectors.count == 2)
        #expect(layout.size.width < 816 * 0.9)
        // Every structure drawn at the same bond length.
        for placed in layout.steps {
            let d = try #require(analysis.steps[placed.step].depiction)
            let b = d.bonds[0]
            let len = hypot(d.atoms[b.a].x - d.atoms[b.b].x, d.atoms[b.a].y - d.atoms[b.b].y) * placed.scale
            #expect(abs(len - ChemSchemeLayout.designBond) < 3)
        }
    }

    @Test func deepCheckRejectsResonanceFormsThatAreDifferentMolecules() async {
        // The model once wrote a seven-membered ring as a "resonance form" of phenoxide.
        func scheme(_ steps: [String]) -> InkyAction {
            .insertChemScheme(InsertChemSchemeAction(near: NormRect(x: 0.1, y: 0.5, width: 0.8, height: 0.2), title: nil,
                                                     steps: steps.map { .init(smiles: $0, label: nil) },
                                                     connectors: Array(repeating: .init(kind: .resonance, above: nil, below: nil), count: steps.count - 1),
                                                     arrows: [], lonePairs: [], highlights: [], caption: nil))
        }
        let request = Fixtures.sampleRequest()
        let bad = await InkyDeepChecker.check(scheme(["[O-]C1=CC=CC=C1", "O=C1C=CC[CH-]C=C1"]), request: request, isFinalAttempt: false)
        guard case .invalid(let problem) = bad else { Issue.record("seven-membered ring accepted"); return }
        #expect(problem.contains("resonance"))
        let good = await InkyDeepChecker.check(scheme(["[O-]C1=CC=CC=C1", "O=C1C=C[CH-]C=C1"]), request: request, isFinalAttempt: false)
        if case .invalid(let p) = good { Issue.record("valid resonance rejected: \(p)") }
    }

    @Test func schemeValidationRepairsConnectorsAndCatchesMissingMaps() {
        let ok = InsertChemSchemeAction(near: .unit, title: nil, steps: [.init(smiles: "C[O-:1]", label: nil), .init(smiles: "CO", label: nil)],
                                        connectors: [], arrows: [], lonePairs: [], highlights: [], caption: nil)
        guard case .valid(.insertChemScheme(let fixed)) = InkyResponseValidator.check(.insertChemScheme(ok)) else { Issue.record("rejected"); return }
        #expect(fixed.connectors.count == 1)
        var bad = ok
        bad.arrows = [.init(step: 0, from: "5", to: "1", kind: .curved)]
        if case .valid = InkyResponseValidator.check(.insertChemScheme(bad)) { Issue.record("missing map accepted") }
    }

    @Test func diagramEngineFitsChecksAndRendersVector() async throws {
        let good = """
        <svg viewBox="0 0 400 200"><rect x="20" y="40" width="120" height="70" rx="10" class="fill-accent accent"/>
        <text x="80" y="80" class="label center">Nucleus</text>
        <line x1="140" y1="75" x2="260" y2="75" marker-end="url(#arrow)"/>
        <text x="300" y="80" class="label">Cytoplasm</text></svg>
        """
        let report = try await DiagramEngine.shared.prepare(svg: good)
        #expect(report.ok, "\(report.problems)")
        #expect(report.textCount == 2)
        #expect(report.width > 250 && report.width < 420)
        let pdf = try await DiagramEngine.shared.pdf(for: report)
        #expect(pdf.count > 500)

        let overlapping = #"<svg viewBox="0 0 300 100"><text x="10" y="50">Mitochondrion</text><text x="20" y="52">Ribosome</text></svg>"#
        let bad = try await DiagramEngine.shared.prepare(svg: overlapping)
        #expect(bad.problems.contains { $0.contains("overlap") })

        let struck = #"<svg viewBox="0 0 300 120"><text x="100" y="60">Nucleus</text><line x1="20" y1="55" x2="280" y2="55"/><text x="10" y="110">A</text><text x="250" y="110">B</text><line x1="20" y1="100" x2="240" y2="20"/><line x1="245" y1="100" x2="20" y2="20"/></svg>"#
        let lines = try await DiagramEngine.shared.prepare(svg: struck)
        #expect(lines.problems.contains { $0.contains("runs through the label \"Nucleus\"") }, "\(lines.problems)")
        #expect(lines.problems.contains { $0.contains("cross") }, "\(lines.problems)")

        // Callouts are laid out by the app: clean even when parts sit close together.
        let cell = #"<svg viewBox="0 0 300 200"><ellipse cx="150" cy="100" rx="130" ry="85"/><circle cx="130" cy="100" r="35"/><circle cx="200" cy="70" r="12"/></svg>"#
        let callouts: [InsertDiagramAction.Callout] = [.init(text: "Nucleus", x: 130, y: 100), .init(text: "Mitochondrion", x: 200, y: 70),
                                                       .init(text: "Ribosome", x: 205, y: 80), .init(text: "Cytoplasm", x: 60, y: 140),
                                                       .init(text: "Cell membrane", x: 30, y: 60)]
        let laidOut = try await DiagramEngine.shared.prepare(svg: cell, callouts: callouts)
        #expect(laidOut.ok, "\(laidOut.problems)")
        #expect(laidOut.textCount == 5)

        let tiny = #"<svg viewBox="0 0 3000 2000"><rect x="0" y="0" width="3000" height="2000"/><text x="100" y="100" font-size="12">tiny</text></svg>"#
        let small = try await DiagramEngine.shared.prepare(svg: tiny)
        #expect(DiagramEngine.displayProblems(for: small, pageSize: CGSize(width: 816, height: 1056)).contains { $0.contains("pt on the page") })

        let unsafe = #"<svg viewBox="0 0 100 100"><script>alert(1)</script><a href="https://x.com"><rect width="50" height="50"/></a><circle cx="50" cy="50" r="20"/></svg>"#
        let cleaned = try await DiagramEngine.shared.prepare(svg: unsafe)
        #expect(!cleaned.svg.contains("<script") && !cleaned.svg.contains("https://"))
    }

    @Test func labelArrowsSnapOntoTheDrawingNotNextToIt() throws {
        let editor = try Self.imageEditor()
        let frame = editor.page.images[0].frame
        // Just right of the "O" of the carbonyl in the image: blank paper a hair off the letter.
        let s = NormPoint(x: frame.x + frame.width * (128.0 / 520), y: frame.y + frame.height * (88.0 / 260))
        guard case .label(let moved) = AnchorSnapper.snapped(.label(LabelAction(anchor: s, text: "carbonyl O", arrow: true)), editor: editor) else { Issue.record("not a label"); return }
        #expect(moved.anchor != s, "moved onto the ink")
        #expect(abs(moved.anchor.x - s.x) < 0.02 && abs(moved.anchor.y - s.y) < 0.02, "but only a little")
        // On the ink already: untouched. Far from anything: untouched.
        let far = NormPoint(x: frame.x + frame.width * 0.95, y: frame.y + frame.height * 0.9)
        guard case .label(let kept) = AnchorSnapper.snapped(.label(LabelAction(anchor: far, text: "x", arrow: true)), editor: editor) else { return }
        #expect(kept.anchor == far)
    }

    @Test func figuresArePlacedInFreeSpace() {
        let page = CGSize(width: 816, height: 1056)
        // Top half is full.
        let busy = [NormRect(x: 0, y: 0, width: 1, height: 0.5)]
        let r = FigurePlacement.place(size: CGSize(width: 400, height: 200), near: NormRect(x: 0.2, y: 0.2, width: 0.5, height: 0.2), avoid: busy, pageSize: page)
        #expect(r.minY >= 0.5 - 1e-9)
        #expect(abs(r.width - 400 / 816) < 1e-6)
    }

    // MARK: Ink fixture

    /// Isoamyl alcohol drawn as pen strokes: a zigzag, a methyl branch and "OH" written by hand.
    static func isoamylAlcoholInk() -> PKDrawing {
        func stroke(_ points: [CGPoint]) -> PKStroke {
            let pts = points.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.01, size: CGSize(width: 3.2, height: 3.2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: densify(pts.map(\.location)).enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.005, size: CGSize(width: 3.2, height: 3.2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: .now))
        }
        func densify(_ p: [CGPoint]) -> [CGPoint] {
            var out: [CGPoint] = []
            for (a, b) in zip(p, p.dropFirst()) {
                let n = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 3))
                for k in 0..<n { out.append(CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / CGFloat(n), y: a.y + (b.y - a.y) * CGFloat(k) / CGFloat(n))) }
            }
            out.append(p.last!)
            return out
        }
        let L: CGFloat = 46, dx = L * 0.866, dy = L * 0.5
        let c1 = CGPoint(x: 200, y: 400), c2 = CGPoint(x: 200 + dx, y: 400 - dy), c3 = CGPoint(x: 200 + 2 * dx, y: 400)
        let c4 = CGPoint(x: 200 + 3 * dx, y: 400 - dy), oCenter = CGPoint(x: 200 + 4 * dx + 6, y: 400 + 2)
        let branch = CGPoint(x: c2.x, y: c2.y - L)
        let toO = CGPoint(x: oCenter.x - 12, y: oCenter.y - 5)
        var strokes = [stroke([c1, c2, c3, c4, toO]), stroke([c2, branch])]
        // "O": a loop; "H": two uprights and a bar.
        strokes.append(stroke((0...24).map { k in
            let a = CGFloat(k) / 24 * 2 * .pi
            return CGPoint(x: oCenter.x + 7 * cos(a), y: oCenter.y + 9 * sin(a))
        }))
        let hx = oCenter.x + 13
        strokes.append(stroke([CGPoint(x: hx, y: oCenter.y - 9), CGPoint(x: hx, y: oCenter.y + 9)]))
        strokes.append(stroke([CGPoint(x: hx + 10, y: oCenter.y - 9), CGPoint(x: hx + 10, y: oCenter.y + 9)]))
        strokes.append(stroke([CGPoint(x: hx, y: oCenter.y), CGPoint(x: hx + 10, y: oCenter.y)]))
        return PKDrawing(strokes: strokes)
    }
}

private final class PerceptionBundleToken {}
