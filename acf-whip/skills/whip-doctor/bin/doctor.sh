#!/usr/bin/env bash
# doctor.sh — backlog integrity battery for acf-whip.
#
# Usage:
#   doctor.sh [--fix] [--quiet] [--active-only] [--mode override|default] [REPO_ROOT]
#     --fix      apply the REPAIRABLE class, then re-scan (default: report only)
#     --mode     integration mode this backlog is being run under; defaults to the resolved
#                ACFW_INTEGRATION_MODE pin (env > config > unpinned). In `override` mode the
#                operator integrates (PR per group), so accepted-but-unintegrated is a NORMAL
#                resting state rather than a defect: the cross-slug dep gate stops firing and an
#                accepted task's worktree stops counting as an orphan. Both changes exist to keep
#                this battery agreeing with the scheduler (whip-go.workflow.js isTerminal/
#                depsSatisfied) — when they disagree, the run aborts on a FATAL the scheduler
#                deliberately allowed, or --fix deletes a branch the scheduler still needs.
#     --quiet    print only FATAL findings + BREAKDOWN + SUMMARY (suppress the per-finding dump);
#                bounds output to O(fatals + codes) so hundreds of historical advisories don't have
#                to flow through the /go scan agent. The interactive /whip-doctor stays verbose.
#     --active-only  per-iteration fast path: run the FULL per-file pass only on the non-accepted
#                active folders (where every mid-run FATAL lives), and feed the cross-task awk graph a
#                cheap BATCHED stub row per accepted task (stem/id/slug/integ/hasBranch) instead of the
#                per-file field() extraction (the 240-600x process-spawn hotspot on a lived-in backlog).
#                Accepted tasks are advisory-only (forced WARN, never a gate FATAL), so the FATAL set
#                and the ok flag are UNCHANGED — only suppressed accepted advisories (WARN/REPAIRABLE
#                counts) differ. Never combine with --fix (the startup gate uses the full --fix pass).
#     REPO_ROOT  defaults to $ACFW_TRUNK_ROOT or `git rev-parse --show-toplevel`
#
# Output (one line per finding, machine- and human-readable):
#   SEVERITY|CODE|TASK_ID|DETAIL          SEVERITY in FATAL|REPAIRABLE|WARN
#   SUMMARY|fatal=N|repairable=N|warn=N|ok=true|false
#
# Exit: 0 when no FATAL findings remain (ok=true); 1 when FATAL findings remain.
# When run as a /go gate, ok=false MUST block dispatch.
#
# Portability: pure bash 3.2 (no `declare -A`) — cross-task graph analysis runs in awk,
# which has portable associative arrays. macOS ships bash 3.2, so this matters.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../../lib/acfw-git.sh"

FIX=0
QUIET=0
ACTIVE_ONLY=0
MODE_ARG=""
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --fix) FIX=1; shift;;
    --quiet) QUIET=1; shift;;
    --active-only) ACTIVE_ONLY=1; shift;;
    # `shift 2` with only one arg left FAILS and shifts nothing, which spins this loop forever.
    # Demand the value explicitly (same guard acfw-store uses for --stage).
    --mode) [ $# -ge 2 ] || { echo "FATAL: --mode requires a value (override|default)" >&2; exit 2; }
            MODE_ARG="$2"; shift 2;;
    --mode=*) MODE_ARG="${1#--mode=}"; shift;;
    *) break;;
  esac
done
case "$MODE_ARG" in
  override|default|"") ;;
  *) echo "FATAL: --mode must be 'override' or 'default', got '$MODE_ARG'" >&2; exit 2;;
esac
REPO_ROOT="${1:-${ACFW_TRUNK_ROOT:-$(git rev-parse --show-toplevel)}}"
BL="$REPO_ROOT/.backlog"

# ---- store guard (the ONLY thing between a non-files board and a destructive --fix) --------------
# Resolved HERE, before acfw_load_namespace (:70) and the config source at (:77) below, for the
# same reason the --mode block above documents: those helpers SOURCE the config file, which would put
# the config's ACFW_STORE into the environment and silently invert the documented env > config
# precedence acfw_resolve_store implements.
#
# This script is the `files` engine. Every check it owns is gated on a `.backlog/<state>/` directory,
# so on a store that keeps state elsewhere every one of them is skipped and the summary reports
# fatal=0 ok=true against zero evidence. Worse, the worktree-registry pass further down is NOT gated:
# it builds its live-slug set from the (now empty) TSV, concludes every acf-whip worktree is orphaned,
# and under --fix runs `git worktree remove --force` + `git branch -D` on each one. In override mode
# those branches are the operator's only copy of an accepted-but-unintegrated deliverable.
#
# So: refuse. Loudly, on stderr, with exit 2, and WITHOUT emitting a SUMMARY line — a refusal a caller
# could parse as a clean report is the same defect one layer up.
ACFW_DOCTOR_STORE=$(acfw_resolve_store "$REPO_ROOT")
if [ "$ACFW_DOCTOR_STORE" != "files" ]; then
  cat >&2 <<EOF
FATAL: doctor.sh is the 'files' store engine, but the active task store is '$ACFW_DOCTOR_STORE'.
       It cannot read that store, and running it anyway reports a clean board against no evidence
       (and with --fix would delete this repo's acf-whip worktrees and their branches).
       Use the dispatcher, which routes to the right battery for every backend:
         bash "\$CLAUDE_PLUGIN_ROOT/skills/lib/bin/acfw-store" doctor [--fix]
EOF
  exit 2
fi
if [ ! -d "$BL" ]; then
  echo "FATAL: task store is 'files' but there is no .backlog/ at $REPO_ROOT — run /whip-init." >&2
  exit 2
fi
# Integration mode: --mode (explicit caller intent) > ACFW_INTEGRATION_MODE env > config key > unpinned.
# Resolved BEFORE acfw_load_namespace because that helper SOURCES the config file, which would
# overwrite an inherited ACFW_INTEGRATION_MODE with the config's own value and silently invert the
# documented env > config precedence. "" and "default" are equivalent here — only "override" relaxes.
MODE=$(acfw_resolve_integration_mode "$REPO_ROOT") || exit 2
[ -n "$MODE_ARG" ] && MODE="$MODE_ARG"
# Timeout precedence: env var > committed config (.acfwhip/config > .backlog/.acfw-config) > default 8h.
# RESOLVED HERE, ABOVE acfw_load_namespace, and read rather than sourced — the same trap :96 documents
# for ACFW_INTEGRATION_MODE, which was hoisted for exactly this reason. acfw_load_namespace SOURCES the
# config into this shell, so an inherited ACFW_INPROGRESS_TIMEOUT_HOURS was overwritten by the config's
# own value before the old code below ever looked at it: config beat env, the documented precedence
# inverted, and a project whose config said 1h had the scheduler time a task out at 1h while the same
# iteration's doctor, still on 8h, reported no stale-in-progress at all.
TIMEOUT_H="${ACFW_INPROGRESS_TIMEOUT_HOURS:-}"
[ -n "$TIMEOUT_H" ] || TIMEOUT_H=$(acfw_config_get "$REPO_ROOT" ACFW_INPROGRESS_TIMEOUT_HOURS)
# A non-numeric value (a stray unit like "8h", or a trailing "# comment") reaches an arithmetic
# comparison far below and aborts the whole scan there, with nothing naming the key that did it.
case "$TIMEOUT_H" in
  ''|*[!0-9]*)
    [ -n "$TIMEOUT_H" ] && echo "WARN: ACFW_INPROGRESS_TIMEOUT_HOURS='$TIMEOUT_H' is not a whole number of hours; using 8." >&2
    TIMEOUT_H=8 ;;
esac
acfw_load_namespace "$REPO_ROOT"   # sets ACFW_WORKTREE_DIR / ACFW_BRANCH_PREFIX (worktree ownership)
ACTIVE="pending in-progress completed in-review blocked rejected accepted"
# Non-accepted active folders: in --active-only mode the full per-file pass runs only over these
# (accepted is fed to the awk graph as a cheap batched stub — see emit_accepted_stub_tsv).
ACTIVE_NONACC="pending in-progress completed in-review blocked rejected"

FINDINGS=$(mktemp "${TMPDIR:-/tmp}/acfw-doctor.XXXXXX")
TSV=$(mktemp "${TMPDIR:-/tmp}/acfw-doctor-tsv.XXXXXX")
# Slugs derived during THIS scan. A file, not a variable, for the same reason $FINDINGS is one: the
# per-task loop and its callees run inside command substitutions and pipelines, so a shell variable
# assigned in there never reaches the parent.
DERIVED=$(mktemp "${TMPDIR:-/tmp}/acfw-doctor-slugs.XXXXXX")
trap 'rm -f "$FINDINGS" "$TSV" "$DERIVED"' EXIT
emit() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$FINDINGS"; }
field() { grep -E "^- \*\*$2\*\*:" "$1" 2>/dev/null | head -1 | sed -E "s/.*$2\*\*:[[:space:]]*//" | sed -E 's/[[:space:]]+$//'; }
# The collapsed-document check, factored so the --active-only accepted screen can reuse it and the two
# paths cannot disagree about what counts as a destroyed document. Kept SEPARATE from the NUL screen
# and called only for a file whose field lookup already failed: a well-formed task must never reach
# this awk, which is what keeps the per-file pass affordable on a large board.
# Returns 0 (and emits) when the document is destroyed, 1 when it is fine.
check_collapsed() { # <file> <stem> <folder>
  local f="$1" stem="$2" folder="$3" collapsed nrow what
  collapsed=$(awk '/^#/{h++} /^\|/{r++} /[^[:space:]]/{n++}
                   END{print ((h+0)==0 && (n+0)==(r+0)) ? 1 : 0}' "$f" 2>/dev/null)
  [ "${collapsed:-0}" = "1" ] || return 1
  nrow=$(grep -c '^|' "$f" 2>/dev/null || true); nrow=${nrow:-0}
  if [ "$nrow" -eq 0 ]; then what="task file is empty"; else what="task file collapsed to $nrow transition-log row(s) — no headings, no metadata"; fi
  emit FATAL collapsed-task-file "$stem" "$what. A concurrent write destroyed the document; the content is still in git. Restore: git -C $REPO_ROOT checkout HEAD -- .backlog/$folder/$stem.md   (then re-run /whip-doctor; NOT --fix-able)"
  return 0
}

# The NUL screen, same reasoning. Cheap (one tr), so it runs for every file, as it always has.
check_control_bytes() { # <file> <stem> <folder>
  local f="$1" stem="$2" folder="$3" nnul
  nnul=$(LC_ALL=C tr -dc '\000' < "$f" 2>/dev/null | wc -c | tr -d '[:space:]')
  [ "${nnul:-0}" -gt 0 ] || return 1
  emit FATAL control-bytes "$stem" "$nnul raw NUL byte(s) (0x00) in the task file — every field lookup is unreliable. Strip: LC_ALL=C tr -d '\\000' < .backlog/$folder/$stem.md > /tmp/t && mv /tmp/t .backlog/$folder/$stem.md"
  return 0
}

commit_fix() { # <path-rel> <msg>
  git_with_lock_backoff -C "$REPO_ROOT" add "$1" >/dev/null 2>&1 || true
  git_with_lock_backoff -C "$REPO_ROOT" commit -m "$2" --quiet >/dev/null 2>&1 || true
}

# Existing worktree-branch slugs (ONE git call). Used to tell a live, integratable accepted
# task (its worktree/<slug> branch exists) from a historical/pre-2.0.0 one (no branch — already
# on trunk the old way, nothing to integrate, terminal). Membership is a fixed-string whole-line
# compare so a metachar slug never matches the wrong entry.
EXISTING_WT_SLUGS=$(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "refs/heads/$ACFW_BRANCH_PREFIX/" 2>/dev/null | sed "s#^${ACFW_BRANCH_PREFIX}/##")
has_branch() { printf '%s\n' "$EXISTING_WT_SLUGS" | grep -qxF "$1"; }

# Integration ledger keys present on the CURRENT trunk tree (ONE git call). The doctor still never
# WRITES integration state — it reads the oracle only to tell "landed" from "assumed landed" below.
INTEGRATED_KEYS=$(acfw_integrated_keys "$REPO_ROOT" HEAD 2>/dev/null || true)
is_integrated_key() { printf '%s\n' "$INTEGRATED_KEYS" | grep -qxF "$1"; }

# --active-only: emit a cheap BATCHED TSV stub row per accepted task so the cross-task awk graph keeps
# every accepted stem as a dep-resolution target (resolve/dangling-dep/cross-slug-dep-not-integrated/
# duplicate-id/dup-folder stay correct) WITHOUT the per-file field() extraction. ONE find + ONE grep
# (ID/Worktree/Integrated-At) feed ONE awk. Accepted deps are emitted "none": an accepted task can
# only ever be the DEPENDED-UPON side of a FATAL (cross-slug-dep-not-integrated fires on the active
# DEPENDENT), and its own structural defects are advisory (WARN) — so its own deps never gate. id IS
# emitted (duplicate-id is FATAL across folders). TSV columns mirror the full pass exactly (11 cols).
emit_accepted_stub_tsv() {
  [ -d "$BL/accepted" ] || return 0
  local accf wtf ikf suspf sf kind sstem
  accf=$(mktemp "${TMPDIR:-/tmp}/acfw-doctor-acc.XXXXXX")
  wtf=$(mktemp "${TMPDIR:-/tmp}/acfw-doctor-wt.XXXXXX")
  ikf=$(mktemp "${TMPDIR:-/tmp}/acfw-doctor-ik.XXXXXX")
  suspf=$(mktemp "${TMPDIR:-/tmp}/acfw-doctor-susp.XXXXXX")
  find "$BL/accepted" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' 2>/dev/null > "$accf"
  printf '%s\n' "$EXISTING_WT_SLUGS" > "$wtf"
  printf '%s\n' "$INTEGRATED_KEYS" > "$ikf"
  grep -HE '^- \*\*(ID|Worktree|Integrated-At)\*\*:' "$BL/accepted/"*.md 2>/dev/null | awk \
    -v accf="$accf" -v wtf="$wtf" -v ikf="$ikf" -v suspf="$suspf" '
    BEGIN {
      while ((getline l < wtf) > 0) if (l != "") wt[l]=1
      while ((getline l < ikf) > 0) if (l != "") ik[l]=1
      while ((getline l < accf) > 0) { if (l=="") continue; files[l]=1; n=split(l,p,"/"); b=p[n]; sub(/\.md$/,"",b); stem[l]=b }
    }
    {
      c=index($0,":"); if (c==0) next
      f=substr($0,1,c-1); rest=substr($0,c+1)
      if (!(f in files)) next
      if (match(rest,/\*\*ID\*\*:[ \t]*/))            { v=substr(rest,RSTART+RLENGTH); gsub(/[ \t]+$/,"",v); id[f]=v }
      else if (match(rest,/\*\*Worktree\*\*:[ \t]*/)) { v=substr(rest,RSTART+RLENGTH); gsub(/[ \t]/,"",v);   slug[f]=v }
      else if (match(rest,/\*\*Integrated-At\*\*:[ \t]*/)) { v=substr(rest,RSTART+RLENGTH); gsub(/[ \t]/,"",v); integ[f]=v }
    }
    END {
      for (f in files) {
        s=stem[f]; i=(f in id)?id[f]:""; sl=(f in slug)?slug[f]:""; ig=(f in integ)?integ[f]:""
        # Ledger truth wins over the inert Integrated-At field: the gate asks the same oracle the scheduler does.
        if (ig=="" && (s in ik)) ig="ledger"
        hb=(sl!="" && sl!="none" && (sl in wt))?1:0
        # An accepted file the batched grep found NO ID in is the CONTENT-LOSS signature: a collapsed
        # document has no metadata line at all, and a raw NUL makes grep treat the file as binary and
        # print nothing for it. Name it; the shell confirms below.
        if (i=="") print f > suspf
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", s, "accepted", i, "accepted", sl, "", "none", ig, "", 0, hb
      }
    }
  '
  # CONFIRM the suspects. --active-only skips the per-file pass over accepted/ — that is the point of
  # the flag and the reason it is ~3.5x faster — but control-bytes and collapsed-task-file are CONTENT
  # LOSS, not advisories, and they are FATAL regardless of folder. Without this the fast path reports
  # ok=true over a destroyed document, which is precisely what the gate exists to refuse, and the
  # flag's documented contract ("the FATAL set and the ok flag are UNCHANGED") would be false.
  # Bounded by the number of ID-less accepted files — normally zero — not by board size.
  while IFS= read -r sf; do
    [ -n "$sf" ] && [ -f "$sf" ] || continue
    sstem=$(basename "$sf" .md)
    check_control_bytes "$sf" "$sstem" "accepted" && continue
    check_collapsed "$sf" "$sstem" "accepted" && continue
    emit WARN unparseable-frontmatter "$sstem" "missing ID and/or Status field"
  done < "$suspf"
  rm -f "$accf" "$wtf" "$ikf" "$suspf"
}

# Derive a kebab-case worktree slug from a task id: drop the "<category>-<NNN>-" prefix and keep
# the descriptive tail (already kebab-case); fall back to "<category>-<NNN>" if the tail is empty
# or invalid. A DISTINCT per-task slug is intentional — one worktree branch per task maximizes
# parallel dispatch. Tasks that genuinely share a file surface are surfaced by the separate
# cross-slug-glob-overlap WARN, not silently serialized here.
# Task-id category vocabulary. Kept in ONE place here and mirrored by ID_RE/CATEGORIES in
# workflows/whip-task.workflow.js — the two are the same regex and drifted apart once already.
# Conventional-commit types beyond the original eight are included because teams put the originating
# ticket category in the id, and an unrecognised prefix used to fall through to the give-up branch.
ACFW_ID_CATEGORIES='feature|bug|infra|test|docs|refactor|data|ml|chore|perf|ci|build|style'

derive_slug() { # <id>
  local id="$1" tail head
  # The sequence number is [0-9]+ and ANCHORED on both sides. It used to be [0-9]{1,4} followed by
  # an unanchored `.*`, so a five-digit id matched a PREFIX of its own digit run: bug-62015-alpha and
  # bug-62017-beta both derived `bug-6201`. Two tasks on one worktree branch, silently — which is the
  # one thing the per-task slug exists to prevent.
  tail=$(printf '%s' "$id" | sed -E "s/^($ACFW_ID_CATEGORIES)-[0-9]+-//")
  if [ "$tail" != "$id" ] && printf '%s' "$tail" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    printf '%s' "$tail"; return
  fi
  # Fallback: the <category>-<NNN> head, but ONLY when the id is exactly that (optionally followed by
  # a `-`-separated tail). An id this pattern cannot fully account for gives up and returns itself —
  # a slug that is wrong-but-unique is recoverable; two tasks sharing one is not.
  head=$(printf '%s' "$id" | sed -E "s/^(($ACFW_ID_CATEGORIES)-[0-9]+)(-.*)?\$/\1/")
  if [ -n "$head" ] && [ "$head" != "$id" ]; then printf '%s' "$head"; else printf '%s' "$id"; fi
}

# Within-run dedup: two ids that derive the same slug must not both get it written. The second and
# later collisions are reported instead of repaired — picking a disambiguated slug here would invent a
# branch name the task document never states, and the operator needs to see the id collision.
#
# The registry is $DERIVED (a file). It cannot be a shell variable: this function is invoked as
# `derived=$(derive_slug_unique "$id")`, which runs it in a SUBSHELL, so an assignment here would be
# discarded and the collision check could never fire — leaving --fix free to write one slug onto two
# tasks, which is the exact condition this exists to prevent.
derive_slug_unique() { # <id> -> slug on stdout; exit 1 (and empty) when the slug is already claimed
  local d; d=$(derive_slug "$1")
  if grep -qxF "$d" "$DERIVED" 2>/dev/null; then printf ''; return 1; fi
  printf '%s\n' "$d" >> "$DERIVED"
  printf '%s' "$d"
}

# Write a derived slug into the task file: replace an empty "- **Worktree**:" line if one exists,
# else insert the field right after the always-present "- **Status**:" line. Then commit.
write_slug() { # <file> <folder> <stem> <slug>
  local f="$1" folder="$2" stem="$3" slug="$4"
  if grep -qE '^- \*\*Worktree\*\*:' "$f"; then
    sed -i.bak -E "s|^- \*\*Worktree\*\*:.*|- **Worktree**: $slug|" "$f" && rm -f "$f.bak"
  else
    sed -i.bak -E "/^- \*\*Status\*\*:/a\\
- **Worktree**: $slug" "$f" && rm -f "$f.bak"
  fi
  commit_fix ".backlog/$folder/$stem.md" "doctor: derive Worktree slug '$slug' on $stem"
}

# ---- FATAL: detached HEAD at trunk root ----
if ! git -C "$REPO_ROOT" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
  emit FATAL detached-head "(repo)" "HEAD is detached at $REPO_ROOT; /go requires a branch checked out at the repo root"
fi

# ---- WARN: tracked files dirty at the shared trunk root, outside .backlog/ ----
# A specialist is supposed to write only inside its own worktree. A relative path resolved against the
# SHARED root instead leaves work here, where the integrator's post-land `reset --hard` will discard it.
# Untracked files are excluded: operator scratch lives at the root legitimately.
ndirty=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | awk 'substr($0,1,2)!="??" && substr($0,4,9)!=".backlog/"{n++} END{print n+0}')
[ "${ndirty:-0}" -gt 0 ] && emit WARN dirty-trunk-root "(repo)" "$ndirty tracked file(s) modified/staged at the trunk root outside .backlog/ — a specialist may have escaped its worktree; commit or stash them before the next integration resyncs the root (git reset --hard)"

# ---- WARN: local trunk ahead of origin ----
# The LP-CAS integrator lands on the LOCAL trunk by compare-and-swap and NEVER pushes — by design (a
# push per landing would need credentials in every agent env, fire CI per task, and drag network faults
# into the integrator's exit taxonomy). Divergence is a fact to surface, not a fault to automate away.
# Zero network: reads only the local remote-tracking ref, and says nothing when there is no origin.
HEAD_BR=$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || true)
if [ -n "$HEAD_BR" ] && git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$HEAD_BR" >/dev/null 2>&1; then
  nahead=$(git -C "$REPO_ROOT" rev-list --count "refs/remotes/origin/$HEAD_BR..HEAD" 2>/dev/null || echo 0)
  [ "${nahead:-0}" -gt 0 ] && emit WARN trunk-unpushed "(repo)" "local $HEAD_BR is $nahead commit(s) ahead of origin/$HEAD_BR — acf-whip lands integrations locally and never pushes; push when ready"
fi

# ---- Per-file pass: emit independent findings, apply per-file repairs, build TSV ----
# --active-only restricts the full per-file pass to the non-accepted folders (accepted is fed to the
# awk graph as a cheap batched stub appended below); full/--fix runs always cover every active folder.
# Seed the derived-slug registry with every slug ALREADY CLAIMED, so the collision FATAL is durable.
# Without this the finding is one-shot: run 1 gives the contended slug to the first claimant and
# refuses the second, run 2 sees the first task holding an EXPLICIT slug (so it never enters the
# derive path) and hands the same slug to the second — producing exactly the duplicate the FATAL
# reported. Two sources, both already in hand: explicit Worktree values on non-accepted tasks (ONE
# batched grep, no per-file cost) and the live worktree branches (already fetched at :155).
# Deliberately NOT seeded from accepted tasks: their slugs are historical, and a long-lived backlog
# would turn into an unrepairable wall of FATALs on first run.
{
  for _st in $ACTIVE_NONACC; do
    [ -d "$BL/$_st" ] || continue
    # Per-LINE whitespace strip. `tr -d '[:space:]'` is what the per-file code uses on a single
    # value, but over a multi-line stream it also deletes the newlines and concatenates every slug
    # into one unusable token.
    grep -hE '^- \*\*Worktree\*\*:' "$BL/$_st/"*.md 2>/dev/null \
      | sed -E 's/.*Worktree\*\*:[[:space:]]*//; s/[[:space:]]+$//; s/^[[:space:]]+//'
  done
  printf '%s\n' "$EXISTING_WT_SLUGS"
} | grep -vxE '(none)?' | sort -u >> "$DERIVED" 2>/dev/null || true

LOOP_FOLDERS="$ACTIVE"
[ "$ACTIVE_ONLY" = "1" ] && LOOP_FOLDERS="$ACTIVE_NONACC"
for st in $LOOP_FOLDERS; do
  d="$BL/$st"; [ -d "$d" ] || continue
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    stem=$(basename "$f" .md); folder="$st"

    # A raw NUL byte makes grep treat the file as binary: every field() lookup silently returns nothing,
    # so a task whose fields are all present reports unparseable-frontmatter AND missing-worktree-slug,
    # and /go aborts on a phantom. Detect it FIRST and skip the file — one true finding beats a cascade
    # of false ones. Deliberately NOT --fix-able: a NUL usually marks a torn write, and the bootstrap
    # --fix must never silently commit a half-written task as "healed". Scoped to NUL, not the whole C0
    # class: ESC/formfeed pasted from terminal output are harmless here, and flagging them would newly
    # block runs on files that parse fine.
    if check_control_bytes "$f" "$stem" "$folder"; then continue; fi

    id=$(field "$f" "ID"); status=$(field "$f" "Status"); slug=$(field "$f" "Worktree" | tr -d '[:space:]')
    deps=$(field "$f" "Dependencies"); integ=$(field "$f" "Integrated-At" | tr -d '[:space:]')
    agent=$(field "$f" "Assigned Agent" | tr -d '[:space:]'); rc=$(field "$f" "Rejection Count" | tr -d '[:space:]')
    bc=$(field "$f" "Block-Count" | tr -d '[:space:]')
    globs=$(field "$f" "Touches Globs")
    hasTok=0; grep -qE '\| clean-checkout \| ok \|' "$f" && hasTok=1
    agentOk=1; { [ -n "$agent" ] && [ "$agent" != "none" ] && [ ! -f "$REPO_ROOT/.claude/agents/$agent.md" ]; } && agentOk=0

    # Severity tier: is this task IN THE DISPATCH PATH? A structural defect only gates a run if the
    # scheduler could act on the task. `accepted` is terminal; `draft` is the human gate (excluded
    # from every scan and from the completion denominator); `archive` is retired. None of the three
    # can be dispatched, transitioned or integrated, so a defect there is advisory, never a gate
    # FATAL. This used to test `accepted` alone, which was correct on `files` (its scanner never
    # emits draft/archive) but wrong on every other backend, where the adapter DOES list them: a
    # draft stub with no agent file produced FATAL|unknown-agent and blocked /go outright.
    case "$folder" in
      accepted|draft|archive) sev_struct=WARN ;;
      *)                      sev_struct=FATAL ;;
    esac

    if [ -z "$id" ] || [ -z "$status" ]; then
      # A file loses ID/Status two very different ways, and the recovery is different, so name them
      # apart. COLLAPSE: append_log_row's read-modify-write was unlocked and something emptied the
      # file mid-read, so a 17KB task document became its own transition-log row and the writer
      # committed it (field incident 2026-08-24). The corpse is unmistakable: not one "#" heading,
      # and every non-blank line is a table row (or the file is blank outright). Anything else is
      # ordinary bad frontmatter and keeps the old code. Reporting it as unparseable-frontmatter
      # was actively misleading — it reads as "someone fat-fingered the metadata" and sends the
      # operator to re-type two fields, when the whole document is gone and is sitting in git.
      # ONE awk, and ONLY for a file that already failed the field lookup — a well-formed task
      # never reaches this line, so the check costs nothing on the happy path.
      if check_collapsed "$f" "$stem" "$folder"; then continue; fi
      emit "$sev_struct" unparseable-frontmatter "$stem" "missing ID and/or Status field"
    elif [ "$status" != "$folder" ]; then
      # Status-folder mismatch is REPAIRABLE, not FATAL: the folder is the source of truth, so --fix
      # rewrites Status to match it. This self-heals a backlog whose mover left Status stale (retro I4)
      # instead of aborting /go at its first transition. Accepted stays advisory (WARN).
      if [ "$folder" = "accepted" ]; then
        emit WARN status-folder-mismatch "$stem" "Status: '$status' but file is in .backlog/accepted/ (advisory)"
      elif [ "$FIX" = "1" ]; then
        sed -i.bak -E "s/^- \*\*Status\*\*:.*/- **Status**: $folder/" "$f" && rm -f "$f.bak"
        commit_fix ".backlog/$folder/$stem.md" "doctor: sync Status to folder '$folder' on $stem"
        emit REPAIRABLE status-folder-mismatch "$stem" "rewrote Status '$status' -> '$folder' (folder is source of truth)"
        status="$folder"
      else
        emit REPAIRABLE status-folder-mismatch "$stem" "Status '$status' != folder '$folder'; --fix rewrites Status to '$folder'"
      fi
    fi
    # Missing Worktree slug: advisory on terminal (accepted) tasks; on active tasks it is a
    # REPAIRABLE that --fix self-heals by deriving a slug from the id and writing it in — so a
    # pre-2.0.0 backlog dispatches instead of hard-failing the gate.
    if [ -z "$slug" ]; then
      if [ "$folder" = "accepted" ]; then
        emit WARN missing-worktree-slug "$stem" "accepted task has no Worktree: slug (historical; advisory)"
      elif [ -n "$id" ]; then
        if ! derived=$(derive_slug_unique "$id"); then
          # Collision: another task this scan already claimed this slug. Report ONLY the FATAL — a
          # REPAIRABLE beside it would promise a repair that deliberately will not happen, and
          # "--fix will derive ''" is not a sentence anyone can act on.
          emit FATAL duplicate-derived-slug "$stem" "id '$id' derives a worktree slug already claimed by another task this scan — give one of them an explicit, distinct Worktree: slug"
        elif [ "$FIX" = "1" ]; then
          write_slug "$f" "$folder" "$stem" "$derived"
          slug="$derived"   # use the derived slug for this task's remaining checks (TSV, registry)
          emit REPAIRABLE missing-worktree-slug "$stem" "derived '$derived' from id and wrote it into the task"
        else
          emit REPAIRABLE missing-worktree-slug "$stem" "no Worktree slug; --fix will derive '$derived' from the id"
        fi
      else
        emit "$sev_struct" missing-worktree-slug "$stem" "no Worktree slug and no id to derive one from"
      fi
    fi
    [ "$agentOk" = "0" ] && emit "$sev_struct" unknown-agent "$stem" "Assigned Agent '$agent' has no .claude/agents/$agent.md — create it or run /whip-add-agents, or reassign the task"

    # Legacy JSON-style Dependencies ("[a, b]"): every dep parser here and in the scanner splits on
    # commas and does NOT strip brackets, so "[a" and "b]" resolve to nothing -> a FALSE dangling-dep
    # FATAL on both ids, blocking /go. whip-move used to write this form; repair it at the source so a
    # damaged backlog self-heals on the bootstrap --fix pass instead of teaching three parsers to
    # tolerate a format nothing should emit.
    case "$deps" in
      \[*\])
        bare=$(printf '%s' "$deps" | sed -E 's/^\[//; s/\]$//')
        if [ "$FIX" = "1" ]; then
          sed -i.bak -E "s|^- \*\*Dependencies\*\*:.*|- **Dependencies**: $bare|" "$f" && rm -f "$f.bak"
          commit_fix ".backlog/$folder/$stem.md" "doctor: de-bracket Dependencies on $stem"
          emit REPAIRABLE bracketed-deps "$stem" "rewrote '$deps' -> '$bare' (parsers expect a bare comma list)"
          deps="$bare"
        else
          emit REPAIRABLE bracketed-deps "$stem" "Dependencies '$deps' is JSON-style; --fix rewrites it to the bare comma list '$bare'"
        fi
        ;;
    esac

    # LP-CAS (3.0.0): the Integrated-At markdown field is INERT — integration truth is the in-tree
    # ledger marker (.acfwhip/integrated/), which the doctor never reads or writes. The old
    # "clear stray Integrated-At" reconciliation is dropped: it existed only to keep a metadata field
    # in sync with reality, and clearing a VALID stamp with no git-ancestry check was itself defect #5
    # (re-arming integration). Nothing the doctor does can re-arm integration now, by construction.
    if printf '%s' "$rc" | grep -qE '^-?[0-9]+$'; then
      if [ "$rc" -lt 0 ] || [ "$rc" -gt 5 ]; then
        clamped=$rc; [ "$rc" -lt 0 ] && clamped=0; [ "$rc" -gt 5 ] && clamped=5
        if [ "$FIX" = "1" ]; then
          sed -i.bak -E "s/^- \*\*Rejection Count\*\*:.*/- **Rejection Count**: $clamped/" "$f" && rm -f "$f.bak"
          commit_fix ".backlog/$folder/$stem.md" "doctor: clamp Rejection Count on $stem to $clamped"
          emit REPAIRABLE rejection-count-out-of-range "$stem" "clamped $rc -> $clamped"
        else
          emit REPAIRABLE rejection-count-out-of-range "$stem" "Rejection Count $rc out of [0,5]"
        fi
      fi
    fi
    # Block-Count (per-task re-block counter, retro I2): clamp a negative/garbage value. A value at or
    # above the cap is VALID — it means the task is intentionally parked for an operator — so only the
    # out-of-range low end is repaired (mirrors Rejection Count; upper bound generous to never mask a cap).
    if [ -n "$bc" ] && printf '%s' "$bc" | grep -qE '^-?[0-9]+$'; then
      if [ "$bc" -lt 0 ] || [ "$bc" -gt 9 ]; then
        bclamp=$bc; [ "$bc" -lt 0 ] && bclamp=0; [ "$bc" -gt 9 ] && bclamp=9
        if [ "$FIX" = "1" ]; then
          sed -i.bak -E "s/^- \*\*Block-Count\*\*:.*/- **Block-Count**: $bclamp/" "$f" && rm -f "$f.bak"
          commit_fix ".backlog/$folder/$stem.md" "doctor: clamp Block-Count on $stem to $bclamp"
          emit REPAIRABLE block-count-out-of-range "$stem" "clamped $bc -> $bclamp"
        else
          emit REPAIRABLE block-count-out-of-range "$stem" "Block-Count $bc out of [0,9]"
        fi
      fi
    fi
    [ "$folder" = "accepted" ] && [ "$hasTok" = "0" ] && emit WARN missing-clean-checkout-token "$stem" "accepted without a 'clean-checkout | ok' token"
    [ "$folder" = "in-review" ] && emit WARN lingering-in-review "$stem" "stuck in in-review/ (quality-reviewer must terminate it)"

    # hasBranch: does a real worktree/<slug> branch exist? (col 11; consumed by the awk graph pass)
    hasBranch=0; [ -n "$slug" ] && [ "$slug" != "none" ] && has_branch "$slug" && hasBranch=1

    # The cross-slug dep gate below must ask the SAME oracle the scheduler asks. Integrated-At is inert
    # in 3.0.0, so a task integrated by LP-CAS carries an empty field while its worktree branch still
    # exists (nothing reaps the branch until a later --fix). Reading the field alone therefore declared
    # a dep that IS on trunk "not integrated": the scheduler dispatched the dependent (marker present),
    # and the next per-iteration doctor recheck FATAL'd on it and aborted the whole run. Fold ledger
    # truth into the column the gate reads, so scheduler and doctor can never disagree.
    integGate="$integ"
    [ -z "$integGate" ] && is_integrated_key "$stem" && integGate="ledger"

    # An accepted code task with NO branch is counted terminal on the assumption "already on trunk the
    # old way" — correct for pre-ledger tasks, and a silent hole for anything else: a branch deleted
    # before its change landed makes a never-integrated task look finished (this shipped an accepted
    # billing engine that was absent from trunk). Keep it terminal (a FATAL here would deadlock every
    # historical backlog), but say so once per run. The ack clears the WARN and is itself the evidence.
    if [ "$folder" = "accepted" ] && [ -n "$slug" ] && [ "$slug" != "none" ] && [ "$hasBranch" = "0" ] \
       && [ -z "$integ" ] && ! is_integrated_key "$stem"; then
      emit WARN accepted-branchless-unverified "$stem" "accepted, but no worktree branch and no ledger marker on trunk — integration was never recorded. Verify the deliverable is on trunk, then ack: whip-move $stem accepted --integrated-at <sha>"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$stem" "$folder" "$id" "$status" "$slug" "$agent" "${deps:-none}" "$integGate" "${globs}" "$rc" "$hasBranch" >> "$TSV"
  done
done

# --active-only: append the cheap batched accepted stub rows so the awk graph below resolves every
# cross-task dependency that points at an accepted task (without the per-file field() cost on accepted).
[ "$ACTIVE_ONLY" = "1" ] && emit_accepted_stub_tsv >> "$TSV"

# ---- Cross-task analysis in awk (portable associative arrays) ----
awk -F'\t' -v mode="$MODE" '
# Memoised. A dep token is resolved once per DEPENDENT, so a token shared by many tasks rescanned the
# whole stem table every time. The cache stores misses too ("" is a real answer), which is why the
# presence test is on rcache and not on its value.
function resolve(d, self,   s, k){
  # Exact wins, and is O(1) — including a GENUINE self-dependency, which is a real cycle of one.
  if(d in stems) return d
  # Prefix fallback, excluding the DEPENDING task. Nothing excluded it before, so a token like
  # feature-231-api that no longer exists prefix-matched its own task feature-231-api-v2, the
  # self-loop branch fired, and the doctor reported a cycle that is not there — FATAL, ok=false,
  # /go refuses to dispatch. Which stem won was awk hash order, so it was not even reproducible.
  # A token that resolves only to its own task is a BAD TOKEN: fall through to dangling-dep, which
  # names the thing to fix. Cached per (token, dependent) because the exclusion is per-dependent.
  k = d SUBSEP self
  if(k in rcache) return rcache[k]
  for(s in stems){ if(s!=self && index(s,d)==1){ rcache[k]=s; return s } }
  rcache[k]=""; return ""
}

# Tarjan strongly-connected components. The previous detector peeled nodes with no DEPENDENTS and
# reported whatever survived — which reports every node a cycle can REACH, not the cycle. On
# a->{b,c}, b->a, the peel names a, b AND c, so an innocent dependency of a cycle member was gated
# with the same FATAL as the cycle itself. Under per-task quarantine that mistake is no longer merely
# noisy: it holds a healthy task out of the run. Only members of a non-trivial SCC (or a self-loop)
# are in a cycle, and that is exactly what this computes.
# (No apostrophes in this block: it lives inside a single-quoted awk program.)
function scc_visit(v,   i, m, aa, w, cnt, comp, bb) {
  tj_idx++; tj_num[v]=tj_idx; tj_low[v]=tj_idx
  tj_sp++; tj_stack[tj_sp]=v; tj_on[v]=1
  m=split(adj[v], aa, " ")
  for(i=1;i<=m;i++){
    w=aa[i]
    if(w=="" || !(w in stems)) continue
    if(!(w in tj_num)){ scc_visit(w); if(tj_low[w]<tj_low[v]) tj_low[v]=tj_low[w] }
    else if(w in tj_on){ if(tj_num[w]<tj_low[v]) tj_low[v]=tj_num[w] }
  }
  if(tj_low[v]==tj_num[v]){
    cnt=0
    do { w=tj_stack[tj_sp]; tj_sp--; delete tj_on[w]; cnt++; comp[cnt]=w } while(w!=v)
    if(cnt>1){ for(i=1;i<=cnt;i++) incycle[comp[i]]=1 }
    else { m=split(adj[v], bb, " "); for(i=1;i<=m;i++) if(bb[i]==v) incycle[v]=1 }
  }
}
{
  stem=$1; folder=$2; id=$3; slug=$5; deps=$7; integ=$8; globs=$9; hasBranch=$11;
  stems[stem]=1; state[stem]=folder; slugOf[stem]=slug; integOf[stem]=integ; depsOf[stem]=deps; globsOf[stem]=globs; hasBranchOf[stem]=hasBranch;
  if(id!=""){ idcount[id]++ }
  foldcount[stem]++; foldlist[stem]=foldlist[stem]" "folder;
  if(folder=="pending"){ pend[stem]=1 }
}
END{
  # LP-CAS (3.0.0): a duplicate ID QUARANTINES that id only — it is advisory (WARN), never a FATAL that
  # aborts the whole run. The split-state duplicate that fired FATAL|duplicate-id and aborted 600+ healthy
  # tasks before any dispatch (#6) can no longer happen. The two files carry distinct stems, so each runs
  # on its own slug + ledger key (no integration collision); an operator de-dups the id at leisure.
  for(i in idcount) if(idcount[i]>1) print "WARN|duplicate-id|" i "|ID appears in " idcount[i] " task files (quarantine: de-dup; run continues)";
  for(s in foldcount) if(foldcount[s]>1) print "REPAIRABLE|dup-folder|" s "|present in folders:" foldlist[s];

  for(s in stems){
    n=split(depsOf[s], da, ",");
    for(k=1;k<=n;k++){ d=da[k]; gsub(/[ \t]/,"",d);
      if(d=="" || d=="none") continue;
      r=resolve(d, s);
      if(r==""){ sev=(state[s]=="accepted")?"WARN":"FATAL"; print sev "|dangling-dep|" s "|depends on " d " which has no task file"; continue }
      adj[s]=adj[s]" "r;
      # Branch-aware: a cross-slug dep that is accepted-but-unintegrated only blocks when it still
      # has a live worktree branch (genuinely pending integration). A branchless historical accepted
      # dep is already on trunk -> satisfied (matches the workflow runtime-terminal model).
      # Mode-aware: in override mode NO ledger marker is ever written and Integrated-At is only ever
      # set by hand, so "accepted but not integrated" is the normal end state of every task, not a
      # defect. The scheduler already relaxes this exact gate there (whip-go.workflow.js depsSatisfied
      # blocks only when mode is default) and dispatches the dependent; if this battery kept firing,
      # the per-iteration recheck would FATAL on that dispatch and abort the whole run. Same lesson as
      # integGate above: the scheduler and the doctor must ask the same oracle, or the run dies on a
      # disagreement rather than on a real defect.
      # (No apostrophes in this block: it lives inside a single-quoted awk program.)
      if(mode!="override" && (state[s]=="in-progress"||state[s]=="completed"||state[s]=="in-review") && slugOf[s]!="" && slugOf[r]!=slugOf[s])
        if(state[r]!="accepted" || (integOf[r]=="" && hasBranchOf[r]=="1"))
          print "FATAL|cross-slug-dep-not-integrated|" s "|dispatched (" state[s] ") but cross-slug dep " r " is not accepted+integrated";
    }
  }
  tj_idx=0; tj_sp=0;
  for(s in stems) if(!(s in tj_num)) scc_visit(s);
  for(s in stems) if(s in incycle){ sev=(state[s]=="accepted")?"WARN":"FATAL"; print sev "|cyclic-deps|" s "|participates in a dependency cycle"; }

  # Contended globs, BY INDEX. This was a double loop over every pair of pending tasks with a nested
  # glob comparison — O(P^2 * G^2) — and it emitted one WARN per overlapping PAIR, so a handful of
  # tasks sharing one glob produced a quadratic wall of advisories that an operator has to read past
  # to find a real finding. The relation is an index and always was: group by glob, count distinct
  # slugs, and report each task once. O(P*G), and the output is bounded by the number of tasks.
  for(s in pend){
    if(globsOf[s]=="") continue
    n=split(globsOf[s], gg, ",")
    for(k=1;k<=n;k++){ g=gg[k]; gsub(/[ \t]/,"",g); if(g=="") continue
      if(!((g SUBSEP slugOf[s]) in gseen)){ gseen[g SUBSEP slugOf[s]]=1; gslugs[g]++ } }
  }
  for(s in pend){
    if(globsOf[s]=="") continue
    n=split(globsOf[s], gg, ","); hit=""
    for(k=1;k<=n;k++){ g=gg[k]; gsub(/[ \t]/,"",g); if(g=="") continue
      if(gslugs[g] > 1) hit=(hit=="" ? g : hit ", " g) }
    if(hit!="") print "WARN|cross-slug-glob-overlap|" s "|declares glob(s) " hit " also declared by a task in a different worktree slug (possible mis-partition)"
  }
}' "$TSV" >> "$FINDINGS"

# ---- dup-folder: identify the survivor (report-only AND fix) ----
# Keepability is computed in BOTH passes, because an unresolvable duplicate is a FATAL and the gate
# that decides whether to dispatch only ever reads the report-only pass. It used to be computed
# exclusively inside --fix — whose stdout /go discards — so the gate saw the REPAIRABLE|dup-folder
# line alone, concluded the board was repairable, and dispatched against a stem no writer can address.
# Snapshot the lines first: `emit` appends to $FINDINGS, which is the file being read.
DUP_LINES=$(grep '^REPAIRABLE|dup-folder|' "$FINDINGS" || true)
if [ -n "$DUP_LINES" ]; then
  printf '%s\n' "$DUP_LINES" | while IFS='|' read -r _sev _code stem _detail; do
    [ -n "$stem" ] || continue
    _folders=$(echo "$_detail" | sed -E 's/.*folders:[[:space:]]*//')
    rep="$BL/$(printf '%s' "$_folders" | awk '{print $1}')/$stem.md"
    keep=$(field "$rep" "Status")
    _keepable=0
    for fol in $_folders; do [ "$fol" = "$keep" ] && _keepable=1; done
    [ "$_keepable" = "1" ] || emit "FATAL" "dup-folder-unresolvable" "$stem" "present in folders:$_folders but its Status field reads '${keep:-<unreadable>}', which is not one of them, so no copy can be chosen as the survivor. Every copy is intact. Resolve by hand, then re-run --fix."
  done
fi

# ---- dup-folder repair (after awk reported) ----
if [ "$FIX" = "1" ] && [ -n "$DUP_LINES" ]; then
  printf '%s\n' "$DUP_LINES" | while IFS='|' read -r _sev _code stem _detail; do
    # Iterate the folders THIS STEM WAS REPORTED IN, not every active folder, and keep the one its
    # own Status names. Both halves are load-bearing.
    _folders=$(echo "$_detail" | sed -E 's/.*folders:[[:space:]]*//')
    rep="$BL/$(printf '%s' "$_folders" | awk '{print $1}')/$stem.md"
    keep=$(field "$rep" "Status")
    # THE KEEPER MUST BE ONE OF THOSE FOLDERS. `keep` is an unvalidated field read: an unparseable
    # Status line — the same malformed copy whose status-sync repair above is skipped — or a detail
    # string the sed cannot match (it then returns the whole detail, making `rep` a path that does
    # not exist) both yield "". With the old `for fol in $ACTIVE`, no $fol ever equalled "", the
    # `continue` never fired, and the repair deleted EVERY copy; the `|| rm -f` fallback then
    # unlinked an untracked one outright, with no git history to recover it from. /go runs
    # `doctor --fix` at bootstrap with its output discarded, so this also erased the very FATAL
    # that should have stopped the run. Refuse instead: a repair that cannot identify the survivor
    # is not repairable.
    _keepable=0
    for fol in $_folders; do [ "$fol" = "$keep" ] && _keepable=1; done
    # Already reported as FATAL|dup-folder-unresolvable by the pass above — just refuse to repair.
    [ "$_keepable" = "1" ] || continue
    for fol in $_folders; do
      [ "$fol" = "$keep" ] && continue
      # NO `|| rm -f` FALLBACK. `git rm` failing here means the path is not tracked, and unlinking
      # an untracked task file destroys the only copy of it that exists anywhere.
      [ -f "$BL/$fol/$stem.md" ] && { git_with_lock_backoff -C "$REPO_ROOT" rm -q -- ".backlog/$fol/$stem.md" >/dev/null 2>&1 \
        || emit "WARN" "dup-folder-untracked" "$stem" "left .backlog/$fol/$stem.md in place: git will not remove it, so it is untracked and deleting it would destroy the only copy. Remove it by hand once you have confirmed .backlog/$keep/$stem.md is the one you want."; }
    done
    commit_fix ".backlog" "doctor: dedup $stem to .backlog/$keep/"
  done
fi

# ---- Worktree registry checks ----
# `accepted` is deliberately absent in default mode: the task's change is already on trunk, so its
# worktree is spent and reaping it is the point. In OVERRIDE mode it is the opposite — nothing has
# landed anywhere, nothing was ever pushed, and worktree/<slug> is the ONLY copy of the deliverable
# the operator still has to open a PR from. Reaping it there (--fix runs `worktree remove --force` +
# `branch -D` below) destroys unreviewed work whose sole home is that branch, and it happens on the
# next /go bootstrap, i.e. before anyone notices. Keep accepted slugs live while the operator owns
# integration; they stop being live when the task leaves accepted/.
# An ACCEPTED task whose change has NOT landed is live in BOTH modes. Override was already covered
# (nothing ever lands there, so its branch is the only copy). Default was not — and the gap is a
# work-loss path, not an inefficiency: a task accepted but not yet integrated (the drain deliberately
# leaves an exit-7 conflict "for the next /go run"; a crash between accept and integrate does the
# same) had its worktree removed and its branch -D'd by the very next bootstrap `doctor --fix`. The
# following scan then reads hasWorktreeBranch=false, calls the task terminal, and the deliverable is
# gone with nothing anywhere saying so. A slug is spent only once its change is ON trunk, which is
# exactly what column 8 (integGate: Integrated-At or the ledger marker) records.
LIVE_SLUGS=$(awk -F'\t' -v mode="$MODE" '
  $2=="pending"||$2=="in-progress"||$2=="completed"||$2=="in-review" {print $5; next}
  $2=="accepted" && (mode=="override" || ($8=="" && $11=="1")) {print $5}' "$TSV" | sort -u)

# PARKED slugs (3.4.0). draft/archive are not in $ACTIVE, so they never reach $TSV and a paused
# task's slug looked exactly like an unowned one — the reaper force-removed the worktree and -D'd
# the branch on the next bootstrap `doctor --fix`, whose stdout /go discards. Pausing is the
# SUPPORTED way to park work on every backend, so it must not be the way to lose it. Reported, never
# reaped: the judgement about a retired task's leftover branch is the operator's, and a WARN keeps it
# visible instead of trading silent deletion for silent accumulation.
PARKED_SLUGS=$(
  for _st in draft archive; do
    [ -d "$BL/$_st" ] || continue
    grep -hE '^- \*\*Worktree\*\*:' "$BL/$_st/"*.md 2>/dev/null \
      | sed -E 's/.*Worktree\*\*:[[:space:]]*//; s/[[:space:]]+$//; s/^[[:space:]]+//'
  done | grep -vxE '(none)?' | sort -u
)
if [ -d "$REPO_ROOT/$ACFW_WORKTREE_DIR" ]; then
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    slug=$(basename "$wt")
    actual=$(git -C "$wt" branch --show-current 2>/dev/null || true)
    # OWNERSHIP GUARD: acf-whip only manages worktrees on its OWN branch namespace
    # (<prefix>/<slug>). A dir under $ACFW_WORKTREE_DIR that is on a foreign branch, detached
    # (e.g. mid-rebase), or not a registered worktree at all belongs to the user's own parallel
    # work — leave it completely alone (no FATAL, no removal). This is what keeps /go's startup
    # doctor --fix from reaping unrelated research/benchmark worktrees parked in the same dir.
    case "$actual" in
      "$ACFW_BRANCH_PREFIX"/*) ;;   # acf-whip-owned — proceed to checks below
      *) continue ;;                # foreign / detached / plain dir — not ours
    esac
    [ "$actual" != "$ACFW_BRANCH_PREFIX/$slug" ] && emit FATAL worktree-wrong-branch "$slug" "$ACFW_WORKTREE_DIR/$slug is on '$actual', expected '$ACFW_BRANCH_PREFIX/$slug'"
    if ! printf '%s\n' "$LIVE_SLUGS" | grep -qxF "$slug"; then
      if printf '%s\n' "$PARKED_SLUGS" | grep -qxF "$slug"; then
        emit WARN parked-task-worktree "$slug" "$ACFW_WORKTREE_DIR/$slug belongs to a task that is parked (draft) or retired (archive) — NOT removed. Resume it with /whip-move $slug pending, or remove the worktree by hand once you are sure nothing in it is needed"
        continue
      fi
      # NEVER --force a worktree that holds uncommitted work. This reaper is the one place acf-whip can
      # destroy one-of-a-kind deliverables (a `remove --force` discards modified AND untracked files:
      # thousands of cassettes, a findings doc, an .env). A dirty orphan is reported and left for a
      # human; only a clean one is reaped. Not repairable by definition — the judgement is the operator's.
      if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
        emit WARN orphaned-worktree-dirty "$slug" "$ACFW_WORKTREE_DIR/$slug has no live task but holds UNCOMMITTED changes — not auto-removed; inspect (git -C $wt status), salvage, then remove by hand"
      elif [ "$FIX" = "1" ]; then
        git_with_lock_backoff -C "$REPO_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
        git_with_lock_backoff -C "$REPO_ROOT" branch -D "$ACFW_BRANCH_PREFIX/$slug" >/dev/null 2>&1 || true
        emit REPAIRABLE orphaned-worktree "$slug" "removed (no live task on slug; worktree was clean)"
      else
        emit REPAIRABLE orphaned-worktree "$slug" "$ACFW_WORKTREE_DIR/$slug has no pending/in-progress/completed/in-review task"
      fi
    fi
  done < <(find "$REPO_ROOT/$ACFW_WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi

# ---- WARN: stale in-progress (older than timeout) ----
if [ -d "$BL/in-progress" ]; then
  now=$(date -u +%s)
  for f in "$BL/in-progress"/*.md; do
    [ -f "$f" ] || continue
    last=$(grep -oE '\| [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \|' "$f" | tail -1 | tr -d '|' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -z "$last" ] && continue
    then_s=$(date -u -j -f "%Y-%m-%d %H:%M:%S" "$last" +%s 2>/dev/null || date -u -d "$last" +%s 2>/dev/null || echo "")
    [ -z "$then_s" ] && continue
    age_h=$(( (now - then_s) / 3600 ))
    [ "$age_h" -ge "$TIMEOUT_H" ] && emit WARN stale-in-progress "$(basename "$f" .md)" "in-progress for ${age_h}h (>= ${TIMEOUT_H}h timeout)"
  done
fi

# ---- Print findings + summary ----
# --quiet: only the FATAL lines (the gate decision) flow through; the per-finding WARN/REPAIRABLE
# dump (one per historical accepted task on a lived-in backlog) is suppressed. BREAKDOWN + SUMMARY
# below are always emitted, so the grouped advisory counts and ok flag are unchanged.
if [ "$QUIET" -eq 1 ]; then
  grep '^FATAL|' "$FINDINGS" 2>/dev/null || true
else
  sort -t'|' -k1,1 "$FINDINGS" 2>/dev/null || cat "$FINDINGS"
fi
nFATAL=$(grep -c '^FATAL|' "$FINDINGS" 2>/dev/null); nFATAL=${nFATAL:-0}
nREP=$(grep -c '^REPAIRABLE|' "$FINDINGS" 2>/dev/null); nREP=${nREP:-0}
nWARN=$(grep -c '^WARN|' "$FINDINGS" 2>/dev/null); nWARN=${nWARN:-0}
# Grouped breakdown (one line per non-empty severity) so callers can show "N historical
# advisories" instead of dumping every finding. Output-only; never affects ok.
for sev in FATAL REPAIRABLE WARN; do
  grp=$(awk -F'|' -v S="$sev" '$1==S{c[$2]++} END{f=1; for(k in c){ printf "%s%s=%d", (f?"":","), k, c[k]; f=0 }}' "$FINDINGS")
  [ -n "$grp" ] && printf 'BREAKDOWN|%s|%s\n' "$sev" "$grp"
done
ok=true; [ "$nFATAL" -gt 0 ] && ok=false
printf 'SUMMARY|fatal=%d|repairable=%d|warn=%d|ok=%s\n' "$nFATAL" "$nREP" "$nWARN" "$ok"
[ "$ok" = "true" ]
