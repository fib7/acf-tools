// phase20-task-plan.test.mjs — /task --plan (3.5.0): whip-task decomposes an APPROVED cycle plan.
//
// WHY THIS EXISTS. Plan mode adds a second contract to whip-task without a second code path: the same
// recon, planners, judge, critic, authors, writer and doctor, with the plan threaded through. Every way
// it can go wrong is silent at runtime:
//
//   * a free-text run drifts (the DIRECT route promises to be byte-identical to 3.4.x, and nothing at
//     runtime would notice a plan-mode string leaking into a free-text prompt);
//   * an abort strands the decomposition lock, so the operator's corrected re-run is refused for 30
//     minutes with nothing in flight, or an abort RELEASES a lock another run holds;
//   * a planner reads the working-tree plan.md instead of the frozen approved copy and builds an edit
//     nobody approved;
//   * a task names no deliverable (invisible to coverage) or only covered ones (re-decomposes done work);
//   * the writer creates tasks before `acfw-cycle record` lands the map, or `add`s to the focus instead of
//     setting it to the cycle.
//
// Four halves:
//   1. the <task-pure> block (validatePlan, parsePlanPath, parseCheck, coverage, schema) extracted and
//      unit-tested, the way phase2/phase14 extract <scheduler-pure> from whip-go;
//   2. a phase14-style line scan: every `aborted: true` return except the one tagged check-refused is
//      preceded within 6 lines by `await releaseCycleLock(`, and the verify:doctor prompt carries the
//      release;
//   3. the REAL workflow body run end to end with a mocked agent(), the way phase11/phase15 drive
//      whip-go: free-text byte-identity against 3.4.2 goldens, plan mode on files and on a non-files
//      store, and every abort path;
//   4. the shell the prompts hand to agents, executed for real under /bin/bash (3.2 on macOS, with BSD
//      awk/sed): the CHECK capture, the Documentation stamp, record-first, and the cycle focus filter,
//      which also runs under zsh (the macOS default shell an agent runs it in).
//
// Regenerating the free-text goldens (only when a free-text prompt changes ON PURPOSE):
//   PHASE20_GOLDEN_SRC=<path to the whip-task.workflow.js whose prompts are the reference> \
//     node acf-whip/tests/phase20-task-plan.test.mjs
// prints the label -> sha256 map to paste into GOLDEN below.
//
// Run: node acf-whip/tests/phase20-task-plan.test.mjs

import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, existsSync, chmodSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { tmpdir } from 'node:os'
import { createHash } from 'node:crypto'
import { execFileSync, spawnSync } from 'node:child_process'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..')
const SRC = join(ROOT, 'workflows', 'whip-task.workflow.js')

let PASS = 0, FAIL = 0
const ok = (m) => { PASS++; console.log(`  PASS: ${m}`) }
const bad = (m) => { FAIL++; console.log(`  FAIL: ${m}`) }
const check = (m, cond) => (cond ? ok(m) : bad(m))
const sha = (s) => createHash('sha256').update(String(s)).digest('hex')

const text = readFileSync(SRC, 'utf8')
// A workflow that no longer compiles as a workflow body fails here, loudly, instead of crashing a scenario.
try {
  new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow', `return (async () => {\n${text.replace(/^export const meta/m, 'const meta')}\n})()`)
} catch (e) {
  bad(`whip-task.workflow.js does not compile as a workflow body: ${e.message}`)
  console.log(`\nphase20-task-plan: ${PASS} passed, ${FAIL} failed`)
  process.exit(1)
}

// ============================ the mocked workflow runtime ============================
// agent() answers by label; every call is recorded (label, prompt, opts) so assertions can read exactly
// what each agent was told. A scenario overrides the answers it cares about.
const AGENTS = ['go-engineer', 'react-engineer', 'quality-reviewer']
const stub = (o) => Object.assign({
  title: 'T', category: 'feature', priority: 'high', assignedAgent: 'go-engineer', isCodeMutating: true,
  prGroup: '', touchesGlobs: ['services/x/**'], dependencies: [], estimatedHours: '4',
  what: 'Endpoint returns 200', why: 'Users need it', constraints: 'p95 < 200ms', outOfScope: 'No UI',
}, o)
const FT_PLAN = {
  summary: 'login',
  tasks: [
    stub({ id: 'feature-002-login-api', title: 'Login API', worktreeSlug: 'auth-api', touchesGlobs: ['services/auth/**'] }),
    stub({ id: 'feature-003-login-ui', title: 'Login UI', assignedAgent: 'react-engineer', worktreeSlug: 'auth-ui', touchesGlobs: ['web/login/**'], dependencies: ['feature-002-login-api'] }),
  ],
}

async function runWorkflow(src, args, sc = {}) {
  const calls = []
  const logs = []
  let n = 0
  async function agent(prompt, opts) {
    const label = (opts && opts.label) || ''
    const call = { i: n++, label, prompt: String(prompt), opts: opts || {} }
    calls.push(call)
    if (sc.on && sc.on[label]) return sc.on[label](call, calls)
    if (label === 'discover-agents') return { agents: sc.agents || AGENTS, ...(sc.check != null ? { check: sc.check } : {}) }
    if (label === 'recon:backlog') return { ids: ['feature-001-existing'], slugsInUse: ['core'], liveBranches: ['worktree/core'], note: '' }
    if (label === 'recon:surface') return { modules: ['services/auth/**', 'web/login/**'], testLayout: 'tests/ next to code', note: '' }
    if (label === 'recon:conventions') return { agents: ['go-engineer: Go services', 'react-engineer: React UI'], gateCommands: 'make test', styleNotes: 'WHAT/WHY only', note: '' }
    if (/^plan:/.test(label)) return sc.planner ? sc.planner(call, calls) : JSON.parse(JSON.stringify(FT_PLAN))
    if (label === 'judge:plan') return { choice: 0, reason: 'cleaner partition' }
    if (label === 'critic:completeness') return { defects: sc.critic ? sc.critic(call, calls) : [] }
    if (/^author:/.test(label)) {
      const id = label.slice('author:'.length)
      const written = sc.authorWritten ? sc.authorWritten(id) : true
      return { id, filename: `${id}.md`, written, note: written ? 'ok' : 'could not write' }
    }
    if (label === 'write:commit' || label === 'write:ingest') {
      return sc.writer ? sc.writer(call) : { committed: true, commitSha: 'abc1234', files: [], note: '', ...(/acfw-cycle' record/.test(call.prompt) ? { record: 'RECORD|ok|cycle=x|tasks=2', dropped: [] } : {}) }
    }
    if (label === 'verify:doctor') return { ok: true, summaryLine: 'SUMMARY|fatal=0|repairable=0|warn=0|ok=true', fatals: [], warns: [] }
    if (label === 'cycle:unlock') return 'done'
    throw new Error(`unmocked agent label "${label}"`)
  }
  const parallel = async (thunks) => {
    const out = []
    for (const f of thunks) { try { out.push(await f()) } catch (e) { out.push(null) } }
    return out
  }
  const pipeline = async () => { throw new Error('pipeline not expected') }
  const phase = () => {}
  const log = (m) => { logs.push(String(m)) }
  const body = src.replace(/^export const meta/m, 'const meta')
  const run = new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow',
    `return (async () => {\n${body}\n})()`)
  const report = await run(agent, parallel, pipeline, phase, log, args, undefined, async () => { throw new Error('workflow not expected') })
  return { report, calls, logs, byLabel: (l) => calls.filter((c) => c.label === l), first: (l) => calls.find((c) => c.label === l) }
}

// ============================ free-text byte identity (3.4.2) ============================
// Two prompts legitimately changed in EVERY mode: the planners and the critic now read the recorded
// lessons by reference (plan §3, "lessons by reference"). Strip exactly those lines and nothing else;
// every other prompt must hash to what 3.4.2 sent.
function normalizeFreeText(label, prompt) {
  let p = prompt
  if (/^plan:/.test(label)) {
    p = p.replace(/^Run `cd [^\n]* lessons` \(read-only\)\. Every rule it prints is a recorded lesson; copy a rule verbatim into the `constraints` of any task that walks into it\.\n/m, '')
  }
  if (label === 'critic:completeness') {
    p = p.replace(/^Run `cd [^\n]* lessons` \(read-only\)\. Every rule it prints is a recorded lesson\.\n\n/m, '')
    p = p.replace(/^ {2}\* a task that walks into a recorded lesson without that rule in its constraints\n/m, '')
  }
  return p
}
const FT_ARGS = (store) => ({ scope: 'Add a login flow: API and UI', pluginRoot: '/p', trunkRoot: '/r', trunkBranch: 'main', store })
async function freeTextHashes(src) {
  const out = {}
  // files store, with one critic finding so the repair prompt (plan:retry0) is covered too
  const a = await runWorkflow(src, FT_ARGS('files'), { critic: () => ['two tasks share nothing'] })
  for (const c of a.calls) out[`files/${c.label}`] = sha(normalizeFreeText(c.label, c.prompt))
  out['files/report'] = sha(JSON.stringify(a.report))
  out['files/schema:plan:0'] = sha(JSON.stringify(a.first('plan:0').opts.schema))
  out['files/schema:discover-agents'] = sha(JSON.stringify(a.first('discover-agents').opts.schema))
  out['files/schema:write:commit'] = sha(JSON.stringify(a.first('write:commit').opts.schema))
  const b = await runWorkflow(src, FT_ARGS('multica'))
  for (const c of b.calls) out[`multica/${c.label}`] = sha(normalizeFreeText(c.label, c.prompt))
  out['multica/report'] = sha(JSON.stringify(b.report))
  out['multica/schema:write:ingest'] = sha(JSON.stringify(b.first('write:ingest').opts.schema))
  return out
}

if (process.env.PHASE20_GOLDEN_SRC) {
  const h = await freeTextHashes(readFileSync(process.env.PHASE20_GOLDEN_SRC, 'utf8'))
  console.log(JSON.stringify(h, null, 2))
  process.exit(0)
}

// Generated from the 3.4.2 whip-task.workflow.js (unchanged through 3.4.3) with PHASE20_GOLDEN_SRC.
// Byte identity is the DIRECT route's promise: a free-text /task sends what 3.4.x sent, except the
// lessons lines normalizeFreeText strips and the one sed fix noted inline.
const GOLDEN = {
  'files/discover-agents': 'f08cf4857afa87da621eb2a879bef16d6a3e1f826148107da6cdc1638bd82d70',
  'files/recon:backlog': '077ef2e76030043b3fc17e118a1527e01a60a33d118550e704367692b9236181',
  'files/recon:surface': '33640ce71cfd23039aebe6730d36e5f29cc229a5a9b7ff85f2705fbe4be098df',
  'files/recon:conventions': '7d665b4a564a0c458b10d77990011dbfc5566349f06effeade04658f2a4854b9',
  'files/plan:0': '51ca39f8bd80da1bdd0be31bdb4ade6c6718a922878786c5e5154cb88d36fd98',
  'files/plan:1': '526da0d99585716611625af2c14d4d041dcb28c2acb9f29bf911ab86d1049b3f',
  'files/judge:plan': 'c8e9a8b63a6af6e4536a266315839d5ef9438599688b68c38bf0dd15a249a113',
  'files/critic:completeness': 'aeb8730676e8e997641bc9a6ea211c1ebe80933ab7ba428d7f8ae6617bedd341',
  'files/plan:retry0': '89458f46441d02bfcd7381c03db164265187ba9ce61e1649abfa70ba6eea54dd',
  'files/author:feature-002-login-api': '705a76e81585b3250e5116ea64bb592cc2c0ecc6a1c6d1232c876c1e901a26d0',
  'files/author:feature-003-login-ui': '008dff5a90cb0582459262aa20dfb2d5ec9f8198aa649880c8d73d6935dc0fdc',
  // The ONE intentional free-text change: the dependency stamp's insert branch now hands sed a single
  // backslash after `a` before the newline (3.4.2 handed it two, which GNU and BSD sed both reject).
  // Regenerated from 3.4.2 with only that fix applied; every other entry is 3.4.2 verbatim.
  'files/write:commit': '58a8b11710df3a2c75f8b8f427329c065fd50fe36028fcdfcc6cfc8f54857573',
  'files/verify:doctor': '37e84681f3e68aaf1ea974aa100248057badc1abd650b241dc7fce53f64e87a7',
  'files/report': '70596c2cfbc99300f915738797343a2f1e4464757633ab4c808df7f38f1e2d81',
  'files/schema:plan:0': '9c5ca38c95c914194189147da411c7d8ba090109fc8ed9692f9aa9a3ef498895',
  'files/schema:discover-agents': 'e9505b3f30fcdc1efd7367778839ab3ca3f6d84a616aba71c2da5d3e71420bc5',
  'files/schema:write:commit': '5d1c8d1b579267a46ed32a9fd69ba48c8ac3b455e11668600d02b1b2773b230a',
  'multica/discover-agents': 'f08cf4857afa87da621eb2a879bef16d6a3e1f826148107da6cdc1638bd82d70',
  'multica/recon:backlog': '2b08de6e9a2507d2144b6ea26c225ef5376f3214eddc426d086a6b813764eb01',
  'multica/recon:surface': 'f27a75da1c86c02e8c4afa31bb997a39b5b37eeaeefad4357801f3bccf258929',
  'multica/recon:conventions': '581b60a74719ac94d6c462bfa1bcebb015149802ce0853947f3b9498c3876533',
  'multica/plan:0': '51ca39f8bd80da1bdd0be31bdb4ade6c6718a922878786c5e5154cb88d36fd98',
  'multica/plan:1': '526da0d99585716611625af2c14d4d041dcb28c2acb9f29bf911ab86d1049b3f',
  'multica/judge:plan': 'c8e9a8b63a6af6e4536a266315839d5ef9438599688b68c38bf0dd15a249a113',
  'multica/critic:completeness': 'aeb8730676e8e997641bc9a6ea211c1ebe80933ab7ba428d7f8ae6617bedd341',
  'multica/author:feature-002-login-api': 'c344c4263ce5acb43ef90f301128b2a784506d578de76e5a39754449120bd180',
  'multica/author:feature-003-login-ui': '6fe136db3380a3d061b9a7d351ebdbda69afab44674285cf37a75b2de74d17a0',
  'multica/write:ingest': 'ec5bb5d9c92148f1081dd4d85bc3b42116f118930b8054ec36c0094920bb9baa',
  'multica/verify:doctor': 'f6de6004b516c45546882113e2d6215ed6a49bb95ea3a39127e5624de2e95126',
  'multica/report': 'aac9caf70ab86fc822e094ae2fc9e9e77bb786f1e22063c5f7acfa654a295dd3',
  'multica/schema:write:ingest': '5d1c8d1b579267a46ed32a9fd69ba48c8ac3b455e11668600d02b1b2773b230a'
}

// ============================ 1. the pure block ============================
const start = text.indexOf('// <task-pure>')
const end = text.indexOf('// </task-pure>')
if (start < 0 || end < 0 || end < start) {
  console.error('FATAL: could not find <task-pure> markers in whip-task.workflow.js')
  process.exit(1)
}
const block = text.slice(start, end)
check('the pure block calls no agent and reads no args', !/\bagent\(|\bargs\b|\bparallel\(/.test(block.replace(/\/\/[^\n]*/g, '')))
const P = new Function(`${block}\nreturn { validatePlan, parsePlanPath, parseCheck, lockPathOk, normDs, planSchemaFor, uncoveredBy, gapDefects, planScopeBlock, taskDs, docValueFor, recordArgFor, oosLineFor, TASK_STUB, DECOMPOSITION_PLAN, WRITE_RESULT, WRITE_RESULT_PLAN }`)()

const TR = '/work/repo'
const ID = '20260928-owner-seat'
const REL = `docs/cycles/${ID}/plan.md`
const C12 = 'abcdef012345'
const LOCK = `${TR}/.acfwhip/run/cycle-${ID}.decomposing`
const FROZEN = `${TR}/.acfwhip/run/cycle/${ID}/${C12}.md`
const HELD = '1790000000'
const FLAG = `${TR}/.acfwhip/run/cycle/${ID}/recorded`
// The stamp-checked release every exit path hands a shell agent (never a bare rm -f of the lock).
const REL_CMD = (lock = LOCK, held = HELD) => `if grep -qx 'ts=${held}' '${lock}' 2>/dev/null; then rm -f '${lock}'; fi`
// The line as the discover-agents capture relays it: check's own CHECK|go line plus the |held=<ts> the
// capture appends after reading the lock back. held: null leaves it off (a relay that dropped it).
const goLine = (o = {}) => {
  const f = Object.assign({ cycle: ID, content: C12, frozen: FROZEN, lock: LOCK, uncovered: 'D2,D3', known: 'D1,D2,D3', coverage: 'on', kind: 'feature', held: HELD }, o)
  return `CHECK|go|cycle=${f.cycle}|content=${f.content}|frozen=${f.frozen}|lock=${f.lock}|uncovered=${f.uncovered}|known=${f.known}|coverage=${f.coverage}|kind=${f.kind}${f.held == null ? '' : `|held=${f.held}`}`
}

// ---- parsePlanPath ----
{
  const pp = (s) => P.parsePlanPath(s, TR)
  for (const s of [REL, ID, `docs/cycles/${ID}`, `docs/cycles/${ID}/`, `./docs/cycles/${ID}/record.md`, `${TR}/docs/cycles/${ID}/plan.md`, `${TR}/${ID}`]) {
    const r = pp(s)
    check(`planPath "${s}" resolves to ${REL}`, r.ok && r.id === ID && r.rel === REL)
  }
  const refuse = [
    ['', 'empty'],
    ['/elsewhere/docs/cycles/20260928-x/plan.md', 'outside this repository'],
    ['docs/cycles/2026-09-28-x/plan.md', 'not a cycle'],
    ['docs/cycles/20260928-Owner/plan.md', 'not a cycle'],
    ['docs/cycles/../cycles/20260928-x/plan.md', '".."'],
    ['docs/plans/feature.md', '/whip <path.md>'],
    [`docs/cycles/${ID}/retro.md`, 'not a cycle'],
    [`${ID}\nrm -rf /`, 'control character'],
    [`${TR}evil/docs/cycles/${ID}/plan.md`, 'outside this repository'],
  ]
  for (const [s, why] of refuse) {
    const r = pp(s)
    check(`planPath ${JSON.stringify(s)} is refused (${why})`, !r.ok && String(r.error).includes(why))
  }
}

// ---- lockPathOk: the guard in front of every rm -f ----
{
  check('lock guard accepts the one shape check writes', P.lockPathOk(LOCK, TR))
  check('...with a trailing slash on the root too', P.lockPathOk(LOCK, `${TR}/`))
  for (const bad of [`/tmp/.acfwhip/run/cycle-${ID}.decomposing`, `${TR}/.acfwhip/run/cycle-../../x.decomposing`,
    `${TR}/.acfwhip/run/cycle-${ID}.decomposing; rm -rf ~`, `${TR}/.acfwhip/run/cycle/${ID}/.lock`, `${TR}/.acfwhip/run/cycle-${ID}.decomposing\n`, '', null]) {
    check(`lock guard refuses ${JSON.stringify(bad)}`, !P.lockPathOk(bad, TR))
  }
  check('lock guard refuses everything with no trunk root', !P.lockPathOk(LOCK, ''))
  // Anchored on the cycle this run asked about: another cycle's lock has the right SHAPE, and removing
  // it would let a second decomposition of that cycle start over a live one.
  check('anchored: the lock of the cycle this run asked about passes', P.lockPathOk(LOCK, TR, ID))
  check('anchored: another cycle\'s lock is refused', !P.lockPathOk(`${TR}/.acfwhip/run/cycle-20260101-other.decomposing`, TR, ID))
  check('anchored: a malformed cycle id refuses everything', !P.lockPathOk(LOCK, TR, '../x'))
  check('anchored: the generic shape check still runs first', !P.lockPathOk(`/tmp/.acfwhip/run/cycle-${ID}.decomposing`, TR, ID))
}

// ---- parseCheck ----
{
  const g = P.parseCheck(goLine(), TR, ID)
  check('CHECK|go parses', g.verdict === 'go' && g.problems.length === 0)
  check('...with the frozen copy, content and lock', g.frozen === FROZEN && g.content === C12 && g.lock === LOCK && g.lockOk)
  check('...and the lock stamp the capture read back', g.held === HELD)
  check('no held= arrived: parses, but held is empty (the run will not release)', P.parseCheck(goLine({ held: null }), TR, ID).held === '')
  check('a held= that is not an epoch is empty too', P.parseCheck(goLine({ held: '12;rm' }), TR, ID).held === '' && P.parseCheck(goLine({ held: '' }), TR, ID).held === '')
  const other = P.parseCheck(goLine({ cycle: '20260101-other', lock: `${TR}/.acfwhip/run/cycle-20260101-other.decomposing` }), TR, ID)
  check('check answering for another cycle: a problem, and that cycle\'s lock is NOT releasable', other.problems.some((p) => p.includes('asked about')) && !other.lockOk)
  check('...and the deliverable lists in D order', g.uncovered.join() === 'D2,D3' && g.known.join() === 'D1,D2,D3' && g.coverage === 'on' && g.kind === 'feature')
  check('a relay with chatter around the line still finds it', P.parseCheck(`Here it is:\n${goLine()}\nThanks`, TR, ID).verdict === 'go')
  const outside = P.parseCheck(goLine({ lock: '/tmp/cycle-x.decomposing' }), TR, ID)
  check('go with a lock outside the repo: proceeds, but the lock is NOT releasable', outside.verdict === 'go' && outside.problems.length === 0 && !outside.lockOk)
  const probs = [
    [{ frozen: `${TR}/plan.md` }, 'frozen'],
    [{ frozen: `${TR}/.acfwhip/run/cycle/${ID}/000000000000.md` }, 'frozen'],
    [{ cycle: '20260101-other' }, 'asked about'],
    [{ content: 'XYZ' }, 'content'],
    [{ uncovered: '' }, 'no open deliverable'],
    [{ uncovered: 'D4', known: 'D1,D2' }, 'not among'],
    [{ uncovered: 'D2,x' }, 'malformed'],
    [{ coverage: 'maybe' }, 'coverage'],
  ]
  for (const [o, why] of probs) {
    const r = P.parseCheck(goLine(o), TR, ID)
    check(`go with ${JSON.stringify(o)} is unusable (${why})`, r.verdict === 'go' && r.problems.some((p) => p.includes(why)))
  }
  const off = P.parseCheck(goLine({ uncovered: '', known: '', coverage: 'off' }), TR, ID)
  check('coverage off with empty lists is a clean go', off.verdict === 'go' && off.problems.length === 0 && off.coverage === 'off' && off.uncovered.length === 0)
  const rf = P.parseCheck(`CHECK|refuse|cycle=${ID}|code=7|reason=a decomposition started 3m ago | if not running: rm ${LOCK}`, TR, ID)
  check('refuse parses with its code', rf.verdict === 'refuse' && rf.code === 7)
  check('...and a reason containing | survives whole', rf.reason === `a decomposition started 3m ago | if not running: rm ${LOCK}`)
  const np = P.parseCheck(`CHECK|noop|cycle=${ID}|reason=covered`, TR, ID)
  check('noop parses', np.verdict === 'noop' && np.reason === 'covered')
  const none = P.parseCheck('CHECK|none|rc=127|out=bash: acfw-cycle: No such file or directory', TR, ID)
  check('the capture fallback (no CHECK line) is malformed, with the exit code', none.verdict === 'malformed' && none.why.includes('exit 127'))
  check('garbage is malformed', P.parseCheck('I ran the command and it looked fine', TR, ID).verdict === 'malformed')
  check('nothing at all is malformed', P.parseCheck(undefined, TR, ID).verdict === 'malformed')
  check('an unknown verdict is malformed', P.parseCheck(`CHECK|maybe|cycle=${ID}`, TR, ID).verdict === 'malformed')
}

// ---- deliverable helpers ----
{
  check('normDs normalises, de-duplicates and orders', P.normDs(['D10', 'd2', 'D2: seat api', 'D1', 'AC1.2', null]).join() === 'D1,D2,D10')
  check('normDs never reads D12 as D1', P.normDs(['D12']).join() === 'D12')
  const cyc = P.parseCheck(goLine(), TR, ID)
  const t = { id: 'feature-010-seat-api', deliverables: ['D3', 'd2', 'D9'] }
  check('taskDs keeps only the plan\'s own ids', P.taskDs(t, cyc).join() === 'D2,D3')
  check('Documentation value: path list plus the (D<n>, ...) suffix', P.docValueFor(t, cyc, REL) === `${REL} (D2, D3)`)
  check('record arg: <stem>=<D1,D2>', P.recordArgFor(t, cyc) === 'feature-010-seat-api=D2,D3')
  check('Out of Scope boundary names the deliverables and read-only', P.oosLineFor(t, cyc, REL) === `Implement only D2, D3 of ${REL}; plan.md is read-only.`)
  const off = P.parseCheck(goLine({ uncovered: '', known: '', coverage: 'off' }), TR, ID)
  check('coverage off: Documentation is the bare path', P.docValueFor(t, off, REL) === REL)
  check('coverage off: record arg is <stem>=-', P.recordArgFor(t, off) === 'feature-010-seat-api=-')
  check('coverage off: the boundary still says read-only', /plan\.md is read-only\.$/.test(P.oosLineFor(t, off, REL)))
  const blk = P.planScopeBlock(cyc, REL)
  check('the scope block points at the FROZEN copy', blk.includes(FROZEN) && blk.includes(`content v1:${C12}`))
  check('...forbids the working-tree plan.md', blk.includes(`Never read ${REL} in the working tree`))
  check('...names only the open deliverables to decompose', blk.includes('Decompose ONLY these deliverables: D2, D3') && blk.includes('NOT part of this run: D1'))
  check('coverage off scope block says so', P.planScopeBlock(off, REL).includes('coverage is off'))
}

// ---- schemas: free text byte-identical, plan mode additive ----
{
  const HASH_TASK_STUB_342 = 'e29d4c7fcbafbc01f1223d20a396b8c6b28583eddcb4668647eff7510ead0d67'
  const HASH_DECOMP_342 = '9c5ca38c95c914194189147da411c7d8ba090109fc8ed9692f9aa9a3ef498895'
  check('TASK_STUB is byte-identical to 3.4.2', sha(JSON.stringify(P.TASK_STUB)) === HASH_TASK_STUB_342)
  check('DECOMPOSITION_PLAN is byte-identical to 3.4.2', sha(JSON.stringify(P.DECOMPOSITION_PLAN)) === HASH_DECOMP_342)
  check('no plan: the schema IS the 3.4.2 object', P.planSchemaFor(null) === P.DECOMPOSITION_PLAN)
  const off = P.parseCheck(goLine({ uncovered: '', known: '', coverage: 'off' }), TR, ID)
  check('coverage off: still the 3.4.2 object (no deliverables to name)', P.planSchemaFor(off) === P.DECOMPOSITION_PLAN)
  const cyc = P.parseCheck(goLine(), TR, ID)
  const s = P.planSchemaFor(cyc)
  const st = s.properties.tasks.items
  check('plan mode: stubs gain a deliverables array', st.properties.deliverables && st.properties.deliverables.type === 'array')
  check('...whose values can only be the plan\'s own D-ids', JSON.stringify(st.properties.deliverables.items.enum) === '["D1","D2","D3"]')
  check('...optional in the schema (the plan contract), enforced by validatePlan', !st.required.includes('deliverables'))
  check('...and additionalProperties stays false', st.additionalProperties === false)
  check('building it never mutates TASK_STUB', !P.TASK_STUB.properties.deliverables && sha(JSON.stringify(P.TASK_STUB)) === HASH_TASK_STUB_342)
  check('the plan writer schema requires the record line', P.WRITE_RESULT_PLAN.required.includes('record') && !P.WRITE_RESULT.required.includes('record'))
}

// ---- validatePlan ----
{
  const reg = AGENTS
  const cyc = P.parseCheck(goLine(), TR, ID)
  const mk = (ds) => ({ tasks: [stub({ id: 'feature-010-seat-api', worktreeSlug: 'seat-api', deliverables: ds })] })
  check('free text: a sound plan has no defects', P.validatePlan(FT_PLAN, reg).length === 0)
  check('free text: deliverables are ignored entirely', P.validatePlan({ tasks: [stub({ id: 'feature-010-a', worktreeSlug: 's', deliverables: ['nonsense'] })] }, reg).length === 0)
  // The 3.4.2 messages, verbatim, for a battery of broken free-text plans.
  const broken = { tasks: [
    stub({ id: 'feature-010-a', worktreeSlug: 'feature-010-a', priority: 'urgent', assignedAgent: 'ghost', dependencies: ['feature-010-a', 'feature-099-nope'] }),
    stub({ id: 'Bad_ID', worktreeSlug: 'none', touchesGlobs: ['none'] }),
    stub({ id: 'docs-001-x', isCodeMutating: false, worktreeSlug: 'docs' }),
    stub({ id: 'feature-011-b', worktreeSlug: 'b', dependencies: ['feature-012-c'] }),
    stub({ id: 'feature-012-c', worktreeSlug: 'c', dependencies: ['feature-011-b'] }),
  ] }
  check('free text: every 3.4.2 defect message is unchanged', sha(JSON.stringify(P.validatePlan(broken, reg))) === 'fa15c5e8395b2200dd8a79ea7f6ebe6c71a985d036116946ed3a9f9f1548625e')
  check('free text: an empty plan is still refused the 3.4.2 way', JSON.stringify(P.validatePlan({ tasks: [] }, reg)) === '["plan contains no tasks"]')

  check('plan: a task naming an open deliverable passes', P.validatePlan(mk(['D2']), reg, cyc).length === 0)
  check('plan: naming a covered one ALONGSIDE an open one passes', P.validatePlan(mk(['D1', 'D2']), reg, cyc).length === 0)
  check('plan: "d2" and "D2: seat api" normalise and pass', P.validatePlan(mk(['d2']), reg, cyc).length === 0 && P.validatePlan(mk(['D2: seat api']), reg, cyc).length === 0)
  const none = P.validatePlan(mk([]), reg, cyc)
  check('plan: a task naming no deliverable is a defect', none.some((d) => d.includes('names no deliverable')))
  check('plan: ...and a missing deliverables key is the same defect', P.validatePlan({ tasks: [stub({ id: 'feature-010-seat-api', worktreeSlug: 'seat-api' })] }, reg, cyc).some((d) => d.includes('names no deliverable')))
  const dup = P.validatePlan(mk(['D1']), reg, cyc)
  check('plan: a task whose deliverables are ALL covered is a duplicate defect', dup.length === 1 && dup[0].includes('duplicate of existing work'))
  check('plan: an unknown D-id is a defect', P.validatePlan(mk(['D2', 'D9']), reg, cyc).some((d) => d.includes('D9 is not a deliverable')))
  check('plan: an only-unknown task is also "names no deliverable"', P.validatePlan(mk(['D9']), reg, cyc).some((d) => d.includes('names no deliverable')))
  check('plan: a non-D token is a defect', P.validatePlan(mk(['D2', 'AC2.1']), reg, cyc).some((d) => d.includes('"AC2.1" is not a deliverable id')))
  const off = P.parseCheck(goLine({ uncovered: '', known: '', coverage: 'off' }), TR, ID)
  check('plan, coverage off: no deliverable rules apply', P.validatePlan(mk([]), reg, off).length === 0)
  // An id recon saw in the store: record-first would map someone else's task to this plan.
  const taken = ['feature-001-existing', 'feature-010-seat-api']
  const col = P.validatePlan(mk(['D2']), reg, cyc, taken)
  check('plan: a task reusing an existing id is a defect', col.length === 1 && col[0].includes('"feature-010-seat-api": id already belongs to an existing task'))
  check('plan: ...with coverage off too', P.validatePlan(mk([]), reg, off, taken).some((d) => d.includes('already belongs')))
  check('plan: an unused id with the existing list passes', P.validatePlan(mk(['D2']), reg, cyc, ['feature-001-existing']).length === 0)
  check('free text: the existing-id rule never applies (3.4.2 gate)', P.validatePlan(mk(['D2']), reg, undefined, taken).length === 0 && P.validatePlan(mk(['D2']), reg, null, taken).length === 0)
  check('plan: structural rules still apply on top', P.validatePlan({ tasks: [stub({ id: 'feature-010-x', worktreeSlug: 'feature-010-x', deliverables: ['D2'] })] }, reg, cyc).some((d) => d.includes('must NOT equal the task id')))

  // coverage gaps: advisory, computed not judged
  const plan2 = { tasks: [stub({ id: 'feature-010-seat-api', worktreeSlug: 'a', deliverables: ['D2'] })] }
  check('uncoveredBy names the open deliverable no task claims', P.uncoveredBy(plan2, cyc).join() === 'D3')
  check('...and nothing once every open one is claimed', P.uncoveredBy({ tasks: [stub({ id: 'feature-010-a', worktreeSlug: 'a', deliverables: ['D2', 'D3'] })] }, cyc).length === 0)
  check('...a covered deliverable is never a gap', !P.uncoveredBy(plan2, cyc).includes('D1'))
  check('...free text and coverage off have no gaps', P.uncoveredBy(plan2, null).length === 0 && P.uncoveredBy(plan2, off).length === 0)
  check('gap defects name the deliverable for the repair planner', /coverage gap: deliverable D3 .*"### D3"/.test(P.gapDefects(['D3'])[0]))
}

// ============================ 2. the line scan ============================
{
  const lines = text.split('\n')
  const aborts = []
  const holding = []
  const refusedReleasing = []
  lines.forEach((l, i) => {
    if (!/aborted: true/.test(l)) return
    aborts.push(i + 1)
    const window = lines.slice(Math.max(0, i - 6), i).join('\n')
    if (/stopReason: 'check-refused'/.test(l)) {
      // The refused path must NOT release: that lock, if any, belongs to another run.
      if (/releaseCycleLock\(/.test(window)) refusedReleasing.push(i + 1)
      return
    }
    if (!/await releaseCycleLock\(/.test(window)) holding.push(i + 1)
  })
  check(`the scan sees every abort (${aborts.length} found; non-vacuity floor 5)`, aborts.length >= 5)
  check(`every aborted return except check-refused releases the lock first (holding: ${holding.join(', ') || 'none'})`, holding.length === 0)
  const tagged = lines.filter((l) => /aborted: true/.test(l) && /stopReason: 'check-refused'/.test(l)).length
  check(`exactly one return is tagged check-refused (${tagged})`, tagged === 1)
  check(`...and it never releases (${refusedReleasing.join(', ') || 'none'})`, refusedReleasing.length === 0)

  const doc = text.slice(text.indexOf('const doctor = await agent('), text.indexOf("label: 'verify:doctor'"))
  check('the verify:doctor prompt carries the release', /\$\{DOCTOR_RELEASE\}/.test(doc))
  check('...which is the stamp-checked release of the guarded lock', /const DOCTOR_RELEASE = lockToRelease\s*\?\s*`[^`]*\$\{lockReleaseCmd\(lockToRelease\)\}/.test(text))
  check('...guarded again before it reaches the prompt', /const lockToRelease = lockReleasable\(cycleLock\) \? cycleLock : null/.test(text))
  check('the guard is path (anchored on this cycle) AND stamp', /function lockReleasable\(l\) \{\s*return !!\(l && lockPathOk\(l\.path, trunkRoot, planRef && planRef\.id\) && HELD_RE\.test\(l\.held \|\| ''\)\)/.test(text))
  check('the release removes the lock only while it carries this run\'s stamp', /function lockReleaseCmd\(l\) \{\s*return `if grep -qx \$\{sq\(`ts=\$\{l\.held\}`\)\} \$\{sq\(l\.path\)\} 2>\/dev\/null; then rm -f \$\{sq\(l\.path\)\}; fi`/.test(text))
  check('releaseCycleLock runs the guard before the release', /async function releaseCycleLock\([\s\S]{0,200}?lockReleasable\(l\)[\s\S]{0,200}?\$\{lockReleaseCmd\(l\)\}/.test(text))
  check('releaseCycleLock is shell tier', /\$\{lockReleaseCmd\(l\)\}`,\s*shellOpts\(\{ label: 'cycle:unlock'/.test(text))
  check('no bare rm -f of a lock path anywhere', !/rm -f \$\{sq\((p|lockToRelease|cycleLock|ck\.lock)\)\}/.test(text))
  check('the lock is taken only from a guarded, stamped CHECK|go', /if \(ck\.lockOk && ck\.held\) cycleLock = \{ path: ck\.lock, held: ck\.held \}/.test(text))
  check('CYCLE sits next to STORE and FOCUS, from the plugin root', /const CYCLE = `\$\{pluginRoot\}\/skills\/lib\/bin\/acfw-cycle`/.test(text))
  check('the judge prompt carries no lessons instruction (judge unchanged)',
    !/lessons/.test(text.slice(text.indexOf('Two or more independent planners'), text.indexOf("label: 'judge:plan'"))))
}

// ============================ 3. end to end: free text is 3.4.2 ============================
{
  const h = await freeTextHashes(text)
  const keys = Object.keys(GOLDEN)
  check(`the golden set is non-trivial (${keys.length} entries)`, keys.length >= 20)
  const drift = keys.filter((k) => h[k] !== GOLDEN[k])
  const extra = Object.keys(h).filter((k) => !(k in GOLDEN))
  check(`every free-text prompt, schema and report is byte-identical to 3.4.2 (drift: ${drift.join(', ') || 'none'})`, drift.length === 0)
  check(`free text dispatches no agent 3.4.2 did not (new: ${extra.join(', ') || 'none'})`, extra.length === 0)

  const ft = await runWorkflow(text, FT_ARGS('files'))
  const plannerP = ft.first('plan:0').prompt
  check('free text: planners read the lessons by reference', plannerP.includes(`Run \`cd '/r' && bash '/p/skills/lib/bin/acfw-cycle' lessons\` (read-only). Every rule it prints is a recorded lesson; copy a rule verbatim into the \`constraints\` of any task that walks into it.`))
  const criticP = ft.first('critic:completeness').prompt
  check('free text: the critic reads them too, with its bullet', criticP.includes("bash '/p/skills/lib/bin/acfw-cycle' lessons` (read-only). Every rule it prints is a recorded lesson.") && criticP.includes('* a task that walks into a recorded lesson without that rule in its constraints'))
  check('free text: no check, no record, no set, no release anywhere',
    !ft.calls.some((c) => /acfw-cycle' (check|record)|--no-resolve --by task [^']*set|acfw-focus' set|\.decomposing/.test(c.prompt)))
  check('free text: the Documentation bullet is still none', ft.byLabel(`author:feature-002-login-api`)[0].prompt.includes('- **Documentation**: none'))
  check('free text: no cycle block in the report', !('cycle' in ft.report))
}

// ============================ 3b. end to end: plan mode ============================
// One writer command per create, whole: the Documentation stamp's insert branch is sed's portable `a\` +
// NEWLINE + text form, so a single command spans two physical lines of the prompt.
const createCmds = (prompt) => prompt.split('\n  cd ').slice(1).map((s) => `  cd ${s.split('\n\n')[0]}`).filter((s) => /acfw-store' create /.test(s))
const PARGS = (store, o = {}) => Object.assign({ planPath: REL, pluginRoot: '/p', trunkRoot: TR, trunkBranch: 'main', store }, o)
const seatApi = (ds) => stub({ id: 'feature-010-seat-api', title: 'Seat API', worktreeSlug: 'seat-api', touchesGlobs: ['services/seat/**'], deliverables: ds })
const seatUi = (ds) => stub({ id: 'feature-011-seat-ui', title: 'Seat UI', assignedAgent: 'react-engineer', worktreeSlug: 'seat-ui', touchesGlobs: ['web/seat/**'], deliverables: ds })
const RECON = ['recon:backlog', 'recon:surface', 'recon:conventions']

// ---- files: gap -> repair -> recomputed ----
{
  // plan:0 covers only D2; plan:1 is a pure duplicate of covered D1 (invalid, so no judge round); the
  // critic finds nothing, the JS gap (D3) alone drives the repair round, and the repaired plan closes it.
  const r = await runWorkflow(text, PARGS('files'), {
    check: goLine(),
    planner: (c) => {
      if (c.label === 'plan:0') return { summary: 's', tasks: [seatApi(['D2'])] }
      if (c.label === 'plan:1') return { summary: 's', tasks: [seatApi(['D1'])] }
      return { summary: 's', tasks: [seatApi(['D2']), seatUi(['D3'])] }
    },
  })
  const rep = r.report
  check('plan/files: completes', rep && rep.phase === 'complete')
  const disc = r.first('discover-agents')
  check('the discover-agents shell agent runs check, given ${ENV}', disc.prompt.includes(`bash '/p/skills/lib/bin/acfw-cycle' check '${REL}'`) && disc.prompt.includes(`export ACFW_TRUNK_ROOT='${TR}'`))
  check('...still on the shell tier, with the plan schema', disc.opts.model === 'haiku' && disc.opts.schema.required.includes('check'))
  check('recon reads the frozen copy through the scope', r.first('recon:surface').prompt.includes(FROZEN))
  const pl = r.first('plan:0')
  check('planners read the frozen copy, never the working-tree file', pl.prompt.includes(`Read ONLY the frozen approved copy: ${FROZEN}`) && pl.prompt.includes(`Never read ${REL} in the working tree`))
  check('planners get only the uncovered deliverables', pl.prompt.includes('Decompose ONLY these deliverables: D2, D3') && pl.prompt.includes('NOT part of this run: D1'))
  check('planners get the DELIVERABLES rule', pl.prompt.includes('- DELIVERABLES (this run decomposes an approved plan)'))
  check('planners get the plan-mode schema', JSON.stringify(pl.opts.schema.properties.tasks.items.properties.deliverables.items.enum) === '["D1","D2","D3"]')
  check('planners read lessons by reference', pl.prompt.includes("acfw-cycle' lessons` (read-only)"))
  check('no judge round when only one plan is valid (the D1-only duplicate failed the gate)', r.byLabel('judge:plan').length === 0)
  const retry = r.byLabel('plan:retry0')
  check('the coverage gap drove exactly one repair round', retry.length === 1 && retry[0].prompt.includes('coverage gap: deliverable D3'))
  const critic = r.first('critic:completeness')
  check('the critic reads lessons and checks the plan\'s AC lines', critic.prompt.includes("acfw-cycle' lessons` (read-only)") && critic.prompt.includes('an acceptance criterion (AC lines) of D2, D3 in the frozen plan'))
  check('gaps are recomputed after the repair: none left', rep.cycle && Array.isArray(rep.cycle.coverageGaps) && rep.cycle.coverageGaps.length === 0)
  // The adopted branch used to reset `critique = []` and stop; a gap computed BEFORE the repair must not
  // survive it. The post-repair recompute is what keeps the operator's log from naming a closed gap.
  check('...and the log names no stale gap after an adopted repair', !r.logs.some((l) => /still ha(s|ve) no task after the repair round/.test(l)))
  check('the report carries the cycle', rep.cycle.id === ID && rep.cycle.plan === REL && rep.cycle.content === `v1:${C12}` && rep.cycle.decomposed.join() === 'D2,D3')
  check('created tasks carry their deliverables', JSON.stringify(rep.created.map((t) => t.deliverables)) === '[["D2"],["D3"]]')

  const au = r.first('author:feature-010-seat-api').prompt
  check('author: the Documentation bullet is stamped, not none', au.includes(`- **Documentation**: ${REL} (D2)`) && !au.includes('- **Documentation**: none'))
  check('author: the Out of Scope boundary is verbatim', au.includes(`- Implement only D2 of ${REL}; plan.md is read-only.`))
  check('author: pointed at the frozen copy for the AC lines', au.includes(`in the frozen approved copy ${FROZEN}`) && au.includes('"### D2" section(s)'))

  const w = r.first('write:commit')
  const p = w.prompt
  const iRec = p.indexOf("acfw-cycle' record")
  check('writer: record is the first command after cd', iRec > 0 && iRec < p.indexOf('2. Verify') && iRec < p.indexOf('git add') && iRec < p.indexOf('git commit'))
  check('writer: record maps each stem to its deliverables', p.includes(`record '${REL}' 'feature-010-seat-api=D2' 'feature-011-seat-ui=D3'`))
  check('writer: a refused record stops everything and parks the files', /If it exits non-zero, STOP HERE/.test(p) && p.includes(`.acfwhip/run/cycle/${ID}/unrecorded`))
  check('writer: the Documentation line is stamped next to the dependency stamp',
    p.indexOf("Documentation\\*\\*:' '.backlog/pending/feature-010-seat-api.md'") > p.indexOf("Dependencies\\*\\*:' '.backlog/pending/feature-010-seat-api.md'") && p.indexOf("Documentation\\*\\*:' '.backlog/pending/") < p.indexOf('4. Make sure'))
  check('writer: the focus is SET to the cycle, never added, one argument per stem ("$@", never a joined string)', p.includes("bash '/p/skills/lib/bin/acfw-focus' set --no-resolve --by task \"$@\"") && !/acfw-focus' add/.test(p) && !/by task \$K/.test(p))
  check('writer: the plan schema (record relayed)', w.opts.schema.required.includes('record'))
  check('writer: still shell tier', w.opts.model === 'haiku')
  // Record-first is shell, not obedience: the flag exists only after record exits 0, and every step that
  // stages, commits or focuses is behind it.
  const recLineF = p.split('\n').find((l) => /acfw-cycle' record /.test(l)) || ''
  check('writer: record clears the flag, checks lock ownership, then leaves the flag only on success',
    recLineF.includes(`rm -f '${FLAG}' && { grep -qx 'ts=${HELD}' '${LOCK}' 2>/dev/null || { echo 'LOCK|lost|cycle=${ID}|`) && /'feature-011-seat-ui=D3' && : > '[^']*\/recorded'$/.test(recLineF))
  check('writer: files stage and commit only behind the flag', p.includes(`5. Stage ONLY those files, plus .gitignore if step 4 changed it:  [ -e '${FLAG}' ] && git add `) && p.includes(`6. Commit once:  [ -e '${FLAG}' ] && git commit -q -m`))
  check('writer: the whole focus command is behind the flag (grouped, not just its first word)', p.includes(`[ -e '${FLAG}' ] && { cd '${TR}' && set --; for s in`) && /set --no-resolve --by task "\$@"; else echo "focus: left unchanged[^\n]*; fi; }\n/.test(p))
  check('writer: files relays dropped = []', w.opts.schema.required.includes('dropped') && p.includes('dropped = [] (a files-store run creates no task through the store)'))
  const d = r.first('verify:doctor').prompt
  check('doctor: releases the lock first, then runs the doctor', d.includes(REL_CMD()) && d.indexOf(REL_CMD()) < d.indexOf("acfw-store' doctor"))
  check('no separate unlock agent on the success path (it rides the doctor)', r.byLabel('cycle:unlock').length === 0)
  check('report: lock released, record landed', rep.cycle.lockReleased === true && rep.cycle.recorded === true)
  check('report: the focus is the cycle', /this plan's unfinished tasks/.test(rep.focus.note))
  check('report: nextStep is /go with no gap note', /^Run \/go: it runs this plan's unfinished tasks/.test(rep.nextStep) && !/coverage gap/.test(rep.nextStep))
}

// ---- files: a repair that fails structurally keeps the plan, and the gap is still recomputed ----
{
  const r = await runWorkflow(text, PARGS('files', { planners: 1 }), {
    check: goLine(),
    planner: (c) => (c.label === 'plan:0' ? { summary: 's', tasks: [seatApi(['D2'])] } : { summary: 's', tasks: [seatApi(['D1'])] }),
  })
  check('failed repair: the valid plan is kept', r.report.phase === 'complete' && r.report.created.length === 1)
  check('failed repair: the gap survives into the report (advisory, not an abort)', r.report.cycle.coverageGaps.join() === 'D3')
  check('failed repair: the recompute on the kept plan is logged', r.logs.some((l) => /coverage: D3 still has no task after the repair round/.test(l)))
  check('...and into nextStep, with the command that closes it', r.report.nextStep.includes(`D3 still has no task (coverage gap): re-run /task --plan ${REL}`))
  check('...and the lock is still released by the doctor', r.first('verify:doctor').prompt.includes(REL_CMD()))
}

// ---- non-files store ----
{
  const r = await runWorkflow(text, PARGS('multica'), {
    check: goLine(),
    planner: () => ({ summary: 's', tasks: [seatApi(['D2']), seatUi(['D3', 'D1'])] }),
  })
  const w = r.first('write:ingest')
  const p = w.prompt
  const iRec = p.indexOf("acfw-cycle' record")
  const iCreate = p.indexOf("acfw-store' create")
  check('ingest: record runs before the first create', iRec > 0 && iCreate > iRec)
  check('ingest: record carries every D a task names', p.includes("'feature-011-seat-ui=D1,D3'"))
  const staged = `${TR}/.acfwhip/run/staging/feature-010-seat-api.md`
  const iStamp = p.indexOf(`Documentation\\*\\*:' '${staged}'`)
  check('ingest: the STAGED file is stamped before its create', iStamp > 0 && iStamp < p.indexOf(`create --file '${staged}'`))
  check('ingest: Documentation never goes through --set', !/--set '[^']*Documentation/.test(p) && p.includes("--set 'Dependencies=none'"))
  check('ingest: the focus is set once at the end, not chained onto each create', p.includes("acfw-focus' set --no-resolve --by task") && !/acfw-focus' add/.test(p) && p.lastIndexOf("acfw-focus' set") > p.lastIndexOf("acfw-store' create"))
  check('ingest: plan schema', w.opts.schema.required.includes('record'))
  check('ingest: the doctor releases the lock', r.first('verify:doctor').prompt.includes(REL_CMD()))
  const creates = createCmds(p)
  check(`ingest: every create line cds, then runs only behind the record flag (${creates.length})`, creates.length === 2 && creates.every((l) => l.startsWith(`  cd '${TR}' && [ -e '${FLAG}' ] && {`)))
  check('ingest: an exit-4 create drops its stem from the record in the SAME command', creates.every((l, i) => {
    const id = i ? 'feature-011-seat-ui' : 'feature-010-seat-api'
    return l.includes(`rc=$?; [ $rc -ne 4 ] || { P=$(awk -v s='${id}' `) && l.includes(`record '${REL}' --drop '${id}' >/dev/null && echo 'DROPPED|${id}'`) && /; \[ \$rc -eq 0 \]; \} && rm -f '[^']*'$/.test(l)
  }))
  check('ingest: the record snapshot the drop reads is taken before record', (() => { const rl = p.split('\n').find((l) => /acfw-cycle' record '[^']*' 'feature/.test(l)) || ''; return rl.indexOf(`git show 'HEAD:docs/cycles/${ID}/record.md' > '${FLAG}.before'`) > 0 && rl.indexOf('.before') < rl.indexOf("acfw-cycle' record") })())
  check('ingest: the focus runs behind the flag', p.includes(`[ -e '${FLAG}' ] && { cd '${TR}' && set --; for s in`))
  check('ingest: the writer is told to relay DROPPED| ids', w.opts.schema.required.includes('dropped') && /Put each DROPPED\| id in dropped/.test(p))
}

// ---- coverage off ----
{
  const r = await runWorkflow(text, PARGS('files'), {
    check: goLine({ uncovered: '', known: '', coverage: 'off' }),
    planner: () => JSON.parse(JSON.stringify(FT_PLAN)),
  })
  check('coverage off: completes', r.report.phase === 'complete')
  check('coverage off: planners get the 3.4.2 schema', !r.first('plan:0').opts.schema.properties.tasks.items.properties.deliverables)
  check('coverage off: record maps each stem to -', r.first('write:commit').prompt.includes("'feature-002-login-api=-' 'feature-003-login-ui=-'"))
  check('coverage off: Documentation is the bare plan path', r.first('author:feature-002-login-api').prompt.includes(`- **Documentation**: ${REL}\n`))
  check('coverage off: no gaps are invented', r.report.cycle.coverageGaps.length === 0)
}

// ---- abort paths ----
{
  const noRecon = (r) => RECON.every((l) => r.byLabel(l).length === 0)

  const rf = await runWorkflow(text, PARGS('files'), { check: `CHECK|refuse|cycle=${ID}|code=6|reason=not approved at HEAD: re-approve with /whip ${ID}` })
  check('refuse: aborts tagged check-refused', rf.report.aborted === true && rf.report.stopReason === 'check-refused' && rf.report.code === 6)
  check('refuse: relays the reason', rf.report.reason.includes('not approved at HEAD'))
  check('refuse: before recon, and never releases', noRecon(rf) && rf.byLabel('cycle:unlock').length === 0 && rf.calls.length === 1)

  const lk = await runWorkflow(text, PARGS('files'), { check: `CHECK|refuse|cycle=${ID}|code=7|reason=a decomposition started 4m ago; if no longer running: rm ${LOCK}` })
  check('lock held by another run: refused, and that run\'s lock is NOT removed', lk.report.stopReason === 'check-refused' && lk.calls.length === 1 && !lk.calls.some((c) => c.prompt.includes(`rm -f '${LOCK}'`)))

  const mf = await runWorkflow(text, PARGS('files'), { check: 'The command ran successfully.' })
  check('malformed relay: aborts check-refused, no release, no recon', mf.report.stopReason === 'check-refused' && noRecon(mf) && mf.byLabel('cycle:unlock').length === 0)
  check('malformed relay: names the lock path to clear if it is stale', mf.report.reason.includes(LOCK))

  const ms = await runWorkflow(text, PARGS('files'), { check: 'CHECK|none|rc=127|out=bash: /p/skills/lib/bin/acfw-cycle: No such file or directory' })
  check('acfw-cycle missing: aborts check-refused with the exit code', ms.report.stopReason === 'check-refused' && ms.report.reason.includes('exit 127'))

  const np = await runWorkflow(text, PARGS('files'), { check: `CHECK|noop|cycle=${ID}|reason=covered` })
  check('noop: a clean no-op report, not an abort', np.report.phase === 'noop' && !np.report.aborted && np.report.created.length === 0)
  check('noop: zero agents after the check, no release', np.calls.length === 1 && /already has tasks/.test(np.report.nextStep))

  const re = await runWorkflow(text, PARGS('files'), { check: goLine(), agents: [] })
  const un = re.byLabel('cycle:unlock')
  check('go + empty registry: aborts and releases the lock it took', re.report.aborted === true && un.length === 1 && un[0].prompt.includes(REL_CMD()))
  check('...on the shell tier, before any recon', un[0].opts.model === 'haiku' && noRecon(re))

  const bp = await runWorkflow(text, PARGS('files'), { check: goLine({ frozen: `${TR}/docs/cycles/${ID}/plan.md` }) })
  check('go with an unusable payload: aborts AND releases (it holds the lock)', bp.report.aborted === true && bp.byLabel('cycle:unlock').length === 1 && noRecon(bp))
  check('...naming the problem', /frozen/.test(bp.report.reason))

  const ev = await runWorkflow(text, PARGS('files'), { check: goLine({ lock: '/etc/passwd' }), planner: () => ({ summary: 's', tasks: [seatApi(['D2']), seatUi(['D3'])] }) })
  check('go with a lock path that fails the guard: runs, and NOTHING rm -fs it', ev.report.phase === 'complete' && !ev.calls.some((c) => /rm -f '\/etc\/passwd'/.test(c.prompt)))
  check('...the report says the lock was not released, and a WARN was logged', ev.report.cycle.lockReleased === false && ev.logs.some((l) => /will not remove it/.test(l)))

  const vf = await runWorkflow(text, PARGS('files', { planners: 1 }), { check: goLine(), planner: () => ({ summary: 's', tasks: [seatApi(['D1'])] }) })
  const vu = vf.byLabel('cycle:unlock')
  check('validation failure: aborts with the duplicate defect', vf.report.aborted === true && vf.report.defects.some((d) => d.includes('duplicate of existing work')))
  check('...after the bounded retries, releasing the lock last', vu.length === 1 && vu[0].i === vf.calls.length - 1 && vf.byLabel('plan:retry0').length === 2)
  check('...and writes nothing', vf.byLabel('write:commit').length === 0 && vf.byLabel('verify:doctor').length === 0)

  const ip = await runWorkflow(text, PARGS('files', { planPath: 'docs/plans/feature.md' }))
  check('invalid planPath: aborts with an error before any agent', ip.report.aborted === true && /not a cycle/.test(ip.report.error) && ip.calls.length === 0)
  const oo = await runWorkflow(text, PARGS('files', { planPath: `/elsewhere/docs/cycles/${ID}/plan.md` }))
  check('planPath outside the repo: aborts before any agent', oo.report.aborted === true && /outside this repository/.test(oo.report.error) && oo.calls.length === 0)
  const both = await runWorkflow(text, PARGS('files', { scope: 'also add a button' }))
  check('planPath plus free text: refused, never merged, before any agent', both.report.aborted === true && /nothing else/.test(both.report.error) && both.calls.length === 0)
  const nothing = await runWorkflow(text, { pluginRoot: '/p', trunkRoot: TR })
  check('neither scope nor planPath: the args error, no agent', /requires args\.scope \(or args\.planPath\)/.test(nothing.report.error) && nothing.calls.length === 0)

  const rr = await runWorkflow(text, PARGS('files'), {
    check: goLine(),
    planner: () => ({ summary: 's', tasks: [seatApi(['D2']), seatUi(['D3'])] }),
    writer: () => ({ committed: false, commitSha: 'n/a', files: [], note: 'record refused', record: 'FATAL: git state refuses: off the trunk branch (exit 5)' }),
  })
  check('record refused: nothing created, said plainly', rr.report.cycle.recorded === false && /^Nothing was created: acfw-cycle record did not accept/.test(rr.report.nextStep))
  check('...names where the authored files went', rr.report.nextStep.includes(`.acfwhip/run/cycle/${ID}/unrecorded/`))
  check('...all open deliverables are still gaps', rr.report.cycle.coverageGaps.join() === 'D2,D3')
  check('...and the doctor still releases the lock', rr.first('verify:doctor').prompt.includes(REL_CMD()))
  // The report must not contradict nextStep: nothing was created, so nothing is listed as created and
  // the focus was never touched (the writer's flag gate stopped the focus step).
  check('...created is empty, not the authored list', Array.isArray(rr.report.created) && rr.report.created.length === 0)
  check('...the authored ids are named as unrecorded instead', rr.report.cycle.unrecorded.join() === 'feature-010-seat-api,feature-011-seat-ui')
  check('...the focus is reported unchanged, count 0', rr.report.focus.count === 0 && /^unchanged: nothing was created$/.test(rr.report.focus.note))

  const za = await runWorkflow(text, PARGS('files'), { check: goLine(), planner: () => ({ summary: 's', tasks: [seatApi(['D2']), seatUi(['D3'])] }), authorWritten: () => false })
  check('zero authored: no writer, no record', za.byLabel('write:commit').length === 0 && !za.calls.some((c) => /acfw-cycle' record/.test(c.prompt)))
  check('zero authored: the always-run doctor releases the lock', za.first('verify:doctor').prompt.includes(REL_CMD()) && za.byLabel('cycle:unlock').length === 0)
  check('zero authored: nextStep says so', /no task document was authored/.test(za.report.nextStep))
  check('zero authored: the focus is reported unchanged', za.report.focus.count === 0 && /^unchanged/.test(za.report.focus.note) && za.report.created.length === 0)

  // ---- lock ownership ----
  // check answered for ANOTHER cycle: a payload problem, and that cycle's lock (the right shape, the
  // wrong cycle) is never handed to rm.
  const oc = await runWorkflow(text, PARGS('files'), { check: goLine({ cycle: '20260101-other', lock: `${TR}/.acfwhip/run/cycle-20260101-other.decomposing`, frozen: `${TR}/.acfwhip/run/cycle/20260101-other/${C12}.md` }) })
  check('check answered for another cycle: aborts before recon', oc.report.aborted === true && /asked about/.test(oc.report.reason) && noRecon(oc))
  check('...and never removes that cycle\'s lock', oc.byLabel('cycle:unlock').length === 0 && !oc.calls.some((c) => /cycle-20260101-other\.decomposing/.test(c.prompt) && /rm -f/.test(c.prompt) && c.label !== 'discover-agents'))

  // No held= stamp arrived: the run proceeds but can prove nothing about the lock, so it never removes it
  // and does not gate record on it.
  const nh = await runWorkflow(text, PARGS('files'), { check: goLine({ held: null }), planner: () => ({ summary: 's', tasks: [seatApi(['D2']), seatUi(['D3'])] }) })
  check('no held stamp: runs to completion', nh.report.phase === 'complete' && nh.report.cycle.recorded === true)
  check('...WARNs and never releases', nh.logs.some((l) => /no held= stamp/.test(l)) && nh.report.cycle.lockReleased === false && !nh.first('verify:doctor').prompt.includes(LOCK))
  check('...and record carries no ownership guard it cannot evaluate', (() => { const l = nh.first('write:commit').prompt.split('\n').find((x) => /acfw-cycle' record /.test(x)) || ''; return l.length > 0 && !l.includes('grep -qx') && !l.includes('LOCK|lost') })())

  // The lock was taken over while this run was planning: the record command's guard prints LOCK|lost
  // and exits non-zero, so nothing is recorded or created.
  const ll = await runWorkflow(text, PARGS('multica'), {
    check: goLine(),
    planner: () => ({ summary: 's', tasks: [seatApi(['D2']), seatUi(['D3'])] }),
    writer: () => ({ committed: false, commitSha: 'n/a', files: [], note: 'record refused', dropped: [], record: `LOCK|lost|cycle=${ID}|reason=this run no longer holds the decomposition lock` }),
  })
  check('lock lost: nothing created, and nextStep says another run took it over', ll.report.cycle.recorded === false && ll.report.created.length === 0 && /another \/task --plan took over this plan's decomposition lock/.test(ll.report.nextStep))
  check('...no files-store parking note on a non-files store', !/unrecorded/.test(ll.report.nextStep))
  check('...and the doctor release is still stamp-checked (it leaves the new owner\'s lock alone)', ll.first('verify:doctor').prompt.includes(REL_CMD()))

  // ---- duplicate ids ----
  // The writer relays the stems its create lines dropped (exit 4): they are someone else's tasks.
  const dp = await runWorkflow(text, PARGS('multica'), {
    check: goLine(),
    planner: () => ({ summary: 's', tasks: [seatApi(['D2']), seatUi(['D3'])] }),
    writer: () => ({ committed: false, commitSha: 'n/a', files: [], note: 'feature-011-seat-ui: already exists (exit 4)', dropped: ['DROPPED|feature-011-seat-ui'], record: `RECORD|ok|cycle=${ID}|tasks=2` }),
  })
  check('dropped: never reported as created', dp.report.created.map((t) => t.id).join() === 'feature-010-seat-api' && dp.report.cycle.dropped.join() === 'feature-011-seat-ui')
  check('...its deliverable is a coverage gap again', dp.report.cycle.coverageGaps.join() === 'D3')
  check('...nextStep names the drop and the gap', /feature-011-seat-ui already belonged to existing tasks/.test(dp.report.nextStep) && /D3 still has no task/.test(dp.report.nextStep))
  check('...the focus counts only what was created', dp.report.focus.count === 1)

  // recon saw the id in the store: the gate refuses it before anything is written (bounded repair).
  const rc = await runWorkflow(text, PARGS('files', { planners: 1 }), {
    check: goLine(),
    on: { 'recon:backlog': () => ({ ids: ['feature-001-existing', 'feature-011-seat-ui'], slugsInUse: [], liveBranches: [], note: '' }) },
    planner: (c) => (c.label === 'plan:0'
      ? { summary: 's', tasks: [seatApi(['D2']), seatUi(['D3'])] }
      : { summary: 's', tasks: [seatApi(['D2']), stub({ id: 'feature-012-seat-ui', title: 'Seat UI', assignedAgent: 'react-engineer', worktreeSlug: 'seat-ui', touchesGlobs: ['web/seat/**'], deliverables: ['D3'] })] }),
  })
  const rcRetry = rc.byLabel('plan:retry0')
  check('existing id from recon: sent back through the repair loop', rcRetry.length >= 1 && rcRetry[0].prompt.includes('"feature-011-seat-ui": id already belongs to an existing task'))
  check('...and the renamed task is what gets recorded', rc.report.phase === 'complete' && rc.first('write:commit').prompt.includes("'feature-012-seat-ui=D3'") && !rc.first('write:commit').prompt.includes("'feature-011-seat-ui=D3'"))
  const ft2 = await runWorkflow(text, FT_ARGS('files'), { on: { 'recon:backlog': () => ({ ids: ['feature-002-login-api'], slugsInUse: [], liveBranches: [], note: '' }) } })
  check('free text: an existing id is NOT a gate defect (3.4.2 behaviour kept)', ft2.report.phase === 'complete' && ft2.byLabel('plan:retry0').length === 0)
}

// ============================ 4. the shell, executed for real ============================
// /bin/bash is 3.2 on macOS with BSD awk/sed; that is the floor these commands must run on.
const BASH = existsSync('/bin/bash') ? '/bin/bash' : 'bash'
// The writer runs these in ITS shell, which on macOS is zsh by default. zsh does not word-split an unquoted
// $VAR, which once made the cycle focus hand acfw-focus every stem as ONE argument while every /bin/bash
// run passed, so the focus commands run under zsh too (-f: no rc files, zsh's default options).
const ZSH = ['/bin/zsh', '/usr/bin/zsh'].find((p) => existsSync(p)) || ''
function sh(cmd, cwd, env = {}, shell = BASH) {
  const r = spawnSync(shell, shell === ZSH ? ['-f', '-c', cmd] : ['-c', cmd], { cwd, env: Object.assign({}, process.env, env), encoding: 'utf8' })
  return { code: r.status, out: r.stdout || '', err: r.stderr || '' }
}
if (!ZSH) {
  if (process.platform === 'darwin') bad('zsh not found on macOS: the zsh runs of the cycle focus cannot run')
  else console.log('  SKIP: zsh not installed: the zsh runs of the cycle focus did not run (bash runs still do)')
}
const scratch = mkdtempSync(join(tmpdir(), 'phase20-'))
try {
  const repo = join(scratch, 'repo')
  const plug = join(scratch, 'plugin')
  const bin = join(plug, 'skills', 'lib', 'bin')
  mkdirSync(bin, { recursive: true })
  mkdirSync(join(repo, '.backlog', 'pending'), { recursive: true })
  mkdirSync(join(repo, 'docs', 'cycles', ID), { recursive: true })
  const git = (...a) => execFileSync('git', a, { cwd: repo, encoding: 'utf8' })
  git('init', '-q', '-b', 'main')
  git('config', 'user.email', 't@example.com')
  git('config', 'user.name', 'T')
  git('config', 'commit.gpgsign', 'false')
  // The record as acfw-cycle writes it: a Plan Log row whose third cell LOOKS like a stem proves the
  // parse stops at the end of ## Tasks.
  writeFileSync(join(repo, 'docs', 'cycles', ID, 'record.md'), [
    '# Cycle Record: Owner seat', '## Metadata', '- **Format**: 1', `- **ID**: ${ID}`, '',
    '## Tasks', '<!-- DO NOT EDIT MANUALLY - acfw-cycle writes this section -->',
    '| Deliverable | Tasks |', '|---|---|',
    '| D1 | feature-001-old-done, feature-004-old-open |',
    '| D2 | feature-010-seat-api, feature-012-archived |',
    '| D3 | feature-011-seat-ui, feature-013-unreadable, feature-014 |', '',
    '## Plan Log', '| Date Time | Event | By | Content | Details |', '|---|---|---|---|---|',
    '| 2026-09-28 10:00:00 | decomposed | feature-999-not-a-task | abc | x |', '',
  ].join('\n'))
  git('add', '-A')
  git('commit', '-q', '-m', 'seed')
  const logf = join(scratch, 'calls.log')
  // Fake acfw-store: `read` answers like the files adapter (compact JSON, "folder" = whip state).
  writeFileSync(join(bin, 'acfw-store'), `#!/usr/bin/env bash
[ "$1" = read ] || exit 2
case "$2" in
  feature-001-old-done) f=accepted ;; feature-012-archived) f=archive ;;
  feature-004-old-open|feature-010-seat-api|feature-011-seat-ui) f=pending ;;
  feature-014) printf '{"stem":"feature-014-other-task","folder":"pending"}\\n'; exit 0 ;;
  *) echo "FATAL: no task matching '$2'" >&2; exit 3 ;;
esac
printf '{"stem":"%s","folder":"%s","fields":{}}\\n' "$2" "$f"
`)
  writeFileSync(join(bin, 'acfw-focus'), `#!/usr/bin/env bash
printf 'focus %s\\n' "$*" >> '${logf}'
printf 'focus-argc %s\\n' "$#" >> '${logf}'
`)
  // Fake acfw-cycle: check prints a WARN on stderr first and human text after, like the real one may, and
  // on go writes the lock the way the real one does (ts=<epoch>), which the capture reads back as held=.
  writeFileSync(join(bin, 'acfw-cycle'), `#!/usr/bin/env bash
case "$1" in
  check)
    if [ -n "\${FAKE_CHECK_SILENT:-}" ]; then echo "boom|pipe" >&2; exit 7; fi
    if [ -n "\${FAKE_CHECK_REFUSE:-}" ]; then echo "CHECK|refuse|cycle=${ID}|code=7|reason=held by another run"; exit 7; fi
    echo "WARN: approval trailer missing (squash?)" >&2
    mkdir -p "\$ACFW_TRUNK_ROOT/.acfwhip/run" && printf 'ts=1790000123\\n' > "\$ACFW_TRUNK_ROOT/.acfwhip/run/cycle-${ID}.decomposing"
    printf 'CHECK|go|cycle=${ID}|content=${C12}|frozen=%s|lock=%s|uncovered=D2,D3|known=D1,D2,D3|coverage=on|kind=feature\\n' "$ACFW_TRUNK_ROOT/.acfwhip/run/cycle/${ID}/${C12}.md" "$ACFW_TRUNK_ROOT/.acfwhip/run/cycle-${ID}.decomposing"
    echo "STATUS decomposing D2, D3"
    ;;
  record) shift; printf 'record %s\\n' "$*" >> '${logf}'; echo "RECORD|ok|cycle=${ID}|tasks=2" ;;
  *) exit 2 ;;
esac
`)
  for (const f of ['acfw-store', 'acfw-focus', 'acfw-cycle']) chmodSync(join(bin, f), 0o755)

  const run = await runWorkflow(text, PARGS('files', { pluginRoot: plug, trunkRoot: repo }), {
    on: {
      'discover-agents': (c) => {
        // Execute the prompt's own command and relay what it printed, exactly as the shell agent would.
        const cmd = (c.prompt.split('\n').find((l) => /acfw-cycle' check /.test(l)) || '').trim()
        const envLine = c.prompt.split('\n')[0].replace(/^.*?(export ACFW_TRUNK_ROOT=)/, '$1')
        const r = sh(`${envLine}\n${cmd}`, repo)
        return { agents: AGENTS, check: r.out }
      },
    },
    planner: () => ({ summary: 's', tasks: [seatApi(['D2']), seatUi(['D3'])] }),
  })
  const discCmd = (run.first('discover-agents').prompt.split('\n').find((l) => /acfw-cycle' check /.test(l)) || '').trim()
  check('shell: the CHECK capture relays exactly the one machine line (stderr WARN and trailing text dropped)', run.report.phase === 'complete' && run.report.cycle.content === `v1:${C12}`)
  const silent = sh(discCmd, repo, { ACFW_TRUNK_ROOT: repo, FAKE_CHECK_SILENT: '1' })
  check('shell: no CHECK line still yields one (verdict none, exit code, | defanged)', silent.out === 'CHECK|none|rc=7|out=boom/pipe\n')
  check('shell: which parses as malformed, never as go', P.parseCheck(silent.out, repo, ID).verdict === 'malformed')

  const wp = run.first('write:commit').prompt
  // record-first, as the writer would run it
  const recLine = (wp.split('\n').find((l) => /acfw-cycle' record /.test(l)) || '').trim()
  const rr = sh(recLine, repo)
  check('shell: the record command runs and prints RECORD|', rr.code === 0 && /^RECORD\|ok\|/.test(rr.out))
  // Documentation stamps (both branches of the if), as the writer would run them
  const stamps = [...wp.matchAll(/ {3}(if grep -qE '\^- \\\*\\\*Documentation[\s\S]*?rm -f '[^']*\.bak')/g)].map((m) => m[1])
  check(`shell: one Documentation stamp per task (${stamps.length})`, stamps.length === 2)
  writeFileSync(join(repo, '.backlog', 'pending', 'feature-010-seat-api.md'), '# Task: Seat API\n## Metadata\n- **ID**: feature-010-seat-api\n- **Status**: pending\n- **Documentation**: none\n## Description\nx\n')
  writeFileSync(join(repo, '.backlog', 'pending', 'feature-011-seat-ui.md'), '# Task: Seat UI\n## Metadata\n- **ID**: feature-011-seat-ui\n- **Status**: pending\n## Description\nx\n')
  for (const s of stamps) { const r = sh(s, repo); if (r.code !== 0) bad(`stamp failed: ${r.err}`) }
  const a = readFileSync(join(repo, '.backlog', 'pending', 'feature-010-seat-api.md'), 'utf8')
  const b = readFileSync(join(repo, '.backlog', 'pending', 'feature-011-seat-ui.md'), 'utf8')
  check('shell: an authored "Documentation: none" is replaced', a.includes(`- **Documentation**: ${REL} (D2)\n`) && !a.includes('Documentation**: none'))
  check('shell: a missing Documentation line is inserted after Status', b.includes(`- **Status**: pending\n- **Documentation**: ${REL} (D3)\n`))
  check('shell: no .bak is left behind', !existsSync(join(repo, '.backlog', 'pending', 'feature-010-seat-api.md.bak')) && !existsSync(join(repo, '.backlog', 'pending', 'feature-011-seat-ui.md.bak')))
  // The dependency stamp shares the insert form, and its insert branch is the silent-loss fallback
  // (an author that omitted the line): through 3.4.3 it rendered a form GNU and BSD sed both reject.
  const depStampCmds = [...wp.matchAll(/ {3}(if grep -qE '\^- \\\*\\\*Dependencies[\s\S]*?rm -f '[^']*\.bak')/g)].map((m) => m[1])
  check(`shell: one Dependencies stamp per task (${depStampCmds.length})`, depStampCmds.length === 2)
  writeFileSync(join(repo, '.backlog', 'pending', 'feature-011-seat-ui.md'), '# Task: Seat UI\n## Metadata\n- **ID**: feature-011-seat-ui\n- **Status**: pending\n## Description\nx\n')
  const ds = sh(depStampCmds[1], repo)
  check('shell: a missing Dependencies line is inserted after Status (both seds)', ds.code === 0 && !/sed:/.test(ds.err)
    && readFileSync(join(repo, '.backlog', 'pending', 'feature-011-seat-ui.md'), 'utf8').includes('- **Status**: pending\n- **Dependencies**: none\n'))
  // the cycle focus, as the writer would run it
  const focusLine = (wp.split('\n').find((l) => /acfw-focus' set /.test(l)) || '').trim()
  const fr = sh(focusLine, repo)
  const calls = existsSync(logf) ? readFileSync(logf, 'utf8') : ''
  const setLine = calls.split('\n').find((l) => l.startsWith('focus ')) || ''
  check('shell: the focus is set to the cycle\'s unfinished tasks, from the record',
    setLine === 'focus set --no-resolve --by task feature-004-old-open feature-010-seat-api feature-011-seat-ui')
  check('shell: accepted and archived tasks are left out', !/old-done|archived/.test(setLine))
  check('shell: a stem the store cannot read is left out, and said', !/unreadable/.test(setLine) && /skipped feature-013-unreadable \(the store could not read it\)/.test(fr.out))
  check('shell: a prefix the store resolved to ANOTHER task is left out, and said', !/feature-014\b/.test(setLine) && /skipped feature-014 \(the store answered for a different task\)/.test(fr.out))
  check('shell: the Plan Log is not read as the task map', !/feature-999/.test(setLine))
  check('shell: the ## Tasks header and separator rows are never read as stems', !/skipped (Tasks|Deliverable|-+)\b/.test(fr.out) && !/\b(Tasks|Deliverable)\b/.test(setLine))
  check('shell: acfw-focus gets one argument per stem (bash)', /^focus-argc 7$/m.test(calls))
  // The focus filter must accept exactly the stems `acfw-cycle record` accepts (acfw_stem_ok). A
  // narrower filter drops a recorded stem from the /go focus silently. Both are run, not compared as text.
  {
    const re = (focusLine.match(/grep -E '(\^[^']*\$)'/) || [])[1] || ''
    const corpus = ['feature-010-seat-api', 'API-7-token', 'fix_1.2', 'a', '9x', 'Ab.C_d-e', '-x', '.x', '_x', 'a b', 'a/b', 'a|b', 'a:b', 'a+b']
    const viaFilter = re ? spawnSync('/bin/bash', ['-c', `printf '%s\\n' "$@" | grep -E '${re}'`, 'x', ...corpus], { encoding: 'utf8' }).stdout.split('\n').filter(Boolean) : []
    const lib = join(ROOT, 'skills', 'lib', 'acfw-plan.sh')
    const viaLib = spawnSync('/bin/bash', ['-c', `. '${lib}'; for s in "$@"; do acfw_stem_ok "$s" && printf '%s\\n' "$s"; done`, 'x', ...corpus], { encoding: 'utf8' }).stdout.split('\n').filter(Boolean)
    check(`shell: the focus filter accepts exactly the stems record accepts (filter: ${viaFilter.join(' ')} | acfw_stem_ok: ${viaLib.join(' ')})`,
      re !== '' && viaLib.length >= 6 && JSON.stringify(viaFilter) === JSON.stringify(viaLib))
  }
  if (ZSH) {
    const before = readFileSync(logf, 'utf8')
    writeFileSync(logf, '')
    const frz = sh(focusLine, repo, {}, ZSH)
    const cz = readFileSync(logf, 'utf8')
    check(`shell, zsh: the same focus, one argument per stem (${cz.trim().replace(/\n/g, ' / ')})`,
      cz.split('\n').find((l) => l.startsWith('focus ')) === setLine && /^focus-argc 7$/m.test(cz))
    check('shell, zsh: the same skips, said the same way', frz.out === fr.out)
    writeFileSync(logf, before)
  }
  check('shell: record argv is <plan> then <stem>=<Ds>', calls.includes(`record ${REL} feature-010-seat-api=D2 feature-011-seat-ui=D3`))
  // the lock the doctor removes is the one check reported, under this repo, and only with its stamp
  const lockF = join(repo, '.acfwhip', 'run', `cycle-${ID}.decomposing`)
  const flagF = join(repo, '.acfwhip', 'run', 'cycle', ID, 'recorded')
  const dp = run.first('verify:doctor').prompt
  check('shell: the capture read the stamp back and the run released with it', run.report.cycle.lockReleased === true && dp.includes(REL_CMD(lockF, '1790000123')))
  const relCmd = (dp.match(/(if grep -qx 'ts=[^\n]*?; fi)/) || [])[1] || ''
  check('shell: the record command left the flag (record exited 0)', existsSync(flagF))
  writeFileSync(lockF, 'ts=1790009999\n')
  const relOther = sh(relCmd, repo)
  check('shell: the release leaves a lock carrying ANOTHER run\'s stamp alone, and exits 0', relOther.code === 0 && existsSync(lockF))
  writeFileSync(lockF, 'ts=1790000123\n')
  const relOwn = sh(relCmd, repo)
  check('shell: ...and removes the lock carrying this run\'s stamp', relOwn.code === 0 && !existsSync(lockF))
  check('shell: with no lock at all it is a quiet no-op', sh(relCmd, repo).code === 0)

  // The ownership guard in front of record: once the lock carries another stamp (taken over after the
  // 30-minute window) or is gone, record never runs and the flag never appears.
  writeFileSync(logf, '')
  writeFileSync(lockF, 'ts=1790009999\n')
  const lost = sh(recLine, repo)
  check('shell: lock taken over: LOCK|lost, non-zero, no record call, no flag', lost.code !== 0 && /^LOCK\|lost\|cycle=/.test(lost.out) && !/record /.test(readFileSync(logf, 'utf8')) && !existsSync(flagF))
  rmSync(lockF, { force: true })
  const gone = sh(recLine, repo)
  check('shell: lock removed as stale: the same refusal', gone.code !== 0 && /^LOCK\|lost\|/.test(gone.out) && !existsSync(flagF))
  // The flag gate: with no flag, the focus step does nothing at all (not merely its first word).
  writeFileSync(logf, '')
  const gatedFocus = sh(focusLine, repo)
  check('shell: no record flag: the focus command runs nothing', gatedFocus.code !== 0 && readFileSync(logf, 'utf8') === '' && gatedFocus.out === '')
  if (ZSH) { const gz = sh(focusLine, repo, {}, ZSH); check('shell, zsh: no record flag: the focus command runs nothing', gz.code !== 0 && readFileSync(logf, 'utf8') === '' && gz.out === '') }
  // A record that exits non-zero leaves no flag either (the flag is written by `&& : >`).
  writeFileSync(lockF, 'ts=1790000123\n')
  writeFileSync(join(bin, 'acfw-cycle.real-fake'), readFileSync(join(bin, 'acfw-cycle'), 'utf8'))
  writeFileSync(join(bin, 'acfw-cycle'), '#!/usr/bin/env bash\necho "REFUSED (5): off the trunk branch" >&2; exit 5\n')
  const refusedRec = sh(recLine, repo)
  check('shell: record refused: non-zero and no flag', refusedRec.code === 5 && !existsSync(flagF))
  writeFileSync(join(bin, 'acfw-cycle'), readFileSync(join(bin, 'acfw-cycle.real-fake'), 'utf8'))
  // The capture: on go it clears a flag an earlier run left and appends held=; on a refusal it touches
  // neither (that lock and that flag may be another run's).
  mkdirSync(dirname(flagF), { recursive: true })
  writeFileSync(flagF, '')
  const capRefuse = sh(discCmd, repo, { ACFW_TRUNK_ROOT: repo, FAKE_CHECK_REFUSE: '1' })
  check('shell: capture on refuse relays the line unchanged and leaves the flag', /^CHECK\|refuse\|/.test(capRefuse.out) && !/held=/.test(capRefuse.out) && existsSync(flagF))
  const capGo = sh(discCmd, repo, { ACFW_TRUNK_ROOT: repo })
  check('shell: capture on go appends the stamp it read back and clears a stale flag', /\|kind=feature\|held=1790000123\n$/.test(capGo.out) && !existsSync(flagF))
  check('shell: ...and what it relays parses as releasable', (() => { const g = P.parseCheck(capGo.out, repo, ID); return g.verdict === 'go' && g.lockOk && g.held === '1790000123' })())

  // a record with no unfinished task leaves the focus alone rather than calling set with nothing
  writeFileSync(join(repo, 'docs', 'cycles', ID, 'record.md'), '## Tasks\n| Deliverable | Tasks |\n|---|---|\n| D1 | feature-001-old-done |\n')
  git('commit', '-q', '-am', 'all done')
  writeFileSync(logf, '')
  writeFileSync(flagF, '') // as a record that exited 0 leaves it
  const fr2 = sh(focusLine, repo)
  check('shell: an all-finished cycle leaves the focus unchanged', readFileSync(logf, 'utf8') === '' && /left unchanged/.test(fr2.out))
  if (ZSH) { const fz2 = sh(focusLine, repo, {}, ZSH); check('shell, zsh: an all-finished cycle leaves the focus unchanged', readFileSync(logf, 'utf8') === '' && /left unchanged/.test(fz2.out)) }
} finally {
  rmSync(scratch, { recursive: true, force: true })
}

// ============================ 5. the real engine, end to end ============================
// Sections 3 and 4 prove what the prompts SAY and that each command runs. This proves what they DO,
// together, against the shipped acfw-cycle, acfw-store (the multica adapter, through the offline fake CLI
// tests/fixtures/multica-fake.sh) and acfw-focus: the writer's commands are executed verbatim, in the
// order the prompt lists them, the way the shell-tier writer runs them.
//
// The scenario is the one that shipped broken: recon hands planners a bounded id list, so on a large
// board a planner can pick an id that is already taken. Record runs first, so the colliding stem lands in
// ## Tasks, and before 3.5.0's drop it stayed there: a teammate's in-progress task counted as this plan's
// coverage (so the deliverable was never decomposed) and the focus pointed a bare /go at their work.
// Both collisions are exercised: a teammate's task (dropped outright) and this cycle's OWN task from an
// earlier run (dropped, then its earlier deliverable re-recorded, because --drop removes every pair).
const hasJq = spawnSync('bash', ['-c', 'command -v jq'], { encoding: 'utf8' }).status === 0
if (!hasJq) {
  // Counted, not noted: a suite that ends "N passed, 0 failed" without its only real-engine proof is
  // green by absence (the failure class 3.3.0 fixed in run-all.sh), and the multica adapter needs jq.
  bad('jq is required for the real-engine scenarios (they need the multica adapter), and it is not installed: that coverage did not run')
} else {
  const W5 = execFileSync('bash', ['-c', 'cd "$1" && pwd -P', '_', mkdtempSync(join(tmpdir(), 'phase20e-'))], { encoding: 'utf8' }).trim()
  const cleanEnv = () => {
    const e = {}
    for (const [k, v] of Object.entries(process.env)) if (!/^(ACFW_|MC_FAKE_|GIT_DIR|GIT_WORK_TREE)/.test(k)) e[k] = v
    return e
  }
  const shx = (cmd, cwd, env) => {
    const r = spawnSync(BASH, ['-c', cmd], { cwd, env, encoding: 'utf8' })
    return { code: r.status, out: r.stdout || '', err: r.stderr || '' }
  }
  const taskDoc = (id, st) => `# Task: ${id}\n\n## Metadata\n- **ID**: ${id}\n- **Status**: ${st}\n- **Priority**: high\n- **Assigned Agent**: go-engineer\n- **Worktree**: s-${id}\n- **PR Group**: s-${id}\n- **Touches Globs**: src/${id}/**\n- **Dependencies**: none\n- **Rejection Count**: 0\n- **Documentation**: none\n\n## Description\nx\n\n## Transition Log\n\n| Date Time | From | To | Agent | Reason/Comment |\n| --------- | ---- | -- | ----- | -------------- |\n`
  let n5 = 0
  // One scenario: a fresh repo + store, an approved cycle, optional pre-existing tasks, then the workflow
  // with every shell-tier call executed for real. Returns what the assertions need.
  async function realRun({ plan, own = [], teammate = [], tasks }) {
    const dir = join(W5, `s${n5++}`)
    const repo = join(dir, 'repo')
    mkdirSync(join(dir, 'nohooks'), { recursive: true })
    const env = Object.assign(cleanEnv(), { ACFW_TRUNK_ROOT: repo, ACFW_STORE: 'multica', ACFW_MULTICA_BIN: join(dir, 'mc'), MC_FAKE_STATE: join(dir, 'mc.json'), GIT_CEILING_DIRECTORIES: dir, GIT_TERMINAL_PROMPT: '0' })
    const B = `${ROOT}/skills/lib/bin`
    const setup = shx(`set -e
. '${ROOT}/tests/fixtures/multica-fake.sh'; multica_fake_install '${join(dir, 'mc')}'
git init -q -b main '${repo}'; cd '${repo}'
git config user.email t@example.com; git config user.name T; git config core.hooksPath '${join(dir, 'nohooks')}'; git config commit.gpgsign false
printf '.acfwhip/run/\\n' > .gitignore; echo seed > seed; git add .gitignore seed; git commit -qm seed
ID=$(bash '${B}/acfw-cycle' init seat --kind feature --source test | sed -n 's/^INIT|\\([^|]*\\)|.*/\\1/p')
cat > "docs/cycles/$ID/plan.md" <<'PLAN'
${plan}PLAN
C=$(. '${ROOT}/skills/lib/acfw-plan.sh'; acfw_plan_content "docs/cycles/$ID/plan.md" | cut -c4-15)
bash '${B}/acfw-cycle' approve "$ID" --expect "$C" >/dev/null
echo "ID=$ID"`, dir, env)
    const ID5 = (setup.out.match(/^ID=(\S+)$/m) || [])[1] || ''
    if (setup.code !== 0 || !ID5) { bad(`real engine: setup failed (${setup.code}): ${setup.err.slice(0, 300)}`); return null }
    const mk = (id, st) => { writeFileSync(join(dir, `${id}.md`), taskDoc(id, st)); return shx(`bash '${B}/acfw-store' create --file '${join(dir, `${id}.md`)}' --folder '${st}' >/dev/null`, repo, env).code }
    for (const [id, st] of teammate) if (mk(id, st) !== 0) bad(`real engine: could not seed ${id}`)
    for (const [id, st, ds] of own) {
      if (mk(id, st) !== 0) bad(`real engine: could not seed ${id}`)
      if (shx(`bash '${B}/acfw-cycle' record '${ID5}' '${id}=${ds}' >/dev/null`, repo, env).code !== 0) bad(`real engine: could not record ${id}`)
    }
    const ran = { writer: [] }
    const r = await runWorkflow(text, { planPath: ID5, pluginRoot: ROOT, trunkRoot: repo, trunkBranch: 'main', store: 'multica', planners: 1 }, {
      on: {
        'discover-agents': (c) => {
          const cmd = (c.prompt.split('\n').find((l) => /acfw-cycle' check /.test(l)) || '').trim()
          return { agents: AGENTS, check: shx(cmd, repo, env).out }
        },
        'write:ingest': (c) => {
          const cmds = [(c.prompt.split('\n').find((l) => /acfw-cycle' record /.test(l)) || '').trim()]
            .concat(createCmds(c.prompt).map((s) => s.trim()))
            .concat([(c.prompt.split('\n').find((l) => /acfw-focus' set /.test(l)) || '').trim()])
          const outs = cmds.map((cmd) => { const o = shx(cmd, repo, env); ran.writer.push(Object.assign({ cmd }, o)); return o })
          const all = outs.map((o) => o.out).join('')
          return {
            committed: outs.slice(1, -1).every((o) => o.code === 0), commitSha: 'n/a', files: [], note: '',
            record: ((outs[0].out.match(/^RECORD\|.*$/m) || [])[0]) || outs[0].out + outs[0].err,
            dropped: [...all.matchAll(/^DROPPED\|(\S+)$/gm)].map((m) => m[1]),
          }
        },
        'verify:doctor': (c) => {
          const rel = (c.prompt.match(/(if grep -qx 'ts=[^\n]*?; fi)/) || [])[1]
          if (rel) ran.release = shx(rel, repo, env)
          return { ok: true, summaryLine: 'SUMMARY|fatal=0|repairable=0|warn=0|ok=true', fatals: [], warns: [] }
        },
      },
      planner: () => ({ summary: 's', tasks: JSON.parse(JSON.stringify(tasks)) }),
      authorWritten: (id) => {
        mkdirSync(join(repo, '.acfwhip', 'run', 'staging'), { recursive: true })
        writeFileSync(join(repo, '.acfwhip', 'run', 'staging', `${id}.md`), taskDoc(id, 'pending'))
        return true
      },
    })
    const rec = shx(`git show 'HEAD:docs/cycles/${ID5}/record.md' | awk '/^## /{f=($0 ~ /^## Tasks/);next} f && /^[|]/' | sed '1,2d'`, repo, env).out
    const focusFile = join(repo, '.acfwhip', 'run', 'focus')
    const focus = existsSync(focusFile) ? readFileSync(focusFile, 'utf8').split('\n').filter((l) => l && l.charAt(0) !== '#').sort() : []
    const after = shx(`bash '${B}/acfw-cycle' check '${ID5}'`, repo, env)
    shx(`rm -f '.acfwhip/run/cycle-${ID5}.decomposing'`, repo, env)
    const folderOf = (id) => ((shx(`bash '${B}/acfw-store' read '${id}'`, repo, env).out.match(/"folder"\s*:\s*"([^"]*)"/) || [])[1] || '')
    return { r, repo, ID: ID5, rec, focus, after: after.out.split('\n')[0], ran, folderOf, lockGone: !existsSync(join(repo, '.acfwhip', 'run', `cycle-${ID5}.decomposing`)) }
  }
  try {
    // ---- coverage on: a teammate's id and this cycle's own earlier id both collide ----
    const PLAN4 = '# Seat\n\n## Problem\nx\n\n## Deliverables\n\n### D1: API\nAC1.1 a\n\n### D2: UI\nAC2.1 b\n\n### D3: Notice\nAC3.1 c\n\n### D4: Docs\nAC4.1 d\n'
    const t = (id, ds) => stub({ id, title: id, worktreeSlug: `s-${id.split('-').slice(2).join('-')}`, touchesGlobs: [`src/${id}/**`], deliverables: ds })
    const on = await realRun({
      plan: PLAN4,
      teammate: [['feature-020-team-task', 'in-progress']],
      own: [['feature-011-seat-ui', 'pending', 'D3']],
      tasks: [t('feature-010-seat-api', ['D1']), t('feature-020-team-task', ['D2']), t('feature-011-seat-ui', ['D4'])],
    })
    if (on) {
      const rep = on.r.report
      check('real: check (real engine) answered go for D1, D2, D4 and the run completed', rep.phase === 'complete' && rep.cycle.decomposed.join() === 'D1,D2,D4')
      const creates = on.ran.writer.slice(1, -1)
      check('real: the fresh id was created; both colliding creates exited 4 (store refused)', creates[0].code === 0 && creates[1].code !== 0 && creates[2].code !== 0 && /already exists/.test(creates[1].err + creates[2].err))
      check('real: the teammate\'s id is NOT in the cycle record', !/feature-020-team-task/.test(on.rec))
      check('real: this cycle\'s own earlier task keeps its earlier deliverable, and only that', /^\| D3 \| feature-011-seat-ui \|$/m.test(on.rec) && !/^\| D4 \|/m.test(on.rec))
      check('real: the fresh task is recorded against its deliverable', /^\| D1 \| feature-010-seat-api \|$/m.test(on.rec) && !/^\| D2 \|/m.test(on.rec))
      check('real: the engine now sees D2 and D4 as open (a re-run decomposes exactly those)', /^CHECK\|go\|.*\|uncovered=D2,D4\|/.test(on.after))
      check(`real: the focus is this cycle's unfinished tasks and never the teammate's (${on.focus.join(' ')})`, on.focus.join() === 'feature-010-seat-api,feature-011-seat-ui')
      check('real: the teammate\'s task is untouched (still in-progress)', on.folderOf('feature-020-team-task') === 'in-progress')
      check('real: the report never lists a collided id as created', rep.created.map((x) => x.id).join() === 'feature-010-seat-api' && rep.cycle.dropped.slice().sort().join() === 'feature-011-seat-ui,feature-020-team-task')
      check('real: the report\'s gaps match the engine', rep.cycle.coverageGaps.join() === 'D2,D4')
      check('real: the lock check took was released, with its stamp', on.ran.release && on.ran.release.code === 0 && on.lockGone && rep.cycle.lockReleased === true)
      check('real: staged files: the created one is gone, the refused ones are kept', !existsSync(join(on.repo, '.acfwhip', 'run', 'staging', 'feature-010-seat-api.md')) && existsSync(join(on.repo, '.acfwhip', 'run', 'staging', 'feature-020-team-task.md')))
      const status = shx('git status --porcelain', on.repo, cleanEnv()).out
      check(`real: the trunk is clean afterwards (${status.trim() || 'clean'})`, status.trim() === '')
    }

    // ---- coverage off: `| - | <stem> |` rows, the same collision ----
    const off = await realRun({
      plan: '# Seat\n\n## Problem\nx\n\n## Scope\nall of it\n',
      teammate: [['feature-020-team-task', 'in-progress']],
      tasks: [stub({ id: 'feature-010-seat-api', title: 'a', worktreeSlug: 's-api', touchesGlobs: ['src/a/**'] }), stub({ id: 'feature-020-team-task', title: 'b', worktreeSlug: 's-team', touchesGlobs: ['src/b/**'] })],
    })
    if (off) {
      check('real, coverage off: completes with coverage off', off.r.report.phase === 'complete' && off.r.report.cycle.coverage === 'off')
      check('real, coverage off: only the fresh stem is recorded, as "-"', /^\| - \| feature-010-seat-api \|$/m.test(off.rec) && !/feature-020/.test(off.rec))
      check('real, coverage off: the engine sees the plan as covered (a re-run is a no-op)', /^CHECK\|noop\|/.test(off.after))
      check('real, coverage off: the focus is the fresh task only', off.focus.join() === 'feature-010-seat-api')
    }
  } finally {
    rmSync(W5, { recursive: true, force: true })
  }
}

// ============================ the skill documents the contract ============================
{
  const skill = readFileSync(join(ROOT, 'skills', 'task', 'SKILL.md'), 'utf8')
  check('/task advertises --plan in its argument-hint', /argument-hint:.*--plan/.test(skill))
  check('/task passes planPath and never scope with it', /planPath:/.test(skill) && /Never pass both/.test(skill))
  check('/task refuses free text alongside --plan', /--plan takes the plan and nothing else/.test(skill))
  check('/task stops on check-refused and never routes around it', /check-refused/.test(skill) && /Do not retry, do not route around it/.test(skill))
  check('/task names the no-Workflow fallback with coverage off', /Implement docs\/cycles\/<ID>\/plan\.md \(D1\.\.Dn\)/.test(skill) && /coverage off/.test(skill))
  check('/task still fences the legacy loop to files', /files.?.?backend only/i.test(skill))
  // Every plan-mode return shape has a report instruction, including the two aborts that carry only
  // reason + nextStep (an unusable go payload, an empty agent registry).
  check('/task covers the reason-only abort (no stopReason, no defects)', /`aborted: true` with `reason` and no `stopReason` or `defects`[^\n]*\n[^\n]*\n\s+verbatim and stop\. The run already released the lock it took\./.test(skill))
  check('/task covers a refused record: created empty, focus untouched, unrecorded listed', /`cycle\.recorded: false`[\s\S]{0,200}`created` is empty, the focus was not touched, and `cycle\.unrecorded`/.test(skill))
  check('/task covers a lost lock (LOCK|lost) and says not to re-run over it', /`LOCK\|lost`[\s\S]{0,300}Do not re-run/.test(skill))
  check('/task names dropped ids', /`cycle\.dropped`/.test(skill))
  const newProse = skill.slice(skill.indexOf('## Plan mode'), skill.indexOf('## Execution: workflow-first'))
  check('the new /task prose has no em dashes', newProse.length > 200 && !newProse.includes('—'))
  const tpl = readFileSync(join(ROOT, 'content', 'backlog', 'task-template.md'), 'utf8')
  check('task-template documents the (D<n>, ...) suffix in Field Usage', /Documentation Field Usage[\s\S]*\(D<n>, \.\.\.\)[\s\S]*docs\/cycles\/<ID>\/plan\.md \(D2, D4\)/.test(tpl))
}

console.log(`\nphase20-task-plan: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL ? 1 : 0)
