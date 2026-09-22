import Foundation

/// Classifies one `tmux has-session` observation without inventing absence.
///
/// tmux reports both "session is absent" and genuine inspection failures with a
/// non-zero exit status. Only diagnostics that establish the named session
/// cannot exist at this observation boundary are treated as `.absent`.
public enum TmuxSessionPresence: Equatable, Sendable {
    case present
    case absent
    case unknown
}

public enum TmuxSessionPresenceClassifier {
    public static func classify(
        exitStatus: Int32,
        output: String
    ) -> TmuxSessionPresence {
        if exitStatus == 0 {
            return .present
        }

        let diagnostic = output.lowercased()

        if diagnostic.contains("can't find session")
            || diagnostic.contains("no server running") {
            return .absent
        }

        // tmux 3.6b on a machine with no server may report the missing socket
        // directly rather than the older "no server running" wording:
        //
        // error connecting to /private/tmp/tmux-501/default
        // (No such file or directory)
        //
        // Restrict this to tmux's connection diagnostic. A generic filesystem
        // ENOENT elsewhere is not proof that the session is absent.
        if diagnostic.contains("error connecting to")
            && diagnostic.contains("no such file or directory") {
            return .absent
        }

        return .unknown
    }
}
