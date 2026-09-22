import Foundation

/// Provider-neutral Conduit control state for one provider session.
///
/// This state answers only whether Conduit currently recognizes a writer/controller.
/// It does not claim anything about another application's writer ownership.
public enum ProviderSessionConduitWriterState: String, Codable, Equatable, Sendable {
    case unclaimed
    case controlled
}

/// What Conduit can currently say about writers outside its own authority registry.
///
/// Wave 1 does not infer external writer ownership from provider persistence.
/// A future provider adapter may upgrade UNKNOWN only from an independent,
/// provider-supported observation.
public enum ProviderExternalWriterState: String, Codable, Equatable, Sendable {
    case unknown
    case detected
}

/// Immutable snapshot of Conduit's provider-session writer authority.
public struct ProviderSessionAuthoritySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var providerID: String
    public var providerSessionID: String
    public var conduitWriterState: ProviderSessionConduitWriterState
    public var writerControllerID: OrchestrationValue<String>
    public var externalWriterState: ProviderExternalWriterState

    public init(
        schemaVersion: Int = ProviderSessionAuthoritySnapshot.currentSchemaVersion,
        providerID: String,
        providerSessionID: String,
        conduitWriterState: ProviderSessionConduitWriterState,
        writerControllerID: OrchestrationValue<String>,
        externalWriterState: ProviderExternalWriterState = .unknown
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.providerSessionID = providerSessionID
        self.conduitWriterState = conduitWriterState
        self.writerControllerID = writerControllerID
        self.externalWriterState = externalWriterState
    }
}

public enum ProviderSessionAuthorityDisposition: String, Codable, Equatable, Sendable {
    case adopted
    case alreadyControlled = "already_controlled"
    case writerCollision = "writer_collision"
}

/// Canonical provider-neutral control-plane failure vocabulary.
///
/// Provider adapters translate their native error language into these failures.
/// Callers branch on the canonical code, never on provider-specific strings.
public enum ProviderSessionAuthorityFailure {
    public static let writerCollisionCode = "writer_collision"

    public static func writerCollision(
        providerID: String,
        providerSessionID: String,
        detail: String? = nil
    ) -> String {
        var message =
            "\(writerCollisionCode): provider \(providerID) session "
            + "\(providerSessionID) already has another active writer/controller"
        if let detail = detail?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
        !detail.isEmpty {
            message += " [provider_detail: \(detail)]"
        }
        return message
    }

    public static func isWriterCollision(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        return normalized == writerCollisionCode
            || normalized.hasPrefix(writerCollisionCode + ":")
    }
}

public enum StructuredAdapterStartFailureDisposition: String, Codable, Equatable, Sendable {
    case failClosedWriterCollision = "fail_closed_writer_collision"
    case fallbackAllowed = "fallback_allowed"
}

public enum StructuredAdapterStartFailurePolicy {
    public static func disposition(
        for failure: String
    ) -> StructuredAdapterStartFailureDisposition {
        ProviderSessionAuthorityFailure.isWriterCollision(failure)
            ? .failClosedWriterCollision
            : .fallbackAllowed
    }
}

/// Receipt for one explicit writer/adoption attempt.
///
/// A collision receipt is evidence that the requested provider session still
/// exists in the authority model and is already controlled by another Conduit
/// writer. It must never be reinterpreted as provider-session absence.
public struct ProviderSessionAuthorityReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var providerID: String
    public var providerSessionID: String
    public var requestedControllerID: String
    public var disposition: ProviderSessionAuthorityDisposition
    public var recognizedControllerID: OrchestrationValue<String>
    public var externalWriterState: ProviderExternalWriterState
    public var observedAt: Date

    public init(
        schemaVersion: Int = ProviderSessionAuthorityReceipt.currentSchemaVersion,
        providerID: String,
        providerSessionID: String,
        requestedControllerID: String,
        disposition: ProviderSessionAuthorityDisposition,
        recognizedControllerID: OrchestrationValue<String>,
        externalWriterState: ProviderExternalWriterState = .unknown,
        observedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.providerSessionID = providerSessionID
        self.requestedControllerID = requestedControllerID
        self.disposition = disposition
        self.recognizedControllerID = recognizedControllerID
        self.externalWriterState = externalWriterState
        self.observedAt = observedAt
    }
}

/// Provider observation paired with Conduit's independent authority snapshot.
public struct ProviderSessionAuthorityObservation: Codable, Equatable, Sendable {
    public var worker: WorkerLineage
    public var authority: ProviderSessionAuthoritySnapshot

    public init(worker: WorkerLineage, authority: ProviderSessionAuthoritySnapshot) {
        self.worker = worker
        self.authority = authority
    }
}

public struct ProviderSessionAdoptionResult: Codable, Equatable, Sendable {
    public var observation: ProviderSessionAuthorityObservation
    public var receipt: ProviderSessionAuthorityReceipt

    public init(
        observation: ProviderSessionAuthorityObservation,
        receipt: ProviderSessionAuthorityReceipt
    ) {
        self.observation = observation
        self.receipt = receipt
    }
}

public enum ProviderSessionAuthorityError: Error, Equatable, LocalizedError {
    case emptyProviderID
    case emptyProviderSessionID
    case emptyControllerID

    public var errorDescription: String? {
        switch self {
        case .emptyProviderID:
            return "Provider id is empty."
        case .emptyProviderSessionID:
            return "Provider session id is empty."
        case .emptyControllerID:
            return "Controller id is empty."
        }
    }
}

/// Process-local registry for Conduit writer/controller authority.
///
/// This is deliberately separate from filesystem/worktree leasing. A future
/// writable worker may need both this provider-session authority and a #57
/// workspace writer lease, but neither lock implies the other.
///
/// Transfer/release remains intentionally separate from task/runtime lifecycle.
/// Closing or stopping a Conduit task must not silently release an independently
/// claimed provider-session writer. A future authority-transfer surface must
/// identify the exact provider session and recognized controller explicitly.
public final class ProviderSessionAuthorityRegistry: @unchecked Sendable {
    public static let shared = ProviderSessionAuthorityRegistry()

    private struct Key: Hashable {
        var providerID: String
        var providerSessionID: String
    }

    private let lock = NSLock()
    private var controllerBySession: [Key: String] = [:]
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func snapshot(
        providerID: String,
        providerSessionID: String
    ) throws -> ProviderSessionAuthoritySnapshot {
        let key = try makeKey(
            providerID: providerID,
            providerSessionID: providerSessionID
        )

        lock.lock()
        let controllerID = controllerBySession[key]
        lock.unlock()

        if let controllerID {
            return ProviderSessionAuthoritySnapshot(
                providerID: key.providerID,
                providerSessionID: key.providerSessionID,
                conduitWriterState: .controlled,
                writerControllerID: .known(controllerID),
                externalWriterState: .unknown
            )
        }

        return ProviderSessionAuthoritySnapshot(
            providerID: key.providerID,
            providerSessionID: key.providerSessionID,
            conduitWriterState: .unclaimed,
            writerControllerID: .unknown,
            externalWriterState: .unknown
        )
    }

    public func claimWriter(
        providerID: String,
        providerSessionID: String,
        controllerID: String
    ) throws -> ProviderSessionAuthorityReceipt {
        let key = try makeKey(
            providerID: providerID,
            providerSessionID: providerSessionID
        )
        let requested = controllerID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !requested.isEmpty else {
            throw ProviderSessionAuthorityError.emptyControllerID
        }

        let disposition: ProviderSessionAuthorityDisposition
        let recognized: String

        lock.lock()
        if let existing = controllerBySession[key] {
            recognized = existing
            disposition = existing == requested
                ? .alreadyControlled
                : .writerCollision
        } else {
            controllerBySession[key] = requested
            recognized = requested
            disposition = .adopted
        }
        lock.unlock()

        return ProviderSessionAuthorityReceipt(
            providerID: key.providerID,
            providerSessionID: key.providerSessionID,
            requestedControllerID: requested,
            disposition: disposition,
            recognizedControllerID: .known(recognized),
            externalWriterState: .unknown,
            observedAt: now()
        )
    }

    private func makeKey(
        providerID: String,
        providerSessionID: String
    ) throws -> Key {
        let provider = providerID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !provider.isEmpty else {
            throw ProviderSessionAuthorityError.emptyProviderID
        }

        let session = providerSessionID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !session.isEmpty else {
            throw ProviderSessionAuthorityError.emptyProviderSessionID
        }

        return Key(providerID: provider, providerSessionID: session)
    }
}

/// Composes a read-only provider observer with the independent Conduit writer
/// registry.
///
/// Observation remains observation. The only method that can change authority
/// is adoptSession, and that transition has no provider mutation interface:
/// it cannot send a prompt, start a provider turn, create a replacement session,
/// resume another session, or fall back to PTY.
public final class ProviderSessionAuthorityCoordinator {
    public let observer: any ProviderSessionObserving
    public let registry: ProviderSessionAuthorityRegistry

    public init(
        observer: any ProviderSessionObserving,
        registry: ProviderSessionAuthorityRegistry
    ) {
        self.observer = observer
        self.registry = registry
    }

    public func listSessions(
        bindingResolver: ((String) -> ProviderObservationBinding?)? = nil
    ) throws -> [ProviderSessionAuthorityObservation] {
        try observer.listSessions(bindingResolver: bindingResolver).map {
            try decorate($0)
        }
    }

    public func observeSession(
        providerSessionID: String,
        binding: ProviderObservationBinding? = nil
    ) throws -> ProviderSessionAuthorityObservation {
        try decorate(
            observer.observeSession(
                providerSessionID: providerSessionID,
                binding: binding
            )
        )
    }

    /// Explicitly claim Conduit writer/controller authority for an existing
    /// provider session.
    ///
    /// The exact provider session is observed first. Only after the observer
    /// proves that identity does the registry attempt a claim. Therefore a
    /// writer collision cannot be converted into "session missing" recovery.
    public func adoptSession(
        providerSessionID: String,
        controllerID: String,
        binding: ProviderObservationBinding? = nil
    ) throws -> ProviderSessionAdoptionResult {
        let worker = try observer.observeSession(
            providerSessionID: providerSessionID,
            binding: binding
        )
        let observedID = worker.providerSessionID.value
        guard observedID == providerSessionID else {
            throw ProviderSessionObservationError.identityMismatch(
                expected: providerSessionID,
                observed: observedID ?? ""
            )
        }

        let receipt = try registry.claimWriter(
            providerID: observer.providerID,
            providerSessionID: providerSessionID,
            controllerID: controllerID
        )
        return ProviderSessionAdoptionResult(
            observation: try decorate(worker),
            receipt: receipt
        )
    }

    private func decorate(
        _ worker: WorkerLineage
    ) throws -> ProviderSessionAuthorityObservation {
        guard let providerSessionID = worker.providerSessionID.value,
              !providerSessionID.isEmpty
        else {
            throw ProviderSessionAuthorityError.emptyProviderSessionID
        }

        let snapshot = try registry.snapshot(
            providerID: observer.providerID,
            providerSessionID: providerSessionID
        )

        var decorated = worker
        if let controllerID = snapshot.writerControllerID.value {
            decorated.writerControllerID = .known(controllerID)
            decorated.relationship = .adopted
        }

        return ProviderSessionAuthorityObservation(
            worker: decorated,
            authority: snapshot
        )
    }
}
