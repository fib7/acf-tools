#!/usr/bin/env bash
# conventions.test.sh - the shipped conventions and the audit agree with acf-whip's cycle layout.
#
# acf-whip 3.5.0 keeps its planning records in docs/cycles/<YYYYMMDD-slug>/ and one-rule lessons in
# docs/acf/lessons/. Nothing functional in acf-whip depends on this plugin, but three librarian defaults
# would damage those records if left as they were:
#   - `/audit-acf-conventions --fix` resolves a broken link by file name and rewrites it. In a cycle's
#     plan.md that edit changes the content hash approval is bound to, so a "fix" silently un-approves
#     the plan; in a retrospective it rewrites a frozen record. Those two prefixes are REPORT-ONLY.
#   - a cycle folder's name is its ID; any rename makes acf-whip stop recognising it. The audit reports,
#     never renames, and ignores folders it does not own (no acf Format stamp in record.md).
#   - listing docs/cycles/ as a required or temporal location would make `--fix` mkdir it in every
#     project, including ones that never use acf-whip.
#   - a lesson's slug is its identity; the timeless rename would fork one rule into two files on the
#     next /retro. Lessons are reported, never renamed.
# And two defects in the link check itself: it read backticked examples as links (the conventions
# document's own samples came up broken on every fresh project and --fix rewrote them), and it edited
# plugin-installed documents, which made a pristine copy look customised and ended its refresh.
# The audit is executed by a model from SKILL.md, so the load-bearing parts are shipped as marked,
# run-verbatim blocks; this suite extracts those exact blocks and runs them against scratch repos.
#
# Offline; every fixture lives under mktemp -d. Run: bash acf-librarian/tests/conventions.test.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORG="$ROOT/content/organization-template.md"
GITC="$ROOT/content/git-commit-conventions-template.md"
SKILL="$ROOT/skills/audit-acf-conventions/SKILL.md"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfl-conv.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/nohooks"

# The fenced block that starts with a "# acf-librarian:<name>" line, up to its closing fence.
block(){ awk -v m="# acf-librarian:$1" 'index($0, m) == 1 { on = 1 } on && /^```$/ { exit } on { print }' "$SKILL"; }
newrepo(){ mkdir -p "$1" && git -C "$1" init -q && git -C "$1" config user.email t@example.invalid &&
  git -C "$1" config user.name t && git -C "$1" config core.hooksPath "$WORK/nohooks" && git -C "$1" config commit.gpgsign false; }
commit_all(){ git -C "$1" add docs >/dev/null && git -C "$1" commit -qm fixture; }

echo "== 1. organization template"
check "the docs tree lists cycles/ with its class and the acf-whip qualifier" \
  "grep -qF '├── cycles/                     # acf-whip cycle records (DATED, LIVING until closed; if using acf-whip)' \"$ORG\""
check "the docs tree lists acf/lessons/ as timeless, under acf/" \
  "grep -qF '│   ├── lessons/               # one-rule lessons from /retro (TIMELESS; if using acf-whip)' \"$ORG\""
check "a third naming class, Dated Living Records, exists" "grep -q '^### Dated Living Records' \"$ORG\""
check "...saying the folder name is the ID and must never be renamed or moved" \
  "grep -A3 '^### Dated Living Records' \"$ORG\" | grep -q 'NEVER rename or move it'"
check "...and that machine files are tooling-only" "grep -A5 '^### Dated Living Records' \"$ORG\" | grep -q 'Machine files are tooling-only'"
TEMPORAL=$(awk '/^### Temporal Documents/{on=1} /^### Timeless Documents/{on=0} on' "$ORG")
check "docs/cycles/ is NOT a temporal Required Location (audit --fix would mkdir it everywhere)" \
  "printf '%s' \"\$TEMPORAL\" | grep -q 'docs/snapshots/planning/' && ! printf '%s' \"\$TEMPORAL\" | grep -q 'docs/cycles'"
check "the snapshots/planning/ comment points at docs/cycles/" \
  "grep -q '└── planning/ .*# Planning snapshots (acf-whip plans live in docs/cycles/)' \"$ORG\""
check "no em dashes in either template" "! grep -q '—' \"$ORG\" \"$GITC\""

echo "== 2. git commit conventions template"
check "the stale 'Worktree-Aware Commits (1.2.0+)' section is gone" "! grep -q 'Worktree-Aware Commits' \"$GITC\""
check "one generic line makes ACFW-* trailers load-bearing" \
  "grep -qxF '\`ACFW-*\` trailers written by acf-whip are load-bearing: never strip, reword or squash them away (see docs/acf/backlog/workflow.md).' \"$GITC\""

echo "== 3. audit skill: optional acf-whip directories are never required"
DIRLOOP=$(grep -m1 '^for dir in docs ' "$SKILL")
check "the Step 2 required-directory loop exists" "[ -n \"\$DIRLOOP\" ]"
check "...and names neither docs/cycles nor docs/acf/lessons" \
  "! printf '%s' \"\$DIRLOOP\" | grep -qE 'docs/cycles|docs/acf/lessons'"
check "the skill says never to create them" "grep -q 'never create them' \"$SKILL\""

echo "== 4. audit skill: cycle folders are report-only"
CYC="$WORK/cycle-check.sh"; block cycle-check > "$CYC"
check "the cycle-check block is present in SKILL.md" "[ -s \"$CYC\" ] && grep -q 'docs/cycles' \"$CYC\""
check "...and contains no mv, rm, mkdir or write redirection into docs/" \
  "! grep -qE '(^|[^a-z])(mv|rm|mkdir|git mv)[[:space:]]|>[[:space:]]*\"?docs/' \"$CYC\""
R1="$WORK/cycles"; newrepo "$R1"
rec(){ mkdir -p "$R1/docs/cycles/$1"
  printf '# Cycle Record: x\n## Metadata\n- **Format**: 1\n- **ID**: %s\n- **Status**: approved\n' "$2" > "$R1/docs/cycles/$1/record.md"; }
rec owner-seat-notice 20260928-owner-seat-notice          # undated folder with an acf stamp
rec 20260928-foo 20260928-bar                             # renamed after creation
rec 20260928-ok 20260928-ok                               # healthy
mkdir -p "$R1/docs/cycles/some-other-tool-plan"; echo '# not ours' > "$R1/docs/cycles/some-other-tool-plan/plan.md"
mkdir -p "$R1/docs/cycles/notes"; printf '# Record\n- **ID**: notes\n' > "$R1/docs/cycles/notes/record.md"   # no Format stamp
echo '# stray' > "$R1/docs/cycles/README.md"
commit_all "$R1"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "  SKIP: $sh not installed"; continue; }
  OUTC=$(cd "$R1" && "$sh" "$CYC" 2>&1)
  check "[$sh] an undated folder with an acf stamp is reported with its ID" \
    "printf '%s\n' \"\$OUTC\" | grep -q '^REPORT: docs/cycles/owner-seat-notice (cycle folder missing YYYYMMDD- prefix.*20260928-owner-seat-notice'"
  check "[$sh] a folder whose name differs from its recorded ID is reported" \
    "printf '%s\n' \"\$OUTC\" | grep -q '^REPORT: docs/cycles/20260928-foo (folder name differs from its recorded ID 20260928-bar'"
  check "[$sh] exactly those two reports: healthy and foreign folders are silent" \
    "[ \"\$(printf '%s\n' \"\$OUTC\" | grep -c '^REPORT:')\" -eq 2 ] && ! printf '%s' \"\$OUTC\" | grep -qE 'ok|some-other-tool|notes|README'"
  check "[$sh] nothing under docs/ changed" "[ -z \"\$(git -C \"$R1\" status --porcelain)\" ]"
done

echo "== 5. audit skill: links in docs/cycles/ and docs/retrospectives/ are never auto-edited"
LNK="$WORK/link-check.sh"; block link-check > "$LNK"
check "the link-check block is present in SKILL.md" "[ -s \"$LNK\" ] && grep -q 'PROTECTED' \"$LNK\""
R2="$WORK/links"; newrepo "$R2"
mkdir -p "$R2/docs/cycles/20260928-x" "$R2/docs/retrospectives" "$R2/docs/patterns" "$R2/docs/agents/universal" \
  "$R2/docs/development" "$R2/docs/a" "$R2/docs/b"
echo '# hub' > "$R2/docs/README.md"                                  # the ONLY README.md: a single match
echo '# moved' > "$R2/docs/agents/universal/moved.md"
echo '# guide' > "$R2/docs/development/guide.md"
echo '# a' > "$R2/docs/a/twin.md"; echo '# b' > "$R2/docs/b/twin.md"
# The plan's verification fixture: plan.md links a missing docs/x/README.md while docs/README.md exists.
printf '# Plan\n\nSee [the hub](docs/x/README.md) and [guide](../../development/old/guide.md).\n' > "$R2/docs/cycles/20260928-x/plan.md"
printf '# Record\n\n[stale](old/moved.md)\n' > "$R2/docs/cycles/20260928-x/record.md"
printf '# Retro\n\nWe followed [the guide](../old/guide.md).\n' > "$R2/docs/retrospectives/20260101-r.md"
printf '# P\n\n[moved](../agents/moved.md#sec) [web](https://example.com/x.md) [mail](mailto:a@b.c) [here](#top)\n[twin](twin.md)\n\n```\n[inside a fence](nowhere.md)\n```\n' > "$R2/docs/patterns/p.md"
printf '# CRLF\r\n\r\n[guide](../guide.md)\r\n' > "$R2/docs/patterns/crlf.md"
# The SAME broken link in prose and in a fenced example: only the prose one may change. A distinct fenced
# link (p.md's nowhere.md) cannot catch a whole-file substitution, because nothing rewrites it.
printf '# F\n\n[moved](../agents/moved.md)\n\n```md\n[moved](../agents/moved.md)\n```\n' > "$R2/docs/patterns/fence.md"
# A doc outside the protected folders that is a symlink INTO a cycle: a write lands in the plan.
ln -s ../cycles/20260928-x/plan.md "$R2/docs/patterns/current-plan.md"
# A doc symlinked to a file outside docs/: a write lands there, with links computed from the wrong folder.
mkdir -p "$R2/shared"; printf '# Ext\n\n[moved](../agents/moved.md)\n' > "$R2/shared/ext.md"
ln -s ../../shared/ext.md "$R2/docs/patterns/ext.md"
commit_all "$R2"; git -C "$R2" add shared >/dev/null && git -C "$R2" commit -qm shared

OUTA=$(cd "$R2" && fix_mode=false bash "$LNK" 2>&1)
check "audit mode: nothing is written anywhere" "git -C \"$R2\" diff --quiet"
check "audit mode: the plan.md broken link is reported" "printf '%s\n' \"\$OUTA\" | grep -q '^BROKEN: docs/cycles/20260928-x/plan.md -> docs/x/README.md'"
check "audit mode: a normal broken link gets a suggestion" \
  "printf '%s\n' \"\$OUTA\" | grep -A1 '^BROKEN: docs/patterns/p.md -> ../agents/moved.md#sec' | grep -q 'SUGGESTION: ../agents/universal/moved.md#sec'"
check "fenced, external, mailto and same-page links are skipped" \
  "! printf '%s' \"\$OUTA\" | grep -qE 'nowhere.md|example.com|mailto|#top'"

OUTF=$(cd "$R2" && fix_mode=true bash "$LNK" 2>&1)
check "FIX mode leaves docs/cycles/ byte-identical (git diff --exit-code)" "git -C \"$R2\" diff --quiet --exit-code -- docs/cycles/"
check "FIX mode leaves docs/retrospectives/ byte-identical" "git -C \"$R2\" diff --quiet --exit-code -- docs/retrospectives/"
check "...and says why: REPORT-ONLY for the plan's single-match link" \
  "printf '%s\n' \"\$OUTF\" | grep -A1 '^BROKEN: docs/cycles/20260928-x/plan.md -> docs/x/README.md' | grep -q 'REPORT-ONLY'"
check "...and for the retrospective" \
  "printf '%s\n' \"\$OUTF\" | grep -A1 '^BROKEN: docs/retrospectives/20260101-r.md' | grep -q 'REPORT-ONLY'"
check "FIX mode still repairs an ordinary doc, keeping the #section suffix (non-vacuity)" \
  "grep -qF '[moved](../agents/universal/moved.md#sec)' \"$R2/docs/patterns/p.md\""
check "an ambiguous target is reported, not guessed" \
  "grep -qF '[twin](twin.md)' \"$R2/docs/patterns/p.md\" && printf '%s' \"\$OUTF\" | grep -q 'AMBIGUOUS: 2 files named twin.md'"
check "the fenced example is untouched" "grep -qF '[inside a fence](nowhere.md)' \"$R2/docs/patterns/p.md\""
check "a link in prose is fixed while the SAME link inside a fence is not" \
  "[ \"\$(sed -n 3p \"$R2/docs/patterns/fence.md\")\" = '[moved](../agents/universal/moved.md)' ] && [ \"\$(sed -n 6p \"$R2/docs/patterns/fence.md\")\" = '[moved](../agents/moved.md)' ]"
check "a doc symlinked into a cycle is report-only (the plan behind it is unchanged, above)" \
  "[ -L \"$R2/docs/patterns/current-plan.md\" ] && printf '%s\n' \"\$OUTF\" | grep -A1 '^BROKEN: docs/patterns/current-plan.md' | grep -q 'REPORT-ONLY'"
check "a doc symlinked outside docs/ is report-only, naming where a write would land" \
  "git -C \"$R2\" diff --quiet --exit-code -- shared/ && [ -L \"$R2/docs/patterns/ext.md\" ] && printf '%s\n' \"\$OUTF\" | grep -A1 '^BROKEN: docs/patterns/ext.md' | grep 'REPORT-ONLY' | grep -q 'symlink to shared/ext.md'"
check "a CRLF file is fixed with its line endings kept" \
  "grep -q 'development/guide.md' \"$R2/docs/patterns/crlf.md\" && [ \"\$(tr -cd '\r' < \"$R2/docs/patterns/crlf.md\" | wc -c | tr -d ' ')\" -eq 3 ]"
check "the tally line counts the report-only links" "printf '%s\n' \"\$OUTF\" | grep -qE '^LINKS: [0-9]+ broken, 3 fixed, 7 report-only$'"
check "only the three ordinary docs changed" \
  "[ \"\$(git -C \"$R2\" diff --name-only | sort | tr '\n' ' ')\" = 'docs/patterns/crlf.md docs/patterns/fence.md docs/patterns/p.md ' ]"

# The conventions document teaches link syntax with examples in backticks. Resolved from docs/acf/,
# they read as 7 broken links on every fresh project, and --fix "repaired" three of them into wrong
# examples, which also made the pristine copy look edited and switched off its template refresh.
echo "== 6. a fresh project's installed conventions survive link-check --fix untouched"
HOOK="$ROOT/hooks/handlers/session-start.py"
R3="$WORK/fresh"; newrepo "$R3"
if command -v python3 >/dev/null 2>&1; then
  (cd "$R3" && echo '{}' | "$HOOK" >/dev/null)
  echo '# hub' > "$R3/docs/README.md"                  # gives the backticked README.md example one match
  commit_all "$R3"
  check "the hook installed the conventions (fixture sanity)" "[ -f \"$R3/docs/acf/organization.md\" ]"
  OUTR3=$(cd "$R3" && fix_mode=true bash "$LNK" 2>&1)
  check "nothing under docs/acf changed" "git -C \"$R3\" diff --quiet -- docs/acf"
  check "no BROKEN line names docs/acf/organization.md" "! printf '%s' \"\$OUTR3\" | grep -q '^BROKEN: docs/acf/organization.md'"
  check "the tally is clean" "printf '%s\n' \"\$OUTR3\" | grep -qx 'LINKS: 0 broken, 0 fixed, 0 report-only'"
else
  echo "  SKIP: python3 not installed"
fi

echo "== 7. inline code spans are examples; plugin-installed documents are report-only"
R4="$WORK/spans"; newrepo "$R4"
mkdir -p "$R4/docs/agents/universal" "$R4/docs/patterns" "$R4/docs/acf/git" "$R4/docs/acf/backlog" "$R4/docs/acf/custom"
echo '# moved' > "$R4/docs/agents/universal/moved.md"
# Same link as a code span and in prose, on ONE line: the prose copy is fixed, the example is not.
printf '# S\n\nWrite `[moved](../agents/moved.md)` like [moved](../agents/moved.md).\nAlso ``[x](gone.md)`` and `unclosed [y](../agents/moved.md)\n' > "$R4/docs/patterns/s.md"
LNK_ORG='[moved](../agents/moved.md)'
printf '# Org\n\n%s (a team edit)\n' "$LNK_ORG" > "$R4/docs/acf/organization.md"
printf '# Git\n\n%s\n' "$LNK_ORG" > "$R4/docs/acf/git/commit-conventions.md"
printf '# WF\n\n%s\n' "$LNK_ORG" > "$R4/docs/acf/backlog/workflow.md"
printf '<!-- acf-whip-artifact: content/x.md sha256:abc -->\n# X\n\n%s\n' "$LNK_ORG" > "$R4/docs/acf/custom/stamped.md"
printf '# Mine\n\n%s\n' "$LNK_ORG" > "$R4/docs/acf/custom/mine.md"
commit_all "$R4"
OUTS=$(cd "$R4" && fix_mode=true bash "$LNK" 2>&1)
check "the prose link beside a code span is fixed and the code span is not" \
  "[ \"\$(sed -n 3p \"$R4/docs/patterns/s.md\")\" = 'Write \`[moved](../agents/moved.md)\` like [moved](../agents/universal/moved.md).' ]"
check "a double-backtick span is skipped (gone.md is never reported)" "! printf '%s' \"\$OUTS\" | grep -q 'gone.md'"
check "an unclosed backtick is literal text, so the link after it is a real link and is fixed" \
  "[ \"\$(sed -n 4p \"$R4/docs/patterns/s.md\")\" = 'Also \`\`[x](gone.md)\`\` and \`unclosed [y](../agents/universal/moved.md)' ]"
for d in docs/acf/organization.md docs/acf/git/commit-conventions.md docs/acf/backlog/workflow.md docs/acf/custom/stamped.md; do
  check "$d is report-only and unchanged" \
    "git -C \"$R4\" diff --quiet -- $d && printf '%s\n' \"\$OUTS\" | grep -A1 '^BROKEN: $d' | grep 'REPORT-ONLY' | grep -q 'plugin-installed'"
done
check "non-vacuity: an ordinary doc under docs/acf/ is still fixed" \
  "grep -qF '[moved](../../agents/universal/moved.md)' \"$R4/docs/acf/custom/mine.md\""

# A lesson's slug is its identity: /retro rewrites the same slug to update one. The audit renaming
# api-v2beta.md to apibeta.md made the next /retro write api-v2beta.md again: one rule, two files.
echo "== 8. lessons: the timeless rule is reported, never fixed"
TCK="$WORK/acf-timeless.sh"; block acf-timeless-check > "$TCK"
LCK="$WORK/lesson-check.sh"; block lesson-check > "$LCK"
check "both blocks are present in SKILL.md" "[ -s \"$TCK\" ] && [ -s \"$LCK\" ]"
check "lesson-check uses the audit's exact timeless regex" "grep -qF \"grep -qE '[0-9]{8}|-v[0-9]+'\" \"$LCK\""
check "lesson-check contains no mv, rm, mkdir or write redirection" \
  "! grep -qE '(^|[^a-z])(mv|rm|mkdir|git mv)[[:space:]]|>[[:space:]]*\"?docs/' \"$LCK\""
R5="$WORK/lessons"; newrepo "$R5"; mkdir -p "$R5/docs/acf/lessons/deep"
for s in good-lesson api-v2beta auth-v1x 20260101-foo Bad_Slug; do printf '# L\n**Rule**: r\n' > "$R5/docs/acf/lessons/$s.md"; done
printf '# L\n' > "$R5/docs/acf/lessons/deep/x-v3.md"
printf '# A\n' > "$R5/docs/acf/architecture-v2.md"
commit_all "$R5"
OUTT=$(cd "$R5" && bash "$TCK" 2>&1); OUTL=$(cd "$R5" && bash "$LCK" 2>&1)
check "the docs/acf/ scan still flags an ordinary versioned doc (non-vacuity)" \
  "printf '%s\n' \"\$OUTT\" | grep -qx 'VIOLATION: docs/acf/architecture-v2.md (has date or version)'"
check "...and never lists a lesson, so none reaches Step 8C's rename" "! printf '%s' \"\$OUTT\" | grep -q lessons"
for s in api-v2beta auth-v1x 20260101-foo; do
  check "lesson $s.md is reported as a date or version" \
    "printf '%s\n' \"\$OUTL\" | grep -q '^REPORT: docs/acf/lessons/$s.md (lesson slug has a date or version'"
done
check "a nested lesson-folder file is reported too" "printf '%s\n' \"\$OUTL\" | grep -q '^REPORT: docs/acf/lessons/deep/x-v3.md'"
check "a bad slug shape is reported" "printf '%s\n' \"\$OUTL\" | grep -q '^REPORT: docs/acf/lessons/Bad_Slug.md (lesson slug must be lowercase'"
check "a slug that breaks both rules names both, in one line" \
  "[ \"\$(printf '%s\n' \"\$OUTL\" | grep -c '20260101-foo')\" -eq 1 ] && printf '%s\n' \"\$OUTL\" | grep '20260101-foo' | grep -q 'date or version; must be lowercase'"
check "exactly five lessons reported" "[ \"\$(printf '%s\n' \"\$OUTL\" | grep -c '^REPORT:')\" -eq 5 ]"
check "a good slug is silent" "! printf '%s' \"\$OUTL\" | grep -q good-lesson"
# Step 8C is a template the model fills; run it with a list that (wrongly) holds a lesson.
FIXC="$WORK/fix-c.sh"
{ echo 'timeless_violations=(docs/acf/lessons/api-v2beta.md docs/acf/architecture-v2.md)'
  awk '/^### C\. Fix Timeless Naming Violations/{on=1} on && /^```bash$/{inb=1; next} inb && /^```$/{exit} inb' "$SKILL"; } > "$FIXC"
OUTC8=$(cd "$R5" && bash "$FIXC" 2>&1)
check "Step 8C skips a lesson even when one reaches its list" \
  "[ -f \"$R5/docs/acf/lessons/api-v2beta.md\" ] && [ ! -e \"$R5/docs/acf/lessons/apibeta.md\" ] && printf '%s' \"\$OUTC8\" | grep -q 'Report only: docs/acf/lessons/api-v2beta.md'"
check "...and still renames an ordinary doc, on this platform's sed" \
  "[ -f \"$R5/docs/acf/architecture.md\" ] && [ ! -e \"$R5/docs/acf/architecture-v2.md\" ]"

echo
echo "conventions: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
