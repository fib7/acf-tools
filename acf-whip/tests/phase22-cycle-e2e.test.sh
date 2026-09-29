#!/usr/bin/env bash
# phase22-cycle-e2e.test.sh: one whole planned cycle, end to end, through the shipped scripts only
# (acf-whip 3.5.0: PLAN -> DECOMPOSE -> BUILD -> VERIFY -> RETRO), on the files store and on the
# offline multica fake.
#
# WHY THIS EXISTS. phase20 pins each acfw-cycle verb, phase21 each acfw-spec verb, phase20-task-plan the
# /task --plan workflow, phase8 the integrator. Each builds its own fixture state (a record.md written by
# hand, a fake acfw-cycle, a task file with no history). The seams BETWEEN them are what a user walks
# through, and no per-verb suite crosses them: the bytes a spec tool reviewed are the bytes approve
# commits; the frozen copy /task decomposes is that commit's plan; the stems `record` writes are the ones
# the store creates and the focus names; the counters /go charges are the ones `triggers` reads; the
# lesson `close` commits is the one the next planner prints. A drift at any seam passes every per-verb
# suite. This one runs the cycle the way the skills drive it, on real git history, and checks each
# hand-off with what an operator or a skill acts on: NEXT lines, machine lines, exit codes, commit
# subjects, commit paths, and record.md rows (newest first).
#
# HOW EACH STAGE IS DRIVEN (no model anywhere):
#   PLAN      the calls /whip makes: acfw-spec add (the --tools add path, which probes, trusts and
#             commits), acfw-cycle init / status / approve, acfw-spec review / push / pull, with the dir
#             workbench and the no-tbd block tool from spec-tools/.
#   DECOMPOSE the REAL whip-task.workflow.js under node with a mock runtime. Judgement agents (planner,
#             critic, author) answer fixed content; every shell-tier agent (registry + check, task review,
#             writer, doctor) EXECUTES the commands its prompt lists, in the prompt's order, the way a
#             shell-tier model does. So record-first, the Documentation stamp and the focus set are what
#             whip-task tells its writer today, never a copy in this file that could drift from it.
#   BUILD     /go is not replayed as a workflow (its agents write code). Its effects are: acfw-store
#             transition with whip-go's argument shapes and state order, clean-checkout.sh for each
#             specialist (a real worktree and branch), a real commit on that branch, and integrate-lpcas.sh
#             on each accepted task, which lands the change and its ledger marker on trunk.
#   VERIFY    acfw-cycle status (the coverage table), and /go's nextStep: status --if-cycle --after-run.
#   RETRO     the /retro skill's own steps: its retro-status, retro-gather and retro-verify blocks (cut
#             from SKILL.md by the markers phase17 uses) around acfw-cycle triggers, retro-begin, the
#             agent's init --kind retro-actions, and close. Then lessons, and a second /task --plan (the
#             retro-actions cycle) whose planner runs the lessons command it is told to run.
#
# TWO STEPS OFF THE HAPPY PATH, both things an operator does while a background run writes at the trunk
# root: an untracked draft of the next idea sits there through /go (it must survive every landing and
# never take NEXT), and an amendment of the approved plan is STAGED during /go and during /task --plan
# (approval binds the bytes at HEAD, so no writer but approve may commit plan.md; each writer that does
# fails exactly the checks written for it, and the approved bytes are put back so the cycle goes on).
#
# WHY BOTH BACKENDS. They differ exactly where the cycle is fragile: a raw adapter's `snapshot --only`
# drops accepted tasks from tasks[], so coverage and triggers must come from scope.resolved, the LP-CAS
# ledger and per-stem reads. A files-only e2e would pass a status that calls every finished multica task
# a phantom.
#
# A step that fails because of a PRODUCT bug keeps its assertion: this file says what the product must do.
#
# Needs git, jq, node and perl (all offline). Engines run under /bin/bash (3.2 on macOS).
# Run: bash acf-whip/tests/phase22-cycle-e2e.test.sh      (P22_ONLY=files|multica runs one backend)

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ACF_WHIP/skills/lib/bin"
CYCLE="$BIN/acfw-cycle"
SPEC="$BIN/acfw-spec"
STORE_BIN="$BIN/acfw-store"
CLEANCO="$ACF_WHIP/skills/clean-checkout-before-task/bin/clean-checkout.sh"
INTEG="$ACF_WHIP/skills/integrate-lpcas/bin/integrate-lpcas.sh"
WF_TASK="$ACF_WHIP/workflows/whip-task.workflow.js"
SH=/bin/bash; [ -x "$SH" ] || SH=$(command -v bash)
CALL_TIMEOUT="${P22_TIMEOUT:-180}"
EMAIL="dev@example.com"

PASS=0 FAIL=0
LAST="" RC="" OUT="" ERR=""
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){
  FAIL=$((FAIL+1)); echo "  FAIL: $1"
  # What the engine actually answered, so a failure report is actionable without a rerun.
  [ -n "$LAST" ] && echo "        last: $LAST -> rc=${RC:-?} | $(printf '%s\n%s\n' "$OUT" "$ERR" | grep -v '^[[:space:]]*$' | head -6 | tr '\n' '|' | cut -c1-500)"
}
t(){ local l="$1"; shift; if "$@"; then ok "$l"; else bad "$l"; fi; }

# Counted, never skipped: a suite that ends "N passed, 0 failed" without having run is green by absence.
for need in git jq node perl; do
  command -v "$need" >/dev/null 2>&1 || { echo "FATAL: $need is required (the cycle's store verbs, the multica fake and the whip-task runtime need it)"; echo "phase22-cycle-e2e: 0 passed, 1 failed"; exit 1; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p22.XXXXXX") || exit 1
WORK=$(cd "$WORK" && pwd -P)   # physical: the engines print absolute paths that are compared byte for byte
# P22_KEEP=1 keeps the scratch repos and $WORK/trace.log (every call with its exit code and output), so a
# passing run can be read back against what the engines really printed.
if [ -n "${P22_KEEP:-}" ]; then trap 'echo "kept: $WORK"' EXIT; else trap 'cd /; rm -rf "$WORK"' EXIT; fi
# Nothing from the operator's shell may steer the engines.
for v in $(env | sed -n 's/^\(ACFW_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(MC_FAKE_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
unset CLAUDE_PLUGIN_ROOT GAPTRAP_API_KEY 2>/dev/null || true
export GIT_EDITOR=true GIT_TERMINAL_PROMPT=0 GIT_CEILING_DIRECTORIES="$WORK" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$WORK/nohooks"

. "$ACF_WHIP/tests/fixtures/multica-fake.sh"
multica_fake_install "$WORK/multica-fake"

# X <cmd...>: run with a per-call alarm (a hung engine fails the suite instead of stalling run-all) and
# stdin closed. Sets RC, OUT, ERR, LAST.
X(){
  LAST="$*"
  perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$CALL_TIMEOUT" "$@" </dev/null >"$WORK/x.out" 2>"$WORK/x.err"; RC=$?
  OUT=$(cat "$WORK/x.out"); ERR=$(cat "$WORK/x.err")
  [ -n "${P22_KEEP:-}" ] && printf '\n$ %s\nrc=%s\n%s\n--- stderr\n%s\n' "$*" "$RC" "$OUT" "$ERR" >> "$WORK/trace.log"
  return 0
}
cy(){ X "$SH" "$CYCLE" "$@"; LAST="acfw-cycle $*"; }
sp(){ X "$SH" "$SPEC" "$@"; LAST="acfw-spec $*"; }
st(){ X "$SH" "$STORE_BIN" "$@"; LAST="acfw-store $*"; }
sq_(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }   # one shell word
# skill_block <skill> <block> <prelude>: run one self-contained block of a shipped SKILL.md (the lines
# between "# >>> <block>" and "# <<< <block>", the same markers phase17 runs) the way the session runs
# it: from the repo root, with B at the plugin's bin, after that step's own variable lines. A block
# that is gone runs as an empty script, and the assertions on its output fail.
skill_block(){
  local f="$ACF_WHIP/skills/$1/SKILL.md" s="$WORK/skill.$2.sh"
  { printf 'cd %s || exit 1\nB=%s\n%s\n' "$(sq_ "$REPO")" "$(sq_ "$BIN")" "$3"
    sed -n "/^# >>> $2 /,/^# <<< $2\$/p" "$f"; } > "$s"
  X "$SH" "$s"; LAST="/$1 skill block $2"
}

rc(){ [ "${RC:-x}" = "$1" ]; }
has_line(){ printf '%s\n' "$OUT" | grep -qxF -- "$1"; }
has_re(){ printf '%s\n' "$OUT" | grep -qE -- "$1"; }
line1(){ printf '%s\n' "$OUT" | head -1; }
line1_is(){ [ "$(line1)" = "$1" ]; }
lastl(){ printf '%s\n' "$OUT" | awk 'NF{l=$0} END{print l}'; }
nextl(){ printf '%s\n' "$OUT" | grep '^NEXT ' || true; }
# next_is: exactly one NEXT line, it is the last non-empty line, and it says exactly this.
next_is(){ [ "$(nextl | grep -c .)" = 1 ] && [ "$(nextl)" = "$1" ] && [ "$(lastl)" = "$1" ]; }
# inv: the status invariants every rendering holds (INTERFACES): one NEXT, last; then NEED YOU: nothing
# or at least one complete WHAT/RISK/REPLY card.
inv(){
  local w r p
  [ "$(nextl | grep -c .)" = 1 ] || return 1
  case "$(lastl)" in "NEXT "*) ;; *) return 1 ;; esac
  printf '%s\n' "$OUT" | grep -q '^NEED YOU: nothing$' && return 0
  w=$(printf '%s\n' "$OUT" | grep -c '^  WHAT ' || true); r=$(printf '%s\n' "$OUT" | grep -c '^  RISK ' || true)
  p=$(printf '%s\n' "$OUT" | grep -c '^  REPLY ' || true)
  [ "${w:-0}" -ge 1 ] && [ "$w" = "$r" ] && [ "$w" = "$p" ]
}
reply_is(){ printf '%s\n' "$OUT" | grep -qxF -- "  REPLY $1"; }
# cov <Dn> <symbol>: Dn's coverage line carries this symbol and no contradicting one.
cov(){
  local l x
  l=$(printf '%s\n' "$OUT" | grep -E "^    $1 ") || return 1
  printf '%s\n' "$l" | grep -qF -- "$2" || return 1
  for x in ✓ ◐ ✗; do [ "$x" = "$2" ] && continue; printf '%s\n' "$l" | grep -qF -- "$x" && return 1; done
  return 0
}

# The content hash as the contract defines it (CRLF->LF, trailing whitespace stripped, trailing blank
# lines dropped, one final newline, git's blob hash), computed HERE so every content= is checked, never
# echoed back.
c12(){ awk '{ sub(/\r$/, ""); sub(/[ \t]+$/, ""); a[NR] = $0 } END { n = NR; while (n > 0 && a[n] == "") n--; for (i = 1; i <= n; i++) print a[i] }' "$1" | git hash-object --stdin | cut -c1-12; }

g(){ git -C "$REPO" "$@"; }
subj(){ g log -1 --format=%s "${1:-HEAD}"; }
subj_is(){ [ "$(subj "${2:-HEAD}")" = "$1" ]; }
paths_of(){ g diff-tree --no-commit-id --name-only -r --root "${1:-HEAD}" | LC_ALL=C sort | paste -sd' ' -; }
paths_are(){ local c="$1"; shift; [ "$(paths_of "$c")" = "$(printf '%s\n' "$@" | LC_ALL=C sort | paste -sd' ' -)" ]; }
trailer_is(){ g log -1 --format=%B "$1" | grep -qx "ACFW-Plan-Event: $2"; }
head_is(){ [ "$(g rev-parse HEAD)" = "$1" ]; }
hrec(){ g show "HEAD:$1" 2>/dev/null; }
meta(){ sed -n "s/^- \*\*$1\*\*:[[:space:]]*//p" | head -1 | sed 's/[[:space:]]*$//'; }
hmeta(){ hrec "$1" | meta "$2"; }
section(){ awk -v h="## $1" '$0==h{f=1;next} f&&/^## /{f=0} f'; }
rows(){ section "$1" | grep '^|' | sed '1,2d'; }
cell(){ awk -F'|' -v n="$1" '{ c=$(n+1); gsub(/^[ \t]+|[ \t]+$/, "", c); print c }'; }
# The Plan Log at HEAD: its Event column top to bottom, and whether its timestamps never increase
# downward (newest first).
log_events(){ hrec "$1" | rows 'Plan Log' | cell 2 | paste -sd, -; }
log_newest_first(){ hrec "$1" | rows 'Plan Log' | cell 1 | awk 'NR > 1 && $0 > p { bad = 1 } { p = $0 } END { exit bad }'; }
log_row(){ hrec "$1" | rows 'Plan Log' | awk -F'|' -v e="$2" '{ c = $3; gsub(/^[ \t]+|[ \t]+$/, "", c) } c == e { print; exit }'; }
tasks_rows(){ hrec "$1" | rows Tasks | paste -sd'#' -; }

# =====================================================================================================
# The /task --plan runtime: the real workflow, shell-tier agents executing their own prompt.
# =====================================================================================================
cat > "$WORK/whip-task-run.mjs" <<'NODE'
// Runs whip-task.workflow.js the way the Workflow tool does, with agent() answered here.
//  * judgement agents (recon, planners, judge, critic, authors) answer fixed content from WT_TASKS;
//  * shell-tier agents run the commands their prompt lists, in the prompt's own order, with the
//    prompt's own `export ACFW_...;` environment line, and relay what those commands printed.
// Env: WT_SRC (workflow), WT_ARGS (JSON), WT_TASKS (JSON stubs), WT_OUT (result file), WT_CYCLE.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
const BASH = existsSync('/bin/bash') ? '/bin/bash' : 'bash'
const src = readFileSync(process.env.WT_SRC, 'utf8')
const args = JSON.parse(process.env.WT_ARGS)
const stubs = JSON.parse(process.env.WT_TASKS)
const repo = args.trunkRoot
const res = { ran: [], labels: [], check: '', check2: null, lessons: null, reviewLines: [], writer: [], errors: [] }
const envOf = (p) => ((p.match(/export ACFW_TRUNK_ROOT='[^']*'; export ACFW_TRUNK_BRANCH='[^']*'; export ACFW_STORE='[^']*';/) || [''])[0])
function sh(label, cmd, env) {
  const r = spawnSync(BASH, ['-c', `${env || ''}\n${cmd}`], { cwd: repo, env: process.env, encoding: 'utf8', timeout: 300000 })
  const o = { label, cmd, code: r.status, out: r.stdout || '', err: r.stderr || '' }
  res.ran.push(o)
  return o
}
const one = (p, re, label) => { const m = p.match(re); if (!m) { res.errors.push(`${label}: no command matching ${re} in its prompt`); return '' } return m[1] }
// Every command a writer prompt lists, in prompt order. Each pattern is one kind of line the writers
// render (record, file moves, the two stamps, the .gitignore guard, stage, commit, creates, focus); the
// order is the prompt's, found by position, never this file's.
function writerCmds(p) {
  const found = []
  const add = (re) => { for (const m of p.matchAll(re)) found.push({ at: m.index + m[0].indexOf(m[1]), cmd: m[1] }) }
  add(/^ *(cd '[^\n]*acfw-cycle' record [^\n]*)$/gm)
  add(/^ {3}(\[ -e '[^\n]*mv -f [^\n]*)$/gm)
  add(/^ {3}(if grep -qE '\^- \\\*\\\*(?:Dependencies|Documentation)\\\*\\\*:'[\s\S]*?rm -f '[^'\n]*\.bak')$/gm)
  add(/^ *((?:cd '[^'\n]*' && )?grep -qxF '\.acfwhip\/run\/' \.gitignore[\s\S]*?>> \.gitignore)$/gm)
  add(/:  (\[ -e '[^'\n]*' \] && git (?:add|commit) [^\n]*)$/gm)
  for (const part of p.split('\n  cd ').slice(1)) {
    const cmd = `cd ${part.split('\n\n')[0]}`
    if (/acfw-store' create /.test(cmd)) found.push({ at: p.indexOf(cmd), cmd })
  }
  add(/^ *(\[ -e '[^\n]*acfw-focus' set [^\n]*)$/gm)
  return found.sort((a, b) => a.at - b.at).map((f) => f.cmd)
}
async function agent(prompt, opts) {
  const label = (opts && opts.label) || ''
  const p = String(prompt)
  const env = envOf(p)
  res.labels.push(label)
  if (label === 'discover-agents') {
    const ls = sh(label, one(p, /^ *(ls -1 [^\n]*)$/m, label), env)
    const chk = sh(label, one(p, /^ *(cd '[^\n]*acfw-cycle' check [^\n]*)$/m, label), env)
    res.check = chk.out.trim()
    // While this run holds the decomposition lock: a second /task --plan of the same cycle, and a bare
    // /whip (what the operator sees meanwhile).
    if (/^CHECK\|go\|/.test(res.check)) {
      res.check2 = sh('concurrent-check', `bash '${process.env.WT_CYCLE}' check '${args.planPath}'`, env)
      res.statusDuring = sh('status-during', `bash '${process.env.WT_CYCLE}' status`, env)
    }
    const r = { agents: ls.out.split('\n').filter(Boolean), check: chk.out }
    const spec = (p.match(/^ *(cd '[^\n]*list --at task --machine[^\n]*)$/m) || [])[1]
    if (spec) r.specTools = sh(label, spec, env).out.split('\n').filter(Boolean)
    return r
  }
  if (label === 'recon:backlog') return { ids: [], slugsInUse: [], liveBranches: [], note: '' }
  if (label === 'recon:surface') return { modules: ['src/**'], testLayout: 'tests/ next to the code', note: '' }
  if (label === 'recon:conventions') return { agents: ['python-engineer: all code'], gateCommands: 'true', styleNotes: 'WHAT/WHY only', note: '' }
  if (/^plan:/.test(label)) {
    // The planner is told to run the lessons command itself; it does, as a planner would.
    const lc = (p.match(/Run `([^`]*acfw-cycle' lessons)`/) || [])[1]
    if (lc) res.lessons = sh('planner:lessons', lc, env)
    else res.errors.push('the planner prompt names no acfw-cycle lessons command')
    return { summary: 'fixed decomposition', tasks: JSON.parse(JSON.stringify(stubs)) }
  }
  if (label === 'judge:plan') return { choice: 0, reason: 'one planner' }
  if (label === 'critic:completeness') return { defects: [] }
  if (/^author:/.test(label)) {
    const id = label.slice('author:'.length)
    const t = stubs.find((s) => s.id === id)
    const m = p.match(/Write the file at '([^']*)'\/(\S*)\/<filename>/)
    if (!t || !m) { res.errors.push(`${label}: no stub or no target directory`); return { id, filename: `${id}.md`, written: false, note: 'mock could not write' } }
    const dir = `${m[1]}/${m[2]}`
    mkdirSync(dir, { recursive: true })
    // A sloppy author on purpose: Dependencies and Documentation say "none". The writer's stamps are
    // what must put the validated graph and the plan reference there.
    writeFileSync(`${dir}/${id}.md`, [
      `# Task: ${t.title}`, '', '## Metadata', '', `- **ID**: ${id}`, '- **Status**: pending', `- **Priority**: ${t.priority}`,
      `- **Estimated Hours**: ${t.estimatedHours}`, `- **Assigned Agent**: ${t.assignedAgent}`, `- **Worktree**: ${t.worktreeSlug}`,
      `- **PR Group**: ${t.prGroup}`, `- **Touches Globs**: ${t.touchesGlobs.join(', ')}`, '- **Dependencies**: none', '- **Integrated-At**:',
      '- **Rejection Count**: 0', '- **Created By**: task-engineer', '- **Created At**: 2026-09-29 10:00:00 UTC', '- **Documentation**: none', '',
      '## Description', '', `${t.what}. ${t.why}.`, '', '## Acceptance Criteria', '', '- [ ] the outcome above holds', '- [ ] all tests pass', '',
      '## Technical Requirements', '', `- ${t.constraints}`, '', '## Edge Cases to Handle', '', '- an empty workspace', '',
      '## Out of Scope', '', `- ${t.outOfScope}`, '', '## Transition Log', '',
      '| Date Time | From | To | Agent | Reason/Comment |', '| --------- | ---- | -- | ----- | -------------- |',
      '| 2026-09-29 10:00:00 | draft | pending | task-engineer | Initial task creation |', ''].join('\n'))
    return { id, filename: `${id}.md`, written: true, note: 'ok' }
  }
  if (/^review:task/.test(label)) {
    const o = sh(label, one(p, /^ *(cd '[^\n]*review --stage task --machine[^\n]*)$/m, label), env)
    res.reviewLines = o.out.split('\n').filter(Boolean)
    return { lines: res.reviewLines }
  }
  if (label === 'write:commit' || label === 'write:ingest') {
    const outs = writerCmds(p).map((c) => { const o = sh(label, c, env); res.writer.push(o); return o })
    const all = outs.map((o) => o.out).join('')
    const rec = outs.find((o) => /acfw-cycle' record /.test(o.cmd))
    const head = sh(label, 'git rev-parse HEAD', env).out.trim()
    return {
      committed: outs.every((o) => o.code === 0), commitSha: label === 'write:commit' ? head : 'n/a', files: [], note: '',
      record: rec ? ((rec.out.match(/^(RECORD\|.*|LOCK\|lost\|.*)$/m) || [])[1] || (rec.out + rec.err).trim()) : '',
      dropped: [...all.matchAll(/^DROPPED\|(\S+)$/gm)].map((m) => m[1]),
    }
  }
  if (label === 'verify:doctor') {
    const rel = (p.match(/(if grep -qx 'ts=[^\n]*?; fi)/) || [])[1]
    if (rel) sh('release', rel, env)
    const d = sh(label, one(p, /run exactly:  (bash '[^\n]*' doctor)$/m, label), env)
    const lines = d.out.split('\n')
    const summaryLine = lines.find((l) => /^SUMMARY\|/.test(l)) || ''
    return { ok: /\|ok=true/.test(summaryLine), summaryLine, fatals: lines.filter((l) => /^FATAL\|/.test(l)), warns: lines.filter((l) => /^(WARN|REPAIRABLE)\|/.test(l)) }
  }
  if (label === 'cycle:unlock') { const c = (p.match(/(if grep -qx 'ts=[^\n]*?; fi)/) || [])[1]; if (c) sh(label, c, env); return 'done' }
  throw new Error(`unmocked agent label "${label}"`)
}
const parallel = async (thunks) => { const out = []; for (const f of thunks) { try { out.push(await f()) } catch (e) { res.errors.push(String(e && e.message || e)); out.push(null) } } return out }
const run = new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow',
  `return (async () => {\n${src.replace(/^export const meta/m, 'const meta')}\n})()`)
try {
  res.report = await run(agent, parallel, async () => { throw new Error('pipeline not expected') }, () => {}, () => {}, args, undefined,
    async () => { throw new Error('workflow not expected') })
} catch (e) { res.errors.push(`the workflow threw: ${e && e.stack || e}`) }
writeFileSync(process.env.WT_OUT, JSON.stringify(res, null, 1))
NODE

# task_plan <plan-ref> <stubs-json>: one /task --plan, launched with the args the /task skill passes.
# Sets WTJ (the result file). The skill's own pre-launch probe decides specTaskTools.
N_WT=0
task_plan(){
  local n
  N_WT=$((N_WT + 1)); WTJ="$WORK/wt.$STORE_NAME.$N_WT.json"
  n=$("$SH" "$SPEC" list --at task --machine 2>/dev/null | grep -c '^TOOL|')
  WT_SRC="$WF_TASK" WT_CYCLE="$CYCLE" WT_TASKS="$2" WT_OUT="$WTJ" \
  WT_ARGS=$(jq -cn --arg p "$1" --arg pr "$ACF_WHIP" --arg tr "$REPO" --arg st "$STORE_NAME" --argjson n "$n" \
    '{planPath: $p, pluginRoot: $pr, trunkRoot: $tr, trunkBranch: "trunk", store: $st, planners: 1} + (if $n > 0 then {specTaskTools: $n} else {} end)') \
    perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' 600 node "$WORK/whip-task-run.mjs" </dev/null >"$WORK/wt.out" 2>&1
  RC=$?; LAST="whip-task --plan $1"; OUT=$(cat "$WORK/wt.out"); ERR=""
  [ -f "$WTJ" ] || { echo '{"errors":["no result file"]}' > "$WTJ"; }
}
wt(){ jq -r "$1" "$WTJ" 2>/dev/null; }
wt_no_errors(){ [ "$(wt '.errors | length')" = 0 ]; }
# The writer's commands, as it ran them: the index of the first one matching a regex (jq's), or -1.
RE_RECORD="acfw-cycle' record "
RE_CREATE="acfw-store' create "
RE_MUTATE="acfw-store' create |git add |git commit |mv -f |acfw-focus' set "
wr_first(){ wt "[.writer[].cmd | test(\"$1\")] | index(true) // -1"; }
# Record-first is an ORDER, and the writers differ in what else they run first (the multica writer
# checks .gitignore before recording): the record must precede every command that makes a task exist
# or points the focus at one.
record_first(){ local r m; r=$(wr_first "$RE_RECORD"); m=$(wr_first "$RE_MUTATE"); [ "${r:--1}" -ge 0 ] && [ "${m:--1}" -gt "$r" ]; }

# =====================================================================================================
# /go, replayed: whip-go's single writer (acfw-store transition, same argument shapes and state order),
# clean-checkout.sh for each specialist, a real commit on the task branch, integrate-lpcas.sh when a
# code task is accepted in default mode.
# =====================================================================================================
go_tr(){ # <stem> <to> <agent> <notes> <rinc> <binc>
  st transition "$@"
  rc 0 || bad "/go writer: transition $1 -> $2 exited $RC"
}
taskloc(){ # <stem> <folder>: where whip-go hands the task document to an agent (its taskLoc)
  if [ "$STORE_NAME" = files ]; then printf '%s\n' "$REPO/.backlog/$2/$1.md"
  else st read --materialize "$REPO/.acfwhip/specs" "$1"; printf '%s\n' "$OUT" | tail -1; fi
}
go_build(){ # <stem> <attempt>: dispatch, the specialist's worktree and commit, completion, review dispatch
  local s="$1" n="$2" loc wtp slug
  go_tr "$s" in-progress orchestrator dispatch 0 0
  loc=$(taskloc "$s" in-progress)
  X env ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk "$SH" "$CLEANCO" "$loc"; LAST="clean-checkout.sh $s"
  rc 0 || { bad "/go specialist: clean-checkout for $s exited $RC"; return 1; }
  wtp=$(printf '%s\n' "$OUT" | tail -1)
  slug=$(sed -n 's/^- \*\*Worktree\*\*:[[:space:]]*//p' "$loc" | head -1 | tr -d '[:space:]')
  mkdir -p "$wtp/src/$slug" && printf 'attempt %s of %s\n' "$n" "$s" > "$wtp/src/$slug/impl.txt"
  { git -C "$wtp" add -- "src/$slug/impl.txt" && git -C "$wtp" commit -q -m "feat($slug): $s, attempt $n"; } >/dev/null 2>&1 \
    || bad "/go specialist: could not commit in the $slug worktree"
  go_tr "$s" completed python-engineer "attempt $n done" 0 0
  go_tr "$s" in-review orchestrator review-dispatch 0 0
}
go_accept(){ # <stem>: the reviewer accepts, then the integrator lands it (default mode, code task)
  local s="$1" loc
  go_tr "$s" accepted python-engineer "every AC holds" 0 0
  loc=$(taskloc "$s" accepted)
  X env ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk "$SH" "$INTEG" "$loc"; LAST="integrate-lpcas.sh $s"
  { rc 0 && has_re "^ACFW-INTEGRATE: integrated key=$s( |\$)"; } || bad "/go integrator: $s did not land (exit $RC)"
}
go_reject(){ go_tr "$1" rejected python-engineer "AC2.1 fails: a dismissed notice comes back after reload" 1 0; }
go_retry(){ go_tr "$1" pending orchestrator "retry (rejection $2/3)" 0 0; }   # whip-go's rejection self-heal
integrated(){ ( . "$ACF_WHIP/skills/lib/acfw-git.sh" && acfw_is_integrated "$REPO" HEAD "$1" ); }
# An approved plan amended and STAGED (git add) at the trunk root while a background run writes there.
# Approval binds the bytes at HEAD, so no writer but approve may commit that file: not_swept holds when
# no commit since <since> touched it. drop_amendment is the operator abandoning the amendment; when a
# writer did sweep it in, the approved bytes (the plan at <since>) go back in a commit of plan.md
# alone, so the rest of the cycle runs on the approved text either way and a defect fails only the
# checks written for it.
not_swept(){ [ -z "$(g log --format=%H "$2..HEAD" -- "$1")" ]; }   # <plan path> <since>
drop_amendment(){
  if not_swept "$1" "$2"; then g reset -q -- "$1" && g checkout -q -- "$1"
  else g show "$2:$1" > "$REPO/$1" && g commit -q -m "docs: restore the approved plan" -- "$1"; fi
}
folder_is(){ st read "$1"; [ "$(printf '%s' "$OUT" | jq -r '.folder // empty' 2>/dev/null)" = "$2" ]; }
field_is(){ st read "$1"; [ "$(printf '%s' "$OUT" | jq -r --arg f "$2" '.fields[$f] // empty | tostring' 2>/dev/null)" = "$3" ]; }
doc_has(){ # <stem> <literal line>: the task document the store keeps carries this exact line
  st read --materialize "$WORK/mat.$STORE_NAME" "$1"; [ -f "$(printf '%s\n' "$OUT" | tail -1)" ] && grep -qxF -- "$2" "$(printf '%s\n' "$OUT" | tail -1)"
}

# =====================================================================================================
# fixtures
# =====================================================================================================
T1=feature-001-notice-banner T2=feature-002-notice-dismiss T3=feature-003-dismiss-audit
stub(){ # <id> <title> <slug> <glob> <deps-json> <what> <D>
  jq -cn --arg id "$1" --arg t "$2" --arg s "$3" --arg gl "$4" --argjson d "$5" --arg w "$6" --arg D "$7" \
    '{id: $id, title: $t, category: ($id | split("-")[0]), priority: "high", assignedAgent: "python-engineer", isCodeMutating: true,
      worktreeSlug: $s, prGroup: $s, touchesGlobs: [$gl], dependencies: $d, estimatedHours: "2", what: $w,
      why: "owners stop paying for seats they did not expect", constraints: "no new dependencies", outOfScope: "email delivery", deliverables: [$D]}'
}
TASKS3="[$(stub $T1 'Seat change banner' notice-ui 'src/notice-ui/**' '[]' 'The banner renders for owners after a seat change' D1),$(stub $T2 'Dismiss the notice' notice-dismiss 'src/notice-dismiss/**' '[]' 'Dismissing hides the notice for the workspace' D2),$(stub $T3 'Audit every dismissal' notice-audit 'src/notice-audit/**' "[\"$T2\"]" 'Each dismissal writes one audit row' D3)]"
TA=test-001-audit-row-sensor
TASKS_RA="[$(stub $TA 'Audit row sensor test' audit-sensor 'tests/audit/**' '[]' 'A test fails when a dismissal writes no audit row' D1)]"

plan_body(){ # <retention line>: the feature plan /whip drafts, with the Assumptions line given
  cat <<EOF
# Seat change notice

## Problem

Workspace owners miss seat changes and are billed for seats they did not expect.

**Actor & trigger**: a workspace owner opens Billing after an admin adds a seat.

## Scope

- Show a notice on the Billing page after a seat change.

## Non-scope

- Email delivery.

## Assumptions

<!-- Defaults chosen for you. Veto any of them on the approval card. -->

$1

## Risks

- The notice query slows the Billing page. Undo: turn the notice off with its flag.

## Deliverables

<!-- D-ids are permanent: new work takes the next unused number, gaps are fine; to drop one, keep its heading and archive its tasks. -->

### D1: Owner sees the notice

- AC1.1: the notice renders for owners after a seat change.

### D2: Owner can dismiss it

- AC2.1: a dismissed notice stays hidden for the workspace.

### D3: Every dismissal is audited

- AC3.1: each dismissal writes exactly one audit row.
EOF
}

new_repo(){ # whip-init, minimally: store folders, one specialist, the pinned mode, the ignores
  local s
  REPO="$WORK/$STORE_NAME-repo"; rm -rf "$REPO"
  git init -q -b trunk "$REPO" || return 1
  g config user.email "$EMAIL"; g config user.name "Dev Example"; g config core.hooksPath "$WORK/nohooks"; g config commit.gpgsign false
  printf '# ACF Whip\n.worktree/\n.backlog/.acfw-run.json\n.acfwhip/run/\n.acfwhip/specs/\n' > "$REPO/.gitignore"
  mkdir -p "$REPO/.claude/agents" "$REPO/.acfwhip"
  printf -- '---\nname: python-engineer\n---\n# python-engineer\n' > "$REPO/.claude/agents/python-engineer.md"
  printf 'ACFW_INTEGRATION_MODE=default\n' > "$REPO/.acfwhip/config"
  set -- .gitignore .claude/agents/python-engineer.md .acfwhip/config
  if [ "$STORE_NAME" = files ]; then
    for s in draft pending in-progress completed in-review accepted rejected blocked archive; do
      mkdir -p "$REPO/.backlog/$s"; : > "$REPO/.backlog/$s/.gitkeep"; set -- "$@" ".backlog/$s/.gitkeep"
    done
  fi
  echo seed > "$REPO/README.md"; set -- "$@" README.md
  g add -- "$@" && g commit -qm "chore: whip-init" || return 1
  export ACFW_TRUNK_ROOT="$REPO"
  export ACFW_WORKBENCH_DIR="$WORK/workbench-$STORE_NAME"; rm -rf "$ACFW_WORKBENCH_DIR"; mkdir -p "$ACFW_WORKBENCH_DIR"
  cd "$REPO" || return 1
}

use_store(){
  STORE_NAME="$1"
  if [ "$1" = multica ]; then
    export ACFW_STORE=multica ACFW_MULTICA_BIN="$WORK/multica-fake" MC_FAKE_STATE="$WORK/multica.state.json"
    printf '{"issues":{},"seq":0}\n' > "$MC_FAKE_STATE"
  else
    unset ACFW_STORE ACFW_MULTICA_BIN MC_FAKE_STATE 2>/dev/null || true
  fi
  echo; echo "################################ store: $1 ################################"
}

# =====================================================================================================
# the cycle
# =====================================================================================================
e2e(){
  local S="[$STORE_NAME]" ID AID P R RA PA C0 C1 H0 H_APPROVE WBF RL FROZEN LOCKP HELD LESSON RULE AC LESSON_SLUG IN DATE GO_NEXT WN NID H_BEFORE_GO H_BEFORE_TASK
  new_repo || { bad "$S fixture: the scratch repo could not be created"; return 1; }

  echo "== $S PLAN: declare the spec tools the way /whip --tools add does =="
  sp add no-tbd
  t "$S acfw-spec add no-tbd: exit 0, committed" eval 'rc 0 && has_re "^ADDED\|no-tbd\|committed\|"'
  t "$S ...its declaration is the shipped example, verbatim" cmp -s "$REPO/.acfwhip/spec-tools/no-tbd" "$ACF_WHIP/spec-tools/examples/no-tbd.example"
  t "$S ...commit 'chore(spec-tools): add no-tbd' carries only the declaration" eval 'subj_is "chore(spec-tools): add no-tbd" && paths_are HEAD .acfwhip/spec-tools/no-tbd'
  sp add dir
  t "$S acfw-spec add dir: exit 0, committed, the probe found ACFW_WORKBENCH_DIR" eval 'rc 0 && has_re "^ADDED\|dir\|committed\|" && has_line "  needs ACFW_WORKBENCH_DIR: set"'
  t "$S ...add trusted both on this machine (no \"run tools\" round needed)" \
    eval 'grep -Eq "^no-tbd [0-9a-f]+\$" "$REPO/.acfwhip/run/spec/trusted" && grep -Eq "^dir [0-9a-f]+\$" "$REPO/.acfwhip/run/spec/trusted"'
  sp list --machine
  t "$S list: dir is a driver workbench, no-tbd a block reviewer at plan and task" \
    eval 'has_line "TOOL|dir|driver|-|advisory|every|30" && has_line "TOOL|no-tbd|review|plan,task|block|every|10"'
  cy status
  t "$S idle: status exits 0 and says /whip \"<goal>\"" eval 'rc 0 && next_is "NEXT /whip \"<goal>\"" && inv'
  t "$S ...and names the declared spec tools as a fact" has_re '^  spec tools: dir\(workbench\) no-tbd\(plan\+task,block,every\)$'

  echo "== $S PLAN: /whip drafts the plan (init, then the session writes plan.md) =="
  H0=$(g rev-parse HEAD)
  cy init seat-notice --kind feature --source "/whip draft" --title "Seat change notice"
  ID=$(line1 | sed -n 's/^INIT|\([^|]*\)|.*/\1/p')
  t "$S init: exit 0, INIT|<YYYYMMDD>-seat-notice|docs/cycles/<ID>/plan.md" \
    eval 'rc 0 && printf "%s" "$ID" | grep -qE "^[0-9]{8}-seat-notice\$" && line1_is "INIT|$ID|docs/cycles/$ID/plan.md"'
  P="docs/cycles/$ID/plan.md"; R="docs/cycles/$ID/record.md"
  t "$S ...nothing committed, the draft folder untracked" eval 'head_is "$H0" && [ -z "$(g ls-files -- docs/cycles)" ]'
  plan_body "- Retention of dismissed notices: TBD." > "$REPO/$P"
  C0=$(c12 "$REPO/$P")

  echo "== $S PLAN: the block reviewer says NO-GO, and the card shows it =="
  sp review "$P"
  t "$S review: exit 0 with the REVIEW block at the plan's content" eval 'rc 0 && has_line "REVIEW spec tools at content=$C0"'
  t "$S ...no-tbd NO-GO, one finding, on the TBD line" \
    eval 'has_re "^  no-tbd \(block, [^)]*\): NO-GO, 1 finding\(s\)\$" && has_re "^  F1 [a-z]+ L[0-9]+ no-tbd: .*TBD"'
  cy status "$ID"
  t "$S status <ID> (the card /whip shows): exit 0, invariants hold" eval 'rc 0 && inv'
  t "$S ...the approval card: content=<c12> and the one-yes REPLY" \
    eval 'has_line "  content=$C0" && reply_is "yes: approve, then start /task --plan in the background (sets your /go focus)"'
  t "$S ...embeds the REVIEW block, indented, with the NO-GO" \
    eval 'has_line "  REVIEW spec tools at content=$C0" && has_re "^    no-tbd \(block, [^)]*\): NO-GO, 1 finding\(s\)\$"'
  t "$S ...NEXT is the approval prompt for exactly those bytes" next_is "NEXT yes: approve $P (content=$C0)"
  t "$S ...coverage lists the 3 deliverables, none decomposed" \
    eval 'has_re "^    D1 · Owner sees the notice" && has_re "^    D2 · " && has_re "^    D3 · "'

  cp "$REPO/$P" "$WORK/plan.before"; cp "$REPO/$R" "$WORK/record.before"
  cy approve "$ID" --expect "$C0"
  t "$S approve over the block tool's NO-GO: refused with 22" rc 22
  t "$S ...the gate names the tool (GATE|unmet|no-tbd|...)" has_re '^GATE\|unmet\|no-tbd\|'
  t "$S ...nothing committed, plan.md and record.md untouched" \
    eval 'head_is "$H0" && cmp -s "$REPO/$P" "$WORK/plan.before" && cmp -s "$REPO/$R" "$WORK/record.before"'

  echo "== $S PLAN: workbench round trip (dir): push, edits on both sides, conflict, --theirs =="
  sp push "$P"
  t "$S push: exit 0, PUSHED|dir|ref=<ID>.md|content=<c12>" eval 'rc 0 && has_line "PUSHED|dir|ref=$ID.md|content=$C0"'
  WBF="$ACFW_WORKBENCH_DIR/$ID.md"
  t "$S ...the workbench copy is the plan, byte for byte" cmp -s "$WBF" "$REPO/$P"
  cy status "$ID"
  t "$S ...status shows the plan OUT in dir" has_re "^  OUT $ID → dir since [0-9]+[mhd], local edits: no"
  cy approve "$ID" --expect "$C0"
  t "$S approve while OUT: refused with 26, nothing committed" eval 'rc 26 && head_is "$H0"'
  # The workbench answers the open question; locally someone rewords the same line and leaves it TBD.
  perl -pi -e 's/^- Retention of dismissed notices: TBD\.$/- Dismissed notices are kept for 30 days./' "$WBF"
  plan_body "- Retention of dismissed notices: TBD, ask legal." > "$REPO/$P"
  cp "$REPO/$P" "$WORK/plan.local"
  sp pull "$P"
  t "$S pull with a conflicting local edit: exit 23 with a CONFLICT|dir|<file> line" eval 'rc 23 && has_re "^CONFLICT\|dir\|.*/$ID\.conflict\.md\$"'
  t "$S ...plan.md untouched" cmp -s "$REPO/$P" "$WORK/plan.local"
  cy status "$ID"
  t "$S ...and the plan is still OUT" has_re "^  OUT $ID → dir "
  sp pull "$P" --theirs
  C1=$(c12 "$REPO/$P")
  t "$S pull --theirs: exit 0, PULLED|dir|theirs|content=<new c12>" eval 'rc 0 && has_line "PULLED|dir|theirs|content=$C1"'
  t "$S ...plan.md now holds the workbench text (the TBD is resolved)" \
    eval 'grep -qxF -- "- Dismissed notices are kept for 30 days." "$REPO/$P" && ! grep -qw TBD "$REPO/$P"'
  t "$S ...the discarded local side is saved as a patch" \
    eval 'grep -lF "TBD, ask legal" "$REPO/.acfwhip/run/workbench/$ID"/discarded-yours-*.patch >/dev/null 2>&1'
  cy status "$ID"
  t "$S ...the pull ended OUT" eval '! has_re "^  OUT $ID "'
  t "$S pull never commits" head_is "$H0"

  echo "== $S PLAN: fresh review, GO; the card binds the new bytes; approve =="
  sp review "$P"
  t "$S review after the pull: no-tbd GO at the new content" \
    eval 'rc 0 && has_line "REVIEW spec tools at content=$C1" && has_re "^  no-tbd \(block, [^)]*\): GO, 0 finding\(s\)\$"'
  cy status "$ID"
  t "$S the card now shows content=<new c12>, the GO, and NEXT approves exactly those bytes" \
    eval 'inv && has_line "  content=$C1" && has_re "^    no-tbd \(block, [^)]*\): GO" && next_is "NEXT yes: approve $P (content=$C1)"'
  cy approve "$ID" --expect "$C0"
  t "$S approve with the OLD card's content: refused with 9 (rule 11), nothing committed" eval 'rc 9 && head_is "$H0"'
  cy approve "$ID" --expect "$C1"
  H_APPROVE=$(g rev-parse HEAD)
  t "$S approve --expect <card content>: exit 0, APPROVE|ok|cycle=<ID>|content=<c12>|commit=<sha12>" \
    eval 'rc 0 && line1_is "APPROVE|ok|cycle=$ID|content=$C1|commit=$(printf %s "$H_APPROVE" | cut -c1-12)"'
  t "$S ...its last line: NEXT /task --plan docs/cycles/<ID>/plan.md" eval '[ "$(lastl)" = "NEXT /task --plan $P" ]'
  t "$S ...one commit 'docs(plan): approve seat-notice' with exactly plan.md and record.md" \
    eval 'subj_is "docs(plan): approve seat-notice" && paths_are HEAD "$P" "$R" && [ "$(g rev-parse HEAD~1)" = "$H0" ]'
  t "$S ...carrying the audit trailer ACFW-Plan-Event: approved <c12> <ID>" trailer_is HEAD "approved $C1 $ID"
  t "$S ...record.md at HEAD: Status approved, Approved By you, Approved Content v1:<c12>" \
    eval '[ "$(hmeta "$R" Status)" = approved ] && [ "$(hmeta "$R" "Approved By")" = "$EMAIL" ] && [ "$(hmeta "$R" "Approved Content")" = "v1:$C1" ]'
  t "$S ...the Plan Log folds every drafting event: approved,reviewed,pulled,pushed,drafted (newest first)" \
    eval '[ "$(log_events "$R")" = "approved,reviewed,pulled,pushed,drafted" ] && log_newest_first "$R"'
  t "$S ...the reviewed row is no-tbd's GO at the approved bytes" eval 'log_row "$R" reviewed | grep -qE "\| reviewed \| no-tbd \| $C1 \| go n=0 \|"'
  t "$S ...the approved row names the deliverables" eval 'log_row "$R" approved | grep -qE "\| approved \| $EMAIL \| $C1 \| ds=D1,D2,D3 \|"'
  t "$S ...no row carries a URL" eval '! hrec "$R" | rows "Plan Log" | grep -q "://"'
  t "$S ...and the folded events left pending.log (a re-approve cannot fold them twice)" \
    eval '[ ! -s "$REPO/.acfwhip/run/cycle/$ID/pending.log" ]'

  echo "== $S DECOMPOSE: /task --plan, the real workflow; its writer runs what the prompt says =="
  task_plan "$P" "$TASKS3"
  t "$S the workflow ran to completion without an unanswered or failed step" \
    eval 'rc 0 && [ "$(wt .report.phase)" = complete ] && wt_no_errors'
  t "$S ...its planner ran the lessons command (none recorded yet: empty, exit 0)" \
    eval '[ "$(wt .lessons.code)" = 0 ] && [ -z "$(wt .lessons.out)" ]'
  FROZEN="$REPO/.acfwhip/run/cycle/$ID/$C1.md"; LOCKP="$REPO/.acfwhip/run/cycle-$ID.decomposing"
  HELD=$(wt '.check' | sed -n 's/.*|held=\([0-9]*\)$/\1/p')
  t "$S check (relayed by discovery): CHECK|go for all three deliverables, with this run's lock stamp" \
    eval '[ "$(wt .check)" = "CHECK|go|cycle=$ID|content=$C1|frozen=$FROZEN|lock=$LOCKP|uncovered=D1,D2,D3|known=D1,D2,D3|coverage=on|kind=feature|held=$HELD" ] && [ -n "$HELD" ]'
  t "$S ...the frozen copy is the approve commit's plan.md, byte for byte" eval 'g show "$H_APPROVE:$P" | cmp -s - "$FROZEN"'
  t "$S ...a second /task --plan meanwhile is refused with 7 and handed the lock's rm override" \
    eval '[ "$(wt .check2.code)" = 7 ] && wt .check2.out | grep -qE "^CHECK\|refuse\|cycle=$ID\|code=7\|reason=.*rm .*cycle-$ID\.decomposing"'
  t "$S ...and a bare /whip meanwhile says wait, with the lock's age and rm override on a card" \
    eval '[ "$(wt .statusDuring.code)" = 0 ] && [ "$(wt .statusDuring.out | grep "^NEXT ")" = "NEXT wait: /task --plan is decomposing $ID (started 0m ago)" ] && wt .statusDuring.out | grep -qxF "  REPLY if that /task is no longer running: rm $LOCKP"'
  t "$S the task-stage review: no-tbd GO on each task (REVIEWED lines), END|lines=3" \
    eval '[ "$(wt ".reviewLines[]" | grep -cE "^REVIEWED\|[a-z0-9-]+\|no-tbd\|block\|go\|0\|")" = 3 ] && wt ".reviewLines[]" | grep -qx "END|lines=3"'
  t "$S writer, record first: acfw-cycle record runs before anything that creates, moves, stages, commits or focuses" record_first
  t "$S ...and answers RECORD|ok|cycle=<ID>|tasks=3" \
    eval 'wt ".writer[$(wr_first "$RE_RECORD")].out" | grep -qx "RECORD|ok|cycle=$ID|tasks=3" && [ "$(wt .report.cycle.recorded)" = true ]'
  # The exact number of commands this runtime found in the writer prompt. A writer step whose line shape
  # it does not recognise would silently not run; the count makes a new or reshaped step fail here, loudly.
  #   files (task tools on, so the staged writer): record, 3 moves, 3+3 stamps, .gitignore, add, commit, focus
  #   multica: .gitignore, record, 3 creates, focus
  WN=14; [ "$STORE_NAME" = files ] || WN=6
  t "$S ...the runtime found exactly the $WN commands this writer lists, and every one exited 0" \
    eval '[ "$(wt ".writer | length")" = "$WN" ] && [ "$(wt "[.writer[] | select(.code != 0)] | length")" = 0 ]'
  t "$S ...its commit 'docs(plan): decompose seat-notice' carries record.md alone, with its trailer" \
    eval 'D=$(g log --format=%H --grep="^docs(plan): decompose seat-notice\$" -1) && [ -n "$D" ] && paths_are "$D" "$R" && trailer_is "$D" "decomposed $C1 $ID"'
  t "$S ...record.md ## Tasks maps each deliverable to its task" \
    eval '[ "$(tasks_rows "$R")" = "| D1 | $T1 |#| D2 | $T2 |#| D3 | $T3 |" ]'
  t "$S ...Status decomposed; the Plan Log grew one row on top: decomposed,approved,..." \
    eval '[ "$(hmeta "$R" Status)" = decomposed ] && [ "$(log_events "$R")" = "decomposed,approved,reviewed,pulled,pushed,drafted" ] && log_newest_first "$R"'
  if [ "$STORE_NAME" = files ]; then
    t "$S ...then one commit 'task: create 3 backlog task(s) [...]' with exactly the three task files" \
      eval 'subj_is "task: create 3 backlog task(s) [notice-ui, notice-dismiss, notice-audit]" && paths_are HEAD .backlog/pending/$T1.md .backlog/pending/$T2.md .backlog/pending/$T3.md'
    t "$S ...and the decompose commit is its parent (the map landed before any task existed)" \
      eval '[ "$(subj HEAD~1)" = "docs(plan): decompose seat-notice" ]'
  else
    t "$S ...then one acfw-store create per task" eval '[ "$(wt "[.writer[].cmd | select(test(\"$RE_CREATE\"))] | length")" = 3 ]'
  fi
  t "$S the store holds the three tasks, pending" eval 'folder_is $T1 pending && folder_is $T2 pending && folder_is $T3 pending'
  t "$S ...each task document names its plan and deliverable (the writer's Documentation stamp)" \
    eval 'doc_has $T1 "- **Documentation**: $P (D1)" && doc_has $T2 "- **Documentation**: $P (D2)" && doc_has $T3 "- **Documentation**: $P (D3)"'
  t "$S ...and the validated dependency (the writer's Dependencies stamp)" doc_has $T3 "- **Dependencies**: $T2"
  t "$S the focus is exactly the cycle's three tasks, set by task" \
    eval '[ "$(grep -v "^#" "$REPO/.acfwhip/run/focus" | grep -v "^\$" | LC_ALL=C sort | paste -sd, -)" = "$T1,$T2,$T3" ] && grep -qx "# setBy=task" "$REPO/.acfwhip/run/focus"'
  t "$S the decomposition lock was released by this run (verify step)" eval '[ ! -e "$LOCKP" ] && [ "$(wt .report.cycle.lockReleased)" = true ]'
  t "$S the create-time doctor is clean" eval '[ "$(wt .report.doctor.ok)" = true ]'
  t "$S the report lists the three tasks as created, no gaps, and points at /go" \
    eval '[ "$(wt "[.report.created[].id] | sort | join(\",\")")" = "$T1,$T2,$T3" ] && [ "$(wt ".report.cycle.coverageGaps | length")" = 0 ] && wt .report.nextStep | grep -q "^Run /go"'
  cy check "$ID"
  t "$S a re-run of /task --plan now: CHECK|noop|cycle=<ID>|reason=covered, and no lock taken" \
    eval 'rc 0 && [ "$OUT" = "CHECK|noop|cycle=$ID|reason=covered" ] && [ ! -e "$LOCKP" ]'

  cy status
  t "$S bare status: exit 0, NEXT /go" eval 'rc 0 && inv && next_is "NEXT /go"'
  t "$S ...with the /go step 3a line: focus = the 3 runnable task(s) of approved cycle <ID>" has_line "  focus = the 3 runnable task(s) of approved cycle $ID"
  cy status --if-cycle
  t "$S status --if-cycle (what /go reads) prints the same line" eval 'rc 0 && has_line "  focus = the 3 runnable task(s) of approved cycle $ID" && next_is "NEXT /go"'
  # Meanwhile the operator drafts the next idea: an untracked cycle folder in the trunk root that every
  # transition commit and every LP-CAS landing below must leave alone.
  cy init next-idea --kind feature --source "/whip draft" --title "Next idea"
  NID=$(line1 | sed -n 's/^INIT|\([^|]*\)|.*/\1/p')
  printf '# Next idea\n\n## Problem\n\nLater.\n\n## Deliverables\n\n### D1: Something later\n\n- AC1.1: it exists.\n' > "$REPO/docs/cycles/$NID/plan.md"
  rm -rf "$WORK/next-idea.before"; cp -R "$REPO/docs/cycles/$NID" "$WORK/next-idea.before"
  cy status
  t "$S a second, untracked draft of mine does not take NEXT from the cycle in flight" \
    eval 'rc 0 && inv && next_is "NEXT /go" && has_line "  focus = the 3 runnable task(s) of approved cycle $ID"'

  echo "== $S BUILD: /go (whip-go's writer, specialists in worktrees, LP-CAS) =="
  st info; RL=$(printf '%s' "$OUT" | jq -r .runLock)
  printf '{"pid":%s,"ts":"%s"}\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RL"   # whip-go takes its run lock
  # While /go runs in the background, the operator starts amending the approved plan and STAGES it
  # (git add). Approval binds the bytes at HEAD, so no /go writer may commit that amendment: it would
  # land an unapproved plan under a task subject, and the approval stops holding at HEAD.
  H_BEFORE_GO=$(g rev-parse HEAD)
  printf '\nNote: the bulk-dismiss path needs the same audit row.\n' >> "$REPO/$P"
  g add -- "$P"
  # Iteration 1: T1 and T2 dispatch (T3 waits on T2). T1 is accepted and lands; T2 is rejected.
  go_build $T1 1; go_build $T2 1
  go_accept $T1; go_reject $T2
  t "$S no /go writer (transitions, LP-CAS landing) committed the operator's staged plan.md amendment" \
    not_swept "$P" "$H_BEFORE_GO"
  cy check "$ID"
  t "$S ...so the approval still holds at HEAD (check: CHECK|noop|...|reason=covered, not a refusal)" \
    eval 'rc 0 && [ "$OUT" = "CHECK|noop|cycle=$ID|reason=covered" ]'
  drop_amendment "$P" "$H_BEFORE_GO"
  cy status
  t "$S mid-run status: NEXT says wait while the /go run lock is fresh" eval 'rc 0 && inv && next_is "NEXT wait: /go is running"'
  t "$S ...coverage: D1 ✓ (accepted and integrated), D2 ◐, D3 ◐" eval 'cov D1 ✓ && cov D2 ◐ && cov D3 ◐'
  t "$S ...and no focus PIN while /go runs" eval '! has_re "^  focus = "'
  # Iteration 2: T2 retries and is rejected again (its second life). T3 still waits on T2.
  go_retry $T2 1; go_build $T2 2; go_reject $T2
  # Iteration 3: T2 retries and is accepted. Iteration 4: T3 runs and is accepted.
  go_retry $T2 2; go_build $T2 3; go_accept $T2
  go_build $T3 1; go_accept $T3
  rm -f "$RL"                                                                     # ...and releases it
  t "$S after /go: all three tasks accepted" eval 'folder_is $T1 accepted && folder_is $T2 accepted && folder_is $T3 accepted'
  t "$S ...each with its ledger marker on trunk (the integration oracle)" eval 'integrated $T1 && integrated $T2 && integrated $T3'
  t "$S ...each change is on trunk" eval 'g cat-file -e HEAD:src/notice-ui/impl.txt && g cat-file -e HEAD:src/notice-dismiss/impl.txt && g cat-file -e HEAD:src/notice-audit/impl.txt'
  t "$S ...$T2 carries Rejection Count 2, the others 0" eval 'field_is $T2 rejection_count 2 && field_is $T1 rejection_count 0 && field_is $T3 rejection_count 0'
  st doctor
  t "$S ...and the store doctor finds nothing fatal after the run" eval 'rc 0 && has_re "^SUMMARY\|fatal=0\|.*\|ok=true\$"'
  t "$S the untracked draft survived every transition and landing, byte for byte, and was never committed" \
    eval 'diff -r "$WORK/next-idea.before" "$REPO/docs/cycles/$NID" >/dev/null && [ -z "$(g log --format=%H -- "docs/cycles/$NID")" ]'
  # The operator parks that idea for now: abandoning an untracked draft stamps it and commits nothing,
  # and dropping the folder is theirs.
  H0=$(g rev-parse HEAD)
  cy abandon "$NID" --reason "later"
  t "$S abandon the untracked draft: ABANDON|ok|cycle=<NID>|committed=no, nothing committed" \
    eval 'rc 0 && [ "$OUT" = "ABANDON|ok|cycle=$NID|committed=no" ] && head_is "$H0" && [ "$(meta Status < "$REPO/docs/cycles/$NID/record.md")" = abandoned ]'
  rm -rf "$REPO/docs/cycles/$NID"

  echo "== $S VERIFY: /go's nextStep, then the coverage table =="
  # The command /go's RunReport tells the session to run next, read from whip-go itself (its final
  # nextStep), so this call is whatever /go says today: stopReason complete, mode default.
  GO_NEXT=$(LC_ALL=C sed -n 's/^[[:space:]]*nextStep: `Run: bash \${sq(CYCLE)} \(status [^`]*\) [^ ][^ ]* print .*/\1/p' "$ACF_WHIP/workflows/whip-go.workflow.js" | head -1 \
            | sed 's/\${stopReason}/complete/; s/\${mode}/default/')
  t "$S whip-go's RunReport names an acfw-cycle status step with --if-cycle --after-run and --mode" \
    eval 'printf "%s" "$GO_NEXT" | grep -q -- "--if-cycle" && printf "%s" "$GO_NEXT" | grep -q -- "--after-run complete" && ! printf "%s" "$GO_NEXT" | grep -q "[\$]{"'
  # shellcheck disable=SC2086
  cy ${GO_NEXT:-status --if-cycle --after-run complete --mode default}
  t "$S $GO_NEXT: exit 0, invariants hold" eval 'rc 0 && inv'
  t "$S ...coverage: D1 ✓ D2 ✓ D3 ✓" eval 'cov D1 ✓ && cov D2 ✓ && cov D3 ✓'
  t "$S ...the retro fact names the fired trigger" has_line "  retro: trigger fired: rework ($T2 rc=2)"
  t "$S ...NEXT /retro <ID> (RETRO is always explicit)" next_is "NEXT /retro $ID"

  echo "== $S RETRO: the /retro skill's own steps (route, triggers, retro-begin, gather, verify, close) =="
  # Step 1 (route): the skill's retro-status block, bare. NEXT names the cycle; no /go is running.
  skill_block retro retro-status "set --"
  t "$S /retro step 1 (retro-status block): exit 0, NEXT /retro <ID>, no GO_RUNNING" \
    eval 'rc 0 && [ "$(lastl)" = "NEXT /retro $ID" ] && ! has_line "GO_RUNNING=yes"'
  # Step 2: triggers, written where the skill writes them.
  IN="$WORK/retro-in.$STORE_NAME"; rm -rf "$IN"; mkdir -p "$IN"
  cy triggers "$ID"; printf '%s\n' "$OUT" > "$IN/triggers.txt"
  t "$S /retro step 2 (triggers): exit 0, exactly TRIGGER|rework|$T2|rc=2" eval 'rc 0 && [ "$OUT" = "TRIGGER|rework|$T2|rc=2" ]'
  # Step 4: the baseline close governs against.
  H0=$(g rev-parse HEAD)
  cy retro-begin "$ID"
  t "$S /retro step 4 (retro-begin): exit 0, RETRO|begin|cycle=<ID>|head=<HEAD>" eval 'rc 0 && [ "$OUT" = "RETRO|begin|cycle=$ID|head=$H0" ]'
  # Step 5: the skill's retro-gather block. It reads the triggered task through the store with
  # --materialize (the rejection notes live there on every backend) and its trunk commits by trailer.
  skill_block retro retro-gather "MODE=close; CYC=$(sq_ "$ID"); FORCE=0; IN=$(sq_ "$IN"); set --"
  DATE=$(printf '%s\n' "$OUT" | sed -n 's/^DATE=//p')
  t "$S /retro step 5 (retro-gather block): exit 0, TASKS=1 (the reworked task), nothing unreadable" \
    eval 'rc 0 && has_line "TASKS=1" && ! has_re "UNREADABLE|^STORE: " && printf "%s" "$DATE" | grep -qE "^[0-9]{8}\$"'
  # task-docs.txt maps each stem to the document the agent reads: a copy under $IN/tasks/ on a raw
  # adapter, the live .backlog/ file on files (whose materialize prints the real path).
  t "$S ...the gathered $T2 document carries both rejection notes the reviewer wrote" \
    eval 'p=$(awk -F"\t" -v s="$T2" "\$1 == s { print \$2 }" "$IN/task-docs.txt") && [ -f "$p" ] && [ "$(grep -c "AC2.1 fails: a dismissed notice comes back after reload" "$p")" -ge 2 ]'
  t "$S ...and its trunk history, found by its ACFW-Task trailer" grep -q "^Subject: integrate: $T2\$" "$IN/git/$T2.log"
  t "$S ...no lessons yet; follow-through: FOLLOW|none" eval '[ ! -s "$IN/lessons.txt" ] && grep -qx "FOLLOW|none" "$IN/follow-through.txt"'
  # Plan §7 RETRO: the spec tools' verdicts on the approved bytes reach the agent, read from HEAD.
  t "$S ...spec-rows.txt holds exactly the committed reviewed row (no-tbd's GO at the approved bytes)" \
    eval '[ "$(grep -c . "$IN/spec-rows.txt")" = 1 ] && grep -qE "\| reviewed \| no-tbd \| $C1 \| go n=0 \|" "$IN/spec-rows.txt"'
  # Step 6: the retro agent's outputs, written in the shapes its prompt demands: the retro doc, at most
  # three lessons (the rule is the first line, no frontmatter), and the actions cycle made with exactly
  # the init command the prompt gives it.
  LESSON_SLUG=dismissal-audit-in-one-transaction
  LESSON="docs/acf/lessons/$LESSON_SLUG.md"
  RULE="A dismiss handler writes its audit row in the same transaction as the dismissal."
  mkdir -p "$REPO/docs/acf/lessons"
  printf '**Rule**: %s\n\n## What happened\n\n%s was rejected twice: the dismissal committed, the audit write failed after it, and a reload showed the notice again.\n\n## Root cause\n\nTwo transactions for one user action.\n\n## Fix\n\nOne transaction; the test in the retro actions guards it.\n' "$RULE" "$T2" > "$REPO/$LESSON"
  printf '# Retro: Seat change notice\n\n## Triggers\n\n- rework: %s (rejection count 2)\n\n## Five whys\n\n1. The reviewer found a dismissed notice back after reload.\n2. The audit write failed after the dismissal committed.\n3. They ran in two transactions.\n4. The task named no transaction boundary.\n5. No test checks the pair.\n\n## Lessons\n\n- %s\n\n## Retire\n\nNone.\n' "$T2" "$LESSON_SLUG" > "$REPO/docs/cycles/$ID/retro.md"
  cy init "${ID#????????-}-retro-actions" --kind retro-actions --source "retro $ID" --title "Retro actions: Seat change notice"
  AID=$(line1 | sed -n 's/^INIT|\([^|]*\)|.*/\1/p')
  t "$S the retro agent's init: exit 0, INIT|<DATE>-seat-notice-retro-actions|docs/cycles/<AID>/plan.md" \
    eval 'rc 0 && [ "$AID" = "$DATE-seat-notice-retro-actions" ] && line1_is "INIT|$AID|docs/cycles/$AID/plan.md"'
  PA="docs/cycles/$AID/plan.md"; RA="docs/cycles/$AID/record.md"
  printf '# Retro actions: Seat change notice\n\n## Problem\n\n%s was reworked twice because a dismissal and its audit row were written in two transactions.\n\n**Actor & trigger**: a developer changes a dismiss handler.\n\n## Scope\n\n- A test that fails when a dismissal writes no audit row.\n\n## Non-scope\n\n- Changing the audit schema.\n\n## Assumptions\n\n- The audit table stays as it is.\n\n## Risks\n\n- The test is slow. Undo: move it to the nightly suite.\n\n## Deliverables\n\n### D1: [sensor] [loosens: no] A test fails when a dismissal writes no audit row\n\n- AC1.1: the suite fails against a dismiss handler that skips the audit write.\n' "$T2" > "$REPO/$PA"
  # Step 7: the skill's retro-verify block over exactly those outputs.
  skill_block retro retro-verify "MODE=close; DOC=$(sq_ "docs/cycles/$ID/retro.md"); AID=$(sq_ "$AID"); set -- $(sq_ "$LESSON")"
  t "$S /retro step 7 (retro-verify block): VERIFY|ok" eval 'rc 0 && [ "$OUT" = "VERIFY|ok" ]'
  # Step 8: one commit through acfw-cycle.
  cy close "$ID" retro.md --lesson "$LESSON" --actions "$AID"
  t "$S close <ID> retro.md --lesson --actions: exit 0, CLOSE|ok|cycle=<ID>|retro=retro.md|lessons=1|actions=<AID>|commit=<sha12>" \
    eval 'rc 0 && has_line "CLOSE|ok|cycle=$ID|retro=retro.md|lessons=1|actions=$AID|commit=$(g rev-parse HEAD | cut -c1-12)"'
  t "$S ...follow-through: no earlier retro-actions cycle (FOLLOW|none), never this retro's own" eval 'has_line "FOLLOW|none" && ! has_re "^FOLLOW\|$AID"'
  t "$S ...ONE commit 'docs(plan): close seat-notice' on top of the retro's HEAD" \
    eval 'subj_is "docs(plan): close seat-notice" && [ "$(g rev-parse HEAD~1)" = "$H0" ]'
  t "$S ...with exactly record.md, retro.md, the lesson and the actions folder" \
    eval 'paths_are HEAD "$R" "docs/cycles/$ID/retro.md" "$LESSON" "$PA" "$RA"'
  t "$S ...carrying ACFW-Plan-Event: closed <c12> <ID>" trailer_is HEAD "closed $C1 $ID"
  t "$S ...record.md at HEAD: Status closed, Retro retro.md" eval '[ "$(hmeta "$R" Status)" = closed ] && [ "$(hmeta "$R" Retro)" = retro.md ]'
  t "$S ...the Plan Log: closed,decomposed,approved,reviewed,pulled,pushed,drafted (newest first)" \
    eval '[ "$(log_events "$R")" = "closed,decomposed,approved,reviewed,pulled,pushed,drafted" ] && log_newest_first "$R"'
  t "$S ...the actions cycle is committed as a retro-actions draft sourced from this retro" \
    eval '[ "$(hmeta "$RA" Kind)" = retro-actions ] && [ "$(hmeta "$RA" Status)" = draft ] && [ "$(hmeta "$RA" Source)" = "retro $ID" ]'
  t "$S ...and the working tree is clean afterwards" eval '[ -z "$(g status --porcelain)" ]'
  cy status "$ID"
  t "$S status <ID>: the closed cycle says so and hands NEXT to the next goal" \
    eval 'rc 0 && inv && has_line "  this cycle is closed (retro: retro.md)" && next_is "NEXT /whip \"<next goal>\""'
  cy status --if-cycle
  t "$S status --if-cycle after the close: prints nothing (the focus reaches only a closed cycle)" eval 'rc 0 && [ -z "$OUT$ERR" ]'

  echo "== $S after the retro: status offers the retro-actions approval; lessons feed the planner =="
  cy status
  t "$S bare status: exit 0, invariants hold" eval 'rc 0 && inv'
  t "$S ...a standing card offers the retro-actions approval (REPLY /whip <AID>)" reply_is "/whip $AID"
  t "$S ...and NEXT is the next goal (a closed cycle never takes NEXT)" next_is 'NEXT /whip "<goal>"'
  sp review "$PA"
  AC=$(c12 "$REPO/$PA")
  t "$S review of the actions plan (before its card): no-tbd GO" eval 'rc 0 && has_re "^  no-tbd \(block, [^)]*\): GO, 0 finding\(s\)\$"'
  cy status "$AID"
  t "$S status <AID> (/whip <AID>): the approval card, NEXT approves exactly its bytes" \
    eval 'rc 0 && inv && has_line "  content=$AC" && next_is "NEXT yes: approve $PA (content=$AC)"'
  t "$S ...the card shows the D heading with its loosens tag" has_line "  D1: [sensor] [loosens: no] A test fails when a dismissal writes no audit row"
  cy lessons
  t "$S acfw-cycle lessons: exit 0, prints the lesson as <slug>: <rule>, no warning" \
    eval 'rc 0 && [ "$OUT" = "$LESSON_SLUG: $RULE" ] && [ -z "$ERR" ]'
  cy approve "$AID" --expect "$AC"
  t "$S approve the retro actions: exit 0, NEXT /task --plan docs/cycles/<AID>/plan.md" \
    eval 'rc 0 && line1_is "APPROVE|ok|cycle=$AID|content=$AC|commit=$(g rev-parse HEAD | cut -c1-12)" && [ "$(lastl)" = "NEXT /task --plan $PA" ]'
  t "$S ...commit 'docs(plan): approve seat-notice-retro-actions': record.md only (close already committed its plan.md)" \
    eval 'subj_is "docs(plan): approve seat-notice-retro-actions" && paths_are HEAD "$RA" && trailer_is HEAD "approved $AC $AID"'
  # "yes" launched /task --plan in the background; meanwhile the operator stages an amendment of the
  # plan it is decomposing. The writer must commit its tasks and nothing else of the index.
  H_BEFORE_TASK=$(g rev-parse HEAD)
  printf '\nNote: cover the bulk-dismiss path in the same test.\n' >> "$REPO/$PA"
  g add -- "$PA"
  task_plan "$PA" "$TASKS_RA"
  t "$S no /task --plan writer commit carried the operator's staged plan.md amendment" not_swept "$PA" "$H_BEFORE_TASK"
  drop_amendment "$PA" "$H_BEFORE_TASK"
  t "$S the next /task --plan (the retro actions) completes" eval 'rc 0 && [ "$(wt .report.phase)" = complete ] && wt_no_errors'
  t "$S ...its check is a retro-actions go" eval 'wt .check | grep -qE "^CHECK\|go\|cycle=$AID\|.*\|uncovered=D1\|known=D1\|coverage=on\|kind=retro-actions\|held=[0-9]+\$"'
  t "$S ...its planner ran the lessons command it was told to run, and got the recorded rule" \
    eval '[ "$(wt .lessons.code)" = 0 ] && wt .lessons.out | grep -qxF "$LESSON_SLUG: $RULE"'
  t "$S ...and the retro-actions record maps D1 to the new task" eval '[ "$(tasks_rows "$RA")" = "| D1 | $TA |" ]'
  t "$S ...its Plan Log: decomposed,approved,reviewed,drafted (newest first)" \
    eval '[ "$(log_events "$RA")" = "decomposed,approved,reviewed,drafted" ] && log_newest_first "$RA"'
  cy status
  t "$S bare status: the loop closed; the retro's actions are the next /go" \
    eval 'rc 0 && inv && has_line "  focus = the 1 runnable task(s) of approved cycle $AID" && next_is "NEXT /go"'
  t "$S the trunk root is clean at the end of the cycle" eval '[ -z "$(g status --porcelain)" ]'
}

case "${P22_ONLY:-}" in
  files|multica) use_store "$P22_ONLY"; e2e ;;
  *) use_store files; e2e; use_store multica; e2e ;;
esac

echo
echo "phase22-cycle-e2e: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
