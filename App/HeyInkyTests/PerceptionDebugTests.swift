import PencilKit
import Testing
import UIKit
@testable import HeyInky

@MainActor
@Suite("Perception debug", .enabled(if: ProcessInfo.processInfo.environment["INKY_DEBUG_PERCEPTION"] == "1"))
struct PerceptionDebugTests {
    @Test func dumpInk() async throws {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "Ink", paper: .blank)
        store.saveDrawing(PerceptionTests.isoamylAlcoholInk(), for: notebook.pages[0].id, in: notebook.id)
        let editor = PageEditorModel(notebookID: notebook.id, page: notebook.pages[0], store: store)
        let sources = PageStructureFinder.sources(editor: editor, text: [])
        for source in sources {
            let (bitmap, _) = try #require(InkBitmap.threshold(source.image, maxSide: 1400, exclude: source.exclude))
            let art = LineArt(bitmap: bitmap)
            let graph = StructureRecognizer.recognize(art)
            print("DEBUG source \(source.kind) bitmap \(bitmap.width)x\(bitmap.height) ink \(bitmap.inkCount) sw \(art.strokeWidth) polylines \(art.polylines.count) L \(graph.bondLength) atoms \(graph.atoms.count) bonds \(graph.bonds.count) glyphs \(graph.glyphs.count)")
            for (i, a) in graph.atoms.enumerated() { print("DEBUG  atom \(i) \(a.point) glyph \(a.glyph.map(String.init) ?? "-") deg \(a.bonds.count)") }
            for comp in graph.components() { print("DEBUG  component \(comp) looks \(StructureRecognizer.looksLikeStructure(graph, atoms: comp))") }
            if let dir = ProcessInfo.processInfo.environment["INKY_DUMP_DIR"] {
                try UIImage(cgImage: source.image).pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ink_source.png"))
            }
        }
    }
}

@MainActor
@Suite("Perception debug image", .enabled(if: ProcessInfo.processInfo.environment["INKY_DEBUG_PERCEPTION"] == "1"))
struct PerceptionDebugImageTests {
    @Test func dumpImageAtoms() async throws {
        let editor = try PerceptionTests.imageEditor()
        PageStructureFinder.clearCache()
        let s = try #require(await PageStructureFinder.find(editor: editor, text: []).first)
        let size = editor.page.size
        for a in s.atoms where a.label != nil {
            let p = a.point.cgPoint(in: size)
            print("DEBUG \(a.id) \(a.element) label \(a.label ?? "-") point (\(Int(p.x)),\(Int(p.y))) box \(a.labelBox.map { $0.cgRect(in: size).integral } ?? .zero) H \(a.hydrogens) written \(a.writtenHydrogens) LP \(StructureAnnotator.lonePairs(s, s.atomIndex(a.id)!))")
        }
        var g = StructureAnnotator.Geometry(structure: s, pageSize: size)
        for a in s.atoms where a.element == "O" {
            let i = s.atomIndex(a.id)!
            print("DEBUG \(a.id) bonds \(g.bondAngles(i).map { Int($0 * 180 / .pi) }) obstacles \(g.labelObstacles(i)) radius \(g.radius(i))")
            print("DEBUG  pairs \(g.placeLonePairs(atom: i, count: 2).map { $0.map { "(\(Int($0.x)),\(Int($0.y)))" } })")
        }
    }
}

@MainActor
@Suite("Perception debug scenario", .enabled(if: ProcessInfo.processInfo.environment["INKY_DEBUG_PERCEPTION"] == "1"))
struct PerceptionDebugScenarioTests {
    @Test func dumpScenario() async throws {
        let editor = try PerceptionTests.imageEditor()
        var page = editor.page
        let aspect = page.images[0].frame.height / page.images[0].frame.width
        page.images[0].frame = NormRect(x: 0.1, y: 0.18, width: 0.5, height: 0.5 * aspect)
        editor.store.updatePage(page, in: editor.notebookID)
        let fresh = PageEditorModel(notebookID: editor.notebookID, page: editor.store.notebook(id: editor.notebookID)!.pages[0], store: editor.store)
        let (_, lines) = await fresh.snapshotForInky()
        for l in lines { print("DEBUG line \"\(l.text)\" \(l.box)") }
        PageStructureFinder.clearCache()
        let s = try #require(await PageStructureFinder.find(editor: fresh, text: lines).first)
        let size = fresh.page.size
        for a in s.atoms where a.label != nil {
            let p = a.point.cgPoint(in: size)
            print("DEBUG \(a.id) \(a.element) label \(a.label ?? "-") point (\(Int(p.x)),\(Int(p.y))) box \(a.labelBox.map { $0.cgRect(in: size).integral } ?? .zero)")
        }
    }
}
