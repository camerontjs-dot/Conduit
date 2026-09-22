import Foundation
import XCTest
@testable import ConduitCore

final class ProviderSessionObservationTests: XCTestCase {
    private final class FakeTransport: OpenCodeProviderObservationTransport {
        var listDocument: CodexJSON
        var exports: [String: CodexJSON]
        private(set) var listCalls = 0
        private(set) var exportCalls: [String] = []

        init(
            listDocument: CodexJSON = .array([]),
            exports: [String: CodexJSON] = [:]
        ) {
            self.listDocument = listDocument
            self.exports = exports
        }

        func listSessionsJSON() throws -> CodexJSON {
            listCalls += 1
            return listDocument
        }

        func readSessionJSON(providerSessionID: String) throws -> CodexJSON {
            exportCalls.append(providerSessionID)
            guard let value = exports[providerSessionID] else {
                throw ProviderSessionObservationError.malformedProviderResponse(
                    "missing fixture"
                )
            }
            return value
        }
    }

    private func makeSQLiteFixture(
        sql: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (directory: URL, database: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conduit-opencode-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let database = directory.appendingPathComponent("opencode.db")
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let errorText = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "sqlite fixture creation failed: \(errorText)",
            file: file,
            line: line
        )
        return (directory, database)
    }

    private func removeSQLiteFixture(_ fixture: (directory: URL, database: URL)) {
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_797_000_000)

    private func json(_ string: String) -> CodexJSON {
        let parsed = CodexJSON.parse(Data(string.utf8))
        XCTAssertNotNil(parsed)
        return parsed ?? .null
    }

    private func externalInventory() -> CodexJSON {
        json(
            #"""
            [
              {
                "id": "ses_external",
                "title": "external session",
                "updated": 1797000000000,
                "created": 1796990000000,
                "projectId": "project-external",
                "directory": "/tmp/external-worktree"
              }
            ]
            """#
        )
    }

    private func exportedSession() -> CodexJSON {
        // Mirrors the SQLite observation transport: session metadata is under
        // "info", while message rows are flat projections of persisted message
        // info rather than provider-export wrappers.
        json(
            #"""
            {
              "info": {
                "id": "ses_external",
                "title": "external session",
                "projectID": "project-external",
                "directory": "/tmp/external-worktree",
                "time": {
                  "created": 1796990000000,
                  "updated": 1797000000000
                }
              },
              "messages": [
                {
                  "id": "msg_user_1",
                  "sessionID": "ses_external",
                  "role": "user",
                  "time": {"created": 1796991000000}
                },
                {
                  "id": "msg_assistant_1",
                  "sessionID": "ses_external",
                  "role": "assistant",
                  "time": {
                    "created": 1796991001000,
                    "completed": 1796991009000
                  },
                  "providerID": "xai",
                  "modelID": "grok-4.20-0309-non-reasoning"
                },
                {
                  "id": "msg_assistant_2",
                  "sessionID": "ses_external",
                  "role": "assistant",
                  "time": {
                    "created": 1796992001000,
                    "completed": null
                  },
                  "providerID": "ollama",
                  "modelID": "qwen3.5:9b"
                }
              ]
            }
            """#
        )
    }


    func testSQLiteTransportProjectsRealFlatPersistenceRows() throws {
        let fixture = try makeSQLiteFixture(
            sql: #"""
            PRAGMA journal_mode=DELETE;
            CREATE TABLE session (
              id TEXT PRIMARY KEY,
              project_id TEXT NOT NULL,
              parent_id TEXT,
              directory TEXT NOT NULL,
              title TEXT NOT NULL,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL
            );
            CREATE TABLE message (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL,
              data TEXT NOT NULL
            );
            CREATE TABLE part (
              id TEXT PRIMARY KEY,
              message_id TEXT NOT NULL,
              session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL,
              data TEXT NOT NULL
            );
            INSERT INTO session VALUES (
              'ses_fixture',
              'project-fixture',
              NULL,
              '/tmp/fixture',
              'fixture session',
              100,
              200
            );
            INSERT INTO message VALUES (
              'msg_user',
              'ses_fixture',
              110,
              110,
              json_object(
                'role','user',
                'time',json_object('created',110)
              )
            );
            INSERT INTO message VALUES (
              'msg_completed',
              'ses_fixture',
              120,
              130,
              json_object(
                'role','assistant',
                'providerID','xai',
                'modelID','grok-fixture',
                'time',json_object('created',120,'completed',130)
              )
            );
            INSERT INTO message VALUES (
              'msg_incomplete',
              'ses_fixture',
              140,
              140,
              json_object(
                'role','assistant',
                'providerID','ollama',
                'modelID','qwen-fixture',
                'time',json_object('created',140,'completed',NULL)
              )
            );
            INSERT INTO part VALUES (
              'prt_running_tool',
              'msg_incomplete',
              'ses_fixture',
              145,
              150,
              json_object(
                'type','tool',
                'tool','bash',
                'callID','call_fixture',
                'state',json_object(
                  'status','running',
                  'input',json_object('command','qualification-only-secret-command')
                )
              )
            );
            """#
        )
        defer { removeSQLiteFixture(fixture) }

        let transport = OpenCodeSQLiteObservationTransport(
            environment: ["OPENCODE_DB": fixture.database.path],
            homeDirectory: fixture.directory,
            timeout: 3
        )
        let observer = OpenCodeProviderSessionObserver(
            transport: transport,
            now: { self.fixedDate }
        )

        let worker = try observer.observeSession(
            providerSessionID: "ses_fixture"
        )

        XCTAssertEqual(worker.turns.count, 2)
        XCTAssertEqual(worker.turns[0].turnID.value, "msg_completed")
        XCTAssertEqual(worker.turns[0].state, .completed)
        XCTAssertEqual(
            worker.turns[0].model.value,
            ProviderModelIdentity(
                providerID: "xai",
                modelID: "grok-fixture"
            )
        )
        XCTAssertEqual(worker.turns[1].turnID.value, "msg_incomplete")
        XCTAssertEqual(worker.turns[1].state, .ambiguous)
        XCTAssertEqual(
            worker.turns[1].model.value,
            ProviderModelIdentity(
                providerID: "ollama",
                modelID: "qwen-fixture"
            )
        )
        XCTAssertEqual(worker.adapter.value, "opencode_sqlite_snapshot")
        XCTAssertEqual(worker.runtimeReconciliation?.providerReportedState, .active)
        XCTAssertEqual(
            worker.runtimeReconciliation?.providerActivities.value?.count,
            1
        )
        let persistedTool = try XCTUnwrap(
            worker.runtimeReconciliation?.providerActivities.value?.first
        )
        XCTAssertEqual(persistedTool.partID.value, "prt_running_tool")
        XCTAssertEqual(persistedTool.messageID.value, "msg_incomplete")
        XCTAssertEqual(persistedTool.callID.value, "call_fixture")
        XCTAssertEqual(persistedTool.toolName.value, "bash")
        XCTAssertEqual(persistedTool.reportedStatus.value, "running")
        XCTAssertEqual(
            try XCTUnwrap(persistedTool.createdAt.value).timeIntervalSince1970,
            0.145,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(persistedTool.updatedAt.value).timeIntervalSince1970,
            0.150,
            accuracy: 0.000_001
        )
        let serializedWorker = try String(
            decoding: JSONEncoder().encode(worker),
            as: UTF8.self
        )
        XCTAssertFalse(serializedWorker.contains("qualification-only-secret-command"))
    }

    func testSQLiteWithoutPartTableKeepsToolActivityUnknown() throws {
        let fixture = try makeSQLiteFixture(
            sql: #"""
            PRAGMA journal_mode=DELETE;
            CREATE TABLE session (
              id TEXT PRIMARY KEY,
              project_id TEXT NOT NULL,
              parent_id TEXT,
              directory TEXT NOT NULL,
              title TEXT NOT NULL,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL
            );
            CREATE TABLE message (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL,
              data TEXT NOT NULL
            );
            INSERT INTO session VALUES (
              'ses_legacy_fixture', 'project-fixture', NULL, '/tmp/fixture',
              'legacy fixture', 100, 200
            );
            INSERT INTO message VALUES (
              'msg_incomplete', 'ses_legacy_fixture', 140, 140,
              json_object(
                'role','assistant',
                'time',json_object('created',140,'completed',NULL)
              )
            );
            """#
        )
        defer { removeSQLiteFixture(fixture) }

        let observer = OpenCodeProviderSessionObserver(
            transport: OpenCodeSQLiteObservationTransport(
                environment: ["OPENCODE_DB": fixture.database.path],
                homeDirectory: fixture.directory,
                timeout: 3
            ),
            now: { self.fixedDate }
        )

        let worker = try observer.observeSession(
            providerSessionID: "ses_legacy_fixture"
        )

        XCTAssertEqual(worker.turns.first?.state, .ambiguous)
        XCTAssertEqual(worker.runtimeReconciliation?.providerActivities.state, .unknown)
        XCTAssertEqual(worker.runtimeReconciliation?.providerReportedState, .unknown)
        XCTAssertTrue(
            worker.runtimeReconciliation?.diagnostics.contains {
                $0.contains("tool-part status is unavailable")
            } == true
        )
        XCTAssertEqual(
            worker.runtimeReconciliation?.disposition,
            .insufficientObservation
        )
    }

    func testSQLiteTransportLargeInventoryDoesNotDependOnPipeCapacity() throws {
        let fixture = try makeSQLiteFixture(
            sql: #"""
            PRAGMA journal_mode=DELETE;
            CREATE TABLE session (
              id TEXT PRIMARY KEY,
              project_id TEXT NOT NULL,
              parent_id TEXT,
              directory TEXT NOT NULL,
              title TEXT NOT NULL,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL
            );
            WITH RECURSIVE rows(value) AS (
              SELECT 1
              UNION ALL
              SELECT value + 1 FROM rows WHERE value < 1500
            )
            INSERT INTO session (
              id,
              project_id,
              parent_id,
              directory,
              title,
              time_created,
              time_updated
            )
            SELECT
              printf('ses_%04d', value),
              'project-large',
              NULL,
              '/tmp/large',
              replace(hex(zeroblob(120)), '00', 'x'),
              value,
              value
            FROM rows;
            """#
        )
        defer { removeSQLiteFixture(fixture) }

        let transport = OpenCodeSQLiteObservationTransport(
            environment: ["OPENCODE_DB": fixture.database.path],
            homeDirectory: fixture.directory,
            timeout: 3
        )

        guard case .array(let rows) = try transport.listSessionsJSON() else {
            return XCTFail("large inventory was not returned as an array")
        }
        XCTAssertEqual(rows.count, 1500)
    }

    func testInstalledOpenCodePersistenceWhenExplicitlyRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CONDUIT_OPENCODE_QUALIFICATION"] == "1" else {
            throw XCTSkip(
                "Set CONDUIT_OPENCODE_QUALIFICATION=1 with DB/session variables for installed qualification."
            )
        }
        guard let databasePath = environment["CONDUIT_OPENCODE_QUALIFICATION_DB"],
              !databasePath.isEmpty,
              let sessionID = environment["CONDUIT_OPENCODE_QUALIFICATION_SESSION_ID"],
              !sessionID.isEmpty
        else {
            return XCTFail(
                "Installed qualification requires CONDUIT_OPENCODE_QUALIFICATION_DB and CONDUIT_OPENCODE_QUALIFICATION_SESSION_ID."
            )
        }

        let database = URL(fileURLWithPath: databasePath)
        let transport = OpenCodeSQLiteObservationTransport(
            environment: ["OPENCODE_DB": database.path],
            homeDirectory: database.deletingLastPathComponent(),
            timeout: 30
        )
        let observer = OpenCodeProviderSessionObserver(transport: transport)

        let worker = try observer.observeSession(providerSessionID: sessionID)
        XCTAssertEqual(worker.providerSessionID.value, sessionID)
        XCTAssertEqual(worker.adapter.value, "opencode_sqlite_snapshot")
        XCTAssertEqual(worker.relationship, .discovered)
        XCTAssertEqual(worker.observation.authority, .providerObserved)
        XCTAssertEqual(worker.observation.freshness, .unknown)
        XCTAssertEqual(worker.writerControllerID.state, .unknown)
        XCTAssertEqual(worker.terminal.objectiveAcceptance, .unknown)

        if let expectedRaw = environment[
            "CONDUIT_OPENCODE_EXPECTED_ASSISTANT_TURNS"
        ],
           let expected = Int(expectedRaw) {
            XCTAssertEqual(worker.turns.count, expected)
        } else {
            XCTAssertFalse(
                worker.turns.isEmpty,
                "selected installed session must expose at least one persisted assistant turn"
            )
        }

        if let expectedProvider = environment[
            "CONDUIT_OPENCODE_EXPECTED_PROVIDER_ID"
        ],
           let expectedModel = environment[
            "CONDUIT_OPENCODE_EXPECTED_MODEL_ID"
        ] {
            let knownModels = worker.turns.compactMap(\.model.value)
            XCTAssertFalse(knownModels.isEmpty)
            XCTAssertTrue(
                knownModels.allSatisfy {
                    $0.providerID == expectedProvider
                        && $0.modelID == expectedModel
                }
            )
        }

        let inventory = try observer.listSessions()
        XCTAssertTrue(
            inventory.contains {
                $0.providerSessionID.value == sessionID
            },
            "installed provider inventory did not contain the selected exact session"
        )

        print(
            "INSTALLED_OPENCODE_OBSERVATION "
                + "session=\(sessionID) "
                + "turns=\(worker.turns.count) "
                + "inventory=\(inventory.count)"
        )
    }


    func testDiscoversExternalSessionWithoutConduitBinding() throws {
        let transport = FakeTransport(listDocument: externalInventory())
        let observer = OpenCodeProviderSessionObserver(
            transport: transport,
            now: { self.fixedDate }
        )

        let workers = try observer.listSessions()
        XCTAssertEqual(workers.count, 1)

        let worker = try XCTUnwrap(workers.first)
        XCTAssertEqual(worker.providerSessionID.value, "ses_external")
        XCTAssertEqual(worker.conduitTaskID.state, .unknown)
        XCTAssertEqual(worker.runtimeAttemptID.state, .unknown)
        XCTAssertEqual(worker.writerControllerID.state, .unknown)
        XCTAssertEqual(worker.relationship, .discovered)
        XCTAssertEqual(worker.origin, .unknown)
        XCTAssertEqual(transport.listCalls, 1)
        XCTAssertTrue(transport.exportCalls.isEmpty)
    }

    func testDiscoveryPreservesProviderIdentityAndDoesNotInventProcessFacts() throws {
        let observer = OpenCodeProviderSessionObserver(
            transport: FakeTransport(listDocument: externalInventory()),
            now: { self.fixedDate }
        )

        let worker = try XCTUnwrap(try observer.listSessions().first)
        XCTAssertEqual(worker.providerSessionID.value, "ses_external")
        XCTAssertEqual(worker.runtime.value, "opencode")
        XCTAssertEqual(worker.adapter.value, "opencode_sqlite_snapshot")
        XCTAssertEqual(worker.providerHostID.state, .unknown)
        XCTAssertEqual(worker.process.launcherPID.state, .unknown)
        XCTAssertEqual(worker.process.processGroupID.state, .unknown)
        XCTAssertEqual(worker.process.parentPID.state, .unknown)
        XCTAssertEqual(worker.workspace.cwd.value, "/tmp/external-worktree")
        XCTAssertEqual(worker.workspace.repositoryRoot.state, .unknown)
        XCTAssertEqual(worker.workspace.worktree.state, .unknown)
    }

    func testExactTaskBindingDoesNotGrantWriterAuthorityOrOwnership() throws {
        let transport = FakeTransport(listDocument: externalInventory())
        let observer = OpenCodeProviderSessionObserver(
            transport: transport,
            now: { self.fixedDate }
        )

        let worker = try XCTUnwrap(
            try observer.listSessions { sessionID in
                XCTAssertEqual(sessionID, "ses_external")
                return ProviderObservationBinding(
                    conduitTaskID: "task-123",
                    runtimeAttemptID: "attempt-456"
                )
            }.first
        )

        XCTAssertEqual(worker.conduitTaskID.value, "task-123")
        XCTAssertEqual(worker.runtimeAttemptID.value, "attempt-456")
        XCTAssertEqual(worker.relationship, .discovered)
        XCTAssertEqual(worker.writerControllerID.state, .unknown)
        XCTAssertEqual(worker.origin, .unknown)
    }

    func testObservePreservesTurnScopedProviderAndModelIdentity() throws {
        let transport = FakeTransport(
            exports: ["ses_external": exportedSession()]
        )
        let observer = OpenCodeProviderSessionObserver(
            transport: transport,
            now: { self.fixedDate }
        )

        let worker = try observer.observeSession(
            providerSessionID: "ses_external"
        )

        XCTAssertEqual(worker.turns.count, 2)
        XCTAssertEqual(worker.turns[0].turnID.value, "msg_assistant_1")
        XCTAssertEqual(
            worker.turns[0].model.value,
            ProviderModelIdentity(
                providerID: "xai",
                modelID: "grok-4.20-0309-non-reasoning"
            )
        )
        XCTAssertEqual(worker.turns[1].turnID.value, "msg_assistant_2")
        XCTAssertEqual(
            worker.turns[1].model.value,
            ProviderModelIdentity(
                providerID: "ollama",
                modelID: "qwen3.5:9b"
            )
        )
        XCTAssertEqual(transport.exportCalls, ["ses_external"])
    }

    func testPersistedIncompleteTurnIsAmbiguousNotActive() throws {
        let observer = OpenCodeProviderSessionObserver(
            transport: FakeTransport(
                exports: ["ses_external": exportedSession()]
            ),
            now: { self.fixedDate }
        )

        let worker = try observer.observeSession(
            providerSessionID: "ses_external"
        )

        XCTAssertEqual(worker.turns[0].state, .completed)
        XCTAssertEqual(worker.turns[1].state, .ambiguous)
        XCTAssertNotEqual(worker.turns[1].state, .active)
        XCTAssertEqual(worker.observation.authority, .providerObserved)
        XCTAssertEqual(worker.observation.freshness, .unknown)
        XCTAssertEqual(worker.observation.observedAt.value, fixedDate)
        XCTAssertEqual(worker.runtimeReconciliation?.providerActivities.state, .unknown)
        XCTAssertEqual(worker.runtimeReconciliation?.providerReportedState, .unknown)
        XCTAssertEqual(
            worker.runtimeReconciliation?.disposition,
            .insufficientObservation
        )
    }

    func testProviderCompletionDoesNotBecomeObjectiveAcceptance() throws {
        let observer = OpenCodeProviderSessionObserver(
            transport: FakeTransport(
                exports: ["ses_external": exportedSession()]
            ),
            now: { self.fixedDate }
        )

        let worker = try observer.observeSession(
            providerSessionID: "ses_external"
        )

        XCTAssertEqual(worker.turns[0].state, .completed)
        XCTAssertEqual(worker.terminal.receipt, .unknown)
        XCTAssertEqual(worker.terminal.verification, .unknown)
        XCTAssertEqual(worker.terminal.objectiveAcceptance, .unknown)
    }

    func testLaterCompletedTurnPreservesOlderRunningToolEvidence() throws {
        let document = json(
            #"""
            {
              "info": {
                "id": "ses_resume_fixture",
                "time": {"updated": 1797000003000}
              },
              "messages": [
                {
                  "id": "msg_interrupted",
                  "role": "assistant",
                  "time": {"created": 1797000000000, "completed": null}
                },
                {
                  "id": "msg_after_resume",
                  "role": "assistant",
                  "time": {"created": 1797000002000, "completed": 1797000003000}
                }
              ],
              "parts": [
                {
                  "id": "prt_stale_tool",
                  "messageID": "msg_interrupted",
                  "kind": "tool",
                  "tool": "bash",
                  "callID": "call_interrupted",
                  "status": "running",
                  "createdAt": 1797000000500,
                  "updatedAt": 1797000000600
                }
              ]
            }
            """#
        )
        let observer = OpenCodeProviderSessionObserver(
            transport: FakeTransport(
                exports: ["ses_resume_fixture": document]
            ),
            now: { self.fixedDate }
        )

        let worker = try observer.observeSession(
            providerSessionID: "ses_resume_fixture"
        )

        XCTAssertEqual(worker.turns.map(\.state), [.ambiguous, .completed])
        XCTAssertEqual(
            worker.runtimeReconciliation?.providerReportedState,
            .inactive
        )
        XCTAssertEqual(
            worker.runtimeReconciliation?.providerActivities.value?.first?.reportedStatus.value,
            "running"
        )
        XCTAssertTrue(
            worker.runtimeReconciliation?.diagnostics.contains {
                $0.contains("older persisted tool part still says running")
            } == true
        )
        XCTAssertEqual(worker.terminal.objectiveAcceptance, .unknown)
    }

    func testProviderSpecificMetadataStaysNamespacedAndTyped() throws {
        let observer = OpenCodeProviderSessionObserver(
            transport: FakeTransport(listDocument: externalInventory()),
            now: { self.fixedDate }
        )

        let worker = try XCTUnwrap(try observer.listSessions().first)
        let payload = try XCTUnwrap(worker.providerSpecific.value)
        XCTAssertEqual(payload.namespace, "opencode.persistence")
        XCTAssertEqual(payload.schemaVersion, 1)

        guard case .object(let root) = payload.value,
              case .string("persistence_inventory")? = root["source"],
              case .object(let session)? = root["session"],
              case .number(0)? = root["message_count"],
              case .number(0)? = root["assistant_turn_count"],
              case .string("project-external")? = session["projectId"],
              session["updated"] == nil
        else {
            return XCTFail("provider-specific metadata lost JSON type or namespace")
        }
    }

    func testRepeatedReadOnlyObservationIsStableAndUsesOnlyReadTransport() throws {
        let transport = FakeTransport(
            exports: ["ses_external": exportedSession()]
        )
        let observer = OpenCodeProviderSessionObserver(
            transport: transport,
            now: { self.fixedDate }
        )

        let first = try observer.observeSession(
            providerSessionID: "ses_external"
        )
        let second = try observer.observeSession(
            providerSessionID: "ses_external"
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            transport.exportCalls,
            ["ses_external", "ses_external"]
        )
        XCTAssertEqual(transport.listCalls, 0)
    }

    func testIdentityMismatchFailsClosed() throws {
        let wrong = json(
            #"""
            {
              "info": {
                "id": "ses_other",
                "directory": "/tmp/other"
              },
              "messages": []
            }
            """#
        )
        let observer = OpenCodeProviderSessionObserver(
            transport: FakeTransport(exports: ["ses_external": wrong]),
            now: { self.fixedDate }
        )

        XCTAssertThrowsError(
            try observer.observeSession(providerSessionID: "ses_external")
        ) { error in
            XCTAssertEqual(
                error as? ProviderSessionObservationError,
                .identityMismatch(
                    expected: "ses_external",
                    observed: "ses_other"
                )
            )
        }
    }

    func testInvalidSessionIDFailsBeforeProviderRead() throws {
        let transport = FakeTransport()
        let observer = OpenCodeProviderSessionObserver(
            transport: transport,
            now: { self.fixedDate }
        )

        XCTAssertThrowsError(
            try observer.observeSession(providerSessionID: "--delete")
        ) { error in
            XCTAssertEqual(
                error as? ProviderSessionObservationError,
                .invalidProviderSessionID("--delete")
            )
        }
        XCTAssertTrue(transport.exportCalls.isEmpty)
        XCTAssertEqual(transport.listCalls, 0)
    }
}
