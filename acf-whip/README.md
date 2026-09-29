# ACF Whip

acf-whip is a Claude Code plugin that breaks a goal into tasks and has agents build them. `/task`
splits the goal into small tasks with explicit dependencies. `/go` builds them in isolated git
worktrees, one per worktree slug, runs your quality gates and a review that accepts or rejects, and
by default lands accepted work on your local trunk. `/retro` closes the cycle and, when something
went wrong, looks for the root cause. A risky goal gets a written plan first, and nothing is built
until you approve it.

It also enforces a task-writing style and generates the specialist agents your stack needs. It is
the backlog engine of **ACF (Agentic Continuous Flow)**, in which humans govern agent swarms and the
agents write the code. It needs no other ACF plugin.

The one command to remember is `/whip`. With no argument it prints where you are, what needs you,
and the one command to run next, worked out from git and the task store on every call.

```
/whip "<goal>" → small work: /task; risky work: a plan you approve with one yes
         ↓
/task → decompose scope into atomic tasks (WHAT/WHY only, no HOW)
         ↓
/go → continuous execution until 100% complete (loops until all terminal)
         ↓
quality gates → zero bypass tolerance (all must pass)
         ↓
review → binary accept/reject (no partial credit)
         ↓
/retro → close the cycle; when something went wrong: root causes, one-rule lessons, action items you approve
```

The rules are strict on purpose. A review either accepts a task or rejects it; there is no partial
credit, and acceptance needs evidence. Gates are never skipped (see [Quality Gates](#quality-gates)).

---

## The cycle (3.5.0)

| Stage | Command | Artifact | Gate |
|---|---|---|---|
| Where am I | `/whip` | STATUS, NEED YOU cards, one NEXT line | none: read-only |
| PLAN | `/whip "<goal>"` drafts, `/whip <file.md>` imports, `/whip <cycle-id>` re-shows the card | `docs/cycles/YYYYMMDD-<slug>/plan.md` (yours) and `record.md` (stamp, task map, Plan Log; written only by `acfw-cycle`) | **you**: one "yes" approves the exact bytes on the card (`content=<hash>`); a `block` spec tool also needs GO or your override |
| DECOMPOSE | starts itself on "yes"; by hand: `/task --plan [<cycle>]` | tasks carrying `Documentation: docs/cycles/<ID>/plan.md (D2)`, the `## Tasks` map in `record.md`, your `/go` focus | re-checked in the workflow: approved at HEAD, built from a frozen copy of the approved text, every task names a deliverable |
| BUILD | `/go` | code on your local trunk (LP-CAS) | per-task gates and review, `ACFW_GATE_CMD` |
| VERIFY | `/whip` | coverage per deliverable: ✓ done, ◐ not finished, ✗ blocked, `?` unverified, cancelled | a ✗ fires the retro |
| RETRO | `/retro [<cycle>]` | clean: `Status: closed`, zero agents; triggered: `retro.md`, up to 3 `docs/acf/lessons/<slug>.md`, a retro-actions cycle | **you**: action items become work only through the same approval card |
| SHIP | yours: push, PR, merge | nothing | **you**, always: `/go` never pushes |

**Two routes.** `/whip "<goal>"` picks one and tells you why. Small work is the default: it prints
`NEXT /task "<goal>"` and runs as it did before 3.5.0, with no plan. A goal gets a plan first when it
touches data, a schema or a migration; auth, secrets, payments or personal data; a public contract,
in a breaking way; three or more modules; or a new user flow. `/whip plan <goal>` asks for a plan
outright. The rubric lives in one place, [`skills/whip/SKILL.md`](skills/whip/SKILL.md).

What a plan's approval card looks like (real output):

```
NEED YOU
  WHAT approve docs/cycles/20260929-owner-seat-notice/plan.md "Owner seat notice" (2 deliverables)
  RISK nothing is built until you approve, and the approval binds exactly content=64075a203d34: any later edit needs a new card. Undo: /whip --abandon 20260929-owner-seat-notice
  REPLY yes: approve, then start /task --plan in the background (sets your /go focus)
  content=64075a203d34
  D1: Owner gets an email when a seat is added
  D2: The notice is logged
  ASSUME Route: planned, because it touches payments.

NEXT yes: approve docs/cycles/20260929-owner-seat-notice/plan.md (content=64075a203d34)
```

The engine enforces these, so you do not have to:

- **Approval binds bytes.** It holds only while `record.md`'s `Approved Content`, the newest
  `approved` row and the hash of `plan.md` agree at HEAD. Edit the plan after "yes" and `/whip`
  says "amended since approval". The approved text keeps building; your edit waits for its own card.
- **D-ids are permanent once a task names them.** New work takes the next number. To drop a
  deliverable, keep its heading and archive its tasks: it shows as cancelled.
- **Imports are copies.** `/whip <file.md>` never writes the source file (superpowers, spec-kit,
  Claude plan mode, hand-written). A plan without `## Deliverables` / `### D<n>` runs with coverage
  off, and the card says so.
- **Tasks never edit cycles.** The integrator drops any `docs/cycles/` change a task carries and
  names the dropped paths in a WARN. A plan changes only through `/whip`.
- **Every plan event is its own commit**, `docs(plan): <event> <slug>`, with an `ACFW-Plan-Event`
  trailer for audit. A squash merge may drop the trailer; that costs a WARN, never an approval.
- **Lessons feed the next plan.** `/task` planners and critics read `docs/acf/lessons/`, and a
  relevant rule goes into the constraints of any task that walks into it.
- **A retro-actions cycle closes itself** once its tasks are done; the next approve, record or
  `/retro` stamps it closed. There is no retro of a retro.

Cards you may meet:

- **Pin the integration mode.** In a project with no `ACFW_INTEGRATION_MODE` pin, as soon as a cycle
  task is accepted with no ledger marker, `/whip` shows a card naming `ACFW_INTEGRATION_MODE`, with
  the pin as its REPLY. Unpinned, `/go` infers the mode from `CLAUDE.md`, and an inferred `override`
  never integrates, so the cycle would never finish. `/whip-init` pins `default` for new projects.
- **`?` on a deliverable** means a task is accepted but no branch or ledger marker proves its change
  reached trunk. On `files`, `/whip-move <stem> accepted --integrated-at <sha>` clears it. On other
  stores, write the ledger marker by hand ("Clearing accepted-branchless-unverified" in
  `docs/acf/backlog/recovery-runbook.md`), or `/whip-move <stem> pending` to build it again.
- **A decomposition lock** shows that a `/task --plan` started. It does not prove the run is still
  alive. The lock expires after 30 minutes, and the card prints its age and the one `rm` that clears
  it sooner.

---

## Spec tools (reviewers and workbenches)

A spec tool reviews a plan before you approve it, reviews the tasks `/task` writes (free text or
`--plan`), or lets you edit the plan somewhere else and merge it back. You add one with a single
committed file in `.acfwhip/spec-tools/`; the engine itself names no tool. The smallest is a grep:

```
# .acfwhip/spec-tools/no-tbd: refuse plans and tasks that still say TBD, TODO or FIXME
review=grep -nwE 'TBD|TODO|FIXME' "$ACFW_SPEC_FILE"; test $? -eq 1
at=plan,task
policy=block
```

GapTrap (hosted spec gap analysis) is the worked example of a paid, remote tool
([setup, cost and egress](spec-tools/gaptrap/README.md)):

1. Create a key in GapTrap under Profile, API keys. In a separate terminal, add
   `export GAPTRAP_API_KEY=...` to your shell profile and restart Claude Code, or add
   `GAPTRAP_API_KEY=...` to a gitignored `.env`, which is read on every run. An export typed into
   another terminal never reaches a running Claude Code. Never paste the key into the chat. The
   exact lines are in [gaptrap/README.md](spec-tools/gaptrap/README.md).
2. `/whip --tools add gaptrap`: a free probe shows the verbs, egress host and cost, then commits it.
3. `/whip "<goal>"`: the card shows GapTrap's verdict, findings F1..F8 and questions.

Hook points: before every approval card (`at=plan`); inside `/task`, free text or `--plan`, before
tasks are written (`at=task`; a task a `block` tool still rejects is held in draft); at approval
(`policy=block` needs GO on those exact bytes, or your reply `yes, override <tool>`); and on
`/whip --push` / `--pull` for a workbench. **Never in `/go`**: the spec is frozen at approval, and a
false positive there would cost a task one of its three lives. A tool that cannot run never blocks.
Full guide: [`spec-tools/README.md`](spec-tools/README.md); protocol:
[`spec-tools/CONTRACT.md`](spec-tools/CONTRACT.md).

---

## Features

### Continuous execution

`/go` loops until every task in its scope is accepted or blocked. Each iteration processes every
state transition and runs independent tasks in parallel, one specialist per worktree slug. A task
waits for its dependencies: a same-slug dependency must be accepted, a cross-slug one integrated.
Accepted work is integrated into your local trunk, and a specialist resolves any conflict. You are
not needed until the work is done or the loop stops making progress.

### Scope: a bare `/go` runs your tasks (3.2.3, 3.4.0)

`/task` points this checkout's **focus** at the tasks it just created, and a bare `/go` runs the
focus. The usual path (plan, then `/task`, then `/go`) takes no arguments and still runs only your
own work. `/whip-focus` edits the focus by hand. It is gitignored, per-checkout state: two people
on one board have two focuses.

```
/go                              your focus
/go --all                        the whole backlog, explicitly
/go api-014-token MUL-4821       exactly these (stems, ids, native ids, unique prefixes)
/go frontend tasks only          a natural-language filter, resolved and confirmed before launch
/whip-move <task> draft          pause it   (archive = cancel) — on every backend
```

Named tasks run with their unmet dependencies, and nothing outside the scope is dispatched,
transitioned or integrated, so `/go` is usable on a backlog a whole team shares. With no focus set,
a bare `/go` drains the backlog on the `files` store and **refuses** on a shared API-backed board:
one person's bare `/go` should never run everyone's work. Details are under `/go` in the
[Commands Reference](#commands-reference).

### Integration: local by default, PR-per-task if you pin it

Integration is automatic and **local** by default: accepted work is cherry-picked onto your local
trunk, nothing is pushed, and no PR is opened. If merges must go through review (a protected trunk,
or a team that works PR by PR), pin the mode so it never depends on a per-run judgement.

Set it in the config file your repo already has, and change the existing line if there is one
(`/whip-init` pins `default` in new projects): `.backlog/.acfw-config` on the files store,
`.acfwhip/config` on the others. acf-whip reads only the first of the two it finds, so never create
`.acfwhip/config` next to an existing `.backlog/.acfw-config`: it would hide every key in the old
file.

```bash
ACFW_INTEGRATION_MODE=override    # committed; travels with the repo
```

`/go` then stops at `accepted`, writes no ledger marker, and keeps each `worktree/<slug>` branch
alive for you to push and open PRs from. Dependency ordering becomes your job. `/go` still never
pushes or calls `gh`. Left unpinned, `/go` decides the mode on each run by reading `CLAUDE.md`.

`.backlog/` state transitions are committed on trunk in **both** modes. If trunk must stay free of
bookkeeping commits, use a non-files task store (below). Details: `skills/go/SKILL.md` §
Integration mode.

### Per-task child workflows (3.2.0)

Each dispatched task runs as its **own nested workflow**, not a single `agent()` call. A
**workflow-architect** agent writes the harness for that task by filling four marked regions of a
locked, byte-diffed skeleton (`skills/lib/child-skeleton.js.tmpl`), and a 20-check validator rejects
a defective harness *before* any child agent starts.

The default harness is shallow on purpose: checkout, implement, a bounded gate loop, an adversarial
review of the diff, verify. It keeps the three things a script gives you that one strong agent
cannot: an advance condition the script checks against a schema instead of taking an agent's word
for it, a reviewer who reads the diff with fresh context, and a stage ledger that survives the
script throwing.

- **Escalation is best effort.** The runtime caps the number of agents per run, so `/go` steps down
  FULL → LEAN → DIRECT → CLOSE as the budget runs out, falling back to unchanged 3.1.0 single-agent
  dispatch at the lower levels. The report says which level you got (`escalation{}`,
  `agentsUsed`/`agentCap`).
- **Tunable**: `escalate` (default on; set it false to go back to 3.1.0 dispatch, and try this first
  if a run looks hung), `escalateReview` (default **off**; it turns on the multi-lens review panel,
  the one escalation that can reject work that would otherwise ship), `maxAmend`, `agentBudget`,
  `agentCap`, `shellModel`.

### Workflow-native orchestration (2.0.0)

When dynamic workflows are available (Claude Code ≥ 2.1.154), `/task` and `/go` run as **dynamic
workflows** (`workflows/whip-task.workflow.js`, `workflows/whip-go.workflow.js`):

- **Flat context.** The loop, slug partition, dependency gate and topological integration order run
  in a deterministic script. Intermediate state lives in script variables rather than in Claude's
  context, so the context stays flat however many tasks and iterations a run takes. This is what
  ended the old "stop work to dump history" problem.
- **Slugs enforced by schema.** `/task`'s planner cannot omit a worktree slug, and a JS validation
  gate (kebab-case, slug ≠ id, acyclic deps, unique ids) runs before any file is written. The doctor
  repairs a missing slug on an active task by deriving one from the id. It raises a FATAL only when
  two ids derive the same slug (`duplicate-derived-slug`) or there is no id to derive one from.
- **Integrity gate.** The doctor gates startup and rechecks every iteration.
- **Fallback.** If dynamic workflows are off, both commands fall back to the legacy single-context
  loop (same behavior, byte-compatible).

### Integrity doctor, and one bad card holds out one task (3.4.0)

`/whip-doctor [--fix]` checks about 20 invariants (listed under `/whip-doctor` below) and reports
each finding as FATAL, REPAIRABLE or WARN. It runs as `/go`'s startup gate and per-iteration
recheck, and when `/task` creates tasks.

Only a **repo-scoped** FATAL stops the run: a detached HEAD, a worktree on the wrong branch, an
unreadable store. A **task-scoped** finding holds out that one task and lets the rest of the board
run; before 3.4.0, one malformed card could block a whole team. The held task is never dispatched
and never integrated, and it still gates its dependents. A run that held something out reports
`partial`, never `complete`, and `heldOut[]` names each task it refused to touch and why.

### The snapshot is narrowed in the store and verified on arrival (3.4.0)

`/go`'s scan agent relays the store walk to the orchestrator. On a large board that relay could come
back short, as valid JSON with fewer tasks, and the run then reported the ids it was given as
nonexistent. Now `--only` emits only the **closure** of the named tasks (the seeds plus their unmet
dependencies), a real `--digest` collapses finished work on **every** backend instead of only
`files`, and every snapshot carries a `relay` header that the orchestrator recomputes. A short relay
stops the run as `relay-truncated`, with the actual remedy. It is never reported as a missing id.

### Agents route by tier, and the run says what it spent (3.4.0)

Agents run on the model their job needs:

| Agents | Model |
|---|---|
| Shell runners that run a fixed command and copy its output (scan, writers, integrate, doctor) | a cheap model (`ACFW_MODEL_SHELL`, default `haiku`) |
| `/task` planners, the judge, the critic | the session model, unless `ACFW_MODEL_JUDGE` pins one |
| `/task` task-document authors | the session model, unless `ACFW_MODEL_AUTHOR` pins one |
| Specialists and reviewers | the `model:` the project declared in `.claude/agents/<name>.md` |
| The architect and the conflict resolver | always the session model |

Pin the tiers once per repo (`ACFW_MODEL_SHELL`, `_JUDGE`, `_AUTHOR`) in the config file your repo
already has, as under Integration above: `.backlog/.acfw-config` on the files store,
`.acfwhip/config` on the others. Every run reports `models` and `agentsByTier`.

### Pluggable task stores (3.1.0)

Task state lives behind an **executable adapter contract** (`adapters/CONTRACT.md`, contract v1).
The `acfw-store` dispatcher resolves the configured backend and routes every read and write
(`snapshot`, `transition`, `read`, `create`, `doctor`) to its adapter:

| Backend | State lives in | Select with |
|---|---|---|
| `files` (default) | `.backlog/<state>/*.md` committed on trunk | nothing: it is the zero-config default |
| `beads` | [beads](https://github.com/gastownhall/beads) (`bd`, embedded Dolt) | `ACFW_STORE=beads` in `.acfwhip/config` |
| `multica` | [multica](https://github.com/multica-ai/multica) server | `ACFW_STORE=multica` + `MULTICA_*` env |
| `linear` | [Linear](https://linear.app) issues (attachment metadata) | `ACFW_STORE=linear` + `LINEAR_API_KEY`/`ACFW_LINEAR_TEAM` env |

- **No migration.** Existing `.backlog/` projects run unchanged; `files` behaves byte for byte as it
  did in 3.0.x.
- **Your own backend, no fork.** Drop one executable at `.acfwhip/adapters/acfw-store-<name>`, set
  `ACFW_STORE=<name>`, and pass the conformance test
  (`ADAPTER=<path> bash tests/phase9-store-conformance.test.sh`). The contract, discovery order,
  JSON shapes and exit codes are in `adapters/CONTRACT.md`; the architecture, dispatcher mechanics
  and an authoring walkthrough are in `adapters/README.md`.
- **What never moves into a backend**: the LP-CAS integration ledger (`.acfwhip/integrated/` in the
  git tree). Integration truth stays in git on every store.

### Every backend under the contract suite, offline (3.3.0)

`tests/phase9-store-conformance.test.sh` is the contract's executable spec. Before 3.3.0 only
`files` ran it: the other three skipped without a live server, and the runner counted a skip as a
pass. The API backends were green by absence, and their defects stayed hidden until a user hit
one: a snapshot field answered for one task state, an inert card raised to a gate FATAL, a network
timeout written into a rejection counter.

The multica suite now drives the real adapter through an offline fake of its CLI, injected at the
`ACFW_MULTICA_BIN` seam that every call already goes through. It runs the frozen spec with no
server, credentials or skip. Fault injection covers the transient paths.

To accept an adapter for your own backend, run
`ADAPTER=<path> bash tests/phase9-store-conformance.test.sh`; that is the whole test.
`tests/phase9-adapter-multica.test.sh` shows how to test an adapter with no backend to talk to.

### Worktree env hydration

A committed `.worktreeinclude` manifest lists the git-ignored files (`.env`, `node_modules`,
`.venv`, local config) to copy or symlink into each fresh `.worktree/<slug>`, so a specialist can
run the full dev and test setup. Nothing outside the list is touched. Every entry must be
git-ignored, and a tracked path is an error. A secret-shaped path (`.env*`, `*.pem`, `*.key`,
`id_*`, `credentials*`, `*.p12`) is never symlinked: a link entry for one becomes a copy with group
and other permissions removed.

### State machine

```
pending → in-progress → completed → in-review → [accepted | rejected]
            ↓                                          ↓
         blocked                                    pending (retry)
```

**Terminal states**: `accepted` (success) and `blocked` (failed after 3 retries, or cannot be
resolved). `draft` (paused) and `archive` (cancelled) sit outside the loop; `/whip-move` puts a task
there.

### Task style enforcement

Every task must follow `docs/acf/style/task-descriptions.md`:

- binary, testable statements ("API validates token", not "improve validation")
- what and why, never how: the specialist decides the implementation
- code snippets of 2-3 lines at most, signatures only, never implementations
- none of the banned words (comprehensive, robust, elegant, enhance, optimize and others)

`/task` checks every task against the guide and revises any that fail before it writes them. The
rules are summarized under [Task Description Style Guide](#task-description-style-guide).

### Agent and manifest generator

`/whip-add-agents` creates the specialist agents your project is missing:

- **Reads the repository**: detects the tech stack and assesses its complexity.
- **Writes two files per agent**: `.claude/agents/{agent}.md` with the agent's core instructions,
  and `docs/agents/{agent}.md`, a manifest that ranks the docs the agent should read (Priority
  1/2/3).
- **Writes a quality-gate doc** for the stack if there is none.
- **Updates** `.backlog/README.md`, and `CLAUDE.md` if the project has one.
- **Takes flags over detection**: `--backend=go --frontend=react`.

### SessionStart hook and installed docs (3.3.0)

On every session start the hook:

- installs any plugin-owned document it does not find: `task-descriptions.md` into
  `docs/acf/style/`, and `task-template.md`, `workflow.md` and `recovery-runbook.md` into
  `docs/acf/backlog/`
- **refreshes** a copy it installed earlier when that copy is unedited. It recognizes an unedited
  copy by content digest (`content/.digests.json`), not by a version stamp the copy may predate, so
  this works on projects older than the mechanism. An edited copy is never overwritten; the hook
  reports it as behind so you can merge what you want
- injects the style guide into the session context

⚠️ **The hook does not create the `.backlog/` structure or install agents.** Run `/whip-init` for
that.

### CLAUDE.md delegation section

`/whip-init` adds a **Pure Delegation Architecture** section to `CLAUDE.md`, and creates a minimal
`CLAUDE.md` first if the project has none. The rule it states: the general-purpose agent never
modifies code. It decomposes, coordinates and enforces gates; specialists implement. The section
also carries an up-to-date matrix of your agents and a 5-step delegation protocol. It mentions a
pre-tool-use hook that validates who edits code, which is not implemented yet, and claims a 3x+
speedup from running specialists in parallel, which nothing in the plugin measures.

The matrix looks like this:

| Domain | Agent | Responsibilities |
|--------|-------|------------------|
| Core | task-engineer | Task decomposition (WHAT/WHY only) |
| Backend | go-engineer | Go implementation |
| Infrastructure | devops | Docker, K8s, CI/CD, monitoring |

### docs/README.md as a documentation index

When `/whip-init` and `/whip-add-agents` build agent manifests, they read `docs/README.md`, if you
have one, to find your documentation. Without it they scan the standard directories
(`docs/architecture/`, `docs/operations/`, and so on). An index lets them find docs outside those
directories, and lets you decide what is listed and what comes first. It needs no special format.

A simple `docs/README.md`:
```markdown
# Project Documentation

## Core
- [Architecture](./architecture/) - System design
- [Quality Gates](./development/quality-gates-go.md) - Go quality standards

## Guides
- [API Development](./guides/api-development.md) - Building APIs
```

A starting point is in `content/templates/docs-readme-template.md`.

### Gap analysis on re-init

Run `/whip-init` again on a project that already has acf-whip and it reports what is missing
(universal agents, manifests, core docs, quality gates, CLAUDE.md sections) with a fix for each. It
never overwrites an existing file. Example output:
```
⚠️  Gap Analysis: Missing ACF Artifacts

🤖 Missing Universal Agents:
   - devops
   → Fix: Re-run /whip-init or manually generate

📚 Missing Agent Manifests:
   - task-engineer.md, devops.md
   → Manifests provide 58-74% token reduction

✅ No gaps detected - ACF Whip fully integrated
```

---

## Installation

### Prerequisites

- Claude Code CLI installed
- Git repository for your project
- Python 3.8+ (for SessionStart hook)

### Install Plugin

```bash
# Add the acf-tools marketplace
/plugin marketplace add ./acf-tools
# OR from GitHub (when published):
# /plugin marketplace add owner/acf-tools

# Install acf-whip plugin
/plugin install acf-whip@acf-tools

# Restart Claude Code if prompted
```

### Verify Installation

```shell
# Check plugin installed
/plugin list
# Should show: acf-whip@acf-tools (enabled)

# Start a session in your project
# You should see:
```
```
# ACF Task Description Style Guide (Enforcement Active)

The following style guide is MANDATORY for all task descriptions...
```

That confirms the SessionStart hook is active.

**If it does not appear:**
```bash
# Enable debug mode to see plugin loading
claude --debug

# Verify plugin structure
cd /path/to/acf-tools/acf-whip
claude plugin validate .
```

---

## Quick Start

⚠️ **Run `/whip-init` first**, right after installing. It creates the task store (`.backlog/` on
the default `files` store), installs the agents and configures quality gates. The SessionStart hook
does none of that.

### 1. Initialize Backlog Workflow

```bash
/whip-init
```

**What it does**:
- Detects the tech stack (Go, Python, Node.js, React, Next.js, K8s, Docker, CI/CD and others) and
  the infrastructure (Docker, Kubernetes, GitHub Actions, monitoring)
- Creates the `.backlog/` structure, 9 state folders (on the `files` store)
- **Generates 7 universal agents** into `.claude/agents/`, customized from patterns, plus `devops`
  when it finds infrastructure and you accept it
- Configures quality gates (`.pre-commit-config.yaml`)
- Generates `.backlog/README.md`
- **Builds agent manifests** from your existing `docs/` (Priority 1/2/3 references)
- **Adds delegation rules and an agent matrix to `CLAUDE.md`**, creating the file if needed
- **On a re-run**, reports missing artifacts and overwrites nothing

**Output**:
```
✅ ACF Whip Initialized Successfully

📁 Directory Structure Created:
   .backlog/ (9 state folders)

📋 Core Documentation Initialized:
   ✓ docs/acf/style/task-descriptions.md
   ✓ docs/acf/backlog/task-template.md
   ✓ docs/acf/backlog/workflow.md
   ✓ .backlog/README.md

👥 Universal Agents Generated (customized for your stack): (6-7)
   ✓ task-engineer (with {stack}-specific examples)
   ✓ quality-reviewer (with {stack} quality gates)
   ✓ lean-architect, retro, precommit, research-agent
   ✓ devops (optional, if infrastructure detected)

📊 Agent Manifests Generated:
   ✓ docs/agents/*.md (Priority 1/2/3 structure, 58-74% token reduction)
   ✓ Deep customization analyzing existing docs/

🎯 Quality Gates Configured

📋 CLAUDE.md Enhanced (if exists):
   ✓ Pure Delegation Architecture section
   ✓ Agent matrix (6-7 agents)
   ✓ Enforcement: General agent CANNOT modify code

Next Steps: Run /whip-add-agents
```

### 2. Generate Specialist Agents

```bash
# Auto-detect tech stack
/whip-add-agents

# OR specify explicitly
/whip-add-agents --backend=go --frontend=react
```

**What it does**:
- Reads the repository structure and finds the specialist agents you are missing
- Creates `.claude/agents/{agent}.md` (implementation) and `docs/agents/{agent}.md` (manifest with
  Priority 1/2/3 docs) for each
- Generates quality gate docs if you have none
- Adds the new agents to `.backlog/README.md`

**Output**:
```
✅ Created 3 specialist agents + manifests

📋 go-engineer
   - Implementation: .claude/agents/go-engineer.md
   - Manifest: docs/agents/go-engineer.md
   - Quality Gates: docs/development/quality-gates-go.md

📋 react-engineer
   ...

Next Steps: Run /task to decompose work
```

### 3. Decompose Scope Into Tasks

```bash
/task "Implement user authentication system with JWT tokens"
```

Not sure whether the work needs a plan? Run `/whip "<goal>"` instead. For small work it prints this
`/task` line for you to run; for risky work (auth, like this example) it drafts a plan and shows an
approval card, and your "yes" starts `/task --plan` itself. See [The cycle](#the-cycle-350).

**What it does**:
- Reads `docs/acf/style/task-descriptions.md`
- Does light research, only to understand the scope (Perplexity, plus Context7 and Figma when they
  apply)
- Decomposes the scope into atomic tasks (WHAT/WHY only)
- Checks each task against the style guide
- Spawns task-engineer agents in parallel
- Creates the tasks as pending (`.backlog/pending/` on `files`)

**Output**:
```
🔥 Task Decomposition Started

✓ Style guide loaded
✓ Research complete
✓ 3 atomic tasks identified
✓ Style validation passed

Created tasks:
- backend-001-user-auth-api.md (high, go-engineer)
- backend-002-user-profile-mgmt.md (high, go-engineer)
- backend-003-password-reset-flow.md (medium, go-engineer)

Next step: Run /go
```

### 4. Execute Backlog

```bash
/go
```

**What it does**: loops until every task in the run is accepted or blocked. Each iteration scans
every state, processes the transitions, dispatches agents in parallel (one per free worktree slug),
integrates newly accepted work and checks for completion. It stops when everything is terminal, or
when it stalls and needs you.

**Output**:
```
🔥 /go - Continuous Backlog Execution Started

🔄 Iteration 1
  🔧 Auto-fixing quality gates...
  📊 Scanning states... (5 pending)
  ⚡ Processing transitions...
  🚀 Spawning agents (parallel)...
  📊 Progress: 0/5 terminal

🔄 Iteration 2
  ...
  📊 Progress: 2/5 terminal (2 accepted)

🔄 Iteration 3
  ...
  📊 Progress: 5/5 terminal (5 accepted, 0 blocked)

✅ Backlog 100% complete!
   Accepted: 5
   Blocked: 0
   Iterations: 3
```

### 5. Check coverage, then close the cycle

```bash
/whip      # a planned cycle: the coverage table, and NEXT /retro once every task is terminal
/retro     # the cycle /whip names
```

A clean cycle closes with one script call. If a task was reworked or stuck, or a deliverable was
missed, the retro agent writes the root causes, up to 3 lessons and a retro-actions cycle for you
to approve; `/retro` in the Commands Reference has the details. Work done without a plan has no
cycle to close: use `/retro --force <task>...`.

---

## Commands Reference

Ten commands you type: `/whip`, `/task`, `/go`, `/retro`, `/research`, `/whip-init`,
`/whip-add-agents`, `/whip-doctor`, `/whip-focus`, `/whip-move`. Two more skills,
`clean-checkout-before-task` and `integrate-lpcas`, are invoked by agents and `/go`, never by you,
and `whip-go` / `whip-task` are the workflow engines behind `/go` and `/task`.

### /whip - Where you are, and the one command to run next

**Purpose**: shows where the cycle stands and what to run next. It prints `acfw-cycle` output
verbatim and never works out a stage on its own.

**Usage**:
```bash
/whip                        # where you are: STATUS, NEED YOU, NEXT (read-only)
/whip "<goal>"               # small: prints NEXT /task "<goal>"; risky: drafts a plan, shows the card
/whip <file.md>              # adopt a plan written anywhere else; the source is never written
/whip <cycle-id>             # re-show that cycle's card, e.g. after you edited its plan.md
/whip --abandon [<cycle-id>] # close a cycle you no longer want, zero agents
yes                          # after a card: approve those exact bytes, then start /task --plan
```

**Behavior**:
- A reply that changes the plan (a vetoed assumption, "yes, but ...") is an edit, not a yes: the
  plan is edited, a new card is shown, and nothing is approved in the same turn
- `--expect` always comes from the `content=` of a card you saw; a stale value is refused with
  exit 9 and nothing is written
- `/go` and `/retro` stay printed NEXT lines: `/whip` never runs them for you
- Without the Workflow tool, approval still works and `/whip` prints the free-text `/task`
  fallback, with coverage off for that cycle

**Output**: the STATUS block, cards, one `NEXT` line. Plans live in `docs/cycles/<ID>/`.

---

### /task - Decompose a scope

**Purpose**: split a scope into atomic tasks. It never implements anything.

**Execution**: runs as the `whip-task` dynamic workflow when available, which enforces slugs by
schema and runs a JS validation gate and the create-time doctor before any file is written.
Otherwise it runs the legacy single-context decomposition.

**Usage**:
```bash
/task "Scope description"
/task "Add real-time notifications. Figma: https://figma.com/design/ABC/App?node-id=1-2"
/task --plan 20260928-owner-seat-notice   # decompose an approved plan (/whip starts this on "yes")
/task --plan                              # the cycle /whip says is next
```

**Plan mode** (`--plan`, workflow only): planners read a frozen copy of the approved `plan.md`,
only deliverables with no task yet are decomposed, every task names the deliverables it implements
(`Documentation: docs/cycles/<ID>/plan.md (D2)`), the task map is recorded in `record.md` before any
task exists, and your `/go` focus is set to the cycle's unfinished tasks. Free text next to
`--plan` is refused: extra work goes into the plan, or into a separate `/task "<scope>"`.

**Behavior**:
1. Reads the style guide (required)
2. Does light research, only to understand the scope (Perplexity, Context7, Figma)
3. Decomposes into atomic tasks (WHAT/WHY only)
4. Checks each task against the style guide
5. Spawns task-engineer agents in parallel
6. Exits without starting any of the work

**Style rules it checks**:
- ✅ Binary language ("API validates token")
- ✅ WHAT/WHY only (no HOW)
- ✅ Code snippets of 2-3 lines at most
- ❌ Implementation details
- ❌ Banned words

**Output**: pending tasks in the task store (`.backlog/pending/` on `files`)

---

### /go - Continuous Execution

**Purpose**: run the tasks in scope until every one is accepted or blocked

**Execution**: runs as the `whip-go` dynamic workflow when available. The loop, partition,
dependency gate and integration live in a script, so Claude's context stays flat across iterations.
Otherwise it runs the legacy single-context loop. A repo-scoped FATAL from the doctor's startup
gate stops both. On a task-scoped FATAL the workflow holds out that task and runs the rest, while
the legacy loop still refuses to dispatch at all.

**Usage**:
```bash
/go                                          # your FOCUS (see Run scope below)
/go --all                                    # every actionable task, explicitly
/go api-014-token-refresh ui-021-login-form  # exactly those, plus their unmet dependencies
/go MUL-4821                                 # native backend ids resolve too
/go frontend tasks only                      # a natural-language filter over the backlog
/go bugfixes                                 # the fix/bug tasks
```

**Run scope (3.2.3, focus-driven since 3.4.0)**: with no arguments `/go` runs your **focus**, the
per-checkout list `/task` sets to the tasks it just created, or that you set with `/whip-focus`.
With no focus, `files` drains the whole backlog as before, and every shared API-backed store refuses
and names the three ways forward. `/go --all` is the explicit "yes, everything".

With arguments it runs **only** what you name. Task ids, stems and native backend ids pass straight
through. A natural-language filter is resolved **once, before launch**: it is matched against the
fields the snapshot carries on every backend (`agent`, `slug`, `priority`, `stem`, `touchesGlobs`),
shown to you and confirmed, so the orchestrator always receives a concrete task list and stays
deterministic.

Unmet transitive dependencies are pulled in and named in the log; already-accepted ones are left
alone. Nothing outside the scope is dispatched, transitioned or integrated, not even by the
post-loop drain, so a scoped run is safe on a backlog other people are working in. Completion is
measured over your scope. An id that matches no task aborts the run, rather than quietly running
less than you asked for. The run report echoes `scopeFilter`, `scopedTo` and `scopeResolved`.

**Behavior**:
- Loops until every task is terminal (or, when scoped, every task in the scope)
- Each iteration:
  - Scans every state (pending, in-progress, completed, in-review, rejected, blocked)
  - Re-checks integrity (`whip-doctor --active-only`)
  - Processes every transition through the single writer
  - Spawns agents in parallel, one per free worktree slug
  - Integrates newly accepted work into trunk (LP-CAS), then checks completion
- Exits: 100% complete; or 3 consecutive iterations doing no work at all (stuck, for example on
  dependencies that can never be met); or 15 iterations with no *terminal* gain (the
  perpetual-retry guard)
- Quality gate auto-fix runs on the **legacy** single-context loop. The workflow orchestrator relies
  on the per-task harness's own bounded gate loop instead

**State Transitions Processed**:
- `rejected` → `pending` (retry if <3 attempts, block if ≥3)
- `blocked` → `pending` (dependencies resolved)
- `pending` → `in-progress` (specialist agents start)
- `completed` → `in-review` → `accepted|rejected` (quality-reviewer)
- `in-progress` → `blocked` (stale dispatch; default 8h, set `ACFW_INPROGRESS_TIMEOUT_HOURS` to change)

**Output**: progress while it runs, then a run report

---

### /whip-focus - What a bare `/go` runs

**Purpose**: manage the run focus, the short per-checkout list of tasks a bare `/go` runs

```bash
/whip-focus                    # show it, with each task's live state and who set it when
/whip-focus set <tasks...>     # replace it with exactly these
/whip-focus add <tasks...>     # add these (replaces outright when every task in it is done)
/whip-focus drop <tasks...>    # remove these
/whip-focus clear              # remove it; a bare /go then follows the store's bareGo policy
```

Tasks may be named by stem, id, native backend id (`MUL-4821`) or a unique stem prefix. `set` and
`add` resolve every token through the store first and **refuse the whole operation** if any is
unknown or ambiguous. A focus that stored raw arguments would inherit every ambiguity in what you
typed, and a selection that quietly changes meaning is worse than none.

It lives at `.acfwhip/run/focus`, which is gitignored on purpose: a focus is one person's current
selection, not a fact about the project. Two people on one board have two focuses, and neither
one's `/go` becomes everyone's.

**Dropping a task does not pause it.** A scoped run pulls in the unmet dependencies of everything in
its scope, so a dropped task that something else needs comes straight back. That is correct:
otherwise the dependent could never run. To park a task, use `/whip-move` below.

---

### /whip-move - Move ONE task between states

**Purpose**: last-mile reconciliation without hand-editing the store

```bash
/whip-move <task> <state> [--reason "..."] [--integrated-at SHA] [--add-dep ID]
```

States: `pending in-progress completed in-review accepted rejected blocked draft archive`.

**`draft` pauses and `archive` cancels**, on every backend (3.4.0). The scheduler ignores both and
neither counts toward completion. Both still resolve as dependencies, so a task that depends on a
paused one is reported as gated, with the reason, rather than as a dangling reference.
`/whip-doctor --fix` never reaps a parked task's worktree or branch: it reports them as
`parked-task-worktree` and leaves them for you.

Setting a native `blocked`/`cancelled` status on an API-backed board does **not** pause a task,
because acf-whip reads its own metadata and ignores the native status. The doctor reports that as
`WARN|native-hold` and leaves the native status alone.

It runs the validated writer, so the folder move, the `Status:` sync, the transition-log row and the
commit stay atomic. Run `/whip-doctor` after.

---

### /whip-doctor - Backlog Integrity

**Purpose**: diagnose, and optionally repair, backlog and worktree health

**Usage**:
```bash
/whip-doctor          # report only
/whip-doctor --fix    # apply the REPAIRABLE class, then re-scan
```

**Checks** (FATAL / REPAIRABLE / WARN): status-vs-folder mismatch, missing/empty worktree slug on a
code task, unknown Assigned Agent, duplicate IDs, dangling/cyclic dependencies, cross-slug dependent
dispatched before integration, worktree on the wrong branch, detached HEAD; missing worktree slug
derivable from the id, out-of-range Rejection Count, dup-folder, orphaned worktree; missing
clean-checkout token, lingering in-review, stale in-progress, cross-slug glob overlap.

**Output**: `SEVERITY|CODE|TASK_ID|DETAIL` lines + a `SUMMARY|fatal=N|repairable=N|warn=N|ok=…`
line; exit 0 iff no FATAL. Runs automatically as a `/go` startup gate and per-iteration recheck.

---

### /retro - Close a Cycle, and Learn from It

**Purpose**: close a planned cycle, and learn from it when something went wrong

**Usage**:
```bash
/retro                       # the cycle waiting for its retro (the one /whip's NEXT names)
/retro <cycle>               # that cycle; mid-cycle with a trigger fired: the doc and lessons, not closed
/retro [<cycle>] --force     # analyze even though no trigger fired
/retro --force               # with no cycle waiting: a plan-less retro over your /go focus
/retro --force <task>...     # work done without a plan: these tasks
```

**Behavior**:
- A clean cycle closes with one script call and zero agents
- When a task was reworked or stuck, or a deliverable is not met, the retro agent finds root causes
  (Five Whys) and writes docs/cycles/<ID>/retro.md, at most 3 one-rule lessons in
  docs/acf/lessons/, and a retro-actions cycle you approve like any plan
- It never creates tasks, edits agent files, or deletes a lesson itself
- `/retro --force <task>...` (or a bare `/retro --force` with no cycle waiting, over your `/go`
  focus) analyzes work done without a plan, and writes `docs/retrospectives/YYYYMMDD-<slug>.md`
  and its lessons for you to commit
- Which triggers fired, and their thresholds, come only from `acfw-cycle triggers`; it reads every
  task store the same way, including reviewer comments on beads and linear
- A lesson a test or gate now enforces is listed under `## Retire`; you run the `git rm`
- It refuses only while `/go` runs

**Output**: `docs/cycles/<ID>/retro.md`, lessons, and a retro-actions cycle awaiting your approval
(or, for a clean cycle, only the `closed` stamp in `record.md`)

---

### /research - Research Workflow

**Purpose**: research a topic with MCP tools, write a dated research document, and file a follow-up
task

**Usage**:
```bash
/research "Next.js 15 server components best practices"
/research "Prisma query optimization for PostgreSQL time-series data"
/research "UI component from Figma: https://figma.com/design/ABC/node-id=1-2"
```

**Behavior**:
1. Checks the task store can take the follow-up task (on `files`, that `.backlog/` exists), and
   warns but continues when `docs/acf/research-protocol.md` or `docs/acf/organization.md` is missing
2. Names the document by date: `docs/research/YYYYMMDD-{topic}.md`
3. Hands the topic to research-agent
4. **MCP tool selection** (from research-protocol.md):
   - **Figma MCP**: required when you give a Figma URL or node
   - **Context7**: library documentation, API references
   - **Perplexity**: best practices, architecture, security, performance
5. Writes the research document, with a source for each claim
6. **Files a pending task** from the findings (`.backlog/pending/` on `files`, `acfw-store create`
   on other stores)

**Naming (required)**:
- Format: `docs/research/YYYYMMDD-description.md`
- Date: the current date as YYYYMMDD, with no hyphens
- Description: lowercase, hyphen-separated
- Reference: `docs/acf/organization.md` (installed by the optional acf-librarian plugin)

**Style requirements** (from `docs/acf/style/research-documents.md`):
- Direct, factual analysis (no promotional language)
- A source for every claim
- Quantified comparisons (not "faster", use "3x faster")
- Tables for comparisons (not prose)
- Code snippets ≤3 lines

**Output**: Research document (`docs/research/YYYYMMDD-topic.md`) + a pending task in the task store

---

### /whip-init - Initialize Workflow

**Purpose**: set up acf-whip in a project

**Usage**:
```bash
/whip-init
/whip-init --with-specialists   # also generate specialist agents for the detected stack
```

**Behavior**:
1. Detects the tech stack (scans package files)
2. Asks you for preferences (priority system, coverage thresholds)
3. Analyzes the repository to customize the agents
4. Creates the `.backlog/` structure (9 folders, `files` store only)
5. Installs quality gate config (`.pre-commit-config.yaml`), with a top-level exclude that keeps
   every hook out of `docs/cycles/`, `docs/acf/`, `.backlog/` and `.acfwhip/`
6. **Generates the 7 universal agents** from patterns into `.claude/agents/`, customized for the
   project, plus `devops` if you accept it
7. Generates agent manifests in `docs/agents/` (Priority 1/2/3 structure)
8. Installs the core docs the SessionStart hook would, and generates `.backlog/README.md`
9. Adds its sections to `CLAUDE.md`, creating a minimal one if there is none, and names `/whip` as
   the place to start
10. In a **new** project only, pins `ACFW_INTEGRATION_MODE=default`. It also adds `docs/cycles/`,
    `docs/acf/`, `.backlog/` and `.acfwhip/` to an existing `.prettierignore` or
    `.markdownlintignore`, so no formatter rewrites the bytes approval hashes or `/go` commits

**Output**: an initialized backlog workflow

---

### /whip-add-agents - Agent + Manifest Generator

**Purpose**: create the specialist agents a project is missing

**Usage**:
```bash
# Auto-detect
/whip-add-agents

# User-specified (PRIORITY)
/whip-add-agents --backend=go --frontend=nextjs
/whip-add-agents --backend=python --data=dagster --infrastructure=k8s
```

**Behavior**:
1. **Parses your flags**, which override auto-detection
2. **Analyzes the repository**:
   - Scans the directory structure
   - Detects tech stack indicators
   - Reads CLAUDE.md for mentions
   - Checks existing agents, so none is duplicated
   - Assesses complexity (LOC, polyglot, microservices)
3. **Studies existing conventions**:
   - Reads existing agent implementations and manifests
   - Extracts their patterns (structure, sections, formats)
4. **Generates agent files**:
   - **Implementation**: `.claude/agents/{agent}.md` (short, core instructions)
   - **Manifest**: `docs/agents/{agent}.md` (Priority 1/2/3 docs, navigation guidance, 5-10
     anti-patterns)
5. **Generates quality gates**: `docs/development/quality-gates-{stack}.md` (if missing)
6. **Updates configuration**:
   - Adds the new agents to `.backlog/README.md`
   - Updates the agent assignments in `CLAUDE.md`, if the project has one
   - Installs pre-commit hooks (if missing)

**Tech stack detection**:
- **Backend**: `go.mod` → go-engineer, `requirements.txt` → python-engineer, `package.json` +
  express/fastify → nodejs-engineer
- **Frontend**: `package.json` + next → nextjs-engineer, + react → react-engineer
- **Data**: Dagster or Airflow → data-engineer
- **Infrastructure**: `k8s/` → k8s-engineer, `docker-compose.yml` → docker-engineer, `terraform/` →
  terraform-engineer

**Output**: agent implementations, manifests, quality gates and updated config

---

## Universal Agents

`/whip-init` generates seven universal agents in every project, plus `devops` when it detects
infrastructure and you accept it. They are **generated** from patterns, not copied, and customized
with:
- stack-specific examples (Go/Python/Node.js syntax)
- the gate tools in your `.pre-commit-config.yaml`
- the coverage thresholds you chose at initialization
- your priority system (3-level, or 5-level SLA-based)
- a matrix of the agents the project has
- the infrastructure it detected (Docker, K8s, CI/CD, monitoring)

### task-engineer
- **Role**: Task decomposition (WHAT/WHY only, no HOW)
- **Authority**: Create tasks, set priorities, assign agents
- **Prohibition**: writes no implementation code
- **Style**: Enforces `task-descriptions.md` style guide

### quality-reviewer
- **Role**: Binary accept/reject decisions
- **Authority**: Accept completed work, reject with reasons
- **Prohibition**: never fixes code; it only identifies issues
- **Required**: every review ends in `accepted` or `rejected`, and the orchestrator makes the move

### lean-architect
- **Role**: System architecture design (WHAT/WHY not HOW)
- **Authority**: Design architectures, define contracts, document decisions
- **Prohibition**: No implementation code
- **Style**: Code snippets of 2-3 lines at most (interfaces only)

### retro
- **Role**: Root cause analysis when a cycle's work went wrong (dispatched by `/retro`)
- **Authority**: Root cause analysis, one-rule lessons, and proposed action items; a human approves every change to agents, workflow or quality standards
- **Method**: Five Whys root cause analysis
- **Existing projects**: a `.claude/agents/retro.md` generated before 3.5.0 still grants edit authority; the 3.5.0 CHANGELOG entry has the exact edit

### precommit
- **Role**: Pre-commit hook configuration
- **Authority**: Configure hooks, choose hook repositories, tune how fast hooks run
- **Prohibition**: Cannot modify quality standards (a /retro action item, approved by a human)

### research-agent
- **Role**: Evidence-based research
- **Authority**: Run research and write reports in `docs/research/`
- **Tools**: Perplexity for every query (required)

### workflow-architect
- **Role**: Writes the per-task child-workflow harness for each `/go` unit: fills the four marked
  regions of the locked skeleton, then stops
- **Prohibition**: Does not implement the task
- **Model**: none pinned; `/go` runs it on the session model

### devops (optional, infrastructure-aware)
- **Role**: Infrastructure, CI/CD, and deployment operations
- **Authority**: Configure Docker/K8s, set up monitoring and CI/CD pipelines, troubleshoot
- **Created when**: Docker, Kubernetes, or a CI/CD platform is detected (you can skip it)
- **Customization**: Generated with detected orchestration (docker-compose/kubernetes), CI tool (github-actions/gitlab-ci), monitoring stack (prometheus-grafana/datadog), cloud provider (gke/eks/aks)
- **Prohibition**: Cannot design K8s manifests (delegates to k8s-engineer if exists)
- **Manifest**: built from what it finds in `docs/operations/` (Priority 1/2/3 docs)

---

## Agent Manifest System

### Purpose

A manifest (`docs/agents/{agent}.md`) tells an agent which docs to read first, so it reads the few
that matter for a task instead of everything. The patterns cite a **58-74% token reduction**;
nothing in the plugin measures it.

### Structure

Every manifest has:

1. **Agent Identity**: Role, tech focus, scope, out of scope
2. **Priority 1: MUST READ** (5-8 docs, used in 80%+ tasks)
3. **Priority 2: SHOULD READ** (10-15 docs, used in 40-80% tasks)
4. **Priority 3: REFERENCE** (situational, <40% tasks)
5. **Navigation Guidance**: Task-specific reading paths
6. **Scope Boundaries**: IS/NOT responsible for
7. **Quality Gates**: Stack-specific commands
8. **Common Workflows**: 5 standard patterns
9. **Integration Points**: Handoffs to/from other agents
10. **Anti-Patterns**: 5-10 common mistakes, each with the reason (the backend, frontend, data and
    infrastructure patterns ship 10)
11. **Quick Reference**: Copy-paste commands, evidence templates
12. **Success Metrics**: First-pass acceptance rate, doc usage

### Example Priority 1 Docs

```markdown
## Priority 1: MUST READ (Every Task)

1. `.backlog/README.md` - Workflow, priorities, evidence
2. `docs/acf/style/task-descriptions.md` - Task requirements format
3. `docs/acf/backlog/task-template.md` - Task file structure
4. `docs/development/quality-gates-go.md` - Quality requirements
5. `docs/architecture/service-architecture.md` - System design
```

### Navigation Guidance

```markdown
**Task Type: New API Endpoint**
**Reading Path**:
1. Priority 1: All docs
2. Priority 2: API contracts, error handling, authentication
3. Reference: Security (if auth-related), monitoring (if critical)
```

---

## Quality Gates

### No bypasses

Never:
- ❌ `git commit --no-verify`
- ❌ `SKIP={hook-name}`
- ❌ Lowering coverage thresholds
- ❌ Commenting out failing tests

A local hook can be skipped, so have your CI re-run every gate. Inside `/go`, the per-task harness
tells the implementer to fix the cause without weakening or deleting a test, and its diff reviewer
looks for removed or weakened tests.

### Stack-Specific Commands

**Go**:
```bash
golangci-lint run ./...
go test ./... -v -race -cover
go build ./...
go mod tidy && git diff --exit-code go.mod go.sum
```

**Python**:
```bash
ruff check .
ruff format . --check
mypy . --strict
pytest --cov --cov-report=term
```

**Node.js/TypeScript**:
```bash
npm run lint
npm run typecheck
npm test --coverage
npm run build
```

### Coverage Thresholds

| Code Type | Minimum Coverage |
|-----------|------------------|
| API endpoints | 90-95% |
| Core logic | 90% |
| Services | 85-90% |
| Utilities | 85% |
| UI components | 80% |

These rows match the default answer (80%) to `/whip-init`'s coverage question. Answering 60% or 95%
moves them down or up.

### Failure Protocol

- **Red gate inside a worktree**: the default per-task harness runs your gates at most twice, with
  one fix round after each failure, then sends the diff to a fresh reviewer. Fix causes; never
  weaken or delete a test. None of this needs you.
- **Rejected in review**: the task goes back to pending with its rejection counted. The third
  rejection blocks it, and a task its own specialist blocks a third time stays blocked (`/go` args
  `maxReject` / `maxBlock`, default 3). The counters are lifetime counters on every store.
- **Blocked at the cap**: this is parked work, and it does need you. In a planned cycle `/whip`
  shows a card with the exact reply. `/whip-move <task> pending` buys exactly one more attempt; the
  usual fix is to archive the task and plan the work again.
- **Learning from it**: when a planned cycle ends with a reworked or stuck task, or an unmet
  deliverable, `/retro` finds the root cause and proposes the fix as an action item you approve.
  For work done without a plan: `/retro --force <task>...`.

---

## Task Description Style Guide

The full guide is `docs/acf/style/task-descriptions.md`. The rules in short:

**Binary language**:
- ✅ "API validates token" NOT "improve validation"
- ✅ "Returns 401 for invalid credentials"
- ❌ "Enhance authentication system"

**WHAT/WHY only, never HOW**:
- ✅ WHAT: "POST /api/v1/auth/login endpoint"
- ✅ WHY: "Users need to authenticate"
- ✅ CONSTRAINTS: "Response < 200ms"
- ❌ HOW: "Use bcrypt for hashing, JWT for tokens"

**Code snippet limits**:
- ✅ ALLOWED (2-3 lines): `POST /api/v1/auth`, `{"token": "jwt"}`, `Returns 400 for missing fields`
- ❌ PROHIBITED: Function implementations, algorithms, config files

**Banned words**:
- comprehensive, systematic, significant, substantial, robust, elegant
- achievement, progress, improvement (unless the work is 100% complete)
- enhance, optimize, streamline: say what changes instead ("query drops from 2s to 200ms")

### Golden Rule

If a specialist agent can read your task and say **"I know WHAT to build and WHY"**, you've succeeded.

If they say **"I just need to copy-paste this code"**, you've failed.

---

## Configuration

### Runtime config keys

Committed config lives in `.acfwhip/config` (or the legacy `.backlog/.acfw-config`; `acfw-store info`
reports which file is active as `configFile`). Every key is also settable as an env var.

| Key | Default | Meaning |
|-----|---------|---------|
| `ACFW_STORE` | `files` | Task-store backend: `files`, `beads`, `multica`, `linear`, or a drop-in adapter name. Env wins over config. |
| `ACFW_INTEGRATION_MODE` | unset (`/whip-init` pins `default` in a new project) | `override` = `/go` stops at accepted and you integrate (PR per group); `default` = LP-CAS folds accepted work into the local trunk. Unset = decided per run from `CLAUDE.md`, and `/whip` shows a card asking you to pin it once a planned cycle's task is accepted with no ledger marker. Env wins over config. An unrecognized value is FATAL. |
| `ACFW_TRUNK_BRANCH` | unset | The branch plan events (`docs(plan): ...` commits) may land on. Unset = the branch each cycle was created on; to move a cycle to another branch, `rm .acfwhip/run/cycle/<ID>/branch`. `acfw-cycle` refuses (exit 5) on any other branch. Env wins over config. |
| `ACFW_INPROGRESS_TIMEOUT_HOURS` | `8` | Hours before an in-progress task is flagged stale / timed out to blocked. Env wins over config. |
| `ACFW_WORKTREE_DIR` | `.worktree` | Directory acf-whip owns for task worktrees. **Config wins over env.** Change only on a fresh backlog. |
| `ACFW_BRANCH_PREFIX` | `worktree` | Branch namespace acf-whip owns (`<prefix>/<slug>`). **Config wins over env.** Change only on a fresh backlog. |
| `ACFW_GATE_CMD` | empty (skip) | Union quality gate, run by the integrator on the candidate tree before it lands. |
| `ACFW_PARSE_SANITY_CMD` | empty (skip) | Cheap parse/lint check, run before the heavy gate; failure is a mechanism fault, not a quality reject. |

Values are read literally: surrounding quotes and trailing whitespace are stripped, a trailing
`# comment` is **not**. Keep comments on their own line.

### SessionStart Hook

What the hook does on every session start:

```python
# Location: hooks/handlers/session-start.py

def main():
    # 1. Install each doc when missing; refresh an unedited copy (by content digest);
    #    report an edited copy as behind, never overwrite it
    sync("task-descriptions.md", "docs/acf/style/")
    sync("task-template.md", "docs/acf/backlog/")
    sync("workflow.md", "docs/acf/backlog/")
    sync("recovery-runbook.md", "docs/acf/backlog/")

    # 2. Warn if .backlog/ is missing (README.md is not auto-generated)

    # 3. Inject style guide into session context
    return hookSpecificOutput with style guide enforcement
```

`.backlog/README.md` is created once by `/whip-init` and never rewritten wholesale afterwards: not
by the SessionStart hook, and not by `/whip-add-agents`, which updates only its agent-roster line in
place. Your gate commands, coverage thresholds and evidence rules are yours, and they survive every
re-run.

### What it writes in your repo

| Path | Written by | In git? |
|---|---|---|
| `.backlog/<state>/*.md` | `/task`, `/go`, `/whip-move` (`files` store only) | committed on trunk |
| `.acfwhip/config` | `/whip-init`, you | committed |
| `.acfwhip/integrated/` | LP-CAS: one ledger marker per integrated task | committed, in the same commit as the change |
| `.acfwhip/adapters/` | you: drop-in store adapters and spec-tool drivers | committed |
| `.acfwhip/spec-tools/<name>` | `/whip --tools add`, or you | committed; the commit is the team's consent to send plans where it says |
| `.acfwhip/run/` | run state: the focus, locks, cycle run state, spec-tool results, workbench state | gitignored |
| `.worktree/<slug>/`, branches `worktree/<slug>` | `/go` | gitignored; reaped after integration |
| `docs/cycles/YYYYMMDD-<slug>/` | `plan.md`: you (drafted by `/whip`, or copied on import); `record.md`: only `acfw-cycle`; `retro.md`: `/retro` | untracked until approval, then `docs(plan): ...` commits by `acfw-cycle` |
| `docs/acf/lessons/<slug>.md` | `/retro` (at most 3 per retro, no frontmatter, one `**Rule**:` line) | committed by `acfw-cycle close` or `note`; after a plan-less retro you commit them; you retire one with `git rm` |
| `docs/retrospectives/YYYYMMDD-<slug>.md` | `/retro --force [<task>...]` (no plan) | you commit it |
| `docs/acf/style/`, `docs/acf/backlog/` | SessionStart hook | you commit them; unedited copies refresh themselves |
| `.claude/agents/`, `docs/agents/`, `.backlog/README.md`, a `CLAUDE.md` section | `/whip-init`, `/whip-add-agents` | you commit them |
| `.gitignore`, `.pre-commit-config.yaml`, `.prettierignore`, `.markdownlintignore` entries | `/whip-init` (keeps formatters out of `docs/cycles/`, whose bytes approval hashes, and out of `docs/acf/`, `.backlog/` and `.acfwhip/`) | you commit them |

`/go` never pushes. What leaves your machine: task state, to a `multica` server or to Linear when
you use those stores, and plan text, to the host a committed spec-tool declaration names.

---

## Examples

### Example 1: Backend API Development

```bash
# 1. Initialize
/whip-init

# 2. Generate Go backend agent
/whip-add-agents --backend=go

# 3. Decompose scope
/task "Implement REST API for user management with CRUD operations"

# Output: Creates 3 tasks
# - backend-001-user-api-endpoints.md (POST/GET/PUT/DELETE)
# - backend-002-user-validation-middleware.md (input validation)
# - backend-003-user-integration-tests.md (API tests)

# 4. Execute backlog
/go

# Output: Loops through:
# Iteration 1: Start all 3 tasks (parallel)
# Iteration 2: Complete tasks, trigger reviews
# Iteration 3: All accepted, exit 100% complete
```

### Example 2: Full-Stack Feature

```bash
# 1. Generate both backend and frontend agents
/whip-add-agents --backend=go --frontend=react

# 2. Decompose full-stack scope
/task "Add user profile page with avatar upload. Figma: https://figma.com/design/ABC/App?node-id=1-2"

# Output: Creates tasks for both stacks
# - backend-001-profile-api.md (go-engineer)
# - backend-002-avatar-upload-s3.md (go-engineer)
# - frontend-001-profile-page.md (react-engineer)

# 3. Execute (cross-stack coordination via dependencies)
/go
```

### Example 3: A Planned Cycle Where a Task Fails Review

```bash
# 1. A risky goal gets a plan and an approval card
/whip "Charge the owner when a seat is added"
yes          # approves those exact bytes and starts /task --plan in the background

# 2. Build the plan's tasks (the focus now holds exactly them)
/go
# feature-001 is rejected three times (coverage 75% vs 85% required), so /go blocks it

# 3. Where are we?
/whip
# D2 shows ✗, a NEED YOU card names feature-001 with the exact reply,
# and once nothing else can run, NEXT is /retro

# 4. Close the cycle and learn from it
/retro
# A trigger fired, so the retro agent writes:
# - docs/cycles/<ID>/retro.md: the root cause (the coverage bar was never in the task)
# - at most 3 lessons in docs/acf/lessons/, which the next /task planners read
# - a retro-actions cycle proposing the fix; it becomes work only after you say yes on its card
```

---

## Troubleshooting

### Tasks Stuck in in-review

**Problem**: a task stays in `in-review` after its review ran

**Solution** (the `ls` applies to the `files` store):
```bash
# Manually check in-review tasks
ls .backlog/in-review/

# Force re-review (the validated writer keeps Status and the transition log in sync)
/whip-move <task> completed
/go
```

**Prevention**: `/whip-doctor` reports a task that lingers in review

### No Progress for 3 Iterations

**Problem**: tasks are blocked, or dependencies form a cycle

**Solution**:
```bash
# Check blocked tasks
ls .backlog/blocked/

# Read blocker reports
cat .backlog/blocked/*.md

# In a planned cycle, /whip names the ROOT blocker and the exact reply
/whip

# Find out why (work done without a plan)
/retro --force <task>...
```

### Style Guide Violations

**Problem**: task-engineer writes tasks with implementation details

**Solution**:
- The SessionStart hook puts the style guide in every session's context
- `/task` checks every task against the guide before spawning agents
- If violations continue, run `/retro --force <task>...`: it proposes a [guide] action item for the
  task-engineer file, which you approve

### Agent Generation Errors

**Problem**: `/whip-add-agents` can't detect the tech stack

**Solution**:
```bash
# Use explicit flags
/whip-add-agents --backend=go --frontend=react

# Or check project structure
ls -la  # Verify go.mod, package.json, etc. exist
```

---

## Architecture

### Plugin Structure

```
acf-whip/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── skills/                      # 10 commands you type, 2 internal skills, shared lib
│   ├── whip/SKILL.md            # /whip: the front door of the cycle
│   ├── task/SKILL.md            # /task, /task --plan
│   ├── go/SKILL.md              # /go
│   ├── retro/SKILL.md           # /retro
│   ├── research/SKILL.md
│   ├── whip-init/SKILL.md
│   ├── whip-add-agents/SKILL.md
│   ├── whip-doctor/             # /whip-doctor (SKILL.md + bin/)
│   ├── whip-focus/SKILL.md
│   ├── whip-move/               # /whip-move (SKILL.md + bin/)
│   ├── clean-checkout-before-task/   # internal: run by every code-mutating agent
│   ├── integrate-lpcas/         # internal: run by /go's integrator
│   └── lib/                     # acfw-cycle, acfw-spec, acfw-store, acfw-focus, shared shell libs
├── workflows/                   # whip-go / whip-task: the engines behind /go and /task
├── adapters/                    # task-store adapters (files, beads, multica, linear) + CONTRACT.md
├── spec-tools/                  # spec-tool protocol, README, gaptrap and dir drivers, examples
├── tests/                       # offline suites; run-all.sh runs them
├── hooks/
│   ├── hooks.json
│   └── handlers/
│       └── session-start.py     # Installs and refreshes the docs below
└── content/                      # Templates and patterns
    ├── acf/
    │   └── research-protocol.md  # Research MCP tool usage
    ├── style/
    │   ├── task-descriptions.md
    │   └── research-documents.md # Research documentation style
    ├── backlog/
    │   ├── task-template.md
    │   ├── workflow.md
    │   ├── recovery-runbook.md
    │   ├── plan-template.md      # a cycle's plan.md
    │   ├── record-template.md    # a cycle's record.md
    │   └── README.sample.md
    ├── quality-gates/            # stack docs
    ├── pre-commit-configs/       # 3 stack configs
    └── agent-patterns/           # Agent generation patterns
        ├── universal/            # 6 universal agent patterns
        │   ├── task-engineer-pattern.md
        │   ├── quality-reviewer-pattern.md
        │   ├── lean-architect-pattern.md
        │   ├── precommit-pattern.md
        │   ├── retro-pattern.md
        │   └── research-agent-pattern.md
        ├── specialist/           # 4 specialist agent patterns
        │   ├── backend-agent-pattern.md
        │   ├── frontend-agent-pattern.md
        │   ├── data-agent-pattern.md
        │   └── infrastructure-agent-pattern.md
        └── manifests/            # 5 manifest generation patterns
            ├── universal-manifest-pattern.md
            ├── backend-manifest-pattern.md
            ├── frontend-manifest-pattern.md
            ├── data-manifest-pattern.md
            └── infrastructure-manifest-pattern.md
```

### Command Flow

```
User Request
    ↓
/whip "<goal>" → small: NEXT /task "<goal>" · risky: plan.md → approval card → yes
    ↓
/task (or /task --plan) → Read style guide + lessons → Decompose → Validate → Record → Exit
    ↓
.backlog/pending/ (tasks created; in a cycle, also record.md ## Tasks and your focus)
    ↓
/go → Loop: Scan states → Process transitions → Spawn agents → Check completion
    ↓
quality-reviewer → Accept/Reject → Move to terminal state → LP-CAS onto local trunk
    ↓
/whip → coverage per deliverable → NEXT /retro
    ↓
/retro → Root causes → Lessons + action items you approve
```

### Agent Generation Flow

```
/whip-add-agents
    ↓
Parse user args (priority) → Repository analysis → Study existing conventions
    ↓
For each missing agent:
    ↓
Generate implementation (.claude/agents/{agent}.md)
    ↓
Generate manifest (docs/agents/{agent}.md) with Priority 1/2/3
    ↓
Generate quality gates (docs/development/quality-gates-{stack}.md)
    ↓
Update .backlog/README.md with new agents
    ↓
Update CLAUDE.md (if exists)
```

---

## Contributing

### Pattern Extraction

To contribute a pattern:

1. Start from an agent or manifest that has worked in production
2. Strip the project-specific details
3. Replace them with template variables (`{backend_stack}`, `{project_name}`), as the existing
   patterns do
4. Add examples for more than one stack
5. Check that the template reads clearly
6. Open a PR with the pattern and a usage example

### Agent Templates

To add an agent pattern:

1. Create `{type}-agent-pattern.md` in `content/agent-patterns/`
2. Create `{type}-manifest-pattern.md` with Priority 1/2/3 structure
3. Teach `/whip-add-agents` to recognize the new type
4. Generate an agent from the pattern to test it
5. Open a PR with usage examples

---

## License

Proprietary License - Copyright 2025 Fibonacci Seven, LLC. See LICENSE file in repository root.

---

## Acknowledgments

Extracted from production ACF implementations.

---

## Support

Issues: https://github.com/fib7/acf-tools/issues

Documentation: https://github.com/fib7/acf-tools/tree/main/docs

---

**Version**: see `.claude-plugin/plugin.json`; what changed in each release: `CHANGELOG.md`
**Last Updated**: 2026-09-29
