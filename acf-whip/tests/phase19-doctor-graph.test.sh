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

echo
echo "phase19-doctor-graph: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
