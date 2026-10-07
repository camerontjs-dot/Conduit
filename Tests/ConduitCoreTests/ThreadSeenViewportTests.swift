import CoreGraphics
import XCTest
@testable import ConduitCore

final class ThreadSeenViewportTests: XCTestCase {
    private let task = TaskSessionID()
    private let eventID = UUID()
    private let viewport = CGRect(x: 0, y: 100, width: 400, height: 300)
    private let tail = CGRect(x: 20, y: 399, width: 360, height: 1)

    private func revision(_ text: String = "alpha", state: AgentOutputState = .live)
        -> ThreadOutputRevisionIdentity {
        let event = SessionPresentation.agentOutputEvent(
            promptEventID: nil, text: text, state: state,
            extraction: .renderedBuffer, truncated: false, id: eventID,
            occurredAt: Date(timeIntervalSince1970: 1_800_100_000)
        )
        guard case .agentOutput(let output) = event.kind else { fatalError("fixture") }
        return ThreadUnseenOutput.revisionIdentity(event: event, output: output)
    }

    private func sample(
        currentTask: TaskSessionID? = nil,
        rendered: ThreadOutputRevisionIdentity? = nil,
        latest: ThreadOutputRevisionIdentity? = nil,
        tailRect: CGRect? = nil,
        viewportRect: CGRect? = nil
    ) -> ThreadOutputRevisionIdentity? {
        ThreadSeenViewport.visibleRevision(
            renderedTaskSessionID: task, currentTaskSessionID: currentTask ?? task,
            renderedRevision: rendered ?? revision(), latestRevision: latest ?? revision(),
            tailRect: tailRect ?? tail, viewportRect: viewportRect ?? viewport
        )
    }

    func testFullyVisibleTailBindsExactRevision() {
        XCTAssertEqual(sample(), revision())
    }

    func testScrolledAwayTailIsNotVisible() {
        XCTAssertNil(sample(tailRect: tail.offsetBy(dx: 0, dy: 2)))
        XCTAssertNil(sample(tailRect: tail.offsetBy(dx: 0, dy: -400)))
    }

    func testPartialVerticalIntersectionIsInsufficient() {
        XCTAssertNil(sample(tailRect: tail.offsetBy(dx: 0, dy: 0.5)))
    }

    func testPartialHorizontalIntersectionIsInsufficient() {
        XCTAssertNil(sample(tailRect: tail.offsetBy(dx: 21, dy: 0)))
    }

    func testExactEdgeContainmentIsAcceptedWithoutTolerance() {
        XCTAssertEqual(sample(tailRect: CGRect(x: 0, y: 100, width: 400, height: 1)), revision())
        XCTAssertNil(sample(tailRect: CGRect(x: 0, y: 99.999, width: 400, height: 1)))
    }

    func testWrongTaskCannotReuseIdenticalOutput() {
        XCTAssertNil(sample(currentTask: TaskSessionID()))
    }

    func testSameEventIDAndByteCountDoNotHideChangedText() {
        XCTAssertEqual(revision("alpha").visibleUTF8ByteCount, revision("omega").visibleUTF8ByteCount)
        XCTAssertNil(sample(rendered: revision("alpha"), latest: revision("omega")))
    }

    func testMissingCurrentRevisionFailsClosed() {
        XCTAssertNil(ThreadSeenViewport.visibleRevision(
            renderedTaskSessionID: task, currentTaskSessionID: task,
            renderedRevision: revision(), latestRevision: nil,
            tailRect: tail, viewportRect: viewport
        ))
    }

    func testEmptyOutputDoesNotBecomeVisibleViaPlaceholder() {
        XCTAssertNil(sample(rendered: revision(""), latest: revision("")))
    }

    func testCaptureStateOnlyChangeRetainsIdentity() {
        XCTAssertEqual(sample(rendered: revision(state: .live), latest: revision(state: .closed)), revision())
    }

    func testInvalidTailGeometryFailsClosed() {
        for rect in invalidRects {
            XCTAssertNil(sample(tailRect: rect), "Invalid tail: \(rect)")
        }
    }

    func testInvalidViewportGeometryFailsClosed() {
        for rect in invalidRects {
            XCTAssertNil(sample(viewportRect: rect), "Invalid viewport: \(rect)")
        }
    }

    func testGeometryDoesNotOverrideWindowOrSurfaceAuthorization() {
        let visible = sample()
        for index in 0..<5 {
            let observation = ThreadSeenObservation(
                taskSessionID: task,
                surface: index == 0 ? .raw : .conversation,
                applicationIsActive: index != 1,
                windowIsKey: index != 2,
                windowIsVisible: index != 3,
                windowIsOcclusionVisible: index != 4,
                visibleLatestRevision: visible
            )
            XCTAssertEqual(ThreadSeenCursor.decide(
                taskSessionID: task, unseenState: .unseen(revision()), observation: observation
            ), .unchanged)
        }
    }

    private var invalidRects: [CGRect] {
        [
            .zero, .null, .infinite,
            CGRect(x: 20, y: 399, width: 0, height: 1),
            CGRect(x: 20, y: 399, width: -1, height: 1),
            CGRect(x: 20, y: 399, width: 360, height: -1),
            CGRect(x: CGFloat.nan, y: 399, width: 360, height: 1),
            CGRect(x: 20, y: CGFloat.nan, width: 360, height: 1),
            CGRect(x: 20, y: 399, width: CGFloat.nan, height: 1),
            CGRect(x: 20, y: 399, width: 360, height: CGFloat.infinity),
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                   width: CGFloat.greatestFiniteMagnitude, height: 1)
        ]
    }
}
