import Foundation

public struct ChatGPTTunnelPrerequisites: Equatable, Sendable {
    public var sessionAPIListening: Bool
    public var tunnelClientAvailable: Bool
    public var profilePresent: Bool
    public var tunnelIDPresent: Bool
    public var controlPlaneKeyPresent: Bool
    public var sessionTokenPresent: Bool

    public init(
        sessionAPIListening: Bool,
        tunnelClientAvailable: Bool,
        profilePresent: Bool,
        tunnelIDPresent: Bool,
        controlPlaneKeyPresent: Bool,
        sessionTokenPresent: Bool
    ) {
        self.sessionAPIListening = sessionAPIListening
        self.tunnelClientAvailable = tunnelClientAvailable
        self.profilePresent = profilePresent
        self.tunnelIDPresent = tunnelIDPresent
        self.controlPlaneKeyPresent = controlPlaneKeyPresent
        self.sessionTokenPresent = sessionTokenPresent
    }

    public var missingRequirements: [String] {
        var missing: [String] = []
        if !sessionAPIListening { missing.append("Session API is not listening") }
        if !tunnelClientAvailable { missing.append("tunnel-client is unavailable") }
        if !profilePresent { missing.append("tunnel-client profile is missing") }
        if !tunnelIDPresent { missing.append("tunnel id is missing") }
        if !controlPlaneKeyPresent { missing.append("control-plane key is missing") }
        if !sessionTokenPresent { missing.append("Session API token is missing") }
        return missing
    }
}

public enum ChatGPTTunnelControlAction: Equatable, Sendable {
    case noChange
    case startOwned
    case stopOwned
    case observeExternal
    case blocked([String])
}

public enum ChatGPTTunnelRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case runningOwned
    case runningExternal
    case blocked([String])
    case failed(String)
}

/// Pure ownership policy for the hosted ChatGPT tunnel.
///
/// A tunnel that Conduit did not launch is observable but never terminated by
/// this control. Session API write authority remains a separate setting.
public enum ChatGPTTunnelControlPolicy {
    public static func action(
        desiredRunning: Bool,
        ownsRunningProcess: Bool,
        healthReachable: Bool,
        prerequisites: ChatGPTTunnelPrerequisites
    ) -> ChatGPTTunnelControlAction {
        if !desiredRunning {
            return ownsRunningProcess ? .stopOwned : .noChange
        }

        if ownsRunningProcess {
            return prerequisites.sessionAPIListening ? .noChange : .stopOwned
        }

        if healthReachable {
            return .observeExternal
        }

        let missing = prerequisites.missingRequirements
        guard missing.isEmpty else {
            return .blocked(missing)
        }
        return .startOwned
    }
}
