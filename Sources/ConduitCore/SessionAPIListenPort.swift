import Foundation

/// Resolves the one loopback listener port before Session API startup.
/// An invalid qualification override must never fall back to the operator port.
public enum SessionAPIListenPort {
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int {
        guard let raw = environment["CONDUIT_SESSION_API_PORT"] else {
            return ConduitSessionAPI.loopbackPort
        }
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let port = Int(raw),
              (18750...18849).contains(port)
        else {
            throw SessionAPIListenPortError.invalidOverride
        }
        return port
    }
}

public enum SessionAPIListenPortError: LocalizedError, Equatable {
    case invalidOverride

    public var errorDescription: String? {
        "CONDUIT_SESSION_API_PORT must be an integer from 18750 through 18849."
    }
}
