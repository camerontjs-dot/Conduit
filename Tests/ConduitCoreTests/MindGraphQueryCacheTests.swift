import XCTest
@testable import ConduitCore

final class MindGraphQueryCacheTests: XCTestCase {
    private func key(_ question: String = "context", _ scope: MindGraphScope = .knowledge, _ topK: Int = 8) -> MindGraphQueryKey {
        MindGraphQueryKey(question: question, scope: scope, topK: topK)!
    }

    private func hit(_ scope: MindGraphScope, _ title: String = "source") -> MindGraphHit {
        MindGraphHit(docID: title, chunkIndex: 0, displayPath: "source.md", title: title,
                     chunkText: "nomination", trustProfile: scope.trustProfile, scope: scope)
    }

    func testRequestKeyTrimsOnlyTransportWhitespace() {
        XCTAssertEqual(key(" \ncontext\t"), key())
        XCTAssertNotEqual(key("Context"), key())
        XCTAssertNotEqual(key("two  words"), key("two words"))
        XCTAssertNil(MindGraphQueryKey(question: " \n", scope: .knowledge, topK: 8))
        XCTAssertNil(MindGraphQueryKey(question: "context", scope: .knowledge, topK: 0))
        XCTAssertNil(MindGraphQueryKey(question: "context", scope: .knowledge, topK: 31))
    }

    func testByteDistinctUnicodeTransportQuestionsCannotAlias() throws {
        let composed = "caf" + String(UnicodeScalar(0xe9)!)
        let decomposed = "cafe" + String(UnicodeScalar(0x301)!)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        let a = key(composed), b = key(decomposed)
        XCTAssertNotEqual(a, b)
        var cache = MindGraphQueryCache()
        let first = try XCTUnwrap(cache.begin(for: a))
        cache.complete(first, result: .success([hit(.knowledge)]))
        XCTAssertNil(cache.phase(for: b))
        XCTAssertNotNil(cache.begin(for: b))
        XCTAssertEqual(cache.count, 2)
    }

    func testRootSelectionHidesOldStateBeforePruningCallback() throws {
        var cache = MindGraphQueryCache()
        let rootA = URL(fileURLWithPath: "/fixture/root-a")
        let rootB = URL(fileURLWithPath: "/fixture/root-b")
        let a = MindGraphQueryKey(question: "context", scope: .knowledge, topK: 8, sourceRoot: rootA)!
        let b = MindGraphQueryKey(question: "context", scope: .knowledge, topK: 8, sourceRoot: rootB)!
        let old = try XCTUnwrap(cache.begin(for: a))
        cache.complete(old, result: .success([hit(.knowledge)]))
        XCTAssertNil(cache.phase(for: b))
        XCTAssertFalse(old.key.matchesSourceRoot(rootB))
        XCTAssertNotEqual(a, b)
    }

    func testForeignRootCompletionCannotEraseNewRootWork() throws {
        var cache = MindGraphQueryCache()
        let rootA = URL(fileURLWithPath: "/fixture/root-a")
        let rootB = URL(fileURLWithPath: "/fixture/root-b")
        let a = MindGraphQueryKey(question: "context", scope: .knowledge, topK: 8, sourceRoot: rootA)!
        let b = MindGraphQueryKey(question: "context", scope: .knowledge, topK: 8, sourceRoot: rootB)!
        let old = try XCTUnwrap(cache.begin(for: a))
        let current = try XCTUnwrap(cache.begin(for: b))
        cache.retainSourceRoot(rootB)
        XCTAssertTrue(cache.ownsPending(current))
        XCTAssertFalse(cache.complete(old, result: .success([hit(.knowledge)])))
        XCTAssertEqual(cache.phase(for: b), .loading)
        cache.retainSourceRoot(rootB)
        XCTAssertTrue(cache.complete(current, result: .success([])))
        XCTAssertEqual(cache.phase(for: b), .results([]))
        XCTAssertEqual(cache.count, 1)
    }

    func testCachedScopeRoundTripNeverRelabelsRows() throws {
        var cache = MindGraphQueryCache()
        let knowledge = key(), projects = key("context", .projects)
        let k = try XCTUnwrap(cache.begin(for: knowledge))
        cache.complete(k, result: .success([hit(.knowledge, "knowledge")]))
        XCTAssertNil(cache.phase(for: projects))
        let p = try XCTUnwrap(cache.begin(for: projects))
        XCTAssertEqual(cache.phase(for: projects), .loading)
        XCTAssertEqual(cache.phase(for: knowledge), .results([hit(.knowledge, "knowledge")]))
        cache.complete(p, result: .success([hit(.projects, "projects")]))
        XCTAssertEqual(cache.phase(for: knowledge), .results([hit(.knowledge, "knowledge")]))
        XCTAssertEqual(cache.phase(for: projects), .results([hit(.projects, "projects")]))
    }

    func testDifferentQuestionAndTopKHaveNoCachedResults() throws {
        var cache = MindGraphQueryCache()
        let request = try XCTUnwrap(cache.begin(for: key()))
        cache.complete(request, result: .success([hit(.knowledge)]))
        XCTAssertNil(cache.phase(for: key("different")))
        XCTAssertNil(cache.phase(for: key("context", .knowledge, 9)))
        XCTAssertEqual(cache.phase(for: key(" context ")), .results([hit(.knowledge)]))
    }

    func testLateKnowledgeSuccessOnlyFinishesItsCapturedRequest() throws {
        var cache = MindGraphQueryCache()
        let k = try XCTUnwrap(cache.begin(for: key()))
        let p = try XCTUnwrap(cache.begin(for: key("context", .projects, 20)))
        cache.complete(k, result: .success([hit(.knowledge)]))
        XCTAssertEqual(k.key.scope, .knowledge)
        XCTAssertEqual(k.key.topK, 8)
        XCTAssertEqual(cache.phase(for: p.key), .loading)
        XCTAssertEqual(cache.runningCount, 1)
        cache.complete(p, result: .success([hit(.projects)]))
        XCTAssertEqual(cache.phase(for: p.key), .results([hit(.projects)]))
    }

    func testLateErrorDoesNotReplaceAnotherScopesLoadingOrEmptyState() throws {
        var cache = MindGraphQueryCache()
        let k = try XCTUnwrap(cache.begin(for: key()))
        let p = try XCTUnwrap(cache.begin(for: key("context", .projects)))
        cache.complete(k, result: .failure(.timedOut))
        XCTAssertEqual(cache.phase(for: p.key), .loading)
        cache.complete(p, result: .success([]))
        XCTAssertEqual(cache.phase(for: p.key), .results([]))
        XCTAssertEqual(cache.phase(for: k.key), .failed(.timedOut))
        XCTAssertNil(cache.phase(for: key("unqueried", .projects)))
    }

    func testExplicitRefreshRejectsOldSuccessAndError() throws {
        var cache = MindGraphQueryCache()
        let old = try XCTUnwrap(cache.begin(for: key()))
        cache.complete(old, result: .success([hit(.knowledge, "old")]))
        let current = try XCTUnwrap(cache.begin(for: key()))
        XCTAssertNotEqual(old.id, current.id)
        XCTAssertFalse(cache.complete(old, result: .failure(.timedOut)))
        XCTAssertFalse(cache.complete(old, result: .success([hit(.knowledge, "late")])))
        XCTAssertEqual(cache.phase(for: key()), .loading)
        cache.complete(current, result: .success([hit(.knowledge, "new")]))
        XCTAssertFalse(cache.complete(current, result: .failure(.timedOut)))
        XCTAssertEqual(cache.phase(for: key()), .results([hit(.knowledge, "new")]))
    }

    func testWrongScopeRejectsTheWholeResult() throws {
        var cache = MindGraphQueryCache()
        let request = try XCTUnwrap(cache.begin(for: key()))
        XCTAssertTrue(cache.complete(request, result: .success([hit(.knowledge), hit(.projects)])))
        XCTAssertEqual(cache.phase(for: key()), .failed(.invalidJSON("Result scope does not match the query request.")))
    }

    func testTrustAndExcerptRemainNominationsWithoutRewriting() throws {
        var cache = MindGraphQueryCache()
        let request = try XCTUnwrap(cache.begin(for: key()))
        let row = MindGraphHit(docID: "unverified", chunkIndex: 3, displayPath: "missing.md", title: "Missing source",
                              chunkText: "unverified excerpt", trustProfile: "unknown", scope: .knowledge, signal: "nomination")
        cache.complete(request, result: .success([row]))
        XCTAssertEqual(cache.phase(for: key()), .results([row]))
    }

    func testInvalidationRejectsOldRootAndUnmountCompletions() throws {
        var cache = MindGraphQueryCache()
        let old = try XCTUnwrap(cache.begin(for: key()))
        cache.invalidate()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.runningCount, 0)
        let current = try XCTUnwrap(cache.begin(for: key()))
        XCTAssertTrue(cache.ownsPending(current))
        XCTAssertFalse(cache.ownsPending(old))
        XCTAssertFalse(cache.complete(old, result: .success([hit(.knowledge)])))
        XCTAssertEqual(cache.phase(for: current.key), .loading)
        cache.complete(current, result: .success([]))
        XCTAssertFalse(cache.ownsPending(current))
        XCTAssertEqual(cache.phase(for: current.key), .results([]))
    }

    func testConcurrentCapacityDoesNotInventQueuedRequests() throws {
        var cache = MindGraphQueryCache()
        let k = try XCTUnwrap(cache.begin(for: key()))
        let p = try XCTUnwrap(cache.begin(for: key("context", .projects)))
        let third = key("third")
        XCTAssertNil(cache.begin(for: third))
        XCTAssertNil(cache.phase(for: third))
        XCTAssertNil(cache.begin(for: k.key))
        XCTAssertEqual(cache.runningCount, 2)
        cache.complete(k, result: .failure(.binaryNotFound))
        XCTAssertNotNil(cache.begin(for: third))
        XCTAssertEqual(cache.phase(for: p.key), .loading)
    }

    func testEvictionBoundsSnapshotsAndRejectsEvictedTicket() throws {
        var cache = MindGraphQueryCache()
        let old = try XCTUnwrap(cache.begin(for: key("old")))
        cache.complete(old, result: .success([]))
        for i in 0..<32 {
            let request = try XCTUnwrap(cache.begin(for: key("query \(i)")))
            cache.complete(request, result: .success([]))
            XCTAssertLessThanOrEqual(cache.count, MindGraphQueryCache.maximumEntries)
        }
        XCTAssertEqual(cache.count, 16)
        XCTAssertNil(cache.phase(for: old.key))
        XCTAssertFalse(cache.complete(old, result: .failure(.timedOut)))
    }

    func testEvictionNeverDiscardsAnInFlightRequest() throws {
        var cache = MindGraphQueryCache()
        let pending = try XCTUnwrap(cache.begin(for: key()))
        for i in 0..<24 {
            let request = try XCTUnwrap(cache.begin(for: key("project \(i)", .projects)))
            cache.complete(request, result: .success([]))
        }
        XCTAssertEqual(cache.count, 16)
        XCTAssertEqual(cache.phase(for: pending.key), .loading)
        XCTAssertTrue(cache.complete(pending, result: .success([hit(.knowledge)])))
        XCTAssertEqual(cache.phase(for: pending.key), .results([hit(.knowledge)]))
    }

    func testAnotherCacheTicketCannotCompleteSameKey() throws {
        var first = MindGraphQueryCache(), second = MindGraphQueryCache()
        let foreign = try XCTUnwrap(first.begin(for: key()))
        let current = try XCTUnwrap(second.begin(for: key()))
        XCTAssertFalse(second.complete(foreign, result: .success([hit(.knowledge)])))
        XCTAssertEqual(second.phase(for: key()), .loading)
        XCTAssertTrue(second.complete(current, result: .success([])))
    }
}
