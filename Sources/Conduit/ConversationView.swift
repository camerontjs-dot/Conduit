#if os(macOS)
import ConduitCore
import SwiftUI

/// A conservative session thread. Native prompts are exact Conduit records;
/// generic output blocks are explicitly labelled projections of rendered Raw.
struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var runtime: TerminalRuntime
    @ObservedObject private var controller: TerminalSessionController

    init(runtime: TerminalRuntime) {
        self._runtime = ObservedObject(wrappedValue: runtime)
        self._controller = ObservedObject(wrappedValue: runtime.controller)
    }

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                activityHeader(at: timeline.date)
            }
            Divider().overlay(palette.line)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        boundaryCard
                        if !model.selectedTaskConversationDiagnostics.isEmpty {
                            retainedHistoryDiagnosticCard
                        }
                        if case .failed(let detail)? =
                            model.selectedTaskConversationRetentionState {
                            retentionFailureCard(detail)
                        }
                        ForEach(runtime.presentationEvents) { event in
                            eventView(event)
                                .id(event.id)
                        }
                        if runtime.isAwaitingAgentOutput,
                           runtime.activeOutputEventID == nil {
                            waitingForVisibleOutputCard
                        }
                        if let notice = runtime.conversationCaptureNotice {
                            captureNoticeCard(notice)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: runtime.presentationEvents.count) { _ in
                    guard let last = runtime.presentationEvents.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: latestOutputCharacterCount) { _ in
                    guard let eventID = runtime.activeOutputEventID else { return }
                    proxy.scrollTo(eventID, anchor: .bottom)
                }
            }
        }
        .background(palette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(runtime.descriptor.agent.name) conversation")
    }

    private func activityHeader(at date: Date) -> some View {
        let state = controller.visualState(at: date)
        return HStack(spacing: 8) {
            AgentSpriteView(
                profile: runtime.descriptor.agent,
                state: state,
                frameSize: CGSize(width: 30, height: 34)
            )
            Circle()
                .fill(palette.color(forTerminalState: state))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(runtime.descriptor.agent.name)
                .font(.subheadline.bold())
                .foregroundStyle(palette.text)
            Text(state.label)
                .font(.caption)
                .foregroundStyle(palette.dim)
            Text("· \(controller.backendLabel)")
                .font(.caption.monospaced())
                .foregroundStyle(palette.faint)
            if let output = controller.lastOutputAt {
                Text("· output \(relativeLabel(from: output, to: date))")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
            }
            Spacer(minLength: 4)
            Button("Open Raw") {
                runtime.selectedSurface = .raw
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.accent)
            .accessibilityHint("Opens the live PTY view and direct CLI controls")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(runtime.descriptor.agent.name), \(state.label), \(controller.backendLabel)"
        )
    }

    private var boundaryCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(palette.dim)
            VStack(alignment: .leading, spacing: 4) {
                Text("Raw terminal remains authoritative")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text("Prompts are exact Conduit records. Rendered Raw output is a best-effort view labelled Derived from Raw; it may include tool logs, prompt echo, or terminal chrome. Approvals and exact terminal state remain in Raw.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(palette.lineSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var retainedHistoryDiagnosticCard: some View {
        Label(
            "\(model.selectedTaskConversationDiagnostics.count) retained-history record(s) could not be projected. Valid records remain visible; source bytes were preserved.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(palette.dim)
        .padding(12)
        .background(palette.lineSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func retentionFailureCard(_ detail: String) -> some View {
        Label(
            "\(detail) This thread may include volatile on-screen events that have not been confirmed retained.",
            systemImage: "externaldrive.badge.exclamationmark"
        )
        .font(.caption)
        .foregroundStyle(palette.dim)
        .padding(12)
        .background(palette.lineSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func eventView(_ event: SessionPresentationEvent) -> some View {
        switch event.kind {
        case .sessionOpened(let entry):
            sessionOpenedCard(entry, event: event)
        case .userPrompt(let prompt):
            promptCard(prompt, event: event)
        case .agentOutput(let output):
            agentOutputCard(output, event: event)
        }
    }

    private var waitingForVisibleOutputCard: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent activity")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text("Waiting for visible terminal output. This does not expose or infer private chain-of-thought.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
        }
        .padding(12)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 680, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func captureNoticeCard(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(palette.dim)
            VStack(alignment: .leading, spacing: 4) {
                Text("Conversation capture stopped")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Open Raw") {
                runtime.selectedSurface = .raw
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.accent)
        }
        .padding(12)
        .background(palette.lineSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 720, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func agentOutputCard(
        _ output: AgentVisibleOutput,
        event: SessionPresentationEvent
    ) -> some View {
        let isCurrentCapture = runtime.activeOutputEventID == event.id
        let stateLabel = output.state == .live && !isCurrentCapture
            ? "Capture interrupted"
            : output.state.displayName

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "terminal")
                    .foregroundStyle(palette.dim)
                Text("Rendered Raw output")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text("· \(stateLabel)")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                Spacer(minLength: 4)
                Button("Open Raw") {
                    runtime.selectedSurface = .raw
                }
                .buttonStyle(.borderless)
                .foregroundStyle(palette.accent)
            }
            Text(output.text)
                .font(.body)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(output.extraction.displayName)
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                if output.truncated {
                    Text("· older projected text omitted")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                }
                Spacer(minLength: 4)
                authorityLine(event)
            }
        }
        .padding(12)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func sessionOpenedCard(
        _ entry: SessionEntry,
        event: SessionPresentationEvent
    ) -> some View {
        let title: String
        let detail: String
        switch entry {
        case .started(let agentName, let requestedBackend):
            title = "Launch requested for \(agentName)"
            detail = "Requested backend: \(requestedBackend). This record does not prove that process attach succeeded; actual runtime state is shown above."
        case .resumed(let agentName, let tmuxName, let attachedElsewhere):
            title = "Reattach requested for \(agentName)"
            detail = "Requested tmux \(tmuxName)\(attachedElsewhere ? "; another client was already attached" : ""). This record does not prove that attach succeeded. Earlier raw activity was not replayed into this thread."
        }

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(palette.dim)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                authorityLine(event)
            }
        }
        .padding(12)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func promptCard(
        _ prompt: SubmittedPrompt,
        event: SessionPresentationEvent
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .forwardedTerminalOutput(let sourceAgentName) = prompt.origin {
                Label(
                    "Forwarded unverified terminal output from \(sourceAgentName)",
                    systemImage: "arrowshape.turn.up.right"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.dim)
            }
            if !prompt.text.isEmpty {
                Text(prompt.text)
                    .font(.body)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !prompt.attachmentPaths.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(prompt.attachmentPaths, id: \.self) { path in
                        Label(path, systemImage: "paperclip")
                            .font(.caption.monospaced())
                            .foregroundStyle(palette.dim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                    }
                }
            }
            HStack(spacing: 6) {
                deliveryMark(prompt.delivery)
                Spacer(minLength: 4)
                authorityLine(event)
            }
        }
        .padding(12)
        .background(palette.accentSoft)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    palette.accent.opacity(0.35),
                    style: prompt.origin.isForwarded
                        ? StrokeStyle(lineWidth: 1, dash: [4, 3])
                        : StrokeStyle(lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 680, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    private func deliveryMark(_ delivery: PromptDeliveryState) -> some View {
        let symbol: String
        let color: Color
        switch delivery {
        case .queued:
            symbol = "clock"
            color = palette.dim
        case .delivered:
            symbol = "checkmark"
            color = palette.ink
        case .failed:
            symbol = "exclamationmark.triangle"
            color = .red
        }
        return Label(delivery.displayName, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }

    private func authorityLine(_ event: SessionPresentationEvent) -> some View {
        Text("\(event.authority.displayName) · \(event.occurredAt.formatted(date: .omitted, time: .shortened))")
            .font(.caption2)
            .foregroundStyle(palette.faint)
    }

    private func relativeLabel(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 2 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

    private var latestOutputCharacterCount: Int {
        guard let eventID = runtime.activeOutputEventID,
              let event = runtime.presentationEvents.first(where: {
                  $0.id == eventID
              }),
              case .agentOutput(let output) = event.kind
        else { return 0 }
        return output.text.count
    }
}

private extension PromptOrigin {
    var isForwarded: Bool {
        if case .forwardedTerminalOutput = self { return true }
        return false
    }
}

/// Read-only projection used when a sidebar task has no open runtime. Selecting
/// history never launches, attaches, or sends anything.
struct ConversationHistoryView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let events: [SessionPresentationEvent]

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(events) { event in
                historyEvent(event)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func historyEvent(_ event: SessionPresentationEvent) -> some View {
        switch event.kind {
        case .sessionOpened(let entry):
            historyBoundary(entry, event: event)
        case .userPrompt(let prompt):
            historyPrompt(prompt, event: event)
        case .agentOutput(let output):
            historyOutput(output, event: event)
        }
    }

    private func historyBoundary(
        _ entry: SessionEntry,
        event: SessionPresentationEvent
    ) -> some View {
        let title: String
        switch entry {
        case .started(let agentName, _):
            title = "Launch requested for \(agentName)"
        case .resumed(let agentName, let tmuxName, let attachedElsewhere):
            title = "Reattach requested for \(agentName) · \(tmuxName)"
                + (attachedElsewhere ? " · another client was attached" : "")
        }
        return Label(title, systemImage: "bolt.horizontal.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.dim)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(palette.lineSoft)
            .clipShape(Capsule())
            .accessibilityLabel(
                "\(title), \(event.authority.displayName), \(event.occurredAt.formatted())"
            )
    }

    private func historyPrompt(
        _ prompt: SubmittedPrompt,
        event: SessionPresentationEvent
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if case .forwardedTerminalOutput(let sourceAgentName) = prompt.origin {
                Label(
                    "Forwarded unverified terminal output from \(sourceAgentName)",
                    systemImage: "arrowshape.turn.up.right"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.dim)
            }
            if !prompt.text.isEmpty {
                Text(prompt.text)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(prompt.attachmentPaths, id: \.self) { path in
                Label(path, systemImage: "paperclip")
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
            HStack(spacing: 6) {
                historicalDeliveryMark(prompt.delivery)
                Spacer(minLength: 4)
                Text(
                    "\(event.authority.displayName) · "
                        + event.occurredAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                )
                .font(.caption2)
                .foregroundStyle(palette.faint)
            }
        }
        .padding(12)
        .background(palette.accentSoft)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    palette.accent.opacity(0.35),
                    style: prompt.origin.isForwarded
                        ? StrokeStyle(lineWidth: 1, dash: [4, 3])
                        : StrokeStyle(lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 680, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func historyOutput(
        _ output: AgentVisibleOutput,
        event: SessionPresentationEvent
    ) -> some View {
        let stateLabel = output.state == .live
            ? "Capture interrupted"
            : output.state.displayName

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Rendered Raw output", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.dim)
                Text("· \(stateLabel)")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
            Text(output.text)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("This projection may include prompt echo, tool output, or terminal chrome.")
                .font(.caption2)
                .foregroundStyle(palette.faint)
            HStack(spacing: 6) {
                Text(output.extraction.displayName)
                if output.truncated {
                    Text("· older projected text omitted")
                }
                Spacer(minLength: 4)
                Text(
                    "\(event.authority.displayName) · "
                        + event.occurredAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                )
            }
                .font(.caption2)
                .foregroundStyle(palette.faint)
        }
        .padding(12)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historicalDeliveryMark(
        _ delivery: PromptDeliveryState
    ) -> some View {
        let label: String
        let symbol: String
        let color: Color
        switch delivery {
        case .queued:
            label = "Delivery unconfirmed"
            symbol = "questionmark.circle"
            color = palette.dim
        case .delivered:
            label = delivery.displayName
            symbol = "checkmark"
            color = palette.ink
        case .failed:
            label = delivery.displayName
            symbol = "exclamationmark.triangle"
            color = .red
        }
        return Label(label, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .help(
                delivery == .queued
                    ? "The prior process ended before Conduit retained a delivery result. This prompt is not queued for automatic resend."
                    : delivery.displayName
            )
    }
}
#endif
