#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

/// Current source facts, re-read when the mounted view is sampled, not a cursor.
struct ConversationViewportContext {
    let taskSessionID: TaskSessionID
    let surface: SessionSurface
    let latestRevision: ThreadOutputRevisionIdentity?
}

/// A transparent background on the latest rendered output document, not on
/// the conversation footer, provider activity, selection or follow-latest flag.
struct ConversationViewportProbe: NSViewRepresentable {
    let taskSessionID: TaskSessionID
    let revision: ThreadOutputRevisionIdentity
    let currentContext: () -> ConversationViewportContext?

    func makeNSView(context: Context) -> ConversationViewportProbeView {
        ConversationViewportProbeView()
    }

    func updateNSView(_ view: ConversationViewportProbeView, context: Context) {
        view.configure(taskSessionID: taskSessionID, revision: revision,
                       currentContext: currentContext)
    }

    static func dismantleNSView(_ view: ConversationViewportProbeView, coordinator: ()) {
        view.invalidate()
    }
}

/// Read-time, ephemeral observation. No cached positive result, timer, global
/// observer, model mutation, disk write or cursor advancement exists here.
/// A future consumer must sample again rather than retain this as live state.
@MainActor
final class ConversationViewportProbeView: NSView {
    private struct Binding: Equatable {
        let taskSessionID: TaskSessionID
        let revision: ThreadOutputRevisionIdentity
    }

    private var binding: Binding?
    private var laidOutBinding: Binding?
    private var currentContext: (() -> ConversationViewportContext?)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        taskSessionID: TaskSessionID,
        revision: ThreadOutputRevisionIdentity,
        currentContext: @escaping () -> ConversationViewportContext?
    ) {
        let next = Binding(taskSessionID: taskSessionID, revision: revision)
        if binding != next {
            binding = next
            laidOutBinding = nil
            needsLayout = true
        }
        self.currentContext = currentContext
    }

    override func layout() {
        super.layout()
        laidOutBinding = binding
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        laidOutBinding = nil
        needsLayout = true
    }

    func invalidate() {
        binding = nil
        laidOutBinding = nil
        currentContext = nil
    }

    /// Samples the real enclosing NSScrollView and owning NSWindow on the main
    /// actor. No caller can inject window/application flags or viewport geometry.
    /// Absence, pending layout, stale source or a detached probe is not visibility.
    func sampleObservation() -> ThreadSeenObservation? {
        guard let binding, laidOutBinding == binding,
              let window, let scroll = enclosingScrollView,
              let document = scroll.documentView,
              isDescendant(of: document), scroll.window === window,
              let context = currentContext?(),
              context.taskSessionID == binding.taskSessionID
        else { return nil }

        var ancestor: NSView? = self
        var layoutAndPresentationReady = window.alphaValue > 0
        while let view = ancestor {
            if view.needsLayout || view.isHidden || view.alphaValue <= 0 {
                layoutAndPresentationReady = false
                break
            }
            ancestor = view.superview
        }

        // This background fills the output document. Its final one-point strip
        // is inside the document, not an empty sentinel after other UI content.
        let tail = CGRect(x: bounds.minX, y: bounds.maxY - 1,
                          width: bounds.width, height: 1)
        let clip = scroll.contentView
        let viewport = clip.bounds.intersection(clip.visibleRect)
        let revision: ThreadOutputRevisionIdentity?
        if layoutAndPresentationReady, bounds.height >= 1,
           visibleRect.contains(tail) {
            revision = ThreadSeenViewport.visibleRevision(
                renderedTaskSessionID: binding.taskSessionID,
                currentTaskSessionID: context.taskSessionID,
                renderedRevision: binding.revision,
                latestRevision: context.latestRevision,
                tailRect: convert(tail, to: clip),
                viewportRect: viewport
            )
        } else {
            revision = nil
        }

        return ThreadSeenObservation(
            taskSessionID: context.taskSessionID,
            surface: context.surface,
            applicationIsActive: NSApplication.shared.isActive,
            windowIsKey: window.isKeyWindow,
            windowIsVisible: window.isVisible,
            windowIsOcclusionVisible: window.occlusionState.contains(.visible),
            visibleLatestRevision: context.surface == .conversation ? revision : nil
        )
    }
}
#endif
