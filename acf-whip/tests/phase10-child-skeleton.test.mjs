// phase10-child-skeleton.test.mjs — behavioral proof of the 3.2.0 per-task child skeleton.
//
// Scaffolds the REAL shipped template via the REAL acfw-child-scaffold, then executes it exactly as the
// Workflow runtime does (async-function wrap, mocked globals) against an in-memory agent.
//
// The floor this pins: an UNFILLED harness must be observably 3.1.0 — one implementer agent that
// receives the verbatim 3.1.x seam prompt and returns an ACFW_RESULT. Everything else the skeleton adds
// is a superset. If this test ever fails, the feature has become a regression rather than an addition.
//
// Run: node acf-whip/tests/phase10-child-skeleton.test.mjs

import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { tmpdir } from 'node:os'

const HERE = dirname(fileURLToPath(import.meta.url))
const SCAFFOLD = join(HERE, '..', 'skills', 'lib', 'bin', 'acfw-child-scaffold')

let PASS = 0, FAIL = 0
const ok = (m) => { PASS++; console.log(`  PASS: ${m}`) }
const bad = (m) => { FAIL++; console.log(`  FAIL: ${m}`) }
const check = (m, cond) => (cond ? ok(m) : bad(m))

const WORK = mkdtempSync(join(tmpdir(), 'acfw-p10-'))

function scaffold(kind, gate = 'make test') {
  const p = join(WORK, `${kind}.workflow.js`)
  execFileSync('bash', [SCAFFOLD, p, '--kind', kind, '--stem', 's1', '--meta-name', `whip-${kind}-s1`, '--gate', gate], { encoding: 'utf8' })
  return readFileSync(p, 'utf8')
}

// Replace the authored body region, exactly as an architect does.
function withBody(src, body) {
  const a = src.indexOf('// <acfw-body>')
  const b = src.indexOf('// </acfw-body>')
  if (a < 0 || b < 0) throw new Error('body markers missing')
  return src.slice(0, a + '// <acfw-body>'.length) + '\n' + body + '\n' + src.slice(b)
}

const BASE_PROMPT = '<<<VERBATIM-3.1.x-SEAM-PROMPT>>>'

function baseArgs(kind, over = {}) {
  return {
    stem: 's1', slug: 'sl', branch: 'worktree/sl', forkbaseRef: 'refs/acfw/forkbase/sl',
    taskPath: '/r/.backlog/in-progress/s1.md', ledgerDir: '/r/.acfwhip/run/child/s1/a0-b0/' + kind,
    ledgerBin: '/p/acfw-child-ledger', runLock: '/r/.backlog/.acfw-run.json',
    basePrompt: BASE_PROMPT, resultSchema: { type: 'object' }, lensSchema: { type: 'object' },
    shellModel: 'haiku', agentBudget: 8, fanoutMax: 3,
    registry: ['go-engineer', 'quality-reviewer'], agentType: 'go-engineer',
    git: { commits: [], dirty: [], worktree: '' },
    trunkRoot: '/r', cleanCheckout: '/p/clean-checkout.sh',
    priorStages: {}, shallow: false, conflictedFiles: '',
    ...over,
  }
}

// Run one scaffolded child. `respond(label, prompt)` returns the agent result, or throws to simulate a
// non-emit, or returns the sentinel THROW_DEFECT to simulate a genuine script defect.
async function run(src, args, respond) {
  const calls = []
  let inFlightMutating = 0, overlapped = false
  const log = () => {}
  const phase = () => {}
  const parallel = (thunks) => Promise.all(thunks.map((f) => Promise.resolve().then(f).catch(() => null)))
  const pipeline = async () => { throw new Error('pipeline not expected') }
  const agent = async (prompt, opts) => {
    const label = (opts && opts.label) || ''
    calls.push({ label, prompt, opts })
    // Detect two mutating stages in flight at once (runWave must serialize them).
    const isMut = /MUTATING/.test(prompt)
    if (isMut) { if (inFlightMutating > 0) overlapped = true; inFlightMutating++ }
    try {
      await Promise.resolve()
      return await respond(label, prompt)
    } finally { if (isMut) inFlightMutating-- }
  }
  const body = src.replace(/^export const meta/m, 'const meta')
  const fn = new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow',
    `return (async () => {\n${body}\n})()`)
  let out = null, threw = null
  try { out = await fn(agent, parallel, pipeline, phase, log, args, undefined, undefined) } catch (e) { threw = e }
  return { out, threw, calls, overlapped }
}

const stage = (label) => label.replace(/^s1:/, '')
const okCheckout = { exitCode: 0, worktreePath: '/r/.worktree/sl' }
const okVerify = { commits: 2, dirty: 0, headSha: 'abc1234', impure: 0 }

// ============================ 1-2. the unfilled harness is observably 3.1.0 ============================
{
  const src = scaffold('impl')
  const r = await run(src, baseArgs('impl'), async (label) => {
    const s = stage(label)
    if (s === 'checkout') return okCheckout
    if (s === 'implement') return { transition: 'completed', commitSha: 'deadbee', rejectionIncrement: 0, notes: 'done' }
    if (s.startsWith('gate')) return { passed: true, failingOutput: '' }
    if (s === 'adversarial') return { verdict: 'accept', findings: '' }
    if (s === 'verify') return okVerify
    throw new Error('unmocked: ' + s)
  })
  const impl = r.calls.find((c) => stage(c.label) === 'implement')
  check('1a unfilled harness returns transition completed', r.out && r.out.transition === 'completed')
  check('1b return is ACFW_RESULT-shaped', r.out && typeof r.out.commitSha === 'string' && r.out.rejectionIncrement === 0 && typeof r.out.notes === 'string')
  check('1c commitSha is the VERIFIED head sha, not the implementer self-report', r.out.commitSha === 'abc1234')
  check('1d the implementer received the verbatim 3.1.x seam prompt', !!impl && impl.prompt.includes(BASE_PROMPT))
  check('1e the implementer kept the task\'s assigned agentType', !!impl && impl.opts.agentType === 'go-engineer')
  check('2a checkout ran exactly once', r.calls.filter((c) => stage(c.label) === 'checkout').length === 1)
  check('2b checkout was the FIRST agent', stage(r.calls[0].label) === 'checkout')
  check('2c no throw', r.threw === null)
}

// ============================ 3. the WT-1 observation guard is in the checkout prompt ============================
{
  const src = scaffold('impl')
  const r = await run(src, baseArgs('impl'), async (label) => {
    const s = stage(label)
    if (s === 'checkout') return okCheckout
    if (s === 'implement') return { transition: 'blocked', commitSha: 'n/a', rejectionIncrement: 0, notes: 'x', blockedReason: 'environment' }
    throw new Error('unmocked: ' + s)
  })
  const co = r.calls.find((c) => stage(c.label) === 'checkout')
  check('3a checkout observes before creating (worktree list --porcelain)', co.prompt.includes('worktree list --porcelain'))
  check('3b checkout only falls through to clean-checkout when nothing was observed', /if \[ -n "\$WT" \]; then echo "\$WT"; else bash/.test(co.prompt))
  check('3c a blocked implementer propagates blockedReason', r.out.transition === 'blocked' && r.out.blockedReason === 'environment')
}

// ============================ 4-5. the locked verify gate refuses to lie ============================
for (const [name, v, why] of [
  ['4 dirty tree', { ...okVerify, dirty: 3 }, 'uncommitted'],
  ['5a no commit', { ...okVerify, commits: 0 }, 'no commit'],
  ['5b impure diff', { ...okVerify, impure: 1 }, '.acfwhip/'],
]) {
  const src = scaffold('impl')
  const r = await run(src, baseArgs('impl'), async (label) => {
    const s = stage(label)
    if (s === 'checkout') return okCheckout
    if (s === 'implement') return { transition: 'completed', commitSha: 'x', rejectionIncrement: 0, notes: 'done' }
    if (s.startsWith('gate')) return { passed: true, failingOutput: '' }
    if (s === 'adversarial') return { verdict: 'accept', findings: '' }
    if (s === 'verify') return v
    throw new Error('unmocked: ' + s)
  })
  check(`${name} => transition 'none', not completed`, r.out && r.out.transition === 'none')
  check(`${name} => typed as a mechanism fault`, r.out && r.out.faultClass === 'mechanism')
}

// ============================ 6. agent non-emit is a value, never a throw ============================
{
  const src = scaffold('impl')
  const r = await run(src, baseArgs('impl'), async (label) => {
    const s = stage(label)
    if (s === 'checkout') return okCheckout
    if (s.startsWith('implement')) throw new Error('StructuredOutput non-emit')
    if (s === 'verify') return okVerify
    throw new Error('unmocked: ' + s)
  })
  check('6a a non-emitting stage does not throw out of the child', r.threw === null)
  check('6b the harness still returns a well-formed result', r.out && r.out.ok === true && typeof r.out.transition === 'string')
  check('6c it degrades to none (transient), not to a false completed', r.out.transition === 'none')
  check('6d the stage was retried once before degrading', r.calls.filter((c) => stage(c.label).startsWith('implement')).length === 2)
}

// ============================ 7. a script defect is recorded, then rethrown ============================
{
  const src = withBody(scaffold('impl'), `  const q = null; q.boom.deep = 1`)
  const r = await run(src, baseArgs('impl'), async (label) => {
    const s = stage(label)
    if (s === 'checkout') return okCheckout
    if (s === '__throw') return 'noted'
    throw new Error('unmocked: ' + s)
  })
  check('7a a TypeError in the body is rethrown to /go (repairable by amending)', r.threw !== null && /TypeError|Cannot read/.test(String(r.threw)))
  check('7b recordThrow ran BEFORE the rethrow', r.calls.some((c) => stage(c.label) === '__throw'))
  check('7c the throw record names the ledger append', r.calls.find((c) => stage(c.label) === '__throw').prompt.includes('__throw --status fail'))
}

// ============================ 8. replay returns the RECORDED value and spawns no agent ============================
{
  const src = scaffold('impl')
  const recorded = { transition: 'completed', commitSha: 'from-ledger', rejectionIncrement: 0, notes: 'recorded run' }
  const args = baseArgs('impl', {
    priorStages: {
      checkout: { status: 'ok', result: okCheckout },
      implement: { status: 'ok', result: recorded },
    },
  })
  const r = await run(src, args, async (label) => {
    const s = stage(label)
    if (s.startsWith('gate')) return { passed: true, failingOutput: '' }
    if (s === 'adversarial') return { verdict: 'accept', findings: '' }
    if (s === 'verify') return okVerify
    throw new Error('unmocked: ' + s)
  })
  check('8a ZERO implement agents spawned on replay', r.calls.filter((c) => stage(c.label) === 'implement').length === 0)
  check('8b ZERO checkout agents spawned on replay (no second stash, ever)', r.calls.filter((c) => stage(c.label) === 'checkout').length === 0)
  check('8c the replayed value was USED, not null', r.out && r.out.transition === 'completed')
  check('8d replayed stages are reported', r.out.stagesReplayed.includes('implement') && r.out.stagesReplayed.includes('checkout'))
  check('8e a replayed stage did not consume budget', r.out.agentsUsed < 8)
}

// ============================ 9. iteration-keyed loop stages ============================
{
  const src = scaffold('impl')
  let gateCalls = 0
  const r = await run(src, baseArgs('impl'), async (label) => {
    const s = stage(label)
    if (s === 'checkout') return okCheckout
    if (s === 'implement') return { transition: 'completed', commitSha: 'x', rejectionIncrement: 0, notes: 'd' }
    if (s.startsWith('gate-fix')) return { ok: true, summary: 'fixed' }
    if (s.startsWith('gate')) { gateCalls++; return { passed: false, failingOutput: 'boom' } }
    if (s === 'adversarial') return { verdict: 'accept', findings: '' }
    if (s === 'verify') return okVerify
    throw new Error('unmocked: ' + s)
  })
  const labels = r.calls.map((c) => stage(c.label))
  check('9a the gate loop dispatched TWICE, not once (no frozen cached result)', gateCalls === 2)
  check('9b iterations produced DISTINCT ledger keys gate#0 and gate#1', labels.includes('gate#0') && labels.includes('gate#1'))
  check('9c the fixer is iteration-keyed too', labels.includes('gate-fix#0'))
  check('9d the fixer received the verbatim failing output', r.calls.find((c) => stage(c.label) === 'gate-fix#0').prompt.includes('boom'))
}

// ============================ 10. review panel arithmetic — no veto ============================
async function panel(verdicts) {
  const src = withBody(scaffold('review'), `  lensVerdicts = ${JSON.stringify(verdicts)}`)
  const r = await run(src, baseArgs('review'), async (label) => {
    const s = stage(label)
    if (s === 'review-gate') return { checkoutOk: true, checkoutExit: 0, worktreePath: '/r/.worktree/sl', gateOutput: '', note: '' }
    throw new Error('unmocked: ' + s)
  })
  return r.out
}
{
  const a = ['acceptance', 'regression', 'conventions']
  const mk = (v) => a.map((lens, i) => ({ lens, verdict: v[i], findings: 'f', severity: 'major' }))
  const oneReject = await panel(mk(['reject', 'accept', 'accept']))
  check('10a 1 of 3 lenses rejecting => ACCEPTED (no veto)', oneReject.transition === 'accepted')
  const twoReject = await panel(mk(['reject', 'reject', 'accept']))
  check('10b 2 of 3 => rejected (strict majority)', twoReject.transition === 'rejected')
  check('10c a panel rejection costs exactly ONE life', twoReject.rejectionIncrement === 1)
  check('10d the rejection names the dissenting lenses', /acceptance/.test(twoReject.notes) && /regression/.test(twoReject.notes))
  const oneOfTwo = await panel([{ lens: 'a', verdict: 'reject', findings: 'f' }, { lens: 'b', verdict: 'accept', findings: '' }])
  check('10e 1 of 2 => accepted (a 2-lens panel cannot reject on a tie)', oneOfTwo.transition === 'accepted')
  const twoOfTwo = await panel([{ lens: 'a', verdict: 'reject', findings: 'f' }, { lens: 'b', verdict: 'reject', findings: 'g' }])
  check('10f 2 of 2 => rejected (unanimous is still a majority)', twoOfTwo.transition === 'rejected')
  const abstain = await panel([{ __failed: true }, { __failed: true }, { __failed: true }])
  check('10g all lenses abstaining => none, NOT a rejection', abstain.transition === 'none')
  check('10h an all-abstain panel is a mechanism fault (charges no quality budget)', abstain.faultClass === 'mechanism')
}

// ============================ 11. runWave serializes mutators ============================
{
  const body = `
  await runWave([
    { key: 'ro-a', prompt: 'read only a' },
    { key: 'ro-b', prompt: 'read only b' },
    { key: 'mut-a', mutates: true, prompt: 'MUTATING a' },
    { key: 'mut-b', mutates: true, prompt: 'MUTATING b' },
  ])
  want = 'completed'`
  const src = withBody(scaffold('impl'), body)
  const r = await run(src, baseArgs('impl'), async (label) => {
    const s = stage(label)
    if (s === 'checkout') return okCheckout
    if (s === 'verify') return okVerify
    return { ok: true }
  })
  check('11a two mutating stages NEVER overlapped', r.overlapped === false)
  check('11b all four wave stages ran', ['ro-a', 'ro-b', 'mut-a', 'mut-b'].every((k) => r.calls.some((c) => stage(c.label) === k)))
}

// ============================ 12. the budget ceiling is enforced, not advisory ============================
{
  const src = scaffold('impl')
  const r = await run(src, baseArgs('impl', { agentBudget: 3 }), async (label) => {
    const s = stage(label)
    if (s === 'checkout') return okCheckout
    if (s === 'implement') return { transition: 'completed', commitSha: 'x', rejectionIncrement: 0, notes: 'd' }
    if (s.startsWith('gate')) return { passed: false, failingOutput: 'boom' }
    if (s === 'adversarial') return { verdict: 'accept', findings: '' }
    if (s === 'verify') return okVerify
    throw new Error('unmocked: ' + s)
  })
  const dispatched = r.calls.filter((c) => !stage(c.label).startsWith('__')).length
  check('12a no more than the budget was dispatched', dispatched <= 3)
  check('12b the harness still returned a well-formed result at the ceiling', r.out && r.out.ok === true)
  check('12c it did not claim completed after degrading', r.out.transition === 'none')
}

// ============================ 13. non-code (direct) kind ============================
{
  const src = scaffold('direct')
  const r = await run(src, baseArgs('direct'), async (label) => {
    const s = stage(label)
    if (s === 'produce') return { transition: 'completed', commitSha: 'n/a', rejectionIncrement: 0, notes: 'wrote docs', deliverableFiles: ['docs/x.md'] }
    throw new Error('unmocked: ' + s)
  })
  check('13a direct kind runs NO checkout stage', !r.calls.some((c) => stage(c.label) === 'checkout'))
  check('13b direct kind runs NO verify stage (it commits nothing)', !r.calls.some((c) => stage(c.label) === 'verify'))
  check('13c deliverableFiles survive to the return (or the writer never stages them)', r.out.deliverableFiles.includes('docs/x.md'))
  check('13d transition completed', r.out.transition === 'completed')
}

console.log(`\nphase10-child-skeleton: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL === 0 ? 0 : 1)
