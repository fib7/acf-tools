// phase14-go-scope.test.mjs — unit-tests /go run scoping (3.2.3).
//
// Two halves, because the feature straddles the pure/impure boundary:
//
//   1. expandScope() is pure and lives inside <scheduler-pure>, so it is extracted and exercised
//      the same way phase2-scheduler.test.mjs does.
//   2. The scope WIRING (which collections the scheduler plans over, and how completion is counted)
//      lives in the iteration body, which needs the Workflow runtime and cannot be evaluated here.
//      That half is guarded structurally against the two ways this feature silently breaks:
//        - a planning site reverts from `sched` to `tasks`  -> out-of-scope work gets dispatched;
//        - completion reverts to the store-wide snap.counts -> `terminal === total` is unreachable
//          for a scoped run, which burns NO_GAIN_LIMIT iterations and exits 'no-progress'.
//      Both are silent at runtime. A grep-shaped assertion is brittle under refactor, which is the
//      point: it should fail loudly and be re-pointed deliberately, not drift.
//
// Run: node acf-whip/tests/phase14-go-scope.test.mjs

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const SRC = join(HERE, '..', 'workflows', 'whip-go.workflow.js')

let PASS = 0, FAIL = 0
const ok = (m) => { PASS++; console.log(`  PASS: ${m}`) }
const bad = (m) => { FAIL++; console.log(`  FAIL: ${m}`) }
const check = (m, cond) => (cond ? ok(m) : bad(m))

const text = readFileSync(SRC, 'utf8')
const start = text.indexOf('// <scheduler-pure>')
const end = text.indexOf('// </scheduler-pure>')
if (start < 0 || end < 0 || end < start) {
  console.error('FATAL: could not find <scheduler-pure> markers in whip-go.workflow.js')
  process.exit(1)
}
const block = text.slice(start, end)

function load(mode) {
  const factory = new Function('mode', `${block}\nreturn { indexTasks, isTerminal, expandScope };`)
  return factory(mode)
}
const S = load('default')

const T = (o) => ({
  stem: o.stem, id: o.id ?? o.stem, folder: o.folder, slug: o.slug ?? 'none',
  deps: o.deps ?? [], hasIntegratedAt: !!o.hasIntegratedAt, hasWorktreeBranch: !!o.hasWorktreeBranch,
  rejectionCount: o.rejectionCount ?? 0, blockCount: o.blockCount ?? 0, ageHours: o.ageHours ?? -1, priority: o.priority ?? 'medium',
})
const sorted = (set) => [...set].sort()

// ============================ expandScope ============================
{
  const { indexTasks, expandScope } = S

  // -- seed resolution: id, stem and unique prefix all reach the same task --
  {
    const tasks = [T({ stem: 'add-login-form', id: 'api-014-token-refresh', folder: 'pending' })]
    const idx = indexTasks(tasks, [])
    check('seed resolves by id', sorted(expandScope(['api-014-token-refresh'], idx).scope).join() === 'add-login-form')
    check('seed resolves by stem', sorted(expandScope(['add-login-form'], idx).scope).join() === 'add-login-form')
    check('seed resolves by unique prefix', sorted(expandScope(['add-login'], idx).scope).join() === 'add-login-form')
  }

  // -- an unresolvable seed is reported, never silently dropped --
  {
    const idx = indexTasks([T({ stem: 'a', folder: 'pending' })], [])
    const r = expandScope(['a', 'does-not-exist'], idx)
    check('unresolvable seed is reported', r.unresolved.join() === 'does-not-exist')
    check('resolvable seeds still resolve alongside it', r.scope.has('a'))
  }

  // -- THE reason expandScope exists: an unmet dep outside the seed is pulled IN, or the scoped
  //    task would stay correctly gated by depsSatisfied and never progress.
  {
    const tasks = [
      T({ stem: 'ui', folder: 'pending', slug: 'ui', deps: ['api'] }),
      T({ stem: 'api', folder: 'pending', slug: 'api' }),
      T({ stem: 'unrelated', folder: 'pending', slug: 'other' }),
    ]
    const idx = indexTasks(tasks, [])
    const r = expandScope(['ui'], idx)
    check('unmet dep is pulled into scope', sorted(r.scope).join() === 'api,ui')
    check('pulled-in dep is reported as added', r.added.join() === 'api')
    check('an unrelated task is NOT pulled in', !r.scope.has('unrelated'))
  }

  // -- a dep that is already terminal needs nothing --
  {
    const tasks = [
      T({ stem: 'ui', folder: 'pending', slug: 'ui', deps: ['api'] }),
      T({ stem: 'api', folder: 'accepted', slug: 'api', hasIntegratedAt: true, hasWorktreeBranch: true }),
    ]
    const idx = indexTasks(tasks, [])
    const r = expandScope(['ui'], idx)
    check('an integrated dep is not pulled in', sorted(r.scope).join() === 'ui')
    check('nothing reported as added for a terminal dep', r.added.length === 0)
  }

  // -- a blocked dep is terminal too, so it is not pulled in (it would never progress) --
  {
    const tasks = [
      T({ stem: 'ui', folder: 'pending', slug: 'ui', deps: ['api'] }),
      T({ stem: 'api', folder: 'blocked', slug: 'api' }),
    ]
    const idx = indexTasks(tasks, [])
    check('a blocked dep is not pulled in', sorted(expandScope(['ui'], idx).scope).join() === 'ui')
  }

  // -- transitive: deps of pulled-in deps come too --
  {
    const tasks = [
      T({ stem: 'a', folder: 'pending', slug: 'a', deps: ['b'] }),
      T({ stem: 'b', folder: 'pending', slug: 'b', deps: ['c'] }),
      T({ stem: 'c', folder: 'pending', slug: 'c' }),
      T({ stem: 'z', folder: 'pending', slug: 'z' }),
    ]
    const idx = indexTasks(tasks, [])
    const r = expandScope(['a'], idx)
    check('transitive deps are pulled in', sorted(r.scope).join() === 'a,b,c')
    check('transitive closure stops at the frontier', !r.scope.has('z'))
  }

  // -- a dependency CYCLE must terminate, not hang the scheduler --
  {
    const tasks = [
      T({ stem: 'x', folder: 'pending', slug: 'x', deps: ['y'] }),
      T({ stem: 'y', folder: 'pending', slug: 'y', deps: ['x'] }),
    ]
    const idx = indexTasks(tasks, [])
    check('a dep cycle terminates', sorted(expandScope(['x'], idx).scope).join() === 'x,y')
  }

  // -- a seed the scanner collapsed into satisfiedDeps resolves to a synthesized TERMINAL task.
  //    Its stem is absent from the working set, so it drops out of both sides of the completion
  //    count rather than erroring.
  {
    const idx = indexTasks([T({ stem: 'live', folder: 'pending' })], [{ stem: 'done-long-ago', id: 'MUL-1.1' }])
    const r = expandScope(['done-long-ago'], idx)
    check('a collapsed-accepted seed resolves (not unresolved)', r.unresolved.length === 0)
    check('a collapsed-accepted seed contributes its stem', r.scope.has('done-long-ago'))
  }

  // -- duplicates and empties --
  {
    const idx = indexTasks([T({ stem: 'a', folder: 'pending' })], [])
    check('duplicate seeds collapse', sorted(expandScope(['a', 'a'], idx).scope).join() === 'a')
    check('an empty seed yields an empty scope', expandScope([], idx).scope.size === 0)
  }
}

// ============================ scope wiring (structural) ============================
{
  // Every collection the scheduler plans over must read `sched`, never `tasks`. If any of these
  // reverts, a scoped run dispatches, transitions or integrates work the operator did not ask for.
  const planningSites = [
    ['unblock/timeout plan', 'planUnblockAndTimeout(sched, idx, {'],
    ['in-review queue', "const inReview = sched.filter((t) => t.folder === 'in-review')"],
    ['completed queue', "const completed = sched.filter((t) => t.folder === 'completed')"],
    ['pending queue', "const pending = sched.filter((t) => t.folder === 'pending')"],
    ['rejected self-heal', "const rejected = sched.filter((t) => t.folder === 'rejected')"],
    ['integration candidates', "for (const t of sched.filter((t) => t.folder === 'accepted'"],
  ]
  for (const [name, needle] of planningSites) {
    check(`planning site plans over the scoped view: ${name}`, text.includes(needle))
  }

  // The index must stay WHOLE: depsSatisfied treats an unresolvable dep token as dangling and
  // refuses to dispatch, so indexing the narrowed view would strand every scoped task with an
  // out-of-scope dependency.
  check('index is built from the full task set, not the scoped view',
    /const idx = indexTasks\(tasks\b[\s\S]{0,80}?snap\.satisfiedDeps\)/.test(text) && !text.includes('indexTasks(sched'))
  // ...and wider still than tasks[]: the dispatcher's enricher splits draft/archive into inactive[],
  // which must be resolvable or a scoped task depending on a draft is stranded with no explanation.
  check('the index unions inactive[] (draft/archive stay resolvable)',
    /indexTasks\(tasks\.concat\(snap\.inactive \|\| \[\]\)/.test(text))
  check('the drain index unions it too',
    /indexTasks\(\(snap2\.tasks \|\| \[\]\)\.concat\(snap2\.inactive \|\| \[\]\)/.test(text))
  // inactive[] must NOT reach the scheduling view, or a scoped run counts a draft in its denominator
  // and terminal === total is unreachable (isTerminal is false for draft and archive alike).
  check('inactive[] never reaches the scheduling view',
    !/sched = .*inactive/.test(text) && !/tasks\.concat\(snap\.inactive[^)]*\)\s*\n?\s*const scoped/.test(text))

  // THE denominator trap: completion for a scoped run must be counted over its own set.
  check('scoped completion counts its own set, not snap.counts',
    text.includes('const total = scoped ? sched.length : snap.counts.total'))
  check('scoped terminal count uses isTerminal over the scoped view',
    text.includes('? sched.filter(isTerminal).length'))
  check('an all-terminal scope stops instead of spinning past the `total > 0` guard',
    text.includes("if (scoped && total === 0) { stopReason = 'complete'; break }"))

  // Post-loop surfaces must honour the scope too, or a scoped run folds in and reports on other
  // people's accepted work.
  check('the integration drain honours the run scope', text.includes('(!runScope || runScope.has(t.stem))'))
  check('needsOperator is filtered to the run scope', text.includes('.filter((t) => (!runScope || runScope.has(t.stem)))'))

  // Default-off: no args.only => byte-identical behaviour.
  check('ONLY defaults to null when args.only is absent or empty',
    text.includes('const ONLY = (args && Array.isArray(args.only) && args.only.length) ? args.only.map(String) : null'))
  check('sched is the full task list on an unscoped run', text.includes(': tasks\n') || text.includes('scoped.scope.has(t.stem)) : tasks'))

  // The report must say what actually ran.
  for (const f of ['scopeFilter:', 'scopedTo: ONLY', 'scopeResolved:']) {
    check(`RunReport carries ${f.replace(':', '')}`, text.includes(f))
  }

  // expandScope must stay PURE (inside the markers) or phase2's extraction silently loses it.
  check('expandScope lives inside <scheduler-pure>', block.includes('function expandScope('))
  check('expandScope does not close over args', !/function expandScope[\s\S]*?\n}/.exec(block)[0].includes('args'))
}

console.log(`\nphase14-go-scope: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL ? 1 : 0)
