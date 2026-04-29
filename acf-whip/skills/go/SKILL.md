---
name: go
description: Continuous backlog execution until 100% tasks reach terminal states (accepted/blocked)
allowed-tools:
  - Bash
  - Glob
  - Read
  - TodoWrite
  - Task
---

# /go - Continuous Backlog Execution

Fire-and-forget automation. Processes ENTIRE backlog without manual intervention until 100% complete.

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

## Integration mode

**Default**: at the end of each iteration, the orchestrator folds every newly-accepted worktree branch into the branch checked out at the repo root (the local trunk) via the `integrate-worktree` skill. Linear history; conflicts resolved intelligently by the task's `assigned_agent`.

**Override**: if the project's `CLAUDE.md` (or any other persistent agent instructions) directs a different integration strategy — for example "open a PR per PR Group via `gh pr create` instead of merging locally" — follow those instructions and skip Step 4.5. In that mode, the loop reverts to the 1.2.0 terminal check (`accepted ∪ blocked`); operator handles integration.

The orchestrator decides which mode to use by reading project instructions (already loaded into Claude's context); no plugin code special-cases the override.

---

## Continuous Execution Loop

```yaml
PRE-LOOP: Capture trunk identity (refuse on detached HEAD).
WHILE (terminal_tasks < total_tasks):
  iteration++
  1. Quality Gate Auto-Fix (stack-specific)
  2. Scan ALL Workflow States
  3. Process ALL Transitions (TodoWrite single call), gating on dependencies
  4. Partition pending by Worktree slug; dispatch one specialist per slug (parallel across slugs)
  4.5. Integrate Newly-Accepted (default mode): topo-sort by deps; merge into local trunk
  5. Check Completion (exit if 100%, else CONTINUE)
  6. Prevent Infinite Loop (max 1000 iterations)
POST-LOOP: Final integration drain (defensive).
```

---

## Pre-Loop: Capture Trunk Identity

Before iteration begins, snapshot the branch checked out at the repo root and export it as environment variables for every dispatched skill (`clean-checkout-before-task`, `integrate-worktree`).

```bash
export ACFW_TRUNK_ROOT=$(git rev-parse --show-toplevel)
export ACFW_TRUNK_BRANCH=$(git -C "$ACFW_TRUNK_ROOT" symbolic-ref --short HEAD 2>/dev/null)
export ACFW_TRUNK_SHA_AT_START=$(git -C "$ACFW_TRUNK_ROOT" rev-parse HEAD)

if [ -z "$ACFW_TRUNK_BRANCH" ]; then
  echo "❌ FATAL: HEAD is detached at $ACFW_TRUNK_ROOT. /go requires a branch checked out at the repo root." >&2
  exit 1
fi
echo "🌳 Trunk: $ACFW_TRUNK_BRANCH @ $ACFW_TRUNK_SHA_AT_START"
```

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

  # Count terminal tasks. In default (auto-merge) mode, an accepted task is terminal
  # only if its Integrated-At: is set. In override (PR) mode, accepted alone is terminal.
  if [ "$ACFW_INTEGRATION_OVERRIDE" = "1" ]; then
    terminal_count=$(ls -1 .backlog/accepted/*.md .backlog/blocked/*.md 2>/dev/null | wc -l)
  else
    integrated_count=$(grep -lE '^- \*\*Integrated-At\*\*:[[:space:]]*[0-9a-f]{7,}' .backlog/accepted/*.md 2>/dev/null | wc -l)
    blocked_count=$(ls -1 .backlog/blocked/*.md 2>/dev/null | wc -l)
    terminal_count=$((integrated_count + blocked_count))
  fi
  total_count=$(find .backlog -name "*.md" ! -path "*/.git/*" ! -name "README.md" ! -name ".gitkeep" | wc -l)

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

## Step 1: Quality Gate Auto-Fix (PRE-PROCESSING)

Before processing ANY tasks, attempt to fix common quality issues automatically.

### Go

```bash
echo "🔧 Auto-fixing quality gates (Go)..."
gofmt -w .
goimports -w . 2>/dev/null || true
go mod tidy
go test ./... || true  # Don't fail on test errors
git stash push -m "acf-whip-go-autofixes" || true
```

### Python

```bash
echo "🔧 Auto-fixing quality gates (Python)..."
ruff check . --fix || true
ruff format . || true
git stash push -m "acf-whip-go-autofixes" || true
```

### Node.js/TypeScript

```bash
echo "🔧 Auto-fixing quality gates (Node.js)..."
npm run lint -- --fix 2>/dev/null || true
npm run format 2>/dev/null || true
git stash push -m "acf-whip-go-autofixes" || true
```

### Next.js/React

```bash
echo "🔧 Auto-fixing quality gates (Next.js)..."
pnpm lint --fix 2>/dev/null || true
pnpm format 2>/dev/null || true
rm -rf .next 2>/dev/null || true  # Clear build cache
git stash push -m "acf-whip-go-autofixes" || true
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
- **Cross-slug dep** (different `Worktree:` slug): `dep` must be in `.backlog/accepted/` **AND** have a non-empty `Integrated-At:` field, i.e. its commits are on the local trunk. Acceptance alone is not enough — the dependent's worktree only sees cross-slug commits after `clean-checkout-before-task` Step 5 fast-forwards from the now-advanced trunk.

In override (PR) mode, where there is no `Integrated-At:` field because no auto-merge happens, treat acceptance as sufficient for cross-slug deps too (operator is responsible for ordering).

```javascript
{
  content: "Process feature-003 (pending→in-progress, deps integrated)",
  status: "pending",
  activeForm: "Processing feature-003"
}
```

#### D. Review Completed Tasks (MANDATORY)

For each task in `.backlog/completed/`:
1. **MANDATORY**: Trigger quality review
2. quality-reviewer moves to accepted/rejected

```javascript
{
  content: "Review feature-004 (completed→in-review→[accepted|rejected])",
  status: "pending",
  activeForm: "Reviewing feature-004"
}
```

#### E. Timeout In-Progress Tasks (48h)

For each task in `.backlog/in-progress/`:
1. Read timestamp from transition log
2. If >48 hours: Timeout (in-progress→blocked)

```javascript
{
  content: "Timeout feature-005 (in-progress→blocked, >48h)",
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
  [ -z "$slug" ] && continue   # research/docs-only tasks; dispatch directly without partitioning
  [ -n "${IN_PROGRESS_SLUGS[$slug]:-}" ] && continue   # group already busy
  [ -n "${SEEN_SLUGS[$slug]:-}" ] && continue   # already picked one task from this group this iteration
  # Apply dependency-gating rule (see Step 3): skip if any dep unsatisfied.
  # Cross-slug dep needs Integrated-At; same-slug dep needs accepted/.
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
  if [ "$dep_slug" != "$THIS_SLUG" ]; then
    # Cross-slug: require Integrated-At
    integrated=$(grep -E '^- \*\*Integrated-At\*\*:' "$dep_file" | sed -E 's/.*Integrated-At\*\*:[[:space:]]*//' | tr -d '[:space:]')
    [ -z "$integrated" ] && return 1
  fi
done
return 0
```

### Step 4b: Spawn one specialist per worktree-group

For each task in `DISPATCH_QUEUE`, spawn the assigned specialist. All spawns happen in parallel because each operates on a distinct `Worktree:` slug, hence a distinct branch and worktree. There is no shared `.git/index` between them.

Use a single message with one Task call per `DISPATCH_QUEUE` entry:

```markdown
Agent 1 (Worktree: alpha): go-engineer for implement feature-003
Agent 2 (Worktree: beta): react-engineer for implement feature-007
Agent 3 (Worktree: gamma): quality-reviewer for review feature-004
```

**Within-group serialization**: tasks sharing a slug are NOT dispatched in the same iteration; they wait until the in-progress task in their slug terminates.

### Agent Type Selection

| Transition | Agent Type | Purpose | Honors Worktree partition? |
|------------|------------|---------|----------------------------|
| retry (rejected→pending) | task-engineer | Handle retry, update rejection_count | No (no code mutation) |
| unblock (blocked→pending) | task-engineer | Resolve blocker, validate dependencies | No |
| start (pending→in-progress) | **specialist agent** | Implement task (go-engineer, react-engineer, etc.); MUST invoke clean-checkout-before-task as Step 0 | **Yes** |
| review (completed→in-review→[accepted\|rejected]) | quality-reviewer | Accept or reject; MUST verify clean-checkout token | **Yes** |
| timeout (in-progress→blocked) | task-engineer | Document timeout reason, create blocker report | No |

task-engineer transitions execute serially on `main` (they only mutate `.backlog/`, no code). Specialist and quality-reviewer transitions execute in parallel only across distinct `Worktree:` slugs.

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

After dispatch returns and specialists have moved their tasks to `.backlog/accepted/`, fold every newly-accepted worktree into the local trunk. The orchestrator (this skill, running as the parent agent) is the **only writer of trunk's `.git/index`**; no parallelism here.

**Skip this step entirely if project instructions (CLAUDE.md, AGENTS.md, etc.) direct a different integration strategy** (e.g. "open a PR per PR Group via `gh pr create` instead"). In that case, leave accepted tasks with empty `Integrated-At:` and let the operator handle integration; the loop's terminal check falls back to `accepted ∪ blocked`.

### Step 4.5a: Topologically sort unintegrated accepted tasks

Read `.backlog/accepted/*.md`. For each task whose `Integrated-At:` is empty, add it to the integration queue. Sort the queue so that, for any cross-slug dep, the dep is integrated before the dependent. Same-slug ordering is implicit (rebase preserves intra-branch order).

```bash
declare -a INTEGRATE_QUEUE
for f in .backlog/accepted/*.md; do
  [ -f "$f" ] || continue
  integrated=$(grep -E '^- \*\*Integrated-At\*\*:' "$f" | sed -E 's/.*Integrated-At\*\*:[[:space:]]*//' | tr -d '[:space:]')
  [ -z "$integrated" ] && INTEGRATE_QUEUE+=("$f")
done

# Topo-sort INTEGRATE_QUEUE by cross-slug deps (dep first). Implementation: simple
# Kahn's algorithm over the dep edges among queue members.
```

### Step 4.5b: Integrate sequentially

```bash
for task_file in "${SORTED_QUEUE[@]}"; do
  if Skill integrate-worktree "$task_file"; then
    echo "✓ integrated: $(basename "$task_file" .md)"
  else
    rc=$?
    if [ $rc -eq 6 ]; then
      echo "✗ resolver failed: $(basename "$task_file" .md) → rejected/, will retry next iteration"
    elif [ $rc -eq 10 ]; then
      echo "↻ transient: $(basename "$task_file" .md) → leave accepted, retry next iteration"
    else
      echo "⚠ integrate-worktree exit $rc on $(basename "$task_file" .md)"
    fi
  fi
done
```

The orchestrator invokes the `integrate-worktree` skill once per task. The skill itself owns the FF → rebase → resolver-dispatch ladder, the cleanup of empty worktrees, and writing `Integrated-At:` on success.

---

## Step 5: Check Completion

After all agents complete in iteration AND Step 4.5 has integrated newly-accepted tasks:

```bash
# Count terminal states. Default mode: accepted tasks must have Integrated-At set.
if [ "$ACFW_INTEGRATION_OVERRIDE" = "1" ]; then
  accepted_count=$(ls -1 .backlog/accepted/*.md 2>/dev/null | wc -l)
  integrated_count=$accepted_count   # treat accepted as terminal in override mode
else
  accepted_count=$(ls -1 .backlog/accepted/*.md 2>/dev/null | wc -l)
  integrated_count=$(grep -lE '^- \*\*Integrated-At\*\*:[[:space:]]*[0-9a-f]{7,}' .backlog/accepted/*.md 2>/dev/null | wc -l)
fi
blocked_count=$(ls -1 .backlog/blocked/*.md 2>/dev/null | wc -l)
terminal_count=$((integrated_count + blocked_count))

# Count total tasks
total_count=$(find .backlog -name "*.md" ! -path "*/.git/*" ! -name "README.md" ! -name ".gitkeep" | wc -l)

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
  for f in .backlog/accepted/*.md; do
    [ -f "$f" ] || continue
    integrated=$(grep -E '^- \*\*Integrated-At\*\*:' "$f" | sed -E 's/.*Integrated-At\*\*:[[:space:]]*//' | tr -d '[:space:]')
    [ -z "$integrated" ] && Skill integrate-worktree "$f"
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

**Never**: Ask user after each task
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
