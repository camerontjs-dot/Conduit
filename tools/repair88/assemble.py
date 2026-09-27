"""Materialize the reviewed repair-88 integration edits on exact input blobs.

One-time developer assembly, not qualification. All edits and preconditions are
computed before writes. No commit/push, source substitution, or test-pin refresh
occurs during tests. Freeze the resulting committed pair before qualification.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

EXPANSION_DISPATCH = r'''
        case .expandMindGraphNomination(let expansionHandle, let scope):
            let requested = expansionHandle.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                _ = try MindGraphExpansionBinding.validateRequest(requested, scope: scope)
            } catch {
                return ["error": "MindGraph expansion origin is invalid or does not match the selected scope"]
            }
            guard let binary = MindGraphQuerySupport.resolveBinary(mainframeRoot: settings.mainframeRoot) else {
                return ["error": "mindgraph binary not found"]
            }
            guard let parsedScope = MindGraphScope(rawValue: scope) else {
                return ["error": "scope must be knowledge or projects"]
            }
            let db = MindGraphQuerySupport.databaseURL(for: parsedScope)
            let result = SubprocessRunner.run(
                binary.path,
                ["expand-nomination", requested, "--db", db.path, "--json", "--scope", scope],
                timeout: 45
            )
            guard !result.timedOut, result.status == 0 else {
                return ["scope": scope, "exit_code": result.status, "error": "MindGraph expansion failed closed"]
            }
            do {
                guard let bytes = MindGraphQuerySupport.extractJSONValue(from: Data(result.output.utf8)) else {
                    return ["error": "MindGraph expansion response was invalid"]
                }
                var payload = try MindGraphExpansionBinding.agentResponse(
                    bytes, expansionHandle: requested, scope: scope
                )
                payload["exit_code"] = result.status
                return payload
            } catch {
                return ["scope": scope, "exit_code": result.status, "error": "MindGraph expansion response failed identity validation"]
            }
'''

APP_TEST_SEAM = r'''
#if os(macOS) && DEBUG
// Opt-in test seam, not an MCP tool or an installed-app mutation surface.
extension AppModel {
    static func repair88RequireIsolatedHome() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard env["CONDUIT_REPAIR88_APP_TESTS"] == "1",
              let configured = env["CONDUIT_QUALIFICATION_HOME"] else {
            throw MindGraphExpansionBinding.BindingError("Explicit isolated qualification home required.")
        }
        let expected = URL(fileURLWithPath: configured).resolvingSymlinksInPath()
        let actual = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        guard expected == actual,
              FileManager.default.fileExists(atPath: expected.appendingPathComponent(".repair88-isolated-fixture").path) else {
            throw MindGraphExpansionBinding.BindingError("Refusing qualification in a non-isolated home.")
        }
        return expected
    }

    func repair88SeedRecordedTask(root: URL) throws {
        _ = try Self.repair88RequireIsolatedHome()
        guard sessions.isEmpty, taskSessions.isEmpty else {
            throw MindGraphExpansionBinding.BindingError("Qualification requires a fresh isolated app model.")
        }
        let id = TaskSessionID()
        let event = TaskSessionEvent(
            taskSessionID: id, authority: .conduitRecorded,
            kind: .created(TaskSessionMetadata(
                workspace: .root(RootWorkspaceScopeSnapshot(rootURL: root)),
                agentName: "Qualification recorded worker", defaultTitle: "Populated context isolation"
            ))
        )
        guard let snapshot = TaskSessionProjection.project(taskSessionID: id, events: [event]) else {
            throw MindGraphExpansionBinding.BindingError("Could not seed recorded task fixture.")
        }
        taskSessions = [snapshot]
        selectedTaskSessionID = id
    }

    /// Capture actual model inputs and the production Context IDE/handoff
    /// projections, not a parallel fake list. No timestamps are normalized.
    func repair88ContextState() throws -> Data {
        _ = try Self.repair88RequireIsolatedHome()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bundle = ContextIDEBridge.buildBundle(
            title: "Populated context isolation", mainframeRoot: settings.mainframeRoot,
            scopePath: selectedProject?.path, candidates: contextCandidates,
            selectedIDs: selectedContextIDs
        )
        let assembled = ContextBundleBuilder().assemble(
            documents: contextCandidates.filter { selectedContextIDs.contains($0.id) }
        )
        let handoff = AgentContextHandoffRenderer.render(
            AgentContextHandoff(objective: "Populated context isolation", bundle: bundle)
        )
        let payload: [String: Any] = [
            "selected_context": selectedContextIDs.sorted(),
            "context_preview": contextPreview,
            "context_bundle": try JSONSerialization.jsonObject(with: encoder.encode(bundle)),
            "assembled": assembled.markdown,
            "handoff": handoff,
            "composer": composerText,
            "attachment_paths": attachments.map { $0.url.path },
            "tasks": try JSONSerialization.jsonObject(with: encoder.encode(taskSessions)),
            "selected_task": selectedTaskSessionID?.rawValue.uuidString as Any? ?? NSNull(),
            "runtime_ids": sessions.map { $0.id.uuidString }.sorted(),
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}
#endif
'''

CATALOG_ENTRY = r'''
        tool(
            "conduit_expand_mindgraph_nomination",
            "Expand an exp2 handle from conduit_query_mindgraph using the same scope. The original scope and stored index identity are checked independently before source text is returned. Legacy exp1, malformed, stale, missing or cross-index handles fail closed. Expansion adds context, not verification. This read does not attach material to another worker.",
            annotations: localReadOnlyAnnotations,
            properties: [
                "expansion_handle": property("string", "Exact exp2 expansion_handle from the compact nomination."),
                "scope": ["type": "string", "enum": ["knowledge", "projects"], "description": "The original query scope."],
            ],
            required: ["expansion_handle", "scope"]
        ),
'''

BLOBS = {
    "Sources/Conduit/AppModel.swift": "bef0d61266591b96678c4d81b7f71e5c82cb30c0",
    "Sources/ConduitCore/ConduitSessionToolCatalog.swift": "d21b716a6ab8fbe5f3a48e366646adaeb28d063f",
    "Sources/ConduitSelfTest/main.swift": "6dc9c86e0988499d851e7ecf24c41f4b3841e0cc",
    "docs/qualification/provider-conformance-v1.json": "4e4077c49c97d702b98f8e4c9abb2c757a9b60fc",
    "Package.swift": "ba955621c169a19c341cccf3069f2d25b3f60475",
    "CHANGELOG.md": "60a0bc6a22f4c8aed312388ba0b80a401a78d65e",
    "DECISIONS.md": "f548ed60286ca3ccb1e0483396eff85a3eb99f02",
}


def once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f"expected one assembly anchor: {old[:90]!r}")
    return text.replace(old, new, 1)


def region(text: str, start: str, end: str, change) -> str:
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError("ambiguous method boundary")
    a, b = text.index(start), text.index(end)
    if a >= b:
        raise ValueError("inverted method boundary")
    return text[:a] + change(text[a:b]) + text[b:]


def function(text: str, name: str) -> str:
    match = re.search(r"^    private func " + re.escape(name) + r"\(", text, re.M)
    if not match:
        raise ValueError(f"missing provider evidence function: {name}")
    following = re.search(r"^    (?:private )?func ", text[match.end():], re.M)
    end = len(text) if following is None else match.end() + following.start()
    return text[match.start():end]


def transform_app(text: str, assets: Path) -> str:
    original = text
    def query(s):
        return once(s, '"--nominations",', '"--nominations", "--nomination-scope", scope.rawValue,')
    text = region(text, "    func queryMindGraphNominations(", "    func expandMindGraphNomination(", query)
    def expand(s):
        s = once(s, "        guard let binary = MindGraphQuerySupport.resolveBinary(", '''        do {
            _ = try MindGraphExpansionBinding.validateRequest(nomination.expansionHandle, scope: nomination.scope.rawValue)
        } catch {
            return .failure(.invalidJSON("Expansion origin does not match the selected scope."))
        }
        guard let binary = MindGraphQuerySupport.resolveBinary(''')
        s = once(s, '                    "--json",', '                    "--json", "--scope", nomination.scope.rawValue,')
        s = once(s, '            let expansion = try MindGraphQuerySupport.decodeExpansion(', '''            guard let payload = MindGraphQuerySupport.extractJSONValue(from: Data(result.output.utf8)) else {
                return .failure(.invalidJSON("Expansion response was invalid."))
            }
            try MindGraphExpansionBinding.validateResponse(payload, upstreamHandle: nomination.expansionHandle)
            let expansion = try MindGraphQuerySupport.decodeExpansion(''')
        return s
    text = region(text, "    func expandMindGraphNomination(", "    func inspectMindGraph(", expand)
    def query_api(s):
        return once(s, '"--nominations", "--no-intent",', '"--nominations", "--nomination-scope", scope, "--no-intent",')
    text = region(text, "        case .queryMindGraph(let question, let scope):", "        case .expandMindGraphNomination(let expansionHandle, let scope):", query_api)
    text = region(text, "        case .expandMindGraphNomination(let expansionHandle, let scope):",
                  "        case .createTask(let agentName, let projectSlug, let objective, let idempotencyKey):",
                  lambda _s: EXPANSION_DISPATCH)
    # Reaffirm the exact source claim before changing its evidence digest.
    for name in ("sessionAPIListProviderSessions", "sessionAPIAdoptProviderSession"):
        before, after = function(original, name), function(text, name)
        if before != after or 'guard sessionAPINormalizedProvider(provider) == "opencode" else' not in after:
            raise ValueError("provider scope evidence changed; do not refresh its pin")
    return text.rstrip() + "\n\n" + APP_TEST_SEAM


def transform_catalog(text: str, assets: Path) -> str:
    old = "Semantic search over the operator's local MindGraph index. scope selects knowledge or projects. Results are ranked nominations, not evidence; not_citable documents remain separate from results."
    new = "Search one local MindGraph scope and return compact nominations with exact previews and exp2 expansion handles. Full chunks are withheld. Use conduit_expand_mindgraph_nomination with the same scope for selected sources. Retrieval and expansion do not verify claims or attach source to another worker."
    text = once(text, old, new)
    marker = "    ]\n\n    private static let writeTools"
    return once(text, marker, CATALOG_ENTRY + marker)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    git = lambda *a: subprocess.check_output(["git", *a], text=True).strip()
    root = Path(git("rev-parse", "--show-toplevel"))
    if Path.cwd().resolve() != root.resolve():
        raise SystemExit("REFUSED: run at the isolated repository root")
    if git("rev-parse", "HEAD") != args.expected_head or git("status", "--porcelain"):
        raise SystemExit("REFUSED: exact clean assembly checkout required")
    inputs = {}
    for rel, expected in BLOBS.items():
        path = root / rel
        if path.is_symlink():
            raise SystemExit("REFUSED: symlink input")
        raw = path.read_bytes()
        actual = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
        if actual != expected:
            raise SystemExit(f"REFUSED: source blob changed: {rel}")
        inputs[rel] = raw.decode("utf-8")
    assets = root / "tools/repair88"
    outputs = dict(inputs)
    app = "Sources/Conduit/AppModel.swift"
    outputs[app] = transform_app(inputs[app], assets)
    catalog = "Sources/ConduitCore/ConduitSessionToolCatalog.swift"
    outputs[catalog] = transform_catalog(inputs[catalog], assets)
    selftest = "Sources/ConduitSelfTest/main.swift"
    outputs[selftest] = once(inputs[selftest], "// MARK: - FrontmatterParser", '''for (name, result) in mindGraphBindingSelfTests() { check(name, result) }

// MARK: - FrontmatterParser''')
    outputs["Package.swift"] = once(inputs["Package.swift"], '''        .testTarget(
            name: "ConduitCoreTests",''', '''        .testTarget(name: "ConduitAppTests", dependencies: ["Conduit", "ConduitCore"]),
        .testTarget(
            name: "ConduitCoreTests",''')
    pin = "docs/qualification/provider-conformance-v1.json"
    manifest = json.loads(inputs[pin])
    # Preserve all unrelated JSON formatting and evidence pins.
    old = "461014a17d5cd519cea1b211728cb0bae8fd930d10138a83bae0dd7218cc5a9c"
    new = hashlib.sha256(outputs[app].encode()).hexdigest()
    outputs[pin] = once(inputs[pin], old, new)
    updated = json.loads(outputs[pin])
    def entry(obj):
        if isinstance(obj, dict):
            if "CONDUIT-API-SCOPE" in obj:
                return obj["CONDUIT-API-SCOPE"]
            for value in obj.values():
                found = entry(value)
                if found is not None: return found
        return None
    if entry(manifest)["artifact"]["path"] != app or entry(updated)["artifact"]["sha256"] != new:
        raise ValueError("unexpected conformance evidence schema")
    outputs["CHANGELOG.md"] = once(inputs["CHANGELOG.md"], "### Fixed\n", '''### Fixed

- Progressive MindGraph expansion now checks the original scope and independent
  stored index identity. The published Core tool catalog exposes expansion.
  Legacy exp1 handles must be requeried; unknown index binding fails closed.
  The provider-scope evidence pin is refreshed only after confirming its guarded
  provider code is unchanged. Populated-model isolation has an opt-in app test.
''')
    outputs["DECISIONS.md"] = inputs["DECISIONS.md"].rstrip() + '''

## D-058 repair addendum: explicit exp2 index binding

Status: proposed successor to the blocked #86 / MindGraph #23 pair.

The collision receipt showed that trust labels and echoed scope were insufficient.
The consumer now binds the original request alias, independently named producer
index, document/chunk/path/namespace and known hash before returning text. exp1
must be requeried. Handles remain unauthenticated locators, not storage custody
or authorization. Only the Core catalog is authoritative for tools/list.

The provider inventory/adoption functions are byte-preserved against the failed
predecessor before the final AppModel digest is repinned. No conformance gate is
removed and no evidence pins refresh automatically during tests.

The opt-in populated-model test exercises real AppModel context, bundle/handoff
rendering and recorded task state. It does not prove non-admission for a live
provider queue; that remains an installed qualification acceptance case.
'''
    receipt = {"operation": "assembly_not_qualification", "input_head": args.expected_head,
               "written": args.write, "provider_scope_functions_unchanged": True,
               "files": {p: hashlib.sha256(s.encode()).hexdigest() for p,s in outputs.items()}}
    if args.write:
        for rel, text in outputs.items():
            (root / rel).write_bytes(text.encode("utf-8"))
    print(json.dumps(receipt, sort_keys=True, indent=2))

if __name__ == "__main__": main()
