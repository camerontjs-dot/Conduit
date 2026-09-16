#if os(macOS)
import ConduitCore
import Foundation

/// App-side bridge from Conduit's durable task identity/runtime observations to
/// MainFrame presentation projections. The bridge never infers a scope from an
/// agent name or terminal prose: a task contributes only when its immutable
/// workspace snapshot records a project path inside the selected MainFrame.
@MainActor
enum MainframeObservedTaskBridge {
    struct Snapshot {
        let taskAssociations: [MainframeTaskAssociation]
        let observedWorkFacts: [MainframeObservedWorkFact]
        let liveRuntimeTaskIDsByScope: [String: Set<TaskSessionID>]
    }

    static func build(
        root: URL,
        tasks: [TaskSessionSnapshot],
        runtimes: [TerminalRuntime]
    ) -> Snapshot {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        var associations: [MainframeTaskAssociation] = []
        var taskScopeByID: [TaskSessionID: String] = [:]

        for task in tasks {
            guard let projectPath = task.metadata.workspace.projectPath else { continue }
            let standardizedProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
            guard standardizedProject.hasPrefix(prefix) else { continue }
            let relative = String(standardizedProject.dropFirst(prefix.count))
            guard relative.hasPrefix("30_projects/") || relative.hasPrefix("40_operations/") else { continue }

            taskScopeByID[task.id] = relative
            associations.append(MainframeTaskAssociation(
                taskID: task.id.rawValue.uuidString,
                taskLabel: task.displayTitle,
                scopePath: relative,
                provenance: "Conduit durable task workspace binding"
            ))
        }

        var liveByScope: [String: Set<TaskSessionID>] = [:]
        for runtime in runtimes {
            guard !runtime.controller.lifecycle.isTerminal,
                  let taskID = runtime.descriptor.taskSessionID,
                  let scope = taskScopeByID[taskID] else { continue }
            liveByScope[scope, default: []].insert(taskID)
        }

        let facts = liveByScope.keys.sorted().compactMap { scope -> MainframeObservedWorkFact? in
            guard let ids = liveByScope[scope], !ids.isEmpty else { return nil }
            return MainframeObservedWorkFact(
                scopePath: scope,
                kind: .taskCount,
                label: "Live runtimes",
                value: String(ids.count),
                sourcePath: nil,
                authority: .observedRuntime
            )
        }

        return Snapshot(
            taskAssociations: associations.sorted {
                if $0.scopePath != $1.scopePath { return $0.scopePath < $1.scopePath }
                return $0.taskID < $1.taskID
            },
            observedWorkFacts: facts,
            liveRuntimeTaskIDsByScope: liveByScope
        )
    }

    static func liveRuntimes(
        for scopePath: String,
        root: URL,
        tasks: [TaskSessionSnapshot],
        runtimes: [TerminalRuntime]
    ) -> [TerminalRuntime] {
        let snapshot = build(root: root, tasks: tasks, runtimes: runtimes)
        guard let taskIDs = snapshot.liveRuntimeTaskIDsByScope[scopePath] else { return [] }
        return runtimes.filter { runtime in
            guard !runtime.controller.lifecycle.isTerminal,
                  let taskID = runtime.descriptor.taskSessionID else { return false }
            return taskIDs.contains(taskID)
        }
    }
}
#endif
