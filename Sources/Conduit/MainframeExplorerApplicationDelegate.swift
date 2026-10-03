#if os(macOS)
import AppKit
import Combine

/// One UI-only exit owner for the retained Explorer and source-window buffers.
/// Editors and the exact-file writer keep their existing authority. This owner
/// has no task, runtime or provider shutdown responsibility.
@MainActor
final class MainframeExplorerApplicationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private weak var explorer: MainframeExplorerWorkspaceModel?
    private weak var explorerWindow: NSWindow?
    private var sources: [ObjectIdentifier: SourceRegistration] = [:]
    private var pendingExit: PendingExit?
    private var pendingAlert: NSAlert?
    private var sheetEndObserver: NSObjectProtocol?

    var isDecidingBufferExit: Bool { pendingExit != nil }
    var isDecidingTermination: Bool {
        if case .quit = pendingExit { return true }
        return false
    }

    private final class SourceRegistration {
        // Keep an unexpectedly detached dirty editor available rather than
        // forgetting its buffer. Normal approved close unregisters it cleanly.
        let editor: MainframeSourceEditingSession
        let root: URL
        let file: URL
        let closeOwner: NSWindowDelegate?
        weak var window: NSWindow?

        init(editor: MainframeSourceEditingSession, root: URL, file: URL, window: NSWindow,
             closeOwner: NSWindowDelegate?) {
            self.editor = editor
            self.root = root.standardizedFileURL
            self.file = file.standardizedFileURL
            self.window = window
            self.closeOwner = closeOwner
        }
    }

    private enum PendingExit {
        case quit(NSApplication)
        case close(NSWindow)
    }

    private struct Buffer {
        let title: String
        let identifier: String
        let window: NSWindow?
        let label: String
        let isCurrent: () -> Bool
        let isDirty: () -> Bool
        let save: () -> Bool
        let discard: () -> Void
        let status: () -> String?
        let noteBlocked: () -> Void
    }

    func registerExplorer(_ explorer: MainframeExplorerWorkspaceModel, window: NSWindow) {
        self.explorer = explorer
        explorerWindow = window
    }

    func unregisterExplorer(_ explorer: MainframeExplorerWorkspaceModel, window: NSWindow) {
        if self.explorer === explorer, explorerWindow === window {
            self.explorer = nil
            explorerWindow = nil
        }
    }

    @discardableResult
    func registerSource(_ editor: MainframeSourceEditingSession, root: URL, file: URL, window: NSWindow,
                        closeOwner: NSWindowDelegate? = nil) -> Bool {
        let identity = ObjectIdentifier(editor)
        if let existing = sources[identity] {
            guard existing.window === window, existing.root == root.standardizedFileURL,
                  existing.file == file.standardizedFileURL else {
                editor.noteNavigationBlocked()
                return false
            }
            guard closeOwner == nil || existing.closeOwner === closeOwner else {
                editor.noteNavigationBlocked()
                return false
            }
            return true
        }
        guard !sources.values.contains(where: { $0.window === window && $0.editor !== editor }) else {
            editor.noteNavigationBlocked()
            return false
        }
        sources[identity] = SourceRegistration(editor: editor, root: root, file: file,
                                              window: window, closeOwner: closeOwner)
        return true
    }

    @discardableResult
    func unregisterSource(_ editor: MainframeSourceEditingSession, window: NSWindow,
                          closeOwner: NSWindowDelegate? = nil) -> Bool {
        let identity = ObjectIdentifier(editor)
        guard let registration = sources[identity], registration.editor === editor,
              registration.window === window,
              closeOwner == nil || registration.closeOwner === closeOwner else { return false }
        // A dismantled representable cannot relinquish the native Close gate
        // while its buffer or a pending decision still needs that exact owner.
        guard !editor.hasUnsavedChanges, !isDecidingBufferExit else {
            editor.noteNavigationBlocked()
            return false
        }
        sources.removeValue(forKey: identity)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quit cannot bypass another Quit or a pending native window decision.
        guard !isDecidingBufferExit else { return .terminateCancel }
        guard let buffer = firstDirtyBuffer() else { return .terminateNow }
        beginDecision(buffer, exit: .quit(sender))
        return .terminateCancel
    }

    func windowShouldCloseExplorer(_ explorer: MainframeExplorerWorkspaceModel, window: NSWindow) -> Bool {
        guard !isDecidingBufferExit else { return false }
        guard self.explorer === explorer, explorerWindow === window else {
            explorer.editor.noteNavigationBlocked()
            return false
        }
        guard explorer.editor.hasUnsavedChanges else { return true }
        beginDecision(explorerBuffer(explorer), exit: .close(window))
        return false
    }

    func windowShouldCloseSource(_ editor: MainframeSourceEditingSession, window: NSWindow) -> Bool {
        guard !isDecidingBufferExit else { return false }
        guard let registration = sources[ObjectIdentifier(editor)], registration.window === window else {
            editor.noteNavigationBlocked()
            return false
        }
        guard editor.hasUnsavedChanges else { return true }
        beginDecision(sourceBuffer(registration), exit: .close(window))
        return false
    }

    private func firstDirtyBuffer() -> Buffer? {
        if let explorer, explorer.editor.hasUnsavedChanges { return explorerBuffer(explorer) }
        return sources.values.sorted {
            ($0.window?.windowNumber ?? Int.max) < ($1.window?.windowNumber ?? Int.max)
        }.first(where: { $0.editor.hasUnsavedChanges }).map(sourceBuffer)
    }

    private func explorerBuffer(_ explorer: MainframeExplorerWorkspaceModel) -> Buffer {
        let window = explorerWindow
        return Buffer(title: "Explorer", identifier: "explorer", window: window,
                      label: explorer.editor.relativePath ?? "Current file",
                      isCurrent: { [weak self] in self?.explorer === explorer && self?.explorerWindow === window },
                      isDirty: { explorer.editor.hasUnsavedChanges }, save: { explorer.saveEdits() },
                      discard: { explorer.discardEdits() }, status: { explorer.editor.statusMessage },
                      noteBlocked: { explorer.editor.noteNavigationBlocked() })
    }

    private func sourceBuffer(_ registration: SourceRegistration) -> Buffer {
        let editor = registration.editor
        let window = registration.window
        return Buffer(title: "Source Workbench", identifier: "source-workbench", window: window,
                      label: editor.relativePath ?? registration.file.lastPathComponent,
                      isCurrent: { [weak self] in
                          self?.sources[ObjectIdentifier(editor)] === registration
                              && registration.window === window
                              && editor.absolutePath == registration.file.path
                      }, isDirty: { editor.hasUnsavedChanges },
                      save: { editor.save(root: registration.root, file: registration.file) },
                      discard: { editor.discard() }, status: { editor.statusMessage },
                      noteBlocked: { editor.noteNavigationBlocked() })
    }

    private func beginDecision(_ buffer: Buffer, exit: PendingExit) {
        guard !isDecidingBufferExit, buffer.isCurrent(), let window = buffer.window,
              window.attachedSheet == nil else {
            buffer.noteBlocked()
            return
        }
        pendingExit = exit
        let purpose: String
        let action: String
        switch exit {
        case .quit: purpose = "quit"; action = "quitting Conduit"
        case .close: purpose = "close"; action = "closing this window"
        }
        let identifier = buffer.identifier + "." + purpose
        let alert = NSAlert()
        alert.messageText = "Unsaved \(buffer.title) changes"
        alert.informativeText = "\(buffer.label) has unsaved changes. Save, discard or cancel \(action)."
        alert.addButton(withTitle: "Save").setAccessibilityIdentifier(identifier + ".save")
        alert.addButton(withTitle: "Discard").setAccessibilityIdentifier(identifier + ".discard")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.setAccessibilityIdentifier(identifier + ".cancel")
        cancel.keyEquivalent = "\u{1b}"
        alert.window.setAccessibilityIdentifier(identifier + ".unsaved-alert")
        pendingAlert = alert
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard buffer.isCurrent(), window.attachedSheet == nil else {
                buffer.noteBlocked()
                self.finish(shouldProceed: false, buffer: buffer)
                return
            }
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.resolve(response, buffer: buffer, window: window, identifier: identifier)
            }
        }
    }

    private func resolve(_ response: NSApplication.ModalResponse, buffer: Buffer, window: NSWindow, identifier: String) {
        guard buffer.isCurrent() else {
            buffer.noteBlocked()
            finish(shouldProceed: false, buffer: buffer)
            return
        }
        switch response {
        case .alertFirstButtonReturn:
            guard buffer.save(), !buffer.isDirty() else {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = "\(buffer.title) changes were not saved"
                failure.informativeText = (buffer.status() ?? "The selected file could not be saved.")
                    + " Conduit will stay open. Your buffer and the current disk version are preserved."
                failure.addButton(withTitle: "Continue Editing")
                    .setAccessibilityIdentifier(identifier + ".save-failure.continue")
                failure.window.setAccessibilityIdentifier(identifier + ".save-failure-alert")
                pendingAlert = failure
                failure.beginSheetModal(for: window) { [weak self] _ in
                    self?.finish(shouldProceed: false, buffer: buffer)
                }
                return
            }
            finish(shouldProceed: true, buffer: buffer)
        case .alertSecondButtonReturn:
            buffer.discard()
            finish(shouldProceed: !buffer.isDirty(), buffer: buffer)
        default:
            finish(shouldProceed: false, buffer: buffer)
        }
    }

    private func finish(shouldProceed: Bool, buffer: Buffer) {
        let exit = pendingExit
        guard shouldProceed, buffer.isCurrent(), !buffer.isDirty(), let exit else {
            clearDecision()
            return
        }
        // A fresh Quit checks every other registered buffer. A fresh Close goes
        // through the same native delegate and any previous window delegate.
        switch exit {
        case .quit(let application):
            clearDecision()
            application.terminate(nil)
        case .close(let window):
            // Native Close is suppressed while the decision sheet is still
            // attached, even from its response callback. Keep the exit guard
            // armed until that exact window reports native sheet teardown.
            if window.attachedSheet != nil {
                sheetEndObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didEndSheetNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closeAfterDecision(window, buffer: buffer) }
                }
            } else {
                DispatchQueue.main.async { [weak self] in self?.closeAfterDecision(window, buffer: buffer) }
            }
        }
    }

    private func closeAfterDecision(_ window: NSWindow, buffer: Buffer) {
        guard case .close(let pendingWindow) = pendingExit, pendingWindow === window else { return }
        guard buffer.isCurrent(), !buffer.isDirty(), window.attachedSheet == nil else {
            buffer.noteBlocked()
            clearDecision()
            return
        }
        clearDecision()
        window.performClose(nil)
    }

    private func clearDecision() {
        if let sheetEndObserver { NotificationCenter.default.removeObserver(sheetEndObserver) }
        sheetEndObserver = nil
        pendingExit = nil
        pendingAlert = nil
    }
}
#endif
