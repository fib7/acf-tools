#!/usr/bin/env bash
# doctor.sh — backlog integrity battery for acf-whip.
#
# Usage:
#   doctor.sh [--fix] [--quiet] [REPO_ROOT]
#     --fix      apply the REPAIRABLE class, then re-scan (default: report only)
#     --quiet    print only FATAL findings + BREAKDOWN + SUMMARY (suppress the per-finding dump);
#                bounds output to O(fatals + codes) so hundreds of historical advisories don't have
#                to flow through the /go scan agent. The interactive /whip-doctor stays verbose.
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
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --fix) FIX=1; shift;;
    --quiet) QUIET=1; shift;;
    *) break;;
  esac
done
REPO_ROOT="${1:-${ACFW_TRUNK_ROOT:-$(git rev-parse --show-toplevel)}}"
BL="$REPO_ROOT/.backlog"
ACTIVE="pending in-progress completed in-review blocked rejected accepted"
# Timeout precedence: env var > .backlog/.acfw-config > default 8h.
ENV_TIMEOUT="${ACFW_INPROGRESS_TIMEOUT_HOURS:-}"
[ -f "$BL/.acfw-config" ] && . "$BL/.acfw-config" 2>/dev/null
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
EXISTING_WT_SLUGS=$(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads/worktree/ 2>/dev/null | sed 's#^worktree/##')
has_branch() { printf '%s\n' "$EXISTING_WT_SLUGS" | grep -qxF "$1"; }

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

# ---- Per-file pass: emit independent findings, apply per-file repairs, build TSV ----
for st in $ACTIVE; do
  d="$BL/$st"; [ -d "$d" ] || continue
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    stem=$(basename "$f" .md); folder="$st"
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

    if [ -n "$integ" ] && [ "$folder" != "accepted" ]; then
      if [ "$FIX" = "1" ]; then
        sed -i.bak -E 's|^(- \*\*Integrated-At\*\*:).*|\1|' "$f" && rm -f "$f.bak"
        commit_fix ".backlog/$folder/$stem.md" "doctor: clear stray Integrated-At on $stem"
        emit REPAIRABLE integrated-at-on-non-accepted "$stem" "cleared (was set in .backlog/$folder/)"
      else
        emit REPAIRABLE integrated-at-on-non-accepted "$stem" "Integrated-At set but task is in .backlog/$folder/ (not accepted)"
      fi
    fi
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
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$stem" "$folder" "$id" "$status" "$slug" "$agent" "${deps:-none}" "$integ" "${globs}" "$rc" "$hasBranch" >> "$TSV"
  done
done

# ---- Cross-task analysis in awk (portable associative arrays) ----
awk -F'\t' '
function resolve(d,   s){ if(d in stems) return d; for(s in stems){ if(index(s,d)==1) return s } return "" }
{
  stem=$1; folder=$2; id=$3; slug=$5; deps=$7; integ=$8; globs=$9; hasBranch=$11;
  stems[stem]=1; state[stem]=folder; slugOf[stem]=slug; integOf[stem]=integ; depsOf[stem]=deps; globsOf[stem]=globs; hasBranchOf[stem]=hasBranch;
  if(id!=""){ idcount[id]++ }
  foldcount[stem]++; foldlist[stem]=foldlist[stem]" "folder;
  if(folder=="pending"){ pend[stem]=1 }
}
END{
  for(i in idcount) if(idcount[i]>1) print "FATAL|duplicate-id|" i "|ID appears in " idcount[i] " task files";
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
      if((state[s]=="in-progress"||state[s]=="completed"||state[s]=="in-review") && slugOf[s]!="" && slugOf[r]!=slugOf[s])
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
LIVE_SLUGS=$(awk -F'\t' '$2=="pending"||$2=="in-progress"||$2=="completed"||$2=="in-review"{print $5}' "$TSV" | sort -u)
if [ -d "$REPO_ROOT/.worktree" ]; then
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    slug=$(basename "$wt")
    actual=$(git -C "$wt" branch --show-current 2>/dev/null || true)
    [ "$actual" != "worktree/$slug" ] && emit FATAL worktree-wrong-branch "$slug" ".worktree/$slug is on '$actual', expected 'worktree/$slug'"
    if ! printf '%s\n' "$LIVE_SLUGS" | grep -qx "$slug"; then
      if [ "$FIX" = "1" ]; then
        git_with_lock_backoff -C "$REPO_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
        git_with_lock_backoff -C "$REPO_ROOT" branch -D "worktree/$slug" >/dev/null 2>&1 || true
        emit REPAIRABLE orphaned-worktree "$slug" "removed (no live task on slug)"
      else
        emit REPAIRABLE orphaned-worktree "$slug" ".worktree/$slug has no pending/in-progress/completed/in-review task"
      fi
    fi
  done < <(find "$REPO_ROOT/.worktree" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
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
