import Foundation

public struct MainframeChecklistItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let line: Int
    public let text: String
    public let isChecked: Bool

    public init(id: String, line: Int, text: String, isChecked: Bool) {
        self.id = id
        self.line = line
        self.text = text
        self.isChecked = isChecked
    }
}

public struct MainframeChecklistProjection: Equatable, Sendable {
    public let items: [MainframeChecklistItem]
    public var completedCount: Int { items.filter(\.isChecked).count }
    public var totalCount: Int { items.count }
    public var hasLiteralDenominator: Bool { !items.isEmpty }

    public init(items: [MainframeChecklistItem]) { self.items = items }

    public static func parse(markdown: String) -> MainframeChecklistProjection {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var items: [MainframeChecklistItem] = []
        var insideFence: String?

        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = trimmed.hasPrefix("```") ? "```" : "~~~"
                if insideFence == nil { insideFence = marker }
                else if insideFence == marker { insideFence = nil }
                continue
            }
            if insideFence != nil { continue }
            guard trimmed.count >= 6,
                  (trimmed.hasPrefix("- [") || trimmed.hasPrefix("* [") || trimmed.hasPrefix("+ [")) else { continue }
            let markerIndex = trimmed.index(trimmed.startIndex, offsetBy: 3)
            let marker = trimmed[markerIndex]
            guard [" ", "x", "X"].contains(marker) else { continue }
            let closeIndex = trimmed.index(trimmed.startIndex, offsetBy: 4)
            guard trimmed[closeIndex] == "]" else { continue }
            let textStart = trimmed.index(trimmed.startIndex, offsetBy: 5)
            let text = String(trimmed[textStart...]).trimmingCharacters(in: .whitespaces)
            items.append(MainframeChecklistItem(
                id: "check:\(offset + 1):\(items.count)",
                line: offset + 1,
                text: text,
                isChecked: marker == "x" || marker == "X"
            ))
        }
        return MainframeChecklistProjection(items: items)
    }
}
