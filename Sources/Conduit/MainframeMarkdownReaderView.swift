#if os(macOS)
import ConduitCore
import Foundation
import SwiftUI

enum MainframeReaderMode: String, CaseIterable {
    case rendered
    case source
    case edit

    var displayName: String {
        switch self {
        case .rendered: return "Read"
        case .source: return "Source"
        case .edit: return "Edit"
        }
    }
}

/// Readability-first Markdown presentation for Explorer. The source string
/// remains authoritative; this view is only a projection over it.
struct MainframeMarkdownReaderView: View {
    let source: String
    let mode: MainframeReaderMode
    let palette: ConduitPalette

    private var document: MainframeMarkdownDocument {
        MainframeMarkdownParser.parse(source)
    }

    var body: some View {
        switch mode {
        case .rendered:
            renderedDocument
        case .source, .edit:
            // Edit mode is normally intercepted by Explorer and rendered with a
            // TextEditor. Falling back to source keeps this projection total.
            sourceDocument
        }
    }

    private var renderedDocument: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                if !document.frontmatter.isEmpty {
                    frontmatterCard
                }
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityLabel("Rendered Markdown document")
    }

    private var sourceDocument: some View {
        ScrollView(.vertical) {
            Text(source)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(palette.text)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 980, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityLabel("Markdown source")
    }

    private var frontmatterCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(document.frontmatter.keys.sorted(), id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(key)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.dim)
                    Text(document.frontmatter[key] ?? "")
                        .font(.caption)
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Document frontmatter")
    }

    @ViewBuilder
    private func blockView(_ block: MainframeMarkdownBlock) -> some View {
        switch block {
        case .heading(let heading):
            inlineText(heading.text)
                .font(font(for: heading.level))
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .padding(.top, heading.level == 1 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let text):
            inlineText(text)
                .font(.body)
                .foregroundStyle(palette.text)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•")
                            .foregroundStyle(palette.dim)
                        inlineText(item)
                            .font(.body)
                            .foregroundStyle(palette.text)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(index + 1).")
                            .foregroundStyle(palette.dim)
                            .frame(minWidth: 24, alignment: .trailing)
                        inlineText(item)
                            .font(.body)
                            .foregroundStyle(palette.text)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(palette.accent.opacity(0.55))
                    .frame(width: 3)
                inlineText(text)
                    .font(.body)
                    .italic()
                    .foregroundStyle(palette.dim)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)

        case .fencedCode(let language, let text):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(palette.faint)
                }
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(12)
                }
                .background(palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }

        case .table(let table):
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    tableRow(table.headers, isHeader: true)
                    Divider().overlay(palette.line)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        tableRow(row, isHeader: false)
                        Divider().overlay(palette.line.opacity(0.6))
                    }
                }
                .padding(1)
            }
            .background(palette.surface.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 7))

        case .horizontalRule:
            Divider().overlay(palette.line)
                .padding(.vertical, 4)
        }
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                inlineText(cell)
                    .font(isHeader ? .callout.weight(.semibold) : .callout)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
    }

    private func inlineText(_ source: String) -> Text {
        if let attributed = try? AttributedString(markdown: source) {
            return Text(attributed)
        }
        return Text(source)
    }

    private func font(for level: Int) -> Font {
        switch level {
        case 1: return .largeTitle.weight(.bold)
        case 2: return .title.weight(.bold)
        case 3: return .title2.weight(.semibold)
        case 4: return .title3.weight(.semibold)
        case 5: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}
#endif
