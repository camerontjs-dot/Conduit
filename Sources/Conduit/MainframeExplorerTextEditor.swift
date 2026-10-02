#if os(macOS)
import AppKit
import SwiftUI

/// A plain-text native editor with literal find and one bounded document undo
/// history supplied by the Explorer session. It has no file-write operation.
struct MainframeExplorerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let findQuery: String
    let findRevision: Int
    let onUndo: () -> Void
    let onRedo: () -> Void
    let canUndo: Bool
    let canRedo: Bool
    let foreground: NSColor
    let background: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let editor = ExplorerTextView()
        editor.isRichText = false
        editor.allowsUndo = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 18, height: 14)
        editor.delegate = context.coordinator
        editor.string = text
        editor.setAccessibilityIdentifier("explorer.text.buffer")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ExplorerTextView else { return }
        editor.textColor = foreground
        editor.backgroundColor = background
        editor.insertionPointColor = foreground
        editor.onUndo = onUndo
        editor.onRedo = onRedo
        editor.canDocumentUndo = canUndo
        editor.canDocumentRedo = canRedo
        if !editor.string.utf8.elementsEqual(text.utf8) {
            let range = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(range.location, (text as NSString).length), length: 0))
        }
        if context.coordinator.findRevision != findRevision {
            context.coordinator.findRevision = findRevision
            let source = editor.string as NSString
            let start = min(NSMaxRange(editor.selectedRange()), source.length)
            var range = source.range(of: findQuery, options: .literal, range: NSRange(location: start, length: source.length - start))
            if range.location == NSNotFound { range = source.range(of: findQuery, options: .literal) }
            if !findQuery.isEmpty, range.location != NSNotFound {
                editor.setSelectedRange(range)
                editor.scrollRangeToVisible(range)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MainframeExplorerTextEditor
        var findRevision = 0
        init(parent: MainframeExplorerTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            if !parent.text.utf8.elementsEqual(editor.string.utf8) { editor.string = parent.text }
        }
    }

    final class ExplorerTextView: NSTextView {
        var onUndo: (() -> Void)?
        var onRedo: (() -> Void)?
        var canDocumentUndo = false
        var canDocumentRedo = false
        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
                if event.modifierFlags.contains(.shift) { if canDocumentRedo { onRedo?() } }
                else if canDocumentUndo { onUndo?() }
                return
            }
            super.keyDown(with: event)
        }
    }
}
#endif
