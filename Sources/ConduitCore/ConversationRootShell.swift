import Foundation

public enum ConversationRootPanelPlacement: String, Equatable, Sendable {
    case hidden
    case overlay
    case pinned
}

public struct ConversationRootShellGeometry: Equatable, Sendable {
    public var taskDrawer: ConversationRootPanelPlacement
    public var inspector: ConversationRootPanelPlacement
    public var taskDrawerWidth: Double
    public var inspectorWidth: Double
    public var contentLeadingInset: Double
    public var contentTrailingInset: Double

    public init(
        taskDrawer: ConversationRootPanelPlacement,
        inspector: ConversationRootPanelPlacement,
        taskDrawerWidth: Double,
        inspectorWidth: Double,
        contentLeadingInset: Double,
        contentTrailingInset: Double
    ) {
        self.taskDrawer = taskDrawer
        self.inspector = inspector
        self.taskDrawerWidth = taskDrawerWidth
        self.inspectorWidth = inspectorWidth
        self.contentLeadingInset = contentLeadingInset
        self.contentTrailingInset = contentTrailingInset
    }
}

/// Presentation-only geometry for the conversation-root shell.
///
/// Conversation owns the window at rest. Secondary panels overlay it unless the
/// operator explicitly pins them and enough room remains for a useful chat
/// canvas. The policy never owns task/runtime identity or provider authority.
public enum ConversationRootShellPolicy {
    public static func resolve(
        windowWidth: Double,
        taskDrawerPresented: Bool,
        taskDrawerPinned: Bool,
        inspectorPresented: Bool,
        inspectorPinned: Bool,
        preferredTaskDrawerWidth: Double = 304,
        preferredInspectorWidth: Double = 360,
        minimumConversationWidth: Double = 620
    ) -> ConversationRootShellGeometry {
        let safeWindowWidth = max(0, windowWidth)
        let taskWidth = clamp(
            preferredTaskDrawerWidth,
            lower: 240,
            upper: max(240, min(420, safeWindowWidth * 0.46))
        )
        let inspectorWidth = clamp(
            preferredInspectorWidth,
            lower: 280,
            upper: max(280, min(520, safeWindowWidth * 0.50))
        )

        let requestedPinnedWidth =
            (taskDrawerPresented && taskDrawerPinned ? taskWidth : 0)
            + (inspectorPresented && inspectorPinned ? inspectorWidth : 0)

        // When both requested pins would squeeze the conversation below its
        // useful minimum, both become overlays. That keeps the rule legible:
        // pinning never makes the primary chat surface unusable.
        let canHonorRequestedPins =
            safeWindowWidth - requestedPinnedWidth >= minimumConversationWidth

        let taskPlacement: ConversationRootPanelPlacement
        if !taskDrawerPresented {
            taskPlacement = .hidden
        } else if taskDrawerPinned && canHonorRequestedPins {
            taskPlacement = .pinned
        } else {
            taskPlacement = .overlay
        }

        let inspectorPlacement: ConversationRootPanelPlacement
        if !inspectorPresented {
            inspectorPlacement = .hidden
        } else if inspectorPinned && canHonorRequestedPins {
            inspectorPlacement = .pinned
        } else {
            inspectorPlacement = .overlay
        }

        return ConversationRootShellGeometry(
            taskDrawer: taskPlacement,
            inspector: inspectorPlacement,
            taskDrawerWidth: taskWidth,
            inspectorWidth: inspectorWidth,
            contentLeadingInset: taskPlacement == .pinned ? taskWidth + 1 : 0,
            contentTrailingInset: inspectorPlacement == .pinned ? inspectorWidth + 1 : 0
        )
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), max(lower, upper))
    }
}
