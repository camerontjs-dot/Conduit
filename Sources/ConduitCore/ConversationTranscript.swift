import Foundation

/// Human-readable projection helpers for copy/export surfaces.
///
/// This deliberately consumes the already source-labelled presentation events.
/// It does not read Raw terminal bytes, infer tool activity from prose, or upgrade
/// any event's authority. The append-only JSONL remains the durable source.
public enum ConversationTranscript {
    /// Operator-facing text for one presentation event without hidden provenance
    /// or debug metadata. This is the default payload for `Copy turn`.
    public static func copyText(for event: SessionPresentationEvent) -> String {
        switch event.kind {
        case .sessionOpened(let entry):
            return sessionBoundaryText(entry)
        case .userPrompt(let prompt):
            return promptText(prompt)
        case .agentOutput(let output):
            return ConversationDisplayText.workstationDerived(output.text)
        case .interruptRequested:
            return "Interrupt requested"
        case .providerTurnFailed(let receipt):
            return receipt.reason
        }
    }

    /// Markdown transcript for explicit whole-thread copy/export.
    ///
    /// The transcript is a readable projection, not a Raw terminal transcript.
    /// Role labels are included so exported text remains understandable when it
    /// leaves the app. Source-authority details stay out of the default export.
    public static func markdown(
        events: [SessionPresentationEvent],
        agentLabel: String = "Agent"
    ) -> String {
        let turns = SessionPresentation.conversationTurns(from: events)
        var sections: [String] = []

        for turn in turns {
            switch turn.kind {
            case .boundary(let event):
                switch event.kind {
                case .sessionOpened(let entry):
                    sections.append("---\n\n_\(sessionBoundaryText(entry))_")
                case .interruptRequested:
                    sections.append("---\n\n_Interrupt requested_")
                case .providerTurnFailed(let receipt):
                    sections.append("---\n\n_Provider turn failed: \(receipt.reason)_")
                case .userPrompt, .agentOutput:
                    break
                }

            case .exchange(let user, let outputs):
                if let user, case .userPrompt(let prompt) = user.kind {
                    let text = promptText(prompt)
                    if !text.isEmpty {
                        sections.append("## You\n\n\(text)")
                    }
                }

                for outputEvent in outputs {
                    guard case .agentOutput(let output) = outputEvent.kind else {
                        continue
                    }
                    let text = ConversationDisplayText.workstationDerived(output.text)
                    guard !text.isEmpty else { continue }
                    sections.append("## \(agentLabel)\n\n\(text)")
                }
            }
        }

        return sections.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func promptText(_ prompt: SubmittedPrompt) -> String {
        var parts: [String] = []
        let body = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            parts.append(body)
        }
        if !prompt.attachmentPaths.isEmpty {
            let attachments = prompt.attachmentPaths
                .map { "- `\($0)`" }
                .joined(separator: "\n")
            parts.append("Attachments:\n\(attachments)")
        }
        return parts.joined(separator: "\n\n")
    }

    private static func sessionBoundaryText(_ entry: SessionEntry) -> String {
        switch entry {
        case .started(let agentName, _):
            return "Started \(agentName)"
        case .resumed(let agentName, let tmuxSessionName, let attachedElsewhere):
            var text = "Reattached \(agentName) · \(tmuxSessionName)"
            if attachedElsewhere {
                text += " · shared attach"
            }
            return text
        }
    }
}
