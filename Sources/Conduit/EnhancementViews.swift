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
                            ProgressView(value: model.resourceSnapshot.usedMemoryGB, total: max(model.resourceSnapshot.totalMemoryGB, 1))
                            Text(String(format: "%.1f GB used of %.1f GB", model.resourceSnapshot.usedMemoryGB, model.resourceSnapshot.totalMemoryGB))
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
                                Button("Unload all detected models") { Task { await model.unloadOllamaModels() } }
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

struct ContextBundleView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            ConduitSheetHeader(
                title: "Context Bundle",
                subtitle: "Nominate sources for inspection — not verification",
                systemImage: "doc.on.doc",
                onClose: { model.showContextBundle = false }
            )
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Context sources")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.text)
                        .padding(12)
                    Divider()
                    List(model.contextCandidates) { document in
                        Toggle(isOn: Binding(
                            get: { model.selectedContextIDs.contains(document.id) },
                            set: { selected in
                                model.setContextDocument(document, selected: selected)
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.label)
                                    .foregroundStyle(palette.text)
                                Text(document.trustLabel)
                                    .font(.caption)
                                    .foregroundStyle(palette.dim)
                            }
                        }
                        .listRowBackground(palette.surface)
                    }
                    .scrollContentBackground(.hidden)
                    .background(palette.app)
                }
                .frame(minWidth: 260)
                .background(palette.app)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Preview")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.text)
                        Spacer()
                        Text("Context, not verification")
                            .font(.caption)
                            .foregroundStyle(palette.dim)
                    }
                    .padding(12)
                    Divider()
                    ScrollView {
                        Text(
                            model.contextPreview.isEmpty
                                ? "Select context sources."
                                : model.contextPreview
                        )
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(
                            model.contextPreview.isEmpty ? palette.faint : palette.text
                        )
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .background(palette.sink)
                    Divider()
                    HStack {
                        Spacer()
                        Button("Attach Bundle") { model.attachContextBundle() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.contextPreview.isEmpty)
                    }
                    .padding()
                    .background(palette.surface)
                }
                .frame(minWidth: 460)
                .background(palette.app)
            }
        }
        .background(palette.app)
        .frame(width: 860, height: 600)
    }
}

#endif
