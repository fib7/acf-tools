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
1. Loop until ALL tasks in terminal states (accepted/blocked)
2. Process ALL state transitions each iteration
3. Partition pending tasks by `Worktree:` slug; dispatch at most one specialist per slug, in parallel across slugs
4. Quality gate auto-fix before processing
5. Exit only when 100% complete OR user intervention needed

**CRITICAL**: This command does NOT terminate after one pass. It continues looping until backlog complete.

---

## Continuous Execution Loop

```yaml
WHILE (terminal_tasks < total_tasks):
  iteration++
  1. Quality Gate Auto-Fix (stack-specific)
  2. Scan ALL Workflow States
  3. Process ALL Transitions (TodoWrite single call)
  4. Partition pending by Worktree slug; dispatch one specialist per slug (parallel across slugs)
  5. Check Completion (exit if 100%, else CONTINUE)
  6. Prevent Infinite Loop (max 1000 iterations)
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

  # Check completion
  terminal_count=$(ls -1 .backlog/accepted/*.md .backlog/blocked/*.md 2>/dev/null | wc -l)
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
1. Read `dependencies` from task metadata
2. Check if all dependencies in `.backlog/accepted/`
3. If resolved: Unblock (blocked→pending)

```javascript
{
  content: "Unblock feature-002 (dependencies resolved: feature-001)",
  status: "pending",
  activeForm: "Unblocking feature-002"
}
```

#### C. Start Pending Tasks

For each task in `.backlog/pending/`:
1. Check no blocking dependencies
2. Check priority (process by priority order)
3. Queue for start (pending→in-progress)

```javascript
{
  content: "Process feature-003 (pending→in-progress)",
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
  SEEN_SLUGS["$slug"]=1
  DISPATCH_QUEUE+=("$f")
done
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

## Step 5: Check Completion

After all agents complete in iteration:

```bash
# Count terminal states
accepted_count=$(ls -1 .backlog/accepted/*.md 2>/dev/null | wc -l)
blocked_count=$(ls -1 .backlog/blocked/*.md 2>/dev/null | wc -l)
terminal_count=$((accepted_count + blocked_count))

# Count total tasks
total_count=$(find .backlog -name "*.md" ! -path "*/.git/*" ! -name "README.md" ! -name ".gitkeep" | wc -l)

echo "📊 Progress: $terminal_count / $total_count terminal ($accepted_count accepted, $blocked_count blocked)"
```

### Exit Conditions

**SUCCESS: 100% Complete**
```bash
if [ $terminal_count -eq $total_count ] && [ $total_count -gt 0 ]; then
  echo "✅ Backlog 100% complete!"
  echo "   Accepted: $accepted_count"
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
