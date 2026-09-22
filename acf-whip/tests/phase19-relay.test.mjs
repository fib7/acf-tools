// phase19-relay.test.mjs — the snapshot relay, end to end through the REAL workflow body (3.4.0).
//
// THE FAILURE THIS REPRODUCES. The snapshot is produced by a script but delivered by an agent: a
// shell-runner reads the store walk's stdout with its Bash tool and copies it into one schema string.
// On a large board that echo silently came back SHORT — valid JSON, fewer tasks — and nothing checked.
// The scheduler then planned over a board that did not exist, could not find the ids it had been
// given, and stopped with "/go was scoped to tasks that do not exist in the backlog: ..." naming
// tasks that were all present. An operator reading that goes looking for a typo they did not make.
//
// The fix is two-sided and both sides are exercised here: the producer states what it emitted
// (relay header) and the consumer refuses a payload that does not match; and a scoped run narrows the
// payload in the STORE (--only) so the hop carries O(scope) records instead of the whole board.
//
// Run: node acf-whip/tests/phase19-relay.test.mjs

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const SRC = join(HERE, '..', 'workflows', 'whip-go.workflow.js')
const BODY = readFileSync(SRC, 'utf8').replace(/^export const meta/m, 'const meta')

let PASS = 0, FAIL = 0
const ok = (m) => { PASS++; console.log(`  PASS: ${m}`) }
const bad = (m) => { FAIL++; console.log(`  FAIL: ${m}`) }
const check = (m, cond) => (cond ? ok(m) : bad(m))

const utf8len = (s) => encodeURIComponent(String(s == null ? '' : s)).replace(/%[0-9A-F]{2}/gi, 'x').length

// Build the relay header the producers emit. `over` lets a test lie about it the way a model would.
function withRelay(snap, over) {
  const arrs = [snap.tasks || [], snap.inactive || [], snap.satisfiedDeps || []]
  const relay = {
    n: arrs.reduce((a, x) => a + x.length, 0),
    tasks: arrs[0].length, inactive: arrs[1].length, sat: arrs[2].length,
    bytes: arrs.reduce((a, x) => a + x.reduce((b, e) => b + utf8len(e && e.stem), 0), 0),
  }
  return Object.assign({ relay: Object.assign(relay, over || {}) }, snap)
}

// ---------------------------------------------------------------------------------------------
// Driver: the real workflow body with mocked globals. `onScan` sees each snapshot prompt and may
// return a DIFFERENT payload than the board actually holds — which is exactly the relay failure.
// ---------------------------------------------------------------------------------------------
async function runGo(cfg) {
  const c = Object.assign({
    tasks: [{ stem: 't1', slug: 's1' }],
    inactive: [],
    goArgs: {},
    bootFatals: [],
    bootDoctorOk: true,
    scopeMeta: null,          // () => ({resolved, unresolved, ambiguous, inactiveSeeds}) per scan
    onScan: null,             // (n, snap) => snapshot object to actually relay
    doctorPerScan: null,      // (n) => {doctorOk, doctorSummary, doctorFatals}
    onWorkflow: () => ({ ok: true, transition: 'completed', commitSha: 'abc', rejectionIncrement: 0, notes: 'done', deliverableFiles: [], stagesRan: [], stagesReplayed: [], agentsUsed: 4 }),
  }, cfg)

  const model = new Map(c.tasks.map((t) => [t.stem, Object.assign({
    stem: t.stem, id: t.stem, folder: 'pending', slug: t.slug, deps: [], hasIntegratedAt: false,
    hasWorktreeBranch: true, hasCleanCheckoutToken: true, rejectionCount: 0, blockCount: 0,
    ageHours: -1, priority: 'medium', agent: 'go-engineer',
  }, t)]))
  const isTerm = (t) => t.folder === 'blocked' || (t.folder === 'accepted' && (t.hasIntegratedAt || t.slug === 'none' || !t.hasWorktreeBranch))
  const baseSnapshot = () => {
    const tasks = [...model.values()].map((t) => ({ ...t }))
    const cnt = { pending: 0, 'in-progress': 0, completed: 0, 'in-review': 0, blocked: 0, rejected: 0, accepted: 0 }
    for (const t of tasks) if (cnt[t.folder] != null) cnt[t.folder]++
    const snap = {
      trunkRoot: '/r', inProgressTimeoutHours: 8, tasks, inactive: c.inactive.map((x) => ({ ...x })), satisfiedDeps: [],
      counts: {
        ...cnt, total: tasks.length, integrated: tasks.filter((t) => t.hasIntegratedAt).length,
        runtimeTerminalDefault: tasks.filter(isTerm).length,
        runtimeTerminalOverride: tasks.filter((t) => t.folder === 'accepted' || t.folder === 'blocked').length,
      },
    }
    if (c.scopeMeta) {
      const sm = c.scopeMeta(scanN, snap)
      if (sm) snap.scope = Object.assign({ seeds: [], resolved: {}, unresolved: [], ambiguous: [], inactiveSeeds: [], added: [] }, sm)
      if (sm) snap.scopeApplied = true
    }
    return snap
  }

  const calls = { scan: [], writer: [], legacy: [], review: [], integrate: [], unlock: [], drainScan: [] }
  let scanN = 0
  const logs = []
  const log = (m) => logs.push(String(m))
  const phase = () => {}
  const parallel = (thunks) => Promise.all(thunks.map((f) => Promise.resolve().then(f).catch(() => null)))
  const pipeline = async () => { throw new Error('pipeline not expected') }
  const workflow = async (ref, wargs) => c.onWorkflow(wargs)

  const agent = async (prompt, opts) => {
    const label = (opts && opts.label) || ''
    if (/Bootstrap the acf-whip/.test(prompt)) {
      return { detached: false, lockFresh: false, doctorOk: c.bootDoctorOk, doctorSummary: `SUMMARY|fatal=${c.bootFatals.length}|repairable=0|warn=0|ok=${c.bootDoctorOk}`, fatals: c.bootFatals, cpuCores: 8, agents: ['go-engineer', 'quality-reviewer'], scaffoldOk: true }
    }
    if (/acfw-store' snapshot/.test(prompt)) {
      const isDrain = /integration drain/.test(prompt)
      scanN++
      const real = baseSnapshot()
      const relayed = c.onScan ? c.onScan(scanN, real, prompt) : real
      ;(isDrain ? calls.drainScan : calls.scan).push({ n: scanN, prompt, label })
      const doc = c.doctorPerScan ? c.doctorPerScan(scanN) : null
      return {
        snapshotJson: JSON.stringify(relayed),
        doctorOk: doc ? doc.doctorOk : true,
        doctorSummary: doc ? doc.doctorSummary : 'SUMMARY|fatal=0|repairable=0|warn=0|ok=true',
        doctorFatals: doc ? doc.doctorFatals : [],
      }
    }
    if (/SINGLE backlog writer/.test(prompt)) {
      const re = /bash '[^']*acfw-store' transition '([^']*)' '([^']*)' '([^']*)' '([^']*)' '([^']*)' '([^']*)'/g
      let m
      while ((m = re.exec(prompt)) !== null) {
        const [, stem, toState] = m
        calls.writer.push({ stem, toState })
        const t = model.get(stem); if (t) t.folder = toState
      }
      return { applied: ['ok'], note: 'mock' }
    }
    if (/integrator for one accepted task/.test(prompt)) {
      const stem = prompt.replace(/^[\s\S]*\/accepted\/([^/']+)\.md[\s\S]*$/, '$1')
      calls.integrate.push(stem)
      const t = model.get(stem); if (t) t.hasIntegratedAt = true
      return { exitCode: 0, outcome: 'integrated', note: '', resolverWorktree: '', resolverBranch: '', resolverAgent: '', resolverConflictedFiles: '', resolverConflictingCommits: '' }
    }
    if (/quality-reviewer reviewing/.test(prompt) || /reviewing one NON-CODE/.test(prompt)) {
      calls.review.push(label)
      return { transition: 'accepted', commitSha: 'n/a', rejectionIncrement: 0, notes: 'lgtm' }
    }
    if (/specialist executing one acf-whip/.test(prompt) || /agent executing one NON-CODE/.test(prompt)) {
      calls.legacy.push(label)
      return { transition: 'completed', commitSha: 'deadbeef', rejectionIncrement: 0, notes: 'legacy' }
    }
    if (/rm -f/.test(prompt)) { calls.unlock.push(label); return 'unlocked' }
    if (/Read-only reconnaissance/.test(prompt)) return { worktree: '', worktreeExists: false, commits: [], stageTrailers: [], dirty: [], stashes: [], stages: [], note: '' }
    if (/Preserve in-flight work/.test(prompt)) return { porcelain: '' }
    throw new Error('unmocked prompt: ' + String(prompt).slice(0, 90))
  }

  const fn = new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow',
    `return (async () => {\n${BODY}\n})()`)
  const goArgs = Object.assign({ pluginRoot: '/p', trunkRoot: '/r', trunkBranch: 'trunk', mode: 'default', escalate: false }, c.goArgs)
  const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('TIMEOUT — deadlock')), 25000))
  const report = await Promise.race([fn(agent, parallel, pipeline, phase, log, goArgs, undefined, workflow), timeout])
  return { report, calls, logs, model }
}

const FIVE = ['t1', 't2', 't3', 't4', 't5'].map((s, i) => ({ stem: s, slug: `s${i + 1}` }))

// ============================ 1. THE reported failure, reproduced ============================
// The scan echoes 2 of 5 tasks but keeps the header it was given. Without the relay check this is
// indistinguishable from a 2-task board, and a run scoped to all five reports three as nonexistent.
{
  const r = await runGo({
    tasks: FIVE,
    goArgs: { only: ['t1', 't2', 't3', 't4', 't5'] },
    scopeMeta: () => ({ resolved: { t1: 't1', t2: 't2', t3: 't3', t4: 't4', t5: 't5' } }),
    onScan: (n, snap) => withRelay(Object.assign({}, snap, { tasks: snap.tasks.slice(0, 2) }), { n: 5, tasks: 5, bytes: 10 }),
  })
  check('1a a short relay does NOT report the missing ids as nonexistent',
    r.report.stopReason !== 'scope-unresolved')
  check('1b it is reported as a relay failure instead', r.report.stopReason === 'relay-truncated')
  check('1c nothing was dispatched on the partial view', r.calls.legacy.length === 0)
  check('1d the run says the board was fine and the HOP was short',
    /relayed intact|could not be relayed/.test(r.report.note || ''))
  check('1e ...and names the two remedies that actually shrink the payload',
    /\/go <ids>|scope/i.test(r.report.note || '') && /shellModel/.test(r.report.note || ''))
  check('1f the operator is never told to "check the ids"', !/check the ids/.test(r.report.note || ''))
  check('1g it retried before giving up', r.calls.scan.length >= 2)
  check('1h the failure is recorded with expected vs got', r.report.relay.failures.length > 0 && r.report.relay.failures[0].expected === 5)
  check('1i relay.verified is false', r.report.relay.verified === false)
}

// ============================ 2. a transient short echo recovers ============================
{
  const r = await runGo({
    tasks: FIVE,
    onScan: (n, snap) => (n === 1
      ? withRelay(Object.assign({}, snap, { tasks: snap.tasks.slice(0, 2) }), { n: 5, tasks: 5, bytes: 10 })
      : withRelay(snap)),
  })
  check('2a a single bad echo does not derail the run', r.report.stopReason === 'complete')
  check('2b ...and the retry is what recovered it', r.calls.scan.length >= 2)
  check('2c every task still ran', r.calls.legacy.length === 5)
}

// ============================ 3. a FORGED header is still caught ============================
// A model that shortens tasks[] may also "tidy" the count it can see. The byte sum is a second,
// content-derived number it would have to recompute deliberately to stay consistent.
{
  const r = await runGo({
    tasks: FIVE,
    onScan: (n, snap) => {
      const cut = Object.assign({}, snap, { tasks: snap.tasks.slice(0, 2) })
      return withRelay(cut, { n: 2, tasks: 2, inactive: 0, sat: 0, bytes: 10 }) // count matches, bytes do not
    },
  })
  check('3a a self-consistent COUNT does not buy past the checksum', r.report.stopReason === 'relay-truncated')
  check('3b nothing was dispatched', r.calls.legacy.length === 0)
}

// ============================ 4. --only reaches EVERY relay site ============================
{
  const r = await runGo({
    tasks: FIVE,
    goArgs: { only: ['t1'] },
    scopeMeta: () => ({ resolved: { t1: 't1' } }),
    onScan: (n, snap) => withRelay(Object.assign({}, snap, { tasks: snap.tasks.filter((t) => t.stem === 't1') })),
  })
  check('4a the loop scan carries --only', r.calls.scan.every((s) => /--only 't1'/.test(s.prompt)))
  check('4b the drain scan carries it too (it is the third, easily-missed relay site)',
    r.calls.drainScan.length === 0 || r.calls.drainScan.every((s) => /--only 't1'/.test(s.prompt)))
  check('4c the scan also tees the FULL snapshot for the doctor', r.calls.scan.every((s) => /--full-to/.test(s.prompt)))
  check('4d ...and points the doctor at that file, so both read ONE store walk',
    r.calls.scan.every((s) => /doctor --quiet --active-only --snapshot/.test(s.prompt)))
  check('4e only the scoped task ran', r.calls.legacy.length === 1)
  check('4f the run completes over its own scope', r.report.stopReason === 'complete')
  check('4g ...and says "Scope", never "Backlog"', /Scope 100%/.test(r.report.note || ''))
}

// ============================ 5. resolved-but-absent is a relay failure ======================
// The store resolved the seed, so the id EXISTS. If the relayed payload lacks it, that is the hop
// losing data — the one case where calling it a bad id is a lie the operator cannot see through.
{
  const r = await runGo({
    tasks: FIVE,
    goArgs: { only: ['t3'] },
    scopeMeta: () => ({ resolved: { t3: 't3' } }),
    onScan: (n, snap) => withRelay(Object.assign({}, snap, { tasks: snap.tasks.filter((t) => t.stem !== 't3') })),
  })
  check('5a a resolved-but-absent stem is a relay failure', r.report.stopReason === 'relay-truncated')
  check('5b ...explicitly NOT a missing id', /NOT missing from the backlog/.test(r.report.reason || ''))
  check('5c nothing was dispatched', r.calls.legacy.length === 0)
  check('5d the lock is released (nothing ran, so nothing needs protecting)', r.calls.unlock.length === 1)
}

// ============================ 6. a genuinely unknown id still refuses =======================
{
  const r = await runGo({
    tasks: FIVE,
    goArgs: { only: ['zz'] },
    scopeMeta: () => ({ resolved: {}, unresolved: ['zz'] }),
    onScan: (n, snap) => withRelay(snap),
  })
  check('6a an id the STORE could not resolve is refused', r.report.stopReason === 'scope-unresolved')
  check('6b ...naming it', /zz/.test(r.report.reason || ''))
  check('6c nothing was dispatched', r.calls.legacy.length === 0)
  check('6d the lock is released so the operator can retry immediately', r.calls.unlock.length === 1)
}

// ============================ 7. an AMBIGUOUS prefix is never guessed ======================
{
  const r = await runGo({
    tasks: FIVE,
    goArgs: { only: ['t'] },
    scopeMeta: () => ({ resolved: {}, ambiguous: [{ tok: 't', candidates: ['t1', 't2'] }] }),
    onScan: (n, snap) => withRelay(snap),
  })
  check('7a an ambiguous prefix refuses rather than picking one', r.report.stopReason === 'scope-unresolved')
  check('7b ...and names the candidates', /t1/.test(r.report.reason || '') && /t2/.test(r.report.reason || ''))
  check('7c nothing was dispatched', r.calls.legacy.length === 0)
}

// ============================ 8. a card that VANISHES mid-run does not kill the run =========
// On a shared board someone else can retire a card under a running orchestrator. At iteration 1 an
// unknown id is a refusal; later it is a held-out task and the rest of the scope finishes.
{
  const r = await runGo({
    tasks: [{ stem: 't1', slug: 's1' }, { stem: 't2', slug: 's2' }],
    goArgs: { only: ['t1', 't2'] },
    scopeMeta: (n) => (n === 1
      ? { resolved: { t1: 't1', t2: 't2' } }
      : { resolved: { t1: 't1' }, unresolved: ['t2'] }),
    onScan: (n, snap) => withRelay(n === 1 ? snap : Object.assign({}, snap, { tasks: snap.tasks.filter((t) => t.stem !== 't2') })),
  })
  check('8a a card vanishing after iteration 1 does not abort the run', r.report.stopReason !== 'scope-unresolved')
  check('8b the run reaches a terminal state', ['complete', 'partial', 'no-progress'].includes(r.report.stopReason))
  check('8c the vanished task is reported, never silently dropped',
    (r.report.heldOut || []).some((h) => h.stem === 't2' && h.why === 'vanished'))
  check('8d the surviving task still ran', r.calls.legacy.some((l) => /t1/.test(l)) || r.model.get('t1').folder !== 'pending')
}

// ============================ 9. the noGain denominator trap ================================
// On a scoped run a finished task COLLAPSES out of the next working set, so `terminal` stays flat
// while `total` shrinks. Counting only "terminal went up" reads that as no progress, and a chain of
// same-slug tasks exhausts NO_GAIN_LIMIT (15) and exits 'no-progress' with the work actually done.
{
  const N = 17
  const many = Array.from({ length: N }, (_, i) => ({ stem: `c${i + 1}`, slug: 'shared' })) // ONE slug: one task per iteration
  const done = new Set()
  const r = await runGo({
    tasks: many,
    goArgs: { only: many.map((t) => t.stem) },
    scopeMeta: () => ({ resolved: Object.fromEntries(many.map((t) => [t.stem, t.stem])) }),
    onScan: (n, snap) => {
      // Model the real collapse: an accepted+integrated task leaves tasks[] next scan. It does NOT
      // vanish from the payload — `--only` RETAINS every resolved seed (that retention is exactly
      // what stops `/go <a-finished-task>` reporting the id as nonexistent), so it reappears as a
      // compact satisfiedDeps entry. Modelling the drop without the retention would test a producer
      // that does not exist.
      for (const t of snap.tasks) if (t.folder === 'accepted' && t.hasIntegratedAt) done.add(t.stem)
      const kept = snap.tasks.filter((t) => !done.has(t.stem))
      const sat = [...done].map((stem) => ({ stem, id: stem }))
      const counts = Object.assign({}, snap.counts, { total: kept.length })
      return withRelay(Object.assign({}, snap, { tasks: kept, satisfiedDeps: sat, counts }))
    },
  })
  check(`9a ${N} same-slug scoped tasks complete instead of exhausting the no-gain budget`,
    r.report.stopReason === 'complete')
  check('9b ...and every one of them actually ran', done.size === N)
  check('9c the run needed more iterations than the no-gain ceiling, which is the point',
    r.report.iterations > 15)
}

// ============================ 10. a store with no relay header still works ==================
// Third-party `snapshot-enriched` adapters predate this contract; the header is SHOULD, not MUST.
// Refusing them would brick every such backend on upgrade — a worse failure than the one prevented.
{
  const r = await runGo({ tasks: FIVE, onScan: (n, snap) => snap })
  check('10a a snapshot with no relay header is accepted', r.report.stopReason === 'complete')
  check('10b ...with the limitation stated once, not every iteration',
    r.logs.filter((l) => /completeness cannot be verified/.test(l)).length <= 1)
  check('10c every task ran', r.calls.legacy.length === 5)
}

console.log(`\nphase19-relay: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL ? 1 : 0)
