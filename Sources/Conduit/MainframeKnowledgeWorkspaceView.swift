#if os(macOS)
import ConduitCore
import SwiftUI

struct MainframeKnowledgeWorkspaceView: View {
    @StateObject private var model: MainframeKnowledgeWorkspaceModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var headingTarget: String?

    init(root: URL) {
        _model = StateObject(wrappedValue: MainframeKnowledgeWorkspaceModel(root: root))
    }

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.line)
            HSplitView {
                MainframeKnowledgeTreeView(model: model)
                    .environmentObject(themeStore)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

                centerSurface
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

                contextualInspector
                    .frame(minWidth: 245, idealWidth: 285, maxWidth: 340)
            }
        }
        .background(palette.app)
        .sheet(isPresented: $model.quickOpenPresented) {
            MainframeQuickOpenSheet(model: model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.searchPresented) {
            MainframeSearchSheet(model: model, headingTarget: $headingTarget)
                .environmentObject(themeStore)
        }
        .task {
            await model.bootstrap()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MainFrame knowledge workspace")
    }

    private var header: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(!model.canGoBack)
                    .help("Back")
                    .accessibilityLabel("Back")
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(!model.canGoForward)
                    .help("Forward")
                    .accessibilityLabel("Forward")

                breadcrumbs
                    .layoutPriority(1)

                Spacer(minLength: 8)

                Picker("Explore surface", selection: $model.surface) {
                    ForEach(MainframeKnowledgeSurface.allCases) { surface in
                        Label(surface.title, systemImage: surface.symbol).tag(surface)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 310)
                .accessibilityLabel("Explore surface")

                Button {
                    model.quickOpenPresented = true
                } label: {
                    Label("Open", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("p", modifiers: [.command])
                .help("Quick Open (Command-P)")

                Button {
                    model.searchPresented = true
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .help("Deterministic Find (Command-Shift-F)")

                Menu {
                    MainframeRecentMenuContent(model: model)
                } label: {
                    Label("Recent", systemImage: "clock")
                }
                .menuStyle(.borderlessButton)

                Button {
                    Task { await model.rebuildDerivedState() }
                } label: {
                    if model.isIndexing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.isIndexing)
                .help("Rebuild bounded read-only index")
                .accessibilityLabel("Rebuild read-only index")
            }

            statusStrip
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface)
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.breadcrumbPaths().enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(palette.faint)
                            .accessibilityHidden(true)
                    }
                    Button(crumb.label) {
                        model.openBreadcrumb(crumb.path)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(index == model.breadcrumbPaths().count - 1 ? palette.text : palette.dim)
                    .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .accessibilityLabel("Breadcrumbs")
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            Label("Read only", systemImage: "lock")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.dim)
            if let content = model.contentIndex {
                Text("\(content.filesystemEntries.count) paths · \(content.records.count) text files · \(ByteCountFormatter.string(fromByteCount: Int64(content.bytesIndexed), countStyle: .file)) indexed")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(palette.faint)
                if content.mayBeIncomplete {
                    Label("bounded", systemImage: "exclamationmark.triangle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.dim)
                        .help("The filesystem or content corpus reached a configured bound. Find and Graph may be incomplete.")
                }
                if content.skippedNonText > 0 || content.skippedTooLarge > 0 {
                    Text("\(content.skippedNonText) non-text · \(content.skippedTooLarge) oversized skipped")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                }
            } else if model.isIndexing {
                Text("Building bounded derived index…")
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
            }
            if let error = model.indexError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
                    .help(error)
            }
            Spacer()
            switch model.surface {
            case .reader:
                Text("Source truth: MainFrame files")
            case .graph:
                Text("Graph: explored projection, not authority")
            case .workstation:
                Text("Signals: observed or explicitly sourced")
            }
        }
        .font(.caption2)
        .foregroundStyle(palette.faint)
    }

    @ViewBuilder
    private var centerSurface: some View {
        switch model.surface {
        case .reader:
            MainframeMarkdownReaderView(model: model, headingTarget: $headingTarget)
                .environmentObject(themeStore)
        case .graph:
            MainframeGraphWorkspaceView(model: model)
                .environmentObject(themeStore)
        case .workstation:
            MainframeWorkstationView(model: model)
                .environmentObject(themeStore)
        }
    }

    @ViewBuilder
    private var contextualInspector: some View {
        switch model.surface {
        case .reader:
            MainframeDocumentInspectorView(model: model, headingTarget: $headingTarget)
                .environmentObject(themeStore)
        case .graph:
            MainframeGraphInspectorView(model: model)
                .environmentObject(themeStore)
        case .workstation:
            MainframeWorkstationContextView(model: model)
                .environmentObject(themeStore)
        }
    }
}

private struct MainframeWorkstationContextView: View {
    @ObservedObject var model: MainframeKnowledgeWorkspaceModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Workstation evidence rules")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                rule("Lifecycle", "State, goal, next action, WIP class and tags come from validated lifecycle records.")
                rule("Tasks", "Counts use exact recorded Conduit project scope. A task history is not a completion claim.")
                rule("Receipts", "Only Conduit session receipts explicitly naming the project slug enter the evidence trail.")
                rule("Attention", "Visit counts show navigation in this Explorer session, not importance or urgency.")
                rule("Checklists", "Completion counts appear only when a source contains a literal task-list denominator.")
                Divider().overlay(palette.line)
                Text("Not inferred")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Text("No universal project percentage, no health score, no progress from elapsed time, no review approval from a merge, and no success from terminal prose.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if model.indexMayBeIncomplete {
                    Divider().overlay(palette.line)
                    Label("Bounded source", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.dim)
                    Text("Some indexed counts and relationships may be incomplete because the corpus reached a bound.")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(palette.surface)
    }

    private func rule(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.text)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
