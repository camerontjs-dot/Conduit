import Foundation

// MARK: - Density identity

/// Stable Focused Flow density modes for R2.
/// Case order is product order: Focused is first and the fresh-product default.
public enum Density: String, CaseIterable, Codable, Hashable, Sendable {
    case focused
    case balanced
    case `operator`

    /// Fresh-product default. Missing or invalid persisted values resolve here.
    public static let productDefault: Density = .focused

    /// Human-readable product labels (exact Settings / chrome strings).
    public var displayName: String {
        switch self {
        case .focused: return "Focused"
        case .balanced: return "Balanced"
        case .operator: return "Operator"
        }
    }

    /// Resolve a stored raw value. Nil or unknown strings become the product default.
    public static func resolved(fromStored raw: String?) -> Density {
        guard let raw, let value = Density(rawValue: raw) else {
            return .productDefault
        }
        return value
    }
}
