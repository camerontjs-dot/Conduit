# Conduit quick start

Conduit is a native agent workspace around the CLI tools already installed on
your Mac. MainFrame files remain project authority, and each agent still runs
through a real PTY. Conversation is the normal work surface; Raw keeps the
terminal one action away.

## First launch

1. Open Conduit and choose your MainFrame folder: the folder containing
   `00_inbox`, `20_live`, and `30_projects`.
2. Open Settings and choose a palette and workspace density. Harbor is the
   default.
3. Leave the task scope at **All MainFrame** unless you want to narrow history
   to the MainFrame root or one scanned project.
4. Press `⌘N` or use **New Task**. Review both fields: the enabled local CLI
   agent and the MainFrame scope where it will run.
5. Choose **Create Task**. Conduit starts the PTY independently and opens the
   task in Conversation.

The three density modes change layout, not behavior:

- **Focused** gives the central task surface the most room. Press `⌘\` when you
  need the temporary project inspector.
- **Balanced** keeps project context visible in a third column.
- **Operator** adds the observed-state resource and Doctor controls for a more
  operational view.

## A normal task

1. Select a task from Pinned, Active, or Recent, or create a new one. Selecting
   history does not reconnect a process.
2. For a new task, add an objective or operator note to the project-scoped
   work-session card if you want it represented in the eventual receipt.
3. Write a prompt in the Conversation composer and press `⌘↩` to send it. You
   can also add files, folders, pasted images, or a captured screen region.
4. Read the delivery label literally: **Queued**, **Sent to terminal**, or
   **Delivery failed** describes the terminal handoff, not whether the agent
   understood or completed the request.
5. Read **Rendered Raw output** in Conversation as a convenience projection.
   **Derived from Raw** means Conduit compared rendered terminal snapshots; the
   block may contain prompt echo, tool logs, or terminal chrome. **Agent
   activity** reports observable runtime activity, not private
   chain-of-thought.
6. Open **Raw** or press `⌘2` for the authoritative live PTY/TUI, CLI
   approvals, direct terminal input, and output that Conversation cannot
   structure safely. Press `⌘1` to return.
7. Build a context bundle when the agent needs project coordination files.
   Preview it before attaching it; the bundle is context, not proof.
8. To hand output to another agent, copy the Raw terminal selection and use the
   session forwarding action. Review the staged text, then confirm or cancel.
9. Leave or end a runtime with its explicit control. Leaving a tmux runtime
   detaches it; leaving a direct PTY closes it. Once the runtime is detached or
   ended, Conversation removes the active composer, keeps Raw available for
   inspection, and shows the applicable reconnect, restart, or New Task action.
10. When the project work session is over, press `⇧⌘W` to close it and write a
   receipt.

`RECORDED` means Conduit successfully wrote the receipt file. It does not mean
the task itself was verified or completed. The receipt is a separate
project-scoped evidence record, not a task transcript.

## Task history and recovery

- **Pinned**, **Active**, and **Recent** are metadata views over append-only task
  events. **Archived** appears only after you enable it from the sidebar's
  More menu.
- Selecting a historical row is safe to browse. Use **Reconnect** explicitly
  when Conduit has observed a matching tmux runtime.
- **Discovered** is a secondary recovery list for tmux sessions not represented
  by loaded task history. A legacy session with no project record requires an
  explicit scope before adoption. A malformed task binding is labelled
  **Needs attention** and is not resumed.
- After relaunch, task history restores identity, scope, agent, title, pin,
  archive, operational state, exact native prompts, local attachment path
  references, and source-labelled rendered-output blocks. Attaching a path
  does not copy that file, but text the CLI renders—including file contents or
  secrets—may be retained. Each rendered revision is capped at 16,000
  characters; append-only earlier revisions remain in the local source.
  Unprocessed Raw terminal bytes are not stored in conversation history.
- After the first successful conversation append, a content-free task marker
  records that local history is expected. If that history is later absent,
  Conduit calls it unavailable. An unmarked task remains a possible
  pre-retention or never-recorded gap. Neither is presented as a complete empty
  thread.

## Useful shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘N` | New Task |
| `⌘F` | Find Tasks |
| `⇧⌘P` | Browse Projects |
| `⌘1` | Show Conversation for the selected live task |
| `⌘2` | Show Raw for the selected live task |
| `⌘T` | Open a Shell session |
| `⌥⌘R` | Open Resume Session |
| `⌘↩` | Send the composer text |
| `⌘\` | Show or hide context in Focused mode |
| `⇧⌘W` | Close the work session and write its receipt |
| `⇧⌘D` | Open Conduit Doctor |
| `⇧⌘M` | Open the Resource Deck |
| `⇧⌘B` | Build a context bundle |
| `⇧⌘I` | Capture a note into `00_inbox` |
| `⇧⌘E` | Leave the active runtime: detach tmux or close a direct PTY |

## Session and evidence signals

- **Running**, **Reconnect available**, **Closed**, **Interrupted**, **Not
  reconnectable**, and **Status unknown** describe operational availability
  only.
- A tmux-backed runtime can remain available after app exit or detach. A direct
  `PTY` runtime cannot reconnect after it closes.
- **output active**, **running**, **detached**, **exited**, and **failed** describe
  observed terminal or process state. They are not task-completion judgments.
- Conversation retains source-labelled local events under
  `~/.conduit/conversations/`. Raw remains the authority for the exact live
  terminal UI and is not retained as an unprocessed byte transcript.
- An available agent seat means no matching runtime is open in the selected
  project. It does not prove the configured command resolves, the CLI is
  authenticated, or a provider is available.
- Receipts are append-only Markdown files under
  `20_live/conduit/sessions/`.

## If something is wrong

- If project discovery loses access, choose **Renew MainFrame Access** and
  select the same MainFrame folder.
- Open Conduit Doctor (`⇧⌘D`) to inspect CLI paths, tmux, folder structure, and
  permissions.
- If the sidebar footer changes from **More** to **Issues**, open **Task History
  Issues** to inspect preserved malformed or unsupported task-log records.
- If a task says **Unknown**, refresh runtime status. Failed discovery is not
  treated as proof that a tmux runtime disappeared.
- If a task is **Reconnectable**, select **Reconnect**. Merely selecting its
  row will not attach.
- If a CLI opens but cannot work, check that CLI's own authentication outside
  Conduit.
- If a direct PTY was closed, start a new session. Only tmux-backed sessions
  are designed to reconnect.

## What to notice during the first week

Keep a short list of anything that slows you down: finding the right task,
choosing a scope, returning from Raw, understanding a runtime label, inspecting
context, and separating task continuity from receipt evidence. Those
observations are the best input for the next polish pass.
