#if os(macOS)
import ConduitCore
import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var isStaging: Bool {
        model.forwardingDraft != nil
    }

    private var sendTargetLabel: String {
        if let session = model.activeSessionForSelectedProject {
            return "Send target: \(session.descriptor.agent.name)"
        }
        return "Send target: new shell"
    }

    var body: some View {
        VStack(spacing: 6) {
            if model.forwardingDraft != nil {
                stagingCard
            }

            ordinaryComposer
                .opacity(isStaging ? 0.4 : 1)
                .disabled(isStaging)
                .accessibilityElement(children: .contain)
                .accessibilityValue(isStaging ? "Disabled while staging a forward" : "")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.rail)
    }

    // MARK: - Staging card

    @ViewBuilder
    private var stagingCard: some View {
        if model.forwardingDraft != nil {
            VStack(alignment: .leading, spacing: 0) {
                stagingHeader
                VStack(alignment: .leading, spacing: 9) {
                    stagingEvidenceBox
                    stagingNoteField
                    stagingFooter
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(palette.accent, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                // Accent boundary edge — visual evidence marker, not delivery state.
                RoundedRectangle(cornerRadius: 11)
                    .fill(palette.accent)
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Forward selection staging")
        }
    }

    private var stagingHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.right.circle.fill")
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text("Forward selection")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
            if let draft = model.forwardingDraft {
                Text("from \(draft.sourceAgentName) · \(draft.lineCount) lines")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
                    .accessibilityLabel("From \(draft.sourceAgentName), \(draft.lineCount) lines")
            }
            Spacer(minLength: 4)
            Button {
                model.cancelForwardingDraft()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.faint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close staging")
            .help("Cancel forwarding without changing the clipboard or composer")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.accentSoft)
    }

    private var stagingEvidenceBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: stagingSelectionBinding)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(palette.dim)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 56, maxHeight: 96)
                .accessibilityLabel("Forward selection text")
                .accessibilityHint("Editable terminal selection to forward")

            HStack(spacing: 10) {
                if let draft = model.forwardingDraft {
                    Text("\(draft.lineCount) lines · \(draft.characterCount) chars")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(palette.accent)
                        .accessibilityLabel("\(draft.lineCount) lines, \(draft.characterCount) characters")
                }
                Text("evidence boundary · unverified terminal output")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(palette.canvas)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(palette.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var stagingNoteField: some View {
        TextField("Add context for the target…", text: stagingNoteBinding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.callout)
            .foregroundStyle(palette.text)
            .lineLimit(1...3)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(palette.sink)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(palette.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Optional context for the target")
    }

    private var stagingFooter: some View {
        HStack(spacing: 10) {
            stagingTargetPicker
            Spacer(minLength: 4)
            Button("Cancel") {
                model.cancelForwardingDraft()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.dim)
            .accessibilityLabel("Cancel forwarding")
            .help("Dismiss the staging draft without changes")

            Button(stagingConfirmLabel) {
                model.confirmForwardingDraft()
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .accessibilityLabel(stagingConfirmLabel)
            .help(stagingConfirmHelp)
        }
    }

    private var stagingTargetPicker: some View {
        HStack(spacing: 4) {
            stagingTargetChip(
                title: "This composer",
                selected: model.forwardingDraft?.destination == .thisComposer
            ) {
                model.forwardingDraft?.destination = .thisComposer
            }

            ForEach(model.forwardableAgents) { agent in
                stagingTargetChip(
                    title: agent.name,
                    selected: {
                        if case .agent(let id) = model.forwardingDraft?.destination {
                            return id == agent.id
                        }
                        return false
                    }()
                ) {
                    model.forwardingDraft?.destination = .agent(agent.id)
                }
            }
        }
        .padding(3)
        .background(palette.sink)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Forward destination")
    }

    private func stagingTargetChip(
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? palette.accent : palette.dim)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(selected ? palette.accentSoft : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Select as forward destination")
    }

    private var stagingConfirmLabel: String {
        guard let draft = model.forwardingDraft else { return "Send" }
        switch draft.destination {
        case .thisComposer:
            return "Move"
        case .agent(let id):
            let name = model.forwardableAgents.first(where: { $0.id == id })?.name ?? "agent"
            return "Send to \(name)"
        }
    }

    private var stagingConfirmHelp: String {
        guard let draft = model.forwardingDraft else { return "Confirm forward" }
        switch draft.destination {
        case .thisComposer:
            return "Append the edited selection to the composer without sending"
        case .agent:
            return "Deliver the selection with the evidence boundary to the chosen agent"
        }
    }

    private var stagingSelectionBinding: Binding<String> {
        Binding(
            get: { model.forwardingDraft?.selection ?? "" },
            set: { model.forwardingDraft?.selection = $0 }
        )
    }

    private var stagingNoteBinding: Binding<String> {
        Binding(
            get: { model.forwardingDraft?.note ?? "" },
            set: { model.forwardingDraft?.note = $0 }
        )
    }

    // MARK: - Ordinary composer

    private var ordinaryComposer: some View {
        VStack(spacing: 6) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.attachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachment.url.hasDirectoryPath ? "folder" : "doc")
                                    .foregroundStyle(palette.dim)
                                Text(attachment.url.lastPathComponent)
                                    .lineLimit(1)
                                    .foregroundStyle(palette.text)
                                Button {
                                    model.removeAttachment(attachment)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(palette.faint)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(attachment.url.lastPathComponent)")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(palette.lineSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }

            HStack(alignment: .center, spacing: 9) {
                Button(action: model.toggleSpeech) {
                    Image(systemName: model.speech.isRecording ? "stop.circle.fill" : "mic.fill")
                        .foregroundStyle(model.speech.isRecording ? .red : palette.text)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(model.speech.isRecording ? "Stop dictation" : "Dictate prompt")
                .help(model.speech.isRecording ? "Stop dictation" : "Dictate prompt")

                Button(action: model.addFiles) {
                    Image(systemName: "paperclip")
                        .foregroundStyle(palette.dim)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Attach files or folders")
                .help("Attach files or folders")

                Menu {
                    Button("Paste image", action: model.pasteImage)
                    Button("Capture screen area", action: model.captureScreen)
                } label: {
                    Image(systemName: "photo")
                        .foregroundStyle(palette.dim)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Add an image")

                TextEditor(text: $model.composerText)
                    .font(.body)
                    .foregroundStyle(palette.text)
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .padding(7)
                    .background(palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(palette.line)
                    }
                    .overlay(alignment: .topLeading) {
                        if model.composerText.isEmpty && !model.speech.isRecording {
                            Text("Ask the active agent, dictate, paste an image, or drop files…")
                                .foregroundStyle(palette.faint)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 15)
                                .allowsHitTesting(false)
                        } else if model.speech.isRecording {
                            Text(model.speech.transcript.isEmpty ? "Listening…" : model.speech.transcript)
                                .foregroundStyle(palette.dim)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 15)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Prompt composer")
                    .accessibilityHint("Command Return sends to the named target below")

                Button("Send", action: model.sendComposer)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityHint(sendTargetLabel)
            }

            HStack(spacing: 8) {
                Text(sendTargetLabel)
                    .font(.caption2.bold())
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
                if let status = model.statusMessage {
                    Text("· \(status)")
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(status)
                        .accessibilityLabel(status)
                }
                Spacer()
                Button(action: model.captureComposerToInbox) {
                    Label("Capture", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(palette.dim)
                .accessibilityLabel("Capture composer to MainFrame inbox")
                .help("Append this prompt and attachments to MainFrame 00_inbox")
            }
        }
    }
}
#endif
