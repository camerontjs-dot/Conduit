import XCTest
@testable import ConduitCore

final class CodexAppServerStreamPumpTests: XCTestCase {
    func testSplitFramesAreParsedAndMappedInOrder() {
        let delivered = expectation(description: "mapped delivery")
        let recorder = CodexDeliveryRecorder { values in
            if values.contains(where: {
                $0 == .effect(.upsertOutput(text: "Hello", state: .live))
            }) {
                delivered.fulfill()
            }
        }
        let pump = CodexAppServerStreamPump(
            configuration: configuration(deliveryCoalescingInterval: 0),
            deliveryQueue: DispatchQueue(label: "test.codex.delivery.split"),
            onDelivery: { recorder.record($0) },
            onFailure: { recorder.record(failure: $0) }
        )
        let input = Data(
            (#"{"id":1,"result":{"thread":{"id":"thr_1"}}}"#
                + "\n"
                + #"{"method":"item/agentMessage/delta","params":{"delta":"Hello"}}"#
                + "\n").utf8
        )
        let split = input.count / 2

        XCTAssertTrue(pump.ingest(input.prefix(split)))
        XCTAssertTrue(pump.ingest(input.suffix(from: split)))

        wait(for: [delivered], timeout: 2)
        let values = recorder.deliveries
        XCTAssertEqual(values.first, .response(id: .number(1), result: .object([
            "thread": .object(["id": .string("thr_1")])
        ])))
        XCTAssertTrue(values.contains(.effect(.threadStarted(id: "thr_1"))))
        XCTAssertTrue(values.contains(.effect(.upsertOutput(text: "Hello", state: .live))))
        XCTAssertNil(recorder.failure)
    }

    func testMalformedEnvelopeFailsWithoutIncludingPayload() {
        let failed = expectation(description: "malformed failure")
        let recorder = CodexDeliveryRecorder { _ in }
        let pump = CodexAppServerStreamPump(
            configuration: configuration(deliveryCoalescingInterval: 0),
            deliveryQueue: DispatchQueue(label: "test.codex.delivery.malformed"),
            onDelivery: { recorder.record($0) },
            onFailure: {
                recorder.record(failure: $0)
                failed.fulfill()
            }
        )

        XCTAssertTrue(pump.ingest(Data(#"{"secret":"must-not-echo"}"#.utf8) + Data([0x0A])))

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(recorder.failure, .malformedMessage)
        XCTAssertFalse(recorder.failure?.localizedDescription.contains("must-not-echo") ?? true)
        XCTAssertTrue(recorder.deliveries.isEmpty)
    }

    func testMalformedMatchingRPCErrorIsProtocolFailureNotErrorDelivery() {
        let failed = expectation(description: "invalid JSON-RPC error rejected")
        let recorder = CodexDeliveryRecorder { _ in }
        let pump = CodexAppServerStreamPump(
            configuration: configuration(deliveryCoalescingInterval: 0),
            deliveryQueue: DispatchQueue(label: "test.codex.delivery.invalid-rpc-error"),
            onDelivery: { recorder.record($0) },
            onFailure: {
                recorder.record(failure: $0)
                failed.fulfill()
            }
        )

        XCTAssertTrue(
            pump.ingest(Data(#"{"id":3,"error":null}"#.utf8) + Data([0x0A]))
        )

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(recorder.failure, .malformedMessage)
        XCTAssertTrue(recorder.deliveries.isEmpty)
    }

    func testOversizedChunkIsRejectedBeforeItIsQueued() {
        let failed = expectation(description: "chunk limit failure")
        let recorder = CodexDeliveryRecorder { _ in }
        let limits = configuration(
            maxChunkBytes: 8,
            maxMessageBytes: 64,
            maxBufferedBytes: 64,
            deliveryCoalescingInterval: 0
        )
        let pump = CodexAppServerStreamPump(
            configuration: limits,
            deliveryQueue: DispatchQueue(label: "test.codex.delivery.chunk"),
            onDelivery: { recorder.record($0) },
            onFailure: {
                recorder.record(failure: $0)
                failed.fulfill()
            }
        )

        XCTAssertFalse(pump.ingest(Data(repeating: 0x61, count: 9)))

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(recorder.failure, .chunkTooLarge(actual: 9, limit: 8))
    }

    func testOversizedUnterminatedMessageFailsAtMessageLimit() {
        let failed = expectation(description: "message limit failure")
        let recorder = CodexDeliveryRecorder { _ in }
        let limits = configuration(
            maxChunkBytes: 64,
            maxMessageBytes: 12,
            maxBufferedBytes: 64,
            deliveryCoalescingInterval: 0
        )
        let pump = CodexAppServerStreamPump(
            configuration: limits,
            deliveryQueue: DispatchQueue(label: "test.codex.delivery.message"),
            onDelivery: { recorder.record($0) },
            onFailure: {
                recorder.record(failure: $0)
                failed.fulfill()
            }
        )

        XCTAssertTrue(pump.ingest(Data(repeating: 0x61, count: 13)))

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(recorder.failure, .messageTooLarge(actual: 13, limit: 12))
    }

    func testBufferOverflowIsExplicitWhenBufferLimitIsStricter() {
        let failed = expectation(description: "buffer failure")
        let recorder = CodexDeliveryRecorder { _ in }
        let limits = configuration(
            maxChunkBytes: 64,
            maxMessageBytes: 64,
            maxBufferedBytes: 8,
            deliveryCoalescingInterval: 0
        )
        let pump = CodexAppServerStreamPump(
            configuration: limits,
            deliveryQueue: DispatchQueue(label: "test.codex.delivery.buffer"),
            onDelivery: { recorder.record($0) },
            onFailure: {
                recorder.record(failure: $0)
                failed.fulfill()
            }
        )

        XCTAssertTrue(pump.ingest(Data(repeating: 0x61, count: 9)))

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(recorder.failure, .bufferOverflow(actual: 9, limit: 8))
    }

    func testIngressQueueRejectsWorkAtomicallyAtItsBounds() {
        let worker = DispatchQueue(label: "test.codex.worker.ingress")
        let gate = DispatchSemaphore(value: 0)
        worker.async { gate.wait() }
        let failed = expectation(description: "ingress failure")
        let recorder = CodexDeliveryRecorder { _ in }
        let limits = configuration(
            maxChunkBytes: 8,
            maxMessageBytes: 64,
            maxBufferedBytes: 64,
            maxPendingIngressBytes: 8,
            maxPendingChunks: 2,
            deliveryCoalescingInterval: 0
        )
        let pump = CodexAppServerStreamPump(
            configuration: limits,
            workerQueue: worker,
            deliveryQueue: DispatchQueue(label: "test.codex.delivery.ingress"),
            onDelivery: { recorder.record($0) },
            onFailure: {
                recorder.record(failure: $0)
                failed.fulfill()
            }
        )

        XCTAssertTrue(pump.ingest(Data(repeating: 0x20, count: 4)))
        XCTAssertTrue(pump.ingest(Data(repeating: 0x20, count: 4)))
        XCTAssertFalse(pump.ingest(Data(repeating: 0x20, count: 4)))
        gate.signal()

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(
            recorder.failure,
            .ingressOverflow(queuedBytes: 12, byteLimit: 8, chunkLimit: 2)
        )
    }

    func testManyLiveRevisionsCoalesceButClosedFinalAndCompletionSurvive() {
        let worker = DispatchQueue(label: "test.codex.worker.coalescing")
        let deliveryQueue = DispatchQueue(label: "test.codex.delivery.coalescing")
        let gate = DispatchSemaphore(value: 0)
        deliveryQueue.async { gate.wait() }
        let completed = expectation(description: "final state delivered")
        let recorder = CodexDeliveryRecorder { values in
            if values.contains(.effect(.turnCompleted(status: "completed"))) {
                completed.fulfill()
            }
        }
        let pump = CodexAppServerStreamPump(
            configuration: configuration(
                maxChunkBytes: 128 * 1_024,
                maxMessageBytes: 1_024,
                maxBufferedBytes: 128 * 1_024,
                maxPendingDeliveries: 8,
                maxDeliveryBatch: 4,
                deliveryCoalescingInterval: 0
            ),
            workerQueue: worker,
            deliveryQueue: deliveryQueue,
            onDelivery: { recorder.record($0) },
            onFailure: { recorder.record(failure: $0) }
        )
        var stream = Data()
        for _ in 0..<200 {
            stream.append(Data(
                (#"{"method":"item/agentMessage/delta","params":{"delta":"x"}}"# + "\n").utf8
            ))
        }
        stream.append(Data(
            (#"{"method":"turn/completed","params":{"status":"completed"}}"# + "\n").utf8
        ))

        XCTAssertTrue(pump.ingest(stream))
        worker.sync {}
        gate.signal()

        wait(for: [completed], timeout: 2)
        XCTAssertNil(recorder.failure)
        let deliveries = recorder.deliveries
        let live = deliveries.filter {
            if case .effect(.upsertOutput(_, state: .live)) = $0 { return true }
            return false
        }
        XCTAssertLessThanOrEqual(live.count, 1)
        XCTAssertTrue(deliveries.contains(
            .effect(.upsertOutput(text: String(repeating: "x", count: 200), state: .closed))
        ))
        let closedIndex = deliveries.firstIndex {
            if case .effect(.upsertOutput(_, state: .closed)) = $0 { return true }
            return false
        }
        let completionIndex = deliveries.firstIndex(of: .effect(.turnCompleted(status: "completed")))
        XCTAssertNotNil(closedIndex)
        XCTAssertNotNil(completionIndex)
        if let closedIndex, let completionIndex {
            XCTAssertLessThan(closedIndex, completionIndex)
        }
    }

    func testDeliveryBatchesRemainBoundedAcrossManyControlResponses() {
        let worker = DispatchQueue(label: "test.codex.worker.batches")
        let delivered = expectation(description: "all responses")
        // The observer is an argument to the recorder's own initializer, so it
        // cannot read the recorder back. Accumulate here instead, and fulfil on
        // the batch that carries the run past the last expected response.
        let observed = CodexResponseCounter()
        let recorder = CodexDeliveryRecorder { values in
            let batch = recorderResponseCount(values: values)
            guard batch > 0 else { return }
            if observed.add(batch) == 20 {
                delivered.fulfill()
            }
        }
        let pump = CodexAppServerStreamPump(
            configuration: configuration(
                maxPendingDeliveries: 32,
                maxDeliveryBatch: 3,
                deliveryCoalescingInterval: 0
            ),
            workerQueue: worker,
            deliveryQueue: DispatchQueue(label: "test.codex.delivery.batches"),
            onDelivery: { recorder.record($0) },
            onFailure: { recorder.record(failure: $0) }
        )
        let stream = (1...20).map {
            "{\"id\":\($0),\"result\":{\"ok\":true}}\n"
        }.joined()

        XCTAssertTrue(pump.ingest(Data(stream.utf8)))

        wait(for: [delivered], timeout: 2)
        XCTAssertNil(recorder.failure)
        XCTAssertEqual(recorderResponseCount(values: recorder.deliveries), 20)
        XCTAssertLessThanOrEqual(recorder.maximumBatchSize, 3)
    }

    func testDownstreamControlOverflowFailsClosed() {
        let worker = DispatchQueue(label: "test.codex.worker.downstream")
        let deliveryQueue = DispatchQueue(label: "test.codex.delivery.downstream")
        let gate = DispatchSemaphore(value: 0)
        deliveryQueue.async { gate.wait() }
        let failed = expectation(description: "downstream failure")
        let recorder = CodexDeliveryRecorder { _ in }
        let pump = CodexAppServerStreamPump(
            configuration: configuration(
                maxPendingDeliveries: 4,
                maxDeliveryBatch: 1,
                deliveryCoalescingInterval: 0
            ),
            workerQueue: worker,
            deliveryQueue: deliveryQueue,
            onDelivery: { recorder.record($0) },
            onFailure: {
                recorder.record(failure: $0)
                failed.fulfill()
            }
        )
        let stream = (1...10).map {
            "{\"id\":\($0),\"result\":{\"ok\":true}}\n"
        }.joined()

        XCTAssertTrue(pump.ingest(Data(stream.utf8)))
        worker.sync {}
        gate.signal()

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(recorder.failure, .deliveryOverflow(limit: 4))
    }

    func testEOFWithPartialMessageFailsExplicitly() {
        let worker = DispatchQueue(label: "test.codex.worker.eof")
        let failed = expectation(description: "truncated failure")
        let recorder = CodexDeliveryRecorder { _ in }
        let pump = CodexAppServerStreamPump(
            configuration: configuration(deliveryCoalescingInterval: 0),
            workerQueue: worker,
            deliveryQueue: DispatchQueue(label: "test.codex.delivery.eof"),
            onDelivery: { recorder.record($0) },
            onFailure: {
                recorder.record(failure: $0)
                failed.fulfill()
            }
        )

        XCTAssertTrue(pump.ingest(Data(#"{"method":"turn/started"}"#.utf8)))
        pump.finish()

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(recorder.failure, .truncatedMessage)
    }

    func testStderrTailRetainsOnlyBoundedSuffix() {
        let tail = CodexAppServerStderrTail(maxBytes: 5)
        tail.append(Data("abcdef".utf8))
        tail.append(Data("gh".utf8))
        XCTAssertEqual(tail.snapshot(), "defgh")
    }

    private func configuration(
        maxChunkBytes: Int = 64 * 1_024,
        maxMessageBytes: Int = 16 * 1_024,
        maxBufferedBytes: Int = 64 * 1_024,
        maxPendingIngressBytes: Int = 128 * 1_024,
        maxPendingChunks: Int = 16,
        maxPendingDeliveries: Int = 16,
        maxDeliveryBatch: Int = 8,
        deliveryCoalescingInterval: TimeInterval
    ) -> CodexAppServerStreamConfiguration {
        CodexAppServerStreamConfiguration(
            maxChunkBytes: maxChunkBytes,
            maxMessageBytes: maxMessageBytes,
            maxBufferedBytes: maxBufferedBytes,
            maxPendingIngressBytes: maxPendingIngressBytes,
            maxPendingChunks: maxPendingChunks,
            maxPendingDeliveries: maxPendingDeliveries,
            maxDeliveryBatch: maxDeliveryBatch,
            compactionThresholdBytes: 32,
            deliveryCoalescingInterval: deliveryCoalescingInterval
        )
    }
}

private func recorderResponseCount(values: [CodexAppServerDelivery]) -> Int {
    values.filter {
        if case .response = $0 { return true }
        return false
    }.count
}

/// A lock-guarded running total for observers that cannot read the recorder
/// they are being installed into.
private final class CodexResponseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    /// Adds to the running total and returns the new value.
    @discardableResult
    func add(_ count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        total += count
        return total
    }
}

private final class CodexDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDeliveries: [CodexAppServerDelivery] = []
    private var recordedFailure: CodexAppServerStreamError?
    private var recordedMaximumBatchSize = 0
    private let afterRecord: @Sendable ([CodexAppServerDelivery]) -> Void

    init(afterRecord: @escaping @Sendable ([CodexAppServerDelivery]) -> Void) {
        self.afterRecord = afterRecord
    }

    func record(_ values: [CodexAppServerDelivery]) {
        lock.lock()
        recordedDeliveries.append(contentsOf: values)
        recordedMaximumBatchSize = max(recordedMaximumBatchSize, values.count)
        lock.unlock()
        afterRecord(values)
    }

    func record(failure: CodexAppServerStreamError) {
        lock.lock()
        recordedFailure = failure
        lock.unlock()
    }

    var deliveries: [CodexAppServerDelivery] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDeliveries
    }

    var failure: CodexAppServerStreamError? {
        lock.lock()
        defer { lock.unlock() }
        return recordedFailure
    }

    var maximumBatchSize: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedMaximumBatchSize
    }
}
