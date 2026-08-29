import Foundation

public enum ContextInspectorLayout: String, Equatable, Sendable {
    case hidden
    case overlay
    case pinned
}

/// Pure geometry policy for the final three-mode workspace. Window width may
/// change panel geometry, but it never mutates the operator's saved density.
public struct WorkspaceGeometry: Equatable, Sendable {
    public let railMinimumWidth: Double
    public let railIdealWidth: Double
    public let railMaximumWidth: Double
    public let inspectorMinimumWidth: Double
    public let inspectorWidth: Double
    public let inspectorMaximumWidth: Double
    public let inspectorLayout: ContextInspectorLayout

    public init(
        railMinimumWidth: Double,
        railIdealWidth: Double,
        railMaximumWidth: Double,
        inspectorMinimumWidth: Double,
        inspectorWidth: Double,
        inspectorMaximumWidth: Double,
        inspectorLayout: ContextInspectorLayout
    ) {
        self.railMinimumWidth = railMinimumWidth
        self.railIdealWidth = railIdealWidth
        self.railMaximumWidth = railMaximumWidth
        self.inspectorMinimumWidth = inspectorMinimumWidth
        self.inspectorWidth = inspectorWidth
        self.inspectorMaximumWidth = inspectorMaximumWidth
        self.inspectorLayout = inspectorLayout
    }
}

public enum WorkspaceGeometryPolicy {
    /// The reading width retained while an operator actively resizes the panel.
    /// Overlay and pinned layouts share the same conservative centre contract.
    public static let workspaceCentreMinimum = 520.0
    public static let inspectorMinimumWidth = 300.0
    public static let inspectorMaximumWidth = 420.0

    public static func resolve(
        windowWidth: Double,
        density: Density,
        isInspectorPresented: Bool,
        preferredInspectorWidth: Double? = nil
    ) -> WorkspaceGeometry {
        let rail: (minimum: Double, ideal: Double, maximum: Double)
        let defaultInspectorWidth: Double

        switch windowWidth {
        case ..<1_200:
            rail = (232, 240, 244)
            defaultInspectorWidth = 300
        case ..<1_440:
            rail = (244, 252, 260)
            defaultInspectorWidth = 312
        default:
            rail = (260, 270, 280)
            defaultInspectorWidth = density == .operator ? 336 : 320
        }

        let inspectorLayout: ContextInspectorLayout
        if !isInspectorPresented {
            inspectorLayout = .hidden
        } else if density == .focused || windowWidth < 1_440 {
            inspectorLayout = .overlay
        } else {
            inspectorLayout = .pinned
        }

        let availableInspectorWidth = windowWidth
            - rail.maximum
            - workspaceCentreMinimum
            - 1 // Visible Inspector divider.
        let inspectorMaximum = min(
            inspectorMaximumWidth,
            max(inspectorMinimumWidth, availableInspectorWidth)
        )
        let sanitizedPreferredWidth = preferredInspectorWidth.flatMap { width in
            width.isFinite && width > 0 ? width : nil
        }
        let inspectorWidth = clampInspectorWidth(
            sanitizedPreferredWidth ?? defaultInspectorWidth,
            minimum: inspectorMinimumWidth,
            maximum: inspectorMaximum
        )

        return WorkspaceGeometry(
            railMinimumWidth: rail.minimum,
            railIdealWidth: rail.ideal,
            railMaximumWidth: rail.maximum,
            inspectorMinimumWidth: inspectorMinimumWidth,
            inspectorWidth: inspectorWidth,
            inspectorMaximumWidth: inspectorMaximum,
            inspectorLayout: inspectorLayout
        )
    }

    public static func clampInspectorWidth(
        _ proposedWidth: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        min(max(proposedWidth, minimum), maximum)
    }

    /// A clamped no-op must not replace a wider stored preference merely
    /// because the current window cannot display it.
    public static func shouldCommitInspectorWidth(
        currentEffectiveWidth: Double,
        proposedWidth: Double
    ) -> Bool {
        currentEffectiveWidth.isFinite
            && proposedWidth.isFinite
            && abs(proposedWidth - currentEffectiveWidth) > 0.5
    }
}
