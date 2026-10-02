#if os(macOS)
import AppKit
import Combine

/// An ordinary application-quit decision for the one primary Explorer buffer.
/// The retained RootView owns the buffer, including while Sessions is visible.
/// This delegate does not own task, runtime or provider shutdown behavior.
@MainActor
final class MainframeExplorerApplicationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private weak var explorer: MainframeExplorerWorkspaceModel?
    private weak var explorerWindow: NSWindow?
    private(set) var isDecidingTermination = false
    private var pendingAlert: NSAlert?

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second Quit while the native decision is open cannot bypass it or
        // open another competing decision for the same buffer.
        guard !isDecidingTermination else { return .terminateCancel }
        guard let explorer, explorer.editor.hasUnsavedChanges else { return .terminateNow }
        guard let window = explorerWindow else {
            explorer.editor.noteNavigationBlocked()
            return .terminateCancel
        }
        isDecidingTermination = true

        let alert = NSAlert()
        alert.messageText = "Unsaved Explorer changes"
        alert.informativeText = "\(explorer.editor.relativePath ?? "Current file") has unsaved changes. Save, discard or cancel quitting Conduit."
        alert.addButton(withTitle: "Save").setAccessibilityIdentifier("explorer.quit.save")
        alert.addButton(withTitle: "Discard").setAccessibilityIdentifier("explorer.quit.discard")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.setAccessibilityIdentifier("explorer.quit.cancel")
        cancel.keyEquivalent = "\u{1b}"
        alert.window.setAccessibilityIdentifier("explorer.quit.unsaved-alert")
        pendingAlert = alert
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.resolve(response, explorer: explorer, window: window, application: sender)
            }
        }
        // End the native termination flow before presenting the decision.
        // Native reentrant terminate can bypass an unresolved runModal or
        // terminateLater flow. A new Quit can now reach the pending guard above.
        return .terminateCancel
    }

    private func resolve(_ response: NSApplication.ModalResponse, explorer: MainframeExplorerWorkspaceModel,
                         window: NSWindow, application: NSApplication) {
        switch response {
        case .alertFirstButtonReturn:
            guard explorer.saveEdits() else {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = "Explorer changes were not saved"
                failure.informativeText = (explorer.editor.statusMessage ?? "The selected file could not be saved.")
                    + " Conduit will stay open. Your buffer and the current disk version are preserved."
                failure.addButton(withTitle: "Continue Editing")
                    .setAccessibilityIdentifier("explorer.quit.save-failure.continue")
                failure.window.setAccessibilityIdentifier("explorer.quit.save-failure-alert")
                pendingAlert = failure
                failure.beginSheetModal(for: window) { [weak self] _ in
                    self?.isDecidingTermination = false
                    self?.pendingAlert = nil
                }
                return
            }
            finish(application, shouldTerminate: true)
        case .alertSecondButtonReturn:
            explorer.discardEdits()
            finish(application, shouldTerminate: true)
        default:
            finish(application, shouldTerminate: false)
        }
    }

    private func finish(_ application: NSApplication, shouldTerminate: Bool) {
        isDecidingTermination = false
        pendingAlert = nil
        // A successful exact Save or explicit Discard has cleared dirty state.
        // This fresh native request can proceed through the normal lifecycle.
        if shouldTerminate { application.terminate(nil) }
    }
}
#endif
