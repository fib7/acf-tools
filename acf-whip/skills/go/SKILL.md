---
name: go
description: Continuous backlog execution until 100% tasks reach terminal states (accepted/blocked)
argument-hint: "[task-ids | filter description]"
allowed-tools:
  - Bash
  - Glob
  - Read
  - TodoWrite
  - Task
  - Workflow
---

# /go - Continuous Backlog Execution

Fire-and-forget automation. Processes the ENTIRE backlog without manual intervention until 100%
complete — or, when given arguments, exactly the subset you name (see **Run scope** below).

## State Machine (User-Specified)

```
pending → in-progress → completed → in-review → [accepted | rejected]
            ↓                                          ↓
         blocked                                    pending (retry)
```

**Terminal States**:
- `accepted` - Successfully completed and passed quality review
- `blocked` - Failed after max retries (3) or unresolvable dependencies

## Purpose

Execute backlog continuously:
1. Capture trunk identity at startup (refuse on detached HEAD).
2. Loop until ALL tasks reach terminal states.
3. Process ALL state transitions each iteration, gating on dependencies.
4. Partition pending tasks by `Worktree:` slug; dispatch at most one specialist per slug, in parallel across slugs.
5. After dispatch returns, integrate every newly-accepted worktree into the local trunk in dependency-topological order (default behavior; see "Integration mode" below).
6. Quality gate auto-fix before processing.
7. Exit only when 100% complete OR user intervention needed.

**CRITICAL**: This command does NOT terminate after one pass. It continues looping until backlog complete AND every accepted worktree is folded into trunk.

## Run scope

`/go` with no arguments drains the whole backlog. With arguments it runs **only** what you name:

```
/go                                          every actionable task (unchanged)
/go api-014-token-refresh ui-021-login-form  exactly those two, plus their unmet dependencies
/go frontend tasks only                      everything a frontend agent owns
/go bugfixes                                 the fix/bug tasks
/go high priority backend                    any predicate over the backlog
```

Both forms resolve to the same thing before launch: a concrete list of task stems
(`args.only`). Ids go straight through; a natural-language filter is matched against the task
store in **step 3** below, shown to you, and confirmed once. The orchestrator itself is
deterministic either way — it never re-interprets your words mid-run, and the set cannot drift.

Three properties worth knowing:

- **Unmet dependencies are pulled in.** A scoped task whose dependency is outside your list would
  otherwise sit gated forever. The orchestrator adds non-terminal transitive deps and names them in
  the run log. Dependencies that are already accepted/integrated are left alone.
- **Everything stays inside the scope.** Out-of-scope tasks are never dispatched, never transitioned,
  and never integrated — including by the post-loop drain. This is what makes `/go` safe to run
  against a backlog shared with other people.
- **Completion is measured over your scope**, not the whole backlog, so a scoped run ends when
  *your* tasks are done. A stem that does not exist aborts the run instead of quietly running less
  than you asked for.

The `RunReport` echoes `scopeFilter` (your words), `scopedTo` (what you asked for) and
`scopeResolved` (what actually ran, including pulled-in dependencies).

## Integration mode

**Default (LP-CAS, 3.0.0)**: the orchestrator lands every newly-accepted task onto the live trunk via the `integrate-lpcas` skill — a single-parent candidate cherry-picked onto the live tip, co-committed with an in-tree ledger marker, union-gated, and CAS-landed. The marker's presence on trunk is the sole integration oracle (no cached snapshot, no rebase); conflicts route to the task's `assigned_agent` as a resolver. See `skills/integrate-lpcas/SKILL.md`. (`workflows/whip-go.workflow.js` is the authoritative implementation; the bash loop further down is the fallback for when the Workflow tool is unavailable, and mirrors it.)

**Override**: if the project's `CLAUDE.md` (or any other persistent agent instructions) directs a different integration strategy — for example "open a PR per PR Group via `gh pr create` instead of merging locally" — follow those instructions and skip Step 4.5. In that mode, the loop reverts to the 1.2.0 terminal check (`accepted ∪ blocked`); operator handles integration.

The mode can be **pinned machine-readably**: `ACFW_INTEGRATION_MODE=override|default` — env var, or a key in `.acfwhip/config` (committed, so the repo's delivery discipline travels with the repo). `acfw-store info` reports the pinned value as `integrationMode`, empty when unpinned. When it is empty, the orchestrator decides by reading project instructions (already loaded into Claude's context), exactly as before.

An **unrecognized value is FATAL** (`acfw-store` exits 2) — it does not degrade to unpinned. This key decides whether accepted work folds into a branch a human may never review, so guessing is not an option, and degrading to unpinned would hand the decision back to the model that the pin exists to stop depending on. Note the config parser strips quotes and trailing whitespace but **not a trailing comment**, so `ACFW_INTEGRATION_MODE=override  # PR per group` is an unrecognized value, not a pin. Put comments on their own line.

### What override mode does and does not do

| | |
|---|---|
| **Does** | Skips Step 4.5, so nothing is cherry-picked onto trunk and no ledger marker is written. Treats `accepted` as terminal (`accepted ∪ blocked`). Keeps each accepted task's `worktree/<slug>` branch and worktree alive instead of reaping them, so the deliverable has a home to PR from. Relaxes the cross-slug dependency gate — acceptance alone satisfies a dep, and **ordering becomes yours**. |
| **Does not** | Push anything. Run `gh pr create`. Read or set `PR Group` (it is authored, validated and stored, but drives no behavior). Check whether trunk is protected, has a remote, or is behind `origin`. Integration is entirely the operator's — acf-whip stops at accepted and gets out of the way. |

**If a clean trunk matters as much as review gating, use a non-files task store.** `/go` commits `.backlog/` state transitions onto the trunk branch in **both** modes, and the writer refuses to run anywhere else (`skills/go/bin/apply-transition.sh`), so a files-backed run puts a stream of `task: <stem> pending -> in-progress` commits on local trunk regardless of integration mode. With `beads`, `multica`, or `linear` (see `adapters/`), task state lives outside git entirely and trunk sees only deliverables. The LP-CAS ledger stays git-native on every backend.

---

## Execution: workflow-first, legacy fallback

acf-whip ships a **dynamic-workflow orchestrator** (`workflows/whip-go.workflow.js`) that runs the
entire loop — scan, slug partition, dependency gate, the full state machine (including
**blocked→pending unblock** when deps resolve and **in-progress→blocked timeout** past the operator
threshold), topological integration, stall/terminal bookkeeping — inside a deterministic script. The intermediate state lives in script variables, so
**your context stays flat across iterations** (this is the fix for the context-bloat problem the
legacy loop has). Prefer it.

**If the `Workflow` tool is available to you** (dynamic workflows enabled, Claude Code ≥ 2.1.154):

1. Decide the integration mode. First check the machine pin: step 2's `acfw-store info` output
   carries `integrationMode` — if it is non-empty, use it **verbatim** as `args.mode`, no further
   reasoning. Only when it is empty, decide by reading the project's `CLAUDE.md`/`AGENTS.md`
   (already in your context): `override` if they direct PR-per-group / non-local-merge
   integration, otherwise `default` (auto-merge into local trunk).
2. Resolve the environment with one bash call. **Refuse on detached HEAD** (empty branch):
   ```bash
   echo "PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT"
   echo "TRUNK_ROOT=$(git rev-parse --show-toplevel)"
   echo "TRUNK_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)"
   bash "$CLAUDE_PLUGIN_ROOT/skills/lib/bin/acfw-store" info
   ```
   If `TRUNK_BRANCH` is empty, STOP — `/go` requires a branch checked out at the repo root.
   The `acfw-store info` line reports the active **task-store backend** (`store`, default `files`),
   its adapter, and the run-lock path (`runLock`) — pass both through in step 4.
3. **Resolve the run scope** from whatever the user typed after `/go`. Three branches:

   **(a) No arguments** — omit `only` entirely. Full-backlog behaviour, unchanged.

   **(b) The arguments are task ids or stems** (they match the backlog's id/stem shape, e.g.
   `api-014-token-refresh`, `add-login-form`) — pass them straight through as `only: ["api-014-token-refresh", ...]`.
   No confirmation: the user named exact tasks.

   **(c) Anything else is a filter predicate** — "frontend tasks only", "bugfixes",
   "high priority backend", "the auth work". Resolve it to a concrete list *here*, before launching:
   ```bash
   bash "$CLAUDE_PLUGIN_ROOT/skills/lib/bin/acfw-store" snapshot --digest
   ```
   Match the predicate against the fields the snapshot projects on every backend —
   `stem` · `id` · `folder` · `slug` · `agent` · `priority` · `deps` · `touchesGlobs`:

   | Predicate | Match on |
   |---|---|
   | "frontend tasks" | `agent` (e.g. `frontend-engineer`), `touchesGlobs` (`src/web/**`), `slug` |
   | "bugfixes" | `stem` (`fix-*`, `bug-*`) — stems are descriptive kebab by convention |
   | "high priority" / "blockers" | `priority` (blocker \| critical \| high \| medium \| low) |
   | "the auth work" | `slug`, `stem` |

   There is **no title or body in the snapshot**. If the predicate cannot be decided from these
   fields, say so and ask for ids rather than guessing. Then **show the matched task list and get one
   confirmation before launching.** This does not violate the fire-and-forget rule below — that rule
   forbids interrupting *between tasks*; this is a single check at launch, and a natural-language
   filter is fuzzy enough that silently committing a long, expensive run to it is worse.
   **If nothing matches, stop and say so — never fall back to the whole backlog.**

   Scope is resolved **once, at launch**: the workflow receives a fixed stem list, so tasks created
   while the run is in flight do not join it. Unmet dependencies of a scoped task *are* pulled in
   automatically by the orchestrator and named in the run log.
4. Launch the orchestrator (it runs in the background; bootstrap runs a doctor `--fix` hard gate and
   the loop re-checks integrity every iteration):
   ```
   Workflow({
     scriptPath: "<PLUGIN_ROOT>/workflows/whip-go.workflow.js",
     args: { pluginRoot: "<PLUGIN_ROOT>", trunkRoot: "<TRUNK_ROOT>", trunkBranch: "<TRUNK_BRANCH>",
             mode: "default" | "override", store: "<info.store>", runLockPath: "<info.runLock>",
             // step 3, both branches (b) and (c); OMIT both when the user gave no arguments
             only: ["<stem-or-id>", ...], scopeFilter: "<the user's words, verbatim>" }
   })
   ```

   **Optional args (3.2.0 per-task child workflows).** Every dispatched unit runs as its own nested
   workflow by default; these tune or disable that:

   | Arg | Default | Effect |
   |-----|---------|--------|
   | `escalate` | `true` | `false` reverts to byte-identical 3.1.0 single-agent dispatch. **Reach for this first if a run looks hung** — expect roughly 2-4× the per-iteration wall clock at the default depth. |
   | `escalateReview` | `false` | Turns on the multi-lens review panel. Off by default because it is the only *subtractive* seam: it can reject work that would otherwise have shipped, against a hard 3-rejection terminal. |
   | `maxAmend` | `2` | Repair rounds when an authored harness throws. Two convergence gates usually cut it to one. |
   | `agentBudget` | `8` | Agent ceiling for one harness (enforced inside the child, not advisory). |
   | `agentCap` | `1000` | The run's total agent budget. Drives the FULL → LEAN → DIRECT → CLOSE ladder. |
   | `shellModel` | `haiku` | Model for the deterministic shell-runner agents. |

   **Run-scope args (3.2.3).** Both come from step 3 and are omitted together on a full-backlog run:

   | Arg | Default | Effect |
   |-----|---------|--------|
   | `only` | *(none)* | Task stems/ids to run **instead of** the whole backlog. The orchestrator plans, transitions, integrates and counts completion over just these, plus any **unmet dependencies**, which it pulls in and names in the log. An id that does not exist aborts the run rather than silently running a smaller set. |
   | `scopeFilter` | `""` | The operator's raw words, recorded in the `RunReport` — for a natural-language filter this is the only record of what was actually asked for, since `only` holds the resolved stems. |
   The per-iteration scan runs `acfw-store snapshot --digest` (a small scheduling snapshot — counts +
   actionable tasks + a compact `satisfiedDeps` list, with terminal-accepted tasks collapsed) and
   `whip-doctor --active-only` (full integrity over active folders; accepted fed as cheap stubs), so a
   lived-in backlog scans in seconds instead of tens of seconds. The deterministic shell-runner agents
   (scan, the single writer, integrate, bootstrap, drain) run on a fast model; pass an optional
   `shellModel` arg to override it (e.g. pin to the session model for rollback). Specialists, reviewers,
   and conflict-resolvers always run on the session model.
5. When it completes, report the returned `RunReport` (completed?, iterations, finalCounts,
   integrated[], stopReason). If it returns `aborted: true` (detached HEAD, an unrepairable FATAL, or
   `stopReason: 'scope-unresolved'` — an id in `only` that matches no task), surface the reason +
   fatals and STOP. On a scoped run also report `scopeResolved`, so the operator sees which tasks
   actually ran and which dependencies were pulled in. Re-running `/go` is the documented resume — git + the task
   store (`.backlog/` on the default files backend) are the only durable state.

   Also surface `escalation{}` and `agentsUsed`/`agentCap`. They are how an operator tells a fully
   escalated run from one that silently degraded to 3.1.0 dispatch — the two are otherwise
   indistinguishable. In particular:
   - `stopReason: 'agent-cap-reached'` is a **clean** stop, not a failure: in-flight work was finished
     and integrated, every completed harness stage is on disk under the same attempt key, and
     re-running `/go` replays them for free and continues.
   - `escalation.authored === 0` with `escalation.fellBack > 0` means no harness was ever authored —
     check that `skills/lib/bin/acfw-child-*` are executable and `.claude/agents/` is populated.
   - `escalation.stagesReplayed` is work a re-run did **not** have to redo.
5. Do **not** also run the legacy loop below — the workflow replaces it.

**Only if the `Workflow` tool is NOT available** (dynamic workflows disabled, or older Claude Code):
run the legacy single-context loop below. It enforces the same doctor gate and slug rules, but the
loop lives in your context (and grows it).

**Run scope on the legacy path.** That loop is prose you execute, not a script taking args, so a scope
cannot be threaded into it mechanically. Resolve it exactly as in step 3, then treat the resolved stem
list — plus any unmet dependencies — as the *entire* backlog for this run: never select, transition or
integrate a task outside it, and state the resolved list before you begin.

---

# Legacy fallback loop (no dynamic workflows)

> Everything below runs only when the `Workflow` tool is unavailable. It is the byte-compatible
> Claude-as-orchestrator implementation of the same `.backlog/` state machine.
>
> **files backend only**: this legacy loop reads and moves `.backlog/<state>/` files directly, so it
> requires the default `files` task store. A project configured with another store backend
> (`ACFW_STORE` in `.acfwhip/config` — e.g. `beads` or `multica`) needs dynamic workflows; if the
> `Workflow` tool is unavailable there, STOP and tell the operator instead of running this loop.

## Continuous Execution Loop

```yaml
PRE-LOOP: Capture trunk identity (refuse on detached HEAD).
WHILE (terminal_tasks < total_tasks):
  iteration++
  1. Quality Gate Auto-Fix (stack-specific)
  2. Scan ALL Workflow States
  3. Process ALL Transitions (TodoWrite single call), gating on dependencies
  4. Partition pending by Worktree slug; dispatch one specialist per slug (parallel across slugs)
  4.5. Integrate Newly-Accepted (default mode): topo-sort by deps; LP-CAS onto live trunk
  5. Check Completion (exit if 100%, else CONTINUE)
  6. Prevent Infinite Loop (max 1000 iterations)
POST-LOOP: Final integration drain (defensive).
```

---

## Pre-Loop: Capture Trunk Identity

Before iteration begins, snapshot the branch checked out at the repo root and export it as environment variables for every dispatched skill (`clean-checkout-before-task`, `integrate-lpcas`).

```bash
export ACFW_TRUNK_ROOT=$(git rev-parse --show-toplevel)
export ACFW_TRUNK_BRANCH=$(git -C "$ACFW_TRUNK_ROOT" symbolic-ref --short HEAD 2>/dev/null)
export ACFW_TRUNK_SHA_AT_START=$(git -C "$ACFW_TRUNK_ROOT" rev-parse HEAD)

if [ -z "$ACFW_TRUNK_BRANCH" ]; then
  echo "❌ FATAL: HEAD is detached at $ACFW_TRUNK_ROOT. /go requires a branch checked out at the repo root." >&2
  exit 1
fi

# Give the loop's PR-mode switch its machine source. When the mode is pinned (env or committed
# config — see "Integration mode"), the pin wins; when unpinned, the orchestrator's prose
# decision (made in step 1 above) stands and this leaves the switch unset.
# Runs AFTER the detached-HEAD refusal (no subprocess on a run that is about to abort), and as an
# if/fi rather than `[ ... ] && export`: that idiom evaluates to exit 1 whenever the mode is not
# override, which is a landmine the day this line ends up last in a block or under `set -e`.
ACFW_MODE_PIN=$(bash "$CLAUDE_PLUGIN_ROOT/skills/lib/bin/acfw-store" info | sed -E 's/.*"integrationMode":"([^"]*)".*/\1/')
if [ "$ACFW_MODE_PIN" = "override" ]; then
  export ACFW_INTEGRATION_OVERRIDE=1
  echo "🔒 Integration mode: override (pinned) — accepted tasks are terminal; you integrate."
fi
echo "🌳 Trunk: $ACFW_TRUNK_BRANCH @ $ACFW_TRUNK_SHA_AT_START"
```

## Pre-Loop: Backlog Integrity Gate (doctor)

Before the loop, run the integrity doctor as a **HARD GATE** over the ACTIVE backlog. The `--fix` pass self-heals the REPAIRABLE class first — including **deriving a missing `Worktree:` slug** for any active code task, so a pre-2.0.0 backlog dispatches instead of hard-failing. Only a remaining **FATAL** aborts. Findings on `accepted/` tasks are **advisory (WARN), never blocking**: an accepted task is terminal / out of the dispatch path, so a missing slug or stale `Status:` there does not gate the run.

```bash
DOCTOR="${CLAUDE_PLUGIN_ROOT}/skills/whip-doctor/bin/doctor.sh"
bash "$DOCTOR" --fix "$ACFW_TRUNK_ROOT" >/dev/null 2>&1 || true   # self-heal REPAIRABLE (incl. derive missing slugs)
if ! REPORT=$(bash "$DOCTOR" --quiet "$ACFW_TRUNK_ROOT"); then
  echo "❌ FATAL: backlog integrity gate failed. /go will not dispatch against an inconsistent backlog." >&2
  echo "$REPORT" | grep '^FATAL' >&2
  echo "Fix the FATAL findings (active-task errors: dangling/cyclic deps, status-folder mismatch) and re-run /go." >&2
  exit 1
fi
# Surface non-blocking findings as a compact grouped breakdown — a lived-in backlog can carry
# hundreds of historical accepted advisories, so never dump them line-by-line.
echo "$REPORT" | grep '^BREAKDOWN|' || true
```

The same doctor runs once per iteration (lite recheck, Step 0 below); a FATAL introduced mid-run also aborts the loop.

## Backlog state lives at root (single writer)

The orchestrator (this skill, running as the parent agent at `$ACFW_TRUNK_ROOT` on the trunk branch) is the **only writer of `.backlog/` files**. Specialists and quality-reviewer **do not** move task files between state folders; they signal their decision via the `ACFW-RESULT` marker (defined below) on Task() return. The orchestrator parses the marker, performs the file move + `git mv` + commit on the trunk branch, then continues.

**task-engineer transitions** (creation N/A→pending, retry rejected→pending, unblock blocked→pending, redesign rejected→blocked at >5 rejections) are likewise performed at root. task-engineer never invokes `clean-checkout-before-task` and never enters a worktree.

**Specialists** still do code work in their worktrees on `worktree/<slug>` (no change). Their commits on the worktree branch contain code only; no `.backlog/` deltas.

### ACFW-RESULT marker

Every implementer specialist and quality-reviewer ends its Task() output with a single marker block parsed by the orchestrator:

```
ACFW-RESULT:
  transition: completed | blocked | accepted | rejected
  commit_sha: <sha on worktree/<slug>, or "n/a">
  rejection_increment: 0 | 1
  notes: <one-line reason; becomes the transition-log Reason field>
```

`transition` is one of:
- `completed` (implementer finished implementation; orchestrator moves pending→completed at root, then schedules quality-reviewer)
- `blocked` (implementer hit an unresolvable blocker mid-work; orchestrator moves in-progress→blocked at root)
- `accepted` (quality-reviewer accepted; orchestrator moves in-review→accepted at root)
- `rejected` (quality-reviewer rejected; orchestrator moves in-review→rejected at root and increments Rejection Count)

If the marker is missing or malformed, the orchestrator treats the dispatch as a transient failure (leave task in current state, retry next iteration).

### Lock-file backoff helper (shared, extracted)

`git_with_lock_backoff` is defined once in `${CLAUDE_PLUGIN_ROOT}/skills/lib/acfw-git.sh` — the single source of truth for all acf-whip git logic. Source it before any orchestrator git operation:

```bash
. "${CLAUDE_PLUGIN_ROOT}/skills/lib/acfw-git.sh"
```

Backoff: 1s → 2s → 4s. Never `rm` the lock; let the holding process finish. (The shared helper captures git's exit status directly and uses a per-invocation temp error file, so it never masks a real failure as success and never clobbers a concurrent agent's error capture.)

### Integration oracle (LP-CAS)

The same file provides the **only** sanctioned integration test. A task is integrated **iff** its in-tree ledger marker (`.acfwhip/integrated/<shard>/<key>.json`, `key` = task stem) is present in the tree of the live trunk tip. Never grep `Integrated-At:` — that field is inert display/ack metadata and can diverge from reality.

```bash
acfw_is_integrated "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH" "$(basename "$f" .md)"   # exit 0 = integrated
acfw_integrated_keys "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH"                        # all integrated keys, one per line
```

### Orchestrator move primitive

After every Task() return, parse the marker and perform the move at root:

```bash
# Parses the ACFW-RESULT marker, then delegates the move + transition-log + commit to the
# shared apply-transition.sh primitive (idempotent; single source of truth; safe on resume).
acfw_apply_result() {
  local task_file="$1" from_state="$2" result="$3"
  local transition reject_inc notes new_state inc=0
  transition=$(echo "$result" | sed -nE 's/^[[:space:]]*transition:[[:space:]]*([a-z]+).*/\1/p')
  reject_inc=$(echo "$result" | sed -nE 's/^[[:space:]]*rejection_increment:[[:space:]]*([0-9]+).*/\1/p')
  notes=$(echo "$result" | sed -nE 's/^[[:space:]]*notes:[[:space:]]*(.*)/\1/p')
  case "$transition" in
    completed) new_state=completed ;;
    blocked)   new_state=blocked   ;;
    accepted)  new_state=accepted  ;;
    rejected)  new_state=rejected  ;;
    *) echo "WARN: missing/invalid ACFW-RESULT for $(basename "$task_file"); transient retry next iter" >&2; return 1 ;;
  esac
  [ "$reject_inc" = "1" ] && [ "$transition" = "rejected" ] && inc=1
  bash "${CLAUDE_PLUGIN_ROOT}/skills/go/bin/apply-transition.sh" \
    "$task_file" "$new_state" "${ASSIGNED_AGENT:-orchestrator}" "$notes" "$inc"
  rc=$?
  # Exit 4 = the task document is collapsed (no ID/Status): nothing was moved or committed.
  # Say so loudly — the writer refused for a reason and /whip-doctor names the recovery.
  [ $rc -eq 4 ] && echo "FATAL: transition refused for $(basename "$task_file") — collapsed task document; run /whip-doctor" >&2
  return $rc
}
```

Used after every specialist and quality-reviewer dispatch.

---

## Loop Implementation

### Iteration Start

```bash
iteration=0
max_iterations=1000
no_progress_count=0
previous_terminal_count=0
```

### Loop Condition

```bash
while [ $iteration -lt $max_iterations ]; do
  iteration=$((iteration + 1))
  echo "🔄 Iteration $iteration"

  # ... process workflow ...

  # Count terminal tasks. Override (PR) mode: accepted alone is terminal. Default (auto-merge)
  # mode: an accepted task is terminal once nothing remains to fold into trunk — its LEDGER MARKER
  # is on trunk, OR it is non-code ("none"), OR it has no worktree/<slug> branch (historical,
  # already on trunk). Equivalently: accepted MINUS the ones still pending integration (a real
  # branch, no marker). Mirrors the workflow's isTerminal.
  accepted_count=$(ls -1 .backlog/accepted/*.md 2>/dev/null | wc -l | tr -d ' ')
  blocked_count=$(ls -1 .backlog/blocked/*.md 2>/dev/null | wc -l | tr -d ' ')
  if [ "$ACFW_INTEGRATION_OVERRIDE" = "1" ]; then
    terminal_count=$((accepted_count + blocked_count))
  else
    pending_integration=0
    for f in .backlog/accepted/*.md; do
      [ -f "$f" ] || continue
      slug=$(grep -E '^- \*\*Worktree\*\*:' "$f" | head -1 | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
      { [ -z "$slug" ] || [ "$slug" = "none" ]; } && continue
      acfw_is_integrated "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH" "$(basename "$f" .md)" && continue
      git -C "$ACFW_TRUNK_ROOT" show-ref --verify --quiet "refs/heads/worktree/$slug" && pending_integration=$((pending_integration + 1))
    done
    terminal_count=$((accepted_count + blocked_count - pending_integration))
  fi
  # Denominator = the 7 ACTIVE folders only (draft/ and archive/ are excluded from automation and
  # must never inflate the completion target — matches the workflow's tasks[] population).
  total_count=$(ls -1 \
    .backlog/pending/*.md .backlog/in-progress/*.md .backlog/completed/*.md .backlog/in-review/*.md \
    .backlog/blocked/*.md .backlog/rejected/*.md .backlog/accepted/*.md 2>/dev/null \
    | grep -vE '/README\.md$' | wc -l | tr -d ' ')

  if [ $terminal_count -eq $total_count ] && [ $total_count -gt 0 ]; then
    echo "✅ Backlog 100% complete!"
    break
  fi

  # Check for progress
  if [ $terminal_count -eq $previous_terminal_count ]; then
    no_progress_count=$((no_progress_count + 1))
  else
    no_progress_count=0
  fi
  previous_terminal_count=$terminal_count

  if [ $no_progress_count -ge 3 ]; then
    echo "⚠️  No progress for 3 iterations. User intervention needed."
    break
  fi
done
```

---

## Step 0: Per-Iteration Integrity Recheck (doctor-lite)

At the top of each iteration, re-run the doctor (report only — repairs were applied at the pre-loop gate). A FATAL introduced mid-run (e.g. a task-engineer retry that produced a cycle, or a half-applied transition after a crash) aborts the loop rather than dispatching against inconsistent state.

```bash
if ! REPORT=$(bash "${CLAUDE_PLUGIN_ROOT}/skills/whip-doctor/bin/doctor.sh" --quiet "$ACFW_TRUNK_ROOT"); then
  echo "❌ FATAL: integrity violation detected mid-run. Aborting before dispatch." >&2
  echo "$REPORT" | grep '^FATAL' >&2
  exit 1
fi
```

## Step 1: Quality Gate Auto-Fix (PRE-PROCESSING)

Before processing ANY tasks, attempt to fix common quality issues automatically.

### Go

```bash
echo "🔧 Auto-fixing quality gates (Go)..."
gofmt -w .
goimports -w . 2>/dev/null || true
go mod tidy
go test ./... || true  # Don't fail on test errors
git_with_lock_backoff stash push -m "acf-whip-go-autofixes" || true
```

### Python

```bash
echo "🔧 Auto-fixing quality gates (Python)..."
ruff check . --fix || true
ruff format . || true
git_with_lock_backoff stash push -m "acf-whip-go-autofixes" || true
```

### Node.js/TypeScript

```bash
echo "🔧 Auto-fixing quality gates (Node.js)..."
npm run lint -- --fix 2>/dev/null || true
npm run format 2>/dev/null || true
git_with_lock_backoff stash push -m "acf-whip-go-autofixes" || true
```

### Next.js/React

```bash
echo "🔧 Auto-fixing quality gates (Next.js)..."
pnpm lint --fix 2>/dev/null || true
pnpm format 2>/dev/null || true
rm -rf .next 2>/dev/null || true  # Clear build cache
git_with_lock_backoff stash push -m "acf-whip-go-autofixes" || true
```

**Purpose**: Eliminate trivial quality gate failures (formatting, linting) before processing tasks.

---

## Step 2: Scan ALL Workflow States

Scan every state folder to identify transitions needed:

```bash
# Pending tasks (ready to start)
pending_tasks=$(ls -1 .backlog/pending/*.md 2>/dev/null || echo "")

# In-progress tasks (check for timeout)
inprogress_tasks=$(ls -1 .backlog/in-progress/*.md 2>/dev/null || echo "")

# Completed tasks (MANDATORY review trigger)
completed_tasks=$(ls -1 .backlog/completed/*.md 2>/dev/null || echo "")

# In-review tasks (should be empty, quality-reviewer must terminate)
inreview_tasks=$(ls -1 .backlog/in-review/*.md 2>/dev/null || echo "")

# Rejected tasks (retry if <3 attempts, block if ≥3)
rejected_tasks=$(ls -1 .backlog/rejected/*.md 2>/dev/null || echo "")

# Blocked tasks (check if dependencies resolved)
blocked_tasks=$(ls -1 .backlog/blocked/*.md 2>/dev/null || echo "")
```

### Check for Workflow Violations

```bash
if [ -n "$inreview_tasks" ]; then
  echo "⚠️  WARNING: Tasks in in-review/ folder (quality-reviewer must move to terminal state)"
  echo "   Tasks: $inreview_tasks"
  # Force review completion on next iteration
fi
```

---

## Step 3: Process ALL Transitions

Build complete transition list in single TodoWrite call.

### Transition Logic

#### A. Retry Rejected Tasks

For each task in `.backlog/rejected/`:
1. Read `rejection_count` from task metadata
2. If `rejection_count < 3`: Retry (increment attempt)
3. If `rejection_count >= 3`: Block (abandon)

```javascript
// Example todo
{
  content: "Retry feature-001 (rejected→pending, attempt 2/3)",
  status: "pending",
  activeForm: "Retrying feature-001 after rejection"
}
```

#### B. Unblock Tasks with Resolved Dependencies

For each task in `.backlog/blocked/`:
1. Read `Dependencies` from task metadata.
2. For each dependency `dep`, check the **dependency-gating rule** below.
3. If all deps satisfied: Unblock (blocked→pending).

#### C. Start Pending Tasks

For each task in `.backlog/pending/`:
1. For each dependency `dep`, apply the **dependency-gating rule** below. Tasks failing the check stay in `pending/` for this iteration.
2. Check priority (process by priority order).
3. Queue for start (pending→in-progress).

#### Dependency-gating rule (used by B and C, and also by Step 4a partition)

A task may dispatch only from a codebase that already contains all its dependencies. For each dep:

- **Same-slug dep** (dep's `Worktree:` equals this task's `Worktree:`): satisfied as soon as `dep` is in `.backlog/accepted/`. Its commits already live on the shared `worktree/<slug>` branch and will be present in the worktree when the within-slug serializer picks the next task.
- **Cross-slug dep** (different `Worktree:` slug): `dep` must be in `.backlog/accepted/` **AND** its commits must already be on the local trunk — i.e. its **ledger marker is on trunk**, **or** it is a historical task with no `worktree/<slug>` branch (already merged the old way; nothing left to integrate). A cross-slug dep blocks only while it is genuinely pending integration (accepted, a live branch, no marker). A non-code (`none`) dep never integrates, so it is satisfied on acceptance.

In override (PR) mode no marker is ever written, so treat acceptance as sufficient for cross-slug deps too (operator is responsible for ordering). The doctor's `cross-slug-dep-not-integrated` FATAL is relaxed in lockstep (`--mode override`, or the resolved pin) — **the scheduler and the doctor must agree here**. When they did not, this gate dispatched the dependent and the next per-iteration doctor recheck aborted the run on the state the scheduler had just chosen.

```javascript
{
  content: "Process feature-003 (pending→in-progress, deps integrated)",
  status: "pending",
  activeForm: "Processing feature-003"
}
```

#### D. Review Completed Tasks (MANDATORY)

For each task in `.backlog/completed/`:
1. **Orchestrator** at root: pre-move completed→in-review (atomic mv + commit on trunk).
2. Dispatch quality-reviewer with `TASK_FILE=$ACFW_TRUNK_ROOT/.backlog/in-review/<file>.md`.
3. On Task() return, orchestrator parses ACFW-RESULT and applies in-review→accepted or in-review→rejected via `acfw_apply_result`.

```javascript
{
  content: "Review feature-004 (completed→in-review→[accepted|rejected])",
  status: "pending",
  activeForm: "Reviewing feature-004"
}
```

#### E. Timeout In-Progress Tasks (operator threshold, default 8h)

For each task in `.backlog/in-progress/`:
1. Read timestamp from transition log
2. If older than `ACFW_INPROGRESS_TIMEOUT_HOURS` (env > `.backlog/.acfw-config` > default **8h**): Timeout (in-progress→blocked)

```javascript
{
  content: "Timeout feature-005 (in-progress→blocked, stale)",
  status: "pending",
  activeForm: "Timing out feature-005"
}
```

### TodoWrite (Single Call)

```javascript
TodoWrite({
  todos: [
    // All retry transitions
    { content: "Retry feature-001 (rejected→pending, attempt 2/3)", status: "pending", activeForm: "Retrying feature-001" },

    // All unblock transitions
    { content: "Unblock feature-002 (dependencies resolved)", status: "pending", activeForm: "Unblocking feature-002" },

    // All start transitions
    { content: "Process feature-003 (pending→in-progress)", status: "pending", activeForm: "Processing feature-003" },
    { content: "Process feature-007 (pending→in-progress)", status: "pending", activeForm: "Processing feature-007" },

    // All review transitions (MANDATORY)
    { content: "Review feature-004 (completed→in-review)", status: "pending", activeForm: "Reviewing feature-004" },

    // All timeout transitions
    { content: "Timeout feature-005 (in-progress→blocked)", status: "pending", activeForm: "Timing out feature-005" }
  ]
})
```

---

## Step 4: Partition by Worktree, Then Spawn

**Concurrency rule (MANDATORY)**: parallel across worktrees, sequential within a worktree. Each task declares `Worktree: <slug>` in its front-matter. Specialists invoke `clean-checkout-before-task` as Step 0; that skill uses git's worktree branch registry as the lock. Do not bypass the partition.

### Step 4a: Partition pending tasks by Worktree

```bash
# For each pending task, extract its Worktree slug.
# Group tasks by slug. Within each group, order by priority (blocker > critical > high > medium > low).
# Skip any group whose .backlog/in-progress/ already has a task with the same Worktree slug.
# Skip any task whose dependencies are not yet satisfied (see dependency-gating rule above).
```

Implementation in shell:

```bash
declare -A IN_PROGRESS_SLUGS
for f in .backlog/in-progress/*.md; do
  [ -f "$f" ] || continue
  slug=$(grep -E '^- \*\*Worktree\*\*:' "$f" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
  [ -n "$slug" ] && IN_PROGRESS_SLUGS["$slug"]=1
done

declare -a DISPATCH_QUEUE
declare -A SEEN_SLUGS
for f in $(ls -1 .backlog/pending/*.md 2>/dev/null | sort); do
  slug=$(grep -E '^- \*\*Worktree\*\*:' "$f" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
  if [ "$slug" = "none" ]; then DIRECT_DISPATCH+=("$f"); continue; fi   # research/docs-only: dispatch directly, no worktree, no clean-checkout
  if [ -z "$slug" ]; then
    # An empty slug on a code task is a FATAL doctor violation that already aborted the run
    # at the integrity gate. If we somehow reach here, do NOT silently skip into limbo —
    # surface it and leave the task pending for the operator.
    echo "WARN: $(basename "$f") has an empty Worktree: slug. Run /whip-doctor; this is a FATAL integrity violation." >&2
    continue
  fi
  [ -n "${IN_PROGRESS_SLUGS[$slug]:-}" ] && continue   # group already busy
  [ -n "${SEEN_SLUGS[$slug]:-}" ] && continue   # already picked one task from this group this iteration
  # Apply dependency-gating rule (see Step 3): skip if any dep unsatisfied.
  # Cross-slug dep needs its ledger marker on trunk; same-slug dep needs accepted/.
  deps_ok=$(./.claude/skills/go/check-deps.sh "$f")  # conceptual; real impl inlines the check
  [ "$deps_ok" != "ok" ] && continue
  SEEN_SLUGS["$slug"]=1
  DISPATCH_QUEUE+=("$f")
done
```

The dep-check (inlined, not a separate script) for each task `$f`:

```bash
THIS_SLUG=$(grep -E '^- \*\*Worktree\*\*:' "$f" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
DEPS=$(grep -E '^- \*\*Dependencies\*\*:' "$f" | sed -E 's/.*Dependencies\*\*:[[:space:]]*//')
[ "$DEPS" = "none" ] || [ -z "$DEPS" ] && return 0

for dep_id in $(echo "$DEPS" | tr ',' '\n' | tr -d '[:space:]'); do
  dep_file=$(ls .backlog/accepted/${dep_id}*.md 2>/dev/null | head -1)
  [ -z "$dep_file" ] && return 1   # dep not accepted
  dep_slug=$(grep -E '^- \*\*Worktree\*\*:' "$dep_file" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
  if [ "$dep_slug" != "$THIS_SLUG" ] && [ "$dep_slug" != "none" ]; then
    # Cross-slug code dep: blocks only while genuinely pending integration — accepted, a live
    # worktree/<slug> branch, and no ledger marker on trunk. A branchless historical dep is already
    # on trunk (satisfied); a non-code "none" dep never integrates (satisfied).
    if ! acfw_is_integrated "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH" "$(basename "$dep_file" .md)" \
       && git -C "$ACFW_TRUNK_ROOT" show-ref --verify --quiet "refs/heads/worktree/$dep_slug"; then
      return 1
    fi
  fi
done
return 0
```

### Step 4b: Spawn one specialist per worktree-group

For each task in `DISPATCH_QUEUE`, spawn the assigned specialist. All spawns happen in parallel because each operates on a distinct `Worktree:` slug, hence a distinct branch and worktree. There is no shared `.git/index` between them.

The orchestrator pre-moves each task `pending → in-progress` at root (single writer, atomic), then dispatches:

```bash
for f in "${DISPATCH_QUEUE[@]}"; do
  fname=$(basename "$f")
  TS=$(date -u +"%Y-%m-%d %H:%M:%S")
  printf '| %s | pending | in-progress | orchestrator | dispatch |\n' "$TS" >> "$f"
  mv "$f" "$ACFW_TRUNK_ROOT/.backlog/in-progress/$fname"
  git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" add ".backlog/pending/$fname" ".backlog/in-progress/$fname"
  git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" commit -m "task: $fname pending -> in-progress" --quiet
done
```

Then issue Task() calls in a single message (one per slug), passing the **root path** as `TASK_FILE`. The specialist prompt explicitly forbids moving the task file:

```markdown
Agent 1 (Worktree: alpha): go-engineer
  TASK_FILE=$ACFW_TRUNK_ROOT/.backlog/in-progress/feature-003.md
  Rules: invoke clean-checkout-before-task as Step 0; do code work
  inside .worktree/alpha; do NOT move the task file or commit any
  .backlog/ changes; end your response with the ACFW-RESULT marker.
Agent 2 (Worktree: beta): react-engineer (same rules)
Agent 3 (Worktree: gamma): quality-reviewer (same rules; transition is accepted | rejected)
```

After all Task() calls return, the orchestrator parses each agent's ACFW-RESULT marker and calls `acfw_apply_result` to perform the corresponding `.backlog/` move at root (in-progress→completed, or accepted→rejected, etc.).

**Within-group serialization**: tasks sharing a slug are NOT dispatched in the same iteration; they wait until the in-progress task in their slug terminates.

### Agent Type Selection

| Transition | Performed by | Notes |
|------------|--------------|-------|
| retry (rejected→pending) | task-engineer at root | Adjusts rejection_count narrative; orchestrator commits the move on trunk after task-engineer returns. task-engineer NEVER enters a worktree. |
| unblock (blocked→pending) | task-engineer at root | Validates dependencies satisfied (cross-slug deps need their ledger marker on trunk). |
| dispatch (pending→in-progress) | **orchestrator** at root, before Task() | Single writer; atomic mv + commit on trunk before specialist starts. |
| start work | specialist agent inside worktree | Reads task at root path; does code work in `.worktree/<slug>`; commits CODE only on `worktree/<slug>`; never moves task file. Returns ACFW-RESULT. |
| in-progress→completed | **orchestrator** at root, on specialist's `transition: completed` signal | acfw_apply_result moves + commits on trunk. |
| in-progress→blocked | **orchestrator** at root, on specialist's `transition: blocked` signal | Same. |
| completed→in-review | **orchestrator** at root, before reviewer Task() | Pre-move + commit on trunk (mirrors dispatch). |
| in-review→accepted | **orchestrator** at root, on reviewer's `transition: accepted` signal | acfw_apply_result. |
| in-review→rejected | **orchestrator** at root, on reviewer's `transition: rejected` signal | acfw_apply_result; increments Rejection Count. |
| timeout (in-progress→blocked, stale past `ACFW_INPROGRESS_TIMEOUT_HOURS`, default 8h) | orchestrator at root | Synthesizes a `transition: blocked` with notes "timeout >=Nh — stale dispatch". |

**The orchestrator is the only writer of `.backlog/` files.** Specialists' worktree-side commits contain code only. task-engineer transitions execute serially at root (no code mutation).

### Specialist Agent Assignment

Read `assigned_agent` field from task metadata:
- `go-engineer`: Go backend tasks
- `python-engineer`: Python backend tasks
- `react-engineer`: React frontend tasks
- `nextjs-engineer`: Next.js tasks
- etc.

If no specialist assigned, use task-engineer for guidance.

---

## Step 4.5: Integrate Newly-Accepted (default mode only)

After dispatch returns and specialists have moved their tasks to `.backlog/accepted/`, land every newly-accepted task onto the live trunk with the **LP-CAS integrator**, one task at a time. The orchestrator (this skill, running as the parent agent) is the **only writer of trunk's `.git/index`**; no parallelism here.

**Skip this step entirely in override mode** — pinned via `ACFW_INTEGRATION_MODE=override`, or directed by project instructions (CLAUDE.md, AGENTS.md, etc.) when unpinned. In that case no ledger marker is ever written, the operator handles integration, and the loop's terminal check falls back to `accepted ∪ blocked`.

The skip is **executable, not advisory**. Until 3.2.1 it was prose only: `ACFW_INTEGRATION_OVERRIDE` gated the terminal counts and the post-loop drain but *not* this step, so a correctly-pinned override run still cherry-picked every accepted task onto the local trunk — the pin changed how tasks were counted and nothing about where the code went.

**Run this check before Step 4.5a.** If it prints the skip line, do not run 4.5a or 4.5b at all — go straight to Step 5:

```bash
if [ "${ACFW_INTEGRATION_OVERRIDE:-}" = "1" ]; then
  echo "⏭️  Step 4.5 skipped (override mode) — accepted tasks stay on worktree/<slug> for you to PR."
fi
```

**If the mode is unpinned and you decided `override` by reading project instructions**, then `export ACFW_INTEGRATION_OVERRIDE=1` yourself during Pre-Loop. That one switch is what the terminal counts (Step 5), the post-loop drain, and this guard all read — set it and they agree; leave it unset while acting as if in override mode and the loop will still fold every accepted task into trunk.

The integrator mutates **only git** (the trunk ref + a disposable integration worktree). It never moves a task file — `.backlog/` moves stay the orchestrator's job (see exit 6 below).

### Step 4.5a: Topologically sort unintegrated accepted tasks

Enqueue every accepted task that has a code slug, a live `worktree/<slug>` branch, and **no ledger marker on trunk**. Sort so that, for any cross-slug dep, the dep integrates first (Kahn's algorithm over the dep edges among queue members).

```bash
declare -a INTEGRATE_QUEUE
for f in .backlog/accepted/*.md; do
  [ -f "$f" ] || continue
  slug=$(grep -E '^- \*\*Worktree\*\*:' "$f" | head -1 | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
  { [ -z "$slug" ] || [ "$slug" = "none" ]; } && continue
  acfw_is_integrated "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH" "$(basename "$f" .md)" && continue
  git -C "$ACFW_TRUNK_ROOT" show-ref --verify --quiet "refs/heads/worktree/$slug" && INTEGRATE_QUEUE+=("$f")
done
```

### Step 4.5b: Integrate sequentially

`ACFW_TRUNK_ROOT` and `ACFW_TRUNK_BRANCH` must be exported (Pre-Loop). Optionally export `ACFW_GATE_CMD` (the project's union quality gate, run with CWD = the candidate tree) and `ACFW_PARSE_SANITY_CMD` (a cheap parse/lint check, run before the heavy gate so a botched conflict resolution surfaces as a mechanism fault, not a coverage regression).

```bash
LP="${CLAUDE_PLUGIN_ROOT}/skills/integrate-lpcas/bin/integrate-lpcas.sh"
for task_file in "${SORTED_QUEUE[@]}"; do
  OUT=$(bash "$LP" "$task_file"); rc=$?
  # rc 7: OUT carries `worktree:`, `assigned_agent:`, and a `conflicted_files:` block. Dispatch that
  # agent into that worktree as a conflict resolver (see below), then resume the SAME attempt:
  [ $rc -eq 7 ] && { bash "$LP" --post-resolver "$task_file"; rc=$?; }
done
```

Map each exit code exactly as `workflows/whip-go.workflow.js` does:

| exit | outcome | orchestrator action |
|------|---------|---------------------|
| 0 | integrated / already-integrated | Change + marker are on trunk. Nothing to write. |
| 3 | contaminated (quarantine) | Malformed or poison candidate. **Park this task for an operator**; do not retry, do not reject the others. |
| 4 | skipped | No candidate ref — historical task already on trunk. Terminal; do not retry. |
| 6 | rejected (quality-fault) | The union gate failed on the candidate tree. **You** move `accepted → rejected` and increment Rejection Count, so the task re-enters the rejection self-heal instead of being re-queued as a candidate every iteration. |
| 7 | resolver-needed | Cherry-pick conflict. Dispatch the resolver, then re-invoke `--post-resolver`. |
| 9, 11, 12, 99 | transient | Mechanism fault / `cas-lost` / trunk unobservable / git lock. **Never** a quality reject: leave the task accepted and retry next iteration. |

Only exit 6 consumes the rejection budget. A conflict (7) or a mechanism fault (9) never does.

### Resolver dispatch (exit 7 only)

The integration worktree printed on the `worktree:` line is a **detached** checkout of the live trunk tip, mid-cherry-pick. Dispatch the task's `assigned_agent` into it via the Task tool with exactly this contract:

- **Allowed**: edit the conflicted files in place, then `git -C <worktree> add <file>` for each. Preserve **both** intents (the task's change and what is already on trunk).
- **Forbidden**: `git cherry-pick --continue` / `--commit` / `--abort` / `--quit` (the integrator owns the commit); `git reset`, `checkout`/`switch` to another commit, `rebase`, deleting the worktree; editing anything under `.backlog/` or `.acfwhip/`.
- If the conflict is genuinely irreconcilable, leave the markers **unstaged** — `--post-resolver` then reports a mechanism fault (exit 9) and the task stays accepted for a later attempt.

Resolver dispatch is hoisted to the orchestrator because bash cannot spawn a subagent. Everything else — the already-integrated check, the single-parent and poison guards, the marker co-commit, the sanity + union gate, and the compare-and-swap land — belongs to the script.

---

## Step 5: Check Completion

After all agents complete in iteration AND Step 4.5 has integrated newly-accepted tasks:

```bash
# Count terminal states. Override mode: accepted alone is terminal. Default mode: an accepted task
# is terminal once nothing remains to fold into trunk — its LEDGER MARKER is on trunk, OR it is
# non-code ("none"), OR it has no worktree/<slug> branch (historical, already on trunk). = accepted
# MINUS those still pending integration (a live branch, no marker). Mirrors the workflow's isTerminal.
accepted_count=$(ls -1 .backlog/accepted/*.md 2>/dev/null | wc -l | tr -d ' ')
blocked_count=$(ls -1 .backlog/blocked/*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$ACFW_INTEGRATION_OVERRIDE" = "1" ]; then
  integrated_count=$accepted_count   # treat accepted as terminal in override mode
  terminal_count=$((accepted_count + blocked_count))
else
  integrated_count=0; pending_integration=0
  for f in .backlog/accepted/*.md; do
    [ -f "$f" ] || continue
    if acfw_is_integrated "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH" "$(basename "$f" .md)"; then
      integrated_count=$((integrated_count + 1)); continue
    fi
    slug=$(grep -E '^- \*\*Worktree\*\*:' "$f" | head -1 | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
    { [ -z "$slug" ] || [ "$slug" = "none" ]; } && continue
    git -C "$ACFW_TRUNK_ROOT" show-ref --verify --quiet "refs/heads/worktree/$slug" && pending_integration=$((pending_integration + 1))
  done
  terminal_count=$((accepted_count + blocked_count - pending_integration))
fi

# Denominator = the 7 ACTIVE folders only (draft/ and archive/ are excluded from automation).
total_count=$(ls -1 \
  .backlog/pending/*.md .backlog/in-progress/*.md .backlog/completed/*.md .backlog/in-review/*.md \
  .backlog/blocked/*.md .backlog/rejected/*.md .backlog/accepted/*.md 2>/dev/null \
  | grep -vE '/README\.md$' | wc -l | tr -d ' ')

echo "📊 Progress: $terminal_count / $total_count terminal ($integrated_count integrated, $accepted_count accepted, $blocked_count blocked)"
```

### Exit Conditions

**SUCCESS: 100% Complete**
```bash
if [ $terminal_count -eq $total_count ] && [ $total_count -gt 0 ]; then
  echo "✅ Backlog 100% complete!"
  echo "   Integrated: $integrated_count"
  echo "   Accepted (unintegrated): $((accepted_count - integrated_count))"
  echo "   Blocked: $blocked_count"
  exit 0
fi
```

**CONTINUE: Work Remaining**
```bash
if [ $terminal_count -lt $total_count ]; then
  echo "⏳ Work remaining. Continuing to next iteration..."
  # Loop continues
fi
```

**INTERVENTION: No Progress**
```bash
if [ $no_progress_count -ge 3 ]; then
  echo "⚠️  No progress for 3 iterations."
  echo "   Manual intervention needed."
  echo "   Review blocked tasks in .backlog/blocked/"
  exit 1
fi
```

**ABORT: Infinite Loop Prevention**
```bash
if [ $iteration -ge $max_iterations ]; then
  echo "❌ Maximum iterations reached ($max_iterations)"
  echo "   Aborting to prevent infinite loop."
  echo "   Review workflow state and blocked tasks."
  exit 1
fi
```

---

## Step 6: Loop Continuation

If completion check passes, return to Step 1 for next iteration:

```bash
echo "🔄 Starting iteration $((iteration + 1))..."
# Return to Step 1: Quality Gate Auto-Fix
```

---

## Post-Loop: Final Integration Drain (default mode)

Defensive: in case the last iteration accepted tasks but exited the loop before reaching Step 4.5 (e.g. progress-detector early-exit), run the integration step once more before returning. Skip in override mode.

```bash
if [ "$ACFW_INTEGRATION_OVERRIDE" != "1" ]; then
  LP="${CLAUDE_PLUGIN_ROOT}/skills/integrate-lpcas/bin/integrate-lpcas.sh"
  for f in .backlog/accepted/*.md; do
    [ -f "$f" ] || continue
    acfw_is_integrated "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH" "$(basename "$f" .md)" && continue
    slug=$(grep -E '^- \*\*Worktree\*\*:' "$f" | head -1 | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
    { [ -z "$slug" ] || [ "$slug" = "none" ]; } && continue
    # Defensive drain. An exit 7 (resolver-needed) here is left for the next /go run rather than
    # dispatching a resolver post-loop; a branchless historical task has no branch to fold (skip).
    git -C "$ACFW_TRUNK_ROOT" show-ref --verify --quiet "refs/heads/worktree/$slug" && bash "$LP" "$f" >/dev/null 2>&1 || true
  done
fi
```

---

## Priority Enforcement (Optional)

If using 5-level priority system with SLAs:

### Priority Processing Order

1. **blocker**: Process ALL before any other priority (sequential within chain)
2. **critical**: Process ALL before high/medium/low (sequential)
3. **high**: Can run parallel with other high
4. **medium/low**: Full parallel execution

```bash
# Filter pending tasks by priority
blocker_tasks=$(grep -l "Priority.*blocker" .backlog/pending/*.md 2>/dev/null || echo "")
critical_tasks=$(grep -l "Priority.*critical" .backlog/pending/*.md 2>/dev/null || echo "")
high_tasks=$(grep -l "Priority.*high" .backlog/pending/*.md 2>/dev/null || echo "")
```

Process in order: blocker → critical → high → medium/low

---

## State Transition Authority

| From | To | WHO performs transition |
|------|----|-------------------------|
| N/A | pending | task-engineer |
| pending | in-progress | Specialist agent |
| in-progress | completed | Specialist agent |
| in-progress | blocked | Specialist agent or timeout |
| completed | in-review | quality-reviewer |
| in-review | accepted | quality-reviewer |
| in-review | rejected | quality-reviewer |
| rejected | pending | task-engineer (retry) |
| rejected | blocked | task-engineer (≥3 retries) |
| blocked | pending | task-engineer (resolved) |

**The agent DOING the work moves the file and updates the transition log.**

---

## Quality Gate Protocol

Each specialist agent MUST run quality gates before marking task complete:

```bash
# Example: Go quality gates
golangci-lint run ./...
go test ./... -v -race -cover
go build ./...
```

**Failure Protocol**:
- Attempts 1-10: Fix actual issues
- After 10 attempts: Move to blocked with failure report

See stack-specific quality gates: `docs/development/quality-gates-{stack}.md`

---

## Success Criteria

✅ Loops until 100% terminal states
✅ Quality gate auto-fix runs each iteration
✅ ALL state transitions processed each iteration
✅ Agents spawned in parallel for independent tasks
✅ Completion checked after each iteration
✅ Exits on 100% complete OR intervention needed

---

## Example Execution Output

```
🔥 /go - Continuous Backlog Execution Started

🔄 Iteration 1

🔧 Auto-fixing quality gates (Go)...
✓ gofmt applied
✓ go mod tidy completed
✓ Changes stashed

📊 Scanning workflow states...
✓ Pending: 5 tasks
✓ In-progress: 0 tasks
✓ Completed: 0 tasks
✓ In-review: 0 tasks
✓ Rejected: 0 tasks
✓ Blocked: 0 tasks

⚡ Processing transitions...
✓ TodoWrite: 5 start transitions

🚀 Spawning agents (parallel)...
→ Agent 1: go-engineer for feature-001
→ Agent 2: go-engineer for feature-002
→ Agent 3: react-engineer for feature-003
→ Agent 4: go-engineer for feature-004
→ Agent 5: go-engineer for feature-005

[Agents execute...]

📊 Progress: 0 / 5 terminal (0 accepted, 0 blocked)
⏳ Work remaining. Continuing to next iteration...

---

🔄 Iteration 2

🔧 Auto-fixing quality gates (Go)...
✓ No changes needed

📊 Scanning workflow states...
✓ Pending: 0 tasks
✓ In-progress: 3 tasks
✓ Completed: 2 tasks
✓ In-review: 0 tasks
✓ Rejected: 0 tasks
✓ Blocked: 0 tasks

⚡ Processing transitions...
✓ TodoWrite: 2 review transitions

🚀 Spawning agents...
→ Agent 1: quality-reviewer for feature-001
→ Agent 2: quality-reviewer for feature-002

[Agents execute...]

📊 Progress: 2 / 5 terminal (2 accepted, 0 blocked)
⏳ Work remaining. Continuing to next iteration...

---

🔄 Iteration 3

📊 Scanning workflow states...
✓ Pending: 0 tasks
✓ In-progress: 0 tasks
✓ Completed: 3 tasks
✓ In-review: 0 tasks
✓ Rejected: 0 tasks
✓ Blocked: 0 tasks

⚡ Processing transitions...
✓ TodoWrite: 3 review transitions

🚀 Spawning agents...
→ Agent 1: quality-reviewer for feature-003
→ Agent 2: quality-reviewer for feature-004
→ Agent 3: quality-reviewer for feature-005

[Agents execute...]

📊 Progress: 5 / 5 terminal (5 accepted, 0 blocked)

✅ Backlog 100% complete!

📊 Final Statistics:
   Total tasks: 5
   Accepted: 5 (100%)
   Blocked: 0 (0%)
   Iterations: 3
   Time: ~15 minutes

🎉 All tasks successfully completed!
```

---

## Anti-Patterns

### ❌ Single Pass Execution

**Never**: Process one iteration and exit
**Always**: Loop until 100% complete

### ❌ Manual Intervention Per Task

**Never**: Ask user after each task (one confirmation at launch for a natural-language scope filter
is fine and expected — see step 3; what is forbidden is interrupting *between* tasks)
**Always**: Fire-and-forget until completion or blockage

### ❌ Skipping Quality Gate Auto-Fix

**Never**: Process tasks with known quality issues
**Always**: Run auto-fix first to eliminate trivial failures

### ❌ Sequential Processing

**Never**: Process one task at a time
**Always**: Spawn agents in parallel for independent tasks

---

## Error Handling

**Infinite Loop Prevention**:
- Max 1000 iterations
- Exit if no progress for 3 iterations

**Workflow Violations**:
- Tasks stuck in in-review (quality-reviewer didn't terminate)
- Circular dependencies
- Missing assigned agents

**Quality Gate Failures**:
- Auto-fix applied
- Specialist retries (max 10)
- Move to blocked after failures

**User Intervention Needed**:
- No progress for 3 iterations
- All non-blocked tasks stuck
- Circular dependency detected
