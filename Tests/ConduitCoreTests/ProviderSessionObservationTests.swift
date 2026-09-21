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
                  "info": {
                    "id": "msg_user_1",
                    "sessionID": "ses_external",
                    "role": "user",
                    "time": {"created": 1796991000000}
                  },
                  "parts": []
                },
                {
                  "info": {
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
                  "parts": []
                },
                {
                  "info": {
                    "id": "msg_assistant_2",
                    "sessionID": "ses_external",
                    "role": "assistant",
                    "time": {"created": 1796992001000},
                    "providerID": "ollama",
                    "modelID": "qwen3.5:9b"
                  },
                  "parts": [
                    {
                      "id": "prt_tool",
                      "type": "tool",
                      "state": {
                        "status": "running",
                        "input": {}
                      }
                    }
                  ]
                }
              ]
            }
            """#
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
        XCTAssertEqual(worker.adapter.value, "opencode_cli_persistence")
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
              case .string("session_list")? = root["source"],
              case .object(let session)? = root["session"],
              case .number(1)? = root["message_count"],
              case .number(0)? = root["assistant_turn_count"],
              case .number(1797000000000)? = session["updated"]
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
