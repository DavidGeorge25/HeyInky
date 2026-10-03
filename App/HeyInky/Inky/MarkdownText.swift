import SwiftUI

/// Minimal block Markdown for sidebar explanations: headings, paragraphs, bullet and
/// numbered lists, code blocks; inline styling via AttributedString.
enum MarkdownText {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(index: String, text: String)
        case code(String)
    }

    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph()
            } else if let match = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flushParagraph()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
            } else if let match = line.firstMatch(of: /^[-*•]\s+(.*)$/) {
                flushParagraph()
                blocks.append(.bullet(String(match.1)))
            } else if let match = line.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
                flushParagraph()
                blocks.append(.numbered(index: String(match.1), text: String(match.2)))
            } else {
                paragraph.append(line)
            }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Text suitable for speech: no markup symbols.
    static func plainText(_ markdown: String) -> String {
        blocks(markdown).map { block -> String in
            switch block {
            case .heading(_, let t), .paragraph(let t), .bullet(let t), .numbered(_, let t):
                String(inline(t).characters)
            case .code(let c):
                c
            }
        }
        .joined(separator: ".\n")
    }
}

struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownText.blocks(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(MarkdownText.inline(text))
                        .font(.system(size: level == 1 ? 22 : (level == 2 ? 18 : 16), weight: .semibold, design: .rounded))
                        .padding(.top, level == 1 ? 0 : 6)
                case .paragraph(let text):
                    Text(MarkdownText.inline(text))
                        .font(.system(size: 16))
                        .lineSpacing(3)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        Text(MarkdownText.inline(text)).font(.system(size: 16))
                    }
                case .numbered(let index, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index).").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                        Text(MarkdownText.inline(text)).font(.system(size: 16))
                    }
                case .code(let code):
                    Text(code)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvasBackground))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
