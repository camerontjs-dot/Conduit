import Foundation
import XCTest
@testable import ConduitCore

/// Deterministic coverage for the Slice 4 active-turn queue (issue #77).
///
/// A second structured prompt while a provider turn is active must not
/// collide with that turn unless the provider offers proven in-turn
/// steering. These tests pin the FIFO queue mechanics that
/// `TerminalRuntime` delegates to: single release per provider turn,
/// readiness-only expiry, and explicit teardown — without any live
/// provider, process, or clock beyond the dates the tests supply.
final class StructuredPromptQueueTests: XCTestCase {

    private typealias Hold = StructuredPromptHold
    private typealias Queue = StructuredPromptQueue

    private func entry(
        _ text: String,
        reason: Hold.HoldReason = .queuedBehindActiveTurn,
        heldAt: Date = Date(timeIntervalSince1970: 1_799_956_800)
    ) -> (eventID: UUID, text: String, reason: Hold.HoldReason, heldAt: Date) {
        (UUID(), text, reason, heldAt)
    }

    private func enqueue(
        _ queue: inout Queue,
        _ text: String,
        reason: Hold.HoldReason = .queuedBehindActiveTurn
    ) -> UUID {
        let parts = entry(text, reason: reason)
        queue.enqueue(
            eventID: parts.eventID,
            text: parts.text,
            reason: parts.reason,
            heldAt: parts.heldAt
        )
        return parts.eventID
    }

    // MARK: - FIFO order

    func testMultipleQueuedPromptsReleaseInArrivalOrder() {
        var queue = Queue()
        let first = enqueue(&queue, "B")
        let second = enqueue(&queue, "C")
        let third = enqueue(&queue, "D")

        XCTAssertEqual(queue.count, 3)
        let releasedFirst = queue.releaseNext(
            isReady: true, isTurnActive: false, policy: .queue
        )
        XCTAssertEqual(releasedFirst?.eventID, first)
        XCTAssertEqual(releasedFirst?.text, "B")
        // The first release starts a provider turn. While it is active the
        // next prompt waits; when the terminal observation lands it follows
        // the preceding turn, not the original one.
        XCTAssertNil(
            queue.releaseNext(isReady: true, isTurnActive: true, policy: .queue)
        )
        let releasedSecond = queue.releaseNext(
            isReady: true, isTurnActive: false, policy: .queue
        )
        XCTAssertEqual(releasedSecond?.eventID, second)
        XCTAssertNil(
            queue.releaseNext(isReady: true, isTurnActive: true, policy: .queue)
        )
        let releasedThird = queue.releaseNext(
            isReady: true, isTurnActive: false, policy: .queue
        )
        XCTAssertEqual(releasedThird?.eventID, third)
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - One release per provider turn

    func testOnlyOnePromptIsReleasedPerProviderTurn() {
        var queue = Queue()
        enqueue(&queue, "B")
        enqueue(&queue, "C")

        let first = queue.releaseNext(
            isReady: true, isTurnActive: false, policy: .queue
        )
        XCTAssertNotNil(first)
        XCTAssertEqual(queue.count, 1, "the second prompt stays queued")
        // The released prompt starts a turn, so the runtime is active now.
        // A second immediate release would overlap the turn it just started.
        XCTAssertNil(
            queue.releaseNext(isReady: true, isTurnActive: true, policy: .queue),
            "only one queued prompt is released per provider turn"
        )
        XCTAssertEqual(queue.count, 1, "a blocked release must not consume")
    }

    func testATerminalProviderEventPermitsTheNextQueuedPrompt() {
        var queue = Queue()
        enqueue(&queue, "B")
        enqueue(&queue, "C")

        _ = queue.releaseNext(
            isReady: true, isTurnActive: false, policy: .queue
        )
        // A terminal observation (completed or a genuinely terminal failure)
        // ends the turn: isTurnActive falls and the next prompt may go.
        let next = queue.releaseNext(
            isReady: true, isTurnActive: false, policy: .queue
        )
        XCTAssertEqual(next?.text, "C")
    }

    func testANonTerminalErrorDoesNotAdvanceTheQueue() {
        // A late or transient provider error that leaves the turn active
        // must not release the next prompt: the preceding turn has not
        // reached a terminal observation.
        var queue = Queue()
        enqueue(&queue, "B")
        enqueue(&queue, "C")

        _ = queue.releaseNext(
            isReady: true, isTurnActive: false, policy: .queue
        )
        XCTAssertNil(
            queue.releaseNext(isReady: true, isTurnActive: true, policy: .queue),
            "turn still active after a non-terminal error; queue must not advance"
        )
        XCTAssertEqual(queue.count, 1)
    }

    // MARK: - Release gates

    func testReleaseIsBlockedWhileAQueuedPolicyTurnIsActive() {
        var queue = Queue()
        enqueue(&queue, "B")
        XCTAssertNil(
            queue.releaseNext(isReady: true, isTurnActive: true, policy: .queue)
        )
        XCTAssertEqual(queue.count, 1)
    }

    func testSteeringReleasesWhileTheTurnIsActive() {
        // Codex turn/steer is provider-supported steering, not queueing.
        var queue = Queue()
        enqueue(&queue, "steer me")
        let released = queue.releaseNext(
            isReady: true, isTurnActive: true, policy: .steer
        )
        XCTAssertEqual(released?.text, "steer me")
        XCTAssertTrue(queue.isEmpty)
    }

    func testReleaseIsBlockedWhileTheRuntimeIsNotReady() {
        var queue = Queue()
        enqueue(&queue, "B", reason: .awaitingReadiness)
        XCTAssertNil(
            queue.releaseNext(
                isReady: false, isTurnActive: false, policy: .queue
            )
        )
        XCTAssertEqual(queue.count, 1)
    }

    func testReleasingFromAnEmptyQueueReturnsNil() {
        var queue = Queue()
        XCTAssertNil(
            queue.releaseNext(isReady: true, isTurnActive: false, policy: .queue)
        )
    }

    // MARK: - Exactly once

    func testAReleasedPromptIsDeliveredExactlyOnce() {
        var queue = Queue()
        let id = enqueue(&queue, "B")
        let released = queue.releaseNext(
            isReady: true, isTurnActive: false, policy: .queue
        )
        XCTAssertEqual(released?.eventID, id)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(
            queue.releaseNext(
                isReady: true, isTurnActive: false, policy: .queue
            ),
            "no prompt is duplicated or delivered twice"
        )
    }

    func testTheOriginalPromptEventIdentityIsRetained() {
        var queue = Queue()
        let id = enqueue(&queue, "B")
        let released = queue.releaseNext(
            isReady: true, isTurnActive: false, policy: .queue
        )
        XCTAssertEqual(
            released?.eventID, id,
            "the queued prompt keeps its original Conduit prompt event"
        )
        XCTAssertEqual(released?.text, "B")
        XCTAssertEqual(released?.reason, .queuedBehindActiveTurn)
    }

    // MARK: - Expiry and teardown

    func testReadinessGraceExpiresOnlyReadinessHolds() {
        var queue = Queue()
        let base = Date(timeIntervalSince1970: 1_799_956_800)
        let pastGrace = base.addingTimeInterval(
            Hold.readinessGrace + 60
        )
        queue.enqueue(
            eventID: UUID(),
            text: "slow starter",
            reason: .awaitingReadiness,
            heldAt: base
        )
        queue.enqueue(
            eventID: UUID(),
            text: "behind a long turn",
            reason: .queuedBehindActiveTurn,
            heldAt: base
        )
        let expired = queue.expireReadinessHolds(now: pastGrace)
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(expired.first?.text, "slow starter")
        XCTAssertEqual(
            queue.count, 1,
            "a prompt queued behind a legitimately long turn must not be "
                + "abandoned by the readiness clock"
        )
        XCTAssertEqual(queue.entries.first?.text, "behind a long turn")
    }

    func testTeardownResolvesEveryRemainingQueuedPromptExplicitly() {
        var queue = Queue()
        enqueue(&queue, "B")
        enqueue(&queue, "C")
        enqueue(&queue, "D", reason: .awaitingReadiness)

        let drained = queue.drainForTeardown()
        XCTAssertEqual(drained.map(\.text), ["B", "C", "D"])
        XCTAssertTrue(
            queue.isEmpty,
            "teardown must strand no prompt"
        )
        // Every drained entry is returned so the caller can resolve it on
        // its durable prompt event; none is silently dropped.
        XCTAssertEqual(Set(drained.map(\.eventID)).count, 3)
    }
}
