# Conduit quick start

Conduit is a focused desktop workspace for running your existing CLI agents
against MainFrame. It does not replace the files, agents, or evidence rules
underneath them.

## First launch

1. Open Conduit and choose your MainFrame folder: the folder containing
   `00_inbox`, `20_live`, and `30_projects`.
2. Open Settings and choose a palette and workspace density. Harbor is the
   default.
3. Use `⌘F` to find and select a project.
4. Launch an agent or Shell from the toolbar.

The three density modes change layout, not behavior:

- **Focused** gives the terminal the most room. Press `⌘\` when you need the
  project inspector.
- **Balanced** keeps project context visible in a third column.
- **Operator** adds the observed-state resource and Doctor controls for a more
  operational view.

## A normal work session

1. Select the project and launch the agent you want.
2. Add a short objective or operator note to the work-session card.
3. Write a prompt in the composer and press `⌘↩` to send it. You can also add
   files, folders, pasted images, or a captured screen region.
4. Build a context bundle when the agent needs project coordination files.
   Preview it before attaching it; the bundle is context, not proof.
5. To hand output to another agent, copy the terminal selection and use the
   session forwarding action. Review the staged text, then confirm or cancel.
6. When the work session is over, press `⇧⌘W` to close it and write a receipt.

`RECORDED` means Conduit successfully wrote the receipt file. It does not mean
the task itself was verified or completed.

## Useful shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘F` | Find a project |
| `⌘T` | Open a Shell session |
| `⌘↩` | Send the composer text |
| `⌘\` | Show or hide context in Focused mode |
| `⇧⌘W` | Close the work session and write its receipt |
| `⇧⌘D` | Open Conduit Doctor |
| `⇧⌘M` | Open the Resource Deck |
| `⇧⌘B` | Build a context bundle |
| `⇧⌘I` | Capture a note into `00_inbox` |
| `⇧⌘E` | Detach the active durable session |

## Session and evidence signals

- A tmux-backed session can survive an app restart after it is detached. A
  direct `PTY` session ends when it is closed.
- **Working**, **ready**, **detached**, **exited**, and **failed** describe
  observed terminal or process state. They are not task-completion judgments.
- An available agent seat means the configured command can be launched. It
  does not prove authentication or provider availability.
- Receipts are append-only Markdown files under
  `20_live/conduit/sessions/`.

## If something is wrong

- If project discovery loses access, choose **Renew MainFrame Access** and
  select the same MainFrame folder.
- Open Conduit Doctor (`⇧⌘D`) to inspect CLI paths, tmux, folder structure, and
  permissions.
- If a CLI opens but cannot work, check that CLI's own authentication outside
  Conduit.
- If a direct PTY was closed, start a new session. Only tmux-backed sessions
  are designed to reconnect.

## What to notice during the first week

Keep a short list of anything that slows you down: the palette and density in
use, cramped areas, unclear labels, missing actions, surprising terminal
behavior, and whether the receipts contain the facts you actually need. Those
observations are the best input for the next polish pass.
