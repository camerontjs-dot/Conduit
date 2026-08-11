#if os(macOS)
import ConduitCore
import SwiftUI

/// Conversation-first presentation over one unchanged terminal runtime.
struct SessionSurfaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let runtime: TerminalRuntime?

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let runtime {
                ActiveSessionSurface(runtime: runtime)
            } else if let task = model.selectedTaskSnapshot,
                      let availability = model.selectedTaskAvailability {
                TaskHistorySurface(task: task, availability: availability)
            } else {
                ConversationEmptyState()
            }
        }
        .background(palette.sink)
    }
}

private struct ActiveSessionSurface: View {
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
            surfacePicker
            Divider().overlay(palette.line)
            // Keep the live PTY mounted under Conversation so capture and
            // buffer continuity survive surface switches. Raw only raises it.
            ZStack {
                rawTerminal
                    .opacity(runtime.selectedSurface == .raw ? 1 : 0)
                    .allowsHitTesting(runtime.selectedSurface == .raw)
                    .accessibilityHidden(runtime.selectedSurface != .raw)

                if runtime.selectedSurface == .conversation {
                    ConversationView(runtime: runtime)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if runtime.selectedSurface == .conversation {
                Divider().overlay(palette.line)
                if controller.lifecycle.isTerminal {
                    terminalRuntimeFooter
                } else {
                    ComposerView()
                }
            }
        }
        .onChange(of: runtime.selectedSurface) { surface in
            if surface == .conversation {
                runtime.resyncConversationCapture()
            } else {
                // Pull once while entering Raw so the projection stays warm.
                controller.refreshConversationCapture()
            }
        }
    }

    private var terminalRuntimeFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: runtimeFooterCopy.symbol)
                .foregroundStyle(palette.dim)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(runtimeFooterCopy.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text(runtimeFooterCopy.detail)
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if controller.lifecycle == .detached,
               let taskSessionID = runtime.descriptor.taskSessionID {
                Button("Reconnect") {
                    model.reconnectTask(taskSessionID)
                }
                .buttonStyle(.borderedProminent)
            } else if runtime.descriptor.recordsIdentity {
                Button("Restart Runtime") {
                    _ = model.restartSession(runtime)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("New Task") {
                model.showNewTask = true
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(palette.surface)
        .accessibilityElement(children: .contain)
    }

    private var runtimeFooterCopy: (
        title: String,
        detail: String,
        symbol: String
    ) {
        if let launchIssue = controller.launchIssue {
            return (
                "Failed to launch · Raw retained",
                "\(launchIssue.localizedDescription) Inspect Raw; a blocked launch does not establish the task outcome.",
                "exclamationmark.triangle"
            )
        }
        switch controller.lifecycle {
        case .detached:
            return (
                "Detached · reconnect required",
                "Composer is unavailable. Raw retains the detached terminal buffer; reconnect is always explicit.",
                "bolt.slash.circle"
            )
        case .exited(let code) where (code ?? 0) != 0:
            return (
                "Failed · Raw retained",
                "The process exited with code \(code ?? 0). Inspect Raw; this does not establish the task outcome.",
                "exclamationmark.triangle"
            )
        case .exited:
            return (
                "Ended · Raw retained",
                "The runtime ended and is not accepting composer messages. Ending does not mean the task completed.",
                "stop.circle"
            )
        case .idle, .launching, .running:
            return (
                "Runtime state changed",
                "Raw remains the terminal authority.",
                "info.circle"
            )
        }
    }

    private var surfacePicker: some View {
        HStack(spacing: 10) {
            Picker("Session view", selection: $runtime.selectedSurface) {
                ForEach(SessionSurface.allCases, id: \.self) { surface in
                    Text(surface.displayName).tag(surface)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 230)
            .accessibilityLabel("Session view")

            Text(surfaceAuthorityLabel)
                .font(.caption2)
                .foregroundStyle(palette.faint)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(palette.rail)
    }

    private var surfaceAuthorityLabel: String {
        guard runtime.selectedSurface == .raw else {
            return "Conversation · Raw authoritative"
        }

        if controller.launchIssue != nil {
            return "Raw · launch blocked buffer"
        }

        switch controller.visualState(at: Date()) {
        case .launching:
            return "Raw · PTY starting"
        case .working, .running:
            return "Raw · live PTY authority"
        case .detached:
            return "Raw · detached buffer"
        case .exited:
            return "Raw · exited buffer"
        case .failed:
            return "Raw · failed exit buffer"
        }
    }

    private var rawTerminal: some View {
        TerminalHostView(
            controller: controller,
            theme: TerminalTheme(palette: palette),
            claimsFocus: runtime.selectedSurface == .raw
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.line, lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Raw terminal")
    }
}

private struct ConversationEmptyState: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 42))
                .foregroundStyle(palette.dim)
            Text("Start a task")
                .font(.title2.bold())
                .foregroundStyle(palette.text)
            Text("Choose an agent and a MainFrame scope. Conduit will open the task in Conversation, with its real terminal available in Raw.")
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.dim)
                .frame(maxWidth: 480)
            HStack(spacing: 8) {
                Button("New Task") {
                    model.showNewTask = true
                }
                .buttonStyle(.borderedProminent)
                Button("Browse Projects") {
                    model.showProjectBrowser = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Read-only continuity shown after an app relaunch, detach, or close.
/// Conversation content is local and source-labelled; selection has no process
/// side effects.
private struct TaskHistorySurface: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let task: TaskSessionSnapshot
    let availability: TaskSessionAvailability

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var status: (label: String, detail: String, symbol: String) {
        switch availability {
        case .running:
            return ("Running", "The live runtime is available in this app process.", "circle.fill")
        case .reconnectable:
            return ("Reconnectable", "A matching durable tmux runtime was observed.", "arrow.triangle.2.circlepath")
        case .recentClosed(let at, _):
            return (
                "Ended",
                "Runtime ended \(at.formatted(date: .abbreviated, time: .shortened)).",
                "stop.circle"
            )
        case .interrupted:
            return ("Interrupted", "The prior runtime is no longer attached.", "exclamationmark.circle")
        case .unavailable:
            return ("Unavailable", "The last detached runtime was not present in the latest successful discovery.", "questionmark.circle")
        case .unknown:
            return ("Unknown", "Runtime availability has not been established.", "questionmark.circle")
        }
    }

    private var emptyHistoryTitle: String {
        if !model.selectedTaskConversationDiagnostics.isEmpty {
            return "Retained history needs attention"
        }
        switch model.selectedTaskConversationRetentionState {
        case .loading:
            return "Loading local conversation history"
        case .pending:
            return "Finishing the local history write"
        case .failed:
            return "Local conversation history is unavailable"
        case .missingExpected:
            return "Expected local history is unavailable"
        case .legacyPreRetention:
            return "No retained thread for this task"
        case .persisted, .none:
            break
        }
        if task.conversationRetentionEnabled {
            return "Expected local history is unavailable"
        }
        return "No retained thread for this task"
    }

    private var emptyHistoryDetail: String {
        if !model.selectedTaskConversationDiagnostics.isEmpty {
            return "The retained thread could not be fully projected. Valid records remain visible when possible, source bytes were preserved, and Conduit will not substitute an invented transcript."
        }
        switch model.selectedTaskConversationRetentionState {
        case .loading:
            return "Conduit is reading this task's private append-only history off the UI thread."
        case .pending:
            return "The latest immutable revision is still being synchronized. Conduit will reload the durable projection before calling it retained."
        case .failed(let detail):
            return "\(detail) Volatile runtime content is not being presented as retained history."
        case .missingExpected:
            return "This task entered the local retention contract, but its conversation file is missing or unavailable. Conduit will not mislabel it as pre-retention or invent a transcript."
        case .legacyPreRetention:
            return "This task may predate local conversation retention, or no conversation event may have been recorded. Conduit will not invent an empty or complete transcript."
        case .persisted, .none:
            break
        }
        if task.conversationRetentionEnabled {
            return "This task entered the local retention contract, but no conversation event is available. Its history may have been removed or become unavailable. Conduit will not mislabel this as a pre-retention task or invent a transcript."
        }
        return "This task may predate local conversation retention, or no conversation event may have been recorded. Conduit will not invent an empty or complete transcript."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: status.symbol)
                        .font(.title2)
                        .foregroundStyle(palette.dim)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.displayTitle)
                            .font(.title2.bold())
                            .foregroundStyle(palette.text)
                        Text(status.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.dim)
                        Text(status.detail)
                            .font(.caption)
                            .foregroundStyle(palette.faint)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    metadataLine(
                        "Agent",
                        value: task.metadata.agentName ?? "Not recorded"
                    )
                    metadataLine(
                        "Scope",
                        value: model.selectedTaskProject?.metadata.title
                            ?? task.metadata.workspace.fallbackTitle
                    )
                    metadataLine(
                        "Last activity",
                        value: task.lastActivityAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                }
                .padding(14)
                .background(palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(palette.line, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.doc")
                        .foregroundStyle(palette.dim)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local conversation history")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.text)
                        Text("Conduit retains new prompts, local attachment references, and source-labelled rendered output under ~/.conduit/conversations. It does not copy a file merely because its path is attached, but text the CLI renders—including file contents or secrets—may be retained. Raw terminal bytes are not stored here, and terminal prose is not verification.")
                            .font(.caption)
                            .foregroundStyle(palette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .background(palette.lineSoft)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if model.selectedTaskConversationEvents.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "clock.badge.questionmark")
                            .foregroundStyle(palette.dim)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(emptyHistoryTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(palette.text)
                            Text(emptyHistoryDetail)
                                .font(.caption)
                                .foregroundStyle(palette.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .background(palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(palette.line, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Text("Conversation history")
                        .font(.headline)
                        .foregroundStyle(palette.text)
                    ConversationHistoryView(
                        events: model.selectedTaskConversationEvents
                    )
                }

                if !model.selectedTaskConversationDiagnostics.isEmpty {
                    Label(
                        "\(model.selectedTaskConversationDiagnostics.count) retained-history record(s) could not be projected. Source bytes were preserved.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .padding(12)
                    .background(palette.lineSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 10) {
                    if availability.kind == .reconnectable {
                        Button("Reconnect") {
                            model.reconnectTask(task.id)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("New Task") {
                        model.showNewTask = true
                    }
                    .buttonStyle(.bordered)
                    Button("Refresh Runtime Status") {
                        Task { await model.refreshDiscoveredSessions() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(palette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(task.displayTitle), \(status.label)")
    }

    private func metadataLine(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.faint)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(palette.dim)
                .textSelection(.enabled)
        }
    }
}
#endif
