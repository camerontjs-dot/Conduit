#if os(macOS)
import ConduitCore
import Foundation

/// Serializes conversation-log I/O away from SwiftUI's main actor.
///
/// One coordinator owns one queue for the configured conversation directory.
/// Appends and reads therefore retain call order: a read submitted after a
/// close revision cannot overtake that revision and accidentally project
/// volatile in-memory state as durable history.
final class ConversationPersistenceCoordinator: @unchecked Sendable {
    struct ReadResult: Sendable {
        let log: ConversationEventLogReadResult
        let fileWasPresent: Bool
    }

    private let directory: URL
    private let queue = DispatchQueue(
        label: "dev.camerontjs.conduit.conversation-persistence",
        qos: .utility
    )

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    func append(
        _ event: SessionPresentationEvent,
        taskSessionID: TaskSessionID,
        completion: @escaping @Sendable (_ errorDescription: String?) -> Void
    ) {
        let directory = directory
        queue.async {
            do {
                try ConversationEventLog(
                    directory: directory,
                    taskSessionID: taskSessionID
                ).append(event)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }

    /// Reads after every previously-enqueued append has completed.
    func read(
        taskSessionID: TaskSessionID,
        completion: @escaping @Sendable (ReadResult) -> Void
    ) {
        let directory = directory
        queue.async {
            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: taskSessionID
            )
            completion(
                ReadResult(
                    log: log.read(),
                    fileWasPresent: FileManager.default.fileExists(
                        atPath: log.url.path
                    )
                )
            )
        }
    }
}
#endif
