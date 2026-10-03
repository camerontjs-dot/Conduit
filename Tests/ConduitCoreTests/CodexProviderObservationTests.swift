import XCTest
@testable import ConduitCore

final class CodexProviderObservationTests: XCTestCase {
    func testRequestsDisableRepairAndContentWithoutResume() {
        let id = CodexObservationRPC.identifier(hostGeneration: UUID(), request: UUID())
        let list = CodexObservationRPC.list(id: id, cursor: "opaque")
        XCTAssertEqual(list["method"], .string("thread/list"))
        XCTAssertEqual(list["id"], .string(id))
        XCTAssertEqual(list["params"]?["useStateDbOnly"], .bool(true))
        XCTAssertEqual(list["params"]?["archived"], .bool(false))
        XCTAssertEqual(list["params"]?["modelProviders"], .array([]))
        XCTAssertEqual(list["params"]?["cursor"], .string("opaque"))
        XCTAssertTrue((list["params"]?["sourceKinds"]?.jsonObject() as? [String])?.contains("appServer") == true)
        XCTAssertNil(list["params"]?["originators"])
        XCTAssertEqual(CodexObservationRPC.loadedList(id: id, cursor: nil)["method"], .string("thread/loaded/list"))
        let read = CodexObservationRPC.read(id: id, threadID: "full-provider-id")
        XCTAssertEqual(read["method"], .string("thread/read"))
        XCTAssertEqual(read["params"]?["includeTurns"], .bool(false))
        XCTAssertEqual(read["params"]?["threadId"], .string("full-provider-id"))
    }

    func testProjectionWithholdsContentAndKeepsAuthorityAxesUnknown() throws {
        let thread = try CodexThreadMetadata.parse(metadata())
        let worker = thread.worker(hostID: "host-one", loadedOnHost: false, binding: nil, observedAt: Date())
        XCTAssertEqual(worker.providerSessionID.value, "provider-session-full")
        XCTAssertFalse(worker.providerHostID.isKnown)
        XCTAssertFalse(worker.conduitTaskID.isKnown)
        XCTAssertFalse(worker.runtimeAttemptID.isKnown)
        XCTAssertFalse(worker.writerControllerID.isKnown)
        XCTAssertEqual(worker.origin, .unknown)
        XCTAssertEqual(worker.relationship, .discovered)
        XCTAssertTrue(worker.turns.isEmpty)
        XCTAssertEqual(worker.terminal.objectiveAcceptance, .unknown)
        XCTAssertEqual(worker.terminal.verification, .unknown)
        XCTAssertEqual(worker.terminal.receipt, .unknown)
        XCTAssertEqual(worker.observation.freshness, .unknown)
        let encoded = try JSONEncoder().encode(worker)
        let text = String(decoding: encoded, as: UTF8.self)
        for secret in ["private-preview", "private-title", "private-rollout", "private-nested-source"] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertTrue(text.contains("configured_or_persisted_model"))
        XCTAssertTrue(text.contains("observation_host_id"))
        XCTAssertTrue(text.contains("host-one"))
        XCTAssertTrue(text.contains("per-turn model and entitlement UNKNOWN"))
    }

    func testExactTaskBindingIsNotWriterOrCreationAuthority() throws {
        let thread = try CodexThreadMetadata.parse(metadata())
        let binding = ProviderObservationBinding(conduitTaskID: "task-axis", runtimeAttemptID: "attempt-axis")
        let worker = thread.worker(hostID: "host-axis", loadedOnHost: true, binding: binding, observedAt: Date())
        XCTAssertEqual(worker.conduitTaskID.value, "task-axis")
        XCTAssertEqual(worker.runtimeAttemptID.value, "attempt-axis")
        XCTAssertEqual(worker.providerSessionID.value, "provider-session-full")
        XCTAssertEqual(worker.providerHostID.value, "host-axis")
        XCTAssertEqual(worker.relationship, .discovered)
        XCTAssertFalse(worker.writerControllerID.isKnown)
        XCTAssertEqual(worker.origin, .unknown)
    }

    func testReadRejectsWrongIdentityAndShortenedSelection() {
        let reply: CodexJSON = .object(["thread": metadata()])
        for selected in ["provider-session", "task-axis", "provider-session-full ", ""] {
            XCTAssertThrowsError(try CodexThreadMetadata.parseRead(reply, exactID: selected))
        }
    }

    func testOpaqueIdentityIsPreservedWithoutUUIDCoercion() throws {
        let full = "vendor-session_opaque.case-sensitive"
        XCTAssertEqual(try CodexThreadMetadata.parse(metadata(changes: ["id": .string(full)])).id, full)
        for invalid in ["", "a\nb", "a b", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try CodexThreadMetadata.parse(metadata(changes: ["id": .string(invalid)])))
        }
    }

    func testMalformedMetadataAndUnexpectedTurnsAreRefusedWithoutPayloadEcho() {
        let changes: [[String: CodexJSON]] = [
            ["turns": .array([.object(["secret": .string("must-not-echo")])])],
            ["createdAt": .number(1.5)], ["createdAt": .number(.infinity)],
            ["updatedAt": .number(0)], ["ephemeral": .number(1)],
            ["cwd": .string("relative")], ["status": .object(["type": .string("new-status")])],
            ["status": .object(["type": .string("active")])],
            ["model": .array([])], ["source": .object(["subAgent": .number(1)])],
        ]
        for change in changes {
            XCTAssertThrowsError(try CodexThreadMetadata.parse(metadata(changes: change))) { error in
                XCTAssertEqual(error as? CodexObservationError, .invalidMetadata)
                XCTAssertFalse(error.localizedDescription.contains("must-not-echo"))
            }
        }
    }

    func testConfiguredModelMayBeUnavailableAndActiveStatusRemainsHostScoped() throws {
        let thread = try CodexThreadMetadata.parse(metadata(changes: [
            "model": .null,
            "status": .object(["type": .string("active"), "activeFlags": .array([.string("waitingOnApproval")])]),
        ]))
        XCTAssertNil(thread.configuredOrPersistedModel)
        let worker = thread.worker(hostID: "host", loadedOnHost: true, binding: nil, observedAt: Date())
        XCTAssertTrue(worker.turns.isEmpty)
        XCTAssertNil(worker.runtimeReconciliation)
        XCTAssertFalse(worker.process.launcherPID.isKnown)
        XCTAssertEqual(worker.terminal.objectiveAcceptance, .unknown)
    }

    func testCompletePagesPreserveOrderAndOpaqueCursor() throws {
        var pages = CodexMetadataPages<String>()
        XCTAssertEqual(try pages.append(page(["one"], cursor: "next"), parse: parseID), "next")
        XCTAssertNil(try pages.append(page(["two"]), parse: parseID))
        XCTAssertEqual(pages.elements, ["one", "two"])
        XCTAssertThrowsError(try pages.append(page(["three"]), parse: parseID))
    }

    func testDuplicatesAcrossPagesFailWithoutChangingAcceptedPage() throws {
        var pages = CodexMetadataPages<String>()
        _ = try pages.append(page(["one"], cursor: "next"), parse: parseID)
        XCTAssertThrowsError(try pages.append(page(["two", "one"]), parse: parseID))
        XCTAssertEqual(pages.elements, ["one"])
    }

    func testDuplicateWithinPageRepeatedCursorAndOversizedPageAreRefused() throws {
        var duplicate = CodexMetadataPages<String>()
        XCTAssertThrowsError(try duplicate.append(page(["one", "one"]), parse: parseID))
        XCTAssertTrue(duplicate.elements.isEmpty)
        var cycle = CodexMetadataPages<String>()
        _ = try cycle.append(page(["one"], cursor: "cycle"), parse: parseID)
        XCTAssertThrowsError(try cycle.append(page(["two"], cursor: "cycle"), parse: parseID))
        XCTAssertEqual(cycle.elements, ["one"])
        var oversized = CodexMetadataPages<String>()
        XCTAssertThrowsError(try oversized.append(page((0...64).map(String.init)), parse: parseID))
        XCTAssertTrue(oversized.elements.isEmpty)
    }

    func testPageBoundRefusesPartialInventory() throws {
        var pages = CodexMetadataPages<String>()
        for index in 0..<3 {
            _ = try pages.append(page(["id-\(index)"], cursor: "cursor-\(index)"), parse: parseID)
        }
        XCTAssertThrowsError(try pages.append(page(["fourth"], cursor: "fifth"), parse: parseID))
        XCTAssertEqual(pages.elements.count, 3)
        XCTAssertNil(try pages.append(page(["fourth"]), parse: parseID))
        XCTAssertEqual(pages.elements.count, 4)
    }

    func testMetadataReplyNamespaceNeverEmitsDrivingEffectsIncludingReplayAndErrors() {
        let marker = expectation(description: "ordered trailing marker")
        let recorder = ObservationDeliveryRecorder(marker: marker)
        let pump = CodexAppServerStreamPump(
            configuration: .init(deliveryCoalescingInterval: 0),
            deliveryQueue: DispatchQueue(label: "test.codex.metadata.namespace"),
            onDelivery: { recorder.record($0) }, onFailure: { recorder.record(failure: $0) }
        )
        let id = "conduit.observation.v1/expired/request"
        let lines = [
            #"{"id":"\#(id)","result":{"thread":{"id":"external"}}}"#,
            #"{"id":"\#(id)","error":{"message":"private-provider-error"}}"#,
            #"{"id":"conduit.observation.v1/wrong-host/unknown","result":{"thread":{"id":"wrong"}}}"#,
            #"{"id":"\#(id)","method":"item/commandExecution/requestApproval","params":{"command":"private-command"}}"#,
            #"{"method":"turn/completed","params":{"turn":{"status":"marker"}}}"#,
        ]
        XCTAssertTrue(pump.ingest(Data((lines.joined(separator: "\n") + "\n").utf8)))
        wait(for: [marker], timeout: 2)
        XCTAssertNil(recorder.failure)
        XCTAssertEqual(recorder.values.filter { if case .effect = $0 { return true }; return false }, [.effect(.turnCompleted(status: "marker"))])
        XCTAssertEqual(recorder.values.count, 5)
        pump.cancel()
    }

    func testNamespaceDoesNotReclassifyDrivingRepliesOrProviderNotifications() {
        XCTAssertFalse(CodexObservationRPC.isObservationReply(.number(1)))
        XCTAssertFalse(CodexObservationRPC.isObservationReply(.string("provider-thread-id")))
        var mapper = CodexAppServerMapper()
        XCTAssertEqual(mapper.apply(.response(id: .number(1), result: .object(["thread": .object(["id": .string("driver")])]))), [.threadStarted(id: "driver")])
        XCTAssertEqual(mapper.apply(.notification(method: "turn/started", params: .object(["turnId": .string("turn")] ))), [.turnStarted(id: "turn")])
    }

    private func metadata(changes: [String: CodexJSON] = [:]) -> CodexJSON {
        .object([
            "id": .string("provider-session-full"), "sessionId": .string("session-family-distinct"),
            "cwd": .string("/qualification-owned"), "createdAt": .number(100), "updatedAt": .number(200),
            "cliVersion": .string("0.154.0"), "modelProvider": .string("fixture-provider"),
            "ephemeral": .bool(false), "model": .string("fixture-model"),
            "source": .object(["subAgent": .object(["other": .string("private-nested-source")])]),
            "status": .object(["type": .string("notLoaded")]), "turns": .array([]),
            "preview": .string("private-preview"), "name": .string("private-title"),
            "path": .string("/private-rollout"), "projectId": .null,
        ].merging(changes) { _, new in new })
    }

    private func page(_ ids: [String], cursor: String? = nil) -> CodexJSON {
        .object(["data": .array(ids.map(CodexJSON.string)), "nextCursor": cursor.map(CodexJSON.string) ?? .null])
    }

    private func parseID(_ json: CodexJSON) throws -> (String, String) {
        guard let value = json.stringValue else { throw CodexObservationError.invalidMetadata }
        return (value, value)
    }
}

private final class ObservationDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let marker: XCTestExpectation
    private var deliveries: [CodexAppServerDelivery] = []
    private var recordedFailure: CodexAppServerStreamError?
    init(marker: XCTestExpectation) { self.marker = marker }
    var values: [CodexAppServerDelivery] { lock.lock(); defer { lock.unlock() }; return deliveries }
    var failure: CodexAppServerStreamError? { lock.lock(); defer { lock.unlock() }; return recordedFailure }
    func record(_ values: [CodexAppServerDelivery]) {
        lock.lock(); deliveries.append(contentsOf: values); lock.unlock()
        if values.contains(.effect(.turnCompleted(status: "marker"))) { marker.fulfill() }
    }
    func record(failure: CodexAppServerStreamError) { lock.lock(); recordedFailure = failure; lock.unlock(); marker.fulfill() }
}
