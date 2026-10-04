import PDFKit
import SwiftUI

/// Paper-like frame for Inky's figures (chemistry schemes, diagrams): white, hairline border,
/// optional small title and caption. Calm on the page, clearly Inky's.
struct InkyFigureFrame<Content: View>: View {
    var title: String?
    var caption: String?
    let scale: CGFloat
    @ViewBuilder var content: Content

    static var titleHeight: CGFloat { 24 }
    static var captionHeight: CGFloat { 22 }
    static var padding: CGFloat { 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 14 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.15, green: 0.15, blue: 0.18))
                    .lineLimit(1)
                    .frame(height: Self.titleHeight * scale, alignment: .bottomLeading)
                    .padding(.horizontal, Self.padding * scale)
            }
            content
                .padding(Self.padding * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12 * scale, design: .rounded))
                    .foregroundStyle(Color(red: 0.15, green: 0.15, blue: 0.18).opacity(0.7))
                    .lineLimit(2)
                    .frame(height: Self.captionHeight * scale, alignment: .topLeading)
                    .padding(.horizontal, Self.padding * scale)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.05), radius: 6 * scale, y: 2 * scale)
        )
        .overlay(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
    }

    /// Extra page points the frame adds around content of a given size.
    static func chrome(title: String?, caption: String?) -> CGSize {
        CGSize(width: 2 * padding,
               height: 2 * padding + (title?.isEmpty == false ? titleHeight : 0) + (caption?.isEmpty == false ? captionHeight : 0))
    }
}

/// An `insertDiagram` figure: the prepared SVG as a vector PDF, drawn natively at any zoom.
struct DiagramFigureView: View {
    let action: InsertDiagramAction
    @State private var page: PDFPage?
    @State private var failed: String?

    @MainActor private static var memory: [String: PDFDocument] = [:]

    var body: some View {
        Canvas { context, size in
            guard let page else { return }
            let box = page.bounds(for: .mediaBox)
            guard box.width > 0, box.height > 0 else { return }
            context.withCGContext { cg in
                let s = min(size.width / box.width, size.height / box.height)
                cg.saveGState()
                cg.translateBy(x: (size.width - box.width * s) / 2, y: (size.height + box.height * s) / 2)
                cg.scaleBy(x: s, y: -s)
                page.draw(with: .mediaBox, to: cg)
                cg.restoreGState()
            }
        }
        .overlay {
            if page == nil {
                if let failed { Text(failed).font(.caption).foregroundStyle(.secondary).padding() } else { ProgressView().controlSize(.small) }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Diagram" + (action.title.map { ": \($0)" } ?? ""))
        .accessibilityIdentifier("inky.figure.diagram")
        .task(id: action) {
            let key = action.svg + action.callouts.map { "\u{1}\($0.text)@\($0.x),\($0.y)" }.joined()
            if let cached = Self.memory[key] { page = cached.page(at: 0); return }
            do {
                let report = try await DiagramEngine.shared.prepare(svg: action.svg, callouts: action.callouts)
                guard !report.svg.isEmpty else { failed = report.problems.first ?? "This diagram couldn't be drawn."; return }
                let data = try await DiagramEngine.shared.pdf(for: report)
                guard let document = PDFDocument(data: data) else { failed = "This diagram couldn't be drawn."; return }
                Self.memory[key] = document
                page = document.page(at: 0)
            } catch {
                failed = error.localizedDescription
            }
        }
    }
}

/// Where a figure goes: the emptiest spot of the right size closest to where Inky asked for it.
enum FigurePlacement {
    /// - Parameters:
    ///   - size: figure size in page points (already fitted to the page).
    ///   - avoid: normalized rects of everything on the page (ink, text, images, marks).
    static func place(size: CGSize, near: NormRect, avoid: [NormRect], pageSize: CGSize) -> NormRect {
        let w = min(0.96, Double(size.width / pageSize.width)), h = min(0.96, Double(size.height / pageSize.height))
        let target = near.clamped.center
        var best = NormRect(x: min(max(target.x - w / 2, 0.02), 0.98 - w), y: min(max(target.y - h / 2, 0.02), 0.98 - h), width: w, height: h)
        var bestCost = Double.infinity
        let margin = 0.02
        var y = margin
        while y + h <= 1 - margin + 1e-9 {
            var x = margin
            while x + w <= 1 - margin + 1e-9 {
                let r = NormRect(x: x, y: y, width: w, height: h)
                let covered = avoid.reduce(0.0) { sum, a in
                    let ix = max(0, min(r.maxX, a.maxX) - max(r.minX, a.minX)), iy = max(0, min(r.maxY, a.maxY) - max(r.minY, a.minY))
                    return sum + ix * iy
                }
                let distance = hypot(r.center.x - target.x, (r.center.y - target.y) * Double(pageSize.height / pageSize.width))
                let cost = 40 * covered / (w * h) + distance
                if cost < bestCost { bestCost = cost; best = r }
                x += 0.02
            }
            y += 0.02
        }
        return best
    }

    /// `size` shrunk (keeping aspect) to fit the page's usable area.
    static func fitted(_ size: CGSize, pageSize: CGSize, maxWidthFraction: CGFloat = 0.92, maxHeightFraction: CGFloat = 0.62) -> CGSize {
        let f = min(1, pageSize.width * maxWidthFraction / max(size.width, 1), pageSize.height * maxHeightFraction / max(size.height, 1))
        return CGSize(width: size.width * f, height: size.height * f)
    }
}

/// Async work an action needs before it can go on the page: figures are drawn, measured and
/// placed in free space (their `near` becomes the final frame).
@MainActor
enum FigurePreparer {
    enum Outcome {
        case ready(InkyAction)
        case failed(String)
    }

    static func prepare(_ action: InkyAction, editor: PageEditorModel) async -> Outcome {
        let pageSize = editor.page.size
        switch action {
        case .insertChemScheme(var a):
            do {
                let analysis = try await MoleculeEngine.shared.scheme(steps: a.steps.map(\.smiles), keepRadicals: a.arrows.contains { $0.kind == .fishhook })
                if let bad = analysis.steps.first(where: { !$0.ok }) {
                    return .failed("Inky couldn't draw \(bad.input).")
                }
                let layout = ChemSchemeLayout(analysis: analysis, action: a, maxWidth: ChemSchemeLayout.preferredMaxWidth(pageWidth: pageSize.width))
                let chrome = InkyFigureFrame<EmptyView>.chrome(title: nil, caption: nil)
                let size = FigurePlacement.fitted(CGSize(width: layout.size.width + chrome.width, height: layout.size.height + chrome.height), pageSize: pageSize)
                a.near = FigurePlacement.place(size: size, near: a.near, avoid: editor.figureObstacles, pageSize: pageSize)
                return .ready(.insertChemScheme(a))
            } catch {
                return .failed(error.localizedDescription)
            }
        case .insertDiagram(var a):
            do {
                let report = try await DiagramEngine.shared.prepare(svg: a.svg, callouts: a.callouts)
                guard !report.svg.isEmpty else { return .failed(report.problems.first ?? "Inky's diagram couldn't be drawn.") }
                // A title written inside the figure isn't repeated above it.
                if let title = a.title, report.svg.contains(">\(title)<") { a.title = nil }
                let natural = DiagramEngine.displaySize(for: report, pageSize: pageSize)
                let chrome = InkyFigureFrame<EmptyView>.chrome(title: a.title, caption: a.caption)
                let size = FigurePlacement.fitted(CGSize(width: natural.width + chrome.width, height: natural.height + chrome.height), pageSize: pageSize)
                a.near = FigurePlacement.place(size: size, near: a.near, avoid: editor.figureObstacles, pageSize: pageSize)
                return .ready(.insertDiagram(a))
            } catch {
                return .failed(error.localizedDescription)
            }
        default:
            return .ready(action)
        }
    }
}
