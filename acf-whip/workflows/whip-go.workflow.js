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
// Task-store backend (3.1.0): 'files' (default) keeps every command and prompt byte-identical to
// 3.0.x; any other value routes task state through the acfw-store dispatcher's adapter for that
// backend and swaps the file-path prompt surface for materialized specs (see taskLoc below).
const store = (args && args.store) || 'files'
const filesStore = store === 'files'
// Worktree branch namespace acf-whip owns (<prefix>/<slug>). Defaults to 'worktree'; updated from
// each scan snapshot's branchPrefix so prompt text matches a custom ACFW_BRANCH_PREFIX in .acfw-config.
// Prompts are informational only — the agent always uses the path clean-checkout.sh prints — so a
// stale default here is cosmetic, but keeping it in sync avoids confusing the specialist.
let branchPrefix = (args && args.branchPrefix) || 'worktree'
if (!pluginRoot || !trunkRoot) {
  return { error: 'whip-go.workflow.js requires args.pluginRoot and args.trunkRoot', got: { pluginRoot, trunkRoot } }
}

// ============================ shell + bin paths ============================
const sq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`
const ENV = `export ACFW_TRUNK_ROOT=${sq(trunkRoot)}; export ACFW_TRUNK_BRANCH=${sq(trunkBranch)}; export ACFW_STORE=${sq(store)};`
// The store dispatcher (3.1.0) is the single entry point for task state: snapshot (scan), transition
// (the writer primitive), doctor, read/materialize. For the files backend it routes to the same
// engines as 3.0.x (scan-backlog.sh / apply-transition.sh / doctor.sh) with identical output.
const STORE = `${pluginRoot}/skills/lib/bin/acfw-store`
// LP-CAS (3.0.0) integrator: lands one accepted task's single-parent candidate onto the LIVE trunk by
// cherry-pick + co-committed in-tree ledger marker + union gate + compare-and-swap. Replaces the retired
// integrate-worktree (rebase-into-cached-snapshot fold), whose stale snapshot was the keystone defect.
const INTEGRATE = `${pluginRoot}/skills/integrate-lpcas/bin/integrate-lpcas.sh`
const CLEAN_CHECKOUT = `${pluginRoot}/skills/clean-checkout-before-task/bin/clean-checkout.sh`

// Run lock (WHIP-15). Two concurrent /go runs collide on the same slugs: tasks cycle in-review without
// accepting, and one run's broad `git add` in the SHARED root checkout sweeps the other's staged work
// into an unrelated commit. The lock is the heartbeat file that already existed for observability —
// freshness by MTIME (no JSON parse, no PID, no daemon, no new file). It is a GUARDRAIL, not the
// correctness keystone: CAS-land and idempotent transitions are what actually make concurrency safe.
// After a crash it self-expires in LOCK_FRESH_MIN; the documented override is one `rm`.
// files keeps the historical .backlog/ location; other stores have no .backlog/, so /go passes
// runLockPath (resolved by `acfw-store info`) pointing under .acfwhip/run/ (gitignored).
const RUN_LOCK = (args && args.runLockPath) || `${trunkRoot}/.backlog/.acfw-run.json`
const RUN_LOCK_DIR = RUN_LOCK.slice(0, RUN_LOCK.lastIndexOf('/'))
const RUN_LOCK_BASE = RUN_LOCK.slice(RUN_LOCK.lastIndexOf('/') + 1)
const LOCK_FRESH_MIN = 30

// Where a dispatched agent READS (and, on files, writes) the task document.
//   files : the live root path — prompts stay byte-identical to 3.0.x.
//   other : a spec materialized from the store into .acfwhip/specs/<stem>.md by materializeCmd
//           (deterministic path, so prompts can embed it before the file exists). Evidence and
//           review comments flow back through `acfw-store comment`, never into the spec file.
const SPECS_DIR = `${trunkRoot}/.acfwhip/specs`
const taskLoc = (t, folder) => (filesStore ? `${trunkRoot}/.backlog/${folder}/${t.stem}.md` : `${SPECS_DIR}/${t.stem}.md`)
const materializeCmd = (t) => `bash ${sq(STORE)} read --materialize ${sq(SPECS_DIR)} ${sq(t.stem)}`

// IMPORTANT (isolation): acf-whip provides its OWN per-task isolation via git worktrees
// (.worktree/<slug>, created by clean-checkout.sh). Agents always operate against the REAL trunk
// via ACFW_TRUNK_ROOT (absolute paths), so we do NOT use the runtime's isolation:'worktree' — that
// would put the agent in a throwaway worktree while clean-checkout still resolved .worktree/<slug>
// off ACFW_TRUNK_ROOT, making the runtime worktree pointless overhead. Parallel safety comes from
// distinct slugs (distinct .worktree/<slug> dirs + branches) and git index-lock backoff.

const MAX_ITER = 1000
const NO_GAIN_LIMIT = 15 // iterations with no terminal gain (perpetual-retry guard); well below MAX_ITER

// Model for the DETERMINISTIC shell-runner agents (bootstrap, scan, the single backlog writer,
// integrate, drain). These agents do ZERO reasoning — they run a fixed bash command and copy its
// stdout into a schema — so they run on a fast/cheap model instead of the session model (every one
// inherited Opus before, paying Opus generation cost for a verbatim echo). The specialist/reviewer/
// direct and conflict-resolver dispatches do REAL work and are deliberately LEFT on the session model
// + their agentType (see the no-model comments at those call sites). Overridable via args.shellModel
// (set it to roll back to the session model if a model ever mis-handles the digest echo).
const SHELL_MODEL = (args && args.shellModel) || 'haiku'

// <scheduler-pure> ===========================================================================
// Everything between these markers is PURE (no agent/parallel/phase/log/clock, no closures except
// the module-level `mode`). tests/phase2-scheduler.test.mjs extracts this block verbatim, injects
// `mode`, and unit-tests it — so the scheduling/terminal logic (the part the 2.0.x migration broke)
// is exercised without the Workflow runtime. Keep it pure; if you add a side effect here, the test
// extraction breaks loudly.
const MAX_REJECT_RETRY = 3 // rejected with count < this -> retry (rejected->pending); >= this -> blocked
const MAX_BLOCK_RETRY = 3 // per-task re-block cap (retro I2): a task whose specialist re-blocks it this
// many times stops being re-unblocked — it stays blocked (terminal) and is surfaced as needsOperator,
// so a single unmodeled-blocker task can no longer livelock the run (the global noGain guard missed it).
const DEFAULT_TIMEOUT_H = 8 // in-progress -> blocked fallback when the snapshot omits inProgressTimeoutHours
const PRIORITY_RANK = { blocker: 0, critical: 1, high: 2, medium: 3, low: 4 }
const prank = (p) => (p in PRIORITY_RANK ? PRIORITY_RANK[p] : 5)
const byPriorityThenStem = (a, b) => (prank(a.priority) - prank(b.priority)) || (a.stem < b.stem ? -1 : a.stem > b.stem ? 1 : 0)

// ============================ schemas ============================
const BOOTSTRAP = {
  type: 'object', additionalProperties: false,
  required: ['detached', 'lockFresh', 'doctorOk', 'doctorSummary', 'fatals'],
  properties: {
    detached: { type: 'boolean', description: 'true if HEAD is detached at the trunk root' },
    lockFresh: { type: 'boolean', description: 'true if the run-lock heartbeat file exists AND was modified within the freshness window (another /go is live)' },
    doctorOk: { type: 'boolean', description: 'true if doctor reported ok=true after --fix' },
    doctorSummary: { type: 'string', description: 'verbatim SUMMARY|... line from the report-only doctor run' },
    fatals: { type: 'array', items: { type: 'string' }, description: 'verbatim FATAL|... lines remaining after --fix' },
  },
}
const SCAN_RESULT = {
  type: 'object', additionalProperties: false,
  required: ['snapshotJson', 'doctorOk', 'doctorSummary', 'doctorFatals'],
  properties: {
    snapshotJson: { type: 'string', description: 'the VERBATIM stdout of the acfw-store snapshot command — a single JSON object, copied exactly, nothing added' },
    doctorOk: { type: 'boolean' },
    doctorSummary: { type: 'string', description: 'verbatim SUMMARY|... line' },
    doctorFatals: { type: 'array', items: { type: 'string' }, description: 'verbatim FATAL|... lines' },
  },
}
const WRITE_BATCH = {
  type: 'object', additionalProperties: false,
  required: ['applied', 'note'],
  properties: {
    applied: { type: 'array', items: { type: 'string' }, description: 'one line per acfw-store transition call: its stdout (ok:/noop:) or an error note' },
    note: { type: 'string' },
  },
}
const ACFW_RESULT = {
  type: 'object', additionalProperties: false,
  // Only the original four are REQUIRED — keeping the emit surface small protects against the
  // StructuredOutput non-emit that BUG-1 hardens against. blockedReason/needsTask are OPTIONAL signals
  // (BUG-2) a specialist sets ONLY when it blocks on unmodeled work; absent, behaviour is unchanged.
  required: ['transition', 'commitSha', 'rejectionIncrement', 'notes'],
  properties: {
    transition: { type: 'string', enum: ['completed', 'blocked', 'accepted', 'rejected', 'none'], description: 'the transition from your ACFW-RESULT marker; "none" if you could not complete (transient — orchestrator retries next iteration)' },
    commitSha: { type: 'string', description: 'commit sha on worktree/<slug>, or "n/a"' },
    rejectionIncrement: { type: 'integer', enum: [0, 1] },
    notes: { type: 'string', description: 'one-line reason' },
    blockedReason: { type: 'string', enum: ['dependency-missing', 'environment', 'unrecoverable', 'none'], description: 'ONLY meaningful when transition=blocked. "dependency-missing" = the REAL blocker is unmodeled work that should be its own task (name it in needsTask) — the orchestrator then PARKS this task for an operator instead of re-dispatching it (re-running /go will not help). Omit or "none" for an ordinary block.' },
    needsTask: { type: 'string', description: 'when blockedReason=dependency-missing: a one-line description of the missing task an operator should create; else "".' },
    deliverableFiles: { type: 'array', items: { type: 'string' }, description: 'NON-CODE (Worktree: none) tasks ONLY: every standalone file you created or modified outside .backlog/, repo-relative (e.g. "docs/research/20260709-foo.md"). The single writer commits these with the state move — list them or they are LOST. Empty when the deliverable lives inside the task file itself.' },
  },
}
const INTEGRATE_RESULT = {
  type: 'object', additionalProperties: false,
  required: ['exitCode', 'outcome', 'note', 'resolverWorktree', 'resolverBranch', 'resolverAgent', 'resolverConflictedFiles', 'resolverConflictingCommits'],
  properties: {
    exitCode: { type: 'integer', description: 'the integrate-lpcas.sh exit code (0,3,4,6,7,9,11,12,99,...)' },
    outcome: { type: 'string', enum: ['integrated', 'resolver-needed', 'rejected', 'transient', 'skipped', 'contaminated', 'error'] },
    note: { type: 'string' },
    resolverWorktree: { type: 'string', description: 'from the resolver-needed block "worktree:" line, else ""' },
    resolverBranch: { type: 'string', description: 'from "branch:", else ""' },
    resolverAgent: { type: 'string', description: 'from "assigned_agent:", else ""' },
    resolverConflictedFiles: { type: 'string', description: 'the conflicted_files block, newline-joined, else ""' },
    resolverConflictingCommits: { type: 'string', description: 'the conflicting_commits block, newline-joined, else ""' },
  },
}

// ============================ pure-JS scheduling helpers ============================
function indexTasks(tasks, satisfiedDeps) {
  const byId = new Map(), byStem = new Map()
  for (const t of tasks) { if (t.id) byId.set(t.id, t); if (t.stem) byStem.set(t.stem, t) }
  // satisfiedDeps (digest mode): terminal-accepted dependency targets the scanner collapsed into
  // {stem,id} instead of full task objects. A dep token that resolves ONLY here is a DONE dependency.
  // Synthesize a terminal accepted object shaped so the EXISTING isTerminal (accepted + hasIntegratedAt
  // -> terminal) and depsSatisfied (slug 'none' short-circuits the cross-slug gate -> satisfied) treat
  // it as satisfied with NO edits to those bodies. REAL tasks (byId/byStem) always win first, so a live
  // integration candidate — a full task object, never in satisfiedDeps — keeps blocking its dependents.
  const sd = satisfiedDeps || []
  const satById = new Map(), satByStem = new Map()
  for (const e of sd) { if (e && e.id) satById.set(e.id, e); if (e && e.stem) satByStem.set(e.stem, e) }
  const synth = (e) => ({ stem: e.stem || e.id, id: e.id || e.stem, folder: 'accepted', slug: 'none', hasIntegratedAt: true, hasWorktreeBranch: false, deps: [] })
  const satResolve = (tok) => {
    if (satById.has(tok)) return synth(satById.get(tok))
    if (satByStem.has(tok)) return synth(satByStem.get(tok))
    for (const [stem, e] of satByStem) if (stem.indexOf(tok) === 0) return synth(e) // prefix (mirrors resolve)
    return null
  }
  const resolve = (tok) => {
    if (byId.has(tok)) return byId.get(tok)
    if (byStem.has(tok)) return byStem.get(tok)
    for (const [stem, t] of byStem) if (stem.indexOf(tok) === 0) return t // prefix match (mirrors doctor)
    return satResolve(tok)
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
  const maxBlock = (o.maxBlock != null) ? o.maxBlock : MAX_BLOCK_RETRY
  const timeoutH = (o.timeoutH != null) ? o.timeoutH : DEFAULT_TIMEOUT_H
  // parked (BUG-2): stems a specialist blocked on with blocked_reason=dependency-missing this run. Their
  // DECLARED deps are satisfied (the real blocker is unmodeled), so without this they would be re-unblocked
  // and re-dispatched on a tight loop until Block-Count hit its cap. Parking stops the re-queue immediately.
  const parked = (o.parked instanceof Set) ? o.parked : new Set(o.parked || [])
  // Actions are STEM-keyed (3.1.0): the store adapter resolves the stem to its current location, so a
  // stale `from` folder can never mis-address a move (strictly more robust on resume than a full path).
  const mk = (t, from, toState, notes) => ({ stem: t.stem, toState, agent: 'orchestrator', notes, inc: 0 })

  // blocked -> pending: deps now satisfied AND not a max-rejection "redesign" block (count >= cap)
  // AND not a max-re-block "needs operator" task (blockCount >= cap). A specialist-blocked or
  // dep-blocked task re-runs once its deps land; a 3x-rejected task is left for a human; a task whose
  // specialist has re-blocked it 3x (its real blocker is unmodeled — retro I2) STOPS being re-queued
  // so it can no longer livelock the run. It stays blocked (terminal) and surfaces as needsOperator.
  const unblockActions = tasks
    .filter((t) => t.folder === 'blocked')
    .sort(byPriorityThenStem)
    .filter((t) => (t.rejectionCount || 0) < maxReject && (t.blockCount || 0) < maxBlock && !parked.has(t.stem) && depsSatisfied(t, idx))
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

// Map a dispatched unit's CURRENT folder + the specialist/reviewer's reported transition to the next
// folder, or null for "no legal move this iteration" (transient — leave the task where it is and retry).
// Extracted pure so the streaming lifecycle (BUG-3) and its unit tests share one source of truth.
function resultToState(from, transition) {
  if (from === 'in-progress' && transition === 'completed') return 'completed'
  if (from === 'in-progress' && transition === 'blocked') return 'blocked'
  if (from === 'in-review' && transition === 'accepted') return 'accepted'
  if (from === 'in-review' && transition === 'rejected') return 'rejected'
  return null
}

// reconcileIntegrationTallies — WS5 / retro #9: the in-loop integrate accumulators are optimistic. A
// post-resolver integrate agent that fails to emit returns 'transient', so the rejection that
// integrate-worktree ALREADY wrote to disk (task moved to rejected/, exit 6) is recorded nowhere — the
// report would claim rejectedAtIntegration:[] while the folder says otherwise, and could even list a
// stem under `integrated` that is actually in rejected/. The fix trusts the final on-disk snapshot:
//   • integratedStems  — stems the loop THOUGHT it integrated (optimistic positives)
//   • rejectedStems    — stems the loop SAW rejected at integration
//   • attemptedIntegrate — every stem handed to the integrator (the authoritative "we tried" set)
//   • finalSnap.tasks  — folder truth; a terminal-integrated task is COLLAPSED out of the digest, so
//     absent ⇒ integrated-or-unknown (NOT rejected). Only an explicit rejected/ entry demotes a stem.
// Returns { integrated, rejectedAtIntegration, reconciled } — deduped, disk-consistent.
function reconcileIntegrationTallies(integratedStems, rejectedStems, attemptedIntegrate, finalSnap) {
  const finalByStem = new Map(((finalSnap && finalSnap.tasks) || []).map((t) => [t.stem, t]))
  const rejectedOnDisk = (stem) => { const t = finalByStem.get(stem); return !!(t && t.folder === 'rejected') }
  const integrated = [...new Set(integratedStems)].filter((s) => !rejectedOnDisk(s))
  const rejectedAtIntegration = [...new Set([
    ...rejectedStems,
    ...[...attemptedIntegrate].filter(rejectedOnDisk),
  ])]
  const reconciled = integrated.length !== new Set(integratedStems).size || rejectedAtIntegration.length !== new Set(rejectedStems).size
  return { integrated, rejectedAtIntegration, reconciled }
}
// </scheduler-pure> ==========================================================================

// ============================ agent prompt builders ============================
const NO_BACKLOG_WRITES = filesStore
  ? 'Do code work ONLY inside the worktree. Do NOT move task files between .backlog/ folders and do NOT commit any .backlog/ change — the orchestrator is the single writer of .backlog/.'
  : 'Do code work ONLY inside the worktree. Do NOT change task state in the task store and do NOT edit the materialized spec file — the orchestrator is the single writer of task state.'

// Non-files stores: the task document lives in the store, not on disk — every dispatched agent
// first materializes a read-only spec (metadata + body + log) at the deterministic taskLoc path.
const fetchSpecStep = (t) => (filesStore ? '' : `
STEP -1 (task spec): run  ${materializeCmd(t)}  — it renders this task's CURRENT document from the '${store}' task store to the path it prints. Read the task there; treat it as read-only.
`)
const evidenceSink = (t, rootPath, author) => (filesStore
  ? `Write evidence-of-completion back into the ROOT task file at ${sq(rootPath)} (append to its sections)`
  : `Record evidence-of-completion in the task store — pipe your evidence text to:  bash ${sq(STORE)} comment ${sq(t.stem)} --author ${sq(author)}`)

function specialistPrompt(t) {
  const rootPath = taskLoc(t, 'in-progress')
  return `${ENV}
You are the ${t.agent || 'assigned'} specialist executing one acf-whip backlog task.
${fetchSpecStep(t)}
STEP 0 (mandatory concurrency primitive): run
  bash ${sq(CLEAN_CHECKOUT)} ${sq(rootPath)}
Its stdout is the absolute worktree path (branch ${branchPrefix}/${t.slug}). If it exits non-zero, do NOT proceed: return transition "none" with the exit code in notes (the orchestrator retries next iteration).

Then: read the task at ${sq(rootPath)} (the ROOT path — read it there). Do the implementation INSIDE the worktree printed by Step 0, on branch ${branchPrefix}/${t.slug}. Run the project's quality gates. Commit your CODE to the worktree branch. ${evidenceSink(t, rootPath, t.agent || 'specialist')}, then end your response with the ACFW-RESULT marker:
  ACFW-RESULT:
    transition: completed | blocked
    commit_sha: <sha on ${branchPrefix}/${t.slug}, or n/a>
    rejection_increment: 0
    notes: <one line>
    blocked_reason: <only if blocked: dependency-missing | environment | unrecoverable | none>
    needs_task: <only if blocked_reason=dependency-missing: the missing task to create, else n/a>
Use transition "completed" when the work is done and quality gates pass; "blocked" if you hit an unresolvable blocker. If the real blocker is WORK THAT SHOULD BE ITS OWN TASK and does not exist yet (not one of your declared Dependencies), set blocked_reason "dependency-missing" and describe that task in needs_task — the orchestrator parks this task for an operator instead of looping on it. ${NO_BACKLOG_WRITES}

Finally return the structured ACFWResult matching your marker (transition, commitSha, rejectionIncrement 0, notes; plus blockedReason/needsTask if you blocked on a missing dependency).`
}

function reviewerPrompt(t) {
  const rootPath = taskLoc(t, 'in-review')
  const tokenRule = filesStore
    ? `AUTO-REJECT rule: if the task's Transition Log lacks a "| clean-checkout | ok |" token, reject.`
    : `AUTO-REJECT rule: AFTER Step 0, re-run  ${materializeCmd(t)}  (Step 0 recorded its own token in the store; the refresh picks it up) and check the refreshed document's Transition Log — if it lacks a "| clean-checkout | ok |" token, reject.`
  const reviewSink = filesStore
    ? `Write your review comments into the ROOT task file at ${sq(rootPath)}`
    : `Record your review comments in the task store — pipe them to:  bash ${sq(STORE)} comment ${sq(t.stem)} --author quality-reviewer`
  return `${ENV}
You are quality-reviewer reviewing one acf-whip task that an implementer marked completed.
${fetchSpecStep(t)}
STEP 0: run  bash ${sq(CLEAN_CHECKOUT)} ${sq(rootPath)}  to attach to the task's worktree (branch ${branchPrefix}/${t.slug}) and validate it. If it exits non-zero, return transition "none" with the exit code in notes.

Then review the implementation against the task's Acceptance Criteria and quality gates, working in the worktree.
${tokenRule}
${reviewSink}, then end with the ACFW-RESULT marker:
  ACFW-RESULT:
    transition: accepted | rejected
    commit_sha: n/a
    rejection_increment: <0 if accepted, 1 if rejected>
    notes: <specific feedback>
${NO_BACKLOG_WRITES}

Return the structured ACFWResult matching your marker.`
}

function directReviewPrompt(t) {
  const rootPath = taskLoc(t, 'in-review')
  const reviewSink = filesStore
    ? `Write your review comments into that ROOT file`
    : `Record your review comments in the task store — pipe them to:  bash ${sq(STORE)} comment ${sq(t.stem)} --author quality-reviewer`
  return `${ENV}
You are quality-reviewer reviewing one NON-CODE acf-whip task (Worktree: none — NO worktree, do NOT run clean-checkout, and do NOT apply the "missing clean-checkout token" auto-reject rule; non-code tasks have no worktree).
${fetchSpecStep(t)}
Read the task and its deliverable at ${sq(rootPath)} and review it against the task's Acceptance Criteria.

If the Acceptance Criteria name a standalone deliverable file (one outside .backlog/), verify for EACH such file that it (a) exists and (b) is COMMITTED — run  git -C ${sq(trunkRoot)} log -1 --oneline -- <file>  and require non-empty output. An existing but uncommitted deliverable is a REJECT (the specialist did not report it to the writer, so the next checkout destroys it); say so in notes, naming the file.

${reviewSink}, then end with the ACFW-RESULT marker:
  ACFW-RESULT:
    transition: accepted | rejected
    commit_sha: n/a
    rejection_increment: <0 if accepted, 1 if rejected>
    notes: <specific feedback>
${NO_BACKLOG_WRITES}

Return the structured ACFWResult matching your marker.`
}

function directPrompt(t) {
  const rootPath = taskLoc(t, 'in-progress')
  const workSink = filesStore
    ? `write the deliverable/evidence into that ROOT task file`
    : `record the deliverable/evidence in the task store (pipe the text to:  bash ${sq(STORE)} comment ${sq(t.stem)} --author ${sq(t.agent || 'specialist')} )`
  return `${ENV}
You are the ${t.agent || 'assigned'} agent executing one NON-CODE acf-whip task (Worktree: none — research/docs-only, NO worktree, do NOT run clean-checkout).
${fetchSpecStep(t)}
Read the task at ${sq(rootPath)}, do the work, and ${workSink} (and, when the task calls for a standalone document, into its own file under the repo — e.g. docs/research/<date>-<topic>.md).

Do NOT create a worktree, do NOT move the file between .backlog/ folders, do NOT commit anything — the orchestrator is the single writer and it commits FOR you.

DELIVERABLE FILES (load-bearing): if you created or modified ANY file outside .backlog/, list every one of them, repo-relative, in deliverable_files. The writer stages exactly those paths in the same commit as this task's state move. A file you do not list is never committed, and the next checkout or stash DESTROYS it — this has permanently lost finished work. If your whole deliverable lives inside the task file, leave the list empty.

End your response with the ACFW-RESULT marker:
  ACFW-RESULT:
    transition: completed | blocked
    commit_sha: n/a
    rejection_increment: 0
    notes: <one line>
    deliverable_files: <comma-separated repo-relative paths you created/modified outside .backlog/, or n/a>
    blocked_reason: <only if blocked: dependency-missing | environment | unrecoverable | none>
    needs_task: <only if blocked_reason=dependency-missing: the missing task to create, else n/a>
If you block because of unmodeled work that should be its own task, set blocked_reason "dependency-missing" and name that task in needs_task so the orchestrator parks this for an operator.

Return the structured ACFWResult matching your marker (deliverableFiles as an array; plus blockedReason/needsTask if you blocked on a missing dependency).`
}

function integratePrompt(t, postResolver) {
  const acceptedPath = taskLoc(t, 'accepted')
  const cmd = postResolver
    ? `bash ${sq(INTEGRATE)} --post-resolver ${sq(acceptedPath)}`
    : `bash ${sq(INTEGRATE)} ${sq(acceptedPath)}`
  const fetchSpec = filesStore ? '' : `First run  ${materializeCmd(t)}  (renders the task spec the integrator reads — Worktree slug and Assigned Agent). Then r`
  return `${ENV}
Run the acf-whip LP-CAS integrator for one accepted task and report its result. ${fetchSpec ? fetchSpec : 'R'}un EXACTLY:
  ${cmd}
Capture the exit code and stdout (stdout carries an "ACFW-INTEGRATE: <verdict> ..." line). Map exit code -> outcome:
  0  -> integrated      (the change + its in-tree ledger marker are now on trunk, landed by compare-and-swap; or an idempotent already-integrated skip)
  3  -> contaminated    (quarantine: malformed/poison candidate — isolate THIS task for an operator, do NOT retry, do NOT reject the others)
  4  -> skipped         (no candidate ref — historical task already on trunk, or nothing to integrate; do NOT retry)
  6  -> rejected        (quality-fault: the union gate FAILED on the candidate tree; task is a genuine quality reject)
  7  -> resolver-needed  (cherry-pick conflict; stdout carries an "ACFW-INTEGRATE: resolver-needed" block — DO NOT touch the worktree, just parse and report)
  9  -> transient        (MECHANISM fault: unresolved conflict / resolution-syntax-broken / worktree error — NOT a quality reject; leave accepted, retry later)
  11 -> transient        (cas-lost: trunk moved under us; leave accepted, re-observe and retry later)
  12 -> transient        (stall: trunk unobservable this attempt; leave accepted, retry later)
  99 -> transient        (git lock contention)
  other -> error
If and ONLY if exit code is 7, parse the resolver-needed stdout block and fill: resolverWorktree (the "worktree:" line value), resolverAgent ("assigned_agent:" — may be empty), resolverConflictedFiles (the lines under "conflicted_files:", newline-joined). Set resolverBranch and resolverConflictingCommits to "" (the LP-CAS integration worktree is detached — there is no branch and no commit list). Otherwise set all five to "".
Return the structured IntegrateResult. Do NOT dispatch a resolver yourself; the orchestrator does that.`
}

function resolverPrompt(t, r) {
  return `${ENV}
You are the conflict resolver (${r.resolverAgent || t.agent || 'assigned specialist'}) for an acf-whip LP-CAS integration.
The integration worktree at ${sq(r.resolverWorktree)} is a DETACHED checkout of the live trunk tip, mid-cherry-pick of this task's candidate, with conflicts. Your ONLY job is to resolve the conflicted files and stage them — the integrator owns the commit, gate, and land.

Conflicted files:
${r.resolverConflictedFiles || '(none reported)'}

FORBIDDEN — these corrupt the fold or destroy work (the integrator detects unmerged paths and reports a mechanism fault if you leave them):
  - git reset (any form), git checkout/switch to another commit/branch, git rebase, deleting the worktree.
  - Running git cherry-pick --continue / --commit / --abort / --quit. Do NOT advance or finish the cherry-pick — the integrator does that. You only resolve + stage.
  - Editing or committing anything under .backlog/ or .acfwhip/ (task state and the integration ledger are the orchestrator's; never touch them).
ALLOWED — only: edit the conflicted files in place, then  git -C ${sq(r.resolverWorktree)} add <file>  for each resolved file.

Resolve every conflict preserving BOTH intents (the task's change AND what is already on trunk), then  git -C ${sq(r.resolverWorktree)} add  every conflicted file. Do NOT commit. If the conflict is genuinely irreconcilable, leave the conflict markers UNstaged — the integrator will report a mechanism fault and the task stays accepted for a later attempt. Do NOT move task files. When done, report what you did in one line.`
}

// Bounded-retry wrapper around a schema agent() call (retro I1). A StructuredOutput non-emit (the
// subagent finished without calling the tool) THROWS out of a bare `await agent({schema})`; unhandled,
// it kills the entire run — runs A and D died this way after hours of work. Retry a few times, then
// degrade gracefully via onGiveUp() (a safe sentinel) instead of propagating. The parallel dispatch
// path already maps a thrown thunk to null (runtime semantics), so this is only for the bare-await
// calls: bootstrap, scan, the single writer, integrate, drain.
async function safeAgent(prompt, opts, onGiveUp) {
  const tries = 3
  for (let k = 1; k <= tries; k++) {
    try {
      return await agent(prompt, k === 1 ? opts : { ...opts, label: `${opts.label}:retry${k - 1}` })
    } catch (e) {
      log(`agent ${opts.label} non-emit/error (attempt ${k}/${tries}): ${String((e && e.message) || e).slice(0, 160)}`)
    }
  }
  return onGiveUp ? onGiveUp() : null
}

// BUG-1 parse-fallback: pull a JSON object out of a free-text agent message. The scan's failure mode
// is "the model ran the command and answered, but did not call StructuredOutput", so the JSON it
// printed is recoverable from the text. Prefer a fenced ```json block; else take the outermost {...}.
function extractJson(text) {
  if (!text) return null
  const t = String(text)
  const fence = t.match(/```(?:json)?\s*([\s\S]*?)```/i)
  const candidate = fence ? fence[1] : t
  const a = candidate.indexOf('{'), b = candidate.lastIndexOf('}')
  if (a < 0 || b < 0 || b <= a) return null
  try { return JSON.parse(candidate.slice(a, b + 1)) } catch (e) { return null }
}

// BUG-1: schema-LESS scan fallback. When the schema-forced scan agent exhausts its retries without
// emitting StructuredOutput, run scan-backlog.sh through a plain (no-schema) agent that returns its
// final text, and parse the snapshot JSON out of that text directly. The per-iteration doctor recheck
// is advisory mid-run (bootstrap already gated, the next clean scan rechecks), so this path skips it.
async function textScanFallback(label) {
  let txt = null
  try {
    txt = await agent(
      `${ENV}
Run EXACTLY:  bash ${sq(STORE)} snapshot --digest --mode ${mode}
Output its stdout — a single JSON object — as your ENTIRE final message. No prose, no markdown fences, nothing else.`,
      { label, phase: 'Iterate', model: SHELL_MODEL },
    )
  } catch (e) { return null }
  const snap = extractJson(txt)
  return snap && snap.counts ? snap : null
}

// Deliverable paths a NON-CODE task reported (WHIP-08). apply-transition.sh refuses a state path with
// exit 2 — which would strand the state move — so filter here too: a specialist that names .backlog/
// or an absolute path loses its staging, never its transition. Defense in depth, not duplication.
function safeStagePaths(files, stem) {
  const out = []
  for (const raw of (Array.isArray(files) ? files : [])) {
    const p = String(raw || '').trim().replace(/^\.\//, '')
    if (!p) continue
    if (p.startsWith('/') || p.includes('..') || p.startsWith('.backlog/') || p.startsWith('.acfwhip/')) {
      log(`WARN ${stem}: ignoring unstageable deliverable path '${p}' (absolute, traversing, or a state path)`)
      continue
    }
    out.push(p)
  }
  return out
}

// One sequential writer call. actions: [{ stem, toState, agent, notes, inc, binc, stage }].
async function applyTransitions(actions, label) {
  if (!actions.length) return { applied: [], note: 'nothing to do' }
  const lines = actions.map((a) => {
    const stage = (a.stage || []).map((p) => `--stage ${sq(p)} `).join('')
    return `  bash ${sq(STORE)} transition ${stage}${sq(a.stem)} ${sq(a.toState)} ${sq(a.agent || 'orchestrator')} ${sq(a.notes || '')} ${sq(String(a.inc || 0))} ${sq(String(a.binc || 0))}`
  }).join('\n')
  // Non-emit here is non-fatal: the moves are re-planned from the next scan (store state is the truth)
  // and the transition primitive is idempotent, so deferring a write one iteration is safe.
  return safeAgent(
    `${ENV}
You are the SINGLE backlog writer. Run these acfw-store transition calls IN ORDER, one at a time (never in parallel). Each moves one task between states in the task store, appends a transition-log row, and records it durably. The transition is idempotent (no-ops if the task is already in the target state), so re-running is safe.

${lines}

Then run exactly once (best-effort — ignore any failure):  mkdir -p ${sq(RUN_LOCK_DIR)} && touch ${sq(RUN_LOCK)}

Capture each transition call's stdout (an "ok:", "noop:" or "warn:" line) into applied[]. If any call errors, record it in applied[] and continue with the rest. Return the WriteResult.`,
    { label, phase: 'Iterate', schema: WRITE_BATCH, model: SHELL_MODEL },
    () => ({ applied: [], note: 'writer agent non-emit after retries — transitions deferred to next iteration' }),
  )
}

// ============================ BOOTSTRAP (hard gate) ============================
phase('Bootstrap')
const boot = await safeAgent(
  `${ENV}
Bootstrap the acf-whip orchestrator at trunk root ${sq(trunkRoot)}.
1. Run-lock check: run  find ${sq(RUN_LOCK_DIR)} -maxdepth 1 -name ${RUN_LOCK_BASE} -mmin -${LOCK_FRESH_MIN}  — if it prints a path, set lockFresh true and stop (do not run the doctor). Otherwise set lockFresh false (a "No such file or directory" error also means false).
2. Detached HEAD check: run  git -C ${sq(trunkRoot)} symbolic-ref --quiet HEAD  — if it FAILS, set detached true and stop (do not run the doctor).
3. If a branch is checked out: apply repairable integrity issues, then re-scan:
     bash ${sq(STORE)} doctor --fix >/dev/null 2>&1 || true
     bash ${sq(STORE)} doctor --quiet
   From the second run capture: doctorOk (SUMMARY ok=true), doctorSummary (the verbatim SUMMARY line), fatals (verbatim FATAL| lines).
Return the BootstrapResult.`,
  { label: 'bootstrap', phase: 'Bootstrap', schema: BOOTSTRAP, model: SHELL_MODEL },
  () => null,
)
if (!boot) {
  return { aborted: true, reason: 'bootstrap agent never emitted after retries; re-run /go (git + .backlog/ are durable, nothing is lost)', mode }
}
if (boot.lockFresh) {
  // Refuse, do not warn: a double-start is unattended by definition, so a console warning protects nothing.
  return { aborted: true, reason: `another /go run appears active (${RUN_LOCK} touched within ${LOCK_FRESH_MIN}m). Never run two /go against one repo — they collide on slugs and on the shared root index. If the previous run crashed, the lock expires on its own, or clear it now:  rm ${RUN_LOCK}`, mode }
}
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
const attemptedIntegrate = new Set() // every stem handed to integrateOne — used to reconcile the report
                                     // against disk (WS5 / retro #9): an attempted stem now in rejected/
                                     // was rejected at integration even if the agent failed to emit it.
const parkedThisRun = new Set() // stems a specialist blocked on with dependency-missing (BUG-2) — not re-dispatched
const parkedNeeds = new Map() // stem -> needs_task text (for the final operator report)
let lastSnapshot = null
let stopReason = 'max-iterations'

while (iter < MAX_ITER) {
  iter++

  // ---- scan (read-only) + doctor-lite + heartbeat ----
  const scanPrompt = `${ENV}
Iteration ${iter} of the acf-whip orchestrator. Do three things and return the result:
1. Read-only snapshot:  bash ${sq(STORE)} snapshot --digest --mode ${mode}  — its stdout is a single JSON object. Put that stdout VERBATIM (copy it exactly, add nothing) into snapshotJson.
2. Integrity recheck (report-only):  bash ${sq(STORE)} doctor --quiet --active-only  — set doctorOk (SUMMARY ok=true), doctorSummary (verbatim SUMMARY line), doctorFatals (verbatim FATAL| lines).
3. Heartbeat (best-effort, NOT committed): write a small JSON file at ${sq(RUN_LOCK)} (create its parent directory first if missing) containing {"iteration":${iter},"mode":"${mode}","ts":"<output of: date -u +%Y-%m-%dT%H:%M:%SZ>"}. If the write fails, ignore it.
Return the ScanResult.`
  let scan = await safeAgent(scanPrompt, { label: `scan#${iter}`, phase: 'Iterate', schema: SCAN_RESULT, model: SHELL_MODEL }, () => null)

  // mid-run FATAL introduced (e.g. a cycle from a retry, a half-applied transition) is a GENUINE stop
  // (unrepairable integrity) -> abort before dispatch. A non-emit/garbled echo is NOT genuine and is
  // handled below by parse-fallback + degrade (BUG-1), never by aborting the whole run.
  if (scan && !scan.doctorOk) {
    stopReason = 'integrity-fatal-midrun'
    return { aborted: true, reason: 'integrity FATAL detected mid-run; aborting before dispatch', mode, iteration: iter, doctorSummary: scan.doctorSummary, fatals: scan.doctorFatals }
  }

  let snap = null
  if (scan) { try { snap = JSON.parse(scan.snapshotJson) } catch (e) { snap = null } }
  if (scan && !snap) {
    // One schema re-scan on a garbled/truncated echo before falling back: the snapshot is relayed by an
    // agent echoing scan-backlog's stdout verbatim, so a single bad echo should not derail a long run.
    log(`iter ${iter}: snapshot JSON unparseable — re-scanning once`)
    scan = await safeAgent(scanPrompt, { label: `scan#${iter}:retry`, phase: 'Iterate', schema: SCAN_RESULT, model: SHELL_MODEL }, () => null)
    if (scan && !scan.doctorOk) {
      stopReason = 'integrity-fatal-midrun'
      return { aborted: true, reason: 'integrity FATAL detected mid-run (on scan retry); aborting before dispatch', mode, iteration: iter, doctorSummary: scan.doctorSummary, fatals: scan.doctorFatals }
    }
    if (scan) { try { snap = JSON.parse(scan.snapshotJson) } catch (e) { snap = null } }
  }
  if (!snap) {
    // Schema path exhausted (StructuredOutput non-emit, or unparseable twice). The model likely ran the
    // command and answered without calling the tool — try a schema-LESS text scan and parse the JSON it
    // printed (BUG-1 parse-fallback). The scan is read-only bookkeeping, not judgement.
    log(`iter ${iter}: scan schema path failed — trying schema-less text scan`)
    const fb = await textScanFallback(`scan#${iter}:text`)
    if (fb) { snap = fb; log(`iter ${iter}: recovered snapshot via text fallback (doctor recheck skipped this iteration)`) }
  }
  if (!snap) {
    // Even the text fallback failed. A read-only scan is bookkeeping, not judgement — do NOT abort the
    // whole run (and discard hours of healthy iterations) over a transient helper-emit failure (BUG-1).
    // Stop the loop gracefully and fall through to the defensive Drain, which integrates any remaining
    // accepted work off the last good snapshot. git + .backlog/ are durable; re-run /go to continue.
    stopReason = 'scan-degraded'
    log(`iter ${iter}: scan produced no snapshot after retries + text fallback — stopping loop, draining, then return (re-run /go to continue)`)
    break
  }
  lastSnapshot = snap
  if (snap.branchPrefix) branchPrefix = snap.branchPrefix
  const tasks = snap.tasks || []
  const idx = indexTasks(tasks, snap.satisfiedDeps)

  // Unblock/timeout plan is computed HERE (before the completion check) so completion can require that
  // no blocked task is about to be unblocked — otherwise a cross-slug dep that integrates in the final
  // iteration hits 100% terminal and the loop breaks before the blocked dependent gets its unblock pass
  // (retro I5A). Reused below for the pre-move batch.
  const { unblockActions, timeoutActions, freshInProgress } = planUnblockAndTimeout(tasks, idx, {
    timeoutH: (snap.inProgressTimeoutHours != null ? snap.inProgressTimeoutHours : DEFAULT_TIMEOUT_H),
    maxReject: MAX_REJECT_RETRY,
    maxBlock: MAX_BLOCK_RETRY,
    parked: parkedThisRun,
    trunkRoot,
  })

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
    return { aborted: true, reason: 'backlog snapshot is missing runtimeTerminal counts — snapshot engine / workflow version skew (or a store adapter emitting a pre-contract snapshot); reinstall acf-whip so both halves match', mode, iteration: iter }
  }
  const total = snap.counts.total
  const terminal = mode === 'override' ? snap.counts.runtimeTerminalOverride : snap.counts.runtimeTerminalDefault
  log(`iter ${iter}: ${terminal}/${total} active terminal (integrated=${snap.counts.integrated}, accepted=${snap.counts.accepted}, blocked=${snap.counts.blocked}, workingSet=${tasks.length})`)
  // Complete only when 100% terminal AND nothing is queued to unblock — the extra unblock+dispatch
  // pass (retro I5A) keeps a last-iteration-integrated dependency from stranding its blocked dependent.
  if (total > 0 && terminal === total && unblockActions.length === 0) { stopReason = 'complete'; break }

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

  // (unblockActions/timeoutActions/freshInProgress were hoisted above the completion check — retro I5A.)

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
      ? { stem: t.stem, toState: 'pending', agent: 'orchestrator', notes: `retry (rejection ${t.rejectionCount}/${MAX_REJECT_RETRY})`, inc: 0 }
      : { stem: t.stem, toState: 'blocked', agent: 'orchestrator', notes: `max rejections (${t.rejectionCount}) — blocked for redesign`, inc: 0 },
  )

  if (warnings.length) for (const w of warnings) log(`WARN ${w}`)

  // ---- pre-move (single writer, sequential) ----
  // Unblock + timeout first (they change what is dispatchable next iteration), then dispatch pre-moves.
  const preActions = [
    ...unblockActions,
    ...timeoutActions,
    ...reviewQ.filter((x) => x.premove).map((x) => ({ stem: x.t.stem, toState: 'in-review', agent: 'orchestrator', notes: 'review-dispatch', inc: 0 })),
    ...specialistQ.filter((x) => x.premove).map((x) => ({ stem: x.t.stem, toState: 'in-progress', agent: 'orchestrator', notes: 'dispatch', inc: 0 })),
    ...directQ.filter((x) => x.premove).map((x) => ({ stem: x.t.stem, toState: 'in-progress', agent: 'orchestrator', notes: 'dispatch', inc: 0 })),
    ...rejectActions,
  ]
  if (preActions.length) await applyTransitions(preActions, `premove#${iter}`)

  // ---- execute: STREAMING lifecycle per dispatched unit (BUG-3) ----
  // Replaces the old "parallel(all) -> barrier -> batch post-move -> integrate" with a per-unit pipeline:
  // each specialist/direct, on completion, flows through review and (default mode) integration WITHOUT
  // waiting for the slowest unit in the wave — so a doc task done in minutes is reviewed+accepted (and
  // a code task integrated) in minutes even while a multi-hour task in the same wave is still running.
  // Two invariants are preserved by EXPLICIT serialization, not by the iteration barrier:
  //   • single writer — every .backlog/ transition runs through serializeWrite (a promise chain), so
  //                     apply-transition.sh calls never overlap even when units finish concurrently.
  //   • integration   — serializeIntegrate serializes the git folds onto trunk. Cross-slug dependents are
  //                     already gated at DISPATCH (depsSatisfied requires the dep accepted+integrated), so
  //                     units accepted in the SAME wave are mutually dependency-independent and need only
  //                     serialization, not ordering. Pre-existing accepted leftovers (which CAN be
  //                     interdependent) integrate first, in one topo-ordered, lock-held pass.
  let productiveDispatch = false // at least one dispatch produced a real (non-'none') transition
  let integratedThisIter = 0
  let writeTail = Promise.resolve()
  const serializeWrite = (fn) => { const r = writeTail.then(() => fn()); writeTail = r.then(() => {}, () => {}); return r }
  let integrateTail = Promise.resolve()
  const serializeIntegrate = (fn) => { const r = integrateTail.then(() => fn()); integrateTail = r.then(() => {}, () => {}); return r }
  const streamWrite = (actions, label) => serializeWrite(() => applyTransitions(actions, label))
  const integTransient = (note) => () => ({ outcome: 'transient', note })

  // Fold ONE accepted task's worktree branch into trunk (resolver hoisted). Updates integration tallies.
  async function integrateOne(t) {
    attemptedIntegrate.add(t.stem)
    let r = await safeAgent(integratePrompt(t, false), { label: `integrate:${t.slug}`, phase: 'Iterate', schema: INTEGRATE_RESULT, model: SHELL_MODEL }, integTransient('integrate agent non-emit — left accepted, retry next iteration'))
    if (r && r.outcome === 'resolver-needed') {
      log(`integrate ${t.slug}: conflict — dispatching resolver ${r.resolverAgent || t.agent || '(default)'}`)
      // NO model: here — the conflict resolver does REAL merge-conflict reasoning; session model + agentType.
      const ropts = { label: `resolve:${t.slug}`, phase: 'Iterate' }
      const ragent = r.resolverAgent || t.agent
      if (ragent && ragent !== 'none') ropts.agentType = ragent
      await agent(resolverPrompt(t, r), ropts)
      r = await safeAgent(integratePrompt(t, true), { label: `integrate:${t.slug}:post`, phase: 'Iterate', schema: INTEGRATE_RESULT, model: SHELL_MODEL }, integTransient('integrate(post-resolver) agent non-emit — left accepted, retry next iteration'))
    }
    if (r && r.outcome === 'integrated') { integratedStems.push(t.stem); integratedThisIter++; log(`✓ integrated ${t.stem}`) }
    else if (r && r.outcome === 'rejected') {
      // LP-CAS exit 6 = the union gate failed on (trunk + this change). The integrator mutates ONLY git;
      // unlike the retired integrate-worktree it does NOT move the task file. So the orchestrator (the
      // single .backlog writer) moves accepted -> rejected here, with a rejection increment, so the task
      // re-enters the rejection self-heal (retry as pending, or blocked at the cap) instead of being
      // re-attempted as an integration candidate every iteration. Keeps the run convergent.
      rejectedStems.push(t.stem)
      await streamWrite([{ stem: t.stem, toState: 'rejected', agent: 'orchestrator', notes: (r.note || 'union gate failed at integration').slice(0, 200), inc: 1 }], `integ-reject#${iter}:${t.stem}`)
      log(`✗ integrate rejected ${t.stem} — ${r.note}`)
    }
    else if (r && r.outcome === 'skipped') { log(`↷ skipped ${t.stem} — no worktree branch (historical; terminal)`) }
    else if (r && r.outcome === 'contaminated') {
      // LP-CAS exit 3 = quarantine: the candidate is malformed (not single-parent) or poison (writes the
      // .acfwhip/ ledger namespace). Isolate THIS task for an operator — never reject the others, never
      // re-run (a re-run re-quarantines). Integration of every other accepted task continues unaffected.
      parkedThisRun.add(t.stem)
      parkedNeeds.set(t.stem, (r.note || `quarantined candidate for ${t.slug} — inspect refs/acfw/patch/${t.stem}; the candidate is not a single-parent code-only commit`).slice(0, 200))
      log(`⚑ ${t.stem}: quarantined candidate (${t.slug}) — parked for operator, isolated from the rest of the run`)
    }
    // transient/error -> leave accepted, retry next iteration
  }

  // Review one task that is NOW in in-review/ (moved there by premove for reviewQ, or inline below for a
  // freshly-completed specialist), then integrate on accept. A reviewer non-emit throws out of the unit
  // thunk -> parallel maps it to null; the task is left committed in in-review/ and re-reviewed next scan.
  async function runReviewAndIntegrate(t) {
    const isNone = t.slug === 'none'
    const rprompt = isNone ? directReviewPrompt(t) : reviewerPrompt(t)
    // Reviewers ALWAYS run as quality-reviewer (independent review — never the implementer's agent).
    const rr = await agent(rprompt, { label: `review:${isNone ? t.stem : t.slug}`, phase: 'Iterate', schema: ACFW_RESULT, agentType: 'quality-reviewer' })
    const toState = resultToState('in-review', rr && rr.transition)
    if (!toState) return // none/mismatched -> transient, leave in in-review/
    await streamWrite([{ stem: t.stem, toState, agent: t.agent || 'orchestrator', notes: (rr.notes || '').slice(0, 200), inc: (toState === 'rejected' && rr.rejectionIncrement === 1) ? 1 : 0 }], `review#${iter}:${t.stem}`)
    productiveDispatch = true
    if (toState === 'accepted' && mode === 'default' && codeSlug(t)) await serializeIntegrate(() => integrateOne(t))
  }

  // Run one specialist/direct unit, then stream it through review (+integration) on completion.
  async function processUnit(d) {
    if (d.kind === 'review') return runReviewAndIntegrate(d.t) // already in in-review/ (premove)
    const prompt = d.kind === 'direct' ? directPrompt(d.t) : specialistPrompt(d.t)
    // NO model: specialists/direct do REAL work — keep the session model (+ agentType). Only the
    // deterministic shell-runners (scan, writer, integrate, bootstrap, drain) use SHELL_MODEL.
    const opts = { label: `${d.kind}:${d.t.slug === 'none' ? d.t.stem : d.t.slug}`, phase: 'Iterate', schema: ACFW_RESULT }
    const at = d.t.agent
    if (at && at !== 'none') opts.agentType = at
    const r = await agent(prompt, opts) // throws on non-emit -> parallel thunk -> null (transient)
    const toState = resultToState('in-progress', r && r.transition)
    if (!toState) return // none/mismatched -> leave in in-progress/, retry next iteration
    if (toState === 'blocked') {
      // BUG-2: dependency-missing -> park for an operator now (stop re-queueing) + actionable message.
      if (r.blockedReason === 'dependency-missing') {
        parkedThisRun.add(d.t.stem)
        const need = (r.needsTask || '').trim()
        if (need) parkedNeeds.set(d.t.stem, need.slice(0, 200))
        log(`⚑ ${d.t.stem}: blocked on unmodeled work — create a task: ${need || '(unspecified — see task notes)'} — parked, not re-dispatching this run`)
      }
      // binc:1 — a specialist re-block of a dispatched task is the unmodeled-blocker signal (retro I2).
      await streamWrite([{ stem: d.t.stem, toState: 'blocked', agent: d.t.agent || 'orchestrator', notes: (r.notes || '').slice(0, 200), inc: 0, binc: 1 }], `block#${iter}:${d.t.stem}`)
      productiveDispatch = true
      return
    }
    // completed: move in-progress -> completed -> in-review (one writer call), then review+integrate inline.
    // A NON-CODE task's standalone deliverables (it works in the ROOT tree and may not commit) are staged
    // by the writer in the FIRST of those commits — the earliest possible moment, so the window in which
    // a concurrent checkout/stash can destroy them is as small as the design allows (WHIP-08).
    const stage = d.kind === 'direct' ? safeStagePaths(r.deliverableFiles, d.t.stem) : []
    if (stage.length) log(`${d.t.stem}: committing ${stage.length} deliverable file(s) — ${stage.join(', ')}`)
    await streamWrite([
      { stem: d.t.stem, toState: 'completed', agent: d.t.agent || 'orchestrator', notes: (r.notes || '').slice(0, 200), inc: 0, stage },
      { stem: d.t.stem, toState: 'in-review', agent: 'orchestrator', notes: 'review-dispatch', inc: 0 },
    ], `done#${iter}:${d.t.stem}`)
    productiveDispatch = true
    await runReviewAndIntegrate(d.t)
  }

  // Pre-existing accepted leftovers (from the scan) CAN be interdependent — integrate them in one
  // topo-ordered, lock-held pass that runs concurrently with the dispatch wave below. A branchless
  // historical/pre-2.0.0 accepted task is already on trunk (isTerminal treats it terminal) — never
  // enqueue it (it has no candidate, so the integrator would exit 4 skip anyway; skip the dispatch).
  let priorIntegratePass = Promise.resolve()
  if (mode === 'default') {
    const seenC = new Set()
    const candidates = []
    for (const t of tasks.filter((t) => t.folder === 'accepted' && codeSlug(t) && !t.hasIntegratedAt && t.hasWorktreeBranch && !parkedThisRun.has(t.stem))) {
      if (seenC.has(t.stem)) continue
      seenC.add(t.stem); candidates.push(t)
    }
    if (candidates.length) {
      const ordered = topoIntegrationOrder(candidates, idx, () => log('WARN integrate: dependency cycle among integration candidates — using input order; run /whip-doctor'))
      priorIntegratePass = serializeIntegrate(async () => { for (const t of ordered) await integrateOne(t) })
    }
  }

  // ---- dispatch the wave; each unit streams its own lifecycle (BUG-3) ----
  const dispatch = [
    ...specialistQ.map((x) => ({ kind: 'specialist', t: x.t })),
    ...directQ.map((x) => ({ kind: 'direct', t: x.t })),
    ...reviewQ.map((x) => ({ kind: 'review', t: x.t })),
  ]
  if (dispatch.length) {
    // BUG-5: name what this wave is running so a supervisor can see WHAT is in flight without polling.
    log(`iter ${iter}: dispatching ${specialistQ.length} specialist + ${directQ.length} direct + ${reviewQ.length} review — ${dispatch.map((d) => `${d.kind}:${d.t.slug === 'none' ? d.t.stem : d.t.slug}`).join(', ')}`)
    await parallel(dispatch.map((d) => () => processUnit(d)))
  }
  await priorIntegratePass // ensure leftover integration finished before progress accounting

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
// finalSnap = the freshest authoritative snapshot used to RECONCILE the run report (WS5 / retro #9).
// Defaults to the last good loop snapshot; the drain rescan below upgrades it when it succeeds.
let finalSnap = lastSnapshot
if (mode === 'default' && lastSnapshot) {
  const rescan = await safeAgent(
    `${ENV}
Final integration drain. Run  bash ${sq(STORE)} snapshot --digest --mode ${mode}  and return its stdout VERBATIM in snapshotJson (set doctorOk true, doctorSummary "drain", doctorFatals []).`,
    { label: 'drain:scan', phase: 'Drain', schema: SCAN_RESULT, model: SHELL_MODEL },
    () => null,
  )
  let snap2 = null
  try { snap2 = rescan ? JSON.parse(rescan.snapshotJson) : null } catch (e) { snap2 = null }
  // BUG-6a: if the drain scan itself can't emit (it routes through the same schema-forced agent as the
  // main scan), drain off the last good in-memory snapshot instead of skipping integration entirely. A
  // stale snapshot may list a just-integrated task as still-accepted, so exclude stems already integrated
  // this run; the LP-CAS integrator's O(1) already-integrated check makes a folded task a no-op (exit 0)
  // even if one slips through.
  if (!snap2) snap2 = lastSnapshot
  finalSnap = snap2 || lastSnapshot
  if (snap2) {
    const idx2 = indexTasks(snap2.tasks || [], snap2.satisfiedDeps)
    const left = topoIntegrationOrder((snap2.tasks || []).filter((t) => t.folder === 'accepted' && t.slug && t.slug !== 'none' && !t.hasIntegratedAt && t.hasWorktreeBranch && !integratedStems.includes(t.stem)), idx2)
    for (const t of left) {
      // single defensive pass: an exit-7 here is intentionally left for the next /go run (no resolver post-loop)
      attemptedIntegrate.add(t.stem)
      const r = await safeAgent(integratePrompt(t, false), { label: `drain:${t.slug}`, phase: 'Drain', schema: INTEGRATE_RESULT, model: SHELL_MODEL }, () => ({ outcome: 'transient', note: 'drain integrate non-emit' }))
      if (r && r.outcome === 'integrated') { integratedStems.push(t.stem); drained++ }
    }
  }
}

// ============================ RELEASE THE RUN LOCK ============================
// A run that reaches here is over (complete | no-progress | max-iterations | scan-degraded), so release
// the lock immediately — otherwise a finished run would block its own re-run for LOCK_FRESH_MIN. The
// mid-run abort paths return earlier and deliberately leave the lock to expire on its own: they end in
// a state an operator should look at before relaunching. Best-effort by construction (the lock is a
// guardrail): if this never runs, the freshness window releases it anyway.
try {
  await agent(`Run exactly this command and report nothing else:  rm -f ${sq(RUN_LOCK)}`, { label: 'unlock', phase: 'Drain', model: SHELL_MODEL })
} catch (e) { /* lock expires on its own */ }

// ============================ REPORT ============================
// WS5 / retro #9: RECONCILE the run tallies against the freshest on-disk snapshot (finalSnap). The
// in-loop accumulators are optimistic — a post-resolver integrate agent that fails to emit returns
// 'transient' while integrate-worktree already moved the task to rejected/ on disk, so a naive report
// can claim a task integrated (or silently omit a rejection) that the folder state contradicts. The
// disk (folder + Integrated-At) is the source of truth; the accumulators only name what we attempted.
const finalCounts = finalSnap ? finalSnap.counts : null
const { integrated, rejectedAtIntegration, reconciled } = reconcileIntegrationTallies(integratedStems, rejectedStems, attemptedIntegrate, finalSnap)
// Tasks parked for an operator: blocked at the re-block cap (their real blocker is unmodeled — retro
// I2) or at the max-rejection cap, OR explicitly parked this run on a dependency-missing signal (BUG-2,
// possibly before reaching the cap). These are why a "complete" run can still leave blocked tasks: the
// loop-breaker intentionally stops re-dispatching them instead of livelocking. Surface them explicitly,
// with the missing-task hint when the specialist provided one.
const capParked = ((finalSnap && finalSnap.tasks) || [])
  .filter((t) => t.folder === 'blocked' && ((t.blockCount || 0) >= MAX_BLOCK_RETRY || (t.rejectionCount || 0) >= MAX_REJECT_RETRY))
  .map((t) => ({ stem: t.stem, blockCount: t.blockCount || 0, rejectionCount: t.rejectionCount || 0, needsTask: parkedNeeds.get(t.stem) || '' }))
const capParkedStems = new Set(capParked.map((n) => n.stem))
const depParked = [...parkedThisRun].filter((s) => !capParkedStems.has(s)).map((s) => ({ stem: s, blockCount: 0, rejectionCount: 0, needsTask: parkedNeeds.get(s) || '' }))
const needsOperator = [...capParked, ...depParked]
return {
  completed: stopReason === 'complete',
  stopReason, // complete | no-progress | max-iterations | scan-degraded | (aborts return earlier)
  mode,
  iterations: iter,
  finalCounts,
  integrated,
  rejectedAtIntegration,
  drainedPostLoop: drained,
  needsOperator,
  note: (stopReason === 'complete'
    ? 'Backlog 100% terminal.'
    : stopReason === 'no-progress'
      ? 'No progress for 3 iterations — user intervention needed (check blocked/ and rejected/).'
      : stopReason === 'scan-degraded'
        ? 'Scan could not emit a snapshot after retries + schema-less text fallback; stopped the loop and drained integratable work. Nothing lost (git + .backlog/ are durable) — re-run /go to continue.'
        : 'Hit the iteration cap.')
    + (needsOperator.length ? ` ${needsOperator.length} task(s) parked for an operator (re-block/rejection cap reached): ${needsOperator.map((n) => n.stem).join(', ')}.` : '')
    + (reconciled ? ' (integration tallies reconciled against final on-disk state).' : ''),
}
