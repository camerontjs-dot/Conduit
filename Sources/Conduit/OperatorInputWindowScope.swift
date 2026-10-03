#if os(macOS)
import AppKit
import SwiftUI

/// A conversation key monitor belongs to its actual mounted window.
/// Sheets, modal dialogs and auxiliary windows keep their own key handling.
@MainActor
final class OperatorInputWindowScope: ObservableObject {
    weak var window: NSWindow?

    var acceptsKeyboardInput: Bool {
        guard let window, window.isVisible,
              NSApp.keyWindow === window,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return false }
        return true
    }

    func accepts(_ event: NSEvent) -> Bool {
        acceptsKeyboardInput && event.window != nil && event.window === window
    }
}

struct OperatorInputWindowReader: NSViewRepresentable {
    let scope: OperatorInputWindowScope

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(scope: scope)
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.scope = scope
        scope.window = view.window
    }

    final class TrackingView: NSView {
        var scope: OperatorInputWindowScope
        init(scope: OperatorInputWindowScope) {
            self.scope = scope
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scope.window = window
        }
    }
}
#endif
