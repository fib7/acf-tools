#!/usr/bin/env bash
# scan-backlog.sh — emit a derived BacklogSnapshot as JSON for the workflow scheduler.
#
# Usage:
#   scan-backlog.sh [--counts-only] [REPO_ROOT]
#     --counts-only  emit trunk identity + counts only (tasks/worktrees arrays empty).
#                    Use for the per-iteration terminal check on large backlogs.
#     REPO_ROOT      defaults to $ACFW_TRUNK_ROOT or `git rev-parse --show-toplevel`.
#
# Stdout: EXACTLY ONE JSON object (the BacklogSnapshot). Nothing else on stdout.
# Stderr: diagnostics only (none on success).
#
# This script is the SCANNER's engine. The workflow JS has no clock and no shell,
# so every time-derived field (generatedAt, ageHours, lastTransitionTs) is computed
# HERE. The script is READ-ONLY: it never writes .backlog/, never commits, and uses
# git only in read-only modes (symbolic-ref, rev-parse, branch --show-current).
#
# Field parsing mirrors whip-doctor/bin/doctor.sh (same `field` extractor, same TSV
# column model) so the scanner and the doctor agree byte-for-byte on every task.
#
# Portability: pure bash 3.2 (no `declare -A`). macOS ships bash 3.2.

set -u

COUNTS_ONLY=false
if [ "${1:-}" = "--counts-only" ]; then COUNTS_ONLY=true; shift; fi
REPO_ROOT="${1:-${ACFW_TRUNK_ROOT:-$(git rev-parse --show-toplevel)}}"
BL="$REPO_ROOT/.backlog"
ACTIVE="pending in-progress completed in-review blocked rejected accepted"
NOW_S=$(date -u +%s)
GEN_TS=$(date -u +"%Y-%m-%d %H:%M:%S")

# In-progress timeout threshold (hours): env > .backlog/.acfw-config > default 8. Mirrors the
# precedence in doctor.sh so /go's in-progress->blocked timeout uses the operator's setting. The
# config is sourced with stdout suppressed so this script's stdout stays a single JSON object.
ENV_TIMEOUT="${ACFW_INPROGRESS_TIMEOUT_HOURS:-}"
[ -f "$BL/.acfw-config" ] && . "$BL/.acfw-config" >/dev/null 2>&1
TIMEOUT_H="${ENV_TIMEOUT:-${ACFW_INPROGRESS_TIMEOUT_HOURS:-8}}"
printf '%s' "$TIMEOUT_H" | grep -qE '^[0-9]+$' || TIMEOUT_H=8

# ---- JSON helpers ----
# Escape a single-line string for embedding in JSON (backslash, doublequote;
# strip stray control chars that should never appear in a frontmatter value).
jesc() { printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }
# Comma-separated list -> JSON array of strings, dropping empty and literal "none".
# Splits on commas via tr (NOT unquoted expansion) so globs like services/**,*.go
# are never glob-expanded against the filesystem.
jarr() {
  local raw="${1:-}" out="" tok first=1
  while IFS= read -r tok || [ -n "$tok" ]; do
    tok=$(printf '%s' "$tok" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -z "$tok" ] && continue
    [ "$tok" = "none" ] && continue
    if [ "$first" -eq 1 ]; then first=0; else out="$out,"; fi
    out="$out\"$(jesc "$tok")\""
  done < <(printf '%s' "$raw" | tr ',' '\n')
  printf '[%s]' "$out"
}
field() { grep -E "^- \*\*$2\*\*:" "$1" 2>/dev/null | head -1 | sed -E "s/.*$2\*\*:[[:space:]]*//" | sed -E 's/[[:space:]]+$//'; }
count_md() { # files in a folder, excluding README.md/.gitkeep
  local d="$1"
  [ -d "$d" ] || { printf '0'; return; }
  find "$d" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' 2>/dev/null | wc -l | tr -d ' '
}

# ---- Trunk identity ----
TRUNK_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || true)
DETACHED=false; [ -z "$TRUNK_BRANCH" ] && DETACHED=true
TRUNK_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)

# ---- Counts ----
c_pending=$(count_md "$BL/pending")
c_inprogress=$(count_md "$BL/in-progress")
c_completed=$(count_md "$BL/completed")
c_inreview=$(count_md "$BL/in-review")
c_blocked=$(count_md "$BL/blocked")
c_rejected=$(count_md "$BL/rejected")
c_accepted=$(count_md "$BL/accepted")
# total = ACTIVE folders only (draft/ and archive/ are excluded from automation, so they must NOT
# inflate the completion denominator — they are not part of tasks[] either).
c_total=$((c_pending + c_inprogress + c_completed + c_inreview + c_blocked + c_rejected + c_accepted))

# Existing worktree-branch slugs (ONE git call), hoisted here so the runtime-terminal accepted count
# is correct in BOTH full and --counts-only modes. hasWorktreeBranch distinguishes a live,
# integratable accepted task (branch exists) from a historical/pre-2.0.0 one (no branch — already on
# trunk, terminal). Membership is a fixed-string whole-line compare (metachar-safe).
EXISTING_WT_SLUGS=$(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads/worktree/ 2>/dev/null | sed 's#^worktree/##')

# integrated = accepted tasks carrying a non-empty hex Integrated-At (>=7 chars).
# c_term_acc = accepted tasks TERMINAL by the default-mode runtime rule (mirrors JS isTerminal for
# accepted): hasIntegratedAt (non-empty Integrated-At), OR non-code slug ("" / "none"), OR no branch.
c_integrated=0
c_term_acc=0
if [ -d "$BL/accepted" ]; then
  for f in "$BL/accepted"/*.md; do
    [ -f "$f" ] || continue
    grep -qE '^- \*\*Integrated-At\*\*:[[:space:]]*[0-9a-f]{7,}' "$f" && c_integrated=$((c_integrated + 1))
    a_slug=$(field "$f" "Worktree" | tr -d '[:space:]')
    a_hasInteg=false; [ -n "$(field "$f" "Integrated-At" | tr -d '[:space:]')" ] && a_hasInteg=true
    a_hasBranch=false
    if [ -n "$a_slug" ] && [ "$a_slug" != "none" ] && printf '%s\n' "$EXISTING_WT_SLUGS" | grep -qxF "$a_slug"; then a_hasBranch=true; fi
    if [ "$a_hasInteg" = true ] || [ -z "$a_slug" ] || [ "$a_slug" = "none" ] || [ "$a_hasBranch" = false ]; then
      c_term_acc=$((c_term_acc + 1))
    fi
  done
fi
c_terminal_default=$((c_integrated + c_blocked))
c_terminal_override=$((c_accepted + c_blocked))
# Runtime-terminal counts drive /go completion (terminal===total). Default: blocked + accepted that
# are terminal-by-rule. Override: blocked + ALL accepted (override treats every accepted as terminal).
c_runtime_terminal_default=$((c_blocked + c_term_acc))
c_runtime_terminal_override=$((c_blocked + c_accepted))

emit_counts() {
  printf '"counts":{'
  printf '"pending":%d,' "$c_pending"
  printf '"in-progress":%d,' "$c_inprogress"
  printf '"completed":%d,' "$c_completed"
  printf '"in-review":%d,' "$c_inreview"
  printf '"blocked":%d,' "$c_blocked"
  printf '"rejected":%d,' "$c_rejected"
  printf '"accepted":%d,' "$c_accepted"
  printf '"integrated":%d,' "$c_integrated"
  printf '"terminalDefault":%d,' "$c_terminal_default"
  printf '"terminalOverride":%d,' "$c_terminal_override"
  printf '"runtimeTerminalDefault":%d,' "$c_runtime_terminal_default"
  printf '"runtimeTerminalOverride":%d,' "$c_runtime_terminal_override"
  printf '"total":%d}' "$c_total"
}

# ---- Per-task objects (skipped in --counts-only) ----
TASKS_JSON=""
if [ "$COUNTS_ONLY" = "false" ]; then
  # Dep-token set: every Dependencies token referenced by ANY active task, extracted with the SAME
  # field()+comma-split/trim that emits each task's deps, so the scanner and the JS resolver agree
  # byte-for-byte. Used by the working-set collapse below: a terminal accepted task is KEPT in tasks[]
  # when it is a dependency target, so depsSatisfied / indexTasks.resolve never see a null and a
  # dependent never silently hangs. Over-keeping is harmless; under-keeping is a hang.
  DEP_TOKENS=$(
    for st in $ACTIVE; do
      d="$BL/$st"; [ -d "$d" ] || continue
      for f in "$d"/*.md; do
        [ -f "$f" ] || continue
        field "$f" "Dependencies" | tr ',' '\n'
      done
    done | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' | grep -vxF 'none' | sort -u
  )
  # Is an accepted task a dependency target? Mirrors indexTasks.resolve: byId, byStem, then stem-prefix.
  is_dep_target() { # <stem> <id>
    local _stem="$1" _id="$2" _tok
    printf '%s\n' "$DEP_TOKENS" | grep -qxF "$_stem" && return 0
    [ -n "$_id" ] && printf '%s\n' "$DEP_TOKENS" | grep -qxF "$_id" && return 0
    while IFS= read -r _tok; do
      [ -z "$_tok" ] && continue
      case "$_stem" in "$_tok"*) return 0;; esac
    done <<EOF
$DEP_TOKENS
EOF
    return 1
  }
  tfirst=1
  for st in $ACTIVE; do
    d="$BL/$st"; [ -d "$d" ] || continue
    for f in "$d"/*.md; do
      [ -f "$f" ] || continue
      stem=$(basename "$f" .md)
      id=$(field "$f" "ID")
      status=$(field "$f" "Status")
      slug=$(field "$f" "Worktree" | tr -d '[:space:]')
      agent=$(field "$f" "Assigned Agent" | tr -d '[:space:]')
      priority=$(field "$f" "Priority" | tr -d '[:space:]')
      deps=$(field "$f" "Dependencies")
      globs=$(field "$f" "Touches Globs")
      integ=$(field "$f" "Integrated-At" | tr -d '[:space:]')
      rc=$(field "$f" "Rejection Count" | tr -d '[:space:]')
      printf '%s' "$rc" | grep -qE '^-?[0-9]+$' || rc=0
      bc=$(field "$f" "Block-Count" | tr -d '[:space:]')
      printf '%s' "$bc" | grep -qE '^-?[0-9]+$' || bc=0

      hasInteg=false; [ -n "$integ" ] && hasInteg=true
      hasTok=false; grep -qE '\| clean-checkout \| ok \|' "$f" && hasTok=true
      codeMut=true; { [ -z "$slug" ] || [ "$slug" = "none" ]; } && codeMut=false
      hasWtBranch=false
      if [ -n "$slug" ] && [ "$slug" != "none" ] && printf '%s\n' "$EXISTING_WT_SLUGS" | grep -qxF "$slug"; then hasWtBranch=true; fi

      # Working-set collapse: a TERMINAL accepted task that nothing depends on is dropped from tasks[]
      # (it survives only in the aggregate counts) so the snapshot stays small enough for the workflow
      # agent to echo reliably. Keep it if it is a dependency target — then depsSatisfied/resolve never
      # see a null. Non-accepted folders are always emitted (they drive dispatch).
      slim=false
      if [ "$st" = "accepted" ]; then
        term_acc=false
        if [ "$hasInteg" = true ] || [ -z "$slug" ] || [ "$slug" = "none" ] || [ "$hasWtBranch" = false ]; then term_acc=true; fi
        if [ "$term_acc" = true ]; then
          # terminal accepted: drop entirely unless something depends on it; if it IS a dep target,
          # keep it but emit a SLIM object (below) instead of the full one.
          if is_dep_target "$stem" "$id"; then slim=true; else continue; fi
        fi
      fi

      # Slim emission for a terminal accepted task retained ONLY as a dependency target. The scheduler
      # consults it via idx.resolve strictly as a DEP: depsSatisfied reads folder/slug/hasIntegratedAt/
      # hasWorktreeBranch and never recurses into the dep's own deps, and a terminal task never enters
      # the integration topo-sort. Dropping the heavy/unused fields shrinks the per-iteration payload
      # on lived-in backlogs (the full object is ~2-3x larger). deps/touchesGlobs are emitted empty so
      # any defensive consumer still sees arrays, not undefined.
      if [ "$slim" = true ]; then
        if [ "$tfirst" -eq 1 ]; then tfirst=0; else TASKS_JSON="$TASKS_JSON,"; fi
        TASKS_JSON="$TASKS_JSON{\"stem\":\"$(jesc "$stem")\",\"id\":\"$(jesc "$id")\",\"folder\":\"accepted\",\"slug\":\"$(jesc "$slug")\",\"deps\":[],\"touchesGlobs\":[],\"hasIntegratedAt\":$hasInteg,\"hasWorktreeBranch\":$hasWtBranch,\"rejectionCount\":$rc,\"blockCount\":$bc,\"ageHours\":-1,\"slim\":true}"
        continue
      fi

      last=$(grep -oE '\| [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \|' "$f" | tail -1 | tr -d '|' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      age=-1; lastTs=""
      if [ -n "$last" ]; then
        lastTs="$last"
        then_s=$(date -u -j -f "%Y-%m-%d %H:%M:%S" "$last" +%s 2>/dev/null || date -u -d "$last" +%s 2>/dev/null || echo "")
        [ -n "$then_s" ] && age=$(( (NOW_S - then_s) / 3600 ))
      fi

      if [ "$tfirst" -eq 1 ]; then tfirst=0; else TASKS_JSON="$TASKS_JSON,"; fi
      TASKS_JSON="$TASKS_JSON{"
      TASKS_JSON="$TASKS_JSON\"stem\":\"$(jesc "$stem")\","
      TASKS_JSON="$TASKS_JSON\"id\":\"$(jesc "$id")\","
      TASKS_JSON="$TASKS_JSON\"folder\":\"$(jesc "$st")\","
      TASKS_JSON="$TASKS_JSON\"status\":\"$(jesc "$status")\","
      TASKS_JSON="$TASKS_JSON\"slug\":\"$(jesc "$slug")\","
      TASKS_JSON="$TASKS_JSON\"agent\":\"$(jesc "$agent")\","
      TASKS_JSON="$TASKS_JSON\"priority\":\"$(jesc "$priority")\","
      TASKS_JSON="$TASKS_JSON\"deps\":$(jarr "$deps"),"
      TASKS_JSON="$TASKS_JSON\"touchesGlobs\":$(jarr "$globs"),"
      TASKS_JSON="$TASKS_JSON\"integratedAt\":\"$(jesc "$integ")\","
      TASKS_JSON="$TASKS_JSON\"hasIntegratedAt\":$hasInteg,"
      TASKS_JSON="$TASKS_JSON\"hasCleanCheckoutToken\":$hasTok,"
      TASKS_JSON="$TASKS_JSON\"isCodeMutating\":$codeMut,"
      TASKS_JSON="$TASKS_JSON\"hasWorktreeBranch\":$hasWtBranch,"
      TASKS_JSON="$TASKS_JSON\"rejectionCount\":$rc,"
      TASKS_JSON="$TASKS_JSON\"blockCount\":$bc,"
      TASKS_JSON="$TASKS_JSON\"lastTransitionTs\":\"$(jesc "$lastTs")\","
      TASKS_JSON="$TASKS_JSON\"ageHours\":$age}"
    done
  done
fi

# ---- Worktree registry (skipped in --counts-only) ----
WT_JSON=""
if [ "$COUNTS_ONLY" = "false" ] && [ -d "$REPO_ROOT/.worktree" ]; then
  # Live slugs = Worktree values of tasks in active-but-unfinished folders, extracted BY VALUE via the
  # shared field() parser — never by interpolating a slug into a regex (a metachar slug like 'api.v2'
  # would otherwise match the wrong task). Membership is then a fixed-string compare (grep -qxF).
  LIVE_SLUGS=""
  for st in pending in-progress completed in-review; do
    d="$BL/$st"; [ -d "$d" ] || continue
    for f in "$d"/*.md; do
      [ -f "$f" ] || continue
      s=$(field "$f" "Worktree" | tr -d '[:space:]')
      [ -n "$s" ] && LIVE_SLUGS="$LIVE_SLUGS$s
"
    done
  done
  wfirst=1
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    slug=$(basename "$wt")
    actual=$(git -C "$wt" branch --show-current 2>/dev/null || true)
    onExpected=false; [ "$actual" = "worktree/$slug" ] && onExpected=true
    isLive=false; printf '%s\n' "$LIVE_SLUGS" | grep -qxF "$slug" && isLive=true
    if [ "$wfirst" -eq 1 ]; then wfirst=0; else WT_JSON="$WT_JSON,"; fi
    WT_JSON="$WT_JSON{\"slug\":\"$(jesc "$slug")\",\"branch\":\"$(jesc "$actual")\",\"onExpectedBranch\":$onExpected,\"isLive\":$isLive}"
  done < <(find "$REPO_ROOT/.worktree" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi

# ---- Assemble ----
printf '{'
printf '"trunkRoot":"%s",' "$(jesc "$REPO_ROOT")"
printf '"trunkBranch":"%s",' "$(jesc "$TRUNK_BRANCH")"
printf '"trunkSha":"%s",' "$(jesc "$TRUNK_SHA")"
printf '"detachedHead":%s,' "$DETACHED"
printf '"countsOnly":%s,' "$COUNTS_ONLY"
printf '"generatedAt":"%s",' "$GEN_TS"
printf '"inProgressTimeoutHours":%d,' "$TIMEOUT_H"
emit_counts
printf ',"tasks":[%s]' "$TASKS_JSON"
printf ',"worktrees":[%s]' "$WT_JSON"
printf '}\n'
