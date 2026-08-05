// phase5-streaming.test.mjs — behavioral proof of the BUG-3 streaming pipeline in whip-go.workflow.js.
//
// It executes the REAL workflow body (wrapped like the harness does) with mocked agent()/parallel()/
// log()/phase(), driving an in-memory backlog of two no-dep code tasks: "fast" and "slow", dispatched
// in the same wave. The slow specialist is GATED so it only returns AFTER the fast task has been
// integrated. Under the OLD per-iteration barrier (parallel-all -> then integrate) this is a DEADLOCK:
// fast's integration could not run until the barrier released, which waited for slow, which waited for
// fast's integration. Under the streaming pipeline each unit integrates inside its own lifecycle, so it
// converges. Passing therefore proves: (1) a fast task is reviewed+integrated while a slow task in the
// same wave is still running, and (2) the single-writer invariant holds (no overlapping writer calls).
//
// Run: node acf-whip/tests/phase5-streaming.test.mjs

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const SRC = join(HERE, '..', 'workflows', 'whip-go.workflow.js')

let PASS = 0, FAIL = 0
const ok = (m) => { PASS++; console.log(`  PASS: ${m}`) }
const bad = (m) => { FAIL++; console.log(`  FAIL: ${m}`) }
const check = (m, cond) => (cond ? ok(m) : bad(m))

// ---- in-memory backlog model ----
const T = (stem, slug) => ({ stem, id: stem, folder: 'pending', slug, deps: [], hasIntegratedAt: false, hasWorktreeBranch: true, rejectionCount: 0, blockCount: 0, ageHours: -1, priority: 'medium' })
const model = new Map([['fast', T('fast', 'sf')], ['slow', T('slow', 'ss')]])

function isTerminalModel(t) { return t.folder === 'accepted' && (t.hasIntegratedAt || t.slug === 'none' || !t.hasWorktreeBranch) }
function buildSnapshot() {
  const tasks = [...model.values()].map((t) => ({ ...t }))
  const c = { pending: 0, 'in-progress': 0, completed: 0, 'in-review': 0, blocked: 0, rejected: 0, accepted: 0, integrated: 0 }
  for (const t of tasks) { if (c[t.folder] != null) c[t.folder]++ }
  const counts = {
    ...c,
    total: tasks.length,
    integrated: tasks.filter((t) => t.hasIntegratedAt).length,
    runtimeTerminalDefault: tasks.filter(isTerminalModel).length,
    runtimeTerminalOverride: tasks.filter((t) => t.folder === 'accepted' || t.folder === 'blocked').length,
  }
  return { trunkRoot: '/r', counts, tasks, satisfiedDeps: [], inProgressTimeoutHours: 8 }
}

// ---- writer: parse the acfw-store transition command lines out of the prompt and mutate the model ----
function applyWriter(prompt) {
  const applied = []
  const re = /bash '[^']*acfw-store' transition '([^']*)' '([^']*)' '([^']*)' '([^']*)' '([^']*)' '([^']*)'/g
  let m
  while ((m = re.exec(prompt)) !== null) {
    const [, stem, toState] = m
    const t = model.get(stem)
    if (t) { t.folder = toState; applied.push(`ok: ${stem} -> ${toState}`) }
    else applied.push(`noop: ${stem}`)
  }
  return { applied, note: 'mock writer' }
}

// ---- gating: slow specialist resolves only after fast is integrated ----
const events = []
let tick = 0
let resolveSlowGate
const slowGate = new Promise((res) => { resolveSlowGate = res })
let slowSpecialistDone = false
let writerActive = 0
let writerOverlap = false

// ---- mocked workflow globals ----
const log = (m) => { events.push({ tick: tick++, kind: 'log', m: String(m) }) }
const phase = () => {}
// parallel(): run thunks concurrently, mapping a thrown thunk to null (matches runtime semantics).
const parallel = (thunks) => Promise.all(thunks.map((f) => Promise.resolve().then(f).catch(() => null)))
const pipeline = async () => { throw new Error('pipeline not expected in this test') }

// ---- 3.2.0: the nested child workflow ----
// Records every invocation, THROWS ONCE for the 'fast' task (so the scout -> amend -> re-run repair
// loop is genuinely exercised rather than merely present), and honours args.priorStages so the replay
// path is observable. The gating that used to live in the specialist mock lives here now, because with
// escalation on the implementation runs inside the child, not in a direct agent() call.
const architectCalls = [], validateCalls = [], workflowCalls = []
// Per-slug scout state. `trailers` is git truth and `stages` is the ledger's claim; the reconciler
// trusts a commit-bearing ledger entry ONLY when git confirms it with an ACFW-Stage trailer, so the
// two must move together or the mock is lying about the world.
const scoutState = {}
let fastThrewOnce = false
const workflow = async (ref, wargs) => {
  workflowCalls.push({ scriptPath: ref && ref.scriptPath, stem: wargs.stem, round: wargs.round, priorStages: wargs.priorStages })
  const stem = wargs.stem
  if (stem === 'fast' && !fastThrewOnce) {
    // Real work LANDED before the throw — committed, with its trailer. The amended run must not redo it.
    fastThrewOnce = true
    scoutState.sf = {
      stages: [
        { name: 'implement', status: 'ok', commit: true, resultJson: '{"transition":"completed","notes":"landed"}', payloadPath: '', payloadMissing: false },
        // A commit-bearing claim git CANNOT confirm (no trailer) must be dropped and re-run: trusting
        // it would skip work that never happened.
        { name: 'gate-fix#0', status: 'ok', commit: true, resultJson: '{"ok":true}', payloadPath: '', payloadMissing: false },
      ],
      trailers: ['implement'],
      commits: ['abc1234 implement the thing'],
    }
    throw new TypeError("Cannot read properties of undefined (reading 'passed')")
  }
  if (stem === 'slow') {
    events.push({ tick: tick++, kind: 'slow-specialist-start' })
    await slowGate
    slowSpecialistDone = true
    events.push({ tick: tick++, kind: 'slow-specialist-return' })
  } else {
    events.push({ tick: tick++, kind: 'fast-specialist-return' })
  }
  return { ok: true, transition: 'completed', commitSha: 'deadbeef', rejectionIncrement: 0, faultClass: 'quality', notes: 'done', deliverableFiles: [], stagesRan: ['implement'], stagesReplayed: Object.keys(wargs.priorStages || {}), agentsUsed: 4 }
}

async function agent(prompt, opts) {
  const label = (opts && opts.label) || ''
  // bootstrap
  // cpuCores/agents/scaffoldOk are LOAD-BEARING for 3.2.0: an empty agent registry or a failed
  // scaffold probe disables escalation, and this test would then pass VACUOUSLY by exercising the
  // 3.1.0 path while every escalation assertion below silently checked nothing.
  if (/Bootstrap the acf-whip/.test(prompt)) return { detached: false, doctorOk: true, doctorSummary: 'SUMMARY|ok=true', fatals: [], cpuCores: 8, agents: ['go-engineer', 'quality-reviewer'], scaffoldOk: true }
  // scout (3.2.0) — round 0 sees an empty worktree and no ledger
  if (/Read-only reconnaissance/.test(prompt)) {
    const slug = (prompt.match(/branch refs\/heads\/worktree\/(\w+)/) || [])[1] || ''
    const st = scoutState[slug] || { stages: [], trailers: [], commits: [] }
    return { worktree: `/r/.worktree/${slug}`, worktreeExists: true, commits: st.commits, stageTrailers: st.trailers, dirty: [], stashes: [], stages: st.stages, note: '' }
  }
  // workflow-architect (3.2.0)
  if (/WORKFLOW ARCHITECT/.test(prompt)) {
    architectCalls.push({ label, amend: /THIS IS AN AMEND/.test(prompt), prompt })
    return { wrote: true, scriptPath: '/r/.acfwhip/run/child/x/a0-b0/impl/harness.workflow.js', planKeys: ['implement'], preservedStages: [], maxAgents: 5, shallow: true, summary: 'default shape fits', refuse: 'none', needsTask: '' }
  }
  // pre-flight validator (3.2.0)
  if (/acfw-child-validate/.test(prompt)) {
    validateCalls.push(label)
    return { ok: true, parser: 'node', errors: [], warnings: [], stageCount: 5, mutatingStages: 3 }
  }
  // scan / drain scan (verbatim digest echo)
  if (/acfw-store' snapshot/.test(prompt)) return { snapshotJson: JSON.stringify(buildSnapshot()), doctorOk: true, doctorSummary: 'SUMMARY|ok=true', doctorFatals: [] }
  // single writer
  if (/SINGLE backlog writer/.test(prompt)) {
    if (writerActive > 0) writerOverlap = true
    writerActive++
    await Promise.resolve() // yield so any concurrent writer would be observed as overlap
    const r = applyWriter(prompt)
    writerActive--
    events.push({ tick: tick++, kind: 'write', m: r.applied.join(';') })
    return r
  }
  // integrator
  if (/integrator for one accepted task/.test(prompt)) {
    const stem = prompt.replace(/^[\s\S]*\/accepted\/([^/']+)\.md[\s\S]*$/, '$1')
    const t = model.get(stem)
    if (t) t.hasIntegratedAt = true
    events.push({ tick: tick++, kind: 'integrate', stem })
    if (stem === 'fast') resolveSlowGate() // <-- releases the slow specialist
    return { exitCode: 0, outcome: 'integrated', note: 'mock', resolverWorktree: '', resolverBranch: '', resolverAgent: '', resolverConflictedFiles: '', resolverConflictingCommits: '' }
  }
  // reviewer (code or non-code) -> accept
  if (/quality-reviewer reviewing/.test(prompt) || /reviewing one NON-CODE/.test(prompt)) {
    return { transition: 'accepted', commitSha: 'n/a', rejectionIncrement: 0, notes: 'lgtm' }
  }
  // specialist executing
  if (/specialist executing one acf-whip/.test(prompt)) {
    const isSlow = label.includes('ss') || /\/slow\.md/.test(prompt)
    if (isSlow) {
      events.push({ tick: tick++, kind: 'slow-specialist-start' })
      await slowGate // gated: only returns after fast integrated
      slowSpecialistDone = true
      events.push({ tick: tick++, kind: 'slow-specialist-return' })
    } else {
      events.push({ tick: tick++, kind: 'fast-specialist-return' })
    }
    return { transition: 'completed', commitSha: 'deadbeef', rejectionIncrement: 0, notes: 'done' }
  }
  // direct (non-code)
  if (/agent executing one NON-CODE/.test(prompt)) return { transition: 'completed', commitSha: 'n/a', rejectionIncrement: 0, notes: 'done' }
  throw new Error('unmocked agent prompt: ' + prompt.slice(0, 80))
}

// ---- load + run the workflow body ----
let body = readFileSync(SRC, 'utf8').replace(/^export const meta/m, 'const meta')
const run = new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow',
  `return (async () => {\n${body}\n})()`)

const args = { pluginRoot: '/p', trunkRoot: '/r', trunkBranch: 'trunk', mode: 'default' }

const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('TIMEOUT — likely a barrier deadlock (BUG-3 regression)')), 20000))

// `budget` stays undefined, matching the runtime when no token target is set: any budget.* access in
// the workflow body must be typeof-guarded or this throws.
let report
try {
  report = await Promise.race([run(agent, parallel, pipeline, phase, log, args, undefined, workflow), timeout])
} catch (e) {
  bad(`workflow did not converge: ${e.message}`)
  console.log(`\nphase5-streaming: ${PASS} passed, ${FAIL} failed`)
  process.exit(1)
}

// ---- assertions ----
const idx = (pred) => events.findIndex(pred)
const iFastIntegrate = idx((e) => e.kind === 'integrate' && e.stem === 'fast')
const iSlowStart = idx((e) => e.kind === 'slow-specialist-start')
const iSlowReturn = idx((e) => e.kind === 'slow-specialist-return')

// FIRST, before anything else: if escalation quietly disabled itself, every assertion below would be
// checking the 3.1.0 path and passing for the wrong reason.
check('escalation was ENABLED (not silently disabled — the vacuous-pass guard)', !!report && report.escalation && report.escalation.enabled === true)
check('every dispatched unit ran as a nested child workflow', workflowCalls.length >= 2)
check('an architect authored each harness', architectCalls.length >= 2)
check('each harness passed pre-flight before it ran', validateCalls.length >= 2)
check('the report distinguishes authored units from fallbacks', report.escalation.authored >= 2)

// The throw-repair loop, end to end.
const fastRuns = workflowCalls.filter((c) => c.stem === 'fast')
check('a harness that threw was re-run after an amend', fastRuns.length === 2)
check('the amend architect was told it was an amend', architectCalls.some((c) => c.amend))
check('the amended run received the pre-throw stage as ALREADY DONE (progress not lost)',
  fastRuns.length === 2 && fastRuns[1].priorStages && fastRuns[1].priorStages.implement !== undefined)
check('the replayed stage carries its RECORDED value, not null',
  fastRuns.length === 2 && fastRuns[1].priorStages.implement && fastRuns[1].priorStages.implement.result
  && fastRuns[1].priorStages.implement.result.transition === 'completed')
check('a commit-bearing stage git could NOT confirm is dropped, so it re-runs rather than being skipped',
  fastRuns.length === 2 && fastRuns[1].priorStages['gate-fix#0'] === undefined)
check('the amend was counted', report.escalation.amended >= 1)
check('the agent ledger advanced (the CLOSE rung has something to read)', report.agentsUsed > 0)

check('run converged (no barrier deadlock)', !!report)
check('run reported complete', report && report.completed === true && report.stopReason === 'complete')
check('fast task was integrated', iFastIntegrate >= 0)
check('slow specialist had started before fast integrated (same wave)', iSlowStart >= 0 && iSlowStart < iFastIntegrate)
check('fast integrated BEFORE the slow specialist returned (streaming, not barrier)', iFastIntegrate >= 0 && iFastIntegrate < iSlowReturn)
check('slow specialist eventually returned and was integrated', slowSpecialistDone && model.get('slow').hasIntegratedAt === true)
check('both tasks integrated', model.get('fast').hasIntegratedAt && model.get('slow').hasIntegratedAt)
check('single-writer invariant held (no overlapping writer calls)', writerOverlap === false)
check('report lists both integrations', report && report.integrated && report.integrated.includes('fast') && report.integrated.includes('slow'))

console.log(`\nphase5-streaming: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL === 0 ? 0 : 1)
