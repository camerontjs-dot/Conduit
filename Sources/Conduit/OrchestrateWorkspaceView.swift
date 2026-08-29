#if os(macOS)
import ConduitCore
import SwiftUI

/// A top-level proposal workspace. It never mounts, sends to, or replaces a
/// terminal session; its local planner cannot create or steer a worker.
struct OrchestrateWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                requestCard
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
