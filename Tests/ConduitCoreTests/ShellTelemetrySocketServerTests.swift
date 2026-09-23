#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import ConduitCore

final class ShellTelemetrySocketServerTests: XCTestCase {
    func testPrivateZshHooksAuthenticatePeerAndRejectForgedOrOutOfOrderFrames() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-shell-socket-test-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let taskID = TaskSessionID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let runtimeID = RuntimeAttemptID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let collector = ShellTelemetryEventCollector()
        let received = expectation(description: "validated shell events")
        received.assertForOverFulfill = false
        collector.onFourEvents = { received.fulfill() }

        let server = ShellTelemetrySocketServer(
            taskSessionID: taskID,
            runtimeAttemptID: runtimeID,
            originalZdotdir: home.path
        ) { event in
            collector.append(event)
        }
        defer { server.stop() }
        let configuration = try server.start()
        let profileDirectory = try XCTUnwrap(
            configuration.environment.first(where: { $0.hasPrefix("ZDOTDIR=") })
                .map { String($0.dropFirst("ZDOTDIR=".count)) }
        )
        let profileFiles = try FileManager.default.contentsOfDirectory(
            atPath: profileDirectory
        )
        for name in profileFiles where name.hasPrefix(".") {
            let path = URL(fileURLWithPath: profileDirectory).appendingPathComponent(name).path
            try runZshSyntaxCheck(path)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let profileText = try String(
            contentsOf: URL(fileURLWithPath: profileDirectory).appendingPathComponent(".zshenv"),
            encoding: .utf8
        )
        let socketPath = try zshAssignment("socket", in: profileText)
        let token = try zshAssignment("token", in: profileText)
        let taskString = taskID.rawValue.uuidString
        let runtimeString = runtimeID.rawValue.uuidString
        let peerPID = Int32(getpid())

        XCTAssertFalse(try sendFrame(
            to: socketPath,
            token: "wrong-token",
            taskID: taskString,
            runtimeID: runtimeString,
            executionID: configuration.executionID,
            shellPID: peerPID
        ))
        XCTAssertFalse(try sendFrame(
            to: socketPath,
            token: token,
            taskID: UUID().uuidString,
            runtimeID: runtimeString,
            executionID: configuration.executionID,
            shellPID: peerPID
        ))
        XCTAssertFalse(try sendFrame(
            to: socketPath,
            token: token,
            taskID: taskString,
            runtimeID: UUID().uuidString,
            executionID: configuration.executionID,
            shellPID: peerPID
        ))
        XCTAssertFalse(try sendFrame(
            to: socketPath,
            token: token,
            taskID: taskString,
            runtimeID: runtimeString,
            executionID: UUID().uuidString,
            shellPID: peerPID
        ))
        XCTAssertFalse(try sendFrame(
            to: socketPath,
            token: token,
            taskID: taskString,
            runtimeID: runtimeString,
            executionID: configuration.executionID,
            shellPID: peerPID + 1
        ))
        XCTAssertFalse(try sendFrame(
            to: socketPath,
            token: token,
            taskID: taskString,
            runtimeID: runtimeString,
            executionID: configuration.executionID,
            shellPID: peerPID,
            phase: "command_started",
            commandSequence: 1
        ))

        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = [
            "-l", "-i", "-c",
            "_conduit_shell_preexec; : 'private-command-secret'; false; _conduit_shell_precmd",
        ]
        zsh.environment = ProcessInfo.processInfo.environment.merging(
            Dictionary(uniqueKeysWithValues: configuration.environment.map {
                let separator = $0.firstIndex(of: "=")!
                return (
                    String($0[..<separator]),
                    String($0[$0.index(after: separator)...])
                )
            }).merging(
                ["HOME": home.path, "TERM": "dumb"],
                uniquingKeysWith: { _, new in new }
            ),
            uniquingKeysWith: { _, new in new }
        )
        zsh.standardInput = FileHandle.nullDevice
        zsh.standardOutput = FileHandle.nullDevice
        let zshError = Pipe()
        zsh.standardError = zshError
        let zshExited = expectation(description: "qualification zsh exited")
        zsh.terminationHandler = { _ in zshExited.fulfill() }
        try zsh.run()
        await fulfillment(of: [zshExited, received], timeout: 5)

        let events = collector.events
        let diagnostic = String(
            decoding: zshError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(zsh.terminationStatus, 0, diagnostic)
        XCTAssertEqual(
            events.map(\.phase),
            [.executionStarted, .commandStarted, .commandExited, .shellExited]
        )
        guard events.count == 4 else { return }
        XCTAssertTrue(events.allSatisfy {
            $0.runtimeAttemptID == runtimeString
                && $0.shellExecutionID == configuration.executionID
                && $0.observation.authority == .shellHookObserved
                && $0.observation.freshness == .current
        })
        XCTAssertEqual(events[1].commandID, "\(configuration.executionID):1")
        XCTAssertEqual(events[1].deliveryTransport.value, .shellStdin)
        XCTAssertEqual(events[2].commandID, "\(configuration.executionID):1")
        XCTAssertEqual(events[2].exitStatus.value, 1)
        XCTAssertFalse(String(describing: events).contains("private-command-secret"))
    }

    func testLiveShellOpenCodeSessionCorrelationWhenIsolatedFixtureConfigured() async throws {
        guard let sessionID = ProcessInfo.processInfo.environment[
            "CONDUIT_SLICE9_OPENCODE_SESSION_ID"
        ],
        let isolatedRootPath = ProcessInfo.processInfo.environment[
            "CONDUIT_SLICE9_LIVE_ROOT"
        ] else {
            throw XCTSkip("No qualification-owned isolated OpenCode fixture was configured.")
        }

        let isolatedRoot = URL(fileURLWithPath: isolatedRootPath, isDirectory: true)
            .standardizedFileURL
        XCTAssertTrue(isolatedRoot.path.hasPrefix("/tmp/conduit-slice9-live-"))
        let home = isolatedRoot.appendingPathComponent("home", isDirectory: true)
        let data = isolatedRoot.appendingPathComponent("data", isDirectory: true)
        let config = isolatedRoot.appendingPathComponent("config", isDirectory: true)
        let cache = isolatedRoot.appendingPathComponent("cache", isDirectory: true)
        let project = isolatedRoot.appendingPathComponent("project", isDirectory: true)
        let shellHome = isolatedRoot.appendingPathComponent("shell-home", isDirectory: true)
        for directory in [home, data, config, cache, project, shellHome] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let initialTransport = OpenCodeSQLiteObservationTransport(
            environment: ["XDG_DATA_HOME": data.path],
            homeDirectory: home
        )
        let initialObserver = OpenCodeProviderSessionObserver(
            transport: initialTransport
        )
        XCTAssertTrue(
            try initialObserver.listSessions().contains {
                $0.providerSessionID.value == sessionID
            },
            "The isolated provider persistence must contain the exact qualification session before launching Shell."
        )

        let taskID = TaskSessionID()
        let runtimeID = RuntimeAttemptID()
        let collector = ShellTelemetryEventCollector()
        let shellStarted = expectation(description: "live qualification shell started")
        let commandStarted = expectation(description: "live OpenCode command started")
        for expectation in [shellStarted, commandStarted] {
            expectation.assertForOverFulfill = false
        }
        collector.onEvent = { event in
            switch event.phase {
            case .executionStarted: shellStarted.fulfill()
            case .commandStarted: commandStarted.fulfill()
            case .commandExited, .shellExited:
                break
            case .directoryChanged: break
            }
        }

        let server = ShellTelemetrySocketServer(
            taskSessionID: taskID,
            runtimeAttemptID: runtimeID,
            originalZdotdir: shellHome.path
        ) { event in
            collector.append(event)
        }
        defer { server.stop() }
        let configuration = try server.start()

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let discard: @Sendable (FileHandle) -> Void = { handle in
            _ = handle.availableData
        }
        output.fileHandleForReading.readabilityHandler = discard
        errors.fileHandleForReading.readabilityHandler = discard

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        shell.arguments = ["-q", "/dev/null", "/bin/zsh", "-l", "-i"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["XDG_DATA_HOME"] = data.path
        environment["XDG_CONFIG_HOME"] = config.path
        environment["XDG_CACHE_HOME"] = cache.path
        environment["OPENCODE_CONFIG_DIR"] = config.path
        environment["TERM"] = "xterm-256color"
        environment["SHELL"] = "/bin/zsh"
        for entry in configuration.environment {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<separator])] = String(
                entry[entry.index(after: separator)...]
            )
        }
        shell.environment = environment
        shell.currentDirectoryURL = project
        shell.standardInput = input
        shell.standardOutput = output
        shell.standardError = errors
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            if shell.isRunning {
                try? input.fileHandleForWriting.write(contentsOf: Data([0x03]))
                usleep(150_000)
                try? input.fileHandleForWriting.write(contentsOf: Data("exit\n".utf8))
                for _ in 0..<30 where shell.isRunning {
                    usleep(100_000)
                }
                if shell.isRunning {
                    shell.terminate()
                    for _ in 0..<20 where shell.isRunning {
                        usleep(100_000)
                    }
                }
            }
            try? input.fileHandleForWriting.close()
        }

        try shell.run()
        await fulfillment(of: [shellStarted], timeout: 8)
        try input.fileHandleForWriting.write(contentsOf: Data(
            "opencode --session \(sessionID)\n".utf8
        ))
        await fulfillment(of: [commandStarted], timeout: 8)

        let command = try XCTUnwrap(
            collector.events.last(where: { $0.phase == .commandStarted })
        )
        let providerTransport = OpenCodeSQLiteObservationTransport(
            environment: ["XDG_DATA_HOME": data.path],
            homeDirectory: home
        )
        let providerObserver = OpenCodeProviderSessionObserver(
            transport: providerTransport
        )
        let providerRows = try providerObserver.listSessions()
        let providerSessionIDs = providerRows.compactMap(\.providerSessionID.value)
        let providerStamp = providerRows.contains(where: {
            $0.providerSessionID.value == sessionID
        }) ? SupervisionObservationStamp(
            authority: .providerObserved,
            freshness: .current,
            observedAt: .known(Date())
        ) : SupervisionObservationStamp(
            authority: .unknown,
            freshness: .unknown,
            observedAt: .unknown
        )

        let deadline = Date().addingTimeInterval(12)
        var processTree: ProcessTreeObservation?
        var correlation: ShellProviderCorrelation?
        var matchedWorker: WorkerLineage?
        while Date() < deadline {
            let tree = MacOSProcessTreeObserver.observe(
                rootPID: pid_t(command.shellPID),
                taskSessionID: taskID.rawValue.uuidString,
                runtimeAttemptID: runtimeID.rawValue.uuidString,
                prior: processTree
            )
            processTree = tree
            let nodes = [tree.launcher.value].compactMap { $0 } + tree.descendants
            let candidates = nodes.compactMap { node -> ShellOpenCodeProcessCandidate? in
                guard node.commandName.value?.lowercased() == "opencode",
                      let arguments = MacOSProcessTreeObserver.arguments(for: node)
                else { return nil }
                return ShellOpenCodeProcessCandidate(node: node, arguments: arguments)
            }
            let result = ShellProviderCorrelationResolver.resolve(
                taskSessionID: taskID.rawValue.uuidString,
                runtimeAttemptID: runtimeID.rawValue.uuidString,
                shellExecutionID: command.shellExecutionID,
                processCandidates: candidates,
                processTree: tree,
                providerSessionIDs: .known(providerSessionIDs),
                providerObservation: providerStamp
            )
            correlation = result
            matchedWorker = providerRows.first(where: {
                $0.providerSessionID.value == result.providerSessionID.value
            })
            if result.kind == .exact { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let exactCorrelation = try XCTUnwrap(
            correlation,
            "The process observer did not produce a Shell correlation result."
        )
        let exactTree = try XCTUnwrap(processTree)
        let observedProcessSummary = ([exactTree.launcher.value].compactMap { $0 }
            + exactTree.descendants).map { node in
                "pid=\(node.pid),name=\(node.commandName.value ?? "UNKNOWN"),"
                    + "ppid=\(node.parentPID.value.map(String.init) ?? "UNKNOWN"),"
                    + "ownership=\(node.ownership.rawValue),life=\(node.liveness.rawValue)"
            }.joined(separator: "; ")
        XCTAssertEqual(
            exactCorrelation.kind,
            .exact,
            exactCorrelation.diagnostics.joined(separator: "; ")
                + " Observed owned process tree: \(observedProcessSummary)"
                + " Provider rows=\(providerSessionIDs.count), exact session count="
                + "\(providerSessionIDs.filter { $0 == sessionID }.count), provider stamp="
                + "\(providerStamp.authority.rawValue)/\(providerStamp.freshness.rawValue), "
                + "candidate sessions=\(exactCorrelation.candidateSessionIDs)."
        )
        guard exactCorrelation.kind == .exact else {
            collector.onEvent = nil
            return
        }
        XCTAssertEqual(exactCorrelation.providerSessionID.value, sessionID)
        XCTAssertEqual(exactCorrelation.taskSessionID.value, taskID.rawValue.uuidString)
        XCTAssertEqual(exactCorrelation.runtimeAttemptID.value, runtimeID.rawValue.uuidString)
        XCTAssertEqual(exactCorrelation.shellExecutionID.value, command.shellExecutionID)

        let providerPID = try XCTUnwrap(exactCorrelation.processPID.value)
        let providerNode = try XCTUnwrap(exactTree.descendants.first(where: {
            $0.pid == providerPID
        }))
        XCTAssertEqual(providerNode.ownership, .taskCreated)
        XCTAssertEqual(providerNode.liveness, .live)
        XCTAssertEqual(providerNode.parentPID.value, command.shellPID)
        XCTAssertTrue(
            ShellProviderCorrelationResolver.isOpenCodeProcessName(
                providerNode.commandName.value
            )
        )
        XCTAssertEqual(command.deliveryTransport.value, .shellStdin)
        XCTAssertEqual(providerStamp.authority, .providerObserved)
        XCTAssertEqual(providerStamp.freshness, .current)

        let taskEvents = collector.events.map { event in
            TaskSessionEvent(
                taskSessionID: taskID,
                occurredAt: event.observation.observedAt.value ?? Date(),
                recordedAt: event.observation.observedAt.value ?? Date(),
                authority: .shellHookObserved,
                kind: .shellTelemetryRecorded(event)
            )
        } + [TaskSessionEvent(
            taskSessionID: taskID,
            authority: .processObserved,
            kind: .shellProcessObservationRecorded(exactTree)
        )]
        let history = try XCTUnwrap(
            ShellTelemetryProjection.latest(taskSessionID: taskID, events: taskEvents)
        )
        XCTAssertEqual(
            history.commandState(liveRuntimeAttemptID: runtimeID.rawValue.uuidString),
            .active
        )

        let fleetShell = FleetShellTelemetrySnapshot(
            runtimeAttemptID: .known(runtimeID.rawValue.uuidString),
            shellExecutionID: .known(command.shellExecutionID),
            phase: .known(history.latestEvent.phase),
            commandID: .known(command.commandID ?? ""),
            commandState: .known(history.commandState(
                liveRuntimeAttemptID: runtimeID.rawValue.uuidString
            )),
            shellPID: .known(command.shellPID),
            processGroupID: command.processGroupID,
            workingDirectory: command.workingDirectory,
            exitStatus: command.exitStatus,
            deliveryTransport: command.deliveryTransport,
            ptyCaptureQuiet: .unknown,
            launcherLiveness: exactTree.launcher.value.map {
                .known($0.liveness)
            } ?? .unknown,
            processObservation: .known(exactTree),
            observation: history.observationStamp(
                liveRuntimeAttemptID: runtimeID.rawValue.uuidString
            )
        )
        XCTAssertEqual(fleetShell.commandState.value, .active)
        XCTAssertEqual(fleetShell.ptyCaptureQuiet.state, .unknown)
        let worker = try XCTUnwrap(matchedWorker)
        let fleetProviderRow = ConduitFleetProviderWorkerSnapshot(
            worker: worker,
            writerAuthority: ProviderSessionAuthoritySnapshot(
                providerID: "opencode",
                providerSessionID: sessionID,
                conduitWriterState: .unclaimed,
                writerControllerID: .unknown
            ),
            writerAuthorityObservation: SupervisionObservationStamp(
                authority: .unknown,
                freshness: .unknown,
                observedAt: .unknown
            ),
            taskAssociation: FleetTaskAssociation(
                kind: .unbound,
                taskSessionID: .unknown,
                runtimeAttemptID: .unknown,
                observation: worker.observation
            ),
            shellCorrelation: exactCorrelation
        )
        let providerPage = ConduitFleetSnapshotBuilder.providerPage(
            items: [fleetProviderRow],
            cursor: nil,
            limit: 10,
            observedAt: Date()
        )
        XCTAssertEqual(providerPage.items.first?.shellCorrelation?.kind, .exact)
        XCTAssertEqual(providerPage.items.first?.worker.providerSessionID.value, sessionID)
        XCTAssertEqual(providerPage.items.first?.taskAssociation.kind, .unbound)
        XCTAssertEqual(providerPage.items.first?.writerAuthority.conduitWriterState, .unclaimed)

        let receipt: [String: Any] = [
            "qualification": "PASS_FOR_SHELL_PROVIDER_TELEMETRY_CORRELATION",
            "fixture": "isolated OpenCode persistence and temporary home",
            "task_session_id": taskID.rawValue.uuidString,
            "runtime_attempt_id": runtimeID.rawValue.uuidString,
            "shell_execution_id": command.shellExecutionID,
            "shell_command_id": command.commandID ?? "UNKNOWN",
            "delivery_transport": command.deliveryTransport.value?.rawValue ?? "UNKNOWN",
            "shell_pid": command.shellPID,
            "shell_pgid": command.processGroupID.value ?? 0,
            "cwd": command.workingDirectory.value ?? "UNKNOWN",
            "command_state": fleetShell.commandState.value?.rawValue ?? "UNKNOWN",
            "command_exit_status": "UNKNOWN while exact provider process remains active",
            "process_tree_coverage": exactTree.coverage.rawValue,
            "provider_process_pid": providerPID,
            "provider_process_name": providerNode.commandName.value ?? "UNKNOWN",
            "provider_process_parent_pid": providerNode.parentPID.value ?? 0,
            "provider_process_group_id": providerNode.processGroupID.value ?? 0,
            "provider_process_ownership_basis": providerNode.ownershipBasis.rawValue,
            "provider_process_ownership": providerNode.ownership.rawValue,
            "provider_process_liveness": providerNode.liveness.rawValue,
            "provider_process_start_time": providerNode.startIdentity.value?.startTime.value
                .map(ISO8601DateFormatter().string(from:)) ?? "UNKNOWN",
            "provider_process_command_id": exactCorrelation.commandID.value ?? "UNKNOWN",
            "provider_session_id": sessionID,
            "provider_session_presence": "observed once in current read-only persistence inventory",
            "provider_persistence_exact_count": providerSessionIDs.filter { $0 == sessionID }.count,
            "provider_persisted_turn_count": worker.turns.count,
            "provider_persistence_snapshot_freshness": providerStamp.freshness.rawValue,
            "provider_worker_live_freshness": worker.observation.freshness.rawValue,
            "correlation_kind": exactCorrelation.kind.rawValue,
            "fleet_provider_row_correlation": providerPage.items.first?.shellCorrelation?.kind.rawValue ?? "UNKNOWN",
            "task_association": providerPage.items.first?.taskAssociation.kind.rawValue ?? "UNKNOWN",
            "conduit_writer_state": providerPage.items.first?.writerAuthority.conduitWriterState.rawValue ?? "UNKNOWN",
            "pty_capture_quiet": "UNKNOWN",
            "provider_turn_state": "UNKNOWN",
            "repository_checkpoint": "UNKNOWN; isolated fixture is not a repository",
            "provider_host_liveness": "UNKNOWN",
            "conduit_task_complete": "UNKNOWN",
            "objective_accepted": "UNKNOWN",
            "command_text_recorded": false,
            "pty_content_recorded": false
        ]
        let receiptData = try JSONSerialization.data(
            withJSONObject: receipt,
            options: [.prettyPrinted, .sortedKeys]
        )
        try receiptData.write(
            to: isolatedRoot.appendingPathComponent("shell-correlation-receipt.json"),
            options: .atomic
        )

    }

    private func runZshSyntaxCheck(_ path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorOutput = Pipe()
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(
            decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
    }

    private func zshAssignment(_ name: String, in source: String) throws -> String {
        let prefix = "typeset -g _conduit_shell_\(name)="
        guard let line = source.components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix(prefix) }),
              line.hasSuffix("'")
        else { throw NSError(domain: "ShellTelemetrySocketServerTests", code: 1) }
        return String(line.dropFirst(prefix.count + 1).dropLast())
    }

    private func sendFrame(
        to path: String,
        token: String,
        taskID: String,
        runtimeID: String,
        executionID: String,
        shellPID: Int32,
        phase: String = "execution_started",
        commandSequence: Int? = nil
    ) throws -> Bool {
        var object: [String: Any] = [
            "token": token,
            "taskSessionID": taskID,
            "runtimeAttemptID": runtimeID,
            "shellExecutionID": executionID,
            "phase": phase,
            "shellPID": shellPID,
            "workingDirectory": "/tmp/forged",
        ]
        if let commandSequence { object["commandSequence"] = commandSequence }
        var bytes = try JSONSerialization.data(withJSONObject: object)
        bytes.append(0x0A)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count + 1 < MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: "ShellTelemetrySocketServerTests", code: 2)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            storage.initializeMemory(as: UInt8.self, repeating: 0)
            storage.copyBytes(from: pathBytes)
        }
        address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        defer { Darwin.close(fd) }
        let sent = bytes.withUnsafeBytes { buffer in
            Darwin.send(fd, buffer.baseAddress, buffer.count, 0)
        }
        guard sent == bytes.count else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        Darwin.shutdown(fd, SHUT_WR)
        var response = [UInt8](repeating: 0, count: 2)
        let received = response.withUnsafeMutableBytes { buffer in
            Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
        }
        return received == 2 && response == [0x31, 0x0A]
    }
}

private final class ShellTelemetryEventCollector {
    private let lock = NSLock()
    private var storedEvents: [ShellTelemetryEvent] = []
    private var didSignalFourEvents = false
    var onFourEvents: (() -> Void)?
    var onEvent: ((ShellTelemetryEvent) -> Void)?

    var events: [ShellTelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func append(_ event: ShellTelemetryEvent) {
        lock.lock()
        storedEvents.append(event)
        let callback = storedEvents.count >= 4 && !didSignalFourEvents
            ? onFourEvents : nil
        let eventCallback = onEvent
        if callback != nil { didSignalFourEvents = true }
        lock.unlock()
        callback?()
        eventCallback?(event)
    }
}
#endif
