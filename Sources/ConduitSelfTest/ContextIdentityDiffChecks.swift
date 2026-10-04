import ConduitCore

func runContextIdentityDiffChecks(_ check: (String, Bool) -> Void) {
    func item(
        id: String = "retained",
        title: String = "Source",
        kind: AgentContextItemKind = .file,
        authority: AgentContextAuthority = .filesystemSource,
        sourceReference: String = "a|b",
        revisionIdentity: String? = "c",
        lineRange: ClosedRange<Int>? = 1...2,
        estimatedTokens: Int? = 10,
        isPinned: Bool = false,
        freshness: AgentContextFreshness = .current
    ) -> AgentContextItem {
        AgentContextItem(
            id: id, title: title, kind: kind, authority: authority,
            sourceReference: sourceReference, revisionIdentity: revisionIdentity,
            lineRange: lineRange, estimatedTokens: estimatedTokens,
            isPinned: isPinned, freshness: freshness
        )
    }
    func diff(_ before: AgentContextItem, _ after: AgentContextItem) -> AgentContextDiff {
        AgentContextDiffer.diff(
            previous: AgentContextBundle(taskTitle: "Before", items: [before]),
            current: AgentContextBundle(taskTitle: "After", items: [after])
        )
    }

    let before = item()
    let collision = item(sourceReference: "a", revisionIdentity: "b|c")
    check("context legacy fingerprint collision remains observable",
          before.identityFingerprint == collision.identityFingerprint)
    let changed = diff(before, collision)
    check("context delta detects delimiter collision",
          changed.changed == [AgentContextItemChange(before: before, after: collision)]
            && changed.added.isEmpty && changed.removed.isEmpty)

    let cases: [(String, AgentContextItem)] = [
        ("kind", item(kind: .selection)),
        ("authority", item(authority: .agentOutput)),
        ("source", item(sourceReference: "other")),
        ("revision", item(revisionIdentity: "next")),
        ("range", item(lineRange: 2...3)),
        ("absent range", item(lineRange: nil)),
        ("freshness state", item(freshness: .unknown)),
        ("stale state", item(freshness: .stale(reason: "source changed")))
    ]
    for (label, after) in cases {
        check("context delta preserves identity field: " + label,
              diff(before, after).changed == [AgentContextItemChange(before: before, after: after)])
    }
    check("context delta preserves stale reason changes",
          diff(item(freshness: .stale(reason: "old")),
               item(freshness: .stale(reason: "new|reason"))).changed.count == 1)
    check("context delta excludes presentation fields",
          diff(before, item(title: "Display", estimatedTokens: 99, isPinned: true)).isEmpty)
    check("context delta preserves absent empty revision equivalence",
          diff(item(revisionIdentity: nil), item(revisionIdentity: "")).isEmpty)

    let oldID = item(id: "old")
    let newID = item(id: "new")
    let identityChange = diff(oldID, newID)
    check("context delta treats changed stable ID as removal and addition",
          identityChange.removed == [oldID] && identityChange.added == [newID]
            && identityChange.changed.isEmpty)
    let ordered = AgentContextDiffer.diff(
        previous: AgentContextBundle(taskTitle: "Task", items: [item(id: "b"), item(id: "a")]),
        current: AgentContextBundle(taskTitle: "Task", items: [
            item(id: "b", sourceReference: "a", revisionIdentity: "b|c"),
            item(id: "a", revisionIdentity: "next")
        ])
    )
    check("context delta keeps deterministic changed order",
          ordered.changed.map { $0.after.id } == ["a", "b"])
}
