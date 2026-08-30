import SwiftUI

/// Renders the markdown that models actually emit (headings, bullets, numbered lists,
/// fenced code, quotes) as formatted text instead of raw `**`, `#` and backticks.
///
/// SwiftUI's built-in markdown support is inline-only: it handles `**bold**` and `` `code` ``
/// but leaves every block marker sitting in the output as literal punctuation. So blocks are
/// split here and each one's *inline* content is handed to `AttributedString`.
struct MarkdownText: View {
    let markdown: String
    var size: CGFloat = 14
    var color: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)

        case .heading(let level, let text):
            inline(text, size: size + (level == 1 ? 4 : level == 2 ? 2 : 1), weight: .semibold)
                .padding(.top, 2)

        case .bullet(let depth, let text):
            listRow(depth: depth, marker: "•", text: text)

        case .ordered(let depth, let number, let text):
            listRow(depth: depth, marker: "\(number).", text: text)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.35))
                    .frame(width: 3)
                inline(text).opacity(0.85)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let text):
            Text(text)
                .font(.system(size: size - 1, design: .monospaced))
                .foregroundStyle(color.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                )

        case .rule:
            Rectangle()
                .fill(color.opacity(0.20))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func listRow(depth: Int, marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.system(size: size))
                .foregroundStyle(color.opacity(0.55))
                .frame(minWidth: 14, alignment: .trailing)
            inline(text)
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    private func inline(
        _ text: String,
        size: CGFloat? = nil,
        weight: Font.Weight = .regular
    ) -> some View {
        Text(MarkdownText.attributed(text))
            .font(.system(size: size ?? self.size, weight: weight))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            // No maxWidth here on purpose: the bubble must hug a short answer instead of
            // stretching to its limit.
            .multilineTextAlignment(.leading)
    }

    /// Inline markdown only. Whitespace is preserved so a soft-wrapped paragraph keeps its
    /// own line breaks; malformed markdown falls back to the raw text rather than vanishing.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// One block-level element of a markdown document.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(depth: Int, text: String)
    case ordered(depth: Int, number: Int, text: String)
    case quote(String)
    case code(String)
    case rule

    /// A deliberately small parser: the block constructs models emit in chat answers, and
    /// nothing else. Anything unrecognised stays a paragraph, so no text is ever dropped.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            // Indentation only matters for list nesting; two spaces or a tab is one level.
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let depth = min(2, indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2)

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let hashes = trimmed.range(of: "^#{1,6} ", options: .regularExpression) {
                flushParagraph()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes.upperBound) - 1
                blocks.append(.heading(level: level, text: String(trimmed[hashes.upperBound...])))
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(trimmed == ">" ? 1 : 2))))
                continue
            }

            if let marker = trimmed.range(of: "^[-*+] ", options: .regularExpression) {
                flushParagraph()
                blocks.append(.bullet(depth: depth, text: String(trimmed[marker.upperBound...])))
                continue
            }

            if let marker = trimmed.range(of: "^[0-9]{1,3}[.)] ", options: .regularExpression) {
                flushParagraph()
                let number = Int(trimmed[trimmed.startIndex..<marker.upperBound]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .)"))) ?? 1
                blocks.append(.ordered(depth: depth, number: number,
                                       text: String(trimmed[marker.upperBound...])))
                continue
            }

            paragraph.append(trimmed)
        }

        // An unterminated fence still has to render; losing the answer would be worse.
        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }
}
