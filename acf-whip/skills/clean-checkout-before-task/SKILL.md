---
name: clean-checkout-before-task
description: Mandatory first step for any agent that mutates code. Resolves the task's Worktree slug, lazy-creates an isolated git worktree on a derived branch, validates the branch, stashes unrelated changes, and logs the clean-checkout token. Eliminates index.lock contention and cross-task commit bundling.
allowed-tools:
  - Bash
  - Read
---

# /clean-checkout-before-task

Concurrency primitive for ACF specialist agents. Every implementer and reviewer invokes this before any edit, commit, or state move.

The mechanism: each task declares `Worktree: <slug>` in its front-matter. This skill creates `.worktree/<slug>` on branch `worktree/<slug>` if missing, validates the branch, stashes unrelated working-tree changes, and writes a `clean-checkout: ok` token to the task transition log. Quality-reviewer rejects any task whose transition log lacks the token.

**The lock is git itself.** `git worktree add -b <branch>` fails when the branch is already checked out elsewhere; that failure is the mutual-exclusion primitive. No custom lock files, daemons, or schedulers.

### Lock-file backoff (used throughout this skill)

Git invocations that touch a shared `.git/index` (the trunk's, or this worktree's after creation) go through this helper. The lock file is **never removed** — we sleep and retry, letting the holding process finish.

```bash
git_with_lock_backoff() {
  local attempt=0 max=3 delay=1 rc
  while [ $attempt -lt $max ]; do
    if git "$@" 2>/tmp/acfw-git-err; then
      return 0
    fi
    rc=$?
    if grep -qE 'index\.lock|Unable to create.*lock' /tmp/acfw-git-err; then
      attempt=$((attempt + 1))
      [ $attempt -ge $max ] && break
      sleep $delay
      delay=$((delay * 2))
      continue
    fi
    cat /tmp/acfw-git-err >&2
    return $rc
  done
  echo "FATAL: git lock contention persisted; another process holds .git/index.lock" >&2
  cat /tmp/acfw-git-err >&2
  return 99
}
```

Backoff: 1s → 2s → 4s. After exhausting retries, the skill exits with code 99; the caller (orchestrator or specialist) treats this as a transient failure.

---

## When to invoke

| Caller | When |
|---|---|
| Implementer specialist (backend, frontend, data, devops, infrastructure) | Step 0, before reading task implementation requirements |
| quality-reviewer | Before moving the task to `.backlog/in-review/` |
| task-engineer | **MUST NOT invoke.** task-engineer always operates on `.backlog/` at the repo root on the trunk branch — never inside a worktree. Creating, retrying, unblocking, or redesigning tasks all happen at root. |
| research-agent, lean-architect, retro, precommit | Only if the task mutates code outside `docs/`. Set `Worktree:` on those tasks; otherwise skip. |

---

## Inputs

- `TASK_FILE`: absolute path to the task markdown file (e.g. `.backlog/pending/feature-001-foo.md` or `.backlog/in-progress/feature-001-foo.md`).

## Outputs

- A worktree at `<repo>/.worktree/<slug>` checked out on `worktree/<slug>`.
- A new line in the task's transition log: `clean-checkout: ok | <slug> | <branch> | <UTC timestamp>`.
- All subsequent agent operations happen inside the worktree. The agent's working directory becomes the worktree path.

---

## Protocol

### Step 1: Resolve slug from task front-matter

Parse the `Worktree:` field. Field is required for any code-mutating task; missing field is a fatal error for implementers.

```bash
TASK_FILE="$1"
SLUG=$(grep -E '^- \*\*Worktree\*\*:' "$TASK_FILE" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')

if [ -z "$SLUG" ]; then
  echo "FATAL: task $TASK_FILE has no Worktree: field. task-engineer must set it." >&2
  exit 1
fi
```

### Step 2: Derive paths and resolve trunk

One rule, no free-form names. Mismatch is a fatal error.

`$ACFW_TRUNK_ROOT` and `$ACFW_TRUNK_BRANCH` are exported by `/go` at startup (the branch checked out at the repo root). If they are not set, the agent is running this skill outside `/go`'s orchestration — fall back to `git rev-parse --show-toplevel` and the current HEAD's branch name.

```bash
REPO_ROOT="${ACFW_TRUNK_ROOT:-$(git rev-parse --show-toplevel)}"
TRUNK_BRANCH="${ACFW_TRUNK_BRANCH:-$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null)}"
WORKTREE_PATH="$REPO_ROOT/.worktree/$SLUG"
BRANCH="worktree/$SLUG"

if [ -z "$TRUNK_BRANCH" ]; then
  echo "FATAL: cannot resolve trunk branch (HEAD detached?). Refuse to create worktree." >&2
  exit 5
fi
```

### Step 3: Lazy-create the worktree

If the worktree directory does not exist, create it based on the local trunk branch. If `git worktree add` fails because the branch already exists in another worktree, the failure is the lock: stop and report.

```bash
if [ ! -d "$WORKTREE_PATH" ]; then
  if ! git_with_lock_backoff -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" -b "$BRANCH" "$TRUNK_BRANCH"; then
    rc=$?
    [ $rc -eq 99 ] && exit 99
    echo "FATAL: cannot create worktree for $SLUG. Likely another agent owns branch $BRANCH." >&2
    exit 2
  fi
fi
```

### Step 4: Validate branch in the worktree

The worktree must be on `worktree/<slug>`. Any drift aborts.

```bash
ACTUAL_BRANCH=$(git -C "$WORKTREE_PATH" branch --show-current)
if [ "$ACTUAL_BRANCH" != "$BRANCH" ]; then
  echo "FATAL: worktree $WORKTREE_PATH is on $ACTUAL_BRANCH, expected $BRANCH." >&2
  echo "Resolve manually before continuing. Do not auto-checkout." >&2
  exit 3
fi
```

### Step 5: Sync to local trunk (fast-forward only)

Picks up any sibling worktrees' commits already integrated into the local trunk by `/go`'s integration step. Fast-forward only; never rebases or merges in this skill (rebase + intelligent conflict resolution belong to the `integrate-worktree` skill at integration time, not here).

**Shell-safety note**: this block contains a `:` immediately after a parameter expansion in the refspec (`"$TRUNK_BRANCH:refs/..."`). zsh applies `:r`/`:e`/`:h` modifiers to such constructs even inside double quotes and silently corrupts the refspec. Execute under `bash`, not `zsh`. The brace form below also defeats zsh's modifier parser.

```bash
git_with_lock_backoff -C "$WORKTREE_PATH" fetch "$REPO_ROOT" "${TRUNK_BRANCH}:refs/acfw/trunk-snapshot" --quiet
if ! git_with_lock_backoff -C "$WORKTREE_PATH" merge --ff-only refs/acfw/trunk-snapshot; then
  echo "WARN: cannot fast-forward $BRANCH to $TRUNK_BRANCH. Branch has diverged." >&2
  echo "Continue with caution; integrate-worktree will rebase + resolve at integration time." >&2
fi
```

### Step 6: Stash unrelated working-tree changes

Pre-commit hooks that stash/unstash are no longer a problem because each worktree has its own index. But if the worktree has stale unrelated edits from a prior task, scope them aside before this task runs.

```bash
TASK_ID=$(basename "$TASK_FILE" .md)
if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain)" ]; then
  git_with_lock_backoff -C "$WORKTREE_PATH" stash push -u -m "pre-task-start: $TASK_ID" --quiet || true
fi
```

### Step 7: Log the OK token

Append to the task's Transition Log table. Quality-reviewer requires this exact token; absence is auto-reject.

```bash
TS=$(date -u +"%Y-%m-%d %H:%M:%S")
LINE="| $TS | clean-checkout | ok | $(basename "$0") | $SLUG | $BRANCH |"
printf '\n%s\n' "$LINE" >> "$TASK_FILE"
```

The token format is intentionally machine-greppable:

```
| <UTC ts> | clean-checkout | ok | clean-checkout-before-task | <slug> | <branch> |
```

### Step 8: Print the worktree path for the caller

Caller agent must `cd` into the worktree (or pass the path to subsequent commands). Everything after Step 8 happens inside `WORKTREE_PATH`.

```bash
echo "$WORKTREE_PATH"
```

---

## Failure modes (all fatal; agent must abort)

| Exit code | Cause | Caller action |
|---|---|---|
| 1 | `Worktree:` field missing on a code-touching task | Send back to task-engineer; do not pick up the task |
| 2 | `git worktree add` failed: branch in use elsewhere | Defer; another agent owns this slug. Try a different task. |
| 3 | Worktree exists but is on the wrong branch | Stop, report; manual intervention required |
| 4 (reserved) | Repo root not resolvable | Misconfigured project; report to operator |
| 5 | Trunk branch not resolvable (detached HEAD) | Refuse; operator must check out a branch at the repo root |
| 99 | Lock contention persisted past backoff (`.git/index.lock` held >7s) | Treat as transient; orchestrator may retry the dispatch next iteration |

The skill never modifies `main`. It never deletes worktrees. It never force-pushes. Cleanup is an operator concern (run `git worktree remove` after the branch is integrated).

---

## Integration with the workflow

After this skill returns, the agent:

1. Reads the task file from inside the worktree.
2. Performs the state transition `pending → in-progress` (move the task file in the worktree, commit on `worktree/<slug>`).
3. Implements the task (edits, tests, quality gates) in the worktree.
4. Commits explicitly-staged files atomically on `worktree/<slug>`. No `git add -A`. No commits on `main`.
5. On completion, moves the task file to `.backlog/completed/` in the worktree, commits.
6. quality-reviewer invokes this skill (idempotent: worktree exists, OK token already logged from Step 7 of the prior call; the reviewer's call validates branch and re-logs a fresh OK token).
7. quality-reviewer moves to `.backlog/in-review/` in the worktree, reviews, moves to `.backlog/accepted/` or `.backlog/rejected/`.

Integration of `worktree/<slug>` into the local trunk is performed by `/go`'s `integrate-worktree` skill at the end of each iteration: fast-forward by default, with rebase + specialist-driven conflict resolution as fallback. If the project's CLAUDE.md (or other persistent agent instructions) directs a different integration strategy — e.g. opening a PR per `PR Group:` via `gh pr create` — the orchestrator follows those instructions instead, per Claude's instruction-priority hierarchy.

---

## Why this works

- **Index lock contention**: each worktree has its own `.git/index`; no shared lock.
- **Pre-commit stash/unstash bundling**: each worktree's pre-commit run sees only that worktree's staged files.
- **Two agents claim same task**: `git worktree add -b <branch>` fails when branch exists. First agent wins, second sees exit code 2 and defers.
- **Two agents touch same files in different worktrees**: handled by `/go` partitioning (sequential within `Worktree:` group). Cross-worktree conflicts surface at integration time.
- **Stale edits from prior task**: stashed in Step 6.

No custom lock files. No daemon. No broker. No scheduler. The mechanism is one shell command's exit code plus one task-file field.

---

## Token format (for greppers and quality-reviewer)

```
| <UTC ts> | clean-checkout | ok | clean-checkout-before-task | <slug> | <branch> |
```

Quality-reviewer rejects any task in `.backlog/in-review/` whose transition log lacks at least one `clean-checkout | ok` line.

---

**Last Updated**: 2026-04-28
