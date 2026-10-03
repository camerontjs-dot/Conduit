#if os(macOS)
import AppKit
import SwiftUI

/// Done and native Close use the same exact source-window delegate path.
@MainActor
final class MainframeSourceWorkbenchCloseController: ObservableObject {
    fileprivate weak var window: NSWindow?
    fileprivate weak var editor: MainframeSourceEditingSession?

    func requestClose() {
        guard let window else { editor?.noteNavigationBlocked(); return }
        window.performClose(nil)
    }
}

struct MainframeSourceWorkbenchCloseGuard: NSViewRepresentable {
    @ObservedObject var editor: MainframeSourceEditingSession
    let root: URL
    let file: URL
    @ObservedObject var applicationDelegate: MainframeExplorerApplicationDelegate
    @ObservedObject var closeController: MainframeSourceWorkbenchCloseController

    func makeCoordinator() -> Coordinator {
        Coordinator(editor: editor, root: root, file: file,
                    applicationDelegate: applicationDelegate, closeController: closeController)
    }
    func makeNSView(context: Context) -> GuardView { GuardView(coordinator: context.coordinator) }
    func updateNSView(_ view: GuardView, context: Context) {}
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
        private let editor: MainframeSourceEditingSession
        private let root: URL
        private let file: URL
        private weak var applicationDelegate: MainframeExplorerApplicationDelegate?
        private weak var closeController: MainframeSourceWorkbenchCloseController?
        private weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?

        init(editor: MainframeSourceEditingSession, root: URL, file: URL,
             applicationDelegate: MainframeExplorerApplicationDelegate,
             closeController: MainframeSourceWorkbenchCloseController) {
            self.editor = editor
            self.root = root
            self.file = file
            self.applicationDelegate = applicationDelegate
            self.closeController = closeController
        }

        @MainActor func attach(to window: NSWindow?) {
            if self.window === window { return }
            detach()
            guard self.window == nil else { editor.noteNavigationBlocked(); return }
            guard let window,
                  applicationDelegate?.registerSource(editor, root: root, file: file,
                                                       window: window, closeOwner: self) == true else { return }
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
            closeController?.editor = editor
            closeController?.window = window
        }

        @MainActor func detach() {
            if let window {
                guard applicationDelegate?.unregisterSource(editor, window: window, closeOwner: self) == true else { return }
                if window.delegate === self { window.delegate = previousDelegate }
                if closeController?.window === window { closeController?.window = nil }
            }
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
            guard let applicationDelegate,
                  applicationDelegate.windowShouldCloseSource(editor, window: sender) else { return false }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }

        func windowWillClose(_ notification: Notification) {
            let previous = previousDelegate
            detach()
            previous?.windowWillClose?(notification)
        }
    }
}
#endif
