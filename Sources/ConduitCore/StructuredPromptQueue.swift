import Foundation

/// FIFO queue for structured prompts Conduit accepted while it could not
/// deliver them immediately (issue #77, Slice 4).
///
/// Two holds share one arrival order but different bounds: prompts held for
/// readiness drain when the host reports ready, while prompts queued behind
/// an active turn drain one per provider turn — each release starts a turn,
/// and the next release waits for that turn's terminal observation. The
/// readiness clock therefore expires only readiness holds; a prompt waiting
/// behind a legitimately long turn is bounded by the turn (or teardown),
/// never by startup grace.
///
/// This type is deliberately free of providers, clocks beyond the dates it
/// is given, and UI: `TerminalRuntime` owns one instance and supplies live
/// readiness/turn state, while the deterministic policy here stays unit
/// testable.
public struct StructuredPromptQueue: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// The original Conduit prompt event. The queue never re-records:
        /// resolution lands on this same event, so IDs and content digests
        /// stay stable from acceptance through delivery.
        public let eventID: UUID
        public let text: String
        public let reason: StructuredPromptHold.HoldReason
        public let heldAt: Date

        public init(
            eventID: UUID,
            text: String,
            reason: StructuredPromptHold.HoldReason,
            heldAt: Date
        ) {
            self.eventID = eventID
            self.text = text
            self.reason = reason
            self.heldAt = heldAt
        }
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Oldest hold still outstanding, for re-arming the expiry deadline.
    public var oldestHeldAt: Date? { entries.map(\.heldAt).min() }

    public mutating func enqueue(
        eventID: UUID,
        text: String,
        reason: StructuredPromptHold.HoldReason,
        heldAt: Date = Date()
    ) {
        entries.append(
            Entry(eventID: eventID, text: text, reason: reason, heldAt: heldAt)
        )
    }

    /// Release at most the head of the queue.
    ///
    /// Release requires a ready runtime and, under `.queue`, no active turn:
    /// the released prompt becomes the next provider turn, so releasing
    /// while a turn is active would overlap it. Under `.steer` the provider
    /// steers the active turn natively and the head may go immediately. A
    /// blocked release consumes nothing — the queue is unchanged.
    public mutating func releaseNext(
        isReady: Bool,
        isTurnActive: Bool,
        policy: StructuredPromptHold.ActiveTurnInputPolicy
    ) -> Entry? {
        guard isReady, !entries.isEmpty else { return nil }
        if isTurnActive, policy == .queue { return nil }
        return entries.removeFirst()
    }

    /// Expire readiness holds that outlived the grace period.
    ///
    /// Only `.awaitingReadiness` entries are governed by the readiness
    /// clock. `.queuedBehindActiveTurn` entries are returned untouched:
    /// their bound is the active turn's terminal observation or teardown.
    /// Every returned entry still needs an explicit resolution recorded on
    /// its prompt event by the caller.
    public mutating func expireReadinessHolds(
        now: Date,
        grace: TimeInterval = StructuredPromptHold.readinessGrace
    ) -> [Entry] {
        let expired = entries.filter {
            $0.reason == .awaitingReadiness
                && StructuredPromptHold.hasExpired(
                    heldAt: $0.heldAt, now: now, grace: grace
                )
        }
        guard !expired.isEmpty else { return [] }
        let expiredIDs = Set(expired.map(\.eventID))
        entries.removeAll { expiredIDs.contains($0.eventID) }
        return expired
    }

    /// Remove every remaining entry, in FIFO order, for explicit teardown
    /// resolution. The caller records each entry's resolution on its durable
    /// prompt event; nothing is stranded and nothing is silently dropped.
    public mutating func drainForTeardown() -> [Entry] {
        let pending = entries
        entries = []
        return pending
    }
}
