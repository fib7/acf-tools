#!/usr/bin/env bash
# acfw-doctor-generic.sh — the store-agnostic half of the doctor battery.
#
# Usage: <ENRICHED BacklogSnapshot JSON on stdin> | acfw-doctor-generic.sh <repo-root>
#
# For non-files backends the store-native invariants (status drift, metadata integrity)
# live in the adapter's own `doctor`; everything a snapshot can prove lives HERE, with
# the same finding codes and severities as doctor.sh so operators read one vocabulary:
#   graph    : duplicate-id (WARN), dangling-dep, cyclic-deps,
#              cross-slug-dep-not-integrated (FATAL), cross-slug-glob-overlap (WARN)
#   per task : unknown-agent, rejection/block-count-out-of-range (WARN — report-only
#              here; fixes are the adapter's), missing-clean-checkout-token,
#              lingering-in-review, stale-in-progress, accepted-branchless-unverified
#   git side : detached-head, dirty-trunk-root, trunk-unpushed,
#              worktree-wrong-branch (FATAL), orphaned-worktree (report-only: this
#              script NEVER mutates — reaping stays with doctor.sh/--fix on files)
# Emits SEV|code|task|detail lines + SUMMARY|; exit 0 iff no FATAL. The dispatcher
# merges these lines with the adapter's own findings and recomputes the summary.
#
# NOT here: `collapsed-task-file` (and `control-bytes`) are FILES-ONLY. Both read raw file
# bytes and this script consumes a snapshot, so it cannot run their discriminators. On a
# non-files backend the equivalent protection is write-time, not scan-time: append_log_row
# refuses an empty/blank read, so an adapter can no longer replace a stored document with a
# lone log row (see acfw-store-multica's log-event guard).
#
# Requires jq (only runs behind non-files adapters, which already require it).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$(cd "$SCRIPT_DIR/.." && pwd)/acfw-git.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: acfw-doctor-generic.sh requires jq" >&2; exit 5; }

REPO_ROOT="${1:-${ACFW_TRUNK_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}}"
[ -n "$REPO_ROOT" ] || { echo "FATAL: repo root unknown" >&2; exit 2; }
# Integration mode, resolved BEFORE acfw_load_namespace (which sources the config and would clobber an
# inherited ACFW_INTEGRATION_MODE, inverting env > config). The dispatcher exports it, so this is
# normally just a read-back. Mirrors doctor.sh: "" and "default" behave alike, only "override" relaxes.
MODE=$(acfw_resolve_integration_mode "$REPO_ROOT") || exit 2
acfw_load_namespace "$REPO_ROOT"

SNAP=$(cat)
[ -n "$SNAP" ] || { echo "FATAL: empty snapshot on stdin" >&2; exit 2; }

FINDINGS=$(mktemp "${TMPDIR:-/tmp}/acfw-docgen.XXXXXX")
TSV=$(mktemp "${TMPDIR:-/tmp}/acfw-docgen-tsv.XXXXXX")
trap 'rm -f "$FINDINGS" "$TSV"' EXIT
emit() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$FINDINGS"; }

TIMEOUT_H=$(printf '%s' "$SNAP" | jq -r '.inProgressTimeoutHours // 8')

# ---- git-side checks (identical semantics to doctor.sh:151-172) ----
if ! git -C "$REPO_ROOT" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
  emit FATAL detached-head "(repo)" "HEAD is detached at $REPO_ROOT; /go requires a branch checked out at the repo root"
fi
ndirty=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | awk 'substr($0,1,2)!="??" && substr($0,4,9)!=".backlog/"{n++} END{print n+0}')
[ "${ndirty:-0}" -gt 0 ] && emit WARN dirty-trunk-root "(repo)" "$ndirty tracked file(s) modified/staged at the trunk root — a specialist may have escaped its worktree; commit or stash before the next integration resyncs the root"
HEAD_BR=$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || true)
if [ -n "$HEAD_BR" ] && git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$HEAD_BR" >/dev/null 2>&1; then
  nahead=$(git -C "$REPO_ROOT" rev-list --count "refs/remotes/origin/$HEAD_BR..HEAD" 2>/dev/null || echo 0)
  [ "${nahead:-0}" -gt 0 ] && emit WARN trunk-unpushed "(repo)" "local $HEAD_BR is $nahead commit(s) ahead of origin/$HEAD_BR — acf-whip never pushes; push when ready"
fi

# Does this backend answer hasCleanCheckoutToken in every state? The dispatcher resolves it from the
# adapter's capabilities and injects it. Absent (a snapshot not produced by the dispatcher) => assume
# yes, which is the files behaviour and keeps the standalone path unchanged.
TOKEN_ALL_STATES=$(printf '%s' "$SNAP" | jq -r 'if has("tokenAllStates") then (.tokenAllStates | tostring) else "true" end' 2>/dev/null)
[ -n "$TOKEN_ALL_STATES" ] || TOKEN_ALL_STATES=true

# ---- per-task checks from the snapshot ----
# One jq pass emits pipe-joined records; bash turns them into findings. The severity tier below is
# kept textually identical to doctor.sh — the two batteries must agree on what gates a run.
while IFS='|' read -r stem folder id status agent rc bc hasTok isCode hasBranch hasInteg age; do
  [ -n "$stem" ] || continue
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
    emit "$sev_struct" unparseable-frontmatter "$stem" "missing ID and/or Status field"
  fi
  if [ -n "$agent" ] && [ "$agent" != "none" ] && [ ! -f "$REPO_ROOT/.claude/agents/$agent.md" ]; then
    emit "$sev_struct" unknown-agent "$stem" "Assigned Agent '$agent' has no .claude/agents/$agent.md — create it or run /whip-add-agents, or reassign the task"
  fi
  if [ "$rc" -lt 0 ] 2>/dev/null || [ "$rc" -gt 5 ] 2>/dev/null; then
    emit WARN rejection-count-out-of-range "$stem" "Rejection Count $rc out of [0,5] (repair via the adapter's doctor --fix)"
  fi
  if [ "$bc" -lt 0 ] 2>/dev/null || [ "$bc" -gt 9 ] 2>/dev/null; then
    emit WARN block-count-out-of-range "$stem" "Block-Count $bc out of [0,9] (repair via the adapter's doctor --fix)"
  fi
  # Only meaningful when the adapter actually answers this field for accepted tasks. Where the answer
  # costs a request, adapters bound the paid set to the review states; `false` on an accepted task
  # then means "not scanned", and warning on it puts a permanent false advisory on every finished task.
  [ "$TOKEN_ALL_STATES" = "true" ] && [ "$folder" = "accepted" ] && [ "$hasTok" = "false" ] \
    && emit WARN missing-clean-checkout-token "$stem" "accepted without a 'clean-checkout | ok' token"
  [ "$folder" = "in-review" ] && emit WARN lingering-in-review "$stem" "stuck in in-review (quality-reviewer must terminate it)"
  if [ "$folder" = "in-progress" ] && [ "$age" -ge "$TIMEOUT_H" ] 2>/dev/null; then
    emit WARN stale-in-progress "$stem" "in-progress for ${age}h (>= ${TIMEOUT_H}h timeout)"
  fi
  if [ "$folder" = "accepted" ] && [ "$isCode" = "true" ] && [ "$hasBranch" = "false" ] && [ "$hasInteg" = "false" ]; then
    emit WARN accepted-branchless-unverified "$stem" "accepted, but no worktree branch and no ledger marker on trunk — verify the deliverable landed, then ack: whip-move $stem accepted --integrated-at <sha>"
  fi
# `slim: true` marks a DEPENDENCY-RESOLUTION STUB, not a task record: the files scanner emits terminal
# accepted tasks that way, carrying only the fields depsSatisfied reads and dropping the rest to keep a
# lived-in backlog's payload small. Checking per-task invariants against one reports every dropped
# field as absent — a slim accepted task would draw a standing missing-clean-checkout-token WARN for a
# token it has. They stay in the GRAPH pass below (that is what they exist for); they are skipped here.
done < <(printf '%s' "$SNAP" | jq -r '.tasks[]? | select((.slim // false) | not) |
  [.stem, .folder, (.id // ""), (.status // ""), (.agent // ""),
   (.rejectionCount // 0 | tostring), (.blockCount // 0 | tostring),
   (.hasCleanCheckoutToken // false | tostring), (.isCodeMutating // false | tostring),
   (.hasWorktreeBranch // false | tostring), (.hasIntegratedAt // false | tostring),
   (.ageHours // -1 | tostring)] | join("|")')

# ---- cross-task graph in awk — the SAME program as doctor.sh:333-381, fed the same
# 11-column TSV, so scheduler/doctor dep semantics can never fork between backends.
# integGate (col 8) folds the ledger oracle in, exactly like doctor.sh:311-312.
# inactive[] (draft/archive) is appended so resolve() can SEE those stems. They are registered as
# resolvable and nothing else: never pending, never a glob contender, never a cycle participant.
# Without them a task depending on a draft reports FATAL|dangling-dep — "this dep does not exist" —
# when the dep exists and is simply still behind the human gate. Different problem, different remedy.
printf '%s' "$SNAP" | jq -r '(.tasks[]? , .inactive[]?) |
  [.stem, .folder, (.id // ""), (.status // ""), (.slug // ""), (.agent // ""),
   ((.deps // []) | if length == 0 then "none" else join(",") end),
   (if (.hasIntegratedAt // false) then "ledger" else (.integratedAt // "") end),
   ((.touchesGlobs // []) | join(",")),
   (.rejectionCount // 0 | tostring),
   (if (.hasWorktreeBranch // false) then "1" else "0" end)] | @tsv' > "$TSV"

awk -F'\t' -v mode="$MODE" '
# Memoised. A dep token is resolved once per DEPENDENT, so a token shared by many tasks rescanned the
# whole stem table every time. The cache stores misses too ("" is a real answer), which is why the
# presence test is on rcache and not on its value.
function resolve(d,   s){
  if(d in rcache) return rcache[d]
  if(d in stems){ rcache[d]=d; return d }
  for(s in stems){ if(index(s,d)==1){ rcache[d]=s; return s } }
  rcache[d]=""; return ""
}
{
  stem=$1; folder=$2; id=$3; slug=$5; deps=$7; integ=$8; globs=$9; hasBranch=$11;
  stems[stem]=1; state[stem]=folder; slugOf[stem]=slug; integOf[stem]=integ; depsOf[stem]=deps; globsOf[stem]=globs; hasBranchOf[stem]=hasBranch;
  if(id!=""){ idcount[id]++ }
  if(folder=="pending"){ pend[stem]=1 }
  if(folder=="draft" || folder=="archive"){ inert[stem]=1 }
}
END{
  for(i in idcount) if(idcount[i]>1) print "WARN|duplicate-id|" i "|ID appears on " idcount[i] " tasks (quarantine: de-dup; run continues)";

  for(s in stems){
    n=split(depsOf[s], da, ",");
    for(k=1;k<=n;k++){ d=da[k]; gsub(/[ \t]/,"",d);
      if(d=="" || d=="none") continue;
      r=resolve(d);
      if(r==""){ sev=(state[s]=="accepted")?"WARN":"FATAL"; print sev "|dangling-dep|" s "|depends on " d " which has no task"; continue }
      # The dep EXISTS but is behind the human gate / retired. The scheduler already refuses to
      # dispatch (isTerminal is false for both), so this is not a gate FATAL — it is the reason a task
      # will sit in pending forever, which an operator otherwise has to work out from silence.
      if(r in inert && !(s in inert)){ print "WARN|dep-inactive|" s "|depends on " r ", which is in " state[r] " — it will never be dispatched until that task is moved to pending"; continue }
      adj[s]=adj[s]" "r; indeg[r]++;
      # mode!="override": in override mode the operator integrates, so no marker is ever written and
      # accepted-but-unintegrated is the normal end state of every task. The scheduler already relaxes
      # this same gate there and dispatches the dependent, so firing here would abort the run on a
      # disagreement rather than a defect. Mirrors doctor.sh — one vocabulary, one oracle.
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

# ---- worktree registry checks (report-only: mutation is never generic) ----
# In override mode an accepted task's worktree branch is the operator's only copy of the deliverable
# (nothing landed, nothing was pushed), so it is live, not orphaned. This script never reaps, so the
# stake here is only a spurious WARN — but it must read the same as doctor.sh, which does reap.
LIVE_SLUGS=$(printf '%s' "$SNAP" | jq -r --arg mode "$MODE" '.tasks[]? |
  select(.folder=="pending" or .folder=="in-progress" or .folder=="completed" or .folder=="in-review"
         or ($mode=="override" and .folder=="accepted")) | .slug // ""' | sort -u)
if [ -d "$REPO_ROOT/$ACFW_WORKTREE_DIR" ]; then
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    slug=$(basename "$wt")
    actual=$(git -C "$wt" branch --show-current 2>/dev/null || true)
    case "$actual" in
      "$ACFW_BRANCH_PREFIX"/*) ;;   # acf-whip-owned — proceed
      *) continue ;;                # foreign / detached — not ours (ownership guard)
    esac
    [ "$actual" != "$ACFW_BRANCH_PREFIX/$slug" ] && emit FATAL worktree-wrong-branch "$slug" "$ACFW_WORKTREE_DIR/$slug is on '$actual', expected '$ACFW_BRANCH_PREFIX/$slug'"
    if ! printf '%s\n' "$LIVE_SLUGS" | grep -qx "$slug"; then
      if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
        emit WARN orphaned-worktree-dirty "$slug" "$ACFW_WORKTREE_DIR/$slug has no live task but holds UNCOMMITTED changes — inspect, salvage, remove by hand"
      else
        emit WARN orphaned-worktree "$slug" "$ACFW_WORKTREE_DIR/$slug has no pending/in-progress/completed/in-review task (remove: git worktree remove $ACFW_WORKTREE_DIR/$slug)"
      fi
    fi
  done < <(find "$REPO_ROOT/$ACFW_WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi

# ---- findings + summary (dispatcher re-merges; SUMMARY here serves standalone use) ----
sort -t'|' -k1,1 "$FINDINGS" 2>/dev/null || cat "$FINDINGS"
nFATAL=$(grep -c '^FATAL|' "$FINDINGS" 2>/dev/null); nFATAL=${nFATAL:-0}
nREP=$(grep -c '^REPAIRABLE|' "$FINDINGS" 2>/dev/null); nREP=${nREP:-0}
nWARN=$(grep -c '^WARN|' "$FINDINGS" 2>/dev/null); nWARN=${nWARN:-0}
ok=true; [ "$nFATAL" -gt 0 ] && ok=false
printf 'SUMMARY|fatal=%d|repairable=%d|warn=%d|ok=%s\n' "$nFATAL" "$nREP" "$nWARN" "$ok"
[ "$ok" = "true" ]
