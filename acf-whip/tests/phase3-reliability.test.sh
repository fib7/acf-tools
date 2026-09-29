#!/usr/bin/env bash
# phase3-reliability.test.sh — verifies the 2.1.0 reliability fixes that live in the shell layer:
#   I4  apply-transition.sh syncs "- **Status**:" to the destination folder (no self-inflicted FATAL)
#   I2  apply-transition.sh increments "- **Block-Count**:" on a flagged specialist re-block
#   I3  append_log_row splices rows INTO the "## Transition Log" table and caps the body length
#   I5B LP-CAS integrator lands a no-code branch as terminal (ledger marker on trunk; no retry loop)
# Run: bash acf-whip/tests/phase3-reliability.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$ACF_WHIP/skills/go/bin/apply-transition.sh"
INTEGRATE="$ACF_WHIP/skills/integrate-lpcas/bin/integrate-lpcas.sh"
LIB="$ACF_WHIP/skills/lib/acfw-git.sh"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p3.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted}
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk

# Minimal task file mirroring the template's load-bearing lines (Status, Rejection Count, the
# Transition Log table, and a section AFTER it so we can prove rows splice in, not dangle at EOF).
mktask(){ # <dir> <stem> <slug> <status>
  cat > ".backlog/$1/$2.md" <<EOF
# Task: $2

## Metadata

- **ID**: $2
- **Status**: $4
- **Assigned Agent**: go-engineer
- **Worktree**: $3
- **Rejection Count**: 0

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
| 2026-06-01 00:00:00 | draft | pending | task-engineer | Initial task creation |

## Implementation Notes

(none)
EOF
}

echo "== I4: apply-transition syncs Status to the destination folder =="
mktask pending t-move slugm pending
git add -A; git commit -qm t-move
bash "$APPLY" "$REPO/.backlog/pending/t-move.md" in-progress orchestrator "dispatch" 0 0 >/dev/null
check "file moved to in-progress/" "[ -f '$REPO/.backlog/in-progress/t-move.md' ] && [ ! -f '$REPO/.backlog/pending/t-move.md' ]"
check "I4: Status rewritten to in-progress" "grep -qE '^- \*\*Status\*\*: in-progress\$' '$REPO/.backlog/in-progress/t-move.md'"
check "I4: no stale 'Status: pending' left" "! grep -qE '^- \*\*Status\*\*: pending\$' '$REPO/.backlog/in-progress/t-move.md'"

echo "== I3: the transition row splices INTO the Transition Log, not after the last heading =="
# The new row must appear BEFORE the '## Implementation Notes' heading (i.e. inside the table section).
ROW_LINE=$(grep -n '| pending | in-progress | orchestrator | dispatch |' "$REPO/.backlog/in-progress/t-move.md" | head -1 | cut -d: -f1)
IMPL_LINE=$(grep -n '^## Implementation Notes' "$REPO/.backlog/in-progress/t-move.md" | head -1 | cut -d: -f1)
check "I3: row is present" "[ -n \"$ROW_LINE\" ]"
check "I3: row sits inside the Transition Log section (before Implementation Notes)" "[ -n \"$ROW_LINE\" ] && [ -n \"$IMPL_LINE\" ] && [ \"$ROW_LINE\" -lt \"$IMPL_LINE\" ]"
check "I3: file still ends with the Implementation Notes section (no dangling rows at EOF)" "tail -3 '$REPO/.backlog/in-progress/t-move.md' | grep -q 'none'"

echo "== I2: apply-transition bumps Block-Count only with the BLOCK_INCREMENT flag =="
# specialist re-block (flag=1): in-progress -> blocked, Block-Count 0 -> 1 (field inserted, pre-2.1.0 task)
bash "$APPLY" "$REPO/.backlog/in-progress/t-move.md" blocked go-engineer "needs missing dep" 0 1 >/dev/null
check "I2: Block-Count inserted + set to 1 on flagged block" "grep -qE '^- \*\*Block-Count\*\*: 1\$' '$REPO/.backlog/blocked/t-move.md'"
# unblock then re-block again -> 2
bash "$APPLY" "$REPO/.backlog/blocked/t-move.md" pending orchestrator "unblocked" 0 0 >/dev/null
bash "$APPLY" "$REPO/.backlog/pending/t-move.md" in-progress orchestrator "dispatch" 0 0 >/dev/null
bash "$APPLY" "$REPO/.backlog/in-progress/t-move.md" blocked go-engineer "still blocked" 0 1 >/dev/null
check "I2: Block-Count increments to 2 on second flagged block" "grep -qE '^- \*\*Block-Count\*\*: 2\$' '$REPO/.backlog/blocked/t-move.md'"
# a timeout/redesign block (flag=0) must NOT bump the counter
bash "$APPLY" "$REPO/.backlog/blocked/t-move.md" pending orchestrator "unblocked" 0 0 >/dev/null
bash "$APPLY" "$REPO/.backlog/pending/t-move.md" blocked orchestrator "timeout — stale dispatch" 0 0 >/dev/null
check "I2: unflagged block does NOT bump Block-Count (stays 2)" "grep -qE '^- \*\*Block-Count\*\*: 2\$' '$REPO/.backlog/blocked/t-move.md'"

echo "== WHIP-08: --stage commits a none-slug task's standalone deliverables with the state move =="
# A "Worktree: none" task writes its deliverable into the ROOT tree and may not commit. Nothing else
# ever staged those paths, so the next checkout/stash destroyed them. The single writer stages them
# BY EXPLICIT PATH in the same commit as the folder move.
mktask pending t-deliv none pending
git add -A; git commit -qm t-deliv
mkdir -p docs/research; echo "findings" > docs/research/20260709-topic.md
echo "table" > docs/research/data.csv
BEFORE=$(git rev-parse HEAD)
bash "$APPLY" --stage docs/research/20260709-topic.md --stage docs/research/data.csv \
  "$REPO/.backlog/pending/t-deliv.md" completed go-engineer "done" 0 0 >/dev/null
check "deliverables are tracked after the transition" "git ls-files --error-unmatch docs/research/20260709-topic.md docs/research/data.csv >/dev/null 2>&1"
check "deliverables landed in the SAME commit as the move" \
  "git diff-tree --no-commit-id --name-only -r HEAD | grep -q '^docs/research/20260709-topic.md\$' && git diff-tree --no-commit-id --name-only -r HEAD | grep -q '^\.backlog/completed/t-deliv.md\$'"
check "exactly one commit was made" "[ \"\$(git rev-list --count $BEFORE..HEAD)\" -eq 1 ]"
check "tree is clean (nothing left uncommitted)" "[ -z \"\$(git status --porcelain)\" ]"

echo "== WHIP-08: --stage refuses state paths and never half-applies =="
mktask pending t-poison none pending
git add -A; git commit -qm t-poison
bash "$APPLY" --stage .backlog/pending/t-poison.md "$REPO/.backlog/pending/t-poison.md" completed go-engineer "x" 0 0 >/dev/null 2>&1
check ".backlog/ stage path exits 2" "[ \$? -eq 2 ]"
bash "$APPLY" --stage .acfwhip/integrated/aa/x.json "$REPO/.backlog/pending/t-poison.md" completed go-engineer "x" 0 0 >/dev/null 2>&1
check ".acfwhip/ stage path exits 2" "[ \$? -eq 2 ]"
bash "$APPLY" --stage /etc/passwd "$REPO/.backlog/pending/t-poison.md" completed go-engineer "x" 0 0 >/dev/null 2>&1
check "absolute stage path exits 2" "[ \$? -eq 2 ]"
bash "$APPLY" --stage ../outside.md "$REPO/.backlog/pending/t-poison.md" completed go-engineer "x" 0 0 >/dev/null 2>&1
check "traversing stage path exits 2" "[ \$? -eq 2 ]"
check "refusal did NOT move the task (validated before any mutation)" "[ -f '$REPO/.backlog/pending/t-poison.md' ]"

echo "== WHIP-08: a missing --stage path is skipped, never strands the transition =="
bash "$APPLY" --stage docs/research/never-written.md "$REPO/.backlog/pending/t-poison.md" completed go-engineer "x" 0 0 >/dev/null 2>&1
check "transition still applied despite the missing deliverable" "[ -f '$REPO/.backlog/completed/t-poison.md' ]"
check "tree clean after skip" "[ -z \"\$(git status --porcelain)\" ]"

echo "== WHIP-08: a crash between mv and commit is repaired on re-apply (rescue path) =="
# Simulate: the file is already in completed/ (move committed) but the deliverable never got staged.
mktask completed t-rescue none completed
git add -A; git commit -qm t-rescue
echo "orphan deliverable" > docs/research/rescued.md
bash "$APPLY" --stage docs/research/rescued.md "$REPO/.backlog/pending/t-rescue.md" completed go-engineer "x" 0 0 >/dev/null
check "no-op re-apply still commits the orphaned deliverable" "git ls-files --error-unmatch docs/research/rescued.md >/dev/null 2>&1"
check "tree clean after rescue" "[ -z \"\$(git status --porcelain)\" ]"

echo "== I3: append_log_row caps the Transition Log body length =="
# shellcheck disable=SC1090
. "$LIB"
CAPFILE="$WORK/capped.md"
cat > "$CAPFILE" <<EOF
# Task: cap

## Transition Log

| Date Time | From | To | Agent | Reason |
| --------- | ---- | -- | ----- | ------ |

## End
EOF
ACFW_LOG_ROW_CAP=10
i=1; while [ $i -le 40 ]; do append_log_row "$CAPFILE" "| row $i | a | b | c | d |"; i=$((i+1)); done
NROWS=$(grep -cE '^\| row [0-9]+ \|' "$CAPFILE")
check "I3: body capped to <= cap rows (10), not 40" "[ \"$NROWS\" -le 10 ]"
check "I3: newest row retained (row 40)" "grep -qE '^\| row 40 \|' '$CAPFILE'"
check "I3: oldest row dropped (row 1)" "! grep -qE '^\| row 1 \|' '$CAPFILE'"
check "I3: '## End' section survives the rewrite" "grep -q '^## End' '$CAPFILE'"
# no Transition Log table -> append at EOF (never lose a row)
NOLOG="$WORK/nolog.md"; printf '# Task\n\nnotes only\n' > "$NOLOG"
append_log_row "$NOLOG" "| x | y | z |"
check "I3: falls back to EOF append when no table exists" "grep -qE '^\| x \| y \| z \|' '$NOLOG'"

echo "== I5B: LP-CAS lands an empty (no-code) branch as terminal — marker on trunk, no retry loop =="
mktask accepted gate-201-review emptyslug accepted
git add -A; git commit -qm gate-task
# create the worktree branch from trunk with NO further commits (a gate/verification task did no code)
git -C "$REPO" worktree add -q "$REPO/.worktree/emptyslug" -b worktree/emptyslug trunk 2>/dev/null
bash "$INTEGRATE" "$REPO/.backlog/accepted/gate-201-review.md" >/tmp/p3-integ.out 2>/dev/null; RC=$?
check "I5B: exit 0 (terminal, not a retry loop)" "[ $RC -eq 0 ]"
check "I5B: integrated verdict emitted" "grep -q 'ACFW-INTEGRATE: integrated' /tmp/p3-integ.out"
# LP-CAS: integration truth is the in-tree ledger marker on trunk (NOT an Integrated-At field).
check "I5B: ledger marker reachable from trunk -> counts terminal" \
  ". '$ACF_WHIP/skills/lib/acfw-git.sh'; acfw_is_integrated '$REPO' trunk gate-201-review"
rm -f /tmp/p3-integ.out

echo "== WHIP-23: append_log_row can never destroy a task file =="
# Field incident 2026-08-24: a 17507-byte task document was replaced by a single 267-byte
# transition row and committed. awk run against a file another process had momentarily emptied
# emits ONLY the new row; `[ -s "$tmp" ]` passed (a row is non-empty) and `cat "$tmp" > "$file"`
# wrote the corpse. The `else` fallback was no safer: `printf >> "$file"` CREATES the same corpse
# on an empty or absent file. Both routes are now refused. (acfw-git.sh append_log_row.)
# NOTE: a table-LESS file is NOT the bug and must keep working — see the I3 EOF-append check above.
ALRW="$WORK/alr"; mkdir -p "$ALRW"

: > "$ALRW/empty.md"
append_log_row "$ALRW/empty.md" "| ts | a | b | c | d |" 2>/dev/null; ARC=$?
check "WHIP-23: an emptied file is REFUSED (rc 3)"            "[ $ARC -eq 3 ]"
check "WHIP-23: the emptied file is left empty, not made a one-row corpse" "[ ! -s '$ALRW/empty.md' ]"

printf '\n\n' > "$ALRW/blank.md"     # [ -s ] alone would pass this; it is the same corpse class
append_log_row "$ALRW/blank.md" "| ts | a | b | c | d |" 2>/dev/null; BRC=$?
check "WHIP-23: a blank-only file is REFUSED (rc 3)" "[ $BRC -eq 3 ]"
check "WHIP-23: the blank-only file gains no row"    "! grep -q '^|' '$ALRW/blank.md'"

append_log_row "$ALRW/absent.md" "| ts | a |" 2>/dev/null; NRC=$?
check "WHIP-23: an absent file is REFUSED (rc 3)"        "[ $NRC -eq 3 ]"
check "WHIP-23: the absent file is NOT created by the fallback" "[ ! -e '$ALRW/absent.md' ]"

mktask pending alr-healthy alrslug pending
HF="$REPO/.backlog/pending/alr-healthy.md"
BEFORE=$(wc -l < "$HF" | tr -d '[:space:]'); INO=$(ls -i "$HF" | awk '{print $1}')
append_log_row "$HF" "| 2026-06-02 00:00:00 | pending | in-progress | orchestrator | go |"; HRC=$?
SEPL=$(grep -n '^| --------- |' "$HF" | head -1 | cut -d: -f1)
NEWL=$(grep -n 'in-progress | orchestrator' "$HF" | head -1 | cut -d: -f1)
check "WHIP-23: a healthy file still gets its row (rc 0)" "[ $HRC -eq 0 ]"
check "WHIP-23: spliced directly under the header separator" \
  "[ -n \"$SEPL\" ] && [ \"$NEWL\" -eq \$(( SEPL + 1 )) ]"
check "WHIP-23: the file grew by EXACTLY one line" \
  "[ \"\$(wc -l < '$HF' | tr -d '[:space:]')\" -eq $((BEFORE+1)) ]"
check "WHIP-23: metadata and the trailing section survived" \
  "grep -q '^- \*\*ID\*\*: alr-healthy' '$HF' && grep -q '^## Implementation Notes' '$HF'"
# The write-back must be an atomic same-directory rename. `cat "$tmp" > "$file"` truncates in
# place, which is itself a 0-byte window for every OTHER reader (doctor field(), scan-backlog,
# the reviewer's token grep). A changed inode is the observable proof it is a rename.
check "WHIP-23: the write-back is a rename, not a truncate-in-place (inode changed)" \
  "[ \"\$(ls -i '$HF' | awk '{print \$1}')\" != '$INO' ]"
check "WHIP-23: mode stayed group/other readable (mktemp is 0600)" \
  "ls -l '$HF' | cut -c1-10 | grep -q '^-rw.r..r..'"
# A leftover temp must be invisible to every consumer glob: they all require a .md suffix.
check "WHIP-23: no .acfw-log temp left beside the task file" \
  "[ -z \"\$(ls -a '$REPO/.backlog/pending' | grep '^\.acfw-log\.' || true)\" ]"

echo "== WHIP-23: apply-transition refuses to MOVE or COMMIT a collapsed task file =="
# What made the incident silent was not the truncation but the commit 25 lines later: this writer
# ran sed/append/mv/add/commit with no content assertion anywhere. Two guards now bracket the
# mutations. Fixture is the observed artifact verbatim: one transition row, nothing else.
mktask pending t-corpse corpseslug pending
git add -A; git commit -qm t-corpse
H0=$(git rev-parse HEAD)
printf '| 2026-08-25 01:41:36 | pending | completed | nextjs-engineer | note |\n' \
  > "$REPO/.backlog/pending/t-corpse.md"
bash "$APPLY" "$REPO/.backlog/pending/t-corpse.md" completed orchestrator "done" 0 0 \
  >"$WORK/corpse.out" 2>&1; CRC=$?
check "WHIP-23: refused with the distinct exit code 4" "[ $CRC -eq 4 ]"
check "WHIP-23: the file did NOT move" \
  "[ -f '$REPO/.backlog/pending/t-corpse.md' ] && [ ! -f '$REPO/.backlog/completed/t-corpse.md' ]"
check "WHIP-23: nothing was committed" "[ \"\$(git rev-parse HEAD)\" = '$H0' ]"
check "WHIP-23: nothing was staged"    "[ -z \"\$(git diff --cached --name-only)\" ]"
check "WHIP-23: the message carries the literal recovery command" \
  "grep -q 'checkout HEAD -- .backlog/pending/t-corpse.md' '$WORK/corpse.out'"
check "WHIP-23: the phase is reported as on-entry (it arrived broken)" \
  "grep -q 'on-entry' '$WORK/corpse.out'"
check "WHIP-23: append_log_row added no second row to the corpse" \
  "[ \"\$(wc -l < '$REPO/.backlog/pending/t-corpse.md' | tr -d '[:space:]')\" -eq 1 ]"

# The PRE-COMMIT guard, exercised deterministically rather than as a real race (which would be
# flaky). A PATH-shimmed `date` empties the file at the TS= line — after the on-entry guard, before
# the first sed — which is exactly the window a concurrent emptier occupies.
mkdir -p "$WORK/shim"
printf '#!/usr/bin/env bash\n[ -n "${ACFW_TEST_TRUNCATE:-}" ] && : > "$ACFW_TEST_TRUNCATE"\nexec /bin/date "$@"\n' \
  > "$WORK/shim/date"; chmod +x "$WORK/shim/date"
mktask pending t-torn tornslug pending
git add -A; git commit -qm t-torn
H1=$(git rev-parse HEAD)
PATH="$WORK/shim:$PATH" ACFW_TEST_TRUNCATE="$REPO/.backlog/pending/t-torn.md" \
  bash "$APPLY" "$REPO/.backlog/pending/t-torn.md" in-progress orchestrator "x" 0 0 \
  >"$WORK/torn.out" 2>&1; TRC=$?
check "WHIP-23: a truncation AFTER the entry guard is caught before the mv (exit 4)" "[ $TRC -eq 4 ]"
check "WHIP-23: the phase is reported as pre-commit (it broke UNDER the writer)" \
  "grep -q 'pre-commit' '$WORK/torn.out'"
check "WHIP-23: still nothing committed" "[ \"\$(git rev-parse HEAD)\" = '$H1' ]"
check "WHIP-23: append_log_row refused rather than writing a row into the emptied file" \
  "[ ! -s '$REPO/.backlog/pending/t-torn.md' ]"

echo "== 3.5.0: append_log_row FILE ROW [HEADING] [CAP] — 2-arg callers stay byte-identical =="
# 3.5.0 generalizes append_log_row so acfw-cycle can write a cycle record's '## Plan Log'. Every
# task-state writer (apply-transition.sh, the multica adapter, clean-checkout's token) still calls it
# with two arguments, and those rows are what the review gate and the doctor grep. The EXPECTED bytes
# below were produced by the 3.4.3 implementation and are pinned as literals, never re-derived from
# the lib under test: comparing the new code against itself would pass whatever it did.
# The fixture carries a SECOND table under '## Plan Log' on purpose. A 2-arg call must not touch it,
# and a heading match that drifted to "first table in the file" or "last '## ... Log'" would.
. "$LIB"
ALB="$WORK/alr-bytes"; mkdir -p "$ALB"
cat > "$ALB/fx.md" <<'EOF'
# Task: fx-001-byte-identity

## Metadata

- **ID**: fx-001
- **Status**: pending

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
| 2026-06-01 00:00:00 | draft | pending | task-engineer | Initial task creation |

## Plan Log

| Date Time | Event | By | Content | Details |
|---|---|---|---|---|
| 2026-06-01 00:00:00 | drafted | t@t | - | must stay untouched by 2-arg calls |

## Implementation Notes

(none)
EOF
cat > "$ALB/fx.expected" <<'EOF'
# Task: fx-001-byte-identity

## Metadata

- **ID**: fx-001
- **Status**: pending

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
| 2026-06-02 00:00:04 | pending | in-progress | orchestrator | dispatch 4 |
| 2026-06-02 00:00:03 | pending | in-progress | orchestrator | dispatch 3 |
| 2026-06-02 00:00:02 | pending | in-progress | orchestrator | dispatch 2 |

## Plan Log

| Date Time | Event | By | Content | Details |
|---|---|---|---|---|
| 2026-06-01 00:00:00 | drafted | t@t | - | must stay untouched by 2-arg calls |

## Implementation Notes

(none)
EOF
ALB_RC=0
for i in 1 2 3 4; do
  ACFW_LOG_ROW_CAP=3 append_log_row "$ALB/fx.md" "| 2026-06-02 00:00:0$i | pending | in-progress | orchestrator | dispatch $i |" || ALB_RC=$?
done
check "2-arg: every call returns 0" "[ $ALB_RC -eq 0 ]"
check "2-arg: capped splice into '## Transition Log' is byte-identical to 3.4.3" "cmp -s '$ALB/fx.md' '$ALB/fx.expected'"

# The table as the LAST section, starting empty, fed a row carrying the multica adapter's escaped
# pipe and a backslash: awk -v and gsub both reinterpret backslashes, and '&' is gsub's
# whole-match token, so a reimplementation that routes the row through either changes these bytes.
cat > "$ALB/last.md" <<'EOF'
# Task: fx-002-last-section

- **ID**: fx-002

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
EOF
cat > "$ALB/last.expected" <<'EOF'
# Task: fx-002-last-section

- **ID**: fx-002

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
| 2026-06-03 10:00:01 | rejected | pending | orchestrator | retry |
| 2026-06-03 10:00:00 | in-review | rejected | quality-reviewer | a \| b & c/d \\n |
EOF
append_log_row "$ALB/last.md" '| 2026-06-03 10:00:00 | in-review | rejected | quality-reviewer | a \| b & c/d \\n |'
append_log_row "$ALB/last.md" '| 2026-06-03 10:00:01 | rejected | pending | orchestrator | retry |'
check "2-arg: an empty trailing table, escaped pipe, '&' and backslashes are byte-identical to 3.4.3" \
  "cmp -s '$ALB/last.md' '$ALB/last.expected'"

# No Transition Log at all: the never-lose-a-row EOF fallback, exact bytes.
printf '# Task: no table\n\nnotes only\n' > "$ALB/eof.md"
append_log_row "$ALB/eof.md" '| 2026-06-02 00:00:09 | a | b | c | d |'
printf '# Task: no table\n\nnotes only\n| 2026-06-02 00:00:09 | a | b | c | d |\n' > "$ALB/eof.expected"
check "2-arg: the EOF fallback is byte-identical to 3.4.3" "cmp -s '$ALB/eof.md' '$ALB/eof.expected'"

# Naming the default heading explicitly must be the same call, not a second code path.
cp "$ALB/fx.md" "$ALB/fx-2arg.md"; cp "$ALB/fx.md" "$ALB/fx-3arg.md"
ACFW_LOG_ROW_CAP=3 append_log_row "$ALB/fx-2arg.md" '| 2026-06-02 00:00:05 | in-progress | completed | go-engineer | done |'
ACFW_LOG_ROW_CAP=3 append_log_row "$ALB/fx-3arg.md" '| 2026-06-02 00:00:05 | in-progress | completed | go-engineer | done |' "Transition Log"
check "3-arg with HEADING='Transition Log' writes the same bytes as the 2-arg call" \
  "cmp -s '$ALB/fx-2arg.md' '$ALB/fx-3arg.md'"

echo "== 3.5.0: HEADING targets '## Plan Log' by exact heading text =="
# A cycle record.md is written only by acfw-cycle, newest first. The heading is matched by STRING
# EQUALITY on the text after '## ': the decoy '## Plan Log Archive' sits ABOVE the real section, so a
# prefix or substring match splices the row into the wrong table and the audit trail reads wrong.
PLF="$ALB/record.md"
cat > "$PLF" <<'EOF'
# Cycle Record: fixture

## Metadata

- **Format**: 1

## Plan Log Archive

| Date Time | Event | By | Content | Details |
|---|---|---|---|---|
| 2025-01-01 00:00:00 | decoy | d@d | - | decoy table |

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
| 2026-06-01 00:00:00 | draft | pending | task-engineer | untouched |

## Plan Log

| Date Time | Event | By | Content | Details |
|---|---|---|---|---|
| 2026-06-01 00:00:00 | drafted | t@t | - | first |

## Tail

end
EOF
sec(){ # <file> <heading> — print the lines of one '## ' section (heading excluded)
  awk -v h="## $2" '$0==h{f=1;next} f&&/^## /{f=0} f' "$1"
}
DECOY_BEFORE=$(sec "$PLF" "Plan Log Archive"); TL_BEFORE=$(sec "$PLF" "Transition Log")
append_log_row "$PLF" '| 2026-06-02 00:00:00 | approved | t@t | 0123456789ab | card yes |' "Plan Log"; HRC=$?
check "HEADING: returns 0" "[ $HRC -eq 0 ]"
check "HEADING: the row lands directly under the '## Plan Log' separator (newest first)" \
  "[ \"\$(sec '$PLF' 'Plan Log' | grep '^|' | sed -n 3p)\" = '| 2026-06-02 00:00:00 | approved | t@t | 0123456789ab | card yes |' ]"
check "HEADING: the older row now sits below it" \
  "[ \"\$(sec '$PLF' 'Plan Log' | grep '^|' | sed -n 4p)\" = '| 2026-06-01 00:00:00 | drafted | t@t | - | first |' ]"
check "HEADING: the decoy '## Plan Log Archive' table is untouched (string equality, not prefix)" \
  "[ \"\$(sec '$PLF' 'Plan Log Archive')\" = \"\$DECOY_BEFORE\" ]"
check "HEADING: the Transition Log table is untouched" \
  "[ \"\$(sec '$PLF' 'Transition Log')\" = \"\$TL_BEFORE\" ]"
check "HEADING: the section after the log survives" "tail -1 '$PLF' | grep -qx 'end'"
check "HEADING: exactly one new line was written" "[ \"\$(grep -c 'approved | t@t' '$PLF')\" -eq 1 ]"

echo "== 3.5.0: CAP 'none' keeps every row even when ACFW_LOG_ROW_CAP=1 =="
# The plan audit trail must never be truncated by a user's ACFW_LOG_ROW_CAP. 'none' has to be
# recognised BEFORE the cap<1 -> 1 clamp: a clamp that ran first would read the non-numeric 'none'
# as 0, clamp it to 1, and keep a single row, which is the exact loss the sentinel exists to stop.
NONEF="$ALB/none.md"
printf '# Cycle Record: none\n\n## Plan Log\n\n| Date Time | Event | By | Content | Details |\n|---|---|---|---|---|\n\n## After\n\nkept\n' > "$NONEF"
i=1; NRC=0
while [ $i -le 40 ]; do
  ACFW_LOG_ROW_CAP=1 append_log_row "$NONEF" "| 2026-06-02 00:00:00 | amended | t@t | - | row $i |" "Plan Log" none || NRC=$?
  i=$((i+1))
done
check "CAP none: every call returns 0" "[ $NRC -eq 0 ]"
check "CAP none: all 40 rows are kept, inside the Plan Log section" \
  "[ \"\$(sec '$NONEF' 'Plan Log' | grep -c '| amended | t@t | - | row [0-9]* |')\" -eq 40 ]"
check "CAP none: newest first (row 40 is the first data row)" \
  "[ \"\$(sec '$NONEF' 'Plan Log' | grep '^|' | sed -n 3p)\" = '| 2026-06-02 00:00:00 | amended | t@t | - | row 40 |' ]"
check "CAP none: oldest last (row 1 is the last data row)" \
  "[ \"\$(sec '$NONEF' 'Plan Log' | grep '^|' | tail -1)\" = '| 2026-06-02 00:00:00 | amended | t@t | - | row 1 |' ]"
check "CAP none: the section after the log survives" "grep -qx 'kept' '$NONEF'"
# The same call WITHOUT the sentinel still honours the env cap, so the test above is not vacuous:
# ACFW_LOG_ROW_CAP=1 really does truncate on this heading.
CAPPEDF="$ALB/capped-plan.md"; cp "$NONEF" "$CAPPEDF"
ACFW_LOG_ROW_CAP=1 append_log_row "$CAPPEDF" '| 2026-06-02 00:00:01 | amended | t@t | - | row 41 |' "Plan Log"
check "CAP omitted: ACFW_LOG_ROW_CAP=1 applies to a non-default heading (1 row left)" \
  "[ \"\$(sec '$CAPPEDF' 'Plan Log' | grep -c '| amended |')\" -eq 1 ]"
check "CAP omitted: the row it kept is the newest" "sec '$CAPPEDF' 'Plan Log' | grep -q 'row 41 |'"
cp "$NONEF" "$CAPPEDF"
ACFW_LOG_ROW_CAP=80 append_log_row "$CAPPEDF" '| 2026-06-02 00:00:01 | amended | t@t | - | row 41 |' "Plan Log" 5
check "CAP numeric: an explicit CAP argument overrides the env cap (5 rows)" \
  "[ \"\$(sec '$CAPPEDF' 'Plan Log' | grep -c '| amended |')\" -eq 5 ]"
cp "$NONEF" "$CAPPEDF"
ACFW_LOG_ROW_CAP=80 append_log_row "$CAPPEDF" '| 2026-06-02 00:00:01 | amended | t@t | - | row 41 |' "Plan Log" 0
check "CAP numeric: a CAP below 1 still clamps to 1 (the sentinel did not replace the clamp)" \
  "[ \"\$(sec '$CAPPEDF' 'Plan Log' | grep -c '| amended |')\" -eq 1 ]"

echo ""
echo "==================================================="
echo "Phase 3 reliability test: $PASS passed, $FAIL failed"
echo "==================================================="
[ $FAIL -eq 0 ]
