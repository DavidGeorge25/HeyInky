import PDFKit
import SwiftUI

extension Notification.Name {
    /// Posted by Inky's cards to ask Inky something (object: the question `String`).
    static let inkyAskFromCard = Notification.Name("inkyAskFromCard")
}

/// An `insertPractice` card: one problem at a time, hints revealed one by one, then the answer and
/// a worked solution. "Check my work" asks Inky to grade what the student wrote on the page.
struct PracticeCardView: View {
    let action: InsertPracticeAction
    var scale: CGFloat = 1

    @State private var index = 0
    @State private var hintsShown = 0
    @State private var showAnswer = false
    @State private var showSolution = false

    private var problem: InsertPracticeAction.Problem? { action.problems.indices.contains(index) ? action.problems[index] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack(spacing: 8 * scale) {
                Text(action.title ?? "Practice")
                    .font(.system(size: 14 * scale, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Spacer()
                if action.problems.count > 1 {
                    Button { go(-1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                        .accessibilityIdentifier("inky.practice.previous")
                    Text("\(index + 1) / \(action.problems.count)")
                        .font(.system(size: 12 * scale, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("inky.practice.position")
                    Button { go(1) } label: { Image(systemName: "chevron.right") }.disabled(index >= action.problems.count - 1)
                        .accessibilityIdentifier("inky.practice.next")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)

            if let problem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10 * scale) {
                        MathText(problem.prompt, scale: scale)
                            .accessibilityIdentifier("inky.practice.prompt")
                        ForEach(Array(problem.hints.prefix(hintsShown).enumerated()), id: \.offset) { _, hint in
                            HStack(alignment: .top, spacing: 6 * scale) {
                                Image(systemName: "lightbulb").foregroundStyle(.orange).font(.system(size: 12 * scale))
                                MathText(hint, scale: scale * 0.9, color: "#6B6B76")
                            }
                        }
                        if showAnswer {
                            HStack(spacing: 6 * scale) {
                                Text("Answer").font(.system(size: 12 * scale, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                                MathText(problem.answer, scale: scale)
                            }
                            .padding(8 * scale)
                            .background(RoundedRectangle(cornerRadius: 8 * scale).fill(Theme.accent.opacity(0.08)))
                            .accessibilityIdentifier("inky.practice.answer")
                        }
                        if showSolution {
                            VStack(alignment: .leading, spacing: 4 * scale) {
                                ForEach(Array(problem.solution.enumerated()), id: \.offset) { i, step in
                                    HStack(alignment: .top, spacing: 6 * scale) {
                                        Text("\(i + 1).").font(.system(size: 12 * scale, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                                        MathText(step, scale: scale * 0.95)
                                    }
                                }
                            }
                            .accessibilityIdentifier("inky.practice.solution")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 6 * scale) {
                    if hintsShown < problem.hints.count {
                        pill("Hint", "lightbulb", id: "inky.practice.hint") { withAnimation(.snappy) { hintsShown += 1 } }
                    }
                    if !showAnswer {
                        pill("Answer", "eye", id: "inky.practice.reveal") { withAnimation(.snappy) { showAnswer = true } }
                    } else if !showSolution && !problem.solution.isEmpty {
                        pill("Solution", "list.number", id: "inky.practice.solve") { withAnimation(.snappy) { showSolution = true } }
                    }
                    Spacer(minLength: 0)
                    pill("Check my work", "checkmark.circle", id: "inky.practice.check", prominent: true) {
                        let question = "Check my work on this practice problem: \(problem.prompt) (the correct answer is \(problem.answer)). Look at what I wrote on the page near the practice card, mark my mistakes and tell me what to fix — don't just give me the answer."
                        NotificationCenter.default.post(name: .inkyAskFromCard, object: question)
                    }
                }
            }
        }
        .padding(12 * scale)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inky.figure.practice")
    }

    private func go(_ delta: Int) {
        withAnimation(.snappy) {
            index = min(max(index + delta, 0), action.problems.count - 1)
            hintsShown = 0
            showAnswer = false
            showSolution = false
        }
    }

    private func pill(_ title: String, _ icon: String, id: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
                .padding(.horizontal, 10 * scale)
                .padding(.vertical, 6 * scale)
                .background(Capsule().fill(prominent ? Theme.accent : Theme.accent.opacity(0.1)))
                .foregroundStyle(prominent ? Color.white : Theme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// Text with inline TeX between \( and \): plain `Text` when there's no math, otherwise wrapped
/// lines typeset by MathJax (`MathTypesetter`) and drawn as vector.
struct MathText: View {
    let source: String
    var scale: CGFloat = 1
    var color: String = "#26262E"
    /// Characters per typeset line before wrapping.
    var lineLength = 46

    @State private var page: PDFPage?
    @MainActor private static var memory: [String: PDFDocument] = [:]

    init(_ source: String, scale: CGFloat = 1, color: String = "#26262E") {
        self.source = source
        self.scale = scale
        self.color = color
    }

    /// Points per typeset unit (MathJax renders at 20 px; body text is ~15 pt).
    private var unit: CGFloat { 0.75 * scale }

    var body: some View {
        if !source.contains("\\(") {
            Text(source).font(.system(size: 15 * scale)).foregroundStyle(Color(hex: color)).fixedSize(horizontal: false, vertical: true)
        } else {
            let box = page?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 200, height: 24)
            Canvas { context, size in
                guard let page else { return }
                context.withCGContext { cg in
                    cg.saveGState()
                    cg.translateBy(x: 0, y: box.height * unit)
                    cg.scaleBy(x: unit, y: -unit)
                    page.draw(with: .mediaBox, to: cg)
                    cg.restoreGState()
                }
            }
            .frame(width: box.width * unit, height: box.height * unit, alignment: .topLeading)
            .accessibilityLabel(Self.plain(source))
            .task(id: source) { await load() }
        }
    }

    private func load() async {
        if let cached = Self.memory[source + color] { page = cached.page(at: 0); return }
        let lines = Self.wrap(source, limit: lineLength).map { InsertMathAction.Line(latex: Self.tex($0, color: color), note: nil) }
        let action = InsertMathAction(near: .zero, title: nil, lines: lines, align: false, boxLast: false, caption: nil)
        guard let math = try? await MathTypesetter.shared.typeset(action),
              let report = try? await DiagramEngine.shared.prepare(svg: math.svg),
              let data = try? await DiagramEngine.shared.pdf(for: report),
              let document = PDFDocument(data: data) else { return }
        Self.memory[source + color] = document
        page = document.page(at: 0)
    }

    /// Splits into lines of about `limit` visible characters, never inside \( … \).
    static func wrap(_ s: String, limit: Int) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inMath = false
        var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix("\\(") { inMath = true; current += "\\("; i = s.index(i, offsetBy: 2); continue }
            if s[i...].hasPrefix("\\)") { inMath = false; current += "\\)"; i = s.index(i, offsetBy: 2); continue }
            if s[i] == " " && !inMath { tokens.append(current); current = ""; i = s.index(after: i); continue }
            current.append(s[i])
            i = s.index(after: i)
        }
        tokens.append(current)
        var lines: [String] = []
        var line = ""
        for t in tokens where !t.isEmpty {
            let visible = plain(line).count + plain(t).count + 1
            if !line.isEmpty && visible > limit { lines.append(line); line = t } else { line = line.isEmpty ? t : line + " " + t }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.isEmpty ? [""] : lines
    }

    /// Text segments become \text{…} (escaped), math segments stay TeX; all in one color.
    static func tex(_ s: String, color: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let open = rest.range(of: "\\(") {
            out += text(String(rest[..<open.lowerBound]))
            let after = rest[open.upperBound...]
            if let close = after.range(of: "\\)") {
                out += "{" + after[..<close.lowerBound] + "}"
                rest = after[close.upperBound...]
            } else {
                out += "{" + after + "}"
                rest = ""
            }
        }
        out += text(String(rest))
        return "\\color{\(color)}{" + out + "}"
    }

    private static func text(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        var e = ""
        for c in s {
            switch c {
            case "\\": e += "\\backslash "
            case "{", "}", "$", "%", "&", "#", "_": e += "\\" + String(c)
            case "^": e += "\\hat{}"
            case "~": e += "\\sim "
            default: e.append(c)
            }
        }
        return "\\textsf{" + e + "}"
    }

    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\\(", with: "").replacingOccurrences(of: "\\)", with: "")
    }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
