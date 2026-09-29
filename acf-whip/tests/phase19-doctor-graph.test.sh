#!/usr/bin/env bash
# phase19-doctor-graph.test.sh — cycle detection and worktree liveness, in BOTH doctor batteries (3.4.0).
#
# Two findings, both of which used to be wrong in the direction that costs work:
#
#   1. cyclic-deps reported every task a cycle could REACH, not the cycle. The detector peeled nodes
#      with no dependents and reported whatever survived, so on a->{b,c}, b->a it named a, b AND c —
#      c being an innocent dependency of a cycle member. That was already misleading; once a
#      task-level FATAL holds ONE card out of the run instead of aborting it, it also holds healthy
#      cards out. Only members of a non-trivial SCC (or a self-loop) are in a cycle.
#
#   2. The orphan reaper treated every ACCEPTED slug as spent in default mode. An accepted task whose
#      change has not landed — the drain leaves an exit-7 conflict "for the next /go run"; a crash
#      between accept and integrate leaves the same state — had its worktree removed and its branch
#      -D'd by the next bootstrap `doctor --fix`. The next scan then read hasWorktreeBranch=false,
#      called the task terminal, and the deliverable was gone. A slug is spent once its change is ON
#      TRUNK. (The reaping half is pinned in phase13; here we pin that BOTH batteries agree, because
#      a report-only battery that calls it an orphan while the reaping one calls it live is how the
#      two tools end up disagreeing about the only thing that can destroy a deliverable.)
#
# Run: bash acf-whip/tests/phase19-doctor-graph.test.sh
set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ACF_WHIP/skills/whip-doctor/bin/doctor.sh"
GEN="$ACF_WHIP/skills/lib/bin/acfw-doctor-generic.sh"
SCAN="$ACF_WHIP/skills/go/bin/scan-backlog.sh"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p19graph.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO"
unset ACFW_STORE ACFW_INTEGRATION_MODE 2>/dev/null || true

mkdir -p .backlog/pending .backlog/in-progress .backlog/completed .backlog/in-review \
         .backlog/blocked .backlog/rejected .backlog/accepted .backlog/draft .backlog/archive
mkdir -p .claude/agents && touch .claude/agents/python-engineer.md

mk(){ # <folder> <stem> <slug> <deps> [integrated-at]
  cat > ".backlog/$1/$2.md" <<EOF
# $2
- **ID**: ${2}-id
- **Status**: $1
- **Worktree**: $3
- **Priority**: medium
- **Agent**: python-engineer
- **Dependencies**: $4
- **Touches**: src/$2/**
- **Integrated-At**: ${5:-}
- **Rejection Count**: 0
EOF
}

cyc(){ bash "$DOC" "$REPO" 2>/dev/null | grep '^FATAL|cyclic-deps|' | cut -d'|' -f3 | sort | paste -sd, -; }
cyc_generic(){ bash "$SCAN" "$REPO" 2>/dev/null | bash "$GEN" "$REPO" 2>/dev/null | grep '^FATAL|cyclic-deps|' | cut -d'|' -f3 | sort | paste -sd, -; }

# ============================ THE defect: a dependency of a cycle member ========================
# aa <-> bb is the cycle. cc is a dependency OF aa and is in no cycle at all. dd is unrelated.
mk pending aa aa "bb, cc"
mk pending bb bb "aa"
mk pending cc cc "none"
mk pending dd dd "none"
git add -A; git commit -qm cyclefixture

check "a real 2-cycle is reported"                    "[ \"\$(cyc)\" = 'aa,bb' ]"
check "a DEPENDENCY of a cycle member is NOT reported" "! bash \"\$DOC\" \"\$REPO\" 2>/dev/null | grep -q '^FATAL|cyclic-deps|cc|'"
check "an unrelated task is not reported"              "! bash \"\$DOC\" \"\$REPO\" 2>/dev/null | grep -q '|cyclic-deps|dd|'"
check "the generic battery agrees exactly"             "[ \"\$(cyc_generic)\" = 'aa,bb' ]"

# ============================ self-loop is a cycle of one ======================================
mk pending ee ee "ee"
git add -A; git commit -qm selfloop
check "a self-dependency is a cycle"          "bash \"\$DOC\" \"\$REPO\" 2>/dev/null | grep -q '^FATAL|cyclic-deps|ee|'"
check "...and the generic battery agrees"     "bash \"\$SCAN\" \"\$REPO\" 2>/dev/null | bash \"\$GEN\" \"\$REPO\" 2>/dev/null | grep -q '^FATAL|cyclic-deps|ee|'"
rm -f .backlog/pending/ee.md; git add -A; git commit -qm rmselfloop

# ============================ a chain BETWEEN two cycles is not in either =======================
# aa<->bb  ->  p -> q ->  rr<->ss.  p and q have both incoming and outgoing edges, so a two-sided
# peel would still spare them; only a real SCC pass excludes them.
mk pending p  p  "q"
mk pending q  q  "rr"
mk pending rr rr "ss"
mk pending ss ss "rr"
python3 - <<'PY' 2>/dev/null || sed -i.bak 's/^- \*\*Dependencies\*\*: bb, cc$/- **Dependencies**: bb, cc, p/' .backlog/pending/aa.md
import re, pathlib
f = pathlib.Path('.backlog/pending/aa.md')
f.write_text(f.read_text().replace('- **Dependencies**: bb, cc', '- **Dependencies**: bb, cc, p'))
PY
rm -f .backlog/pending/aa.md.bak
git add -A; git commit -qm chainfixture
check "both cycles are reported"            "[ \"\$(cyc)\" = 'aa,bb,rr,ss' ]"
check "a node on the path BETWEEN them is not (p)" "! bash \"\$DOC\" \"\$REPO\" 2>/dev/null | grep -q '|cyclic-deps|p|'"
check "...nor q"                                   "! bash \"\$DOC\" \"\$REPO\" 2>/dev/null | grep -q '|cyclic-deps|q|'"
check "the generic battery agrees on the chain"    "[ \"\$(cyc_generic)\" = 'aa,bb,rr,ss' ]"

# ============================ an acyclic board reports nothing =================================
rm -f .backlog/pending/*.md
mk pending x x "y"
mk pending y y "z"
mk pending z z "none"
git add -A; git commit -qm acyclic
check "a plain dependency chain is not a cycle"  "[ -z \"\$(cyc)\" ]"
check "...in the generic battery either"         "[ -z \"\$(cyc_generic)\" ]"

# A cycle among ACCEPTED tasks is advisory, not a gate (unchanged 3.3.x behaviour).
rm -f .backlog/pending/*.md
mk accepted ca ca "cb" "deadbeef"
mk accepted cb cb "ca" "deadbeef"
git add -A; git commit -qm acceptedcycle
check "a cycle among accepted tasks is WARN, not FATAL" \
  "bash \"\$DOC\" \"\$REPO\" 2>/dev/null | grep -q '^WARN|cyclic-deps|ca|'"
check "...so it does not gate the run" "! bash \"\$DOC\" \"\$REPO\" 2>/dev/null | grep -q '^FATAL|cyclic-deps|'"
rm -f .backlog/accepted/*.md; git add -A; git commit -qm rmacceptedcycle

# ============================ worktree liveness: the two batteries must agree ===================
mk accepted landed   landedslug   none "deadbeef"
mk accepted unlanded unlandedslug none ""
git add -A; git commit -qm worktreefixture
git -C "$REPO" worktree add -q "$REPO/.worktree/unlandedslug" -b worktree/unlandedslug trunk 2>/dev/null
git -C "$REPO" worktree add -q "$REPO/.worktree/landedslug"   -b worktree/landedslug   trunk 2>/dev/null

REPORT=$(bash "$DOC" --mode default "$REPO" 2>/dev/null)
GREPORT=$(bash "$SCAN" "$REPO" 2>/dev/null | bash "$GEN" "$REPO" 2>/dev/null)
check "report-only: an accepted-but-UNINTEGRATED worktree is not called an orphan" \
  "! printf '%s' \"\$REPORT\" | grep -q 'orphaned-worktree|unlandedslug'"
check "...and the generic battery agrees (they must never disagree about this)" \
  "! printf '%s' \"\$GREPORT\" | grep -q 'orphaned-worktree|unlandedslug'"
check "report-only: an INTEGRATED accepted worktree IS an orphan" \
  "printf '%s' \"\$REPORT\" | grep -q 'orphaned-worktree|landedslug'"
check "...and the generic battery agrees there too" \
  "printf '%s' \"\$GREPORT\" | grep -q 'orphaned-worktree|landedslug'"

# ============================ dup-folder-unresolvable is visible to the GATE ====================
# /go runs `doctor --fix` with its stdout discarded and then reads the report-only pass. A finding
# computed only inside --fix is invisible to the gate that decides whether to dispatch.
rm -f .backlog/accepted/*.md
for f in pending blocked; do
  cat > ".backlog/$f/dup-001.md" <<'EOF'
# dup-001
- **ID**: D-1
- **Status**:
- **Worktree**: dupslug
- **Priority**: medium
- **Agent**: python-engineer
- **Dependencies**: none
- **Touches**: src/dup/**
- **Rejection Count**: 0
EOF
done
git add -A; git commit -qm dupfixture
OUT=$(bash "$DOC" "$REPO" 2>/dev/null)
check "the REPORT-ONLY pass emits dup-folder-unresolvable" \
  "printf '%s' \"\$OUT\" | grep -q '^FATAL|dup-folder-unresolvable|dup-001|'"
check "...so the SUMMARY the gate reads is ok=false" "printf '%s' \"\$OUT\" | grep -q 'SUMMARY|.*|ok=false'"
bash "$DOC" --fix "$REPO" >/dev/null 2>&1
check "--fix refuses to guess a survivor: both copies survive" \
  "[ -f .backlog/pending/dup-001.md ] && [ -f .backlog/blocked/dup-001.md ]"

# ============================ a dep token that prefixes its OWN task is not a cycle ============
# The dep resolver falls back to a prefix scan over every stem, and nothing excluded the DEPENDING
# stem from that scan. So `feature-231-api-v2` declaring a dependency on `feature-231-api` — a name
# that no longer exists — prefix-matched itself, the self-loop branch fired, and the doctor reported
# a cycle that is not there: FATAL, ok=false, /go refuses to dispatch. Which stem won was awk hash
# order, so it was not even reproducible across platforms. A token that only resolves to its own task
# is a BAD TOKEN; dangling-dep is the truthful finding and names the thing to fix.
mkdir -p .backlog/pending
mk pending feature-231-api-v2 f231 "feature-231-api"
git add -A; git commit -qm prefixself
check "a dep token that prefix-matches only its own task is NOT a cycle" \
  "! bash \"\$DOC\" \"\$REPO\" 2>/dev/null | grep -q '^FATAL|cyclic-deps|feature-231-api-v2|'"
check "...it is reported as a dangling dependency instead" \
  "bash \"\$DOC\" \"\$REPO\" 2>/dev/null | grep -q '^FATAL|dangling-dep|feature-231-api-v2|'"
check "...and the generic battery agrees" \
  "! bash \"\$SCAN\" \"\$REPO\" 2>/dev/null | bash \"\$GEN\" \"\$REPO\" 2>/dev/null | grep -q '^FATAL|cyclic-deps|feature-231-api-v2|'"
check "...reporting the same dangling token" \
  "bash \"\$SCAN\" \"\$REPO\" 2>/dev/null | bash \"\$GEN\" \"\$REPO\" 2>/dev/null | grep -q '^FATAL|dangling-dep|feature-231-api-v2|'"
# A genuine prefix reference to ANOTHER task still resolves, and a genuine self-dependency is still
# a cycle — the fix must not blunt either.
mk pending target-900-real tgt "none"
mk pending refers-by-prefix rbp "target-900"
mk pending honest-self hs "honest-self"
git add -A; git commit -qm prefixstill
check "a unique prefix of ANOTHER task still resolves" \
  "! bash \"\$DOC\" \"\$REPO\" 2>/dev/null | grep -q '^FATAL|dangling-dep|refers-by-prefix|'"
check "a genuine self-dependency is still a cycle" \
  "bash \"\$DOC\" \"\$REPO\" 2>/dev/null | grep -q '^FATAL|cyclic-deps|honest-self|'"
rm -f .backlog/pending/feature-231-api-v2.md .backlog/pending/target-900-real.md \
      .backlog/pending/refers-by-prefix.md .backlog/pending/honest-self.md
git add -A; git commit -qm rmprefixfixture

# ============================ a dep on a PARKED task is dep-inactive, not dangling (3.4.3) ======
# doctor.sh built its dependency index from the seven active folders only, so a pending task whose
# dependency had been paused (`/whip-move X draft`) or retired (`archive`) reported
# FATAL|dangling-dep — "this dep does not exist" — about a task that exists, and under per-task
# quarantine that FATAL holds the dependent out of the run. The generic battery (every other backend)
# already said WARN|dep-inactive with the remedy. Same board, two verdicts, depending on the store.
# Only a token that names nothing in ANY folder is a dangling dependency.
mk draft   parked-dep  pds "none"
mk archive retired-dep rds "none"
mk pending waits-on-draft   wod "parked-dep"
mk pending waits-on-archive woa "retired-dep"
mk pending waits-on-prefix  wop "parked-d"
mk pending waits-on-ghost   wog "ghost-dep-999"
git add -A; git commit -qm parkedfixture
OUT=$(bash "$DOC" "$REPO" 2>/dev/null)
check "a pending task depending on a DRAFT task is WARN|dep-inactive" \
  "printf '%s\n' \"\$OUT\" | grep -q '^WARN|dep-inactive|waits-on-draft|'"
check "...and is NOT reported as a dangling dependency" \
  "! printf '%s\n' \"\$OUT\" | grep -q '|dangling-dep|waits-on-draft|'"
check "...so no FATAL of any code names it (nothing holds it out of the run)" \
  "! printf '%s\n' \"\$OUT\" | grep -q '^FATAL|[^|]*|waits-on-draft|'"
check "the detail names the parked dep and the folder it is parked in" \
  "printf '%s\n' \"\$OUT\" | grep -qF 'WARN|dep-inactive|waits-on-draft|depends on parked-dep, which is in draft'"
check "an ARCHIVED dep is dep-inactive too, naming archive" \
  "printf '%s\n' \"\$OUT\" | grep -qF 'WARN|dep-inactive|waits-on-archive|depends on retired-dep, which is in archive' && ! printf '%s\n' \"\$OUT\" | grep -q '^FATAL|[^|]*|waits-on-archive|'"
check "a PREFIX token of a draft stem resolves to it, like any other dep token" \
  "printf '%s\n' \"\$OUT\" | grep -qF 'WARN|dep-inactive|waits-on-prefix|depends on parked-dep, which is in draft'"
check "a dep that exists NOWHERE is still FATAL|dangling-dep" \
  "printf '%s\n' \"\$OUT\" | grep -q '^FATAL|dangling-dep|waits-on-ghost|'"
check "...and it is not softened into dep-inactive" \
  "! printf '%s\n' \"\$OUT\" | grep -q '|dep-inactive|waits-on-ghost|'"
# The per-iteration gate runs --active-only, which skips the per-file pass over accepted/ for speed.
# The parked index must not depend on that pass, or the fast path reintroduces the false FATAL.
AOUT=$(bash "$DOC" --active-only "$REPO" 2>/dev/null)
check "--active-only (the per-iteration gate) agrees: WARN, no FATAL" \
  "printf '%s\n' \"\$AOUT\" | grep -q '^WARN|dep-inactive|waits-on-draft|' && ! printf '%s\n' \"\$AOUT\" | grep -q '^FATAL|[^|]*|waits-on-draft|'"
check "--quiet (the /go gate's dump) carries no FATAL for it" \
  "! bash \"\$DOC\" --quiet \"\$REPO\" 2>/dev/null | grep -q '^FATAL|[^|]*|waits-on-draft|'"
# Byte parity with the generic battery. Field 3 is a routing decision (CONTRACT.md: the exact whip
# key, matched exactly), so "the same finding" means the same LINE, not merely the same code. The
# files scanner does not list draft/archive wholesale, so the generic is fed the snapshot shape an
# adapter produces: the dependent in tasks[], the parked dep in inactive[].
GSNAP='{"tasks":[{"stem":"waits-on-draft","folder":"pending","id":"waits-on-draft-id","status":"pending","slug":"wod","deps":["parked-dep"],"touchesGlobs":[]}],"inactive":[{"stem":"parked-dep","folder":"draft","id":"parked-dep-id","slug":"pds","deps":[],"touchesGlobs":[]}]}'
GLINE=$(printf '%s' "$GSNAP" | bash "$GEN" "$REPO" 2>/dev/null | grep '^WARN|dep-inactive|waits-on-draft|')
DLINE=$(printf '%s\n' "$OUT" | grep '^WARN|dep-inactive|waits-on-draft|')
check "the files battery emits the generic battery's dep-inactive line byte for byte" \
  "[ -n \"\$GLINE\" ] && [ \"\$GLINE\" = \"\$DLINE\" ]"
# Parked stems are consulted only when NO active task answers the token. On files the scheduler's
# dependency index is the scanner's output, which omits draft/ and archive/, so it resolves a token
# that prefixes an active stem to THAT stem even when a parked task carries the exact name. The
# doctor must reach the same answer: dep-inactive here would warn "never dispatched" about a task
# the scheduler dispatches, and dropping the resolved edge would hide a real cycle or cross-slug FATAL.
mk draft   shared-100      s100d "none"
mk pending shared-100-live s100l "none"
mk pending waits-on-shared wos   "shared-100"
git add -A; git commit -qm shadowfixture
check "a token an ACTIVE task answers keeps resolving to it (parked stems never shadow it)" \
  "! bash \"\$DOC\" \"\$REPO\" 2>/dev/null | grep -q '|waits-on-shared|'"
rm -f .backlog/draft/parked-dep.md .backlog/archive/retired-dep.md .backlog/draft/shared-100.md \
      .backlog/pending/waits-on-draft.md .backlog/pending/waits-on-archive.md \
      .backlog/pending/waits-on-prefix.md .backlog/pending/waits-on-ghost.md \
      .backlog/pending/shared-100-live.md .backlog/pending/waits-on-shared.md
git add -A; git commit -qm rmparkedfixture

echo
echo "phase19-doctor-graph: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
