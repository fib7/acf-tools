# ACF Whip - Hostile Workflow Enforcer

**Zero tolerance backlog automation from decomposition to acceptance with aggressive quality gates.**

**ACF (Agentic Continuous Flow)** is software development where humans govern intelligent agent swarms rather than write code directly. Whip automates the complete task lifecycle with zero tolerance for incomplete work.

Standalone ACF plugin that implements the complete cycle: plan approval, task decomposition, continuous execution, quality review, deliverable coverage, and retrospectives. Enforces strict task description style and generates specialist agents on demand.

## Overview

ACF Whip is a hostile workflow enforcer that automates the entire task lifecycle:

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

**Philosophy**: Zero tolerance for incomplete work. Binary outcomes. Evidence required. No shortcuts.

The one command to remember is `/whip`. With no argument it prints where you are, what needs you,
and the one command to run next, derived from git and the task store on every call.

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

**Two routes.** `/whip "<goal>"` picks one and says why. Small work is the default: it prints
`NEXT /task "<goal>"` and runs exactly as before 3.5.0, with no plan. A goal that touches data, a
schema or a migration; auth, secrets, payments or personal data; a breaking change to a public
contract; three or more modules; or a new user flow gets a plan first, and so does
`/whip plan <goal>`. The rubric lives once, in [`skills/whip/SKILL.md`](skills/whip/SKILL.md).

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

Rules the engine enforces, so you do not have to:

- **Approval binds bytes.** It holds only while `record.md`'s `Approved Content`, the newest
  `approved` row and the hash of `plan.md` agree at HEAD. Edit the plan after "yes" and `/whip`
  says "amended since approval"; the approved text keeps building, the edit never builds unapproved.
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
- **A decomposition lock** is evidence that a `/task --plan` started, not proof it still runs. It
  expires after 30 minutes, and the card prints its age and the one `rm` that clears it sooner.

---

## Spec tools (reviewers and workbenches)

A spec tool reviews a plan before you approve it, reviews the tasks `/task` writes (free text or
`--plan`), or lets you edit the plan somewhere else and merge it back. You plug one in with one committed file
in `.acfwhip/spec-tools/`; acf-whip itself names no tool. The smallest is a grep:

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

Hook points: before every approval card (`at=plan`), inside `/task` (free text or `--plan`) before
tasks are written (`at=task`; a task a `block` tool still rejects is held in draft), at approval
(`policy=block` needs GO on those exact bytes, or your reply `yes, override <tool>`), and on
`/whip --push` / `--pull` for a workbench. **Never in `/go`**: the spec is frozen at approval, and a false positive there would
cost a task one of its three lives. A tool that cannot run never blocks. Full guide:
[`spec-tools/README.md`](spec-tools/README.md); protocol: [`spec-tools/CONTRACT.md`](spec-tools/CONTRACT.md).

---

## Features

### 🎯 A bare `/go` runs YOUR tasks (3.4.0)

`/task` points this checkout's **focus** at the tasks it just created, and a bare `/go` runs the
focus. The ordinary path — plan → `/task` → `/go` — needs no arguments and still runs only your own
work. `/whip-focus` manages the list by hand; it is gitignored per-checkout state, so two people on
one board have two focuses.

```
/go                              your focus
/go --all                        the whole backlog, explicitly
/go api-014-token MUL-4821       exactly these (stems, ids, native ids, unique prefixes)
/go frontend tasks only          a natural-language filter, resolved and confirmed before launch
/whip-move <task> draft          pause it   (archive = cancel) — on every backend
```

With no focus set, a bare `/go` drains the backlog on the `files` store (unchanged) and **refuses**
on a shared API-backed board, naming the three ways forward. One person's bare `/go` should never be
everyone's.

### 📦 The snapshot is narrowed in the store, and verified on arrival (3.4.0)

`/go`'s scan agent relays the store walk into the orchestrator. On a large board that relay could come
back short — valid JSON, fewer tasks — and the run would report the ids it was given as nonexistent.
Now `--only` emits just the **closure** of the named tasks (seeds plus their unmet dependencies), a
real `--digest` collapses finished work on **every** backend rather than only `files`, and every
snapshot carries a `relay` header the orchestrator recomputes. A short relay stops the run as
`relay-truncated` with the honest remedy; it is never reported as a missing id.

### 🩹 One malformed card no longer blocks the team (3.4.0)

An integrity FATAL used to stop the run. Now only **repo-scoped** ones do (detached HEAD, a worktree
on the wrong branch, an unreadable store). A **task-scoped** finding holds out that one task — never
dispatched, never integrated, still gating its dependents — and the rest of the board runs. The run
reports `partial`, never `complete`, and `heldOut[]` names what it refused to touch and why.

### 💸 Agents route by tier, and the run says what it spent (3.4.0)

Fixed-command shell runners (scan, writers, integrate, doctor) run on a cheap model; specialists and
reviewers run on the model the project declared in `.claude/agents/<name>.md`; the architect and the
conflict resolver stay on the session model. Pin it once per repo (`ACFW_MODEL_SHELL`, `_JUDGE`,
`_AUTHOR`). Every run reports `models` and `agentsByTier`.

### 🔥 Hostile Task Style Enforcement

**MANDATORY compliance** with `docs/acf/style/task-descriptions.md`:
- Binary language only ("API validates token" NOT "improve validation")
- WHAT/WHY specification, NEVER HOW (specialists decide implementation)
- Max 2-3 line code snippets (signatures only, NO implementations)
- Banned words: comprehensive, robust, elegant, enhance, optimize

**Violations = Immediate rejection**

### ⚡ Workflow-native orchestration (2.0.0)

When dynamic workflows are available (Claude Code ≥ 2.1.154), `/task` and `/go` run as **dynamic workflows** (`workflows/whip-task.workflow.js`, `workflows/whip-go.workflow.js`):

- **Flat context**: the loop, slug partition, dependency gate, and topological integration order run inside a deterministic script — intermediate state lives in script variables, not Claude's context — so context stays flat no matter how many tasks/iterations. (This is the fix for the old "stop work to dump history" problem.)
- **Schema-enforced worktree slugs**: `/task`'s planner cannot omit a slug; a JS validation gate (kebab-case, slug ≠ id, acyclic deps, unique ids) runs before any file is written; the doctor REPAIRS a missing slug on an active task by deriving one from the id, and FATALs only when two ids derive the same slug (`duplicate-derived-slug`) or there is no id to derive one from.
- **Integrity-gated**: the doctor runs as a hard gate at startup and a recheck every iteration.
- **Automatic fallback**: if dynamic workflows are off, both commands fall back to the legacy single-context loop (same behavior, byte-compatible).

### 🔌 Pluggable task stores (3.1.0)

Task state lives behind an **executable adapter contract** (`adapters/CONTRACT.md`, contract v1).
The `acfw-store` dispatcher resolves the configured backend and routes every read/write —
`snapshot`, `transition`, `read`, `create`, `doctor` — to its adapter:

| Backend | State lives in | Select with |
|---|---|---|
| `files` (default) | `.backlog/<state>/*.md` committed on trunk | nothing — zero-config default |
| `beads` | [beads](https://github.com/gastownhall/beads) (`bd`, embedded Dolt) | `ACFW_STORE=beads` in `.acfwhip/config` |
| `multica` | [multica](https://github.com/multica-ai/multica) server | `ACFW_STORE=multica` + `MULTICA_*` env |
| `linear` | [Linear](https://linear.app) issues (attachment metadata) | `ACFW_STORE=linear` + `LINEAR_API_KEY`/`ACFW_LINEAR_TEAM` env |

- **Zero migration**: existing `.backlog/` projects run unchanged; `files` behavior is byte-identical to 3.0.x.
- **Third-party backends without forking**: drop one executable at `.acfwhip/adapters/acfw-store-<name>`, set `ACFW_STORE=<name>`, pass the conformance test (`ADAPTER=<path> bash tests/phase9-store-conformance.test.sh`). Contract, discovery order, JSON shapes and exit codes: `adapters/CONTRACT.md`; architecture, dispatcher mechanics, and an authoring walkthrough: `adapters/README.md`.
- **What never moves into a backend**: the LP-CAS integration ledger (`.acfwhip/integrated/` in the git tree) — integration truth stays git-native on every store.

### 🧬 Per-task child workflows (3.2.0)

Every dispatched unit runs as its **own nested workflow**, not a single `agent()` call. A
**workflow-architect** authors that harness for the specific task by filling four marked regions of a
locked, byte-diffed skeleton (`skills/lib/child-skeleton.js.tmpl`); a 20-check validator rejects a
defective harness *before* any child agent spawns. The default harness is deliberately shallow —
checkout → implement → bounded gate loop → adversarial diff review → verify — holding the only three
mechanisms a script structurally buys over one strong agent: a schema-*observed* advance condition, a
fresh-context reviewer of the diff, and a durable stage ledger that survives the script throwing.

- **Escalation is a policy, not a guarantee**: the runtime caps total agents per run, so `/go`
  degrades FULL → LEAN → DIRECT → CLOSE back to verbatim 3.1.0 single-agent dispatch, and the report
  says which one you got (`escalation{}`, `agentsUsed`/`agentCap`).
- **Tunable**: `escalate` (default on — set false to revert to 3.1.0 dispatch; reach for this first
  if a run looks hung), `escalateReview` (default **off**, the only subtractive seam), `maxAmend`,
  `agentBudget`, `agentCap`, `shellModel`.

### 🎯 Scoped runs (3.2.3)

`/go` is no longer all-or-nothing. `/go api-014-token-refresh ui-021-login-form` runs exactly those tasks plus their
unmet dependencies; `/go frontend tasks only` or `/go bugfixes` resolves a natural-language filter
against the backlog once, before launch, and confirms the matched list with you. Nothing outside the
scope is dispatched, transitioned or integrated — which is what makes `/go` usable on a backlog a
whole team shares. See `/go` under Commands Reference.

### 🧪 Every backend under the contract suite, offline (3.3.0)

`tests/phase9-store-conformance.test.sh` is the contract's executable spec, and it used to run only
against the default `files` adapter — the three others skipped unless a live server was reachable, and
the runner counted a skip as a pass. So the API backends were green by absence, and a whole class of
defect was invisible until a user hit it: a snapshot field answered for one task state, an inert card
raised to a gate FATAL, a network timeout written into a rejection counter.

The multica suite now drives the real adapter through an offline fake of its CLI — injected at the
`ACFW_MULTICA_BIN` seam every call already funnels through — and runs the frozen spec with no server,
no credentials and no skip, with fault injection so the transient paths are exercised deliberately.
Writing an adapter for your own backend? `ADAPTER=<path> bash tests/phase9-store-conformance.test.sh`
is the whole acceptance criterion, and `tests/phase9-adapter-multica.test.sh` is a worked example of
testing one without a backend to talk to.

### 🔁 Installed docs that stay current (3.3.0)

The plugin installs a few documents into your project (`docs/acf/backlog/workflow.md` and friends).
Those used to be copied once and never touched again, so a correction made here never reached a
project that already had the file. Now an **unedited** copy refreshes itself — recognised by content,
so it works on projects that predate the mechanism — and an **edited** one is never overwritten: the
session tells you it is behind and leaves the merge to you.

### 🔄 Continuous Backlog Execution

`/go` loops until 100% complete — or, when scoped, until every task in the scope is terminal:
- Processes ALL state transitions each iteration
- Parallel agent spawning for independent tasks (one specialist per worktree slug)
- Dependency-gated dispatch (same-slug needs accepted; cross-slug needs integrated)
- Autonomous integration into local trunk with specialist-driven conflict resolution
- Exits only when all tasks in terminal states (accepted/blocked)
- No manual intervention needed

**Protected trunk / PR-per-task teams**: integration is automatic and **local** by default — accepted
work is cherry-picked onto your local trunk, nothing is pushed and no PR is opened. If merges must go
through review, pin the mode so it never depends on a per-run judgement:

Set it in the config file your repo already has, and change the existing line if there is one
(`/whip-init` pins `default` in new projects): `.backlog/.acfw-config` on the files store,
`.acfwhip/config` on the others. acf-whip reads only the first of the two it finds, so never create
`.acfwhip/config` next to an existing `.backlog/.acfw-config`: it would hide every key in the old
file.

```bash
ACFW_INTEGRATION_MODE=override    # committed; travels with the repo
```

`/go` then stops at `accepted`, writes no ledger marker, and keeps each `worktree/<slug>` branch alive
for you to push and open PRs from; dependency ordering becomes yours. It does not push or call `gh` —
that stays your call. Left unpinned, `/go` decides each run by reading `CLAUDE.md`. Note `.backlog/`
state transitions are committed on trunk in **both** modes; use a non-files task store (below) if
trunk must stay free of bookkeeping commits. Details: `skills/go/SKILL.md` § Integration mode.

### 🩺 Backlog Integrity Doctor

`/whip-doctor [--fix]` is the integrity battery (~20 invariants across FATAL/REPAIRABLE/WARN): status-vs-folder mismatch, missing/empty worktree slug, unknown agent, dangling/cyclic deps, cross-slug dependent dispatched before integration, orphaned worktrees, stale in-progress, and more. It runs automatically as a `/go` startup gate and per-iteration recheck, and at `/task` create-time.

### 📦 Worktree Env Hydration

A committed `.worktreeinclude` manifest lists git-ignored files (`.env`, `node_modules`, `.venv`, local config) to copy/symlink into each fresh `.worktree/<slug>` so specialists run a full dev/test sandbox. Allowlist-only with a hard secret denylist (refuses to symlink `.env*`/`*.pem`/`*.key`/`id_*`/`credentials*`/`*.p12`, requires every entry to be git-ignored, treats a tracked path as an error).

### 🤖 Agent + Manifest Generator

`/whip-add-agents` creates specialist agents on demand:
- **Analyzes repository**: Tech stack detection, complexity assessment
- **Creates TWO files per agent**:
  - `.claude/agents/{agent}.md` (implementation, core instructions)
  - `docs/agents/{agent}.md` (manifest with Priority 1/2/3 docs, 58-74% token reduction)
- **Generates quality gates**: Stack-specific documentation if missing
- **Updates configuration**: `.backlog/README.md`, `CLAUDE.md`
- **User args override auto-detection**: `--backend=go --frontend=react`

### 📋 State Machine

User-specified custom flow:

```
pending → in-progress → completed → in-review → [accepted | rejected]
            ↓                                          ↓
         blocked                                    pending (retry)
```

**Terminal states**: `accepted` (success), `blocked` (failure after 3 retries or unresolvable)

### 🪝 SessionStart Hook

**Passive documentation setup** (runs automatically on every session):
- Installs the plugin-owned documents it does not find: `task-descriptions.md` into
  `docs/acf/style/`, and `task-template.md`, `workflow.md` and `recovery-runbook.md` into
  `docs/acf/backlog/`
- **Refreshes** a copy it already installed when that copy is unedited — recognised by content
  digest (`content/.digests.json`), not by a version stamp the copy may predate. An edited copy is
  never overwritten; it is reported as behind so you can merge what you want
- Injects style guide into session context for enforcement

⚠️ **SessionStart hook does NOT create `.backlog/` structure or install agents.** Run `/whip-init` for complete initialization.

### 🚀 Pure Delegation Enforcement

`/whip-init` adds **Pure Delegation Architecture** section to `CLAUDE.md` (if exists):
- **CRITICAL RULE**: General-purpose agent CANNOT modify code directly
- **Orchestration ONLY**: Task decomposition, coordination, quality gates
- **Agent Matrix**: Up-to-date table of all agents with specializations
- **Delegation Protocol**: 5-step process ensuring specialists handle implementation
- **Enforcement**: Pre-tool-use hook validates (conceptual - not yet implemented)
- **Result**: 3x+ speedup through parallel specialist execution

**Matrix Example**:
| Domain | Agent | Responsibilities |
|--------|-------|------------------|
| Core | task-engineer | Task decomposition (WHAT/WHY only) |
| Backend | go-engineer | Go implementation |
| Infrastructure | devops | Docker, K8s, CI/CD, monitoring |

### 📚 docs/README.md Support

If your project has a `docs/README.md` file, acf-whip agents will read it to discover documentation instead of blind directory scanning.

**How it works**:
- `/whip-init` checks for `docs/README.md`
- If exists: Agents read it to understand what documentation is available
- If missing: Agents scan standard directories (`docs/architecture/`, `docs/operations/`, etc.)

**Benefits**:
- Agents discover ALL documentation (not just standard directories)
- You control what's documented and prioritized
- Natural language index (no special format required)

**Simple example** `docs/README.md`:
```markdown
# Project Documentation

## Core
- [Architecture](./architecture/) - System design
- [Quality Gates](./development/quality-gates-go.md) - Go quality standards

## Guides
- [API Development](./guides/api-development.md) - Building APIs
```

**Template**: See `content/templates/docs-readme-template.md` for a starting point.

### 🔍 Gap Analysis on Re-Init

Running `/whip-init` on existing project performs **non-destructive gap detection**:
- **Checks**: Universal agents, manifests, core docs, quality gates, CLAUDE.md sections
- **Reports**: Missing artifacts with actionable recommendations
- **Never overwrites**: Existing files preserved, gaps highlighted
- **Example output**:
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
# ACF Task Description Style Guide (Enforcement Active)

The following style guide is MANDATORY for all task descriptions...
```

This confirms SessionStart hook is active.

**Debug if not working:**
```bash
# Enable debug mode to see plugin loading
claude --debug

# Verify plugin structure
cd /path/to/acf-tools/acf-whip
claude plugin validate .
```

---

## Quick Start

⚠️ **REQUIRED FIRST STEP**: You MUST run `/whip-init` after plugin installation to create the `.backlog/` structure, install agents, and configure quality gates. The SessionStart hook alone does NOT perform complete initialization.

### 1. Initialize Backlog Workflow

```bash
/whip-init
```

**What it does**:
- Detects tech stack (Go, Python, Node.js, React, Next.js, K8s, Docker, CI/CD, etc.)
- Detects infrastructure (Docker, Kubernetes, GitHub Actions, monitoring)
- Creates `.backlog/` structure (9 state folders)
- **Generates 6-7 universal agents** to `.claude/agents/` (customized from patterns, devops optional)
- Configures quality gates (`.pre-commit-config.yaml`)
- Generates `.backlog/README.md`
- **Deep manifest customization**: Analyzes existing `docs/` for Priority 1/2/3 references
- **CLAUDE.md Pure Delegation enforcement**: Adds delegation rules + agent matrix (if CLAUDE.md exists)
- **Gap analysis**: Non-destructive detection of missing artifacts on re-init

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
- Analyzes repository structure
- Detects missing specialist agents
- Creates `.claude/agents/{agent}.md` (implementation)
- Creates `docs/agents/{agent}.md` (manifest with Priority 1/2/3 docs)
- Generates quality gate docs (if missing)
- Updates `.backlog/README.md` with new agents

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
- Reads `docs/acf/style/task-descriptions.md` (style enforcement)
- Minimal research (Perplexity, Context7, Figma if applicable)
- Decomposes scope into atomic tasks (WHAT/WHY only)
- Validates against style guide
- Spawns task-engineer agents in parallel
- Creates tasks in `.backlog/pending/`

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

**What it does**:
- Loops until 100% tasks in terminal states
- Each iteration:
  1. Quality gate auto-fix
  2. Scan ALL states
  3. Process ALL transitions
  4. Spawn agents in parallel
  5. Check completion
- Exits when all tasks accepted/blocked OR intervention needed

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

**What it does**:
- A clean cycle closes with one script call and zero agents
- When a task was reworked or stuck, or a deliverable is not met, the retro agent finds root causes (Five Whys) and writes docs/cycles/<ID>/retro.md, at most 3 one-rule lessons in docs/acf/lessons/, and a retro-actions cycle you approve like any plan
- It never creates tasks, edits agent files, or deletes a lesson itself

Work done without a plan has no cycle to close: `/retro --force <task>...` analyzes it (name no
tasks and it reads your `/go` focus) and writes `docs/retrospectives/YYYYMMDD-<slug>.md` and its
lessons for you to commit.

---

## Commands Reference

Ten commands you type: `/whip`, `/task`, `/go`, `/retro`, `/research`, `/whip-init`,
`/whip-add-agents`, `/whip-doctor`, `/whip-focus`, `/whip-move`. Two more skills,
`clean-checkout-before-task` and `integrate-lpcas`, are invoked by agents and `/go`, never by you,
and `whip-go` / `whip-task` are the workflow engines behind `/go` and `/task`.

### /whip - Where you are, and the one command to run next

**Purpose**: the front door of the cycle. It prints `acfw-cycle` output verbatim and never derives
a stage in prose.

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

### /task - Pure Orchestration

**Purpose**: Decompose scope into atomic tasks (NEVER implements)

**Execution**: runs as the `whip-task` dynamic workflow when available (schema-enforced slugs + JS validation gate + create-time doctor, before any file is written); otherwise the legacy single-context decomposition.

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
1. Reads style guide (mandatory)
2. Minimal research (Perplexity, Context7, Figma)
3. Decomposes into atomic tasks (WHAT/WHY only)
4. Validates against style guide
5. Spawns task-engineer agents (parallel)
6. Exits immediately

**Style Enforcement**:
- ✅ Binary language ("API validates token")
- ✅ WHAT/WHY only (no HOW)
- ✅ Max 2-3 line code snippets
- ❌ NO implementation details
- ❌ NO banned words

**Output**: Tasks created in `.backlog/pending/`

---

### /go - Continuous Execution

**Purpose**: Execute entire backlog until 100% complete

**Execution**: runs as the `whip-go` dynamic workflow when available (the loop/partition/dependency-gate/integration live in a script, so Claude's context stays flat across iterations); otherwise the legacy single-context loop. Both refuse to dispatch against a FATAL-failing backlog (doctor startup gate).

**Usage**:
```bash
/go                                          # your FOCUS (see Run scope below)
/go --all                                    # every actionable task, explicitly
/go api-014-token-refresh ui-021-login-form  # exactly those, plus their unmet dependencies
/go MUL-4821                                 # native backend ids resolve too
/go frontend tasks only                      # a natural-language filter over the backlog
/go bugfixes                                 # the fix/bug tasks
```

**Run scope (3.2.3, focus-driven since 3.4.0)**: with no arguments `/go` runs your **focus** — the
per-checkout list `/task` sets to the tasks it just created, or that you set with `/whip-focus`. With
no focus, `files` drains the whole backlog as before while every shared API-backed store refuses and
names the three ways forward; `/go --all` is the explicit "yes, everything". With arguments it runs
**only** what you name. Task ids, stems and native backend ids pass straight through; a
natural-language filter is resolved **once, before launch** — matched against the fields the snapshot projects on every backend
(`agent`, `slug`, `priority`, `stem`, `touchesGlobs`), shown to you, and confirmed — so the
orchestrator always receives a concrete task list and stays deterministic. Unmet transitive
dependencies are pulled in and named in the log; already-accepted ones are left alone. Nothing
outside the scope is dispatched, transitioned or integrated, including by the post-loop drain, which
is what makes a scoped run safe against a backlog other people are working in. Completion is
measured over your scope, and an id matching no task aborts the run rather than quietly running
less than you asked for. The run report echoes `scopeFilter`, `scopedTo` and `scopeResolved`.

**Behavior**:
- Loops until ALL tasks in terminal states (or, when scoped, all tasks in the scope)
- Each iteration:
  - Scan ALL states (pending, in-progress, completed, in-review, rejected, blocked)
  - Integrity re-check (`whip-doctor --active-only`)
  - Process ALL transitions through the single writer
  - Spawn agents in parallel, one per free worktree slug
  - Integrate newly-accepted work into trunk (LP-CAS), then check completion
- Exits: 100% complete, OR 3 consecutive iterations doing no work at all (genuinely stuck — e.g.
  unsatisfiable dependencies), OR 15 iterations with no *terminal* gain (the perpetual-retry guard)
- Quality gate auto-fix runs on the **legacy** single-context loop; the workflow orchestrator relies
  on the per-task harness's own bounded gate loop instead

**State Transitions Processed**:
- `rejected` → `pending` (retry if <3 attempts, block if ≥3)
- `blocked` → `pending` (dependencies resolved)
- `pending` → `in-progress` (specialist agents start)
- `completed` → `in-review` → `accepted|rejected` (quality-reviewer)
- `in-progress` → `blocked` (stale dispatch; default 8h, set `ACFW_INPROGRESS_TIMEOUT_HOURS` to change)

**Output**: Continuous progress until completion

---

### /whip-focus - What a bare `/go` runs

**Purpose**: manage the run focus — the small, per-checkout list of tasks a bare `/go` runs

```bash
/whip-focus                    # show it, with each task's live state and who set it when
/whip-focus set <tasks...>     # replace it with exactly these
/whip-focus add <tasks...>     # add these (replaces outright when every task in it is done)
/whip-focus drop <tasks...>    # remove these
/whip-focus clear              # remove it; a bare /go then follows the store's bareGo policy
```

Tasks may be named by stem, id, native backend id (`MUL-4821`) or a unique stem prefix. `set` and
`add` resolve every token through the store first and **refuse the whole operation** if any is
unknown or ambiguous — a focus holding raw arguments would inherit every ambiguity of the thing
typed, and a selection that silently changes meaning is worse than no selection.

It lives at `.acfwhip/run/focus`, which is gitignored, and that is not an implementation detail: a
focus is one person's current selection, never a fact about the project. Two people on one board
have two focuses, and neither one's `/go` becomes everyone's.

**Dropping is not pausing.** A scoped run pulls in the unmet dependencies of everything in its
scope, so a task you drop that something else needs comes straight back — correctly, since otherwise
that dependent could never run. To actually park a task, use `/whip-move` below.

---

### /whip-move - Move ONE task between states

**Purpose**: last-mile reconciliation without hand-editing the store

```bash
/whip-move <task> <state> [--reason "..."] [--integrated-at SHA] [--add-dep ID]
```

States: `pending in-progress completed in-review accepted rejected blocked draft archive`.

**`draft` pauses and `archive` cancels**, on every backend (3.4.0). Both are inert to the scheduler
and excluded from the completion denominator, while staying resolvable as dependencies — so a task
that depends on a paused one is reported as *gated, and here is why*, not as a dangling reference.
A parked task's worktree and branch are never reaped by `/whip-doctor --fix`; they are reported as
`parked-task-worktree` and left for you.

Setting a native `blocked`/`cancelled` status on an API-backed board does **not** pause a task —
whip reads its own metadata, not the native status. The doctor reports that as `WARN|native-hold`
and leaves the native status alone rather than repairing it.

It runs the validated writer, so the folder move, the `Status:` sync, the transition-log row and the
commit stay atomic. Run `/whip-doctor` after.

---

### /whip-doctor - Backlog Integrity

**Purpose**: Diagnose (and optionally repair) backlog + worktree health

**Usage**:
```bash
/whip-doctor          # report only
/whip-doctor --fix    # apply the REPAIRABLE class, then re-scan
```

**Checks** (FATAL / REPAIRABLE / WARN): status-vs-folder mismatch, missing/empty worktree slug on a code task, unknown Assigned Agent, duplicate IDs, dangling/cyclic dependencies, cross-slug dependent dispatched before integration, worktree on the wrong branch, detached HEAD; missing worktree slug derivable from the id, out-of-range Rejection Count, dup-folder, orphaned worktree; missing clean-checkout token, lingering in-review, stale in-progress, cross-slug glob overlap.

**Output**: `SEVERITY|CODE|TASK_ID|DETAIL` lines + a `SUMMARY|fatal=N|repairable=N|warn=N|ok=…` line; exit 0 iff no FATAL. Runs automatically as a `/go` startup gate and per-iteration recheck.

---

### /retro - Close a Cycle, and Learn from It

**Purpose**: Close a planned cycle, and learn from it when something went wrong

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
- When a task was reworked or stuck, or a deliverable is not met, the retro agent finds root causes (Five Whys) and writes docs/cycles/<ID>/retro.md, at most 3 one-rule lessons in docs/acf/lessons/, and a retro-actions cycle you approve like any plan
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

**Purpose**: Conduct structured research using MCP tools, create temporal documentation, generate backlog task

**Usage**:
```bash
/research "Next.js 15 server components best practices"
/research "Prisma query optimization for PostgreSQL time-series data"
/research "UI component from Figma: https://figma.com/design/ABC/node-id=1-2"
```

**Behavior**:
1. Verifies prerequisites (`.backlog/`, `docs/acf/research-protocol.md`, `docs/acf/organization.md`)
2. Generates temporal filename: `docs/research/YYYYMMDD-{topic}.md`
3. Launches research-agent for comprehensive research
4. **MCP Tool Selection** (from research-protocol.md):
   - **Figma MCP**: MANDATORY when Figma URL/node provided
   - **Context7**: Library documentation, API references
   - **Perplexity**: Best practices, architecture, security, performance
5. Creates research document with evidence-based analysis
6. **Automatically generates backlog task** from findings

**Temporal Naming (MANDATORY)**:
- Format: `docs/research/YYYYMMDD-description.md`
- Date: Current date in YYYYMMDD (NO hyphens)
- Description: lowercase, hyphen-separated
- Reference: `docs/acf/organization.md`

**Style Requirements** (from `docs/acf/style/research-documents.md`):
- Direct, factual analysis (no promotional language)
- Evidence-based claims with source attribution
- Quantified comparisons (not "faster", use "3x faster")
- Tables for comparisons (not prose)
- Code snippets ≤3 lines

**Output**: Research document (`docs/research/YYYYMMDD-topic.md`) + backlog task (`.backlog/pending/`)

---

### /whip-init - Initialize Workflow

**Purpose**: Explicit project initialization

**Usage**:
```bash
/whip-init
/whip-init --with-specialists   # also generate specialist agents for the detected stack
```

**Behavior**:
1. Detects tech stack (package files scan)
2. Asks user for customization (priority system, coverage thresholds)
3. Analyzes repository for agent customization data
4. Creates `.backlog/` structure (9 folders)
5. Installs quality gate config (`.pre-commit-config.yaml`), with every hook kept out of `docs/cycles/`
6. **Generates 6 universal agents** from patterns to `.claude/agents/` (customized for project)
7. Generates agent manifests in `docs/agents/` (Priority 1/2/3 structure)
8. Triggers SessionStart hook behavior (copies docs, generates README)
9. Adds CLAUDE.md section (if exists), naming `/whip` as the place to start
10. In a **new** project only, pins `ACFW_INTEGRATION_MODE=default`; adds `docs/cycles/` to an
    existing `.prettierignore` or `.markdownlintignore`, because approval hashes those bytes

**Output**: Complete backlog workflow initialized

---

### /whip-add-agents - Agent + Manifest Generator

**Purpose**: Create missing specialist agents

**Usage**:
```bash
# Auto-detect
/whip-add-agents

# User-specified (PRIORITY)
/whip-add-agents --backend=go --frontend=nextjs
/whip-add-agents --backend=python --data=dagster --infrastructure=k8s
```

**Behavior**:
1. **Parse user args** (override auto-detection)
2. **Repository analysis**:
   - Scan directory structure
   - Detect tech stack indicators
   - Analyze CLAUDE.md for mentions
   - Check existing agents (avoid duplication)
   - Assess complexity (LOC, polyglot, microservices)
3. **Study existing conventions**:
   - Read existing agent implementations
   - Read existing manifests
   - Extract patterns (structure, sections, formats)
4. **Generate agent files**:
   - **Implementation**: `.claude/agents/{agent}.md` (small, core instructions)
   - **Manifest**: `docs/agents/{agent}.md` (Priority 1/2/3 docs, navigation guidance, 10 anti-patterns)
5. **Generate quality gates**: `docs/development/quality-gates-{stack}.md` (if missing)
6. **Update configuration**:
   - Regenerate `.backlog/README.md` with new agents
   - Update `CLAUDE.md` agent assignments (if exists)
   - Install pre-commit hooks (if missing)

**Tech Stack Detection**:
- **Backend**: `go.mod` → go-engineer, `requirements.txt` → python-engineer, `package.json` + express/fastify → nodejs-backend-engineer
- **Frontend**: `package.json` + next → nextjs-engineer, + react → react-engineer
- **Data**: Dagster/BentoML files → data-engineer/ml-ops-engineer
- **Infrastructure**: `k8s/` → k8s-engineer, `docker-compose.yml` → devops

**Output**: Agent implementations + manifests + quality gates + updated config

---

## Universal Agents

All projects get **6-7 universal agents** (devops optional) **GENERATED FROM PATTERNS** and customized for the project's tech stack:

**Key Change**: Universal agents are no longer generic files copied verbatim. They're **generated** from patterns and customized with:
- Stack-specific examples (Go/Python/Node.js syntax)
- Quality gate tool references matching your `.pre-commit-config.yaml`
- Coverage thresholds from your initialization choices
- Priority system (3-level vs 5-level SLA-based)
- Agent assignment matrices reflecting your actual agents
- **Infrastructure detection** (Docker, K8s, CI/CD, monitoring)

**The 6 core universal agents**:

### task-engineer
- **Role**: Task decomposition (WHAT/WHY only, no HOW)
- **Authority**: Create tasks, set priorities, assign agents
- **Prohibition**: ZERO implementation code
- **Style**: Enforces `task-descriptions.md` style guide

### quality-reviewer
- **Role**: Binary accept/reject decisions
- **Authority**: Accept completed work, reject with reasons
- **Prohibition**: NEVER fixes code, only identifies issues
- **Critical**: MUST move tasks to terminal state (accepted/rejected)

### lean-architect
- **Role**: System architecture design (WHAT/WHY not HOW)
- **Authority**: Design architectures, define contracts, document decisions
- **Prohibition**: NO implementation code
- **Style**: Max 2-3 line code snippets (interfaces only)

### retro
- **Role**: Root cause analysis when a cycle's work went wrong (dispatched by `/retro`)
- **Authority**: Root cause analysis, one-rule lessons, and proposed action items; a human approves every change to agents, workflow or quality standards
- **Method**: Five Whys root cause analysis
- **Existing projects**: a `.claude/agents/retro.md` generated before 3.5.0 still grants edit authority; the 3.5.0 CHANGELOG entry has the exact edit

### precommit
- **Role**: Pre-commit hook configuration
- **Authority**: Configure hooks, select repositories, optimize execution
- **Prohibition**: Cannot modify quality standards (a /retro action item, approved by a human)

### research-agent
- **Role**: Evidence-based research
- **Authority**: Conduct research, create comprehensive reports
- **Tools**: **MANDATORY Perplexity usage** for all research

### devops (Optional, Infrastructure-Aware)
- **Role**: Infrastructure, CI/CD, and deployment operations
- **Authority**: Configure Docker/K8s, setup monitoring, CI/CD pipelines, troubleshooting
- **Created When**: Docker, Kubernetes, or CI/CD platform detected (user can skip)
- **Customization**: Generated with detected orchestration (docker-compose/kubernetes), CI tool (github-actions/gitlab-ci), monitoring stack (prometheus-grafana/datadog), cloud provider (gke/eks/aks)
- **Prohibition**: Cannot design K8s manifests (delegates to k8s-engineer if exists)
- **Manifest**: Deeply customized analyzing `docs/operations/` for Priority 1/2/3 docs

---

## Agent Manifest System

### Purpose

Achieve **58-74% token reduction** through priority-ordered documentation.

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
10. **Anti-Patterns**: 10 common mistakes with explanations
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

### Zero Bypass Tolerance

**ABSOLUTE PROHIBITIONS**:
- ❌ `git commit --no-verify`
- ❌ `SKIP={hook-name}`
- ❌ Lowering coverage thresholds
- ❌ Commenting out failing tests

**Enforcement**: CI re-runs all quality gates. Bypasses = immediate rejection.

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

### Failure Protocol

- **Red gate inside a worktree**: the default per-task harness runs your gates at most twice, with
  one fix round after each failure, then sends the diff to a fresh reviewer. Fix causes; never
  weaken or delete a test. This never pages you.
- **Rejected in review**: the task goes back to pending with its rejection counted. The third
  rejection blocks it, and a task its own specialist blocks a third time stays blocked (`/go` args
  `maxReject` / `maxBlock`, default 3). The counters are lifetime counters on every store.
- **Blocked at the cap**: parked work, which does page you. In a planned cycle `/whip` shows a card
  with the exact reply. `/whip-move <task> pending` buys exactly one more attempt; the usual fix is
  to archive the task and plan the work again.
- **Learning from it**: when a planned cycle ends with a reworked or stuck task, or an unmet
  deliverable, `/retro` finds the root cause and proposes the fix as an action item you approve.
  For work done without a plan: `/retro --force <task>...`.

---

## Task Description Style Guide

### MANDATORY Rules

**Binary Language**:
- ✅ "API validates token" NOT "improve validation"
- ✅ "Returns 401 for invalid credentials"
- ❌ "Enhance authentication system"

**WHAT/WHY Only** (NO HOW):
- ✅ WHAT: "POST /api/v1/auth/login endpoint"
- ✅ WHY: "Enable user authentication"
- ✅ CONSTRAINTS: "Response < 200ms"
- ❌ HOW: "Use bcrypt for hashing, JWT for tokens"

**Code Snippet Limits**:
- ✅ ALLOWED (2-3 lines): `POST /api/v1/auth`, `{"token": "jwt"}`, `Returns 400 for missing fields`
- ❌ PROHIBITED: Function implementations, algorithms, config files

**Banned Words**:
- comprehensive, systematic, significant, substantial
- robust, elegant, achievement
- enhance, optimize, streamline (unless specific: "optimize query from 2s to 200ms")

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

Automatically initializes on every session:

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

`.backlog/README.md` is created once by `/whip-init` and is never rewritten wholesale
afterwards — not by the SessionStart hook, and not by `/whip-add-agents`, which updates
only its agent-roster line in place. Your gate commands, coverage thresholds and evidence
rules are yours, and they survive every re-run.

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
| `.gitignore`, `.pre-commit-config.yaml`, `.prettierignore`, `.markdownlintignore` entries | `/whip-init` (keeps formatters out of `docs/cycles/`, whose bytes approval hashes) | you commit them |

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

**Problem**: quality-reviewer didn't move tasks to terminal state

**Solution**:
```bash
# Manually check in-review tasks
ls .backlog/in-review/

# Force re-review (the validated writer keeps Status and the transition log in sync)
/whip-move <task> completed
/go
```

**Prevention**: quality-reviewer agent enforces terminal state movement

### No Progress for 3 Iterations

**Problem**: Tasks blocked or circular dependencies

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

**Problem**: task-engineer creates tasks with implementation details

**Solution**:
- SessionStart hook injects style guide enforcement
- `/task` command validates before spawning agents
- If violations persist, run /retro --force <task>...: it proposes a [guide] action item for the task-engineer file, which you approve

### Agent Generation Errors

**Problem**: `/whip-add-agents` can't detect tech stack

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

To contribute new patterns:

1. Identify universal pattern in production
2. Strip project-specific details
3. Add PARAMETERIZE markers
4. Create multi-stack examples
5. Test template clarity
6. Submit PR with comprehensive documentation

### Agent Templates

To add new agent patterns:

1. Create `{type}-agent-pattern.md` in `content/agent-patterns/`
2. Create `{type}-manifest-pattern.md` with Priority 1/2/3 structure
3. Update `/whip-add-agents` command to recognize new type
4. Test agent generation with pattern
5. Submit PR with usage examples

---

## License

Proprietary License - Copyright 2025 Fibonacci Seven, LLC. See LICENSE file in repository root.

---

## Acknowledgments

Distilled from production ACF implementations.

---

## Support

Issues: https://github.com/fib7/acf-tools/issues

Documentation: https://github.com/fib7/acf-tools/tree/main/docs

---

**Version**: see `.claude-plugin/plugin.json`; what changed in each release: `CHANGELOG.md`
**Last Updated**: 2026-09-29

Zero tolerance. Binary outcomes. Evidence required. No shortcuts.
