#if os(macOS)
import AppKit
import ConduitCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// UI-only helpers for explicit copy/reveal/export operations.
///
/// The append-only JSONL stays the durable source. Human-readable export is a
/// derived projection and is written only after the operator chooses a target.
enum ConversationTranscriptActions {
    static let conversationDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".conduit/conversations", isDirectory: true)

    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    static func logURL(taskSessionID: TaskSessionID) -> URL {
        ConversationEventLog(
            directory: conversationDirectory,
            taskSessionID: taskSessionID
        ).url
    }

    static func revealLog(taskSessionID: TaskSessionID) throws {
        let url = logURL(taskSessionID: taskSessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversationTranscriptActionError.logMissing(url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func exportMarkdown(
        events: [SessionPresentationEvent],
        agentLabel: String,
        taskSessionID: TaskSessionID?
    ) throws {
        let text = ConversationTranscript.markdown(
            events: events,
            agentLabel: agentLabel
        )
        guard !text.isEmpty else {
            throw ConversationTranscriptActionError.emptyTranscript
        }

        let panel = NSSavePanel()
        panel.title = "Export Conduit Transcript"
        panel.prompt = "Export"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        if let taskSessionID {
            panel.nameFieldStringValue =
                "conduit-transcript-\(taskSessionID.rawValue.uuidString.lowercased()).md"
        } else {
            panel.nameFieldStringValue = "conduit-transcript.md"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

enum ConversationTranscriptActionError: LocalizedError {
    case logMissing(URL)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .logMissing(let url):
            return "No retained conversation log exists at \(url.path)."
        case .emptyTranscript:
            return "There is no projected conversation text to export."
        }
    }
}

/// Compact selected-thread actions. Keeping these operations in one menu makes
/// retained history discoverable without adding another permanent toolbar.
struct ConversationTranscriptMenu: View {
    let events: [SessionPresentationEvent]
    let agentLabel: String
    let taskSessionID: TaskSessionID?

    @State private var errorMessage: String?

    var body: some View {
        Menu {
            Button("Copy transcript") {
                let transcript = ConversationTranscript.markdown(
                    events: events,
                    agentLabel: agentLabel
                )
                guard !transcript.isEmpty else { return }
                ConversationTranscriptActions.copy(transcript)
            }
            .disabled(events.isEmpty)

            Button("Export transcript…") {
                do {
                    try ConversationTranscriptActions.exportMarkdown(
                        events: events,
                        agentLabel: agentLabel,
                        taskSessionID: taskSessionID
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .disabled(events.isEmpty)

            Divider()

            Button("Reveal retained log in Finder") {
                guard let taskSessionID else { return }
                do {
                    try ConversationTranscriptActions.revealLog(
                        taskSessionID: taskSessionID
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .disabled(taskSessionID == nil)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("Conversation actions")
        .accessibilityLabel("Conversation actions")
        .alert(
            "Conversation action failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }
}

/// Small, explicit whole-turn copy control. Partial selection continues to use
/// normal macOS text selection and Command-C.
struct ConversationCopyTurnButton: View {
    let text: String

    var body: some View {
        Button {
            ConversationTranscriptActions.copy(text)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption2)
        }
        .buttonStyle(.borderless)
        .disabled(text.isEmpty)
        .help("Copy turn")
        .accessibilityLabel("Copy turn")
    }
}

/// Single selectable Text node for one rendered assistant document. A single
/// node avoids the previous selection boundary between heading/list/code views.
/// Whole-turn copying still uses the original Markdown projection so code fences
/// and readable line breaks are preserved.
struct ConversationSelectableDocument: View {
    let text: String
    let foreground: Color
    var font: Font = .callout
    var lineSpacing: CGFloat = 2

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }

    var body: some View {
        Text(attributed)
            .font(font)
            .foregroundStyle(foreground)
            .textSelection(.enabled)
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Cache immutable assistant projections so a growing live turn does not force
/// completed turns to repeatedly scrub terminal chrome and parse Markdown.
final class ConversationPresentationCache: ObservableObject {
    struct Presentation {
        let sourceText: String
        let displayText: String
        let attributedText: AttributedString
        let menuOptions: [TerminalMenuOption]
        let looksLikeInteractiveMenu: Bool
    }

    private var entries: [UUID: Presentation] = [:]

    func presentation(
        eventID: UUID,
        output: AgentVisibleOutput
    ) -> Presentation {
        if output.state != .live,
           let cached = entries[eventID],
           cached.sourceText == output.text {
            return cached
        }

        let display = ConversationDisplayText.workstationDerived(output.text)
        let attributed = (try? AttributedString(
            markdown: display,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(display)
        let presentation = Presentation(
            sourceText: output.text,
            displayText: display,
            attributedText: attributed,
            menuOptions: TerminalMenuParser.options(in: display),
            looksLikeInteractiveMenu: TerminalMenuParser.looksLikeInteractiveMenu(display)
        )
        if output.state != .live {
            entries[eventID] = presentation
        }
        return presentation
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}

struct ConversationCachedSelectableDocument: View {
    let attributed: AttributedString
    let foreground: Color
    var font: Font = .callout
    var lineSpacing: CGFloat = 2

    var body: some View {
        Text(attributed)
            .font(font)
            .foregroundStyle(foreground)
            .textSelection(.enabled)
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
