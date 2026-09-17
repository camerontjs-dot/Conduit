#if os(macOS)
import ConduitCore
import SwiftUI

/// Small programmatic pixel glyph used as a visual landmark in Explorer.
/// The glyph communicates only presentation category. Row text and authority
/// labels remain the accessible/source-of-truth representation.
struct MainframePixelGlyph: View {
    let kind: MainframeExplorerVisualKind
    let primary: Color
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let pattern = PixelPattern.pattern(for: kind)
            let cell = min(size.width, size.height) / 10
            let xInset = (size.width - cell * 10) / 2
            let yInset = (size.height - cell * 10) / 2

            func draw(_ cells: [PixelCell], color: Color) {
                var path = Path()
                for item in cells {
                    path.addRect(CGRect(
                        x: xInset + CGFloat(item.x) * cell,
                        y: yInset + CGFloat(item.y) * cell,
                        width: cell,
                        height: cell
                    ))
                }
                context.fill(path, with: .color(color))
            }

            draw(pattern.base, color: primary)
            draw(pattern.mark, color: accent)
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

private struct PixelCell: Hashable {
    let x: Int
    let y: Int
}

private struct PixelPattern {
    let base: [PixelCell]
    let mark: [PixelCell]

    static func pattern(for kind: MainframeExplorerVisualKind) -> PixelPattern {
        if isFolder(kind) {
            return PixelPattern(base: folderBase, mark: folderMark(for: kind))
        }
        if kind == .symbolicLink {
            return PixelPattern(base: linkBase, mark: linkMark)
        }
        return PixelPattern(base: fileBase, mark: fileMark(for: kind))
    }

    private static func isFolder(_ kind: MainframeExplorerVisualKind) -> Bool {
        switch kind {
        case .folder, .inboxFolder, .ingestFolder, .knowledgeFolder, .liveFolder,
             .projectsFolder, .operationsFolder, .archiveFolder, .projectFolder,
             .operationFolder, .sourceFolder, .testFolder, .documentationFolder,
             .assetFolder, .configurationFolder, .generatedFolder:
            return true
        default:
            return false
        }
    }

    private static let folderBase: [PixelCell] = cells([
        "..........",
        ".111.......",
        ".11111.....",
        ".11111111..",
        ".11111111..",
        ".11111111..",
        ".11111111..",
        ".11111111..",
        "..........",
        "..........",
    ])

    private static let fileBase: [PixelCell] = cells([
        "..11111...",
        "..111111..",
        "..1111111.",
        "..1111111.",
        "..1111111.",
        "..1111111.",
        "..1111111.",
        "..1111111.",
        "..........",
        "..........",
    ])

    private static let linkBase: [PixelCell] = cells([
        "..........",
        ".111.......",
        "1111..1111",
        "11....1111",
        "1111..1111",
        ".111.......",
        "..........",
        "..........",
        "..........",
        "..........",
    ])

    private static let linkMark: [PixelCell] = cells([
        "..........",
        "..........",
        "....11....",
        "...1111...",
        "....11....",
        "..........",
        "..........",
        "..........",
        "..........",
        "..........",
    ])

    private static func folderMark(for kind: MainframeExplorerVisualKind) -> [PixelCell] {
        switch kind {
        case .inboxFolder:
            return cells(marker: ["11111", "1...1", ".111."])
        case .ingestFolder:
            return cells(marker: ["..1..", ".111.", "..1..", "11111"])
        case .knowledgeFolder, .documentationFolder:
            return cells(marker: ["11.11", "11.11", "11.11", ".111."])
        case .liveFolder:
            return cells(marker: ["..1..", ".1.1.", "1...1", ".1.1.", "..1.."])
        case .projectsFolder, .projectFolder:
            return cells(marker: ["..1..", ".111.", "11111", ".111.", "..1.."])
        case .operationsFolder, .operationFolder:
            return cells(marker: ["1...1", ".111.", ".111.", "1...1"])
        case .archiveFolder:
            return cells(marker: ["11111", "1...1", "1.1.1", "11111"])
        case .sourceFolder:
            return cells(marker: [".1.1.", "1...1", ".1.1."])
        case .testFolder:
            return cells(marker: ["1....", ".1.1.", "..1..", ".1..."])
        case .assetFolder:
            return cells(marker: ["...1.", ".1...", "1.1.1", "11111"])
        case .configurationFolder:
            return cells(marker: ["1.1.1", ".1.1.", "1.1.1"])
        case .generatedFolder:
            return cells(marker: [".1.1.", "11111", ".111.", "11111", ".1.1."])
        case .folder:
            return cells(marker: [".....", "..1.."])
        default:
            return []
        }
    }

    private static func fileMark(for kind: MainframeExplorerVisualKind) -> [PixelCell] {
        switch kind {
        case .sourceFile:
            return cells(marker: [".1.1.", "1...1", ".1.1."])
        case .markdownFile:
            return cells(marker: ["1...1", "11.11", "1.1.1", "1...1"])
        case .testFile:
            return cells(marker: ["1....", ".1.1.", "..1..", ".1..."])
        case .configurationFile:
            return cells(marker: ["1.1.1", ".1.1.", "1.1.1"])
        case .scriptFile:
            return cells(marker: ["1....", ".1...", "..1..", ".1...", "1...."])
        case .assetFile:
            return cells(marker: ["...1.", ".1...", "1.1.1", "11111"])
        case .gitFile:
            return cells(marker: ["..1..", ".111.", "1.1.1", "..1.."])
        case .textFile:
            return cells(marker: ["11111", ".111.", "11111"])
        case .binaryFile:
            return cells(marker: ["1.1.1", ".1.1.", "1.1.1", ".1.1."])
        case .unknownFile:
            return cells(marker: [".111.", "...1.", "..1..", ".....", "..1.."])
        default:
            return []
        }
    }

    /// Places a small marker inside the shared folder/file body.
    private static func cells(marker rows: [String]) -> [PixelCell] {
        var result: [PixelCell] = []
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, value) in row.enumerated() where value == "1" {
                result.append(PixelCell(x: columnIndex + 3, y: rowIndex + 3))
            }
        }
        return result
    }

    private static func cells(_ rows: [String]) -> [PixelCell] {
        var result: [PixelCell] = []
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, value) in row.enumerated() where value == "1" {
                result.append(PixelCell(x: columnIndex, y: rowIndex))
            }
        }
        return result
    }
}
#endif
