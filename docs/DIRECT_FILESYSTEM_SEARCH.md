# Direct project file search

The authenticated MCP tool `conduit_search_files` searches ordinary UTF-8 files in one registered project. It runs directly in Conduit, without an agent task or a shell. The project comes from the exact `project_slug`; the human's current project, task and pane do not affect it.

```json
{
  "project_slug": "example-project",
  "path": "workbench/Sources",
  "query": "loadConfiguration",
  "max_results": 50
}
```

Matching is case-sensitive and literal. A period means a period, and there is no regular expression, glob expansion or shell syntax. Queries contain at most 256 UTF-8 bytes and cannot contain a newline. Each matching LF-delimited line produces one result, even when the query appears more than once on that line. CRLF input is supported.

Each result gives a project-relative path, a one-based line number and UTF-8 byte column, a zero-based file byte offset, a SHA-256 of the exact observed file bytes, and a snippet of at most 512 UTF-8 bytes around the first match. A truncated snippet is explicitly marked. Read the exact file through `conduit_read_filesystem` before relying on omitted surrounding text; that read also returns the exact observed file hash for a later write precondition.

## Scope and omissions

The caller supplies an existing project slug, not a filesystem root. Conduit requires the configured MainFrame root to be ready and authorized, resolves exactly one non-root project, and checks that project's directory through Explorer's contained, no-follow path handling. Ambiguous slugs, root-project requests, missing authorization and unavailable projects refuse.

Paths are literal and relative to that project. Absolute paths, parent components and ambiguous separators refuse. Links are never followed, including links that point back inside the project. Explorer's exclusions, including `.git`, remain in effect. Directories may change while traversal proceeds; the results are observations of individual files rather than a filesystem snapshot.

| Parameter | Default | Maximum |
| --- | ---: | ---: |
| `max_results` | 50 | 200 matching lines |
| `max_entries` | 1,000 | 5,000 visible entries |
| `max_files` | 200 | 1,000 ordinary file candidates |
| `max_file_bytes` | 128,000 | 512,000 bytes |
| `max_total_bytes` | 1,048,576 | 8,388,608 bytes |
| `max_depth` | 8 | 32 levels below the starting directory |

A depth of zero searches only the starting directory. The total read budget includes bounded lookahead. Failed reads retain their reserved budget because the exact number of bytes consumed is unknown; this can make a search stop conservatively.

The response reports `partial_reasons`, per-reason `skipped` counts, entries and files considered, files successfully read, source bytes read and charged read budget. Oversized files, depth or byte limits, read failures and changed-during-read observations prevent a complete traversal claim. Unsupported binary files and links remain outside the ordinary-text search policy.

`status: partial` is a usable bounded observation, with `truncated: true`; it is not a failed task and must not be interpreted as proof that no other matches exist. Narrow the starting directory or adjust the relevant bound for a further observation. Unavailable roots and invalid requests return a typed error instead.

## Authority and verification

The read uses the existing listener bearer and is available while Session API writes are disabled. Returned text remains untrusted source data and carries `verification: unverified_contents`. It does not become an instruction, accepted evidence or a context attachment merely by appearing in a result.

Disposable native tests exercise real files, source changes, UTF-8 byte positions, literal matching, links, excluded metadata, binary files, every traversal budget and bounded snippets. Transport tests exercise the actual authenticated response/dispatch path without taking the operator's listener. Installed app, tunnel and ChatGPT catalog acceptance remain separate from these source checks.

Owners: [local operations #51](https://github.com/camerontjs-dot/Conduit/issues/51), [Explorer #54](https://github.com/camerontjs-dot/Conduit/issues/54), and [implementation plan #60](https://github.com/camerontjs-dot/Conduit/issues/60).
