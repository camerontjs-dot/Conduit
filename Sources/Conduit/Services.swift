#if os(macOS)
import AppKit
import AVFoundation
import ConduitCore
import Foundation
import Speech
import SwiftTerm
import SwiftUI

final class ActivityTerminalView: LocalProcessTerminalView {
    /// Reports observed byte volume after SwiftTerm has interpreted the chunk.
    /// Rendered snapshots are coalesced separately; translating the entire
    /// buffer for every PTY read makes long streams quadratic in practice.
    var onOutput: ((Int) -> Void)?
    /// Direct SwiftTerm keyboard/mouse input only. Native composer delivery
    /// writes to `process` or tmux out of band and intentionally bypasses this.
    var onDirectRawInput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?(slice.count)
    }

    override func send(
        source: TerminalView,
        data: ArraySlice<UInt8>
    ) {
        onDirectRawInput?()
        super.send(source: source, data: data)
    }

    /// SwiftTerm's rendered active surface. Direct PTYs may include their
    /// bounded normal-buffer scrollback; the strict reducer always compares it
    /// with a same-source baseline before any text can reach Conversation.
    func renderedSnapshot() -> String {
        let terminal = getTerminal()
        let kind: Terminal.BufferKind = terminal.isCurrentBufferAlternate
            ? .active
            : .normal
        return String(
            decoding: terminal.getBufferAsData(kind: kind),
            as: UTF8.self
        )
    }

    /// A fallback that provably contains no scrollback. SwiftTerm's alternate
    /// buffer has only the active screen; its normal buffer may include prior
    /// history and is therefore never used to replace a failed tmux capture.
    func scrollbackFreeRenderedSnapshot() -> String? {
        let terminal = getTerminal()
        guard terminal.isCurrentBufferAlternate else { return nil }
        return String(
            decoding: terminal.getBufferAsData(kind: .active),
            as: UTF8.self
        )
    }
}

@MainActor
final class TerminalSessionController: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let descriptor: SessionDescriptor
    let terminalView: ActivityTerminalView

    @Published private(set) var lifecycle: SessionLifecycle = .idle {
        didSet {
            guard lifecycle.isTerminal else { return }
            onTerminalBoundary?()
            recordObservedUsage()
        }
    }
    @Published private(set) var launchIssue: TerminalLaunchIssue?
    @Published private(set) var terminalTitle: String
    @Published private(set) var lastOutputAt: Date?
    private(set) var usesTmux = false
    private(set) var tmuxSessionName: String?

    // MARK: - Tier A observed usage
    //
    // Counters over what Conduit itself saw. Nothing here is read from the
    // agent's own records, and output bytes are rendered volume — not tokens
    // and not a proxy for them.
    private(set) var observedOutputBytes = 0
    private(set) var observedPromptsDelivered = 0
    private(set) var observedPromptsFailed = 0
    private(set) var attachedAt: Date?
    /// Set once the terminal record has been emitted, so detach-then-exit or a
    /// double transition cannot bank the same session twice.
    private var usageRecorded = false
    /// Invoked once per session with what Conduit observed. The controller
    /// stays unaware of where it is written.
    var onUsageRecord: ((SessionUsageRecord) -> Void)?
    /// Called only when durable attach is intentionally blocked. The AppModel
    /// may surface this later without inferring failure from terminal prose.
    var onLaunchIssue: ((TerminalLaunchIssue) -> Void)?

    private let useDetachedSessions: Bool

    /// One prompt awaiting delivery, with an optional MainActor completion that
    /// reports whether the bytes actually reached the session.
    private struct PendingPrompt {
        let text: String
        let submit: Bool
        let willDeliver: ((RawDerivedCapture) -> Void)?
        let completion: ((Bool) -> Void)?
    }

    /// A session is "ready" for input once its output has quiesced after first
    /// appearing — i.e. the agent has printed its banner and gone quiet, by
    /// which point it has enabled bracketed paste. Gating on first *byte* is
    /// wrong: for tmux that byte is the attach redraw, long before the agent
    /// is listening, so a multiline prompt would land raw and split-submit.
    private var isReadyForInput = false
    private var firstOutputAt: Date?
    private var pendingPrompts: [PendingPrompt] = []
    /// Exactly one prompt write may own the next rendered-output boundary.
    /// Later prompts stay queued until that write observes a quiet boundary or
    /// the bounded hard cap expires. Neither condition is agent completion.
    private var deliveryWriteInProgress = false
    private var awaitingPromptOutputBoundary = false
    private var promptBoundaryStartedAt: Date?
    private var promptBoundaryFirstOutputAt: Date?
    private var promptBoundaryWorkItem: DispatchWorkItem?
    private var conversationCaptureExtraction: AgentOutputExtraction?
    /// Serial queue: tmux delivery is three blocking subprocess calls; running
    /// them here (never overlapping, FIFO) keeps back-to-back prompts from
    /// interleaving into one merged or reordered message, and keeps the waits
    /// off the cooperative pool.
    private let deliveryQueue = DispatchQueue(label: "dev.camerontjs.conduit.delivery")
    private let captureQueue = DispatchQueue(label: "dev.camerontjs.conduit.capture")
    private var deliveryCompletions: [UUID: (Bool) -> Void] = [:]
    private var paneCaptureScheduled = false
    private var paneCaptureNeedsFollowup = false
    private var renderedCaptureScheduled = false
    private var renderedCaptureNeedsFollowup = false
    private var lastAcceptedRenderedBuffer = ""
    private var lastAcceptedTmuxPane = ""

    /// Rendered terminal changes for the convenience Conversation projection.
    /// These callbacks never carry completion or verification authority.
    var onRenderedOutput: ((RawDerivedCapture) -> Void)?
    /// Direct input through the Raw SwiftTerm surface. The runtime should close
    /// or de-associate its active derived block before later output arrives.
    var onDirectRawInput: (() -> Void)?
    /// Lets the runtime close a live capture on a deterministic process
    /// boundary. A quiet terminal is deliberately not such a boundary.
    var onTerminalBoundary: (() -> Void)?

    private let readinessQuiescence: TimeInterval = 0.6
    private let readinessHardCap: TimeInterval = 8.0
    private let renderedCaptureInterval: TimeInterval = 0.08

    var isDetached: Bool { lifecycle == .detached }
    var exitCode: Int32? {
        if case .exited(let code) = lifecycle { return code }
        return nil
    }
    var backendLabel: String {
        if launchIssue != nil { return "blocked" }
        return usesTmux ? "tmux" : "PTY"
    }

    init(descriptor: SessionDescriptor, useDetachedSessions: Bool) {
        self.descriptor = descriptor
        self.useDetachedSessions = useDetachedSessions
        self.terminalTitle = descriptor.title
        self.terminalView = ActivityTerminalView(frame: .zero)
        super.init()
        terminalView.processDelegate = self
        terminalView.onOutput = { [weak self] byteCount in
            Task { @MainActor in
                self?.noteOutput(byteCount: byteCount)
            }
        }
        terminalView.onDirectRawInput = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Keep Conversation capture armed while the operator uses Raw.
                // Ending capture on every keystroke made surface switches and
                // slash menus break the turn stream. Capture still closes on
                // process boundaries and the next Conduit prompt delivery.
                self.onDirectRawInput?()
            }
        }
        terminalView.font = NSFont.monospacedSystemFont(ofSize: TerminalTheme.fontSize, weight: .regular)
        // System colours are only the pre-theme fallback; TerminalHostView
        // applies the palette as soon as the view is mounted.
        terminalView.nativeForegroundColor = NSColor.textColor
        terminalView.nativeBackgroundColor = NSColor.windowBackgroundColor
    }

    func startIfNeeded() {
        guard lifecycle == .idle else { return }
        launchIssue = nil
        lifecycle.transition(to: .launching)

        if useDetachedSessions, let tmux = EnvironmentResolver.shared.resolve("tmux") {
            // The descriptor carries the binding so a resumed session attaches
            // to the discovered name and a second instance gets its own.
            let name = descriptor.tmuxSessionName
                ?? TmuxSessionNaming.sessionName(
                    projectPath: descriptor.projectPath,
                    agentName: descriptor.agent.name,
                    instance: descriptor.instance
                )
            let driver = TmuxDriver(tmuxPath: tmux)
            // Session creation happens out-of-band and detached, so the
            // session deterministically exists before the client attaches
            // and before any prompt delivery.
            let ensureResult = driver.ensureSession(
                name: name,
                directory: descriptor.projectPath.path,
                command: paneCommand(),
                // Only stamp identity when Conduit actually knows it; a
                // resumed unidentified session keeps its blank record rather
                // than inheriting a placeholder name.
                projectPath: descriptor.recordsIdentity ? descriptor.projectPath.path : nil,
                agentName: descriptor.recordsIdentity ? descriptor.agent.name : nil,
                taskSessionID: descriptor.taskSessionID,
                // Only the explicit Resume path may adopt a discovered legacy
                // session. A generated-name collision is never permission.
                adoptUnboundExistingSession: descriptor.adoptsLegacyTaskSession == true,
                requireExistingSession: descriptor.requiresExistingTmuxSession == true
            )
            switch ensureResult {
            case .ready:
                attachedAt = Date()
                usesTmux = true
                tmuxSessionName = name
                terminalView.startProcess(
                    executable: tmux,
                    args: ["attach-session", "-t", "=\(name)"],
                    currentDirectory: descriptor.projectPath.path
                )
                terminalTitle = "\(descriptor.title) · durable"
                return
            case .directPTYFallback:
                break
            case .blocked(let issue):
                failLaunch(issue)
                return
            }
        } else if descriptor.requiresExistingTmuxSession == true {
            let name = descriptor.tmuxSessionName
                ?? descriptor.title
            failLaunch(.tmuxUnavailableForReconnect(sessionName: name))
            return
        }

        usesTmux = false
        attachedAt = Date()
        startDirectSession()
    }

    /// Delivers composer or forwarded text with paste semantics. Held until the
    /// session is ready (output quiesced) so prompts to a just-launched agent
    /// are neither dropped nor mangled. `completion(false)` fires if the bytes
    /// could not be delivered, so the caller can restore what the user typed.
    func deliverPrompt(
        _ text: String,
        submit: Bool = true,
        willDeliver: ((RawDerivedCapture) -> Void)? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        let normalized = PromptEncoder.normalized(text)
        guard !normalized.isEmpty else { completion?(true); return }
        // Refuse to swallow a prompt aimed at a session that has already ended.
        if lifecycle.isTerminal {
            completion?(false)
            return
        }
        startIfNeeded()
        // A blocked durable attach starts no replacement process. Report the
        // prompt as undelivered rather than leaving it queued forever.
        guard !lifecycle.isTerminal else {
            completion?(false)
            return
        }
        let prompt = PendingPrompt(
            text: normalized,
            submit: submit,
            willDeliver: willDeliver,
            completion: completion
        )
        pendingPrompts.append(prompt)
        drainPromptQueueIfPossible()
    }

    func interrupt() {
        guard lifecycle == .running || lifecycle == .launching else { return }
        let bytes = Array("\u{3}".utf8)
        terminalView.process.send(data: bytes[...])
    }

    /// Detach (tmux) or terminate (direct PTY). Does not kill a durable tmux
    /// session — relaunching the same agent will reconnect. Use `endSession`
    /// when the operator wants the process gone and a clean slate.
    func closeSession() {
        switch lifecycle {
        case .idle, .detached, .exited:
            return
        case .launching, .running:
            break
        }
        failPendingPrompts()
        if usesTmux, let name = tmuxSessionName {
            lifecycle.transition(to: .detached)
            if let tmux = EnvironmentResolver.shared.resolve("tmux") {
                let driver = TmuxDriver(tmuxPath: tmux)
                Task.detached(priority: .userInitiated) {
                    driver.detachClients(session: name)
                }
            }
            // The attach client exits once the server detaches it; this is a
            // fallback in case the detach command could not reach the server.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.lifecycle == .detached else { return }
                self.terminalView.terminate()
            }
        } else {
            flushRenderedBufferCapture(
                requiresScrollbackFreeBuffer: false
            )
            terminate()
        }
    }

    /// Kill the underlying process (and durable tmux session when present) so
    /// the next launch creates a brand-new session instead of reconnecting.
    @discardableResult
    func endSession() -> Bool {
        failPendingPrompts()
        let runtimeEnded: Bool
        if usesTmux {
            if let name = tmuxSessionName,
               let tmux = EnvironmentResolver.shared.resolve("tmux") {
                // Kill first so has-session during processTerminated sees
                // "gone", and keep the result honest when tmux is unreachable.
                runtimeEnded = TmuxDriver(tmuxPath: tmux).killSession(name)
            } else {
                runtimeEnded = false
            }
        } else {
            runtimeEnded = true
        }

        let terminalState: SessionLifecycle = runtimeEnded
            ? .exited(code: nil)
            : .detached
        // Detach→exited is blocked on the state machine (receipt honesty);
        // an explicit operator action may force the terminal presentation
        // state after the out-of-band result has been classified.
        if lifecycle.isTerminal {
            lifecycle = terminalState
        } else if !lifecycle.transition(to: terminalState) {
            lifecycle = terminalState
        }
        terminalView.terminate()
        return runtimeEnded
    }

    func terminate() {
        guard lifecycle == .launching || lifecycle == .running else { return }
        terminalView.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.lifecycle.isTerminal else { return }
            self.lifecycle.transition(to: .exited(code: nil))
        }
    }

    func visualState(at date: Date) -> TerminalVisualState {
        if launchIssue != nil { return .failed }
        switch lifecycle {
        case .idle, .launching:
            return .launching
        case .detached:
            return .detached
        case .exited(let code):
            return (code ?? 0) != 0 ? .failed : .exited
        case .running:
            if let lastOutputAt, date.timeIntervalSince(lastOutputAt) < 1.8 {
                return .working
            }
            return .running
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.terminalTitle = title.isEmpty ? self.descriptor.title : title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.handleProcessTermination(exitCode: exitCode)
        }
    }

    private func handleProcessTermination(exitCode: Int32?) {
        // Already resolved (e.g. our own detach set .detached) — ignore.
        guard !lifecycle.isTerminal else { return }

        if usesTmux, let name = tmuxSessionName, let tmux = EnvironmentResolver.shared.resolve("tmux") {
            // The exit code here belongs to the tmux ATTACH CLIENT, not the
            // agent — a crashed agent and a clean detach both exit the client
            // 0. Resolve the truth out-of-band: if the session still exists the
            // client was detached externally; if it is gone the agent ended but
            // its real code is unknowable through the client.
            let driver = TmuxDriver(tmuxPath: tmux)
            deliveryQueue.async { [weak self] in
                let finalSnapshot = driver.capturePaneSnapshot(session: name)
                let presence = driver.sessionPresence(name)
                Task { @MainActor in
                    guard let self, !self.lifecycle.isTerminal else { return }
                    if self.conversationCaptureExtraction == .tmuxPane {
                        if let finalSnapshot {
                            self.acceptRenderedSnapshot(
                                finalSnapshot,
                                extraction: .tmuxPane
                            )
                        } else {
                            self.reportCaptureUnavailable(
                                .tmuxPaneCaptureFailed,
                                expected: .tmuxPane
                            )
                        }
                    } else if self.conversationCaptureExtraction
                                == .renderedBuffer {
                        self.flushRenderedBufferCapture(
                            requiresScrollbackFreeBuffer: true
                        )
                    }
                    switch presence {
                    case .present:
                        self.lifecycle.transition(to: .detached)
                    case .absent:
                        self.lifecycle.transition(to: .exited(code: nil))
                    case .unknown:
                        // The attach client ended, but a failed observation is
                        // not proof that the durable runtime ended. Preserve a
                        // reconnectable/unknown path rather than recording a
                        // false exit.
                        self.lifecycle.transition(to: .detached)
                    }
                    self.failPendingPrompts()
                }
            }
            return
        }

        // Direct PTY: SwiftTerm hands us the raw waitpid status; decode it so
        // the receipt records a real exit code, not 256 for a 1.
        flushRenderedBufferCapture(
            requiresScrollbackFreeBuffer: false
        )
        let decoded = exitCode.map { POSIXExitStatus.decode($0) }
        lifecycle.transition(to: .exited(code: decoded))
        failPendingPrompts()
    }

    // MARK: - Private

    private func failLaunch(_ issue: TerminalLaunchIssue) {
        launchIssue = issue
        onLaunchIssue?(issue)
        usesTmux = false
        tmuxSessionName = nil
        attachedAt = nil
        failPendingPrompts()
        lifecycle.transition(to: .exited(code: nil))
    }

    private func noteOutput(byteCount: Int) {
        observedOutputBytes += byteCount
        let observedAt = Date()
        lastOutputAt = observedAt
        if lifecycle == .launching {
            lifecycle.transition(to: .running)
        }

        if awaitingPromptOutputBoundary,
           promptBoundaryFirstOutputAt == nil {
            promptBoundaryFirstOutputAt = observedAt
        }

        switch conversationCaptureExtraction {
        case .tmuxPane:
            scheduleTmuxPaneCapture()
        case .renderedBuffer:
            scheduleRenderedBufferCapture(
                requiresScrollbackFreeBuffer: usesTmux
            )
        case .structuredAdapter, .none:
            break
        }

        guard firstOutputAt == nil else { return }
        firstOutputAt = observedAt
        scheduleReadinessCheck()
    }

    private func acceptRenderedSnapshot(
        _ snapshot: String,
        extraction: AgentOutputExtraction
    ) {
        guard conversationCaptureExtraction == extraction else { return }
        switch extraction {
        case .renderedBuffer:
            guard snapshot != lastAcceptedRenderedBuffer else { return }
            lastAcceptedRenderedBuffer = snapshot
        case .tmuxPane:
            guard snapshot != lastAcceptedTmuxPane else { return }
            lastAcceptedTmuxPane = snapshot
        case .structuredAdapter:
            return
        }
        onRenderedOutput?(
            .available(
                RawDerivedSnapshot(
                    text: snapshot,
                    extraction: extraction
                )
            )
        )
    }

    private func reportCaptureUnavailable(
        _ reason: RawDerivedCaptureUnavailableReason,
        expected extraction: AgentOutputExtraction
    ) {
        guard conversationCaptureExtraction == extraction else { return }
        conversationCaptureExtraction = nil
        onRenderedOutput?(.unavailable(reason))
    }

    /// Coalesces direct rendered-buffer translation to at most one pass per
    /// interval. A tmux fallback is allowed only while SwiftTerm is in its
    /// scrollback-free alternate buffer.
    private func scheduleRenderedBufferCapture(
        requiresScrollbackFreeBuffer: Bool
    ) {
        if renderedCaptureScheduled {
            renderedCaptureNeedsFollowup = true
            return
        }
        renderedCaptureScheduled = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + renderedCaptureInterval
        ) { [weak self] in
            guard let self else { return }
            let snapshot = requiresScrollbackFreeBuffer
                ? self.terminalView.scrollbackFreeRenderedSnapshot()
                : self.terminalView.renderedSnapshot()
            let followup = self.renderedCaptureNeedsFollowup
            self.renderedCaptureNeedsFollowup = false
            self.renderedCaptureScheduled = false

            if let snapshot {
                self.acceptRenderedSnapshot(
                    snapshot,
                    extraction: .renderedBuffer
                )
            } else {
                self.reportCaptureUnavailable(
                    .renderedFallbackMayIncludeHistory,
                    expected: .renderedBuffer
                )
            }
            if followup,
               self.conversationCaptureExtraction == .renderedBuffer {
                self.scheduleRenderedBufferCapture(
                    requiresScrollbackFreeBuffer:
                        requiresScrollbackFreeBuffer
                )
            }
        }
    }

    private func flushRenderedBufferCapture(
        requiresScrollbackFreeBuffer: Bool
    ) {
        guard conversationCaptureExtraction == .renderedBuffer else {
            return
        }
        let snapshot = requiresScrollbackFreeBuffer
            ? terminalView.scrollbackFreeRenderedSnapshot()
            : terminalView.renderedSnapshot()
        if let snapshot {
            acceptRenderedSnapshot(
                snapshot,
                extraction: .renderedBuffer
            )
        } else {
            reportCaptureUnavailable(
                .renderedFallbackMayIncludeHistory,
                expected: .renderedBuffer
            )
        }
    }

    /// The outer SwiftTerm is an alternate-screen tmux client, so its buffer
    /// has no useful pane scrollback. Capture a bounded rendered pane out of
    /// band on a throttled serial queue. Failure is explicit; it never falls
    /// back to an unbounded current-screen projection.
    private func scheduleTmuxPaneCapture() {
        guard usesTmux,
              let name = tmuxSessionName,
              let tmux = EnvironmentResolver.shared.resolve("tmux")
        else { return }
        if paneCaptureScheduled {
            paneCaptureNeedsFollowup = true
            return
        }
        paneCaptureScheduled = true
        let driver = TmuxDriver(tmuxPath: tmux)
        captureQueue.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            let snapshot = driver.capturePaneSnapshot(session: name)
            Task { @MainActor in
                guard let self else { return }
                let followup = self.paneCaptureNeedsFollowup
                self.paneCaptureNeedsFollowup = false
                self.paneCaptureScheduled = false
                if let snapshot {
                    self.acceptRenderedSnapshot(
                        snapshot,
                        extraction: .tmuxPane
                    )
                } else if !followup {
                    self.reportCaptureUnavailable(
                        .tmuxPaneCaptureFailed,
                        expected: .tmuxPane
                    )
                }
                if followup,
                   self.conversationCaptureExtraction == .tmuxPane {
                    self.scheduleTmuxPaneCapture()
                }
            }
        }
    }

    /// Polls output quiescence: once output has been idle for
    /// `readinessQuiescence` (or `readinessHardCap` has elapsed since the first
    /// byte), the session is ready and queued prompts flush.
    private func scheduleReadinessCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + readinessQuiescence) { [weak self] in
            guard let self, !self.isReadyForInput, let first = self.firstOutputAt else { return }
            guard !self.lifecycle.isTerminal else { return }
            let now = Date()
            let quietFor = now.timeIntervalSince(self.lastOutputAt ?? first)
            let sinceFirst = now.timeIntervalSince(first)
            if quietFor >= self.readinessQuiescence || sinceFirst >= self.readinessHardCap {
                self.becomeReadyForInput()
            } else {
                self.scheduleReadinessCheck()
            }
        }
    }

    private func becomeReadyForInput() {
        guard !isReadyForInput else { return }
        isReadyForInput = true
        drainPromptQueueIfPossible()
    }

    private func drainPromptQueueIfPossible() {
        guard isReadyForInput,
              !deliveryWriteInProgress,
              !awaitingPromptOutputBoundary,
              !lifecycle.isTerminal,
              !pendingPrompts.isEmpty
        else { return }
        deliveryWriteInProgress = true
        let prompt = pendingPrompts.removeFirst()
        enqueueDelivery(prompt)
    }

    /// Starts the one output boundary immediately before a serialized terminal
    /// write. Merely queueing a prompt never moves the boundary.
    private func beginPromptWrite(
        _ prompt: PendingPrompt,
        baseline: RawDerivedCapture
    ) {
        switch baseline {
        case .available(let snapshot):
            conversationCaptureExtraction = snapshot.extraction
        case .unavailable:
            conversationCaptureExtraction = nil
        }
        awaitingPromptOutputBoundary = true
        promptBoundaryStartedAt = Date()
        promptBoundaryFirstOutputAt = nil
        prompt.willDeliver?(baseline)
        schedulePromptBoundaryCheck()
    }

    private func directPromptBaseline() -> RawDerivedCapture {
        let snapshot = terminalView.renderedSnapshot()
        // Empty is still a valid same-surface baseline: first-prompt capture can
        // prompt-anchor once the agent paints, instead of refusing the boundary.
        return .available(
            RawDerivedSnapshot(
                text: snapshot,
                extraction: .renderedBuffer
            )
        )
    }

    /// Captures a bounded tmux pane on the delivery queue. Retries briefly so
    /// first-prompt cold starts are less likely to miss a painted pane. If
    /// tmux still cannot provide a non-empty pane, the permitted fallback is
    /// SwiftTerm's active alternate buffer. As a last resort an empty
    /// same-surface baseline is returned so Conversation can still open a
    /// prompt-anchored capture instead of hard-failing the boundary.
    private nonisolated static func tmuxPromptBaseline(
        driver: TmuxDriver,
        sessionName: String,
        safeRenderedFallback: () -> String?
    ) -> RawDerivedCapture {
        var lastEmptyPane: String?
        for attempt in 0..<3 {
            if let snapshot = driver.capturePaneSnapshot(session: sessionName) {
                if !snapshot.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                    return .available(
                        RawDerivedSnapshot(
                            text: snapshot,
                            extraction: .tmuxPane
                        )
                    )
                }
                lastEmptyPane = snapshot
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if let fallback = safeRenderedFallback(),
           !fallback.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            return .available(
                RawDerivedSnapshot(
                    text: fallback,
                    extraction: .renderedBuffer
                )
            )
        }
        if let lastEmptyPane {
            return .available(
                RawDerivedSnapshot(
                    text: lastEmptyPane,
                    extraction: .tmuxPane
                )
            )
        }
        // Keep the extraction surface stable so later pane snapshots can still
        // project with the prompt-anchored reducer instead of hard-failing.
        return .available(
            RawDerivedSnapshot(
                text: "",
                extraction: .tmuxPane
            )
        )
    }

    private func enqueueDelivery(_ prompt: PendingPrompt) {
        if usesTmux, let name = tmuxSessionName, let tmux = EnvironmentResolver.shared.resolve("tmux") {
            let id = UUID()
            if let completion = prompt.completion {
                deliveryCompletions[id] = completion
            }
            let driver = TmuxDriver(tmuxPath: tmux)
            let text = prompt.text
            let submit = prompt.submit
            deliveryQueue.async { [weak self] in
                let delivered = driver.paste(
                    session: name,
                    text: text,
                    submit: submit
                ) { [weak self] in
                    let baseline = Self.tmuxPromptBaseline(
                        driver: driver,
                        sessionName: name
                    ) {
                        DispatchQueue.main.sync { [weak self] in
                            self?.terminalView
                                .scrollbackFreeRenderedSnapshot()
                        }
                    }
                    return DispatchQueue.main.sync { [weak self] in
                        guard let self, !self.lifecycle.isTerminal else {
                            return false
                        }
                        self.beginPromptWrite(prompt, baseline: baseline)
                        return true
                    }
                }
                Task { @MainActor in self?.finishDelivery(id, delivered: delivered) }
            }
        } else {
            // Direct PTY writes must happen on the main actor (view access);
            // this is the exact serialized write boundary.
            beginPromptWrite(prompt, baseline: directPromptBaseline())
            let bracketed = terminalView.getTerminal().bracketedPasteMode
            let bytes = PromptEncoder.encode(text: prompt.text, bracketedPaste: bracketed, submit: prompt.submit)
            if !bytes.isEmpty {
                terminalView.process.send(data: bytes[...])
            }
            observedPromptsDelivered += 1
            prompt.completion?(true)
            deliveryWriteInProgress = false
        }
    }

    private func finishDelivery(_ id: UUID, delivered: Bool) {
        if delivered {
            observedPromptsDelivered += 1
        } else {
            observedPromptsFailed += 1
        }
        deliveryCompletions.removeValue(forKey: id)?(delivered)
        deliveryWriteInProgress = false
        if !delivered {
            cancelPromptOutputBoundary()
            drainPromptQueueIfPossible()
        } else if !awaitingPromptOutputBoundary {
            // The hard cap may have elapsed while a slow write command was
            // still returning. Do not strand the next serialized prompt.
            drainPromptQueueIfPossible()
        }
    }

    /// A delivery boundary becomes available after output has been quiet for
    /// the same bounded quiescence interval, or after the hard cap from the
    /// actual write. This serializes writes; it does not identify an agent turn
    /// or imply completion.
    private func schedulePromptBoundaryCheck() {
        promptBoundaryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.checkPromptOutputBoundary()
        }
        promptBoundaryWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + readinessQuiescence,
            execute: item
        )
    }

    private func checkPromptOutputBoundary() {
        guard awaitingPromptOutputBoundary,
              let started = promptBoundaryStartedAt,
              !lifecycle.isTerminal
        else { return }
        let now = Date()
        let sinceWrite = now.timeIntervalSince(started)
        let isQuiet: Bool
        if promptBoundaryFirstOutputAt != nil,
           let lastOutputAt {
            isQuiet = now.timeIntervalSince(lastOutputAt)
                >= readinessQuiescence
        } else {
            isQuiet = false
        }

        if isQuiet || sinceWrite >= readinessHardCap {
            cancelPromptOutputBoundary()
            drainPromptQueueIfPossible()
        } else {
            schedulePromptBoundaryCheck()
        }
    }

    private func cancelPromptOutputBoundary() {
        promptBoundaryWorkItem?.cancel()
        promptBoundaryWorkItem = nil
        awaitingPromptOutputBoundary = false
        promptBoundaryStartedAt = nil
        promptBoundaryFirstOutputAt = nil
    }

    private func failPendingPrompts() {
        let queued = pendingPrompts
        pendingPrompts = []
        for prompt in queued {
            observedPromptsFailed += 1
            prompt.completion?(false)
        }
        let inFlight = Array(deliveryCompletions.values)
        deliveryCompletions = [:]
        for completion in inFlight {
            observedPromptsFailed += 1
            completion(false)
        }
        deliveryWriteInProgress = false
        cancelPromptOutputBoundary()
        conversationCaptureExtraction = nil
    }

    /// Banks one observed-usage record for this session. Called on every
    /// terminal transition; the `usageRecorded` latch means detach-then-exit
    /// banks the detach only, and a session Conduit never attached to (no
    /// `attachedAt`) is not recorded at all rather than recorded as zero.
    private func recordObservedUsage() {
        guard !usageRecorded, let attachedAt else { return }
        let outcome: SessionUsageRecord.Outcome
        switch lifecycle {
        case .detached:
            outcome = .detached
        case .exited(let code):
            outcome = (code ?? 0) == 0 ? .exitedClean : .exitedFailed
        default:
            return
        }
        usageRecorded = true
        onUsageRecord?(
            SessionUsageRecord(
                agent: descriptor.agent.name,
                projectSlug: descriptor.projectPath.lastPathComponent,
                startedAt: attachedAt,
                endedAt: Date(),
                outcome: outcome,
                outputBytes: observedOutputBytes,
                promptsDelivered: observedPromptsDelivered,
                promptsFailed: observedPromptsFailed
            )
        )
    }

    private func startDirectSession() {
        let agent = descriptor.agent
        let launchArgs = AgentLaunchArguments.resolved(for: agent)
        if agent.kind == .shell && agent.command.hasPrefix("/") {
            terminalView.startProcess(
                executable: agent.command,
                args: launchArgs,
                currentDirectory: descriptor.projectPath.path
            )
        } else {
            let command = ShellQuoting.commandLine(agent.command, launchArgs)
            terminalView.startProcess(
                executable: "/bin/zsh",
                args: ["-l", "-c", "exec \(command)"],
                currentDirectory: descriptor.projectPath.path
            )
        }
    }

    /// The command run inside a fresh tmux pane. CLI agents launch under a
    /// login shell so PATH and profile environment match the operator's
    /// normal terminals.
    private func paneCommand() -> String {
        let agent = descriptor.agent
        let launchArgs = AgentLaunchArguments.resolved(for: agent)
        let line = ShellQuoting.commandLine(agent.command, launchArgs)
        if agent.kind == .shell && agent.command.hasPrefix("/") {
            return line
        }
        return "/bin/zsh -l -c " + ShellQuoting.quote("exec \(line)")
    }

    /// Injects keyboard-like control text into the live PTY/tmux client without
    /// treating it as a Raw direct-input boundary. Used from Conversation for
    /// agent permission menus so capture can continue.
    func injectControlInput(
        _ text: String,
        submit: Bool = false
    ) {
        guard lifecycle == .running || lifecycle == .launching else { return }
        var payload = text
        if submit, !payload.hasSuffix("\n"), !payload.hasSuffix("\r") {
            payload += "\n"
        }
        let bytes = Array(payload.utf8)
        guard !bytes.isEmpty else { return }
        // Bypass ActivityTerminalView.send so onDirectRawInput is not fired.
        terminalView.process.send(data: bytes[...])
    }

    /// Arms Derived-from-Raw capture using an already-taken baseline without
    /// delivering a prompt. Used for slash-command inject and reconnect catch-up.
    func armConversationCapture(from baseline: RawDerivedCapture) {
        switch baseline {
        case .available(let snapshot):
            conversationCaptureExtraction = snapshot.extraction
            // Empty recovery baselines must not seed last-accepted, or the
            // immediate refresh would be treated as a no-op.
            if snapshot.text.isEmpty {
                lastAcceptedRenderedBuffer = ""
                lastAcceptedTmuxPane = ""
            } else {
                switch snapshot.extraction {
                case .renderedBuffer:
                    lastAcceptedRenderedBuffer = snapshot.text
                case .tmuxPane:
                    lastAcceptedTmuxPane = snapshot.text
                case .structuredAdapter:
                    break
                }
            }
        case .unavailable:
            conversationCaptureExtraction = nil
        }
    }

    /// Current same-surface baseline for capture start/resync.
    func currentCaptureBaseline() -> RawDerivedCapture {
        if usesTmux, let name = tmuxSessionName,
           let tmux = EnvironmentResolver.shared.resolve("tmux") {
            return Self.tmuxPromptBaseline(
                driver: TmuxDriver(tmuxPath: tmux),
                sessionName: name,
                safeRenderedFallback: { [weak self] in
                    self?.terminalView.scrollbackFreeRenderedSnapshot()
                }
            )
        }
        return directPromptBaseline()
    }

    /// Forces an immediate rendered snapshot into the capture pipeline so
    /// Conversation can catch up after Raw interaction or reconnect.
    func refreshConversationCapture() {
        // Clear last-accepted so the next snapshot is always applied.
        lastAcceptedRenderedBuffer = ""
        lastAcceptedTmuxPane = ""
        switch conversationCaptureExtraction {
        case .tmuxPane:
            guard let name = tmuxSessionName,
                  let tmux = EnvironmentResolver.shared.resolve("tmux")
            else { return }
            let driver = TmuxDriver(tmuxPath: tmux)
            captureQueue.async { [weak self] in
                let snapshot = driver.capturePaneSnapshot(session: name)
                Task { @MainActor in
                    guard let self,
                          self.conversationCaptureExtraction == .tmuxPane
                    else { return }
                    if let snapshot {
                        self.acceptRenderedSnapshot(
                            snapshot,
                            extraction: .tmuxPane
                        )
                    }
                }
            }
        case .renderedBuffer:
            flushRenderedBufferCapture(
                requiresScrollbackFreeBuffer: usesTmux
            )
        case .structuredAdapter, .none:
            break
        }
    }

    /// Common menu navigation keys for agent permission TUIs.
    func injectControlKey(_ key: TerminalControlKey) {
        injectControlInput(key.bytes, submit: false)
    }
}

enum TerminalControlKey {
    case escape
    case enter
    case up
    case down
    case left
    case right

    var bytes: String {
        switch self {
        case .escape: return "\u{1b}"
        case .enter: return "\r"
        case .up: return "\u{1b}[A"
        case .down: return "\u{1b}[B"
        case .left: return "\u{1b}[D"
        case .right: return "\u{1b}[C"
        }
    }

    var label: String {
        switch self {
        case .escape: return "Esc"
        case .enter: return "Enter"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        }
    }
}

/// Hosts a SwiftTerm view without letting it dictate SwiftUI / window ideal size.
/// Returning `LocalProcessTerminalView` directly made macOS grow or reflow the
/// window when a session attached (looked like a zoom; clipped both edges).
final class TerminalContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Never advertise a preferred size to Auto Layout / SwiftUI.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        autoresizesSubviews = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var isFlipped: Bool { false }

    /// Attaches exactly one terminal. Returns true when the attached terminal
    /// actually changed, so the caller can move keyboard focus only on a real
    /// session switch. Previously an already-attached terminal short-circuited
    /// without evicting the others, so every session stayed stacked full-size
    /// and the last one added kept rendering — selecting an earlier session tab
    /// looked like nothing happened.
    @discardableResult
    func attach(_ terminal: LocalProcessTerminalView) -> Bool {
        var didChange = false
        for sub in subviews where sub !== terminal {
            sub.removeFromSuperview()
            didChange = true
        }
        if terminal.superview !== self {
            terminal.removeFromSuperview()
            terminal.translatesAutoresizingMaskIntoConstraints = true
            terminal.autoresizingMask = [.width, .height]
            addSubview(terminal)
            didChange = true
        }
        layoutTerminal(terminal)
        return didChange
    }

    private func layoutTerminal(_ terminal: LocalProcessTerminalView) {
        terminal.frame = bounds
    }

    override func layout() {
        super.layout()
        for sub in subviews {
            sub.frame = bounds
        }
    }
}

/// Palette-derived terminal presentation, matching the signed-off R1 mockup's
/// `.terminal` / `.term-scroll` / `.term-pre` rules. Only base foreground,
/// background, caret, and selection are themed: the 16-colour ANSI palette an
/// agent emits is its own semantic signal, so recolouring it would change what
/// the tool reported.
struct TerminalTheme: Equatable {
    /// Mockup `.term-pre` font-size 12.5px and line-height 1.55.
    static let fontSize: CGFloat = 12.5
    static let lineSpacing: CGFloat = 1.55

    let foreground: NSColor
    let background: NSColor
    let caret: NSColor
    let selection: NSColor

    init(palette: ConduitPalette) {
        foreground = NSColor(palette.text)
        background = NSColor(palette.surface)
        caret = NSColor(palette.accent)
        selection = NSColor(palette.accentSoft)
    }

    func apply(to view: LocalProcessTerminalView) {
        guard view.nativeForegroundColor != foreground
            || view.nativeBackgroundColor != background
            || view.caretColor != caret
            || view.selectedTextBackgroundColor != selection
            || view.lineSpacing != Self.lineSpacing
        else { return }
        view.nativeForegroundColor = foreground
        view.nativeBackgroundColor = background
        view.caretColor = caret
        view.selectedTextBackgroundColor = selection
        // Setting lineSpacing resets the font and resizes the terminal, so it
        // stays behind the equality guard rather than running every update.
        view.lineSpacing = Self.lineSpacing
    }
}

@MainActor
struct TerminalHostView: NSViewRepresentable {
    let controller: TerminalSessionController
    let theme: TerminalTheme
    /// When false, host the terminal for capture continuity without stealing
    /// keyboard focus (Conversation surface keeps the composer first-responder).
    var claimsFocus: Bool = true

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(frame: .zero)
        controller.startIfNeeded()
        theme.apply(to: controller.terminalView)
        container.attach(controller.terminalView)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        controller.startIfNeeded()
        theme.apply(to: controller.terminalView)
        // Only claim focus when the session actually changed and Raw is the
        // active surface. Unrelated updateNSView passes must not yank focus
        // from the Conversation composer.
        if container.attach(controller.terminalView),
           claimsFocus,
           let window = container.window {
            window.makeFirstResponder(controller.terminalView)
        }
    }
}

private enum AttachmentServiceError: LocalizedError {
    case clipboardHasNoImage
    case imageEncodingFailed
    case screenCaptureFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .clipboardHasNoImage: return "The clipboard does not contain an image."
        case .imageEncodingFailed: return "The clipboard image could not be encoded as PNG."
        case .screenCaptureFailed(let code): return "Screen capture exited with code \(code)."
        }
    }
}

enum AttachmentService {
    static func saveImageFromPasteboard() throws -> URL {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard) else {
            throw AttachmentServiceError.clipboardHasNoImage
        }
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            throw AttachmentServiceError.imageEncodingFailed
        }
        let url = try newAttachmentURL(extension: "png")
        try png.write(to: url, options: .atomic)
        return url
    }

    static func captureScreenSelection() async throws -> URL {
        let url = try newAttachmentURL(extension: "png")
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", url.path]
            process.terminationHandler = { process in
                if process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) {
                    continuation.resume(returning: url)
                } else if process.terminationStatus == 1 {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: AttachmentServiceError.screenCaptureFailed(process.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func newAttachmentURL(extension ext: String) throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".conduit/attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return directory.appendingPathComponent("\(formatter.string(from: Date())).\(ext)")
    }
}

@MainActor
final class SpeechTranscriber: ObservableObject {
    @Published var transcript = ""
    @Published private(set) var isRecording = false
    @Published var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() {
        guard !isRecording else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.errorMessage = "Speech recognition permission was not granted."
                    return
                }
                do {
                    try self.beginRecording()
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
    }

    private func beginRecording() throws {
        transcript = ""
        errorMessage = nil
        task?.cancel()

        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            errorMessage = "On-device speech recognition is not available for this locale. Conduit does not send audio to a server; dictation is disabled."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Privacy promise, enforced: transcription never leaves this Mac.
        request.requiresOnDeviceRecognition = true
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal { self.stop() }
                }
                if let error {
                    self.errorMessage = error.localizedDescription
                    self.stop()
                }
            }
        }
    }
}
#endif
