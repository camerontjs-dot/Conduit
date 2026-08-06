import XCTest
@testable import ConduitCore

final class RawDerivedOutputTests: XCTestCase {
    func testExactLinePrefixReturnsAppendedSuffix() {
        let result = deriveOutput(
            baseline: "Conduit Agent\nReady\n\n",
            current: """
            Conduit Agent
            Ready
            Inspected the source.
            The tests are passing.

            """
        )

        XCTAssertEqual(result.strategy, .appendedSuffix)
        XCTAssertEqual(
            result.text,
            "Inspected the source.\nThe tests are passing."
        )
        XCTAssertFalse(result.truncated)
    }

    func testRepaintUsesLCSDeltaAndRemovesUnchangedChrome() {
        let result = deriveOutput(
            baseline: """
            Claude Code
            Working…
            esc to interrupt
            """,
            current: """
            Claude Code
            Updated two files.
            Added four tests.
            esc to interrupt
            """
        )

        XCTAssertEqual(result.strategy, .screenDelta)
        XCTAssertEqual(result.text, "Updated two files.\nAdded four tests.")
        XCTAssertFalse(result.text.contains("Claude Code"))
        XCTAssertFalse(result.text.contains("esc to interrupt"))
    }

    func testExactPromptEchoIsRemovedFromAppendedOutput() {
        let result = deriveOutput(
            baseline: "Agent\nReady",
            current: """
            Agent
            Ready
            Explain the failure

            The configuration path is missing.
            """,
            promptText: "Explain the failure"
        )

        XCTAssertEqual(result.strategy, .appendedSuffix)
        XCTAssertEqual(result.text, "The configuration path is missing.")
    }

    func testUnchangedRenderingReturnsEmptyAppendedSuffix() {
        let result = deriveOutput(
            baseline: "Agent\nReady\n\n",
            current: "Agent\nReady"
        )

        XCTAssertEqual(result.strategy, .appendedSuffix)
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.truncated)
    }

    func testAmbiguousRepaintDeclinesCurrentScreenFallback() {
        let reduction = RawDerivedOutputReducer.derive(
            baseline: snapshot("Old full-screen interface"),
            current: snapshot("New interface\nVisible response")
        )

        XCTAssertEqual(reduction, .unavailable(.noStableAnchor))
    }

    func testTruncationKeepsNewestContentAndIncludesMarkerWithinLimit() {
        let limit = 96
        let recent = String(repeating: "z", count: 180)
        let result = deriveOutput(
            baseline: "Ready",
            current: "Ready\n\(recent)",
            maximumCharacters: limit
        )

        XCTAssertEqual(result.strategy, .appendedSuffix)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text.count, limit)
        XCTAssertTrue(
            result.text.hasPrefix(
                RawDerivedOutputReducer.truncationMarker
            )
        )
        XCTAssertTrue(result.text.hasSuffix(String(repeating: "z", count: 20)))
    }

    func testEmptyBaselineIsUnavailableInsteadOfImportingCurrentScreen() {
        let reduction = RawDerivedOutputReducer.derive(
            baseline: snapshot("\n\n"),
            current: snapshot("Earlier pane history\nNew response")
        )

        XCTAssertEqual(reduction, .unavailable(.baselineUnavailable))
    }

    func testMultilinePromptEchoAndCRLFNormalizeDeterministically() {
        let result = deriveOutput(
            baseline: "Header\r\nReady\r\n",
            current: """
            Header
            Ready
            First prompt line
            Second prompt line

            First response paragraph.

            Second response paragraph.
            """,
            promptText: "First prompt line\r\nSecond prompt line\r\n"
        )

        XCTAssertEqual(result.strategy, .appendedSuffix)
        XCTAssertEqual(
            result.text,
            "First response paragraph.\n\nSecond response paragraph."
        )
        XCTAssertFalse(result.truncated)
    }

    func testPartialPromptMatchIsPreservedRatherThanGuessedAway() {
        let result = deriveOutput(
            baseline: "Header",
            current: """
            Header
            › Explain the failure
            Response
            """,
            promptText: "Explain the failure"
        )

        XCTAssertEqual(
            result.text,
            "› Explain the failure\nResponse"
        )
    }

    func testDifferentExtractionSurfacesAreNeverCompared() {
        let reduction = RawDerivedOutputReducer.derive(
            baseline: snapshot(
                "Rendered outer terminal",
                extraction: .renderedBuffer
            ),
            current: snapshot(
                "Rendered tmux pane",
                extraction: .tmuxPane
            )
        )

        XCTAssertEqual(reduction, .unavailable(.extractionChanged))
    }

    func testOversizedNonPrefixRepaintDeclinesInsteadOfPersistingScreen() {
        let baseline = (0...700)
            .map { "old-\($0)" }
            .joined(separator: "\n")
        let current = (0...700)
            .map { "new-\($0)" }
            .joined(separator: "\n")

        let reduction = RawDerivedOutputReducer.derive(
            baseline: snapshot(baseline),
            current: snapshot(current)
        )

        XCTAssertEqual(reduction, .unavailable(.comparisonTooLarge))
    }

    private func snapshot(
        _ text: String,
        extraction: AgentOutputExtraction = .renderedBuffer
    ) -> RawDerivedSnapshot {
        RawDerivedSnapshot(text: text, extraction: extraction)
    }

    private func deriveOutput(
        baseline: String,
        current: String,
        promptText: String? = nil,
        maximumCharacters: Int = RawDerivedOutputReducer.defaultMaximumCharacters,
        extraction: AgentOutputExtraction = .renderedBuffer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> RawDerivedOutputResult {
        let reduction = RawDerivedOutputReducer.derive(
            baseline: snapshot(baseline, extraction: extraction),
            current: snapshot(current, extraction: extraction),
            promptText: promptText,
            maximumCharacters: maximumCharacters
        )
        guard case .output(let result) = reduction else {
            XCTFail(
                "Expected output reduction, got \(reduction)",
                file: file,
                line: line
            )
            return RawDerivedOutputResult(
                text: "",
                strategy: .appendedSuffix,
                truncated: false
            )
        }
        return result
    }
}
