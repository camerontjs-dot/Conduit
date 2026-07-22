import Foundation

/// Pure navigation rules for presenting MainFrame projects without creating a
/// second project database. The scanner's metadata remains the only input.
public enum ProjectNavigation {
    public static func matches(_ project: MainframeProject, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }

        let haystack = [
            project.metadata.title,
            project.slug,
            project.metadata.domain,
            project.metadata.projectState,
            project.metadata.status,
            project.metadata.goal,
            project.metadata.nextAction,
            project.metadata.tags.joined(separator: " ")
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        return haystack.localizedCaseInsensitiveContains(needle)
    }

    /// "Active" is a presentation grouping only. It never changes project
    /// state and intentionally recognizes just the explicit MainFrame values
    /// used for current work rather than guessing from dates or prose.
    public static func isActive(_ project: MainframeProject) -> Bool {
        guard !project.isMainframeRoot else { return false }
        let raw = project.metadata.projectState ?? project.metadata.status ?? ""
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return ["active", "in-progress", "doing"].contains(normalized)
    }
}
