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
# Integration mode: --mode (explicit caller intent) > ACFW_INTEGRATION_MODE env > config key > unpinned.
# Resolved BEFORE acfw_load_namespace because that helper SOURCES the config file, which would
# overwrite an inherited ACFW_INTEGRATION_MODE with the config's own value and silently invert the
# documented env > config precedence. "" and "default" are equivalent here — only "override" relaxes.
MODE=$(acfw_resolve_integration_mode "$REPO_ROOT") || exit 2
[ -n "$MODE_ARG" ] && MODE="$MODE_ARG"
acfw_load_namespace "$REPO_ROOT"   # sets ACFW_WORKTREE_DIR / ACFW_BRANCH_PREFIX (worktree ownership)
ACTIVE="pending in-progress completed in-review blocked rejected accepted"
# Non-accepted active folders: in --active-only mode the full per-file pass runs only over these
# (accepted is fed to the awk graph as a cheap batched stub — see emit_accepted_stub_tsv).
ACTIVE_NONACC="pending in-progress completed in-review blocked rejected"
# Timeout precedence: env var > committed config (.acfwhip/config > .backlog/.acfw-config) > default 8h.
ENV_TIMEOUT="${ACFW_INPROGRESS_TIMEOUT_HOURS:-}"
ACFW_CFG_FILE=$(acfw_resolve_config_file "$REPO_ROOT" || true)
[ -n "$ACFW_CFG_FILE" ] && . "$ACFW_CFG_FILE" 2>/dev/null
TIMEOUT_H="${ENV_TIMEOUT:-${ACFW_INPROGRESS_TIMEOUT_HOURS:-8}}"

FINDINGS=$(mktemp "${TMPDIR:-/tmp}/acfw-doctor.XXXXXX")
TSV=$(mktemp "${TMPDIR:-/tmp}/acfw-doctor-tsv.XXXXXX")
trap 'rm -f "$FINDINGS" "$TSV"' EXIT
emit() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$FINDINGS"; }
field() { grep -E "^- \*\*$2\*\*:" "$1" 2>/dev/null | head -1 | sed -E "s/.*$2\*\*:[[:space:]]*//" | sed -E 's/[[:space:]]+$//'; }
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
  local accf wtf ikf
  accf=$(mktemp "${TMPDIR:-/tmp}/acfw-doctor-acc.XXXXXX")
  wtf=$(mktemp "${TMPDIR:-/tmp}/acfw-doctor-wt.XXXXXX")
  ikf=$(mktemp "${TMPDIR:-/tmp}/acfw-doctor-ik.XXXXXX")
  find "$BL/accepted" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' 2>/dev/null > "$accf"
  printf '%s\n' "$EXISTING_WT_SLUGS" > "$wtf"
  printf '%s\n' "$INTEGRATED_KEYS" > "$ikf"
  grep -HE '^- \*\*(ID|Worktree|Integrated-At)\*\*:' "$BL/accepted/"*.md 2>/dev/null | awk \
    -v accf="$accf" -v wtf="$wtf" -v ikf="$ikf" '
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
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", s, "accepted", i, "accepted", sl, "", "none", ig, "", 0, hb
      }
    }
  '
  rm -f "$accf" "$wtf" "$ikf"
}

# Derive a kebab-case worktree slug from a task id: drop the "<category>-<NNN>-" prefix and keep
# the descriptive tail (already kebab-case); fall back to "<category>-<NNN>" if the tail is empty
# or invalid. A DISTINCT per-task slug is intentional — one worktree branch per task maximizes
# parallel dispatch. Tasks that genuinely share a file surface are surfaced by the separate
# cross-slug-glob-overlap WARN, not silently serialized here.
derive_slug() { # <id>
  local id="$1" tail head
  tail=$(printf '%s' "$id" | sed -E 's/^(feature|bug|infra|test|docs|refactor|data|ml)-[0-9]{1,4}-//')
  if [ "$tail" != "$id" ] && printf '%s' "$tail" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    printf '%s' "$tail"; return
  fi
  head=$(printf '%s' "$id" | sed -E 's/^((feature|bug|infra|test|docs|refactor|data|ml)-[0-9]{1,4}).*/\1/')
  if [ -n "$head" ] && [ "$head" != "$id" ]; then printf '%s' "$head"; else printf '%s' "$id"; fi
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
    nnul=$(LC_ALL=C tr -dc '\000' < "$f" 2>/dev/null | wc -c | tr -d '[:space:]')
    if [ "${nnul:-0}" -gt 0 ]; then
      emit FATAL control-bytes "$stem" "$nnul raw NUL byte(s) (0x00) in the task file — every field lookup is unreliable. Strip: LC_ALL=C tr -d '\\000' < .backlog/$folder/$stem.md > /tmp/t && mv /tmp/t .backlog/$folder/$stem.md"
      continue
    fi

    id=$(field "$f" "ID"); status=$(field "$f" "Status"); slug=$(field "$f" "Worktree" | tr -d '[:space:]')
    deps=$(field "$f" "Dependencies"); integ=$(field "$f" "Integrated-At" | tr -d '[:space:]')
    agent=$(field "$f" "Assigned Agent" | tr -d '[:space:]'); rc=$(field "$f" "Rejection Count" | tr -d '[:space:]')
    bc=$(field "$f" "Block-Count" | tr -d '[:space:]')
    globs=$(field "$f" "Touches Globs")
    hasTok=0; grep -qE '\| clean-checkout \| ok \|' "$f" && hasTok=1
    agentOk=1; { [ -n "$agent" ] && [ "$agent" != "none" ] && [ ! -f "$REPO_ROOT/.claude/agents/$agent.md" ]; } && agentOk=0

    # Severity tier: a task in accepted/ is terminal (out of the dispatch path), so its
    # structural defects are advisory (WARN), never blocking. Active folders keep FATAL.
    sev_struct=FATAL; [ "$folder" = "accepted" ] && sev_struct=WARN

    if [ -z "$id" ] || [ -z "$status" ]; then
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
        derived=$(derive_slug "$id")
        if [ "$FIX" = "1" ]; then
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
function resolve(d,   s){ if(d in stems) return d; for(s in stems){ if(index(s,d)==1) return s } return "" }
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
      r=resolve(d);
      if(r==""){ sev=(state[s]=="accepted")?"WARN":"FATAL"; print sev "|dangling-dep|" s "|depends on " d " which has no task file"; continue }
      adj[s]=adj[s]" "r; indeg[r]++;
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
  changed=1;
  while(changed){ changed=0;
    for(s in stems){ if(removed[s]) continue;
      if((s in indeg ? indeg[s] : 0) <= 0){ removed[s]=1; changed=1;
        m=split(adj[s], aa, " "); for(k=1;k<=m;k++){ t=aa[k]; if(t!="") indeg[t]-- } } } }
  for(s in stems) if(!removed[s]){ sev=(state[s]=="accepted")?"WARN":"FATAL"; print sev "|cyclic-deps|" s "|participates in a dependency cycle"; }

  np=0; for(s in pend){ np++; parr[np]=s }
  for(a=1;a<=np;a++) for(b=a+1;b<=np;b++){ sa=parr[a]; sb=parr[b];
    if(slugOf[sa]==slugOf[sb]) continue;
    if(globsOf[sa]==""||globsOf[sb]=="") continue;
    na=split(globsOf[sa],ga,","); done=0;
    for(k=1;k<=na && !done;k++){ g=ga[k]; gsub(/[ \t]/,"",g); if(g=="") continue;
      nb=split(globsOf[sb],gb,","); for(j=1;j<=nb;j++){ h=gb[j]; gsub(/[ \t]/,"",h);
        if(g==h){ print "WARN|cross-slug-glob-overlap|" sa "|shares glob " g " with " sb " in a different slug (possible mis-partition)"; done=1; break } } }
  }
}' "$TSV" >> "$FINDINGS"

# ---- dup-folder repair (after awk reported) ----
if [ "$FIX" = "1" ]; then
  grep '^REPAIRABLE|dup-folder|' "$FINDINGS" | while IFS='|' read -r _sev _code stem _detail; do
    rep="$BL/$(echo "$_detail" | sed -E 's/.*folders://' | awk '{print $1}')/$stem.md"
    keep=$(field "$rep" "Status")
    for fol in $ACTIVE; do
      [ "$fol" = "$keep" ] && continue
      [ -f "$BL/$fol/$stem.md" ] && { git_with_lock_backoff -C "$REPO_ROOT" rm -q -- ".backlog/$fol/$stem.md" >/dev/null 2>&1 || rm -f "$BL/$fol/$stem.md"; }
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
LIVE_SLUGS=$(awk -F'\t' -v mode="$MODE" '$2=="pending"||$2=="in-progress"||$2=="completed"||$2=="in-review"||(mode=="override"&&$2=="accepted"){print $5}' "$TSV" | sort -u)
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
    if ! printf '%s\n' "$LIVE_SLUGS" | grep -qx "$slug"; then
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
