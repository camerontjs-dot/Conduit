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
    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var terminalTitle: String
    @Published private(set) var lastOutputAt: Date?
    @Published private(set) var isDetached = false
    @Published private(set) var usesTmux = false
    private let useDetachedSessions: Bool
    private var hasStarted = false

    init(descriptor: SessionDescriptor, useDetachedSessions: Bool) {
        self.descriptor = descriptor
        self.useDetachedSessions = useDetachedSessions
        self.terminalTitle = descriptor.title
        self.terminalView = ActivityTerminalView(frame: .zero)
        super.init()
        terminalView.processDelegate = self
        terminalView.onOutput = { [weak self] in
            Task { @MainActor in self?.lastOutputAt = Date() }
        }
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeForegroundColor = NSColor.textColor
        terminalView.nativeBackgroundColor = NSColor.windowBackgroundColor
    }

    var backendLabel: String {
        usesTmux ? "tmux" : "PTY"
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        isRunning = true
        isDetached = false
        exitCode = nil

        if useDetachedSessions, ShellProbe.resolve("tmux") != nil {
            usesTmux = true
            startTmuxSession()
        } else {
            usesTmux = false
            startDirectSession()
        }
    }

    func send(_ text: String) {
        startIfNeeded()
        let bytes = Array(text.utf8)
        terminalView.process.send(data: bytes[...])
    }

    func interrupt() {
        send("\u{3}")
    }

    func closeSession() {
        guard hasStarted else { return }
        if usesTmux && isRunning {
            let detach = Array("\u{2}d".utf8)
            terminalView.process.send(data: detach[...])
            isDetached = true
            isRunning = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.terminalView.terminate()
            }
        } else {
            terminate()
        }
    }

    func terminate() {
        guard hasStarted else { return }
        terminalView.terminate()
        isRunning = false
    }

    func visualState(at date: Date) -> TerminalVisualState {
        if isDetached { return .detached }
        if let exitCode, exitCode != 0 { return .failed }
        if !isRunning { return .exited }
        if let lastOutputAt, date.timeIntervalSince(lastOutputAt) < 1.8 { return .working }
        return .running
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        terminalTitle = title.isEmpty ? descriptor.title : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if !isDetached {
            isRunning = false
            self.exitCode = exitCode
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
            let command = ([agent.command] + agent.arguments).map(Self.shellQuote).joined(separator: " ")
            terminalView.startProcess(
                executable: "/bin/zsh",
                args: ["-l", "-c", "exec \(command)"],
                currentDirectory: descriptor.projectPath.path
            )
        }
    }

    private func startTmuxSession() {
        let name = Self.tmuxSessionName(for: descriptor)
        let command = ([descriptor.agent.command] + descriptor.agent.arguments)
            .map(Self.shellQuote)
            .joined(separator: " ")
        let script = """
        if tmux has-session -t \(Self.shellQuote(name)) 2>/dev/null; then
          exec tmux attach-session -t \(Self.shellQuote(name))
        else
          exec tmux new-session -s \(Self.shellQuote(name)) -c \(Self.shellQuote(descriptor.projectPath.path)) \(Self.shellQuote("exec \(command)"))
        fi
        """
        terminalView.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", script],
            currentDirectory: descriptor.projectPath.path
        )
        terminalTitle = "\(descriptor.title) · durable"
    }

    private static func tmuxSessionName(for descriptor: SessionDescriptor) -> String {
        let raw = "\(descriptor.projectPath.standardizedFileURL.path)|\(descriptor.agent.name)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let project = safeName(descriptor.projectPath.lastPathComponent)
        let agent = safeName(descriptor.agent.name)
        return String("conduit-\(project)-\(agent)-\(String(hash, radix: 16).suffix(8))".prefix(70))
    }

    private static func safeName(_ value: String) -> String {
        let transformed = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(transformed).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
struct TerminalHostView: NSViewRepresentable {
    let controller: TerminalSessionController

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        controller.startIfNeeded()
        return controller.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
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

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-CA"))
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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
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

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
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
