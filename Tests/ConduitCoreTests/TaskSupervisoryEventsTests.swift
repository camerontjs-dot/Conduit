import Foundation
import XCTest
@testable import ConduitCore

final class TaskSupervisoryEventsTests: XCTestCase {
    private let store = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    private let a = TaskSessionID(rawValue: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    private let b = TaskSessionID(rawValue: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
    private let c = TaskSessionID(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000000")!)
    private let attempt = RuntimeAttemptID(rawValue: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!)
    private let date = Date(timeIntervalSinceReferenceDate: 42)
    private let secret = "PRIVATE_CONTENT_CANARY_X7"

    private func eventID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "aaaaaaaa-aaaa-4aaa-8aaa-%012x", number))!
    }
    private func event(_ number: Int, _ task: TaskSessionID, _ kind: TaskSessionEventKind,
                       authority: TaskSessionEventAuthority = .conduitRecorded,
                       schema: Int = 1, at: Date? = nil) -> TaskSessionEvent {
        TaskSessionEvent(schemaVersion: schema, id: eventID(number), taskSessionID: task,
            occurredAt: at ?? date, recordedAt: at ?? date, authority: authority, kind: kind)
    }
    private func created(_ number: Int, _ task: TaskSessionID, text: String = "fixture") -> TaskSessionEvent {
        event(number, task, .created(TaskSessionMetadata(
            workspace: .root(RootWorkspaceScopeSnapshot(rootURL: URL(fileURLWithPath: "/private/fixture-source-path"), fallbackTitle: text)),
            agentName: text, defaultTitle: text)))
    }
    private func source(_ task: TaskSessionID, _ events: [TaskSessionEvent],
                        diagnostics: [TaskSessionEventLogDiagnostic] = []) -> TaskSupervisorySourceSnapshot {
        .init(taskSessionID: task, readResult: .init(events: events, diagnostics: diagnostics))
    }
    private func baseline() -> [TaskSupervisorySourceSnapshot] {
        [source(a, [created(1,a,text:secret), event(2,a,.operationalStateChanged(.runtimeOpened(attempt))),
                    event(3,a,.titleOverridden(secret),authority:.operatorAsserted), event(4,a,.conversationActivityRecorded)]),
         source(b, [created(5,b), event(6,b,.operationalStateChanged(.closed(.operatorClosed)),authority:.operatorAsserted)])]
    }
    private func query(_ sources: [TaskSupervisorySourceSnapshot]? = nil, cursor: String? = nil,
                       limit: Int? = nil, storeID: UUID? = nil) -> TaskSupervisoryPageResult {
        TaskSupervisoryHistory.page(snapshot: .init(storeID: storeID ?? store, sources: sources ?? baseline()), cursor:cursor, limit:limit)
    }
    private func page(_ result: TaskSupervisoryPageResult, file: StaticString = #filePath, line: UInt = #line) throws -> TaskSupervisoryPage {
        XCTAssertEqual(result.status,.ready,file:file,line:line)
        XCTAssertTrue(result.issues.isEmpty,file:file,line:line)
        return try XCTUnwrap(result.page,file:file,line:line)
    }
    private func refused(_ result: TaskSupervisoryPageResult, _ status: TaskSupervisoryPageStatus,
                         _ reason: TaskSupervisoryRejectionReason, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.status,status,file:file,line:line)
        XCTAssertNil(result.page,file:file,line:line)
        XCTAssertEqual(result.issues.first?.reason,reason,file:file,line:line)
    }
    private func mutateCursor(_ raw: String, _ body: (inout [String:Any]) -> Void) throws -> String {
        var text=String(raw.dropFirst(5)).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        text += String(repeating:"=",count:(4-text.count%4)%4)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(Data(base64Encoded:text))) as? [String:Any])
        body(&object)
        let data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
        return "gsv1:"+data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }

    func testEmptyStoreProducesAStableEmptyCursor() throws {
        let first=try page(query([]))
        let second=try page(query([],cursor:first.nextCursor))
        XCTAssertEqual(first,second)
        XCTAssertFalse(first.hasMore)
    }
    func testSourceInputOrderDoesNotChangeCanonicalPageBytes() throws {
        let original=query(limit:2)
        let reversed=query(Array(baseline().reversed()),limit:2)
        XCTAssertEqual(try TaskSupervisoryHistory.canonicalData(original),try TaskSupervisoryHistory.canonicalData(reversed))
    }
    func testRoundRobinPagesPreserveEachTaskSourceOrder() throws {
        let first=try page(query(limit:2))
        let second=try page(query(cursor:first.nextCursor,limit:2))
        let third=try page(query(cursor:second.nextCursor,limit:2))
        XCTAssertEqual(first.events.map(\.id.sourceEventID),[eventID(1),eventID(5)])
        XCTAssertEqual(second.events.map(\.id.sourceEventID),[eventID(2),eventID(6)])
        XCTAssertEqual(third.events.map(\.id.sourceEventID),[eventID(4)])
        XCTAssertFalse(third.hasMore)
    }
    func testEmptyContinuationDoesNotMintDifferentCursor() throws {
        let end=try page(query()).nextCursor
        let next=try page(query(cursor:end))
        XCTAssertTrue(next.events.isEmpty)
        XCTAssertEqual(end,next.nextCursor)
    }
    func testBackdatedAppendKeepsItsSourceOrdinal() throws {
        let original=baseline()
        let end=try page(query(original)).nextCursor
        let older=event(7,a,.conversationActivityRecorded,at:Date(timeIntervalSinceReferenceDate:-1000))
        let updated=[source(a,original[0].events+[older]),original[1]]
        let next=try page(query(updated,cursor:end))
        XCTAssertEqual(next.events.map(\.id.sourceEventID),[eventID(7)])
        XCTAssertEqual(next.events.first?.sourceOrdinal,4)
    }
    func testLexicallyEarlierLateTaskIsNotMissed() throws {
        let end=try page(query()).nextCursor
        let next=try page(query(baseline()+[source(c,[created(8,c)])],cursor:end))
        XCTAssertEqual(next.events.map(\.id.taskSessionID),[c])
    }
    func testSameUUIDInDifferentTasksHasDistinctCompoundIdentity() throws {
        let next=try page(query([source(a,[created(1,a)]),source(b,[created(1,b)])]))
        XCTAssertEqual(next.events.count,2)
        XCTAssertNotEqual(next.events[0].id,next.events[1].id)
        XCTAssertEqual(next.events[0].id.sourceEventID,next.events[1].id.sourceEventID)
    }
    func testExactDuplicateRetainsFirstOccurrenceAndConsumesTail() throws {
        let original=baseline()
        let duplicate=[source(a,original[0].events+[original[0].events[0]]),original[1]]
        let first=try page(query(duplicate))
        XCTAssertEqual(first.events.filter{$0.id.sourceEventID==eventID(1)}.count,1)
        XCTAssertTrue(try page(query(duplicate,cursor:first.nextCursor)).events.isEmpty)
    }
    func testConflictingDuplicateDoesNotProduceAnyCursor() {
        let original=baseline()
        refused(query([source(a,original[0].events+[created(1,a,text:"different")]),original[1]]),.reconciliationRequired,.conflictingEventID)
    }
    func testSecondCreationIsExplicitlyUnreconciled() {
        let original=baseline()
        refused(query([source(a,original[0].events+[created(9,a)]),original[1]]),.reconciliationRequired,.duplicateCreation)
    }
    func testConsumedPrefixMutationRequiresReconciliation() throws {
        let end=try page(query()).nextCursor
        let original=baseline()
        refused(query([source(a,[created(1,a,text:"changed")]+Array(original[0].events.dropFirst())),original[1]],cursor:end),.reconciliationRequired,.sourcePrefixChanged)
    }
    func testUnconsumedPreviouslyObservedSuffixAlsoBindsCursor() throws {
        let first=try page(query(limit:1)).nextCursor
        let original=baseline()
        refused(query([source(a,Array(original[0].events.dropLast())+[event(4,a,.conversationActivityRecorded,at:Date(timeIntervalSinceReferenceDate:99))]),original[1]],cursor:first),.reconciliationRequired,.sourcePrefixChanged)
    }
    func testSourceTruncationIsNotCleanAbsence() throws {
        let end=try page(query()).nextCursor
        let original=baseline()
        refused(query([source(a,Array(original[0].events.dropLast())),original[1]],cursor:end),.reconciliationRequired,.sourcePrefixChanged)
    }
    func testKnownSourceRemovalRequiresReconciliation() throws {
        let end=try page(query()).nextCursor
        refused(query([baseline()[0]],cursor:end),.reconciliationRequired,.sourceRemoved)
    }
    func testDuplicateTaskSourcesAreNotSilentlyMerged() {
        let original=baseline()
        refused(query(original+[original[0]]),.invalidInput,.duplicateTaskSource)
    }
    func testMissingCreationAndEmptySourceRemainUnprojectable() {
        refused(query([source(a,[event(2,a,.conversationActivityRecorded)])]),.invalidInput,.missingCreation)
        refused(query([source(a,[])]),.invalidInput,.missingCreation)
    }
    func testWrongTaskIdentityFailsBeforeProjection() {
        refused(query([source(a,[created(1,b)])]),.invalidInput,.mismatchedTaskSessionID)
    }
    func testInvalidSourceAuthorityFailsBeforeProjection() {
        refused(query([source(a,[event(1,a,.created(TaskSessionMetadata(workspace:.root(.init(rootURL:URL(fileURLWithPath:"/fixture"))),agentName:nil,defaultTitle:"fixture")),authority:.processObserved)])]),.invalidInput,.invalidAuthority)
    }
    func testFutureSourceSchemaFailsBeforeProjection() {
        let original=created(1,a)
        let future=TaskSessionEvent(schemaVersion:2,id:original.id,taskSessionID:a,occurredAt:date,recordedAt:date,authority:original.authority,kind:original.kind)
        refused(query([source(a,[future])]),.invalidInput,.unsupportedEventSchema)
    }
    func testNonfiniteEventDatesCannotBecomeIdentity() {
        let original=created(1,a)
        for value in [Double.nan,Double.infinity,-Double.infinity] {
            let malformed=TaskSessionEvent(id:original.id,taskSessionID:a,occurredAt:Date(timeIntervalSinceReferenceDate:value),recordedAt:date,authority:original.authority,kind:original.kind)
            refused(query([source(a,[malformed])]),.invalidInput,.nonfiniteDate)
        }
    }
    func testReadDiagnosticsNeverBecomeAUsablePageOrLeakDetails() throws {
        for kind in [TaskSessionEventLogDiagnosticKind.malformedLine,.unreadableLog,.unprojectableLog,.duplicateTaskSessionLog,.directoryReadFailed,.unsupportedSchemaVersion,.invalidAuthority,.mismatchedTaskSessionID,.invalidFilename] {
            let diagnostic=TaskSessionEventLogDiagnostic(kind:kind,fileURL:URL(fileURLWithPath:"/private/PRIVATE_PATH_CANARY"),detail:secret)
            let result=query([source(a,[created(1,a)],diagnostics:[diagnostic])])
            refused(result,.reconciliationRequired,.readDiagnostics)
            let text=String(decoding:try TaskSupervisoryHistory.canonicalData(result),as:UTF8.self)
            XCTAssertFalse(text.contains(secret))
            XCTAssertFalse(text.contains("PRIVATE_PATH_CANARY"))
        }
    }
    func testRepeatedReadDiagnosticsHaveConstantRefusalBytes() throws {
        var reference: Data?
        for count in [1, 8_193, 32_769] {
            let diagnostics = (0..<count).map { line in
                TaskSessionEventLogDiagnostic(kind: .malformedLine,
                    fileURL: URL(fileURLWithPath: "/private/PRIVATE_PATH_CANARY"),
                    lineNumber: line + 1, detail: secret)
            }
            let snapshot = source(a, [], diagnostics: diagnostics)
            XCTAssertEqual(snapshot.readDiagnosticKinds, [.malformedLine])
            let result = query([snapshot])
            refused(result, .reconciliationRequired, .readDiagnostics)
            XCTAssertEqual(result.issues.count, 1)
            XCTAssertEqual(result.issues.first?.readDiagnosticKinds, [.malformedLine])
            let bytes = try TaskSupervisoryHistory.canonicalData(result)
            XCTAssertLessThan(bytes.count, 512)
            if let reference { XCTAssertEqual(bytes, reference) } else { reference = bytes }
            XCTAssertEqual(try TaskSupervisoryHistory.decodeCanonicalData(bytes), result)
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(text.contains(secret))
            XCTAssertFalse(text.contains("PRIVATE_PATH_CANARY"))
        }
    }
    func testMixedReadDiagnosticsPreserveEveryKindOnceIndependentOfOrder() throws {
        let kinds: [TaskSessionEventLogDiagnosticKind] = [.malformedLine, .unsupportedSchemaVersion,
            .invalidAuthority, .mismatchedTaskSessionID, .invalidFilename, .duplicateTaskSessionLog,
            .unreadableLog, .unprojectableLog, .directoryReadFailed]
        let expected = kinds.sorted { $0.rawValue < $1.rawValue }
        let diagnostics = (0..<9_216).map { line in
            TaskSessionEventLogDiagnostic(kind: kinds[line % kinds.count],
                fileURL: URL(fileURLWithPath: "/private/PRIVATE_PATH_CANARY"),
                lineNumber: line + 1, detail: secret)
        }
        var reference: Data?
        for input in [Array(diagnostics.prefix(kinds.count)), diagnostics, Array(diagnostics.reversed())] {
            let snapshot = source(a, [], diagnostics: input)
            XCTAssertEqual(snapshot.readDiagnosticKinds, expected)
            let result = query([snapshot])
            refused(result, .reconciliationRequired, .readDiagnostics)
            XCTAssertEqual(result.issues.count, 1)
            XCTAssertEqual(result.issues.first?.readDiagnosticKinds, expected)
            let bytes = try TaskSupervisoryHistory.canonicalData(result)
            XCTAssertLessThan(bytes.count, 512)
            if let reference { XCTAssertEqual(bytes, reference) } else { reference = bytes }
            XCTAssertEqual(try TaskSupervisoryHistory.decodeCanonicalData(bytes), result)
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(text.contains(secret))
            XCTAssertFalse(text.contains("PRIVATE_PATH_CANARY"))
        }
    }
    func testNormalizedDiagnosticsStillRefuseAnOverBudgetEventSource() {
        let diagnostics = Array(repeating: TaskSessionEventLogDiagnostic(kind: .unreadableLog,
            fileURL: URL(fileURLWithPath: "/private/PRIVATE_PATH_CANARY"), detail: secret), count: 32_769)
        let snapshot = source(a, Array(repeating: created(1, a),
            count: TaskSupervisoryHistory.maximumEventsPerSource + 1), diagnostics: diagnostics)
        XCTAssertEqual(snapshot.readDiagnosticKinds, [.unreadableLog])
        refused(query([snapshot]), .reconciliationRequired, .readDiagnostics)
    }
    func testMalformedCursorDoesNotRestartFromBeginning() {
        for raw in ["","0","v1:2","gsv1:AA","gsv1:++++"," gsv1:AA","gsv1:AA="] {
            refused(query(cursor:raw),.invalidCursor,.malformedCursor)
        }
    }
    func testCursorCannotMoveToAnotherDeclaredStore() throws {
        let cursor=try page(query()).nextCursor
        refused(query(cursor:cursor,storeID:UUID()),.invalidCursor,.cursorStore)
    }
    func testCursorVersionAndPolicyAreExact() throws {
        let cursor=try page(query()).nextCursor
        refused(query(cursor:try mutateCursor(cursor){$0["schemaVersion"]=2}),.invalidCursor,.cursorVersion)
        refused(query(cursor:try mutateCursor(cursor){$0["policyVersion"]="future"}),.invalidCursor,.cursorVersion)
    }
    func testUnknownCursorFieldIsNotTrustedOrIgnored() throws {
        let cursor=try page(query()).nextCursor
        refused(query(cursor:try mutateCursor(cursor){$0["extra"]=secret}),.invalidCursor,.malformedCursor)
    }
    func testDuplicateCursorSourceCannotCreateTwoPositions() throws {
        let cursor=try page(query()).nextCursor
        let changed=try mutateCursor(cursor) { object in
            var sources=object["sources"] as! [[String:Any]]
            sources.append(sources[0]); object["sources"]=sources
        }
        refused(query(cursor:changed),.invalidCursor,.duplicateCursorSource)
    }
    func testNegativeAndAheadCursorPositionsAreRefused() throws {
        let cursor=try page(query()).nextCursor
        for count in [-1,9999] {
            let changed=try mutateCursor(cursor) { object in
                var sources=object["sources"] as! [[String:Any]]
                sources[0]["consumedCount"]=count; object["sources"]=sources
            }
            refused(query(cursor:changed),.invalidCursor,.cursorPosition)
        }
    }
    func testCursorSuppliedDigestIsRecomputedAgainstSource() throws {
        let cursor=try page(query()).nextCursor
        let changed=try mutateCursor(cursor) { object in
            var sources=object["sources"] as! [[String:Any]]
            sources[0]["observedPrefixDigest"]=String(repeating:"0",count:64); object["sources"]=sources
        }
        refused(query(cursor:changed),.reconciliationRequired,.sourcePrefixChanged)
    }
    func testUnknownCursorAnchorIsRefused() throws {
        let cursor=try page(query()).nextCursor
        refused(query(cursor:try mutateCursor(cursor){$0["lastEmittedTask"]=c.rawValue.uuidString}),.invalidCursor,.cursorAnchor)
    }
    func testCursorByteBoundIsExplicit() {
        refused(query(cursor:String(repeating:"x",count:65_537)),.limitExceeded,.cursorBytes)
    }
    func testSourceCountBoundIsExplicit() {
        let sources=(0..<129).map { number -> TaskSupervisorySourceSnapshot in
            let task=TaskSessionID(rawValue:UUID(uuidString:String(format:"00000000-0000-4000-8000-%012x",number))!)
            return source(task,[created(1,task)])
        }
        refused(query(sources),.limitExceeded,.sourceCount)
    }
    func testPerSourceEventBoundIsExplicit() {
        let events=[created(1,a)]+(0..<4096).map{event($0+2,a,.conversationActivityRecorded)}
        refused(query([source(a,events)]),.limitExceeded,.sourceEventCount)
    }
    func testTotalEventBoundIsExplicit() {
        let sources=[a,b,c].map { task in source(task,[created(1,task)]+(0..<2730).map{event($0+2,task,.conversationActivityRecorded)}) }
        refused(query(sources),.limitExceeded,.totalEventCount)
    }
    func testSourceRecordAndAggregateByteBoundsAreExplicit() {
        refused(query([source(a,[created(1,a),event(2,a,.titleOverridden(String(repeating:"x",count:65_536)),authority:.operatorAsserted)])]),.limitExceeded,.sourceRecordBytes)
        let titles=(0..<145).map{event($0+2,a,.titleOverridden(String(repeating:"x",count:60_000)),authority:.operatorAsserted)}
        refused(query([source(a,[created(1,a)]+titles)]),.limitExceeded,.totalSourceBytes)
    }
    func testPageLimitClampsAndInvalidLimitUsesDefault() throws {
        let many=[source(a,[created(1,a)]+(0..<70).map{event($0+2,a,.conversationActivityRecorded)})]
        XCTAssertEqual(try page(query(many,limit:1000)).events.count,50)
        XCTAssertEqual(try page(query(many,limit:0)).events.count,20)
        XCTAssertEqual(try page(query(many,limit:-1)).events.count,20)
    }
    func testFractionalDateMutationIsNotRoundedOutOfPrefixIdentity() throws {
        let events=[created(1,a),event(2,a,.conversationActivityRecorded,at:Date(timeIntervalSinceReferenceDate:0.000001))]
        let cursor=try page(query([source(a,events)],limit:1)).nextCursor
        refused(query([source(a,[events[0],event(2,a,.conversationActivityRecorded,at:Date(timeIntervalSinceReferenceDate:0.000002))])],cursor:cursor),.reconciliationRequired,.sourcePrefixChanged)
    }
    func testRuntimeOpenedAndShellExitDoNotBecomeProviderCompletion() throws {
        let telemetry=ShellTelemetryEvent(shellExecutionID:UUID().uuidString,runtimeAttemptID:attempt.rawValue.uuidString,phase:.shellExited,shellPID:42,
            observation:.init(authority:.shellHookObserved,freshness:.current,observedAt:.known(date)))
        let result=try page(query([source(a,[created(1,a),event(2,a,.operationalStateChanged(.runtimeOpened(attempt))),event(3,a,.shellTelemetryRecorded(telemetry),authority:.shellHookObserved)])]))
        XCTAssertEqual(result.events[1].kind,.runtimeOpened)
        XCTAssertEqual(result.events[2].kind,.shellTelemetryRecorded(.shellExited))
        for fact in [TaskSupervisoryUnsupportedFact.sourceAuthenticity,.providerProgress,.verification,.acceptance,.currentNativeState] {
            XCTAssertTrue(result.unsupportedFacts.contains(fact))
        }
    }
    func testPrivateMetadataAndFailureStringsNeverEnterExportOrCursor() throws {
        let result=query([source(a,[created(1,a,text:secret),event(2,a,.operationalStateChanged(.runtimeProvisioningFailed(attempt,tmuxSessionName:secret,reason:secret,recoverable:true)))])])
        let text=String(decoding:try TaskSupervisoryHistory.canonicalData(result),as:UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("/private/fixture-source-path"))
        XCTAssertEqual(try page(result).events[1].kind,.runtimeProvisioningFailed(recoverable:true))
    }
    func testCanonicalResultRoundtripRetainsExactNativeBytes() throws {
        let bytes=try TaskSupervisoryHistory.canonicalData(query())
        XCTAssertEqual(bytes,try TaskSupervisoryHistory.canonicalData(TaskSupervisoryHistory.decodeCanonicalData(bytes)))
    }
    func testCanonicalResultRejectsUnknownFields() throws {
        let bytes=try TaskSupervisoryHistory.canonicalData(query())
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        object["extra"]=secret
        let changed=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
        XCTAssertThrowsError(try TaskSupervisoryHistory.decodeCanonicalData(changed))
    }
    func testPhysicalLogsAndPersistedCursorCanBeReadByANewReader() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let log=TaskSessionEventLog(directory:directory,taskSessionID:a)
        try log.append(created(1,a))
        let first=try page(query([.init(taskSessionID:a,readResult:log.read())]))
        let cursorURL=directory.appendingPathComponent("cursor.txt")
        try Data(first.nextCursor.utf8).write(to:cursorURL)
        try log.append(event(2,a,.conversationActivityRecorded))
        let fresh=TaskSessionEventLog(directory:directory,taskSessionID:a)
        let before=try Data(contentsOf:fresh.url)
        let persistedCursor=String(decoding:try Data(contentsOf:cursorURL),as:UTF8.self)
        let next=try page(query([.init(taskSessionID:a,readResult:fresh.read())],cursor:persistedCursor))
        XCTAssertEqual(next.events.map(\.id.sourceEventID),[eventID(2)])
        XCTAssertEqual(before,try Data(contentsOf:fresh.url))
    }
    func testPhysicalTornLineDiagnosticsCannotAdvanceCursor() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let log=TaskSessionEventLog(directory:directory,taskSessionID:a)
        try log.append(created(1,a))
        let cursor=try page(query([.init(taskSessionID:a,readResult:log.read())])).nextCursor
        let handle=try FileHandle(forWritingTo:log.url)
        try handle.seekToEnd(); try handle.write(contentsOf:Data("{\"schemaVersion\":1,".utf8)); try handle.close()
        let before=try Data(contentsOf:log.url)
        refused(query([.init(taskSessionID:a,readResult:log.read())],cursor:cursor),.reconciliationRequired,.readDiagnostics)
        XCTAssertEqual(before,try Data(contentsOf:log.url))
    }
}
