// Deterministic local verification for ConduitCore without XCTest, so the
// core can be checked on machines with Command Line Tools only:
//   swift run conduit-selftest
// CI still runs the full XCTest suite with Xcode.

import ConduitCore
import Foundation

var passed = 0
var failures: [String] = []

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        passed += 1
        print("ok   \(name)")
    } else {
        failures.append(name)
        print("FAIL \(name)")
    }
}

func withTempDir(_ body: (URL) throws -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("conduit-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        try body(dir)
    } catch {
        failures.append("uncaught error: \(error)")
        print("FAIL uncaught error: \(error)")
    }
}

// MARK: - FrontmatterParser

let frontmatter = FrontmatterParser.parse("""
---
title: "Image Lab"
project_state: "active"
goal: "Build"
next_action: "Test"
tags: ["images", "agents"]
---
# Image Lab
""", fallbackTitle: "Fallback")
check("frontmatter parses title", frontmatter.title == "Image Lab")
check("frontmatter parses state", frontmatter.projectState == "active")
check("frontmatter parses tags", frontmatter.tags == ["images", "agents"])
check("frontmatter falls back to heading",
      FrontmatterParser.parse("# Plain\n", fallbackTitle: "F").title == "Plain")

let navigationProject = MainframeProject(
    slug: "conduit",
    path: URL(fileURLWithPath: "/tmp/MainFrame/30_projects/conduit"),
    readmePath: nil,
    metadata: ProjectMetadata(
        title: "Conduit",
        projectState: "active",
        nextAction: "Finish native smoke",
        tags: ["macOS", "agents"]
    )
)
check("project search uses authority metadata",
      ProjectNavigation.matches(navigationProject, query: "native smoke"))
check("project search is case insensitive",
      ProjectNavigation.matches(navigationProject, query: "MACOS"))
check("project active grouping uses explicit state",
      ProjectNavigation.isActive(navigationProject))
check("project search keyboard selection preserves scanner order",
      ProjectNavigation.firstMatch(
        in: [
            MainframeProject(
                slug: "other",
                path: URL(fileURLWithPath: "/tmp/MainFrame/30_projects/other"),
                readmePath: nil,
                metadata: ProjectMetadata(title: "Other")
            ),
            navigationProject
        ],
        query: "conduit"
      )?.id == navigationProject.id)
check("sprite mapping resolves Codex exactly",
      AgentSpriteResolver.resolve(AgentProfile(name: "Codex", command: "codex"))
        == AgentSpriteResolution(skin: .codex, isExactMatch: true))
check("sprite mapping resolves Claude executable exactly",
      AgentSpriteResolver.resolve(AgentProfile(name: "Claude Code", command: "/opt/bin/claude"))
        == AgentSpriteResolution(skin: .claude, isExactMatch: true))
check("sprite mapping keeps custom profiles generic",
      AgentSpriteResolver.resolve(AgentProfile(name: "Codexish", command: "custom-agent"))
        == AgentSpriteResolution(skin: nil, isExactMatch: false))

// MARK: - PromptEncoder

let multiline = "line one\nline two"
let bracketed = PromptEncoder.encode(text: multiline, bracketedPaste: true, submit: true)
check("bracketed paste starts with ESC[200~",
      Array(bracketed.prefix(6)) == PromptEncoder.bracketedPasteStart)
check("bracketed paste ends with ESC[201~ + CR",
      Array(bracketed.suffix(7)) == PromptEncoder.bracketedPasteEnd + Array("\r".utf8))
check("bracketed payload preserves newline",
      bracketed.contains(UInt8(ascii: "\n")))
let plain = PromptEncoder.encode(text: multiline, bracketedPaste: false, submit: true)
check("plain typing converts newline to CR",
      !plain.contains(UInt8(ascii: "\n")) && plain.filter { $0 == UInt8(ascii: "\r") }.count == 2)
check("no submit means no trailing CR",
      PromptEncoder.encode(text: "hi", bracketedPaste: false, submit: false) == Array("hi".utf8))
check("trailing newlines are normalized away",
      PromptEncoder.normalized("cmd\n\n") == "cmd")
check("empty prompt encodes to nothing",
      PromptEncoder.encode(text: "\n\n", bracketedPaste: true, submit: true).isEmpty)

// MARK: - ArgumentTokenizer

check("tokenizer splits plain args",
      ArgumentTokenizer.tokenize("-l --color auto") == ["-l", "--color", "auto"])
check("tokenizer respects double quotes",
      ArgumentTokenizer.tokenize("--msg \"hello world\" -x") == ["--msg", "hello world", "-x"])
check("tokenizer respects single quotes",
      ArgumentTokenizer.tokenize("-c 'a b'") == ["-c", "a b"])
check("tokenizer keeps empty quoted token",
      ArgumentTokenizer.tokenize("a \"\" b") == ["a", "", "b"])
let roundtrip = ["--message", "hello world", "plain", "it's"]
check("tokenizer joins and reparses",
      ArgumentTokenizer.tokenize(ArgumentTokenizer.join(roundtrip)) == roundtrip)

// MARK: - ShellQuoting

check("shell quote escapes single quotes",
      ShellQuoting.quote("it's") == "'it'\\''s'")
check("command line quotes each part",
      ShellQuoting.commandLine("claude", ["--continue"]) == "'claude' '--continue'")

// MARK: - TmuxSessionNaming

let projectURL = URL(fileURLWithPath: "/tmp/MainFrame/30_projects/conduit")
let nameA = TmuxSessionNaming.sessionName(projectPath: projectURL, agentName: "Claude")
let nameB = TmuxSessionNaming.sessionName(projectPath: projectURL, agentName: "Claude")
let nameC = TmuxSessionNaming.sessionName(projectPath: projectURL, agentName: "Codex")
check("tmux name is deterministic", nameA == nameB)
check("tmux name distinguishes agents", nameA != nameC)
check("tmux name is bounded", nameA.count <= 70)
check("tmux name uses safe characters",
      nameA.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })

// MARK: - SessionLifecycle

var lifecycle = SessionLifecycle.idle
check("idle cannot jump to running", !lifecycle.transition(to: .running))
check("idle can launch", lifecycle.transition(to: .launching))
check("launching can run", lifecycle.transition(to: .running))
check("running can detach", lifecycle.transition(to: .detached))
check("detached refuses exit-code overwrite",
      !lifecycle.transition(to: .exited(code: 0)) && lifecycle == .detached)
var exiting = SessionLifecycle.running
check("running can exit with code", exiting.transition(to: .exited(code: 3)))
check("exited is terminal", exiting.isTerminal)
check("launching is not terminal", !SessionLifecycle.launching.isTerminal)
check("detached is terminal", SessionLifecycle.detached.isTerminal)

// MARK: - POSIXExitStatus (raw waitpid status decoding)

check("exit 0 decodes to 0", POSIXExitStatus.decode(0) == 0)
check("exit 1 (raw 256) decodes to 1", POSIXExitStatus.decode(256) == 1)
check("exit 3 (raw 768) decodes to 3", POSIXExitStatus.decode(768) == 3)
check("exit 255 (raw 65280) decodes to 255", POSIXExitStatus.decode(65280) == 255)
check("SIGTERM (raw 15) decodes to 143", POSIXExitStatus.decode(15) == 143)
check("SIGKILL (raw 9) decodes to 137", POSIXExitStatus.decode(9) == 137)

// MARK: - Event log + renderer + receipt writer

withTempDir { dir in
    let logDir = dir.appendingPathComponent("worklog")
    let log = WorkSessionEventLog(directory: logDir, sessionID: "s1")
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    try log.append(.started(sessionID: "s1", projectSlug: "conduit", projectTitle: "Conduit",
                            projectPath: "/tmp/p", objective: "Initial objective", at: t0))
    try log.append(.agentLaunched(agent: "Claude", backend: "durable-requested", at: t0.addingTimeInterval(1)))
    try log.append(.objectiveChanged(text: "Refined objective", at: t0.addingTimeInterval(2)))
    try log.append(.terminalOutcome(agent: "Claude", title: "build", exitCode: 0,
                                    detached: false, live: false, at: t0.addingTimeInterval(3)))
    try log.append(.terminalOutcome(agent: "Codex", title: "review", exitCode: nil,
                                    detached: true, live: false, at: t0.addingTimeInterval(4)))

    let beforeClose = log.readEvents()
    check("event log roundtrips events", beforeClose.count == 5)
    // Compare standardized paths: /var vs /private/var on macOS.
    let interrupted = WorkSessionEventLog.interruptedLogs(in: logDir)
    check("interrupted log is detected",
          interrupted.map(\.url.lastPathComponent) == [log.url.lastPathComponent])

    // A torn final line (crash mid-write) must not poison the log.
    let handle = try FileHandle(forWritingTo: log.url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"broken".utf8))
    try handle.close()
    check("torn trailing line is skipped", log.readEvents().count == 5)

    let recovered = WorkSessionReceiptRenderer.render(events: log.readEvents(), recovered: true)
    check("recovered receipt renders", recovered != nil)
    check("recovered receipt is marked",
          recovered?.markdown.contains("## Recovery note") == true)

    try log.append(.gitSnapshot(summary: "branch: main", at: t0.addingTimeInterval(5)))
    try log.append(.closed(at: t0.addingTimeInterval(6)))
    check("closed log is no longer interrupted",
          WorkSessionEventLog.interruptedLogs(in: logDir).isEmpty)

    guard let rendered = WorkSessionReceiptRenderer.render(events: log.readEvents()) else {
        check("closed receipt renders", false)
        return
    }
    check("closed receipt renders", true)
    check("receipt keeps latest objective",
          rendered.markdown.contains("Refined objective") && !rendered.markdown.contains("Initial objective"))
    check("receipt records exit code", rendered.markdown.contains("observed exit code 0"))
    check("receipt records detach",
          rendered.markdown.contains("detached; process continuity delegated to tmux"))
    check("receipt records git snapshot", rendered.markdown.contains("branch: main"))
    check("receipt keeps evidence boundary",
          rendered.markdown.contains("Terminal prose is not treated as proof"))
    check("clean receipt has no recovery note",
          !rendered.markdown.contains("## Recovery note"))
    check("receipt ended-at comes from closed event",
          rendered.endedAt == t0.addingTimeInterval(6))

    // Writer: append-only, collision-safe, requires 20_live.
    let root = dir.appendingPathComponent("root")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("20_live"), withIntermediateDirectories: true)
    let writer = WorkSessionReceiptWriter()
    let first = try writer.write(root: root, receipt: rendered)
    let second = try writer.write(root: root, receipt: rendered)
    check("receipt files never collide", first != second)
    check("receipt lands under 20_live/conduit/sessions",
          first.path.contains("20_live/conduit/sessions"))
    let missingLive = dir.appendingPathComponent("no-live-root")
    try FileManager.default.createDirectory(at: missingLive, withIntermediateDirectories: true)
    check("writer refuses roots without 20_live",
          (try? writer.write(root: missingLive, receipt: rendered)) == nil)
}

// MARK: - Scanner + inbox + prompt assembly

withTempDir { root in
    try FileManager.default.createDirectory(at: root.appendingPathComponent("00_inbox"), withIntermediateDirectories: true)
    let project = root.appendingPathComponent("30_projects/demo")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try "# MainFrame".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try "---\ntitle: \"Demo\"\nproject_state: \"active\"\n---\n".write(
        to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

    let projects = try MainframeScanner().scan(root: root)
    check("scanner finds root plus project", projects.count == 2 && projects[0].isMainframeRoot)
    check("scanner reads project metadata", projects[1].metadata.title == "Demo")

    let writer = InboxWriter(now: { Date(timeIntervalSince1970: 1_700_000_000) })
    let capture1 = try writer.capture(root: root, project: projects[1], text: "Remember this", attachments: [])
    let capture2 = try writer.capture(root: root, project: projects[1], text: "Remember this", attachments: [])
    check("inbox capture never overwrites", capture1 != capture2)
    let captureContent = try String(contentsOf: capture1, encoding: .utf8)
    check("inbox capture records provenance",
          captureContent.contains("conduit://project/demo"))

    let assembled = PromptAssembler.assemble(
        text: "Review these",
        attachments: [Attachment(url: URL(fileURLWithPath: "/tmp/a.png"))]
    )
    check("prompt assembler lists attachment paths",
          assembled.contains("Review these") && assembled.contains("/tmp/a.png"))
}

// MARK: - Context bundle + forwarder

withTempDir { dir in
    try "# P\nImportant context".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try "# D\nUse evidence.".write(to: dir.appendingPathComponent("decisions.md"), atomically: true, encoding: .utf8)
    let project = MainframeProject(
        slug: "p", path: dir,
        readmePath: dir.appendingPathComponent("README.md"),
        metadata: ProjectMetadata(title: "P")
    )
    let builder = ContextBundleBuilder()
    let candidates = builder.candidates(for: project)
    check("bundle nominates coordination files", candidates.count == 2)
    let bundle = builder.assemble(documents: candidates)
    check("bundle carries trust labels", bundle.markdown.contains("Trust label"))
    check("bundle is inspection not verification",
          bundle.markdown.contains("not verification"))
    let tiny = builder.assemble(documents: candidates, maximumBytes: 120)
    check("bundle marks truncation", tiny.truncated)
}

let forwarded = TerminalForwarder.prompt(selection: "Done!", sourceAgent: "Claude", destinationAgent: "Codex")
check("forwarder wraps with evidence boundary",
      forwarded.contains("unverified terminal output") && forwarded.contains("Re-run deterministic checks"))
check("forwarder keeps the selection", forwarded.contains("Done!"))

// MARK: - Optional real-tree smoke (set CONDUIT_SMOKE_ROOT=/path/to/MainFrame)

if let smokeRoot = ProcessInfo.processInfo.environment["CONDUIT_SMOKE_ROOT"] {
    let root = URL(fileURLWithPath: smokeRoot)
    do {
        let projects = try MainframeScanner().scan(root: root)
        check("real-tree scan finds the root workspace", projects.first?.isMainframeRoot == true)
        check("real-tree scan discovers projects", projects.count > 1)
        let bundleBuilder = ContextBundleBuilder()
        // Exercise the exact candidate/assemble path the UI's bundle uses.
        var bundleOK = true
        for project in projects.prefix(6) {
            let candidates = bundleBuilder.candidates(for: project)
            let bundle = bundleBuilder.assemble(documents: candidates)
            if !candidates.isEmpty && !bundle.markdown.contains("Trust label") { bundleOK = false }
        }
        check("real-tree context bundles assemble", bundleOK)
        print("   ↳ scanned \(projects.count - 1) projects under \(root.lastPathComponent):")
        for project in projects.dropFirst().prefix(8) {
            let state = project.metadata.projectState ?? project.metadata.status ?? "—"
            print("     • \(project.slug)  [\(state)]  \(project.metadata.title)")
        }
    } catch {
        check("real-tree scan (\(error.localizedDescription))", false)
    }
}

// Optional installed-config smoke. This detects schema drift without baking a
// user-specific path into the republishable product.
if let configPath = ProcessInfo.processInfo.environment["CONDUIT_CONFIG_PATH"] {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let config = try JSONDecoder().decode(ConduitSettings.self, from: data)
        check("saved config decodes", true)
        check("saved config retains MainFrame root", config.mainframeRoot != nil)
    } catch {
        check("saved config decodes (\(error.localizedDescription))", false)
    }
}

// MARK: - Summary

print("\n\(passed) passed, \(failures.count) failed")
if !failures.isEmpty {
    print("failures:")
    for failure in failures {
        print("  - \(failure)")
    }
    exit(1)
}
