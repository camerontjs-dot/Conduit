import Foundation

// MARK: - Companion scale (presentation only)

/// Density-aware companion sizes for rail / header / shelf.
/// Pure geometry — never implies lifecycle or success.
public enum CompanionScale: String, CaseIterable, Codable, Hashable, Sendable {
    case compact
    case standard
    case expanded

    /// Product default when no operator override is set.
    public static func defaultFor(density: Density) -> CompanionScale {
        switch density {
        case .focused: return .compact
        case .balanced: return .standard
        case .operator: return .expanded
        }
    }

    /// Point size for the nearest-neighbor sprite frame (width × height-ish).
    public var spriteSide: Double {
        switch self {
        case .compact: return 28
        case .standard: return 48
        case .expanded: return 72
        }
    }

    public var railSpriteSide: Double {
        switch self {
        case .compact: return 22
        case .standard: return 28
        case .expanded: return 34
        }
    }

    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .expanded: return "Expanded"
        }
    }
}

// MARK: - Operator peek (optional multi-agent shelf)

/// Defaults for the optional Operator peek shelf.
/// Never a permanent OPERATORS strip by product default.
public enum OperatorPeekPolicy {
    /// When the operator has not customized the preference, density decides.
    public static func defaultEnabled(for density: Density) -> Bool {
        switch density {
        case .focused, .balanced: return false
        case .operator: return true
        }
    }

    public static func resolveEnabled(
        customized: Bool,
        storedEnabled: Bool,
        density: Density
    ) -> Bool {
        if customized { return storedEnabled }
        return defaultEnabled(for: density)
    }
}

// MARK: - Agent inbox attention (true integers only)

/// Attention counts for the task rail. Counts are always derived from catalog
/// rows the operator can already see — never invented "quests" or health.
public struct AgentInboxAttention: Equatable, Sendable {
    public let pinned: Int
    public let active: Int
    public let reconnectable: Int
    public let recent: Int
    public let archived: Int
    public let discovered: Int

    public init(
        pinned: Int,
        active: Int,
        reconnectable: Int,
        recent: Int,
        archived: Int,
        discovered: Int
    ) {
        self.pinned = pinned
        self.active = active
        self.reconnectable = reconnectable
        self.recent = recent
        self.archived = archived
        self.discovered = discovered
    }

    /// Rows that likely need an operator decision (reconnect only).
    public var needsAttention: Int { reconnectable }

    public var summaryLine: String {
        var parts: [String] = []
        if needsAttention > 0 {
            parts.append(
                "\(needsAttention) reconnectable"
            )
        }
        if active > 0 {
            parts.append("\(active) active")
        }
        if pinned > 0 {
            parts.append("\(pinned) pinned")
        }
        if recent > 0 {
            parts.append("\(recent) recent")
        }
        if discovered > 0 {
            parts.append("\(discovered) discovered")
        }
        if parts.isEmpty {
            return "No tasks in this scope"
        }
        return parts.joined(separator: " · ")
    }

    public static func from(
        pinned: [TaskSessionCatalogRow],
        active: [TaskSessionCatalogRow],
        recent: [TaskSessionCatalogRow],
        archived: [TaskSessionCatalogRow],
        discoveredCount: Int
    ) -> AgentInboxAttention {
        let reconnectable = (pinned + active).filter {
            $0.availability.kind == .reconnectable
        }.count
        return AgentInboxAttention(
            pinned: pinned.count,
            active: active.count,
            reconnectable: reconnectable,
            recent: recent.count,
            archived: archived.count,
            discovered: discoveredCount
        )
    }
}

// MARK: - Next safe action (Session card)

/// A single primary next action grounded in observed runtime/task state.
/// Never invents completion, review, or quest language.
public enum SessionNextSafeAction: Equatable, Sendable {
    case openRaw
    case reconnect
    case leave
    case newTask
    case selectTask
    case none

    public var title: String {
        switch self {
        case .openRaw: return "Open Raw"
        case .reconnect: return "Reconnect"
        case .leave: return "Leave runtime"
        case .newTask: return "New Task"
        case .selectTask: return "Select a task"
        case .none: return ""
        }
    }

    public var help: String {
        switch self {
        case .openRaw:
            return "Opens the same mounted PTY as Conversation. Raw is authoritative."
        case .reconnect:
            return "Explicitly attaches to the observed durable tmux runtime."
        case .leave:
            return "Detaches the UI without claiming the process finished successfully."
        case .newTask:
            return "Starts a new task and chooses MainFrame scope."
        case .selectTask:
            return "Pick a task in the rail to inspect session details."
        case .none:
            return ""
        }
    }

    /// Resolve from observed facts only.
    public static func resolve(
        hasSelectedTask: Bool,
        hasOpenRuntime: Bool,
        isDetached: Bool,
        isReconnectableWithoutRuntime: Bool
    ) -> SessionNextSafeAction {
        if hasOpenRuntime {
            if isDetached { return .reconnect }
            return .openRaw
        }
        if isReconnectableWithoutRuntime { return .reconnect }
        if hasSelectedTask { return .newTask }
        return .selectTask
    }
}

// MARK: - Juicy UI feedback policy

/// Operator-action micro-feedback (select, send, inspector). Never tied to
/// agent progress, XP, or completion claims.
public enum JuicyFeedbackPolicy {
    public static let selectDuration: Double = 0.14
    public static let sendFlashDuration: Double = 0.16
    public static let inspectorDuration: Double = 0.18

    /// Pose swaps stay static even when juiciness is on.
    public static func shouldAnimatePoseChange() -> Bool { false }

    public static func shouldPlayChromeMotion(
        juicyEnabled: Bool,
        reduceMotion: Bool
    ) -> Bool {
        juicyEnabled && !reduceMotion
    }
}
