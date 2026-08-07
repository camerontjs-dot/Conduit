#if os(macOS)
import AppKit
import SwiftUI

/// Multiline composer that sends on Return and inserts a newline on Shift-Return.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    /// Tab while a slash menu is open. Return true when the key was handled.
    var onTabComplete: (() -> Bool)? = nil
    var placeholder: String
    var textColor: NSColor
    var backgroundColor: NSColor
    var insertionPointColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let textView = KeyHandlingTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.onTabComplete = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onTabComplete?() ?? false
        }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.drawsBackground = true
        textView.backgroundColor = backgroundColor
        textView.textColor = textColor
        textView.insertionPointColor = insertionPointColor
        textView.string = text

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? KeyHandlingTextView else { return }
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.onTabComplete = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onTabComplete?() ?? false
        }
        textView.backgroundColor = backgroundColor
        textView.textColor = textColor
        textView.insertionPointColor = insertionPointColor
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
        }
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: KeyHandlingTextView?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

final class KeyHandlingTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onTabComplete: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let isReturn =
            event.keyCode == 36
            || event.keyCode == 76
            || event.charactersIgnoringModifiers == "\r"
            || event.charactersIgnoringModifiers == "\n"
        if isReturn {
            let shift = event.modifierFlags.contains(.shift)
            if shift {
                super.insertNewline(nil)
            } else if event.modifierFlags.contains(.command) {
                // Keep ⌘Return as send as well.
                onSubmit?()
            } else {
                onSubmit?()
            }
            return
        }
        // Tab completes the top slash/skill match when available.
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if onTabComplete?() == true {
                return
            }
        }
        super.keyDown(with: event)
    }
}
#endif
