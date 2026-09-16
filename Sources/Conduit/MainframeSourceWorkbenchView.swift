#if os(macOS)
import AppKit
import ConduitCore
import Foundation
import SwiftUI

private enum MainframeSourceWorkbenchMode: String, CaseIterable {
    case inspect
    case edit
    case diff

    var displayName: String { rawValue.capitalized }
}

private enum MainframeSourceInspectorTab: String, CaseIterable {
    case outline
    case git
    case context

    var displayName: String { rawValue.capitalized }
}

private struct SourceGitEvidence: Sendable {
    let snapshot: GitWorkspaceSnapshot?
    let workingDiff: GitWorkspaceDiff?
    let stagedDiff: GitWorkspaceDiff?
    let history: [String]
    let headBlobIdentity: String?
    let workingTreeBlobIdentity: String?
    let error: String?
}

/// A compact source workbench for Conduit's Context IDE.
///
/// The important object is not "code editing" by itself. It is an exact source
/// location plus its repository identity, history, diff, diagnostics, and the
/// context that can be handed to an agent. Writes reuse the same explicit,
/// conflict-aware exact-file boundary as Explorer's qualified Markdown editor.
struct MainframeSourceWorkbenchView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let root: URL
    let file: URL
    let relativePath: String
    let onPinContext: ((AgentContextItem) -> Void)?

    @StateObject private var editor = MainframeSourceEditingSession()
    @State private var mode: MainframeSourceWorkbenchMode = .inspect
    @State private var inspectorTab: MainframeSourceInspectorTab = .outline
    @State private var selectedLine = 1
    @State private var jumpLine: Int?
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var diagnosticText = ""
    @State private var loadError: String?
    @State private var gitSnapshot: GitWorkspaceSnapshot?
    @State private var workingDiff: GitWorkspaceDiff?
    @State private var stagedDiff: GitWorkspaceDiff?
    @State private var gitHistory: [String] = []
    @State private var gitError: String?
    @State private var headBlobIdentity: String?
    @State private var workingTreeBlobIdentity: String?
    @State private var selectedLineBlame: GitWorkspaceBlame?
    @State private var gitRefreshing = false
    @State private var showSideDiff = false
    @State private var lastContextAction: String?

    init(
        root: URL,
        file: URL,
        relativePath: String,
        onPinContext: ((AgentContextItem) -> Void)? = nil
    ) {
        self.root = root
        self.file = file
        self.relativePath = relativePath
        self.onPinContext = onPinContext
    }

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var lines: [String] {
        editor.buffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var outline: MainframeSourceOutline {
        MainframeSourceOutlineExtractor.extract(source: editor.buffer, kind: editor.kind)
    }

    private var matchCount: Int {
        guard !findText.isEmpty else { return 0 }
        return editor.buffer.components(separatedBy: findText).count - 1
    }

    private var repositoryRelativePath: String? {
        guard let snapshot = gitSnapshot else { return nil }
        let repository = URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true)
            .standardizedFileURL.path
        let target = file.standardizedFileURL.path
        let prefix = repository.hasSuffix("/") ? repository : repository + "/"
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    private var selectedGitStatus: GitWorkspaceStatusEntry? {
        guard let path = repositoryRelativePath else { return nil }
        return gitSnapshot?.statusEntry(for: path)
    }

    private var contextActionsBlockedByUnsavedBuffer: Bool {
        editor.hasUnsavedChanges
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.line)
            commandBar
            Divider().overlay(palette.line)

            if let message = editor.statusMessage {
                statusBanner(message)
                Divider().overlay(palette.line)
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(palette.dim)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HSplitView {
                    sourceSurface
                        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                    inspector
                        .frame(minWidth: 270, idealWidth: 320, maxWidth: 410, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 1020, minHeight: 700)
        .background(palette.app)
        .task(id: file.standardizedFileURL.path) {
            loadSource()
            await refreshGit()
            await refreshBlame()
        }
        .onChange(of: selectedLine) { _ in
            Task { await refreshBlame() }
        }
        .onChange(of: mode) { newMode in
            if newMode == .diff {
                Task { await refreshGit() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.lastPathComponent)
                    .font(.headline)
                    .foregroundStyle(palette.text)
                HStack(spacing: 7) {
                    Text(relativePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(editor.kind.displayName.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.faint)
                    if let status = selectedGitStatus {
                        Text(status.statusLabel.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(palette.faint)
                    }
                }
            }
            Spacer()
            Text("line \(selectedLine) · \(lines.count) lines")
                .font(.caption.monospacedDigit())
                .foregroundStyle(palette.faint)
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
                .disabled(editor.hasUnsavedChanges)
                .actionExplainer(
                    ActionExplainerSpec(
                        title: "Close Source Workbench",
                        summary: editor.hasUnsavedChanges
                            ? "Save or discard the current edit before closing."
                            : "Close this source workbench.",
                        nonEffect: "Does not close or mutate the underlying Conduit task.",
                        target: relativePath,
                        authority: "Workspace-local presentation"
                    )
                )
        }
        .padding(12)
        .background(palette.surface)
    }

    private var commandBar: some View {
        HStack(spacing: 9) {
            Picker("Source mode", selection: $mode) {
                Text("Inspect").tag(MainframeSourceWorkbenchMode.inspect)
                Text("Edit").tag(MainframeSourceWorkbenchMode.edit)
                    .disabled(!editor.canEdit)
                Text("Diff").tag(MainframeSourceWorkbenchMode.diff)
            }
            .pickerStyle(.segmented)
            .frame(width: 250)

            if mode == .inspect {
                Toggle(isOn: $showSideDiff) {
                    Label("Side Diff", systemImage: "rectangle.split.2x1")
                }
                .toggleStyle(.button)
                .disabled(workingDiff == nil)
                .actionExplainer(
                    ActionExplainerSpec(
                        title: "Source + Diff",
                        summary: "Show the current source beside its read-only working-tree diff.",
                        nonEffect: "Does not stage or modify Git state.",
                        target: repositoryRelativePath,
                        authority: "Git observation"
                    )
                )
            }

            if !editor.canEdit, let reason = editor.readOnlyReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
                    .help(reason)
            }

            Spacer(minLength: 8)

            if mode == .edit {
                TextField("Find", text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 135)
                TextField("Replace", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 135)
                Text("\(matchCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(palette.faint)
                    .help("Exact matches in the current edit buffer")
                Button("Replace All") {
                    _ = editor.replaceAll(find: findText, replacement: replaceText)
                }
                .buttonStyle(.bordered)
                .disabled(findText.isEmpty || !editor.canEdit)
                .actionExplainer(
                    ActionExplainerSpec(
                        title: "Replace All in Buffer",
                        summary: "Replace every exact text match in the in-memory edit buffer.",
                        effect: "Changes the unsaved buffer only.",
                        nonEffect: "Does not write to disk until Save succeeds.",
                        target: relativePath,
                        authority: "Operator edit buffer"
                    )
                )

                if editor.hasUnsavedChanges {
                    Button("Save") {
                        if editor.save(root: root, file: file) {
                            Task { await refreshGit() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: [.command])
                    .actionExplainer(
                        ActionExplainerSpec(
                            title: "Save Source",
                            summary: "Write only this exact allowlisted UTF-8 file after checking its observed baseline.",
                            effect: "Conflict-checks and replaces the selected file.",
                            nonEffect: "Does not rename, move, delete, stage, commit, or touch adjacent files.",
                            target: relativePath,
                            authority: "Explicit exact-file write",
                            shortcut: "⌘S"
                        )
                    )
                    Button("Discard") { editor.discard() }
                        .buttonStyle(.bordered)
                }

                if editor.hasConflict {
                    Button("Reload from Disk") {
                        if editor.reload(root: root, file: file) {
                            Task { await refreshGit() }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.rail)
    }

    @ViewBuilder
    private var sourceSurface: some View {
        switch mode {
        case .inspect:
            if showSideDiff {
                HSplitView {
                    syntaxReader
                        .frame(minWidth: 380)
                    sideDiff
                        .frame(minWidth: 330)
                }
            } else {
                syntaxReader
            }
        case .edit:
            TextEditor(text: $editor.buffer)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(8)
                .background(palette.sink)
        case .diff:
            diffSurface
        }
    }

    private var syntaxReader: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                        sourceLine(number: offset + 1, source: line)
                            .id(offset + 1)
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, 20)
            }
            .background(palette.sink)
            .onChange(of: jumpLine) { line in
                guard let line else { return }
                selectedLine = min(max(1, line), max(1, lines.count))
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(selectedLine, anchor: .center)
                }
            }
        }
    }

    private func sourceLine(number: Int, source: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Button {
                selectedLine = number
            } label: {
                Text(String(format: "%4d", number))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(number == selectedLine ? palette.accent : palette.faint)
                    .frame(width: 54, alignment: .trailing)
                    .padding(.trailing, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Copy Path:Line") { copyPathLine(number) }
                Button("Pin Line to Context") { pinLine(number) }
                    .disabled(contextActionsBlockedByUnsavedBuffer)
                Button("Copy Agent Handoff for Line") { copyLineHandoff(number) }
                    .disabled(contextActionsBlockedByUnsavedBuffer)
            }

            SyntaxLineView(source: source, kind: editor.kind, palette: palette)
                .textSelection(.enabled)
                .padding(.vertical, 1)
        }
        .background(number == selectedLine ? palette.accent.opacity(0.07) : Color.clear)
    }

    private var sideDiff: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WORKING TREE ↔ HEAD")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.faint)
                .padding(9)
            Divider().overlay(palette.line)
            ScrollView([.horizontal, .vertical]) {
                Text(workingDiff?.text.isEmpty == false ? workingDiff!.text : "No working-tree diff for this file.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(palette.sink)
        }
    }

    private var diffSurface: some View {
        VStack(spacing: 0) {
            HStack {
                Text(repositoryRelativePath.map { "Git diff · \($0)" } ?? "Git diff unavailable")
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.dim)
                Spacer()
                if gitRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await refreshGit() } }
                    .buttonStyle(.borderless)
                    .disabled(gitRefreshing)
                    .actionExplainer(
                        ActionExplainerSpec(
                            title: "Refresh Git Evidence",
                            summary: "Re-read HEAD, branch, status, exact content identities, history, and this file's diffs using fixed read-only Git commands.",
                            nonEffect: "Does not stage, commit, checkout, reset, clean, stash, merge, or rebase.",
                            target: gitSnapshot?.repositoryRoot,
                            authority: "Git observation"
                        )
                    )
            }
            .padding(10)
            Divider().overlay(palette.line)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 16) {
                    diffBlock("WORKING TREE ↔ HEAD", diff: workingDiff)
                    diffBlock("STAGED ↔ HEAD", diff: stagedDiff)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(palette.sink)
        }
    }

    @ViewBuilder
    private func diffBlock(_ title: String, diff: GitWorkspaceDiff?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.faint)
            if let diff {
                Text(diff.text.isEmpty ? "No diff for this file." : diff.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                if diff.wasTruncated {
                    Text("Diff truncated at the Context IDE inspection limit.")
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                }
            } else {
                Text(gitError ?? "No Git diff loaded.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $inspectorTab) {
                ForEach(MainframeSourceInspectorTab.allCases, id: \.self) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)
            Divider().overlay(palette.line)

            switch inspectorTab {
            case .outline: outlineInspector
            case .git: gitInspector
            case .context: contextInspector
            }
        }
        .background(palette.surface)
    }

    private var outlineInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SOURCE OUTLINE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.faint)
                Spacer()
                if outline.mayBeIncomplete {
                    Text("LIGHTWEIGHT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.faint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            if outline.entries.isEmpty {
                Text(editor.kind.isCode
                    ? "No declarations detected by the lightweight outline."
                    : "Outline is not generated for this file type.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .padding(10)
                Spacer()
            } else {
                List(outline.entries) { entry in
                    Button {
                        mode = .inspect
                        jumpLine = entry.line
                    } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: outlineSymbol(entry.kind))
                                .foregroundStyle(palette.faint)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.caption)
                                    .foregroundStyle(palette.text)
                                    .lineLimit(2)
                                Text("line \(entry.line)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(palette.faint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var gitInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let snapshot = gitSnapshot {
                    inspectorFact("REPOSITORY", snapshot.repositoryRoot)
                    inspectorFact("HEAD", snapshot.headSHA)
                    inspectorFact("BRANCH", snapshot.branch ?? "detached HEAD")
                    inspectorFact("WORKTREE", snapshot.isDirty ? "modified" : "clean")
                    if let path = repositoryRelativePath {
                        inspectorFact("THIS FILE", selectedGitStatus?.statusLabel ?? "clean")
                        inspectorFact("REPO PATH", path)
                    }
                    if let workingTreeBlobIdentity {
                        inspectorFact("CURRENT BLOB", workingTreeBlobIdentity)
                    }
                    if let headBlobIdentity {
                        inspectorFact("HEAD BLOB", headBlobIdentity)
                    } else if repositoryRelativePath != nil {
                        Text("Current file is not being labelled with a HEAD blob identity because it is modified/untracked or absent from HEAD.")
                            .font(.caption2)
                            .foregroundStyle(palette.faint)
                    }

                    Divider().overlay(palette.line)
                    Text("SELECTED LINE BLAME")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.faint)
                    if let blame = selectedLineBlame {
                        inspectorFact("LINE", "\(blame.line)")
                        inspectorFact("COMMIT", blame.commitSHA)
                        if let author = blame.author { inspectorFact("AUTHOR", author) }
                        if let authorTime = blame.authorTime {
                            inspectorFact("DATE", authorTime.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let summary = blame.summary { inspectorFact("SUMMARY", summary) }
                    } else {
                        Text("No committed blame fact for this line.")
                            .font(.caption)
                            .foregroundStyle(palette.dim)
                    }

                    if !gitHistory.isEmpty {
                        Divider().overlay(palette.line)
                        Text("FILE HISTORY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(palette.faint)
                        ForEach(Array(gitHistory.enumerated()), id: \.offset) { _, row in
                            Text(row)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(palette.dim)
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Text(gitRefreshing ? "Inspecting Git…" : (gitError ?? "No Git repository observation."))
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var contextInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("SOURCE CONTEXT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.faint)

                inspectorFact("PATH", relativePath)
                inspectorFact("LOCATION", "\(relativePath):\(selectedLine)")
                inspectorFact("TYPE", editor.kind.displayName)
                if let snapshot = gitSnapshot {
                    inspectorFact("REPO HEAD", snapshot.headSHA)
                    inspectorFact("BRANCH", snapshot.branch ?? "detached")
                }
                if let workingTreeBlobIdentity {
                    inspectorFact("EXACT CURRENT BLOB", workingTreeBlobIdentity)
                }
                if let headBlobIdentity {
                    inspectorFact("EXACT HEAD BLOB", headBlobIdentity)
                }

                if editor.hasUnsavedChanges {
                    Label(
                        "Save or discard the edit buffer before pinning or drafting agent context. Context actions are bound to exact on-disk bytes, not an uncommitted editor buffer.",
                        systemImage: "lock"
                    )
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
                }

                Divider().overlay(palette.line)

                Button("Copy Path:Line") { copyPathLine(selectedLine) }
                    .buttonStyle(.bordered)

                Button("Pin File to Context") { pinFile() }
                    .buttonStyle(.bordered)
                    .disabled(contextActionsBlockedByUnsavedBuffer)
                    .actionExplainer(
                        ActionExplainerSpec(
                            title: "Pin File Context",
                            summary: editor.hasUnsavedChanges
                                ? "Save or discard the edit buffer before pinning exact source context."
                                : "Nominate this exact on-disk source path for the current Context IDE preview.",
                            effect: "Adds a provenance-labelled file item when a calling context stack is available.",
                            nonEffect: "Does not send anything to an agent by itself and never snapshots unsaved editor text as filesystem truth.",
                            target: relativePath,
                            authority: "Filesystem source"
                        )
                    )

                Button("Pin Selected Line") { pinLine(selectedLine) }
                    .buttonStyle(.bordered)
                    .disabled(contextActionsBlockedByUnsavedBuffer)

                Button("Copy Agent Handoff for Line") { copyLineHandoff(selectedLine) }
                    .buttonStyle(.bordered)
                    .disabled(contextActionsBlockedByUnsavedBuffer)
                    .actionExplainer(
                        ActionExplainerSpec(
                            title: "Draft from Source Line",
                            summary: editor.hasUnsavedChanges
                                ? "Save or discard the edit buffer before drafting from exact source bytes."
                                : "Copy a provenance-labelled agent handoff draft for this exact source location.",
                            effect: "Writes a draft to the pasteboard.",
                            nonEffect: "Does not send it, launch an agent, or claim the current bytes match Git HEAD.",
                            target: "\(relativePath):\(selectedLine)",
                            authority: "Filesystem source + observed Git identity"
                        )
                    )

                if let lastContextAction {
                    Text(lastContextAction)
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                }

                Divider().overlay(palette.line)

                Text("JUMP FROM DIAGNOSTIC")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.faint)
                TextField("path:line[:column]", text: $diagnosticText)
                    .textFieldStyle(.roundedBorder)
                Button("Jump") { jumpFromDiagnostic() }
                    .buttonStyle(.bordered)
                    .disabled(diagnosticText.isEmpty)
                Text("Compiler/test locations are navigation hints only; the parsed source path still has to match this exact file.")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: editor.hasConflict ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(palette.dim)
            Text(message)
                .font(.caption)
                .foregroundStyle(palette.dim)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(palette.rail)
    }

    private func inspectorFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.faint)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func outlineSymbol(_ kind: MainframeSourceOutlineKind) -> String {
        switch kind {
        case .type: return "cube"
        case .function: return "function"
        case .extensionDecl: return "puzzlepiece.extension"
        }
    }

    private func loadSource() {
        do {
            let source = try MainframeExplorerScanner().readUTF8Text(
                root: root,
                file: file,
                maxBytes: 2_000_000
            )
            editor.load(
                relativePath: relativePath,
                absolutePath: file.standardizedFileURL.path,
                source: source
            )
            loadError = nil
            mode = .inspect
        } catch {
            editor.clear()
            loadError = error.localizedDescription
        }
    }

    private func refreshGit() async {
        gitRefreshing = true
        let fileURL = file
        let evidence = await Task.detached(priority: .utility) { () -> SourceGitEvidence in
            do {
                let inspector = GitWorkspaceInspector()
                let snapshot = try inspector.snapshot(startingAt: fileURL)
                let rootPath = snapshot.repositoryRoot
                let filePath = fileURL.standardizedFileURL.path
                let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                guard filePath.hasPrefix(prefix) else {
                    return SourceGitEvidence(
                        snapshot: snapshot,
                        workingDiff: nil,
                        stagedDiff: nil,
                        history: [],
                        headBlobIdentity: nil,
                        workingTreeBlobIdentity: nil,
                        error: nil
                    )
                }
                let path = String(filePath.dropFirst(prefix.count))
                let working = try inspector.diff(
                    startingAt: fileURL,
                    relativePath: path,
                    basis: .workingTree
                )
                let staged = try inspector.diff(
                    startingAt: fileURL,
                    relativePath: path,
                    basis: .staged
                )
                let history = try inspector.fileHistory(
                    startingAt: fileURL,
                    relativePath: path,
                    limit: 12
                )
                let headBlob = try inspector.headBlobIdentity(
                    startingAt: fileURL,
                    relativePath: path
                )
                let workingBlob = try inspector.workingTreeBlobIdentity(
                    startingAt: fileURL,
                    relativePath: path
                )
                return SourceGitEvidence(
                    snapshot: snapshot,
                    workingDiff: working,
                    stagedDiff: staged,
                    history: history,
                    headBlobIdentity: headBlob,
                    workingTreeBlobIdentity: workingBlob,
                    error: nil
                )
            } catch {
                return SourceGitEvidence(
                    snapshot: nil,
                    workingDiff: nil,
                    stagedDiff: nil,
                    history: [],
                    headBlobIdentity: nil,
                    workingTreeBlobIdentity: nil,
                    error: error.localizedDescription
                )
            }
        }.value

        gitSnapshot = evidence.snapshot
        workingDiff = evidence.workingDiff
        stagedDiff = evidence.stagedDiff
        gitHistory = evidence.history
        headBlobIdentity = evidence.headBlobIdentity
        workingTreeBlobIdentity = evidence.workingTreeBlobIdentity
        gitError = evidence.error
        gitRefreshing = false
    }

    private func refreshBlame() async {
        guard let path = repositoryRelativePath else {
            selectedLineBlame = nil
            return
        }
        let fileURL = file
        let line = selectedLine
        selectedLineBlame = await Task.detached(priority: .utility) {
            try? GitWorkspaceInspector().blame(
                startingAt: fileURL,
                relativePath: path,
                line: line
            )
        }.value
    }

    private func copyPathLine(_ line: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(relativePath):\(line)", forType: .string)
        lastContextAction = "Copied \(relativePath):\(line)."
    }

    private func pinFile() {
        guard !editor.hasUnsavedChanges else {
            lastContextAction = "Save or discard the edit buffer before pinning exact filesystem context."
            return
        }
        let item = AgentContextItem(
            id: "file:\(relativePath)",
            title: file.lastPathComponent,
            kind: .file,
            authority: .filesystemSource,
            sourceReference: relativePath,
            revisionIdentity: workingTreeBlobIdentity,
            estimatedTokens: max(1, editor.buffer.count / 4),
            isPinned: true,
            freshness: .current
        )
        onPinContext?(item)
        lastContextAction = onPinContext == nil
            ? "No parent Context Stack is attached to this standalone workbench. Use Copy Agent Handoff instead."
            : "Pinned file context: \(relativePath)"
    }

    private func pinLine(_ line: Int) {
        guard !editor.hasUnsavedChanges else {
            lastContextAction = "Save or discard the edit buffer before pinning exact filesystem context."
            return
        }
        guard line > 0, line <= lines.count else { return }
        let item = contextItem(for: line)
        onPinContext?(item)
        lastContextAction = onPinContext == nil
            ? "No parent Context Stack is attached to this standalone workbench. Use Copy Agent Handoff instead."
            : "Pinned source line: \(relativePath):\(line)"
    }

    private func contextItem(for line: Int) -> AgentContextItem {
        AgentContextItem(
            id: "line:\(relativePath):\(line)",
            title: "\(file.lastPathComponent):\(line)",
            kind: .selection,
            authority: .filesystemSource,
            sourceReference: relativePath,
            revisionIdentity: workingTreeBlobIdentity,
            lineRange: line...line,
            estimatedTokens: line > 0 && line <= lines.count
                ? max(1, lines[line - 1].count / 4)
                : nil,
            isPinned: true,
            freshness: .current
        )
    }

    private func copyLineHandoff(_ line: Int) {
        guard !editor.hasUnsavedChanges else {
            lastContextAction = "Save or discard the edit buffer before drafting exact source context."
            return
        }
        guard line > 0, line <= lines.count else { return }
        var items: [AgentContextItem] = [contextItem(for: line)]
        if let snapshot = gitSnapshot {
            items.append(
                AgentContextItem(
                    id: "git-head:\(snapshot.repositoryRoot)",
                    title: "Git HEAD",
                    kind: .commit,
                    authority: .gitCommit,
                    sourceReference: snapshot.repositoryRoot,
                    revisionIdentity: snapshot.headSHA,
                    freshness: .current
                )
            )
            if let status = selectedGitStatus {
                items.append(
                    AgentContextItem(
                        id: "git-status:\(relativePath)",
                        title: "\(status.statusLabel) · \(relativePath)",
                        kind: .gitDiff,
                        authority: .gitWorkingTree,
                        sourceReference: repositoryRelativePath ?? relativePath,
                        revisionIdentity: workingTreeBlobIdentity,
                        freshness: .current
                    )
                )
            }
        }
        if let blame = selectedLineBlame {
            items.append(
                AgentContextItem(
                    id: "blame:\(relativePath):\(line)",
                    title: "Blame · \(blame.author ?? "unknown author")",
                    kind: .commit,
                    authority: .gitCommit,
                    sourceReference: "\(relativePath):\(line)",
                    revisionIdentity: blame.commitSHA,
                    freshness: .current
                )
            )
        }

        let bundle = AgentContextBundle(
            taskTitle: "Inspect \(file.lastPathComponent):\(line)",
            scopePath: relativePath,
            repository: gitSnapshot?.repositoryRoot,
            branch: gitSnapshot?.branch,
            commitSHA: gitSnapshot?.headSHA,
            items: items
        )
        let handoff = AgentContextHandoff(
            objective: "Inspect this exact source location in context. The filesystem item identity refers to current on-disk bytes when available; Git HEAD remains a separate immutable identity.",
            bundle: bundle
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            AgentContextHandoffRenderer.render(handoff),
            forType: .string
        )
        lastContextAction = "Copied provenance-labelled agent handoff for \(relativePath):\(line)."
    }

    private func jumpFromDiagnostic() {
        guard let location = MainframeDiagnosticParser.parseLocation(from: diagnosticText) else {
            lastContextAction = "No path:line diagnostic location detected."
            return
        }
        let diagnosticURL: URL
        if location.path.hasPrefix("/") {
            diagnosticURL = URL(fileURLWithPath: location.path).standardizedFileURL
        } else if let snapshot = gitSnapshot {
            diagnosticURL = URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true)
                .appendingPathComponent(location.path)
                .standardizedFileURL
        } else {
            diagnosticURL = root.appendingPathComponent(location.path).standardizedFileURL
        }
        guard diagnosticURL.path == file.standardizedFileURL.path else {
            lastContextAction = "Diagnostic points to a different file: \(location.path)"
            return
        }
        mode = .inspect
        jumpLine = location.line
    }
}

private struct SyntaxLineView: View {
    let source: String
    let kind: MainframeSourceKind
    let palette: ConduitPalette

    private var tokens: [SyntaxToken] {
        SyntaxToken.tokenize(source, kind: kind)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Text(token.text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(color(for: token.role))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func color(for role: SyntaxToken.Role) -> Color {
        switch role {
        case .plain: return palette.text
        case .keyword: return palette.accent
        case .string, .number: return palette.dim
        case .comment: return palette.faint
        }
    }
}

private struct SyntaxToken {
    enum Role { case plain, keyword, string, comment, number }
    let text: String
    let role: Role

    static func tokenize(_ line: String, kind: MainframeSourceKind) -> [SyntaxToken] {
        if let marker = commentMarker(for: kind),
           let range = line.range(of: marker) {
            let before = String(line[..<range.lowerBound])
            let comment = String(line[range.lowerBound...])
            return tokenizeCode(before, kind: kind) + [SyntaxToken(text: comment, role: .comment)]
        }
        return tokenizeCode(line, kind: kind)
    }

    private static func tokenizeCode(_ source: String, kind: MainframeSourceKind) -> [SyntaxToken] {
        var result: [SyntaxToken] = []
        var current = ""
        var inString: Character?

        func flush(_ role: Role = .plain) {
            guard !current.isEmpty else { return }
            result.append(SyntaxToken(
                text: current,
                role: roleFor(current, kind: kind, fallback: role)
            ))
            current = ""
        }

        for char in source {
            if let quote = inString {
                current.append(char)
                if char == quote {
                    flush(.string)
                    inString = nil
                }
                continue
            }
            if char == "\"" || char == "'" {
                flush()
                current.append(char)
                inString = char
            } else if char.isLetter || char.isNumber || char == "_" || char == "." {
                current.append(char)
            } else {
                flush()
                result.append(SyntaxToken(text: String(char), role: .plain))
            }
        }
        flush(inString == nil ? .plain : .string)
        return result
    }

    private static func roleFor(_ token: String, kind: MainframeSourceKind, fallback: Role) -> Role {
        if fallback == .string { return .string }
        if token.allSatisfy({ $0.isNumber || $0 == "." }),
           token.contains(where: { $0.isNumber }) {
            return .number
        }
        return keywords(for: kind).contains(token) ? .keyword : fallback
    }

    private static func commentMarker(for kind: MainframeSourceKind) -> String? {
        switch kind {
        case .python, .shell, .yaml, .toml: return "#"
        case .swift, .javascript, .typescript, .rust, .go, .java, .cFamily: return "//"
        case .markdown, .json, .plainText, .unsupported: return nil
        }
    }

    private static func keywords(for kind: MainframeSourceKind) -> Set<String> {
        switch kind {
        case .swift:
            return ["actor", "class", "deinit", "enum", "extension", "func", "guard", "if", "import", "init", "let", "private", "protocol", "public", "return", "struct", "switch", "var", "while"]
        case .python:
            return ["and", "as", "async", "await", "class", "def", "elif", "else", "except", "False", "for", "from", "if", "import", "in", "None", "not", "or", "pass", "return", "True", "try", "while", "with", "yield"]
        case .javascript, .typescript:
            return ["async", "await", "class", "const", "else", "export", "extends", "function", "if", "import", "interface", "let", "new", "return", "type", "var"]
        case .rust:
            return ["async", "await", "const", "enum", "fn", "impl", "let", "match", "mod", "mut", "pub", "return", "self", "struct", "trait", "use"]
        case .go:
            return ["break", "case", "const", "continue", "defer", "else", "fallthrough", "for", "func", "go", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "type", "var"]
        case .java, .cFamily:
            return ["class", "const", "else", "enum", "for", "if", "import", "interface", "private", "protected", "public", "return", "static", "struct", "switch", "void", "while"]
        case .shell:
            return ["case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "then", "while"]
        case .markdown, .json, .yaml, .toml, .plainText, .unsupported:
            return []
        }
    }
}
#endif
