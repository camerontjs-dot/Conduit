#if os(macOS)
import ConduitCore
import Foundation

/// Adapts Conduit's existing project-context candidates into the typed Context
/// IDE model without changing their underlying authority. Candidate files stay
/// filesystem sources. Git HEAD and working-tree observations are represented as
/// separate context items rather than pretending every selected file is exactly
/// the blob stored at HEAD.
enum ContextIDEBridge {
    static func buildBundle(
        title: String,
        mainframeRoot: URL?,
        scopePath: URL?,
        candidates: [ContextDocument],
        selectedIDs: Set<String>,
        pinnedItems: [AgentContextItem] = [],
        gitSnapshot: GitWorkspaceSnapshot? = nil
    ) -> AgentContextBundle {
        let selected = candidates.filter { selectedIDs.contains($0.id) }

        let sourceItems = selected.map { document in
            AgentContextItem(
                id: "context-document:\(document.id)",
                title: document.label,
                kind: .file,
                authority: .filesystemSource,
                sourceReference: displayPath(document.url, mainframeRoot: mainframeRoot),
                revisionIdentity: nil,
                estimatedTokens: estimatedTokens(for: document.url),
                isPinned: false,
                // The legacy context-candidate list identifies the current path
                // but does not carry an exact byte identity. Do not promote that
                // absence into a claim that a persisted snapshot is still fresh.
                // Source Workbench pins use an exact current Git blob identity
                // when available and can therefore make a stronger claim.
                freshness: .unknown
            )
        }

        let gitItems = gitSnapshot.map(gitContextItems) ?? []
        let items = sourceItems + gitItems + pinnedItems

        return AgentContextBundle(
            taskTitle: title,
            scopePath: scopePath.map { displayPath($0, mainframeRoot: mainframeRoot) },
            repository: gitSnapshot?.repositoryRoot,
            branch: gitSnapshot?.branch,
            commitSHA: gitSnapshot?.headSHA,
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

    private static func gitContextItems(_ snapshot: GitWorkspaceSnapshot) -> [AgentContextItem] {
        var rows: [AgentContextItem] = [
            AgentContextItem(
                id: "git-head:\(snapshot.repositoryRoot)",
                title: snapshot.isDetached
                    ? "Git HEAD (detached)"
                    : "Git HEAD · \(snapshot.branch ?? "unknown branch")",
                kind: .commit,
                authority: .gitCommit,
                sourceReference: snapshot.repositoryRoot,
                revisionIdentity: snapshot.headSHA,
                freshness: .current
            )
        ]

        for entry in snapshot.status.prefix(120) {
            rows.append(
                AgentContextItem(
                    id: "git-working-tree:\(entry.path):\(entry.indexStatus)\(entry.workTreeStatus)",
                    title: "\(entry.statusLabel) · \(entry.path)",
                    kind: .gitDiff,
                    authority: .gitWorkingTree,
                    sourceReference: entry.path,
                    revisionIdentity: nil,
                    freshness: .current
                )
            )
        }

        if snapshot.statusWasTruncated {
            rows.append(
                AgentContextItem(
                    id: "git-working-tree:truncated:\(snapshot.repositoryRoot)",
                    title: "Git status output truncated",
                    kind: .note,
                    authority: .gitWorkingTree,
                    sourceReference: snapshot.repositoryRoot,
                    freshness: .unknown
                )
            )
        }
        return rows
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
