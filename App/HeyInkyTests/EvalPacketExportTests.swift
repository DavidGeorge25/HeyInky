import Foundation
import Testing
import UIKit
@testable import HeyInky

/// Builds the eval "context packets" with the app's real pipeline (grid rendering,
/// Vision OCR, mark overlay, prompt builder) and writes the exact request bodies to
/// `evals/out/packets/`. `evals/run_evals.py` then sends them through the proxy and scores.
/// Opt-in; run via `evals/export_packets.sh`:
///
///     TEST_RUNNER_INKY_EVAL_DIR=$PWD/evals xcodebuild test ... -only-testing:HeyInkyTests/EvalPacketExportTests
@MainActor
@Suite("Eval packet export (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["INKY_EVAL_DIR"] != nil))
struct EvalPacketExportTests {
    struct CaseFile: Decodable {
        var cases: [EvalCase]
    }

    struct EvalCase: Decodable {
        struct Existing: Decodable { var action: InkyAction; var question: String? }
        struct Turn: Decodable { var question: String; var actions: [InkyAction]; var created: [Int] }
        var id: String
        var page: String
        var question: String
        var lasso: [Double]?
        var pdfText: Bool
        var existing: [Existing]
        var history: [Turn]
    }

    struct PageText: Decodable {
        struct Line: Decodable { var text: String; var box: [Double] }
        var size: [Double]
        var lines: [Line]
    }

    @Test(.timeLimit(.minutes(10)))
    func exportPackets() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["INKY_EVAL_DIR"]))
        let outDir = env["INKY_EVAL_OUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("out/packets")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        applyTuning(env["INKY_EVAL_TUNING"])

        let cases = try JSONDecoder().decode(CaseFile.self, from: Data(contentsOf: root.appendingPathComponent("cases.json"))).cases
        let only = env["INKY_EVAL_ONLY"].flatMap { $0.isEmpty ? nil : $0 }.map { Set($0.split(separator: ",").map(String.init)) }
        var ocrCache: [String: [RecognizedTextLine]] = [:]

        for c in cases where only?.contains(c.id) ?? true {
            let pageURL = root.appendingPathComponent("pages/\(c.page).png")
            let image = try #require(UIImage(contentsOfFile: pageURL.path), "missing \(pageURL.path)")
            let text = try JSONDecoder().decode(PageText.self, from: Data(contentsOf: root.appendingPathComponent("pages/\(c.page).json")))
            let pageSize = CGSize(width: text.size[0], height: text.size[1])
            // Draw at page-point size so the renderer sees the app's page geometry.
            let pageImage = UIGraphicsImageRenderer(size: pageSize, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 2; return f }())
                .image { _ in image.draw(in: CGRect(origin: .zero, size: pageSize)) }

            let lines: [RecognizedTextLine]
            if c.pdfText {
                // Typed PDF pages: the app reads the PDF text layer (exact boxes).
                lines = text.lines.map { RecognizedTextLine(text: $0.text, box: NormRect(x: $0.box[0], y: $0.box[1], width: $0.box[2], height: $0.box[3])) }
            } else if let cached = ocrCache[c.page] {
                lines = cached
            } else {
                lines = await InkyLocalization.recognizeText(in: try #require(pageImage.cgImage))
                ocrCache[c.page] = lines
            }

            let annotations = c.existing.enumerated().map { index, e in
                let annotation = InkyAnnotation(id: Self.uuid(index), action: e.action, question: e.question)
                return InkyPageAnnotation(id: annotation.id, action: e.action,
                                          bounds: InkyAnnotationGeometry.bounds(for: annotation, pageSize: pageSize),
                                          question: e.question)
            }
            let history = c.history.enumerated().map { offset, t in
                InkyTurn(question: t.question, actions: t.actions, createdAnnotationIDs: t.created.map(Self.uuid),
                         date: Date(timeIntervalSinceNow: Double(offset - c.history.count) * 60))
            }
            let lasso = c.lasso.map { NormRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
            let lassoPath = lasso.map { r in [NormPoint(x: r.minX, y: r.minY), NormPoint(x: r.maxX, y: r.minY), NormPoint(x: r.maxX, y: r.maxY), NormPoint(x: r.minX, y: r.maxY)] } ?? []

            let request = await InkyContextBuilder.makeRequest(
                question: c.question, pageImage: pageImage, recognizedText: lines,
                lassoRegion: lasso, lassoPath: lassoPath,
                pageAspectRatio: pageSize.width / pageSize.height, notebookTitle: nil,
                annotations: annotations, history: history
            )
            try InkyPromptBuilder.bodyData(for: request).write(to: outDir.appendingPathComponent("\(c.id).json"))
            for (i, img) in request.images.enumerated() {
                try img.pngData.write(to: outDir.appendingPathComponent("\(c.id).img\(i).png"))
            }
            let meta: [String: Any] = [
                "ocrLines": lines.map { ["text": $0.text, "box": [$0.box.x, $0.box.y, $0.box.width, $0.box.height]] },
                "annotationIDs": annotations.map(\.id.uuidString),
                "blanks": request.blanks.map { [$0.x, $0.y, $0.width, $0.height] },
                "imageBytes": request.images.map(\.pngData.count),
            ]
            try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]).write(to: outDir.appendingPathComponent("\(c.id).meta.json"))
        }
    }

    static func uuid(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
    }

    /// `INKY_EVAL_TUNING="fullPageLongEdge=1536,cropLongEdge=1024"` for grid experiments.
    func applyTuning(_ spec: String?) {
        guard let spec else { return }
        for pair in spec.split(separator: ",") {
            let kv = pair.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let v = Double(kv[1]) else { continue }
            switch kv[0] {
            case "fullPageLongEdge": InkyLocalization.tuning.fullPageLongEdge = v
            case "cropLongEdge": InkyLocalization.tuning.cropLongEdge = v
            case "cropPadding": InkyLocalization.tuning.cropPadding = v
            case "gridLineAlpha": InkyLocalization.tuning.gridLineAlpha = v
            case "minorGridLines": InkyLocalization.tuning.minorGridLines = v != 0
            case "labelAllEdges": InkyLocalization.tuning.labelAllEdges = v != 0
            case "detectBlanks": InkyLocalization.tuning.detectBlanks = v != 0
            default: break
            }
        }
    }
}
