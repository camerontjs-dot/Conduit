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

// MARK: - Density (Focused Flow R2)

check("density case order is focused balanced operator",
      Density.allCases.map(\.rawValue) == ["focused", "balanced", "operator"])
check("density exposes exactly three modes", Density.allCases.count == 3)
check("density product default is Focused",
      Density.productDefault == .focused && Density.allCases.first == .focused)
check("density display labels are Focused Balanced Operator",
      Density.allCases.map(\.displayName) == ["Focused", "Balanced", "Operator"])
check("density recovers valid raw values",
      Density.resolved(fromStored: "focused") == .focused
        && Density.resolved(fromStored: "balanced") == .balanced
        && Density.resolved(fromStored: "operator") == .operator)
check("density invalid and missing fall back to Focused",
      Density.resolved(fromStored: nil) == .focused
        && Density.resolved(fromStored: "") == .focused
        && Density.resolved(fromStored: "compact") == .focused
        && Density.resolved(fromStored: "FOCUSED") == .focused
        && Density.resolved(fromStored: "Operator") == .focused)

// MARK: - PaletteSpec (Focused Flow R2 base lock)

check("palette case order is Harbor Sage Clay Heather Phosphor",
      PaletteID.allCases.map(\.rawValue) == ["harbor", "sage", "clay", "heather", "phosphor"])
check("palette product default is Harbor",
      PaletteID.productDefault == .harbor && PaletteID.allCases.first == .harbor)
check("palette exposes exactly five identifiers", PaletteID.allCases.count == 5)
check("palette exposes exactly ten base variants", PaletteID.allBaseVariants.count == 10)

let harborLight = PaletteID.harbor.baseTokens(variant: .light)
check("Harbor light accent", harborLight.accent == "#456881")
check("Harbor light on-accent", harborLight.onAccent == "#FFFFFF")
check("Harbor light ink", harborLight.ink == "#35566D")
check("Harbor light canvas", harborLight.canvas == "#F2F5F7")
check("Harbor light app", harborLight.app == "#E4E9ED")
check("Harbor light rail", harborLight.rail == "#EBEFF2")
check("Harbor light surface", harborLight.surface == "#FCFDFE")
check("Harbor light sink", harborLight.sink == "#DFE5EA")
check("Harbor light text", harborLight.text == "#232A31")
check("Harbor light dim", harborLight.dim == "#5C6772")
check("Harbor light faint", harborLight.faint == "#93A0AB")
check("Harbor light shade",
      harborLight.shade == PaletteShade(red: 30, green: 48, blue: 62))
check("Harbor light is soft", harborLight.soft)

let harborDark = PaletteID.harbor.baseTokens(variant: .dark)
check("Harbor dark accent", harborDark.accent == "#7FA8C8")
check("Harbor dark on-accent", harborDark.onAccent == "#0D1417")
check("Harbor dark ink", harborDark.ink == "#A3C4DD")
check("Harbor dark canvas", harborDark.canvas == "#0F1417")
check("Harbor dark app", harborDark.app == "#141A1E")
check("Harbor dark rail", harborDark.rail == "#192025")
check("Harbor dark surface", harborDark.surface == "#1E262B")
check("Harbor dark sink", harborDark.sink == "#131A1E")
check("Harbor dark text", harborDark.text == "#E1E6EA")
check("Harbor dark dim", harborDark.dim == "#93A0AA")
check("Harbor dark faint", harborDark.faint == "#64707A")
check("Harbor dark has no shade", harborDark.shade == nil)
check("Harbor dark is soft", harborDark.soft)

let sageLight = PaletteID.sage.baseTokens(variant: .light)
check("Sage light base tokens",
      sageLight.accent == "#4F6B49"
        && sageLight.onAccent == "#FFFFFF"
        && sageLight.ink == "#3F5740"
        && sageLight.canvas == "#F5F3EC"
        && sageLight.app == "#E9EBE2"
        && sageLight.rail == "#EEF0E7"
        && sageLight.surface == "#FCFCF8"
        && sageLight.sink == "#E4E7DC"
        && sageLight.text == "#2A2E27"
        && sageLight.dim == "#626B5D"
        && sageLight.faint == "#98A08D"
        && sageLight.shade == PaletteShade(red: 40, green: 50, blue: 32)
        && sageLight.soft)
let sageDark = PaletteID.sage.baseTokens(variant: .dark)
check("Sage dark base tokens",
      sageDark.accent == "#8FB183"
        && sageDark.onAccent == "#14180F"
        && sageDark.ink == "#A9C99E"
        && sageDark.canvas == "#141A15"
        && sageDark.app == "#191E1A"
        && sageDark.rail == "#1E241F"
        && sageDark.surface == "#232924"
        && sageDark.sink == "#171C18"
        && sageDark.text == "#E4E7DD"
        && sageDark.dim == "#9AA393"
        && sageDark.faint == "#6B7365"
        && sageDark.shade == nil
        && sageDark.soft)

let clayLight = PaletteID.clay.baseTokens(variant: .light)
check("Clay light base tokens",
      clayLight.accent == "#97583E"
        && clayLight.onAccent == "#FFFFFF"
        && clayLight.ink == "#7C4530"
        && clayLight.canvas == "#F5F0E9"
        && clayLight.app == "#EAE1D6"
        && clayLight.rail == "#F0E8DD"
        && clayLight.surface == "#FDFBF7"
        && clayLight.sink == "#E5DBCD"
        && clayLight.text == "#2E2620"
        && clayLight.dim == "#6D6055"
        && clayLight.faint == "#A0917F"
        && clayLight.shade == PaletteShade(red: 60, green: 42, blue: 28)
        && clayLight.soft)
let clayDark = PaletteID.clay.baseTokens(variant: .dark)
check("Clay dark base tokens",
      clayDark.accent == "#CB8A6E"
        && clayDark.onAccent == "#17120E"
        && clayDark.ink == "#E0A888"
        && clayDark.canvas == "#17120E"
        && clayDark.app == "#1D1712"
        && clayDark.rail == "#221B15"
        && clayDark.surface == "#271F18"
        && clayDark.sink == "#1A140F"
        && clayDark.text == "#EAE2D8"
        && clayDark.dim == "#A3958A"
        && clayDark.faint == "#736659"
        && clayDark.shade == nil
        && clayDark.soft)

let heatherLight = PaletteID.heather.baseTokens(variant: .light)
check("Heather light base tokens",
      heatherLight.accent == "#635B8C"
        && heatherLight.onAccent == "#FFFFFF"
        && heatherLight.ink == "#4F4874"
        && heatherLight.canvas == "#F4F3F7"
        && heatherLight.app == "#E7E5EE"
        && heatherLight.rail == "#EDEBF3"
        && heatherLight.surface == "#FCFCFE"
        && heatherLight.sink == "#E2E0EB"
        && heatherLight.text == "#2A2833"
        && heatherLight.dim == "#625D70"
        && heatherLight.faint == "#9A94A8"
        && heatherLight.shade == PaletteShade(red: 40, green: 36, blue: 58)
        && heatherLight.soft)
let heatherDark = PaletteID.heather.baseTokens(variant: .dark)
check("Heather dark base tokens",
      heatherDark.accent == "#A79FCE"
        && heatherDark.onAccent == "#141318"
        && heatherDark.ink == "#C3BCE0"
        && heatherDark.canvas == "#141318"
        && heatherDark.app == "#1A181F"
        && heatherDark.rail == "#201E27"
        && heatherDark.surface == "#26232E"
        && heatherDark.sink == "#18161D"
        && heatherDark.text == "#E5E2EC"
        && heatherDark.dim == "#9D97AC"
        && heatherDark.faint == "#6D6879"
        && heatherDark.shade == nil
        && heatherDark.soft)

let phosphorLight = PaletteID.phosphor.baseTokens(variant: .light)
check("Phosphor light base tokens",
      phosphorLight.accent == "#C97A16"
        && phosphorLight.onAccent == "#241A08"
        && phosphorLight.ink == "#8A5410"
        && phosphorLight.canvas == "#FAF8F4"
        && phosphorLight.app == "#ECE7DE"
        && phosphorLight.rail == "#F4F0E8"
        && phosphorLight.surface == "#FFFFFF"
        && phosphorLight.sink == "#E7E1D6"
        && phosphorLight.text == "#221E18"
        && phosphorLight.dim == "#6C665B"
        && phosphorLight.faint == "#9C9488"
        && phosphorLight.shade == PaletteShade(red: 40, green: 32, blue: 20)
        && phosphorLight.soft == false)
let phosphorDark = PaletteID.phosphor.baseTokens(variant: .dark)
check("Phosphor dark base tokens",
      phosphorDark.accent == "#E8A13B"
        && phosphorDark.onAccent == "#201603"
        && phosphorDark.ink == "#F2BE6E"
        && phosphorDark.canvas == "#0B0E0C"
        && phosphorDark.app == "#101311"
        && phosphorDark.rail == "#181B18"
        && phosphorDark.surface == "#1E221F"
        && phosphorDark.sink == "#121614"
        && phosphorDark.text == "#E7E3DA"
        && phosphorDark.dim == "#9B978C"
        && phosphorDark.faint == "#6B675E"
        && phosphorDark.shade == nil
        && phosphorDark.soft == false)

let softFlags = PaletteID.allBaseVariants.map { ($0.id, $0.tokens.soft) }
check("Phosphor alone is non-soft",
      softFlags.filter { !$0.1 }.map(\.0) == [.phosphor, .phosphor]
        && softFlags.filter { $0.1 }.count == 8)

let lightShades = PaletteID.allCases.compactMap { id -> (PaletteID, PaletteShade?) in
    (id, id.baseTokens(variant: .light).shade)
}
check("every light variant has a shade triple",
      lightShades.allSatisfy { $0.1 != nil })
check("every dark variant has no shade",
      PaletteID.allCases.allSatisfy { $0.baseTokens(variant: .dark).shade == nil })

let hexPattern = #"^#[0-9A-F]{6}$"#
let hexRegex = try! NSRegularExpression(pattern: hexPattern)
func isNormalizedHex(_ value: String) -> Bool {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return hexRegex.firstMatch(in: value, range: range) != nil
}
var allHexOK = true
for entry in PaletteID.allBaseVariants {
    let t = entry.tokens
    for color in [t.accent, t.onAccent, t.ink, t.canvas, t.app, t.rail, t.surface, t.sink, t.text, t.dim, t.faint] {
        if !isNormalizedHex(color) { allHexOK = false }
    }
}
check("all base color literals are six-digit uppercase hex", allHexOK)

check("mk accent-soft alpha",
      PaletteMkConstants.accentSoftAlphaDark == 0.17
        && PaletteMkConstants.accentSoftAlphaLight == 0.13)
check("mk soft accent-glow",
      PaletteMkConstants.softAccentGlowDark == 0.20
        && PaletteMkConstants.softAccentGlowLight == 0.13)
check("mk non-soft accent-glow",
      PaletteMkConstants.nonSoftAccentGlowDark == 0.42
        && PaletteMkConstants.nonSoftAccentGlowLight == 0.30)
check("mk line",
      PaletteMkConstants.lineDarkWhite == 0.10
        && PaletteMkConstants.lineLightShade == 0.13)
check("mk line-soft",
      PaletteMkConstants.lineSoftDarkWhite == 0.05
        && PaletteMkConstants.lineSoftLightShade == 0.06)
check("mk soft scan",
      PaletteMkConstants.softScanDarkWhite == 0.008
        && PaletteMkConstants.softScanLightShade == 0.006)
check("mk non-soft scan",
      PaletteMkConstants.nonSoftScanDarkWhite == 0.022
        && PaletteMkConstants.nonSoftScanLightShade == 0.015)
check("mk desk darkening",
      PaletteMkConstants.desk1DarkeningDark == 0.35
        && PaletteMkConstants.desk1DarkeningLight == 0.05
        && PaletteMkConstants.desk2DarkeningDark == 0.15
        && PaletteMkConstants.desk2DarkeningLight == 0.13)
check("mk shadow dark string",
      PaletteMkConstants.shadowDark
        == "0 26px 70px -18px rgba(0,0,0,.7),0 2px 10px rgba(0,0,0,.5)")
check("mk shadow light string",
      PaletteMkConstants.shadowLight
        == "0 22px 60px -18px rgba(30,22,10,.3),0 2px 8px rgba(30,22,10,.1)")
check("mk pop-shadow dark string",
      PaletteMkConstants.popShadowDark == "0 18px 46px -8px rgba(0,0,0,.66)")
check("mk pop-shadow light string",
      PaletteMkConstants.popShadowLight == "0 14px 40px -10px rgba(20,15,5,.3)")

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
