# Pixel ambient visual system

Status: design proposal

Date: 2026-09-18

Related work: PR #43 introduces semantic pixel glyphs for Explorer. This proposal deliberately stays separate from that qualified candidate and describes a broader optional animation/state vocabulary for later experimentation.

## Objective

Make Conduit feel more alive without weakening its conversation-first interface or turning decoration into fake system state.

Pixel art should function as ambient feedback, navigation support, and personality around the edges of the app. Conversation remains the primary surface. The visual system must be small, low-frame-rate, performant, accessible, and hideable.

## Design principle

Use pixel art when it helps answer one of these questions:

- what is active?
- what changed?
- where did work happen?
- which workspace/worktree am I looking at?
- is this state idle, blocked, stale, or complete?
- where did an artifact come from or go?

Do not use animation merely because a surface is empty.

The semantic pixel glyphs in PR #43 remain presentation categories only. Runtime/agent animations are a separate vocabulary and must be tied to observed state rather than inferred health, success, or authority.

## Candidate concepts

### File Explorer workers and critters

Use tiny optional sprites beside directories or scoped areas when real activity is occurring there.

Examples:

- a worker entering a folder while an agent is actively reading or editing within it;
- carrying a page/file when a new artifact is written;
- sleeping or sitting when the associated runtime is idle;
- disappearing entirely when ambient animation is disabled.

The sprite should supplement normal labels and status text, never replace them.

### Worktree identity scenes

Give worktrees a small visual identity that helps distinguish current, active, historical, and stale checkouts.

Candidate scenes:

- active worktree: tiny lit workstation/camp;
- currently selected worktree: subtle focus animation;
- historical/stale worktree: dormant or dusty scene;
- disposable task worktree: temporary tent/crate/scaffold motif.

This is especially useful if Conduit later exposes first-class task-to-worktree associations. Visual state must come from Git/worktree/task facts, not from guessing whether a branch is "good" or "safe."

### File activity animations

Use very short animations for observable filesystem events:

- writing/editing: pencil or cursor motion;
- create: page/crate appears;
- rename/move: short slide from source to destination;
- delete: bounded removal animation;
- refresh/reload: small page flip or spinner-like pixel loop.

Avoid persistent animation for routine background churn.

### Agent state sprites

Define one tiny reusable agent-state vocabulary.

Initial candidate states:

- idle
- thinking
- working
- reading
- writing
- success/completed
- blocked
- stale/disconnected

Potential metaphors:

- thinking: scribbling at a desk;
- reading: open book/document;
- writing: pencil/keyboard;
- working/executing: terminal glow;
- blocked: closed gate/barrier;
- idle: seated/resting;
- stale/disconnected: dim or unplugged station;
- success: brief completion pose, then return to idle.

Do not use a success pose unless Conduit has an authoritative completion state.

### Task-completion parcel movement

When a task produces a concrete artifact, briefly animate a small parcel/document from the task/agent surface toward the relevant project or Explorer location.

This can make provenance legible: the animation says "this work produced something here."

It should only occur when a destination is actually known.

### Conduit packet / routing animation

Use the Conduit name literally but lightly.

Represent dispatch or message transfer as tiny packets moving through a short conduit/pipe path between bounded surfaces such as:

ChatGPT / operator
→ Conduit task
→ agent/runtime
→ repository or artifact

This could become a recognizable visual language for routing, but it must not imply delivery or execution success before those states are observed.

### Contextual empty states

Replace generic empty states with small static or low-motion pixel scenes where useful.

Candidates:

- empty directory: unopened crate/shelf;
- no search results: character with binoculars/magnifier;
- disconnected runtime: unplugged cable/terminal;
- no active tasks: empty desk;
- no recent artifacts: quiet archive shelf.

These should remain secondary to clear explanatory text.

### Mini activity landscape

Experiment with a very small optional strip near the bottom of Explorer or another peripheral surface.

It can summarize real activity through tiny scenes:

- agents arrive/leave;
- terminal windows light up;
- files move;
- a worktree becomes active;
- a task goes idle or blocked.

Treat this as an experiment. It must not consume meaningful vertical space or compete with navigation.

### Stateful and dangerous-operation animations

Use distinctive visual motion for operations where state transitions matter.

Candidates:

- branch/worktree switch: railway track switch;
- destructive delete: clear removal animation;
- migration/restructure: crate/cart movement;
- disconnect: cable unplug;
- reconnect: cable restored;
- task handoff: parcel transfer.

Animation should reinforce an already explicit UI state, not replace confirmation, labels, or safety controls.

### Rare easter eggs

Keep these uncommon and non-semantic.

Examples:

- several simultaneous successful tasks: brief tiny fireworks;
- long idle period: agent fishes/reads;
- large deterministic test pass: brief confetti.

Easter eggs must never obscure failures, warnings, or active controls and should be disableable with ambient animation.

## Initial reusable sprite system

Start with a small coherent set rather than dozens of bespoke animations.

Recommended first pass:

1. idle
2. thinking
3. working
4. reading
5. writing
6. success/completed
7. blocked
8. stale/disconnected

Design each as a small loop or short transition that can survive at compact sidebar sizes.

Prefer a consistent base character/silhouette with props and poses over unrelated icons for every state.

## Visual constraints

- conversation remains visually dominant;
- animation belongs primarily in sidebars, Explorer, status edges, and transitions;
- low frame rate and short loops;
- no continuous high-frequency motion;
- no meaning encoded by color alone;
- readable in light and dark themes;
- respect Reduce Motion;
- provide a global/off or reduced ambient-animation setting;
- stop or simplify animation when the window is unfocused where practical;
- avoid asset sizes or redraw patterns that worsen current UI performance concerns;
- do not let pixel art imply health, verification, authority, Git cleanliness, completion, or priority unless that state is explicitly observed.

## Suggested implementation order

### Phase 1: asset exploration

Generate a coherent sprite sheet for the eight core states plus a small set of Explorer/worktree objects.

No product integration claim yet. Evaluate legibility at actual Conduit sidebar sizes.

### Phase 2: one bounded integration

Choose one low-risk surface, preferably observed agent state or worktree identity.

Map only states Conduit already knows explicitly.

Verify performance and Reduce Motion behavior in the installed app.

### Phase 3: provenance/transitions

If Phase 2 is useful, test one short transition such as task-produced artifact → Explorer location or runtime dispatch → agent.

### Phase 4: ambient scenes

Only after ordinary status animations prove useful should Conduit test the mini activity landscape or rare easter eggs.

## Acceptance questions for the first visual experiment

The first prototype should answer:

- Can the state be recognized at compact size without text?
- Does the same animation remain understandable in light and dark themes?
- Does it stay secondary to the chat and file tree?
- Is the state tied to an observed Conduit fact?
- Does Reduce Motion/off fully suppress unnecessary animation?
- Does repeated activity remain calm rather than visually noisy?
- Is there any measurable interaction/rendering regression?
- Does the visual add useful orientation or feedback beyond the existing label?

A negative answer is acceptable. Pixel animation is optional product texture, not a required architecture.

## Non-goals

This proposal does not:

- change task, runtime, filesystem, Git, lifecycle, or completion authority;
- modify PR #43's qualified Explorer/Related candidate;
- define a new source of truth for worktree state;
- replace textual status or accessibility labels;
- require every surface to use pixel art;
- justify animation that creates measurable lag;
- make decorative assets part of correctness.

## First generation target

Generate one coherent sprite sheet rather than isolated polished scenes.

The first sheet should contain:

- one base Conduit worker/agent character;
- the eight core state poses/loops;
- folder, document, terminal, parcel, cable, small gate, desk/workstation, and worktree-camp props;
- a small routing-packet motif;
- enough spacing and consistency that individual sprites can be extracted cleanly.

The purpose of the first generation is to discover a usable visual language, not to freeze final production assets.
