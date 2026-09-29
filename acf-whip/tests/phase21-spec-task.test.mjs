// phase21-spec-task.test.mjs — the task-stage spec review in whip-task (3.5.0).
//
// WHY THIS EXISTS. A project that declares a spec tool with at=task gets a Review phase between Author
// and Write: each authored task is reviewed by acfw-spec, a task a policy=block tool rejects gets one
// repair round, and whatever a block tool still rejects is held in draft with a Transition Log row and
// kept out of the run focus. Every way that goes wrong is silent at runtime:
//
//   * a project with NO task tools drifts from 3.4.x (a Review phase, a staging dir or a report key
//     that should not be there), which nothing at runtime would notice;
//   * the repair loops (costing an author per round) or keeps an edit that changed the metadata the
//     scheduler reads (Status, Worktree, Dependencies);
//   * a held task lands in pending anyway, in either writer, or enters the focus, so a bare /go runs
//     exactly the task a block tool said no to;
//   * a skip or an error holds a task (a tool that could not run must never block work);
//   * a relay that came back short is read as "no findings" and a block tool is skipped silently;
//   * on the files store, a task is authored straight into .backlog/pending/ where a bare /go can pick
//     it up before anyone reviewed it.
//
// Three halves:
//   1. the pure review functions, extracted from the <task-pure> block and unit-tested;
//   2. the REAL workflow body with a mocked agent() (the phase11/phase15/phase20 way): every contract
//      point above, read off the prompts each agent is sent and the report;
//   3. the shell those prompts hand to agents, executed for real under /bin/bash (and, where the agent
//      shell matters, under zsh, the macOS default) against the shipped
//      acfw-spec (real declarations, real verdicts, real cache), the files store in a scratch git repo,
//      and the multica adapter through tests/fixtures/multica-fake.sh.
//
// Run: node acf-whip/tests/phase21-spec-task.test.mjs

import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, existsSync, chmodSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { tmpdir } from 'node:os'
import { execFileSync, spawnSync } from 'node:child_process'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..')
// PHASE21_SRC: a dev switch to run this suite against a mutated copy of the workflow (proof it fails
// when the behaviour it pins is broken). run-all.sh never sets it.
const SRC = process.env.PHASE21_SRC || join(ROOT, 'workflows', 'whip-task.workflow.js')

let PASS = 0, FAIL = 0
const ok = (m) => { PASS++; console.log(`  PASS: ${m}`) }
const bad = (m) => { FAIL++; console.log(`  FAIL: ${m}`) }
const check = (m, cond) => (cond ? ok(m) : bad(m))
const sec = (m) => console.log(`\n== ${m}`)

const text = readFileSync(SRC, 'utf8')
try {
  new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow', `return (async () => {\n${text.replace(/^export const meta/m, 'const meta')}\n})()`)
} catch (e) {
  bad(`whip-task.workflow.js does not compile as a workflow body: ${e.message}`)
  console.log(`\nphase21-spec-task: ${PASS} passed, ${FAIL} failed`)
  process.exit(1)
}

// ============================ 1. the pure review functions ============================
sec('1. pure: parsing the relays and deciding holds')
const start = text.indexOf('// <task-pure>')
const end = text.indexOf('// </task-pure>')
if (start < 0 || end < start) { bad('could not find the <task-pure> block'); process.exit(1) }
const P = new Function(`${text.slice(start, end)}\nreturn { parseToolList, parseReviewRelay, pickReview, reviewOutcome, holdNote, relayLines, reviewNeedsRetry, mergeMeta, blockToolsFrom, toolsFrom, heldWhy, waitingOnHeld, waitNote }`)()

const SPATH = (id, tool, file = 'findings.md') => `/r/.acfwhip/run/spec/${id}/0123456789ab/${tool}/${file}`
const RV = (id, tool, policy, verdict, n = 0, file = 'findings.md') => `REVIEWED|${id}|${tool}|${policy}|${verdict}|${n}|${n ? 'high' : '-'}|${SPATH(id, tool, file)}`
const A = 'feature-002-login-api'
const B = 'feature-003-login-ui'
{
  const t = P.parseToolList(['TOOL|blk|review|task|block|every|10', 'TOOL|adv|driver|plan,task|advisory|ask|120', 'TOOL|Bad_Name|review|task|block|every|10', 'TOOL|blk|review|task|block|every|10', 'noise', 'TOOLS|2'])
  check('tool list: names, kinds and policies parse; a bad name and a duplicate are dropped', JSON.stringify(t.tools) === JSON.stringify([{ name: 'blk', kind: 'review', policy: 'block' }, { name: 'adv', kind: 'driver', policy: 'advisory' }]))
  check('tool list: the capture\'s own TOOLS| count is read', t.count === 2)
  check('tool list: no TOOLS| line leaves count null (a short relay is visible)', P.parseToolList(['TOOL|blk|review|task|block|every|10']).count === null)
  check('tool list: TOOLS|0 with nothing else is "no task tools"', (() => { const z = P.parseToolList(['TOOLS|0']); return z.count === 0 && z.tools.length === 0 })())
  check('relay lines: several lines packed into one element are split and trimmed', P.relayLines(['a\nb ', ' c', '', null]).join(',') === 'a,b,c')
}
{
  const whole = P.parseReviewRelay([RV(A, 'blk', 'block', 'nogo', 2), RV(A, 'adv', 'advisory', 'go'), 'END|lines=2', 'RC|0'], [A])
  check('review relay: END matches the usable REVIEWED count -> ok', whole.ok && whole.rows.length === 2 && whole.end === 2 && whole.rc === 0)
  check('review relay: the row fields land where the engine put them', (() => { const r = whole.rows[0]; return r.id === A && r.tool === 'blk' && r.policy === 'block' && r.verdict === 'nogo' && r.n === 2 && r.maxsev === 'high' && r.path === SPATH(A, 'blk') })())
  const shortR = P.parseReviewRelay([RV(A, 'blk', 'block', 'go'), 'END|lines=2'], [A])
  check('review relay: END|lines=2 with one row arriving is short, and says so', !shortR.ok && /END\|lines=2, but 1 usable REVIEWED/.test(shortR.why))
  const noEnd = P.parseReviewRelay([RV(A, 'blk', 'block', 'go'), 'ERR|FATAL: spec tool declarations hold a credential literal', 'RC|20'], [A])
  check('review relay: no END line is short, carrying the engine\'s FATAL', !noEnd.ok && noEnd.rc === 20 && /did not finish: FATAL: spec tool/.test(noEnd.why))
  check('review relay: nothing at all is short', !P.parseReviewRelay([], [A]).ok)
  const foreign = P.parseReviewRelay([RV('feature-999-other', 'blk', 'block', 'go'), 'END|lines=1'], [A])
  check('review relay: a line for a task this call did not review is malformed (not ok)', !foreign.ok && foreign.rows.length === 0)
  const garbled = P.parseReviewRelay([`REVIEWED|${A}|blk|block|maybe|0|-|x`, 'END|lines=1'], [A])
  check('review relay: an unknown verdict is malformed, never guessed', !garbled.ok)
  const piped = P.parseReviewRelay([`REVIEWED|${A}|blk|block|go|0|-|/r/odd|dir/findings.md`, 'END|lines=1'], [A])
  check('review relay: a findings path holding a | keeps it', piped.ok && piped.rows[0].path === '/r/odd|dir/findings.md')
  const extras = P.parseReviewRelay([`${RV(A, 'blk', 'block', 'error')}\nEND|lines=1`, `UNRUN|${A}|blk`, `META|${A}|restored`, 'RC|0'], [A])
  check('review relay: UNRUN and META lines are read (and one packed element still parses)', extras.ok && extras.unrun.length === 1 && extras.unrun[0].tool === 'blk' && extras.meta[A] === 'restored')
  check('retry trigger: a short relay, or a budget placeholder; a whole clean relay is not', P.reviewNeedsRetry(shortR) && P.reviewNeedsRetry(extras) && !P.reviewNeedsRetry(whole))
  const again = P.pickReview(shortR, whole)
  check('pick: a whole retry wins over a short first attempt', again.ok && again.retried && again.rows.length === 2)
  check('pick: a whole first attempt stands when the retry came back short', P.pickReview(extras, shortR).ok)
  const both = P.pickReview(P.parseReviewRelay([RV(A, 'adv', 'advisory', 'go'), 'END|lines=3'], [A]), P.parseReviewRelay([RV(A, 'blk', 'block', 'go'), 'END|lines=3'], [A]))
  check('pick: two short attempts keep every line either relayed, and stay not ok', !both.ok && both.rows.length === 2)
  check('meta: a restore either attempt saw stands', P.mergeMeta({ x: 'restored' }, { x: 'same' }).x === 'restored' && P.mergeMeta({ x: 'same' }, { x: 'restored' }).x === 'restored')
}
{
  const rows = [
    { id: A, tool: 'blk', policy: 'block', verdict: 'nogo', n: 2, maxsev: 'high', path: SPATH(A, 'blk') },
    { id: A, tool: 'adv', policy: 'advisory', verdict: 'nogo', n: 3, maxsev: 'low', path: SPATH(A, 'adv') },
    { id: B, tool: 'blk', policy: 'block', verdict: 'nogo', n: 0, maxsev: '-', path: SPATH(B, 'blk', 'held.md') },
    { id: B, tool: 'adv', policy: 'advisory', verdict: 'skip', n: 0, maxsev: '-', path: SPATH(B, 'adv') },
  ]
  const o = P.reviewOutcome(rows, [A, B], ['blk'], [])
  check('outcome: block + nogo holds', o[A].holds.length === 1 && o[A].holds[0].tool === 'blk' && o[B].holds.length === 1)
  check('outcome: an advisory nogo never holds; it is a note', o[A].notes.some((x) => x.tool === 'adv' && x.verdict === 'nogo'))
  check('outcome: real findings in findings.md are repairable', o[A].repairable.length === 1)
  check('outcome: a held.md hold (n=0: the tool\'s state, not the text) is not sent to a repair', o[B].repairable.length === 0)
  const errs = P.reviewOutcome([
    { id: A, tool: 'blk', policy: 'block', verdict: 'skip', n: 0, maxsev: '-', path: '-' },
    { id: A, tool: 'blk2', policy: 'block', verdict: 'error', n: 0, maxsev: '-', path: '-' },
    { id: A, tool: 'adv', policy: 'advisory', verdict: 'error', n: 0, maxsev: '-', path: '-' },
  ], [A], ['blk', 'blk2'], [])
  check('outcome: skip and error never hold, whatever the policy', errs[A].holds.length === 0 && errs[A].notes.length === 3)
  const short = P.reviewOutcome([{ id: A, tool: 'blk', policy: 'block', verdict: 'go', n: 0, maxsev: '-', path: SPATH(A, 'blk') }], [A, B], ['blk'], [A, B])
  check('outcome, short relay: a block tool with no line for a task holds it, marked unreviewed', short[B].holds.length === 1 && short[B].holds[0].unreviewed === true && short[B].holds[0].n === 0)
  check('outcome, short relay: a block line that did arrive saying go still releases', short[A].holds.length === 0)
  check('outcome, short relay: an advisory-only tool set never fails closed', P.reviewOutcome([], [A], [], [A])[A].holds.length === 0)
  check('outcome, whole relay: a missing line is the engine\'s choice (ACFW_SPEC=off), never a hold', P.reviewOutcome([], [A], ['blk'], [])[A].holds.length === 0)
  const note = P.holdNote(A, [{ tool: 'no-tbd', n: 2 }, { tool: 'blk', n: 0 }])
  check(`hold note: "${note}"`, note === `held: no-tbd nogo n=2, blk nogo n=0; /whip --review ${A}`)
  check('hold note: ASCII only, no | (it is a table cell)', /^[\x20-\x7e]+$/.test(note) && !note.includes('|'))
  // A relay-loss hold is committed to the Transition Log; it must not claim a verdict no tool gave.
  const un = P.holdNote(A, [{ tool: 'blk', n: 0, unreviewed: true }, { tool: 'no-tbd', n: 1 }])
  check(`hold note, unreviewed: "${un}"`, un === `held: blk unreviewed (verdict not relayed), no-tbd nogo n=1; /whip --review ${A}` && !un.includes('|'))
}
{
  // Why a task was held: "after one repair round" only for tasks that went through it.
  const rep = new Set([A])
  check('held why: every held task was repaired', P.heldWhy([A], rep) === 'a policy=block spec tool still rejected it after one repair round')
  check('held why: none was repaired (held.md, relay loss): neutral', P.heldWhy([B], rep) === 'a policy=block spec tool held it' && P.heldWhy([A, B], new Set()) === 'a policy=block spec tool held them')
  check('held why: some were: names them', P.heldWhy([A, B], rep) === `a policy=block spec tool held them; ${A} was still rejected after one repair round`)
  // Dependents of a held task: direct and transitive, never the held task itself.
  const C = 'feature-004-login-docs'
  const graph = [{ id: A, dependencies: [] }, { id: B, dependencies: [A] }, { id: C, dependencies: [B] }, { id: 'feature-005-free', dependencies: [] }]
  const w = P.waitingOnHeld(graph, [A])
  check('waiting: a direct dependent and a transitive one both wait on the held task', w.get(B).join() === A && w.get(C).join() === A && !w.has(A) && !w.has('feature-005-free'))
  check('waiting: a held task in the middle is itself held, its dependent waits on it', (() => { const m = P.waitingOnHeld(graph, [B]); return !m.has(A) && !m.has(B) && m.get(C).join() === B })())
  check('waiting: nothing held, nothing waits', P.waitingOnHeld(graph, []).size === 0)
  check('wait note: one', P.waitNote([{ id: B, on: [A] }]) === `${B} waits on held ${A}: /go will not dispatch it until ${A} is released`)
  check('wait note: several', P.waitNote([{ id: B, on: [A] }, { id: C, on: [A, 'feature-009-x'] }]) === `${B} waits on held ${A}; ${C} waits on held ${A}, feature-009-x: /go will not dispatch them until the held tasks are released`)
  // The fail-closed tool set comes from every listing, and turns into 'unknown' when none arrived whole.
  const whole = P.parseToolList(['TOOL|blk|review|task|block|every|10', 'TOOL|adv|review|task|advisory|every|10', 'TOOLS|2'])
  const lost = P.parseToolList([])
  const partial = P.parseToolList(['TOOL|blk2|review|task|block|every|10', 'TOOLS|2'])
  check('block tools: a whole listing names its block tools and nothing else', P.blockToolsFrom([whole]).join() === 'blk')
  check('block tools: a whole listing anywhere is enough (discovery lost, the review relay whole)', P.blockToolsFrom([lost, whole]).join() === 'blk')
  check('block tools: no listing whole: what arrived, plus unknown', P.blockToolsFrom([lost, partial]).join() === 'blk2,unknown' && P.blockToolsFrom([lost]).join() === 'unknown')
  check('block tools: the union across listings', P.blockToolsFrom([whole, P.parseToolList(['TOOL|blk3|review|task|block|every|10', 'TOOLS|1'])]).join() === 'blk,blk3')
  check('tools for the report: every named tool, once, first listing first', JSON.stringify(P.toolsFrom([whole, partial])) === JSON.stringify([{ name: 'blk', policy: 'block' }, { name: 'adv', policy: 'advisory' }, { name: 'blk2', policy: 'block' }]))
  const withList = P.parseReviewRelay(['TOOL|blk|review|task|block|every|10', 'TOOLS|1', RV(A, 'blk', 'block', 'go'), 'END|lines=1', 'RC|0'], [A])
  check('review relay: the listing it carries is read, and does not count as malformed', withList.ok && withList.listing.count === 1 && withList.listing.tools[0].name === 'blk')
  check('pick: every attempt\'s listing rides along', P.pickReview(withList).listings.length === 1 && P.pickReview(P.parseReviewRelay([], [A]), withList).listings.length === 2)
}

// ============================ the mocked workflow runtime ============================
const AGENTS = ['go-engineer', 'react-engineer', 'quality-reviewer']
const stub = (o) => Object.assign({
  title: 'T', category: 'feature', priority: 'high', assignedAgent: 'go-engineer', isCodeMutating: true,
  prGroup: '', touchesGlobs: ['services/x/**'], dependencies: [], estimatedHours: '4',
  what: 'Endpoint returns 200', why: 'Users need it', constraints: 'p95 < 200ms', outOfScope: 'No UI',
}, o)
const FT_PLAN = {
  summary: 'login',
  tasks: [
    stub({ id: A, title: 'Login API', worktreeSlug: 'auth-api', touchesGlobs: ['services/auth/**'] }),
    stub({ id: B, title: 'Login UI', assignedAgent: 'react-engineer', worktreeSlug: 'auth-ui', touchesGlobs: ['web/login/**'], dependencies: [A] }),
  ],
}
const TOOLS2 = ['TOOL|blk|review|task|block|every|10', 'TOOL|adv|review|task|advisory|every|10', 'TOOLS|2']
const allGo = (ids) => ids.flatMap((id) => [RV(id, 'blk', 'block', 'go'), RV(id, 'adv', 'advisory', 'go')]).concat([`END|lines=${ids.length * 2}`, 'RC|0'])
// The task ids a review call covers: the staged documents its command names (never the .frozen copies).
const idsOf = (c) => [...c.prompt.matchAll(/\/\.acfwhip\/run\/staging\/([a-z0-9-]+)\.md'/g)].map((m) => m[1]).filter((v, i, a) => a.indexOf(v) === i)

async function runWorkflow(src, args, sc = {}) {
  const calls = []
  const logs = []
  const phases = []
  let n = 0
  async function agent(prompt, opts) {
    const label = (opts && opts.label) || ''
    const call = { i: n++, label, prompt: String(prompt), opts: opts || {} }
    calls.push(call)
    if (sc.on && sc.on[label]) return sc.on[label](call, calls)
    if (label === 'discover-agents') return { agents: AGENTS, ...(sc.check != null ? { check: sc.check } : {}), ...(sc.specTools ? { specTools: sc.specTools } : {}) }
    if (label === 'recon:backlog') return { ids: ['feature-001-existing'], slugsInUse: ['core'], liveBranches: [], note: '' }
    if (label === 'recon:surface') return { modules: ['services/auth/**', 'web/login/**'], testLayout: 'tests/', note: '' }
    if (label === 'recon:conventions') return { agents: ['go-engineer: Go', 'react-engineer: React'], gateCommands: 'make test', styleNotes: 'WHAT/WHY', note: '' }
    if (/^plan:/.test(label)) return sc.planner ? sc.planner(call, calls) : JSON.parse(JSON.stringify(FT_PLAN))
    if (label === 'judge:plan') return { choice: 0, reason: 'x' }
    if (label === 'critic:completeness') return { defects: [] }
    if (/^author:/.test(label)) { const id = label.slice(7); return { id, filename: `${id}.md`, written: true, note: 'ok' } }
    if (/^review:task/.test(label)) return { lines: sc.review ? sc.review(call, calls) : allGo(idsOf(call)) }
    if (/^repair:/.test(label)) return sc.repair ? sc.repair(call) : { id: label.slice(7), changed: true, note: 'fixed' }
    if (label === 'write:commit' || label === 'write:ingest') {
      return sc.writer ? sc.writer(call) : { committed: true, commitSha: 'abc1234', files: [], note: '', ...(/acfw-cycle' record/.test(call.prompt) ? { record: 'RECORD|ok|cycle=x|tasks=2', dropped: [] } : {}) }
    }
    if (label === 'verify:doctor') return { ok: true, summaryLine: 'SUMMARY|fatal=0|repairable=0|warn=0|ok=true', fatals: [], warns: [] }
    if (label === 'cycle:unlock') return 'done'
    throw new Error(`unmocked agent label "${label}"`)
  }
  const parallel = async (thunks) => { const out = []; for (const f of thunks) { try { out.push(await f()) } catch (e) { out.push(null) } } return out }
  const run = new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow', `return (async () => {\n${src.replace(/^export const meta/m, 'const meta')}\n})()`)
  const report = await run(agent, parallel, async () => { throw new Error('pipeline') }, (p) => phases.push(p), (m) => logs.push(String(m)), args, undefined, async () => { throw new Error('workflow') })
  // first() of a label that never ran is an empty call, so a missing agent FAILS the checks that read it
  // rather than crashing the suite before its tally.
  const none = (l) => ({ i: -1, label: l, prompt: '', opts: { schema: { required: [] } } })
  return { report, calls, logs, phases, labels: calls.map((c) => c.label), byLabel: (l) => calls.filter((c) => c.label === l), first: (l) => calls.find((c) => c.label === l) || none(l) }
}
const FT = (store, o = {}) => Object.assign({ scope: 'Add a login flow: API and UI', pluginRoot: '/p', trunkRoot: '/r', trunkBranch: 'main', store }, o)
// plan mode, as phase20 drives it
const TR = '/work/repo'
const CID = '20260928-owner-seat'
const REL = `docs/cycles/${CID}/plan.md`
const C12 = 'abcdef012345'
const goLine = `CHECK|go|cycle=${CID}|content=${C12}|frozen=${TR}/.acfwhip/run/cycle/${CID}/${C12}.md|lock=${TR}/.acfwhip/run/cycle-${CID}.decomposing|uncovered=D2,D3|known=D1,D2,D3|coverage=on|kind=feature|held=1790000000`
const PT = (store, o = {}) => Object.assign({ planPath: REL, pluginRoot: '/p', trunkRoot: TR, trunkBranch: 'main', store }, o)
const SA = 'feature-010-seat-api'
const SU = 'feature-011-seat-ui'
const planTasks = () => ({ summary: 's', tasks: [stub({ id: SA, title: 'Seat API', worktreeSlug: 'seat-api', touchesGlobs: ['services/seat/**'], deliverables: ['D2'] }), stub({ id: SU, title: 'Seat UI', assignedAgent: 'react-engineer', worktreeSlug: 'seat-ui', touchesGlobs: ['web/seat/**'], deliverables: ['D3'] })] })
const reviewLabels = (r) => r.labels.filter((l) => /^(review:|repair:)/.test(l))
// One held task: blk rejects `holdId` with findings, and again after the repair.
const holdOne = (holdId) => (c) => idsOf(c).flatMap((id) => [RV(id, 'blk', 'block', id === holdId ? 'nogo' : 'go', id === holdId ? 2 : 0), RV(id, 'adv', 'advisory', 'go')]).concat([`END|lines=${idsOf(c).length * 2}`, 'RC|0'])

// ============================ 2a. no task tools: nothing changes ============================
sec('2a. no task tools: no Review phase, a byte-identical report')
for (const [name, args, extra] of [['free text, files', FT('files'), {}], ['free text, multica', FT('multica'), {}], ['plan mode, files', PT('files'), { check: goLine, planner: planTasks }], ['plan mode, multica', PT('multica'), { check: goLine, planner: planTasks }]]) {
  const base = await runWorkflow(text, args, extra)
  const hinted = await runWorkflow(text, Object.assign({}, args, { specTaskTools: 1 }), Object.assign({ specTools: ['TOOLS|0'] }, extra))
  check(`[${name}] no hint: no Review phase, no review or repair agent, no spec command anywhere`, !base.phases.includes('Review') && !reviewLabels(base).length && !base.calls.some((c) => /acfw-spec'/.test(c.prompt)))
  check(`[${name}] no hint: no review key in the report`, !('review' in base.report))
  check(`[${name}] hint, but the listing says TOOLS|0: no Review phase`, !hinted.phases.includes('Review') && !reviewLabels(hinted).length)
  check(`[${name}] ...the same agents in the same order`, hinted.labels.join() === base.labels.join())
  const drift = hinted.calls.filter((c, i) => c.label !== 'discover-agents' && (c.prompt !== base.calls[i].prompt || JSON.stringify(c.opts.schema) !== JSON.stringify(base.calls[i].opts.schema))).map((c) => c.label)
  check(`[${name}] ...every prompt and schema but discovery's byte-identical (drift: ${drift.join(', ') || 'none'})`, drift.length === 0)
  check(`[${name}] ...and a byte-identical report`, JSON.stringify(hinted.report) === JSON.stringify(base.report))
  const disc = hinted.first('discover-agents')
  check(`[${name}] the hint adds the listing to the SAME discovery call (no extra agent)`, /acfw-spec' list --at task --machine/.test(disc.prompt) && disc.opts.schema.required.includes('specTools'))
}
{
  const f = await runWorkflow(text, FT('files'))
  check('files, no task tools: authors still write straight into .backlog/pending/', f.first(`author:${A}`).prompt.includes(`'/r'/.backlog/pending/<filename>`))
}

// ============================ 2b. staging on files ============================
sec('2b. task tools on files: authoring goes to staging, the writer moves it in')
{
  const r = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2 })
  check('the Review phase runs, between Author and Write', r.phases.join('>').includes('Author>Review>Write'))
  check('authors write to .acfwhip/run/staging/ on the files store', r.first(`author:${A}`).prompt.includes(`'/r'/.acfwhip/run/staging/<filename>`) && !r.first(`author:${A}`).prompt.includes('.backlog/pending/<filename>'))
  const rv = r.first('review:task')
  check('ONE review agent, shell tier, relaying lines', r.byLabel('review:task').length === 1 && rv.opts.model === 'haiku' && rv.opts.schema.required.join() === 'lines')
  check('...told to give the Bash call a 600000 ms timeout', /timeout set to 600000/.test(rv.prompt))
  check('...running review --stage task --machine over both staged documents, absolute paths', /acfw-spec' review --stage task --machine "\$@"/.test(rv.prompt) && idsOf(rv).join() === `${A},${B}`)
  check('...after freezing a byte copy of each (the repair reference)', /mkdir -p '\/r\/\.acfwhip\/run\/staging\/\.frozen'/.test(rv.prompt) && /cp -f "\$f" '\/r\/\.acfwhip\/run\/staging\/\.frozen\/'/.test(rv.prompt))
  check('...and printing the tool listing first, in the same call (the fail-closed rule\'s second source)', (() => { const i = rv.prompt.indexOf("acfw-spec' list --at task --machine"); return i > 0 && i < rv.prompt.indexOf("acfw-spec' review --stage task") && rv.prompt.includes("printf 'TOOLS|%s\\n'") })())
  check('all go: no repair, no retry', !r.labels.some((l) => /^repair:|:retry$|:again/.test(l)))
  const w = r.first('write:commit').prompt
  check('the files writer moves each staged document into .backlog/pending/', w.includes(`mv -f '.acfwhip/run/staging/${A}.md' '.backlog/pending/${A}.md'`) && w.includes(`mv -f '.acfwhip/run/staging/${B}.md' '.backlog/pending/${B}.md'`))
  check('...then stamps and stages the moved files, in one commit', w.includes(`git add '.backlog/pending/${A}.md' '.backlog/pending/${B}.md' .gitignore`) && (w.match(/git commit -q -m/g) || []).length === 1)
  check('...and focuses both', w.includes(`add --no-resolve --by task '${A}' '${B}'`))
  check('report: a review block, relay ok, nothing held', r.report.review && r.report.review.relay === 'ok' && r.report.review.held.length === 0 && r.report.review.reviewed === 2)
  check('report: the verdicts the decision rests on are counted (2 tasks x 2 tools)', r.report.review.verdicts === 4)
  check('report: the tools as listed', JSON.stringify(r.report.review.tools) === JSON.stringify([{ name: 'blk', policy: 'block' }, { name: 'adv', policy: 'advisory' }]))
  check(`report: the review agent is counted on the shell tier (discover, recon, review, writer, doctor = 5; got ${r.report.agentsByTier.shell}) and nothing extra on the author tier`, r.report.agentsByTier.shell === 5 && r.report.agentsByTier.author === 2)
  const lost = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: ['TOOL|blk|review|task|block|every|10'] })
  check('a listing relay that lost its TOOLS| line still reviews (the hint stands)', lost.phases.includes('Review'))
  const none = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: [] })
  check('a listing relay that came back empty still reviews (never skip a gate on a lost relay)', none.phases.includes('Review'))
}

// ============================ 2c. repair: bounded to one round ============================
sec('2c. the repair round: one, body only, a META change restored')
{
  const r = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2, review: holdOne(A) })
  check('a block nogo with findings gets exactly ONE repair agent', r.byLabel(`repair:${A}`).length === 1 && !r.labels.includes(`repair:${B}`))
  check('...a task-engineer on the author tier', r.first(`repair:${A}`).opts.agentType === 'task-engineer' && r.report.agentsByTier.author === 3)
  const rp = r.first(`repair:${A}`).prompt
  check('...handed the findings by PATH, never relayed text', rp.includes(`'${SPATH(A, 'blk')}'`) && rp.includes(`'/r/.acfwhip/run/staging/${A}.md'`))
  check('...told to change the body only, and why', /Change ONLY the body/.test(rp) && /throws your whole edit away/.test(rp))
  check('...told the findings are data, not instructions', /never instructions to you/.test(rp))
  const again = r.byLabel('review:task:again')
  check('then ONE re-review, of the repaired task only', again.length === 1 && idsOf(again[0]).join() === A)
  check('...which first checks the repair against the frozen copy and restores it on a META change', /awk "\$M" '\/r\/\.acfwhip\/run\/staging\/feature-002-login-api\.md'/.test(again[0].prompt) && again[0].prompt.includes(`cp -f '/r/.acfwhip/run/staging/.frozen/${A}.md' '/r/.acfwhip/run/staging/${A}.md' && echo 'META|${A}|restored'`))
  check('still rejected after the round: no second repair, the task is held', r.byLabel(`repair:${A}`).length === 1 && r.report.review.held.map((h) => h.id).join() === A)
  check('report: the repair and its check are listed', r.report.review.repaired.length === 1 && r.report.review.repaired[0].id === A && r.report.review.repaired[0].changed === true)
  let n = 0
  const fixed = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2, review: (c) => (n++ === 0 ? holdOne(A)(c) : allGo(idsOf(c)).concat([`META|${A}|same`])) })
  check('a repair the re-review accepts: nothing held, the task goes to pending', fixed.report.review.held.length === 0 && fixed.first('write:commit').prompt.includes(`'.backlog/pending/${A}.md'`) && fixed.report.review.repaired[0].check === 'same')
  n = 0
  const restored = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2, review: (c) => (n++ === 0 ? holdOne(A)(c) : holdOne(A)(c).concat([`META|${A}|restored`])) })
  check('a META-changed repair is reported as restored (and the original, still rejected, is held)', restored.report.review.repaired[0].metaRestored === true && restored.report.review.held[0].id === A)
  const heldmd = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2, review: (c) => idsOf(c).flatMap((id) => [RV(id, 'blk', 'block', 'nogo', 0, 'held.md'), RV(id, 'adv', 'advisory', 'skip')]).concat([`END|lines=${idsOf(c).length * 2}`]) })
  check('a held.md hold (untrusted, local edit, budget) sends nobody to repair it, and holds', !heldmd.labels.some((l) => /^repair:/.test(l)) && heldmd.report.review.held.length === 2)
  check('...and nothing says it was rejected after a repair round it never had', !/repair round/.test(heldmd.report.nextStep) && !/repair round/.test(heldmd.first('write:commit').prompt.split('Do EXACTLY this')[0]))
  const plan = await runWorkflow(text, PT('files', { specTaskTools: 2 }), { check: goLine, planner: planTasks, specTools: TOOLS2, review: holdOne(SA) })
  const prp = plan.first(`repair:${SA}`).prompt
  check('plan mode: the repair must keep the Out of Scope boundary and never touch plan.md', prp.includes(`Keep this Out of Scope bullet verbatim:  - Implement only D2 of ${REL}; plan.md is read-only.`) && prp.includes(`Never read or edit ${REL}.`))
  check('plan mode: ...and the META check demands the boundary survive when the author wrote it', plan.first('review:task:again').prompt.includes(`! grep -qF -- '- Implement only D2 of ${REL}; plan.md is read-only.'`))
}

// ============================ 2d. held routes to draft, in both writers ============================
sec('2d. held tasks: draft, a Transition Log row, no focus, in both writers')
// The splice runs in its own bash (the agent's shell may be zsh, where acfw-git.sh cannot be sourced).
const ROW_RE = (id, note = `held: blk nogo n=2; /whip --review ${id}`) => new RegExp(`bash -c '\\. "\\$1" && append_log_row "\\$2" "\\$3"' _ '[^']*/skills/lib/acfw-git\\.sh' '[^']*${id}\\.md' "\\| \\$\\(date -u \\+'%Y-%m-%d %H:%M:%S'\\) \\| pending \\| draft \\| spec-review \\| ${note.replace(/[()]/g, '\\$&')} \\|"`)
{
  const f = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2, review: holdOne(A) })
  const w = f.first('write:commit').prompt
  check('files: the held task moves to .backlog/draft/, the other to pending', w.includes(`mv -f '.acfwhip/run/staging/${A}.md' '.backlog/draft/${A}.md'`) && w.includes(`'.backlog/pending/${B}.md'`))
  check('files: its Status is set to draft and the row is spliced in', w.includes(`'s|^- \\*\\*Status\\*\\*:.*|- **Status**: draft|' '.backlog/draft/${A}.md'`) && ROW_RE(A).test(w))
  check('files: the held task is staged from draft, in the same single commit', w.includes(`git add '.backlog/draft/${A}.md' '.backlog/pending/${B}.md' .gitignore`))
  check('files: the focus gets only the task that was not held', w.includes(`add --no-resolve --by task '${B}'`) && !new RegExp(`by task[^\\n]*${A}`).test(w))
  check('files: the prompt says which task was held and why (it went through the repair round)', w.includes(`${A} was held (a policy=block spec tool still rejected it after one repair round).`))
  check('report: created, flagged held, and out of the focus count', f.report.created.find((c) => c.id === A).held === true && !('held' in f.report.created.find((c) => c.id === B)) && f.report.focus.count === 1)
  check('report: nextStep names the hold and how to release it', /held in draft and not in your focus/.test(f.report.nextStep) && /\/whip-move <stem> pending, then \/whip-focus add <stem>/.test(f.report.nextStep))
  check('report: the held entry names the tool, its count, the path and the next command', (() => { const h = f.report.review.held[0]; return h.id === A && h.by[0].tool === 'blk' && h.by[0].n === 2 && h.by[0].path === SPATH(A, 'blk') && h.next === `/whip --review ${A}` })())
  // B depends on A. With A in draft, /go never dispatches B (the doctor says dep-inactive), so B is in
  // the focus but not runnable, and the report must not send the user to a /go that can run nothing.
  check('report: B, which depends on held A, is listed as waiting', JSON.stringify(f.report.review.waiting) === JSON.stringify([{ id: B, on: [A] }]))
  check(`report: nextStep does not call B runnable (${f.report.nextStep.slice(0, 60)}...)`, /^Nothing new can run yet: /.test(f.report.nextStep) && !/Run \/go/.test(f.report.nextStep) && f.report.nextStep.includes(`${B} waits on held ${A}: /go will not dispatch it until ${A} is released`))
  check('report: the focus note says B is in the focus but not runnable yet', f.report.focus.note.includes(`added but not runnable yet: ${B} waits on held ${A}`))
  const fb = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2, review: holdOne(B) })
  check('holding the dependent instead: nothing waits, and the other task is runnable', fb.report.review.waiting.length === 0 && /^Run \/go: it runs these 1 task\(s\) as your focus/.test(fb.report.nextStep))

  const m = await runWorkflow(text, FT('multica', { specTaskTools: 2 }), { specTools: TOOLS2, review: holdOne(A) })
  const mi = m.first('write:ingest').prompt
  const lineA = mi.split('\n  ').find((l) => l.includes(`staging/${A}.md' --folder`)) || ''
  const lineB = mi.split('\n  ').find((l) => l.includes(`staging/${B}.md' --folder`)) || ''
  check('non-files: the held task is created with --folder draft, after its row', /--folder draft/.test(lineA) && ROW_RE(A).test(lineA) && lineA.indexOf('append_log_row') < lineA.indexOf('create --file'))
  check('non-files: ...and never added to the focus', !/acfw-focus/.test(lineA))
  check('non-files: the other task is created in pending and focused, as before', /--folder pending/.test(lineB) && lineB.includes(`add --no-resolve --by task '${B}'`))
  check('non-files: the frozen copy goes with the staged file', lineB.includes(`rm -f '/r/.acfwhip/run/staging/${B}.md' '/r/.acfwhip/run/staging/.frozen/${B}.md'`))

  // plan mode: held tasks are still the cycle's tasks (recorded), but draft and out of the focus
  for (const st of ['files', 'multica']) {
    const p = await runWorkflow(text, PT(st, { specTaskTools: 2 }), { check: goLine, planner: planTasks, specTools: TOOLS2, review: holdOne(SA) })
    const wp = p.first(st === 'files' ? 'write:commit' : 'write:ingest').prompt
    check(`plan/${st}: the held task is still recorded to the cycle`, wp.includes(`record '${REL}' '${SA}=D2' '${SU}=D3'`))
    check(`plan/${st}: it lands in draft, with its row`, (st === 'files' ? wp.includes(`'.backlog/draft/${SA}.md'`) : /create --file '[^']*feature-010-seat-api\.md' --folder draft/.test(wp)) && ROW_RE(SA).test(wp))
    check(`plan/${st}: the cycle focus skips draft tasks`, wp.includes('case "$F" in accepted|archive|draft) continue ;; esac'))
    check(`plan/${st}: the report keeps it created (it covers D2) and out of the focus count`, p.report.created.some((c) => c.id === SA && c.held) && p.report.focus.count === 1 && p.report.cycle.coverageGaps.length === 0)
  }
  {
    const dep = () => { const p = planTasks(); p.tasks[1].dependencies = [SA]; return p }
    const pw = await runWorkflow(text, PT('files', { specTaskTools: 2 }), { check: goLine, planner: dep, specTools: TOOLS2, review: holdOne(SA) })
    check('plan mode: a task that depends on the held one is not called runnable', /^None of the tasks this run created can run yet/.test(pw.report.nextStep) && pw.report.nextStep.includes(`${SU} waits on held ${SA}`))
    check('plan mode: ...and the focus note says so', pw.report.focus.note.includes(`in the focus but not runnable yet: ${SU} waits on held ${SA}`))
  }
  const pn = await runWorkflow(text, PT('files'), { check: goLine, planner: planTasks })
  check('plan mode without task tools: the focus filter is unchanged (draft kept)', pn.first('write:commit').prompt.includes('case "$F" in accepted|archive) continue ;; esac'))
  const allH = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2, review: (c) => idsOf(c).flatMap((id) => [RV(id, 'blk', 'block', 'nogo', 1), RV(id, 'adv', 'advisory', 'go')]).concat([`END|lines=${idsOf(c).length * 2}`]) })
  const aw = allH.first('write:commit').prompt
  check('every task held: the writer leaves the focus alone and says so', /Every task was held in draft, so leave the run focus alone/.test(aw) && !/acfw-focus/.test(aw))
  check('every task held: nextStep does not tell you to run /go', /^Nothing new is in your focus/.test(allH.report.nextStep) && allH.report.focus.count === 0)
}

// ============================ 2e. skip and error never hold ============================
sec('2e. a tool that could not run never holds')
{
  const r = await runWorkflow(text, FT('multica', { specTaskTools: 2 }), {
    specTools: TOOLS2,
    review: (c) => idsOf(c).flatMap((id) => [RV(id, 'adv', 'advisory', id === A ? 'skip' : 'error'), RV(id, 'blk', 'block', id === A ? 'skip' : 'error')]).concat([`END|lines=${idsOf(c).length * 2}`]),
  })
  const mi = r.first('write:ingest').prompt
  check('skip (untrusted, unavailable) and error (credential literal, crash): nothing held', r.report.review.held.length === 0 && !/--folder draft/.test(mi))
  check('...nothing repaired', !r.labels.some((l) => /^repair:/.test(l)))
  check('...both tasks focused', mi.includes(`--by task '${A}'`) && mi.includes(`--by task '${B}'`))
  check('...and every one is reported as a note', r.report.review.notes.length === 4 && r.report.review.notes.every((x) => x.verdict === 'skip' || x.verdict === 'error'))
  const adv = await runWorkflow(text, FT('files', { specTaskTools: 1 }), { specTools: ['TOOL|adv|review|task|advisory|every|10', 'TOOLS|1'], review: (c) => idsOf(c).map((id) => RV(id, 'adv', 'advisory', 'nogo', 5)).concat([`END|lines=${idsOf(c).length}`]) })
  check('an advisory NO-GO with findings: noted, never repaired, never held', adv.report.review.held.length === 0 && !adv.labels.some((l) => /^repair:/.test(l)) && adv.report.review.notes.length === 2)
}

// ============================ 2f. the relay: END count, one retry ============================
sec('2f. the relay: END|lines=k is checked, and a short one is retried once')
{
  let n = 0
  const r = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2, review: (c) => (n++ === 0 ? allGo(idsOf(c)).filter((l) => !l.startsWith(`REVIEWED|${B}|blk`)) : allGo(idsOf(c))) })
  check('a relay one line short: exactly one retry, then on', r.labels.filter((l) => /^review:task/.test(l)).join() === 'review:task,review:task:retry')
  check('...the retry is the same command (the cache resumes it)', r.first('review:task:retry').prompt === r.first('review:task').prompt)
  check('...and a whole retry releases everything, relay "retried"', r.report.review.held.length === 0 && r.report.review.relay === 'retried')
  const twice = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2, review: (c) => allGo(idsOf(c)).filter((l) => !l.startsWith(`REVIEWED|${B}|blk`)) })
  check('short twice: no third attempt', twice.labels.filter((l) => /^review:task/.test(l)).length === 2)
  check('...the block tool fails closed for the task it has no line for (held, unreviewed)', twice.report.review.held.map((h) => h.id).join() === B && twice.report.review.held[0].by[0].unreviewed === true)
  check('...and the report says the relay came back short', /^short: END\|lines=4, but 3 usable/.test(twice.report.review.relay))
  const died = { 'review:task': () => { throw new Error('agent died') }, 'review:task:retry': () => { throw new Error('agent died') } }
  const thrown = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2, on: died })
  check('a relay agent that throws is a short relay: the run finishes and block tools fail closed', thrown.report.phase === 'complete' && thrown.report.review.held.length === 2)
  // What a relay-loss hold writes and says: no tool gave a verdict and nothing was repaired.
  const tw = thrown.first('write:commit').prompt
  check('relay-loss hold: the durable row says unreviewed, never "nogo n=0"', ROW_RE(A, `held: blk unreviewed (verdict not relayed); /whip --review ${A}`).test(tw) && !/blk nogo n=0/.test(tw))
  check('relay-loss hold: nothing claims a repair round that never ran', !/after one repair round/.test(tw) && !/after one repair round/.test(thrown.report.nextStep) && tw.includes('were held (a policy=block spec tool held them).'))
  // The listing is a relay too. Losing it in discovery must not disarm the fail-closed rule.
  const noList = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: [], on: died })
  check('discovery listing lost AND the review relay lost twice: every task held, by "unknown", unreviewed', noList.report.review.held.length === 2 && noList.report.review.held.every((h) => h.by.length === 1 && h.by[0].tool === 'unknown' && h.by[0].unreviewed === true))
  check('...and its row says so', ROW_RE(A, `held: unknown unreviewed (verdict not relayed); /whip --review ${A}`).test(noList.first('write:commit').prompt))
  const fromRelay = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: [], review: (c) => TOOLS2.concat(allGo(idsOf(c)).filter((l) => !l.startsWith(`REVIEWED|${B}|blk`))) })
  check('discovery listing lost, the review relay short but carrying a whole listing: held by the named block tool only', fromRelay.report.review.held.map((h) => `${h.id}:${h.by.map((b) => b.tool).join('+')}`).join() === `${B}:blk` && fromRelay.report.review.tools.map((t) => t.name).join() === 'blk,adv')
  const wholeNoList = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: [], review: (c) => allGo(idsOf(c)) })
  check('discovery listing lost, the review relay whole: nothing held (unknown only ever fails closed on a short relay)', wholeNoList.report.review.held.length === 0)
  n = 0
  const budget = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2, review: (c) => (n++ === 0 ? allGo(idsOf(c)).map((l) => l.replace(`REVIEWED|${A}|adv|advisory|go`, `REVIEWED|${A}|adv|advisory|error`)).concat([`UNRUN|${A}|adv`]) : allGo(idsOf(c))) })
  check('a budget placeholder (UNRUN) earns the one retry, which resumes it', budget.labels.includes('review:task:retry') && budget.report.review.notes.length === 0)
  n = 0
  const again = await runWorkflow(text, FT('files', { specTaskTools: 2 }), { specTools: TOOLS2, review: (c) => { n++; if (n === 1) return holdOne(A)(c); if (n === 2) return [`META|${A}|same`, 'RC|0']; return allGo(idsOf(c)).concat([`META|${A}|same`]) } })
  check('the re-review has its own single retry', again.labels.filter((l) => /^review:task/.test(l)).join() === 'review:task,review:task:again,review:task:again:retry' && again.report.review.held.length === 0)
}

// ============================ 2g. static: routing and the lock line scan ============================
sec('2g. static checks on the source')
{
  check('every review call is shell-tier through shellOpts', /shellOpts\(\{ label: lbl, phase: 'Review', schema: REVIEW_RELAY \}\)/.test(text))
  check('the repair is author-tier through tierOpts', /tierOpts\(\{ label: `repair:\$\{t\.id\}`, phase: 'Review', schema: REPAIRED, agentType: 'task-engineer' \}, 'author'\)/.test(text))
  check('the Review phase adds no aborted return (a review never aborts a run)', !text.slice(text.indexOf('// ============================ REVIEW (task-stage'), text.indexOf('// ============================ WRITE (single committer)')).includes('aborted: true'))
  check('meta.phases lists Review between Author and Write', /title: 'Author'[\s\S]{0,200}title: 'Review'[\s\S]{0,300}title: 'Write'/.test(text))
}

// ============================ 3. the shell, executed for real ============================
const BASH = existsSync('/bin/bash') ? '/bin/bash' : 'bash'
// The shell-tier agents run these commands in THEIR shell, and on macOS that is zsh by default. zsh does
// not word-split an unquoted $VAR and cannot source a bash library that finds itself via BASH_SOURCE, and
// both once broke a writer command that passed every /bin/bash run. So the commands an agent runs are
// executed under zsh too. -f skips the user's rc files, so the run sees zsh's default options.
const ZSH = ['/bin/zsh', '/usr/bin/zsh'].find((p) => existsSync(p)) || ''
const cleanEnv = (extra = {}) => {
  const e = {}
  for (const [k, v] of Object.entries(process.env)) if (!/^(ACFW_|MC_FAKE_|GIT_DIR|GIT_WORK_TREE|GIT_INDEX)/.test(k)) e[k] = v
  return Object.assign(e, extra)
}
const shx = (cmd, cwd, env, shell = BASH) => { const r = spawnSync(shell, shell === ZSH ? ['-f', '-c', cmd] : ['-c', cmd], { cwd, env, encoding: 'utf8' }); return { code: r.status, out: r.stdout || '', err: r.stderr || '' } }
const shxIn = shx
if (!ZSH) {
  // macOS always ships /bin/zsh, so there a missing zsh is a broken machine, not a skip.
  if (process.platform === 'darwin') bad('zsh not found on macOS: the zsh runs of 3b and 3g cannot run')
  else console.log('  SKIP: zsh not installed: the zsh runs of 3b and 3g did not run (bash runs still do)')
}
const outLines = (s) => s.split('\n').filter((l) => l.length)
// A command block in a prompt: lines indented 2-3 spaces start a command, an unindented line continues
// it (sed's `a\` insert puts its text on the next physical line).
function splitCmds(block) {
  const out = []
  for (const l of block.split('\n')) {
    if (/^ {2,3}\S/.test(l)) out.push(l.trim())
    else if (out.length && /^\S/.test(l)) out[out.length - 1] += `\n${l}`
  }
  return out
}
const between = (s, a, b) => { const i = s.indexOf(a); if (i < 0) return ''; const j = s.indexOf(b, i + a.length); return s.slice(i + a.length, j < 0 ? undefined : j) }
const taskDoc = (id, extra = '') => `# Task: ${id}\n\n## Metadata\n- **ID**: ${id}\n- **Status**: pending\n- **Priority**: high\n- **Estimated Hours**: 4\n- **Assigned Agent**: go-engineer\n- **Worktree**: s-${id.split('-').slice(2).join('-')}\n- **PR Group**: s-${id.split('-').slice(2).join('-')}\n- **Touches Globs**: src/${id}/**\n- **Dependencies**: none\n- **Integrated-At**:\n- **Rejection Count**: 0\n- **Created By**: task-engineer\n- **Created At**: 2026-09-29 10:00:00 UTC\n- **Documentation**: none\n\n## Description\nBuild ${id}.\n${extra}\n## Acceptance Criteria\n- [ ] it works\n\n## Out of Scope\n- nothing else\n\n## Transition Log\n\n| Date Time | From | To | Agent | Reason/Comment |\n| --------- | ---- | -- | ----- | -------------- |\n| 2026-09-29 10:00:00 | draft | pending | task-engineer | Initial task creation |\n`
const TBD_DECL = (policy) => `# grep exits 0 on a match: test $? -eq 1 turns "found one" into NO-GO\nreview=grep -nwE 'TBD' "$ACFW_SPEC_FILE"; test $? -eq 1\nat=task\npolicy=${policy}\ntimeout=20\n`

const W = execFileSync('bash', ['-c', 'cd "$1" && pwd -P', '_', mkdtempSync(join(tmpdir(), 'phase21t-'))], { encoding: 'utf8' }).trim()
let nrepo = 0
// A fresh repo with the given declarations committed (and trusted unless told otherwise).
function mkRepo({ decls, trust = true, store = 'files' }) {
  const dir = join(W, `r${nrepo++}`)
  const repo = join(dir, 'repo')
  mkdirSync(join(dir, 'nohooks'), { recursive: true })
  const env = cleanEnv({ ACFW_TRUNK_ROOT: repo, ACFW_STORE: store, GIT_CEILING_DIRECTORIES: dir, GIT_TERMINAL_PROMPT: '0', ACFW_MULTICA_BIN: join(dir, 'mc'), MC_FAKE_STATE: join(dir, 'mc.json') })
  const setup = shx(`set -e
git init -q -b main '${repo}'; cd '${repo}'
git config user.email t@example.com; git config user.name T; git config core.hooksPath '${join(dir, 'nohooks')}'; git config commit.gpgsign false
printf '.acfwhip/run/\\n' > .gitignore; mkdir -p .acfwhip/spec-tools
${Object.keys(decls).map((k) => `cat > .acfwhip/spec-tools/${k} <<'DECL'\n${decls[k]}DECL`).join('\n')}
git add .gitignore .acfwhip/spec-tools; git commit -qm seed
${store === 'multica' ? `. '${ROOT}/tests/fixtures/multica-fake.sh'; multica_fake_install '${join(dir, 'mc')}'` : ''}
${trust ? `bash '${ROOT}/skills/lib/bin/acfw-spec' trust >/dev/null 2>&1 || true; bash '${ROOT}/skills/lib/bin/acfw-spec' trust >/dev/null 2>&1` : ':'}`, dir, env)
  if (setup.code !== 0) bad(`real: repo setup failed: ${setup.err.slice(0, 300)}`)
  return { dir, repo, env }
}
// Run the whole workflow with every shell-tier call that matters executed for real, in `shell` (the
// agent's shell: bash, or zsh for the scenarios that pin zsh behaviour).
async function realRun(R, { docs, repair, reviewEnv = [], planner, store = 'files', shell = BASH }) {
  const ran = { review: [], writer: [] }
  const shx = (cmd, cwd, env) => shxIn(cmd, cwd, env, shell)
  const r = await runWorkflow(text, { scope: 'Add a login flow: API and UI', pluginRoot: ROOT, trunkRoot: R.repo, trunkBranch: 'main', store, specTaskTools: 2, planners: 1 }, {
    on: {
      'discover-agents': (c) => {
        const cmd = (c.prompt.split('\n').find((l) => /acfw-spec' list --at task/.test(l)) || '').trim()
        return { agents: AGENTS, specTools: outLines(shx(cmd, R.repo, R.env).out) }
      },
      ...Object.fromEntries(['review:task', 'review:task:retry', 'review:task:again', 'review:task:again:retry'].map((lbl) => [lbl, (c) => {
        const cmd = (c.prompt.split('\n').find((l) => /acfw-spec' review --stage task/.test(l)) || '').trim()
        const env = Object.assign({}, R.env, reviewEnv[ran.review.length] || {})
        const o = shx(cmd, R.repo, env)
        ran.review.push(Object.assign({ label: lbl }, o))
        return { lines: outLines(o.out) }
      }])),
      'write:commit': (c) => {
        const w = c.prompt
        const moves = splitCmds(between(w, '\n2. Move each file into the backlog', '\n3. Stamp'))
        const stamps = splitCmds(between(w, '\n3. Stamp', '\n4. Make sure'))
        const add = (w.split('\n').find((l) => /^5\. Stage ONLY/.test(l)) || '').replace(/^[^:]*:\s+/, '')
        const commit = (w.split('\n').find((l) => /^6\. Commit once/.test(l)) || '').replace(/^[^:]*:\s+/, '')
        const focus = (w.split('\n').find((l) => /acfw-focus' add /.test(l)) || '').trim()
        for (const cmd of moves.concat(stamps, [add, commit], focus ? [focus] : [])) ran.writer.push(Object.assign({ cmd }, shx(cmd, R.repo, R.env)))
        return { committed: true, commitSha: 'x', files: [], note: '' }
      },
      'write:ingest': (c) => {
        const block = between(c.prompt, 'THEN run these commands IN ORDER', '\n\nReturn the WriteResult')
        for (const cmd of splitCmds(block.slice(block.indexOf('\n') + 1))) ran.writer.push(Object.assign({ cmd }, shx(cmd, R.repo, R.env)))
        return { committed: true, commitSha: 'n/a', files: [], note: '' }
      },
    },
    planner: planner || (() => JSON.parse(JSON.stringify(FT_PLAN))),
    repair: (c) => repair ? repair(c.label.slice(7), R) : { id: c.label.slice(7), changed: false, note: '' },
  })
  // the authors, as the mock did not write anything: stage what `docs` says, where the prompt said
  return { r, ran }
}
// The mock's authors do not write files, so the documents are staged up front, at the path the author
// prompt names (asserted), exactly as an author following it would.
function stage(R, docs) {
  mkdirSync(join(R.repo, '.acfwhip', 'run', 'staging'), { recursive: true })
  for (const [id, body] of Object.entries(docs)) writeFileSync(join(R.repo, '.acfwhip', 'run', 'staging', `${id}.md`), body)
}
const readF = (p) => (existsSync(p) ? readFileSync(p, 'utf8') : '')
const git = (R, cmd) => shx(`git ${cmd}`, R.repo, R.env).out

try {
  // ---- 3a. files: a block tool rejects A, the repair fixes it, nothing is held ----
  sec('3a. real engine, files: reject, repair, re-review, release')
  {
    const R = mkRepo({ decls: { blk: TBD_DECL('block'), adv: TBD_DECL('advisory') } })
    stage(R, { [A]: taskDoc(A, 'Retry policy: TBD\n'), [B]: taskDoc(B) })
    let frozenSeen = ''
    const { r, ran } = await realRun(R, {
      repair: (id, RR) => {
        // The repair runs after the first review, so this is what the freeze left for the META check.
        frozenSeen = readF(join(RR.repo, '.acfwhip', 'run', 'staging', '.frozen', `${id}.md`))
        const f = join(RR.repo, '.acfwhip', 'run', 'staging', `${id}.md`)
        writeFileSync(f, readF(f).replace('Retry policy: TBD\n', 'Retry policy: three attempts, then fail.\n'))
        return { id, changed: true, note: 'replaced TBD' }
      },
    })
    check('the listing ran for real and found both task tools (the engine lists them sorted)', r.report.review && r.report.review.tools.map((t) => `${t.name}:${t.policy}`).join() === 'adv:advisory,blk:block')
    const rv1 = ran.review[0]
    check('the first review ran the engine: blk says nogo for A with its grep line as a finding', /^REVIEWED\|feature-002-login-api\|blk\|block\|nogo\|1\|/m.test(rv1.out) && /^END\|lines=4$/m.test(rv1.out) && /^RC\|0$/m.test(rv1.out))
    check('...and printed the tool listing in front of the verdicts', /^TOOL\|blk\|/m.test(rv1.out) && /^TOOLS\|2$/m.test(rv1.out) && rv1.out.indexOf('TOOLS|2') < rv1.out.indexOf('REVIEWED|'))
    check('...and froze a byte copy of each staged document first, byte for byte', frozenSeen === taskDoc(A, 'Retry policy: TBD\n'))
    check('one repair, one re-review, which found the metadata unchanged', r.labels.filter((l) => /^(repair|review):/.test(l)).join() === `review:task,repair:${A},review:task:again` && /^META\|feature-002-login-api\|same$/m.test(ran.review[1].out))
    check('the re-review ran the engine on the repaired bytes: go', /^REVIEWED\|feature-002-login-api\|blk\|block\|go\|0\|/m.test(ran.review[1].out))
    check('nothing held; both tasks in .backlog/pending/, committed', r.report.review.held.length === 0 && existsSync(join(R.repo, '.backlog/pending', `${A}.md`)) && existsSync(join(R.repo, '.backlog/pending', `${B}.md`)) && git(R, 'log -1 --name-only --format=').includes(`.backlog/pending/${A}.md`))
    check('...the repaired text is what landed', readF(join(R.repo, '.backlog/pending', `${A}.md`)).includes('three attempts'))
    check('...the staging dir and the frozen copies are gone', !existsSync(join(R.repo, '.acfwhip/run/staging', `${A}.md`)) && !existsSync(join(R.repo, '.acfwhip/run/staging/.frozen', `${A}.md`)))
    check('...the focus holds both', readF(join(R.repo, '.acfwhip/run/focus')).includes(A) && readF(join(R.repo, '.acfwhip/run/focus')).includes(B))
    const wfail = ran.writer.filter((x) => x.code !== 0)
    check(`...every writer command exited 0 (${ran.writer.length} run${wfail.length ? `; failed: ${wfail.map((x) => `${x.cmd.slice(0, 60)}: ${x.err.slice(0, 120)}`).join(' | ')}` : ''})`, ran.writer.length >= 6 && wfail.length === 0)
    check('...and the trunk is clean afterwards', git(R, 'status --porcelain').trim() === '')
  }

  // ---- 3b. files: the repair edits the metadata -> restored -> still rejected -> held in draft ----
  // The review and writer commands run in zsh here, the macOS default agent shell, because this is the
  // scenario that runs the hold's splice (holdPrepCmd) and it must not depend on bash-only sourcing.
  sec(`3b. real engine, files, under ${ZSH ? 'zsh' : 'bash (no zsh here)'}: a META-changing repair is thrown away and the task is held`)
  {
    const R = mkRepo({ decls: { blk: TBD_DECL('block') } })
    stage(R, { [A]: taskDoc(A, 'Retry policy: TBD\n'), [B]: taskDoc(B) })
    const { r, ran } = await realRun(R, {
      shell: ZSH || BASH,
      repair: (id, RR) => {
        const f = join(RR.repo, '.acfwhip', 'run', 'staging', `${id}.md`)
        writeFileSync(f, readF(f).replace('Retry policy: TBD\n', 'Retry policy: fixed.\n').replace('- **Priority**: high', '- **Priority**: low'))
        return { id, changed: true, note: 'x' }
      },
    })
    const wbad = ran.writer.filter((x) => x.code !== 0 || /acfw-store\.sh|no such file|not found|WARN:/i.test(x.err + x.out))
    check(`every writer command exited 0 with no error on stderr (${ran.writer.length} run${wbad.length ? `; bad: ${wbad.map((x) => `${x.cmd.slice(0, 50)}: ${(x.err + x.out).slice(0, 160)}`).join(' | ')}` : ''})`, ran.writer.length >= 6 && wbad.length === 0)
    check('the review calls ran clean in this shell too', ran.review.length === 2 && ran.review.every((x) => x.code === 0 && /^RC\|0$/m.test(x.out) && !x.err.trim()))
    check('the META check restored the original from the frozen copy', /^META\|feature-002-login-api\|restored$/m.test(ran.review[1].out) && r.report.review.repaired[0].metaRestored === true)
    check('...so the re-review saw the original bytes (from the cache) and still says nogo', /^REVIEWED\|feature-002-login-api\|blk\|block\|nogo\|1\|/m.test(ran.review[1].out))
    const held = join(R.repo, '.backlog/draft', `${A}.md`)
    const doc = readF(held)
    check('A is held: .backlog/draft/, committed with B in ONE commit', existsSync(held) && !existsSync(join(R.repo, '.backlog/pending', `${A}.md`)) && git(R, 'log -1 --name-only --format=').split('\n').filter(Boolean).sort().join() === `.backlog/draft/${A}.md,.backlog/pending/${B}.md`)
    check('...Status draft, the metadata the repair changed is back', /^- \*\*Status\*\*: draft$/m.test(doc) && /^- \*\*Priority\*\*: high$/m.test(doc) && !doc.includes('Retry policy: fixed.'))
    const rows = doc.slice(doc.indexOf('## Transition Log')).split('\n').filter((l) => /^\| [0-9]{4}-/.test(l))
    check(`...the hold row is the newest row, in the store's format (${rows[0] || 'none'})`, rows.length === 2 && /^\| [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \| pending \| draft \| spec-review \| held: blk nogo n=1; \/whip --review feature-002-login-api \|$/.test(rows[0]) && /Initial task creation/.test(rows[1]))
    check('...the focus holds B only', (() => { const f = readF(join(R.repo, '.acfwhip/run/focus')); return f.includes(B) && !f.includes(A) })())
    const fr = shx(`bash '${ROOT}/skills/lib/bin/acfw-store' read '${A}'`, R.repo, R.env).out
    check('...and the files store reads it as draft', /"folder"\s*:\s*"draft"/.test(fr))
    check('...the trunk is clean afterwards', git(R, 'status --porcelain').trim() === '')
  }

  // ---- 3c. untrusted tools: advisory skips, block holds (n=0, held.md), nobody repairs ----
  sec('3c. real engine: tools not trusted on this machine')
  {
    const R = mkRepo({ decls: { blk: TBD_DECL('block'), adv: TBD_DECL('advisory') }, trust: false })
    stage(R, { [A]: taskDoc(A), [B]: taskDoc(B) })
    const { r, ran } = await realRun(R, {})
    check('the advisory tool comes back skip, and a skip holds nothing', /^REVIEWED\|feature-002-login-api\|adv\|advisory\|skip\|/m.test(ran.review[0].out) && r.report.review.notes.filter((n) => n.verdict === 'skip').length === 2)
    check('the block tool comes back nogo n=0 with held.md (the engine fails closed), so both are held', /^REVIEWED\|feature-002-login-api\|blk\|block\|nogo\|0\|-\|.*\/held\.md$/m.test(ran.review[0].out) && r.report.review.held.length === 2)
    check('...and no repair was attempted (a text edit cannot trust a tool)', !r.labels.some((l) => /^repair:/.test(l)))
    check('...held.md says why: it is new on this machine and needs a "run tools" trust', /new or changed on this machine, so it did not run: trust it with a "run tools" reply/.test(readF(r.report.review.held[0].by[0].path)))
  }

  // ---- 3d. a credential literal in a task, advisory tool only: error, never held ----
  sec('3d. real engine: a credential literal in a task document')
  {
    const R = mkRepo({ decls: { adv: TBD_DECL('advisory') } })
    stage(R, { [A]: taskDoc(A, 'key sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n'), [B]: taskDoc(B) })
    const { r, ran } = await realRun(R, {})
    check('the engine refuses to send it: verdict error', /^REVIEWED\|feature-002-login-api\|adv\|advisory\|error\|/m.test(ran.review[0].out))
    check('...an error never holds: A lands in pending', r.report.review.held.length === 0 && existsSync(join(R.repo, '.backlog/pending', `${A}.md`)))
    check('...and the relay never carried the literal', !ran.review.some((x) => /sk-ant-api03/.test(x.out)))
  }

  // ---- 3e. the budget runs out on the first call: UNRUN -> one retry resumes it ----
  sec('3e. real engine: a review budget placeholder is retried once, and resumes')
  {
    const R = mkRepo({ decls: { blk: TBD_DECL('block') } })
    stage(R, { [A]: taskDoc(A), [B]: taskDoc(B) })
    const { r, ran } = await realRun(R, { reviewEnv: [{ ACFW_SPEC_BUDGET: '3' }] })
    check('first call: the engine never started the tool (unrun placeholder) and the capture said UNRUN', /^UNRUN\|feature-002-login-api\|blk$/m.test(ran.review[0].out))
    check('...one retry, which ran the tool for real: go for both', ran.review.length === 2 && ran.review[1].label === 'review:task:retry' && (ran.review[1].out.match(/\|blk\|block\|go\|/g) || []).length === 2)
    check('...nothing held, relay "retried"', r.report.review.held.length === 0 && r.report.review.relay === 'retried')
  }

  // ---- 3e2. ACFW_SPEC=off: the engine reviews nothing, and that is said, never read as a hold ----
  sec('3e2. real engine: ACFW_SPEC=off')
  {
    const R = mkRepo({ decls: { blk: TBD_DECL('block') } })
    stage(R, { [A]: taskDoc(A, 'Retry policy: TBD\n'), [B]: taskDoc(B) })
    const { r, ran } = await realRun(R, { reviewEnv: [{ ACFW_SPEC: 'off' }, { ACFW_SPEC: 'off' }] })
    check('the engine printed END|lines=0 and nothing else: a whole relay, no retry', /^END\|lines=0$/m.test(ran.review[0].out) && ran.review.length === 1 && r.report.review.relay === 'ok')
    check('...verdicts 0 in the report (the skill says nothing was reviewed)', r.report.review.verdicts === 0)
    check('...and the engine\'s choice holds nothing, even behind a block tool', r.report.review.held.length === 0 && existsSync(join(R.repo, '.backlog/pending', `${A}.md`)))
  }

  // ---- 3f. multica (non-files): the held task is created in draft with its row in the body ----
  sec('3f. real engine + multica adapter: held in draft through the store')
  if (spawnSync('bash', ['-c', 'command -v jq'], { encoding: 'utf8' }).status !== 0) {
    // Counted, not noted: this is the only real non-files proof of a hold, and a suite that ends
    // "N passed, 0 failed" without it is green by absence (the failure class 3.3.0 fixed in run-all.sh).
    bad('jq is required for the multica hold scenario (3f), and it is not installed: that coverage did not run')
  } else {
    const R = mkRepo({ decls: { blk: TBD_DECL('block') }, store: 'multica' })
    stage(R, { [A]: taskDoc(A, 'Retry policy: TBD\n'), [B]: taskDoc(B) })
    const { r, ran } = await realRun(R, { store: 'multica' })
    const mfail = ran.writer.filter((x) => x.code !== 0)
    check(`the writer's two create lines both exited 0${mfail.length ? ` (failed: ${mfail.map((x) => `${x.code}: ${x.err.slice(0, 200)}`).join(' | ')})` : ''}`, ran.writer.length === 2 && mfail.length === 0)
    const S = `bash '${ROOT}/skills/lib/bin/acfw-store'`
    check('A is in the store as draft, B as pending', /"folder"\s*:\s*"draft"/.test(shx(`${S} read '${A}'`, R.repo, R.env).out) && /"folder"\s*:\s*"pending"/.test(shx(`${S} read '${B}'`, R.repo, R.env).out))
    const body = shx(`${S} read --body '${A}'`, R.repo, R.env).out
    check('...and A\'s stored body carries the hold row', /pending \| draft \| spec-review \| held: blk nogo n=1; \/whip --review feature-002-login-api/.test(body))
    check('...the focus holds B only', (() => { const f = readF(join(R.repo, '.acfwhip/run/focus')); return f.includes(B) && !f.includes(A) })())
    check('...staged and frozen copies are gone', !existsSync(join(R.repo, '.acfwhip/run/staging', `${A}.md`)) && !existsSync(join(R.repo, '.acfwhip/run/staging/.frozen', `${B}.md`)))
    check('report: A created and flagged held', r.report.created.find((c) => c.id === A).held === true)
  }

  // ---- 3g. the record gate still holds a held line back (precedence), in bash and in zsh ----
  // Both commands here are ones a shell-tier agent runs in ITS shell. Under zsh the cycle focus once
  // passed every stem to acfw-focus as ONE argument (zsh does not split an unquoted $VAR), and the hold's
  // splice sourced a bash-only library into the agent's shell; each shell gets its own run.
  sec(`3g. plan mode shell: a held create never runs past a missing record flag (${ZSH ? 'bash and zsh' : 'bash'})`)
  {
    const R = mkRepo({ decls: {}, trust: false })
    const bin = join(R.dir, 'plug', 'skills', 'lib', 'bin')
    mkdirSync(bin, { recursive: true })
    mkdirSync(join(R.dir, 'plug', 'skills', 'lib'), { recursive: true })
    writeFileSync(join(R.dir, 'plug', 'skills', 'lib', 'acfw-git.sh'), readF(join(ROOT, 'skills', 'lib', 'acfw-git.sh')))
    writeFileSync(join(R.dir, 'plug', 'skills', 'lib', 'acfw-store.sh'), readF(join(ROOT, 'skills', 'lib', 'acfw-store.sh')))
    const logf = join(R.dir, 'calls.log')
    const created = join(R.dir, 'created.md')
    // create keeps a copy of the document it was handed, so the row the hold wrote can be read back.
    writeFileSync(join(bin, 'acfw-store'), `#!/usr/bin/env bash\nprintf 'store %s\\n' "$*" >> '${logf}'\ncase "$1" in read) printf '{"stem":"%s","folder":"%s"}\\n' "$2" "$(cat '${R.dir}'/folder."$2" 2>/dev/null || echo pending)" ;; create) cp "$3" '${created}' ;; esac\n`)
    // One line per call, plus the argument count: an argv collapsed into one word shows up as argc 5.
    writeFileSync(join(bin, 'acfw-focus'), `#!/usr/bin/env bash\nprintf 'focus %s\\n' "$*" >> '${logf}'\nprintf 'focus-argc %s\\n' "$#" >> '${logf}'\n`)
    writeFileSync(join(bin, 'acfw-cycle'), `#!/usr/bin/env bash\nprintf 'cycle %s\\n' "$*" >> '${logf}'\necho 'RECORD|ok|cycle=${CID}|tasks=2'\n`)
    for (const f of ['acfw-store', 'acfw-focus', 'acfw-cycle']) chmodSync(join(bin, f), 0o755)
    const p = await runWorkflow(text, PT('multica', { specTaskTools: 2, pluginRoot: join(R.dir, 'plug'), trunkRoot: R.repo }), {
      check: goLine.split(TR).join(R.repo), planner: planTasks, specTools: TOOLS2, review: holdOne(SA),
    })
    const wp = p.first('write:ingest').prompt
    const line = splitCmds(between(wp, 'THEN run these commands IN ORDER', '\n\nFINALLY')).find((l) => l.includes(`${SA}.md' --folder draft`)) || ''
    const focusLine = (wp.split('\n').find((l) => /acfw-focus' set /.test(l)) || '').trim()
    // The cycle record: SA (held, so draft in the store) and two unfinished tasks, so the focus gets
    // two stems and a collapsed argv cannot pass for a correct one.
    const SD = 'feature-012-seat-docs'
    mkdirSync(join(R.repo, 'docs', 'cycles', CID), { recursive: true })
    writeFileSync(join(R.repo, 'docs', 'cycles', CID, 'record.md'), `## Tasks\n| Deliverable | Tasks |\n|---|---|\n| D2 | ${SA} |\n| D3 | ${SU}, ${SD} |\n`)
    shx(`git add docs && git commit -qm rec`, R.repo, R.env)
    const flagF = join(R.repo, '.acfwhip', 'run', 'cycle', CID, 'recorded')
    for (const [name, shell] of [['bash', BASH]].concat(ZSH ? [['zsh', ZSH]] : [])) {
      mkdirSync(join(R.repo, '.acfwhip', 'run', 'staging'), { recursive: true })
      writeFileSync(join(R.repo, '.acfwhip', 'run', 'staging', `${SA}.md`), taskDoc(SA))
      rmSync(flagF, { force: true })
      rmSync(created, { force: true })
      writeFileSync(logf, '')
      const noflag = shx(line, R.repo, R.env, shell)
      check(`[${name}] no record flag: the held line creates nothing, writes no row, and fails`, noflag.code !== 0 && !/store create/.test(readF(logf)) && !/spec-review/.test(readF(join(R.repo, '.acfwhip/run/staging', `${SA}.md`))))
      mkdirSync(dirname(flagF), { recursive: true })
      writeFileSync(flagF, '')
      const withflag = shx(line, R.repo, R.env, shell)
      check(`[${name}] with the flag: row first, then create --folder draft, then the staged file removed`, withflag.code === 0 && /store create --file \S+ --folder draft/.test(readF(logf)) && !existsSync(join(R.repo, '.acfwhip/run/staging', `${SA}.md`)))
      const doc = readF(created)
      const rows = doc.slice(doc.indexOf('## Transition Log')).split('\n').filter((l) => /^\| [0-9]{4}-/.test(l))
      check(`[${name}] ...the document the store got says draft, with the hold row newest (${rows[0] || 'none'})`, /^- \*\*Status\*\*: draft$/m.test(doc) && rows.length === 2 && /^\| [0-9-]{10} [0-9:]{8} \| pending \| draft \| spec-review \| held: blk nogo n=2; \/whip --review feature-010-seat-api \|$/.test(rows[0]))
      check(`[${name}] ...and the line printed no error and no WARN (stderr: ${(withflag.err || 'none').trim().slice(0, 160)})`, !withflag.err.trim() && !/WARN/.test(withflag.out))
      // the cycle focus, with the draft skip, as the writer would run it
      writeFileSync(join(R.dir, `folder.${SA}`), 'draft\n')
      writeFileSync(logf, '')
      shx(focusLine, R.repo, R.env, shell)
      const lg = readF(logf)
      check(`[${name}] the cycle focus skips the held (draft) task and passes each other stem as its own argument (${lg.trim().replace(/\n/g, ' / ')})`, /^focus set --no-resolve --by task feature-011-seat-ui feature-012-seat-docs$/m.test(lg) && /^focus-argc 6$/m.test(lg))
      rmSync(join(R.dir, `folder.${SA}`), { force: true })
    }
  }
} finally {
  rmSync(W, { recursive: true, force: true })
}

// ============================ the skill documents the contract ============================
sec('4. task/SKILL.md')
{
  const skill = readFileSync(join(ROOT, 'skills', 'task', 'SKILL.md'), 'utf8')
  check('every plugin-root reference is braced (Claude Code substitutes only ${CLAUDE_PLUGIN_ROOT})', !/\$CLAUDE_PLUGIN_ROOT(?!\})/.test(skill) && /\$\{CLAUDE_PLUGIN_ROOT\}/.test(skill))
  check('step 1 counts the task tools with acfw-spec list --at task --machine', /SPEC_TASK_TOOLS=\$\(bash "\$\{CLAUDE_PLUGIN_ROOT\}\/skills\/lib\/bin\/acfw-spec" list --at task --machine/.test(skill))
  check('step 2 passes specTaskTools', /specTaskTools: <SPEC_TASK_TOOLS>/.test(skill))
  check('the held-in-draft outcome is documented, with the row and the release path', /held in draft/.test(skill) && /spec-review \| held: /.test(skill) && /\/whip-move <stem> pending/.test(skill) && /\/whip-focus add <stem>/.test(skill))
  check('skip and error never hold, and an advisory tool never holds', /never holds a task/.test(skill) && /`advisory`\s+tool never holds a task/.test(skill))
  check('the plan-mode report covers a held task', /`review\.held` is still this cycle's task/.test(skill))
  check('a relay-loss hold is documented as unreviewed, with its row, and the unknown fallback', /held: <tool> unreviewed \(verdict not relayed\)/.test(skill) && /under the name `unknown`/.test(skill))
  check('a task waiting on a held one is documented, and not counted as runnable', /`review\.waiting`/.test(skill) && /do\s+not count it among the tasks a bare `\/go` runs now/.test(skill))
  const prose = skill.slice(skill.indexOf('### Task-stage spec review'), skill.indexOf('**Launch by NAME'))
  check('the new prose has no em dashes', prose.length > 500 && !prose.includes('—'))
  check('...and none of the banned words', !/\b(seamless|leverage|utiliz|facilitat|enabl|powerful|cutting-edge|comprehensive|robust|elegant|significant|substantial)/i.test(prose))
}

console.log(`\nphase21-spec-task: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL ? 1 : 0)
