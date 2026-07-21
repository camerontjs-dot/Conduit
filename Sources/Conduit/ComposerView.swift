#if os(macOS)
import ConduitCore
import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
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
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 9) {
                Button(action: model.toggleSpeech) {
                    Image(systemName: model.speech.isRecording ? "stop.circle.fill" : "mic.fill")
                        .foregroundStyle(model.speech.isRecording ? .red : .primary)
                }
                .buttonStyle(.borderless)
                .help(model.speech.isRecording ? "Stop dictation" : "Dictate prompt")

                Button(action: model.addFiles) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .help("Attach files or folders")

                Menu {
                    Button("Paste image", action: model.pasteImage)
                    Button("Capture screen area", action: model.captureScreen)
                } label: {
                    Image(systemName: "photo")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                TextEditor(text: $model.composerText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 54, maxHeight: 150)
                    .padding(7)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
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

                VStack(spacing: 6) {
                    Button("Send", action: model.sendComposer)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])
                    Button("Capture", action: model.captureComposerToInbox)
                        .buttonStyle(.bordered)
                        .font(.caption)
                        .help("Capture this prompt and attachments to MainFrame 00_inbox")
                }
            }

            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.bar)
    }
}
#endif
