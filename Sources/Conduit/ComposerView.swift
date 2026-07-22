#if os(macOS)
import ConduitCore
import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var model: AppModel

    private var sendTargetLabel: String {
        if let session = model.activeSession {
            return "Send target: \(session.descriptor.agent.name)"
        }
        return "Send target: new shell"
    }

    var body: some View {
        VStack(spacing: 6) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.attachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachment.url.hasDirectoryPath ? "folder" : "doc")
                                Text(attachment.url.lastPathComponent).lineLimit(1)
                                Button {
                                    model.removeAttachment(attachment)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(attachment.url.lastPathComponent)")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }

            HStack(alignment: .center, spacing: 9) {
                Button(action: model.toggleSpeech) {
                    Image(systemName: model.speech.isRecording ? "stop.circle.fill" : "mic.fill")
                        .foregroundStyle(model.speech.isRecording ? .red : .primary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(model.speech.isRecording ? "Stop dictation" : "Dictate prompt")
                .help(model.speech.isRecording ? "Stop dictation" : "Dictate prompt")

                Button(action: model.addFiles) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Attach files or folders")
                .help("Attach files or folders")

                Menu {
                    Button("Paste image", action: model.pasteImage)
                    Button("Capture screen area", action: model.captureScreen)
                } label: {
                    Image(systemName: "photo")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Add an image")

                TextEditor(text: $model.composerText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .padding(7)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.secondary.opacity(0.14))
                    }
                    .overlay(alignment: .topLeading) {
                        if model.composerText.isEmpty && !model.speech.isRecording {
                            Text("Ask the active agent, dictate, paste an image, or drop files…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 15)
                                .allowsHitTesting(false)
                        } else if model.speech.isRecording {
                            Text(model.speech.transcript.isEmpty ? "Listening…" : model.speech.transcript)
                                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let status = model.statusMessage {
                    Text("· \(status)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(action: model.captureComposerToInbox) {
                    Label("Capture", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("Capture composer to MainFrame inbox")
                .help("Append this prompt and attachments to MainFrame 00_inbox")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
#endif
