import Foundation

/// Whether a structured session actually came back, or was quietly replaced.
///
/// Every structured client accepts a resume id, and every one of them
/// substitutes a brand-new session when that id does not take:
/// `CodexAppServerClient` and `GrokACPClient` catch the failed
/// `thread/resume` / `session/load` and start a fresh one, `OpenCodeHTTPClient`
/// creates a session when its existence check misses, and `StreamJSONClient`
/// never asks the provider at all — it asserts the id and reports ready.
/// The adapter then emits `sessionStarted` and Conduit reports a healthy
/// session with a live runtime. Nothing downstream can tell that the history
/// the caller asked for is gone.
///
/// That is the OBS-2 shape — a clean green result over an empty one — and it
/// is worse here than a wrong answer, because the substitution also **erases
/// the way back**: `AdapterThreadStore` is keyed by task, so the replacement
/// id lands on top of the only pointer to the real thread.
///
/// So the decision each client makes gets a name and a value it must report.
/// `close_outcome` already tells a caller whether a close is reversible
/// *before* it commits; provenance is the same promise for the other
/// direction. Note the deliberate fourth case: a client that never checked
/// says so, rather than guessing in either direction.
public enum SessionResumeSemantics {
    /// What the client did about the resume id it was handed.
    ///
    /// The client is the only thing that knows this, so it is an input here
    /// rather than something inferred from the ids afterwards.
    public enum Attempt: String, Equatable, Sendable {
        /// No resume id was supplied; a new session was expected.
        case notRequested
        /// The provider accepted the id and answered with that session.
        case accepted
        /// The provider refused the id, so a replacement was started.
        case refused
        /// Conduit presented the id as live without asking the provider.
        case unchecked
    }

    /// Where the session Conduit is now driving actually came from.
    public enum Provenance: Equatable, Sendable {
        /// A new session nobody asked to resume. Nothing was lost.
        case fresh(id: String)
        /// The provider honoured the requested id. History is continuous.
        case resumed(id: String)
        /// A resume was requested and refused. `replacement` is live and
        /// empty; the history the caller wanted is under `requested`.
        case restarted(requested: String, replacement: String)
        /// Conduit is driving this as a resume but never confirmed it with the
        /// provider, so continuity is unknown — not assumed either way.
        case unverified(id: String)

        /// The session now being driven.
        public var liveID: String {
            switch self {
            case .fresh(let id), .resumed(let id), .unverified(let id):
                return id
            case .restarted(_, let replacement):
                return replacement
            }
        }

        /// The id this start displaced, and which must survive somewhere.
        ///
        /// Non-nil only when a refused resume put a different session in its
        /// place: that is the one case where writing the live id over the
        /// stored one would destroy the route back to real history.
        public var supersededID: String? {
            guard case .restarted(let requested, let replacement) = self,
                  requested != replacement
            else { return nil }
            return requested
        }

        /// Whether this session contains an earlier session's history.
        ///
        /// Phrased about the session rather than about the request, so it
        /// answers all four cases: `fresh` is false because the session is new,
        /// `restarted` is false because the history was lost, and only
        /// `thread_provenance` distinguishes those two. Three-valued on
        /// purpose -- `nil` means unknown, and an orchestrator must treat
        /// unknown as "verify against the provider's own store", never as yes.
        public var historyIsContinuous: Bool? {
            switch self {
            case .resumed: return true
            case .fresh, .restarted: return false
            case .unverified: return nil
            }
        }

        /// Stable value for the Session API and for logs.
        public var wireValue: String {
            switch self {
            case .fresh: return "fresh"
            case .resumed: return "resumed"
            case .restarted: return "restarted"
            case .unverified: return "unverified"
            }
        }
    }

    /// Total by construction: every client states what it did, and gets back
    /// the only provenance consistent with it.
    public static func classify(
        requested: String?,
        started: String,
        attempt: Attempt
    ) -> Provenance {
        let asked = (requested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return .fresh(id: started) }
        switch attempt {
        case .notRequested:
            // An id was supplied but the client says it never went out. Treat
            // it as the new session it is rather than crediting a resume.
            return .fresh(id: started)
        case .accepted:
            return .resumed(id: started)
        case .refused:
            return .restarted(requested: asked, replacement: started)
        case .unchecked:
            return .unverified(id: started)
        }
    }

    /// What the caller is told, in terms it can branch on.
    public static func authority(for provenance: Provenance) -> String {
        switch provenance {
        case .fresh:
            return "new session; no resume was requested. Not verification."
        case .resumed:
            return "the provider accepted the resume id and this session "
                + "continues the earlier thread. Not verification."
        case .restarted(let requested, _):
            return "RESTARTED, not resumed: the provider refused \(requested) "
                + "and this is a NEW, EMPTY session. Earlier history is not "
                + "present in it and did not transfer. Not verification."
        case .unverified:
            return "presented as a resume but never confirmed with the "
                + "provider, so continuity is UNKNOWN. Read the provider's own "
                + "store before relying on history. Not verification."
        }
    }
}
