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

    private var slashMatches: [AgentSlashCommand] {
        AgentSlashCatalog.matches(
            query: model.composerText,
            projectPath: model.selectedTaskProject?.path
                ?? model.selectedProject?.path
        )
    }

    private var ordinaryComposer: some View {
        VStack(spacing: 6) {
            if !model.attachments.isEmpty {
                attachmentChipRow
            }

            if !slashMatches.isEmpty {
                slashCommandMenu
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
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "paperclip")
                            .foregroundStyle(
                                model.attachments.isEmpty ? palette.dim : palette.accent
                            )
                        if !model.attachments.isEmpty {
                            Text("\(model.attachments.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(palette.onAccent)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(palette.accent)
                                .clipShape(Capsule())
                                .offset(x: 8, y: -7)
                        }
                    }
                    .frame(minWidth: 18, minHeight: 16)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    model.attachments.isEmpty
                        ? "Attach files or folders"
                        : "Attach files or folders, \(model.attachments.count) attached"
                )
                .help(
                    model.attachments.isEmpty
                        ? "Attach files or folders"
                        : "\(model.attachments.count) attached — click to add more"
                )

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

                ZStack(alignment: .topLeading) {
                    ComposerTextView(
                        text: $model.composerText,
                        onSubmit: {
                            guard !isStaging else { return }
                            model.sendComposer()
                        },
                        onTabComplete: {
                            guard let first = slashMatches.first else { return false }
                            model.applySlashCommandToComposer(first.command)
                            return true
                        },
                        placeholder: "",
                        textColor: .labelColor,
                        backgroundColor: .textBackgroundColor,
                        insertionPointColor: .controlAccentColor
                    )
                    .frame(minHeight: 64, maxHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(
                                model.isDropTargeted ? palette.accent : palette.line,
                                lineWidth: model.isDropTargeted ? 2 : 1
                            )
                    }

                    if model.composerText.isEmpty && !model.speech.isRecording {
                        Text("Ask the active agent… / for skills · Return sends")
                            .foregroundStyle(palette.faint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    } else if model.speech.isRecording {
                        Text(model.speech.transcript.isEmpty ? "Listening…" : model.speech.transcript)
                            .foregroundStyle(palette.dim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Prompt composer")
                .accessibilityHint("Return sends. Type / for agent skills and slash commands. Shift Return inserts a newline.")

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
                if !model.attachments.isEmpty {
                    Text("· \(model.attachments.count) attached")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .accessibilityLabel("\(model.attachments.count) attachments ready")
                }
                if let status = model.statusMessage {
                    Text("· \(status)")
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                        .lineLimit(2)
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

    private var slashCommandMenu: some View {
        let matches = Array(slashMatches.prefix(10))
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Skills & slash commands")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.faint)
                Spacer()
                Text("Tab/click fills composer · Return runs CLI command")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().overlay(palette.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { item in
                        slashRow(item, isTop: item.id == matches.first?.id)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slash command suggestions")
    }

    private func slashRow(_ item: AgentSlashCommand, isTop: Bool) -> some View {
        Button {
            model.applySlashCommandToComposer(item.command)
        } label: {
            HStack(spacing: 10) {
                Text(item.command)
                    .font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .frame(minWidth: 110, alignment: .leading)
                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.source == .builtin ? "built-in" : "skill")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isTop ? palette.accentSoft : Color.clear)
        .accessibilityLabel("\(item.command), \(item.summary). Fills the composer.")
        .help("Put \(item.command) in the composer. Press Return to send.")
    }

    private var attachmentChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 6) {
                        attachmentThumbnail(for: attachment.url)
                        Text(attachment.url.lastPathComponent)
                            .lineLimit(1)
                            .foregroundStyle(palette.text)
                            .help(attachment.url.path)
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
                    .padding(.vertical, 5)
                    .background(palette.lineSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(palette.accent.opacity(0.35), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Attached \(attachment.url.lastPathComponent)")
                }
            }
        }
        .accessibilityLabel("\(model.attachments.count) attachments")
    }

    @ViewBuilder
    private func attachmentThumbnail(for url: URL) -> some View {
        if url.hasDirectoryPath {
            Image(systemName: "folder.fill")
                .foregroundStyle(palette.dim)
                .frame(width: 22, height: 22)
        } else if Self.isImageURL(url), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.fill")
                .foregroundStyle(palette.dim)
                .frame(width: 22, height: 22)
        }
    }

    private static func isImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic"].contains(ext)
    }
}
#endif
