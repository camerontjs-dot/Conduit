#if os(macOS)
import SwiftUI

/// Structured hover help for controls whose authority or side effects deserve
/// more explanation than a one-line tooltip. The card is presentation only and
/// never performs the described action itself.
struct ActionExplainerSpec: Equatable {
    let title: String
    let summary: String
    let effect: String?
    let nonEffect: String?
    let target: String?
    let authority: String?
    let shortcut: String?

    init(
        title: String,
        summary: String,
        effect: String? = nil,
        nonEffect: String? = nil,
        target: String? = nil,
        authority: String? = nil,
        shortcut: String? = nil
    ) {
        self.title = title
        self.summary = summary
        self.effect = effect
        self.nonEffect = nonEffect
        self.target = target
        self.authority = authority
        self.shortcut = shortcut
    }
}

private struct ActionExplainerModifier: ViewModifier {
    let spec: ActionExplainerSpec
    let delayNanoseconds: UInt64

    @State private var isPresented = false
    @State private var anchorHovered = false
    @State private var cardHovered = false
    @State private var pendingTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            // Keep native help as a fallback for accessibility and for cases
            // where the richer hover card cannot be presented.
            .help(spec.summary)
            .onHover { hovering in
                anchorHovered = hovering
                if hovering {
                    scheduleShow()
                } else {
                    scheduleHide()
                }
            }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ActionExplainerCard(spec: spec)
                    .onHover { hovering in
                        cardHovered = hovering
                        if hovering {
                            pendingTask?.cancel()
                        } else {
                            scheduleHide()
                        }
                    }
            }
            .onDisappear {
                pendingTask?.cancel()
                pendingTask = nil
                isPresented = false
            }
    }

    private func scheduleShow() {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, anchorHovered else { return }
            isPresented = true
        }
    }

    private func scheduleHide() {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            // Small grace period lets the pointer move from the control into
            // the anchored card without creating tooltip flicker.
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled, !anchorHovered, !cardHovered else { return }
            isPresented = false
        }
    }
}

private struct ActionExplainerCard: View {
    let spec: ActionExplainerSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(spec.title)
                .font(.headline)

            Text(spec.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let effect = spec.effect {
                explainerRow(label: "DOES", value: effect)
            }
            if let nonEffect = spec.nonEffect {
                explainerRow(label: "DOES NOT", value: nonEffect)
            }
            if let target = spec.target {
                explainerRow(label: "TARGET", value: target, monospaced: true)
            }
            if let authority = spec.authority {
                explainerRow(label: "AUTHORITY", value: authority)
            }
            if let shortcut = spec.shortcut {
                explainerRow(label: "SHORTCUT", value: shortcut, monospaced: true)
            }
        }
        .padding(13)
        .frame(width: 330, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private func explainerRow(
        label: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilitySummary: String {
        [
            spec.title,
            spec.summary,
            spec.effect.map { "Does: \($0)" },
            spec.nonEffect.map { "Does not: \($0)" },
            spec.target.map { "Target: \($0)" },
            spec.authority.map { "Authority: \($0)" },
            spec.shortcut.map { "Shortcut: \($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: ". ")
    }
}

extension View {
    /// Rich hover explanation with a native `.help` fallback.
    func actionExplainer(
        _ spec: ActionExplainerSpec,
        delayMilliseconds: UInt64 = 420
    ) -> some View {
        modifier(
            ActionExplainerModifier(
                spec: spec,
                delayNanoseconds: max(1, delayMilliseconds) * 1_000_000
            )
        )
    }
}
#endif
