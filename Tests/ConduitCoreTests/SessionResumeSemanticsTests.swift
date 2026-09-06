import XCTest
@testable import ConduitCore

/// The branch these cover is the one 342 green tests never entered: it only
/// runs when a provider refuses a resume, deep inside a live handshake.
final class SessionResumeSemanticsTests: XCTestCase {
    func testNoResumeRequestedIsFresh() {
        let p = SessionResumeSemantics.classify(
            requested: nil, started: "s-1", attempt: .notRequested
        )
        XCTAssertEqual(p, .fresh(id: "s-1"))
        XCTAssertNil(p.supersededID)
        XCTAssertEqual(p.historyIsContinuous, false)
    }

    func testEmptyResumeIDIsFreshNotAResume() {
        for requested in ["", "   "] {
            let p = SessionResumeSemantics.classify(
                requested: requested, started: "s-1", attempt: .accepted
            )
            XCTAssertEqual(p, .fresh(id: "s-1"), "blank id must not count as a resume")
        }
    }

    func testAcceptedResumeIsContinuous() {
        let p = SessionResumeSemantics.classify(
            requested: "t-old", started: "t-old", attempt: .accepted
        )
        XCTAssertEqual(p, .resumed(id: "t-old"))
        XCTAssertEqual(p.historyIsContinuous, true)
        XCTAssertNil(p.supersededID)
    }

    /// The defect this whole type exists for.
    func testRefusedResumeIsRestartedAndNamesWhatItDisplaced() {
        let p = SessionResumeSemantics.classify(
            requested: "t-old", started: "t-new", attempt: .refused
        )
        XCTAssertEqual(p, .restarted(requested: "t-old", replacement: "t-new"))
        XCTAssertEqual(p.liveID, "t-new")
        XCTAssertEqual(p.supersededID, "t-old", "the route back must be named")
        XCTAssertEqual(p.historyIsContinuous, false)
    }

    func testRestartedAuthoritySaysEmptyNotResumed() {
        let line = SessionResumeSemantics.authority(
            for: .restarted(requested: "t-old", replacement: "t-new")
        )
        XCTAssertTrue(line.contains("RESTARTED"))
        XCTAssertTrue(line.contains("EMPTY"))
        XCTAssertTrue(line.contains("t-old"), "name the thread the caller wanted")
        XCTAssertFalse(line.hasPrefix("the provider accepted"))
    }

    /// StreamJSON (Claude, Antigravity) never contacts the provider at start.
    func testUncheckedResumeIsUnknownNotAssumedEitherWay() {
        let p = SessionResumeSemantics.classify(
            requested: "c-1", started: "c-1", attempt: .unchecked
        )
        XCTAssertEqual(p, .unverified(id: "c-1"))
        XCTAssertNil(p.historyIsContinuous, "unknown is not false and not true")
        XCTAssertNil(p.supersededID, "nothing was displaced; it may still be live")
        XCTAssertTrue(SessionResumeSemantics.authority(for: p).contains("UNKNOWN"))
    }

    func testARestartOntoTheSameIDDisplacesNothing() {
        let p = SessionResumeSemantics.classify(
            requested: "t-1", started: "t-1", attempt: .refused
        )
        XCTAssertNil(p.supersededID, "same id: there is no other pointer to keep")
    }

    func testWireValuesAreStable() {
        XCTAssertEqual(SessionResumeSemantics.Provenance.fresh(id: "a").wireValue, "fresh")
        XCTAssertEqual(SessionResumeSemantics.Provenance.resumed(id: "a").wireValue, "resumed")
        XCTAssertEqual(
            SessionResumeSemantics.Provenance
                .restarted(requested: "a", replacement: "b").wireValue,
            "restarted"
        )
        XCTAssertEqual(
            SessionResumeSemantics.Provenance.unverified(id: "a").wireValue, "unverified"
        )
    }

    func testOnlyResumedEverClaimsContinuity() {
        let all: [SessionResumeSemantics.Provenance] = [
            .fresh(id: "a"),
            .resumed(id: "a"),
            .restarted(requested: "a", replacement: "b"),
            .unverified(id: "a"),
        ]
        XCTAssertEqual(all.filter { $0.historyIsContinuous == true }, [.resumed(id: "a")])
    }
}
