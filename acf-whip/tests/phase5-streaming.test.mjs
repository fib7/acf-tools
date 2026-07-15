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

async function agent(prompt, opts) {
  const label = (opts && opts.label) || ''
  // bootstrap
  if (/Bootstrap the acf-whip/.test(prompt)) return { detached: false, doctorOk: true, doctorSummary: 'SUMMARY|ok=true', fatals: [] }
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

const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('TIMEOUT — likely a barrier deadlock (BUG-3 regression)')), 8000))

let report
try {
  report = await Promise.race([run(agent, parallel, pipeline, phase, log, args, undefined, undefined), timeout])
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
