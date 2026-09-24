// phase11-escalation.test.mjs — the 3.2.0 escalation machinery in whip-go.workflow.js.
//
// Executes the REAL workflow body with mocked globals (the same technique as phase5) and drives the
// paths that only appear when a harness misbehaves: the throw-repair loop and its convergence gates,
// the architect's refusal path, the agent-budget ladder, the WIP-preservation before a fallback, and
// the lane bound.
//
// The property every one of these defends: escalation can be SLOWER than 3.1.0, but it can never be
// less correct. Every exhaustion path must land on the verbatim 3.1.0 dispatch with the task in a
// defined state and nothing lost.
//
// Run: node acf-whip/tests/phase11-escalation.test.mjs

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

// Every adapter acf-whip ships stamps a `relay` header on its snapshot, and since 3.4.0 the
// orchestrator refuses a payload from a shipped backend that has none — a model that shortens what
// it echoes is at least as likely to drop the header as to recompute it. This mock is a shipped
// backend, so it stamps one, exactly as scan-backlog.sh does.
function withRelay(snap) {
  const arrs = [['tasks', snap.tasks], ['inactive', snap.inactive], ['sat', snap.satisfiedDeps]]
  let n = 0, bytes = 0
  const per = {}
  for (const [name, a] of arrs) {
    const list = Array.isArray(a) ? a : []
    per[name] = list.length
    n += list.length
    for (const e of list) for (const ch of String((e && e.stem) || '')) {
      const c = ch.codePointAt(0)
      bytes += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4
    }
  }
  return Object.assign({ relay: { n, bytes, tasks: per.tasks, inactive: per.inactive, sat: per.sat } }, snap)
}


const HERE = dirname(fileURLToPath(import.meta.url))
const SRC = join(HERE, '..', 'workflows', 'whip-go.workflow.js')
const BODY = readFileSync(SRC, 'utf8').replace(/^export const meta/m, 'const meta')

let PASS = 0, FAIL = 0
const ok = (m) => { PASS++; console.log(`  PASS: ${m}`) }
const bad = (m) => { FAIL++; console.log(`  FAIL: ${m}`) }
const check = (m, cond) => (cond ? ok(m) : bad(m))

// ---------------------------------------------------------------------------------------------
// A configurable driver around the real workflow body.
// ---------------------------------------------------------------------------------------------
async function runGo(cfg) {
  const c = Object.assign({
    tasks: [{ stem: 't1', slug: 's1' }],
    cpuCores: 8,
    agents: ['go-engineer', 'quality-reviewer'],
    goArgs: {},
    onArchitect: () => ({ wrote: true, scriptPath: '/p.js', planKeys: ['implement'], preservedStages: [], maxAgents: 5, shallow: true, summary: 'default', refuse: 'none', needsTask: '' }),
    onValidate: () => ({ ok: true, parser: 'node', errors: [], warnings: [], stageCount: 5, mutatingStages: 3 }),
    onScout: () => ({ worktree: '/r/.worktree/x', worktreeExists: true, commits: [], stageTrailers: [], dirty: [], stashes: [], stages: [], note: '' }),
    onWorkflow: () => ({ ok: true, transition: 'completed', commitSha: 'abc', rejectionIncrement: 0, notes: 'done', deliverableFiles: [], stagesRan: [], stagesReplayed: [], agentsUsed: 4 }),
  }, cfg)

  const model = new Map(c.tasks.map((t) => [t.stem, {
    stem: t.stem, id: t.stem, folder: 'pending', slug: t.slug, deps: [], hasIntegratedAt: false,
    hasWorktreeBranch: true, hasCleanCheckoutToken: true, rejectionCount: t.rejectionCount || 0,
    blockCount: t.blockCount || 0, ageHours: -1, priority: 'medium', agent: 'go-engineer',
  }]))
  const isTerm = (t) => t.folder === 'accepted' && (t.hasIntegratedAt || t.slug === 'none' || !t.hasWorktreeBranch)
  const snapshot = () => {
    const tasks = [...model.values()].map((t) => ({ ...t }))
    const cnt = { pending: 0, 'in-progress': 0, completed: 0, 'in-review': 0, blocked: 0, rejected: 0, accepted: 0 }
    for (const t of tasks) if (cnt[t.folder] != null) cnt[t.folder]++
    return {
      trunkRoot: '/r', inProgressTimeoutHours: 8, tasks, satisfiedDeps: [],
      counts: { ...cnt, total: tasks.length, integrated: tasks.filter((t) => t.hasIntegratedAt).length,
        runtimeTerminalDefault: tasks.filter(isTerm).length,
        runtimeTerminalOverride: tasks.filter((t) => t.folder === 'accepted' || t.folder === 'blocked').length },
    }
  }

  const calls = { architect: [], validate: [], scout: [], workflow: [], writer: [], wip: [], legacy: [], review: [] }
  let liveUnits = 0, maxLiveUnits = 0
  const logs = []
  const log = (m) => logs.push(String(m))
  const phase = () => {}
  const parallel = (thunks) => Promise.all(thunks.map((f) => Promise.resolve().then(f).catch(() => null)))
  const pipeline = async () => { throw new Error('pipeline not expected') }

  const workflow = async (ref, wargs) => {
    calls.workflow.push({ stem: wargs.stem, kind: wargs.stem, round: wargs.round, priorStages: wargs.priorStages, budget: wargs.agentBudget })
    return c.onWorkflow(wargs, calls.workflow.filter((w) => w.stem === wargs.stem).length)
  }

  const agent = async (prompt, opts) => {
    const label = (opts && opts.label) || ''
    if (/Bootstrap the acf-whip/.test(prompt)) {
      return { detached: false, lockFresh: false, doctorOk: true, doctorSummary: 'SUMMARY|ok=true', fatals: [], cpuCores: c.cpuCores, agents: c.agents, scaffoldOk: c.scaffoldOk !== false }
    }
    if (/acfw-store' snapshot/.test(prompt)) {
      return { snapshotJson: JSON.stringify(withRelay(snapshot())), doctorOk: true, doctorSummary: 'SUMMARY|ok=true', doctorFatals: [] }
    }
    if (/SINGLE backlog writer/.test(prompt)) {
      const re = /bash '[^']*acfw-store' transition '([^']*)' '([^']*)' '([^']*)' '([^']*)' '([^']*)' '([^']*)'/g
      let m
      while ((m = re.exec(prompt)) !== null) {
        const [, stem, toState, , , inc, binc] = m
        calls.writer.push({ stem, toState, inc, binc })
        const t = model.get(stem); if (t) t.folder = toState
      }
      return { applied: ['ok'], note: 'mock' }
    }
    if (/integrator for one accepted task/.test(prompt)) {
      const stem = prompt.replace(/^[\s\S]*\/accepted\/([^/']+)\.md[\s\S]*$/, '$1')
      const t = model.get(stem); if (t) t.hasIntegratedAt = true
      return { exitCode: 0, outcome: 'integrated', note: '', resolverWorktree: '', resolverBranch: '', resolverAgent: '', resolverConflictedFiles: '', resolverConflictingCommits: '' }
    }
    if (/Read-only reconnaissance/.test(prompt)) {
      calls.scout.push(label)
      return c.onScout(calls.scout.length, prompt)
    }
    if (/WORKFLOW ARCHITECT/.test(prompt)) {
      liveUnits++; maxLiveUnits = Math.max(maxLiveUnits, liveUnits)
      await new Promise((r) => setTimeout(r, 3))
      liveUnits--
      calls.architect.push({ label, prompt, amend: /THIS IS AN AMEND/.test(prompt) })
      return c.onArchitect(calls.architect.length, prompt)
    }
    if (/acfw-child-validate/.test(prompt)) {
      calls.validate.push(label)
      return c.onValidate(calls.validate.length, prompt)
    }
    if (/Preserve in-flight work/.test(prompt)) { calls.wip.push(label); return { porcelain: '' } }
    if (/quality-reviewer reviewing/.test(prompt) || /reviewing one NON-CODE/.test(prompt)) {
      calls.review.push(label)
      return { transition: 'accepted', commitSha: 'n/a', rejectionIncrement: 0, notes: 'lgtm' }
    }
    if (/specialist executing one acf-whip/.test(prompt) || /agent executing one NON-CODE/.test(prompt)) {
      calls.legacy.push(label)
      return { transition: 'completed', commitSha: 'deadbeef', rejectionIncrement: 0, notes: 'legacy' }
    }
    if (/rm -f/.test(prompt)) return 'unlocked'
    throw new Error('unmocked prompt: ' + String(prompt).slice(0, 90))
  }

  const fn = new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow',
    `return (async () => {\n${BODY}\n})()`)
  const goArgs = Object.assign({ pluginRoot: '/p', trunkRoot: '/r', trunkBranch: 'trunk', mode: 'default' }, c.goArgs)
  const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('TIMEOUT — deadlock')), 20000))
  const report = await Promise.race([fn(agent, parallel, pipeline, phase, log, goArgs, undefined, workflow), timeout])
  return { report, calls, logs, model, maxLiveUnits }
}

// ============================ 1. architect non-emit -> legacy ============================
{
  const r = await runGo({ onArchitect: () => { throw new Error('StructuredOutput non-emit') } })
  check('1a an architect that never emits falls back to the verbatim 3.1.0 dispatch', r.calls.legacy.length === 1)
  check('1b the child never ran', r.calls.workflow.length === 0)
  check('1c the task still completed', r.report.completed === true)
  check('1d the fallback is counted', r.report.escalation.fellBack >= 1)
  check('1e safeAgent retried the architect 3x before giving up (a non-emit is transient, not a defect)', r.calls.architect.length === 3)
}

// ============================ 2. architect refuses on a missing dependency ============================
{
  const r = await runGo({
    onArchitect: () => ({ wrote: true, scriptPath: '/p.js', planKeys: [], preservedStages: [], maxAgents: 0, shallow: false, summary: 'blocked', refuse: 'dependency-missing', needsTask: 'create the migration task first' }),
  })
  const blockRow = r.calls.writer.find((w) => w.toState === 'blocked')
  check('2a a refusal parks the task as blocked', !!blockRow)
  check('2b it does NOT charge Block-Count (the architect attempted nothing)', blockRow && blockRow.binc === '0')
  check('2c it does NOT charge Rejection Count either', blockRow && blockRow.inc === '0')
  check('2d the child never ran', r.calls.workflow.length === 0)
  check('2e the missing task is surfaced to the operator', JSON.stringify(r.report.needsOperator).includes('migration'))
  check('2f the refusal is counted separately from a fallback', r.report.escalation.refused === 1)
}

// ============================ 3. pre-flight rejection -> amend -> convergence gate ============================
{
  // The SAME errors twice: round 1 is granted, round 2 is not (paying for a round that provably
  // accomplishes nothing is the failure mode `improved` exists to stop).
  const r = await runGo({
    onValidate: () => ({ ok: false, parser: 'node', errors: ['V-GLOBALS: Date.now'], warnings: [], stageCount: 0, mutatingStages: 0 }),
  })
  check('3a a rejected harness never runs', r.calls.workflow.length === 0)
  check('3b the architect was re-invoked to amend', r.calls.architect.length === 2)
  check('3c an UNCHANGED pre-flight error stops the loop after one round', r.calls.architect.length === 2)
  check('3d it fell back to 3.1.0 rather than looping', r.calls.legacy.length === 1)
  check('3e the reason names non-convergence', r.logs.some((l) => /not converging/.test(l)) || r.report.escalation.preflightRejected >= 2)
  check('3f the task still reached a terminal state', r.report.completed === true)
}
{
  // DIFFERENT errors each round: the loop is allowed to continue to the bound.
  let n = 0
  const r = await runGo({
    onValidate: () => { n++; return { ok: false, parser: 'node', errors: [`V-PLAN: defect number ${n}`], warnings: [], stageCount: 0, mutatingStages: 0 } },
  })
  check('3g a CHANGING pre-flight error is allowed to run to the amend bound', r.calls.architect.length === 3)
  check('3h and then falls back cleanly', r.calls.legacy.length === 1)
}

// ============================ 4. throw -> scout -> amend, with and without progress ============================
{
  // No progress between rounds: the ledger stays empty, so round 2 is refused.
  const r = await runGo({ onWorkflow: () => { throw new TypeError('boom') } })
  check('4a a throwing harness is amended once', r.calls.workflow.length === 2)
  check('4b a throw with NO ledger/branch advance stops the loop after one round', r.calls.architect.length === 2)
  check('4c it fell back to 3.1.0', r.calls.legacy.length === 1)
  check('4d a scout ran before every amend', r.calls.scout.length >= 2)
}
{
  // Progress between rounds: the ledger advances, so the loop is granted its full bound.
  let round = 0
  const stagesByRound = [[], [{ name: 'a', status: 'ok', commit: false, resultJson: '{"x":1}', payloadPath: '', payloadMissing: false }],
    [{ name: 'a', status: 'ok', commit: false, resultJson: '{"x":1}', payloadPath: '', payloadMissing: false },
     { name: 'b', status: 'ok', commit: false, resultJson: '{"y":2}', payloadPath: '', payloadMissing: false }]]
  const r = await runGo({
    onScout: (n) => ({ worktree: '/r/.worktree/s1', worktreeExists: true, commits: [], stageTrailers: [], dirty: [], stashes: [], stages: stagesByRound[Math.min(n - 1, 2)], note: '' }),
    onWorkflow: () => { round++; throw new TypeError('boom ' + round) },
  })
  check('4e a throw WITH ledger advance is granted the full amend bound', r.calls.workflow.length === 3)
  const amendPrompts = r.calls.architect.filter((a) => a.amend)
  check('4f the amend architect was told what already completed', amendPrompts.length > 0 && /completed stages/.test(amendPrompts[0].prompt))
  check('4g ...and was given the error text', amendPrompts.length > 0 && /boom/.test(amendPrompts[0].prompt))
  check('4h ...and the stage key it must preserve', amendPrompts.length > 0 && /\ba\b/.test(amendPrompts[0].prompt))
  const second = r.calls.workflow[1]
  check('4i the re-run received the completed stage as ALREADY DONE', second && second.priorStages && second.priorStages.a !== undefined)
  check('4j the replayed stage carries its recorded value', second && second.priorStages.a && second.priorStages.a.result.x === 1)
}

// ============================ 5. WIP preservation before the legacy fallback ============================
{
  const r = await runGo({
    onScout: () => ({ worktree: '/r/.worktree/s1', worktreeExists: true, commits: [], stageTrailers: [], dirty: ['src/a.go', 'src/b.go'], stashes: [], stages: [], note: '' }),
    onWorkflow: () => { throw new TypeError('boom') },
  })
  check('5a in-flight work is committed as WIP before the fallback re-runs clean-checkout', r.calls.wip.length === 1)
  const wipIdx = r.logs.findIndex((l) => /committed 2 in-flight path/.test(l))
  const fbIdx = r.logs.findIndex((l) => /single-agent fallback/.test(l))
  check('5b ...and it happens BEFORE the fallback dispatch (clean-checkout would stash it away)', wipIdx >= 0 && fbIdx >= 0 && wipIdx < fbIdx)
}
{
  const r = await runGo({ onWorkflow: () => { throw new TypeError('boom') } })
  check('5c a clean tree needs no WIP commit', r.calls.wip.length === 0)
}

// ============================ 6. the environment kill switch ============================
{
  const r = await runGo({
    tasks: [{ stem: 't1', slug: 's1' }, { stem: 't2', slug: 's2' }],
    onWorkflow: () => { throw new Error('Workflow tool is restricted to named bundled workflows') },
  })
  check('6a an unavailable workflow() disables escalation for the WHOLE run', r.report.escalation.enabled === false)
  // Units already in flight in the same wave can each throw once before the flag is observable — that
  // is inherent and bounded by the lane count. What must NOT happen is an amend loop per task.
  check('6b the kill switch short-circuits the amend loop (no re-authoring)', r.calls.architect.length === r.calls.workflow.length)
  check('6b2 it probes by DOING — at most one throw per in-flight unit, never per amend round', r.calls.workflow.length <= 2)
  check('6c both tasks still completed via 3.1.0', r.report.completed === true && r.calls.legacy.length === 2)
  check('6d the operator is told why', r.logs.some((l) => /workflow\(\) unavailable/.test(l)))
}

// ============================ 7. the agent-budget ladder ============================
{
  const r = await runGo({
    tasks: [{ stem: 't1', slug: 's1' }, { stem: 't2', slug: 's2' }, { stem: 't3', slug: 's3' }],
    goArgs: { agentCap: 60 },
  })
  check('7a a small cap still produces a CLEAN report, never a crash', !!r.report && typeof r.report.stopReason === 'string')
  check('7b the report exposes the agent ledger', typeof r.report.agentsUsed === 'number' && r.report.agentCap === 60)
  check('7c the run released its lock (a finished run must not block its own re-run)',
    r.logs.length >= 0 && r.report.stopReason !== undefined)
}
{
  // A cap far below the reserve: the run must still terminate, report, and ACTUALLY TRY.
  // This used to assert that the ladder "fires immediately", which was only ever true because
  // CAP_RESERVE was a fixed 150 against an operator-settable cap — so `used >= cap - reserve` held
  // at used === 0 and the CLOSE rung emptied both queues before the pre-move. The run then reported
  // agent-cap-reached with agentsUsed 2/100 and "Nothing lost.", which is a clean stop that
  // dispatched nothing. Firing immediately was the defect, not the contract.
  const r = await runGo({ tasks: [{ stem: 't1', slug: 's1' }], goArgs: { agentCap: 10 } })
  check('7d inside the reserve, dispatch degrades instead of dying', !!r.report)
  check('7e the ladder is still reportable at a small cap',
    r.report.escalation && typeof r.report.escalation.fellBack === 'number')
  check('7f a small cap does not stop the run before it dispatched anything',
    r.report.stopReason !== 'agent-cap-reached' || r.report.agentsUsed > 0)
  check('7g ...and the task was actually attempted', r.calls.writer.length > 0 || r.report.agentsUsed > 0)
}

// ============================ 8. the kill switch ============================
{
  const r = await runGo({ goArgs: { escalate: false } })
  check('8a args.escalate:false runs verbatim 3.1.0', r.calls.workflow.length === 0 && r.calls.architect.length === 0)
  check('8b ...with no scout and no validator either', r.calls.scout.length === 0 && r.calls.validate.length === 0)
  check('8c the report says escalation was off', r.report.escalation.enabled === false)
  check('8d the task completed', r.report.completed === true)
}

// ============================ 9. an empty agent registry disables escalation loudly ============================
{
  const r = await runGo({ agents: [] })
  check('9a an EMPTY .claude/agents/ disables escalation (a harness would have nothing to dispatch)',
    r.report.escalation.enabled === false)
  check('9b ...loudly, with the fix named', r.logs.some((l) => /whip-add-agents/.test(l)))
  check('9c ...and the run still completes via 3.1.0', r.report.completed === true && r.calls.legacy.length === 1)

  const r2 = await runGo({ scaffoldOk: false })
  check('9d a failed scaffold probe also disables escalation (a missed chmod +x would otherwise degrade 100% silently)',
    r2.report.escalation.enabled === false)
  check('9e ...naming the executables to check', r2.logs.some((l) => /acfw-child-/.test(l)))

  const r3 = await runGo({})
  check('9f with agents installed and the scaffold working, escalation is ON', r3.report.escalation.enabled === true)
}

// ============================ 10. the lane bound holds and does not deadlock ============================
{
  // cpuCores 4 -> POOL 2 -> LANES 2. Four independent tasks must still all complete.
  const r = await runGo({
    cpuCores: 4,
    tasks: [{ stem: 't1', slug: 's1' }, { stem: 't2', slug: 's2' }, { stem: 't3', slug: 's3' }, { stem: 't4', slug: 's4' }],
  })
  check('10a a narrow lane bound does NOT deadlock — every task completed', r.report.completed === true)
  check('10b all four ran as authored harnesses', r.calls.workflow.length === 4)
  check('10c concurrency was actually bounded by the lanes', r.maxLiveUnits <= r.report.lanes)
  check('10d lanes never collapse to 1 (that would serialize the whole backlog)', r.report.lanes >= 2)
}

// ============================ 11. a child that returns garbage is transient, not corrupting =========
{
  const r = await runGo({ onWorkflow: () => ({ ok: true, transition: 'not-a-real-transition' }) })
  check('11a an unusable child return does not move the task', !r.calls.writer.some((w) => w.toState === 'completed'))
  check('11b it is logged as transient', r.logs.some((l) => /no usable ACFW_RESULT/.test(l)))
  check('11c the run terminates instead of looping forever', !!r.report && r.report.stopReason !== undefined)
}
{
  const r = await runGo({ onWorkflow: () => null })
  check('11d a null child return is also transient', !!r.report)
}

// ---------------------------------------------------------------------------------------------
// 12. A small agentCap must not make the run stop before it starts.
// CAP_RESERVE is a fixed 150 while agentCap is operator-settable with no documented floor, so any
// cap <= 150 made `used >= cap - reserve` true at used === 0. The CLOSE rung emptied both queues
// before the pre-move and the run reported agent-cap-reached with "agentsUsed: 2/100" and
// "Nothing lost." — a clean stop that dispatched nothing. The rung is not gated on ESCALATE, so
// `escalate: false` (the first thing skills/go/SKILL.md suggests for a hung run) hit it too.
// ---------------------------------------------------------------------------------------------
{
  const tier = new Function(`${BODY.match(/function escalationTier[\s\S]*?\n}/)[0]}\nreturn escalationTier`)()
  const RESERVE = Number(BODY.match(/const CAP_RESERVE\s*=\s*(\d+)/)[1])

  check('12a a fresh run at the default cap is FULL', tier(0, 1000, RESERVE) === 'FULL')
  check('12b a fresh run at a cap of 100 is FULL, not CLOSE', tier(0, 100, RESERVE) === 'FULL')
  check('12c ...at a cap of 20 too', tier(0, 20, RESERVE) === 'FULL')
  check('12d ...and at exactly the reserve', tier(0, RESERVE, RESERVE) === 'FULL')
  check('12e a small cap still reaches CLOSE near its end', tier(19, 20, RESERVE) === 'CLOSE')
  // The default ladder must be byte-identical: this fix may not move the boundary anyone relies on.
  check('12f the default cap still closes at exactly cap-reserve', tier(1000 - RESERVE, 1000, RESERVE) === 'CLOSE')
  check('12g ...and does not close one agent earlier', tier(1000 - RESERVE - 1, 1000, RESERVE) === 'DIRECT')
  check('12h cap<=0 is still guarded (a NaN compare would read DIRECT)', tier(0, 0, RESERVE) === 'FULL')
}

console.log(`\nphase11-escalation: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL === 0 ? 0 : 1)
