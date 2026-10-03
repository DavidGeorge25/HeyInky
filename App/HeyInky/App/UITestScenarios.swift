#if DEBUG
import UIKit

/// QA content for UI tests and manual end-to-end runs (DEBUG builds only). Launch arguments:
///   -InkyUITestLibrary <name>   fixed library folder in tmp, so a relaunch sees the same notebooks
///                               (with `-InkyUITestReset YES` it is wiped first)
///   -InkyUITestScenario <a,b>   seed notebooks: molecule, asymptotes, worksheet
///   -InkyUITestImage <path>     the molecule scenario's image (a handwritten structure)
///   -InkyUITestSpeech "<text>"  `SpeechInput` hears this instead of the microphone
@MainActor
enum UITestScenarios {
    static let moleculeTitle = "Organic structures"
    static let asymptotesTitle = "Lecture 9 – Rational functions"
    static let worksheetTitle = "Warm-up worksheet"

    /// Worksheet questions and their answers (the UI tests check Inky's fills against these).
    static let worksheet: [(question: String, answer: String)] = [
        ("1.  7 × 8 =", "56"),
        ("2.  144 ÷ 12 =", "12"),
        ("3.  15% of 80 =", "12"),
        ("4.  Molar mass of H₂O (g/mol) =", "18"),
    ]

    static func libraryRoot(named name: String, reset: Bool) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UITestLibrary-\(name)")
        if reset { try? FileManager.default.removeItem(at: root) }
        return root
    }

    static func seed(_ scenarios: String, into store: NotebookStore, imagePath: String?) {
        for name in scenarios.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch name {
            case "molecule": seedMolecule(into: store, imagePath: imagePath)
            case "asymptotes": seedPDF(title: asymptotesTitle, into: store, write: writeRationalSlide)
            case "worksheet": seedPDF(title: worksheetTitle, into: store, write: writeWorksheet)
            default: break
            }
        }
    }

    private static func exists(_ title: String, in store: NotebookStore) -> Bool {
        store.notebooks.contains { $0.title == title }
    }

    /// A grid page with a photo of a handwritten structure placed on it.
    private static func seedMolecule(into store: NotebookStore, imagePath: String?) {
        guard !exists(moleculeTitle, in: store), let imagePath,
              let data = FileManager.default.contents(atPath: imagePath) else { return }
        let notebook = store.createNotebook(title: moleculeTitle, paper: .grid)
        guard let page = notebook.pages.first,
              var placed = try? store.addImage(data, to: page.id, in: notebook.id, center: NormPoint(x: 0.4, y: 0.3)),
              var fresh = store.notebook(id: notebook.id)?.pages.first else { return }
        // About half the page wide, like a structure drawn in the notes.
        let aspect = placed.frame.height / max(placed.frame.width, 0.0001)
        placed.frame = NormRect(x: 0.1, y: 0.18, width: 0.5, height: 0.5 * aspect)
        if let index = fresh.images.firstIndex(where: { $0.id == placed.id }) {
            fresh.images[index] = placed
            store.updatePage(fresh, in: notebook.id)
        }
    }

    private static func seedPDF(title: String, into store: NotebookStore, write: () throws -> URL) {
        guard !exists(title, in: store), let url = try? write() else { return }
        _ = try? store.importPDF(from: url, title: title)
        try? FileManager.default.removeItem(at: url)
    }

    /// A landscape lecture slide with a rational function (vertical asymptote x = 3, horizontal y = 2).
    static func writeRationalSlide() throws -> URL {
        let size = CGSize(width: 1024, height: 768)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RationalSlide-\(UUID().uuidString).pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).writePDF(to: url) { ctx in
            ctx.beginPage()
            let ink = UIColor(white: 0.12, alpha: 1)
            UIColor(red: 0.36, green: 0.36, blue: 0.84, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 10))
            draw("Rational Functions", at: CGPoint(x: 72, y: 60), font: .systemFont(ofSize: 40, weight: .bold), color: ink)
            draw("Example 3", at: CGPoint(x: 72, y: 150), font: .systemFont(ofSize: 22, weight: .semibold), color: .gray)
            draw("f(x) = (2x + 1) / (x − 3)", at: CGPoint(x: 72, y: 200), font: .systemFont(ofSize: 34, weight: .medium), color: ink)
            let body = UIFont.systemFont(ofSize: 22)
            var y: CGFloat = 300
            for line in ["• Domain: all real x except x = 3", "• Find the intercepts", "• Find the vertical and horizontal asymptotes", "• Sketch the graph"] {
                draw(line, at: CGPoint(x: 72, y: y), font: body, color: ink)
                y += 44
            }
            draw("MATH 120 · Week 9", at: CGPoint(x: 72, y: 700), font: .systemFont(ofSize: 14), color: .gray)
        }
        return url
    }

    /// A worksheet: each question is followed by an empty answer box.
    static func writeWorksheet() throws -> URL {
        let size = CGSize(width: 816, height: 1056)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Worksheet-\(UUID().uuidString).pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).writePDF(to: url) { ctx in
            ctx.beginPage()
            let ink = UIColor(white: 0.12, alpha: 1)
            draw("Warm-up: quick calculations", at: CGPoint(x: 72, y: 72), font: .systemFont(ofSize: 28, weight: .bold), color: ink)
            draw("Write your answer in the box.", at: CGPoint(x: 72, y: 120), font: .systemFont(ofSize: 16), color: .gray)
            let font = UIFont.systemFont(ofSize: 22)
            var y: CGFloat = 200
            for item in worksheet {
                draw(item.question, at: CGPoint(x: 72, y: y), font: font, color: ink)
                let box = CGRect(x: 480, y: y - 12, width: 150, height: 52)
                ink.setStroke()
                let path = UIBezierPath(rect: box)
                path.lineWidth = 1.5
                path.stroke()
                y += 110
            }
        }
        return url
    }

    private static func draw(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}
#endif
