// phase15-first-run-autoreject.test.mjs — regression proof for the first-run clean-checkout auto-reject.
//
// The deterministic gate in runReviewAndIntegrate reads hasCleanCheckoutToken/hasWorktreeBranch off the
// task object. That object comes from the SCAN, and on the inline path it is handed to the gate AFTER
// the specialist ran — so for a first attempt both fields describe the world one specialist-run in the
// past: no token row yet, no refs/heads/worktree/<slug> yet. The gate therefore hard-rejected every code
// task on its first completion, on every backend, charging 1 of MAX_REJECT_RETRY=3 and costing a
// specialist round plus two iterations. It then "recovered" (the branch existed next iteration, so the
// gate took the mechanism arm), which is exactly why it survived undiagnosed.
//
// Neither phase5-streaming nor phase11-escalation could catch it: phase5's fixture sets
// hasWorktreeBranch:true on a never-dispatched task and omits hasCleanCheckoutToken entirely, and
// phase11 hard-codes hasCleanCheckoutToken:true. Both make the strict `=== false` unreachable.
//
// This suite drives the REAL workflow body with the fixture the scanner actually produces — both flags
// false at scan time — and flips them on the MODEL when the unit runs, which is what clean-checkout does.
//
// Run: node acf-whip/tests/phase15-first-run-autoreject.test.mjs

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const SRC = join(HERE, '..', 'workflows', 'whip-go.workflow.js')

let PASS = 0, FAIL = 0
const ok = (m) => { PASS++; console.log(`  PASS: ${m}`) }
const bad = (m) => { FAIL++; console.log(`  FAIL: ${m}`) }
const check = (m, cond) => (cond ? ok(m) : bad(m))

// ---- the fixture the SCANNER actually produces for a first-run pending task ----
// scan-backlog.sh:124 greps the document for the token row -> false (no row yet).
// scan-backlog.sh:129-130 derives the branch from refs/heads/worktree/* -> false (nothing created yet).
const T = (stem, slug, folder = 'pending') => ({
  stem, id: stem, folder, slug, deps: [],
  hasIntegratedAt: false,
  hasWorktreeBranch: false,      // <-- the two fields every other suite stubs the other way
  hasCleanCheckoutToken: false,
  rejectionCount: 0, blockCount: 0, ageHours: -1, priority: 'medium',
})
// alpha: a first-run PENDING task. It is dispatched this iteration, so the object the gate sees
//        predates its own clean-checkout — the stale-read case. Must NOT be auto-rejected.
// beta:  already in COMPLETED at scan time, with no token and no branch. It reaches review through
//        the premove call site, which passes NO opts, so the gate is LIVE for it. Must BE
//        auto-rejected — otherwise the tokenStale fix is a hole rather than a correction, and every
//        assertion below would pass just as well with the gate deleted outright.
const model = new Map([['alpha', T('alpha', 'sa')], ['beta', T('beta', 'sb', 'completed')]])

function isTerminalModel(t) { return t.folder === 'accepted' && (t.hasIntegratedAt || t.slug === 'none' || !t.hasWorktreeBranch) }
function buildSnapshot() {
  const tasks = [...model.values()].map((t) => ({ ...t }))
  const c = { pending: 0, 'in-progress': 0, completed: 0, 'in-review': 0, blocked: 0, rejected: 0, accepted: 0 }
  for (const t of tasks) { if (c[t.folder] != null) c[t.folder]++ }
  return {
    trunkRoot: '/r', tasks, satisfiedDeps: [], inProgressTimeoutHours: 8,
    counts: {
      ...c,
      total: tasks.length,
      integrated: tasks.filter((t) => t.hasIntegratedAt).length,
      runtimeTerminalDefault: tasks.filter(isTerminalModel).length,
      runtimeTerminalOverride: tasks.filter((t) => t.folder === 'accepted' || t.folder === 'blocked').length,
    },
  }
}

// ---- writer: capture inc and notes too, or the assertions below cannot be written ----
const events = []
let tick = 0
function applyWriter(prompt) {
  const applied = []
  const re = /bash '[^']*acfw-store' transition '([^']*)' '([^']*)' '([^']*)' '([^']*)' '([^']*)' '([^']*)'/g
  let m
  while ((m = re.exec(prompt)) !== null) {
    const [, stem, toState, , , rinc] = m
    const t = model.get(stem)
    if (t) {
      t.folder = toState
      if (toState === 'rejected' && rinc === '1') t.rejectionCount++
      events.push({ tick: tick++, kind: 'transition', stem, toState, rinc })
      applied.push(`ok: ${stem} -> ${toState}`)
    } else applied.push(`noop: ${stem}`)
  }
  return { applied, note: 'mock writer' }
}

// ---- mocked workflow globals ----
const log = (m) => { events.push({ tick: tick++, kind: 'log', m: String(m) }) }
const phase = () => {}
const parallel = (thunks) => Promise.all(thunks.map((f) => Promise.resolve().then(f).catch(() => null)))
const pipeline = async () => { throw new Error('pipeline not expected in this test') }

// This is what clean-checkout.sh actually does inside the unit: create the branch and append the token
// row. Both the escalated (child workflow) and legacy (direct agent) paths must do it, so that whichever
// path the runtime takes, the NEXT snapshot reports them true — exactly like a real store.
function runCleanCheckout(stem) {
  const t = model.get(stem)
  if (!t) return
  t.hasWorktreeBranch = true
  t.hasCleanCheckoutToken = true
  events.push({ tick: tick++, kind: 'clean-checkout', stem })
}

const workflowCalls = []
const workflow = async (ref, wargs) => {
  workflowCalls.push({ stem: wargs.stem, round: wargs.round })
  runCleanCheckout(wargs.stem)
  return { ok: true, transition: 'completed', commitSha: 'deadbeef', rejectionIncrement: 0, faultClass: 'quality', notes: 'done', deliverableFiles: [], stagesRan: ['implement'], stagesReplayed: [], agentsUsed: 4 }
}

const specialistRuns = []
async function agent(prompt, opts) {
  const label = (opts && opts.label) || ''
  if (/Bootstrap the acf-whip/.test(prompt)) return { detached: false, doctorOk: true, doctorSummary: 'SUMMARY|ok=true', fatals: [], cpuCores: 8, agents: ['go-engineer', 'quality-reviewer'], scaffoldOk: true }
  if (/Read-only reconnaissance/.test(prompt)) {
    const slug = (prompt.match(/branch refs\/heads\/worktree\/(\w+)/) || [])[1] || ''
    return { worktree: `/r/.worktree/${slug}`, worktreeExists: true, commits: [], stageTrailers: [], dirty: [], stashes: [], stages: [], note: '' }
  }
  if (/WORKFLOW ARCHITECT/.test(prompt)) return { wrote: true, scriptPath: '/r/.acfwhip/run/child/x/a0-b0/impl/harness.workflow.js', planKeys: ['implement'], preservedStages: [], maxAgents: 5, shallow: true, summary: 'default shape fits', refuse: 'none', needsTask: '' }
  if (/acfw-child-validate/.test(prompt)) return { ok: true, parser: 'node', errors: [], warnings: [], stageCount: 5, mutatingStages: 3 }
  if (/acfw-store' snapshot/.test(prompt)) return { snapshotJson: JSON.stringify(buildSnapshot()), doctorOk: true, doctorSummary: 'SUMMARY|ok=true', doctorFatals: [] }
  if (/SINGLE backlog writer/.test(prompt)) return applyWriter(prompt)
  if (/integrator for one accepted task/.test(prompt)) {
    const stem = prompt.replace(/^[\s\S]*\/accepted\/([^/']+)\.md[\s\S]*$/, '$1')
    const t = model.get(stem)
    if (t) t.hasIntegratedAt = true
    events.push({ tick: tick++, kind: 'integrate', stem })
    return { exitCode: 0, outcome: 'integrated', note: 'mock', resolverWorktree: '', resolverBranch: '', resolverAgent: '', resolverConflictedFiles: '', resolverConflictingCommits: '' }
  }
  if (/quality-reviewer reviewing/.test(prompt) || /reviewing one NON-CODE/.test(prompt)) {
    events.push({ tick: tick++, kind: 'review', label })
    return { transition: 'accepted', commitSha: 'n/a', rejectionIncrement: 0, notes: 'lgtm' }
  }
  if (/specialist executing one acf-whip/.test(prompt)) {
    const stem = (prompt.match(/\/([a-z]+)\.md/) || [])[1] || 'alpha'
    specialistRuns.push(stem)
    runCleanCheckout(stem)
    return { transition: 'completed', commitSha: 'deadbeef', rejectionIncrement: 0, notes: 'done' }
  }
  if (/agent executing one NON-CODE/.test(prompt)) return { transition: 'completed', commitSha: 'n/a', rejectionIncrement: 0, notes: 'done' }
  throw new Error('unmocked agent prompt: ' + prompt.slice(0, 80))
}

// ---- load + run the workflow body ----
const body = readFileSync(SRC, 'utf8').replace(/^export const meta/m, 'const meta')
const run = new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow',
  `return (async () => {\n${body}\n})()`)

const args = { pluginRoot: '/p', trunkRoot: '/r', trunkBranch: 'trunk', mode: 'default' }
const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('TIMEOUT')), 20000))

let report
try {
  report = await Promise.race([run(agent, parallel, pipeline, phase, log, args, undefined, workflow), timeout])
} catch (e) {
  bad(`workflow did not converge: ${e.message}`)
  console.log(`\nphase15-first-run-autoreject: ${PASS} passed, ${FAIL} failed`)
  process.exit(1)
}

// ---- assertions ----
const rejects = events.filter((e) => e.kind === 'transition' && e.toState === 'rejected')

// THE one that fails on the pre-fix tree.
check('a unit that ran clean-checkout inside its own dispatch is NOT auto-rejected',
  !rejects.some((e) => e.stem === 'alpha'))
check('no rejection life is charged to a first-run task', model.get('alpha').rejectionCount === 0)
check('the task was reviewed rather than skipped', events.some((e) => e.kind === 'review'))
check('the task reached accepted', model.get('alpha').folder === 'accepted')
check('the task was implemented exactly once (no spurious re-dispatch)',
  workflowCalls.filter((c) => c.stem === 'alpha').length + specialistRuns.filter((s) => s === 'alpha').length === 1)

// THE assertion that makes this suite a proof rather than a description. Without it every check
// above passes with the deterministic gate deleted outright — verified. beta is scan-fresh with no
// token and no branch, so the gate must fire for it.
check('the gate is still LIVE on the scan-fresh path: beta IS auto-rejected',
  rejects.some((e) => e.stem === 'beta'))
check('...and it is charged a rejection (inc 1, a real quality reject)',
  rejects.some((e) => e.stem === 'beta' && e.rinc === '1'))
check('...and the report names it', report && (report.rejectedAtReview || []).includes('beta'))
check('the run report exposes review-time auto-rejects (they used to be recorded nowhere)',
  report && Array.isArray(report.rejectedAtReview))
check('alpha is NOT in that tally', !(report.rejectedAtReview || []).includes('alpha'))

console.log(`\nphase15-first-run-autoreject: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL === 0 ? 0 : 1)
