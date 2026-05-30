export const meta = {
  name: 'whip-go',
  description: 'Continuous backlog orchestrator. The loop, the slug partition, the dependency gate, the topological integration order, and the stall/terminal bookkeeping all live in this script (not in Claude\'s context). Agents do every filesystem/git operation: a read-only scanner, a single sequential writer, parallel specialists/reviewers isolated by acf-whip worktree slugs, and a sequential integrator with hoisted conflict-resolver dispatch.',
  whenToUse: 'Launched by the acf-whip /go skill when dynamic workflows are available. Replaces the Claude-as-orchestrator markdown loop so context stays flat across iterations.',
  phases: [
    { title: 'Bootstrap', detail: 'detached-HEAD refusal + doctor --fix hard gate' },
    { title: 'Iterate', detail: 'scan → plan (pure JS) → pre-move → execute (parallel) → post-move → integrate (sequential)' },
    { title: 'Drain', detail: 'defensive final integration pass (default mode)' },
  ],
}

// ============================ args ============================
const pluginRoot = (args && args.pluginRoot) || ''
const trunkRoot = (args && args.trunkRoot) || ''
const trunkBranch = (args && args.trunkBranch) || ''
const mode = (args && args.mode === 'override') ? 'override' : 'default'
if (!pluginRoot || !trunkRoot) {
  return { error: 'whip-go.workflow.js requires args.pluginRoot and args.trunkRoot', got: { pluginRoot, trunkRoot } }
}

// ============================ shell + bin paths ============================
const sq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`
const ENV = `export ACFW_TRUNK_ROOT=${sq(trunkRoot)}; export ACFW_TRUNK_BRANCH=${sq(trunkBranch)};`
const SCAN = `${pluginRoot}/skills/go/bin/scan-backlog.sh`
const APPLY = `${pluginRoot}/skills/go/bin/apply-transition.sh`
const DOCTOR = `${pluginRoot}/skills/whip-doctor/bin/doctor.sh`
const INTEGRATE = `${pluginRoot}/skills/integrate-worktree/bin/integrate-worktree.sh`
const CLEAN_CHECKOUT = `${pluginRoot}/skills/clean-checkout-before-task/bin/clean-checkout.sh`

// IMPORTANT (isolation): acf-whip provides its OWN per-task isolation via git worktrees
// (.worktree/<slug>, created by clean-checkout.sh). Agents always operate against the REAL trunk
// via ACFW_TRUNK_ROOT (absolute paths), so we do NOT use the runtime's isolation:'worktree' — that
// would put the agent in a throwaway worktree while clean-checkout still resolved .worktree/<slug>
// off ACFW_TRUNK_ROOT, making the runtime worktree pointless overhead. Parallel safety comes from
// distinct slugs (distinct .worktree/<slug> dirs + branches) and git index-lock backoff.

const MAX_ITER = 1000
const NO_GAIN_LIMIT = 15 // iterations with no terminal gain (perpetual-retry guard); well below MAX_ITER

// <scheduler-pure> ===========================================================================
// Everything between these markers is PURE (no agent/parallel/phase/log/clock, no closures except
// the module-level `mode`). tests/phase2-scheduler.test.mjs extracts this block verbatim, injects
// `mode`, and unit-tests it — so the scheduling/terminal logic (the part the 2.0.x migration broke)
// is exercised without the Workflow runtime. Keep it pure; if you add a side effect here, the test
// extraction breaks loudly.
const MAX_REJECT_RETRY = 3 // rejected with count < this -> retry (rejected->pending); >= this -> blocked
const DEFAULT_TIMEOUT_H = 8 // in-progress -> blocked fallback when the snapshot omits inProgressTimeoutHours
const PRIORITY_RANK = { blocker: 0, critical: 1, high: 2, medium: 3, low: 4 }
const prank = (p) => (p in PRIORITY_RANK ? PRIORITY_RANK[p] : 5)
const byPriorityThenStem = (a, b) => (prank(a.priority) - prank(b.priority)) || (a.stem < b.stem ? -1 : a.stem > b.stem ? 1 : 0)

// ============================ schemas ============================
const BOOTSTRAP = {
  type: 'object', additionalProperties: false,
  required: ['detached', 'doctorOk', 'doctorSummary', 'fatals'],
  properties: {
    detached: { type: 'boolean', description: 'true if HEAD is detached at the trunk root' },
    doctorOk: { type: 'boolean', description: 'true if doctor reported ok=true after --fix' },
    doctorSummary: { type: 'string', description: 'verbatim SUMMARY|... line from the report-only doctor run' },
    fatals: { type: 'array', items: { type: 'string' }, description: 'verbatim FATAL|... lines remaining after --fix' },
  },
}
const SCAN_RESULT = {
  type: 'object', additionalProperties: false,
  required: ['snapshotJson', 'doctorOk', 'doctorSummary', 'doctorFatals'],
  properties: {
    snapshotJson: { type: 'string', description: 'the VERBATIM stdout of scan-backlog.sh — a single JSON object, copied exactly, nothing added' },
    doctorOk: { type: 'boolean' },
    doctorSummary: { type: 'string', description: 'verbatim SUMMARY|... line' },
    doctorFatals: { type: 'array', items: { type: 'string' }, description: 'verbatim FATAL|... lines' },
  },
}
const WRITE_BATCH = {
  type: 'object', additionalProperties: false,
  required: ['applied', 'note'],
  properties: {
    applied: { type: 'array', items: { type: 'string' }, description: 'one line per apply-transition.sh call: its stdout (ok:/noop:) or an error note' },
    note: { type: 'string' },
  },
}
const ACFW_RESULT = {
  type: 'object', additionalProperties: false,
  required: ['transition', 'commitSha', 'rejectionIncrement', 'notes'],
  properties: {
    transition: { type: 'string', enum: ['completed', 'blocked', 'accepted', 'rejected', 'none'], description: 'the transition from your ACFW-RESULT marker; "none" if you could not complete (transient — orchestrator retries next iteration)' },
    commitSha: { type: 'string', description: 'commit sha on worktree/<slug>, or "n/a"' },
    rejectionIncrement: { type: 'integer', enum: [0, 1] },
    notes: { type: 'string', description: 'one-line reason' },
  },
}
const INTEGRATE_RESULT = {
  type: 'object', additionalProperties: false,
  required: ['exitCode', 'outcome', 'note', 'resolverWorktree', 'resolverBranch', 'resolverAgent', 'resolverConflictedFiles', 'resolverConflictingCommits'],
  properties: {
    exitCode: { type: 'integer', description: 'the integrate-worktree.sh exit code (0,4,6,7,10,99,...)' },
    outcome: { type: 'string', enum: ['integrated', 'resolver-needed', 'rejected', 'transient', 'skipped', 'error'] },
    note: { type: 'string' },
    resolverWorktree: { type: 'string', description: 'from the resolver-needed block "worktree:" line, else ""' },
    resolverBranch: { type: 'string', description: 'from "branch:", else ""' },
    resolverAgent: { type: 'string', description: 'from "assigned_agent:", else ""' },
    resolverConflictedFiles: { type: 'string', description: 'the conflicted_files block, newline-joined, else ""' },
    resolverConflictingCommits: { type: 'string', description: 'the conflicting_commits block, newline-joined, else ""' },
  },
}

// ============================ pure-JS scheduling helpers ============================
function indexTasks(tasks) {
  const byId = new Map(), byStem = new Map()
  for (const t of tasks) { if (t.id) byId.set(t.id, t); if (t.stem) byStem.set(t.stem, t) }
  const resolve = (tok) => {
    if (byId.has(tok)) return byId.get(tok)
    if (byStem.has(tok)) return byStem.get(tok)
    for (const [stem, t] of byStem) if (stem.indexOf(tok) === 0) return t // prefix match (mirrors doctor)
    return null
  }
  return { byId, byStem, resolve }
}
function isTerminal(t) {
  if (t.folder === 'blocked') return true
  if (t.folder === 'accepted') {
    if (mode === 'override') return true
    // default (auto-merge): terminal when integrated, or when there's nothing to integrate —
    // a non-code slug ("none"), or a historical/pre-2.0.0 task with no worktree branch (already
    // on trunk the old way; a phantom branch can never be fetched, so it's as done as it gets).
    return t.hasIntegratedAt || t.slug === 'none' || !t.hasWorktreeBranch
  }
  return false
}
function depsSatisfied(t, idx) {
  for (const depTok of (t.deps || [])) {
    const dep = idx.resolve(depTok)
    if (!dep) return false // dangling — doctor would FATAL; be conservative
    if (dep.folder !== 'accepted') return false
    // A cross-slug code dep blocks only while it is genuinely pending integration: accepted, has a
    // live worktree branch, and not yet integrated. A branchless historical dep is already on trunk
    // -> satisfied (mirrors isTerminal + the doctor's branch-aware cross-slug-dep check).
    const crossSlug = dep.slug !== t.slug // includes dep.slug === 'none'
    if (mode === 'default' && crossSlug && dep.slug !== 'none' && dep.hasWorktreeBranch && !dep.hasIntegratedAt) return false
  }
  return true
}

// Topological order (Kahn) over cross-slug dependency edges among the integration candidates,
// so each cross-slug dependency integrates before its dependent. Falls back to input order on cycle
// (doctor would already FATAL on a real cycle).
function topoIntegrationOrder(candidates, idx, onCycle) {
  const set = new Set(candidates.map((t) => t.stem))
  const indeg = new Map(candidates.map((t) => [t.stem, 0]))
  const adj = new Map(candidates.map((t) => [t.stem, []]))
  for (const t of candidates) {
    for (const depTok of (t.deps || [])) {
      const dep = idx.resolve(depTok)
      if (!dep || !set.has(dep.stem)) continue
      if (dep.slug === t.slug) continue // same-slug order is implicit in the branch
      adj.get(dep.stem).push(t.stem)
      indeg.set(t.stem, indeg.get(t.stem) + 1)
    }
  }
  const q = candidates.filter((t) => indeg.get(t.stem) === 0).sort(byPriorityThenStem).map((t) => t.stem)
  const order = []
  const byStem = new Map(candidates.map((t) => [t.stem, t]))
  while (q.length) {
    const s = q.shift(); order.push(s)
    for (const n of adj.get(s)) { indeg.set(n, indeg.get(n) - 1); if (indeg.get(n) === 0) q.push(n) }
  }
  if (order.length < candidates.length) { if (onCycle) onCycle(); return candidates.slice() } // cycle guard: keep all, input order
  return order.map((s) => byStem.get(s))
}

// The two transitions the 2.0.x workflow migration dropped (the legacy markdown loop performed them
// via task-engineer; see go/SKILL.md Step 3.B/3.E and content/backlog/workflow.md). PURE: returns
// the single-writer actions plus the in-progress tasks that are still FRESH (must be re-dispatched,
// NOT timed out this iteration). Both moves land in the pre-move batch, so the moved task dispatches
// on the NEXT scan (same timing as the rejected->pending self-heal).
function planUnblockAndTimeout(tasks, idx, opts) {
  const o = opts || {}
  const maxReject = (o.maxReject != null) ? o.maxReject : MAX_REJECT_RETRY
  const timeoutH = (o.timeoutH != null) ? o.timeoutH : DEFAULT_TIMEOUT_H
  const root = o.trunkRoot || ''
  const mk = (t, from, toState, notes) => ({ path: `${root}/.backlog/${from}/${t.stem}.md`, toState, agent: 'orchestrator', notes, inc: 0 })

  // blocked -> pending: deps now satisfied AND not a max-rejection "redesign" block (count >= cap).
  // A specialist-blocked or dep-blocked task re-runs once its deps land; a 3x-rejected task is left
  // for a human (re-dispatching it just re-rejects). depsSatisfied is the same gate pending uses.
  const unblockActions = tasks
    .filter((t) => t.folder === 'blocked')
    .sort(byPriorityThenStem)
    .filter((t) => (t.rejectionCount || 0) < maxReject && depsSatisfied(t, idx))
    .map((t) => mk(t, 'blocked', 'pending', 'dependencies resolved — unblocked'))

  // in-progress -> blocked: stale past the operator timeout (ageHours is computed by scan-backlog;
  // a negative ageHours means "unknown timestamp" and never times out). A timed-out task must be
  // excluded from the re-dispatch set, so the caller uses `freshInProgress` to build specialistQ.
  const stale = tasks
    .filter((t) => t.folder === 'in-progress' && t.ageHours >= 0 && t.ageHours >= timeoutH)
    .sort(byPriorityThenStem)
  const timeoutActions = stale.map((t) => mk(t, 'in-progress', 'blocked', `timeout >=${timeoutH}h — stale dispatch`))
  const staleStems = new Set(stale.map((t) => t.stem))
  const freshInProgress = tasks.filter((t) => t.folder === 'in-progress' && !staleStems.has(t.stem))

  return { unblockActions, timeoutActions, freshInProgress }
}
// </scheduler-pure> ==========================================================================

// ============================ agent prompt builders ============================
const NO_BACKLOG_WRITES = 'Do code work ONLY inside the worktree. Do NOT move task files between .backlog/ folders and do NOT commit any .backlog/ change — the orchestrator is the single writer of .backlog/.'

function specialistPrompt(t) {
  const rootPath = `${trunkRoot}/.backlog/in-progress/${t.stem}.md`
  return `${ENV}
You are the ${t.agent || 'assigned'} specialist executing one acf-whip backlog task.

STEP 0 (mandatory concurrency primitive): run
  bash ${sq(CLEAN_CHECKOUT)} ${sq(rootPath)}
Its stdout is the absolute worktree path (branch worktree/${t.slug}). If it exits non-zero, do NOT proceed: return transition "none" with the exit code in notes (the orchestrator retries next iteration).

Then: read the task at ${sq(rootPath)} (the ROOT path — read it there). Do the implementation INSIDE the worktree printed by Step 0, on branch worktree/${t.slug}. Run the project's quality gates. Commit your CODE to the worktree branch. Write evidence-of-completion back into the ROOT task file at ${sq(rootPath)} (append to its sections), then end your response with the ACFW-RESULT marker:
  ACFW-RESULT:
    transition: completed | blocked
    commit_sha: <sha on worktree/${t.slug}, or n/a>
    rejection_increment: 0
    notes: <one line>
Use transition "completed" when the work is done and quality gates pass; "blocked" if you hit an unresolvable blocker. ${NO_BACKLOG_WRITES}

Finally return the structured ACFWResult matching your marker (transition, commitSha, rejectionIncrement 0, notes).`
}

function reviewerPrompt(t) {
  const rootPath = `${trunkRoot}/.backlog/in-review/${t.stem}.md`
  return `${ENV}
You are quality-reviewer reviewing one acf-whip task that an implementer marked completed.

STEP 0: run  bash ${sq(CLEAN_CHECKOUT)} ${sq(rootPath)}  to attach to the task's worktree (branch worktree/${t.slug}) and validate it. If it exits non-zero, return transition "none" with the exit code in notes.

Then review the implementation against the task's Acceptance Criteria and quality gates, working in the worktree.
AUTO-REJECT rule: if the task's Transition Log lacks a "| clean-checkout | ok |" token, reject.
Write your review comments into the ROOT task file at ${sq(rootPath)}, then end with the ACFW-RESULT marker:
  ACFW-RESULT:
    transition: accepted | rejected
    commit_sha: n/a
    rejection_increment: <0 if accepted, 1 if rejected>
    notes: <specific feedback>
${NO_BACKLOG_WRITES}

Return the structured ACFWResult matching your marker.`
}

function directReviewPrompt(t) {
  const rootPath = `${trunkRoot}/.backlog/in-review/${t.stem}.md`
  return `${ENV}
You are quality-reviewer reviewing one NON-CODE acf-whip task (Worktree: none — NO worktree, do NOT run clean-checkout, and do NOT apply the "missing clean-checkout token" auto-reject rule; non-code tasks have no worktree).

Read the task and its deliverable at ${sq(rootPath)} and review it against the task's Acceptance Criteria. Write your review comments into that ROOT file, then end with the ACFW-RESULT marker:
  ACFW-RESULT:
    transition: accepted | rejected
    commit_sha: n/a
    rejection_increment: <0 if accepted, 1 if rejected>
    notes: <specific feedback>
${NO_BACKLOG_WRITES}

Return the structured ACFWResult matching your marker.`
}

function directPrompt(t) {
  const rootPath = `${trunkRoot}/.backlog/in-progress/${t.stem}.md`
  return `${ENV}
You are the ${t.agent || 'assigned'} agent executing one NON-CODE acf-whip task (Worktree: none — research/docs-only, NO worktree, do NOT run clean-checkout).

Read the task at ${sq(rootPath)}, do the work, and write the deliverable/evidence directly into that ROOT task file. Do NOT create a worktree, do NOT move the file between .backlog/ folders, do NOT commit .backlog/ — the orchestrator is the single writer. End your response with the ACFW-RESULT marker:
  ACFW-RESULT:
    transition: completed | blocked
    commit_sha: n/a
    rejection_increment: 0
    notes: <one line>

Return the structured ACFWResult matching your marker.`
}

function integratePrompt(t, postResolver) {
  const acceptedPath = `${trunkRoot}/.backlog/accepted/${t.stem}.md`
  const cmd = postResolver
    ? `bash ${sq(INTEGRATE)} --post-resolver ${sq(acceptedPath)}`
    : `bash ${sq(INTEGRATE)} ${sq(acceptedPath)}`
  return `${ENV}
Run the acf-whip integrator for one accepted task and report its result. Run EXACTLY:
  ${cmd}
Capture the exit code and stdout. Map exit code -> outcome:
  0  -> integrated      (folded into trunk; Integrated-At written)
  4  -> skipped         (no worktree/<slug> branch — historical/pre-2.0.0 task already on trunk; nothing to integrate, do NOT retry)
  6  -> rejected        (conflict unresolved; task moved to rejected/)
  7  -> resolver-needed  (rebase conflict; stdout carries a "ACFW-INTEGRATE: resolver-needed" block — DO NOT touch the worktree, just parse and report)
  10 -> transient        (anti-orphan guard; leave accepted, retry later)
  99 -> transient        (git lock contention)
  other -> error
If and ONLY if exit code is 7, parse the resolver-needed stdout block and fill: resolverWorktree (the "worktree:" line value), resolverBranch ("branch:"), resolverAgent ("assigned_agent:" — may be empty), resolverConflictedFiles (the lines under "conflicted_files:", newline-joined), resolverConflictingCommits (the lines under "conflicting_commits:", newline-joined). Otherwise set those five to "".
Return the structured IntegrateResult. Do NOT dispatch a resolver yourself; the orchestrator does that.`
}

function resolverPrompt(t, r) {
  return `${ENV}
You are the conflict resolver (${r.resolverAgent || t.agent || 'assigned specialist'}) for an acf-whip integration.
The worktree at ${sq(r.resolverWorktree)} (branch ${r.resolverBranch}) is MID-REBASE onto trunk with conflicts. Do NOT abort the rebase unless the conflict is irreconcilable.

Conflicted files:
${r.resolverConflictedFiles || '(none reported)'}

Resolve every conflict preserving BOTH intents, run the project's quality gates inside the worktree, then:
  - if resolved cleanly:  git -C ${sq(r.resolverWorktree)} rebase --continue   (continue until the rebase finishes)
  - if irreconcilable:    git -C ${sq(r.resolverWorktree)} rebase --abort   AND append a line "| <date> | FATAL: <reason> |" to the task file ${sq(`${trunkRoot}/.backlog/accepted/${t.stem}.md`)}
Do NOT move task files and do NOT commit .backlog/. When done, report what you did in one line.`
}

// One sequential writer call. actions: [{ path, toState, agent, notes, inc }].
async function applyTransitions(actions, label) {
  if (!actions.length) return { applied: [], note: 'nothing to do' }
  const lines = actions.map((a) =>
    `  bash ${sq(APPLY)} ${sq(a.path)} ${sq(a.toState)} ${sq(a.agent || 'orchestrator')} ${sq(a.notes || '')} ${sq(String(a.inc || 0))}`,
  ).join('\n')
  return agent(
    `${ENV}
You are the SINGLE backlog writer. Run these apply-transition.sh calls IN ORDER, one at a time (never in parallel). Each moves one task file between .backlog/ folders, appends a transition-log row, and commits on trunk. apply-transition.sh is idempotent (no-ops if the file is already in the target folder), so re-running is safe.

${lines}

Capture each call's stdout (an "ok:" or "noop:" line) into applied[]. If any call errors, record it in applied[] and continue with the rest. Return the WriteResult.`,
    { label, phase: 'Iterate', schema: WRITE_BATCH },
  )
}

// ============================ BOOTSTRAP (hard gate) ============================
phase('Bootstrap')
const boot = await agent(
  `${ENV}
Bootstrap the acf-whip orchestrator at trunk root ${sq(trunkRoot)}.
1. Detached HEAD check: run  git -C ${sq(trunkRoot)} symbolic-ref --quiet HEAD  — if it FAILS, set detached true and stop (do not run the doctor).
2. If a branch is checked out: apply repairable integrity issues, then re-scan:
     bash ${sq(DOCTOR)} --fix ${sq(trunkRoot)} >/dev/null 2>&1 || true
     bash ${sq(DOCTOR)} --quiet ${sq(trunkRoot)}
   From the second run capture: doctorOk (SUMMARY ok=true), doctorSummary (the verbatim SUMMARY line), fatals (verbatim FATAL| lines).
Return the BootstrapResult.`,
  { label: 'bootstrap', phase: 'Bootstrap', schema: BOOTSTRAP },
)
if (boot.detached) {
  return { aborted: true, reason: 'detached HEAD at trunk root; /go requires a branch checked out at the repo root', mode }
}
if (!boot.doctorOk) {
  return { aborted: true, reason: 'backlog integrity gate failed; will not dispatch against an inconsistent backlog', mode, doctorSummary: boot.doctorSummary, fatals: boot.fatals }
}
log(`bootstrap ok — ${boot.doctorSummary}`)

// ============================ ITERATE ============================
phase('Iterate')
let iter = 0
let idle = 0 // consecutive iterations doing NO work (genuinely stuck: unsatisfiable deps) — break at 3
let noGain = 0 // consecutive iterations with no terminal gain (perpetual futile retry) — break at NO_GAIN_LIMIT
let prevTerminal = -1
const integratedStems = []
const rejectedStems = []
let lastSnapshot = null
let stopReason = 'max-iterations'

while (iter < MAX_ITER) {
  iter++

  // ---- scan (read-only) + doctor-lite + heartbeat ----
  const scanPrompt = `${ENV}
Iteration ${iter} of the acf-whip orchestrator. Do three things and return the result:
1. Read-only snapshot:  bash ${sq(SCAN)} ${sq(trunkRoot)}  — its stdout is a single JSON object. Put that stdout VERBATIM (copy it exactly, add nothing) into snapshotJson.
2. Integrity recheck (report-only):  bash ${sq(DOCTOR)} --quiet ${sq(trunkRoot)}  — set doctorOk (SUMMARY ok=true), doctorSummary (verbatim SUMMARY line), doctorFatals (verbatim FATAL| lines).
3. Heartbeat (best-effort, NOT committed): write a small JSON file at ${sq(`${trunkRoot}/.backlog/.acfw-run.json`)} containing {"iteration":${iter},"mode":"${mode}","ts":"<output of: date -u +%Y-%m-%dT%H:%M:%SZ>"}. If the write fails, ignore it.
Return the ScanResult.`
  let scan = await agent(scanPrompt, { label: `scan#${iter}`, phase: 'Iterate', schema: SCAN_RESULT })

  // mid-run FATAL introduced (e.g. a cycle from a retry, a half-applied transition) -> abort before dispatch
  if (!scan.doctorOk) {
    stopReason = 'integrity-fatal-midrun'
    return { aborted: true, reason: 'integrity FATAL detected mid-run; aborting before dispatch', mode, iteration: iter, doctorSummary: scan.doctorSummary, fatals: scan.doctorFatals }
  }

  let snap
  try { snap = JSON.parse(scan.snapshotJson) } catch (e) {
    // One re-scan before giving up: the snapshot is relayed by an agent echoing scan-backlog's stdout
    // verbatim, so a single garbled/truncated echo should not abort a long run. Re-run once; if it is
    // still unparseable, the snapshot is genuinely malformed -> abort.
    log(`iter ${iter}: snapshot JSON unparseable — re-scanning once`)
    scan = await agent(scanPrompt, { label: `scan#${iter}:retry`, phase: 'Iterate', schema: SCAN_RESULT })
    if (!scan.doctorOk) {
      stopReason = 'integrity-fatal-midrun'
      return { aborted: true, reason: 'integrity FATAL detected mid-run (on scan retry); aborting before dispatch', mode, iteration: iter, doctorSummary: scan.doctorSummary, fatals: scan.doctorFatals }
    }
    try { snap = JSON.parse(scan.snapshotJson) } catch (e2) {
      stopReason = 'snapshot-parse-error'
      return { aborted: true, reason: 'could not parse backlog snapshot JSON after one retry', mode, iteration: iter, raw: (scan.snapshotJson || '').slice(0, 400) }
    }
  }
  lastSnapshot = snap
  const tasks = snap.tasks || []
  const idx = indexTasks(tasks)

  // ---- terminal + stall (computed from scan-backlog's COUNTS, not tasks[]) ----
  // tasks[] is now the bounded WORKING SET (scan-backlog collapses terminal/historical accepted into
  // counts so the snapshot stays small enough for the agent to echo reliably). So completion is
  // measured over counts.total — which is already ACTIVE-only (draft/ and archive/ are excluded at
  // the scanner) — against the runtime-terminal count, which mirrors isTerminal exactly.
  // No silent fallback: a snapshot missing these counts means scan/workflow version skew; counting
  // isTerminal over the collapsed working set would UNDERcount and stall forever as 'no-progress'
  // instead of 'complete'. Abort loudly instead.
  if (snap.counts.runtimeTerminalDefault == null || snap.counts.runtimeTerminalOverride == null) {
    stopReason = 'snapshot-version-skew'
    return { aborted: true, reason: 'backlog snapshot is missing runtimeTerminal counts — scan-backlog.sh / workflow version skew; reinstall acf-whip so both are 2.0.2+', mode, iteration: iter }
  }
  const total = snap.counts.total
  const terminal = mode === 'override' ? snap.counts.runtimeTerminalOverride : snap.counts.runtimeTerminalDefault
  log(`iter ${iter}: ${terminal}/${total} active terminal (integrated=${snap.counts.integrated}, accepted=${snap.counts.accepted}, blocked=${snap.counts.blocked}, workingSet=${tasks.length})`)
  if (total > 0 && terminal === total) { stopReason = 'complete'; break }

  // ---- plan (pure JS): partition by slug, gate deps, build queues ----
  // PARALLELISM INVARIANT (default): every non-conflicting ready unit dispatches CONCURRENTLY.
  // The slug is the partition — one agent per distinct ready slug runs in parallel below
  // (parallel(dispatch...)); only same-slug work (shared file surface) and unmet deps serialize.
  // Nothing here may serialize work that a distinct slug + satisfied deps would let run in parallel.
  const codeSlug = (t) => t.slug && t.slug !== 'none'
  const seen = new Set()
  // One agent per code slug per iteration. Reviewers claim first, then in-progress (re-dispatch
  // recovery), then pending — so a same-slug pending sibling is blocked by `seen` while the
  // in-progress task itself re-dispatches exactly once. (A task sitting in in-progress at plan time
  // is always a finished/failed prior dispatch — parallel() is a barrier, so nothing is still running.)
  const claim = (slug) => { if (!codeSlug({ slug })) return true; if (seen.has(slug)) return false; seen.add(slug); return true }

  const reviewQ = []      // {t, premove} — needs a quality-reviewer (worktree)
  const specialistQ = []  // {t, premove} — needs a specialist (worktree)
  const directQ = []      // {t, premove} — non-code (slug none), no worktree
  const warnings = []

  // blocked->pending (deps resolved) + in-progress->blocked (stale) — see planUnblockAndTimeout.
  // These land in the pre-move batch; the moved task dispatches next scan. freshInProgress excludes
  // any task we just timed out so it is not re-dispatched in the same iteration.
  const { unblockActions, timeoutActions, freshInProgress } = planUnblockAndTimeout(tasks, idx, {
    timeoutH: (snap.inProgressTimeoutHours != null ? snap.inProgressTimeoutHours : DEFAULT_TIMEOUT_H),
    maxReject: MAX_REJECT_RETRY,
    trunkRoot,
  })

  // reviewers first: completed (premove -> in-review) and lingering in-review (re-review). They claim the slug.
  const inReview = tasks.filter((t) => t.folder === 'in-review').sort(byPriorityThenStem)
  const completed = tasks.filter((t) => t.folder === 'completed').sort(byPriorityThenStem)
  for (const t of [...inReview, ...completed]) {
    if (codeSlug(t) && !claim(t.slug)) continue
    reviewQ.push({ t, premove: t.folder === 'completed' })
  }

  // then specialists: in-progress (re-dispatch recovery — FRESH only; stale ones were timed out
  // above) and pending (start), one per free slug.
  const pending = tasks.filter((t) => t.folder === 'pending').sort(byPriorityThenStem)
  for (const t of [...freshInProgress.slice().sort(byPriorityThenStem), ...pending]) {
    if (t.slug === 'none') {
      if (t.folder === 'pending' && !depsSatisfied(t, idx)) continue
      directQ.push({ t, premove: t.folder === 'pending' })
      continue
    }
    if (t.slug === '') { warnings.push(`${t.stem}: empty Worktree slug on a code task (FATAL integrity — left pending)`); continue }
    if (!claim(t.slug)) continue
    if (t.folder === 'pending' && !depsSatisfied(t, idx)) { seen.delete(t.slug); continue } // free the slug for a ready sibling
    specialistQ.push({ t, premove: t.folder === 'pending' })
  }

  // rejection self-heal (writer pre-move): rejected with count < bound -> retry (pending); else -> blocked.
  const rejected = tasks.filter((t) => t.folder === 'rejected')
  const rejectActions = rejected.map((t) =>
    (t.rejectionCount < MAX_REJECT_RETRY)
      ? { path: `${trunkRoot}/.backlog/rejected/${t.stem}.md`, toState: 'pending', agent: 'orchestrator', notes: `retry (rejection ${t.rejectionCount}/${MAX_REJECT_RETRY})`, inc: 0 }
      : { path: `${trunkRoot}/.backlog/rejected/${t.stem}.md`, toState: 'blocked', agent: 'orchestrator', notes: `max rejections (${t.rejectionCount}) — blocked for redesign`, inc: 0 },
  )

  if (warnings.length) for (const w of warnings) log(`WARN ${w}`)

  // ---- pre-move (single writer, sequential) ----
  // Unblock + timeout first (they change what is dispatchable next iteration), then dispatch pre-moves.
  const preActions = [
    ...unblockActions,
    ...timeoutActions,
    ...reviewQ.filter((x) => x.premove).map((x) => ({ path: `${trunkRoot}/.backlog/completed/${x.t.stem}.md`, toState: 'in-review', agent: 'orchestrator', notes: 'review-dispatch', inc: 0 })),
    ...specialistQ.filter((x) => x.premove).map((x) => ({ path: `${trunkRoot}/.backlog/pending/${x.t.stem}.md`, toState: 'in-progress', agent: 'orchestrator', notes: 'dispatch', inc: 0 })),
    ...directQ.filter((x) => x.premove).map((x) => ({ path: `${trunkRoot}/.backlog/pending/${x.t.stem}.md`, toState: 'in-progress', agent: 'orchestrator', notes: 'dispatch', inc: 0 })),
    ...rejectActions,
  ]
  if (preActions.length) await applyTransitions(preActions, `premove#${iter}`)

  // ---- execute (parallel; one agent per claimed slug + all direct tasks) ----
  // Build a flat dispatch list; results map back by position.
  const dispatch = [
    ...specialistQ.map((x) => ({ kind: 'specialist', t: x.t, from: 'in-progress' })),
    ...directQ.map((x) => ({ kind: 'direct', t: x.t, from: 'in-progress' })),
    ...reviewQ.map((x) => ({ kind: 'review', t: x.t, from: 'in-review' })),
  ]
  const justAcceptedTasks = [] // tasks accepted THIS iteration -> integrate in the same iteration (legacy timing)
  let productiveDispatch = false // at least one dispatch returned a real (non-'none') transition
  if (dispatch.length) {
    const results = await parallel(dispatch.map((d) => () => {
      const prompt = d.kind === 'review'
        ? (d.t.slug === 'none' ? directReviewPrompt(d.t) : reviewerPrompt(d.t)) // none tasks have no worktree to clean-checkout
        : d.kind === 'direct' ? directPrompt(d.t) : specialistPrompt(d.t)
      const opts = { label: `${d.kind}:${d.t.slug === 'none' ? d.t.stem : d.t.slug}`, phase: 'Iterate', schema: ACFW_RESULT }
      // Reviewers ALWAYS run as quality-reviewer (independent review — never the implementer's agent);
      // specialists/direct run as the task's assigned agent (doctor guarantees a set agent exists).
      const at = d.kind === 'review' ? 'quality-reviewer' : d.t.agent
      if (at && at !== 'none') opts.agentType = at
      return agent(prompt, opts)
    }))

    // ---- post-move (single writer, sequential) — map each ACFW-RESULT to a transition ----
    const postActions = []
    results.forEach((r, i) => {
      if (!r || r.transition === 'none') return // transient: leave task where it is, retry next iteration
      const d = dispatch[i]
      let toState = null
      if (d.from === 'in-progress' && r.transition === 'completed') toState = 'completed'
      else if (d.from === 'in-progress' && r.transition === 'blocked') toState = 'blocked'
      else if (d.from === 'in-review' && r.transition === 'accepted') toState = 'accepted'
      else if (d.from === 'in-review' && r.transition === 'rejected') toState = 'rejected'
      if (!toState) return // mismatched marker -> transient
      if (toState === 'accepted') justAcceptedTasks.push(d.t)
      postActions.push({
        path: `${trunkRoot}/.backlog/${d.from}/${d.t.stem}.md`,
        toState,
        agent: d.t.agent || 'orchestrator',
        notes: (r.notes || '').slice(0, 200),
        inc: (toState === 'rejected' && r.rejectionIncrement === 1) ? 1 : 0,
      })
    })
    productiveDispatch = postActions.length > 0 // a real transition was applied (not just a transient/mismatched marker)
    if (postActions.length) await applyTransitions(postActions, `postmove#${iter}`)
  }

  // ---- integrate (default mode only; sequential, topo order; resolver hoisted) ----
  let integratedThisIter = 0
  if (mode === 'default') {
    const seenC = new Set()
    const candidates = []
    // Only enqueue accepted tasks that have a real worktree branch to fold in. A branchless
    // historical/pre-2.0.0 accepted task is already on trunk (isTerminal treats it terminal) — never
    // enqueue it, or integrate-worktree would fetch a missing ref and retry forever.
    for (const t of [...tasks.filter((t) => t.folder === 'accepted' && codeSlug(t) && !t.hasIntegratedAt && t.hasWorktreeBranch), ...justAcceptedTasks.filter(codeSlug)]) {
      if (seenC.has(t.stem)) continue
      seenC.add(t.stem); candidates.push(t)
    }
    const ordered = topoIntegrationOrder(candidates, idx, () => log('WARN integrate: dependency cycle among integration candidates — using input order; run /whip-doctor'))
    for (const t of ordered) {
      let r = await agent(integratePrompt(t, false), { label: `integrate:${t.slug}`, phase: 'Iterate', schema: INTEGRATE_RESULT })
      if (r && r.outcome === 'resolver-needed') {
        log(`integrate ${t.slug}: conflict — dispatching resolver ${r.resolverAgent || t.agent || '(default)'}`)
        const ropts = { label: `resolve:${t.slug}`, phase: 'Iterate' }
        const ragent = r.resolverAgent || t.agent
        if (ragent && ragent !== 'none') ropts.agentType = ragent
        await agent(resolverPrompt(t, r), ropts)
        r = await agent(integratePrompt(t, true), { label: `integrate:${t.slug}:post`, phase: 'Iterate', schema: INTEGRATE_RESULT })
      }
      if (r && r.outcome === 'integrated') { integratedStems.push(t.stem); integratedThisIter++; log(`✓ integrated ${t.stem}`) }
      else if (r && r.outcome === 'rejected') { rejectedStems.push(t.stem); log(`✗ integrate rejected ${t.stem} — ${r.note}`) }
      else if (r && r.outcome === 'skipped') { log(`↷ skipped ${t.stem} — no worktree branch (historical; terminal)`) }
      // transient/error -> leave accepted, retry next iteration
    }
  }

  // ---- progress accounting (computed from THIS iteration's work) ----
  // didWork drives the idle guard (break at 3). A pre-move (unblock/timeout/dispatch/reject), an
  // integration, or a dispatch that returned a REAL transition all count. A dispatch that returns
  // only 'none' (transient) does NOT — otherwise a task that re-dispatches and keeps failing would
  // hold idle at 0 forever and only the looser noGain guard (15) would catch it.
  const didWork = preActions.length > 0 || integratedThisIter > 0 || productiveDispatch
  idle = didWork ? 0 : idle + 1
  noGain = terminal > prevTerminal ? 0 : noGain + 1
  prevTerminal = terminal
  if (idle >= 3) { stopReason = 'no-progress'; break } // nothing left to do but not complete -> stuck (e.g. unsatisfiable deps)
  if (noGain >= NO_GAIN_LIMIT) { stopReason = 'no-progress'; break } // perpetual futile retry guard
}

// ============================ DRAIN (defensive, default mode) ============================
phase('Drain')
let drained = 0
if (mode === 'default' && lastSnapshot) {
  const rescan = await agent(
    `${ENV}
Final integration drain. Run  bash ${sq(SCAN)} ${sq(trunkRoot)}  and return its stdout VERBATIM in snapshotJson (set doctorOk true, doctorSummary "drain", doctorFatals []).`,
    { label: 'drain:scan', phase: 'Drain', schema: SCAN_RESULT },
  )
  let snap2 = null
  try { snap2 = JSON.parse(rescan.snapshotJson) } catch (e) { snap2 = null }
  if (snap2) {
    const idx2 = indexTasks(snap2.tasks || [])
    const left = topoIntegrationOrder((snap2.tasks || []).filter((t) => t.folder === 'accepted' && t.slug && t.slug !== 'none' && !t.hasIntegratedAt && t.hasWorktreeBranch), idx2)
    for (const t of left) {
      // single defensive pass: an exit-7 here is intentionally left for the next /go run (no resolver post-loop)
      const r = await agent(integratePrompt(t, false), { label: `drain:${t.slug}`, phase: 'Drain', schema: INTEGRATE_RESULT })
      if (r && r.outcome === 'integrated') { integratedStems.push(t.stem); drained++ }
    }
  }
}

// ============================ REPORT ============================
const finalCounts = lastSnapshot ? lastSnapshot.counts : null
return {
  completed: stopReason === 'complete',
  stopReason, // complete | no-progress | max-iterations | (aborts return earlier)
  mode,
  iterations: iter,
  finalCounts,
  integrated: integratedStems,
  rejectedAtIntegration: rejectedStems,
  drainedPostLoop: drained,
  note: stopReason === 'complete'
    ? 'Backlog 100% terminal.'
    : stopReason === 'no-progress'
      ? 'No progress for 3 iterations — user intervention needed (check blocked/ and rejected/).'
      : 'Hit the iteration cap.',
}
