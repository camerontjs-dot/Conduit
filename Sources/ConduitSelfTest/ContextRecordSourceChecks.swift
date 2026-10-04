import ConduitCore
import Foundation

// Public-API parity for the selected record suite. All files are created under
// the self-test's owned temporary root; no project history or runtime is read.
func runContextRecordSourceChecks(root: URL, check: (String, Bool) -> Void) throws {
    let fm = FileManager.default
    let adapter = ContextRecordSourceAdapter()
    let clock = Date(timeIntervalSince1970: 1_700_000_000)
    func write(_ path: String, _ text: String) throws {
        let file = root.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    func request(
        _ path: String, _ provenance: ContextRecordSourceProvenance = .testReceipt,
        origin: ContextFileSourceOrigin = .selectedFile, range: ClosedRange<Int>? = nil,
        expected: String? = nil, task: String? = nil, freshness: AgentContextFreshness = .unknown
    ) -> ContextRecordSourceRequest {
        .init(file: .init(relativePath: path, origin: origin, lineRange: range,
                         expectedContentDigest: expected), provenance: provenance,
              associatedTaskIdentity: task, freshness: freshness)
    }
    func observe(
        _ requests: [ContextRecordSourceRequest], required: [ContextFileSourceRequest] = [],
        using current: ContextRecordSourceAdapter? = nil
    ) throws -> ContextRecordSourceBatch {
        try (current ?? adapter).observe(root: root, requests: requests,
                                        requiredRequests: required, observedAt: clock)
    }
    func refused(_ code: ContextRecordSourceError, _ body: () throws -> Void) -> Bool {
        do { try body(); return false }
        catch let error as ContextRecordSourceError { return code == error }
        catch { return false }
    }

    let text = "{\"status\":\"PASS\",\"verified\":true,\"freshness\":\"current\"}\n"
    try write("record.json", text)
    let requests = [ContextRecordSourceProvenance.agentArtifact, .testReceipt, .lifecycleRecord].map {
        request("record.json", $0, task: "fixture-task")
    }
    let batch = try observe(requests)
    let set = try batch.makeContextSet(id: "set", objective: "Inspect")
    check("record one selected read retains three provenance classes", batch.isHandoffEligible
          && batch.sourceByteBudgetUsed == text.utf8.count && set.entries.count == 3
          && Set(set.entries.map { $0.item.authority }) == Set([AgentContextAuthority.agentOutput, .testReceipt, .lifecycleRecord]))
    check("record receipt words do not grant current validity", set.entries.allSatisfy { $0.item.freshness == .unknown }
          && batch.requiredSourceObservations.isEmpty
          && !set.entries.contains { $0.item.authority == .filesystemSource })
    check("record selected bytes retain exact observation time", batch.observations.allSatisfy {
        $0.snapshot?.representedBytes == Data(text.utf8) && $0.snapshot?.observedAt == clock
    })
    let none = try observe([])
    check("record no selection performs no discovery", none.observations.isEmpty && none.sourceByteBudgetUsed == 0
          && none.isHandoffEligible)
    check("record unknown provenance is unresolved before read", refused(.unknownProvenance) {
        _ = try observe([request("missing", .unknown)])
    })
    check("record current declaration is refused before read", refused(.unsupportedCurrentFreshness) {
        _ = try observe([request("missing", freshness: .current)])
    })
    for invalid in ["", " \n", "task\0id", String(repeating: "a", count: 4_097)] {
        check("record malformed task declaration is refused", refused(.invalidDeclaration) {
            _ = try observe([request("missing", task: invalid)])
        })
        check("record malformed stale declaration is refused", refused(.invalidDeclaration) {
            _ = try observe([request("missing", freshness: .stale(reason: invalid))])
        })
    }
    let staleState = AgentContextFreshness.stale(reason: "Superseded run")
    let pinned = try observe([request("record.json", origin: .operatorPin, freshness: staleState)])
    let pinnedSet = try pinned.makeContextSet(id: "pin", objective: "Inspect")
    check("record successful read preserves pinned stale receipt", pinnedSet.entries[0].item.freshness == staleState
          && pinnedSet.entries[0].item.isPinned && pinnedSet.entries[0].item.authority == .testReceipt)
    let manifest = ContextManifestCompiler.compile(
        contextSet: pinnedSet, destination: .init(capacityTokens: 0),
        budget: .init(reservedOutputTokens: 0, reservedToolTokens: 0)
    )
    check("record mandatory budget conflict preserves receipt", manifest.budget.state == .hardContextExceedsCapacity
          && pinnedSet.entries[0].disposition == .mandatory)
    for origin in ContextFileSourceOrigin.allCases {
        let missing = try observe([request("record.json"), request("missing", origin: origin)])
        check("record missing \(origin.rawValue) refuses complete handoff", missing.candidateEntries.count == 1
              && missing.unresolvedRequests.map(\.file.origin) == [origin]
              && refused(.incompleteSourceObservation) { _ = try missing.makeContextSet(id: "set", objective: "Inspect") })
    }
    let missingContract = try observe([request("record.json")],
                                      required: [.init(relativePath: "missing-contract", origin: .requiredContract)])
    check("record valid receipt cannot hide missing required source", !missingContract.isHandoffEligible
          && missingContract.requiredSourceObservations[0].failure?.code == .missing)

    try write("abc.txt", "abc")
    let abc = try observe([request("abc.txt")])
    let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check("record digest is physically read source SHA256", abc.observations[0].snapshot?.sourceContentDigest == digest)
    try write("abc.txt", "xyz")
    let changed = try observe([request("abc.txt", expected: digest)])
    check("record changed expected bytes remain unresolved", changed.observations[0].failure?.code == .expectedIdentityMismatch
          && changed.observations[0].observedSourceContentDigest != nil && changed.candidateEntries.isEmpty)
    try write("lines.txt", "α\r\nsame\nsame\n")
    let excerpt = try observe([request("lines.txt", range: 1...1)])
    check("record exact lines preserve bytes and receipt kind", excerpt.observations[0].snapshot?.representedBytes == Data("α\r\n".utf8)
          && excerpt.candidateEntries[0].item.kind == .testReceipt && excerpt.candidateEntries[0].contentDigest == nil)
    let ranges = try observe([request("lines.txt", range: 2...2), request("lines.txt", range: 3...3)])
    check("record repeated line bytes keep distinct ranges", try ranges.makeContextSet(id: "ranges", objective: "Inspect").entries.count == 2)
    check("record absent lines cannot be clipped", try observe([request("lines.txt", range: 1...9)]).observations[0].failure?.code == .invalidLineRange)
    let cap = try observe([request("abc.txt")], required: [.init(relativePath: "record.json", origin: .objective)],
                          using: .init(sourceLimits: .init(maximumRequests: 1)))
    check("record shared request budget retains all failures", cap.batchFailure?.code == .requestLimitExceeded
          && cap.sourceByteBudgetUsed == 0 && cap.observations.count == 1 && cap.requiredSourceObservations.count == 1)
    let lowBytes = try observe([request("abc.txt")], using: .init(sourceLimits: .init(maximumFileBytes: 1)))
    check("record file byte bound is never a successful prefix", lowBytes.observations[0].failure?.code == .fileByteLimitExceeded
          && !lowBytes.isHandoffEligible)
    try write("alias.txt", text)
    let aliases = try observe([request("record.json", task: "task:a"),
                              request("alias.txt", origin: .operatorPin, task: "task:b")])
    let aliasSet = try aliases.makeContextSet(id: "aliases", objective: "Inspect")
    check("record byte dedup retains pin path and task reasons", aliasSet.entries.count == 1
          && aliasSet.entries[0].item.isPinned && aliasSet.entries[0].duplicateSourceReferences.count == 1
          && aliasSet.entries[0].inclusionReasons.contains { $0.detail == "Caller-declared task association: task:a" }
          && aliasSet.entries[0].inclusionReasons.contains { $0.detail == "Caller-declared task association: task:b" })
    let staleCollision = try observe([request("record.json", freshness: staleState),
                                      request("record.json", origin: .operatorPin)])
    check("record pin cannot erase duplicate staleness", staleCollision.isComplete && !staleCollision.isHandoffEligible
          && refused(.incompatibleDuplicateMetadata) { _ = try staleCollision.makeContextSet(id: "set", objective: "Inspect") })
    let stalePinRequests = [request("record.json", origin: .operatorPin, freshness: staleState), request("record.json")]
    for ordered in [stalePinRequests, Array(stalePinRequests.reversed())] {
        let stalePin = try observe(ordered)
        let stalePinSet = try stalePin.makeContextSet(id: "set", objective: "Inspect")
        check("record stale pin keeps staleness in either request order", stalePin.isHandoffEligible
              && stalePinSet.entries[0].item.freshness == staleState)
    }
    let conflictingRequests = [request("record.json", freshness: staleState),
                               request("record.json", freshness: .stale(reason: "Replaced source"))]
    for ordered in [conflictingRequests, Array(conflictingRequests.reversed())] {
        let conflicting = try observe(ordered)
        check("record different stale reasons remain a conflict in either order", conflicting.isComplete && !conflicting.isHandoffEligible
              && refused(.incompatibleDuplicateMetadata) { _ = try conflicting.makeContextSet(id: "set", objective: "Inspect") })
    }
    let roleCollision = try observe([request("record.json", .lifecycleRecord)],
                                     required: [.init(relativePath: "record.json", origin: .operatorPin)])
    check("record ordinary source cannot erase record provenance", roleCollision.isComplete && !roleCollision.isHandoffEligible
          && refused(.incompatibleDuplicateMetadata) { _ = try roleCollision.makeContextSet(id: "set", objective: "Inspect") })
    for path in ["../outside", "/outside", "a//b", "a\0b", ".git/config"] {
        check("record unsafe path remains refused", try observe([request(path)]).observations[0].failure?.code == .unsafePath)
    }
    try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("abc.txt"))
    check("record symlink retains reader failure", try observe([request("link")]).observations[0].failure?.code == .symbolicLink)
    try Data([255, 254]).write(to: root.appendingPathComponent("binary"))
    check("record invalid UTF8 retains failure", try observe([request("binary")]).observations[0].failure?.code == .nonUTF8)
    for url in ["https://example.invalid/root", "file://example.invalid/root"] {
        check("record nonlocal root is refused without network", refused(.invalidRoot) {
            _ = try adapter.observe(root: URL(string: url)!, requests: [request("abc.txt")], observedAt: clock)
        })
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    check("record input order keeps observations deterministic", try encoder.encode(batch) == encoder.encode(observe(Array(requests.reversed()))))
}
