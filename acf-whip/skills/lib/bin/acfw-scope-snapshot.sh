#!/usr/bin/env bash
# acfw-scope-snapshot.sh — the snapshot POST-STAGE (3.4.0): real --digest and --only, once, for every
# backend that does not implement them itself.
#
# WHY THIS EXISTS
# ---------------
# The snapshot is produced by a script but DELIVERED by an agent: /go's shell-runner reads the store
# walk's stdout with its Bash tool and copies it into one schema string, which the workflow parses.
# That hop is bounded by what a model will reliably echo. The `files` scanner has always kept the
# payload small (it collapses terminal-accepted tasks into counts + a compact satisfiedDeps list), but
# every API adapter says outright that --digest is a hint and emits EVERY card it can see — accepted,
# archived, draft and all. On a lived-in board that is hundreds of full records, and the failure mode
# is not an error: the model silently returns a shortened-but-valid JSON, the scheduler plans over a
# board that does not exist, and a scoped run reports that the ids it was given "do not exist in the
# backlog" when every one of them does.
#
# So: narrow in a SCRIPT, before the payload ever reaches an agent.
#
#   --digest      collapse terminal-accepted tasks the same three ways the files scanner does
#   --only K...   emit only the closure of the named tasks (seeds + their unmet dependencies)
#
# and state, in the output, exactly what was emitted, so the consumer can prove it received all of it.
#
# WHERE IT RUNS
# -------------
# Inside `acfw-store snapshot`, on the RAW-adapter path only: adapter -> enrich -> [tee --full-to] ->
# HERE. Adapters that declare `snapshot-enriched` (today: files) bypass it entirely, because the files
# path must keep working on a machine with no jq and its scanner already implements both flags
# natively. The order matters: --full-to must capture the FULL snapshot, before any collapse, because
# that file is what `doctor --snapshot` reads and the graph invariants are whole-graph properties.
#
# CONTRACT
# --------
# stdin   one enriched BacklogSnapshot JSON object
# stdout  the same object, narrowed/collapsed, with these additive keys:
#           relay        {n, tasks, inactive, sat, bytes}   FIRST key — see "relay" below
#           digest       true when --digest collapsed anything
#           scopeApplied true when --only narrowed the view
#           scope        {seeds, resolved{tok:stem}, unresolved[], ambiguous[], inactiveSeeds[], added[]}
#           scopeCounts  the same counts model, computed over the narrowed view
#         store-wide `counts` is passed through UNTOUCHED in every case.
# exit    0 on success (including "a seed did not resolve" — that is reported in scope, not an error)
#         2 on usage/parse failure
#
# Requires jq (every raw adapter already does).
set -u

MODE=default
DIGEST=0
ONLY=""
REPO_ROOT=""

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --mode)    MODE="${2:-default}"; shift 2 ;;
    --mode=*)  MODE="${1#--mode=}"; shift ;;
    --digest)  DIGEST=1; shift ;;
    --only)    [ $# -ge 2 ] || { echo "FATAL: --only requires a value" >&2; exit 2; }
               ONLY="${ONLY}${ONLY:+,}$2"; shift 2 ;;
    --only=*)  ONLY="${ONLY}${ONLY:+,}${1#--only=}"; shift ;;
    *)         REPO_ROOT="${REPO_ROOT:-$1}"; shift ;;
  esac
done
[ "$MODE" = "override" ] || MODE=default

command -v jq >/dev/null 2>&1 || { echo "FATAL: acfw-scope-snapshot.sh requires jq" >&2; exit 2; }

IN=$(cat)
[ -n "$IN" ] || { echo "FATAL: acfw-scope-snapshot.sh read an empty snapshot on stdin" >&2; exit 2; }

printf '%s' "$IN" | jq -c --arg mode "$MODE" --arg only "$ONLY" --argjson wantDigest "$DIGEST" '

  # ---- terminal-accepted, per mode. Mirrors isTerminal() in whip-go.workflow.js exactly. A drift
  # here is a silent scheduling bug: a task this calls terminal is collapsed into satisfiedDeps, where
  # the scheduler synthesizes it as accepted+integrated and dispatches everything behind it.
  def isCode: ((.slug // "") != "" and (.slug // "") != "none");
  def acceptedTerminal:
    (.folder // "") == "accepted"
    and ( $mode == "override"
          or (.hasIntegratedAt // false)
          or (isCode | not)
          or ((.hasWorktreeBranch // false) | not) );

  . as $snap
  | ($snap.tasks // []) as $tasks
  | ($snap.inactive // []) as $inactive
  | ($snap.satisfiedDeps // []) as $sat

  # ---- dependency-token resolution over the WHOLE board (never the narrowed view).
  # Order mirrors indexTasks.resolve: exact id, exact stem, exact backendId, then UNIQUE stem prefix.
  # "Unique" is the difference that matters at scale: the scheduler resolves a prefix by first match
  # over map order, which on a large board silently picks whichever of `feature-231-*` was listed
  # first. Here an ambiguous prefix is REPORTED, never guessed.
  | ($tasks + $inactive) as $all
  | ( reduce $all[] as $t ({}; .[$t.stem // ""] = $t.stem) ) as $byStem
  | ( reduce $all[] as $t ({}; if ($t.id // "") != "" then .[$t.id] = $t.stem else . end) ) as $byId
  | ( reduce $all[] as $t ({}; if ($t.backendId // "") != "" then .[$t.backendId] = $t.stem else . end) ) as $byBackend
  | ( reduce $sat[] as $e ({}; .[$e.stem // ""] = ($e.stem // $e.id)) ) as $satByStem
  | ( reduce $sat[] as $e ({}; if ($e.id // "") != "" then .[$e.id] = ($e.stem // $e.id) else . end) ) as $satById

  | def resolveTok($tok):
      if   ($byId[$tok] // null)      != null then {stem: $byId[$tok]}
      elif ($byStem[$tok] // null)    != null then {stem: $byStem[$tok]}
      elif ($byBackend[$tok] // null) != null then {stem: $byBackend[$tok]}
      elif ($satById[$tok] // null)   != null then {stem: $satById[$tok], terminal: true}
      elif ($satByStem[$tok] // null) != null then {stem: $satByStem[$tok], terminal: true}
      else
        ( [ ($byStem | keys_unsorted[]) | select(startswith($tok)) ] ) as $c
        | if   ($c | length) == 1 then {stem: $c[0]}
          elif ($c | length) > 1  then {ambiguous: $c}
          else
            ( [ ($satByStem | keys_unsorted[]) | select(startswith($tok)) ] ) as $sc
            | if ($sc | length) == 1 then {stem: $sc[0], terminal: true}
              elif ($sc | length) > 1 then {ambiguous: $sc}
              else null end
          end
      end;

  # ---- the active scheduling vocabulary. A card outside it cannot be dispatched by anyone.
  ( reduce $tasks[] as $t ({}; .[$t.stem // ""] = true) ) as $schedulable
  | ( reduce $all[] as $t ({}; .[$t.stem // ""] = $t) ) as $objByStem

  | ( ($only | if . == "" then [] else (split(",") | map(select(. != ""))) end) ) as $seeds

  # ---- seed classification
  | ( reduce $seeds[] as $tok (
        {resolved: {}, unresolved: [], ambiguous: [], inactiveSeeds: [], start: []};
        (resolveTok($tok)) as $r
        | if $r == null then .unresolved += [$tok]
          elif ($r.ambiguous // null) != null then .ambiguous += [{tok: $tok, candidates: $r.ambiguous}]
          else
            ( $objByStem[$r.stem] // null ) as $obj
            # A terminal seed is exempt from the actionability test: scoping to finished work is legal
            # and simply contributes nothing to either side of the completion count.
            | if ($r.terminal // false) or (($obj != null) and ($obj | acceptedTerminal))
              then .resolved += {($tok): $r.stem}
              elif ($schedulable[$r.stem] // false)
              then (.resolved += {($tok): $r.stem}) | (.start += [$r.stem])
              else .inactiveSeeds += [{stem: $r.stem, folder: (($obj.folder // "") )}]
              end
          end
      ) ) as $seedInfo

  # ---- transitive closure. Pull in every dependency that is not ACCEPTED-terminal — blocked and
  # rejected deps included, because they are RETRYABLE: the unblock/retry passes run over the scope,
  # so a dep left outside it can never be lifted and its dependent can never dispatch.
  | ( if ($seeds | length) == 0 then null
      else
        { scope: {}, added: [], stack: $seedInfo.start }
        | until( (.stack | length) == 0;
            .stack[-1] as $s
            | .stack |= .[0:-1]
            | if (.scope[$s] // false) then .
              else
                .scope += {($s): true}
                | ( ($objByStem[$s].deps // []) ) as $deps
                | reduce $deps[] as $d (.;
                    (resolveTok($d)) as $dr
                    | if ($dr == null) or (($dr.ambiguous // null) != null) then .
                      else
                        ( $objByStem[$dr.stem] // null ) as $dobj
                        | if (.scope[$dr.stem] // false) then .
                          elif ($dr.terminal // false) then .
                          elif ($dobj != null) and ($dobj | acceptedTerminal) then .
                          else (.added += [$dr.stem]) | (.stack += [$dr.stem])
                          end
                      end)
              end)
      end ) as $closure

  # ---- apply the scope to the emitted arrays. The store-wide counts are NOT touched.
  | ( if $closure == null then $tasks    else [ $tasks[]    | select($closure.scope[.stem] // false) ] end ) as $tasks2
  | ( if $closure == null then $inactive else [ $inactive[] | select($closure.scope[.stem] // false) ] end ) as $inactive2

  # ---- digest: the three-way split. A terminal-accepted task that something still depends on stays
  # as a compact satisfiedDeps entry (dependency resolution must never see a null); one nothing
  # depends on survives only in the aggregate counts; everything else is emitted in full. An
  # accepted task with a live branch and no ledger marker is NOT terminal in default mode — it still
  # has to be integrated — so it stays a full record and the integrator can still find it.
  | ( [ $tasks2[] | select(.deps // [] | length > 0) | .deps[] ] ) as $depToks
  | ( reduce $depToks[] as $d ({}; .[$d] = true) ) as $depSet
  | ( if $wantDigest == 1
      then
        [ $tasks2[] | select( (. | acceptedTerminal) | not ) ] as $keep
        | [ $tasks2[]
            | select(. | acceptedTerminal)
            | select( ($depSet[.stem] // false) or ($depSet[.id // ""] // false) )
            | {stem: .stem, id: (.id // ""), backendId: (.backendId // "")} ] as $collapsed
        | {tasks: $keep, sat: ($sat + $collapsed), didCollapse: (($tasks2 | length) != ($keep | length))}
      else {tasks: $tasks2, sat: $sat, didCollapse: false}
      end ) as $dg

  | $dg.tasks as $outTasks
  | $dg.sat   as $outSat

  # ---- scoped counts (the narrowed view), alongside the untouched store-wide counts.
  | def cnt($st): [ $outTasks[] | select((.folder // "") == $st) ] | length;
    { "pending": cnt("pending"), "in-progress": cnt("in-progress"), "completed": cnt("completed"),
      "in-review": cnt("in-review"), "blocked": cnt("blocked"), "rejected": cnt("rejected"),
      "accepted": cnt("accepted"),
      "total": ($outTasks | length) } as $scopeCounts

  # ---- relay header. See relayCheck() in whip-go.workflow.js for what it does and does not prove.
  | ( ($outTasks | length) + ($inactive2 | length) + ($outSat | length) ) as $rn
  | ( [ ($outTasks[], $inactive2[], $outSat[]) | (.stem // "") | utf8bytelength ] | add // 0 ) as $rbytes

  | ( $snap
      + { tasks: $outTasks, inactive: $inactive2, satisfiedDeps: $outSat }
      + (if $dg.didCollapse then {digest: true} else {} end)
      + (if $closure == null then {} else {
          scopeApplied: true,
          scopeCounts: $scopeCounts,
          scope: {
            seeds: $seeds,
            resolved: $seedInfo.resolved,
            unresolved: $seedInfo.unresolved,
            ambiguous: $seedInfo.ambiguous,
            inactiveSeeds: $seedInfo.inactiveSeeds,
            added: ($closure.added | unique)
          }
        } end)
    ) as $out

  # relay FIRST, so a tail-elided echo still carries the expectation it fails.
  | {relay: {n: $rn, tasks: ($outTasks|length), inactive: ($inactive2|length), sat: ($outSat|length), bytes: $rbytes}} + $out
'
