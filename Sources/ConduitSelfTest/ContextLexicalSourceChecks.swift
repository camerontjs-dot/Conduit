import ConduitCore
import Foundation

// Public-API parity for the lexical XCTest suite. All files belong to the
// caller's temporary fixture root; no shared corpus, provider, or index is used.
func runContextLexicalSourceChecks(root: URL, check: (String, Bool) -> Void) throws {
    let adapter = ContextLexicalSourceAdapter()
    let clock = Date(timeIntervalSince1970: 1_700_000_000)
    let fm = FileManager.default
    func write(_ path: String, _ text: String) throws {
        let file = root.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    func record(_ path: String, _ text: String, count: Int? = nil,
                markdown: MainframeMarkdownDocument? = nil) -> MainframeDocumentRecord {
        .init(path: path, name: String(path.split(separator: "/").last ?? ""), zone: .system,
              recordScope: nil, text: text, byteCount: count ?? text.utf8.count, markdown: markdown)
    }
    func index(_ records: [MainframeDocumentRecord], partial: Bool = false,
               nonText: Int = 0, tooLarge: Int = 0) -> MainframeContentIndex {
        .init(records: records, filesystemEntries: [], filesystemIndexTruncated: partial,
              contentTruncated: false, bytesIndexed: records.reduce(0) { $0 + $1.byteCount },
              skippedNonText: nonText, skippedTooLarge: tooLarge)
    }
    func expand(_ batch: ContextLexicalNominationBatch, ids: [String]? = nil, pin: Bool = false,
                range: ClosedRange<Int>? = nil, required: [ContextFileSourceRequest] = [],
                using current: ContextLexicalSourceAdapter? = nil) throws -> ContextLexicalSourceExpansionBatch {
        let selection = try batch.select((ids ?? batch.nominations.map(\.id)).map {
            .init(nominationID: $0, lineRange: range, isPinned: pin)
        })
        return try (current ?? adapter).expand(batch: batch, selection: selection, root: root,
                                              query: batch.query, requiredRequests: required, observedAt: clock)
    }
    func refused(_ code: ContextLexicalSourceError, _ body: () throws -> Void) -> Bool {
        do { try body(); return false }
        catch let failure as ContextLexicalSourceError { return failure == code }
        catch { return false }
    }

    let original = "  needle source  \r\n"
    try write("a.txt", original)
    let actualIndex = try MainframeContentIndexer().build(root: root)
    let batch = try adapter.discover(index: actualIndex, root: root, query: "needle")
    check("lexical actual Find supplies a compact cached preview", batch.nominations.count == 1
          && batch.nominations[0].preview == "needle source")
    let none = try expand(batch, ids: [])
    let empty = try none.makeContextSet(id: "empty", objective: "Inspect")
    check("lexical no selection reads and delivers no source", none.sourceBatch.observations.isEmpty
          && ContextManifestCompiler.compile(contextSet: empty, destination: .init(), budget: .init()).deliveredEntries.isEmpty)
    let observed = try expand(batch)
    check("lexical selection observes exact bytes rather than preview", observed.isHandoffEligible
          && observed.sourceBatch.observations[0].snapshot?.representedBytes == Data(original.utf8))
    check("lexical selected source retains authority and unknown later freshness", observed.candidateEntries[0].item.authority == .filesystemSource
          && observed.candidateEntries[0].item.freshness == .unknown
          && Set(observed.candidateEntries[0].inclusionReasons.map(\.kind)) == [.lexicalMatch, .explicitExpansion, .exactIdentity])
    let hard = try expand(batch, required: [.init(relativePath: "a.txt", origin: .objective),
                                           .init(relativePath: "a.txt", origin: .operatorPin),
                                           .init(relativePath: "a.txt", origin: .requiredContract)])
    let hardSet = try hard.makeContextSet(id: "set", objective: "Inspect")
    check("lexical pin objective and contract reasons survive compiler dedup", hardSet.entries.count == 1
          && hardSet.entries[0].item.isPinned && hardSet.entries[0].disposition == .mandatory
          && Set(hardSet.entries[0].inclusionReasons.map(\.kind)) == [.lexicalMatch, .explicitExpansion, .exactIdentity, .objective, .operatorPin, .requiredContract])
    check("lexical unknown budget remains unknown", ContextManifestCompiler.compile(
        contextSet: hardSet, destination: .init(), budget: .init()).budget.state == .unknownDestinationCapacity)
    check("lexical hard budget conflict preserves hard source", ContextManifestCompiler.compile(
        contextSet: hardSet, destination: .init(capacityTokens: 0),
        budget: .init(reservedOutputTokens: 0, reservedToolTokens: 0)).budget.state == .hardContextExceedsCapacity)
    let selectedPin = try expand(batch, pin: true, required: [.init(relativePath: "a.txt", origin: .objective)])
        .makeContextSet(id: "pin", objective: "Inspect")
    check("lexical explicit selected pin survives equal-strength duplicate", selectedPin.entries[0].item.isPinned)
    for origin in [ContextFileSourceOrigin.objective, .operatorPin, .requiredContract] {
        let incomplete = try expand(batch, required: [.init(relativePath: "missing", origin: origin)])
        check("lexical missing hard \(origin.rawValue) refuses handoff", incomplete.candidateEntries.count == 1
              && refused(.incompleteSourceObservation) { _ = try incomplete.makeContextSet(id: "set", objective: "Inspect") })
    }

    let ticket = try batch.select([.init(nominationID: batch.nominations[0].id)])
    let next = try adapter.discover(index: actualIndex, root: root, query: "needle")
    check("lexical stable snapshot and IDs have distinct active generations", batch.snapshotIdentity == next.snapshotIdentity
          && batch.nominations.map(\.id) == next.nominations.map(\.id) && batch.generationID != next.generationID)
    check("lexical stale selection generation is refused", refused(.foreignSelection) {
        _ = try adapter.expand(batch: next, selection: ticket, root: root, query: "needle", observedAt: clock)
    })
    check("lexical duplicate selection is refused", refused(.duplicateSelection) {
        _ = try batch.select([.init(nominationID: batch.nominations[0].id), .init(nominationID: batch.nominations[0].id)])
    })
    check("lexical missing selection ID is refused", refused(.nominationNotFound) { _ = try batch.select([.init(nominationID: "foreign")]) })
    check("lexical wrong root cannot relabel selection", refused(.wrongRootOrQuery) {
        _ = try adapter.expand(batch: batch, selection: ticket, root: root.appendingPathComponent("other"), query: "needle", observedAt: clock)
    })
    check("lexical exact query bytes bind selection", refused(.wrongRootOrQuery) {
        _ = try adapter.expand(batch: batch, selection: ticket, root: root, query: " needle ", observedAt: clock)
    })
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let firstManifest = ContextManifestCompiler.compile(contextSet: try observed.makeContextSet(id: "set", objective: "Inspect"), destination: .init(), budget: .init())
    let nextManifest = ContextManifestCompiler.compile(contextSet: try expand(next).makeContextSet(id: "set", objective: "Inspect"), destination: .init(), budget: .init())
    check("lexical fresh generations keep source manifest deterministic", try encoder.encode(firstManifest) == encoder.encode(nextManifest))
    try write("a.txt", "  absent source  \r\n")
    let changed = try expand(batch)
    check("lexical same-length after-index mutation remains unresolved", changed.sourceBatch.observations[0].failure?.code == .expectedIdentityMismatch
          && changed.sourceBatch.observations[0].observedSourceContentDigest != nil && changed.candidateEntries.isEmpty)
    try fm.removeItem(at: root.appendingPathComponent("a.txt"))
    check("lexical deleted selection remains unresolved", try expand(batch).sourceBatch.observations[0].failure?.code == .missing)

    try write("a.txt", "needle\r\nsecond\n")
    let lines = try adapter.discover(index: MainframeContentIndexer().build(root: root), root: root, query: "needle")
    let ranged = try expand(lines, range: 1...1)
    check("lexical explicit line range preserves CRLF bytes", ranged.sourceBatch.observations[0].snapshot?.representedBytes == Data("needle\r\n".utf8)
          && ranged.candidateEntries[0].representation == .excerpt && ranged.candidateEntries[0].contentDigest == nil)
    check("lexical invalid line range never clips", try expand(lines, range: 1...8).sourceBatch.observations[0].failure?.code == .invalidLineRange)
    let lowBytes = ContextLexicalSourceAdapter(sourceLimits: .init(maximumFileBytes: 1))
    check("lexical bounded read never clips into source success", try expand(lines, using: lowBytes).sourceBatch.observations[0].failure?.code == .fileByteLimitExceeded)
    try write("b.txt", "needle\n")
    let capped = ContextLexicalSourceAdapter(limits: .init(maximumNominations: 1))
    let clipped = try capped.discover(index: MainframeContentIndexer().build(root: root), root: root, query: "needle")
    check("lexical one extra Find hit exposes result clipping", clipped.nominations.count == 1 && clipped.coverage.resultClipped)
    check("lexical clipped search cannot yield complete handoff", refused(.partialDiscovery) {
        _ = try expand(clipped, using: capped).makeContextSet(id: "set", objective: "Inspect")
    })
    for cached in [index([], partial: true), index([], nonText: 1), index([], tooLarge: 1)] {
        let partial = try adapter.discover(index: cached, root: root, query: "needle")
        check("lexical skipped or partial empty search remains explicit", partial.coverage.mayBeIncomplete && refused(.partialDiscovery) {
            _ = try expand(partial).makeContextSet(id: "set", objective: "Inspect")
        })
    }
    let contentCap = try adapter.discover(index: index([record("a.txt", "needle\nneedle\nneedle\nneedle\n")]), root: root, query: "needle")
    check("lexical Find per-file cap is explicit", contentCap.nominations.count == 3 && contentCap.coverage.filesWithClippedContentHits == 1)
    let good = record("a.txt", "needle")
    for malformed in [index([good, good]), index([record("a.txt", "needle", count: 1)]), index([], nonText: -1)] {
        check("lexical malformed cached records cannot become nominations", refused(.invalidIndex) {
            _ = try adapter.discover(index: malformed, root: root, query: "needle")
        })
    }
    let forged = MainframeMarkdownParser.parse("# needle\n")
    check("lexical forged structured headings cannot manufacture a match", try adapter.discover(
        index: index([record("a.md", "no match", markdown: forged)]), root: root, query: "needle").nominations.isEmpty)
    for path in ["../outside", "/outside", "a//b", "a\0b", ".git/config"] {
        check("lexical unsafe cached path refused \(path.debugDescription)", refused(.invalidIndex) {
            _ = try adapter.discover(index: index([record(path, "needle")]), root: root, query: "needle")
        })
    }
    check("lexical invalid query is refused", refused(.invalidQuery) { _ = try adapter.discover(index: index([]), root: root, query: " \n") })
    check("lexical invalid limit is refused", refused(.invalidLimits) {
        _ = try ContextLexicalSourceAdapter(limits: .init(maximumNominations: 0)).discover(index: index([]), root: root, query: "needle")
    })
    check("lexical non-file root never triggers a network read", refused(.invalidRoot) {
        _ = try adapter.discover(index: index([]), root: URL(string: "https://example.invalid/root")!, query: "needle")
    })
    check("lexical remote file URL cannot label a local source read", refused(.invalidRoot) {
        _ = try adapter.discover(index: index([]), root: URL(string: "file://example.invalid/root")!, query: "needle")
    })
    let composed = "caf\u{00e9}", decomposed = "cafe\u{0301}"
    let unicode = index([record(composed + ":a", "needle"), record(decomposed + ":a", "needle"), record("a:content:1:b", "needle")])
    let distinct = try adapter.discover(index: unicode, root: root, query: "needle")
    check("lexical exact UTF8 and delimiter identities do not alias", distinct.nominations.count == 3 && Set(distinct.nominations.map(\.id)).count == 3)
    let a = try adapter.discover(index: index([record("a.txt", composed)]), root: root, query: composed)
    let b = try adapter.discover(index: index([record("a.txt", composed)]), root: root, query: decomposed)
    check("lexical byte-distinct Unicode queries keep separate identities", a.snapshotIdentity != b.snapshotIdentity && a.nominations.map(\.id) != b.nominations.map(\.id))
    let reversed = try adapter.discover(index: index(Array(unicode.records.reversed())), root: root, query: "needle")
    check("lexical input order cannot change stable IDs", distinct.snapshotIdentity == reversed.snapshotIdentity && distinct.nominations.map(\.id) == reversed.nominations.map(\.id))
    try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("a.txt"))
    let linked = try adapter.discover(index: index([record("link", "needle")]), root: root, query: "needle")
    check("lexical physical symlink is refused by unchanged reader", try expand(linked).sourceBatch.observations[0].failure?.code == .symbolicLink)
}
