#if os(macOS)
import AppKit
import ConduitCore
import Foundation
import SwiftTerm

@MainActor
final class TerminalSessionController: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let descriptor: SessionDescriptor
    let terminalView: LocalProcessTerminalView
    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var terminalTitle: String
    private var hasStarted = false

    init(descriptor: SessionDescriptor) {
        self.descriptor = descriptor
        self.terminalTitle = descriptor.title
        self.terminalView = LocalProcessTerminalView(frame: .zero)
        super.init()
        terminalView.processDelegate = self
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeForegroundColor = NSColor.textColor
        terminalView.nativeBackgroundColor = NSColor.windowBackgroundColor
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        isRunning = true

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

    func send(_ text: String) {
        startIfNeeded()
        let bytes = Array(text.utf8)
        terminalView.process.send(data: bytes[...])
    }

    func interrupt() {
        send("\u{3}")
    }

    func terminate() {
        guard hasStarted else { return }
        terminalView.terminate()
        isRunning = false
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        terminalTitle = title.isEmpty ? descriptor.title : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        self.exitCode = exitCode
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

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
