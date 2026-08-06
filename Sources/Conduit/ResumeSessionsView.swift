#if os(macOS)
import ConduitCore
import SwiftUI

/// Durable tmux sessions Conduit can reattach to.
///
/// Everything tmux reports is listed, including sessions Conduit cannot
/// identify — hiding those would imply the server is emptier than it is.
/// Identity comes from options recorded on the session, never from guessing at
/// its name.
struct ResumeSessionsSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false
    @State private var legacyAdoption: LegacyAdoptionSelection?

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.line)
            content
            Divider().overlay(palette.line)
            footer
        }
        .frame(minWidth: 620, minHeight: 380)
        .background(palette.canvas)
        .task { await refresh() }
        .sheet(item: $legacyAdoption) { selection in
            LegacySessionScopeSheet(session: selection.session)
                .environmentObject(model)
                .environmentObject(themeStore)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Resume a session")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Text("Durable tmux sessions this Mac is still running")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
            Spacer()
            Button("Refresh") { Task { await refresh() } }
                .disabled(isRefreshing)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        let rows = model.resumableSessions
        if rows.isEmpty {
            VStack(spacing: 6) {
                Text(isRefreshing ? "Looking for sessions…" : "No durable sessions found")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.dim)
                if !isRefreshing {
                    Text(model.discoveryNote ?? "tmux is not running any Conduit sessions on this Mac.")
                        .font(.caption)
                        .foregroundStyle(palette.faint)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.session.tmuxName) { row in
                        sessionRow(row)
                        Divider().overlay(palette.lineSoft)
                    }
                }
            }
        }
    }

    private func sessionRow(_ row: ResumableSession) -> some View {
        let session = row.session
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title(for: row))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.text)
                    if session.attachedClients > 0 {
                        Text("attached elsewhere")
                            .font(.system(size: 10))
                            .foregroundStyle(palette.dim)
                    }
                }
                Text(subtitle(for: row))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Text(session.tmuxName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.faint)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            action(for: row)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func action(for row: ResumableSession) -> some View {
        if case .malformed = row.session.taskSessionBinding {
            Text("needs attention")
                .font(.system(size: 10))
                .foregroundStyle(palette.faint)
                .help("The tmux task binding is malformed. Conduit will not attach or overwrite it.")
        } else if case .alreadyOpen = row.relation {
            Text("open")
                .font(.system(size: 10))
                .foregroundStyle(palette.faint)
        } else if row.session.projectPath == nil {
            Button("Choose Scope…") {
                legacyAdoption = LegacyAdoptionSelection(session: row.session)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.accent)
            .help("Explicitly choose the MainFrame scope for this legacy session")
        } else {
            Button("Resume") {
                model.resume(row.session)
                dismiss()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.accent)
        }
    }

    private func title(for row: ResumableSession) -> String {
        row.session.agentName ?? "Unidentified session"
    }

    private func subtitle(for row: ResumableSession) -> String {
        var parts: [String] = []
        switch row.relation {
        case .resumableHere: parts.append("this project")
        case .alreadyOpen: parts.append("already open here")
        case .otherProject(let title): parts.append(title)
        case .unidentified: parts.append("no recorded project or agent")
        }
        if let created = row.session.createdAt {
            parts.append("started \(Self.relative.localizedString(for: created, relativeTo: Date()))")
        }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Resuming reattaches to a session that is still running; it does not replay or verify what happened in it.")
                .foregroundStyle(palette.dim)
            Text("Sessions with no recorded project or agent predate that record, or were created by something else — Conduit will not guess whose they are.")
                .foregroundStyle(palette.faint)
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(palette.rail)
    }

    private func refresh() async {
        isRefreshing = true
        await model.refreshDiscoveredSessions()
        isRefreshing = false
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct LegacyAdoptionSelection: Identifiable {
    let id = UUID()
    let session: DiscoveredSession
}

private struct LegacySessionScopeSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let session: DiscoveredSession

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Choose a scope for this legacy session")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Text("tmux did not record a project for \(session.tmuxName). Your choice creates local task metadata; Conduit will not infer a scope from the session name.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider().overlay(palette.line)

            List(model.projects) { project in
                Button {
                    if model.resume(session, adoptingInto: project) != nil {
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: project.isMainframeRoot ? "shippingbox" : "folder")
                            .foregroundStyle(palette.dim)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.metadata.title)
                                .foregroundStyle(palette.text)
                            Text(project.path.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(palette.faint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Adopt into \(project.metadata.title)")
            }
            .scrollContentBackground(.hidden)

            Divider().overlay(palette.line)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 460)
        .background(palette.canvas)
    }
}
#endif
