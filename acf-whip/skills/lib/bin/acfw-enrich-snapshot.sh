#!/usr/bin/env bash
# acfw-enrich-snapshot.sh — turn a RAW adapter snapshot into a full BacklogSnapshot.
#
# Usage: <adapter snapshot stdout> | acfw-enrich-snapshot.sh <repo-root>
#
# Adapters without the `snapshot-enriched` capability (beads, multica, third-party)
# know nothing about git. This enricher adds every git-derived fact the whip-go
# scheduler consumes, with the SAME rules as scan-backlog.sh (the files reference):
#   per task : hasIntegratedAt (LP-CAS ledger membership by stem — THE oracle),
#              integratedAt (display, "" when absent), isCodeMutating (slug-derived),
#              hasWorktreeBranch (refs/heads/<prefix>/<slug>), ageHours (from
#              lastTransitionTs; -1 when unknown)
#   top level: trunk identity, branchPrefix/worktreeDir, inProgressTimeoutHours,
#              worktrees[], and the integrated/terminal/runtimeTerminal counts model
#              (scan-backlog.sh:300-322) recomputed from the enriched tasks.
# Counts are recomputed from tasks[] — a raw snapshot MUST list every active task. Tasks in `draft`
# or `archive` are split out into `inactive[]`: resolvable for dependency purposes, never scheduled,
# never counted, never checked per-task.
#
# Requires jq: enrichment only ever runs behind a non-files adapter, and every one of
# those already declares jq as a dependency. Diagnostics to stderr; JSON to stdout.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$(cd "$SCRIPT_DIR/.." && pwd)/acfw-git.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: acfw-enrich-snapshot.sh requires jq" >&2; exit 5; }

REPO_ROOT="${1:-${ACFW_TRUNK_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}}"
[ -n "$REPO_ROOT" ] || { echo "FATAL: repo root unknown" >&2; exit 2; }

# ---- git facts (mirrors scan-backlog.sh) ----
TRUNK_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || true)
DETACHED=false; [ -z "$TRUNK_BRANCH" ] && DETACHED=true
TRUNK_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)
acfw_load_namespace "$REPO_ROOT"
ENV_TIMEOUT="${ACFW_INPROGRESS_TIMEOUT_HOURS:-}"
CFG=$(acfw_resolve_config_file "$REPO_ROOT" || true)
[ -n "$CFG" ] && . "$CFG" >/dev/null 2>&1
TIMEOUT_H="${ENV_TIMEOUT:-${ACFW_INPROGRESS_TIMEOUT_HOURS:-8}}"
printf '%s' "$TIMEOUT_H" | grep -qE '^[0-9]+$' || TIMEOUT_H=8
NOW_S=$(date -u +%s)
GEN_TS=$(date -u +"%Y-%m-%d %H:%M:%S")

# Ledger keys + worktree-branch slugs as JSON arrays (one git call each).
IK_JSON=$(acfw_integrated_keys "$REPO_ROOT" "${TRUNK_SHA:-HEAD}" 2>/dev/null | jq -R . | jq -s .)
WT_JSON=$(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "refs/heads/$ACFW_BRANCH_PREFIX/" 2>/dev/null \
  | sed "s#^${ACFW_BRANCH_PREFIX}/##" | jq -R . | jq -s .)

# Worktree dirs (slug/branch/onExpectedBranch; isLive is filled by jq from tasks[]).
WTS_JSON="[]"
if [ -d "$REPO_ROOT/$ACFW_WORKTREE_DIR" ]; then
  WTS_JSON=$(
    while IFS= read -r wt; do
      [ -z "$wt" ] && continue
      slug=$(basename "$wt")
      actual=$(git -C "$wt" branch --show-current 2>/dev/null || true)
      onExp=false; [ "$actual" = "$ACFW_BRANCH_PREFIX/$slug" ] && onExp=true
      jq -n --arg s "$slug" --arg b "$actual" --argjson e "$onExp" '{slug:$s,branch:$b,onExpectedBranch:$e}'
    done < <(find "$REPO_ROOT/$ACFW_WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null) | jq -s .
  )
fi

jq \
  --arg trunkRoot "$REPO_ROOT" \
  --arg trunkBranch "$TRUNK_BRANCH" \
  --arg trunkSha "$TRUNK_SHA" \
  --argjson detached "$DETACHED" \
  --arg branchPrefix "$ACFW_BRANCH_PREFIX" \
  --arg worktreeDir "$ACFW_WORKTREE_DIR" \
  --argjson timeoutH "$TIMEOUT_H" \
  --argjson now "$NOW_S" \
  --arg genTs "$GEN_TS" \
  --argjson ik "$IK_JSON" \
  --argjson wt "$WT_JSON" \
  --argjson wts "$WTS_JSON" '
  def codemut: ((.slug // "") != "" and (.slug // "") != "none");
  def agehours:
    (.lastTransitionTs // "") as $ts
    | if $ts == "" then -1
      else (($ts | strptime("%Y-%m-%d %H:%M:%S") | mktime) as $then
            | (($now - $then) / 3600 | floor))
      end;

  # ACTIVE WORKING SET. `tasks[]` is what the scheduler plans over and what the doctor batteries check
  # per task; it spans the seven ACTIVE states only. `draft` is the human gate and `archive` is retired
  # — neither can be dispatched, transitioned or integrated. The files scanner has always excluded them
  # (scan-backlog.sh ACTIVE), but every API adapter lists them, so on those backends they leaked into
  # both: a scoped run counted them in its denominator and could never reach terminal === total, and
  # the per-task battery raised findings against cards nothing will ever touch.
  #
  # They are NOT dropped. Dependency resolution must still see them, or a pending task depending on a
  # draft flips from "gated, and you can see why" to FATAL|dangling-dep. They move to `inactive[]`,
  # which the graph passes register as resolvable stems but never schedule.
  def isactive: ((.folder // "") | IN("pending","in-progress","completed","in-review","blocked","rejected","accepted"));
  ((.tasks // []) | map(select(isactive))) as $rawTasks
  | ((.tasks // []) | map(select(isactive | not))) as $rawInactive
  | ($rawInactive | map(. + {
      isCodeMutating: codemut,
      hasIntegratedAt: (.stem | IN($ik[])),
      hasWorktreeBranch: (codemut and ((.slug // "") | IN($wt[])))
    })) as $inactive
  | ($rawTasks | map(. + {
      integratedAt: (.integratedAt // ""),
      hasIntegratedAt: (.stem | IN($ik[])),
      isCodeMutating: codemut,
      hasWorktreeBranch: (codemut and ((.slug // "") | IN($wt[]))),
      hasCleanCheckoutToken: (.hasCleanCheckoutToken // false),
      rejectionCount: (.rejectionCount // 0),
      blockCount: (.blockCount // 0),
      lastTransitionTs: (.lastTransitionTs // ""),
      ageHours: (try agehours catch -1)
    })) as $tasks

  # Counts model — mirrors scan-backlog.sh exactly. total spans the 7 active states
  # only (draft/archive/unknown never inflate the completion denominator).
  | def cnt($st): [$tasks[] | select(.folder == $st)] | length;
    (cnt("pending"))     as $p  | (cnt("in-progress")) as $ip
  | (cnt("completed"))   as $c  | (cnt("in-review"))   as $ir
  | (cnt("blocked"))     as $b  | (cnt("rejected"))    as $r
  | (cnt("accepted"))    as $a
  | ([$tasks[] | select(.folder == "accepted" and .hasIntegratedAt)] | length) as $integ
  | ([$tasks[] | select(.folder == "accepted"
        and (.hasIntegratedAt or (.isCodeMutating | not) or (.hasWorktreeBranch | not)))] | length) as $termAcc

  # Live slugs (pending/in-progress/completed/in-review code tasks) mark worktrees isLive.
  | ([$tasks[] | select(.folder == "pending" or .folder == "in-progress"
                        or .folder == "completed" or .folder == "in-review")
               | .slug // ""] | map(select(. != "" and . != "none"))) as $live

  | . + {
      trunkRoot: $trunkRoot,
      trunkBranch: $trunkBranch,
      trunkSha: $trunkSha,
      detachedHead: $detached,
      countsOnly: (.countsOnly // false),
      digest: (.digest // false),
      mode: (.mode // "default"),
      generatedAt: (.generatedAt // $genTs),
      inProgressTimeoutHours: $timeoutH,
      branchPrefix: $branchPrefix,
      worktreeDir: $worktreeDir,
      counts: {
        "pending": $p, "in-progress": $ip, "completed": $c, "in-review": $ir,
        "blocked": $b, "rejected": $r, "accepted": $a,
        "integrated": $integ,
        "terminalDefault": ($integ + $b),
        "terminalOverride": ($a + $b),
        "runtimeTerminalDefault": ($b + $termAcc),
        "runtimeTerminalOverride": ($b + $a),
        "total": ($p + $ip + $c + $ir + $b + $r + $a)
      },
      tasks: $tasks,
      # Resolvable but never scheduled. Consumers that resolve dependency tokens MUST union this with
      # tasks[]; consumers that plan, count or check per-task invariants MUST NOT.
      inactive: $inactive,
      satisfiedDeps: (.satisfiedDeps // []),
      worktrees: ($wts | map(. + {isLive: (.slug | IN($live[]))}))
    }
  | del(.raw)
'
