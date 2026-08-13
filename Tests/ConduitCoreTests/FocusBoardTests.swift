import XCTest
@testable import ConduitCore

final class FocusBoardTests: XCTestCase {
    private let nowMs: Double = 1_783_879_200_000 // 2026-07-12T18:00:00Z

    func testVocabulary() {
        XCTAssertEqual(FocusBoardSeverity.urgent.rank, 4)
        XCTAssertGreaterThan(FocusBoardSeverity.urgent.rank, FocusBoardSeverity.info.rank)
        XCTAssertEqual(FocusBoardConstants.weeklyStaleDays, 8)
        XCTAssertEqual(FocusBoardConstants.activeCap, 10)
        XCTAssertTrue(FocusBoardSource.allCases.contains(.sessionClose))
        XCTAssertTrue(FocusBoardSource.allCases.contains(.feedsMissing))
    }

    func testParseJsonlSkipsBadLines() {
        XCTAssertTrue(FocusBoard.parseJsonl("").isEmpty)
        XCTAssertEqual(FocusBoard.parseJsonl("{not json\n{\"a\":1}\n").count, 1)
        XCTAssertEqual(FocusBoard.parseJsonl("{\"a\":1}\n{\"b\":2}\n").count, 2)
    }

    func testRankAndDedupe() {
        let ranked = FocusBoard.rankFocusItems([
            item(id: "i", severity: .info, asOf: "2026-07-12"),
            item(id: "u", severity: .urgent, asOf: "2026-07-12"),
            item(id: "w", severity: .watch, asOf: "2026-07-10"),
        ])
        XCTAssertEqual(ranked.map(\.id), ["u", "w", "i"])

        let deduped = FocusBoard.dedupeFocusItems([
            item(id: "x", severity: .watch),
            item(id: "x", severity: .urgent),
        ])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.severity, .urgent)
    }

    func testCloseCheckProjectors() {
        let close = FocusBoard.itemsFromCloseCheck(
            FocusBoardJSON([
                "fixture": .bool(true),
                "kind": .string("close-check"),
                "ok": .bool(false),
                "session_hash": .string("deadbeefdeadbeef"),
                "as_of": .string("2026-07-12"),
                "warnings": .array([.string("eval-schedule"), .string("working-tree")]),
                "actions": .array([
                    .object(FocusBoardJSON([
                        "kind": .string("manual"),
                        "name": .string("state-md-narrative"),
                        "needed": .bool(true),
                        "ran": .bool(false),
                        "reason": .string("update STATE"),
                    ])),
                    .object(FocusBoardJSON([
                        "kind": .string("auto"),
                        "name": .string("sync-project-index"),
                        "needed": .bool(true),
                        "ran": .bool(false),
                        "reason": .string("stale"),
                    ])),
                ]),
            ])
        )
        XCTAssertTrue(close.allSatisfy(\.fixture))
        XCTAssertTrue(close.contains { $0.severity == .urgent && $0.source == .sessionClose })
        XCTAssertTrue(close.contains { $0.source == .evalSchedule })
        XCTAssertTrue(close.contains { $0.source == .workingTree })
        XCTAssertTrue(close.contains { $0.severity == .actionRequired })
        XCTAssertTrue(close.contains { $0.id.contains("close-auto-sync") })
        XCTAssertTrue(FocusBoard.itemsFromCloseCheck(FocusBoardJSON(["kind": .string("checkpoint")])).isEmpty)
        XCTAssertTrue(FocusBoard.itemsFromCloseCheck(FocusBoardJSON()).isEmpty)
    }

    func testCheckpointProjectors() {
        let drift = FocusBoard.itemsFromCheckpoint(
            FocusBoardJSON([
                "fixture": .bool(true),
                "kind": .string("checkpoint"),
                "drift": .bool(true),
                "session_hash": .string("cafebabecafebabe"),
                "as_of": .string("2026-07-12"),
                "dirty_files": .number(0),
            ])
        )
        XCTAssertTrue(drift.contains { $0.severity == .actionRequired })

        let ok = FocusBoard.itemsFromCheckpoint(
            FocusBoardJSON([
                "fixture": .bool(true),
                "kind": .string("checkpoint"),
                "drift": .bool(false),
                "session_hash": .string("1111111111111111"),
                "as_of": .string("2026-07-12"),
                "dirty_files": .number(0),
                "weekly_eval": .object(FocusBoardJSON([
                    "ok": .bool(true),
                    "stale": .bool(false),
                ])),
            ])
        )
        XCTAssertEqual(ok.count, 1)
        XCTAssertEqual(ok.first?.severity, .info)
    }

    func testScheduleProjectors() {
        let stale = FocusBoard.itemsFromScheduleRuns(
            [
                FocusBoardJSON([
                    "fixture": .bool(true),
                    "cadence": .string("weekly"),
                    "all_passed": .bool(true),
                    "run_id": .string("old"),
                    "finished_at": .string("2026-07-01T00:00:00Z"),
                ]),
            ],
            nowMs: Date.parseISO("2026-07-12T18:00:00Z")
        )
        XCTAssertTrue(stale.contains { $0.id.hasPrefix("eval-stale") })

        let failed = FocusBoard.itemsFromScheduleRuns(
            [
                FocusBoardJSON([
                    "fixture": .bool(true),
                    "cadence": .string("weekly"),
                    "all_passed": .bool(false),
                    "run_id": .string("bad"),
                    "finished_at": .string("2026-07-12T00:00:00Z"),
                ]),
            ],
            nowMs: Date.parseISO("2026-07-12T18:00:00Z")
        )
        XCTAssertTrue(failed.contains { $0.id.hasPrefix("eval-failed") })
    }

    func testProjectIndexAndIngest() {
        let wip = FocusBoard.itemsFromProjectIndex(
            FocusBoardProjectIndexSummary(
                activeCount: 11,
                activeCap: 10,
                problems: [
                    FocusBoardProjectProblem(
                        code: "missing_frontmatter",
                        project: "repo-radar",
                        detail: "no frontmatter"
                    ),
                ],
                fixture: true
            )
        )
        XCTAssertTrue(wip.contains { $0.id == "project-wip-breach" })
        XCTAssertTrue(wip.contains { $0.severity == .actionRequired })

        let ingest = FocusBoard.itemsFromIngestStatus(
            FocusBoardJSON([
                "fixture": .bool(true),
                "lanes": .array([
                    .object(FocusBoardJSON([
                        "name": .string("00_inbox"),
                        "files": .number(3),
                        "oldest_file_age_days": .number(12),
                    ])),
                    .object(FocusBoardJSON([
                        "name": .string("01_ingest/ready"),
                        "files": .number(0),
                        "oldest_file_age_days": .null,
                    ])),
                ]),
            ])
        )
        XCTAssertTrue(ingest.contains { $0.source == .ingest && $0.severity == .watch })
    }

    func testMissingFeedsIsNotAllClear() {
        let board = FocusBoard.buildFocusBoard(
            FocusBoardInputs(nowMs: nowMs, feedsMissing: true, fixture: true)
        )
        XCTAssertTrue(board.insufficient)
        XCTAssertEqual(board.items.count, 1)
        XCTAssertEqual(board.items[0].source, .feedsMissing)
        XCTAssertTrue(board.items[0].title.contains("No truth feeds"))
        XCTAssertTrue(board.fixture)
        XCTAssertFalse(board.items[0].title.lowercased().contains("all-clear"))
    }

    func testAllClearFixture() {
        let board = FocusBoard.buildFocusBoard(allClearInputs())
        XCTAssertFalse(board.insufficient)
        XCTAssertTrue(board.fixture)
        XCTAssertTrue(board.items.allSatisfy(\.fixture))
        XCTAssertFalse(board.items.contains { $0.severity == .urgent || $0.severity == .actionRequired })
        XCTAssertTrue(board.items.contains { $0.source == .evalSchedule && $0.severity == .info })
        XCTAssertEqual(board.items.map(\.id), [
            "checkpoint-ok-bbbbbbbb",
            "eval-ok-2026-07-12T100000-scheduled-weekly",
        ])
    }

    func testStaleWeeklyFixture() {
        let board = FocusBoard.buildFocusBoard(staleWeeklyInputs())
        XCTAssertTrue(board.items.contains { $0.severity == .urgent && $0.source == .evalSchedule })
        XCTAssertTrue(board.items.contains {
            $0.title.contains("Session close check failed") || $0.id.contains("close-check-failed")
        })
        XCTAssertEqual(board.items.first?.severity, .urgent)
        XCTAssertEqual(board.items[0].id, "eval-stale-2026-07-02T093908-scheduled-weekly")
    }

    func testWIPBreachFixture() {
        let board = FocusBoard.buildFocusBoard(wipBreachInputs())
        XCTAssertTrue(board.items.contains { $0.id == "project-wip-breach" })
        XCTAssertTrue(board.items.contains { $0.id.contains("missing_frontmatter") })
        XCTAssertEqual(board.items.first?.severity, .urgent)
        XCTAssertEqual(board.items[0].id, "project-wip-breach")
    }

    func testPendingAutoFixture() {
        let board = FocusBoard.buildFocusBoard(pendingAutoInputs())
        XCTAssertTrue(board.items.contains {
            $0.severity == .actionRequired && $0.title.contains("state-md-narrative")
        })
        XCTAssertTrue(board.items.contains {
            $0.severity == .watch && $0.title.contains("sync-project-index")
        })
        XCTAssertTrue(board.items.contains { $0.source == .workingTree })
        XCTAssertEqual(board.items[0].severity, .urgent)
    }

    func testOnlyLatestCloseCheckIsProjected() {
        let board = FocusBoard.buildFocusBoard(
            FocusBoardInputs(
                sessionCloseRecords: [
                    FocusBoardJSON([
                        "fixture": .bool(true),
                        "kind": .string("close-check"),
                        "ok": .bool(true),
                        "session_hash": .string("oldoldoldoldold1"),
                        "logged_at": .string("2026-07-10T12:00:00Z"),
                        "as_of": .string("2026-07-10"),
                        "actions": .array([
                            .object(FocusBoardJSON([
                                "kind": .string("manual"),
                                "name": .string("old-manual"),
                                "needed": .bool(true),
                                "ran": .bool(false),
                                "reason": .string("old"),
                            ])),
                        ]),
                        "warnings": .array([]),
                    ]),
                    FocusBoardJSON([
                        "fixture": .bool(true),
                        "kind": .string("close-check"),
                        "ok": .bool(true),
                        "session_hash": .string("newnewnewnewnew1"),
                        "logged_at": .string("2026-07-12T12:00:00Z"),
                        "as_of": .string("2026-07-12"),
                        "actions": .array([]),
                        "warnings": .array([]),
                    ]),
                ],
                scheduleRuns: [
                    FocusBoardJSON([
                        "fixture": .bool(true),
                        "cadence": .string("weekly"),
                        "all_passed": .bool(true),
                        "run_id": .string("recent"),
                        "finished_at": .string("2026-07-12T00:00:00Z"),
                    ]),
                ],
                nowMs: Date.parseISO("2026-07-12T18:00:00Z"),
                fixture: true
            )
        )
        XCTAssertFalse(board.items.contains { $0.title.contains("old-manual") })
    }

    func testParseProjectIndexMarkdown() {
        let md = """
        # Projects Index

        | Project | State | Goal | Next action | Updated | Evidence |
        | --- | --- | --- | --- | --- | --- |
        | [Alpha](alpha/README.md) | active | do things | ship unit | 2026-07-15 | 2026-07-15 |
        | [Beta](beta/README.md) | active | wait | - | 2026-07-01 | - |
        | [Gamma](gamma/README.md) | weird | x | y | 2026-07-01 | 2026-07-01 |
        | [Delta](delta/README.md) | paused | park | reentry | 2026-07-01 | 2026-07-01 |
        """
        let summary = FocusBoard.parseProjectIndexMarkdown(md, activeCap: 10, asOf: "2026-07-15")
        XCTAssertEqual(summary.activeCount, 2)
        XCTAssertEqual(summary.activeCap, 10)
        XCTAssertEqual(summary.projects.count, 4)
        XCTAssertTrue(summary.problems.contains { $0.code == "unknown_state" && $0.project == "gamma" })
        XCTAssertTrue(summary.problems.contains { $0.code == "active_without_evidence" && $0.project == "beta" })
        XCTAssertTrue(summary.problems.contains { $0.code == "active_missing_next_action" && $0.project == "beta" })
        XCTAssertFalse(summary.problems.contains { $0.project == "alpha" && $0.code == "active_without_evidence" })
    }

    func testApprovedFocusAndProposalParsers() {
        let yaml = """
        schema_version: 1
        decision_id: focus-fixture-01
        revision: fixture-revision
        as_of: 2026-07-15T00:00:00Z
        review_by: 2099-01-01T00:00:00Z
        selected_by: operator
        primary:
          project: one
          desired_outcome: Keep the fixture bounded
          success_boundary: One read-only render
          why_now: Test the display seam
          confidence: high
          evidence_refs:
            - 30_projects/one/README.md
        supporting_slots: []
        snoozed: []
        candidate_snapshot: null
        """
        let approved = FocusBoard.parseApprovedFocus(yaml)
        XCTAssertEqual(approved.status, "available")
        XCTAssertEqual(approved.primary.project, "one")
        XCTAssertEqual(approved.reviewStatus, "current")
        XCTAssertEqual(approved.primary.evidenceRefs, ["30_projects/one/README.md"])

        let json = """
        {
          "schema_version": 1,
          "artifact_type": "weekly_focus_proposal",
          "proposal_id": "weekly-focus-2026-07-15",
          "as_of": "2026-07-15",
          "approval": { "status": "proposed", "approved": false, "receipt": null },
          "proposed": {
            "website_outcome": {
              "status": "proposed",
              "project": "one",
              "action": "Keep the fixture bounded",
              "evidence_refs": ["30_projects/one/README.md"]
            }
          },
          "intent_context": { "status": "not_used" },
          "warnings": []
        }
        """.data(using: .utf8)!
        let proposal = FocusBoard.parseFocusProposal(
            data: json,
            artifactPath: "20_live/focus/proposals/weekly-focus-2026-07-15.json"
        )
        XCTAssertEqual(proposal.status, "available")
        XCTAssertEqual(proposal.slots.first?.project, "one")
        XCTAssertFalse(proposal.approvalApproved)
        XCTAssertTrue(FocusBoard.isProposalFileName("weekly-focus-2026-07-15.json"))
        XCTAssertTrue(FocusBoard.isProposalFileName("weekly-focus-2026-07-15-initial.json"))
        XCTAssertFalse(FocusBoard.isProposalFileName("notes.json"))
    }

    func testEvidencePathSafety() {
        XCTAssertTrue(FocusBoard.isViewableEvidencePath("20_live/workstation/session-close-feed.jsonl"))
        XCTAssertTrue(FocusBoard.isViewableEvidencePath("30_projects/index.md"))
        XCTAssertFalse(FocusBoard.isViewableEvidencePath("bin/ingest-status"))
        XCTAssertFalse(FocusBoard.isViewableEvidencePath("/etc/passwd"))
        XCTAssertFalse(FocusBoard.isViewableEvidencePath("../secret"))
        let root = URL(fileURLWithPath: "/tmp/MainFrame")
        XCTAssertNotNil(
            FocusBoard.resolvedEvidenceURL(
                path: "30_projects/index.md",
                mainframeRoot: root
            )
        )
        XCTAssertNil(
            FocusBoard.resolvedEvidenceURL(
                path: "bin/ingest-status",
                mainframeRoot: root
            )
        )
    }

    // MARK: - Fixture inputs

    private func item(
        id: String,
        severity: FocusBoardSeverity,
        asOf: String? = nil
    ) -> FocusBoardItem {
        FocusBoardItem(
            id: id,
            severity: severity,
            title: id,
            detail: "",
            source: .sessionClose,
            evidencePath: "p",
            asOf: asOf
        )
    }

    private func allClearInputs() -> FocusBoardInputs {
        FocusBoardInputs(
            sessionCloseRecords: [
                FocusBoardJSON([
                    "fixture": .bool(true),
                    "kind": .string("close-check"),
                    "ok": .bool(true),
                    "as_of": .string("2026-07-12"),
                    "logged_at": .string("2026-07-12T12:00:00-04:00"),
                    "session_hash": .string("aaaaaaaaaaaaaaaa"),
                    "actions": .array([]),
                    "pending_auto": .array([]),
                    "warnings": .array([]),
                ]),
                FocusBoardJSON([
                    "fixture": .bool(true),
                    "kind": .string("checkpoint"),
                    "as_of": .string("2026-07-12"),
                    "logged_at": .string("2026-07-12T11:00:00-04:00"),
                    "session_hash": .string("bbbbbbbbbbbbbbbb"),
                    "drift": .bool(false),
                    "dirty_files": .number(0),
                    "weekly_eval": .object(FocusBoardJSON([
                        "ok": .bool(true),
                        "stale": .bool(false),
                    ])),
                ]),
            ],
            scheduleRuns: [
                FocusBoardJSON([
                    "fixture": .bool(true),
                    "run_id": .string("2026-07-12T100000-scheduled-weekly"),
                    "cadence": .string("weekly"),
                    "all_passed": .bool(true),
                    "finished_at": .string("2026-07-12T10:05:00+00:00"),
                    "started_at": .string("2026-07-12T10:00:00+00:00"),
                ]),
            ],
            projectIndex: FocusBoardProjectIndexSummary(
                activeCount: 5,
                activeCap: 10,
                asOf: "2026-07-12",
                fixture: true
            ),
            ingestStatus: FocusBoardJSON([
                "fixture": .bool(true),
                "as_of": .string("2026-07-12"),
                "lanes": .array([
                    .object(FocusBoardJSON([
                        "name": .string("00_inbox"),
                        "files": .number(0),
                        "oldest_file_age_days": .null,
                    ])),
                ]),
            ]),
            nowMs: nowMs,
            fixture: true
        )
    }

    private func staleWeeklyInputs() -> FocusBoardInputs {
        FocusBoardInputs(
            sessionCloseRecords: [
                FocusBoardJSON([
                    "fixture": .bool(true),
                    "kind": .string("close-check"),
                    "ok": .bool(false),
                    "as_of": .string("2026-07-12"),
                    "logged_at": .string("2026-07-12T12:00:00-04:00"),
                    "session_hash": .string("cccccccccccccccc"),
                    "actions": .array([
                        .object(FocusBoardJSON([
                            "kind": .string("warn"),
                            "name": .string("eval-schedule"),
                            "needed": .bool(true),
                            "ran": .bool(false),
                            "reason": .string("scheduled evals need attention"),
                        ])),
                    ]),
                    "pending_auto": .array([]),
                    "warnings": .array([.string("eval-schedule")]),
                    "reason": .string("other"),
                ]),
            ],
            scheduleRuns: [
                FocusBoardJSON([
                    "fixture": .bool(true),
                    "run_id": .string("2026-07-02T093908-scheduled-weekly"),
                    "cadence": .string("weekly"),
                    "all_passed": .bool(true),
                    "finished_at": .string("2026-07-02T13:39:34+00:00"),
                    "started_at": .string("2026-07-02T13:39:08+00:00"),
                ]),
            ],
            nowMs: nowMs,
            fixture: true
        )
    }

    private func wipBreachInputs() -> FocusBoardInputs {
        FocusBoardInputs(
            sessionCloseRecords: [],
            scheduleRuns: [
                FocusBoardJSON([
                    "fixture": .bool(true),
                    "run_id": .string("2026-07-12T100000-scheduled-weekly"),
                    "cadence": .string("weekly"),
                    "all_passed": .bool(true),
                    "finished_at": .string("2026-07-12T10:05:00+00:00"),
                ]),
            ],
            projectIndex: FocusBoardProjectIndexSummary(
                activeCount: 11,
                activeCap: 10,
                problems: [
                    FocusBoardProjectProblem(
                        code: "missing_frontmatter",
                        project: "repo-radar",
                        detail: "missing project_state frontmatter"
                    ),
                ],
                asOf: "2026-07-12",
                fixture: true
            ),
            nowMs: nowMs,
            fixture: true
        )
    }

    private func pendingAutoInputs() -> FocusBoardInputs {
        FocusBoardInputs(
            sessionCloseRecords: [
                FocusBoardJSON([
                    "fixture": .bool(true),
                    "kind": .string("close-check"),
                    "ok": .bool(false),
                    "as_of": .string("2026-07-12"),
                    "logged_at": .string("2026-07-12T21:55:15-04:00"),
                    "session_hash": .string("eed3c2a3d1cd13de"),
                    "actions": .array([
                        .object(FocusBoardJSON([
                            "kind": .string("manual"),
                            "name": .string("state-md-narrative"),
                            "needed": .bool(true),
                            "ran": .bool(false),
                            "reason": .string("update STATE.md narrative"),
                        ])),
                        .object(FocusBoardJSON([
                            "kind": .string("auto"),
                            "name": .string("sync-project-index"),
                            "needed": .bool(true),
                            "ran": .bool(false),
                            "reason": .string("project index is stale"),
                        ])),
                        .object(FocusBoardJSON([
                            "kind": .string("auto"),
                            "name": .string("workflow-report"),
                            "needed": .bool(true),
                            "ran": .bool(false),
                            "reason": .string("telemetry available"),
                        ])),
                        .object(FocusBoardJSON([
                            "kind": .string("warn"),
                            "name": .string("working-tree"),
                            "needed": .bool(true),
                            "ran": .bool(false),
                            "reason": .string("5 changed file(s) in working tree"),
                        ])),
                    ]),
                    "pending_auto": .array([
                        .string("sync-project-index"),
                        .string("workflow-report"),
                        .string("handoff-digest"),
                    ]),
                    "warnings": .array([.string("working-tree"), .string("eval-schedule")]),
                    "reason": .string("other"),
                ]),
            ],
            scheduleRuns: [
                FocusBoardJSON([
                    "fixture": .bool(true),
                    "run_id": .string("2026-07-02T093908-scheduled-weekly"),
                    "cadence": .string("weekly"),
                    "all_passed": .bool(true),
                    "finished_at": .string("2026-07-02T13:39:34+00:00"),
                ]),
            ],
            nowMs: nowMs,
            fixture: true
        )
    }
}

private extension Date {
    static func parseISO(_ raw: String) -> Double {
        FocusBoard.parseTimeMs(raw) ?? 0
    }
}
