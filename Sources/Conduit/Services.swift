#if os(macOS)
import AppKit
import AVFoundation
import ConduitCore
import Foundation
import Speech
import SwiftTerm
import SwiftUI

final class ActivityTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onOutput?()
        super.dataReceived(slice: slice)
    }
}

@MainActor
final class TerminalSessionController: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let descriptor: SessionDescriptor
    let terminalView: ActivityTerminalView

    @Published private(set) var lifecycle: SessionLifecycle = .idle
    @Published private(set) var terminalTitle: String
    @Published private(set) var lastOutputAt: Date?
    private(set) var usesTmux = false
    private(set) var tmuxSessionName: String?

    private let useDetachedSessions: Bool

    /// One prompt awaiting delivery, with an optional MainActor completion that
    /// reports whether the bytes actually reached the session.
    private struct PendingPrompt {
        let text: String
        let submit: Bool
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
    /// Serial queue: tmux delivery is three blocking subprocess calls; running
    /// them here (never overlapping, FIFO) keeps back-to-back prompts from
    /// interleaving into one merged or reordered message, and keeps the waits
    /// off the cooperative pool.
    private let deliveryQueue = DispatchQueue(label: "dev.camerontjs.conduit.delivery")
    private var deliveryCompletions: [UUID: (Bool) -> Void] = [:]

    private let readinessQuiescence: TimeInterval = 0.6
    private let readinessHardCap: TimeInterval = 8.0

    var isDetached: Bool { lifecycle == .detached }
    var exitCode: Int32? {
        if case .exited(let code) = lifecycle { return code }
        return nil
    }
    var backendLabel: String { usesTmux ? "tmux" : "PTY" }

    init(descriptor: SessionDescriptor, useDetachedSessions: Bool) {
        self.descriptor = descriptor
        self.useDetachedSessions = useDetachedSessions
        self.terminalTitle = descriptor.title
        self.terminalView = ActivityTerminalView(frame: .zero)
        super.init()
        terminalView.processDelegate = self
        terminalView.onOutput = { [weak self] in
            Task { @MainActor in self?.noteOutput() }
        }
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeForegroundColor = NSColor.textColor
        terminalView.nativeBackgroundColor = NSColor.windowBackgroundColor
    }

    func startIfNeeded() {
        guard lifecycle == .idle else { return }
        lifecycle.transition(to: .launching)

        if useDetachedSessions, let tmux = EnvironmentResolver.shared.resolve("tmux") {
            let name = TmuxSessionNaming.sessionName(
                projectPath: descriptor.projectPath,
                agentName: descriptor.agent.name
            )
            let driver = TmuxDriver(tmuxPath: tmux)
            // Session creation happens out-of-band and detached, so the
            // session deterministically exists before the client attaches
            // and before any prompt delivery.
            if driver.ensureSession(
                name: name,
                directory: descriptor.projectPath.path,
                command: paneCommand()
            ) {
                usesTmux = true
                tmuxSessionName = name
                terminalView.startProcess(
                    executable: tmux,
                    args: ["attach-session", "-t", "=\(name)"],
                    currentDirectory: descriptor.projectPath.path
                )
                terminalTitle = "\(descriptor.title) · durable"
                return
            }
        }

        usesTmux = false
        startDirectSession()
    }

    /// Delivers composer or forwarded text with paste semantics. Held until the
    /// session is ready (output quiesced) so prompts to a just-launched agent
    /// are neither dropped nor mangled. `completion(false)` fires if the bytes
    /// could not be delivered, so the caller can restore what the user typed.
    func deliverPrompt(_ text: String, submit: Bool = true, completion: ((Bool) -> Void)? = nil) {
        let normalized = PromptEncoder.normalized(text)
        guard !normalized.isEmpty else { completion?(true); return }
        // Refuse to swallow a prompt aimed at a session that has already ended.
        if lifecycle.isTerminal {
            completion?(false)
            return
        }
        startIfNeeded()
        let prompt = PendingPrompt(text: normalized, submit: submit, completion: completion)
        if isReadyForInput {
            enqueueDelivery(prompt)
        } else {
            pendingPrompts.append(prompt)
        }
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
            terminate()
        }
    }

    /// Kill the underlying process (and durable tmux session when present) so
    /// the next launch creates a brand-new session instead of reconnecting.
    func endSession() {
        failPendingPrompts()
        if usesTmux, let name = tmuxSessionName, let tmux = EnvironmentResolver.shared.resolve("tmux") {
            // Kill first so has-session during processTerminated sees "gone".
            TmuxDriver(tmuxPath: tmux).killSession(name)
        }
        // Detach→exited is blocked on the state machine (receipt honesty);
        // an explicit operator kill may force the exited state.
        if case .exited = lifecycle {
            // already terminal
        } else if !lifecycle.transition(to: .exited(code: nil)) {
            lifecycle = .exited(code: nil)
        }
        terminalView.terminate()
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
                let alive = driver.hasSession(name)
                Task { @MainActor in
                    guard let self, !self.lifecycle.isTerminal else { return }
                    self.lifecycle.transition(to: alive ? .detached : .exited(code: nil))
                    self.failPendingPrompts()
                }
            }
            return
        }

        // Direct PTY: SwiftTerm hands us the raw waitpid status; decode it so
        // the receipt records a real exit code, not 256 for a 1.
        let decoded = exitCode.map { POSIXExitStatus.decode($0) }
        lifecycle.transition(to: .exited(code: decoded))
        failPendingPrompts()
    }

    // MARK: - Private

    private func noteOutput() {
        lastOutputAt = Date()
        if lifecycle == .launching {
            lifecycle.transition(to: .running)
        }
        guard firstOutputAt == nil else { return }
        firstOutputAt = Date()
        scheduleReadinessCheck()
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
        let queued = pendingPrompts
        pendingPrompts = []
        for prompt in queued {
            enqueueDelivery(prompt)
        }
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
                let delivered = driver.paste(session: name, text: text, submit: submit)
                Task { @MainActor in self?.finishDelivery(id, delivered: delivered) }
            }
        } else {
            // Direct PTY writes must happen on the main actor (view access);
            // enqueueDelivery is already called in FIFO order here.
            let bracketed = terminalView.getTerminal().bracketedPasteMode
            let bytes = PromptEncoder.encode(text: prompt.text, bracketedPaste: bracketed, submit: prompt.submit)
            if !bytes.isEmpty {
                terminalView.process.send(data: bytes[...])
            }
            prompt.completion?(true)
        }
    }

    private func finishDelivery(_ id: UUID, delivered: Bool) {
        deliveryCompletions.removeValue(forKey: id)?(delivered)
    }

    private func failPendingPrompts() {
        let queued = pendingPrompts
        pendingPrompts = []
        for prompt in queued {
            prompt.completion?(false)
        }
    }

    private func startDirectSession() {
        let agent = descriptor.agent
        if agent.kind == .shell && agent.command.hasPrefix("/") {
            terminalView.startProcess(
                executable: agent.command,
                args: agent.arguments,
                currentDirectory: descriptor.projectPath.path
            )
        } else {
            let command = ShellQuoting.commandLine(agent.command, agent.arguments)
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
        let line = ShellQuoting.commandLine(agent.command, agent.arguments)
        if agent.kind == .shell && agent.command.hasPrefix("/") {
            return line
        }
        return "/bin/zsh -l -c " + ShellQuoting.quote("exec \(line)")
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

    func attach(_ terminal: LocalProcessTerminalView) {
        if terminal.superview === self {
            layoutTerminal(terminal)
            return
        }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        layoutTerminal(terminal)
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

@MainActor
struct TerminalHostView: NSViewRepresentable {
    let controller: TerminalSessionController

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(frame: .zero)
        controller.startIfNeeded()
        container.attach(controller.terminalView)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        controller.startIfNeeded()
        container.attach(controller.terminalView)
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
