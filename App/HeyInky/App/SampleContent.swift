import UIKit

/// A sample "lecture slide" notebook so a fresh install has something to ask Inky about.
/// Also used by UI tests and the live integration test.
@MainActor
enum SampleContent {
    static let notebookTitle = "Welcome to Hey Inky"
    static let pageTitle = "Lecture 7: Chemical Equilibrium"

    /// Where the title is drawn, in normalized page coordinates (for tests).
    static var titleRegion: NormRect {
        NormRect(CGRect(x: 72, y: 72, width: titleSize.width, height: titleSize.height), in: pageSize)
    }

    static let pageSize = CGSize(width: 816, height: 1056)
    private static let titleFont = UIFont.systemFont(ofSize: 34, weight: .bold)
    private static var titleSize: CGSize { (pageTitle as NSString).size(withAttributes: [.font: titleFont]) }

    static func seed(into store: NotebookStore) {
        guard let url = try? writeSamplePDF() else { return }
        _ = try? store.importPDF(from: url, title: notebookTitle)
        try? FileManager.default.removeItem(at: url)
    }

    static func writeSamplePDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HeyInkySample-\(UUID().uuidString).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        try renderer.writePDF(to: url) { ctx in
            ctx.beginPage()
            let ink = UIColor(white: 0.12, alpha: 1)
            (pageTitle as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: titleFont, .foregroundColor: ink])

            let body = UIFont.systemFont(ofSize: 18)
            let lines = [
                "• A reaction at equilibrium has equal forward and reverse rates.",
                "• Le Chatelier's principle: the system shifts to oppose a change.",
                "• Equilibrium constant:  K = [C]^c [D]^d / [A]^a [B]^b",
                "• Large K: products favoured.  Small K: reactants favoured.",
                "",
                "Example: N₂ + 3H₂ ⇌ 2NH₃   (ΔH < 0)",
                "Raising the temperature shifts the equilibrium to the ____.",
            ]
            var y: CGFloat = 170
            for line in lines {
                (line as NSString).draw(at: CGPoint(x: 72, y: y), withAttributes: [.font: body, .foregroundColor: ink])
                y += 34
            }

            let box = CGRect(x: 72, y: y + 30, width: 672, height: 220)
            UIColor(white: 0.8, alpha: 1).setStroke()
            let path = UIBezierPath(roundedRect: box, cornerRadius: 10)
            path.lineWidth = 1
            path.stroke()
            ("Notes" as NSString).draw(at: CGPoint(x: box.minX + 14, y: box.minY + 10), withAttributes: [.font: UIFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: UIColor.gray])
        }
        return url
    }
}
