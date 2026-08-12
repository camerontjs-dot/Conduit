#if os(macOS)
import ConduitCore
import Foundation
import SwiftUI

/// Provider-neutral model chooser used by New Task and the live composer.
/// The menu is populated by the agent's own CLI, with a CLI-default escape
/// hatch for profiles that do not expose a catalog.
struct AgentModelPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let agent: AgentProfile
    let selectedModelID: String?
    let options: [AgentModelOption]
    let isRefreshing: Bool
    let onSelect: (AgentModelOption?) -> Void
    let onRefresh: () -> Void

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var selectedOption: AgentModelOption? {
        options.first { $0.id == selectedModelID }
    }

    var body: some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                modelMenuLabel(
                    title: "CLI default",
                    detail: "Let \(agent.name) choose",
                    selected: selectedModelID == nil
                )
            }

            if !options.isEmpty {
                Divider()
                ForEach(Array(options.prefix(48))) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        modelMenuLabel(
                            title: option.displayName,
                            detail: optionDetail(option),
                            selected: option.id == selectedModelID
                        )
                    }
                }
                if options.count > 48 {
                    Text("Showing first 48 models — refresh or use Settings for a custom ID")
                }
            } else if isRefreshing {
                Text("Reading \(agent.name) models…")
            } else {
                Text("No models found — Refresh, or set a custom ID in Settings")
            }

            Divider()
            Button {
                onRefresh()
            } label: {
                Label(
                    isRefreshing ? "Refreshing…" : "Refresh models",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(isRefreshing)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cube.transparent")
                    .foregroundStyle(palette.accent)
                Text(selectedOption?.displayName ?? selectedModelID ?? "CLI default")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(palette.faint)
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(palette.sink)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(palette.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Model for \(agent.name)")
        .accessibilityValue(selectedOption?.displayName ?? selectedModelID ?? "CLI default")
        .help(
            "Choose \(agent.name)’s model. Catalogs come from each CLI when possible (Codex/OpenCode/Cursor/Grok/Agy/Ollama; Claude/Gemini use documented aliases). Live switch when supported — always confirm in Raw. Relaunch applies --model for every agent."
        )
    }

    private func optionDetail(_ option: AgentModelOption) -> String {
        if let context = option.contextWindowTokens {
            return "\(option.detail ?? "Model") · \(compactTokenCount(context)) context"
        }
        return option.detail ?? "Context limit unknown"
    }

    private func modelMenuLabel(title: String, detail: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark" : "circle")
                .foregroundStyle(selected ? palette.accent : palette.faint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
            }
        }
    }

    private func compactTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

/// A compact circular meter for the composer. A nil fraction is rendered as
/// unknown; it is never silently converted into zero usage or zero capacity.
struct CircularLimitMeter: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let fraction: Double?
    let valueLabel: String
    let detail: String

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var clampedFraction: Double {
        min(max(fraction ?? 0, 0), 1)
    }

    private var progressColor: Color {
        guard let fraction else { return palette.faint }
        if fraction >= 1 { return Color.red.opacity(0.85) }
        if fraction >= 0.8 { return Color.orange.opacity(0.9) }
        return palette.accent
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(palette.line, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: clampedFraction)
                    .stroke(
                        progressColor,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text(valueLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 48, height: 48)
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.dim)
            Text(detail)
                .font(.system(size: 8))
                .foregroundStyle(palette.faint)
                .lineLimit(1)
                .frame(maxWidth: 80)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) meter")
        .accessibilityValue("\(valueLabel), \(detail)")
        .help("\(title): \(valueLabel) · \(detail)")
    }
}
#endif
