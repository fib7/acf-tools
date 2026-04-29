---
name: integrate-worktree
description: Fold a single accepted worktree branch into the local trunk (the branch checked out at the repo root). Tries fast-forward; on non-FF rebases the worktree onto trunk; on rebase conflict dispatches the task's assigned specialist as a conflict resolver inside the worktree. On success writes Integrated-At to the task and removes the worktree if no more pending tasks share the slug. Invoked exclusively by /go's orchestrator; never by specialists.
allowed-tools:
  - Bash
  - Read
  - Task
---

# /integrate-worktree

Single-slug integration primitive. The orchestrator (`/go`) calls this once per accepted-but-unintegrated task, sequentially, in dependency-topological order. Specialists never call this — they never write to trunk's `.git/index`.

The mechanism: fast-forward `worktree/<slug>` into the local trunk branch (captured at `/go` startup as `$ACFW_TRUNK_BRANCH` in `$ACFW_TRUNK_ROOT`). If FF is impossible because trunk has advanced, rebase the worktree onto trunk and retry FF. If the rebase produces conflicts, dispatch the task's `assigned_agent` as a conflict resolver in the worktree, with full context of the conflicting commits and their source tasks; on resolution, retry FF. If the resolver fails, route the task back to `.backlog/rejected/` so the existing retry/block machinery handles it.

**Default applies unless project instructions override.** If the project's `CLAUDE.md` (or any other persistent agent instructions) directs a different integration strategy — e.g. "open a PR per PR Group via `gh pr create` instead of merging locally" — the orchestrator follows those instructions and does not invoke this skill, per Claude's instruction-priority hierarchy.

---

## Inputs

- `TASK_FILE`: absolute path to a task markdown file in `.backlog/accepted/` (front-matter `Integrated-At:` empty).
- `ACFW_TRUNK_ROOT`: env var, set by `/go` at startup; absolute path to the repo root checkout.
- `ACFW_TRUNK_BRANCH`: env var, set by `/go` at startup; the branch checked out at `$ACFW_TRUNK_ROOT`.

## Outputs

- On success: `Integrated-At: <new-trunk-sha>` written to task front-matter; transition-log line appended; task remains in `.backlog/accepted/`. If no more tasks share the slug, the worktree is removed and the local branch deleted.
- On unresolvable conflict: task moved to `.backlog/rejected/` with `Rejection Count` incremented and a `conflict-unresolved` transition-log line; existing `/go` retry machinery picks it up next iteration.

---

## Protocol

### Step 1: Resolve task fields

```bash
TASK_FILE="$1"
SLUG=$(grep -E '^- \*\*Worktree\*\*:' "$TASK_FILE" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
ASSIGNED_AGENT=$(grep -E '^- \*\*Assigned Agent\*\*:' "$TASK_FILE" | sed -E 's/.*Assigned Agent\*\*:[[:space:]]*//' | tr -d '[:space:]')
TASK_ID=$(basename "$TASK_FILE" .md)

if [ -z "$SLUG" ]; then
  echo "FATAL: $TASK_FILE has no Worktree: field; cannot integrate." >&2
  exit 1
fi

WORKTREE="$ACFW_TRUNK_ROOT/.worktree/$SLUG"
BRANCH="worktree/$SLUG"
```

### Step 2: Fetch the worktree branch into trunk's refs

Cheap; no working-tree change in trunk.

```bash
git -C "$ACFW_TRUNK_ROOT" fetch . "$BRANCH:refs/acfw/$SLUG" --quiet || {
  echo "WARN: fetch $BRANCH failed; will retry next iteration" >&2
  exit 10  # transient; orchestrator leaves task accepted, retries next iter
}
```

### Step 3: Try fast-forward into trunk

```bash
TRUNK_SHA_BEFORE=$(git -C "$ACFW_TRUNK_ROOT" rev-parse HEAD)
if git -C "$ACFW_TRUNK_ROOT" merge --ff-only "refs/acfw/$SLUG" 2>/tmp/ff-err; then
  TRUNK_SHA_AFTER=$(git -C "$ACFW_TRUNK_ROOT" rev-parse HEAD)
  goto_success
fi
```

If the merge succeeded → goto Step 7 (success). Otherwise fall through to rebase.

### Step 4: Rebase the worktree onto current trunk

The rebase happens inside the worktree, never on trunk.

```bash
git -C "$WORKTREE" fetch "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH:refs/acfw/trunk-snapshot" --quiet
if git -C "$WORKTREE" rebase refs/acfw/trunk-snapshot 2>/tmp/rebase-err; then
  # Clean rebase. Refresh refs/acfw/<slug> and retry FF.
  git -C "$ACFW_TRUNK_ROOT" fetch . "$BRANCH:refs/acfw/$SLUG" --quiet --force
  if git -C "$ACFW_TRUNK_ROOT" merge --ff-only "refs/acfw/$SLUG"; then
    TRUNK_SHA_AFTER=$(git -C "$ACFW_TRUNK_ROOT" rev-parse HEAD)
    goto_success
  fi
fi
# Either rebase had conflicts, or FF still failed (rare race) — fall through to resolver.
```

### Step 5: Dispatch conflict resolver

Worktree is left with rebase in progress and conflict markers in place. Assemble context, then invoke the task's `assigned_agent` via the Task tool.

**Context assembly** (the orchestrator runs this; the resolver receives it in its prompt):

```bash
# Conflicting trunk commits since the worktree's merge-base
MERGE_BASE=$(git -C "$WORKTREE" merge-base HEAD refs/acfw/trunk-snapshot)
CONFLICTING_COMMITS=$(git -C "$ACFW_TRUNK_ROOT" log "${MERGE_BASE}..${ACFW_TRUNK_BRANCH}" --pretty=format:'%H %s')

# Map commits back to their source tasks via Integrated-At in .backlog/accepted/
SOURCE_TASKS=$(grep -lE '^- \*\*Integrated-At\*\*:[[:space:]]*[0-9a-f]{7,}' "$ACFW_TRUNK_ROOT/.backlog/accepted/"*.md 2>/dev/null || true)

# Files in conflict
CONFLICTED_FILES=$(git -C "$WORKTREE" diff --name-only --diff-filter=U)
```

**Resolver dispatch** (Task tool call by the orchestrator):

```
subagent_type: <ASSIGNED_AGENT>
prompt: |
  You are resolving a rebase conflict in the worktree at $WORKTREE.

  CONTEXT
  - Task being integrated: $TASK_FILE
  - Branch: $BRANCH
  - Conflicting commits already on trunk ($ACFW_TRUNK_BRANCH):
    $CONFLICTING_COMMITS
  - Source task files for those commits (read these to understand intent):
    $SOURCE_TASKS
  - Files currently in conflict (markers in place):
    $CONFLICTED_FILES

  RULES
  - Work ONLY inside $WORKTREE. Never cd to $ACFW_TRUNK_ROOT. Never touch trunk's .git/index.
  - Resolve each conflict to preserve the intent of BOTH this task and the conflicting tasks.
  - After resolving, run the project's quality gates inside the worktree. They must pass.
  - When clean: `git add` the resolved files, run `git rebase --continue` until rebase finishes.
  - Append a transition-log line to $TASK_FILE describing what you resolved and why.

  IF YOU CANNOT RECONCILE INTENT
  - Run `git rebase --abort` (returns the worktree to the pre-rebase state).
  - Append `FATAL: <reason>` to the task's transition log.
  - Return without committing further.

  SUCCESS CRITERIA
  - `git -C "$WORKTREE" status` is clean.
  - `git -C "$WORKTREE" log -1 --pretty=%s` shows the rebased head, no rebase in progress.
  - Quality gates green.
  - Transition log entry added.
```

After the resolver returns, the orchestrator validates:

```bash
# Rebase still in progress? Resolver gave up or crashed.
if [ -d "$WORKTREE/.git/rebase-merge" ] || [ -d "$WORKTREE/.git/rebase-apply" ]; then
  git -C "$WORKTREE" rebase --abort 2>/dev/null || true
  goto_resolver_failure
fi

# Working tree dirty? Resolver did not finish cleanly.
if [ -n "$(git -C "$WORKTREE" status --porcelain)" ]; then
  goto_resolver_failure
fi

# FATAL token in transition log?
if grep -qE '^\| .* FATAL:' "$TASK_FILE"; then
  goto_resolver_failure
fi

# Refresh and retry FF.
git -C "$ACFW_TRUNK_ROOT" fetch . "$BRANCH:refs/acfw/$SLUG" --quiet --force
if git -C "$ACFW_TRUNK_ROOT" merge --ff-only "refs/acfw/$SLUG"; then
  TRUNK_SHA_AFTER=$(git -C "$ACFW_TRUNK_ROOT" rev-parse HEAD)
  goto_success
fi
goto_resolver_failure
```

### Step 6: Resolver failure path

```bash
git -C "$WORKTREE" rebase --abort 2>/dev/null || true
TS=$(date -u +"%Y-%m-%d %H:%M:%S")
REASON="conflict-unresolved by $ASSIGNED_AGENT"

# Increment Rejection Count
RC=$(grep -E '^- \*\*Rejection Count\*\*:' "$TASK_FILE" | sed -E 's/.*Rejection Count\*\*:[[:space:]]*([0-9]+).*/\1/')
RC=${RC:-0}
NEW_RC=$((RC + 1))
sed -i.bak -E "s/^- \*\*Rejection Count\*\*:.*/- **Rejection Count**: $NEW_RC/" "$TASK_FILE" && rm -f "$TASK_FILE.bak"

# Append transition log line
printf '| %s | accepted | rejected | integrate-worktree | %s | %s |\n' "$TS" "$SLUG" "$REASON" >> "$TASK_FILE"

# Move on the trunk's filesystem (orchestrator owns trunk; this is allowed)
mv "$TASK_FILE" "$ACFW_TRUNK_ROOT/.backlog/rejected/$(basename "$TASK_FILE")"
git -C "$ACFW_TRUNK_ROOT" add ".backlog/accepted/$(basename "$TASK_FILE")" ".backlog/rejected/$(basename "$TASK_FILE")"
git -C "$ACFW_TRUNK_ROOT" commit -m "integrate: reject $TASK_ID ($REASON)" --quiet
exit 6
```

### Step 7: Success path

```bash
TS=$(date -u +"%Y-%m-%d %H:%M:%S")

# Write Integrated-At to front-matter (note: task file is now under trunk's accepted/, on trunk)
TASK_FILE_ON_TRUNK="$ACFW_TRUNK_ROOT/.backlog/accepted/$(basename "$TASK_FILE")"
if grep -qE '^- \*\*Integrated-At\*\*:' "$TASK_FILE_ON_TRUNK"; then
  sed -i.bak -E "s|^- \*\*Integrated-At\*\*:.*|- **Integrated-At**: $TRUNK_SHA_AFTER|" "$TASK_FILE_ON_TRUNK"
else
  # Insert after the Worktree line
  sed -i.bak -E "/^- \*\*Worktree\*\*:/a\\
- **Integrated-At**: $TRUNK_SHA_AFTER" "$TASK_FILE_ON_TRUNK"
fi
rm -f "$TASK_FILE_ON_TRUNK.bak"

# Append transition-log line
printf '| %s | accepted | accepted | integrate-worktree | %s | %s | integrated |\n' \
  "$TS" "$SLUG" "$TRUNK_SHA_AFTER" >> "$TASK_FILE_ON_TRUNK"

git -C "$ACFW_TRUNK_ROOT" add ".backlog/accepted/$(basename "$TASK_FILE")"
git -C "$ACFW_TRUNK_ROOT" commit -m "integrate: $TASK_ID ($SLUG -> $ACFW_TRUNK_BRANCH)" --quiet

# Cleanup: remove worktree iff no more pending/in-progress tasks share the slug
REMAINING=$(grep -lE "^- \*\*Worktree\*\*:[[:space:]]*$SLUG[[:space:]]*\$" \
  "$ACFW_TRUNK_ROOT/.backlog/pending/"*.md \
  "$ACFW_TRUNK_ROOT/.backlog/in-progress/"*.md 2>/dev/null | wc -l)
if [ "$REMAINING" -eq 0 ]; then
  git -C "$ACFW_TRUNK_ROOT" worktree remove --force "$WORKTREE" 2>/dev/null || true
  git -C "$ACFW_TRUNK_ROOT" branch -d "$BRANCH" 2>/dev/null || true
fi

exit 0
```

---

## Failure modes

| Exit | Cause | Orchestrator action |
|---|---|---|
| 0 | Integrated successfully | Continue to next task in topological order |
| 1 | Task missing `Worktree:` field | Programmer error in task-engineer; surface to operator |
| 6 | Conflict could not be resolved | Task is now in `.backlog/rejected/`; existing retry path takes over next iteration |
| 10 | Transient git error (fetch/network) | Leave task in `accepted/`; retry next iteration |

The skill never modifies any worktree other than the slug it was called with. It never force-pushes. It never abandons trunk in a partially-merged state — every mutation is one atomic `merge --ff-only` followed by an atomic file move + commit.

---

## Why this works

- **Trunk has one writer**: only `/go` invokes this skill, sequentially. No locks needed; no `.git/index` contention on trunk.
- **Specialists stay isolated**: the resolver subagent works inside `$WORKTREE`; trunk is untouched until the orchestrator's `merge --ff-only` retry.
- **Linear history**: rebase + FF guarantees a linear trunk. No merge bubbles, no octopus.
- **Cross-worktree dependency pickup**: after a task is integrated, sibling worktrees pick up the new trunk on their next `clean-checkout-before-task` Step 5 fast-forward.
- **Failure recovery is free**: transient errors (exit 10) just retry next iteration. Resolver failures route through the existing rejection/retry/block machinery — no new state to maintain.

---

**Last Updated**: 2026-04-28
