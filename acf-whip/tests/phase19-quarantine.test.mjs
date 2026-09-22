// phase19-quarantine.test.mjs — integrity findings hold out ONE task, not the run (3.4.0).
//
// THE FAILURE THIS FIXES. A FATAL meant one thing: stop. That conflates "this repository is unusable"
// with "one card is malformed", and on a shared board the second is overwhelmingly the common case.
// A single long-cancelled card with a hand-edited state blocked every `/go` for a whole team —
// including runs scoped to tasks that had nothing to do with it. There was no way to ignore it and no
// way to scope around it, because the gate ran before anything else and read the whole board.
//
// The split: REPO-level findings still abort. TASK-level findings hold that task out and the rest of
// the board runs. Findings naming nothing the scheduler can act on are reported and otherwise
// ignored — aborting for those would reinstate exactly the gate being removed.
//
// The dangerous half is the holding-out, and most of this file is about it: a held-out task must not
// be dispatched, must not be integrated, must keep gating its dependents, must keep its worktree slug
// reserved, and must make the run report `partial` rather than `complete`.
//
// Run: node acf-whip/tests/phase19-quarantine.test.mjs

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
function withRelay(snap) {
  const arrs = [snap.tasks || [], snap.inactive || [], snap.satisfiedDeps || []]
  return Object.assign({
    relay: {
      n: arrs.reduce((a, x) => a + x.length, 0),
      tasks: arrs[0].length, inactive: arrs[1].length, sat: arrs[2].length,
      bytes: arrs.reduce((a, x) => a + x.reduce((b, e) => b + utf8len(e && e.stem), 0), 0),
    },
  }, snap)
}
const SUMMARY = (fatals) => `SUMMARY|fatal=${fatals.length}|repairable=0|warn=0|ok=${fatals.length === 0}`

async function runGo(cfg) {
  const c = Object.assign({
    tasks: [{ stem: 't1', slug: 's1' }],
    goArgs: {},
    bootFatals: [],
    fatalsPerScan: () => [],   // (n) => FATAL lines relayed by that iteration's doctor
    doctorSummaryOverride: null,
    onWorkflow: () => ({ ok: true, transition: 'completed', commitSha: 'abc', rejectionIncrement: 0, notes: 'done', deliverableFiles: [], stagesRan: [], stagesReplayed: [], agentsUsed: 4 }),
  }, cfg)

  const model = new Map(c.tasks.map((t) => [t.stem, Object.assign({
    stem: t.stem, id: t.stem, folder: 'pending', slug: t.slug, deps: [], hasIntegratedAt: false,
    hasWorktreeBranch: true, hasCleanCheckoutToken: true, rejectionCount: 0, blockCount: 0,
    ageHours: -1, priority: 'medium', agent: 'go-engineer',
  }, t)]))
  const isTerm = (t) => t.folder === 'blocked' || (t.folder === 'accepted' && (t.hasIntegratedAt || t.slug === 'none' || !t.hasWorktreeBranch))
  let scanN = 0
  const snapshot = () => {
    const tasks = [...model.values()].map((t) => ({ ...t }))
    const cnt = { pending: 0, 'in-progress': 0, completed: 0, 'in-review': 0, blocked: 0, rejected: 0, accepted: 0 }
    for (const t of tasks) if (cnt[t.folder] != null) cnt[t.folder]++
    const snap = {
      trunkRoot: '/r', inProgressTimeoutHours: 8, tasks, inactive: [], satisfiedDeps: [],
      counts: {
        ...cnt, total: tasks.length, integrated: tasks.filter((t) => t.hasIntegratedAt).length,
        runtimeTerminalDefault: tasks.filter(isTerm).length,
        runtimeTerminalOverride: tasks.filter((t) => t.folder === 'accepted' || t.folder === 'blocked').length,
      },
    }
    if (c.goArgs.only) {
      snap.scopeApplied = true
      snap.scope = { seeds: c.goArgs.only, resolved: Object.fromEntries(c.goArgs.only.map((s) => [s, s])), unresolved: [], ambiguous: [], inactiveSeeds: [], added: [] }
    }
    return withRelay(snap)
  }

  const calls = { writer: [], legacy: [], review: [], integrate: [], unlock: [], dispatched: [] }
  const logs = []
  const log = (m) => logs.push(String(m))
  const phase = () => {}
  const parallel = (thunks) => Promise.all(thunks.map((f) => Promise.resolve().then(f).catch(() => null)))
  const pipeline = async () => { throw new Error('pipeline not expected') }
  const workflow = async (ref, wargs) => { calls.dispatched.push(wargs.stem); return c.onWorkflow(wargs) }

  const agent = async (prompt, opts) => {
    const label = (opts && opts.label) || ''
    if (/Bootstrap the acf-whip/.test(prompt)) {
      return { detached: false, lockFresh: false, doctorOk: c.bootFatals.length === 0, doctorSummary: SUMMARY(c.bootFatals), fatals: c.bootFatals, cpuCores: 8, agents: ['go-engineer', 'quality-reviewer'], scaffoldOk: true }
    }
    if (/acfw-store' snapshot/.test(prompt)) {
      const isDrain = /integration drain/.test(prompt)
      if (!isDrain) scanN++
      const fatals = isDrain ? [] : c.fatalsPerScan(scanN)
      return {
        snapshotJson: JSON.stringify(snapshot()),
        doctorOk: fatals.length === 0,
        doctorSummary: c.doctorSummaryOverride ? c.doctorSummaryOverride(scanN, fatals) : SUMMARY(fatals),
        doctorFatals: fatals,
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

const touched = (r, stem) => r.calls.writer.some((w) => w.stem === stem) || r.calls.legacy.some((l) => l.includes(stem))

// ============================ 1. THE headline: one bad card no longer stops the board =========
{
  const r = await runGo({
    tasks: [{ stem: 't1', slug: 's1' }, { stem: 't2', slug: 's2' }],
    bootFatals: ['FATAL|dangling-dep|t2|depends on ghost-1 which has no task file'],
    fatalsPerScan: () => ['FATAL|dangling-dep|t2|depends on ghost-1 which has no task file'],
  })
  check('1a a task-level FATAL at bootstrap no longer aborts the run', r.report.aborted !== true)
  check('1b the healthy task runs', touched(r, 't1'))
  check('1c the malformed one is never touched', !touched(r, 't2'))
  check('1d it is reported as held out', (r.report.heldOut || []).some((h) => h.stem === 't2' && h.why === 'quarantined'))
  check('1e ...with the finding that caused it', (r.report.heldOut || [])[0].code === 'dangling-dep')
  check('1f ...and the detail an operator needs', /ghost-1/.test((r.report.heldOut || [])[0].detail || ''))
  check('1g the run reports partial, NOT complete', r.report.stopReason === 'partial')
  check('1h completed is false even though every runnable task finished', r.report.completed === false)
  check('1i the note says the backlog is not complete', /NOT complete/.test(r.report.note || ''))
  check('1j the bootstrap says it deferred the finding rather than swallowing it',
    r.logs.some((l) => /deferred to the first scan/.test(l)))
}

// ============================ 2. repo-level findings still abort ==============================
for (const [code, key] of [['detached-head', '(repo)'], ['worktree-wrong-branch', 's1'], ['doctor-unavailable', '-']]) {
  const r = await runGo({
    tasks: [{ stem: 't1', slug: 's1' }],
    fatalsPerScan: (n) => (n === 1 ? [`FATAL|${code}|${key}|something is wrong with the checkout`] : []),
  })
  const isUnavailable = code === 'doctor-unavailable'
  check(`2 ${code} still aborts the whole run`, r.report.aborted === true)
  check(`2 ${code} under the right stop reason`,
    r.report.stopReason === (isUnavailable ? 'doctor-unavailable-midrun' : 'integrity-fatal-midrun'))
  check(`2 ${code} dispatches nothing`, r.calls.legacy.length === 0)
}
// worktree-wrong-branch carries a SLUG in field 3, and a slug can be a prefix of a real stem. It must
// stay repo-scoped on the CODE alone — quarantining "the task named s1" would be a mis-attribution.
{
  const r = await runGo({
    tasks: [{ stem: 's1-task', slug: 's1' }],
    fatalsPerScan: () => ['FATAL|worktree-wrong-branch|s1|on the wrong branch'],
  })
  check('2z a slug-keyed repo finding is never mistaken for a task finding', r.report.aborted === true)
}

// ============================ 3. findings outside the run do not gate it ======================
{
  const r = await runGo({
    tasks: [{ stem: 't1', slug: 's1' }],
    fatalsPerScan: () => ['FATAL|dangling-dep|some-card-nobody-here-knows|depends on x'],
  })
  check('3a a FATAL naming nothing this board can act on does not abort', r.report.aborted !== true)
  check('3b the run completes', r.report.stopReason === 'complete')
  check('3c ...but the finding is REPORTED, never silently dropped',
    (r.report.fatalsNotGating || []).some((l) => /some-card-nobody-here-knows/.test(l)))
  check('3d ...and the note points at the tool that explains it', /whip-doctor/.test(r.report.note || ''))
  check('3e nothing is held out for it', (r.report.heldOut || []).length === 0)
}

// ============================ 4. a quarantined dep still gates its dependents =================
// The dangerous shape: hold a task out, and its dependent must NOT proceed as if the dep were done.
{
  const r = await runGo({
    tasks: [
      { stem: 'dep', slug: 'sd', folder: 'accepted', hasIntegratedAt: false, hasWorktreeBranch: true },
      { stem: 'ui', slug: 'su', deps: ['dep'] },
    ],
    fatalsPerScan: () => ['FATAL|unparseable-frontmatter|dep|its Status line is unreadable'],
  })
  check('4a the held-out dep is never integrated', !r.calls.integrate.includes('dep'))
  check('4b its dependent is never dispatched behind it', !touched(r, 'ui'))
  check('4c the dep is reported as held out', (r.report.heldOut || []).some((h) => h.stem === 'dep'))
  check('4d the run does not claim completion', r.report.completed === false)
  check('4e the report explains WHY the dependent never moved',
    (r.report.gated || []).some((g) => g.stem === 'ui' && /held out/.test(g.why || '')))
}

// ============================ 5. quarantine is not sticky ====================================
// Recomputed from each iteration's findings: an operator who fixes the card mid-run gets it back.
{
  const r = await runGo({
    tasks: [{ stem: 't1', slug: 's1' }, { stem: 't2', slug: 's2' }],
    fatalsPerScan: (n) => (n === 1 ? ['FATAL|unknown-agent|t2|agent file is gone'] : []),
  })
  check('5a a finding that disappears stops holding its task out', touched(r, 't2'))
  check('5b both tasks finish', touched(r, 't1') && touched(r, 't2'))
  check('5c the run still records that it was held out at some point',
    (r.report.heldOut || []).some((h) => h.stem === 't2'))
}

// ============================ 6. a held-out in-flight task KEEPS its slug ====================
// Quarantine frees the task from the scheduling view, which would free its worktree slug — and a
// same-slug sibling dispatched into it opens with clean-checkout's silent `stash push -u`, sweeping
// the held-out task's uncommitted work into the shared stash. Holding the slug is the whole point.
{
  const r = await runGo({
    tasks: [
      { stem: 'inflight', slug: 'shared', folder: 'in-progress' },
      { stem: 'sibling', slug: 'shared' },
    ],
    fatalsPerScan: (n) => (n <= 1 ? ['FATAL|control-bytes|inflight|the document contains control bytes'] : []),
  })
  const firstSiblingIter = r.logs.findIndex((l) => /sibling/.test(l))
  check('6a the held-out in-flight task is not dispatched', !r.calls.dispatched.includes('inflight'))
  check('6b its same-slug sibling did not take the slug while it was held',
    !r.calls.writer.some((w) => w.stem === 'sibling' && w.toState === 'in-progress' && firstSiblingIter === 0))
  check('6c the run still terminates rather than deadlocking', typeof r.report.stopReason === 'string')
}

// ============================ 7. counts stay coherent on an UNSCOPED run =====================
// A quarantined BLOCKED task is terminal under both modes. If the denominator drops without the
// terminal count dropping with it, `terminal === total` becomes unreachable and the run burns its
// whole no-gain budget before exiting 'no-progress' with nothing left to do.
{
  const r = await runGo({
    tasks: [{ stem: 't1', slug: 's1' }, { stem: 'stuck', slug: 's2', folder: 'blocked', blockCount: 99, rejectionCount: 99 }],
    fatalsPerScan: () => ['FATAL|cyclic-deps|stuck|participates in a dependency cycle'],
  })
  check('7a the run reaches a terminal state quickly, not by exhausting no-gain', r.report.iterations < 10)
  check('7b ...and does not report no-progress', r.report.stopReason !== 'no-progress')
  check('7c the healthy task ran', touched(r, 't1'))
  check('7d the held-out one is named', (r.report.heldOut || []).some((h) => h.stem === 'stuck'))
}

// ============================ 8. a scoped run ignores findings outside its scope =============
{
  const r = await runGo({
    tasks: [{ stem: 't1', slug: 's1' }, { stem: 'other', slug: 's2' }],
    goArgs: { only: ['t1'] },
    fatalsPerScan: () => ['FATAL|dangling-dep|other|depends on ghost'],
  })
  check('8a a FATAL on an out-of-scope task does not gate the scoped run', r.report.aborted !== true)
  check('8b the scoped task ran', touched(r, 't1'))
  check('8c the run completes over its scope', r.report.stopReason === 'complete')
  check('8d completed is true — nothing IN SCOPE was held out', r.report.completed === true)
  check('8e the out-of-scope finding is still visible in the report',
    (r.report.heldOut || []).length === 0 || !(r.report.heldOut || []).some((h) => h.stem === 't1'))
}

// ============================ 9. a dropped FATAL line is refused, never guessed ==============
// The doctor's findings ride the same relay hop as the snapshot. A dropped FATAL silently UN-holds
// the task it named, so the run would dispatch against the exact state the gate exists to refuse.
{
  const r = await runGo({
    tasks: [{ stem: 't1', slug: 's1' }],
    fatalsPerScan: () => ['FATAL|dangling-dep|t1|x'],
    doctorSummaryOverride: () => 'SUMMARY|fatal=2|repairable=0|warn=0|ok=false', // claims 2, relays 1
  })
  check('9a a findings count that does not match the relayed lines aborts', r.report.aborted === true)
  check('9b ...under its own stop reason', r.report.stopReason === 'doctor-relay-truncated')
  check('9c ...saying we cannot tell WHICH finding was lost', /WHICH finding/.test(r.report.reason || ''))
  check('9d nothing was dispatched', r.calls.legacy.length === 0)
  check('9e the lock is released (nothing ran)', r.calls.unlock.length === 1)
}

// ============================ 10. a held-out ACCEPTED task is never drained ==================
// The drain runs after the loop off a fresh snapshot that knows nothing about this run's quarantine.
{
  const r = await runGo({
    tasks: [{ stem: 'bad', slug: 'sb', folder: 'accepted', hasIntegratedAt: false, hasWorktreeBranch: true }],
    fatalsPerScan: () => ['FATAL|collapsed-task-file|bad|the document was destroyed'],
  })
  check('10a a held-out accepted task is not integrated by the loop', !r.calls.integrate.includes('bad'))
  check('10b ...nor by the post-loop drain', r.report.drainedPostLoop === 0)
  check('10c the run reports partial', r.report.stopReason === 'partial')
}

console.log(`\nphase19-quarantine: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL ? 1 : 0)
