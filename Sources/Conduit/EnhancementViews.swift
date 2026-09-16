#if os(macOS)
import AppKit
import AVFoundation
import ConduitCore
import Foundation
import Speech
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            ConduitSheetHeader(
                title: "Conduit Doctor",
                subtitle: "Local command, path, and permission checks — not authentication, quota, or quality",
                systemImage: "stethoscope",
                trailing: {
                    Button("Refresh") { Task { await model.refreshHealth() } }
                }
            )
            Divider()
            List(model.healthResults) { result in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: result.state.systemImage)
                        .foregroundStyle(result.state.color)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(result.name)
                                .font(.headline)
                                .foregroundStyle(palette.text)
                            Spacer()
                            Text(result.state.displayName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(result.state.color)
                        }
                        Text(result.detail)
                            .font(.caption)
                            .foregroundStyle(palette.dim)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 3)
                .listRowBackground(palette.surface)
                .accessibilityElement(children: .combine)
            }
            .scrollContentBackground(.hidden)
            .background(palette.app)
        }
        .background(palette.app)
        .frame(width: 640, height: 480)
        .task { await model.refreshHealth() }
    }
}

struct ResourcePanelView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            ConduitSheetHeader(
                title: "Resource Deck",
                subtitle: "Local memory and loaded models",
                systemImage: "gauge.with.dots.needle.67percent",
                trailing: {
                    HStack(spacing: 8) {
                        Button("Activity Monitor") {
                            NSWorkspace.shared.open(
                                URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                            )
                        }
                        Button("Refresh") { Task { await model.refreshResources() } }
                    }
                }
            )
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Memory") {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(
                                value: model.resourceSnapshot.usedMemoryGB,
                                total: max(model.resourceSnapshot.totalMemoryGB, 1)
                            )
                            Text(String(
                                format: "%.1f GB used of %.1f GB",
                                model.resourceSnapshot.usedMemoryGB,
                                model.resourceSnapshot.totalMemoryGB
                            ))
                                .font(.caption)
                                .foregroundStyle(palette.dim)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Loaded Ollama models") {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.resourceSnapshot.ollamaModels.isEmpty {
                                Text("No loaded models detected.")
                                    .foregroundStyle(palette.dim)
                            } else {
                                ForEach(model.resourceSnapshot.ollamaModels, id: \.self) {
                                    Text($0)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(palette.text)
                                }
                                Button("Unload all detected models") {
                                    Task { await model.unloadOllamaModels() }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Largest processes") {
                        VStack(spacing: 6) {
                            ForEach(model.resourceSnapshot.topProcesses) { process in
                                HStack {
                                    Text(process.command)
                                        .lineLimit(1)
                                        .foregroundStyle(palette.text)
                                    Spacer()
                                    Text(String(format: "%.0f MB", process.residentMegabytes))
                                        .foregroundStyle(palette.dim)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(palette.app)
        }
        .background(palette.app)
        .frame(width: 680, height: 560)
        .task { await model.refreshResources() }
    }
}

private enum ContextBundlePreviewMode: String, CaseIterable {
    case stack
    case assembled
    case changes

    var displayName: String {
        switch self {
        case .stack: return "Stack"
        case .assembled: return "Assembled"
        case .changes: return "Changes"
        }
    }
}

struct ContextBundleView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var previewMode: ContextBundlePreviewMode = .stack
    @State private var sourceCandidate: ContextDocument?
    @State private var pinnedItems: [AgentContextItem] = []
    @State private var gitObservation: GitWorkspaceSnapshot?
    @State private var contextDiff: AgentContextDiff?
    @State private var latestSnapshot: AgentContextSnapshot?
    @State private var snapshotStatus: String?
    @State private var snapshotWorking = false
    @State private var gitObservationError: String?

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var taskTitle: String {
        model.selectedTaskSnapshot?.displayTitle
            ?? model.selectedProject?.metadata.title
            ?? "Context preview"
    }

    private var typedBundle: AgentContextBundle {
        ContextIDEBridge.buildBundle(
            title: taskTitle,
            mainframeRoot: model.settings.mainframeRoot,
            scopePath: model.selectedProject?.path,
            candidates: model.contextCandidates,
            selectedIDs: model.selectedContextIDs,
            pinnedItems: pinnedItems,
            gitSnapshot: gitObservation
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ConduitSheetHeader(
                title: "Context IDE",
                subtitle: "Inspect exactly what an agent can be given, where it came from, and what changed",
                systemImage: "square.stack.3d.up",
                onClose: { model.showContextBundle = false }
            )
            Divider().overlay(palette.line)

            contextToolbar
            Divider().overlay(palette.line)

            HSplitView {
                sourceList
                    .frame(minWidth: 300, idealWidth: 330)
                preview
                    .frame(minWidth: 560)
            }

            Divider().overlay(palette.line)
            footer
        }
        .background(palette.app)
        .frame(width: 1040, height: 700)
        .task(id: model.selectedProject?.path.path ?? "") {
            await refreshGitObservation()
            await refreshSnapshotComparison()
        }
        .onChange(of: model.selectedContextIDs) { _ in
            Task { await refreshSnapshotComparison() }
        }
        .onChange(of: pinnedItems) { _ in
            Task { await refreshSnapshotComparison() }
        }
        .sheet(item: $sourceCandidate) { document in
            let workRoot = model.settings.mainframeRoot
                ?? model.selectedProject?.path
                ?? document.url.deletingLastPathComponent()
            MainframeSourceWorkbenchView(
                root: workRoot,
                file: document.url,
                relativePath: ContextIDEBridge.displayPath(
                    document.url,
                    mainframeRoot: model.settings.mainframeRoot
                ),
                onPinContext: pinContextItem
            )
            .environmentObject(themeStore)
        }
    }

    private var contextToolbar: some View {
        HStack(spacing: 10) {
            Picker("Context preview", selection: $previewMode) {
                ForEach(ContextBundlePreviewMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 310)

            Spacer()

            if let gitObservation {
                Label(
                    gitObservation.branch ?? "detached",
                    systemImage: gitObservation.isDirty ? "arrow.triangle.branch" : "checkmark.circle"
                )
                .font(.caption.monospaced())
                .foregroundStyle(palette.dim)
                .help("HEAD \(gitObservation.headSHA)")
            } else if let gitObservationError {
                Text("Git: \(gitObservationError)")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
            }

            Button {
                Task {
                    await refreshGitObservation()
                    await refreshSnapshotComparison()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .actionExplainer(
                ActionExplainerSpec(
                    title: "Refresh Context Observations",
                    summary: "Re-read the project's read-only Git identity and compare this proposed context with the last explicit snapshot.",
                    effect: "Updates derived context observations in this preview.",
                    nonEffect: "Does not edit MainFrame, stage Git changes, or send anything to an agent.",
                    target: model.selectedProject?.path.path,
                    authority: "Filesystem + read-only Git observation"
                )
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.rail)
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CONTEXT SOURCES")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.9)
                    .foregroundStyle(palette.faint)
                Spacer()
                Text("\(model.selectedContextIDs.count) selected")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(palette.faint)
            }
            .padding(12)

            Divider().overlay(palette.line)

            List(model.contextCandidates) { document in
                HStack(alignment: .top, spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { model.selectedContextIDs.contains(document.id) },
                        set: { selected in
                            model.setContextDocument(document, selected: selected)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(document.label)
                                .foregroundStyle(palette.text)
                            Text(document.trustLabel)
                                .font(.caption2)
                                .foregroundStyle(palette.dim)
                            Text(ContextIDEBridge.displayPath(
                                document.url,
                                mainframeRoot: model.settings.mainframeRoot
                            ))
                                .font(.caption2.monospaced())
                                .foregroundStyle(palette.faint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Spacer(minLength: 4)

                    Button {
                        sourceCandidate = document
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Inspect or safely edit this text source")
                    .actionExplainer(
                        ActionExplainerSpec(
                            title: "Open Source Workbench",
                            summary: "Inspect source, line identity, outline, Git evidence, and allowlisted explicit edits.",
                            effect: "Opens a separate source workbench for this exact file.",
                            nonEffect: "Opening the workbench does not modify the file or send it to an agent.",
                            target: document.url.path,
                            authority: "Filesystem source"
                        )
                    )
                }
                .listRowBackground(palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(palette.app)

            if !pinnedItems.isEmpty {
                Divider().overlay(palette.line)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("PINNED FROM SOURCE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(palette.faint)
                        Spacer()
                        Button("Clear") { pinnedItems = [] }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    ForEach(pinnedItems) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.kind == .selection ? "selection.pin.in.out" : "pin")
                                .foregroundStyle(palette.faint)
                            Text(item.locationLabel)
                                .font(.caption2.monospaced())
                                .foregroundStyle(palette.dim)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                pinnedItems.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(10)
                .background(palette.rail)
            }
        }
        .background(palette.app)
    }

    @ViewBuilder
    private var preview: some View {
        switch previewMode {
        case .stack:
            ContextStackView(bundle: typedBundle, title: "PROPOSED CONTEXT")
                .background(palette.sink)
        case .assembled:
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("ASSEMBLED BUNDLE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.faint)
                    Spacer()
                    Text("Existing attachment payload")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                }
                .padding(10)
                Divider().overlay(palette.line)
                ScrollView {
                    Text(model.contextPreview.isEmpty ? "Select context sources." : model.contextPreview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(model.contextPreview.isEmpty ? palette.faint : palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(palette.sink)
                if !pinnedItems.isEmpty {
                    Text("Pinned source locations are visible in the typed Context Stack but are not silently injected into the legacy assembled Markdown attachment. A future handoff path must admit them explicitly.")
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                        .padding(10)
                        .background(palette.rail)
                }
            }
        case .changes:
            contextChangesView
        }
    }

    private var contextChangesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CHANGES SINCE LAST SNAPSHOT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(palette.faint)
                        if let latestSnapshot {
                            Text("Snapshot \(latestSnapshot.createdAt.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption)
                                .foregroundStyle(palette.dim)
                        } else {
                            Text("No prior explicit snapshot for this repository/scope.")
                                .font(.caption)
                                .foregroundStyle(palette.dim)
                        }
                    }
                    Spacer()
                }

                if let contextDiff {
                    changeSection("ADDED", items: contextDiff.added, symbol: "plus.circle")
                    changeSection("REMOVED", items: contextDiff.removed, symbol: "minus.circle")
                    changedSection(contextDiff.changed)
                    if contextDiff.added.isEmpty && contextDiff.removed.isEmpty && contextDiff.changed.isEmpty {
                        Label("No context-item changes from the latest snapshot.", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(palette.dim)
                    }
                } else {
                    Text(latestSnapshot == nil
                        ? "Record a snapshot when this is the exact context you want to preserve as a handoff boundary."
                        : "Context comparison unavailable.")
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.sink)
    }

    @ViewBuilder
    private func changeSection(
        _ title: String,
        items: [AgentContextItem],
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) · \(items.count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.faint)
            ForEach(items) { item in
                Label(item.locationLabel, systemImage: symbol)
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.dim)
            }
        }
    }

    private func changedSection(_ changes: [AgentContextItemChange]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CHANGED · \(changes.count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.faint)
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 2) {
                    Label(change.current.locationLabel, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.dim)
                    if change.previous.revisionIdentity != change.current.revisionIdentity {
                        Text("identity: \(change.previous.revisionIdentity ?? "unknown") → \(change.current.revisionIdentity ?? "unknown")")
                            .font(.caption2.monospaced())
                            .foregroundStyle(palette.faint)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if snapshotWorking {
                ProgressView().controlSize(.small)
            }
            if let snapshotStatus {
                Text(snapshotStatus)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
            } else {
                Text("Previewing context does not persist or send it.")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
            }

            Spacer()

            Button("Record Snapshot") {
                Task { await recordSnapshot() }
            }
            .buttonStyle(.bordered)
            .disabled(snapshotWorking || typedBundle.items.isEmpty)
            .actionExplainer(
                ActionExplainerSpec(
                    title: "Record Context Snapshot",
                    summary: "Persist the exact typed context identities currently shown so later handoffs can be diffed against them.",
                    effect: "Writes one JSON snapshot under ~/.conduit/context-snapshots.",
                    nonEffect: "Does not modify MainFrame project files, Git state, or send context to an agent.",
                    target: AgentContextSnapshotStore.defaultDirectory().path,
                    authority: "Explicit local Conduit record"
                )
            )

            Button("Attach Bundle") { model.attachContextBundle() }
                .buttonStyle(.borderedProminent)
                .disabled(model.contextPreview.isEmpty)
                .actionExplainer(
                    ActionExplainerSpec(
                        title: "Attach Legacy Context Bundle",
                        summary: "Attach the assembled Markdown bundle built from the checked context-source documents.",
                        effect: "Uses the existing explicit Conduit bundle attachment path.",
                        nonEffect: "Does not silently include Source Workbench pins, semantic nominations, or unselected documents.",
                        target: model.selectedProject?.path.path,
                        authority: "Operator-selected filesystem context"
                    )
                )
        }
        .padding(12)
        .background(palette.surface)
    }

    private func pinContextItem(_ item: AgentContextItem) {
        if let index = pinnedItems.firstIndex(where: { $0.id == item.id }) {
            pinnedItems[index] = item
        } else {
            pinnedItems.append(item)
        }
        previewMode = .stack
    }

    private func refreshGitObservation() async {
        guard let path = model.selectedProject?.path else {
            gitObservation = nil
            gitObservationError = nil
            return
        }
        let result = await Task.detached(priority: .utility) { () -> Result<GitWorkspaceSnapshot, Error> in
            do {
                return .success(try GitWorkspaceInspector().snapshot(startingAt: path))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let snapshot):
            gitObservation = snapshot
            gitObservationError = nil
        case .failure(let error):
            gitObservation = nil
            gitObservationError = error.localizedDescription
        }
    }

    private func refreshSnapshotComparison() async {
        let bundle = typedBundle
        let store = AgentContextSnapshotStore(
            directory: AgentContextSnapshotStore.defaultDirectory()
        )
        let result = await Task.detached(priority: .utility) { () -> Result<(AgentContextSnapshot?, AgentContextDiff?), Error> in
            do {
                let latest = try store.latest(matching: bundle)
                let diff = latest.map { AgentContextDiffer.diff(previous: $0.bundle, current: bundle) }
                return .success((latest, diff))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let pair):
            latestSnapshot = pair.0
            contextDiff = pair.1
        case .failure(let error):
            latestSnapshot = nil
            contextDiff = nil
            snapshotStatus = "Snapshot comparison failed: \(error.localizedDescription)"
        }
    }

    private func recordSnapshot() async {
        guard !typedBundle.items.isEmpty else { return }
        snapshotWorking = true
        let bundle = typedBundle
        let store = AgentContextSnapshotStore(
            directory: AgentContextSnapshotStore.defaultDirectory()
        )
        let result = await Task.detached(priority: .utility) { () -> Result<AgentContextSnapshot, Error> in
            do {
                return .success(try store.record(bundle))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let snapshot):
            snapshotStatus = "Recorded context snapshot \(snapshot.id.uuidString.prefix(8))."
            latestSnapshot = snapshot
            contextDiff = AgentContextDiffer.diff(previous: snapshot.bundle, current: bundle)
        case .failure(let error):
            snapshotStatus = "Snapshot failed: \(error.localizedDescription)"
        }
        snapshotWorking = false
    }
}

#endif
