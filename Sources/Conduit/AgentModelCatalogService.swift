#if os(macOS)
import ConduitCore
import Foundation

/// Discovers models through the installed agent CLI, without maintaining a
/// second provider registry in Conduit. Discovery is lazy: opening a model
/// menu or explicitly refreshing it is the only trigger.
///
/// CLIs that expose a real catalog (OpenCode, Codex, Cursor, Grok, Agy,
/// Ollama, Aider) are preferred. Claude and Gemini CLI do not list models via
/// a non-interactive flag, so Conduit falls back to the aliases those CLIs
/// document in `--help` / their own picker — labeled as aliases, never as
/// vendor-reported inventory.
struct AgentModelCatalogService {
    static func discover(for agent: AgentProfile) async -> [AgentModelOption] {
        await BlockingWork.run(qos: .utility) {
            EnvironmentResolver.shared.prewarm()
            guard let executable = EnvironmentResolver.shared.resolve(agent.command) else {
                return mergeWithConfigured(fallbackOption(for: agent), agent: agent)
            }

            let command = normalizedExecutable(agent.command)
            let discovered: [AgentModelOption]
            switch command {
            case "ollama":
                discovered = ollamaModels(executable: executable)
            case "opencode":
                discovered = openCodeModels(executable: executable)
            case "cursor-agent", "agent":
                discovered = cursorModels(executable: executable)
            case "codex":
                discovered = codexModels(executable: executable)
            case "grok":
                discovered = grokModels(executable: executable)
            case "agy":
                discovered = agyModels(executable: executable)
            case "aider":
                discovered = aiderModels(executable: executable)
            case "claude":
                discovered = claudeAliasModels()
            case "gemini":
                discovered = geminiAliasModels()
            default:
                discovered = genericModelsSubcommand(executable: executable)
            }

            if discovered.isEmpty {
                return mergeWithConfigured(fallbackOption(for: agent), agent: agent)
            }
            return mergeWithConfigured(discovered, agent: agent)
        }
    }

    static func contextWindowTokens(
        for agent: AgentProfile,
        model: String
    ) async -> Int? {
        await BlockingWork.run(qos: .utility) {
            EnvironmentResolver.shared.prewarm()
            guard let executable = EnvironmentResolver.shared.resolve(agent.command) else {
                return nil
            }

            switch normalizedExecutable(agent.command) {
            case "ollama":
                return ollamaContext(executable: executable, model: model)
            case "opencode":
                return openCodeModels(executable: executable)
                    .first(where: { $0.id == model })?.contextWindowTokens
            case "codex":
                return codexModels(executable: executable)
                    .first(where: { $0.id == model })?.contextWindowTokens
            default:
                return nil
            }
        }
    }

    // MARK: - CLI catalogs

    private static func ollamaModels(executable: String) -> [AgentModelOption] {
        // Prefer `list` (documented); fall back to `ls`.
        let primary = SubprocessRunner.run(executable, ["list"], timeout: 15)
        let result = primary.status == 0
            ? primary
            : SubprocessRunner.run(executable, ["ls"], timeout: 15)
        guard result.status == 0 else { return [] }
        let options = result.output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { line -> AgentModelOption? in
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard let name = fields.first, !name.isEmpty else { return nil }
                let id = String(name)
                guard id.lowercased() != "name" else { return nil }
                let detail = id.lowercased().contains("-cloud")
                    ? "Ollama cloud tag; account usage not reported here"
                    : "Ollama local model"
                return AgentModelOption(id: id, detail: detail)
            }
        return dedupeAndSort(options)
    }

    private static func ollamaContext(executable: String, model: String) -> Int? {
        let result = SubprocessRunner.run(
            executable,
            ["show", model, "--verbose"],
            timeout: 20
        )
        guard result.status == 0 else { return nil }
        return integerAfterMarker("context length", in: result.output)
    }

    private static func openCodeModels(executable: String) -> [AgentModelOption] {
        let verbose = SubprocessRunner.run(
            executable,
            ["models", "--verbose"],
            timeout: 20
        )
        let parsed = parseOpenCodeVerbose(verbose.output)
        if !parsed.isEmpty { return parsed }

        let simple = SubprocessRunner.run(executable, ["models"], timeout: 15)
        return dedupeAndSort(
            simple.output
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter(isLikelyModelID)
                .map { option(for: $0, provider: "OpenCode") }
        )
    }

    private static func parseOpenCodeVerbose(_ output: String) -> [AgentModelOption] {
        var options: [AgentModelOption] = []
        var pendingID: String?
        var jsonBuffer = ""
        var jsonBalance = 0

        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if !jsonBuffer.isEmpty {
                jsonBuffer += line
                jsonBalance += jsonBalanceDelta(in: line)
                if jsonBalance <= 0 {
                    appendOpenCodeOption(
                        id: pendingID,
                        json: jsonBuffer,
                        to: &options
                    )
                    pendingID = nil
                    jsonBuffer = ""
                    jsonBalance = 0
                }
                continue
            }

            if line.hasPrefix("{") || line.hasPrefix("[") {
                jsonBuffer = line
                jsonBalance = jsonBalanceDelta(in: line)
                if jsonBalance <= 0 {
                    appendOpenCodeOption(
                        id: pendingID,
                        json: jsonBuffer,
                        to: &options
                    )
                    pendingID = nil
                    jsonBuffer = ""
                    jsonBalance = 0
                }
                continue
            }

            guard isLikelyModelID(line) else { continue }
            if let currentID = pendingID {
                options.append(option(for: currentID, provider: "OpenCode"))
            }
            pendingID = line
        }

        if !jsonBuffer.isEmpty {
            appendOpenCodeOption(id: pendingID, json: jsonBuffer, to: &options)
            pendingID = nil
        }
        if let currentID = pendingID {
            options.append(option(for: currentID, provider: "OpenCode"))
        }
        return dedupeAndSort(options)
    }

    private static func appendOpenCodeOption(
        id: String?,
        json: String,
        to options: inout [AgentModelOption]
    ) {
        guard let id else { return }
        options.append(
            option(
                for: id,
                provider: "OpenCode",
                contextWindowTokens: contextValue(in: json)
            )
        )
    }

    private static func jsonBalanceDelta(in line: String) -> Int {
        line.reduce(into: 0) { balance, character in
            switch character {
            case "{", "[": balance += 1
            case "}", "]": balance -= 1
            default: break
            }
        }
    }

    private static func cursorModels(executable: String) -> [AgentModelOption] {
        let result = SubprocessRunner.run(executable, ["models"], timeout: 25)
        guard result.status == 0 || !result.output.isEmpty else { return [] }
        return dedupeAndSort(
            result.output
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .compactMap { rawLine in
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { return nil }
                    // "id - Display Name" or bare id
                    let id: String
                    let display: String?
                    if let range = line.range(of: " - ") {
                        id = String(line[..<range.lowerBound])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        display = String(line[range.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        id = line
                        display = nil
                    }
                    guard isLikelyModelID(id), id.lowercased() != "available models" else {
                        return nil
                    }
                    return AgentModelOption(
                        id: id,
                        displayName: display,
                        detail: "Cursor model; context limit not reported"
                    )
                }
        )
    }

    /// Codex exposes a raw JSON catalog via `codex debug models`.
    private static func codexModels(executable: String) -> [AgentModelOption] {
        let result = SubprocessRunner.run(
            executable,
            ["debug", "models"],
            timeout: 30
        )
        guard !result.output.isEmpty else { return [] }

        guard let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return []
        }

        let models: [[String: Any]]
        if let root = object as? [String: Any],
           let list = root["models"] as? [[String: Any]] {
            models = list
        } else if let list = object as? [[String: Any]] {
            models = list
        } else {
            return []
        }

        let options: [AgentModelOption] = models.compactMap { entry in
            let visibility = (entry["visibility"] as? String)?.lowercased()
            // Hide internal routing aliases unless the operator already uses one.
            if visibility == "hide" { return nil }

            guard let slug = stringValue(entry["slug"])
                ?? stringValue(entry["id"])
                ?? stringValue(entry["name"]),
                !slug.isEmpty
            else { return nil }

            let display = stringValue(entry["display_name"])
                ?? stringValue(entry["displayName"])
            let description = stringValue(entry["description"])
            let context = integerValue(entry["context_window"])
                ?? integerValue(entry["contextWindow"])
                ?? integerValue(entry["context_window_tokens"])

            var detailParts: [String] = []
            if let description, !description.isEmpty {
                detailParts.append(description)
            } else {
                detailParts.append("Codex model")
            }
            if let levels = entry["supported_reasoning_levels"] as? [[String: Any]],
               !levels.isEmpty {
                let efforts = levels.compactMap { stringValue($0["effort"]) }
                if !efforts.isEmpty {
                    detailParts.append("effort: \(efforts.joined(separator: "/"))")
                }
            }

            return AgentModelOption(
                id: slug,
                displayName: display,
                detail: detailParts.joined(separator: " · "),
                contextWindowTokens: context
            )
        }
        return dedupeAndSort(options)
    }

    /// `grok models` prints a bullet list under "Available models:".
    private static func grokModels(executable: String) -> [AgentModelOption] {
        let result = SubprocessRunner.run(executable, ["models"], timeout: 20)
        guard !result.output.isEmpty else { return [] }

        var options: [AgentModelOption] = []
        var inList = false
        for rawLine in result.output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.lowercased().hasPrefix("available models") {
                inList = true
                continue
            }
            if line.lowercased().hasPrefix("default model:") {
                // "Default model: grok-4.5"
                if let colon = line.firstIndex(of: ":") {
                    let id = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if isLikelyModelID(id) {
                        options.append(
                            AgentModelOption(
                                id: id,
                                displayName: id,
                                detail: "Grok default model"
                            )
                        )
                    }
                }
                continue
            }
            guard inList || line.hasPrefix("*") || line.hasPrefix("-") else { continue }

            var token = line
            if token.hasPrefix("*") || token.hasPrefix("-") {
                token = String(token.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            // "grok-4.5 (default)" → id + note
            var detail = "Grok model"
            if let paren = token.range(of: " (") {
                let note = String(token[paren.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                if !note.isEmpty { detail = "Grok model · \(note)" }
                token = String(token[..<paren.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
            guard isLikelyModelID(token) else { continue }
            options.append(AgentModelOption(id: token, detail: detail))
        }
        return dedupeAndSort(options)
    }

    /// `agy models` prints `id<TAB>Display Name` (or id glued to display).
    private static func agyModels(executable: String) -> [AgentModelOption] {
        let result = SubprocessRunner.run(executable, ["models"], timeout: 25)
        guard !result.output.isEmpty else { return [] }

        return dedupeAndSort(
            result.output
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .compactMap { rawLine -> AgentModelOption? in
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { return nil }
                    let lower = line.lowercased()
                    if lower.contains("fetching available")
                        || lower.hasPrefix("usage")
                        || lower.hasPrefix("error")
                    {
                        return nil
                    }

                    if line.contains("\t") {
                        let parts = line.split(separator: "\t", maxSplits: 1)
                        let id = String(parts[0]).trimmingCharacters(in: .whitespaces)
                        let display = parts.count > 1
                            ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                            : nil
                        guard isLikelyModelID(id) else { return nil }
                        return AgentModelOption(
                            id: id,
                            displayName: display,
                            detail: "Antigravity model"
                        )
                    }

                    // idDisplayName with no separator: split at first uppercase after id.
                    if let match = line.range(
                        of: #"^([a-z0-9][a-z0-9._-]*)([A-Z].*)$"#,
                        options: .regularExpression
                    ) {
                        let full = String(line[match])
                        if let idRange = full.range(
                            of: #"^[a-z0-9][a-z0-9._-]*"#,
                            options: .regularExpression
                        ) {
                            let id = String(full[idRange])
                            let display = String(full[idRange.upperBound...])
                            guard isLikelyModelID(id) else { return nil }
                            return AgentModelOption(
                                id: id,
                                displayName: display.isEmpty ? nil : display,
                                detail: "Antigravity model"
                            )
                        }
                    }

                    guard isLikelyModelID(line) else { return nil }
                    return AgentModelOption(id: line, detail: "Antigravity model")
                }
        )
    }

    /// Aider's full catalog is huge; surface a practical shortlist plus any
    /// local Ollama tags (as `ollama/<name>`), and sample common provider
    /// prefixes when the CLI responds quickly.
    private static func aiderModels(executable: String) -> [AgentModelOption] {
        var options: [AgentModelOption] = curatedAiderModels()

        // Local Ollama tags are high-value for Aider BYOK/local setups.
        if let ollama = EnvironmentResolver.shared.resolve("ollama") {
            for model in ollamaModels(executable: ollama) {
                let id = "ollama/\(model.id)"
                options.append(
                    AgentModelOption(
                        id: id,
                        detail: "Local Ollama via Aider"
                    )
                )
            }
        }

        // Sample a few popular prefixes; ignore failures / slow prompts.
        for query in ["anthropic/claude", "openai/gpt", "gemini-2.5"] {
            let result = SubprocessRunner.run(
                executable,
                [
                    "--yes-always",
                    "--no-check-update",
                    "--no-git",
                    "--list-models",
                    query
                ],
                timeout: 18
            )
            guard result.status == 0 || !result.output.isEmpty else { continue }
            for rawLine in result.output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("- ") else { continue }
                let id = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard isLikelyModelID(id) || id.contains("/") else { continue }
                // Skip very long / obscure cloud routing IDs in the shortlist UI.
                if id.count > 80 { continue }
                options.append(
                    AgentModelOption(id: id, detail: "Aider model match for \(query)")
                )
            }
        }

        return dedupeAndSort(options)
    }

    private static func curatedAiderModels() -> [AgentModelOption] {
        let ids = [
            "anthropic/claude-sonnet-4-6",
            "anthropic/claude-opus-4-6",
            "anthropic/claude-haiku-4-5",
            "anthropic/claude-sonnet-4-5",
            "openai/gpt-4o",
            "openai/gpt-4.1",
            "openai/o3",
            "openai/o4-mini",
            "gemini/gemini-2.5-pro",
            "gemini/gemini-2.5-flash",
            "openrouter/anthropic/claude-sonnet-4.6",
            "openrouter/openai/gpt-4o"
        ]
        return ids.map {
            AgentModelOption(
                id: $0,
                detail: "Common Aider model id (configure keys in Aider/env)"
            )
        }
    }

    /// Claude Code has no non-interactive model list; use documented aliases
    /// and current family IDs from its own help / picker surface.
    private static func claudeAliasModels() -> [AgentModelOption] {
        let aliases: [(String, String, String)] = [
            ("fable", "Fable (alias)", "Claude alias → latest Fable"),
            ("opus", "Opus (alias)", "Claude alias → latest Opus"),
            ("sonnet", "Sonnet (alias)", "Claude alias → latest Sonnet"),
            ("haiku", "Haiku (alias)", "Claude alias → latest Haiku"),
            ("mythos", "Mythos (alias)", "Claude alias → latest Mythos"),
            ("claude-fable-5", "Claude Fable 5", "Claude model id"),
            ("claude-opus-5", "Claude Opus 5", "Claude model id"),
            ("claude-sonnet-5", "Claude Sonnet 5", "Claude model id"),
            ("claude-haiku-4-5", "Claude Haiku 4.5", "Claude model id"),
            ("claude-opus-4-8", "Claude Opus 4.8", "Claude model id"),
            ("claude-opus-4-7", "Claude Opus 4.7", "Claude model id"),
            ("claude-opus-4-6", "Claude Opus 4.6", "Claude model id"),
            ("claude-sonnet-4-6", "Claude Sonnet 4.6", "Claude model id"),
            ("claude-sonnet-4-5", "Claude Sonnet 4.5", "Claude model id"),
            ("claude-mythos-5", "Claude Mythos 5", "Claude model id")
        ]
        return aliases.map {
            AgentModelOption(id: $0.0, displayName: $0.1, detail: $0.2)
        }
    }

    /// Gemini CLI likewise lacks a list flag; surface aliases + defaults from
    /// the installed package's documented model constants.
    private static func geminiAliasModels() -> [AgentModelOption] {
        let aliases: [(String, String, String)] = [
            ("auto", "Auto (alias)", "Gemini alias"),
            ("pro", "Pro (alias)", "Gemini alias"),
            ("flash", "Flash (alias)", "Gemini alias"),
            ("flash-lite", "Flash Lite (alias)", "Gemini alias"),
            ("auto-gemini-2.5", "Auto Gemini 2.5", "Gemini model id"),
            ("auto-gemini-3", "Auto Gemini 3", "Gemini model id"),
            ("gemini-2.5-pro", "Gemini 2.5 Pro", "Gemini model id"),
            ("gemini-2.5-flash", "Gemini 2.5 Flash", "Gemini model id"),
            ("gemini-3.5-flash", "Gemini 3.5 Flash", "Gemini model id"),
            ("gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite", "Gemini model id"),
            ("gemini-3-pro-preview", "Gemini 3 Pro Preview", "Gemini model id"),
            ("gemini-3.1-pro-preview", "Gemini 3.1 Pro Preview", "Gemini model id"),
            ("gemini-3-flash-preview", "Gemini 3 Flash Preview", "Gemini model id")
        ]
        return aliases.map {
            AgentModelOption(id: $0.0, displayName: $0.1, detail: $0.2)
        }
    }

    /// Best-effort: many CLIs grow a `models` subcommand over time.
    private static func genericModelsSubcommand(executable: String) -> [AgentModelOption] {
        let result = SubprocessRunner.run(executable, ["models"], timeout: 15)
        guard result.status == 0, !result.output.isEmpty else { return [] }
        return dedupeAndSort(
            result.output
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .compactMap { rawLine in
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard isLikelyModelID(line) else { return nil }
                    return AgentModelOption(
                        id: line,
                        detail: "Reported by CLI models subcommand"
                    )
                }
        )
    }

    // MARK: - Helpers

    private static func mergeWithConfigured(
        _ options: [AgentModelOption],
        agent: AgentProfile
    ) -> [AgentModelOption] {
        guard let model = agent.model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return options }
        if options.contains(where: { $0.id == model }) { return options }
        var merged = options
        merged.insert(
            AgentModelOption(
                id: model,
                detail: "Configured model",
                contextWindowTokens: agent.contextWindowTokens
            ),
            at: 0
        )
        return merged
    }

    private static func fallbackOption(for agent: AgentProfile) -> [AgentModelOption] {
        guard let model = agent.model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return [] }
        return [
            AgentModelOption(
                id: model,
                detail: "Configured model",
                contextWindowTokens: agent.contextWindowTokens
            )
        ]
    }

    private static func option(
        for id: String,
        provider: String,
        contextWindowTokens: Int? = nil
    ) -> AgentModelOption {
        let detail: String
        if id.lowercased().contains("free") {
            detail = "\(provider) free model; limits may vary"
        } else {
            detail = "\(provider) model"
        }
        return AgentModelOption(
            id: id,
            detail: detail,
            contextWindowTokens: contextWindowTokens
        )
    }

    private static func contextValue(in jsonLine: String) -> Int? {
        guard let data = jsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return contextValue(in: object)
    }

    private static func contextValue(in object: Any) -> Int? {
        if let dictionary = object as? [String: Any] {
            for key in ["context", "contextWindow", "contextWindowTokens", "context_window"] {
                if let value = integerValue(dictionary[key]) { return value }
            }
            for value in dictionary.values {
                if let found = contextValue(in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = contextValue(in: value) { return found }
            }
        }
        return nil
    }

    private static func integerAfterMarker(_ marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker, options: .caseInsensitive) else {
            return nil
        }
        let tail = text[range.upperBound...]
        return tail
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" })
            .compactMap { Int($0.filter { $0.isNumber }) }
            .first
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Accepts typical model IDs: `gpt-5.6-sol`, `opencode/foo`, `claude-sonnet-5`.
    /// Colons (Ollama tags) are allowed when the whole token is otherwise clean.
    private static func isLikelyModelID(_ value: String) -> Bool {
        let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              line.count < 240,
              !line.contains("{") && !line.contains("}")
        else { return false }
        let lower = line.lowercased()
        let ignored = [
            "available models", "model", "models", "provider", "name",
            "default model", "fetching available models..."
        ]
        guard !ignored.contains(lower) else { return false }
        // Reject prose lines with spaces (except intentional multi-word ids are rare).
        if line.contains(where: { $0.isWhitespace }) { return false }
        // Must look like an identifier, not a sentence.
        return line.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._/:@+-]*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func normalizedExecutable(_ command: String) -> String {
        URL(fileURLWithPath: command).lastPathComponent.lowercased()
    }

    private static func dedupeAndSort(_ options: [AgentModelOption]) -> [AgentModelOption] {
        var seen = Set<String>()
        return options
            .filter { seen.insert($0.id).inserted }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
    }
}
#endif
