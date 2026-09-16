#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

/// Builds an explicit agent-to-agent/operator-to-agent handoff draft from the
/// exact typed context currently visible. Loading the draft into Composer is
/// deliberately separate from sending it.
struct ContextHandoffView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let bundle: AgentContextBundle

    @State private var recipe: AgentContextRecipe = .agentHandoff
    @State private var destination = ""
    @State private var sourceAgent = ""
    @State private var objective = ""
    @State private var diff: AgentContextDiff?
    @State private var comparisonStatus: String?

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var handoff: AgentContextHandoff {
        AgentContextHandoff(
            recipe: recipe,
            destinationLabel: nonEmpty(destination),
            sourceAgentLabel: nonEmpty(sourceAgent),
            objective: objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? bundle.taskTitle
                : objective.trimmingCharacters(in: .whitespacesAndNewlines),
            bundle: bundle,
            changesSinceLastHandoff: diff
        )
    }

    private var rendered: String {
        AgentContextHandoffRenderer.render(handoff)
    }

    var body: some View {
        VStack(spacing: 0) {
            ConduitSheetHeader(
                title: "Context Handoff",
                subtitle: "Preview the exact provenance-labelled handoff before it reaches an agent",
                systemImage: "arrow.triangle.branch",
                onClose: { dismiss() }
            )
            Divider().overlay(palette.line)

            HSplitView {
                controls
                    .frame(minWidth: 310, idealWidth: 340, maxWidth: 410)
                preview
                    .frame(minWidth: 540)
            }

            Divider().overlay(palette.line)
            footer
        }
        .frame(width: 980, height: 660)
        .background(palette.app)
        .task { await loadComparison() }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("HANDOFF CONTRACT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(palette.faint)

                Picker("Recipe", selection: $recipe) {
                    ForEach(AgentContextRecipe.allCases, id: \.self) { recipe in
                        Text(recipeLabel(recipe)).tag(recipe)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("DESTINATION")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.faint)
                    TextField("e.g. Codex, Claude, local reviewer", text: $destination)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("PRIOR WORKER")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.faint)
                    TextField("Optional", text: $sourceAgent)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("OBJECTIVE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.faint)
                    TextEditor(text: $objective)
                        .font(.callout)
                        .frame(minHeight: 92)
                        .padding(6)
                        .background(palette.sink)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(palette.line, lineWidth: 1)
                        )
                }

                Divider().overlay(palette.line)

                contextFact("ITEMS", "\(bundle.items.count)")
                contextFact("EST. TOKENS", "\(bundle.estimatedTokenTotal)")
                if let repository = bundle.repository { contextFact("REPOSITORY", repository) }
                if let branch = bundle.branch { contextFact("BRANCH", branch) }
                if let commit = bundle.commitSHA { contextFact("COMMIT", commit) }

                if let diff {
                    contextFact(
                        "SINCE SNAPSHOT",
                        "+\(diff.added.count)  -\(diff.removed.count)  ~\(diff.changed.count)"
                    )
                } else if let comparisonStatus {
                    Text(comparisonStatus)
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                }

                Text("Recipe kinds are transparent recommendations only. This sheet does not auto-admit extra files or retrieval results.")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.surface)
        .onAppear {
            if objective.isEmpty { objective = bundle.taskTitle }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("HANDOFF PREVIEW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.faint)
                Spacer()
                Text("draft only")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
            .padding(10)
            Divider().overlay(palette.line)
            ScrollView {
                Text(rendered)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(palette.sink)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label("Nothing is sent until you use the normal Composer send action.", systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(palette.dim)

            Spacer()

            Button("Copy Draft") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(rendered, forType: .string)
            }
            .buttonStyle(.bordered)

            Button("Load into Composer") {
                model.composerText = rendered
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .actionExplainer(
                ActionExplainerSpec(
                    title: "Load Context Handoff",
                    summary: "Place this exact handoff draft into Conduit's Composer for inspection and optional editing.",
                    effect: "Replaces the current Composer text with this draft.",
                    nonEffect: "Does not press Send, launch an agent, attach hidden files, or mutate MainFrame.",
                    target: destination.isEmpty ? "current Composer" : destination,
                    authority: "Operator-reviewed draft"
                )
            )
        }
        .padding(12)
        .background(palette.surface)
    }

    private func contextFact(_ label: String, _ value: String) -> some View {
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

    private func loadComparison() async {
        let store = AgentContextSnapshotStore(
            directory: AgentContextSnapshotStore.defaultDirectory()
        )
        let current = bundle
        let result = await Task.detached(priority: .utility) { () -> Result<AgentContextDiff?, Error> in
            do {
                return .success(try store.diffFromLatest(to: current))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let loaded):
            diff = loaded
            comparisonStatus = loaded == nil ? "No prior explicit snapshot for this scope." : nil
        case .failure(let error):
            diff = nil
            comparisonStatus = "Snapshot comparison unavailable: \(error.localizedDescription)"
        }
    }

    private func nonEmpty(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func recipeLabel(_ recipe: AgentContextRecipe) -> String {
        switch recipe {
        case .reviewPullRequest: return "Review Pull Request"
        case .investigateFailure: return "Investigate Failure"
        case .implementIssue: return "Implement Issue"
        case .researchArchitecture: return "Research Architecture"
        case .qualificationRun: return "Qualification Run"
        case .reproduceBug: return "Reproduce Bug"
        case .agentHandoff: return "Agent Handoff"
        }
    }
}
#endif
