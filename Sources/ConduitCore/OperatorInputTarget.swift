import Foundation
import CryptoKit

/// A menu action also belongs to the exact displayed input/output revision.
/// It does not establish provider state, completion or durable acceptance.
public struct OperatorConversationInputRevision: Equatable, Sendable {
    public let eventID: UUID?
    public let contentBytes: Data?

    public init(eventID: UUID?, contentBytes: Data?) {
        self.eventID = eventID
        self.contentBytes = contentBytes
    }

    public static func capture(_ event: SessionPresentationEvent) -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self(eventID: event.id, contentBytes: try? encoder.encode(event))
    }

    public static func latest(in events: [SessionPresentationEvent]) -> Self {
        guard let last = events.last else { return Self(eventID: nil, contentBytes: Data()) }
        guard events.filter({ $0.id == last.id }).count == 1 else {
            return Self(eventID: last.id, contentBytes: nil)
        }
        return capture(last)
    }

    public func matches(_ current: Self) -> Bool {
        contentBytes != nil && current.contentBytes != nil && self == current
    }

    public var identifierComponent: String {
        let event = eventID?.uuidString.lowercased() ?? "empty"
        guard let contentBytes else { return event + ".unverifiable" }
        return event + "." + SHA256.hash(data: contentBytes)
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// An exact, ephemeral UI input target. Durable task and runtime attempt are
/// separate identities; an explicitly unbound legacy runtime keeps task nil.
public struct OperatorInputTarget: Equatable, Hashable, Sendable {
    public let taskSessionID: TaskSessionID?
    public let runtimeID: UUID
    public let runtimeAttemptID: RuntimeAttemptID
    public let projectPath: String

    public init(taskSessionID: TaskSessionID?, runtimeID: UUID,
                runtimeAttemptID: RuntimeAttemptID, projectPath: String) {
        self.taskSessionID = taskSessionID
        self.runtimeID = runtimeID
        self.runtimeAttemptID = runtimeAttemptID
        self.projectPath = projectPath
    }
}

/// Captured when a composer control is rendered, then compared again at dispatch.
public struct OperatorInputSelection: Equatable, Sendable {
    public let projectPath: String?
    public let taskSessionID: TaskSessionID?
    public let activeRuntime: OperatorInputTarget?

    public init(projectPath: String?, taskSessionID: TaskSessionID?,
                activeRuntime: OperatorInputTarget?) {
        self.projectPath = projectPath
        self.taskSessionID = taskSessionID
        self.activeRuntime = activeRuntime
    }
}

public enum OperatorInputGate {
    /// The UI must supply current ownership/liveness immediately before use.
    /// An identifier is a target description, never an input grant by itself.
    public static func permits(_ target: OperatorInputTarget,
                               selection: OperatorInputSelection,
                               liveTargets: [OperatorInputTarget]) -> Bool {
        guard selection.projectPath == target.projectPath,
              selection.taskSessionID == target.taskSessionID,
              selection.activeRuntime == target,
              liveTargets.filter({ $0.runtimeID == target.runtimeID }).count == 1,
              liveTargets.contains(target) else { return false }
        if let taskID = target.taskSessionID {
            guard liveTargets.filter({ $0.taskSessionID == taskID }).count == 1
            else { return false }
        }
        return true
    }
}

/// Stable semantic names for re-resolution, with full identities and no labels,
/// shortened IDs, row positions or agent display names as target authority.
public enum OperatorControlIdentifier {
    public static let tools = "conduit.controls.tools"
    public static let settings = "conduit.controls.settings"
    public static let settingsSurface = "conduit.settings.surface"
    public static let settingsDone = "conduit.settings.done"

    public static func task(_ id: TaskSessionID) -> String {
        "conduit.task." + id.rawValue.uuidString.lowercased()
    }

    public static func control(_ control: String, target: OperatorInputTarget) -> String {
        let taskID = target.taskSessionID?.rawValue.uuidString.lowercased() ?? "unbound"
        return "conduit.task.\(taskID).runtime.\(target.runtimeID.uuidString.lowercased())"
            + ".attempt.\(target.runtimeAttemptID.rawValue.uuidString.lowercased())"
            + ".control." + component(control)
    }

    public static func composer(_ control: String,
                                selection: OperatorInputSelection) -> String {
        if let target = selection.activeRuntime {
            return self.control("composer." + control, target: target)
        }
        let taskID = selection.taskSessionID?.rawValue.uuidString.lowercased() ?? "new"
        // A project path is encoded solely as an exact local presentation key.
        // This does not make a path or a missing runtime an execution authority.
        return "conduit.composer.task.\(taskID).project."
            + component(selection.projectPath ?? "") + "." + component(control)
    }

    private static func component(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
