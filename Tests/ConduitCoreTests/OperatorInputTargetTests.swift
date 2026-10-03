import XCTest
@testable import ConduitCore

final class OperatorInputTargetTests: XCTestCase {
    private let task = TaskSessionID()
    private let otherTask = TaskSessionID()
    private let runtime = UUID()
    private let attempt = RuntimeAttemptID()

    private var target: OperatorInputTarget {
        OperatorInputTarget(taskSessionID: task, runtimeID: runtime,
                            runtimeAttemptID: attempt, projectPath: "/fixture/project")
    }
    private func selection(_ t: OperatorInputTarget) -> OperatorInputSelection {
        OperatorInputSelection(projectPath: t.projectPath,
                               taskSessionID: t.taskSessionID, activeRuntime: t)
    }

    func testFreshExactTargetAcceptsAndUnrelatedRuntimeDoesNotMakeItAmbiguous() {
        let other = OperatorInputTarget(taskSessionID: otherTask, runtimeID: UUID(),
                         runtimeAttemptID: RuntimeAttemptID(), projectPath: "/fixture/other")
        XCTAssertTrue(OperatorInputGate.permits(target, selection: selection(target),
                                               liveTargets: [target, other]))
    }

    func testChangedTaskSelectionRefuses() {
        let selected = OperatorInputSelection(projectPath: target.projectPath,
                                             taskSessionID: otherTask, activeRuntime: target)
        XCTAssertFalse(OperatorInputGate.permits(target, selection: selected, liveTargets: [target]))
    }

    func testChangedProjectSelectionRefuses() {
        let selected = OperatorInputSelection(projectPath: "/fixture/other",
                                             taskSessionID: task, activeRuntime: target)
        XCTAssertFalse(OperatorInputGate.permits(target, selection: selected, liveTargets: [target]))
    }

    func testMissingSelectionFactsRefuse() {
        for selected in [
            OperatorInputSelection(projectPath: nil, taskSessionID: task, activeRuntime: target),
            OperatorInputSelection(projectPath: target.projectPath, taskSessionID: nil, activeRuntime: target),
            OperatorInputSelection(projectPath: target.projectPath, taskSessionID: task, activeRuntime: nil)
        ] {
            XCTAssertFalse(OperatorInputGate.permits(target, selection: selected, liveTargets: [target]))
        }
    }

    func testChangedActiveRuntimeRefuses() {
        let replacement = OperatorInputTarget(taskSessionID: task, runtimeID: UUID(),
                              runtimeAttemptID: RuntimeAttemptID(), projectPath: target.projectPath)
        XCTAssertFalse(OperatorInputGate.permits(target, selection: selection(replacement),
                                                liveTargets: [target, replacement]))
    }

    func testReusedRuntimeIDWithNewAttemptCannotReviveCapturedTarget() {
        let replacement = OperatorInputTarget(taskSessionID: task, runtimeID: runtime,
                              runtimeAttemptID: RuntimeAttemptID(), projectPath: target.projectPath)
        XCTAssertFalse(OperatorInputGate.permits(target, selection: selection(replacement),
                                                liveTargets: [replacement]))
        XCTAssertFalse(OperatorInputGate.permits(target, selection: selection(target),
                                                liveTargets: [replacement]))
        XCTAssertTrue(OperatorInputGate.permits(replacement, selection: selection(replacement),
                                               liveTargets: [replacement]))
    }

    func testRemovedRuntimeRefuses() {
        XCTAssertFalse(OperatorInputGate.permits(target, selection: selection(target), liveTargets: []))
    }

    func testDuplicateExactBindingRefuses() {
        XCTAssertFalse(OperatorInputGate.permits(target, selection: selection(target),
                                                liveTargets: [target, target]))
    }

    func testDuplicateRuntimeIDWithDifferentAttemptRefuses() {
        let collision = OperatorInputTarget(taskSessionID: otherTask, runtimeID: runtime,
                          runtimeAttemptID: RuntimeAttemptID(), projectPath: "/fixture/other")
        XCTAssertFalse(OperatorInputGate.permits(target, selection: selection(target),
                                                liveTargets: [target, collision]))
    }

    func testTwoLiveRuntimeBindingsToSameTaskRefuse() {
        let other = OperatorInputTarget(taskSessionID: task, runtimeID: UUID(),
                      runtimeAttemptID: RuntimeAttemptID(), projectPath: target.projectPath)
        XCTAssertFalse(OperatorInputGate.permits(target, selection: selection(target),
                                                liveTargets: [target, other]))
    }

    func testExplicitUnboundLegacyRuntimeRetainsExactRuntimeBoundary() {
        let legacy = OperatorInputTarget(taskSessionID: nil, runtimeID: runtime,
                         runtimeAttemptID: attempt, projectPath: target.projectPath)
        XCTAssertTrue(OperatorInputGate.permits(legacy, selection: selection(legacy), liveTargets: [legacy]))
        let boundSelection = OperatorInputSelection(projectPath: legacy.projectPath,
                                                   taskSessionID: task, activeRuntime: legacy)
        XCTAssertFalse(OperatorInputGate.permits(legacy, selection: boundSelection, liveTargets: [legacy]))
    }

    func testIdentifiersContainFullTaskRuntimeAndAttempt() {
        let id = OperatorControlIdentifier.control("strip.choice.1", target: target)
        XCTAssertTrue(id.contains(task.rawValue.uuidString.lowercased()))
        XCTAssertTrue(id.contains(runtime.uuidString.lowercased()))
        XCTAssertTrue(id.contains(attempt.rawValue.uuidString.lowercased()))
        XCTAssertNotEqual(id, OperatorControlIdentifier.settings)
        XCTAssertNotEqual(id, OperatorControlIdentifier.control("strip.enter", target: target))
    }

    func testIdentifiersDoNotAliasDifferentChoiceBytesOrOutputEvents() {
        let choices = ["a.b", "a/b", "a b", "a%2eb", "é", "e\u{0301}", "", "1"]
        XCTAssertEqual(Set(choices.map {
            OperatorControlIdentifier.control("output.one.choice." + $0, target: target)
        }).count, choices.count)
        XCTAssertNotEqual(OperatorControlIdentifier.control("output.one.choice.1", target: target),
                          OperatorControlIdentifier.control("output.two.choice.1", target: target))
    }

    func testShortenedTaskPrefixesCannotAliasControls() {
        let first = TaskSessionID(rawValue: UUID(uuidString: "12345678-0000-0000-0000-000000000001")!)
        let second = TaskSessionID(rawValue: UUID(uuidString: "12345678-0000-0000-0000-000000000002")!)
        XCTAssertNotEqual(OperatorControlIdentifier.task(first), OperatorControlIdentifier.task(second))
    }

    func testUntargetedComposerIsDistinctFromRuntimeAndOtherProject() {
        let empty = OperatorInputSelection(projectPath: "/fixture/a", taskSessionID: nil, activeRuntime: nil)
        let other = OperatorInputSelection(projectPath: "/fixture/b", taskSessionID: nil, activeRuntime: nil)
        XCTAssertNotEqual(OperatorControlIdentifier.composer("send", selection: empty),
                          OperatorControlIdentifier.composer("send", selection: other))
        XCTAssertNotEqual(OperatorControlIdentifier.composer("send", selection: empty),
                          OperatorControlIdentifier.composer("send", selection: selection(target)))
    }

    func testCurrentOutputRevisionAcceptsButLaterMenuRefuses() {
        let a = SessionPresentation.agentOutputEvent(promptEventID: nil, text: "1. First",
                    extraction: .renderedBuffer, truncated: false)
        let b = SessionPresentation.agentOutputEvent(promptEventID: nil, text: "1. Second",
                    extraction: .renderedBuffer, truncated: false)
        let captured = OperatorConversationInputRevision.capture(a)
        XCTAssertTrue(captured.matches(.latest(in: [a])))
        XCTAssertFalse(captured.matches(.latest(in: [a, b])))
        XCTAssertTrue(OperatorConversationInputRevision.capture(b).matches(.latest(in: [a, b])))
    }

    func testSameEventChangedBytesInvalidateOldActionAndSemanticIdentifier() {
        let id = UUID(), time = Date(timeIntervalSince1970: 100)
        let a = SessionPresentation.agentOutputEvent(promptEventID: nil, text: "1. First",
                    extraction: .renderedBuffer, truncated: false, id: id, occurredAt: time)
        let b = SessionPresentation.agentOutputEvent(promptEventID: nil, text: "1. Second",
                    extraction: .renderedBuffer, truncated: false, id: id, occurredAt: time)
        let first = OperatorConversationInputRevision.capture(a)
        let second = OperatorConversationInputRevision.capture(b)
        XCTAssertFalse(first.matches(second))
        XCTAssertNotEqual(first.identifierComponent, second.identifierComponent)
    }

    func testPromptAndInterruptInvalidatePreviousOutputActions() {
        let a = SessionPresentation.agentOutputEvent(promptEventID: nil, text: "1. First",
                    extraction: .renderedBuffer, truncated: false)
        let prompt = SessionPresentation.promptEvent(text: "next", attachmentPaths: [], renderedPayload: "next")
        let captured = OperatorConversationInputRevision.capture(a)
        XCTAssertFalse(captured.matches(.latest(in: [a, prompt])))
        XCTAssertFalse(captured.matches(.latest(in: [a, SessionPresentation.interruptRequestEvent()])))
    }

    func testDuplicateOrUnencodableRevisionRefusesInsteadOfAliasing() {
        let a = SessionPresentation.agentOutputEvent(promptEventID: nil, text: "1. First",
                    extraction: .renderedBuffer, truncated: false)
        XCTAssertFalse(OperatorConversationInputRevision.capture(a).matches(.latest(in: [a, a])))
        let invalid = SessionPresentationEvent(id: a.id, occurredAt: Date(timeIntervalSince1970: .nan),
                         authority: a.authority, kind: a.kind)
        let bad = OperatorConversationInputRevision.capture(invalid)
        XCTAssertNil(bad.contentBytes)
        XCTAssertFalse(bad.matches(bad))
    }
}
