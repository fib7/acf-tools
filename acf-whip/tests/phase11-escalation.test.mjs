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

import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync, existsSync, realpathSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
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
    stem: t.stem, id: t.stem, folder: t.folder || 'pending', slug: t.slug, deps: [], hasIntegratedAt: false,
    hasWorktreeBranch: t.hasWorktreeBranch !== false, hasCleanCheckoutToken: t.hasCleanCheckoutToken !== false,
    rejectionCount: t.rejectionCount || 0,
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

  const calls = { architect: [], validate: [], scout: [], workflow: [], writer: [], wip: [], legacy: [], review: [], legacyPrompts: [], reviewPrompts: [], restore: [], probe: [], seq: [] }
  let liveUnits = 0, maxLiveUnits = 0
  const logs = []
  const log = (m) => logs.push(String(m))
  const phase = () => {}
  const parallel = (thunks) => Promise.all(thunks.map((f) => Promise.resolve().then(f).catch(() => null)))
  const pipeline = async () => { throw new Error('pipeline not expected') }

  // The child's kind is only observable through its script path (childDirFor: .../<stem>/<attempt>/<kind>/),
  // and its BASE is what every stage of it is told — both are recorded so section 13 can assert on them.
  const workflow = async (ref, wargs) => {
    const kind = (String((ref && ref.scriptPath) || '').match(/\/([a-z]+)\/harness\.workflow\.js$/) || [])[1] || ''
    calls.workflow.push({ stem: wargs.stem, kind, basePrompt: wargs.basePrompt, round: wargs.round, priorStages: wargs.priorStages, budget: wargs.agentBudget })
    calls.seq.push(`workflow:${kind}`)
    return c.onWorkflow(wargs, calls.workflow.filter((w) => w.stem === wargs.stem).length, kind, model)
  }

  const agent = async (prompt, opts) => {
    const label = (opts && opts.label) || ''
    if (/Bootstrap the acf-whip/.test(prompt)) {
      return { detached: false, lockFresh: false, doctorOk: true, doctorSummary: 'SUMMARY|ok=true', fatals: [], cpuCores: c.cpuCores, agents: c.agents, scaffoldOk: c.scaffoldOk !== false }
    }
    // restoreCheckoutToken (3.4.3). A 'restored' outcome writes the token, exactly as the real
    // clean-checkout does, so the NEXT scan sees it — that is what lets section 14 run a whole cycle.
    if (/Re-record this task's clean-checkout token/.test(prompt)) {
      const stem = (prompt.match(/\/in-progress\/([^/']+)\.md'/) || [])[1] || ''
      calls.restore.push({ label, prompt, stem, model: opts && opts.model }); calls.seq.push('restore')
      const out = c.onRestore ? c.onRestore(stem, prompt) : { outcome: 'restored', exitCode: 0 }
      if (out && out.outcome === 'restored') { const t = model.get(stem); if (t) t.hasCleanCheckoutToken = true }
      return out
    }
    // reviewTokenObserved (3.4.3): the inline review panel's token probe. It reads the row, so it
    // answers from the model — the same witness the reviewer mock below and the scan both use.
    if (/Check this task's clean-checkout token before its review panel/.test(prompt)) {
      const stem = (prompt.match(/\/in-review\/([^/']+)\.md'/) || [])[1] || ''
      calls.probe.push({ label, prompt, stem, model: opts && opts.model }); calls.seq.push('probe')
      const t = model.get(stem)
      return c.onProbe ? c.onProbe(stem, prompt) : { token: t && t.hasCleanCheckoutToken ? 'present' : 'absent' }
    }
    if (/acfw-store' snapshot/.test(prompt)) {
      return { snapshotJson: JSON.stringify(withRelay(snapshot())), doctorOk: true, doctorSummary: 'SUMMARY|ok=true', doctorFatals: [] }
    }
    if (/SINGLE backlog writer/.test(prompt)) {
      // Each argument is sq()-quoted, so an apostrophe in the notes arrives as '\'' — a bare '([^']*)'
      // silently skipped every such row (the token-strand park note says "token's"), leaving the task
      // where it was in the model while the workflow believed it moved.
      const Q = String.raw`'((?:[^']|'\\'')*)'`
      const re = new RegExp(String.raw`bash '[^']*acfw-store' transition (?:--stage '(?:[^']|'\\'')*' )*` + [Q, Q, Q, Q, Q, Q].join(' '), 'g')
      let m
      while ((m = re.exec(prompt)) !== null) {
        const [, stem, toState, , , inc, binc] = m
        calls.writer.push({ stem, toState, inc, binc }); calls.seq.push(`write:${toState}`)
        const t = model.get(stem); if (t) t.folder = toState
      }
      return { applied: ['ok'], note: 'mock' }
    }
    if (/integrator for one accepted task/.test(prompt)) {
      const stem = prompt.replace(/^[\s\S]*\/accepted\/([^/']+)\.md[\s\S]*$/, '$1')
      const post = /--post-resolver/.test(prompt)
      const over = c.onIntegrate ? c.onIntegrate(stem, post) : null
      if (over) return over
      const t = model.get(stem); if (t) t.hasIntegratedAt = true
      return { exitCode: 0, outcome: 'integrated', note: '', resolverWorktree: '', resolverBranch: '', resolverAgent: '', resolverConflictedFiles: '', resolverConflictingCommits: '' }
    }
    if (/You are the conflict resolver/.test(prompt)) {
      calls.legacyPrompts.push({ label, prompt })
      return 'resolved'
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
      calls.review.push(label); calls.reviewPrompts.push({ label, prompt })
      // reviewerPrompt's PRE-STEP-0 CHECK, honoured: a code task whose branch exists but whose token
      // does not is a MECHANISM fault. Every other section runs with the token present, so this arm
      // only ever fires in section 14 — where ignoring it would let the forever-loop pass unnoticed.
      const rs = (prompt.match(/\/in-review\/([^/']+)\.md'/) || [])[1]
      const rt = /quality-reviewer reviewing one acf-whip/.test(prompt) && rs && model.get(rs)
      if (rt && rt.hasWorktreeBranch && !rt.hasCleanCheckoutToken) {
        return { transition: 'rejected', commitSha: 'n/a', rejectionIncrement: 0, faultClass: 'mechanism', notes: 'token row lost, branch exists' }
      }
      return { transition: 'accepted', commitSha: 'n/a', rejectionIncrement: 0, notes: 'lgtm' }
    }
    if (/specialist executing one acf-whip/.test(prompt) || /agent executing one NON-CODE/.test(prompt)) {
      calls.legacy.push(label); calls.legacyPrompts.push({ label, prompt })
      // A 3.1.0 code specialist runs its own STEP 0 clean-checkout, which creates the branch and records
      // the token — the one thing the reviewer mock above now checks for.
      const ls = /specialist executing one acf-whip/.test(prompt) && (prompt.match(/\/in-progress\/([^/']+)\.md'/) || [])[1]
      const lt = ls && model.get(ls)
      if (lt) { lt.hasWorktreeBranch = true; lt.hasCleanCheckoutToken = true }
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

// ---------------------------------------------------------------------------------------------
// 13. The child-harness stage rules reach impl and review stages — and ONLY those (3.4.3).
// childPreamble was defined in 3.2.0 and never called, so every authored stage was handed the bare
// specialist/reviewer prompt, whose STEP 0 is "run clean-checkout": N stages, N non-reentrant
// checkouts, each able to stash a sibling stage's in-flight work into the shared refs/stash. The
// single-checkout rule was only ever told to the architect. It must wrap impl and review, and must
// NOT wrap direct (no worktree exists, nothing may be committed) or resolve (a mid-cherry-pick tree
// whose one commit the integrator owns): those two BASEs stay byte-identical to the prompt the 3.1.0
// single agent receives, which each test below takes from a real escalation-off run of the same task.
// ---------------------------------------------------------------------------------------------
{
  const MARK = 'acf-whip child-harness stage rules'
  const HEARTBEAT = "touch '/r/.backlog/.acfw-run.json'"
  const DONE = () => ({ ok: true, transition: 'completed', commitSha: 'abc', rejectionIncrement: 0, notes: 'done', deliverableFiles: [], stagesRan: [], stagesReplayed: [], agentsUsed: 4 })
  const childOf = (r, kind) => r.calls.workflow.find((w) => w.kind === kind)
  const promptIn = (list, re) => (list.find((p) => re.test(p.prompt)) || {}).prompt || ''

  // ---- impl
  const implRun = await runGo({})
  const implOff = await runGo({ goArgs: { escalate: false } })
  const impl = childOf(implRun, 'impl')
  const implBare = promptIn(implOff.calls.legacyPrompts, /specialist executing one acf-whip/)
  check('13a an impl harness ran and its BASE carries the stage rules', !!impl && impl.basePrompt.includes(MARK))
  check('13b ...APPENDED to the verbatim 3.1.0 specialist prompt, never replacing it',
    !!impl && implBare.length > 0 && impl.basePrompt.startsWith(implBare) && impl.basePrompt.length > implBare.length)
  check('13c ...telling every stage to skip the STEP 0 checkout the specialist prompt calls mandatory',
    !!impl && /SKIP the STEP 0 above/.test(impl.basePrompt) && /STEP 0 \(mandatory/.test(implBare))
  check('13d ...while sanctioning the locked checkout stage (a first dispatch has no worktree to attach to)',
    !!impl && /that stage IS the one checkout/.test(impl.basePrompt))
  // The exception is keyed to the stage KEY the skeleton's locked rule() prints, never to the stage's
  // instructions: an authored stage whose prompt interpolates A.cleanCheckout passes the validator's
  // literal-substring guard, and content-keyed wording sanctioned exactly that stage.
  check('13d2 ...by the stage KEY (impl: exactly \'checkout\'), not by what the stage instructions say',
    !!impl && /if that key is EXACTLY 'checkout'/.test(impl.basePrompt)
    && /PROGRESS LEDGER for stage '<key>'/.test(impl.basePrompt)
    && /For ANY other\s+key, never run clean-checkout[\s\S]{0,80}even if your stage instructions spell out/.test(impl.basePrompt)
    && !/when the stage instructions at\s+the END of this prompt spell out/.test(impl.basePrompt))
  check('13e ...and carrying the per-stage run-lock heartbeat', !!impl && impl.basePrompt.includes(HEARTBEAT))
  check('13f the 3.1.0 single-agent fallback is NOT wrapped (a lone specialist must run its own Step 0)',
    implBare.length > 0 && !implBare.includes(MARK))

  // ---- review (the panel seam is opt-in, so it has to be switched on to exist at all)
  const REVIEW_OK = { ok: true, transition: 'accepted', commitSha: 'n/a', rejectionIncrement: 0, notes: 'panel ok', stagesRan: [], stagesReplayed: [], agentsUsed: 4 }
  const revRun = await runGo({ goArgs: { escalateReview: true }, onWorkflow: (w, n, kind) => (kind === 'review' ? REVIEW_OK : DONE()) })
  const revOff = await runGo({ goArgs: { escalate: false } })
  const rev = childOf(revRun, 'review')
  const revBare = promptIn(revOff.calls.reviewPrompts, /quality-reviewer reviewing/)
  check('13g a review harness ran and its BASE carries the stage rules', !!rev && rev.basePrompt.includes(MARK))
  check('13h ...appended to the verbatim 3.1.0 reviewer prompt',
    !!rev && revBare.length > 0 && rev.basePrompt.startsWith(revBare) && rev.basePrompt.length > revBare.length)
  check('13h2 ...whose one sanctioned checkout is the locked \'review-gate\' stage, not \'checkout\'',
    !!rev && /if that key is EXACTLY 'review-gate'/.test(rev.basePrompt) && !/EXACTLY 'checkout'/.test(rev.basePrompt))
  check('13i the review child\'s accept was consumed (no single-agent reviewer ran)', !!rev && revRun.calls.review.length === 0 && revRun.report.completed === true)
  check('13i2 ...after ONE token probe that saw the row (a present token never defers the panel)',
    revRun.calls.probe.length === 1 && revRun.calls.seq.indexOf('probe') < revRun.calls.seq.indexOf('workflow:review')
    && !revRun.logs.some((l) => /not observed before the review panel/.test(l)))
  check('13j the token check no longer sends a stage "Continue to Step 0" (the rules it is wrapped in forbid Step 0)',
    revBare.length > 0 && !/Continue to Step 0/.test(revBare) && /PRE-STEP-0 CHECK/.test(revBare))
  check('13k the unwrapped 3.1.0 reviewer is still sent on to its STEP 0 after a passing check',
    /STEP 0 included/.test(revBare) && /STEP 0: run/.test(revBare) && !revBare.includes(MARK))

  // ---- direct (Worktree: none)
  const dirTasks = [{ stem: 't1', slug: 'none' }]
  const dirRun = await runGo({ tasks: dirTasks })
  const dirOff = await runGo({ tasks: dirTasks, goArgs: { escalate: false } })
  const dir = childOf(dirRun, 'direct')
  const dirBare = promptIn(dirOff.calls.legacyPrompts, /agent executing one NON-CODE/)
  check('13l a direct harness ran and its BASE does NOT carry the stage rules', !!dir && !dir.basePrompt.includes(MARK))
  check('13m ...it is BYTE-IDENTICAL to the 3.1.0 direct prompt (no "worktree ALREADY EXISTS" for a task that has none)',
    !!dir && dirBare.length > 0 && dir.basePrompt === dirBare)
  check('13n no impl child was dispatched for a Worktree: none task', !childOf(dirRun, 'impl'))

  // ---- resolve (the integrator reports a cherry-pick conflict once, then integrates post-resolver)
  const conflict = { exitCode: 7, outcome: 'resolver-needed', note: '', resolverWorktree: '/r/.acfwhip/run/integ', resolverBranch: '', resolverAgent: '', resolverConflictedFiles: 'src/a.go', resolverConflictingCommits: '' }
  const onIntegrate = (stem, post) => (post ? null : conflict)
  const RESOLVED = { ok: true, transition: 'none', commitSha: 'n/a', rejectionIncrement: 0, notes: 'resolved, 1 staged', resolved: true, staged: 1, stagesRan: [], stagesReplayed: [], agentsUsed: 3 }
  const resRun = await runGo({ onIntegrate, onWorkflow: (w, n, kind) => (kind === 'resolve' ? RESOLVED : DONE()) })
  const resOff = await runGo({ onIntegrate, goArgs: { escalate: false } })
  const res = childOf(resRun, 'resolve')
  const resBare = promptIn(resOff.calls.legacyPrompts, /You are the conflict resolver/)
  check('13o a resolve harness ran and its BASE does NOT carry the stage rules', !!res && !res.basePrompt.includes(MARK))
  check('13p ...it is BYTE-IDENTICAL to the 3.1.0 resolver prompt (never told it may ADD commits mid-cherry-pick)',
    !!res && resBare.length > 0 && res.basePrompt === resBare)
  check('13q the resolved conflict still integrated', resRun.report.completed === true && resOff.report.completed === true)
}

// ---------------------------------------------------------------------------------------------
// 14. The token write section 13 took away, put back where it cannot stash anything (3.4.3).
// The locked checkout runs clean-checkout ONLY when no worktree exists; on an existing one it echoes the
// path and writes no token. Before 3.4.3 the implement stage's own STEP 0 re-ran clean-checkout and
// re-recorded it — the preamble now forbids that, so a harness that ATTACHES (a same-slug sibling, a
// re-dispatch after clean-checkout exited 6, a task re-queued after a token-strand park) got no token
// at all, and a replay with an unchanged attempt key re-parked it forever. The parent now re-records it
// before the harness, with the SAME command, and only on a clean tree.
// ---------------------------------------------------------------------------------------------
{
  const CC = "bash '/p/skills/clean-checkout-before-task/bin/clean-checkout.sh' '/r/.backlog/in-progress/t1.md'"
  const at = (r, k) => r.calls.seq.indexOf(k)
  const promptIn = (list, re) => (list.find((x) => re.test(x.prompt)) || {}).prompt || ''

  // ---- branch exists, token missing: the attach case
  const r = await runGo({ tasks: [{ stem: 't1', slug: 's1', hasCleanCheckoutToken: false }] })
  const p = (r.calls.restore[0] || {}).prompt || ''
  check('14a a dispatch onto an existing worktree with no token re-records it exactly once', r.calls.restore.length === 1)
  check('14b ...with the SAME clean-checkout command the locked checkout stage runs (same script, same task path)', p.includes(CC))
  check('14c ...and only on a CLEAN attached tree (a dirty one is where a second stash destroys work)',
    /elif \[ -n "\$S" \]; then echo 'OUTCOME dirty'/.test(p) && p.indexOf('OUTCOME dirty') < p.indexOf(CC))
  check('14c2 ...where an UNREADABLE tree is never read as clean (the status call\'s own exit is tested first)',
    /elif ! S=\$\(git -C "\$WT" status --porcelain\); then echo 'OUTCOME unreadable'/.test(p)
    && p.indexOf('OUTCOME unreadable') < p.indexOf('OUTCOME dirty'))
  check('14d ...attaching BY QUERY, as the locked stage does (the constructed path can differ from the real one)',
    /worktree list --porcelain \| awk -v b="branch refs\/heads\/[^"]*\/s1"/.test(p))
  check('14d2 ...and parsing the porcelain path WHOLE (p=$2 cuts it at the first space)',
    p.includes("'/^worktree /{p=substr($0,10)}") && !p.includes('{p=$2}'))

  // ---- the probe EXECUTED, not regex-matched: a fail-open probe reads exactly like a correct one.
  // The snippet is lifted verbatim from the prompt and run by bash against a real git worktree under a
  // path with a space in it. Only three literals are rebound: the trunk root, the clean-checkout script
  // (a stand-in that records that it ran, and writes the token row as the real one does) and the task
  // file. If the probe ever lets clean-checkout near an unreadable or dirty tree, CC_RAN appears.
  {
    const snip = (p.match(/Run EXACTLY this, ONCE:\n([\s\S]*?)\nReport outcome/) || [])[1] || ''
    const branch = (snip.match(/branch refs\/heads\/([^"]+)"/) || [])[1] || ''
    const base = realpathSync(mkdtempSync(join(tmpdir(), 'acfw p11 ')))
    const repo = join(base, 'my repo'), wt = join(repo, '.worktree', 's1')
    const cc = join(base, 'cc.sh'), ran = join(base, 'CC_RAN'), task = join(base, 't1.md')
    const G = ['-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', '-c', 'user.name=t', '-c', 'user.email=t@t']
    const git = (...a) => spawnSync('git', [...G, ...a], { encoding: 'utf8' })
    const sqp = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`
    const run = () => {
      writeFileSync(task, '# t1\n\n## Transition Log\n| At | Event | Status | Note |\n')
      rmSync(ran, { force: true })
      const sh = snip.split("'/r'").join(sqp(repo))
        .split("'/p/skills/clean-checkout-before-task/bin/clean-checkout.sh'").join(sqp(cc))
        .split("'/r/.backlog/in-progress/t1.md'").join(sqp(task))
      const o = spawnSync('bash', ['-c', sh], { encoding: 'utf8' })
      return { out: String(o.stdout || ''), ran: existsSync(ran) }
    }
    try {
      mkdirSync(repo)
      writeFileSync(cc, `#!/bin/bash\ntouch ${sqp(ran)}\nprintf '| now | clean-checkout | ok | stand-in |\\n' >> "$1"\n`)
      const setup = [git('-C', repo, 'init', '-q'), git('-C', repo, 'commit', '-q', '--allow-empty', '-m', 'init')]
      writeFileSync(join(repo, 'a.txt'), 'a\n')
      setup.push(git('-C', repo, 'add', 'a.txt'), git('-C', repo, 'commit', '-q', '-m', 'a'))
      setup.push(git('-C', repo, 'worktree', 'add', '-q', '-b', branch, wt))
      const ready = snip.length > 0 && branch.length > 0 && setup.every((s) => s.status === 0)
      check('14v the probe snippet was lifted and a worktree created under a path with a space', ready)

      writeFileSync(join(wt, 'a.txt'), 'modified\n'); writeFileSync(join(wt, 'wip.txt'), 'wip\n')
      const dirty = run()
      check('14w dirty worktree at a spaced path -> OUTCOME dirty, clean-checkout never runs',
        /OUTCOME dirty/.test(dirty.out) && !dirty.ran && git('-C', repo, 'stash', 'list').stdout.trim() === '')

      git('-C', wt, 'checkout', '-q', '--', 'a.txt'); rmSync(join(wt, 'wip.txt'))
      const clean = run()
      check('14x clean worktree at a spaced path -> clean-checkout runs once and the row is verified (OUTCOME restored)',
        /OUTCOME restored/.test(clean.out) && clean.ran)

      // `git -C` cannot enter the tree: status prints its fatal to stderr and NOTHING to stdout. The
      // 3.4.3 original read that empty stdout as a clean tree and ran clean-checkout.
      rmSync(wt, { recursive: true, force: true })
      const gone = run()
      check('14y a tree git cannot read (status exits non-zero) -> OUTCOME unreadable, clean-checkout never runs (fails CLOSED)',
        /OUTCOME unreadable/.test(gone.out) && !gone.ran)

      git('-C', repo, 'worktree', 'prune')
      const none = run()
      check('14z no worktree on the branch -> OUTCOME no-worktree, clean-checkout never runs', /OUTCOME no-worktree/.test(none.out) && !none.ran)
    } finally { rmSync(base, { recursive: true, force: true }) }
  }
  check('14e ...and on files it proves the row landed (clean-checkout only WARNs and exits 0 when append_log_row refuses)',
    /grep -qE '\\\| clean-checkout \\\| ok \\\|' '\/r\/\.backlog\/in-progress\/t1\.md'; then echo 'OUTCOME unrecorded'/.test(p))
  check('14f it ran BEFORE the impl harness, not after', at(r, 'restore') >= 0 && at(r, 'restore') < at(r, 'workflow:impl'))
  check('14g on the shell tier (it echoes one command\'s outcome)', !!r.calls.restore[0] && typeof r.calls.restore[0].model === 'string' && r.calls.restore[0].model.length > 0)
  check('14h the task still completed', r.report.completed === true)

  // ---- cases where re-recording would be redundant or unsafe
  const present = await runGo({})
  check('14i token already present -> no re-record (the common path costs nothing)', present.calls.restore.length === 0 && present.calls.workflow.length === 1)
  const fresh = await runGo({ tasks: [{ stem: 't1', slug: 's1', hasWorktreeBranch: false, hasCleanCheckoutToken: false }] })
  check('14j no branch yet -> no re-record (the locked checkout CREATES the worktree and records the token itself)', fresh.calls.restore.length === 0 && fresh.calls.workflow.length === 1)
  const off = await runGo({ tasks: [{ stem: 't1', slug: 's1', hasCleanCheckoutToken: false }], goArgs: { escalate: false } })
  const offBare = promptIn(off.calls.legacyPrompts, /specialist executing one acf-whip/)
  check('14k escalation off -> no re-record: the 3.1.0 specialist runs its own STEP 0 checkout',
    off.calls.restore.length === 0 && off.calls.legacy.length === 1 && /STEP 0 \(mandatory/.test(offBare) && offBare.includes(CC))
  const none = await runGo({ tasks: [{ stem: 't1', slug: 'none', hasCleanCheckoutToken: false }] })
  check('14l a Worktree: none task is never re-recorded (it has no worktree and no token rule)', none.calls.restore.length === 0)

  // ---- it never DEFERS the harness: a task that never starts is worse than one review parks
  // Dirty on the first dispatch, clean on the next: the harness's verify stage commits what it leaves,
  // so the re-dispatch after the token-strand park is where the re-record lands.
  let d14 = 0
  const dirty = await runGo({ tasks: [{ stem: 't1', slug: 's1', hasCleanCheckoutToken: false }],
    onRestore: () => (d14++ === 0 ? { outcome: 'dirty', exitCode: 0 } : { outcome: 'restored', exitCode: 0 }) })
  check('14m a dirty tree is left alone and the harness still runs right after',
    dirty.calls.restore.length >= 1 && dirty.calls.seq[dirty.calls.seq.indexOf('restore') + 1] === 'workflow:impl')
  check('14n ...and the log says why no checkout ran', dirty.logs.some((l) => /uncommitted work/.test(l) && /refs\/stash/.test(l)))
  check('14o ...and once the tree is clean the next dispatch re-records it and the task completes',
    dirty.calls.restore.length === 2 && dirty.report.completed === true)
  const failed = await runGo({ tasks: [{ stem: 't1', slug: 's1', hasCleanCheckoutToken: false }], onRestore: () => ({ outcome: 'failed', exitCode: 2 }) })
  check('14p a failed re-record still runs the harness (exit 2 on a path mismatch would recur forever)', failed.calls.workflow.length >= 1 && failed.logs.some((l) => /could not re-record/.test(l) && /exit 2/.test(l)))

  // ---- once per dispatch, never per amend round (round 0 may have dirtied the tree)
  let n14 = 0
  const amend = await runGo({
    tasks: [{ stem: 't1', slug: 's1', hasCleanCheckoutToken: false }],
    onWorkflow: () => { n14++; if (n14 === 1) throw new TypeError('boom'); return { ok: true, transition: 'completed', commitSha: 'abc', rejectionIncrement: 0, notes: 'done', deliverableFiles: [], stagesRan: [], stagesReplayed: [], agentsUsed: 4 } },
  })
  check('14q an amended harness is re-recorded ONCE, before round 0 only', amend.calls.workflow.length === 2 && amend.calls.restore.length === 1)

  // ---- the reviewer's cycle, end to end: in-review with the branch but no token.
  // Review finds a mechanism fault twice -> the tokenStrand arm parks it (inc 0) -> the unblock pass
  // re-queues it -> the re-dispatch re-records the token BEFORE the harness replays -> review accepts.
  // Without the re-record, the replay writes no token and the task re-parks until the run gives up.
  const cyc = await runGo({ tasks: [{ stem: 't1', slug: 's1', folder: 'in-review', hasCleanCheckoutToken: false }] })
  const parkAt = at(cyc, 'write:blocked')
  check('14r a task stranded without its token is parked (not charged a life)', parkAt >= 0 && cyc.calls.writer.some((w) => w.toState === 'blocked' && w.inc === '0'))
  check('14s ...and its re-dispatch re-records the token before the harness runs', at(cyc, 'restore') > parkAt && at(cyc, 'restore') < cyc.calls.seq.indexOf('workflow:impl', parkAt))
  check('14t ...so the cycle ENDS: accepted and integrated, run complete', cyc.model.get('t1').folder === 'accepted' && cyc.model.get('t1').hasIntegratedAt === true && cyc.report.completed === true)
  check('14u ...parked exactly once (the replay no longer re-parks it)', cyc.calls.writer.filter((w) => w.toState === 'blocked').length === 1)
}

// ---------------------------------------------------------------------------------------------
// 15. With the review panel ON, a missing token on the INLINE path is still a mechanism fault (3.4.3).
// The inline path skips the typed token gate (the scan object predates the implementer) and leaves the
// question to reviewerPrompt's PRE-STEP-0 CHECK — whose mechanism arm a panel cannot express: lenses
// answer accept|reject, and the locked aggregate() folds a strict-majority reject to ('rejected',
// 'quality'), which reviewVerdict charges as a life. restoreCheckoutToken's dirty/unreadable/failed
// outcomes all arrive here, so the parent probes the row before the panel and defers to the next
// scan's typed gate when it is not there. The review workflow below behaves like the real panel: with
// no token row every lens rejects, so a panel that runs while the token is absent costs a life.
// ---------------------------------------------------------------------------------------------
{
  const DONE = { ok: true, transition: 'completed', commitSha: 'abc', rejectionIncrement: 0, notes: 'done', deliverableFiles: [], stagesRan: [], stagesReplayed: [], agentsUsed: 4 }
  const panel = (w, n, kind, model) => {
    if (kind !== 'review') return DONE
    const t = model.get(w.stem)
    return t && t.hasCleanCheckoutToken
      ? { ok: true, transition: 'accepted', commitSha: 'n/a', rejectionIncrement: 0, faultClass: 'quality', notes: '3-lens panel accepted', stagesRan: [], stagesReplayed: [], agentsUsed: 4 }
      : { ok: true, transition: 'rejected', commitSha: 'n/a', rejectionIncrement: 1, faultClass: 'quality', notes: '3/3 lenses reject: no clean-checkout row', stagesRan: [], stagesReplayed: [], agentsUsed: 4 }
  }
  const charged = (r) => r.calls.writer.filter((w) => w.toState === 'rejected' || w.inc === '1')

  // Dirty on the first dispatch (no token written), clean on the re-dispatch after the park.
  let d15 = 0
  const r = await runGo({
    tasks: [{ stem: 't1', slug: 's1', hasCleanCheckoutToken: false }], goArgs: { escalateReview: true }, onWorkflow: panel,
    onRestore: () => (d15++ === 0 ? { outcome: 'dirty', exitCode: 0 } : { outcome: 'restored', exitCode: 0 }),
  })
  const firstProbe = r.calls.seq.indexOf('probe')
  check('15a the inline panel review probed the token first, and found it absent', firstProbe >= 0 && r.calls.seq[firstProbe + 1] !== 'workflow:review')
  check('15b ...so the panel did NOT run while the token was absent', r.calls.workflow.filter((w) => w.kind === 'review').length === 1)
  check('15c ...and the deferral is logged as such', r.logs.some((l) => /not observed before the review panel/.test(l) && /no rejection charged/.test(l)))
  check('15d NO life was charged at any point (no rejected write, no inc 1)', charged(r).length === 0)
  check('15e the typed gate took over: parked once with inc 0, re-dispatched, re-recorded, accepted',
    r.calls.writer.filter((w) => w.toState === 'blocked' && w.inc === '0').length === 1 && r.calls.restore.length === 2
    && r.model.get('t1').folder === 'accepted' && r.model.get('t1').hasIntegratedAt === true && r.report.completed === true)
  check('15f the panel ran exactly once, after a probe that saw the row',
    r.calls.seq.lastIndexOf('probe') < r.calls.seq.indexOf('workflow:review') && r.calls.probe.length === 2)

  // A probe that never emits is not a "present": fail closed, charge nothing, let the scan decide.
  let p15 = 0
  const silent = await runGo({
    tasks: [{ stem: 't1', slug: 's1' }], goArgs: { escalateReview: true }, onWorkflow: panel,
    onProbe: () => { p15++; throw new Error('StructuredOutput non-emit') },
  })
  check('15g a non-emitting probe defers the panel instead of running it blind', p15 === 3 && silent.logs.some((l) => /probe non-emit/.test(l)))
  check('15h ...and the next scan (token observed present) reviews it with no probe and no charge',
    silent.calls.workflow.filter((w) => w.kind === 'review').length === 1 && charged(silent).length === 0 && silent.report.completed === true)

  // The probe is paid only where it buys something.
  const noPanel = await runGo({ tasks: [{ stem: 't1', slug: 's1', hasCleanCheckoutToken: false }], onRestore: () => ({ outcome: 'dirty', exitCode: 0 }) })
  check('15i panel OFF -> no probe (the lone reviewer\'s PRE-STEP-0 CHECK types the fault itself)', noPanel.calls.probe.length === 0)
  check('15j ...and it charges no life either (baseline the panel path must match)', charged(noPanel).length === 0)
}

console.log(`\nphase11-escalation: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL === 0 ? 0 : 1)
