import XCTest
@testable import ConduitCore

final class ConversationTranscriptTests: XCTestCase {
    func testCopyTextForPromptPreservesBodyAndAttachments() {
        let event = SessionPresentation.promptEvent(
            text: "Inspect the failing test.",
            attachmentPaths: ["/tmp/failure.log", "/tmp/fixture.json"],
            renderedPayload: "Inspect the failing test."
        )

        XCTAssertEqual(
            ConversationTranscript.copyText(for: event),
            """
            Inspect the failing test.

            Attachments:
            - `/tmp/failure.log`
            - `/tmp/fixture.json`
            """
        )
    }

    func testCopyTextForAgentOutputUsesWorkstationProjection() {
        let event = SessionPresentation.agentOutputEvent(
            promptEventID: nil,
            text: "Thinking...\n\nFinal answer",
            state: .closed,
            extraction: .structuredAdapter,
            truncated: false
        )

        XCTAssertEqual(
            ConversationTranscript.copyText(for: event),
            "Final answer"
        )
    }

    func testMarkdownRendersReadableRoleLabeledThread() {
        let prompt = SessionPresentation.promptEvent(
            text: "Show the implementation.",
            attachmentPaths: [],
            renderedPayload: "Show the implementation."
        )
        let output = SessionPresentation.agentOutputEvent(
            promptEventID: prompt.id,
            text: "```swift\nlet answer = 42\n```",
            state: .closed,
            extraction: .structuredAdapter,
            truncated: false
        )

        let rendered = ConversationTranscript.markdown(
            events: [prompt, output],
            agentLabel: "Codex"
        )

        XCTAssertEqual(
            rendered,
            """
            ## You

            Show the implementation.

            ## Codex

            ```swift
            let answer = 42
            ```
            """
        )
    }

    func testMarkdownKeepsSessionBoundaryButOmitsHiddenAuthorityMetadata() {
        let opened = SessionPresentation.openingEvent(
            .resumed(
                agentName: "Claude",
                tmuxSessionName: "conduit-claude",
                attachedElsewhere: true
            )
        )
        let output = SessionPresentation.agentOutputEvent(
            promptEventID: nil,
            text: "Done.",
            state: .closed,
            extraction: .tmuxPane,
            truncated: true
        )

        let rendered = ConversationTranscript.markdown(
            events: [opened, output],
            agentLabel: "Claude"
        )

        XCTAssertTrue(rendered.contains("_Reattached Claude · conduit-claude · shared attach_"))
        XCTAssertTrue(rendered.contains("## Claude\n\nDone."))
        XCTAssertFalse(rendered.contains("Derived from Raw"))
        XCTAssertFalse(rendered.contains("truncated"))
    }
}
