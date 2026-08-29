import Foundation

/// Explicit lifecycle for one terminal session. The controller may only move
/// through validated transitions; UI state is derived from this single value.
public enum SessionLifecycle: Equatable, Sendable {
    case idle
    case launching
    case running
    case detached
    case exited(code: Int32?)

    public var isTerminal: Bool {
        switch self {
        case .detached, .exited: return true
        case .idle, .launching, .running: return false
        }
    }

    /// Returns true when `next` is a legal transition from the current state.
    public func canTransition(to next: SessionLifecycle) -> Bool {
        switch (self, next) {
        case (.idle, .launching):
            return true
        case (.launching, .running), (.launching, .detached), (.launching, .exited):
            return true
        case (.running, .detached), (.running, .exited):
            return true
        default:
            return false
        }
    }

    /// Attempts the transition; returns false (unchanged) when illegal.
    @discardableResult
    public mutating func transition(to next: SessionLifecycle) -> Bool {
        guard canTransition(to: next) else { return false }
        self = next
        return true
    }
}

/// Deterministic tmux session naming shared by launch, reconnect, and detach.
public enum TmuxSessionNaming {
    /// Instance 1 keeps the historic name exactly, so sessions created before
    /// multi-instance support stay reattachable rather than being orphaned.
    /// Later instances append `-2`, `-3`, … to that same stem.
    public static func sessionName(
        projectPath: URL,
        agentName: String,
        instance: Int
    ) -> String {
        let base = sessionName(projectPath: projectPath, agentName: agentName)
        guard instance > 1 else { return base }
        return "\(base)-\(instance)"
    }

    /// The lowest instance number whose name is not already taken.
    public static func nextInstance(
        projectPath: URL,
        agentName: String,
        existingNames: Set<String>
    ) -> Int {
        var instance = 1
        while existingNames.contains(
            sessionName(projectPath: projectPath, agentName: agentName, instance: instance)
        ) {
            instance += 1
        }
        return instance
    }

    public static func sessionName(projectPath: URL, agentName: String) -> String {
        let raw = "\(projectPath.standardizedFileURL.path)|\(agentName)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let project = safeName(projectPath.lastPathComponent)
        let agent = safeName(agentName)
        return String("conduit-\(project)-\(agent)-\(String(hash, radix: 16).suffix(8))".prefix(70))
    }

    private static func safeName(_ value: String) -> String {
        let transformed = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(transformed).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
    }
}

/// Decodes a raw `waitpid` status into a conventional exit code.
///
/// SwiftTerm's PTY path hands the delegate the raw wait status, not a decoded
/// code, so a child that exits 1 arrives as 256 and a signal death arrives as
/// the bare signal number. Receipts must record the real value.
public enum POSIXExitStatus {
    public static func decode(_ raw: Int32) -> Int32 {
        // WIFEXITED: low 7 bits are zero -> normal exit, code is bits 8..15.
        if raw & 0x7f == 0 {
            return (raw >> 8) & 0xff
        }
        // WIFSIGNALED: low 7 bits hold the signal. Shell convention: 128 + sig.
        let signal = raw & 0x7f
        if signal != 0x7f {
            return 128 + signal
        }
        // Stopped (0x7f) or otherwise undecodable: pass through unchanged.
        return raw
    }
}

public enum ShellQuoting {
    /// Single-quote a value for POSIX shells.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote a command and arguments as one shell line.
    public static func commandLine(_ command: String, _ arguments: [String]) -> String {
        ([command] + arguments).map(quote).joined(separator: " ")
    }
}

/// Encodes composer text into PTY bytes with correct paste semantics.
///
/// Raw bytes written to a PTY look like *typing*: embedded newlines act as
/// Enter presses. When the foreground application has enabled bracketed paste
/// (mode 2004), wrapping the payload in the paste markers delivers it as one
/// block; the trailing carriage return is the explicit submit.
public enum PromptEncoder {
    public static let bracketedPasteStart: [UInt8] = Array("\u{1b}[200~".utf8)
    public static let bracketedPasteEnd: [UInt8] = Array("\u{1b}[201~".utf8)

    public static func encode(text: String, bracketedPaste: Bool, submit: Bool) -> [UInt8] {
        let payload = normalized(text)
        guard !payload.isEmpty else { return [] }
        var bytes: [UInt8] = []
        if bracketedPaste {
            bytes += bracketedPasteStart
            bytes += Array(payload.utf8)
            bytes += bracketedPasteEnd
        } else {
            // Typing semantics: Enter is CR in raw mode, so newlines become \r.
            bytes += Array(payload.replacingOccurrences(of: "\n", with: "\r").utf8)
        }
        if submit {
            bytes += Array("\r".utf8)
        }
        return bytes
    }

    /// Trailing newlines/whitespace are stripped so "submit" stays a single
    /// explicit CR rather than an accidental double-Enter.
    public static func normalized(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
        while let last = value.last, last == "\n" || last == "\r" {
            value.removeLast()
        }
        return value
    }
}

/// Splits an arguments string respecting single and double quotes, so agent
/// profiles can carry arguments containing spaces.
public enum ArgumentTokenizer {
    public static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasContent = false
        var quote: Character?

        for character in input {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                hasContent = true
            } else if character == " " || character == "\t" {
                if hasContent || !current.isEmpty {
                    tokens.append(current)
                    current = ""
                    hasContent = false
                }
            } else {
                current.append(character)
            }
        }
        if hasContent || !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    /// Joins arguments back into an editable string, quoting where needed.
    /// The tokenizer has no escape syntax, so quoting picks whichever quote
    /// character the argument does not contain.
    public static func join(_ arguments: [String]) -> String {
        arguments.map { argument in
            if argument.isEmpty { return "\"\"" }
            let needsQuoting = argument.contains(" ") || argument.contains("\t")
                || argument.contains("\"") || argument.contains("'")
            guard needsQuoting else { return argument }
            if !argument.contains("\"") {
                return "\"" + argument + "\""
            }
            return "'" + argument + "'"
        }.joined(separator: " ")
    }
}
