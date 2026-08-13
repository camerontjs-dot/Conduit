#if os(macOS)
import ConduitCore
import Foundation

/// File loaders for the Attention / Focus Board. Projection only — never
/// writes focus authority, STATE.md, eval registries, or session-close apply.
enum FocusBoardService {
    static func load(
        mainframeRoot: URL,
        now: Date = Date(),
        includeIngest: Bool = true
    ) async -> Result<FocusBoardSnapshot, FocusBoardLoadError> {
        await BlockingWork.run(qos: .userInitiated) {
            loadSync(
                mainframeRoot: mainframeRoot,
                now: now,
                includeIngest: includeIngest
            )
        }
    }

    static func loadSync(
        mainframeRoot: URL,
        now: Date = Date(),
        includeIngest: Bool = true
    ) -> Result<FocusBoardSnapshot, FocusBoardLoadError> {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: mainframeRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return .failure(.rootMissing)
        }

        let nowMs = now.timeIntervalSince1970 * 1000
        var parseErrors: [String] = []
        var feeds: [FocusBoardFeedMeta] = []

        let sessionRead = readText(root: mainframeRoot, relative: FocusBoardPaths.sessionClose)
        var sessionRecords: [FocusBoardJSON]?
        switch sessionRead {
        case .missing(let error):
            feeds.append(
                FocusBoardFeedMeta(
                    id: "session-close",
                    path: FocusBoardPaths.sessionClose,
                    present: false,
                    error: error
                )
            )
        case .failed(let error):
            parseErrors.append("session-close: \(error)")
            feeds.append(
                FocusBoardFeedMeta(
                    id: "session-close",
                    path: FocusBoardPaths.sessionClose,
                    present: true,
                    error: error
                )
            )
        case .ok(let text):
            sessionRecords = FocusBoard.parseJsonl(text)
            feeds.append(
                FocusBoardFeedMeta(
                    id: "session-close",
                    path: FocusBoardPaths.sessionClose,
                    present: true,
                    recordCount: sessionRecords?.count
                )
            )
        }

        let scheduleRead = readText(root: mainframeRoot, relative: FocusBoardPaths.scheduleRuns)
        var scheduleRuns: [FocusBoardJSON]?
        switch scheduleRead {
        case .missing(let error):
            feeds.append(
                FocusBoardFeedMeta(
                    id: "eval-schedule",
                    path: FocusBoardPaths.scheduleRuns,
                    present: false,
                    error: error
                )
            )
        case .failed(let error):
            parseErrors.append("eval-schedule: \(error)")
            feeds.append(
                FocusBoardFeedMeta(
                    id: "eval-schedule",
                    path: FocusBoardPaths.scheduleRuns,
                    present: true,
                    error: error
                )
            )
        case .ok(let text):
            scheduleRuns = FocusBoard.parseJsonl(text)
            feeds.append(
                FocusBoardFeedMeta(
                    id: "eval-schedule",
                    path: FocusBoardPaths.scheduleRuns,
                    present: true,
                    recordCount: scheduleRuns?.count
                )
            )
        }

        let indexRead = readText(root: mainframeRoot, relative: FocusBoardPaths.projectIndex)
        var projectIndex: FocusBoardProjectIndexSummary?
        switch indexRead {
        case .missing(let error):
            feeds.append(
                FocusBoardFeedMeta(
                    id: "project-index",
                    path: FocusBoardPaths.projectIndex,
                    present: false,
                    error: error
                )
            )
        case .failed(let error):
            parseErrors.append("project-index: \(error)")
            feeds.append(
                FocusBoardFeedMeta(
                    id: "project-index",
                    path: FocusBoardPaths.projectIndex,
                    present: true,
                    error: error
                )
            )
        case .ok(let text):
            let asOf = isoDateOnly(now)
            projectIndex = FocusBoard.parseProjectIndexMarkdown(
                text,
                activeCap: FocusBoardConstants.activeCap,
                asOf: asOf
            )
            feeds.append(
                FocusBoardFeedMeta(
                    id: "project-index",
                    path: FocusBoardPaths.projectIndex,
                    present: true,
                    recordCount: projectIndex?.projects.count
                )
            )
        }

        var ingestStatus: FocusBoardJSON?
        if includeIngest {
            let ingest = runIngestStatus(mainframeRoot: mainframeRoot)
            if let error = ingest.error {
                parseErrors.append("ingest: \(error)")
                feeds.append(
                    FocusBoardFeedMeta(
                        id: "ingest",
                        path: FocusBoardPaths.ingestStatus,
                        present: !error.contains("not found"),
                        error: error
                    )
                )
            } else {
                ingestStatus = ingest.status
                let lanes = ingestStatus?["lanes"]?.arrayValue?.count ?? 0
                feeds.append(
                    FocusBoardFeedMeta(
                        id: "ingest",
                        path: FocusBoardPaths.ingestStatus,
                        present: true,
                        recordCount: lanes
                    )
                )
            }
        } else {
            feeds.append(
                FocusBoardFeedMeta(
                    id: "ingest",
                    path: FocusBoardPaths.ingestStatus,
                    present: false,
                    error: "skipped"
                )
            )
        }

        let proposal = loadProposal(mainframeRoot: mainframeRoot)
        feeds.append(
            FocusBoardFeedMeta(
                id: "weekly-focus-proposal",
                path: FocusBoardPaths.proposalDirectory,
                present: proposal.status == "available",
                recordCount: proposal.status == "available" ? 1 : 0,
                error: proposal.status == "available"
                    ? nil
                    : (proposal.error ?? proposal.detail ?? "proposal unavailable")
            )
        )

        let approved = loadApprovedFocus(mainframeRoot: mainframeRoot, nowMs: nowMs)
        feeds.append(
            FocusBoardFeedMeta(
                id: "approved-focus",
                path: FocusBoardPaths.approvedFocus,
                present: approved.status != "unavailable",
                recordCount: approved.status == "available" ? 1 : 0,
                error: approved.status == "available"
                    ? nil
                    : (approved.errors.joined(separator: "; ").nilIfEmpty
                        ?? "approved focus unavailable")
            )
        )

        let board = FocusBoard.buildFocusBoard(
            FocusBoardInputs(
                sessionCloseRecords: sessionRecords,
                scheduleRuns: scheduleRuns,
                projectIndex: projectIndex,
                ingestStatus: ingestStatus,
                nowMs: nowMs
            )
        )
        let asOf = board.items.first(where: { $0.asOf != nil })?.asOf
            ?? isoTimestamp(now)

        return .success(
            FocusBoardSnapshot(
                items: board.items,
                insufficient: board.insufficient,
                feedNotes: board.feedNotes,
                asOf: asOf,
                feeds: feeds,
                parseErrors: parseErrors,
                weeklyFocusProposal: proposal,
                approvedFocus: approved,
                fixture: board.fixture
            )
        )
    }

    // MARK: - Reads

    private enum FileRead {
        case missing(String)
        case failed(String)
        case ok(String)
    }

    private static func readText(root: URL, relative: String) -> FileRead {
        let url = root.appendingPathComponent(relative)
        if !FileManager.default.fileExists(atPath: url.path) {
            return .missing("file not found")
        }
        do {
            return .ok(try String(contentsOf: url, encoding: .utf8))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func runIngestStatus(
        mainframeRoot: URL
    ) -> (status: FocusBoardJSON?, error: String?) {
        let script = mainframeRoot.appendingPathComponent(FocusBoardPaths.ingestStatus)
        guard FileManager.default.isExecutableFile(atPath: script.path)
            || FileManager.default.fileExists(atPath: script.path)
        else {
            return (nil, "bin/ingest-status not found")
        }
        let result = SubprocessRunner.run(
            script.path,
            ["--json"],
            currentDirectory: mainframeRoot.path,
            timeout: FocusBoardConstants.ingestTimeoutSeconds
        )
        if result.timedOut {
            return (nil, "ingest-status timed out after \(Int(FocusBoardConstants.ingestTimeoutSeconds * 1000))ms")
        }
        if result.status != 0 {
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, trimmed.isEmpty ? "ingest-status exit \(result.status)" : trimmed)
        }
        guard let data = result.output.data(using: .utf8),
              let rec = FocusBoard.decodeJSONObject(data)
        else {
            return (nil, "ingest-status JSON parse failed")
        }
        return (rec, nil)
    }

    private static func loadProposal(mainframeRoot: URL) -> FocusBoardProposal {
        let directory = mainframeRoot.appendingPathComponent(FocusBoardPaths.proposalDirectory)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            return .unavailable(
                error: "no weekly focus proposal artifact found",
                detail: error.localizedDescription
            )
        }
        let candidates = names.filter { FocusBoard.isProposalFileName($0) }.sorted()
        guard let name = candidates.last else {
            return .unavailable(
                error: "no weekly focus proposal artifact found",
                detail: "run bin/propose-weekly-focus --write to create one under \(FocusBoardPaths.proposalDirectory)/"
            )
        }
        let artifactPath = "\(FocusBoardPaths.proposalDirectory)/\(name)"
        let url = directory.appendingPathComponent(name)
        do {
            let data = try Data(contentsOf: url)
            return FocusBoard.parseFocusProposal(data: data, artifactPath: artifactPath)
        } catch {
            return .unavailable(
                error: "weekly focus proposal artifact could not be parsed",
                detail: error.localizedDescription,
                artifactPath: artifactPath
            )
        }
    }

    private static func loadApprovedFocus(mainframeRoot: URL, nowMs: Double) -> FocusBoardApprovedFocus {
        let url = mainframeRoot.appendingPathComponent(FocusBoardPaths.approvedFocus)
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return FocusBoard.parseApprovedFocus(text, nowMs: nowMs)
        } catch {
            return .unavailable(error: error.localizedDescription)
        }
    }

    private static func isoDateOnly(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
#endif
