#if os(macOS)
import AppKit
import SwiftUI

/// The main window retains the one Explorer buffer even while Sessions is
/// visible. Window-close decisions preserve that buffer without owning any
/// task, runtime or provider lifecycle behavior.
struct MainframeExplorerWindowCloseGuard: NSViewRepresentable {
    @ObservedObject var explorer: MainframeExplorerWorkspaceModel
    var applicationDelegate: MainframeExplorerApplicationDelegate? = nil

    func makeCoordinator() -> Coordinator { Coordinator(explorer: explorer, applicationDelegate: applicationDelegate) }
    func makeNSView(context: Context) -> GuardView { GuardView(coordinator: context.coordinator) }
    func updateNSView(_ view: GuardView, context: Context) { context.coordinator.explorer = explorer }
    static func dismantleNSView(_ view: GuardView, coordinator: Coordinator) { coordinator.detach() }

    final class GuardView: NSView {
        let coordinator: Coordinator
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        override func viewDidMoveToWindow() { coordinator.attach(to: window) }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var explorer: MainframeExplorerWorkspaceModel?
        private weak var applicationDelegate: MainframeExplorerApplicationDelegate?
        private weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?

        init(explorer: MainframeExplorerWorkspaceModel, applicationDelegate: MainframeExplorerApplicationDelegate? = nil) {
            self.explorer = explorer
            self.applicationDelegate = applicationDelegate
        }

        @MainActor func attach(to window: NSWindow?) {
            if self.window === window { return }
            detach()
            guard let window else { return }
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
            if let explorer { applicationDelegate?.registerExplorer(explorer, window: window) }
        }

        @MainActor func detach() {
            if let window, let explorer { applicationDelegate?.unregisterExplorer(explorer, window: window) }
            if let window, window.delegate === self { window.delegate = previousDelegate }
            window = nil
            previousDelegate = nil
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (previousDelegate?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previousDelegate?.responds(to: selector) == true { return previousDelegate }
            return super.forwardingTarget(for: selector)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if applicationDelegate?.isDecidingTermination == true { return false }
            if let explorer, explorer.editor.hasUnsavedChanges {
                let alert = NSAlert()
                alert.messageText = "Unsaved Explorer changes"
                alert.informativeText = "\(explorer.editor.relativePath ?? "Current file") has unsaved changes. Save, discard or cancel closing this window."
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Discard")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    guard explorer.saveEdits() else { return false }
                case .alertSecondButtonReturn:
                    explorer.discardEdits()
                default: return false
                }
            }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }
    }
}
#endif
