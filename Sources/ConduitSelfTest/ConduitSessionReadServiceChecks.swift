import ConduitCore
import Foundation

func runConduitSessionReadServiceChecks(_ check: (String, Bool) -> Void) {
    let task = TaskSessionID(
        rawValue: UUID(uuidString: "71111111-1111-1111-1111-111111111111")!
    )
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("conduit-selftest-read-service-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = ConversationEventLog(
        directory: root.appendingPathComponent("history"),
        taskSessionID: task
    )
    var calls: [String] = []
    let owner = ConduitSessionClosureReadOwner(
        observe: { id in
            calls.append("observe")
            return id == task
                ? ConduitSessionTaskObservation(
                    backend: .pty,
                    lifecycle: "closed",
                    runtimeState: "closed",
                    live: false,
                    ready: false
                )
                : nil
        },
        live: { _ in
            calls.append("live")
            return nil
        },
        cached: { _ in
            calls.append("cached")
            return nil
        },
        log: { _ in
            calls.append("log")
            return log
        }
    )

    let page = try? ConduitSessionReadService.events(
        owner: owner,
        taskSessionID: task.rawValue.uuidString,
        cursor: nil,
        limit: nil,
        options: ConduitSessionEventReadOptions(changesSince: "")
    ).get()
    check(
        "read service reads the durable log before choosing the timeline",
        calls.first(where: { $0 == "log" || $0 == "live" }) == "log"
    )
    check(
        "read service reports a missing log through the durable timeline",
        page?.timelineSource?.kind == .durableLog
            && page?.timelineSource?.durableCoverage == .missing
            && page?.changes?.coverage == .missing
    )

    calls.removeAll()
    let unknown = ConduitSessionReadService.events(
        owner: owner,
        taskSessionID: UUID().uuidString,
        cursor: nil,
        limit: nil
    )
    var refused = false
    if case .failure(.unknownTask) = unknown { refused = true }
    check(
        "read service refuses an unknown task without touching runtime state",
        refused && calls == ["observe"]
    )
}
