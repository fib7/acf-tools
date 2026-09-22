#!/usr/bin/env bash
# phase10-validate-child.test.sh — the child-workflow TOOLING: the pre-flight validator and the ledger.
#
# Every check here is a throw class that would otherwise cost a whole child execution to discover —
# and several (a forbidden global on a branch that never runs, a dropped stage key, an unkeyed loop)
# would not be caught by executing the harness at all.
#
# Two regressions are pinned deliberately, because both were live bugs during development and both
# fail in the SILENT direction:
#   * `node --check` false-positives on every valid harness (the runtime compiles the body inside an
#     async function, so top-level await/return are legal). A validator that used it would reject
#     100% of correct harnesses.
#   * A blind grep for Date.now rejects a prompt that merely TELLS an agent to shell out to `date`.
#     The offset-preserving lexer exists for this; a fixed-string grep running alongside it would
#     veto the precise check and defeat it entirely.
#
# Run: bash acf-whip/tests/phase10-validate-child.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAFFOLD="$ACF_WHIP/skills/lib/bin/acfw-child-scaffold"
VALIDATE="$ACF_WHIP/skills/lib/bin/acfw-child-validate"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p10v.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REG="go-engineer,quality-reviewer"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable (test harness only)"; exit 0; }

# ---- build a realistically FILLED harness (what an architect actually produces) ----
build() { # <out> <kind>
  bash "$SCAFFOLD" "$1" --kind "$2" --stem s1 --meta-name "whip-$2-s1" --gate "make test" >/dev/null || return 1
  python3 - "$1" "$2" <<'PY'
import sys
p, kind = sys.argv[1], sys.argv[2]
s = open(p).read()
s = s.replace("  // <acfw-meta>\n  // </acfw-meta>",
  "  // <acfw-meta>\n  name: 'whip-%s-s1',\n  description: 'harness for s1',\n  phases: [{ title: 'Stages', detail: 'x' }],\n  // </acfw-meta>" % kind)
plan = {
 'impl': """const PLANNED = [
  { key: 'implement', label: 'i', agentType: 'go-engineer', producesCommit: true, mutates: true, maxAgents: 1 },
  { key: 'gate', label: 'g', agentType: '', producesCommit: false, mutates: true, maxAgents: 2 },
  { key: 'gate-fix', label: 'f', agentType: 'go-engineer', producesCommit: true, mutates: true, maxAgents: 2 },
  { key: 'adversarial', label: 'r', agentType: 'quality-reviewer', producesCommit: false, mutates: false, maxAgents: 1 },
  { key: 'adversarial-fix', label: 'f2', agentType: 'go-engineer', producesCommit: true, mutates: true, maxAgents: 1 },
]""",
}.get(kind, "const PLANNED = []")
s = s.replace("// <acfw-plan>\n// </acfw-plan>",
  "// <acfw-plan>\n%s\nconst SHALLOW = 'default shape fits'\n// </acfw-plan>" % plan)
open(p, 'w').write(s)
PY
}

verdict() { # <file> <kind> [require-stages] -> prints "ok" or "rejected:<first error>"
  bash "$VALIDATE" "$1" /r --kind "$2" --registry "$REG" --budget 8 --stem s1 --require-stages "${3:-}" \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("ok" if d["ok"] else "rejected:" + (d["errors"][0] if d["errors"] else "?"))'
}

# mutate <old> <new> -> a plain string replace into $WORK/n.js.
# OLD/NEW travel as argv, never as embedded Python source: these fixtures are full of quotes and
# backslashes, and inlining them into `python3 -c` silently produced a SyntaxError whose only visible
# effect was the previous (unmutated) fixture being re-validated — a test that passes by accident.
mutate() {
  python3 - "$WORK/h.js" "$WORK/n.js" "$1" "$2" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if old not in s:
    sys.stderr.write("FIXTURE-MISS: %r not found in the scaffolded harness\n" % old[:70])
    sys.exit(3)
open(dst, 'w').write(s.replace(old, new, 1))
PY
}

want_reject() { # <label> <code-prefix> <old> <new>
  if ! mutate "$3" "$4"; then bad "$1: fixture did not apply"; return; fi
  local v; v=$(verdict "$WORK/n.js" impl)
  case "$v" in
    rejected:$2*) ok "$1 -> $2" ;;
    ok)           bad "$1: ACCEPTED but must be rejected by $2" ;;
    *)            bad "$1: rejected by the WRONG check: ${v:0:90}" ;;
  esac
}

want_accept() { # <label> <old> <new>
  if ! mutate "$2" "$3"; then bad "$1: fixture did not apply"; return; fi
  local v; v=$(verdict "$WORK/n.js" impl)
  if [ "$v" = "ok" ]; then ok "$1"; else bad "$1: ${v:0:120}"; fi
}

BODY='// <acfw-body>'

build "$WORK/h.js" impl || { echo "FATAL: scaffold failed"; exit 1; }

echo "== the pristine filled harness validates clean =="
v=$(verdict "$WORK/h.js" impl)
[ "$v" = "ok" ] && ok "pristine harness accepted" || bad "pristine harness rejected: ${v:0:140}"

echo "== V-SKEL: the locked skeleton is immutable =="
cp "$WORK/h.js" "$WORK/n.js"
python3 -c "
s=open('$WORK/n.js').read()
s=s.replace('const FAILED = { __failed: true }', 'const FAILED = { __failed: false }')
open('$WORK/n.js','w').write(s)"
case "$(verdict "$WORK/n.js" impl)" in
  rejected:V-SKEL*) ok "a one-token edit in a locked segment is caught" ;;
  *) bad "locked-segment tampering was NOT caught" ;;
esac
# Trailing whitespace at END OF LINE must NOT be tampering (editors add and strip it constantly).
# Note the target: a locked line with NOTHING after it. Padding before a trailing comment is INTERIOR
# whitespace and is correctly treated as tampering — the normalisation is end-of-line only, by design.
cp "$WORK/h.js" "$WORK/n.js"
python3 -c "
s=open('$WORK/n.js').read()
s=s.replace('const ran = [], replayed = []\n', 'const ran = [], replayed = []   \n')
open('$WORK/n.js','w').write(s)"
[ "$(verdict "$WORK/n.js" impl)" = "ok" ] && ok "END-OF-LINE whitespace on a locked line is NOT tampering" \
  || bad "end-of-line whitespace was wrongly reported as tampering"
# ...but interior whitespace IS a real edit and must be caught.
cp "$WORK/h.js" "$WORK/n.js"
python3 -c "
s=open('$WORK/n.js').read()
s=s.replace('const FAILED = { __failed: true }  ', 'const FAILED = { __failed: true }     ')
open('$WORK/n.js','w').write(s)"
case "$(verdict "$WORK/n.js" impl)" in
  rejected:V-SKEL*) ok "INTERIOR whitespace in a locked line is caught" ;;
  *) bad "interior whitespace in a locked line was not caught" ;;
esac
# A stale contract stamp is distinct from tampering: re-author, do not amend.
cp "$WORK/h.js" "$WORK/n.js"
python3 -c "
s=open('$WORK/n.js').read()
s=s.replace('acfw-child-contract: v2', 'acfw-child-contract: v0')
open('$WORK/n.js','w').write(s)"
case "$(verdict "$WORK/n.js" impl)" in
  rejected:V-CONTRACT*skew*) ok "a stale contract stamp reports skeleton-version-skew" ;;
  *) bad "stale contract stamp not reported as skew" ;;
esac

echo "== V-GLOBALS / V-DIRECT / V-BOUND / V-RETURN =="
want_reject "Date.now() in the body"         V-GLOBALS "$BODY" "$BODY
  const t = Date.now()"
want_reject "Math.random() in the body"      V-GLOBALS "$BODY" "$BODY
  const t = Math.random()"
want_reject "workflow() (nesting violation)" V-GLOBALS "$BODY" "$BODY
  await workflow({ scriptPath: 1 })"
want_reject "require()"                      V-GLOBALS "$BODY" "$BODY
  const f = require('fs')"
want_reject "a bare agent() call"            V-DIRECT  "$BODY" "$BODY
  await agent('x', {})"
want_reject "a bare parallel() call"         V-DIRECT  "$BODY" "$BODY
  await parallel([])"
want_reject "while (true)"                   V-BOUND   "$BODY" "$BODY
  while (true) { break }"
want_reject "a top-level return"             V-RETURN  "$BODY" "$BODY
  return 5"
want_accept "return finish(...) is allowed"            "$BODY" "$BODY
  if (!WT) return finish('none', 'n/a', 'x', 'mechanism')"

echo "== V-WORKTREE: the single-clean-checkout rule is mechanical =="
want_reject "'clean-checkout' named in the body" V-WORKTREE "$BODY" "$BODY
  const c = 'now run clean-checkout'"
want_reject "a .worktree/ path literal"          V-WORKTREE "$BODY" "$BODY
  const p = '.worktree/sl'"
want_reject "isolation: on a spec"               V-WORKTREE "$BODY" "$BODY
  const o = { isolation: 'worktree' }"

echo "== V-META: the meta region must be a pure literal =="
want_reject "interpolation in meta.name" V-META "name: 'whip-impl-s1'," 'name: `whip-impl-${STEM}`,'

echo "== V-AGENTS: agentTypes are literals from the real registry =="
want_reject "an uninstalled agentType" V-AGENTS "agentType: 'quality-reviewer', producesCommit: false" "agentType: 'nope-engineer', producesCommit: false"
want_reject "a COMPUTED agentType"     V-AGENTS "agentType: 'quality-reviewer', prompt:" "agentType: pick(), prompt:"

echo "== V-LOOP: a loop stage without iteration: freezes on a cached result =="
want_reject "gate stage missing iteration:"     V-LOOP "key: 'gate', iteration: i," "key: 'gate',"
want_reject "gate-fix stage missing iteration:" V-LOOP "key: 'gate-fix', iteration: i," "key: 'gate-fix',"

echo "== V-DEREF: a 2-level deref on a stage result throws on __failed =="
want_reject "r.a.b without ?." V-DEREF "if (g.__failed || g.passed) break" "if (g.out.deep) break"

echo "== V-PLAN =="
want_reject "duplicate stage key"        V-PLAN "{ key: 'adversarial', label" "{ key: 'gate', label"
want_reject "maxAgents over the ceiling" V-PLAN "maxAgents: 2 }" "maxAgents: 40 }"
want_reject "a non-kebab stage key"      V-PLAN "key: 'gate-fix', label" "key: 'GateFix', label"

echo "== V-SCHEMA: a malformed schema throws deep in the run, so catch it here =="
want_reject "required names an absent property" V-SCHEMA "required: ['ok', 'summary']" "required: ['ok', 'nope']"
want_reject "schema with no top-level type"     V-SCHEMA "const ST = { type: 'object', additionalProperties: false, required: ['ok', 'summary']," "const ST = { additionalProperties: false, required: ['ok', 'summary'],"

echo "== V-COMPILE and its false-positive guard =="
want_reject "a genuine syntax error" V-COMPILE "$BODY" "$BODY
  const x = ((("
want_accept "LEGAL top-level await (node --check would reject this)" "$BODY" "$BODY
  const z = await Promise.resolve(1)"

echo "== the lexer: prompt prose is not code =="
want_accept "Date.now mentioned inside a PROMPT string" "Do the implementation in" "Report the Date.now equivalent via date -u, then implement in"
want_accept "a regex containing a quote is not an unterminated string" "$BODY" "$BODY
  const q = String(BRANCH).replace(/'/g, '_')"

echo "== V-STAGES: the mechanical half of the durability guarantee =="
v=$(verdict "$WORK/h.js" impl "implement,gate")
[ "$v" = "ok" ] && ok "a harness that KEEPS its completed stages is accepted" || bad "kept stages rejected: ${v:0:120}"
mutate "key: 'implement'," "key: 'implement-v2',"
case "$(verdict "$WORK/n.js" impl "implement")" in
  rejected:V-STAGES*) ok "renaming a COMPLETED stage is rejected before any agent spawns" ;;
  *) bad "a dropped completed stage was not caught — the amend would redo finished work" ;;
esac

echo "== all four kinds scaffold and validate clean =="
for k in impl direct review resolve; do
  build "$WORK/$k.js" "$k" || { bad "$k: scaffold failed"; continue; }
  v=$(verdict "$WORK/$k.js" "$k")
  [ "$v" = "ok" ] && ok "$k harness validates clean" || bad "$k harness rejected: ${v:0:130}"
done

echo "== acfw-child-ledger: the durability primitive =="
LBIN="$ACF_WHIP/skills/lib/bin/acfw-child-ledger"
LD="$WORK/led"; LOCK="$WORK/lockdir/run.json"
printf '{"passed":false,"failingOutput":"boom"}' > "$WORK/r1.json"
printf '{"passed":true,"failingOutput":""}'      > "$WORK/r2.json"
printf 'long form\nnotes\n'                       > "$WORK/p.md"
bash "$LBIN" append "$LD" 'gate#0' --status ok --result-file "$WORK/r1.json" --payload "$WORK/p.md" --heartbeat "$LOCK" >/dev/null
bash "$LBIN" append "$LD" 'gate#1' --status ok --result-file "$WORK/r2.json" >/dev/null
[ -f "$LOCK" ] && ok "a stage completion refreshes the /go run-lock heartbeat" || bad "heartbeat not touched"
[ -f "$LD/payload/gate#0.md" ] && ok "the payload lands before the marker (crash => re-run, never a truncated resume)" || bad "payload missing"
# Last-wins: a re-run of a stage supersedes its earlier entry without rewriting history.
bash "$LBIN" append "$LD" 'gate#0' --status ok --result-file "$WORK/r2.json" >/dev/null
LINES=$(bash "$LBIN" read "$LD" | wc -l | tr -d ' ')
[ "$LINES" = "2" ] && ok "read compacts last-wins (2 stages from 3 appends)" || bad "last-wins compaction wrong: $LINES lines"
bash "$LBIN" read "$LD" | head -1 | grep -q '"passed":true' \
  && ok "the SUPERSEDING result is what replays, not the first one" || bad "compaction returned a stale result"
# The result cap is enforced at WRITE time so round 0 and round N observe an identical value.
python3 -c "open('$WORK/big.json','w').write('{\"a\":\"' + 'x'*2500 + '\"}')"
bash "$LBIN" append "$LD" big --status ok --result-file "$WORK/big.json" >/dev/null 2>&1
[ $? -eq 2 ] && ok "an oversize result is refused (exit 2) with a --payload instruction" || bad "oversize result was accepted"
bash "$LBIN" read "$WORK/no-such-dir" >/dev/null 2>&1
[ $? -eq 0 ] && ok "reading a ledger that does not exist yet is silent success (round 0)" || bad "missing ledger errored"

echo "== the validator never exits non-zero, whatever it finds =="
bash "$VALIDATE" "$WORK/n.js" /r --kind impl --registry "$REG" >/dev/null 2>&1
[ $? -eq 0 ] && ok "exit 0 on a REJECTED harness (the verdict lives in the JSON)" || bad "non-zero exit on rejection"
bash "$VALIDATE" "$WORK/does-not-exist.js" /r --kind impl >/dev/null 2>&1
[ $? -eq 0 ] && ok "exit 0 on a missing file" || bad "non-zero exit on a missing file"

echo
echo "phase10-validate-child: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
