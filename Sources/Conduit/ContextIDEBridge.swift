#if os(macOS)
import ConduitCore
import Foundation

/// Adapts Conduit's existing project-context candidates into the typed Context
/// IDE model without changing their underlying authority. Candidate files stay
/// filesystem sources; Git metadata is added only when it is actually observed.
enum ContextIDEBridge {
    static func buildBundle(
        title: String,
        mainframeRoot: URL?,
        scopePath: URL?,
        candidates: [ContextDocument],
        selectedIDs: Set<String>,
        pinnedItems: [AgentContextItem] = []
    ) -> AgentContextBundle {
        let selected = candidates.filter { selectedIDs.contains($0.id) }
        let git = scopePath.flatMap { try? GitWorkspaceInspector().snapshot(startingAt: $0) }

        let items = selected.map { document in
            AgentContextItem(
                id: "context-document:\(document.id)",
                title: document.label,
                kind: .file,
                authority: .filesystemSource,
                sourceReference: displayPath(document.url, mainframeRoot: mainframeRoot),
                revisionIdentity: revisionIdentity(for: document.url, snapshot: git),
                estimatedTokens: estimatedTokens(for: document.url),
                isPinned: false,
                freshness: git == nil ? .unknown : .current
            )
        } + pinnedItems

        return AgentContextBundle(
            taskTitle: title,
            scopePath: scopePath.map { displayPath($0, mainframeRoot: mainframeRoot) },
            repository: git?.repositoryRoot,
            branch: git?.branch,
            commitSHA: git?.headSHA,
            items: deduplicated(items)
        )
    }

    static func displayPath(_ url: URL, mainframeRoot: URL?) -> String {
        let target = url.standardizedFileURL.path
        guard let mainframeRoot else { return target }
        let root = mainframeRoot.standardizedFileURL.path
        if target == root { return "." }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target.hasPrefix(prefix) else { return target }
        return String(target.dropFirst(prefix.count))
    }

    private static func revisionIdentity(
        for file: URL,
        snapshot: GitWorkspaceSnapshot?
    ) -> String? {
        guard let snapshot else { return nil }
        let root = snapshot.repositoryRoot
        let target = file.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target == root || target.hasPrefix(prefix) else { return nil }
        return snapshot.headSHA
    }

    private static func estimatedTokens(for url: URL) -> Int? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        // Deliberately an estimate for budget visualization, not tokenizer truth.
        return max(1, size / 4)
    }

    private static func deduplicated(_ items: [AgentContextItem]) -> [AgentContextItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
#endif
