import CoreGraphics
import Foundation
import PencilKit
import UIKit

/// Finds chemical structures on a page — in placed images (photos, screenshots, scans), in the
/// student's pen strokes, and in PDF slides — and turns each into a `PageStructure` with exact
/// atom positions that Inky can annotate by atom id.
///
/// Pipeline per source: raster → `LineArt` → `StructureRecognizer` graph → atom labels
/// (`AtomLabelReader`, or the page's own text for short PDF/OCR words) → RDKit
/// (`MoleculeEngine.molecule(fromGraph:)`) for SMILES and hydrogens. Results are cached per
/// source content, so asking again is instant.
@MainActor
enum PageStructureFinder {
    /// One raster to look at and where it sits on the page.
    struct Source: @unchecked Sendable {
        var kind: PageStructure.Source
        var image: CGImage
        /// Where the image maps onto the page (normalized).
        var frame: NormRect
        /// Normalized (within the image) areas to ignore: lines of prose.
        var exclude: [NormRect]
        /// Short words already read on the page, normalized within the image: atom label hints.
        var hints: [RecognizedTextLine]
        var cacheKey: String
    }

    /// A structure found in one source, before ids are assigned.
    struct Found: Sendable {
        var kind: PageStructure.Source
        var atoms: [PageStructure.Atom]
        var bonds: [PageStructure.Bond]
        var smiles: String?
        var bondLength: Double
        var region: NormRect
    }

    /// A shape found in one source, before ids are assigned.
    struct FoundShape: Sendable {
        var kind: PageShape.Kind
        var vertices: [NormPoint]
        var center: NormPoint
        var radius: Double
        var angles: [Double]
    }

    /// A part of a picture, before ids are assigned. `parent` indexes the same source's parts.
    struct FoundPart: Sendable {
        var part: ImagePartFinder.Part
        var box: NormRect
        var point: NormPoint
        var outline: [NormPoint]
        var picture: NormRect
    }

    struct Analysis: Sendable {
        var structures: [Found] = []
        var shapes: [FoundShape] = []
        var parts: [FoundPart] = []
    }

    /// Everything Inky can mark by id on a page.
    struct Findings: Sendable {
        var structures: [PageStructure] = []
        var shapes: [PageShape] = []
        var parts: [PagePart] = []
    }

    private static var cache: [String: Analysis] = [:]
    private static var cacheOrder: [String] = []

    static func find(editor: PageEditorModel, text: [RecognizedTextLine]) async -> [PageStructure] {
        await findAll(editor: editor, text: text).structures
    }

    /// Structures (S1…) and shapes (P1…) on the page.
    static func findAll(editor: PageEditorModel, text: [RecognizedTextLine]) async -> (structures: [PageStructure], shapes: [PageShape]) {
        let all = await findEverything(editor: editor, text: text)
        return (all.structures, all.shapes)
    }

    /// Structures (S1…), shapes (P1…) and picture parts (R1…) on the page.
    static func findEverything(editor: PageEditorModel, text: [RecognizedTextLine]) async -> Findings {
        var found: [Found] = []
        var shapes: [FoundShape] = []
        var partGroups: [[FoundPart]] = []
        for source in sources(editor: editor, text: text) {
            let analysis: Analysis
            if let hit = cache[source.cacheKey] {
                analysis = hit
            } else {
                analysis = await analyze(source, pageSize: editor.page.size)
                remember(analysis, key: source.cacheKey)
            }
            found += analysis.structures
            shapes += analysis.shapes
            if !analysis.parts.isEmpty { partGroups.append(analysis.parts) }
        }
        // Ids: S1, S2… by position on the page (top to bottom, then left to right).
        found.sort { ($0.region.y, $0.region.x) < ($1.region.y, $1.region.x) }
        let structures = found.enumerated().map { index, f in
            PageStructure(id: "S\(index + 1)", source: f.kind, region: f.region, smiles: f.smiles,
                          bondLength: f.bondLength, atoms: f.atoms, bonds: f.bonds)
        }
        shapes.sort { ($0.center.y, $0.center.x) < ($1.center.y, $1.center.x) }
        var pageShapes = shapes.enumerated().map { index, f in
            PageShape(id: "P\(index + 1)", kind: f.kind, vertices: f.vertices, center: f.center, radius: f.radius, angles: f.angles, contacts: [])
        }
        addContacts(&pageShapes, pageSize: editor.page.size)
        return Findings(structures: structures, shapes: pageShapes, parts: numberParts(partGroups))
    }

    /// Ids R1, R2… per picture (top to bottom), biggest parts first; at most 28 in all.
    static func numberParts(_ groups: [[FoundPart]]) -> [PagePart] {
        var result: [PagePart] = []
        for group in groups.sorted(by: { ($0.first?.picture.y ?? 0, $0.first?.picture.x ?? 0) < ($1.first?.picture.y ?? 0, $1.first?.picture.x ?? 0) }) {
            let order = group.indices.sorted { group[$0].part.area > group[$1].part.area }.prefix(max(0, 28 - result.count))
            var ids: [Int: String] = [:]
            for (k, i) in order.enumerated() { ids[i] = "R\(result.count + k + 1)" }
            for i in order {
                let f = group[i]
                result.append(PagePart(
                    id: ids[i]!, kind: f.part.kind == .marks ? .marks : .region,
                    color: ImagePartFinder.colorName(f.part.color), shape: ImagePartFinder.shapeName(f.part),
                    box: f.box, point: f.point, outline: f.outline, area: (f.part.area * 1000).rounded() / 1000,
                    inside: f.part.parent.flatMap { ids[$0] }, outlined: f.part.outlined, detailed: f.part.detailed,
                    picture: f.picture
                ))
            }
        }
        return result
    }

    /// A shape rests on another when one of its edges lies along one of the other's (a block on a
    /// ramp). Recorded on the shape that sits on the surface, with the surface's slope.
    static func addContacts(_ shapes: inout [PageShape], pageSize: CGSize) {
        func pts(_ s: PageShape) -> [CGPoint] { s.vertices.map { $0.cgPoint(in: pageSize) } }
        for i in shapes.indices where shapes[i].kind != .circle {
            let a = pts(shapes[i])
            for j in shapes.indices where j != i && shapes[j].kind != .circle {
                let b = pts(shapes[j])
                let bCenter = shapes[j].center.cgPoint(in: pageSize), aCenter = shapes[i].center.cgPoint(in: pageSize)
                for ea in a.indices {
                    let p1 = a[ea], p2 = a[(ea + 1) % a.count]
                    for eb in b.indices {
                        let q1 = b[eb], q2 = b[(eb + 1) % b.count]
                        let angA = atan2(p2.y - p1.y, p2.x - p1.x), angB = atan2(q2.y - q1.y, q2.x - q1.x)
                        var d = abs(angA - angB).truncatingRemainder(dividingBy: .pi)
                        d = min(d, .pi - d)
                        guard d < 0.12 else { continue }
                        let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                        guard Geometry2D.distance(mid, toLine: q1, q2) < 10 else { continue }
                        // Overlap along the surface.
                        let len = max(hypot(q2.x - q1.x, q2.y - q1.y), 1)
                        let ux = (q2.x - q1.x) / len, uy = (q2.y - q1.y) / len
                        let t1 = (p1.x - q1.x) * ux + (p1.y - q1.y) * uy, t2 = (p2.x - q1.x) * ux + (p2.y - q1.y) * uy
                        let overlap = min(max(t1, t2), len) - max(min(t1, t2), 0)
                        guard overlap > 0.3 * min(hypot(p2.x - p1.x, p2.y - p1.y), len) else { continue }
                        // The smaller shape, outside the other, rests on it.
                        let sizeA = hypot(a.map(\.x).max()! - a.map(\.x).min()!, a.map(\.y).max()! - a.map(\.y).min()!)
                        let sizeB = hypot(b.map(\.x).max()! - b.map(\.x).min()!, b.map(\.y).max()! - b.map(\.y).min()!)
                        guard sizeA < sizeB else { continue }
                        // a's center on the opposite side of the edge from b's center.
                        let side = { (p: CGPoint) in (q2.x - q1.x) * (p.y - q1.y) - (q2.y - q1.y) * (p.x - q1.x) }
                        guard side(aCenter) * side(bCenter) < 0 else { continue }
                        var slope = abs(Double(angB) * 180 / .pi).truncatingRemainder(dividingBy: 180)
                        if slope > 90 { slope = 180 - slope }
                        if !shapes[i].contacts.contains(where: { $0.other == shapes[j].id }) {
                            shapes[i].contacts.append(.init(other: shapes[j].id, edge: ea, slope: (slope * 10).rounded() / 10))
                        }
                    }
                }
            }
        }
    }

    private static func remember(_ result: Analysis, key: String) {
        cache[key] = result
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        if cacheOrder.count > 24 { cache[cacheOrder.removeFirst()] = nil }
    }

    // MARK: Sources

    static func sources(editor: PageEditorModel, text: [RecognizedTextLine]) -> [Source] {
        let page = editor.page
        var result: [Source] = []

        // Placed images.
        for placed in page.images {
            guard let image = editor.store.image(placed.asset, in: editor.notebookID)?.cgImage else { continue }
            let hints = text.compactMap { line -> RecognizedTextLine? in
                guard isLabelHint(line.text), placed.frame.contains(line.box.center) else { return nil }
                return RecognizedTextLine(text: line.text, box: within(placed.frame, line.box))
            }
            result.append(Source(kind: .image, image: image, frame: placed.frame, exclude: [], hints: hints,
                                 cacheKey: "img:\(placed.asset):\(placed.frame.x),\(placed.frame.y),\(placed.frame.width)"))
        }

        // The student's ink (prose handwriting masked out; short words may be atom labels), cropped
        // to the drawing so pen lines stay several pixels wide.
        if !editor.drawing.strokes.isEmpty {
            let prose = text.filter { !isLabelHint($0.text) && $0.text.filter { !$0.isWhitespace }.count >= 4 }.map(\.box)
            var area = CGRect.null
            for stroke in editor.drawing.strokes {
                let r = NormRect(stroke.renderBounds, in: page.size)
                if prose.contains(where: { $0.insetBy(dx: -0.005, dy: -0.005).contains(r.center) }) { continue }
                area = area.union(stroke.renderBounds)
            }
            if !area.isNull, area.width > 12 || area.height > 12 {
                let crop = area.insetBy(dx: -24, dy: -24).intersection(CGRect(origin: .zero, size: page.size))
                let frame = NormRect(crop, in: page.size)
                let scale: CGFloat = min(2.5, 1400 / max(crop.width, crop.height))
                let full = PageRenderer.image(page: page, notebookID: editor.notebookID, store: editor.store,
                                              drawing: editor.drawing, pixelWidth: page.width * scale, layers: [.ink])
                let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral
                if let cg = full.cgImage?.cropping(to: pixels) {
                    let hints = text.filter { isLabelHint($0.text) }.map { RecognizedTextLine(text: $0.text, box: within(frame, $0.box)) }
                    result.append(Source(kind: .ink, image: cg, frame: frame, exclude: prose.map { within(frame, $0) }, hints: hints,
                                         cacheKey: "ink:\(editor.page.id):\(editor.drawing.dataRepresentation().hashValue)"))
                }
            }
        }

        // PDF slide figures (text-layer words masked; short ones kept as label hints).
        if case .pdf(let asset, let index) = page.background {
            let image = PageRenderer.image(page: page, notebookID: editor.notebookID, store: editor.store,
                                           drawing: nil, pixelWidth: 1400, layers: [.pdf])
            if let cg = image.cgImage {
                let pdfText = PageRenderer.pdfTextLines(page: page, notebookID: editor.notebookID, store: editor.store)
                // Only real words are masked: short labels ("30°", "F") sit on the lines of figures.
                let prose = pdfText.filter { !isLabelHint($0.text) && $0.text.filter { !$0.isWhitespace }.count >= 4 }.map(\.box)
                let hints = pdfText.filter { isLabelHint($0.text) }
                result.append(Source(kind: .pdf, image: cg, frame: .unit, exclude: prose, hints: hints,
                                     cacheKey: "pdf:\(editor.notebookID):\(asset):\(index)"))
            }
        }
        return result
    }

    /// A word short enough to be an atom label ("OH", "NH₂", "Cl").
    static func isLabelHint(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.count <= 4 && AtomLabelReader.parse(t) != nil
    }

    /// `box` (page-normalized) expressed relative to `frame`.
    static func within(_ frame: NormRect, _ box: NormRect) -> NormRect {
        NormRect(x: (box.x - frame.x) / frame.width, y: (box.y - frame.y) / frame.height,
                 width: box.width / frame.width, height: box.height / frame.height)
    }

    // MARK: Analysis

    /// Raster work off the main actor.
    private struct Raster: Sendable {
        var bitmap: InkBitmap
        var graph: StructureRecognizer.Graph
        var shapes: [ShapeFinder.Shape]
        var parts: [ImagePartFinder.Part]
    }

    static func analyze(_ source: Source, pageSize: CGSize) async -> Analysis {
        let raster: Raster? = await Task.detached(priority: .userInitiated) {
            guard let (bitmap, _) = InkBitmap.threshold(source.image, maxSide: 1400, exclude: source.exclude) else { return nil }
            let art = LineArt(bitmap: bitmap)
            // Shapes at least ~3% of the page across (letters and arrowheads aren't shapes).
            let pagePixels = CGFloat(bitmap.width) / max(CGFloat(source.frame.width), 0.01)
            // Picture parts: photos, diagrams and slide figures (not the student's own ink).
            let parts = source.kind == .ink ? [] : ImagePartFinder.parts(in: source.image, exclude: source.exclude.map { $0.cgRect(in: CGSize(width: 1, height: 1)) })
            return Raster(bitmap: bitmap, graph: StructureRecognizer.recognize(art),
                          shapes: ShapeFinder.shapes(in: art, minSize: max(18, pagePixels * 0.03)), parts: parts)
        }.value
        guard let raster else { return Analysis() }
        let graph = raster.graph
        let bw = CGFloat(raster.bitmap.width), bh = CGFloat(raster.bitmap.height)

        func pagePoint(_ p: CGPoint) -> NormPoint {
            NormPoint(x: source.frame.x + Double(p.x / bw) * source.frame.width, y: source.frame.y + Double(p.y / bh) * source.frame.height)
        }
        func pageRect(_ r: CGRect) -> NormRect {
            NormRect(x: source.frame.x + Double(r.minX / bw) * source.frame.width, y: source.frame.y + Double(r.minY / bh) * source.frame.height,
                     width: Double(r.width / bw) * source.frame.width, height: Double(r.height / bh) * source.frame.height)
        }
        // Page points per bitmap pixel (horizontal).
        let pointsPerPixel = Double(source.frame.width) * Double(pageSize.width) / Double(bw)

        var result: [Found] = []
        for component in graph.components() where StructureRecognizer.looksLikeStructure(graph, atoms: component) {
            let set = Set(component)
            // Left-to-right ids.
            let ordered = component.sorted { (graph.atoms[$0].point.x, graph.atoms[$0].point.y) < (graph.atoms[$1].point.x, graph.atoms[$1].point.y) }
            var index: [Int: Int] = [:]
            for (i, a) in ordered.enumerated() { index[a] = i }
            let bonds = graph.bonds.filter { set.contains($0.a) }.map { PageStructure.Bond(a: index[$0.a]!, b: index[$0.b]!, order: $0.order) }

            // Labels.
            var readings: [AtomLabelReader.Reading?] = []
            for a in ordered {
                guard let g = graph.atoms[a].glyph else { readings.append(nil); continue }
                let box = graph.glyphs[g].box
                let normBox = NormRect(x: Double(box.minX / bw), y: Double(box.minY / bh), width: Double(box.width / bw), height: Double(box.height / bh))
                let p = graph.atoms[a].point
                let directions = graph.neighbors(of: a).map { atan2(graph.atoms[$0].point.y - p.y, graph.atoms[$0].point.x - p.x) }
                if let hint = source.hints.first(where: { $0.box.insetBy(dx: -0.01, dy: -0.01).intersectionOverUnion(normBox) > 0.15 || $0.box.contains(normBox.center) }),
                   let reading = AtomLabelReader.parse(hint.text) {
                    readings.append(AtomLabelReader.ordered(reading, bondDirections: directions))
                    continue
                }
                let reading = await AtomLabelReader.read(bitmap: raster.bitmap, box: box, bondDirections: directions)
                readings.append(AtomLabelReader.ordered(reading, bondDirections: directions))
            }

            // RDKit: SMILES and hydrogens.
            let engineAtoms: [[String: Any]] = ordered.enumerated().map { i, a in
                let p = graph.atoms[a].point
                return ["symbol": readings[i]?.element ?? "C", "x": Double(p.x / graph.bondLength), "y": Double(p.y / graph.bondLength), "charge": 0]
            }
            let engineBonds: [[String: Any]] = bonds.map { ["a": $0.a, "b": $0.b, "order": $0.order] }
            let molecule = try? await MoleculeEngine.shared.molecule(fromGraph: engineAtoms, bonds: engineBonds)
            var finalBonds = bonds
            if let molecule, molecule.ok {
                for i in molecule.loweredBonds where i < finalBonds.count { finalBonds[i].order -= 1 }
            }

            var atoms: [PageStructure.Atom] = []
            for (i, a) in ordered.enumerated() {
                let reading = readings[i]
                let element = reading?.element ?? "C"
                let bondOrder = finalBonds.filter { $0.a == i || $0.b == i }.reduce(0) { $0 + $1.order }
                let hydrogens: Int
                if let molecule, molecule.ok, i < molecule.atoms.count {
                    hydrogens = molecule.atoms[i].hydrogens
                } else {
                    hydrogens = max(0, (Self.valence[element] ?? 0) - bondOrder)
                }
                let box = graph.atoms[a].glyph.map { pageRect(graph.glyphs[$0].box) }
                // A written label with H's ("OH", "H2N"): the atom is its heavy-atom letter, on the side
                // its bond comes from, so marks around it keep clear of the written H.
                var center = graph.atoms[a].point
                if let g = graph.atoms[a].glyph, let reading, reading.text.count >= 2 {
                    let glyphBox = graph.glyphs[g].box
                    let letter = min(glyphBox.height, glyphBox.width / CGFloat(reading.text.count) * 1.2)
                    let first = reading.text.first.map { String($0) } ?? ""
                    let heavyFirst = first == reading.element.prefix(1).description
                    center = CGPoint(x: heavyFirst ? glyphBox.minX + letter / 2 : glyphBox.maxX - letter / 2, y: glyphBox.midY)
                }
                atoms.append(PageStructure.Atom(
                    id: "a\(i + 1)", element: element, label: reading?.text, point: pagePoint(center),
                    labelBox: box, hydrogens: hydrogens, writtenHydrogens: reading?.writtenHydrogens ?? 0,
                    charge: molecule?.ok == true && i < (molecule?.atoms.count ?? 0) ? molecule!.atoms[i].charge : 0,
                    aromatic: molecule?.ok == true && i < (molecule?.atoms.count ?? 0) ? molecule!.atoms[i].aromatic : false,
                    unsure: reading.map { !$0.confident } ?? false
                ))
            }
            var region = CGRect.null
            for a in component {
                let p = graph.atoms[a].point
                region = region.union(CGRect(x: p.x, y: p.y, width: 0, height: 0))
                if let g = graph.atoms[a].glyph { region = region.union(graph.glyphs[g].box) }
            }
            result.append(Found(
                kind: source.kind, atoms: atoms, bonds: finalBonds,
                smiles: molecule?.ok == true ? molecule?.smiles : nil,
                bondLength: Double(graph.bondLength) * pointsPerPixel,
                region: pageRect(region.insetBy(dx: -graph.bondLength * 0.25, dy: -graph.bondLength * 0.25))
            ))
        }
        // Shapes, except rings that are part of a molecule.
        let shapes = raster.shapes.compactMap { shape -> FoundShape? in
            let center = pagePoint(shape.center)
            if result.contains(where: { $0.region.contains(center) }) { return nil }
            return FoundShape(kind: PageShape.Kind(rawValue: shape.kind.rawValue) ?? .polygon,
                              vertices: shape.vertices.map(pagePoint), center: center,
                              radius: Double(shape.radius) * pointsPerPixel,
                              angles: ShapeFinder.angles(shape.vertices).map { ($0 * 10).rounded() / 10 })
        }
        // Parts, in page space (marks that are a molecule's bonds aren't parts).
        func imagePoint(_ p: CGPoint) -> NormPoint {
            NormPoint(x: source.frame.x + Double(p.x) * source.frame.width, y: source.frame.y + Double(p.y) * source.frame.height)
        }
        var parts: [FoundPart] = []
        var keep = [Bool](repeating: true, count: raster.parts.count)
        for (i, part) in raster.parts.enumerated() where part.kind == .marks {
            if result.contains(where: { $0.region.contains(imagePoint(part.point)) }) { keep[i] = false }
        }
        var newIndex: [Int: Int] = [:]
        for i in raster.parts.indices where keep[i] { newIndex[i] = newIndex.count }
        for (i, part) in raster.parts.enumerated() where keep[i] {
            var p = part
            p.parent = part.parent.flatMap { newIndex[$0] }
            let b = part.box
            parts.append(FoundPart(
                part: p,
                box: NormRect(x: source.frame.x + Double(b.minX) * source.frame.width, y: source.frame.y + Double(b.minY) * source.frame.height,
                              width: Double(b.width) * source.frame.width, height: Double(b.height) * source.frame.height),
                point: imagePoint(part.point), outline: part.outline.map(imagePoint), picture: source.frame
            ))
        }
        return Analysis(structures: result, shapes: shapes, parts: parts)
    }

    /// Typical valence when RDKit can't vouch for the drawing.
    nonisolated static let valence: [String: Int] = ["C": 4, "N": 3, "O": 2, "S": 2, "P": 3, "B": 3, "F": 1, "Cl": 1, "Br": 1, "I": 1, "Si": 4]

    static func clearCache() {
        cache = [:]
        cacheOrder = []
    }
}
