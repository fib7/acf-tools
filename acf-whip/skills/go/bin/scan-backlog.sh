#!/usr/bin/env bash
# scan-backlog.sh — emit a derived BacklogSnapshot as JSON for the workflow scheduler.
#
# Usage:
#   scan-backlog.sh [--counts-only] [--digest] [--mode default|override] [REPO_ROOT]
#     --counts-only  emit trunk identity + counts only (tasks/worktrees arrays empty).
#                    Use for the per-iteration terminal check on large backlogs.
#     --digest       emit a SMALL scheduling-correct snapshot: counts + ONLY the actionable
#                    tasks (non-accepted active folders + accepted INTEGRATION CANDIDATES as
#                    full objects) + a compact `satisfiedDeps` array of {stem,id} for every
#                    terminal-accepted dependency target. Terminal accepted tasks are NEVER
#                    emitted as full/slim objects (they collapse into satisfiedDeps + counts),
#                    and the accepted folder is classified in ONE batched grep+awk pass instead
#                    of the per-file field() loop (the 240-600x process-spawn hotspot). This is
#                    the snapshot the /go workflow echoes every iteration; keeping it tiny is
#                    what keeps the per-iteration scan-agent echo cheap.
#     --mode M       default|override (default: default). Drives the digest's accepted split:
#                    in `default`, only integrated/branchless accepted are terminal (an accepted
#                    task with a live worktree branch + no Integrated-At is an INTEGRATION
#                    CANDIDATE -> full object, must keep blocking cross-slug dependents); in
#                    `override`, EVERY accepted is terminal (integration is skipped) so there are
#                    NO candidates and all accepted dep targets go to satisfiedDeps. Mirrors the
#                    JS isTerminal exactly so the digest split matches the run mode.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../../lib/acfw-git.sh"

COUNTS_ONLY=false
DIGEST=false
MODE_ARG=default
# Run scope (3.4.0). Seeds named by the caller (`/go <ids>`); resolved HERE, against every folder,
# before any collapse can hide one. The scanner does NOT narrow tasks[] — its digest is already the
# bounded active working set and the scheduler narrows its own view — but a seed must survive the
# collapse, or `/go <a-finished-task>` is told the task "does not exist in the backlog".
ONLY_SEEDS=""
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --counts-only) COUNTS_ONLY=true; shift;;
    --digest) DIGEST=true; shift;;
    --mode) [ $# -ge 2 ] || { echo "FATAL: --mode requires a value (override|default)" >&2; exit 2; }
            MODE_ARG="$2"; shift 2;;
    --mode=*) MODE_ARG="${1#--mode=}"; shift;;
    --only) [ $# -ge 2 ] || { echo "FATAL: --only requires a task key" >&2; exit 2; }
            ONLY_SEEDS="$ONLY_SEEDS$2
"; shift 2;;
    --only=*) ONLY_SEEDS="$ONLY_SEEDS${1#--only=}
"; shift;;
    *) break;;
  esac
done
[ "$MODE_ARG" = "override" ] || MODE_ARG=default
REPO_ROOT="${1:-${ACFW_TRUNK_ROOT:-$(git rev-parse --show-toplevel)}}"
BL="$REPO_ROOT/.backlog"

# ---- store guard -------------------------------------------------------------------------------
# Symmetric with doctor.sh: this is the `files` scanner and every folder it reads is under .backlog/.
# On another backend it would emit a syntactically valid snapshot describing an EMPTY backlog, and the
# orchestrator would read that as "nothing to do" and report the run complete. Refuse on stderr and
# emit NO JSON — a caller must not be able to parse a refusal as an empty board.
if [ "$(acfw_resolve_store "$REPO_ROOT")" != "files" ]; then
  echo "FATAL: scan-backlog.sh is the 'files' store scanner; active store is '$(acfw_resolve_store "$REPO_ROOT")'. Use: acfw-store snapshot" >&2
  exit 2
fi
ACTIVE="pending in-progress completed in-review blocked rejected accepted"
# Every folder a card can sit in. Seed resolution spans ALL of them — a seed naming a draft or an
# archived card must be answered "it exists, and here is why it cannot run", never "it does not exist".
ALL_FOLDERS="pending in-progress completed in-review blocked rejected accepted draft archive"
# Non-accepted active folders (digest emits these as full objects; accepted is handled separately).
ACTIVE_NONACC="pending in-progress completed in-review blocked rejected"
NOW_S=$(date -u +%s)
GEN_TS=$(date -u +"%Y-%m-%d %H:%M:%S")

# In-progress timeout threshold (hours): env > committed config > default 8. Mirrors the
# precedence in doctor.sh so /go's in-progress->blocked timeout uses the operator's setting. The
# config location is resolved by acfw_resolve_config_file (.acfwhip/config > .backlog/.acfw-config);
# it is sourced with stdout suppressed so this script's stdout stays a single JSON object.
ENV_TIMEOUT="${ACFW_INPROGRESS_TIMEOUT_HOURS:-}"
ACFW_CFG_FILE=$(acfw_resolve_config_file "$REPO_ROOT" || true)
[ -n "$ACFW_CFG_FILE" ] && . "$ACFW_CFG_FILE" >/dev/null 2>&1
TIMEOUT_H="${ENV_TIMEOUT:-${ACFW_INPROGRESS_TIMEOUT_HOURS:-8}}"
printf '%s' "$TIMEOUT_H" | grep -qE '^[0-9]+$' || TIMEOUT_H=8

# Worktree ownership namespace (env > .acfw-config > default). Emitted in the snapshot so the
# workflow's prompt strings reference the configured branch prefix, not a hardcoded one.
acfw_load_namespace "$REPO_ROOT"

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

# Emit ONE full task object (all scheduler-consumed fields) for file $1 in folder $2, appending to
# TASKS_JSON with the shared TFIRST comma flag. Used by the full-mode loop (non-slim tasks) and by
# the digest path (non-accepted actionable tasks + accepted integration candidates).
TFIRST=1
TASKS_JSON=""
emit_task_full() {
  local f="$1" st="$2"
  local stem id status slug agent priority deps globs integ rc bc hasInteg hasTok codeMut hasWtBranch last age lastTs then_s
  stem=$(basename "$f" .md)
  id=$(field "$f" "ID")
  status=$(field "$f" "Status")
  slug=$(field "$f" "Worktree" | tr -d '[:space:]')
  agent=$(field "$f" "Assigned Agent" | tr -d '[:space:]')
  priority=$(field "$f" "Priority" | tr -d '[:space:]')
  deps=$(field "$f" "Dependencies")
  globs=$(field "$f" "Touches Globs")
  integ=$(field "$f" "Integrated-At" | tr -d '[:space:]')   # display only — inert in 3.0.0 (LP-CAS)
  rc=$(field "$f" "Rejection Count" | tr -d '[:space:]')
  printf '%s' "$rc" | grep -qE '^-?[0-9]+$' || rc=0
  bc=$(field "$f" "Block-Count" | tr -d '[:space:]')
  printf '%s' "$bc" | grep -qE '^-?[0-9]+$' || bc=0
  hasInteg=false; is_integrated_key "$stem" && hasInteg=true   # ledger is the oracle, not the field
  hasTok=false; grep -qE '\| clean-checkout \| ok \|' "$f" && hasTok=true
  codeMut=true; { [ -z "$slug" ] || [ "$slug" = "none" ]; } && codeMut=false
  hasWtBranch=false
  if [ -n "$slug" ] && [ "$slug" != "none" ] && printf '%s\n' "$EXISTING_WT_SLUGS" | grep -qxF "$slug"; then hasWtBranch=true; fi
  last=$(grep -oE '\| [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \|' "$f" | tail -1 | tr -d '|' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  age=-1; lastTs=""
  if [ -n "$last" ]; then
    lastTs="$last"
    then_s=$(date -u -j -f "%Y-%m-%d %H:%M:%S" "$last" +%s 2>/dev/null || date -u -d "$last" +%s 2>/dev/null || echo "")
    [ -n "$then_s" ] && age=$(( (NOW_S - then_s) / 3600 ))
  fi
  if [ "$TFIRST" -eq 1 ]; then TFIRST=0; else TASKS_JSON="$TASKS_JSON,"; fi
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
}

# ---- Trunk identity ----
TRUNK_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || true)
DETACHED=false; [ -z "$TRUNK_BRANCH" ] && DETACHED=true
TRUNK_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)

# ---- LP-CAS integration oracle (3.0.0) ----
# The authoritative integration state is a fact about git, NEVER the markdown Integrated-At field:
# a task is integrated IFF its in-tree ledger marker is present in the CURRENT trunk tree. We list
# that ledger ONCE (acfw_integrated_keys) and key membership by task stem (= the integrator's KEY).
# This is what eliminates the keystone-cascade class (#1,4,5,9,10,11,16): there is no cached snapshot
# and no metadata to drift — the marker is on trunk or it is not. Integrated-At is read only for the
# (now inert) integratedAt display field; it no longer decides hasIntegratedAt.
INTEGRATED_KEYS=$(acfw_integrated_keys "$REPO_ROOT" "${TRUNK_SHA:-HEAD}" 2>/dev/null)
IK_FILE=$(mktemp "${TMPDIR:-/tmp}/acfw-scan-ik.XXXXXX")
printf '%s\n' "$INTEGRATED_KEYS" > "$IK_FILE"
trap 'rm -f "$IK_FILE"' EXIT
is_integrated_key() { [ -n "$1" ] && printf '%s\n' "$INTEGRATED_KEYS" | grep -qxF "$1"; }

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
# integratable accepted task (branch exists) from a historical/pre-2.0.0 one (no branch — already
# on trunk, terminal). Membership is a fixed-string whole-line compare (metachar-safe).
EXISTING_WT_SLUGS=$(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "refs/heads/$ACFW_BRANCH_PREFIX/" 2>/dev/null | sed "s#^${ACFW_BRANCH_PREFIX}/##")

# ---- Run scope seed resolution (3.4.0) ---------------------------------------------------------
# Resolve each --only token to exactly one stem, over EVERY folder, before any collapse runs. The
# order mirrors indexTasks.resolve in whip-go.workflow.js: exact stem, exact ID field, then a stem
# prefix — except that an AMBIGUOUS prefix is reported here instead of silently taking the first
# match. On a large board that difference is the whole point: `feature-231` must not quietly select
# whichever `feature-231*` the filesystem listed first.
ACFW_TAB=$(printf '\t')   # field separator for the scope accumulators below
SCOPE_RESOLVED=""      # lines: <token><TAB><stem>
SCOPE_UNRESOLVED=""    # lines: <token>
SCOPE_AMBIGUOUS=""     # lines: <token><TAB><candidate,candidate,...>
SCOPE_INACTIVE=""      # lines: <stem><TAB><folder>
SCOPE_SEED_STEMS=""    # lines: <stem>  (resolved, any folder)

SCOPE_INDEX=""   # declared unconditionally: the digest branch's EXIT trap names it either way
if [ -n "$ONLY_SEEDS" ]; then
  # One pass over the board: stem<TAB>id<TAB>folder for every card, in every folder.
  SCOPE_INDEX=$(mktemp "${TMPDIR:-/tmp}/acfw-scan-scope.XXXXXX")
  trap 'rm -f "$IK_FILE" "$SCOPE_INDEX"' EXIT
  for st in $ALL_FOLDERS; do
    d="$BL/$st"; [ -d "$d" ] || continue
    for f in "$d"/*.md; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in README.md) continue;; esac
      printf '%s\t%s\t%s\n' "$(basename "$f" .md)" "$(field "$f" "ID" | tr -d '[:space:]')" "$st" >> "$SCOPE_INDEX"
    done
  done
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    hit=$(awk -F'\t' -v t="$tok" '$1 == t {print $1"\t"$3; found=1; exit} END{}' "$SCOPE_INDEX")
    [ -z "$hit" ] && hit=$(awk -F'\t' -v t="$tok" '$2 != "" && $2 == t {print $1"\t"$3; exit}' "$SCOPE_INDEX")
    if [ -z "$hit" ]; then
      cands=$(awk -F'\t' -v t="$tok" 'index($1, t) == 1 {print $1}' "$SCOPE_INDEX")
      n=$(printf '%s\n' "$cands" | grep -c '[^[:space:]]' || true)
      if [ "${n:-0}" -eq 1 ]; then
        cstem=$(printf '%s\n' "$cands" | grep '[^[:space:]]' | head -1)
        hit=$(awk -F'\t' -v t="$cstem" '$1 == t {print $1"\t"$3; exit}' "$SCOPE_INDEX")
      elif [ "${n:-0}" -gt 1 ]; then
        SCOPE_AMBIGUOUS="$SCOPE_AMBIGUOUS$tok$ACFW_TAB$(printf '%s' "$cands" | grep '[^[:space:]]' | paste -sd, -)
"
        continue
      fi
    fi
    if [ -z "$hit" ]; then
      SCOPE_UNRESOLVED="$SCOPE_UNRESOLVED$tok
"
      continue
    fi
    sstem=${hit%%"$ACFW_TAB"*}; sfold=${hit##*"$ACFW_TAB"}
    SCOPE_RESOLVED="$SCOPE_RESOLVED$tok$ACFW_TAB$sstem
"
    SCOPE_SEED_STEMS="$SCOPE_SEED_STEMS$sstem
"
    case " $ACTIVE " in
      *" $sfold "*) ;;
      *) SCOPE_INACTIVE="$SCOPE_INACTIVE$sstem$ACFW_TAB$sfold
" ;;
    esac
  done <<EOF
$ONLY_SEEDS
EOF
fi

# Dep-token set for the digest satisfiedDeps filter: the Dependencies tokens referenced by
# NON-ACCEPTED active tasks (pending/in-progress/completed/in-review/blocked/rejected) — extracted
# with ONE batched grep (the 240-600x process-spawn win) instead of a per-file field() loop. Scoping
# to non-accepted referrers is correct AND much smaller: the scheduler only calls depsSatisfied on
# non-accepted tasks (pending dispatch gate, blocked unblock gate), so a terminal-accepted task that
# is referenced ONLY by other (terminal) accepted tasks gates nothing and need not be retained.
# topoIntegrationOrder's resolve() is null-safe for unkept tokens. The comma-split/trim mirrors
# field()+jarr so the scanner and the JS resolver agree byte-for-byte.
compute_dep_tokens_batched() {
  local globs="" st
  for st in $ACTIVE_NONACC; do [ -d "$BL/$st" ] && globs="$globs $BL/$st/"*.md; done
  [ -n "$globs" ] || return 0
  # shellcheck disable=SC2086
  grep -hE '^- \*\*Dependencies\*\*:' $globs 2>/dev/null \
    | sed -E 's/.*Dependencies\*\*:[[:space:]]*//' \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$' | grep -vxF 'none' | sort -u
}

# ---- Accepted classification: integrated/terminal counts (+ digest candidates + satisfiedDeps) ----
c_integrated=0
c_term_acc=0
DIGEST_CAND_STEMS=""   # newline list of accepted integration-candidate stems (digest, default mode)
DIGEST_SAT_JSON=""     # JSON array body: {"stem":..,"id":..},.. for terminal-accepted dep targets

if [ "$DIGEST" = true ]; then
  # Batched single-pass classification of the accepted folder. ONE find (register every file) + ONE
  # grep (ID/Worktree/Integrated-At for all files) feed ONE awk that computes c_integrated/c_term_acc
  # and splits each accepted task into: integration candidate (default mode, live branch, unintegrated)
  # -> full object; terminal dep target -> satisfiedDeps; terminal non-dep-target -> dropped (counts).
  DEP_TOKENS=$(compute_dep_tokens_batched)
  # A --only SEED is retained exactly like a dependency target. Without this, scoping to a task that
  # is already finished (terminal accepted, nothing depends on it) collapses it out of the snapshot
  # entirely, and the orchestrator — which can only see what it was handed — reports the id as one
  # that "does not exist in the backlog". Retention is the whole fix: a retained seed resolves, is
  # recognised as terminal, and the run reports the scope complete instead of accusing the operator
  # of a typo. Over-keeping is harmless here; under-keeping is a false refusal.
  DEP_TOKENS=$(printf '%s\n%s\n' "$DEP_TOKENS" "$SCOPE_SEED_STEMS" | grep -v '^$' | sort -u)
  ACC_LIST=$(mktemp "${TMPDIR:-/tmp}/acfw-scan-acc.XXXXXX")
  WT_FILE=$(mktemp "${TMPDIR:-/tmp}/acfw-scan-wt.XXXXXX")
  DT_FILE=$(mktemp "${TMPDIR:-/tmp}/acfw-scan-dt.XXXXXX")
  # $SCOPE_INDEX stays in the list: a `trap ... EXIT` REPLACES the previous handler, and dropping it
  # here leaked one $TMPDIR/acfw-scan-scope.* per /go iteration, which is the hot path (--digest
  # --only, every iteration, for the length of a run).
  trap 'rm -f "$ACC_LIST" "$WT_FILE" "$DT_FILE" "$IK_FILE" "$SCOPE_INDEX"' EXIT
  find "$BL/accepted" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' 2>/dev/null > "$ACC_LIST"
  printf '%s\n' "$EXISTING_WT_SLUGS" > "$WT_FILE"
  printf '%s\n' "$DEP_TOKENS" > "$DT_FILE"

  # awk: first input = ACC_LIST (register stems); main stream = batched grep output. wt/dt sets are
  # loaded from temp files in BEGIN. is_dep_target mirrors the JS resolve(): exact stem, exact id, then
  # stem-prefix (a dep token that is a prefix of the stem). All compares are whole-token fixed-string
  # (set membership / index==1), never regex, so a metachar slug/stem never false-matches. Bias is
  # toward OVER-keeping (a borderline accepted task lands in satisfiedDeps) — harmless; under-keeping
  # would silently hang a dependent.
  DIGEST_AWK=$(grep -HE '^- \*\*(ID|Worktree|Integrated-At)\*\*:' "$BL/accepted/"*.md 2>/dev/null | awk \
    -v wtf="$WT_FILE" -v dtf="$DT_FILE" -v accf="$ACC_LIST" -v ikf="$IK_FILE" -v mode="$MODE_ARG" '
    function is_dep_target(s, i,    d) {
      if (s in dt) return 1
      if (i != "" && i in dt) return 1
      for (d in dt) { if (d != "" && index(s, d) == 1) return 1 }
      return 0
    }
    BEGIN {
      while ((getline l < wtf) > 0) if (l != "") wt[l]=1
      while ((getline l < dtf) > 0) if (l != "") dt[l]=1
      while ((getline l < ikf) > 0) if (l != "") ik[l]=1
      while ((getline l < accf) > 0) {
        if (l == "") continue
        files[l]=1
        n=split(l, p, "/"); b=p[n]; sub(/\.md$/, "", b); stem[l]=b
      }
    }
    {
      c=index($0, ":"); if (c==0) next
      f=substr($0, 1, c-1); rest=substr($0, c+1)
      if (!(f in files)) next
      if (match(rest, /\*\*ID\*\*:[ \t]*/))            { v=substr(rest, RSTART+RLENGTH); gsub(/[ \t]+$/, "", v); id[f]=v }
      else if (match(rest, /\*\*Worktree\*\*:[ \t]*/)) { v=substr(rest, RSTART+RLENGTH); gsub(/[ \t]/, "", v);   slug[f]=v }
      else if (match(rest, /\*\*Integrated-At\*\*:[ \t]*/)) { v=substr(rest, RSTART+RLENGTH); gsub(/[ \t]/, "", v); integ[f]=v }
    }
    END {
      cInteg=0; cTerm=0
      for (f in files) {
        s=stem[f]; i=(f in id)?id[f]:""; sl=(f in slug)?slug[f]:""
        hasInteg=(s in ik)?1:0   # LP-CAS: integration truth is the ledger marker, keyed by stem
        hasBranch=(sl!="" && sl!="none" && (sl in wt))?1:0
        if (hasInteg) cInteg++
        if (mode=="override") term=1
        else term=(hasInteg || sl=="" || sl=="none" || !hasBranch)?1:0
        isCand=(mode=="default" && sl!="" && sl!="none" && hasBranch && !hasInteg)?1:0
        if (term) cTerm++
        if (isCand) { print "CAND\t" f }
        else if (term && is_dep_target(s, i)) { print "SAT\t" s "\t" i }
      }
      print "COUNTS\t" cInteg "\t" cTerm
    }
  ')
  # Parse the awk output into shell state.
  while IFS="$(printf '\t')" read -r kind a b; do
    case "$kind" in
      COUNTS) c_integrated="$a"; c_term_acc="$b";;
      CAND)   DIGEST_CAND_STEMS="$DIGEST_CAND_STEMS$a
";;
      SAT)
        [ -n "$DIGEST_SAT_JSON" ] && DIGEST_SAT_JSON="$DIGEST_SAT_JSON,"
        DIGEST_SAT_JSON="$DIGEST_SAT_JSON{\"stem\":\"$(jesc "$a")\",\"id\":\"$(jesc "$b")\"}"
        ;;
    esac
  done <<EOF
$DIGEST_AWK
EOF
  c_integrated=${c_integrated:-0}
  c_term_acc=${c_term_acc:-0}
elif [ -d "$BL/accepted" ]; then
  # Full / counts-only mode: original per-file accepted classification.
  # integrated = accepted tasks carrying a non-empty hex Integrated-At (>=7 chars).
  # c_term_acc = accepted tasks TERMINAL by the default-mode runtime rule (mirrors JS isTerminal for
  # accepted): hasIntegratedAt (non-empty Integrated-At), OR non-code slug ("" / "none"), OR no branch.
  for f in "$BL/accepted"/*.md; do
    [ -f "$f" ] || continue
    a_stem=$(basename "$f" .md)
    a_slug=$(field "$f" "Worktree" | tr -d '[:space:]')
    a_hasInteg=false; is_integrated_key "$a_stem" && { a_hasInteg=true; c_integrated=$((c_integrated + 1)); }
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

# ---- Per-task objects ----
if [ "$COUNTS_ONLY" = "false" ] && [ "$DIGEST" = true ]; then
  # Digest tasks[]: actionable non-accepted tasks (full) + accepted integration candidates (full).
  # NO terminal accepted objects (they live in satisfiedDeps + counts). No slim stubs.
  for st in $ACTIVE_NONACC; do
    d="$BL/$st"; [ -d "$d" ] || continue
    for f in "$d"/*.md; do [ -f "$f" ] || continue; emit_task_full "$f" "$st"; done
  done
  # Integration candidates: emit the accepted candidate files identified by the batched classifier.
  while IFS= read -r cf; do
    [ -z "$cf" ] && continue
    [ -f "$cf" ] && emit_task_full "$cf" "accepted"
  done <<EOF
$DIGEST_CAND_STEMS
EOF
fi

if [ "$COUNTS_ONLY" = "false" ] && [ "$DIGEST" = false ]; then
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
  # --only seeds are retained in full mode too, for the same reason as in digest mode above.
  DEP_TOKENS=$(printf '%s\n%s\n' "$DEP_TOKENS" "$SCOPE_SEED_STEMS" | grep -v '^$' | sort -u)
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
  for st in $ACTIVE; do
    d="$BL/$st"; [ -d "$d" ] || continue
    for f in "$d"/*.md; do
      [ -f "$f" ] || continue
      stem=$(basename "$f" .md)
      id=$(field "$f" "ID")
      slug=$(field "$f" "Worktree" | tr -d '[:space:]')
      hasInteg=false; is_integrated_key "$stem" && hasInteg=true   # ledger oracle, not Integrated-At
      hasWtBranch=false
      if [ -n "$slug" ] && [ "$slug" != "none" ] && printf '%s\n' "$EXISTING_WT_SLUGS" | grep -qxF "$slug"; then hasWtBranch=true; fi

      # Working-set collapse: a TERMINAL accepted task that nothing depends on is dropped from tasks[]
      # (it survives only in the aggregate counts) so the snapshot stays small enough for the workflow
      # agent to echo reliably. Keep it if it is a dependency target — then depsSatisfied/resolve never
      # see a null. Non-accepted folders are always emitted (they drive dispatch).
      rc=$(field "$f" "Rejection Count" | tr -d '[:space:]')
      printf '%s' "$rc" | grep -qE '^-?[0-9]+$' || rc=0
      bc=$(field "$f" "Block-Count" | tr -d '[:space:]')
      printf '%s' "$bc" | grep -qE '^-?[0-9]+$' || bc=0
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
        if [ "$TFIRST" -eq 1 ]; then TFIRST=0; else TASKS_JSON="$TASKS_JSON,"; fi
        TASKS_JSON="$TASKS_JSON{\"stem\":\"$(jesc "$stem")\",\"id\":\"$(jesc "$id")\",\"folder\":\"accepted\",\"slug\":\"$(jesc "$slug")\",\"deps\":[],\"touchesGlobs\":[],\"hasIntegratedAt\":$hasInteg,\"hasWorktreeBranch\":$hasWtBranch,\"rejectionCount\":$rc,\"blockCount\":$bc,\"ageHours\":-1,\"slim\":true}"
        continue
      fi

      emit_task_full "$f" "$st"
    done
  done
fi

# ---- Worktree registry (skipped in --counts-only and --digest) ----
# The /go scheduler does not consume worktrees[]; digest omits it (and its per-worktree git calls) to
# keep the echo small. Full mode still emits it for the interactive/standalone snapshot consumers.
WT_JSON=""
if [ "$COUNTS_ONLY" = "false" ] && [ "$DIGEST" = false ] && [ -d "$REPO_ROOT/.worktree" ]; then
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
    onExpected=false; [ "$actual" = "$ACFW_BRANCH_PREFIX/$slug" ] && onExpected=true
    isLive=false; printf '%s\n' "$LIVE_SLUGS" | grep -qxF "$slug" && isLive=true
    if [ "$wfirst" -eq 1 ]; then wfirst=0; else WT_JSON="$WT_JSON,"; fi
    WT_JSON="$WT_JSON{\"slug\":\"$(jesc "$slug")\",\"branch\":\"$(jesc "$actual")\",\"onExpectedBranch\":$onExpected,\"isLive\":$isLive}"
  done < <(find "$REPO_ROOT/$ACFW_WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi

# ---- inactive[] for scoped draft/archive seeds (3.4.0) -----------------------------------------
# The scanner has never emitted draft/archive cards, and it still does not emit them wholesale. But a
# seed naming one must come back as a RECOGNISED card in a non-schedulable state, or the orchestrator
# cannot tell "this is paused" from "this does not exist" — and those two deserve opposite answers.
INACTIVE_JSON=""
IFIRST=1
if [ -n "$SCOPE_INACTIVE" ]; then
  while IFS="$ACFW_TAB" read -r istem ifold; do
    [ -z "$istem" ] && continue
    ifile="$BL/$ifold/$istem.md"
    [ -f "$ifile" ] || continue
    iid=$(field "$ifile" "ID" | tr -d '[:space:]')
    islug=$(field "$ifile" "Worktree" | tr -d '[:space:]')
    ideps=$(field "$ifile" "Dependencies")
    if [ "$IFIRST" -eq 1 ]; then IFIRST=0; else INACTIVE_JSON="$INACTIVE_JSON,"; fi
    INACTIVE_JSON="$INACTIVE_JSON{\"stem\":\"$(jesc "$istem")\",\"id\":\"$(jesc "$iid")\",\"folder\":\"$(jesc "$ifold")\",\"slug\":\"$(jesc "$islug")\",\"deps\":$(jarr "$ideps"),\"touchesGlobs\":[],\"hasIntegratedAt\":false,\"hasWorktreeBranch\":false}"
  done <<EOF
$SCOPE_INACTIVE
EOF
fi

# ---- scope{} (3.4.0) ---------------------------------------------------------------------------
SCOPE_JSON=""
if [ -n "$ONLY_SEEDS" ]; then
  _seeds=$(printf '%s' "$ONLY_SEEDS" | grep -v '^$' | while IFS= read -r t; do printf '"%s",' "$(jesc "$t")"; done)
  _res=$(printf '%s' "$SCOPE_RESOLVED" | grep -v '^$' | while IFS="$ACFW_TAB" read -r t st; do printf '"%s":"%s",' "$(jesc "$t")" "$(jesc "$st")"; done)
  _unres=$(printf '%s' "$SCOPE_UNRESOLVED" | grep -v '^$' | while IFS= read -r t; do printf '"%s",' "$(jesc "$t")"; done)
  _amb=$(printf '%s' "$SCOPE_AMBIGUOUS" | grep -v '^$' | while IFS="$ACFW_TAB" read -r t cands; do
    printf '{"tok":"%s","candidates":[' "$(jesc "$t")"
    # printf '%s\n' (not '%s'): without the trailing newline `read` hits EOF on the LAST candidate
    # and returns non-zero, so the loop body never runs for it and the ambiguity report silently
    # names one fewer candidate than it found — the opposite of the point.
    # `tr -d` the trailing comma rather than `sed 's/,$//'`: this whole object must stay on ONE line
    # (the file's contract, and acfw-store's `sed '1s/^{/...'` header injection depends on it), and
    # BSD sed APPENDS a newline to input that has none — putting a literal newline mid-object.
    printf '%s\n' "$cands" | tr ',' '\n' | while IFS= read -r c; do [ -n "$c" ] && printf '"%s",' "$(jesc "$c")"; done | tr -d '\n' | sed 's/,$//' | tr -d '\n'
    printf ']},'
  done)
  _inact=$(printf '%s' "$SCOPE_INACTIVE" | grep -v '^$' | while IFS="$ACFW_TAB" read -r st fo; do printf '{"stem":"%s","folder":"%s"},' "$(jesc "$st")" "$(jesc "$fo")"; done)
  SCOPE_JSON=",\"scopeApplied\":true,\"scope\":{\"seeds\":[${_seeds%,}],\"resolved\":{${_res%,}},\"unresolved\":[${_unres%,}],\"ambiguous\":[${_amb%,}],\"inactiveSeeds\":[${_inact%,}],\"added\":[]}"
fi

# ---- relay header (3.4.0) ----------------------------------------------------------------------
# The snapshot is produced by this script but DELIVERED by an agent echoing its stdout into a schema
# string. A shortened-but-valid echo parses cleanly and is indistinguishable from a smaller board, so
# the producer states what it emitted and the consumer proves it received all of it. Counted here,
# from the assembled JSON, under LC_ALL=C so ${#s} is a BYTE length (what relayCheck expects).
count_stems() { # <json-array-body> -> one stem per line
  printf '%s' "$1" | grep -o '"stem":"[^"]*"' | sed 's/^"stem":"//; s/"$//'
}
_R_STEMS=$(printf '%s\n%s\n%s\n' "$(count_stems "$TASKS_JSON")" "$(count_stems "$INACTIVE_JSON")" "$(count_stems "$DIGEST_SAT_JSON")" | grep -v '^$' || true)
R_TASKS=$(count_stems "$TASKS_JSON" | grep -c '[^[:space:]]' || true); R_TASKS=${R_TASKS//[^0-9]/}
R_INACT=$(count_stems "$INACTIVE_JSON" | grep -c '[^[:space:]]' || true); R_INACT=${R_INACT//[^0-9]/}
R_SAT=$(count_stems "$DIGEST_SAT_JSON" | grep -c '[^[:space:]]' || true); R_SAT=${R_SAT//[^0-9]/}
R_N=$(( ${R_TASKS:-0} + ${R_INACT:-0} + ${R_SAT:-0} ))
R_BYTES=0
if [ -n "$_R_STEMS" ]; then
  R_BYTES=$(LC_ALL=C awk '{ n += length($0) } END { print n+0 }' <<EOF
$_R_STEMS
EOF
)
fi

# ---- Assemble ----
printf '{'
printf '"relay":{"n":%d,"tasks":%d,"inactive":%d,"sat":%d,"bytes":%d},' "$R_N" "${R_TASKS:-0}" "${R_INACT:-0}" "${R_SAT:-0}" "$R_BYTES"
printf '"trunkRoot":"%s",' "$(jesc "$REPO_ROOT")"
printf '"trunkBranch":"%s",' "$(jesc "$TRUNK_BRANCH")"
printf '"trunkSha":"%s",' "$(jesc "$TRUNK_SHA")"
printf '"detachedHead":%s,' "$DETACHED"
printf '"countsOnly":%s,' "$COUNTS_ONLY"
printf '"digest":%s,' "$DIGEST"
printf '"mode":"%s",' "$MODE_ARG"
printf '"generatedAt":"%s",' "$GEN_TS"
printf '"inProgressTimeoutHours":%d,' "$TIMEOUT_H"
printf '"branchPrefix":"%s",' "$(jesc "$ACFW_BRANCH_PREFIX")"
printf '"worktreeDir":"%s",' "$(jesc "$ACFW_WORKTREE_DIR")"
emit_counts
printf ',"tasks":[%s]' "$TASKS_JSON"
printf ',"inactive":[%s]' "$INACTIVE_JSON"
printf ',"satisfiedDeps":[%s]' "$DIGEST_SAT_JSON"
printf ',"worktrees":[%s]' "$WT_JSON"
printf '%s' "$SCOPE_JSON"
printf '}\n'
