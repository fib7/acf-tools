// phase2-scheduler.test.mjs — unit-tests the PURE scheduling/terminal logic of whip-go.workflow.js.
//
// The Workflow harness wraps the script body in an async function and provides agent()/parallel()/
// phase()/log() as globals, so the workflow file cannot be `import`ed directly. Instead this test
// extracts the `// <scheduler-pure> … // </scheduler-pure>` block (which is side-effect-free) from
// the real source, evals it with `mode` injected, and asserts on isTerminal / depsSatisfied /
// topoIntegrationOrder / planUnblockAndTimeout. This is the regression guard for the two transitions
// the 2.0.x migration dropped (blocked->pending unblock; in-progress->blocked timeout).
//
// Run: node acf-whip/tests/phase2-scheduler.test.mjs

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const SRC = join(HERE, '..', 'workflows', 'whip-go.workflow.js')

let PASS = 0, FAIL = 0
const ok = (m) => { PASS++; console.log(`  PASS: ${m}`) }
const bad = (m) => { FAIL++; console.log(`  FAIL: ${m}`) }
const check = (m, cond) => (cond ? ok(m) : bad(m))

// ---- extract the pure block ----
const text = readFileSync(SRC, 'utf8')
const start = text.indexOf('// <scheduler-pure>')
const end = text.indexOf('// </scheduler-pure>')
if (start < 0 || end < 0 || end < start) {
  console.error('FATAL: could not find <scheduler-pure> markers in whip-go.workflow.js')
  process.exit(1)
}
const block = text.slice(start, end)

// Build a factory that closes over an injected `mode` and returns the functions.
function load(mode) {
  // eslint-disable-next-line no-new-func
  const factory = new Function('mode', `${block}\nreturn { indexTasks, isTerminal, depsSatisfied, topoIntegrationOrder, planUnblockAndTimeout, resultToState, reconcileIntegrationTallies, byPriorityThenStem, MAX_REJECT_RETRY, MAX_BLOCK_RETRY, DEFAULT_TIMEOUT_H };`)
  return factory(mode)
}
const Sdef = load('default')
const Sovr = load('override')

// sanity: constants came from the source, not duplicated here
check('MAX_REJECT_RETRY extracted from source (=3)', Sdef.MAX_REJECT_RETRY === 3)
check('MAX_BLOCK_RETRY extracted from source (=3)', Sdef.MAX_BLOCK_RETRY === 3)
check('DEFAULT_TIMEOUT_H extracted from source (=8)', Sdef.DEFAULT_TIMEOUT_H === 8)

// ---- task factory ----
const T = (o) => ({
  stem: o.stem, id: o.id ?? o.stem, folder: o.folder, slug: o.slug ?? 'none',
  deps: o.deps ?? [], hasIntegratedAt: !!o.hasIntegratedAt, hasWorktreeBranch: !!o.hasWorktreeBranch,
  rejectionCount: o.rejectionCount ?? 0, blockCount: o.blockCount ?? 0, ageHours: o.ageHours ?? -1, priority: o.priority ?? 'medium',
})

// ============================ isTerminal ============================
{
  const { isTerminal } = Sdef
  check('blocked is terminal (default)', isTerminal(T({ stem: 'b', folder: 'blocked' }), 'default') === true)
  check('blocked is terminal (override)', Sovr.isTerminal(T({ stem: 'b', folder: 'blocked' }), 'override') === true)
  check('pending is not terminal', isTerminal(T({ stem: 'p', folder: 'pending', slug: 's' })) === false)
  check('accepted+Integrated-At is terminal (default)', isTerminal(T({ stem: 'a', folder: 'accepted', slug: 's', hasIntegratedAt: true, hasWorktreeBranch: true })) === true)
  check('accepted+none-slug is terminal (default)', isTerminal(T({ stem: 'a', folder: 'accepted', slug: 'none' })) === true)
  check('accepted+no-branch is terminal (default, historical)', isTerminal(T({ stem: 'a', folder: 'accepted', slug: 's', hasWorktreeBranch: false })) === true)
  check('accepted+branch+unintegrated is NOT terminal (default)', isTerminal(T({ stem: 'a', folder: 'accepted', slug: 's', hasWorktreeBranch: true, hasIntegratedAt: false })) === false)
  check('accepted+branch+unintegrated IS terminal (override)', Sovr.isTerminal(T({ stem: 'a', folder: 'accepted', slug: 's', hasWorktreeBranch: true, hasIntegratedAt: false }), 'override') === true)
}

// ============================ depsSatisfied (default mode) ============================
{
  const { indexTasks, depsSatisfied } = Sdef
  const A_int = T({ stem: 'a', folder: 'accepted', slug: 'sa', hasIntegratedAt: true, hasWorktreeBranch: true })
  const A_live = T({ stem: 'a', folder: 'accepted', slug: 'sa', hasIntegratedAt: false, hasWorktreeBranch: true }) // pending integration
  const A_none = T({ stem: 'a', folder: 'accepted', slug: 'none' })
  const A_blocked = T({ stem: 'a', folder: 'blocked', slug: 'sa' })

  const mk = (dep, tslug) => { const t = T({ stem: 't', folder: 'pending', slug: tslug, deps: ['a'] }); return depsSatisfied(t, indexTasks([dep, t])) }

  check('no deps -> satisfied', depsSatisfied(T({ stem: 't', folder: 'pending', slug: 's' }), indexTasks([])) === true)
  check('cross-slug dep accepted+integrated -> satisfied', mk(A_int, 'sb') === true)
  check('cross-slug dep accepted+live-branch+unintegrated -> NOT satisfied', mk(A_live, 'sb') === false)
  check('same-slug dep accepted (even unintegrated) -> satisfied', mk(A_live, 'sa') === true)
  check('dep accepted with none-slug -> satisfied on acceptance', mk(A_none, 'sb') === true)
  check('dep in blocked -> NOT satisfied', mk(A_blocked, 'sb') === false)
  check('dangling dep (unresolvable) -> NOT satisfied', depsSatisfied(T({ stem: 't', folder: 'pending', slug: 's', deps: ['ghost'] }), indexTasks([T({ stem: 't', folder: 'pending', slug: 's', deps: ['ghost'] })])) === false)

  // override mode: cross-slug dep satisfied on acceptance alone (no Integrated-At written)
  check('override: cross-slug live-branch unintegrated dep -> satisfied', (() => {
    const t = T({ stem: 't', folder: 'pending', slug: 'sb', deps: ['a'] })
    return Sovr.depsSatisfied(t, Sovr.indexTasks([A_live, t])) === true
  })())
}

// ============================ satisfiedDeps (F1 digest collapse) ============================
// The digest scanner collapses terminal-accepted dependency targets into a flat satisfiedDeps[] of
// {stem,id} instead of full task objects. indexTasks(tasks, satisfiedDeps) must synthesize a terminal
// accepted dep for a token that resolves ONLY there, so depsSatisfied treats it as satisfied — while a
// REAL integration candidate (a full task object, never in satisfiedDeps) still blocks.
{
  const { indexTasks, depsSatisfied } = Sdef
  const P = (deps) => T({ stem: 't', folder: 'pending', slug: 'st', deps })
  // (1) token resolves only via satisfiedDeps -> satisfied (default)
  {
    const t = P(['a'])
    check('digest: dep in satisfiedDeps -> satisfied (default)', depsSatisfied(t, indexTasks([t], [{ stem: 'a', id: 'a' }])) === true)
  }
  // (2) same in override
  {
    const t = P(['a'])
    check('digest: dep in satisfiedDeps -> satisfied (override)', Sovr.depsSatisfied(t, Sovr.indexTasks([t], [{ stem: 'a', id: 'a' }])) === true)
  }
  // (3) a REAL integration candidate (live branch, unintegrated, cross-slug) still BLOCKS even if a
  //     same-named entry were (wrongly) in satisfiedDeps — real byStem wins first.
  {
    const cand = T({ stem: 'a', folder: 'accepted', slug: 'sa', hasWorktreeBranch: true, hasIntegratedAt: false })
    const t = T({ stem: 't', folder: 'pending', slug: 'sb', deps: ['a'] })
    check('digest: real integration candidate wins over satisfiedDeps -> blocks', depsSatisfied(t, indexTasks([cand, t], [{ stem: 'a', id: 'a' }])) === false)
  }
  // (4) id-based match (dep token is the id, stem differs)
  {
    const t = P(['feature-9-foo'])
    check('digest: satisfiedDeps id match -> satisfied', depsSatisfied(t, indexTasks([t], [{ stem: 'f9', id: 'feature-9-foo' }])) === true)
  }
  // (5) stem-prefix match (dep token is a prefix of a satisfiedDeps stem; mirrors resolve())
  {
    const t = P(['feature-9'])
    check('digest: satisfiedDeps stem-prefix match -> satisfied', depsSatisfied(t, indexTasks([t], [{ stem: 'feature-9-foo', id: 'feature-9-foo' }])) === true)
  }
  // (6) token absent from both tasks[] and satisfiedDeps -> dangling -> NOT satisfied (no silent pass)
  {
    const t = P(['ghost'])
    check('digest: token in neither -> dangling -> NOT satisfied', depsSatisfied(t, indexTasks([t], [{ stem: 'a', id: 'a' }])) === false)
  }
  // (7) version-skew: indexTasks called with NO satisfiedDeps arg behaves as before (full snapshot)
  {
    const A = T({ stem: 'a', folder: 'accepted', slug: 'none' })
    const t = T({ stem: 't', folder: 'pending', slug: 'sb', deps: ['a'] })
    check('digest: indexTasks without satisfiedDeps arg still resolves real tasks', depsSatisfied(t, indexTasks([A, t])) === true)
  }
}

// ============================ planUnblockAndTimeout ============================
{
  const { indexTasks, planUnblockAndTimeout } = Sdef
  const A = T({ stem: 'a', folder: 'accepted', slug: 'sa', hasIntegratedAt: true, hasWorktreeBranch: true }) // satisfied dep
  const A_live = T({ stem: 'a', folder: 'accepted', slug: 'sa', hasWorktreeBranch: true, hasIntegratedAt: false }) // unsatisfied cross-slug dep

  // (1) blocked, deps satisfied, rejectionCount < cap -> unblock
  {
    const B = T({ stem: 'b', folder: 'blocked', slug: 'sb', deps: ['a'], rejectionCount: 0 })
    const tasks = [A, B]
    const r = planUnblockAndTimeout(tasks, indexTasks(tasks), { trunkRoot: '/r' })
    check('blocked+deps-satisfied+rc<cap -> unblock action', r.unblockActions.length === 1 && r.unblockActions[0].toState === 'pending' && r.unblockActions[0].stem === 'b')
  }
  // (2) blocked, deps satisfied, rejectionCount >= cap -> NOT unblocked (max-rejection redesign)
  {
    const B = T({ stem: 'b', folder: 'blocked', slug: 'sb', deps: ['a'], rejectionCount: 3 })
    const tasks = [A, B]
    const r = planUnblockAndTimeout(tasks, indexTasks(tasks), { trunkRoot: '/r' })
    check('blocked+deps-satisfied+rc>=cap -> NOT unblocked', r.unblockActions.length === 0)
  }
  // (3) blocked, deps UNsatisfied -> NOT unblocked
  {
    const B = T({ stem: 'b', folder: 'blocked', slug: 'sb', deps: ['a'], rejectionCount: 0 })
    const tasks = [A_live, B]
    const r = planUnblockAndTimeout(tasks, indexTasks(tasks), { trunkRoot: '/r' })
    check('blocked+deps-UNsatisfied -> NOT unblocked', r.unblockActions.length === 0)
  }
  // (3b) I2: blocked, deps satisfied, blockCount >= cap -> NOT unblocked (parked for operator)
  {
    const B = T({ stem: 'b', folder: 'blocked', slug: 'sb', deps: ['a'], rejectionCount: 0, blockCount: 3 })
    const tasks = [A, B]
    const r = planUnblockAndTimeout(tasks, indexTasks(tasks), { trunkRoot: '/r' })
    check('I2: blocked+deps-satisfied+blockCount>=cap -> NOT unblocked (loop-breaker)', r.unblockActions.length === 0)
  }
  // (3c) I2: blocked, deps satisfied, blockCount < cap -> still unblocked (gets another fair shot)
  {
    const B = T({ stem: 'b', folder: 'blocked', slug: 'sb', deps: ['a'], rejectionCount: 0, blockCount: 2 })
    const tasks = [A, B]
    const r = planUnblockAndTimeout(tasks, indexTasks(tasks), { trunkRoot: '/r' })
    check('I2: blocked+deps-satisfied+blockCount<cap -> still unblocked', r.unblockActions.length === 1)
  }
  // (3d) I2: a custom maxBlock threshold is honored
  {
    const B = T({ stem: 'b', folder: 'blocked', slug: 'sb', deps: ['a'], rejectionCount: 0, blockCount: 1 })
    const tasks = [A, B]
    const r = planUnblockAndTimeout(tasks, indexTasks(tasks), { trunkRoot: '/r', maxBlock: 1 })
    check('I2: blockCount 1 >= custom maxBlock 1 -> NOT unblocked', r.unblockActions.length === 0)
  }
  // (3e) BUG-2: blocked, deps satisfied, blockCount < cap, but stem is PARKED (dependency-missing) -> NOT unblocked
  {
    const B = T({ stem: 'b', folder: 'blocked', slug: 'sb', deps: ['a'], rejectionCount: 0, blockCount: 0 })
    const tasks = [A, B]
    const parkedOff = planUnblockAndTimeout(tasks, indexTasks(tasks), { trunkRoot: '/r' })
    check('BUG-2: not parked -> unblocked (baseline)', parkedOff.unblockActions.length === 1)
    const parkedOnSet = planUnblockAndTimeout(tasks, indexTasks(tasks), { trunkRoot: '/r', parked: new Set(['b']) })
    check('BUG-2: parked stem (Set) -> NOT unblocked even below the cap', parkedOnSet.unblockActions.length === 0)
    const parkedOnArr = planUnblockAndTimeout(tasks, indexTasks(tasks), { trunkRoot: '/r', parked: ['b'] })
    check('BUG-2: parked accepts an array too', parkedOnArr.unblockActions.length === 0)
    const parkedOther = planUnblockAndTimeout(tasks, indexTasks(tasks), { trunkRoot: '/r', parked: new Set(['z']) })
    check('BUG-2: parking an unrelated stem does not suppress this one', parkedOther.unblockActions.length === 1)
  }
  // (4) in-progress stale -> timeout->blocked, excluded from freshInProgress
  {
    const IP = T({ stem: 'ip', folder: 'in-progress', slug: 'si', ageHours: 20 })
    const r = planUnblockAndTimeout([IP], indexTasks([IP]), { trunkRoot: '/r', timeoutH: 8 })
    check('in-progress age>=timeout -> timeout action (blocked)', r.timeoutActions.length === 1 && r.timeoutActions[0].toState === 'blocked')
    check('timed-out task excluded from freshInProgress', r.freshInProgress.length === 0)
  }
  // (5) in-progress fresh -> no timeout, kept fresh
  {
    const IP = T({ stem: 'ip', folder: 'in-progress', slug: 'si', ageHours: 3 })
    const r = planUnblockAndTimeout([IP], indexTasks([IP]), { trunkRoot: '/r', timeoutH: 8 })
    check('in-progress age<timeout -> no timeout', r.timeoutActions.length === 0)
    check('fresh in-progress kept for re-dispatch', r.freshInProgress.length === 1)
  }
  // (6) in-progress unknown age (-1) -> never times out
  {
    const IP = T({ stem: 'ip', folder: 'in-progress', slug: 'si', ageHours: -1 })
    const r = planUnblockAndTimeout([IP], indexTasks([IP]), { trunkRoot: '/r', timeoutH: 8 })
    check('in-progress unknown age -> never timed out', r.timeoutActions.length === 0 && r.freshInProgress.length === 1)
  }
  // (7) honors custom timeout threshold
  {
    const IP = T({ stem: 'ip', folder: 'in-progress', slug: 'si', ageHours: 10 })
    const r = planUnblockAndTimeout([IP], indexTasks([IP]), { trunkRoot: '/r', timeoutH: 24 })
    check('age 10 < threshold 24 -> not timed out', r.timeoutActions.length === 0)
  }
}

// ============================ the gaptrap chain (regression repro) ============================
// pending P -> blocked B -> accepted+integrated A. Pre-fix the workflow never touched blocked, so
// the backlog stalled. Now planUnblockAndTimeout must unblock B (its dep A is satisfied).
{
  const { indexTasks, planUnblockAndTimeout, depsSatisfied } = Sdef
  const A = T({ stem: 'a', folder: 'accepted', slug: 'sa', hasIntegratedAt: true, hasWorktreeBranch: true })
  const B = T({ stem: 'b', folder: 'blocked', slug: 'sb', deps: ['a'], rejectionCount: 0 })
  const P = T({ stem: 'p', folder: 'pending', slug: 'sp', deps: ['b'], rejectionCount: 0 })
  const tasks = [A, B, P]
  const idx = indexTasks(tasks)
  const r = planUnblockAndTimeout(tasks, idx, { trunkRoot: '/r' })
  check('gaptrap: B unblocks (blocked->pending)', r.unblockActions.some((a) => a.stem === 'b' && a.toState === 'pending'))
  check('gaptrap: P stays gated while B still blocked (deps not yet satisfied)', depsSatisfied(P, idx) === false)
}

// ============================ topoIntegrationOrder ============================
{
  const { indexTasks, topoIntegrationOrder } = Sdef
  // dep D (slug sd) must integrate before dependent C (slug sc) that cross-slug-depends on it
  const D = T({ stem: 'd', folder: 'accepted', slug: 'sd', hasWorktreeBranch: true })
  const C = T({ stem: 'c', folder: 'accepted', slug: 'sc', hasWorktreeBranch: true, deps: ['d'] })
  const order = topoIntegrationOrder([C, D], indexTasks([C, D]))
  check('topo: cross-slug dep ordered before dependent', order.map((t) => t.stem).join(',') === 'd,c')

  // cycle -> onCycle fires, returns input order
  const X = T({ stem: 'x', folder: 'accepted', slug: 'sx', hasWorktreeBranch: true, deps: ['y'] })
  const Y = T({ stem: 'y', folder: 'accepted', slug: 'sy', hasWorktreeBranch: true, deps: ['x'] })
  let cycled = false
  const ord2 = topoIntegrationOrder([X, Y], indexTasks([X, Y]), () => { cycled = true })
  check('topo: cycle triggers onCycle callback', cycled === true)
  check('topo: cycle falls back to input order (all kept)', ord2.length === 2)
}

// ============================ resultToState (BUG-3 streaming lifecycle) ============================
{
  const { resultToState } = Sdef
  check('in-progress + completed -> completed', resultToState('in-progress', 'completed') === 'completed')
  check('in-progress + blocked -> blocked', resultToState('in-progress', 'blocked') === 'blocked')
  check('in-review + accepted -> accepted', resultToState('in-review', 'accepted') === 'accepted')
  check('in-review + rejected -> rejected', resultToState('in-review', 'rejected') === 'rejected')
  check('in-progress + accepted -> null (illegal jump)', resultToState('in-progress', 'accepted') === null)
  check('in-review + completed -> null (illegal jump)', resultToState('in-review', 'completed') === null)
  check('any + none -> null (transient)', resultToState('in-progress', 'none') === null && resultToState('in-review', 'none') === null)
  check('any + undefined -> null (non-emit)', resultToState('in-progress', undefined) === null)
}

// ============================ reconcileIntegrationTallies (WS5 / retro #9) ============================
{
  const { reconcileIntegrationTallies } = Sdef
  const snap = (tasks) => ({ tasks })

  // Baseline: accumulators agree with disk (integrated tasks collapsed out of the digest) -> unchanged.
  {
    const r = reconcileIntegrationTallies(['a', 'b'], [], new Set(['a', 'b']), snap([]))
    check('recon: clean run keeps integrated as-is', JSON.stringify(r.integrated) === JSON.stringify(['a', 'b']))
    check('recon: clean run has no rejections', r.rejectedAtIntegration.length === 0)
    check('recon: clean run not flagged reconciled', r.reconciled === false)
  }

  // The #9 case: a post-resolver agent NON-EMIT — integrate-worktree moved the task to rejected/ on
  // disk (exit 6) but no accumulator caught it. attemptedIntegrate + the rejected/ folder recover it.
  {
    const r = reconcileIntegrationTallies([], [], new Set(['x']), snap([{ stem: 'x', folder: 'rejected' }]))
    check('recon: missed integration-rejection recovered from disk', JSON.stringify(r.rejectedAtIntegration) === JSON.stringify(['x']))
    check('recon: flagged reconciled when a rejection was recovered', r.reconciled === true)
  }

  // A stem the loop OPTIMISTICALLY counted integrated but disk shows in rejected/ -> demoted.
  {
    const r = reconcileIntegrationTallies(['y'], [], new Set(['y']), snap([{ stem: 'y', folder: 'rejected' }]))
    check('recon: false-positive integrated demoted out of integrated', r.integrated.length === 0)
    check('recon: false-positive integrated added to rejectedAtIntegration', JSON.stringify(r.rejectedAtIntegration) === JSON.stringify(['y']))
    check('recon: demotion flags reconciled', r.reconciled === true)
  }

  // Dedup: a stem in BOTH rejectedStems and the disk-derived set appears once.
  {
    const r = reconcileIntegrationTallies([], ['z'], new Set(['z']), snap([{ stem: 'z', folder: 'rejected' }]))
    check('recon: rejection not double-counted', JSON.stringify(r.rejectedAtIntegration) === JSON.stringify(['z']))
  }

  // An accepted-but-not-yet-integrated stem present in the snapshot is NOT a rejection.
  {
    const r = reconcileIntegrationTallies(['k'], [], new Set(['k']), snap([{ stem: 'k', folder: 'accepted' }]))
    check('recon: accepted-in-snapshot stem stays integrated (not demoted)', JSON.stringify(r.integrated) === JSON.stringify(['k']))
  }
}

console.log(`\nphase2-scheduler: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL === 0 ? 0 : 1)
