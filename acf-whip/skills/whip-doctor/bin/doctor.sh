#!/usr/bin/env bash
# doctor.sh — backlog integrity battery for acf-whip.
#
# Usage:
#   doctor.sh [--fix] [REPO_ROOT]
#     --fix      apply the REPAIRABLE class, then re-scan (default: report only)
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
if [ "${1:-}" = "--fix" ]; then FIX=1; shift; fi
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
    globs=$(field "$f" "Touches Globs")
    hasTok=0; grep -qE '\| clean-checkout \| ok \|' "$f" && hasTok=1
    agentOk=1; { [ -n "$agent" ] && [ "$agent" != "none" ] && [ ! -f "$REPO_ROOT/.claude/agents/$agent.md" ]; } && agentOk=0

    if [ -z "$id" ] || [ -z "$status" ]; then
      emit FATAL unparseable-frontmatter "$stem" "missing ID and/or Status field"
    else
      [ "$status" != "$folder" ] && emit FATAL status-folder-mismatch "$stem" "Status: '$status' but file is in .backlog/$folder/"
    fi
    [ -z "$slug" ] && emit FATAL missing-worktree-slug "$stem" "code-mutating task has no Worktree: slug (set a slug, or 'none' for research/docs-only)"
    [ "$agentOk" = "0" ] && emit FATAL unknown-agent "$stem" "Assigned Agent '$agent' has no .claude/agents/$agent.md"

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
    [ "$folder" = "accepted" ] && [ "$hasTok" = "0" ] && emit WARN missing-clean-checkout-token "$stem" "accepted without a 'clean-checkout | ok' token"
    [ "$folder" = "in-review" ] && emit WARN lingering-in-review "$stem" "stuck in in-review/ (quality-reviewer must terminate it)"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$stem" "$folder" "$id" "$status" "$slug" "$agent" "${deps:-none}" "$integ" "${globs}" "$rc" >> "$TSV"
  done
done

# ---- Cross-task analysis in awk (portable associative arrays) ----
awk -F'\t' '
function resolve(d,   s){ if(d in stems) return d; for(s in stems){ if(index(s,d)==1) return s } return "" }
{
  stem=$1; folder=$2; id=$3; slug=$5; deps=$7; integ=$8; globs=$9;
  stems[stem]=1; state[stem]=folder; slugOf[stem]=slug; integOf[stem]=integ; depsOf[stem]=deps; globsOf[stem]=globs;
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
      if(r==""){ print "FATAL|dangling-dep|" s "|depends on " d " which has no task file"; continue }
      adj[s]=adj[s]" "r; indeg[r]++;
      if((state[s]=="in-progress"||state[s]=="completed"||state[s]=="in-review") && slugOf[s]!="" && slugOf[r]!=slugOf[s])
        if(state[r]!="accepted" || integOf[r]=="")
          print "FATAL|cross-slug-dep-not-integrated|" s "|dispatched (" state[s] ") but cross-slug dep " r " is not accepted+integrated";
    }
  }
  changed=1;
  while(changed){ changed=0;
    for(s in stems){ if(removed[s]) continue;
      if((s in indeg ? indeg[s] : 0) <= 0){ removed[s]=1; changed=1;
        m=split(adj[s], aa, " "); for(k=1;k<=m;k++){ t=aa[k]; if(t!="") indeg[t]-- } } } }
  for(s in stems) if(!removed[s]) print "FATAL|cyclic-deps|" s "|participates in a dependency cycle";

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
sort -t'|' -k1,1 "$FINDINGS" 2>/dev/null || cat "$FINDINGS"
nFATAL=$(grep -c '^FATAL|' "$FINDINGS" 2>/dev/null); nFATAL=${nFATAL:-0}
nREP=$(grep -c '^REPAIRABLE|' "$FINDINGS" 2>/dev/null); nREP=${nREP:-0}
nWARN=$(grep -c '^WARN|' "$FINDINGS" 2>/dev/null); nWARN=${nWARN:-0}
ok=true; [ "$nFATAL" -gt 0 ] && ok=false
printf 'SUMMARY|fatal=%d|repairable=%d|warn=%d|ok=%s\n' "$nFATAL" "$nREP" "$nWARN" "$ok"
[ "$ok" = "true" ]
