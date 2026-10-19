import Foundation
import ConduitCore

func runSessionAPIReplayChecks(_ check: (String, Bool) -> Void) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build")
        .appendingPathComponent("replay-selftest-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent("journal")
        var journal: SessionAPIReplayJournal? = try .init(directory: directory)
        for index in 0..<2049 {
            _ = journal!.perform(caller: "fixture", operation: "conduit_send_prompt", key: "denied-\(index)", fields: [], admission: { _ in
                ["error": "known pre-dispatch refusal"]
            })
        }
        check("known refusals leave no replay receipts", try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["owner"])
        let task = UUID().uuidString, event = UUID().uuidString
        let original = journal!.perform(caller: "fixture", operation: "conduit_send_prompt", key: "key", fields: ["prompt"]) {
            ["taskSessionID": task, "eventID": event, "delivery": "queued", "delivered": false]
        }
        check("replay journal records original acceptance", original["error"] == nil)
        journal = nil
        journal = try .init(directory: directory)
        var effects = 0
        let replay = journal!.perform(caller: "fixture", operation: "conduit_send_prompt", key: "key", fields: ["prompt"]) {
            effects += 1; return [:]
        }
        check("replay survives reconstruction without dispatch", effects == 0 && replay["eventID"] as? String == event)
        let conflict = journal!.perform(caller: "fixture", operation: "conduit_send_prompt", key: "key", fields: ["changed"]) {
            effects += 1; return [:]
        }
        check("replay conflicts fail closed", effects == 0 && conflict["replay_state"] as? String == "conflict")
    } catch { check("replay journal fixture: \(error)", false) }
}
