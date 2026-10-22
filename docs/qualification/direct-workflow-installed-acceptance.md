# Installed-client acceptance packet · direct workflow

**Prepared, NOT_RUN. No installation or production execution is authorized by
this packet.** Source identity and the locally built bundle hash belong in
`CANDIDATE.json`; observed installed identity belongs in a new run receipt.
Use `direct-workflow-installed-acceptance.json` as a blank account, copying it
to a new private run directory rather than overwriting the template or history.

## Two separate tracks and prerequisites

**A · guarded candidate:** after separately authorized installation of this
exact source, verify read/search/scoped edit, durable file replay, UI isolation
and command refusal. This candidate cannot pass a production command-execution
loop. `execution_authority_unavailable` is its required result.

**B · enabled execution successor:** BLOCKED until an operator-selected profile
is implemented, independently reviewed, OS-tested with the actual toolchain,
and separately authorized for a specific installation/test. That will be a new
source/build identity. It must not expose the internal fixture initializer,
remove the guard without equivalent authority, or add a caller approval flag.

Before either installed track, record the authorized source/tree and local
bundle hash, actual installed binary/bundle signature, PID/listener ownership,
existing tunnel/connector registration identity, exact write-gate authority and
test-only project slug/root identities. Never publish tokens or secrets. A
source build is not an installed identity, and an installed identity is not a
fresh client's discovery or behavior. Refresh/reconnect the existing connector
only within the authorized experiment; no new registration is implied.

The human leaves project A/task X selected, records Raw/Thread surface, cursor
and scroll state, and enters a unique unsent draft plus an attachment. Capture
the exact expected state using a separately qualified state-observation method
and human observation; do not use the known-failing broad state comparator as
an oracle. If no such method is available, UI preservation remains BLOCKED.
Remote calls address only disposable project B. No create/send/reconcile task,
provider adoption, model launch, focus/selection action, clipboard automation or
UI-driving script is part of this packet.

Use an operator-prepared standalone project B with ordinary `value.txt`
containing `before\n`, and `human-dirty.txt` containing a private sentinel.
Parents already exist. Choose unique operation IDs once and freeze complete
request JSON before dispatch. Record `${slug}` and `${read_path}` separately:
the former is B's registered slug; the latter is B's `value.txt` path relative
to the configured MainFrame root. Do not use a root override or a guessed slug.
Keep fixture scripts pre-reviewed and hashed in B; shell examples below are
eligible only if the future execution profile explicitly permits that shell.

## Exact direct loop

1. On a **fresh authenticated client**, capture `initialize` and `tools/list`.
   Compare full tool names, descriptions, annotations and schemas against the
   exact candidate catalog. Capture `initialize.result.instructions` and compare
   it with `ConduitSessionToolCatalog.clientInstructions`. Confirm paging, tail
   and budget fields. Record the
   raw request/response and client identity, not only a displayed tool count.
2. Read `conduit_read_filesystem` with
   `{"operation":"read","path":"${read_path}"}` and preserve raw bytes/hash.
   Search with `conduit_search_files` using
   `{"project_slug":"${slug}","query":"before"}`. Inspect partial/skipped
   coverage, not just hits.
3. First submit a stale-hash replacement with its own unique operation ID.
   Require refusal with no changed file or accepted mutation receipt. Then call
   `conduit_write_file` using the actual read hash:

   ```json
   {"operation_id":"RUN-edit","project_slug":"${slug}","path":"value.txt","expected_sha256":"${read_sha256}","text":"after\n"}
   ```

   Inspect the resulting file through direct read; compare `human-dirty.txt`
   before/after. Discard the first response in the test record to represent a
   lost client response, reconnect the client without restarting Conduit, and
   retry the identical JSON. Require `replayed: true`, one file effect and the
   original receipt. A changed request under the same ID must conflict.
4. Track A calls `conduit_run_command` with a new operation ID and literal
   `argv: ["/bin/echo","guard-probe"]`. Require
   `execution_authority_unavailable` before command receipt/admission/spawn.
   Verify no command marker, new provider, task, or runtime. Stop Track A's
   command sequence here. This expected refusal is not end-to-end completion.
5. Track B, only on the separately qualified successor, sends:

   ```json
   {"operation_id":"RUN-check","project_slug":"${slug}","argv":["/bin/sh","-c","printf x >> check-count; test \"$(cat value.txt)\" = after || exit 23; printf checked; printf diagnostic >&2"],"timeout_ms":180000,"max_output_bytes":16,"max_tail_bytes":16}
   ```

   Do not equate accepted/queued/running with success. Poll:

   ```json
   {"operation_id":"RUN-check","project_slug":"${slug}","stdout_offset":0,"stderr_offset":0,"output_page_bytes":4}
   ```

   Consume each stream independently and follow `next_byte_offset`. Require
   exact `checked`/`diagnostic` bytes, exit 0, EOF and the stated process facts.
   Retry the identical execute request after a simulated lost response/client
   reconnect; require `idempotent_replay: true` and exactly one `x` in the marker.
   Inspect the final source/hash and marker with direct file tools.
6. At each step, the human verifies project A/task X/surface/draft/attachment,
   insertion point and scroll anchor against the predeclared observation
   method. Any change stops UI acceptance; retain evidence, do not repair state
   and silently restart the experiment.

## Required cases and observations

All are NOT_RUN in this packet; each gets raw requests/responses, timestamps,
artifact hashes, exact expected versus observed result, and its own verdict.

| ID / track | Stimulus | Required observation |
| --- | --- | --- |
| A01 | Candidate identity + fresh client discovery | Exact source/build/install/client link; no stale schema |
| A02 | Read/search; stale then correct hash edit | Explicit coverage; stale refusal; correct changed bytes only |
| A03 | Lost file response, reconnect, duplicate/changed retry | Same-ID original receipt; one mutation; changed request conflicts |
| A04 | Candidate command attempt | Guard refusal, no admission/receipt/process effect |
| A05 | Every remote operation while human works in A/X | Selection, surface, drafts, attachments and cursor/scroll preserved |
| A06 | Routine project request in three fresh ChatGPT sessions | Direct file tools first; exact host/project; guarded command refusal reported; no new model, Shell task, privilege or selected-state fallback. Record actual calls; instruction presence alone is not routing evidence |
| B01 | File→command→inspect loop above | Exit 0 with exact bytes and one check marker |
| B02 | `printf '0123456789abcdefghijklmnopqrstuv'; printf 'FAIL-last' >&2; exit 23`, prefix 4/tail 8 | `nonzero`, exit 23; stdout gap [4,24), suffix `opqrstuv`; stderr bytes recoverable; no MCP error masquerading as retry permission |
| B03 | `printf before; /bin/sleep 121; printf after`, budget 180000 | Immediate acknowledgement; same operation still running past 120 s; eventual exact output/exit; no task/model launched |
| B04 | Continuous output fixture; cancel exact owned ID twice; repeat with a TERM-ignoring descendant whose leader exits on TERM | Cancellation request then observed outcome; grace-period escalation while child identity remains pinned; group absence before capacity release; bounded pages; no unrelated PID signalled |
| B05 | Sleep beyond a deliberately short budget; repeat with B04's descendant fixture | `timed_out` only with observed exit/group facts; descendant absent before capacity release; otherwise UNKNOWN |
| B06 | Client transport reconnect and identical command retry | No new command/provider; exact original ID and single side effect |
| B07 | Controlled app ownership loss/restart | Separate disposable installation/process required; live human app restart prohibited. Unowned nonterminal derives UNKNOWN, no PID adoption/signalling/respawn, unresolved capacity blocks new work |
| B08 | Invalid offsets, future offsets, stale root remap, invalid profile/environment fields | Explicit refusal; receipt bytes unchanged; no effect/admission |
| B09 | Outside-file, traversal, symlink, network and unapproved-executable attempts under actual profile | OS denials plus passing permitted controls; same restrictions after child setsid; logging alone fails acceptance |
| B10 | Human state throughout B and final direct inspection | Same exact human-state contract as A05; final dirty sentinel/source/receipts intact |

Network controls use only an owned disposable listener, never the user's
service. Cancellation uses only operations owned by this run. B07 is not a
reason to terminate the active human app. If a separate authorized instance
cannot isolate settings, listener, receipts and task state, retain B07 BLOCKED.

For A06, use: “In disposable project B, inspect value.txt, make the requested
scoped change, run its known check and inspect the result. Keep reasoning here.”
The expected guarded result stops at the execution refusal after eligible file
work. Also present an unknown project and require discovery/clarification rather
than a selected-project guess. Record a routing-only response to an interactive
TUI request and an independent-review request: the client should identify the
separate interactive or review need. Do not actually launch a task/model under
this packet. [Client guidance](../DIRECT_WORKFLOW_CLIENT.md) explains the route.

## Verdict and stop rules

Run the eligible cases in two fresh client sessions with new run IDs. Within
each run use the original IDs for retries. Append observations; preserve the
first failure, refusal, contamination or incomplete evidence. Never replace a
failed run's JSON with a repaired result. Stop dependent cases on source/build
mismatch, unexpected authority, duplicate effect, UI mutation, uncertain
ownership or missing outcome. Independent source work may continue.

Installed acceptance requires all eligible installed cases and exact evidence,
not source test counts or a prepared packet. Track A's expected guard refusal
leaves #170 execution acceptance BLOCKED. Track B cannot start on this candidate.
Record cleanup of owned fixtures/processes separately; no automatic restore,
reset, installation, privilege expansion, production enablement or merge.

> **Binds:** a future explicitly authorized installed-client experiment.
> **Tier:** T0 operator procedure; the current API guard is an independent enforced refusal.
> **Check:** exact run receipt and independently reviewable raw observations for each case.
> **Escape:** leave an unavailable prerequisite BLOCKED and its cases NOT_RUN; never use source fixture authority in the installed product.
