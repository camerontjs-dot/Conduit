import Foundation

/// Hard limits for the long-lived Codex app-server stdout stream.
///
/// The defaults are deliberately larger than normal JSON-RPC notifications,
/// but small enough that a wedged or hostile producer cannot grow Conduit's
/// memory without bound.
public struct CodexAppServerStreamConfiguration: Equatable, Sendable {
    public var maxChunkBytes: Int
    public var maxMessageBytes: Int
    public var maxBufferedBytes: Int
    public var maxPendingIngressBytes: Int
    public var maxPendingChunks: Int
    public var maxPendingDeliveries: Int
    public var maxDeliveryBatch: Int
    public var compactionThresholdBytes: Int
    public var deliveryCoalescingInterval: TimeInterval

    public init(
        maxChunkBytes: Int = 512 * 1_024,
        maxMessageBytes: Int = 1_024 * 1_024,
        maxBufferedBytes: Int = 2 * 1_024 * 1_024,
        maxPendingIngressBytes: Int = 4 * 1_024 * 1_024,
        maxPendingChunks: Int = 64,
        maxPendingDeliveries: Int = 128,
        maxDeliveryBatch: Int = 32,
        compactionThresholdBytes: Int = 256 * 1_024,
        deliveryCoalescingInterval: TimeInterval = 0.016
    ) {
        self.maxChunkBytes = max(1, maxChunkBytes)
        self.maxMessageBytes = max(1, maxMessageBytes)
        self.maxBufferedBytes = max(1, maxBufferedBytes)
        self.maxPendingIngressBytes = max(1, maxPendingIngressBytes)
        self.maxPendingChunks = max(1, maxPendingChunks)
        self.maxPendingDeliveries = max(2, maxPendingDeliveries)
        self.maxDeliveryBatch = max(1, min(maxDeliveryBatch, self.maxPendingDeliveries))
        self.compactionThresholdBytes = max(1, compactionThresholdBytes)
        self.deliveryCoalescingInterval = max(0, deliveryCoalescingInterval)
    }

    public static let conservative = CodexAppServerStreamConfiguration()
}

public enum CodexAppServerStreamError: Error, Equatable, Sendable {
    case chunkTooLarge(actual: Int, limit: Int)
    case ingressOverflow(queuedBytes: Int, byteLimit: Int, chunkLimit: Int)
    case messageTooLarge(actual: Int, limit: Int)
    case bufferOverflow(actual: Int, limit: Int)
    case malformedMessage
    case truncatedMessage
    case deliveryOverflow(limit: Int)
}

extension CodexAppServerStreamError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .chunkTooLarge(let actual, let limit):
            return "Codex app-server stdout chunk exceeded the bounded limit (\(actual) > \(limit) bytes)."
        case .ingressOverflow(let queuedBytes, let byteLimit, let chunkLimit):
            return "Codex app-server stdout ingress queue overflowed (\(queuedBytes)/\(byteLimit) bytes; \(chunkLimit) chunk limit)."
        case .messageTooLarge(let actual, let limit):
            return "Codex app-server JSON-RPC message exceeded the bounded limit (\(actual) > \(limit) bytes)."
        case .bufferOverflow(let actual, let limit):
            return "Codex app-server framing buffer overflowed (\(actual) > \(limit) bytes)."
        case .malformedMessage:
            return "Codex app-server emitted malformed JSON-RPC. The stream was closed without recording its contents."
        case .truncatedMessage:
            return "Codex app-server stdout ended with a truncated JSON-RPC message."
        case .deliveryOverflow(let limit):
            return "Codex app-server downstream delivery queue exceeded its \(limit)-item limit."
        }
    }
}

/// Parsed app-server work delivered to the UI actor.
///
/// Responses remain distinct because request continuations must be resumed.
/// Mapper effects are already computed on the stream worker, including the
/// potentially expensive cumulative-output assembly.
public enum CodexAppServerDelivery: Equatable, Sendable {
    case response(id: CodexJSONRPCID, result: CodexJSON)
    case error(id: CodexJSONRPCID?, message: String)
    case effect(CodexAppServerEffect)
}

/// A bounded, single-worker newline framer and JSON-RPC mapper.
///
/// `ingest(_:)` is safe to call directly from a `FileHandle` readability
/// callback. It never parses on that callback and never creates a Task. At
/// most one bounded delivery batch is in flight, so a stalled main actor
/// cannot create an unbounded chain of callbacks.
public final class CodexAppServerStreamPump: @unchecked Sendable {
    public typealias DeliveryHandler = @Sendable ([CodexAppServerDelivery]) -> Void
    public typealias FailureHandler = @Sendable (CodexAppServerStreamError) -> Void

    private let configuration: CodexAppServerStreamConfiguration
    private let worker: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private let onDelivery: DeliveryHandler
    private let onFailure: FailureHandler

    private let stateLock = NSLock()
    private var accepting = true
    private var queuedIngressBytes = 0
    private var queuedIngressChunks = 0

    // Worker-confined state.
    private var buffer = Data()
    private var lineStartOffset = 0
    private var scanOffset = 0
    private var mapper = CodexAppServerMapper()
    private var pendingDeliveries: [CodexAppServerDelivery] = []
    private var deliveryInFlight = false
    private var terminalFailureDelivered = false

    public init(
        configuration: CodexAppServerStreamConfiguration = .conservative,
        workerQueue: DispatchQueue? = nil,
        deliveryQueue: DispatchQueue = .main,
        onDelivery: @escaping DeliveryHandler,
        onFailure: @escaping FailureHandler
    ) {
        self.configuration = configuration
        self.worker = workerQueue ?? DispatchQueue(
            label: "com.conduit.codex-app-server.stream",
            qos: .userInitiated
        )
        self.deliveryQueue = deliveryQueue
        self.onDelivery = onDelivery
        self.onFailure = onFailure
    }

    /// Enqueues a stdout chunk if doing so remains within both ingress bounds.
    /// Returns false once the stream has failed, stopped, or rejected a chunk.
    @discardableResult
    public func ingest(_ chunk: Data) -> Bool {
        guard !chunk.isEmpty else {
            finish()
            return true
        }
        guard chunk.count <= configuration.maxChunkBytes else {
            requestFailure(
                .chunkTooLarge(
                    actual: chunk.count,
                    limit: configuration.maxChunkBytes
                )
            )
            return false
        }

        stateLock.lock()
        guard accepting else {
            stateLock.unlock()
            return false
        }
        let nextBytes = queuedIngressBytes + chunk.count
        let nextChunks = queuedIngressChunks + 1
        guard nextBytes <= configuration.maxPendingIngressBytes,
              nextChunks <= configuration.maxPendingChunks
        else {
            accepting = false
            stateLock.unlock()
            enqueueTerminalFailure(
                .ingressOverflow(
                    queuedBytes: nextBytes,
                    byteLimit: configuration.maxPendingIngressBytes,
                    chunkLimit: configuration.maxPendingChunks
                )
            )
            return false
        }
        queuedIngressBytes = nextBytes
        queuedIngressChunks = nextChunks
        stateLock.unlock()

        worker.async { [weak self] in
            guard let self else { return }
            defer { self.releaseIngress(byteCount: chunk.count) }
            guard self.isAccepting else { return }
            self.process(chunk)
        }
        return true
    }

    /// Marks stdout EOF. A non-whitespace partial frame is an explicit error.
    public func finish() {
        worker.async { [weak self] in
            guard let self, self.isAccepting else { return }
            let trailing = self.buffer.suffix(from: self.lineStartOffset)
            if trailing.contains(where: { !Self.isJSONWhitespace($0) }) {
                self.failOnWorker(.truncatedMessage)
            }
        }
    }

    /// Resets per-turn mapper state in stream order.
    public func resetTurn() {
        worker.async { [weak self] in
            guard let self, self.isAccepting else { return }
            self.mapper.resetTurn()
        }
    }

    /// Supplies a thread id obtained during handshake without moving mapper
    /// mutation back onto the UI actor.
    public func setThreadID(_ threadID: String) {
        worker.async { [weak self] in
            guard let self, self.isAccepting else { return }
            self.mapper.threadID = threadID
        }
    }

    /// Stops accepting work without reporting a protocol failure.
    public func cancel() {
        stateLock.lock()
        accepting = false
        stateLock.unlock()
        worker.async { [weak self] in
            self?.buffer.removeAll(keepingCapacity: false)
            self?.pendingDeliveries.removeAll(keepingCapacity: false)
        }
    }

    private var isAccepting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return accepting
    }

    private func releaseIngress(byteCount: Int) {
        stateLock.lock()
        queuedIngressBytes = max(0, queuedIngressBytes - byteCount)
        queuedIngressChunks = max(0, queuedIngressChunks - 1)
        stateLock.unlock()
    }

    private func requestFailure(_ error: CodexAppServerStreamError) {
        stateLock.lock()
        guard accepting else {
            stateLock.unlock()
            return
        }
        accepting = false
        stateLock.unlock()
        enqueueTerminalFailure(error)
    }

    private func enqueueTerminalFailure(_ error: CodexAppServerStreamError) {
        worker.async { [weak self] in
            self?.failOnWorker(error, stateAlreadyClosed: true)
        }
    }

    private func process(_ chunk: Data) {
        buffer.append(chunk)
        guard buffer.count <= configuration.maxBufferedBytes else {
            failOnWorker(
                .bufferOverflow(
                    actual: buffer.count,
                    limit: configuration.maxBufferedBytes
                )
            )
            return
        }

        while scanOffset < buffer.count {
            let index = buffer.index(buffer.startIndex, offsetBy: scanOffset)
            if buffer[index] == 0x0A {
                let messageLength = scanOffset - lineStartOffset
                guard messageLength <= configuration.maxMessageBytes else {
                    failOnWorker(
                        .messageTooLarge(
                            actual: messageLength,
                            limit: configuration.maxMessageBytes
                        )
                    )
                    return
                }
                let lower = buffer.index(buffer.startIndex, offsetBy: lineStartOffset)
                let line = buffer.subdata(in: lower..<index)
                lineStartOffset = scanOffset + 1
                scanOffset += 1
                if line.contains(where: { !Self.isJSONWhitespace($0) }) {
                    guard let json = CodexJSON.parse(line),
                          let message = CodexJSONRPCMessage.parse(json)
                    else {
                        failOnWorker(.malformedMessage)
                        return
                    }
                    process(message)
                    guard isAccepting else { return }
                }
                continue
            }
            scanOffset += 1
            let partialLength = scanOffset - lineStartOffset
            if partialLength > configuration.maxMessageBytes {
                failOnWorker(
                    .messageTooLarge(
                        actual: partialLength,
                        limit: configuration.maxMessageBytes
                    )
                )
                return
            }
        }

        compactIfNeeded()
    }

    private func process(_ message: CodexJSONRPCMessage) {
        switch message {
        case .response(let id, let result):
            guard enqueue(.response(id: id, result: result)) else { return }
        case .error(let id, let message):
            guard enqueue(.error(id: id, message: message)) else { return }
        case .notification, .request:
            break
        }

        for effect in mapper.apply(message) {
            guard enqueue(.effect(effect)) else { return }
        }
    }

    private func enqueue(_ delivery: CodexAppServerDelivery) -> Bool {
        if delivery.isLiveOutput {
            if let index = pendingDeliveries.lastIndex(where: { $0.isLiveOutput }) {
                pendingDeliveries[index] = delivery
                return true
            }
            // Live output is observational and replaceable. If control work has
            // consumed the reserved capacity, omit this revision; a later live
            // or final closed revision remains authoritative.
            guard pendingDeliveries.count < configuration.maxPendingDeliveries else {
                return true
            }
        } else {
            if delivery.isClosedOutput {
                pendingDeliveries.removeAll(where: { $0.isLiveOutput })
            }
            if pendingDeliveries.count >= configuration.maxPendingDeliveries,
               let liveIndex = pendingDeliveries.firstIndex(where: { $0.isLiveOutput }) {
                pendingDeliveries.remove(at: liveIndex)
            }
            guard pendingDeliveries.count < configuration.maxPendingDeliveries else {
                failOnWorker(
                    .deliveryOverflow(limit: configuration.maxPendingDeliveries)
                )
                return false
            }
        }

        pendingDeliveries.append(delivery)
        scheduleDeliveryIfNeeded()
        return true
    }

    private func scheduleDeliveryIfNeeded() {
        guard !deliveryInFlight, !pendingDeliveries.isEmpty, isAccepting else {
            return
        }
        deliveryInFlight = true
        let count = min(configuration.maxDeliveryBatch, pendingDeliveries.count)
        let batch = Array(pendingDeliveries.prefix(count))
        pendingDeliveries.removeFirst(count)
        let delay = configuration.deliveryCoalescingInterval
        deliveryQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.onDelivery(batch)
            self.worker.async { [weak self] in
                guard let self else { return }
                self.deliveryInFlight = false
                self.scheduleDeliveryIfNeeded()
            }
        }
    }

    private func compactIfNeeded() {
        guard lineStartOffset > 0 else { return }
        let shouldCompact = lineStartOffset >= configuration.compactionThresholdBytes
            || lineStartOffset >= buffer.count / 2
        guard shouldCompact else { return }
        buffer = Data(buffer.suffix(from: lineStartOffset))
        scanOffset -= lineStartOffset
        lineStartOffset = 0
    }

    private func failOnWorker(
        _ error: CodexAppServerStreamError,
        stateAlreadyClosed: Bool = false
    ) {
        guard !terminalFailureDelivered else { return }
        terminalFailureDelivered = true
        if !stateAlreadyClosed {
            stateLock.lock()
            accepting = false
            stateLock.unlock()
        }
        buffer.removeAll(keepingCapacity: false)
        pendingDeliveries.removeAll(keepingCapacity: false)
        deliveryQueue.async { [onFailure] in
            onFailure(error)
        }
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }
}

private extension CodexAppServerDelivery {
    var isLiveOutput: Bool {
        if case .effect(.upsertOutput(_, state: .live)) = self { return true }
        return false
    }

    var isClosedOutput: Bool {
        if case .effect(.upsertOutput(_, state: .closed)) = self { return true }
        return false
    }
}

/// Thread-safe, tail-only stderr capture used to keep the app-server pipe
/// drained without retaining an unbounded diagnostic transcript.
public final class CodexAppServerStderrTail: @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var bytes = Data()

    public init(maxBytes: Int = 64 * 1_024) {
        self.maxBytes = max(1, maxBytes)
    }

    public func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        if chunk.count >= maxBytes {
            bytes = Data(chunk.suffix(maxBytes))
        } else {
            let overflow = max(0, bytes.count + chunk.count - maxBytes)
            if overflow > 0 {
                bytes.removeFirst(overflow)
            }
            bytes.append(chunk)
        }
        lock.unlock()
    }

    public func snapshot() -> String {
        lock.lock()
        let snapshot = bytes
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
    }
}
