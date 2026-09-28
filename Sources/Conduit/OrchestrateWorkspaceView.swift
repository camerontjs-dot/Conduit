#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

/// A top-level proposal workspace. It never mounts, sends to, or replaces a
/// terminal session; its local planner cannot create or steer a worker.
struct OrchestrateWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var workspaceWorktrees: [GitWorktreeRecord] = []
    @State private var workspaceHumanSnapshot: GitWorkspaceSnapshot?
    @State private var workspaceBaseRevision = ""
    @State private var workspaceTaskBranch = ""
    @State private var workspacePlan: ExecutionWorkspaceAllocationPlan?
    @State private var workspaceCandidate: ExecutionWorkspace?
    @State private var workspaceLease: WorkspaceLease?
    @State private var workspaceReconciliation: ExecutionWorkspaceReconciliation?
    @State private var workspaceMessage: String?
    @State private var workspaceBusy = false

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                requestCard
                executionWorkspaceCard
                contextCard
                proposalCard
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Orchestrate workspace")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Orchestrate", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.title2.bold())
                .foregroundStyle(palette.text)
            Text("Prepare one bounded proposal, then review it before any worker can be started. Planner output is never task verification.")
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Label(model.orchestrationBackendLabel, systemImage: "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.dim)
                .accessibilityLabel("Planner backend")
                .accessibilityValue(model.orchestrationBackendLabel)
        }
    }

    private var requestCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Planning request")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Picker("Project", selection: Binding(
                    get: { model.orchestrationProject?.id ?? "" },
                    set: { model.selectOrchestrationProject($0.isEmpty ? nil : $0) }
                )) {
                    Text("Choose a project").tag("")
                    ForEach(model.orchestrationProjects) { project in
                        Text(project.isMainframeRoot
                            ? "\(project.metadata.title) root"
                            : project.metadata.title)
                            .tag(project.id)
                    }
                }
                .accessibilityLabel("Proposal project")

                TextEditor(text: $model.orchestrationRequest)
                    .font(.body)
                    .frame(minHeight: 110)
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(palette.line, lineWidth: 1)
                    )
                    .accessibilityLabel("Bounded planning request")

                HStack {
                    Button("Ask local planner") {
                        model.requestLocalOrchestrationProposal()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isOrchestrationPlannerRunning)
                    .help("Sends only this request to the fixed loopback Ollama planner. It has no tool interface and cannot create a worker.")

                    Button("Preview fixture proposal") {
                        model.previewOrchestrationProposal()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isOrchestrationPlannerRunning)
                    .help("Uses a deterministic local fixture. It does not contact a model or start a worker.")

                    Button("Reset") {
                        model.orchestrationRequest = ""
                        model.resetOrchestrationPreview()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }

                Text("The planner unloads its model after each response. Ollama may remain running as a shared local service, and Conduit never stops it.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }


    private var executionWorkspaceCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Execution workspace")
                        .font(.headline)
                        .foregroundStyle(palette.text)
                    Spacer()
                    Button("Inspect worktrees") {
                        inspectExecutionWorkspaces()
                    }
                    .buttonStyle(.bordered)
                    .disabled(workspaceBusy || model.orchestrationProject == nil)
                }

                Text("Writable Git work uses an explicit isolated worktree and a separate one-writer workspace lease. A Git worktree is checkout isolation, not a security sandbox.")
                    .font(.subheadline)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)

                if let snapshot = workspaceHumanSnapshot {
                    HStack(spacing: 8) {
                        workspaceBadge("human checkout")
                        Text(snapshot.branch ?? "detached")
                        Text(String(snapshot.headSHA.prefix(12)))
                            .font(.caption.monospaced())
                        if snapshot.isDirty {
                            workspaceBadge("dirty")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                }

                ForEach(workspaceWorktrees, id: \.path) { worktree in
                    HStack(spacing: 8) {
                        workspaceBadge(
                            ExecutionWorkspacePresentation.classification(
                                worktree: worktree,
                                humanCheckoutPath: model.orchestrationProject?.path.path ?? "",
                                managedWorkspaceRoot: managedWorkspaceRoot.path
                            )
                        )
                        Text(worktree.branchName ?? "detached")
                            .lineLimit(1)
                        Text(String(worktree.headSHA.prefix(12)))
                            .font(.caption.monospaced())
                        Spacer()
                        Text(worktree.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(palette.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                }

                Divider()

                TextField("Base ref or exact SHA", text: $workspaceBaseRevision)
                    .textFieldStyle(.roundedBorder)
                    .disabled(workspaceBusy)
                TextField("Task branch", text: $workspaceTaskBranch)
                    .textFieldStyle(.roundedBorder)
                    .disabled(workspaceBusy)

                HStack {
                    Button("Prepare exact base") {
                        prepareExecutionWorkspace()
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        workspaceBusy
                            || model.orchestrationProject == nil
                            || workspaceBaseRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || workspaceTaskBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || workspaceCandidate != nil
                    )

                    Button("Create isolated worktree") {
                        allocatePreparedExecutionWorkspace()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspaceBusy || workspacePlan == nil || workspaceCandidate != nil)

                    Spacer()
                }

                if let plan = workspacePlan {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PREPARED EXACT BASE")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.faint)
                        Text("\(plan.baseRevision) → \(plan.baseSHA)")
                            .font(.caption.monospaced())
                            .foregroundStyle(palette.dim)
                            .textSelection(.enabled)
                        Text(plan.workspacePath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(palette.faint)
                            .textSelection(.enabled)
                    }
                }

                if let candidate = workspaceCandidate {
                    Divider()
                    HStack(spacing: 8) {
                        workspaceBadge("agent workspace")
                        if workspaceLease?.status == .active {
                            workspaceBadge("writer leased")
                        }
                        if let reconciliation = workspaceReconciliation {
                            workspaceBadge(reconciliation.disposition.rawValue.lowercased())
                        }
                    }

                    Text(candidate.path ?? "Workspace path UNKNOWN")
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.dim)
                        .textSelection(.enabled)

                    if let warning = ExecutionWorkspacePresentation.humanEntryWarning(
                        workspace: candidate,
                        lease: workspaceLease
                    ) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let reconciliation = workspaceReconciliation {
                        ForEach(Array(reconciliation.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(palette.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack {
                        Button("Reconcile") {
                            reconcileExecutionWorkspace()
                        }
                        .buttonStyle(.bordered)
                        .disabled(workspaceBusy)

                        Button("Reveal exact path") {
                            revealExecutionWorkspace(candidate)
                        }
                        .buttonStyle(.bordered)
                        .disabled(candidate.path == nil)

                        if workspaceLease?.status == .active {
                            Button("Release lease · preserve worktree") {
                                releaseExecutionWorkspaceLease()
                            }
                            .buttonStyle(.bordered)
                            .disabled(workspaceBusy)
                        }
                    }
                }

                if let workspaceMessage {
                    Text(workspaceMessage)
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var managedWorkspaceRoot: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".conduit")
        return applicationSupport
            .appendingPathComponent("Conduit", isDirectory: true)
            .appendingPathComponent("ExecutionWorkspaces", isDirectory: true)
    }

    private var workspaceLeaseRoot: URL {
        managedWorkspaceRoot
            .deletingLastPathComponent()
            .appendingPathComponent("WorkspaceLeases", isDirectory: true)
    }

    private func inspectExecutionWorkspaces() {
        guard let project = model.orchestrationProject else {
            workspaceMessage = "Choose a project before inspecting Git worktrees."
            return
        }
        workspaceBusy = true
        defer { workspaceBusy = false }

        do {
            let controller = GitExecutionWorkspaceController()
            workspaceWorktrees = try controller.discoverWorktrees(repositoryRoot: project.path)
            let snapshot = try GitWorkspaceInspector().snapshot(startingAt: project.path)
            workspaceHumanSnapshot = snapshot
            if workspaceBaseRevision.isEmpty {
                workspaceBaseRevision = snapshot.branch ?? snapshot.headSHA
            }
            if workspaceTaskBranch.isEmpty {
                workspaceTaskBranch =
                    "conduit/workspace-\(UUID().uuidString.lowercased().prefix(8))"
            }
            if let candidate = workspaceCandidate {
                let result = controller.reconcile(
                    candidate,
                    leaseStore: WorkspaceLeaseStore(directory: workspaceLeaseRoot)
                )
                workspaceReconciliation = result
                workspaceLease = result.activeLease
            }
            workspaceMessage =
                "Read-only inspection complete. No task, provider session, writer lease, or worktree was created."
        } catch {
            workspaceMessage = "Workspace inspection failed: \(error.localizedDescription)"
        }
    }

    private func prepareExecutionWorkspace() {
        guard let project = model.orchestrationProject else {
            workspaceMessage = "Choose a project before preparing a workspace."
            return
        }
        let revision = workspaceBaseRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = workspaceTaskBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaceBusy = true
        defer { workspaceBusy = false }

        do {
            let plan = try GitExecutionWorkspaceController().prepareAllocation(
                repositoryRoot: project.path,
                workspaceRoot: managedWorkspaceRoot,
                branchName: branch,
                baseRevision: revision
            )
            workspacePlan = plan
            workspaceMessage =
                "Prepared \(plan.baseSHA). Creation stays pinned to this SHA even if \(plan.baseRevision) moves."
        } catch {
            workspacePlan = nil
            workspaceMessage = "Workspace preparation failed: \(error.localizedDescription)"
        }
    }

    private func allocatePreparedExecutionWorkspace() {
        guard let plan = workspacePlan else { return }
        workspaceBusy = true
        defer { workspaceBusy = false }

        do {
            let controller = GitExecutionWorkspaceController()
            let receipt = try controller.allocate(plan)
            workspaceCandidate = receipt.workspace

            do {
                let store = WorkspaceLeaseStore(directory: workspaceLeaseRoot)
                let lease = try store.acquire(
                    workspaceID: receipt.workspace.id,
                    ownerID: "orchestrate-manual"
                )
                let bound = receipt.workspace.binding(lease)
                workspaceCandidate = bound
                workspaceLease = lease
                workspaceReconciliation = controller.reconcile(
                    bound,
                    leaseStore: store
                )
                workspaceMessage = (
                    receipt.warnings.map(\.message)
                    + ["Allocated exact isolated worktree and acquired one writer lease. The ordinary checkout was not switched."]
                ).joined(separator: "\n")
            } catch {
                workspaceLease = nil
                workspaceReconciliation = controller.reconcile(receipt.workspace)
                workspaceMessage =
                    "Worktree allocation succeeded, but writer lease acquisition failed closed: \(error.localizedDescription). The worktree is preserved for inspection."
            }

            workspaceWorktrees = try controller.discoverWorktrees(
                repositoryRoot: URL(
                    fileURLWithPath: plan.repository.repositoryRoot,
                    isDirectory: true
                )
            )
        } catch {
            workspaceMessage =
                "Workspace allocation failed closed: \(error.localizedDescription). No cleanup or fallback to the ordinary checkout was attempted."
        }
    }

    private func reconcileExecutionWorkspace() {
        guard let candidate = workspaceCandidate else { return }
        workspaceBusy = true
        defer { workspaceBusy = false }

        let result = GitExecutionWorkspaceController().reconcile(
            candidate,
            leaseStore: WorkspaceLeaseStore(directory: workspaceLeaseRoot)
        )
        workspaceReconciliation = result
        workspaceLease = result.activeLease
        workspaceMessage = result.issues.isEmpty
            ? "Workspace reconciliation: \(result.disposition.rawValue)."
            : result.issues.map(\.message).joined(separator: "\n")
    }

    private func releaseExecutionWorkspaceLease() {
        guard let candidate = workspaceCandidate,
              let lease = workspaceLease else { return }
        workspaceBusy = true
        defer { workspaceBusy = false }

        do {
            _ = try WorkspaceLeaseStore(directory: workspaceLeaseRoot).release(
                workspaceID: candidate.id,
                ownerID: lease.ownerID,
                expectedLeaseID: lease.id
            )
            let preserved = candidate.preservingAfterLeaseRelease()
            workspaceCandidate = preserved
            workspaceLease = nil
            workspaceReconciliation = GitExecutionWorkspaceController().reconcile(
                preserved,
                leaseStore: WorkspaceLeaseStore(directory: workspaceLeaseRoot)
            )
            workspaceMessage =
                "Writer lease released. The worktree and task branch were preserved; no cleanup or integration was performed."
        } catch {
            workspaceMessage = "Lease release failed: \(error.localizedDescription)"
        }
    }

    private func revealExecutionWorkspace(_ workspace: ExecutionWorkspace) {
        guard let path = workspace.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: path, isDirectory: true)
        ])
    }

    private func workspaceBadge(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(palette.surface.opacity(0.75))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(palette.line, lineWidth: 1)
            )
            .foregroundStyle(palette.dim)
    }

    private var contextCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("MindGraph context")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Text("No context is selected yet. The local planner receives this empty labelled packet plus the request; future context must remain operator-selected, separately labelled Knowledge and Project-status nominations within a fixed budget.")
                    .font(.subheadline)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if let packet = model.orchestrationContextPacket {
                    Text("Packet: \(packet.entries.count) entries · \(packet.tokenEstimate) estimated tokens")
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.faint)
                }
            }
        }
    }

    @ViewBuilder
    private var proposalCard: some View {
        if let response = model.orchestrationResponse {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(response.proposal == nil ? "Planner response" : "Proposal review")
                        .font(.headline)
                        .foregroundStyle(palette.text)
                    Text(response.text)
                        .foregroundStyle(palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    if let proposal = response.proposal {
                        Divider()
                        proposalField("Objective", proposal.objective)
                        proposalField("Suggested worker", proposal.suggestedAgent)
                        proposalField("Scope", proposal.scopeAllowlist.joined(separator: "\n"))
                        proposalField("Verification", proposal.verificationSteps.joined(separator: "\n"))
                        proposalField("Non-goals", proposal.nonGoals.joined(separator: "\n"))
                        if let validation = model.orchestrationValidation {
                            let state = validationLabel(validation)
                            Label(state.title, systemImage: state.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(state.color)
                                .accessibilityLabel("Proposal validation")
                                .accessibilityValue(state.title)
                            ForEach(validation.reasons, id: \.self) { reason in
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(palette.dim)
                            }
                        }
                    } else {
                        Text("The visible response was not a declared proposal envelope, so Conduit did not infer scope or offer it for launch.")
                            .font(.caption)
                            .foregroundStyle(palette.dim)
                    }
                    Button("Start one worker") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                        .help("Disabled: the one-worker launch handoff is not implemented.")
                        .accessibilityLabel("Start one worker")
                        .accessibilityHint("Disabled until the explicit launch handoff is separately implemented and verified.")
                }
            }
        } else {
            card {
                Text(model.isOrchestrationPlannerRunning
                    ? "Local planner is running in an isolated deny-all temporary project. No worker can be created from this request."
                    : "No planner response yet. Asking the local planner can contact only the configured local Ollama model; it cannot call MCP or create a task.")
                    .foregroundStyle(palette.dim)
            }
        }
    }

    private func proposalField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.faint)
            Text(value)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
        }
    }

    private func validationLabel(_ validation: OrchestrationProposalValidation) -> (title: String, symbol: String, color: Color) {
        switch validation {
        case .valid:
            return ("Proposal is structurally ready for operator review", "checkmark.shield", .green)
        case .needsOperatorRevision:
            return ("Proposal needs revision", "exclamationmark.triangle", .orange)
        case .refused:
            return ("Proposal refused by local policy", "xmark.shield", .red)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(palette.line, lineWidth: 1)
            )
    }
}
#endif
