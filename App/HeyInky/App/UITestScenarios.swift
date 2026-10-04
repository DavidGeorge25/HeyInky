#if DEBUG
import PencilKit
import UIKit

/// QA content for UI tests and manual end-to-end runs (DEBUG builds only). Launch arguments:
///   -InkyUITestLibrary <name>   fixed library folder in tmp, so a relaunch sees the same notebooks
///                               (with `-InkyUITestReset YES` it is wiped first)
///   -InkyUITestScenario <a,b>   seed notebooks: molecule, asymptotes, worksheet, skeleton
///   -InkyUITestImage <path>     the molecule scenario's image (a handwritten structure)
///   -InkyUITestSpeech "<text>"  `SpeechInput` hears this instead of the microphone
@MainActor
enum UITestScenarios {
    static let moleculeTitle = "Organic structures"
    static let asymptotesTitle = "Lecture 9 – Rational functions"
    static let worksheetTitle = "Warm-up worksheet"
    static let skeletonTitle = "Hydrogen practice"
    static let algebraTitle = "Algebra homework"
    static let physicsTitle = "Physics – Forces"
    static let biologyTitle = "Bio – Cellular respiration"
    static let stoichTitle = "Chem – Balancing equations"
    static let geometryTitle = "Geometry – Triangles"
    static let cellTitle = "Bio – Cell diagram"
    static let labTitle = "Physics lab – Motion"

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
            case "skeleton": seedSkeleton(into: store)
            case "algebra": seedPDF(title: algebraTitle, into: store, write: writeAlgebraHomework)
            case "physics": seedPDF(title: physicsTitle, into: store, write: writeInclineSlide)
            case "biology": seedPDF(title: biologyTitle, into: store, write: writeRespirationNotes)
            case "stoich": seedPDF(title: stoichTitle, into: store, write: writeBalancing)
            case "geometry": seedPDF(title: geometryTitle, into: store, write: writeTriangle)
            case "lab": seedPDF(title: labTitle, into: store, write: writeLabData)
            case "cell": seedCellImage(into: store)
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

    /// Methylcyclohexane drawn in pen ink the way a student would: the ring in one stroke, then
    /// the methyl branch. (C₇H₁₄: 14 hidden hydrogens.)
    private static func seedSkeleton(into store: NotebookStore) {
        guard !exists(skeletonTitle, in: store) else { return }
        let notebook = store.createNotebook(title: skeletonTitle, paper: .blank)
        guard let page = notebook.pages.first else { return }
        let center = CGPoint(x: 300, y: 380), r: CGFloat = 62
        // Pointy-top hexagon, starting at the top vertex, closing back on itself.
        let ring = (0...6).map { i -> CGPoint in
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 3
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        let upperRight = ring[1]
        let branch = [upperRight, CGPoint(x: upperRight.x + r * cos(-.pi / 6), y: upperRight.y + r * sin(-.pi / 6))]
        let drawing = PKDrawing(strokes: [handStroke(ring, seed: 1), handStroke(branch, seed: 2)])
        store.saveDrawing(drawing, for: page.id, in: notebook.id)
    }

    private static func handStroke(_ corners: [CGPoint], seed: Int) -> PKStroke {
        var points: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let steps = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 3))
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps)
                let wobble = sin(CGFloat(points.count + seed * 17) * 0.21) * 0.8
                points.append(CGPoint(x: a.x + (b.x - a.x) * t + wobble, y: a.y + (b.y - a.y) * t - wobble))
            }
        }
        points.append(corners[corners.count - 1])
        let strokePoints = points.enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) * 0.01, size: CGSize(width: 3.2, height: 3.2),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: UIColor(red: 0.15, green: 0.2, blue: 0.45, alpha: 1)),
                        path: PKStrokePath(controlPoints: strokePoints, creationDate: Date(timeIntervalSince1970: 0)))
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

    /// A homework problem with the student's working (handwriting font) and a sign slip in line 1:
    /// 3(x − 2) = 2x + 5 → "3x − 2 = 2x + 5" (should be 3x − 6), so they get x = 7 instead of 11.
    static func writeAlgebraHomework() throws -> URL {
        try writePage(name: "Algebra") { ink in
            draw("Homework 4 — Linear equations", at: CGPoint(x: 72, y: 72), font: .systemFont(ofSize: 26, weight: .bold), color: ink)
            draw("Q3.  Solve for x:   3(x − 2) = 2x + 5", at: CGPoint(x: 72, y: 150), font: .systemFont(ofSize: 22), color: ink)
            let hand = UIFont(name: "Noteworthy-Bold", size: 24) ?? .systemFont(ofSize: 24)
            let pen = UIColor(red: 0.10, green: 0.20, blue: 0.55, alpha: 1)
            var y: CGFloat = 220
            for line in ["3x − 2 = 2x + 5", "3x − 2x = 5 + 2", "x = 7"] {
                draw(line, at: CGPoint(x: 110, y: y), font: hand, color: pen)
                y += 56
            }
        }
    }

    /// A physics slide: a block on a 30° frictionless incline, drawn.
    static func writeInclineSlide() throws -> URL {
        try writePage(name: "Incline") { ink in
            draw("Forces on an incline", at: CGPoint(x: 72, y: 72), font: .systemFont(ofSize: 28, weight: .bold), color: ink)
            draw("A 5.0 kg block rests on a frictionless ramp inclined at 30°.", at: CGPoint(x: 72, y: 130), font: .systemFont(ofSize: 18), color: ink)
            draw("(a) Draw the free-body diagram.  (b) Find the acceleration.", at: CGPoint(x: 72, y: 160), font: .systemFont(ofSize: 18), color: ink)
            let a = CGPoint(x: 120, y: 520), b = CGPoint(x: 520, y: 520), c = CGPoint(x: 520, y: 289)
            let ramp = UIBezierPath()
            ramp.move(to: a); ramp.addLine(to: b); ramp.addLine(to: c); ramp.close()
            ramp.lineWidth = 2
            ink.setStroke(); ramp.stroke()
            // The block sits on the slope, rotated 30°.
            let ctx = UIGraphicsGetCurrentContext()!
            ctx.saveGState()
            ctx.translateBy(x: 330, y: 410)
            ctx.rotate(by: -.pi / 6)
            let block = UIBezierPath(rect: CGRect(x: -35, y: -60, width: 70, height: 60))
            block.lineWidth = 2
            UIColor(white: 0.93, alpha: 1).setFill(); block.fill(); block.stroke()
            ctx.restoreGState()
            draw("30°", at: CGPoint(x: 165, y: 490), font: .systemFont(ofSize: 18), color: ink)
            draw("m = 5.0 kg", at: CGPoint(x: 300, y: 300), font: .systemFont(ofSize: 16), color: .gray)
        }
    }

    /// Lecture notes (text only) on cellular respiration.
    static func writeRespirationNotes() throws -> URL {
        try writePage(name: "Respiration") { ink in
            draw("Cellular respiration", at: CGPoint(x: 72, y: 72), font: .systemFont(ofSize: 28, weight: .bold), color: ink)
            let body = UIFont.systemFont(ofSize: 17)
            var y: CGFloat = 140
            for line in [
                "C₆H₁₂O₆ + 6 O₂ → 6 CO₂ + 6 H₂O + energy (~30–32 ATP)",
                "1. Glycolysis (cytoplasm): glucose → 2 pyruvate, net 2 ATP + 2 NADH",
                "2. Pyruvate oxidation: pyruvate → acetyl-CoA + CO₂ (mitochondrial matrix)",
                "3. Krebs / citric acid cycle (matrix): 2 ATP, 6 NADH, 2 FADH₂, CO₂ released",
                "4. Electron transport chain (inner membrane): NADH/FADH₂ → ~26–28 ATP",
                "   O₂ is the final electron acceptor → water",
                "Without O₂: fermentation (lactate in muscle, ethanol in yeast) — 2 ATP only",
            ] {
                draw(line, at: CGPoint(x: 72, y: y), font: body, color: ink)
                y += 40
            }
        }
    }

    /// Equations to balance.
    static func writeBalancing() throws -> URL {
        try writePage(name: "Balancing") { ink in
            draw("Balance these equations", at: CGPoint(x: 72, y: 72), font: .systemFont(ofSize: 28, weight: .bold), color: ink)
            let font = UIFont.systemFont(ofSize: 22)
            var y: CGFloat = 160
            for line in ["1.   Fe + O₂ → Fe₂O₃", "2.   C₃H₈ + O₂ → CO₂ + H₂O", "3.   Al + HCl → AlCl₃ + H₂"] {
                draw(line, at: CGPoint(x: 72, y: y), font: font, color: ink)
                y += 90
            }
        }
    }

    /// A triangle with two sides and the included angle given: find the third side (law of cosines).
    static func writeTriangle() throws -> URL {
        try writePage(name: "Triangle") { ink in
            draw("Q5.  In triangle ABC, a = 7 cm, b = 9 cm and C = 52°.", at: CGPoint(x: 72, y: 80), font: .systemFont(ofSize: 20), color: ink)
            draw("Find side c and angle A.", at: CGPoint(x: 72, y: 112), font: .systemFont(ofSize: 20), color: ink)
            let A = CGPoint(x: 150, y: 520), B = CGPoint(x: 560, y: 520), C = CGPoint(x: 330, y: 250)
            let tri = UIBezierPath()
            tri.move(to: A); tri.addLine(to: B); tri.addLine(to: C); tri.close()
            tri.lineWidth = 2
            ink.setStroke(); tri.stroke()
            let f = UIFont.systemFont(ofSize: 20, weight: .medium)
            draw("A", at: CGPoint(x: 126, y: 524), font: f, color: ink)
            draw("B", at: CGPoint(x: 568, y: 524), font: f, color: ink)
            draw("C", at: CGPoint(x: 322, y: 220), font: f, color: ink)
            draw("9 cm", at: CGPoint(x: 190, y: 360), font: .systemFont(ofSize: 17), color: ink)
            draw("7 cm", at: CGPoint(x: 460, y: 360), font: .systemFont(ofSize: 17), color: ink)
            draw("52°", at: CGPoint(x: 316, y: 282), font: .systemFont(ofSize: 15), color: ink)
        }
    }

    /// A lab data table (roughly linear: v ≈ 2.1 m/s).
    static func writeLabData() throws -> URL {
        try writePage(name: "Lab") { ink in
            draw("Lab 2 — Constant velocity cart", at: CGPoint(x: 72, y: 72), font: .systemFont(ofSize: 26, weight: .bold), color: ink)
            let rows = [("t (s)", "x (m)"), ("0.0", "0.10"), ("1.0", "2.25"), ("2.0", "4.30"), ("3.0", "6.42"), ("4.0", "8.51"), ("5.0", "10.60")]
            var y: CGFloat = 150
            for (i, row) in rows.enumerated() {
                let font = i == 0 ? UIFont.systemFont(ofSize: 18, weight: .semibold) : .monospacedDigitSystemFont(ofSize: 18, weight: .regular)
                draw(row.0, at: CGPoint(x: 100, y: y), font: font, color: ink)
                draw(row.1, at: CGPoint(x: 220, y: y), font: font, color: ink)
                y += 34
            }
            draw("Plot x vs t and find the cart's velocity.", at: CGPoint(x: 72, y: y + 30), font: .systemFont(ofSize: 18), color: ink)
        }
    }

    /// An unlabeled animal cell drawn as an image, placed on a blank page.
    private static func seedCellImage(into store: NotebookStore) {
        guard !exists(cellTitle, in: store) else { return }
        let image = cellImage()
        guard let data = image.pngData() else { return }
        let notebook = store.createNotebook(title: cellTitle, paper: .blank)
        guard let page = notebook.pages.first,
              var placed = try? store.addImage(data, to: page.id, in: notebook.id, center: NormPoint(x: 0.5, y: 0.35)),
              var fresh = store.notebook(id: notebook.id)?.pages.first else { return }
        let aspect = placed.frame.height / max(placed.frame.width, 0.0001)
        placed.frame = NormRect(x: 0.08, y: 0.12, width: 0.84, height: 0.84 * aspect)
        if let index = fresh.images.firstIndex(where: { $0.id == placed.id }) {
            fresh.images[index] = placed
            store.updatePage(fresh, in: notebook.id)
        }
    }

    /// An unlabeled textbook-style animal cell: membrane, nucleus + nucleolus, two mitochondria,
    /// rough ER (wavy lines), Golgi (stacked arcs).
    static func cellImage() -> UIImage {
        let size = CGSize(width: 900, height: 620)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            UIColor.white.setFill(); g.fill(CGRect(origin: .zero, size: size))
            g.setLineWidth(4)
            // Membrane
            UIColor(red: 0.93, green: 0.97, blue: 0.93, alpha: 1).setFill()
            UIColor(white: 0.15, alpha: 1).setStroke()
            let cell = UIBezierPath(ovalIn: CGRect(x: 60, y: 50, width: 780, height: 520)); cell.lineWidth = 4; cell.fill(); cell.stroke()
            // Nucleus + nucleolus
            UIColor(red: 0.85, green: 0.88, blue: 0.98, alpha: 1).setFill()
            let nucleus = UIBezierPath(ovalIn: CGRect(x: 330, y: 200, width: 220, height: 190)); nucleus.lineWidth = 4; nucleus.fill(); nucleus.stroke()
            UIColor(red: 0.55, green: 0.60, blue: 0.90, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 415, y: 270, width: 55, height: 50)).fill()
            // Mitochondria
            for frame in [CGRect(x: 150, y: 330, width: 130, height: 60), CGRect(x: 610, y: 150, width: 120, height: 55)] {
                UIColor(red: 1.0, green: 0.88, blue: 0.80, alpha: 1).setFill()
                let m = UIBezierPath(ovalIn: frame); m.lineWidth = 3; m.fill(); m.stroke()
                let cristae = UIBezierPath()
                cristae.move(to: CGPoint(x: frame.minX + 15, y: frame.midY))
                for k in 0..<5 {
                    let x = frame.minX + 15 + CGFloat(k) * (frame.width - 30) / 5
                    cristae.addQuadCurve(to: CGPoint(x: x + (frame.width - 30) / 5, y: frame.midY), controlPoint: CGPoint(x: x + (frame.width - 30) / 10, y: frame.midY + (k % 2 == 0 ? -18 : 18)))
                }
                cristae.lineWidth = 2.5; cristae.stroke()
            }
            // Rough ER: wavy lines beside the nucleus
            for k in 0..<3 {
                let er = UIBezierPath()
                let y0 = CGFloat(220 + k * 28)
                er.move(to: CGPoint(x: 580, y: y0 + 120))
                er.addCurve(to: CGPoint(x: 760, y: y0 + 140), controlPoint1: CGPoint(x: 640, y: y0 + 90), controlPoint2: CGPoint(x: 700, y: y0 + 170))
                er.lineWidth = 3; er.stroke()
            }
            // Golgi: stacked arcs, lower left
            for k in 0..<4 {
                let golgi = UIBezierPath()
                let y0 = CGFloat(420 + k * 16)
                golgi.move(to: CGPoint(x: 330, y: y0)); golgi.addQuadCurve(to: CGPoint(x: 450, y: y0), controlPoint: CGPoint(x: 390, y: y0 - 22))
                golgi.lineWidth = 3; golgi.stroke()
            }
        }
        return image
    }

    private static func writePage(name: String, draw body: (UIColor) -> Void) throws -> URL {
        let size = CGSize(width: 816, height: 1056)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).writePDF(to: url) { ctx in
            ctx.beginPage()
            body(UIColor(white: 0.12, alpha: 1))
        }
        return url
    }

    private static func draw(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}
#endif
