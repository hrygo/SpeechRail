import Foundation
import SwiftUI

/// Foundation 解析块与行内语义；仅改变展示，不改写存储、复制或导出的 Markdown。
struct MinutesMarkdownBlock: Identifiable {
    let id: Int
    var text: AttributedString
    let headingLevel: Int?
    let marker: String?
    let listDepth: Int
    let isQuote: Bool
    let isCode: Bool

    static func parse(_ markdown: String) -> [Self] {
        guard let document = try? AttributedString(markdown: markdown,
            options: .init(interpretedSyntax: .full)) else {
            return [.init(id: 0, text: AttributedString(markdown), headingLevel: nil,
                marker: nil, listDepth: 0, isQuote: false, isCode: false)]
        }
        var blocks: [Self] = []
        for run in document.runs {
            let components = run.presentationIntent?.components ?? []
            let id = components.first?.identity ?? 0
            let text = AttributedString(document[run.range])
            if blocks.last?.id == id {
                blocks[blocks.count - 1].text.append(text)
                continue
            }
            var heading: Int?, ordinal: Int?
            var ordered = false, quote = false, code = false, depth = 0
            for component in components {
                switch component.kind {
                case .header(let level): heading = level
                case .listItem(let value): if ordinal == nil { ordinal = value }
                case .orderedList:
                    if depth == 0 { ordered = true }
                    depth += 1
                case .unorderedList: depth += 1
                case .blockQuote: quote = true
                case .codeBlock: code = true
                default: break
                }
            }
            blocks.append(.init(id: id, text: text, headingLevel: heading,
                marker: ordinal.map { ordered ? "\($0)." : "•" },
                listDepth: max(0, depth - 1), isQuote: quote, isCode: code))
        }
        return blocks
    }
}

struct MinutesMarkdownView: View {
    private let blocks: [MinutesMarkdownBlock]

    init(_ markdown: String) { blocks = MinutesMarkdownBlock.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            ForEach(blocks) { block in
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    if block.isQuote {
                        Rectangle()
                            .fill(SpeechRailDesignTokens.Color.separator)
                            .frame(width: SpeechRailDesignTokens.Spacing.hairline)
                    }
                    if let marker = block.marker {
                        Text(verbatim: marker).accessibilityHidden(true)
                    }
                    blockText(block)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, CGFloat(block.listDepth) * SpeechRailDesignTokens.Spacing.md)
            }
        }
        .font(SpeechRailDesignTokens.Typography.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockText(_ block: MinutesMarkdownBlock) -> some View {
        if let level = block.headingLevel {
            Text(block.text)
                .font(level == 1 ? SpeechRailDesignTokens.Typography.display : SpeechRailDesignTokens.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(block.text)
                .font(block.isCode ? SpeechRailDesignTokens.Typography.code : SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(block.isQuote ? SpeechRailDesignTokens.Color.inkSecondary : SpeechRailDesignTokens.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
