#if os(macOS)
import ConduitCore
import Foundation

/// Discovers models through the installed agent CLI, without maintaining a
/// second provider registry in Conduit. Discovery is lazy: opening a model
/// menu or explicitly refreshing it is the only trigger.
struct AgentModelCatalogService {
    static func discover(for agent: AgentProfile) async -> [AgentModelOption] {
        await BlockingWork.run(qos: .utility) {
            EnvironmentResolver.shared.prewarm()
            guard let executable = EnvironmentResolver.shared.resolve(agent.command) else {
                return fallbackOption(for: agent)
            }

            let command = normalizedExecutable(agent.command)
            switch command {
            case "ollama":
                return ollamaModels(executable: executable)
            case "opencode":
                return openCodeModels(executable: executable)
            case "cursor-agent":
                return cursorModels(executable: executable)
            default:
                return fallbackOption(for: agent)
            }
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
            default:
                return nil
            }
        }
    }

    private static func ollamaModels(executable: String) -> [AgentModelOption] {
        let result = SubprocessRunner.run(executable, ["ls"], timeout: 15)
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
        let result = SubprocessRunner.run(executable, ["models"], timeout: 20)
        guard result.status == 0 else { return [] }
        return dedupeAndSort(
            result.output
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .compactMap { rawLine in
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { return nil }
                    let id = line.components(separatedBy: " - ").first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? line
                    guard isLikelyModelID(id), id.lowercased() != "available models" else {
                        return nil
                    }
                    return AgentModelOption(
                        id: id,
                        detail: "Cursor model; context limit not reported"
                    )
                }
        )
    }

    private static func fallbackOption(for agent: AgentProfile) -> [AgentModelOption] {
        guard let model = agent.model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return [] }
        return [AgentModelOption(id: model, detail: "Configured model")]
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
            for key in ["context", "contextWindow", "contextWindowTokens"] {
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

    private static func isLikelyModelID(_ value: String) -> Bool {
        let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              line.count < 240,
              !line.contains("{") && !line.contains("}") && !line.contains(":")
        else { return false }
        let lower = line.lowercased()
        let ignored = ["available models", "model", "models", "provider", "name"]
        guard !ignored.contains(lower) else { return false }
        return !line.contains(where: { $0.isWhitespace })
    }

    private static func normalizedExecutable(_ command: String) -> String {
        URL(fileURLWithPath: command).lastPathComponent.lowercased()
    }

    private static func dedupeAndSort(_ options: [AgentModelOption]) -> [AgentModelOption] {
        var seen = Set<String>()
        return options
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
#endif
