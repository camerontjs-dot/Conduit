#if os(macOS)
import ConduitCore
import SwiftUI

/// Compact provider-reported activity embedded at the bottom of the current
/// OpenCode turn. The full Source Workbench remains the inspection surface.
///
/// This view observes only structured OpenCode activity. PTY-derived prose is
/// never parsed to manufacture tool history.
struct OpenCodeConversationActivityView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var client: OpenCodeHTTPClient
    let projectRoot: URL

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        if !client.conversationActivities.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "hammer")
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                    Text("Activity")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.dim)
                    Text("OpenCode reported")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                }

                ForEach(client.conversationActivities) { activity in
                    activityRow(activity)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func activityRow(_ activity: OpenCodeConversationActivity) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let toolName = activity.toolName, !toolName.isEmpty {
                    labeled("Tool", toolName)
                }
                if !activity.paths.isEmpty {
                    ForEach(activity.paths, id: \.self) { path in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(path)
                                .font(.caption.monospaced())
                                .foregroundStyle(palette.dim)
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            Button {
                                ConversationTranscriptActions.copy(path)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy path")

                            if let file = resolvableFile(path) {
                                Button("Workbench") {
                                    openWindow(
                                        id: "source-workbench",
                                        value: file.path
                                    )
                                }
                                .buttonStyle(.borderless)
                                .font(.caption2.weight(.semibold))
                                .help("Open this exact path in Source Workbench")
                            }
                        }
                    }
                }
                if let detail = activity.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.dim)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Provider-reported status · not independent verification")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: activity))
                    .font(.caption)
                    .foregroundStyle(color(for: activity))
                    .frame(width: 14)
                Text(activity.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(stateLabel(activity.state))
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(palette.sink.opacity(0.55))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.lineSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.faint)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(palette.dim)
                .textSelection(.enabled)
        }
    }

    /// Resolve only exact paths contained by this task's project scope. The
    /// Source Workbench performs its own MainFrame containment check when the
    /// window loads, so this remains a presentation preflight rather than a new
    /// filesystem authority.
    private func resolvableFile(_ rawPath: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let root = projectRoot.standardizedFileURL
        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed).standardizedFileURL
        } else {
            candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        }
        let rootPath = root.path
        let candidatePath = candidate.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath == rootPath || candidatePath.hasPrefix(prefix) else {
            return nil
        }
        return candidate
    }

    private func symbol(for activity: OpenCodeConversationActivity) -> String {
        switch activity.kind {
        case .tool:
            switch activity.state {
            case .running: return "gearshape.2"
            case .completed: return "checkmark.circle"
            case .failed: return "exclamationmark.triangle"
            case .pending: return "clock"
            case .observed: return "hammer"
            }
        case .patch:
            return "arrow.triangle.branch"
        }
    }

    private func color(for activity: OpenCodeConversationActivity) -> Color {
        activity.state == .failed ? .red : palette.dim
    }

    private func stateLabel(_ state: OpenCodeConversationActivity.State) -> String {
        switch state {
        case .pending: return "pending"
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .observed: return "observed"
        }
    }
}
#endif
