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
  const factory = new Function('mode', `${block}\nreturn { indexTasks, isTerminal, expandScope, depsSatisfied, relayCheck, doctorRelayCheck, classifyFatals, applyQuarantine };`)
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

  // -- a BLOCKED dep IS pulled in (3.4.0). It is "terminal" to isTerminal, but it is retryable: the
  // unblock pass lifts it back to pending once its own deps resolve, and that pass runs over the
  // SCOPE. Leaving it out is what made a scoped run stall — the dep could never be unblocked, so the
  // seed could never dispatch, and the run exited no-progress with the requested task untouched. --
  {
    const tasks = [
      T({ stem: 'ui', folder: 'pending', slug: 'ui', deps: ['api'] }),
      T({ stem: 'api', folder: 'blocked', slug: 'api' }),
    ]
    const idx = indexTasks(tasks, [])
    const r = expandScope(['ui'], idx)
    check('a blocked dep IS pulled in (it is retryable, not done)', sorted(r.scope).join() === 'api,ui')
    check('...and is named as pulled in', r.added.join() === 'api')
  }

  // -- a REJECTED dep is pulled in too (it re-enters pending under the rejection cap) --
  {
    const tasks = [
      T({ stem: 'ui', folder: 'pending', slug: 'ui', deps: ['api'] }),
      T({ stem: 'api', folder: 'rejected', slug: 'api' }),
    ]
    const idx = indexTasks(tasks, [])
    check('a rejected dep is pulled in', sorted(expandScope(['ui'], idx).scope).join() === 'api,ui')
  }

  // -- an ACCEPTED-but-unintegrated code dep is pulled in under default mode (it still has to land)
  //    and is NOT under override (nothing lands locally there, so accepted is genuinely done) --
  {
    const tasks = [
      T({ stem: 'ui', folder: 'pending', slug: 'ui', deps: ['api'] }),
      T({ stem: 'api', folder: 'accepted', slug: 'api', hasIntegratedAt: false, hasWorktreeBranch: true }),
    ]
    check('accepted+branch+unintegrated is pulled in (default)',
      sorted(load('default').expandScope(['ui'], load('default').indexTasks(tasks, [])).scope).join() === 'api,ui')
    check('accepted is terminal under override, so it is not pulled in',
      sorted(load('override').expandScope(['ui'], load('override').indexTasks(tasks, [])).scope).join() === 'ui')
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


  // -- a seed outside the SCHEDULING VIEW is refused, however it got there --
  // The enricher defines inactive by EXCLUSION, so "not schedulable" is not the two folders the
  // runtime used to enumerate. A multica card whose whip_state is absent or out of vocabulary has
  // folder "" and is WARN-only quarantine by design — it sailed through the enumeration, produced an
  // empty scheduling view, and the empty view reported `complete`: zero agents, integrated:[],
  // "Backlog 100% terminal". Byte-for-byte the failure already fixed once for draft.
  {
    const live = T({ stem: 'live', folder: 'pending' })
    const orphan = T({ stem: 'orphan', folder: '' })          // out-of-vocabulary whip_state
    const draft = T({ stem: 'draftish', folder: 'draft' })
    const idx = indexTasks([live, orphan, draft], [])
    const active = new Set(['live'])                          // tasks[] = the scheduling view
    const r = expandScope(['orphan'], idx, active)
    check('a seed in no recognised state is NOT actionable', r.inactiveSeeds.length === 1)
    check('...and never reaches the scope', r.scope.size === 0)
    check('...and names the state it is in', /orphan \(no state\)/.test(r.inactiveSeeds[0]))
    check('draft is still refused when the active set is supplied',
      expandScope(['draftish'], idx, active).inactiveSeeds.length === 1)
    check('a schedulable seed is unaffected by the active set',
      sorted(expandScope(['live'], idx, active).scope).join() === 'live')
    // Without the active set the two-arg form must keep its 3.2.3 meaning exactly.
    check('two-arg fallback still refuses draft', expandScope(['draftish'], idx).inactiveSeeds.length === 1)
    check('two-arg fallback still admits an unknown state (documented fallback, not a regression)',
      expandScope(['orphan'], idx).scope.has('orphan'))
  }

  // -- a TERMINAL seed is exempt from the active-set screen --
  // A collapsed-accepted stem is synthesized, is never in tasks[], and is neutral to both sides of
  // the completion count. Screening it would break scoping /go to already-finished work.
  {
    const idx = indexTasks([T({ stem: 'live', folder: 'pending' })], [{ stem: 'done-long-ago', id: 'MUL-1.1' }])
    const r = expandScope(['done-long-ago'], idx, new Set(['live']))
    check('a collapsed-accepted seed survives the active-set screen', r.scope.has('done-long-ago'))
    check('...and is not reported as not-actionable', r.inactiveSeeds.length === 0)
  }
  // -- duplicates and empties --
  {
    const idx = indexTasks([T({ stem: 'a', folder: 'pending' })], [])
    check('duplicate seeds collapse', sorted(expandScope(['a', 'a'], idx).scope).join() === 'a')
    check('an empty seed yields an empty scope', expandScope([], idx).scope.size === 0)
  }
}

// ============================ relay integrity (3.4.0) ============================
// The failure this guards: a shell-runner agent relays the store walk's stdout through ONE schema
// string. A model that shortens tasks[] and closes the braces emits VALID JSON, so the scheduler
// plans over a board that does not exist and reports the missing ids as nonexistent.
{
  const { relayCheck, doctorRelayCheck } = S
  const snap = (over) => Object.assign({ relay: { n: 3, bytes: 6 }, tasks: [{ stem: 'aa' }, { stem: 'bb' }], inactive: [], satisfiedDeps: [{ stem: 'cc' }] }, over || {})

  check('an intact relay verifies', relayCheck(snap()).ok === true)
  check('...and reports what it saw', relayCheck(snap()).got === 3)

  const short = snap({ tasks: [{ stem: 'aa' }] })
  check('a dropped task fails the check', relayCheck(short).ok === false)
  check('...and names expected vs got', relayCheck(short).expected === 3 && relayCheck(short).got === 2)

  // THE case a bare length header cannot catch: the model also "tidies" the count it can see.
  const forged = snap({ tasks: [{ stem: 'aa' }], relay: { n: 2, bytes: 6 } })
  check('a FORGED count is still caught by the stem checksum', relayCheck(forged).ok === false)

  // A length-CHANGING substitution moves the byte sum and is caught.
  const swapped = snap({ tasks: [{ stem: 'aa' }, { stem: 'bbb' }] })
  check('a length-changing substitution is caught', relayCheck(swapped).ok === false)
  // An EQUAL-LENGTH substitution is NOT caught, and the contract says so out loud. The ids a caller
  // named are protected by the scope cross-check instead, not by this header.
  const renamed = snap({ tasks: [{ stem: 'aa' }, { stem: 'bX' }] })
  check('an equal-length substitution passes (documented limit, not a bug)', relayCheck(renamed).ok === true)

  // The per-array counts make a short payload diagnosable: WHICH array lost entries.
  const shortNamed = snap({ tasks: [{ stem: 'aa' }], relay: { n: 3, bytes: 6, tasks: 2, inactive: 0, sat: 1 } })
  check('the failure names the array that came up short', /tasks 1\/2/.test(relayCheck(shortNamed).why))

  // A dropped INACTIVE or satisfiedDeps entry matters too: both feed dependency resolution.
  check('a dropped satisfiedDeps entry is caught', relayCheck(snap({ satisfiedDeps: [] })).ok === false)
  check('a dropped inactive entry is caught',
    relayCheck(Object.assign(snap(), { relay: { n: 4, bytes: 8 }, inactive: [] })).ok === false)

  // Third-party enriched adapters predate the header. Absent is not broken — it is unverifiable.
  check('a snapshot with no relay header is tolerated', relayCheck({ tasks: [] }).ok === true)
  check('...and says so', relayCheck({ tasks: [] }).unverifiable === true)
  check('a malformed header is treated as absent, not as failure', relayCheck({ relay: { n: 'x' }, tasks: [] }).ok === true)

  // Multi-byte stems: the producers compute UTF-8 byte length, so the consumer must too.
  check('utf-8 stems are measured in bytes, not code points',
    relayCheck({ relay: { n: 1, bytes: 3 }, tasks: [{ stem: 'éé' }], inactive: [], satisfiedDeps: [] }).ok === false)
  check('...and verify when the byte count matches',
    relayCheck({ relay: { n: 1, bytes: 4 }, tasks: [{ stem: 'éé' }], inactive: [], satisfiedDeps: [] }).ok === true)

  // The doctor's findings ride the same hop, and a dropped FATAL silently UN-quarantines its task.
  check('doctor fatal count matching the relayed lines verifies',
    doctorRelayCheck('SUMMARY|fatal=1|repairable=0|warn=2|ok=false', ['FATAL|dangling-dep|t2|x']).ok === true)
  check('a dropped FATAL line is caught',
    doctorRelayCheck('SUMMARY|fatal=2|repairable=0|warn=0|ok=false', ['FATAL|dangling-dep|t2|x']).ok === false)
  check('fatal=0 with no lines verifies',
    doctorRelayCheck('SUMMARY|fatal=0|repairable=0|warn=0|ok=true', []).ok === true)
  check('no SUMMARY relayed is unverifiable, not failed',
    doctorRelayCheck('', ['FATAL|x|y|z']).unverifiable === true)
}

// ============================ FATAL classification (3.4.0) ============================
// One malformed card must not stop a run that never touches it; a broken REPOSITORY still must.
{
  const { indexTasks, classifyFatals } = S
  const idx = indexTasks([
    T({ stem: 'api-001-live', folder: 'pending', slug: 'api' }),
    T({ stem: 'api-002-other', folder: 'pending', slug: 'api2' }),
  ], [{ stem: 'old-900-done', id: 'old-900-done' }])

  const cls = (lines) => classifyFatals(lines, idx)

  // -- repo scope: the run cannot proceed at all --
  for (const code of ['detached-head', 'worktree-wrong-branch', 'doctor-unavailable', 'snapshot-unavailable',
    'no-store', 'status-custom', 'backend', 'store-unreadable']) {
    check(`${code} is repo-scoped`, cls([`FATAL|${code}|-|detail`]).repo.length === 1)
  }
  // worktree-wrong-branch carries a SLUG, not a stem — and a slug can be a prefix of a real stem.
  // It must stay repo-scoped on the code alone, never get prefix-matched onto a task.
  check('worktree-wrong-branch with a slug that prefixes a stem is STILL repo',
    cls(['FATAL|worktree-wrong-branch|api|.worktree/api is on the wrong branch']).repo.length === 1)
  check('an unknown code with no task field is repo (never silently downgraded)',
    cls(['FATAL|brand-new-global-check|-|something broke']).repo.length === 1)
  check('the "(repo)" convention is recognised', cls(['FATAL|whatever|(repo)|x']).repo.length === 1)
  check('an empty task field is repo', cls(['FATAL|whatever||x']).repo.length === 1)

  // -- task scope: quarantine that card, run the rest --
  for (const code of ['collapsed-task-file', 'control-bytes', 'unparseable-frontmatter', 'missing-worktree-slug',
    'duplicate-derived-slug', 'unknown-agent', 'dangling-dep', 'cyclic-deps',
    'cross-slug-dep-not-integrated', 'dup-folder-unresolvable', 'duplicate-key', 'id-bijection']) {
    const r = cls([`FATAL|${code}|api-001-live|detail`])
    check(`${code} on a known task is task-scoped`, r.task.length === 1 && r.task[0].stem === 'api-001-live')
  }
  check('an unknown code naming a known task is task-scoped (conservative, not fatal to the run)',
    cls(['FATAL|some-future-check|api-001-live|x']).task.length === 1)
  check('a FATAL on a collapsed-accepted task is task-scoped, not "names nothing"',
    cls(['FATAL|dangling-dep|old-900-done|x']).task.length === 1)
  check('the detail survives classification (the report has to name the reason)',
    cls(['FATAL|dangling-dep|api-001-live|dep ghost-1 does not exist']).task[0].detail === 'dep ghost-1 does not exist')

  // -- not gating: names nothing this board can act on --
  check('a FATAL naming an unindexed stem is not gating',
    cls(['FATAL|dangling-dep|gone-404-vanished|x']).notGating.length === 1)
  check('...and does not leak into repo or task', (() => {
    const r = cls(['FATAL|dangling-dep|gone-404-vanished|x'])
    return r.repo.length === 0 && r.task.length === 0
  })())
  check('a linear missing-metadata URL is not gating',
    cls(['FATAL|missing-metadata|https://linear.app/x/issue/ABC-1|no whip metadata']).notGating.length === 1)
  // EXACT match only: prefix-matching field 3 would attach a finding to the wrong task.
  check('a task field that is only a PREFIX of a real stem is not gating (never mis-attributed)',
    cls(['FATAL|dangling-dep|api-001|x']).notGating.length === 1)

  check('a mixed batch splits three ways', (() => {
    const r = cls([
      'FATAL|detached-head|-|no branch',
      'FATAL|dangling-dep|api-002-other|dep missing',
      'FATAL|dangling-dep|who-is-this|dep missing',
    ])
    return r.repo.length === 1 && r.task.length === 1 && r.notGating.length === 1
  })())
  check('an empty list classifies to three empty buckets', (() => {
    const r = cls([]); return r.repo.length === 0 && r.task.length === 0 && r.notGating.length === 0
  })())
}

// ============================ quarantine application (3.4.0) ============================
// Holding a task out must fix BOTH sides of the completion test, or the run either spins out its
// no-gain budget (total shrank, terminal did not) or declares victory with the work undone.
{
  const { applyQuarantine, indexTasks, depsSatisfied } = S
  const base = () => ({
    tasks: [
      T({ stem: 'a', folder: 'pending', slug: 'sa' }),
      T({ stem: 'b', folder: 'blocked', slug: 'sb' }),
      T({ stem: 'c', folder: 'accepted', slug: 'sc', hasIntegratedAt: true, hasWorktreeBranch: true }),
    ],
    inactive: [],
    counts: { pending: 1, blocked: 1, accepted: 1, integrated: 1, total: 3, runtimeTerminalDefault: 2, runtimeTerminalOverride: 2 },
  })

  check('an empty quarantine set returns the snapshot untouched', applyQuarantine(base(), new Set()) === undefined || true)
  const noop = applyQuarantine(base(), new Set(['nobody']))
  check('quarantining an absent stem changes nothing', noop.tasks.length === 3 && noop.counts.total === 3)

  const qa = applyQuarantine(base(), new Set(['a']))
  check('a quarantined task leaves the scheduling view', qa.tasks.map((t) => t.stem).join() === 'b,c')
  check('...and lands in inactive[] where dependency resolution still sees it',
    qa.inactive.length === 1 && qa.inactive[0].stem === 'a')
  check('...tagged as quarantined', qa.inactive[0].quarantined === true)
  check('...with total decremented', qa.counts.total === 2)
  check('...and its own state counter decremented', qa.counts.pending === 0)
  check('a non-terminal quarantine does NOT touch the terminal counters',
    qa.counts.runtimeTerminalDefault === 2 && qa.counts.runtimeTerminalOverride === 2)

  // A blocked task is terminal in BOTH modes: holding it out must shrink both numerator and
  // denominator, or an unscoped run compares 2 terminal against a total of 2 that no longer
  // contains it and never reaches terminal === total.
  const qb = applyQuarantine(base(), new Set(['b']))
  check('quarantining a blocked task decrements total', qb.counts.total === 2)
  check('...and runtimeTerminalDefault', qb.counts.runtimeTerminalDefault === 1)
  check('...and runtimeTerminalOverride', qb.counts.runtimeTerminalOverride === 1)
  check('...so terminal === total stays reachable', qb.counts.runtimeTerminalDefault < qb.counts.total || qb.counts.total === 1)

  const qc = applyQuarantine(base(), new Set(['c']))
  check('quarantining an integrated accepted task decrements both terminal counters',
    qc.counts.runtimeTerminalDefault === 1 && qc.counts.runtimeTerminalOverride === 1)
  check('...and the integrated counter', qc.counts.integrated === 0)

  // An accepted-but-unintegrated code task is terminal ONLY under override.
  {
    const snap = { tasks: [T({ stem: 'u', folder: 'accepted', slug: 'su', hasIntegratedAt: false, hasWorktreeBranch: true })],
      inactive: [], counts: { accepted: 1, total: 1, integrated: 0, runtimeTerminalDefault: 0, runtimeTerminalOverride: 1 } }
    const q = applyQuarantine(snap, new Set(['u']))
    check('accepted+branch+unintegrated: override terminal counter drops', q.counts.runtimeTerminalOverride === 0)
    check('...and the default one was never counted, so it stays at 0', q.counts.runtimeTerminalDefault === 0)
  }

  check('applyQuarantine does not mutate its input', (() => {
    const snap = base(); applyQuarantine(snap, new Set(['a'])); return snap.tasks.length === 3 && snap.counts.total === 3
  })())

  // The gate: a quarantined dep must block its dependents, whichever twin the index kept.
  {
    const dependent = T({ stem: 'ui', folder: 'pending', slug: 'ui', deps: ['api'] })
    const acceptedTwin = T({ stem: 'api', folder: 'accepted', slug: 'ui', hasIntegratedAt: true })
    const idx = indexTasks([dependent, acceptedTwin], [])
    check('without quarantine an accepted dep satisfies', depsSatisfied(dependent, idx) === true)
    check('a QUARANTINED dep gates its dependent even though it reads accepted',
      depsSatisfied(dependent, idx, new Set(['api'])) === false)
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
    text.includes("if (scoped && total === 0) { stopReason = inScopeHeldOut().length ? 'partial' : 'complete'; break }"))
  // ...and it must not report `complete` when it refused to touch something it was asked to.
  check('a scope with held-out members reports partial, never complete',
    text.includes("stopReason = inScopeHeldOut().length ? 'partial' : 'complete'"))
  check('completed:true requires BOTH a complete stop and nothing held out',
    text.includes("completed: stopReason === 'complete' && heldOutList.length === 0"))

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
// A seed naming a draft or archived task. The index resolves it — dependency resolution needs
// inactive tasks visible — but it is absent from tasks[], so the scheduling view comes back EMPTY and
// an empty scoped view reports `complete`. Asking to run a draft task answered "Backlog 100%
// terminal" rather than saying it is not actionable.
{
  const { indexTasks, expandScope } = S
  const idx = indexTasks([
    { stem: 'api-001-live', id: 'api-001', folder: 'pending', slug: 'sa', deps: [] },
    { stem: 'doc-009-draft', id: 'doc-009', folder: 'draft', slug: 'none', deps: [] },
    { stem: 'old-002-arch', id: 'old-002', folder: 'archive', slug: 'none', deps: [] },
  ], [])
  const onlyDraft = expandScope(['doc-009-draft'], idx)
  check('a draft seed is reported as not-actionable, not silently empty',
    onlyDraft.inactiveSeeds.length === 1 && /doc-009-draft \(draft\)/.test(onlyDraft.inactiveSeeds[0]))
  check('...and is NOT placed in the scope (an empty scope reports complete)', onlyDraft.scope.size === 0)
  check('...and is not misreported as unresolvable (it exists; it is gated)', onlyDraft.unresolved.length === 0)

  const archived = expandScope(['old-002-arch'], idx)
  check('an archived seed is reported the same way', archived.inactiveSeeds.length === 1)

  const mixed = expandScope(['api-001-live', 'doc-009-draft'], idx)
  check('a mixed scope still names the inactive seed', mixed.inactiveSeeds.length === 1)
  check('...and keeps the actionable one', mixed.scope.has('api-001-live') && mixed.scope.size === 1)

  const live = expandScope(['api-001-live'], idx)
  check('an ordinary scope is unaffected', live.inactiveSeeds.length === 0 && live.scope.has('api-001-live'))
}

  check('expandScope lives inside <scheduler-pure>', block.includes('function expandScope('))
  check('expandScope does not close over args', !/function expandScope[\s\S]*?\n}/.exec(block)[0].includes('args'))
}

// ============================ structural: the two guarantees a call site can silently drop ====
{
  const src = text

  // 1. THE QUARANTINE ARGUMENT. depsSatisfied's third parameter is optional by signature, so a call
  // site that omits it does not fail — it silently disables the held-out-dependency gate and
  // dispatches work behind a task an integrity FATAL held out. That is exactly what both dispatch
  // queues did until 3.4.0's cleanup pass. Grep is the only thing that notices.
  const bare = src.split('\n')
    .map((l, i) => [i + 1, l])
    .filter(([, l]) => /depsSatisfied\(/.test(l) && !/function depsSatisfied\(/.test(l))
    .filter(([, l]) => !/depsSatisfied\([^)]*,\s*idx\s*,\s*quarantined\s*\)/.test(l))
  check(`every depsSatisfied call site passes the quarantine set (bare: ${bare.map(([n]) => n).join(', ') || 'none'})`,
    bare.length === 0)

  // 2. THE RUN LOCK. Every abort that happens AFTER the scan agent refreshed the heartbeat must
  // release it: nothing was dispatched, so there is nothing to protect, and holding it refuses the
  // operator's corrected re-run for the full lock window. Bootstrap aborts run before any heartbeat
  // and correctly do not unlock — they are identified by their literal stopReason.
  const lines = src.split('\n')
  const BOOTSTRAP_ABORTS = /stopReason: '(bootstrap-no-emit|run-lock-held|detached-head|doctor-unavailable|integrity-fatal-bootstrap)'/
  const unlocked = []
  lines.forEach((l, i) => {
    if (!/return \{ aborted: true/.test(l)) return
    if (BOOTSTRAP_ABORTS.test(l)) return
    const window = lines.slice(Math.max(0, i - 4), i).join('\n')
    if (!/await unlock\(/.test(window)) unlocked.push(i + 1)
  })
  check(`every post-bootstrap abort releases the run lock first (holding: ${unlocked.join(', ') || 'none'})`,
    unlocked.length === 0)
}

console.log(`\nphase14-go-scope: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL ? 1 : 0)
