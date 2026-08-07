#if os(macOS)
import ConduitCore
import Foundation
import Security

/// Fetches **account-reported** usage from vendor CLIs / OAuth.
///
/// Separate from Tier A Conduit observation. Never logs tokens or secrets.
enum AccountUsageService {
    static func refreshAll() async -> [AccountUsageSnapshot] {
        async let claude = fetchClaude()
        async let codex = fetchCodex()
        async let openCode = fetchOpenCode()
        return await [claude, codex, openCode]
    }

    // MARK: - Claude (Anthropic OAuth usage)

    private static func fetchClaude() async -> AccountUsageSnapshot {
        await BlockingWork.run(qos: .userInitiated) {
            do {
                guard let token = readClaudeOAuthAccessToken() else {
                    return AccountUsageSnapshot(
                        agentName: "Claude",
                        sourceLabel: "Anthropic account",
                        error: "Not signed in to Claude Code (no OAuth token in Keychain)."
                    )
                }
                var request = URLRequest(
                    url: URL(string: "https://api.anthropic.com/api/oauth/usage")!
                )
                request.httpMethod = "GET"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(
                    "oauth-2025-04-20",
                    forHTTPHeaderField: "anthropic-beta"
                )
                request.setValue("Conduit", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 15

                let sem = DispatchSemaphore(value: 0)
                var resultData: Data?
                var resultError: String?
                URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error {
                        resultError = error.localizedDescription
                    } else if let http = response as? HTTPURLResponse,
                              !(200...299).contains(http.statusCode) {
                        resultError = "HTTP \(http.statusCode)"
                    } else {
                        resultData = data
                    }
                    sem.signal()
                }.resume()
                if sem.wait(timeout: .now() + 18) == .timedOut {
                    return AccountUsageSnapshot(
                        agentName: "Claude",
                        sourceLabel: "Anthropic account",
                        error: "Timed out contacting Anthropic usage API."
                    )
                }
                if let resultError {
                    return AccountUsageSnapshot(
                        agentName: "Claude",
                        sourceLabel: "Anthropic account",
                        error: resultError
                    )
                }
                guard let resultData else {
                    return AccountUsageSnapshot(
                        agentName: "Claude",
                        sourceLabel: "Anthropic account",
                        error: "Empty usage response."
                    )
                }
                return try AccountUsageParsing.parseClaudeOAuthUsage(resultData)
            } catch {
                return AccountUsageSnapshot(
                    agentName: "Claude",
                    sourceLabel: "Anthropic account",
                    error: error.localizedDescription
                )
            }
        }
    }

    /// Claude Code stores OAuth JSON in the login keychain item.
    private static func readClaudeOAuthAccessToken() -> String? {
        // Prefer Keychain (current Claude Code layout on this Mac).
        if let raw = readKeychainPassword(service: "Claude Code-credentials"),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = obj["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String,
           !token.isEmpty {
            return token
        }
        // Legacy file path used by some builds / docs.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = obj["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String,
           !token.isEmpty {
            return token
        }
        return nil
    }

    private static func readKeychainPassword(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    // MARK: - Codex (app-server rate limits)

    private static func fetchCodex() async -> AccountUsageSnapshot {
        await BlockingWork.run(qos: .userInitiated) {
            guard let codex = EnvironmentResolver.shared.resolve("codex"),
                  FileManager.default.isExecutableFile(atPath: codex)
            else {
                return AccountUsageSnapshot(
                    agentName: "Codex",
                    sourceLabel: "OpenAI / ChatGPT account",
                    error: "codex CLI not found on PATH."
                )
            }
            do {
                let data = try codexRateLimitsJSON(executable: codex)
                return try AccountUsageParsing.parseCodexRateLimits(data)
            } catch {
                return AccountUsageSnapshot(
                    agentName: "Codex",
                    sourceLabel: "OpenAI / ChatGPT account",
                    error: error.localizedDescription
                )
            }
        }
    }

    private static func codexRateLimitsJSON(executable: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        func send(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  var line = String(data: data, encoding: .utf8)
            else { return }
            line += "\n"
            stdin.fileHandleForWriting.write(Data(line.utf8))
        }

        send([
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "conduit",
                    "title": "Conduit",
                    "version": "1.0",
                ],
            ],
        ])
        // Brief settle — shorter values can yield empty rate-limit replies.
        Thread.sleep(forTimeInterval: 0.55)
        send([
            "method": "account/rateLimits/read",
            "id": 1,
            "params": [:] as [String: Any],
        ])

        let deadline = Date().addingTimeInterval(4)
        var buffer = Data()
        var matched: Data?
        while Date() < deadline {
            let chunk = stdout.fileHandleForReading.availableData
            if !chunk.isEmpty {
                buffer.append(chunk)
                if let line = findRateLimitsLine(in: buffer) {
                    matched = line
                    break
                }
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if !process.isRunning { break }
        }
        process.terminate()
        try? stdin.fileHandleForWriting.close()
        guard let matched else {
            throw NSError(
                domain: "Conduit.AccountUsage",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Codex app-server did not return rate limits (sign in with codex login?).",
                ]
            )
        }
        return matched
    }

    private static func findRateLimitsLine(in buffer: Data) -> Data? {
        guard let text = String(data: buffer, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            if line.contains("\"rateLimits\"") || line.contains("usedPercent") {
                return Data(line.utf8)
            }
        }
        return nil
    }

    // MARK: - OpenCode (local DB)

    private static func fetchOpenCode() async -> AccountUsageSnapshot {
        await BlockingWork.run(qos: .userInitiated) {
            let db = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/opencode/opencode.db")
            guard FileManager.default.fileExists(atPath: db.path) else {
                return AccountUsageSnapshot(
                    agentName: "OpenCode",
                    sourceLabel: "OpenCode local database",
                    error: "No OpenCode database at ~/.local/share/opencode/opencode.db."
                )
            }
            // Use sqlite3 CLI for a dependency-free query.
            let weekAgoMs = Int((Date().timeIntervalSince1970 - 7 * 86400) * 1000)
            let allSQL =
                "SELECT count(*), coalesce(sum(tokens_input),0), coalesce(sum(tokens_output),0), coalesce(sum(cost),0) FROM session;"
            let weekSQL =
                "SELECT count(*), coalesce(sum(tokens_input),0), coalesce(sum(tokens_output),0), coalesce(sum(cost),0) FROM session WHERE time_created >= \(weekAgoMs);"
            guard
                let all = sqliteQuery(db: db.path, sql: allSQL),
                let week = sqliteQuery(db: db.path, sql: weekSQL)
            else {
                return AccountUsageSnapshot(
                    agentName: "OpenCode",
                    sourceLabel: "OpenCode local database",
                    error: "Could not query OpenCode session table."
                )
            }
            return AccountUsageParsing.openCodeSnapshot(
                weekTokensIn: week.inTok,
                weekTokensOut: week.outTok,
                weekCost: week.cost,
                weekSessions: week.count,
                allTokensIn: all.inTok,
                allTokensOut: all.outTok,
                allCost: all.cost,
                allSessions: all.count
            )
        }
    }

    private struct SQLiteAgg {
        let count: Int
        let inTok: Int
        let outTok: Int
        let cost: Double
    }

    private static func sqliteQuery(db: String, sql: String) -> SQLiteAgg? {
        let result = SubprocessRunner.run(
            "/usr/bin/sqlite3",
            [db, "-separator", "|", sql],
            timeout: 5
        )
        guard result.status == 0 else { return nil }
        let line = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .last
            .map(String.init) ?? ""
        let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 4,
              let count = Int(parts[0]),
              let inTokD = Double(parts[1]),
              let outTokD = Double(parts[2]),
              let cost = Double(parts[3])
        else { return nil }
        return SQLiteAgg(
            count: count,
            inTok: Int(inTokD),
            outTok: Int(outTokD),
            cost: cost
        )
    }
}
#endif
