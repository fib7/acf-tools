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
// Run scope (3.2.3). A list of task stems/ids to run INSTEAD of the whole backlog; absent/empty =>
// today's full-backlog behaviour, byte-identical. The skill resolves both `/go <id> <id>` and a
// natural-language filter ("frontend tasks only") to this same concrete list BEFORE launching, so the
// scheduler stays deterministic and the selected set cannot drift mid-run.
const ONLY = (args && Array.isArray(args.only) && args.only.length) ? args.only.map(String) : null
const SCOPE_FILTER = (args && typeof args.scopeFilter === 'string') ? args.scopeFilter : ''
// Where the scope came from (3.4.0). 'args' = the operator named ids on this invocation; 'focus' =
// bare `/go` ran the checkout's saved focus; 'all' = unscoped. It changes exactly one decision: an
// inactive member of an EXPLICIT scope is a refusal (you asked for a task that cannot run), while an
// inactive member of a FOCUS is a held-out task the run reports and continues past (a focus is a
// standing list, and pausing one of its tasks must not stop the others).
const SCOPE_SOURCE = (args && typeof args.scopeSource === 'string' && args.scopeSource) || (ONLY ? 'args' : 'all')
if (!pluginRoot || !trunkRoot) {
  return { error: 'whip-go.workflow.js requires args.pluginRoot and args.trunkRoot', got: { pluginRoot, trunkRoot } }
}

// ============================ shell + bin paths ============================
const sq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`
// ACFW_INTEGRATION_MODE is exported so every shell-runner agent's doctor/scan/integrate call resolves
// the SAME mode this script is scheduling under. Without it the doctors fall back to the config pin (or
// unpinned) and can contradict `mode` here: in override mode depsSatisfied deliberately dispatches a
// task whose cross-slug dep is accepted-but-unintegrated, a mode-blind doctor calls that
// FATAL|cross-slug-dep-not-integrated, and the per-iteration recheck aborts the run on a state this
// script chose. Passing args.mode (not the pin) also keeps an explicit caller override authoritative.
const ENV = `export ACFW_TRUNK_ROOT=${sq(trunkRoot)}; export ACFW_TRUNK_BRANCH=${sq(trunkBranch)}; export ACFW_STORE=${sq(store)}; export ACFW_INTEGRATION_MODE=${sq(mode)};`
// The store dispatcher (3.1.0) is the single entry point for task state: snapshot (scan), transition
// (the writer primitive), doctor, read/materialize. For the files backend it routes to the same
// engines as 3.0.x (scan-backlog.sh / apply-transition.sh / doctor.sh) with identical output.
const STORE = `${pluginRoot}/skills/lib/bin/acfw-store`
// LP-CAS (3.0.0) integrator: lands one accepted task's single-parent candidate onto the LIVE trunk by
// cherry-pick + co-committed in-tree ledger marker + union gate + compare-and-swap. Replaces the retired
// integrate-worktree (rebase-into-cached-snapshot fold), whose stale snapshot was the keystone defect.
const INTEGRATE = `${pluginRoot}/skills/integrate-lpcas/bin/integrate-lpcas.sh`
const CLEAN_CHECKOUT = `${pluginRoot}/skills/clean-checkout-before-task/bin/clean-checkout.sh`
// Cycle engine (3.5.0). /go never runs it: it only names it in the final report's nextStep, so the
// turn that reads the report (often a resumed one, after compaction dropped the skill's step 5)
// knows the exact command without having to rebuild it.
const CYCLE = `${pluginRoot}/skills/lib/bin/acfw-cycle`

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
// Full-snapshot tee (3.4.0). The scan writes the PRE-narrowing snapshot here and the doctor reads it
// back, so the scheduler and the integrity battery observe ONE store walk instead of two. On a shared
// board two walks can straddle a colleague's transition, and the battery then reports findings about
// a task the scheduler's own snapshot does not contain — which, under per-task quarantine, means
// holding out a stem nobody can see.
//
// APPLIES TO RAW ADAPTERS ONLY, and that is not a gap. The tee exists to feed the GENERIC battery,
// which is the doctor for every adapter without `doctor-complete`. `files` declares it, so
// `acfw-store doctor` execs doctor.sh, which walks `.backlog/` itself and never reads a snapshot —
// there is no second walk to eliminate. The file is simply never written there, and the scan prompt
// falls back to the two-command form when it is absent.
//
// Path: always under `.acfwhip/run/`, never beside the run lock. On files the lock lives in
// `.backlog/`, which is the COMMITTED task store — dropping a scratch file in there would put an
// untracked artefact in the tree every doctor pass reports on.
const FULL_SNAP = `${trunkRoot}/.acfwhip/run/snap-full.json`

// --only flags for every snapshot call, built once. A scoped run relays O(scope) records instead of
// the whole board — which is the fix for the failure that started this: a store of several hundred cards whose full
// snapshot cannot be echoed through one agent response, so the echo was silently short and the ids
// the operator named were reported as nonexistent.
const ONLY_FLAGS = ONLY ? ONLY.map((k) => ` --only ${sq(k)}`).join('') : ''
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

// ============================ model routing (3.4.0) ============================
// Agents are routed by what they DO, not by who calls them. Three tiers, three reasons:
//
//   * SHELL — bootstrap, scan, the single backlog writer, integrate, drain, the scout, the harness
//     validator, the WIP snapshot, unlock. Each runs a fixed bash command and copies its stdout into
//     a schema. Zero reasoning, and by far the most frequent class, so it runs on a fast/cheap model
//     rather than inheriting the session model and paying frontier generation cost for a verbatim
//     echo. Raising THIS tier was the suggested workaround for the truncated-snapshot failure; it is
//     the wrong lever — bounding the payload is the fix, and this tier stays cheap because of it.
//   * SPECIALIST / REVIEW — every agentType dispatch. These route by the `model:` frontmatter of the
//     agent the PROJECT installed, which is where a project already says "this kind of work runs on
//     that model". The bootstrap reads the registry and hands back the map; each call passes the
//     model explicitly, so the choice lands in the run report instead of being buried in whatever
//     the runtime happens to resolve (which is undocumented for agentType inside a workflow).
//   * ARCHITECT / RESOLVER — not knobs. One authors executable harnesses, the other resolves real
//     merge conflicts. Both stay on the session model deliberately.
//
// Resolution is env > .acfwhip/config > default, surfaced by `acfw-store info` and passed in by the
// skill, so a team pins its cost policy once per repo instead of per invocation.
const MODELS = (args && args.models && typeof args.models === 'object') ? args.models : {}
const SHELL_MODEL = (args && args.shellModel) || MODELS.shell || 'haiku'
// Reasoning effort for the shell tier. Ships UNSET: Haiku is absent from the documented effort
// support table, and the effect of a low setting on verbatim-copy fidelity is undocumented — so this
// is an opt-in a team can measure, safely, now that a short relay is detected rather than believed.
const EFFORTS = (args && args.efforts && typeof args.efforts === 'object') ? args.efforts : {}
// Per-agentType models, discovered at bootstrap from .claude/agents/*.md frontmatter.
let agentModels = {}
// Which tier each agent this run spent belongs to. Without it, a run that quietly routed every
// specialist to the session model is indistinguishable from one that honoured the project's
// frontmatter — the same argument that put `escalation` in the report, applied to cost.
//
// Counted where an agent is CHARGED, not where a call site is written. Incrementing in the option
// helpers undercounted twice over: safeAgent charges up to three real agents per invocation on a
// retry, and every agent a child harness spends was added to agentsUsed and to no tier at all — so
// on an escalated run the tiers summed to a fraction of the total while the skill told the operator
// this field said what each tier spent. `untiered` is deliberate: a dispatch that goes through
// neither helper shows up as a number instead of vanishing.
const agentsByTier = { shell: 0, specialist: 0, review: 0, architect: 0, resolver: 0, child: 0, untiered: 0 }
// opts object -> tier. A WeakMap rather than a property on the options, because anything set there is
// passed verbatim to agent() and an unknown key is the runtime's business, not ours.
const tierOf = new WeakMap()
// THE charge point: one agent spent, against the ledger and against its tier.
function charge(opts, n) {
  const k = Math.max(1, n || 1)
  agentsUsed += k
  const t = (opts && tierOf.get(opts)) || 'untiered'
  agentsByTier[t] = (agentsByTier[t] || 0) + k
}
// THE single place a shell-tier call gets its model (and, when pinned, its effort). One helper, so a
// new shell stage cannot silently inherit the session model by forgetting the option.
function shellOpts(o) {
  const out = Object.assign({}, o, { model: SHELL_MODEL })
  if (EFFORTS.shell) out.effort = EFFORTS.shell
  tierOf.set(out, 'shell')
  return out
}
// Options for an agentType dispatch: the project's declared model for that agent, when it declares
// one. Omitted otherwise, which inherits the session model exactly as before.
function typedOpts(o, tier) {
  const out = Object.assign({}, o)
  const m = out.agentType && agentModels[out.agentType]
  // Never clobber a model the caller already chose. No current caller does; the guard costs nothing
  // and the child skeleton already gets this right (`&& !o.model && AGENT_MODELS[...]`).
  if (m && !out.model) out.model = m
  if (tier) tierOf.set(out, tier)
  return out
}

// ============================ 3.2.0: per-task authored child workflows ============================
// Every dispatched unit runs as its OWN nested workflow — a bespoke harness a workflow-architect agent
// fills into a locked, shipped skeleton — instead of one opaque agent() call. Everything in this block
// is mutable or path-bearing, so it MUST stay outside <scheduler-pure>: that block is extracted and
// eval'd in isolation by tests/phase2-scheduler.test.mjs, and a closure over these would break it.
//
// Escalation is a POLICY, never a guarantee: the tier ladder below degrades to verbatim 3.1.0 dispatch
// as the run's agent budget depletes, so a large backlog still drains instead of dying mid-run.
let ESCALATE = (args && args.escalate) !== false                  // default ON
const ESCALATE_REVIEW = (args && args.escalateReview) === true    // default OFF — the only SUBTRACTIVE seam
const MAX_AMEND = (args && typeof args.maxAmend === 'number') ? args.maxAmend : 2
const LEAN_BUDGET = 5
const FULL_BUDGET = (args && typeof args.agentBudget === 'number') ? args.agentBudget : 8
const SKELETON = `${pluginRoot}/skills/lib/child-skeleton.js.tmpl`
const SCAFFOLD = `${pluginRoot}/skills/lib/bin/acfw-child-scaffold`
const VALIDATE_BIN = `${pluginRoot}/skills/lib/bin/acfw-child-validate`
const LEDGER_BIN = `${pluginRoot}/skills/lib/bin/acfw-child-ledger`
const CHILD_DIR = `${trunkRoot}/.acfwhip/run/child`
// The runtime caps TOTAL agents across a workflow's lifetime, and a /go run is ONE invocation whose
// children share the counter. There is no script-visible runtime counter, so the parent keeps its own.
const AGENT_CAP = (args && args.agentCap) || 1000
const CAP_RESERVE = 150
const DISPATCH_CHUNK = 512
let agentsUsed = 0
let REGISTRY = []
const registryHas = (n) => REGISTRY.indexOf(n) >= 0
const esc = { authored: 0, amended: 0, preflight: 0, fellBack: 0, refused: 0, shallow: 0, replayed: 0, faults: [] }
let archMissingLogged = false // announce a missing workflow-architect ONCE, not once per unit
// Every agent() in this script routes through agentC (or safeAgent, which charges its own retries) so
// the ledger cannot drift low and let the CLOSE rung fire too late.
async function agentC(p, o) { charge(o); return agent(p, o) }

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

// The doctor now reports a battery that COULD NOT RUN as a typed FATAL rather than as silence
// (acfw-store: doctor-unavailable / snapshot-unavailable). Both gates below used to model the
// doctor's outcome as one boolean and tell the operator the backlog was inconsistent — a
// misdiagnosis that sends them to /whip-doctor to fix findings that were never produced. Separate
// "the board is broken" from "nobody could read the board", and name the remedy for the second.
const UNAVAILABLE_RE = /^FATAL\|(doctor|snapshot)-unavailable\|/
const doctorVerdict = (fatals) => {
  const list = Array.isArray(fatals) ? fatals : []
  const blocked = list.filter((f) => UNAVAILABLE_RE.test(String(f)))
  if (!blocked.length || blocked.length !== list.length) return { reported: true }
  return { reported: false, why: blocked.map((f) => String(f).split('|').slice(3).join('|')).join(' · ') }
}
const byPriorityThenStem = (a, b) => (prank(a.priority) - prank(b.priority)) || (a.stem < b.stem ? -1 : a.stem > b.stem ? 1 : 0)

// ============================ schemas ============================
const BOOTSTRAP = {
  type: 'object', additionalProperties: false,
  required: ['detached', 'lockFresh', 'doctorOk', 'doctorSummary', 'fatals', 'cpuCores', 'agents', 'scaffoldOk'],
  // agentModels is deliberately NOT required: a bootstrap from an older cached plugin, or a project
  // with no frontmatter models at all, must still satisfy the schema. Absent => route nothing.
  properties: {
    detached: { type: 'boolean', description: 'true if HEAD is detached at the trunk root' },
    lockFresh: { type: 'boolean', description: 'true if the run-lock heartbeat file exists AND was modified within the freshness window (another /go is live)' },
    doctorOk: { type: 'boolean', description: 'true if doctor reported ok=true after --fix' },
    doctorSummary: { type: 'string', description: 'verbatim SUMMARY|... line from the report-only doctor run' },
    fatals: { type: 'array', items: { type: 'string' }, description: 'verbatim FATAL|... lines remaining after --fix' },
    cpuCores: { type: 'integer', description: 'core count from the sysctl/nproc step; 0 if it could not be determined' },
    agents: { type: 'array', items: { type: 'string' }, description: 'the project\'s INSTALLED agent names from .claude/agents/*.md, without the .md suffix' },
    agentModels: { type: 'array', items: { type: 'string' }, description: 'for each installed agent that DECLARES a model in its frontmatter, the line "<agent-name>=<model>". Agents with no model: line are omitted entirely — omission means "inherit the session model", which is not the same as any particular model.' },
    scaffoldOk: { type: 'boolean', description: 'true if the child-workflow scaffold probe printed a skeleton' },
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
    faultClass: { type: 'string', enum: ['quality', 'mechanism'], description: 'OPTIONAL (absent => quality). Set "mechanism" to say "this failed, and it is NOT the task\'s fault" — a broken environment, a missing worktree, a lost clean-checkout token, a harness defect. A mechanism fault is TRANSIENT: it never charges the task\'s Rejection Count or Block-Count, and the task is retried unchanged. Use "quality" (or omit) when the WORK is what is wrong.' },
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
  // satByStem is exported so classifyFatals can ask "is this key a task this board knows about?"
  // including the collapsed-accepted entries: a FATAL naming one of those is a real finding about a
  // real task, just one the digest folded away — it must not be filed as "names nothing".
  return { byId, byStem, satByStem, resolve }
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
function depsSatisfied(t, idx, quarantined) {
  for (const depTok of (t.deps || [])) {
    const dep = idx.resolve(depTok)
    if (!dep) return false // dangling — doctor would FATAL; be conservative
    // A QUARANTINED dep gates its dependents, and this test comes FIRST, before the folder read.
    // Two twins sharing one whip key collapse to a single index entry (byStem is last-write-wins), so
    // if the surviving object happens to be the accepted one, a folder-only gate would call a
    // duplicate-key task "done" and dispatch everything behind it. Keying the refusal on the STEM —
    // which both twins share and which applyQuarantine holds out — makes the quarantine transitive
    // through the gate regardless of which object the index kept.
    if (quarantined && quarantined.has(dep.stem)) return false
    if (dep.folder !== 'accepted') return false
    // A cross-slug code dep blocks only while it is genuinely pending integration: accepted, has a
    // live worktree branch, and not yet integrated. A branchless historical dep is already on trunk
    // -> satisfied (mirrors isTerminal + the doctor's branch-aware cross-slug-dep check).
    const crossSlug = dep.slug !== t.slug // includes dep.slug === 'none'
    if (mode === 'default' && crossSlug && dep.slug !== 'none' && dep.hasWorktreeBranch && !dep.hasIntegratedAt) return false
  }
  return true
}

// Run scope (3.2.3). Expand a caller-supplied seed of task stems/ids into the set of stems the
// scheduler may act on. A scoped task whose dependency sits OUTSIDE the seed would stay correctly
// gated by depsSatisfied and never progress, so unmet (non-terminal) transitive deps are pulled IN;
// an already-terminal dep needs nothing and is left out. Seed tokens resolve through the same
// idx.resolve as everything else (id, stem, unique prefix, or a collapsed-accepted satisfiedDeps
// entry), so a scoped id that the scanner collapsed resolves to a synthesized terminal object whose
// stem is simply absent from the working set — neutral to both numerator and denominator below.
// PURE: no clock, no closure beyond `mode` (reached via isTerminal), so the <scheduler-pure>
// extraction in tests/phase2-scheduler.test.mjs keeps working. `seed` is a parameter, never `args`.
const INACTIVE_STATES = ['draft', 'archive']
function expandScope(seed, idx, activeStems) {
  const scope = new Set(), added = [], unresolved = [], inactiveSeeds = [], stack = []
  // The index resolves non-schedulable tasks (dependency resolution needs them) but they are absent
  // from tasks[]. A seed naming one produces an EMPTY scheduling view, and an empty scoped view
  // reports `complete` — "Backlog 100% terminal", zero agents, integrated:[].
  //
  // ENUMERATING ['draft','archive'] DOES NOT COVER THAT. acfw-enrich-snapshot.sh defines inactive by
  // EXCLUSION — anything outside the seven active states — so on a non-`files` store a card whose
  // whip_state is absent or out of vocabulary (WARN|invalid-state, quarantine by construction since
  // 3.3.0) has folder "" and sailed straight through this guard, reproducing the exact failure that
  // was already fixed once for draft. The caller's active set IS the question, so ask it directly;
  // the enumeration stays as the fallback so a two-arg caller keeps its current meaning.
  const schedulable = (t) => (activeStems ? activeStems.has(t.stem) : INACTIVE_STATES.indexOf(t.folder) < 0)
  for (const tok of (seed || [])) {
    const t = idx.resolve(tok)
    if (!t) { unresolved.push(tok); continue }
    // Terminal seeds are exempt: a collapsed-accepted stem is synthesized, never in tasks[], and is
    // neutral to both sides of the completion count — rejecting it would break scoping to done work.
    if (!isTerminal(t) && !schedulable(t)) { inactiveSeeds.push(`${t.stem} (${t.folder || 'no state'})`); continue }
    stack.push(t.stem)
  }
  while (stack.length) {
    const stem = stack.pop()
    if (scope.has(stem)) continue
    scope.add(stem)
    const t = idx.byStem.get(stem)
    if (!t) continue // collapsed-accepted (synthesized): terminal, nothing to walk
    for (const depTok of (t.deps || [])) {
      const dep = idx.resolve(depTok)
      if (!dep || scope.has(dep.stem)) continue
      // PULL IN every dep that is not ACCEPTED-terminal. `isTerminal` alone is the wrong predicate and
      // wrong in the one direction that loses work: `blocked` is terminal by that definition, but a
      // blocked dep is RETRYABLE — planUnblockAndTimeout lifts it back to pending once its own deps
      // resolve, and that pass runs over `sched`, i.e. over the scope. Skipping it here leaves the dep
      // outside the scheduling view forever, so it can never be unblocked, so the seed that depends on
      // it never dispatches and the run exits 'no-progress' with the requested task untouched. Only an
      // ACCEPTED-terminal dep is genuinely done and needs nothing; everything else comes along.
      if (dep.folder === 'accepted' && isTerminal(dep)) continue
      added.push(dep.stem)
      stack.push(dep.stem)
    }
  }
  return { scope, added, unresolved, inactiveSeeds }
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
  // quarantined (3.4.0): stems held out by a task-level integrity FATAL this iteration. They must gate
  // their dependents exactly like an unsatisfied dep, so the set is threaded into depsSatisfied rather
  // than filtered afterwards — an unblock action for a task behind a broken dep is not merely useless,
  // it moves the card and charges the run an iteration.
  const quarantined = (o.quarantined instanceof Set) ? o.quarantined : new Set(o.quarantined || [])
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
    .filter((t) => (t.rejectionCount || 0) < maxReject && (t.blockCount || 0) < maxBlock && !parked.has(t.stem) && !quarantined.has(t.stem) && depsSatisfied(t, idx, quarantined))
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

// reviewVerdict — the review call site's whole decision, made pure and testable.
//
// Fixes a livelock: the old call site wrote `inc: (toState === 'rejected' && rr.rejectionIncrement === 1)
// ? 1 : 0`, so a reviewer that returned transition 'rejected' WITHOUT setting rejectionIncrement wrote
// inc:0. Rejection Count then never advanced, MAX_REJECT_RETRY never bound, and the task cycled
// in-review -> rejected -> pending -> in-review forever, caught only by the loose NO_GAIN_LIMIT.
// Deriving inc from toState makes the increment structural — a rejection ALWAYS costs one life.
//
// But rejectionIncrement was also the only channel a reviewer had for "reject, and this is not the
// task's fault". That is now the explicit faultClass field: a mechanism fault is transient (no move, no
// increment), which keeps mechanism faults out of the quality budget — the separation the 3.0.0 LP-CAS
// design established for the integrator and that review never had.
function reviewVerdict(rr) {
  if (!rr) return { toState: null, inc: 0, mechanism: false }
  if (rr.transition === 'rejected' && rr.faultClass === 'mechanism') return { toState: null, inc: 0, mechanism: true }
  const toState = resultToState('in-review', rr.transition)
  return { toState, inc: toState === 'rejected' ? 1 : 0, mechanism: false }
}

// ============================ 3.2.0 pure helpers (child workflows) ============================

// attemptKeyOf — the ledger GENERATION for one task. The SAME key across amend rounds, re-dispatches
// and /go crashes, which is what makes progress survive them. A NEW key the moment an external review
// rejects: a retry harness that replayed every stage as already-done would produce nothing at all.
function attemptKeyOf(t) { return `a${t.rejectionCount || 0}-b${t.blockCount || 0}` }

// coerceAcfwResult — workflow() enforces NO schema (only agent({schema}) does), so a child's return
// value has to be validated here before resultToState sees it. Returning null reproduces today's
// non-emit semantics EXACTLY: resultToState(from, null) === null, so the task stays where it is and
// is retried next iteration with nothing corrupted.
function coerceAcfwResult(raw, allowVocab) {
  if (!raw || typeof raw !== 'object') return null
  const tr = String(raw.transition || '')
  if ((allowVocab || []).indexOf(tr) < 0) return null
  const out = {
    transition: tr,
    commitSha: typeof raw.commitSha === 'string' ? raw.commitSha : 'n/a',
    rejectionIncrement: raw.rejectionIncrement === 1 ? 1 : 0,
    notes: typeof raw.notes === 'string' ? raw.notes : '',
    faultClass: raw.faultClass === 'mechanism' ? 'mechanism' : 'quality',
  }
  if (typeof raw.blockedReason === 'string') out.blockedReason = raw.blockedReason
  if (typeof raw.needsTask === 'string') out.needsTask = raw.needsTask
  if (Array.isArray(raw.deliverableFiles)) out.deliverableFiles = raw.deliverableFiles.filter((f) => typeof f === 'string')
  return out
}

// coerceResolveResult — the resolve child's locked verify-resolve probe is the AUTHORITY on whether a
// conflict is actually resolved. resolved:false means the parent SKIPS --post-resolver entirely, which
// would otherwise only re-detect the unmerged paths and burn a round trip.
function coerceResolveResult(raw) {
  if (!raw || typeof raw !== 'object') return { resolved: false, staged: 0, note: 'resolve child returned nothing usable' }
  return {
    resolved: raw.resolved === true && Number(raw.staged || 0) > 0,
    staged: Number(raw.staged || 0),
    note: typeof raw.notes === 'string' ? raw.notes : '',
  }
}

// escalationTier — how much of the run's agent budget remains decides how deep this unit may go.
// Guarded against cap<=0: a NaN comparison would silently read DIRECT and disable the whole feature.
// Evaluated per unit AFTER a lane is acquired — before the lane every unit in a wave samples the same
// pre-wave counter, and the ladder could never fire mid-wave.
function escalationTier(used, cap, reserve) {
  if (!cap || cap <= 0) return 'FULL'
  // The reserve is a FRACTION of a small cap, not a constant. agentCap is operator-settable with no
  // documented floor while CAP_RESERVE is fixed at 150, so any cap <= 150 made `used >= cap - reserve`
  // true at used === 0: the CLOSE rung emptied both queues before the pre-move, and the run reported
  // agent-cap-reached with "agentsUsed: 2/100" and "Nothing lost." — a clean stop that dispatched
  // nothing. That rung is not gated on ESCALATE either, so `escalate: false` — the first thing the
  // skill suggests for a hung run — hit it too. Identical to the old behaviour at the 1000 default
  // and for every cap above the reserve.
  const r = cap > reserve ? reserve : Math.max(1, Math.floor(cap * 0.15))
  if (used >= cap - r) return 'CLOSE'
  const frac = used / cap
  if (frac < 0.50) return 'FULL'
  if (frac < 0.70) return 'LEAN'
  return 'DIRECT'
}

function chunkList(a, n) {
  const out = []
  for (let i = 0; i < (a || []).length; i += n) out.push(a.slice(i, i + n))
  return out
}

// improved — a repair round is only worth paying for if the error actually CHANGED. A blind round
// count pays for rounds that provably accomplish nothing.
function improved(prevErr, nextErr) { return String(prevErr || '') !== String(nextErr || '') }

// reconcileChildProgress — merge the scout's ledger view with git truth into the replay set.
// EVERY disagreement resolves toward RE-RUN (informed by the RESUME clause), never toward skip:
//   * commit-bearing ledger entry with no matching ACFW-Stage trailer -> dropped (the commit never landed)
//   * trailer present with no ledger entry                            -> done, payload unavailable
//   * worktree gone                                                   -> drop everything (nothing is verifiable)
//   * unparseable or missing recorded result                          -> dropped
// Double-applying a stage is worse than re-running one, and re-running is always safe.
function reconcileChildProgress(stages, trailers, git) {
  const trailerSet = {}
  for (const t of (trailers || [])) trailerSet[t] = true
  const wtMissing = !(git && git.worktreeExists)
  const priorStages = {}
  const names = [], dropped = []
  for (const s of (stages || [])) {
    if (!s || !s.name) continue
    if (s.status !== 'ok') { dropped.push(s.name); continue }
    if (wtMissing && s.commit) { dropped.push(s.name); continue }
    if (s.commit && !trailerSet[s.name]) { dropped.push(s.name); continue }
    if (s.payloadPath && s.payloadMissing) { dropped.push(s.name); continue }
    if (s.result === undefined || s.result === null) { dropped.push(s.name); continue }
    priorStages[s.name] = { status: 'ok', result: s.result }
    names.push(s.name)
  }
  // A trailer git can see but the ledger cannot is still DONE — the commit is the durable proof.
  // Its recorded payload is gone, so it replays as a minimal marker and the architect is told.
  for (const t of (trailers || [])) {
    if (priorStages[t] === undefined && !wtMissing) {
      priorStages[t] = { status: 'ok', result: { __fromTrailer: true } }
      names.push(t)
    }
  }
  return { priorStages, names, dropped }
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

// ============================ 3.4.0: relay integrity ============================
// The snapshot is produced by a SCRIPT but delivered by an AGENT: a shell-runner reads the store
// walk's stdout with its Bash tool and copies it into one schema string, which this script parses.
// That hop is lossy in the one way that reads as data: a model that shortens tasks[] and closes the
// braces emits VALID JSON, so JSON.parse succeeds and the scheduler plans over a board that does not
// exist. On a large board that is not hypothetical — it is what made a scoped run report that the
// requested ids "do not exist in the backlog" when every one of them did.
//
// So the producer states what it emitted and the consumer checks. `relay.n` is the total entry count,
// `relay.tasks`/`inactive`/`sat` are the per-array counts (so a short payload says WHICH array lost
// entries), and `relay.bytes` is the sum of the UTF-8 byte lengths of every stem across them. The
// count alone is not enough — a model that truncates may also "tidy" a header it can see — so the
// byte sum is a second, content-derived number it would have to recompute deliberately to keep
// consistent. The header leads the object (after the dispatcher's own store/tokenAllStates keys, and
// always before tasks[]), so a tail-elided echo still carries the expectation it fails.
//
// WHAT THIS PROVES, precisely: no entry was dropped, added, or replaced by one of a different stem
// length. It does NOT prove stem identity — an equal-length substitution passes. That is deliberate:
// a length sum is the strongest check all three producers (jq, bash, JS) can compute identically and
// cheaply, and substitution is not a failure mode of an echoing model, whereas truncation demonstrably
// is. The ids a caller actually NAMED get a stronger guarantee elsewhere: every seed the script
// resolved must be exactly present in the relayed index, or the run refuses (see the scope
// cross-check at the scan site). Do not weaken that check on the strength of this one.
//
// PURE: no clock, no I/O. Returns {ok, why, expected, got} — the caller decides the ladder.
function stemBytes(s) {
  // UTF-8 byte length without Buffer/TextEncoder (neither is guaranteed in the workflow sandbox, and
  // the producers compute it in jq (`utf8bytelength`) and bash (`LC_ALL=C ${#stem}`) respectively).
  let n = 0
  for (const ch of String(s == null ? '' : s)) {
    const c = ch.codePointAt(0)
    n += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4
  }
  return n
}
const RELAY_REQUIRED = ['files', 'beads', 'multica', 'linear']
function relayCheck(snap, store) {
  if (!snap || typeof snap !== 'object') return { ok: false, why: 'no snapshot', expected: 0, got: 0 }
  const r = snap.relay
  // A snapshot with NO header from a THIRD-PARTY adapter is not a failure: the field is SHOULD, not
  // MUST, and refusing would brick every such backend on upgrade. But every adapter acf-whip ships
  // always emits one, so on those a missing header IS the failure mode — the threat here is a model
  // shortening the payload, and a model that drops entries is at least as likely to drop a 60-byte
  // header it does not understand as to recompute it. Tolerating that on a shipped backend would
  // leave the single most probable relay loss passing silently.
  if (!r || typeof r !== 'object' || typeof r.n !== 'number' || typeof r.bytes !== 'number') {
    if (RELAY_REQUIRED.indexOf(String(store || '')) >= 0) {
      return { ok: false, why: `the '${store}' store always emits a relay header and this snapshot has none — the payload was not relayed intact`, expected: null, got: null }
    }
    return { ok: true, unverifiable: true, expected: null, got: null }
  }
  const arrs = [['tasks', snap.tasks], ['inactive', snap.inactive], ['sat', snap.satisfiedDeps]]
  let n = 0, bytes = 0
  const per = {}
  for (const [name, a] of arrs) {
    const list = Array.isArray(a) ? a : []
    per[name] = list.length
    n += list.length
    for (const e of list) bytes += stemBytes(e && e.stem)
  }
  if (n !== r.n) {
    // Name the array that came up short — "tasks 180/400" is actionable; "3 != 4" is not.
    const which = ['tasks', 'inactive', 'sat']
      .filter((k) => typeof r[k] === 'number' && r[k] !== per[k])
      .map((k) => `${k} ${per[k]}/${r[k]}`).join(', ')
    return { ok: false, why: `entry count ${n} != declared ${r.n}${which ? ` (${which})` : ''}`, expected: r.n, got: n }
  }
  if (bytes !== r.bytes) return { ok: false, why: `stem checksum ${bytes} != declared ${r.bytes} (same count, different entries)`, expected: r.n, got: n }
  return { ok: true, expected: r.n, got: n }
}
// The doctor's findings travel the SAME hop as the snapshot, in a sibling field, and a dropped FATAL
// line is worse than a dropped task: under per-task quarantine a FATAL that never arrives silently
// UN-quarantines its task and the run dispatches against the exact state the gate exists to refuse.
// The SUMMARY line carries the count the battery emitted, so cross-check it against what was relayed.
function doctorRelayCheck(summaryLine, fatals) {
  const m = /fatal=(\d+)/.exec(String(summaryLine || ''))
  if (!m) return { ok: true, unverifiable: true } // no SUMMARY relayed (text fallback) — nothing to compare
  const declared = Number(m[1])
  const got = Array.isArray(fatals) ? fatals.length : 0
  if (declared === got) return { ok: true, declared, got }
  return { ok: false, declared, got, why: `doctor reported fatal=${declared} but ${got} FATAL line(s) were relayed` }
}

// ============================ 3.4.0: integrity finding classification ============================
// A FATAL used to mean one thing: stop the run. On a shared board that conflates two unrelated
// statements — "this repository is not in a state anyone can work in" and "ONE card is malformed" —
// and the second is far more common. A single long-cancelled card with a hand-edited state blocked
// every run for a whole team, including runs scoped to tasks that never touched it.
//
// Split them. REPO findings still abort. TASK findings hold out that task and let the rest proceed.
// A finding naming something the scheduler cannot act on at all is NOT GATING — it is reported, never
// acted on, because aborting for it would reinstate the board-wide gate for an inert card.
//
// Matching is by EXACT stem. The doctor's third field is not a typed surface (it carries stems, slugs
// and URLs depending on the emitter), and prefix-matching it would attach a finding to the wrong task
// — the one failure mode that would make quarantine less safe than aborting.
const REPO_FATAL_CODES = [
  'detached-head',          // no branch at the trunk root: nothing can be transitioned or integrated
  'worktree-wrong-branch',  // a worktree dir on a foreign branch: affects the dir's slug AND the branch's
  'doctor-unavailable',     // the battery could not run: findings are UNKNOWN, not absent
  'snapshot-unavailable',   // ditto for the graph/git battery
  'no-store',               // beads: the store itself is missing
  'status-custom',          // beads: the status vocabulary does not match
  'backend',                // beads: the backend is unreadable
  'store-unreadable',       // beads: the per-issue battery did not run
]
function classifyFatals(lines, idx) {
  const repo = [], task = [], notGating = []
  for (const raw of (Array.isArray(lines) ? lines : [])) {
    const line = String(raw == null ? '' : raw)
    const parts = line.split('|')
    const code = (parts[1] || '').trim()
    const key = (parts[2] || '').trim()
    const detail = parts.slice(3).join('|').trim()
    const entry = { line, code, stem: key, detail }
    // Repo scope by CODE, or by the contract's "no task" convention in field 3. An unrecognised code
    // with no key is repo too: an unknown global finding must not be silently downgraded.
    if (REPO_FATAL_CODES.indexOf(code) >= 0 || key === '' || key === '-' || key === '(repo)') { repo.push(entry); continue }
    // NO INDEX YET (bootstrap runs before the first snapshot). Membership is unknowable, so the only
    // safe reading is "task-scoped, decide it at iteration 1" — filing it as not-gating would let a
    // genuine finding through unchecked, and aborting on it would keep the board-wide gate this
    // release removes. The caller treats this bucket as DEFERRED, not as a quarantine set.
    if (!idx) { task.push(entry); continue }
    const hit = idx.byStem && idx.byStem.has(key)
    const sat = idx.satByStem && idx.satByStem.has(key)
    if (hit || sat) { task.push(entry); continue }
    notGating.push(entry)
  }
  return { repo, task, notGating }
}

// Move quarantined tasks OUT of the scheduling view and fix the counts on both sides of the
// completion test. Leaving them in tasks[] would dispatch them; dropping them without adjusting
// counts would make `terminal === total` unreachable (unscoped counts come from the store) or
// reachable too early (scoped counts come from the view). They land in inactive[], where dependency
// resolution still sees them — so a dependent stays gated legibly instead of reporting a dangling dep.
// PURE: returns a NEW snapshot object; never mutates the input.
function applyQuarantine(snap, qset) {
  if (!snap || !qset || !qset.size) return snap
  const keep = [], moved = []
  for (const t of (snap.tasks || [])) {
    if (qset.has(t.stem)) moved.push(t); else keep.push(t)
  }
  if (!moved.length) return snap
  const counts = Object.assign({}, snap.counts || {})
  const dec = (k) => { if (typeof counts[k] === 'number') counts[k] = Math.max(0, counts[k] - 1) }
  for (const t of moved) {
    dec(t.folder)
    dec('total')
    if (t.folder === 'accepted' && t.hasIntegratedAt) dec('integrated')
    // The runtime-terminal counters mirror isTerminal per mode. Decrement each one exactly when the
    // moved task was terminal UNDER THAT MODE, or an unscoped run compares a shrunken total against
    // an unshrunken terminal count and spins out its no-gain budget with nothing left to do.
    const termDefault = t.folder === 'blocked' || (t.folder === 'accepted' && (t.hasIntegratedAt || t.slug === 'none' || !t.hasWorktreeBranch))
    const termOverride = t.folder === 'blocked' || t.folder === 'accepted'
    if (termDefault) dec('runtimeTerminalDefault')
    if (termOverride) dec('runtimeTerminalOverride')
  }
  const qmark = moved.map((t) => Object.assign({}, t, { quarantined: true }))
  return Object.assign({}, snap, { tasks: keep, inactive: (snap.inactive || []).concat(qmark), counts })
}
// </scheduler-pure> ==========================================================================

// Runtime retry caps. MAX_REJECT_RETRY / MAX_BLOCK_RETRY stay INSIDE the pure block as the defaults
// (phase2-scheduler.test.mjs extracts that block verbatim and must keep working standalone); the
// operator override is resolved out here, where `args` is legal.
//
// planUnblockAndTimeout already accepted o.maxReject/o.maxBlock and the production caller already
// passed the constants — but that is only ONE of four decision sites. The rejected->pending self-heal,
// the needsOperator classification and the architect's attempt-history briefing each read the
// constant directly, so binding the scheduler alone would produce an incoherent run: a task retried
// past a lowered cap, then reported as if it had not been.
const REJECT_CAP = (args && Number.isInteger(args.maxReject) && args.maxReject >= 1) ? args.maxReject : MAX_REJECT_RETRY
const BLOCK_CAP = (args && Number.isInteger(args.maxBlock) && args.maxBlock >= 1) ? args.maxBlock : MAX_BLOCK_RETRY

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
  // PRE-STEP-0, and that ordering is the whole point. The old rule ran AFTER Step 0 and greped the
  // document for a "| clean-checkout | ok |" row — but Step 0 IS a clean-checkout, and
  // clean-checkout.sh writes that row with a HARD-CODED agent field, so the reviewer's own row is
  // byte-indistinguishable from the implementer's. The rule could never fire on a genuine skip; the
  // non-files branch even said so out loud ("Step 0 recorded its own token; the refresh picks it up").
  // Since the inline dispatch path now skips the deterministic gate (the scan object predates the
  // implementer), this prose check is the only thing standing there — so it has to be asked BEFORE
  // the reviewer contaminates the evidence.
  //
  // Both arms, mirroring the deterministic gate exactly. A single-arm version reintroduces the false
  // positive fixed in c941764: a lost token with a live branch is a MECHANISM fault (append_log_row is
  // an unlocked read-modify-write), not the task's fault, and must not cost it a life.
  //
  // The pass arm does not say "continue to Step 0" (it did until 3.4.3). This same prompt is also the
  // BASE of every review-harness stage, where childPreamble forbids Step 0, so that wording would point
  // a stage at the one command its later rules prohibit. "The rest of this prompt as written" is right
  // in both places: the lone 3.1.0 reviewer still reaches Step 0, a harness stage reaches the override.
  const tokenProbe = filesStore
    ? `read the task's Transition Log at ${sq(rootPath)}`
    : `run  ${materializeCmd(t)}  and read the Transition Log of the document it prints`
  const tokenRule = `PRE-STEP-0 CHECK — do this FIRST, before Step 0, because Step 0 writes this very row:
  ${tokenProbe} and look for a "| clean-checkout | ok |" row.
    - Row present  -> the implementer did enter a worktree; this check passes. Carry on with the rest of
        this prompt as written (STEP 0 included, unless a later section tells you to skip it) and review.
    - Row ABSENT   -> run  git -C ${sq(trunkRoot)} rev-parse --verify refs/heads/${branchPrefix}/${t.slug}
        * command FAILS (no branch): nothing was ever checked out. Return transition "rejected",
          rejection_increment 1, fault_class quality, notes naming this. Do NOT run Step 0.
        * command SUCCEEDS (branch exists): the work is there but the token row was lost — a MECHANISM
          fault, not the task's fault. Return transition "rejected", rejection_increment 0,
          fault_class mechanism, notes naming this. Do NOT run Step 0.`
  const reviewSink = filesStore
    ? `Write your review comments into the ROOT task file at ${sq(rootPath)}`
    : `Record your review comments in the task store — pipe them to:  bash ${sq(STORE)} comment ${sq(t.stem)} --author quality-reviewer`
  return `${ENV}
You are quality-reviewer reviewing one acf-whip task that an implementer marked completed.
${fetchSpecStep(t)}
${tokenRule}

STEP 0: run  bash ${sq(CLEAN_CHECKOUT)} ${sq(rootPath)}  to attach to the task's worktree (branch ${branchPrefix}/${t.slug}) and validate it. If it exits non-zero, return transition "none" with the exit code in notes.

Then review the implementation against the task's Acceptance Criteria and quality gates, working in the worktree.
${reviewSink}, then end with the ACFW-RESULT marker:
  ACFW-RESULT:
    transition: accepted | rejected
    commit_sha: n/a
    rejection_increment: <0 if accepted, 1 if rejected; 0 for a mechanism fault>
    fault_class: quality | mechanism
    notes: <specific feedback>
${NO_BACKLOG_WRITES}

"mechanism" means the failure is NOT the task's fault — a broken environment, a missing worktree, a
lost clean-checkout token. It never charges the task's rejection count and the task is retried
unchanged. Use "quality" (or omit) when the WORK is what is wrong.

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
note: one line saying what happened. Then, whatever the exit code, copy EVERY line the integrator printed on stderr that starts with "WARN:" into note, verbatim and one per line, after that first line. They say when it dropped this task's edits under docs/cycles/ or overwrote uncommitted work at the root, and the recovery command they carry exists nowhere else.
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
      // Charged per ATTEMPT: a retry costs a real agent, and an undercounted ledger would let the
      // CLOSE rung fire too late to matter. Same for the tier — a retried shell call spends two.
      charge(opts)
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
    txt = await agentC(
      `${ENV}
Run EXACTLY:  bash ${sq(STORE)} snapshot --digest --mode ${mode}${ONLY_FLAGS}
Output its stdout — a single JSON object — as your ENTIRE final message. No prose, no markdown fences, nothing else. Copy it exactly: it carries a "relay" header stating how many entries it contains, and a payload that does not match is refused.`,
      shellOpts({ label, phase: 'Iterate' }),
    )
  } catch (e) { return null }
  const snap = extractJson(txt)
  return snap && snap.counts ? snap : null
}

// Release the run lock. Factored out of the end-of-run path because the ABORT paths need it too:
// a run that stops before dispatching anything (an unresolvable id, a relay it cannot trust, a
// repo-level integrity FATAL) used to `return` straight past the unlock, leaving its own heartbeat
// fresh — so the operator who fixed the typo in ten seconds was refused for the next half hour with
// "another /go run appears active". Nothing was dispatched; there is nothing to protect.
// Best-effort by construction: if it fails, the freshness window still expires the lock.
async function unlock(phaseName) {
  try {
    await agentC(`Run exactly this command and report nothing else:  rm -f ${sq(RUN_LOCK)}`,
      shellOpts({ label: 'unlock', phase: phaseName || 'Iterate' }))
  } catch (e) { /* lock expires on its own */ }
}

// The spelling git acts on, as apply-transition.sh's norm_path computes it (keep the two in step):
// git reads docs//cycles, docs/./cycles, ././docs and docs/ as one pathspec, so a guard that tests the
// spelling alone lets the others through. Collapse `//`, drop `.` segments, then a leading `./` and a
// trailing `/`; the root comes back as `.`. Each step shortens the string, so the loop ends.
function normStagePath(p) {
  let q = String(p)
  for (;;) {
    if (q.includes('//')) q = q.replace('//', '/')
    else if (q.includes('/./')) q = q.replace('/./', '/')
    else if (q.startsWith('./')) q = q.slice(2)
    else if (q.endsWith('/.')) q = q.slice(0, -2)
    else if (q.length > 1 && q.endsWith('/')) q = q.slice(0, -1)
    else break
  }
  return q || '.'
}

// Deliverable paths a NON-CODE task reported (WHIP-08). apply-transition.sh refuses a state path with
// exit 2 — which would strand the state move — so filter here too: a specialist that names .backlog/
// or an absolute path loses its staging, never its transition. Defense in depth, not duplication.
function safeStagePaths(files, stem) {
  const out = []
  for (const raw of (Array.isArray(files) ? files : [])) {
    const p = String(raw || '').trim().replace(/^\.\//, '')
    if (!p) continue
    // The writer strips one more `./` and refuses what is then empty or absolute, and it tests the
    // state paths on the normalized form (bare folders included). Mirror both, so no path it would
    // refuse with exit 2 ever reaches it.
    const seen = p.replace(/^\.\//, '')
    const key = normStagePath(p)
    const under = (dir) => key === dir || key.startsWith(`${dir}/`)
    if (!seen || seen.startsWith('/') || p.includes('..') || under('.backlog') || under('.acfwhip')) {
      log(`WARN ${stem}: ignoring unstageable deliverable path '${p}' (absolute, traversing, or a state path)`)
      continue
    }
    // 3.5.0: tasks never edit cycles. The writer commits at the shared root, where a human may be
    // half way through amending a plan.md: staging it would commit their draft and void the approval
    // at HEAD with no /whip card behind it. Skipped, never refused, so the state move still happens.
    // The bare folder counts too: `git add -- docs/cycles` stages every cycle, an untracked draft
    // included. An ancestor (`docs`, `.`) cannot be dropped here without losing its other files, so
    // the `git add` behind the writer carries an exclude pathspec for docs/cycles instead. The test
    // reads `key`, so docs//cycles/... and docs/./cycles/... are caught too; `p` is what gets passed
    // on, and the writer normalizes it the same way.
    if (under('docs/cycles')) {
      log(`WARN ${stem}: not staging '${p}': tasks never edit cycles; change a plan with /whip`)
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
    shellOpts({ label, phase: 'Iterate', schema: WRITE_BATCH }),
    () => ({ applied: [], note: 'writer agent non-emit after retries — transitions deferred to next iteration' }),
  )
}

// ==================== per-task authored child workflows (3.2.0) ====================
// runAuthoredUnit NEVER throws on the escalation path. Every exhaustion returns {via:'legacy'} and the
// caller makes the VERBATIM 3.1.0 agent() call, whose throw maps to null in the parallel thunk exactly
// as today. This feature can be slower than 3.1.0; it cannot be less correct.

const ARCHITECT = {
  type: 'object', additionalProperties: false,
  required: ['wrote', 'scriptPath', 'planKeys', 'preservedStages', 'maxAgents', 'shallow', 'summary', 'refuse', 'needsTask'],
  properties: {
    wrote: { type: 'boolean', description: 'true ONLY if you ran the scaffold AND wrote the four regions' },
    scriptPath: { type: 'string', description: 'must equal the path you were given, exactly' },
    planKeys: { type: 'array', items: { type: 'string' }, description: 'every PLANNED[].key you authored, in execution order' },
    preservedStages: { type: 'array', items: { type: 'string' }, description: 'AMEND ONLY: the completed stage keys you were handed, copied VERBATIM. Every one must also appear in planKeys. Empty on a first authoring. Never guess, never rename.' },
    maxAgents: { type: 'integer', description: 'worst-case agent() calls of ONE run of your script, loop iterations included' },
    shallow: { type: 'boolean', description: 'true if you deliberately kept the default 5-stage shape because depth would be ceremony for this task' },
    summary: { type: 'string', description: 'one line: the shape you chose and why THIS task deserves that depth' },
    refuse: { type: 'string', enum: ['none', 'dependency-missing', 'unrepairable'] },
    needsTask: { type: 'string', description: 'when refuse=dependency-missing: the missing prerequisite task an operator should create' },
  },
}
const VALIDATE = {
  type: 'object', additionalProperties: false,
  required: ['ok', 'errors', 'warnings', 'stageCount', 'mutatingStages', 'parser'],
  properties: {
    ok: { type: 'boolean' }, parser: { type: 'string' },
    errors: { type: 'array', items: { type: 'string' } },
    warnings: { type: 'array', items: { type: 'string' } },
    stageCount: { type: 'integer' }, mutatingStages: { type: 'integer' },
  },
}
const SCOUT = {
  type: 'object', additionalProperties: false,
  required: ['worktree', 'worktreeExists', 'commits', 'stageTrailers', 'dirty', 'stashes', 'stages', 'note'],
  properties: {
    worktree: { type: 'string', description: 'absolute worktree path resolved BY QUERY, or "" if none exists' },
    worktreeExists: { type: 'boolean' },
    commits: { type: 'array', items: { type: 'string' }, description: 'one-line log entries on the branch since its fork-base' },
    stageTrailers: { type: 'array', items: { type: 'string' }, description: 'every ACFW-Stage: value found in the branch commit messages' },
    dirty: { type: 'array', items: { type: 'string' }, description: 'uncommitted paths (porcelain), path only' },
    stashes: { type: 'array', items: { type: 'string' }, description: 'git stash list entries (SHARED across worktrees — never auto-pop)' },
    stages: {
      type: 'array',
      description: 'one entry per ledger line, in order',
      items: {
        type: 'object', additionalProperties: false,
        required: ['name', 'status'],
        properties: {
          name: { type: 'string' }, status: { type: 'string' },
          commit: { type: 'boolean', description: 'true when the ledger line carried "commit":true' },
          resultJson: { type: 'string', description: 'the VERBATIM "result" value of that line as JSON text, or ""' },
          payloadPath: { type: 'string' }, payloadMissing: { type: 'boolean' },
        },
      },
    },
    note: { type: 'string' },
  },
}
const WIPRESULT = {
  type: 'object', additionalProperties: false,
  required: ['porcelain'], properties: { porcelain: { type: 'string' } },
}

const childDirFor = (ctx) => `${CHILD_DIR}/${ctx.stem}/${ctx.attemptKey}/${ctx.kind}`
const scriptPathFor = (ctx) => `${childDirFor(ctx)}/harness.workflow.js`

// The child inherits the VERBATIM 3.1.x seam prompt as `BASE`, prepended to every stage — so a stage
// agent is told exactly what a 3.1.0 specialist was told, plus the ledger discipline. Nothing is retyped.
//
// Applied by childCtx for kinds 'impl' and 'review' ONLY (3.4.3). From 3.2.0 until then it was defined
// and never called, so every authored stage got the bare specialist/reviewer prompt, whose STEP 0 is
// "run clean-checkout" (the specialist's is even labelled mandatory), with nothing countermanding it:
// implement, gate-fix, and the read-only lenses runWave fans out concurrently were each told to run
// their own checkout, and clean-checkout.sh is not reentrant — its silent `stash push -u` sweeps a
// sibling stage's uncommitted work into the shared refs/stash. "The locked checkout stage is the ONLY
// clean-checkout" was stated to the ARCHITECT (WORKTREE_CONTRACT_CODE); no stage prompt carried it.
//   'direct' and 'resolve' stay UNWRAPPED, byte for byte. A non-code task has no worktree and no branch,
// so "the worktree ALREADY EXISTS / you may only ADD commits" is false there and invites a commit on the
// trunk root that bypasses the orchestrator's single writer; a resolver sits in the integrator's
// MID-CHERRY-PICK tree, where the integrator owns the one commit, and a commit made there anyway
// concludes the pick behind its back (CHERRY_PICK_HEAD vanishes, and verify-resolve reports unresolved).
//   The locked-stage exception below is load-bearing, not politeness. BASE prefixes the locked checkout
// and review-gate stages too, and on a first dispatch no worktree exists yet: a shell-tier agent that
// took an unqualified "do NOT run clean-checkout" literally would drop the else-branch, report a
// non-zero exit, and the prologue would finish 'none' (mechanism) on every attempt — a task that can
// never start, retried forever as transient.
//   The exception is keyed to the stage's KEY, never to what its instructions say. Keying it to "the
// stage whose instructions spell out the checkout command" sanctioned any AUTHORED stage that did the
// same: the validator's only guard is a literal `clean-checkout` substring, and `bash ${sq(A.cleanCheckout)}`
// — the interpolation the locked stages use, visible in the scaffold — passes it. The key is printed
// by the skeleton's locked rule() ("PROGRESS LEDGER for stage '<key>'"), and an authored stage cannot
// run under a locked key: the prologue has already filled results[key], so runStage replays it in zero
// agents, and an iteration spec's key carries a '#N' suffix.
//   Forbidding STEP 0 has a cost the old accident hid: the implement stage's STEP 0 was the second,
// sequential token write that made a lost first one heal itself, and on an ATTACHED worktree (a
// same-slug sibling, a re-dispatch) it was the only one. restoreCheckoutToken puts that write back
// in the parent, where it can be guarded on a clean tree — never as prose a stage may or may not obey.
function childPreamble(t, kind, basePrompt) {
  const lockedKey = kind === 'review' ? 'review-gate' : 'checkout'
  return `${basePrompt}

──────────── acf-whip child-harness stage rules (3.2.0) ────────────
You are ONE STAGE of a multi-stage harness for this task. These rules OVERRIDE the instructions above
and below wherever they disagree. ${NO_BACKLOG_WRITES}
SKIP the STEP 0 above: do NOT run clean-checkout. Exactly one checkout happens per task, in the
harness's locked '${lockedKey}' stage, and a second one silently stashes another stage's in-flight work
into the shared refs/stash. The ONE exception is decided by your stage's KEY, printed below on the line
"PROGRESS LEDGER for stage '<key>'": if that key is EXACTLY '${lockedKey}', run the attach-or-create
command your stage instructions give, exactly as written — that stage IS the one checkout. For ANY other
key, never run clean-checkout (nor the script behind it) even if your stage instructions spell out such
a command: the worktree ALREADY EXISTS and its path was given to you as text.
FORBIDDEN in the worktree: git merge, git rebase, git pull, git reset, git stash, deleting the worktree
or branch, switching branches, and any write to .backlog/ or .acfwhip/. You may only ADD commits to
this task's own branch — the integrator rebuilds the candidate from the branch tree, so rewriting
history or merging trunk corrupts it.
Best effort FIRST, ignore failure:  mkdir -p ${sq(RUN_LOCK_DIR)} && touch ${sq(RUN_LOCK)}
`
}

// The porcelain `worktree <path>` line, parsed WHOLE. `p=$2` (what this file used until 3.4.3, and what
// the skeleton's locked stages still use) cuts a path at its first space, and a repo under
// `~/My Projects/` or iCloud's `Mobile Documents/` is ordinary. In the scout a cut path only misreports
// worktreeExists=false; in restoreCheckoutToken it fed the clean-tree probe that guards the one
// command that stashes. substr from column 10 = everything after the 9-byte "worktree " prefix.
const WT_BY_BRANCH_AWK = (branch) => `awk -v b="branch refs/heads/${branch}" '/^worktree /{p=substr($0,10)} $0==b{print p; exit}'`

function scoutPrompt(ctx) {
  return `${ENV}
Read-only reconnaissance for one acf-whip task's harness. Change NOTHING.

1. Resolve the worktree BY QUERY (never by constructing a path — the worktree dir is config-driven and
   the constructed path can differ from the real one):
     WT=$(git -C ${sq(trunkRoot)} worktree list --porcelain | ${WT_BY_BRANCH_AWK(ctx.branch)})
   Report it as worktree, and worktreeExists=true only if it is non-empty and the directory exists.
2. If it exists, report:
     git -C "$WT" log --oneline ${sq(ctx.forkbaseRef)}..HEAD | head -40          -> commits
     git -C "$WT" log --format=%B ${sq(ctx.forkbaseRef)}..HEAD | sed -n 's/^ACFW-Stage: *//p'  -> stageTrailers
     git -C "$WT" status --porcelain | head -60                                   -> dirty (paths only)
     git -C "$WT" stash list | head -10                                           -> stashes
   If the fork-base ref does not resolve, use the branch's full log instead and say so in note.
3. Read the stage ledger (absent is normal — that means round 0):
     bash ${sq(LEDGER_BIN)} read ${sq(ctx.ledgerDir)} 2>/dev/null || true
   Each output line is one JSON object. For each, report name (its "stage"), status, commit (true only
   if the line contains "commit":true), resultJson (the VERBATIM text of its "result" value, or ""),
   payloadPath (its "payload" value, or ""), and payloadMissing (true if payloadPath is set but
   ${sq(ctx.ledgerDir)}/<that path> does not exist).

Copy values EXACTLY. Do not summarize, repair, or pretty-print any JSON. Return the ScoutResult.`
}

async function scout(ctx) {
  const r = await safeAgent(scoutPrompt(ctx), shellOpts({ label: `scout:${ctx.kind}:${ctx.key}`, phase: ctx.phase, schema: SCOUT }), () => null)
  const empty = { worktree: '', worktreeExists: false, commits: [], trailers: [], dirty: [], stashes: [], stages: [], names: [], priorStages: {}, dropped: [], note: 'scout non-emit' }
  if (!r) return empty
  const stages = (r.stages || []).map((s) => {
    let result
    if (s.resultJson) { try { result = JSON.parse(s.resultJson) } catch (e) { result = undefined } }
    return { name: s.name, status: s.status, commit: s.commit === true, result, payloadPath: s.payloadPath || '', payloadMissing: s.payloadMissing === true }
  })
  const git = { worktreeExists: r.worktreeExists === true }
  const rec = reconcileChildProgress(stages, r.stageTrailers || [], git)
  return {
    worktree: r.worktree || '', worktreeExists: r.worktreeExists === true,
    commits: r.commits || [], trailers: r.stageTrailers || [], dirty: r.dirty || [], stashes: r.stashes || [],
    stages, names: rec.names, priorStages: rec.priorStages, dropped: rec.dropped, note: r.note || '',
  }
}

// The harness MENU — what a script structurally buys over one strong agent, and when each pays.
const HARNESS_MENU = `
  A. PARALLEL RECON (fan, read-only) — N agents each mapping a different facet, merged into one brief.
     PAYS: unfamiliar or large surface; Touches Globs spanning more than one module; a first attempt.
     SKIP: a single-file change; a retry where the surface is already understood — spend on G instead.
  B. COMPETING PLANS, JUDGED — 2-3 agents read READ-ONLY and each propose an approach; one judge picks
     or merges; ONE implementer executes the winner.
     HARD CONSTRAINT: you may NOT run competing IMPLEMENTATIONS. Only one agent can hold this task's
     worktree — the slug IS the branch and the branch IS the lock. Compete on PLANS, never on code.
     PAYS: a real architectural fork; high blast radius; a retry rejected on DESIGN grounds.
  C. TEST-FIRST SPLIT — a stage that writes tests which FAIL and encode the Acceptance Criteria, then a
     stage that makes them pass without weakening them. SEQUENTIAL: one worktree, one writer.
     PAYS: crisp binary criteria (this backlog mandates them); category bug; category test.
  D. ADVERSARIAL DIFF REVIEW — a FRESH agent reads the branch diff against the Acceptance Criteria and
     TRIES TO REJECT it; the implementer fixes; at most two rounds. IN THE DEFAULT BODY ALREADY.
     HIGHEST ROI on this menu, for an acf-whip-specific reason: it converts EXTERNAL rejections —
     expensive, capped, terminal at the cap — into INTERNAL ones that cost one agent and are uncapped.
  E. LOOP-UNTIL-GATES-GREEN — a bounded loop over a schema'd {passed, failingOutput} gate stage; on
     failure a fixer stage gets the verbatim output. IN THE DEFAULT BODY ALREADY.
     This is the thing one agent structurally cannot do: the advance condition is an OBSERVED FIELD,
     not a self-report. One agent conflates "I ran the gates" with "the gates passed".
     LOOPS ARE SPECIAL — read THE ITERATION RULE below or your loop will silently freeze.
  F. MULTI-MODAL CALL-SITE FAN (read-only) — parallel agents each using a DIFFERENT modality: exact
     grep, symbol references, tests and fixtures, docs+config+string literals, generated code. Union
     the results in plain JS.
     PAYS: category refactor; renaming or moving a public symbol; broad globs. Any single modality
     misses call sites, and a missed one either fails the gates or passes them and breaks at runtime.
  G. DIAGNOSIS-FIRST — stage 1 writes NO code: it reads the prior review comments, the Transition Log
     and the existing diff and states WHY this was rejected and what specifically must change. Every
     later stage receives that diagnosis.
  H. CHUNKED PIPELINE — independently verifiable chunks with a gate between them, so a late failure
     does not discard early verified work (each chunk is separately ledgered and replays for free).
     PAYS: large tasks; 6+ acceptance criteria.`

function architectPrompt(ctx, budget, round, lastErr, prior) {
  const amend = round > 0
  const preserved = prior.names.length ? prior.names.join(', ') : '(none)'
  const amendBlock = amend ? `
════════════════════════ THIS IS AN AMEND (round ${round}/${MAX_AMEND}) ════════════════════════
Your previous harness did NOT complete. The error:
${String(lastErr || '(unknown)').slice(0, 1200)}

WORK THAT IS ALREADY DONE AND MUST NOT BE REDONE:
  completed stages ... ${preserved}
  commits on branch . ${prior.commits.length ? prior.commits.slice(0, 12).join(' | ') : '(none)'}
  uncommitted paths . ${prior.dirty.length ? prior.dirty.slice(0, 12).join(' ') : '(none)'}
  ${prior.dropped.length ? `dropped (git could not confirm them; they WILL re-run): ${prior.dropped.join(', ')}` : ''}
  ${prior.stashes.length ? `⚠ this worktree has ${prior.stashes.length} stash entry/entries — inspect before proceeding; refs/stash is SHARED across worktrees, so never blindly pop.` : ''}

Every completed stage key above MUST appear in your PLANNED and in a runStage call in the body, spelled
EXACTLY as given, and must be listed in preservedStages. The harness replays their recorded results in
ZERO agents. Renaming or dropping one is rejected by pre-flight before a single agent spawns, because
it would redo finished work.

Fix the CAUSE of the error. Do not rewrite the harness from scratch.
` : ''
  return `${ENV}
You are the WORKFLOW ARCHITECT for one acf-whip ${ctx.kindLabel}. You do NOT do the work. You COPY a
committed skeleton, fill in four marked regions, and stop. /go then runs your file and consumes its
return value exactly as it used to consume a single specialist agent's return value.

Your product is ONE FILE. Its quality is the only thing that matters.
${amendBlock}
════════════════════════ WHAT YOU ARE GIVEN ════════════════════════
  kind ................ ${ctx.kind}
  skeleton ............ ${sq(SKELETON)}            <- READ THIS FIRST, IN FULL
  scaffold command .... bash ${sq(SCAFFOLD)} ${sq(ctx.scriptPath)} --kind ${ctx.kind} --stem ${sq(ctx.stem)} --meta-name ${sq(ctx.metaName)} --trunk-root ${sq(trunkRoot)}
  write your file to .. ${sq(ctx.scriptPath)}
  task document ....... ${sq(ctx.taskPath)}${ctx.materialize ? `   (run this FIRST: ${ctx.materialize})` : ''}
  assigned agent ...... ${ctx.agent || '(none)'}
  worktree slug ....... ${ctx.slug}       branch: ${ctx.branch}
  installed agentTypes  ${REGISTRY.join(', ') || '(none)'}
      ^ the COMPLETE set your script may dispatch. There are no others. Read any of
        ${trunkRoot}/.claude/agents/<name>.md to learn what a specialist is actually for.
  attempt history ..... rejectionCount=${ctx.rejectionCount}/${REJECT_CAP}   blockCount=${ctx.blockCount}/${BLOCK_CAP}
  ledger generation ... ${ctx.attemptKey}       (NEVER derive your own)
  your ceiling ........ ${budget} agent() calls TOTAL, at most ${ctx.fanoutMax} per fan-out

════════════════════════ STEP 1 — READ BEFORE YOU DESIGN ════════════════════════
1. The skeleton. You cannot author correctly without knowing what it already does for you.
2. The task document. Its Acceptance Criteria are your harness's TERMINATION CONDITION; its Touches
   Globs are your surface; its Out of Scope is your boundary.
3. **The task's Transition Log and every review comment in the document.** If rejectionCount or
   blockCount is above zero, THIS TASK HAS ALREADY FAILED and a reviewer wrote down WHY, right there.
   That text is the most valuable input you have. A retry harness that does not begin by consuming it
   is negligent — there are only ${REJECT_CAP} rejections before this task is blocked permanently.
4. The real code in ${trunkRoot} that the Touches Globs actually name — how the neighbouring code is
   structured and how it is tested.
5. The project's quality gates: docs/development/quality-gates-*.md plus the repo's own config
   (Makefile, package.json scripts, pyproject.toml, .pre-commit-config.yaml, go.mod).
   RESOLVE THE GATE COMMANDS NOW and bake the LITERAL commands into the stage prompts you write. Do not
   make your stages rediscover them. A wrong gate command costs this task a third of its life.
6. CLAUDE.md and docs/acf/ for conventions the implementation must obey.

════════════════════════ STEP 2 — CHOOSE THE HARNESS ════════════════════════
The scaffold's DEFAULT BODY is already a correct five-stage harness:
    checkout -> implement -> bounded gate loop -> adversarial diff review -> verify
Those five hold the only three mechanisms a script structurally buys over one strong agent: a
schema-OBSERVED advance condition, a fresh-context reviewer of the diff, and a durable ledger.
KEEPING IT — and setting shallow=true with a one-line reason — IS A CORRECT ANSWER for a config bump,
a version bump, a single-file doc edit, or anything whose surface you already understand. Do not pad.
Do NOT under-build a task that has already been rejected.

Add from this menu when the task shape calls for it. Depth is YOUR judgement within the ceiling.
${HARNESS_MENU}
${ctx.rejectionCount >= 1 || ctx.blockCount >= 1 ? '\n  ⚠ MENU ITEM G IS MANDATORY FOR THIS TASK: it has already failed ' + (ctx.rejectionCount + ctx.blockCount) + ' time(s).\n' : ''}
════════════════════════ STEP 3 — FILL EXACTLY FOUR REGIONS ════════════════════════
Run the scaffold command FIRST. Then edit ONLY between these marker pairs. Every locked segment is
byte-diffed against the shipped skeleton and /go REFUSES to run a file whose locked segments differ.

  // <acfw-meta> ... // </acfw-meta>
      name / description / phases. PURE LITERALS — no template literals, no interpolation, no
      concatenation, no function calls. The runtime parses this BEFORE your code exists.
      Write  name: '${ctx.metaName}'  exactly, as a quoted literal. It MUST contain the stem: the
      runtime groups your child's agents under "▸ <meta.name>", and if every harness is named the same
      a supervisor watching seven concurrent harnesses cannot tell them apart.

  // <acfw-plan> ... // </acfw-plan>
      PLANNED = [ { key, label, agentType, producesCommit, mutates, maxAgents }, ... ]  — a pure literal.
      SHALLOW = '<one line why shallow>'  or  SHALLOW = ''
      Keys unique, lowercase-kebab, STABLE across amendments. agentType from the installed list or ''.
      Sum of maxAgents <= ${budget}. producesCommit:true on any stage whose agent commits.
      mutates:true on any stage that edits files, runs git add/commit, OR RUNS THE BUILD OR TEST SUITE
      (that writes target/, __pycache__, coverage, formatter rewrites).

  // <acfw-pre> ... // </acfw-pre>
      OPTIONAL read-only stages that must precede the checkout. Usually EMPTY.

  // <acfw-body> ... // </acfw-body>
      Your stages, and the plain-JS control flow between them.

INSIDE A REGION YOU MAY WRITE:
    await runStage(spec) · await runWave([spec, ...]) · log(...) · ordinary JS control flow
    reads of results / WT / BASE / RESULT / LENS / GIT / A.* · assignment to the declared outputs:
    want, finalNote, blockedReason, needsTask, deliverableFiles, lensVerdicts, resolveOk, resolveStaged

YOU MAY NOT WRITE — each is checked before your file runs, and each is a hard pre-flight failure:
  • a bare  agent(  ·  parallel(  ·  pipeline(  ·  workflow(  — everything goes through runStage/runWave.
    workflow() in particular: nesting is ONE LEVEL ONLY and YOU ARE that level.
  • a top-level  return   (except  return finish(...)  , allowed on an error path)
  • Date.now() · Math.random() · argless new Date()  — the runtime throws on these.
    Need a timestamp? Have an AGENT run  date -u +%FT%TZ  in its shell command.
  • import / require / fs / path / process / child_process / eval — a workflow script has NO filesystem
    and NO Node API. Agents do ALL I/O.
  • TypeScript of any kind: type annotations, interfaces, generics, \`as\`, enums.
  • isolation: on any spec — acf-whip provides its OWN worktree isolation.
  • while (true) · for (;;) — you have no clock and no timer, so an unbounded loop hangs the whole /go
    iteration. Every loop gets a literal integer bound.
  • the literal text  clean-checkout  anywhere in your regions (see the WORKTREE CONTRACT).
  • a  .worktree/  path literal — the worktree path is not knowable at authoring time; it is the locked
    checkout stage's stdout, already bound to the variable WT.
  • an agentType that is not in the installed list, or a COMPUTED agentType (it must be a literal).
  • .acfwhip/integrated — that is the LP-CAS ledger; writing it QUARANTINES this task.

════════════════════════ THE ITERATION RULE (read this twice) ════════════════════════
A stage key is a DURABLE LEDGER KEY. runStage returns the RECORDED result for any key that already
completed, WITHOUT dispatching an agent. That is what makes a throw cost one stage instead of the task.
It also means a loop that reuses ONE key runs its agent exactly once and then spins on a frozen result.

  WRONG — the gate runs once and iterations 2 and 3 replay its failure:
    for (let i = 0; i < 3; i++) { const g = await runStage({ key: 'gate', ... }) ; ... }

  RIGHT — every iteration is its own durable stage:
    for (let i = 0; i < 3; i++) {
      const g = await runStage({ key: 'gate', iteration: i, ... })
      if (g.__failed || g.passed) break
      const f = await runStage({ key: 'gate-fix', iteration: i, ... })
      if (f.__failed) break
    }

Pass  iteration:  on EVERY runStage/runWave call inside any for/while body. Pre-flight rejects a loop
without it.

════════════════════════ RESULTS ARE ALWAYS OBJECTS ════════════════════════
runStage NEVER returns null. On agent flakiness (a StructuredOutput non-emit after its two internal
tries) or an exhausted budget it returns  { __failed: true } . So  r.field  is always safe;
r.field.sub  is NOT. Test  if (r.__failed) ...  and use  ?.  for anything deeper than one level.
runWave returns an array the same length as its input, with __failed entries in place.
Agent flakiness is TRANSIENT — /go retries the task next iteration. It is not a defect to repair.

════════════════════════ WORKTREE CONTRACT (violating this destroys work) ════════════════════════
${ctx.worktreeContract}

════════════════════════ ${ctx.kindNote} ════════════════════════
${ctx.kindGuidance}

Now do Step 1, then Step 2, then run the scaffold and write the four regions. Return the
ArchitectResult: scriptPath, planKeys in execution order, preservedStages copied verbatim from the
completed list, maxAgents (worst case, loops included), shallow, one line on why this depth, refuse.`
}

function validatePrompt(ctx, requireStages) {
  return `Run EXACTLY this command and copy its output into the ValidateResult:
  bash ${sq(VALIDATE_BIN)} ${sq(ctx.scriptPath)} ${sq(trunkRoot)} --kind ${sq(ctx.kind)} --require-stages ${sq((requireStages || []).join(','))} --fanout ${ctx.fanoutMax} --budget ${ctx.agentBudget} --registry ${sq(REGISTRY.join(','))} --stem ${sq(ctx.stem)}
It prints ONE JSON line. Copy its fields into the ValidateResult VERBATIM. Add nothing. Judge nothing.
Do not fix the script. Do not run it.`
}

const WORKTREE_CONTRACT_CODE = `Exactly ONE agent may write in this task's worktree at a time, and "write" includes editing files,
running git add or git commit, AND RUNNING THE BUILD OR TEST SUITE (which produces target/,
__pycache__, node_modules/.cache, coverage output, generated code and formatter rewrites).
  * The locked checkout stage is the ONLY clean-checkout. Every other stage receives WT as text.
    Never put A.cleanCheckout (or TASKPATH as a script argument) in an authored stage: every stage's
    rules deny that command to every key but the locked one, so such a stage fails instead of running.
  * Mark every writing stage mutates:true. runWave FORCES mutating specs sequential after its
    read-only chunk, so a mislabelled mutates costs throughput but never correctness.
  * Read-only is the parallel lane: recon, call-site census, dependency mapping, review lenses,
    adversarial judging, per-file analysis. Those may fan out freely.
  * Commit before you finish. The locked verify stage refuses to report completed on a dirty tree,
    because the REVIEWER's own checkout would stash your uncommitted work away and the task would then
    be rejected for having no implementation.
  * NEVER merge, rebase, pull, reset, stash, switch branches, or delete the worktree. The integrator
    rebuilds this task's candidate from the branch TREE, so N ordinary commits are fine and any history
    rewriting or trunk merge corrupts it.`

function childCtx(kind, t, basePrompt, folder, waveWidth) {
  const key = t.slug === 'none' ? t.stem : t.slug
  const attemptKey = attemptKeyOf(t)
  const ctx = {
    kind, t, stem: t.stem, slug: t.slug, key, attemptKey,
    agent: t.agent, branch: `${branchPrefix}/${t.slug}`,
    forkbaseRef: `refs/acfw/forkbase/${t.slug}`,
    taskPath: taskLoc(t, folder),
    materialize: filesStore ? '' : materializeCmd(t),
    rejectionCount: t.rejectionCount || 0, blockCount: t.blockCount || 0,
    // The stage rules are appended HERE, by kind, rather than at the call sites: this is the one place
    // every harness's BASE passes through, so a future call site cannot forget them. impl/review only —
    // childPreamble says why direct/resolve must stay byte-identical. The legacy fallbacks never read
    // ctx.basePrompt (each calls agentC with its own bare prompt), and that matters: a single 3.1.0
    // agent MUST run its own STEP 0, and the preamble would tell it to skip the only checkout it gets.
    basePrompt: (kind === 'impl' || kind === 'review') ? childPreamble(t, kind, basePrompt) : basePrompt,
    phase: 'Iterate',
    metaName: `whip-${kind}-${t.stem}`.slice(0, 90),
    agentBudget: FULL_BUDGET, fanoutMax: fanoutFor(waveWidth),
    enabled: true, worktreeContract: WORKTREE_CONTRACT_CODE,
  }
  ctx.ledgerDir = childDirFor(ctx)
  ctx.scriptPath = scriptPathFor(ctx)
  if (kind === 'impl') {
    ctx.kindLabel = 'implementation task'
    ctx.kindNote = 'SINGLE-MUTATOR RULE'
    ctx.kindGuidance = 'Parallelize recon, localization, per-module analysis, call-site census and design critique. Serialize everything that touches the tree.'
  } else if (kind === 'direct') {
    ctx.kindLabel = 'non-code task'
    ctx.kindNote = 'NON-CODE TASK — NO WORKTREE'
    ctx.kindGuidance = 'You work in the trunk root and COMMIT NOTHING. Every file you create or modify outside .backlog/ must be assigned to deliverableFiles — the orchestrator\'s single writer stages exactly those paths in the same commit as the state move. A file you do not list is never committed and the next checkout DESTROYS it. This has permanently lost finished work.'
    ctx.worktreeContract = 'This task has NO worktree and NO branch. Do not run clean-checkout. Do not commit. Report every file you touched in deliverableFiles.'
  } else if (kind === 'review') {
    ctx.kindLabel = 'quality review'
    ctx.kindNote = 'REVIEW LENSES ARE READ-ONLY'
    ctx.kindGuidance = 'The locked gate stage has already attached to the worktree and run the quality gates; its output is in gate.gateOutput. Your lenses are STRICTLY READ-ONLY: no writes, no git add, no test runs. Author 3-5 lenses appropriate to THIS diff (acceptance-criteria conformance, call-site completeness, security, error and edge paths, test adequacy, public-API stability, docs). Each returns {lens, verdict, severity, findings, evidence} and you assign the array to lensVerdicts. THE VERDICT IS NOT YOURS — the locked epilogue folds the lenses in pure JS, by strict majority, with no veto.'
  } else {
    ctx.kindLabel = 'merge-conflict resolution'
    ctx.kindNote = 'MID-CHERRY-PICK TREE'
    ctx.kindGuidance = 'The integration worktree is MID-CHERRY-PICK. Author ONE READ-ONLY analyst per conflicted file (mutates:false; they may git show / git log / read files and they NEVER run git add — staging a path clears its unmerged state regardless of content, and the integrator\'s completion oracle is exactly that state being empty). Then exactly ONE mutates:true stager that edits and stages the ENUMERATED conflicted paths — never git add -A, because the integrator already does add -A afterwards and any stray file you leave rides onto trunk. Never run cherry-pick --continue/--commit/--abort/--quit, never git reset, never run the build in that tree, never leave a scratch file.'
    ctx.worktreeContract = 'This tree is MID-CHERRY-PICK and belongs to the integrator. You may edit conflicted files and git add exactly those paths. Nothing else.'
  }
  return ctx
}

function childArgs(ctx, budget, prior, round) {
  return {
    stem: ctx.stem, slug: ctx.slug, branch: ctx.branch, forkbaseRef: ctx.forkbaseRef,
    taskPath: ctx.taskPath, ledgerDir: ctx.ledgerDir, ledgerBin: LEDGER_BIN, runLock: RUN_LOCK,
    basePrompt: ctx.basePrompt, resultSchema: ACFW_RESULT, lensSchema: REVIEW_LENS,
    shellModel: SHELL_MODEL, shellEffort: EFFORTS.shell || '', agentModels, agentBudget: budget, fanoutMax: ctx.fanoutMax,
    registry: REGISTRY, agentType: ctx.agent && ctx.agent !== 'none' ? ctx.agent : '',
    git: { commits: prior.commits, dirty: prior.dirty, worktree: prior.worktree },
    trunkRoot, cleanCheckout: CLEAN_CHECKOUT, priorStages: prior.priorStages,
    shallow: ctx.shallow === true, conflictedFiles: ctx.conflictedFiles || '',
    resolverWorktree: ctx.resolverWorktree || '', round,
  }
}

const REVIEW_LENS = {
  type: 'object', additionalProperties: false,
  required: ['lens', 'verdict', 'findings'],
  properties: {
    lens: { type: 'string' },
    verdict: { type: 'string', enum: ['accept', 'reject'] },
    severity: { type: 'string' },
    findings: { type: 'string', description: 'specific, with file:line evidence' },
    evidence: { type: 'string' },
  },
}

// Preserve the harness's uncommitted work before the LEGACY path re-runs clean-checkout, whose Step 6
// does `git stash push -u ... || true` on ANY dirty state, silently, into the SHARED refs/stash.
// Without this the fallback destroys exactly what the durability design exists to protect.
async function preserveBeforeLegacy(ctx, prior) {
  if (ctx.slug === 'none' || !prior || !prior.dirty.length || !prior.worktree) return
  await safeAgent(`${ENV}
Preserve in-flight work before a fallback dispatch. In ${sq(prior.worktree)} run EXACTLY:
  git -C ${sq(prior.worktree)} add -A -- . ':(exclude).backlog' ':(exclude).acfwhip'
  git -C ${sq(prior.worktree)} commit -q -m 'wip: harness partial (acf-whip fallback)' || true
  git -C ${sq(prior.worktree)} status --porcelain
Report the final porcelain output. Change nothing else. Never run clean-checkout, stash, reset or rebase.`,
    shellOpts({ label: `wip:${ctx.key}`, phase: ctx.phase, schema: WIPRESULT }), () => null)
  log(`  ${ctx.stem}: committed ${prior.dirty.length} in-flight path(s) as WIP before the fallback dispatch`)
}

// Put back the token write that wiring childPreamble took away (3.4.3). The locked checkout stage runs
// clean-checkout.sh only when NO worktree exists; when one does it just echoes the path, because a
// second clean-checkout on a dirty tree stashes that work into the shared refs/stash. Until 3.4.3 the
// gap was covered by accident: every stage got the bare specialist prompt, whose mandatory STEP 0
// re-ran clean-checkout on the freshly attached (clean) tree and re-recorded the token as a side
// effect. The preamble now forbids STEP 0, so a harness that ATTACHES writes no token at all — and that
// is not a corner case. The worktree is per SLUG and outlives integration, so every same-slug sibling
// after the first attaches; so does every re-dispatch after clean-checkout created the worktree and then
// failed to record the token (a non-files log-event refusal, exit 6). Such a task completes, its review
// finds the branch without the token (a mechanism fault), the tokenStrand arm parks it, the unblock pass
// re-queues it, and — attempt key unchanged — the harness replays every stage in zero agents, checkout
// included, writing no token again. Parked, re-queued, parked: forever.
//   So here, deterministically and BEFORE the harness: when the scan saw the branch but no token, run
// the SAME command the locked stage would, and only on a CLEAN attached tree. There clean-checkout skips
// creation, has nothing to stash, re-validates the branch and records the token. A dirty tree is left
// alone (the one case where a second stash destroys work; the harness's verify commits it, so the next
// re-dispatch finds it clean), and so is a missing worktree (the locked stage creates it and records
// the token itself). It never DEFERS the harness: clean-checkout can fail for reasons no retry fixes —
// it tests the CONSTRUCTED path, so a worktree whose real path differs exits 2 every time — and a task
// that never starts is worse than one the review gate parks. Escalation-off and budget-rung dispatches
// never get here: their 3.1.0 specialist runs its own STEP 0.
//   The scan-time object is a sound witness HERE, unlike on the inline review path: it was read at this
// iteration's plan, after every earlier dispatch of the task had ended (parallel() is a barrier). `!==
// true`, not `=== false`: an unanswered field costs one cheap re-record, which is idempotent on a clean
// tree; guessing "present" costs the forever-loop above.
function needsTokenRestore(t) {
  return !!t && !!t.slug && t.slug !== 'none' && t.hasWorktreeBranch === true && t.hasCleanCheckoutToken !== true
}
const TOKENRESTORE = {
  type: 'object', additionalProperties: false, required: ['outcome', 'exitCode'],
  properties: {
    outcome: { type: 'string', enum: ['restored', 'unrecorded', 'dirty', 'unreadable', 'no-worktree', 'failed'] },
    exitCode: { type: 'integer' },
  },
}
async function restoreCheckoutToken(ctx) {
  // files: clean-checkout only WARNs when append_log_row refuses and still exits 0, so exit 0 proves
  // nothing there — the row itself is the evidence. A non-files store fails log-event LOUDLY (exit 6),
  // so there exit 0 already means the durable write landed.
  const verify = filesStore
    ? `
    elif ! grep -qE '\\| clean-checkout \\| ok \\|' ${sq(ctx.taskPath)}; then echo 'OUTCOME unrecorded'`
    : ''
  const mat = ctx.materialize ? `${ctx.materialize} >/dev/null; ` : ''
  // The clean-tree probe FAILS CLOSED, because the command it guards is the stashing one. The 3.4.3
  // original read `[ -n "$(git -C "$WT" status --porcelain)" ]`: when `git -C` cannot enter the tree
  // (a path cut at a space, a worktree directory deleted by hand) git prints its fatal to stderr and
  // NOTHING to stdout, the empty string reads as CLEAN, and clean-checkout — which finds the real tree
  // from the constructed path — stashes the live work into refs/stash and reports success. So the
  // status call's own exit is tested first, and an unreadable tree is never treated as a clean one.
  const r = await safeAgent(`${ENV}
Re-record this task's clean-checkout token before its harness runs. Run EXACTLY this, ONCE:
  WT=$(git -C ${sq(trunkRoot)} worktree list --porcelain | ${WT_BY_BRANCH_AWK(ctx.branch)})
  if [ -z "$WT" ]; then echo 'OUTCOME no-worktree'
  elif ! S=$(git -C "$WT" status --porcelain); then echo 'OUTCOME unreadable'
  elif [ -n "$S" ]; then echo 'OUTCOME dirty'
  else ${mat}bash ${sq(CLEAN_CHECKOUT)} ${sq(ctx.taskPath)} >/dev/null; rc=$?
    if [ "$rc" -ne 0 ]; then echo "OUTCOME failed $rc"${verify}
    else echo 'OUTCOME restored'; fi
  fi
Report outcome (the word after OUTCOME) and exitCode (the number after "failed", else 0). Change nothing
else: never run clean-checkout a second time or any other way, never stash, reset, commit or edit a file.`,
    shellOpts({ label: `token:${ctx.key}`, phase: ctx.phase, schema: TOKENRESTORE }), () => null)
  const o = r && r.outcome
  if (o === 'restored') log(`  ${ctx.stem}: clean-checkout token re-recorded on the existing ${ctx.branch} worktree before its harness`)
  else if (o === 'dirty') log(`⚠ ${ctx.stem}: no clean-checkout token, and ${ctx.branch}'s worktree has uncommitted work — NOT re-running clean-checkout (it would stash that work into the shared refs/stash); the harness runs, and the review gate treats the missing token as a mechanism fault`)
  else if (o === 'unreadable') log(`⚠ ${ctx.stem}: no clean-checkout token, and git could not read ${ctx.branch}'s worktree status — NOT re-running clean-checkout (an unread tree is never assumed clean: that is the one command that can stash its work); the harness runs, and the review gate treats the missing token as a mechanism fault`)
  else if (o !== 'no-worktree') log(`⚠ ${ctx.stem}: could not re-record the clean-checkout token on ${ctx.branch} (${o ? `${o}${r.exitCode ? ` exit ${r.exitCode}` : ''}` : 'no emit'}) — the harness runs anyway; the review gate treats the missing token as a mechanism fault`)
  return o || 'no-emit'
}

// Before an INLINE review panel only: is the clean-checkout token actually there? (3.4.3)
// On the inline path the scan-time object predates the implementer, so runReviewAndIntegrate skips its
// deterministic token gate and leaves the question to reviewerPrompt's PRE-STEP-0 CHECK — whose
// "branch exists -> rejected, fault_class mechanism" arm only a single ACFW_RESULT reviewer can
// express. A panel lens answers REVIEW_LENS (accept | reject, no fault class), and the locked
// aggregate() has no token-shaped mechanism exit, so every lens rejects, the strict majority folds to
// finish('rejected', …, 'quality'), and reviewVerdict charges one of the task's three lives for a
// mechanism fault. restoreCheckoutToken's dirty/unreadable/failed/unrecorded outcomes all end here.
//   So the parent asks first, deterministically, and anything short of a positively observed row —
// absent, unreadable, a probe that never emits — skips the panel and leaves the task in in-review/.
// That is not a new verdict path: the next scan observes the task AFTER its implementation, so the
// existing typed gate decides it (branch exists -> mechanism, re-reviewed then parked with inc 0;
// no branch -> the same inc-1 auto-reject the lone reviewer would have returned). The deferral is
// bounded by construction — only the inline path probes, and a task is inline once per completion.
const TOKENPROBE = {
  type: 'object', additionalProperties: false, required: ['token'],
  properties: { token: { type: 'string', enum: ['present', 'absent'] } },
}
async function reviewTokenObserved(ctx) {
  const probe = filesStore
    ? `if grep -qE '\\| clean-checkout \\| ok \\|' ${sq(ctx.taskPath)}; then echo 'TOKEN present'; else echo 'TOKEN absent'; fi`
    : `if P=$(${ctx.materialize}) && [ -n "$P" ] && grep -qE '\\| clean-checkout \\| ok \\|' "$P"; then echo 'TOKEN present'; else echo 'TOKEN absent'; fi`
  const r = await safeAgent(`${ENV}
Check this task's clean-checkout token before its review panel runs. Run EXACTLY this, ONCE:
  ${probe}
Report token (the word after TOKEN). Change nothing: never run clean-checkout, never edit or commit.`,
    shellOpts({ label: `token-probe:${ctx.key}`, phase: ctx.phase, schema: TOKENPROBE }), () => null)
  return { present: !!r && r.token === 'present', why: r ? `token ${r.token}` : 'probe non-emit' }
}

async function runAuthoredUnit(ctx) {
  if (!ESCALATE) return { via: 'legacy', why: 'escalation off' }
  if (!ctx.enabled) return { via: 'legacy', why: `${ctx.kind} escalation disabled` }

  // Lane FIRST, then tier. The tier check must be on the far side of the lane or every unit in a wave
  // samples the same pre-wave agentsUsed, all read FULL, and the ladder can never fire mid-wave.
  await acquireLane()
  try {
    const tier = escalationTier(agentsUsed, AGENT_CAP, CAP_RESERVE)
    if (tier === 'DIRECT' || tier === 'CLOSE') { esc.fellBack++; return { via: 'legacy', why: `agent-budget tier ${tier}` } }
    const budget = tier === 'LEAN' ? LEAN_BUDGET : ctx.agentBudget
    ctx.agentBudget = budget

    // AFTER the tier check, so the probe is paid only when a panel is really about to run (a DIRECT or
    // CLOSE rung hands the review to the lone 3.1.0 reviewer, whose PRE-STEP-0 CHECK types the fault
    // itself), and BEFORE the scout, which a panel that will not run has no use for.
    if (ctx.kind === 'review' && ctx.tokenStale) {
      const tk = await reviewTokenObserved(ctx)
      if (!tk.present) return { via: 'defer', why: tk.why }
    }

    let prior = await scout(ctx)   // before round 0 too: a re-dispatch may already have progress
    // Once per dispatch, never per amend round: after round 0 the harness itself may have dirtied the
    // tree, and the whole point of the guard is that no second checkout ever runs against live work.
    if (ctx.kind === 'impl' && needsTokenRestore(ctx.t)) await restoreCheckoutToken(ctx)
    let lastErr = '', round = 0

    while (round <= MAX_AMEND) {
      // ---- 1. AUTHOR / AMEND. Real design work => NO model option (session model), like specialists.
      const aopts = { label: `arch:${ctx.kind}:${ctx.key}${round ? `:amend${round}` : ''}`, phase: ctx.phase, schema: ARCHITECT }
      // The architect persona is optional, but its ABSENCE used to be completely silent: the agent has
      // been documented since 3.2.0 and no installer ever created it, so registryHas was false on
      // every project and the headline capability degraded to the default agent everywhere, for two
      // releases, with nothing in the log or the report to say so. Announce it once per run; the
      // report carries it too, so a run that quietly used the fallback is distinguishable afterwards.
      if (registryHas('workflow-architect')) aopts.agentType = 'workflow-architect'
      else if (!archMissingLogged) {
        archMissingLogged = true
        log('⚠ no workflow-architect agent installed — harnesses are being authored by the default agent (run /whip-init to install it: content/agent-patterns/universal/workflow-architect-pattern.md)')
      }
      // Tagged, not counted: safeAgent is the charge point, so a retried architect call spends two.
      tierOf.set(aopts, 'architect')
      const a = await safeAgent(architectPrompt(ctx, budget, round, lastErr, prior), aopts, () => null)
      if (!a || a.wrote !== true) { esc.fellBack++; return { via: 'legacy', why: 'architect wrote no script', prior } }
      if (a.refuse === 'unrepairable') { esc.fellBack++; return { via: 'legacy', why: `architect declined: ${a.summary}`, prior } }
      if (a.refuse === 'dependency-missing') { esc.refused++; return { via: 'refuse', needsTask: a.needsTask || '' } }
      ctx.shallow = a.shallow === true
      log(`▸ ${ctx.stem}: harness ${round ? `amended (round ${round}/${MAX_AMEND})` : 'authored'} — ${(a.planKeys || []).length} stage(s), <=${a.maxAgents} agents${a.shallow ? ' [shallow]' : ''} — ${String(a.summary || '').slice(0, 140)}`)
      if (a.shallow) esc.shallow++

      // ---- 2. PRE-FLIGHT. The parent has no filesystem and cannot compile the child itself, so an
      //         agent runs the validator binary. Most throw classes never become throws.
      const v = await safeAgent(validatePrompt(ctx, prior.names),
        shellOpts({ label: `val:${ctx.kind}:${ctx.key}:${round}`, phase: ctx.phase, schema: VALIDATE }),
        () => ({ ok: false, parser: 'none', errors: ['validator agent non-emit'], warnings: [], stageCount: 0, mutatingStages: 0 }))
      if (!v.ok) {
        esc.preflight++
        const nextErr = `pre-flight: ${(v.errors || []).slice(0, 6).join('; ')}`
        log(`✗ ${ctx.stem}: pre-flight rejected the harness — ${nextErr.slice(0, 240)}`)
        // Convergence: if the errors are not a strict improvement, stop paying for rounds.
        if (round >= 1 && !improved(lastErr, nextErr)) { esc.fellBack++; return { via: 'legacy', why: 'pre-flight not converging', prior } }
        lastErr = nextErr; round++; esc.amended++; continue
      }
      if ((v.warnings || []).length) log(`  ${ctx.stem}: pre-flight warnings — ${v.warnings.slice(0, 3).join('; ').slice(0, 200)}`)

      // ---- 3. RUN. The ONE workflow() call site in acf-whip.
      //         Pre-charge the ENFORCED ceiling (runStage hard-guards used >= BUDGET), not a promise.
      const CHILD_TIER = {}; tierOf.set(CHILD_TIER, 'child')
      charge(CHILD_TIER, budget)
      let out = null, threw = null
      try { out = await workflow({ scriptPath: ctx.scriptPath }, childArgs(ctx, budget, prior, round)) }
      catch (e) { threw = e }
      const reported = (out && typeof out.agentsUsed === 'number') ? out.agentsUsed : budget
      const refund = Math.max(0, budget - Math.min(budget, reported))
      agentsUsed -= refund                       // true up DOWNWARD only
      agentsByTier.child -= refund
      if (out && Array.isArray(out.stagesReplayed)) esc.replayed += out.stagesReplayed.length

      if (!threw && out && out.ok !== false) { esc.authored++; return { via: 'workflow', raw: out, prior } }

      if (threw) {
        const msg = String((threw && threw.message) || threw)
        // Environment kill switch (an older runtime, a name-only workflow policy, no workflow hook):
        // probe by DOING — one throw, then verbatim 3.1.0 for the rest of the run.
        // 'named workflows' is the TOP-LEVEL tool's wording, 'named bundled workflows' is in-script
        // workflow()'s — the two diverge, so both must be here or a copy from either side stops
        // matching. The trailing alternatives are permission REFUSALS: not a missing capability, but
        // also not something a repair round can converge on, so probe-by-doing and fall back once.
        if (/named (bundled )?workflows|nesting is limited|is not a function|not available in this build|unknown workflow|script path this tool returned|outside the readable set|requested permissions|permission denied/i.test(msg)) {
          ESCALATE = false
          log(`↷ escalation disabled for this run — workflow() unavailable here (${msg.slice(0, 140)})`)
          esc.fellBack++; return { via: 'legacy', why: 'workflow() unavailable', prior }
        }
        lastErr = msg.slice(0, 400)
      } else {
        lastErr = `child stage '${(out && out.stage) || '?'}': ${(out && out.error) || 'returned ok:false'}`.slice(0, 400)
      }

      // ---- 4. SCOUT, ALWAYS, BEFORE AMENDING. Three failure paths, one uniformly-shaped `prior`.
      const before = prior.names.length, beforeCommits = prior.commits.length
      prior = await scout(ctx)
      const advanced = prior.names.length > before || prior.commits.length > beforeCommits
      log(`✗ ${ctx.stem}: harness threw — ${lastErr.slice(0, 160)}; progress: ${prior.names.length} stage(s) ledgered, ${prior.commits.length} commit(s), ${prior.dirty.length} dirty${advanced ? '' : ' (NO advance since last round)'}`)
      // The ledger makes convergence MEASURABLE: another round is granted only if the last one moved something.
      if (round >= 1 && !advanced) { esc.fellBack++; return { via: 'legacy', why: 'amend not converging', prior } }
      if (round >= MAX_AMEND) break
      round++; esc.amended++
    }
    esc.fellBack++
    esc.faults.push({ stem: ctx.stem, kind: ctx.kind, rounds: round, lastError: lastErr.slice(0, 200) })
    return { via: 'legacy', why: `amend budget exhausted: ${lastErr.slice(0, 160)}`, prior }
  } finally { releaseLane() }
}

// ============================ BOOTSTRAP (hard gate) ============================
phase('Bootstrap')
const boot = await safeAgent(
  `${ENV}
Bootstrap the acf-whip orchestrator at trunk root ${sq(trunkRoot)}.

SHELL TIMEOUT: the store walk and the integrity battery are O(backlog), and on a large board either
can run for minutes. Your Bash tool's DEFAULT timeout is short enough to kill them mid-walk, and a
killed command returns partial or empty output that is indistinguishable from an empty backlog — so
pass an explicit timeout of at least 300000 ms (5 minutes) on every acfw-store command below. If one
is killed anyway, say so in your result rather than reporting what the truncated output appeared to
show.

1. Run-lock check: run  find ${sq(RUN_LOCK_DIR)} -maxdepth 1 -name ${RUN_LOCK_BASE} -mmin -${LOCK_FRESH_MIN}  — if it prints a path, set lockFresh true and stop (do not run the doctor). Otherwise set lockFresh false (a "No such file or directory" error also means false).
2. Detached HEAD check: run  git -C ${sq(trunkRoot)} symbolic-ref --quiet HEAD  — if it FAILS, set detached true and stop (do not run the doctor).
3. If a branch is checked out: apply repairable integrity issues, then re-scan. The --fix pass is
   deliberately FULL so it self-heals the accepted folder too — nothing in doctor.sh forbids
   --fix with --active-only, it simply would not repair what the run needs repaired; the re-scan
   that produces the gate verdict is --active-only, which by
   doctor.sh's own contract leaves the FATAL set and the ok flag UNCHANGED and only suppresses
   accepted-folder advisories — the per-file pass over a mostly-accepted board is the dominant cost:
     bash ${sq(STORE)} doctor --fix >/dev/null 2>&1 || true
     bash ${sq(STORE)} doctor --quiet --active-only
   From the second run capture: doctorOk (SUMMARY ok=true), doctorSummary (the verbatim SUMMARY line), fatals (verbatim FATAL| lines).
4. Core count (for the child-workflow concurrency bound):  sysctl -n hw.ncpu 2>/dev/null || nproc  -> cpuCores (0 if neither works).
5. Installed agent registry:  ls -1 ${sq(trunkRoot)}/.claude/agents/*.md 2>/dev/null | sed -E 's#.*/##; s#\\.md$##'  -> agents (an empty list is not an error).
5b. Declared models:  grep -l '^model:' ${sq(trunkRoot)}/.claude/agents/*.md 2>/dev/null | while read -r f; do printf '%s=%s\\n' "$(basename "$f" .md)" "$(sed -n 's/^model:[[:space:]]*//p' "$f" | head -1)"; done  -> agentModels, one "name=model" line each. Omit any agent with no model: line — omission means "inherit the session model". An empty list is not an error.
6. Child-workflow tooling probe:  bash ${sq(SCAFFOLD)} --stdout --kind impl --stem probe --meta-name probe >/dev/null 2>&1 && echo yes || echo no  -> scaffoldOk.
Return the BootstrapResult.`,
  shellOpts({ label: 'bootstrap', phase: 'Bootstrap', schema: BOOTSTRAP }),
  () => null,
)
if (!boot) {
  return { aborted: true, stopReason: 'bootstrap-no-emit', reason: 'bootstrap agent never emitted after retries; re-run /go (git + .backlog/ are durable, nothing is lost)', mode }
}
if (boot.lockFresh) {
  // Refuse, do not warn: a double-start is unattended by definition, so a console warning protects nothing.
  return { aborted: true, stopReason: 'run-lock-held', reason: `another /go run appears active (${RUN_LOCK} touched within ${LOCK_FRESH_MIN}m). Never run two /go against one repo — they collide on slugs and on the shared root index. If the previous run crashed, the lock expires on its own, or clear it now:  rm ${RUN_LOCK}`, mode }
}
if (boot.detached) {
  return { aborted: true, stopReason: 'detached-head', reason: 'detached HEAD at trunk root; /go requires a branch checked out at the repo root', mode }
}
if (!boot.doctorOk) {
  const v = doctorVerdict(boot.fatals)
  if (!v.reported) {
    return { aborted: true, stopReason: 'doctor-unavailable', reason: `the backlog integrity gate could not RUN, so the board is unverified rather than known-bad — nothing was dispatched. ${v.why}. Fix the store backend (credentials, connectivity, \`acfw-store info\`) and re-run /go; /whip-doctor will not help until the store is reachable.`, mode, doctorUnavailable: true, doctorSummary: boot.doctorSummary, fatals: boot.fatals }
  }
  // 3.4.0: only REPO-level findings stop the run here. There is no snapshot yet, so a task-level line
  // cannot be attributed to a task — it is classified by code and deferred to iteration 1, where the
  // index exists and the finding either holds ONE task out or turns out to name nothing at all. This
  // is the gate that made a single long-cancelled card block every run for a whole team; it now
  // blocks exactly what it can prove is broken about the repository.
  const bcls = classifyFatals(boot.fatals, null)
  if (bcls.repo.length) {
    return { aborted: true, stopReason: 'integrity-fatal-bootstrap', reason: `repository-level integrity gate failed; will not dispatch against an inconsistent checkout (${bcls.repo.map((f) => f.code).join(', ')})`, mode, doctorSummary: boot.doctorSummary, fatals: bcls.repo.map((f) => f.line) }
  }
  log(`bootstrap: ${bcls.task.length} task-level integrity finding(s) deferred to the first scan — each will hold out ONE task, not the run. ${boot.doctorSummary}`)
} else {
  log(`bootstrap ok — ${boot.doctorSummary}`)
}

// ---- concurrency bound for nested child workflows (3.2.0) ----
// The runtime caps CONCURRENT agent() calls at min(16, cores-2) per workflow, and a child shares its
// parent's pool. Whether a parent thunk awaiting workflow() itself holds a slot is NOT documented, so
// the bound must be safe under BOTH readings:
//   * if it holds no slot, LANES is harmless admission control that bounds iteration wall clock;
//   * if it DOES hold one, LANES <= POOL-2 leaves >=2 slots free, so every admitted child can always
//     schedule an agent — progress is guaranteed and deadlock is impossible.
// floor(POOL/2) is deliberately NOT used: on a 4-core box it gives LANES=1 and serializes the entire
// backlog, violating the PARALLELISM INVARIANT above, while buying nothing POOL-2 does not.
const POOL = Math.min(16, Math.max(1, (Number(boot.cpuCores) > 0 ? Math.min(128, Math.max(2, Number(boot.cpuCores))) : 8) - 2))
const LANES = Math.max(2, POOL - 2)
// Within a task, parallelism only pays when there is no parallelism ACROSS tasks to be had.
function fanoutFor(waveWidth) {
  const w = Math.max(1, Math.min(LANES, Number(waveWidth) || 1))
  return Math.max(1, Math.floor((POOL - 2) / w))
}

// A unit holds AT MOST ONE lane at a time, released in `finally` before the next acquire (impl child ->
// release -> review -> release -> integrate). If a unit ever held its impl lane while requesting a
// review lane, LANES units would deadlock against each other. Never acquire a lane inside the
// serializeIntegrate chain either: the chain head would wait for a lane while every lane was held by a
// unit waiting for the chain.
let lanesFree = LANES
const laneQ = []
function acquireLane() {
  if (lanesFree > 0) { lanesFree--; return Promise.resolve() }
  return new Promise((res) => laneQ.push(res))
}
function releaseLane() {
  const next = laneQ.shift()
  if (next) next()
  else lanesFree++
}

REGISTRY = Array.isArray(boot.agents) ? boot.agents.filter((s) => typeof s === 'string' && s) : []
// Per-agent model routing, from the frontmatter of the agents the PROJECT installed. Parsed from
// "name=model" lines rather than a nested object because the bootstrap relays through one schema and
// a flat string array is the shape a shell-runner echoes most reliably. An agent absent from the map
// inherits the session model, which is the correct default for anything that reasons.
agentModels = {}
for (const line of (Array.isArray(boot.agentModels) ? boot.agentModels : [])) {
  const i = String(line || '').indexOf('=')
  if (i <= 0) continue
  const name = String(line).slice(0, i).trim()
  const m = String(line).slice(i + 1).trim()
  if (name && m) agentModels[name] = m
}
if (Object.keys(agentModels).length) {
  log(`model routing: ${Object.keys(agentModels).length} installed agent(s) declare a model — honouring each (shell tier: ${SHELL_MODEL}${EFFORTS.shell ? `, effort ${EFFORTS.shell}` : ''})`)
}
if (ESCALATE && !REGISTRY.length) {
  ESCALATE = false
  log('⚑ escalation off — .claude/agents/ is empty, so an authored harness would have no specialist to dispatch. Run /whip-add-agents.')
}
if (ESCALATE && boot.scaffoldOk === false) {
  // A missed chmod +x would otherwise degrade 100% of escalations SILENTLY, with esc.fellBack as the
  // only signal. Fail loudly once instead.
  ESCALATE = false
  log('⚑ escalation off — the child-workflow scaffold did not run. Check that skills/lib/bin/acfw-child-* are executable.')
}
if (ESCALATE) log(`escalation on — per-task authored harnesses (lanes=${LANES} pool=${POOL} cap=${AGENT_CAP} review=${ESCALATE_REVIEW ? 'on' : 'off'})`)
let capReached = false

// ============================ ITERATE ============================
phase('Iterate')
let iter = 0
let idle = 0 // consecutive iterations doing NO work (genuinely stuck: unsatisfiable deps) — break at 3
let noGain = 0 // consecutive iterations with no terminal gain (perpetual futile retry) — break at NO_GAIN_LIMIT
let prevTerminal = -1
const integratedStems = []
const rejectedStems = []
const autoRejectedStems = [] // review-time clean-checkout auto-rejects; rejectedStems only ever held integrateOne's
const tokenStrandSeen = new Map()  // stem -> times this run hit the missing-token MECHANISM arm
const tokenStrandedStems = []      // stems parked because the token never came back (see that arm)
const attemptedIntegrate = new Set() // every stem handed to integrateOne — used to reconcile the report
                                     // against disk (WS5 / retro #9): an attempted stem now in rejected/
                                     // was rejected at integration even if the agent failed to emit it.
const parkedThisRun = new Set() // stems a specialist blocked on with dependency-missing (BUG-2) — not re-dispatched
const parkedNeeds = new Map() // stem -> needs_task text (for the final operator report)
// 3.5.0. WARN lines the integrator printed on stderr, relayed through the integrate agent's note.
// An INTEGRATED task's note was read by nothing, so the two WARNs an operator must act on (this
// task's docs/cycles/ edits were dropped; uncommitted root work was overwritten, with the only copy
// of its Recover: command) reached no one. A Set: a task retried after a lost CAS prints the same
// drop WARN on every attempt.
const integrationWarnings = new Set()
const INTEGRATION_WARN_CAP = 20
function collectIntegrateWarnings(t, r) {
  // Split on newlines AND before each "WARN:", so a note the agent joined onto one line still yields
  // one entry per WARN rather than one run-on entry or none. The per-line bound is generous on
  // purpose: the overwrite WARN carries two 40-hex oids and the root path twice before its Recover:
  // command, which is the part that matters and the part a tight cut would drop.
  const found = String((r && r.note) || '').split(/\n|(?=WARN: )/).map((l) => l.trim()).filter((l) => l.startsWith('WARN:'))
  for (const w of found) {
    const line = `${t.stem}: ${w}`.slice(0, 2000)
    if (!integrationWarnings.has(line)) log(`⚠ ${line}`)
    integrationWarnings.add(line)
  }
}
// An aborted return is a report too. A run that landed work in an earlier iteration and then aborts
// may hold the only copy of a Recover: command: the snapshot it names comes from commit-tree, no ref
// points at it, and gc can prune it once the command is lost. So every abort inside the loop carries
// what the run collected. The bootstrap aborts do not need it (nothing has integrated yet), and an
// abort with no WARN is left exactly as it was.
function abortWarnings() {
  return integrationWarnings.size ? { integrationWarnings: [...integrationWarnings].slice(0, INTEGRATION_WARN_CAP) } : {}
}
let lastSnapshot = null
// The resolved scope of the LAST iteration (stems). Null on an unscoped run. Held at run level so the
// post-loop integration drain and the final report stay inside the scope the operator asked for —
// otherwise a scoped run would fold in, and report on, other people's accepted work.
let runScope = null
let stopReason = 'max-iterations'
// ---- 3.4.0 run-level bookkeeping ----
let prevTotal = -1          // last iteration's scope denominator; see the noGain guard for why
let relayWarned = false     // "this store emits no relay header" — say it once, not every iteration
const relayFailures = []    // {iteration, expected, got, why} for the report
// heldOut: every task the run REFUSED to touch, and why. A quarantined task (task-level integrity
// FATAL), a paused one (inactive member of a focus), or a vanished one (in the scope at iteration 1,
// gone from the board later — someone else moved it). This is what makes `partial` legible: a run
// that finished everything it could still must not claim the backlog is done.
const heldOut = new Map()   // stem -> {stem, why, code, detail, firstIter, lastIter, lifted}
const noteHeld = (stem, why, code, detail) => {
  const prev = heldOut.get(stem)
  if (prev) { prev.lastIter = iter; prev.lifted = false; return }
  heldOut.set(stem, { stem, why, code: code || '', detail: detail || '', firstIter: iter, lastIter: iter, lifted: false })
}
// Quarantine is recomputed every iteration, so an operator who fixes a card mid-run gets it back.
// heldOut, by contrast, is the run's HISTORY and never forgets — which is right for the report and
// wrong for every decision. Left conflated, a task whose FATAL was fixed (and which then ran and was
// accepted) still made the run report `partial`, and — worse — the drain re-quarantined it off the
// same map, so the one pass that catches stragglers skipped its finished work. Mark, do not delete:
// the entry stays visible, `lifted` says the hold ended.
const liftHeld = (live) => {
  for (const h of heldOut.values()) {
    if (h.why === 'quarantined' && !live.has(h.stem)) h.lifted = true
  }
}
const stillHeld = () => [...heldOut.values()].filter((h) => !h.lifted)
let lastFatalsNotGating = []  // FATAL lines naming nothing this board can act on — reported, never acted on
let lastQuarantined = new Set()  // the LIVE quarantine set from the last iteration — what the drain must respect
let lastQuarantineKey = ''    // log the quarantine set on change, not every iteration
let lastGated = []            // pending scope members whose deps are unsatisfied at the last iteration

while (iter < MAX_ITER) {
  iter++

  // ---- scan (read-only) + doctor-lite + heartbeat ----
  const scanPrompt = `${ENV}
Iteration ${iter} of the acf-whip orchestrator. Do three things and return the result:

SHELL TIMEOUT: the store walk and the integrity battery are O(backlog), and on a large board either
can run for minutes. Your Bash tool's DEFAULT timeout is short enough to kill them mid-walk, and a
killed command returns partial or empty output that is indistinguishable from an empty backlog — so
pass an explicit timeout of at least 300000 ms (5 minutes) on every acfw-store command below. If one
is killed anyway, say so in your result rather than reporting what the truncated output appeared to
show.

1. Read-only snapshot:  bash ${sq(STORE)} snapshot --digest --mode ${mode}${ONLY_FLAGS} --full-to ${sq(FULL_SNAP)}  — its stdout is a single JSON object. Put that stdout VERBATIM (copy it exactly, add nothing) into snapshotJson. Do NOT summarize, abbreviate, re-indent or drop any entry: the object carries a "relay" header stating how many entries it contains, and the orchestrator refuses a payload that does not match it.
2. Integrity recheck (report-only): the previous step wrote the FULL snapshot to ${sq(FULL_SNAP)}. If that file exists and is non-empty, run  bash ${sq(STORE)} doctor --quiet --active-only --snapshot ${sq(FULL_SNAP)}  so the battery reads the same store walk step 1 did; otherwise run  bash ${sq(STORE)} doctor --quiet --active-only  . Either way set doctorOk (SUMMARY ok=true), doctorSummary (verbatim SUMMARY line), doctorFatals (EVERY verbatim FATAL| line — the SUMMARY's fatal=N is cross-checked against how many you return).
3. Heartbeat (best-effort, NOT committed): write a small JSON file at ${sq(RUN_LOCK)} (create its parent directory first if missing) containing {"iteration":${iter},"mode":"${mode}","ts":"<output of: date -u +%Y-%m-%dT%H:%M:%SZ>"}. If the write fails, ignore it.
Return the ScanResult.`
  let scan = await safeAgent(scanPrompt, shellOpts({ label: `scan#${iter}`, phase: 'Iterate', schema: SCAN_RESULT }), () => null)

  // A doctor battery that could not RUN is still an immediate stop: the board is unverified rather
  // than known-bad, and that verdict needs no index to reach. REPORTED findings are NOT decided here
  // any more — they are classified below, once the snapshot gives us an index to attribute them to,
  // so one malformed card holds itself out instead of stopping a run that never touches it.
  const unavailableAbort = async (sc, whenNote) => {
    const v = doctorVerdict(sc.doctorFatals)
    if (v.reported) return null
    stopReason = 'doctor-unavailable-midrun'
    await unlock('Iterate')
    return { aborted: true, stopReason, reason: `the mid-run integrity recheck could not RUN${whenNote} — the board is unverified, not known-bad. ${v.why}`, mode, iteration: iter, doctorUnavailable: true, doctorSummary: sc.doctorSummary, fatals: sc.doctorFatals, ...abortWarnings() }
  }
  if (scan && !scan.doctorOk) {
    const ab = await unavailableAbort(scan, '')
    if (ab) return ab
  }

  // Parse + PROVE the relay. A shortened echo is valid JSON, so JSON.parse alone cannot tell a small
  // board from a truncated one; relayCheck compares the payload against the header the producer wrote.
  // A mismatch is routed into the SAME retry -> text-fallback ladder as an unparseable echo, because
  // the remedy is identical (ask again) — only the terminal reason differs, and it has to: telling an
  // operator the scan "degraded" when the board was silently halved sends them to the wrong place.
  let snap = null, relayShort = null
  const parseScan = (sc) => {
    if (!sc) return null
    let o = null
    try { o = JSON.parse(sc.snapshotJson) } catch (e) { return null }
    const rc = relayCheck(o, store)
    if (!rc.ok) { relayShort = rc; log(`iter ${iter}: RELAY SHORT — ${rc.why}`); return null }
    if (rc.unverifiable && iter === 1 && !relayWarned) { relayWarned = true; log('note: this store emits no relay header, so snapshot completeness cannot be verified (third-party adapter)') }
    relayShort = null
    return o
  }
  snap = parseScan(scan)
  if (scan && !snap) {
    // One schema re-scan on a garbled/truncated echo before falling back: the snapshot is relayed by an
    // agent echoing scan-backlog's stdout verbatim, so a single bad echo should not derail a long run.
    log(`iter ${iter}: snapshot ${relayShort ? 'incomplete' : 'JSON unparseable'} — re-scanning once`)
    scan = await safeAgent(scanPrompt, shellOpts({ label: `scan#${iter}:retry`, phase: 'Iterate', schema: SCAN_RESULT }), () => null)
    if (scan && !scan.doctorOk) {
      const ab2 = await unavailableAbort(scan, ' (on scan retry)')
      if (ab2) return ab2
    }
    snap = parseScan(scan)
  }
  if (!snap) {
    // Schema path exhausted (StructuredOutput non-emit, or unparseable twice). The model likely ran the
    // command and answered without calling the tool — try a schema-LESS text scan and parse the JSON it
    // printed (BUG-1 parse-fallback). The scan is read-only bookkeeping, not judgement.
    log(`iter ${iter}: scan schema path failed — trying schema-less text scan`)
    const fb = await textScanFallback(`scan#${iter}:text`)
    if (fb) {
      const rcf = relayCheck(fb, store)
      if (rcf.ok) { snap = fb; relayShort = null; log(`iter ${iter}: recovered snapshot via text fallback (doctor recheck skipped this iteration)`) }
      else { relayShort = rcf; log(`iter ${iter}: text fallback ALSO incomplete — ${rcf.why}`) }
    }
  }
  if (!snap && relayShort) {
    // Every relay attempt came back short. This is NOT "the scan degraded" — the command ran and the
    // board was read; what failed is the hop between the script and this scheduler, and the cause is
    // almost always a payload too large for one agent response. Say that, and name the two things that
    // actually shrink it. Planning over a half-relayed board is the one thing we will not do: that is
    // how a run reports tasks as nonexistent and stops, which is the failure this check exists for.
    stopReason = 'relay-truncated'
    log(`iter ${iter}: snapshot relay incomplete after retries (${relayShort.why}) — stopping loop, draining, then return`)
    relayFailures.push({ iteration: iter, expected: relayShort.expected, got: relayShort.got, why: relayShort.why })
    break
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
  // The doctor's findings ride the same hop as the snapshot. A dropped FATAL line silently
  // UN-quarantines its task, so the run would dispatch against the exact state the gate exists to
  // refuse — the one relay loss that is worse than losing a task record. Cross-check the count the
  // battery itself reported against how many lines came back, and refuse rather than guess which.
  if (scan && scan.doctorSummary) {
    const drc = doctorRelayCheck(scan.doctorSummary, scan.doctorFatals)
    if (!drc.ok) {
      stopReason = 'doctor-relay-truncated'
      await unlock('Iterate')
      return { aborted: true, stopReason, reason: `the integrity report was relayed incompletely (${drc.why}) — we cannot tell WHICH finding was dropped, and a dropped FATAL would silently un-hold the task it names. Nothing was dispatched. Re-run /go; if it recurs, scope the run (/go <ids>) or raise shellModel.`, mode, iteration: iter, doctorSummary: scan.doctorSummary, fatals: scan.doctorFatals, ...abortWarnings() }
    }
  }
  if (snap.branchPrefix) branchPrefix = snap.branchPrefix

  // ---- integrity findings: classify, then HOLD OUT the tasks they name (3.4.0) ----
  // A FATAL used to stop the run, full stop. That conflates "this repository is unusable" with "one
  // card is malformed", and on a shared board the second is overwhelmingly the common case: a single
  // long-cancelled card with a hand-edited state blocked every run for a whole team, including runs
  // scoped to tasks that never touched it. Repo-scoped findings still abort. Task-scoped ones hold
  // that task out and the rest of the board proceeds. Findings naming nothing this board can act on
  // are reported and otherwise ignored — aborting for them would reinstate the very gate being
  // removed. Recomputed every iteration from that iteration's relay-verified lines: no sticky state,
  // so a finding an operator fixes mid-run stops holding its task out on the next pass.
  const preIdx = indexTasks((snap.tasks || []).concat(snap.inactive || []), snap.satisfiedDeps)
  const cls = classifyFatals((scan && scan.doctorFatals) || [], preIdx)
  if (cls.repo.length) {
    stopReason = 'integrity-fatal-midrun'
    await unlock('Iterate')
    return { aborted: true, stopReason, reason: `repository-level integrity FATAL detected mid-run; aborting before dispatch (this class is not task-scoped — it affects the whole checkout): ${cls.repo.map((f) => f.code).join(', ')}`, mode, iteration: iter, doctorSummary: scan && scan.doctorSummary, fatals: cls.repo.map((f) => f.line), fatalsNotGating: cls.notGating.map((f) => f.line), ...abortWarnings() }
  }
  const quarantined = new Set(cls.task.map((f) => f.stem))
  for (const f of cls.task) noteHeld(f.stem, 'quarantined', f.code, f.detail)
  liftHeld(quarantined)
  lastQuarantined = quarantined
  const qkey = [...quarantined].sort().join(',')
  if (qkey !== lastQuarantineKey) {
    lastQuarantineKey = qkey
    if (quarantined.size) {
      const names = [...quarantined].slice(0, 3).join(', ')
      log(`integrity: holding out ${quarantined.size} task(s) with a FATAL finding — ${names}${quarantined.size > 3 ? `, +${quarantined.size - 3} more` : ''}. The rest of the board runs. /whip-doctor explains each.`)
    } else if (iter > 1) {
      log('integrity: no tasks held out this iteration (previously held-out tasks are back in play)')
    }
  }
  lastFatalsNotGating = cls.notGating.map((f) => f.line)
  if (cls.notGating.length && iter === 1) {
    log(`integrity: ${cls.notGating.length} FATAL finding(s) name nothing this run can dispatch, transition or integrate — reported, not gating.`)
  }
  snap = applyQuarantine(snap, quarantined)

  lastSnapshot = snap
  const tasks = snap.tasks || []
  // `inactive` (draft/archive, plus anything quarantined above) is UNION'd into the dependency index
  // and nowhere else. The dispatcher's enricher splits it out of tasks[] so a scoped run's denominator
  // and the per-task batteries see only work the scheduler can act on — but depsSatisfied treats an
  // unresolvable token as dangling and refuses to dispatch, so dropping these from the index would
  // turn "gated behind a draft" into "silently never dispatched". They can never be terminal
  // (isTerminal is false for both states), so a dependent still waits; it just waits legibly.
  const idx = indexTasks(tasks.concat(snap.inactive || []), snap.satisfiedDeps)
  // Run scope (3.2.3). The INDEX stays whole — dependency resolution must still see out-of-scope
  // tasks, because depsSatisfied treats an unresolvable dep token as dangling and refuses to
  // dispatch (conservative by design). Only the SCHEDULING VIEW narrows; `sched` replaces `tasks`
  // at every planning site below, and nowhere else.
  // tasks[] IS the scheduling view, so its stems are exactly what can be dispatched. Passing it makes
  // the guard below answer the real question instead of a two-value enumeration of it.
  // ---- resolve the run scope ----
  // Seeds are resolved by the SCRIPT, in the store, over the whole board (`snapshot --only` returns
  // snap.scope), and this scheduler consumes that resolution rather than re-deriving it. That split
  // matters: idx.resolve settles a prefix by FIRST MATCH over map order, which on a large board
  // silently selects whichever `feature-231-*` happened to be listed first, whereas the script
  // refuses an ambiguous prefix outright. Re-resolving here would reintroduce the guess.
  const scopeMeta = snap.scope && typeof snap.scope === 'object' ? snap.scope : null
  let seedStems = ONLY
  if (ONLY && scopeMeta) {
    // Cross-check BEFORE trusting the resolution: every stem the script resolved must be exactly
    // present in the relayed index, and every token we asked about must be accounted for in exactly
    // one bucket. A payload that satisfies the relay header but is missing a task we were promised is
    // a relay failure, NOT a nonexistent id — and calling it the latter is precisely the misdiagnosis
    // this release exists to end ("check the ids" when the ids were fine).
    const resolvedVals = Object.values(scopeMeta.resolved || {})
    const accountedFor = new Set([
      ...Object.keys(scopeMeta.resolved || {}),
      ...(scopeMeta.unresolved || []),
      ...(scopeMeta.ambiguous || []).map((a) => a && a.tok),
      ...(scopeMeta.inactiveSeeds || []).map((e) => (e && e.stem) || e),
    ])
    const missingFromIndex = resolvedVals.filter((st) => !idx.byStem.has(st) && !idx.satByStem.has(st) && !heldOut.has(st))
    const unaccounted = ONLY.filter((tok) => !accountedFor.has(tok))
    if (missingFromIndex.length || unaccounted.length) {
      stopReason = 'relay-truncated'
      await unlock('Iterate')
      return { aborted: true, stopReason, reason: `the store resolved ${resolvedVals.length} of the tasks you named, but the snapshot handed to the orchestrator does not contain ${missingFromIndex.concat(unaccounted).join(', ')} — the snapshot was relayed incompletely, so the ids are NOT missing from the backlog. Nothing was dispatched. Re-run /go; if it recurs, name fewer tasks or raise shellModel.`, scopeFilter: SCOPE_FILTER, scopedTo: ONLY, mode, iteration: iter, ...abortWarnings() }
    }
    seedStems = resolvedVals
  }
  const scoped = ONLY ? expandScope(seedStems, idx, new Set(tasks.map((t) => t.stem))) : null
  // Unresolvable / ambiguous seeds are decided by the SCRIPT and only at iteration 1. Later
  // iterations must not abort on them: on a shared board a card can legitimately move or be retired
  // under a running orchestrator, and killing a healthy multi-hour run over someone else's edit is
  // not a safety property. From iteration 2 the stem is held out and named in the report.
  const scriptUnresolved = scopeMeta ? (scopeMeta.unresolved || []) : []
  const scriptAmbiguous = scopeMeta ? (scopeMeta.ambiguous || []) : []
  if (iter > 1 && scriptUnresolved.length) {
    // Past iteration 1 the store itself can no longer resolve a seed it resolved before: someone else
    // retired or renamed the card under a running orchestrator. That is a shared-board fact, not a
    // reason to discard a healthy multi-hour run — hold the stem out and name it in the report.
    for (const tok of scriptUnresolved) noteHeld(tok, 'vanished', '', 'the store could not resolve this id any more — it was retired or renamed mid-run')
  }
  if (iter === 1 && (scriptUnresolved.length || scriptAmbiguous.length)) {
    stopReason = 'scope-unresolved'
    await unlock('Iterate')
    const ambText = scriptAmbiguous.map((a) => `${a.tok} (matches ${(a.candidates || []).join(', ')})`).join('; ')
    return { aborted: true, stopReason, reason: [
      scriptUnresolved.length ? `/go was scoped to tasks that do not exist in the backlog: ${scriptUnresolved.join(', ')} — check the ids` : '',
      ambText ? `/go was scoped by an AMBIGUOUS prefix, which is never guessed: ${ambText} — name one` : '',
    ].filter(Boolean).join('. ') + ' (nothing was dispatched)', scopeFilter: SCOPE_FILTER, scopedTo: ONLY, mode, iteration: iter, ...abortWarnings() }
  }
  if (scoped && scoped.unresolved.length) {
    if (iter === 1) {
      stopReason = 'scope-unresolved'
      await unlock('Iterate')
      return { aborted: true, stopReason, reason: `/go was scoped to tasks that do not exist in the backlog: ${scoped.unresolved.join(', ')} — check the ids (nothing was dispatched)`, scopeFilter: SCOPE_FILTER, scopedTo: ONLY, mode, iteration: iter, ...abortWarnings() }
    }
    for (const st of scoped.unresolved) noteHeld(st, 'vanished', '', 'was in scope at iteration 1 but is no longer on the board — someone else moved or retired it')
  }
  // An inactive member of an EXPLICIT scope is a refusal: you named a task that cannot run, and
  // silently running fewer tasks than asked for is the behaviour this whole feature rejects. An
  // inactive member of a FOCUS is different in kind — a focus is a standing list, and pausing one of
  // its tasks (the supported way to park work) must not stop the others.
  if (scoped && scoped.inactiveSeeds.length) {
    if (SCOPE_SOURCE === 'focus') {
      for (const e of scoped.inactiveSeeds) {
        const stem = String(e).split(' ')[0]
        noteHeld(stem, 'paused', '', String(e))
      }
      if (iter === 1) log(`scope: ${scoped.inactiveSeeds.length} focus task(s) are paused or retired and will be skipped — ${scoped.inactiveSeeds.join(', ')}`)
    } else {
      stopReason = 'scope-not-actionable'
      await unlock('Iterate')
      return { aborted: true, stopReason, reason: `/go was scoped to tasks that are not actionable: ${scoped.inactiveSeeds.join(', ')}. A draft task is behind the human gate, an archived one is retired, and one in no recognised state is quarantined — none can be dispatched. Give it a schedulable state (pending) first (nothing was dispatched)`, scopeFilter: SCOPE_FILTER, scopedTo: ONLY, mode, iteration: iter, ...abortWarnings() }
    }
  }
  const sched = scoped ? tasks.filter((t) => scoped.scope.has(t.stem)) : tasks
  // runScope is the UNION across iterations, never just this one's. A scope member that collapses out
  // of the working set once it is terminal-accepted would otherwise drop out of the drain filter, the
  // needsOperator filter and scopeResolved — so the run would stop reporting on work it did.
  if (scoped) {
    if (!runScope) runScope = new Set()
    for (const st of scoped.scope) runScope.add(st)
  }
  if (scoped && iter === 1) {
    log(`scope: ${sched.length} task(s)${scoped.added.length ? ` (+${scoped.added.length} pulled in as unmet dependencies: ${scoped.added.join(', ')})` : ''}${SCOPE_FILTER ? ` — filter: ${SCOPE_FILTER}` : ''}`)
    if (cls.notGating.length) log(`note: ${cls.notGating.length} integrity FATAL(s) sit outside this run's scope — not gating it`)
  }

  // Unblock/timeout plan is computed HERE (before the completion check) so completion can require that
  // no blocked task is about to be unblocked — otherwise a cross-slug dep that integrates in the final
  // iteration hits 100% terminal and the loop breaks before the blocked dependent gets its unblock pass
  // (retro I5A). Reused below for the pre-move batch.
  const { unblockActions, timeoutActions, freshInProgress } = planUnblockAndTimeout(sched, idx, {
    timeoutH: (snap.inProgressTimeoutHours != null ? snap.inProgressTimeoutHours : DEFAULT_TIMEOUT_H),
    maxReject: REJECT_CAP,
    maxBlock: BLOCK_CAP,
    parked: parkedThisRun,
    quarantined,
    trunkRoot,
  })

  // ---- terminal + stall (computed from scan-backlog's COUNTS, not tasks[]) ----
  // tasks[] is now the bounded WORKING SET (scan-backlog collapses terminal/historical accepted into
  // counts so the snapshot stays small enough for the agent to echo reliably). So completion is
  // measured over counts.total — which is already ACTIVE-only (the files scanner never emits draft/
  // archive, and for every other backend the dispatcher's enricher splits them into inactive[]) —
  // against the runtime-terminal count, which mirrors isTerminal exactly.
  // No silent fallback: a snapshot missing these counts means scan/workflow version skew; counting
  // isTerminal over the collapsed working set would UNDERcount and stall forever as 'no-progress'
  // instead of 'complete'. Abort loudly instead.
  // `total` is checked with them: without it `total === undefined` makes every comparison below
  // quietly false — terminal === total never fires, total < prevTotal is NaN-false — so the run
  // spins the whole no-gain budget and exits `no-progress` with `undefined` in its own iteration log.
  if (snap.counts.runtimeTerminalDefault == null || snap.counts.runtimeTerminalOverride == null || snap.counts.total == null) {
    // A scoped run counts isTerminal over its own tasks and never reads these, so skew here cannot
    // mis-measure it — warn instead of aborting, so a slightly stale adapter still permits scoping.
    if (!scoped) {
      stopReason = 'snapshot-version-skew'
      await unlock('Iterate')
      return { aborted: true, stopReason, reason: 'backlog snapshot is missing runtimeTerminal counts — snapshot engine / workflow version skew (or a store adapter emitting a pre-contract snapshot); reinstall acf-whip so both halves match', mode, iteration: iter, ...abortWarnings() }
    }
    if (iter === 1) log('WARN snapshot is missing runtimeTerminal counts (snapshot/workflow version skew) — tolerated because this run is scoped, but reinstall acf-whip')
  }
  // A SCOPED run must measure completion over its own set. snap.counts is store-wide, so reusing it
  // here would make `terminal === total` unreachable and burn NO_GAIN_LIMIT iterations before exiting
  // 'no-progress' — silent, slow and expensive. Scoped stems the scanner collapsed as terminal-accepted
  // are absent from the working set, so they drop out of BOTH sides and stay neutral.
  const total = scoped ? sched.length : snap.counts.total
  const terminal = scoped
    ? sched.filter(isTerminal).length
    : (mode === 'override' ? snap.counts.runtimeTerminalOverride : snap.counts.runtimeTerminalDefault)
  // Held-out tasks make "done" a DIFFERENT claim. A run that finished everything it was allowed to
  // touch, while refusing to touch something in its scope, has not completed the backlog — and
  // reporting `complete` there is the failure this guards: the operator reads "Backlog 100% terminal"
  // and the task they asked for was never run. `partial` is a terminal state like `complete`; it just
  // tells the truth, and `completed:false` keeps any automation reading that flag honest too.
  const inScopeHeldOut = () => stillHeld().map((h) => h.stem).filter((st) => !runScope || runScope.has(st))
  // Every scoped task already terminal (or all of them collapsed-accepted) => nothing to do. The
  // unscoped guard below is `total > 0`, which would spin here instead of stopping.
  if (scoped && total === 0) { stopReason = inScopeHeldOut().length ? 'partial' : 'complete'; break }
  log(`iter ${iter}: ${terminal}/${total} ${scoped ? 'scoped' : 'active'} terminal (integrated=${snap.counts.integrated}, accepted=${snap.counts.accepted}, blocked=${snap.counts.blocked}, workingSet=${tasks.length}${scoped ? `, scope=${sched.length}` : ''}${heldOut.size ? `, heldOut=${heldOut.size}` : ''})`)
  // Complete only when 100% terminal AND nothing is queued to unblock — the extra unblock+dispatch
  // pass (retro I5A) keeps a last-iteration-integrated dependency from stranding its blocked dependent.
  if (total > 0 && terminal === total && unblockActions.length === 0) {
    stopReason = inScopeHeldOut().length ? 'partial' : 'complete'
    break
  }
  // An UNSCOPED run whose entire remaining board is held out has nothing left to do either, and the
  // `total > 0` guard above would spin it to the no-gain ceiling instead of stopping.
  if (!scoped && total === 0 && inScopeHeldOut().length) { stopReason = 'partial'; break }

  // ---- plan (pure JS): partition by slug, gate deps, build queues ----
  // PARALLELISM INVARIANT (default): every non-conflicting ready unit dispatches CONCURRENTLY.
  // The slug is the partition — one agent per distinct ready slug runs in parallel below
  // (parallel(dispatch...)); only same-slug work (shared file surface) and unmet deps serialize.
  // Nothing here may serialize work that a distinct slug + satisfied deps would let run in parallel.
  const codeSlug = (t) => t.slug && t.slug !== 'none'
  const seen = new Set()
  // HOLD the slug of any quarantined task that was already in flight. Quarantine moves the task out
  // of the scheduling view, which frees its worktree slug — and a same-slug sibling would then be
  // dispatched into it. clean-checkout.sh opens with a silent `stash push -u`, so that sibling's
  // first act would be to sweep the held-out task's uncommitted work into the shared stash, where the
  // next clean-checkout pops it into a DIFFERENT task's tree. Holding the slug costs one iteration of
  // parallelism on one slug; not holding it costs the work.
  for (const t of (snap.inactive || [])) {
    if (!t.quarantined) continue
    if (t.folder !== 'in-progress' && t.folder !== 'completed' && t.folder !== 'in-review') continue
    if (codeSlug(t)) seen.add(t.slug)
  }
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
  const inReview = sched.filter((t) => t.folder === 'in-review').sort(byPriorityThenStem)
  const completed = sched.filter((t) => t.folder === 'completed').sort(byPriorityThenStem)
  for (const t of [...inReview, ...completed]) {
    if (codeSlug(t) && !claim(t.slug)) continue
    reviewQ.push({ t, premove: t.folder === 'completed' })
  }

  // then specialists: in-progress (re-dispatch recovery — FRESH only; stale ones were timed out
  // above) and pending (start), one per free slug.
  const pending = sched.filter((t) => t.folder === 'pending').sort(byPriorityThenStem)
  for (const t of [...freshInProgress.slice().sort(byPriorityThenStem), ...pending]) {
    if (t.slug === 'none') {
      if (t.folder === 'pending' && !depsSatisfied(t, idx, quarantined)) continue
      directQ.push({ t, premove: t.folder === 'pending' })
      continue
    }
    if (t.slug === '') { warnings.push(`${t.stem}: empty Worktree slug on a code task (FATAL integrity — left pending)`); continue }
    if (!claim(t.slug)) continue
    if (t.folder === 'pending' && !depsSatisfied(t, idx, quarantined)) { seen.delete(t.slug); continue } // free the slug for a ready sibling
    specialistQ.push({ t, premove: t.folder === 'pending' })
  }

  // rejection self-heal (writer pre-move): rejected with count < bound -> retry (pending); else -> blocked.
  const rejected = sched.filter((t) => t.folder === 'rejected')
  const rejectActions = rejected.map((t) =>
    (t.rejectionCount < REJECT_CAP)
      ? { stem: t.stem, toState: 'pending', agent: 'orchestrator', notes: `retry (rejection ${t.rejectionCount}/${REJECT_CAP})`, inc: 0 }
      : { stem: t.stem, toState: 'blocked', agent: 'orchestrator', notes: `max rejections (${t.rejectionCount}) — blocked for redesign`, inc: 0 },
  )

  if (warnings.length) for (const w of warnings) log(`WARN ${w}`)

  // ---- CLOSE rung: stop opening NEW work when the run's agent budget is nearly spent ----
  // Trimmed BEFORE the pre-move, deliberately: moving a task to in-progress and then never dispatching
  // it would leave it stranded there until the 8h timeout sweeps it on some later run. In-flight review
  // and integration still run to completion, so nothing already started is abandoned.
  if (escalationTier(agentsUsed, AGENT_CAP, CAP_RESERVE) === 'CLOSE') {
    const trimmed = specialistQ.length + directQ.length
    if (trimmed) log(`iter ${iter}: agent ledger ${agentsUsed}/${AGENT_CAP} — no new dispatch (${trimmed} unit(s) deferred); finishing in-flight work and draining`)
    specialistQ.length = 0
    directQ.length = 0
    capReached = true
  }

  // Wave width feeds the per-task fan-out ceiling: parallelism WITHIN a task only pays when there is
  // no parallelism ACROSS tasks left to be had.
  const waveWidth = specialistQ.length + directQ.length + reviewQ.length

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
  async function integrateOne(t, opts) {
    const noEscalate = !!(opts && opts.noEscalate)
    attemptedIntegrate.add(t.stem)
    let r = await safeAgent(integratePrompt(t, false), shellOpts({ label: `integrate:${t.slug}`, phase: 'Iterate', schema: INTEGRATE_RESULT }), integTransient('integrate agent non-emit — left accepted, retry next iteration'))
    // Read on EVERY pass, the resolver-needed one included: a conflict under docs/cycles/ is stripped
    // (and its drop WARN printed) before the exit 7, and the --post-resolver pass then finds nothing
    // left to strip, so it never prints that WARN again.
    collectIntegrateWarnings(t, r)
    if (r && r.outcome === 'resolver-needed') {
      log(`integrate ${t.slug}: conflict — dispatching resolver ${r.resolverAgent || t.agent || '(default)'}`)
      // NO model: here — the conflict resolver does REAL merge-conflict reasoning; session model + agentType.
      const ropts = { label: `resolve:${t.slug}`, phase: 'Iterate' }
      const ragent = r.resolverAgent || t.agent
      if (ragent && ragent !== 'none') ropts.agentType = ragent
      // SEAM (iii): fan out READ, fan in WRITE. Multiple agents may NOT write a mid-cherry-pick tree —
      // shared unwrapped index.lock, last-writer-wins on a file, and N chances to run a forbidden
      // cherry-pick --continue the integrator cannot recover from. There is also no throughput argument:
      // this whole seam already runs inside serializeIntegrate, which is why it needs no lane.
      let resolved = null
      if (ESCALATE && !noEscalate) {
        const rctx = childCtx('resolve', t, resolverPrompt(t, r), 'accepted', 1)
        rctx.conflictedFiles = r.resolverConflictedFiles || ''
        rctx.resolverWorktree = r.resolverWorktree || ''
        const res = await runAuthoredUnit(rctx)
        if (res.via === 'workflow') resolved = coerceResolveResult(res.raw)
      }
      if (!resolved) {
        // try-wrapped: this was the ONLY un-safeAgent'd agent() inside integrateOne, and integrateOne
        // runs on the serializeIntegrate chain whose promise is awaited at the end of the iteration.
        // An unhandled non-emit here used to abort the whole run.
        try {
          // Counted, never re-modelled: conflict resolution is real reasoning on a mid-cherry-pick
          // tree and stays on the session model (or the resolver agent's own declared one).
          await agentC(resolverPrompt(t, r), typedOpts(ropts, 'resolver'))
        } catch (e) {
          log(`WARN resolve ${t.slug}: resolver agent non-emit (${String((e && e.message) || e).slice(0, 160)}) — conflict left unresolved, retried next iteration`)
        }
      } else if (!resolved.resolved) {
        // The locked verify-resolve probe is the AUTHORITY. Unresolved means --post-resolver would only
        // re-detect the unmerged paths and burn an exit-9 round trip: skip it and leave the task
        // accepted/ for the next iteration's fresh trunk observation.
        log(`⚠ resolve ${t.slug}: not resolved (${resolved.note.slice(0, 140)}) — skipping --post-resolver, retried next iteration`)
        return
      } else {
        log(`  resolve ${t.slug}: ${resolved.staged} path(s) staged by the harness`)
      }
      r = await safeAgent(integratePrompt(t, true), shellOpts({ label: `integrate:${t.slug}:post`, phase: 'Iterate', schema: INTEGRATE_RESULT }), integTransient('integrate(post-resolver) agent non-emit — left accepted, retry next iteration'))
      collectIntegrateWarnings(t, r)
    }
    if (r && r.outcome === 'integrated') { integratedStems.push(t.stem); integratedThisIter++; log(`✓ integrated ${t.stem}`) }
    else if (r && r.outcome === 'rejected') {
      // LP-CAS exit 6 = the union gate failed on (trunk + this change). The integrator mutates ONLY git;
      // unlike the retired integrate-worktree it does NOT move the task file. So the orchestrator (the
      // single .backlog writer) moves accepted -> rejected here, with a rejection increment, so the task
      // re-enters the rejection self-heal (retry as pending, or blocked at the cap) instead of being
      // re-attempted as an integration candidate every iteration. Keeps the run convergent.
      rejectedStems.push(t.stem)
      // First line only: the note now carries the integrator's WARN lines after it, and a newline
      // inside a transition-log cell splits the markdown table row it is written into.
      await streamWrite([{ stem: t.stem, toState: 'rejected', agent: 'orchestrator', notes: (String(r.note || '').split('\n')[0].trim() || 'union gate failed at integration').slice(0, 200), inc: 1 }], `integ-reject#${iter}:${t.stem}`)
      log(`✗ integrate rejected ${t.stem} — ${r.note}`)
    }
    else if (r && r.outcome === 'skipped') { log(`↷ skipped ${t.stem} — no worktree branch (historical; terminal)`) }
    else if (r && r.outcome === 'contaminated') {
      // LP-CAS exit 3 = quarantine: the candidate is malformed (not single-parent) or poison (writes the
      // .acfwhip/ ledger namespace). Isolate THIS task for an operator — never reject the others, never
      // re-run (a re-run re-quarantines). Integration of every other accepted task continues unaffected.
      parkedThisRun.add(t.stem)
      parkedNeeds.set(t.stem, (String(r.note || '').split('\n')[0].trim() || `quarantined candidate for ${t.slug} — inspect refs/acfw/patch/${t.stem}; the candidate is not a single-parent code-only commit`).slice(0, 200))
      log(`⚑ ${t.stem}: quarantined candidate (${t.slug}) — parked for operator, isolated from the rest of the run`)
    }
    // transient/error -> leave accepted, retry next iteration
  }

  // Review one task that is NOW in in-review/ (moved there by premove for reviewQ, or inline below for a
  // freshly-completed specialist), then integrate on accept. A reviewer non-emit throws out of the unit
  // thunk -> parallel maps it to null; the task is left committed in in-review/ and re-reviewed next scan.
  async function runReviewAndIntegrate(t, opts) {
    const isNone = t.slug === 'none'
    // `t` is the SCAN-TIME object. On the inline path below (a unit this iteration just dispatched) its
    // hasCleanCheckoutToken/hasWorktreeBranch were read BEFORE the implementer ran its own clean-checkout,
    // so they are false for EVERY first attempt and describe the world one specialist-run in the past.
    // Gate only on fields the scan observed AFTER the implementation — i.e. a task the scan already found
    // in completed/ or in-review/. A specialist that genuinely skipped clean-checkout is caught by
    // reviewerPrompt's PRE-STEP-0 CHECK, which asks this same question with the same two arms BEFORE
    // the reviewer runs its own clean-checkout. That ordering is load-bearing and is why the check was
    // moved: it used to run AFTER Step 0 and grep for a row Step 0 itself writes (clean-checkout.sh
    // uses a hard-coded agent field), so it could never fire — and this comment cited it as a backstop.
    const tokenObserved = !(opts && opts.tokenStale)
    // Deterministic clean-checkout AUTO-REJECT, decided HERE rather than by a reasoning prompt.
    // hasCleanCheckoutToken is an adapter-owned snapshot field on every backend (CONTRACT.md), so this
    // costs nothing and cannot be forgotten mid-review the way the prose rule in reviewerPrompt can.
    // It is TYPED, because the token's most common cause of loss is mechanical, not a missing worktree:
    // append_log_row is a read-modify-write with no lock, and clean-checkout's store log-event fallback
    // fails with only a WARN. So: branch exists + token missing => the token was lost, not the work
    // => mechanism, retried. No branch at all => nothing was ever checked out => a real quality reject.
    if (!isNone && tokenObserved && t.hasCleanCheckoutToken === false) {
      if (t.hasWorktreeBranch) {
        // BOUNDED, because "leave it for re-review" has no one to re-review it INTO a token.
        // clean-checkout.sh is the token's only writer and it runs at DISPATCH, not at review; the
        // reviewer is explicitly forbidden from writing one (reviewerPrompt's PRE-STEP-0). So an
        // unbounded arm is a fixed point: the task sits in in-review/ across every future run, the
        // run ends no-progress with committed work never integrated, and claim(t.slug) starves every
        // same-slug sibling for the whole run, every run. Re-review once — the token is usually back
        // next iteration when the cause was a lost append_log_row race — then park it.
        //   Parking is also what RESTORES it: inc/binc 0 keep the task under both caps, so the unblock
        // pass re-queues it, and the re-dispatch's restoreCheckoutToken re-records the token on its
        // (by then committed, clean) worktree before the harness replays. Until 3.4.3 wired the stage
        // preamble that replay could never write one — which is why the note's remedy must stay true.
        const seen = (tokenStrandSeen.get(t.stem) || 0) + 1
        tokenStrandSeen.set(t.stem, seen)
        if (seen < 2) {
          log(`↷ ${t.stem}: clean-checkout token missing but ${branchPrefix}/${t.slug} exists — mechanism, left in-review/ for re-review`)
          return
        }
        log(`⚠ ${t.stem}: clean-checkout token still missing after ${seen} reviews — parking in blocked/ for an operator instead of re-reviewing forever`)
        tokenStrandedStems.push(t.stem)
        // inc: 0 — this is mechanical. Charging a life for a token the orchestrator itself could not
        // write would spend the task's three rejections on a fault it never caused.
        await streamWrite([{ stem: t.stem, toState: 'blocked', agent: 'orchestrator', notes: `clean-checkout token absent on ${seen} consecutive reviews while ${branchPrefix}/${t.slug} exists. The token's only writer runs at dispatch, so no further review can restore it; a re-dispatch re-records it once that worktree is clean — verify the branch, then re-run /go to re-dispatch.`, inc: 0 }], `review#${iter}:${t.stem}`)
        productiveDispatch = true
        return
      }
      // The ONLY state change in this function that used to be silent: no log line, and absent from
      // every run tally, so a run could auto-reject each task it dispatched and still report complete.
      log(`✗ ${t.stem}: AUTO-REJECT — no clean-checkout token and no ${branchPrefix}/${t.slug} branch (the implementation never entered a worktree)`)
      autoRejectedStems.push(t.stem)
      await streamWrite([{ stem: t.stem, toState: 'rejected', agent: 'orchestrator', notes: 'AUTO-REJECT: no clean-checkout token and no worktree branch — the implementation never entered a worktree', inc: 1 }], `review#${iter}:${t.stem}`)
      productiveDispatch = true
      return
    }
    const rprompt = isNone ? directReviewPrompt(t) : reviewerPrompt(t)
    // SEAM (ii): the multi-lens review panel. OFF by default (args.escalateReview) because this is the
    // only SUBTRACTIVE seam — escalating it can destroy work that would otherwise have shipped, and it
    // runs against a hard 3-rejection terminal. When on, the child's LOCKED aggregate() folds the
    // lenses by strict majority with NO veto and clamps rejectionIncrement to 1, so a panel of any
    // size costs at most one life per round.
    let rr = null
    if (ESCALATE && ESCALATE_REVIEW && !isNone) {
      const rctx = childCtx('review', t, rprompt, 'in-review', 1)
      // The inline path skipped the typed gate above, and a panel cannot express its mechanism arm —
      // reviewTokenObserved says why. 'defer' charges nothing and moves nothing: the next scan's
      // observed fields put the task through that gate instead.
      rctx.tokenStale = !tokenObserved
      const res = await runAuthoredUnit(rctx)
      if (res.via === 'defer') {
        log(`↷ ${t.stem}: clean-checkout token not observed before the review panel (${res.why}) — left in in-review/ for the next scan's token gate, no rejection charged`)
        return
      }
      if (res.via === 'workflow') rr = coerceAcfwResult(res.raw, ['accepted', 'rejected', 'none'])
      if (!rr) rr = await agentC(rprompt, typedOpts({ label: `review:${t.slug}`, phase: 'Iterate', schema: ACFW_RESULT, agentType: 'quality-reviewer' }, 'review'))
    } else {
      // Reviewers ALWAYS run as quality-reviewer (independent review — never the implementer's agent).
      rr = await agentC(rprompt, typedOpts({ label: `review:${isNone ? t.stem : t.slug}`, phase: 'Iterate', schema: ACFW_RESULT, agentType: 'quality-reviewer' }, 'review'))
    }
    const rv = reviewVerdict(rr)
    if (rv.mechanism) { log(`↷ ${t.stem}: review reported a MECHANISM fault (${(rr.notes || '').slice(0, 120)}) — left in-review/, no rejection charged`); return }
    if (!rv.toState) return // none/mismatched -> transient, leave in in-review/
    // notes capped at 400, not 200: review feedback is the single most valuable input a retry has, and a
    // folded multi-lens critique truncated to 200 chars is LESS actionable than one reviewer's 200 —
    // which would make retry quality go down rather than up.
    await streamWrite([{ stem: t.stem, toState: rv.toState, agent: t.agent || 'orchestrator', notes: (rr.notes || '').slice(0, 400), inc: rv.inc }], `review#${iter}:${t.stem}`)
    productiveDispatch = true
    if (rv.toState === 'accepted' && mode === 'default' && codeSlug(t)) await serializeIntegrate(() => integrateOne(t))
  }

  // Run one specialist/direct unit, then stream it through review (+integration) on completion.
  async function processUnit(d) {
    if (d.kind === 'review') return runReviewAndIntegrate(d.t) // already in in-review/ (premove)
    const prompt = d.kind === 'direct' ? directPrompt(d.t) : specialistPrompt(d.t)
    // Specialists/direct do REAL work, so they never take the shell tier. They DO take the model the
    // project declared for that agent in .claude/agents/<name>.md — that file is where a project
    // already expresses "this kind of work runs on that model", and honouring it explicitly puts the
    // choice in the run report instead of leaving it to whatever the runtime resolves for an
    // agentType inside a workflow (which is undocumented). No frontmatter model => session model,
    // exactly as before.
    const baseOpts = { label: `${d.kind}:${d.t.slug === 'none' ? d.t.stem : d.t.slug}`, phase: 'Iterate', schema: ACFW_RESULT }
    const at = d.t.agent
    if (at && at !== 'none') baseOpts.agentType = at
    const opts = typedOpts(baseOpts, 'specialist')

    // SEAM (i): the task runs as its OWN authored child workflow. runAuthoredUnit never throws; on any
    // exhaustion it returns via:'legacy' and we make the EXACT 3.1.0 call below, whose throw maps to
    // null in the parallel thunk — byte-identical degradation to 3.1.0.
    const ctx = childCtx(d.kind === 'direct' ? 'direct' : 'impl', d.t, prompt, 'in-progress', waveWidth)
    const es = await runAuthoredUnit(ctx)
    if (es.via === 'refuse') {
      // The architect found unmodeled work before running anything. Park WITHOUT charging Block-Count:
      // an agent that attempted nothing must not spend one of the task's three lives.
      parkedThisRun.add(d.t.stem)
      if (es.needsTask) parkedNeeds.set(d.t.stem, es.needsTask.slice(0, 200))
      log(`⚑ ${d.t.stem}: architect refused — unmodeled prerequisite: ${es.needsTask || '(unspecified)'} — parked`)
      await streamWrite([{ stem: d.t.stem, toState: 'blocked', agent: 'orchestrator', notes: (es.needsTask || 'unmodeled prerequisite').slice(0, 200), inc: 0, binc: 0 }], `block#${iter}:${d.t.stem}`)
      productiveDispatch = true
      return
    }
    let r
    if (es.via === 'workflow') {
      r = coerceAcfwResult(es.raw, ['completed', 'blocked', 'none'])
      if (!r) log(`↷ ${d.t.stem}: harness returned no usable ACFW_RESULT — transient, retried next iteration`)
    } else {
      // Only preserve when a child could actually have left work behind. es.prior is set exactly on
      // the paths where the escalation machinery ran and scouted; on 'escalation off' and on the
      // DIRECT/CLOSE budget rungs no child ever existed, and scouting there would buy a wasted agent
      // per task — the opposite of what those rungs are for.
      if (es.prior) await preserveBeforeLegacy(ctx, es.prior)
      log(`↷ ${d.t.stem}: single-agent fallback — ${es.why}`)
      r = await agentC(prompt, opts) // 3.1.0 verbatim: throws on non-emit -> thunk -> null (transient)
    }
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
    await runReviewAndIntegrate(d.t, { tokenStale: true })
  }

  // Pre-existing accepted leftovers (from the scan) CAN be interdependent — integrate them in one
  // topo-ordered, lock-held pass that runs concurrently with the dispatch wave below. A branchless
  // historical/pre-2.0.0 accepted task is already on trunk (isTerminal treats it terminal) — never
  // enqueue it (it has no candidate, so the integrator would exit 4 skip anyway; skip the dispatch).
  let priorIntegratePass = Promise.resolve()
  if (mode === 'default') {
    const seenC = new Set()
    const candidates = []
    for (const t of sched.filter((t) => t.folder === 'accepted' && codeSlug(t) && !t.hasIntegratedAt && t.hasWorktreeBranch && !parkedThisRun.has(t.stem))) {
      if (seenC.has(t.stem)) continue
      seenC.add(t.stem); candidates.push(t)
    }
    if (candidates.length) {
      const ordered = topoIntegrationOrder(candidates, idx, () => log('WARN integrate: dependency cycle among integration candidates — using input order; run /whip-doctor'))
      // noEscalate: this pass runs CONCURRENTLY with the dispatch wave, and every unit that reaches
      // accepted queues behind it on serializeIntegrate. A multi-stage resolve harness here would turn
      // one leftover conflict into a wave-wide throughput collapse.
      priorIntegratePass = serializeIntegrate(async () => { for (const t of ordered) await integrateOne(t, { noEscalate: true }) })
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
    // Each entry is now a whole sub-workflow, so publish the tier/lane/budget state too — otherwise a
    // run that has silently degraded to 3.1.0 everywhere looks identical to a fully escalated one.
    const tierNow = ESCALATE ? escalationTier(agentsUsed, AGENT_CAP, CAP_RESERVE) : 'off'
    log(`iter ${iter}: dispatching ${specialistQ.length} specialist + ${directQ.length} direct + ${reviewQ.length} review [tier=${tierNow} lanes=${LANES} fanout=${fanoutFor(dispatch.length)} agents≈${agentsUsed}/${AGENT_CAP}] — ${dispatch.map((d) => `${d.kind}:${d.t.slug === 'none' ? d.t.stem : d.t.slug}`).join(', ')}`)
    // Chunked AND try-wrapped. A runtime agent-cap exception is thrown at the top of parallel() itself,
    // so an uncaught throw here escapes the while loop AND the script: no report, no unlock, run lock
    // held for LOCK_FRESH_MIN. That is the "hours of work, no report" mode 3.0.1 eliminated. Chunking
    // also guards the 4096-item parallel() limit, which is reachable because slug==='none' tasks are
    // unpartitioned.
    for (const part of chunkList(dispatch, DISPATCH_CHUNK)) {
      try {
        await parallel(part.map((d) => () => processUnit(d)))
      } catch (e) {
        capReached = true
        log(`WARN dispatch wave aborted: ${String((e && e.message) || e).slice(0, 200)} — finishing in-flight work and draining`)
        break
      }
    }
  }
  // MUST stay guarded. integrateOne dispatches the conflict resolver through a bare agent(), so a
  // resolver non-emit REJECTS this promise; serializeIntegrate returns the un-swallowed promise, and a
  // bare `await` here propagates out of the while loop AND out of the script — no report, no unlock,
  // run lock held for LOCK_FRESH_MIN. That is exactly the "hours of work, no report" failure 3.0.1 was
  // written to eliminate. Swallowing is strictly safe: a leftover stays accepted/ and is retried next
  // iteration and again by the drain pass.
  await priorIntegratePass.catch((e) => log(`WARN prior-integrate pass failed: ${String((e && e.message) || e).slice(0, 200)} — leftovers stay accepted, retried next iteration`))

  // ---- progress accounting (computed from THIS iteration's work) ----
  // didWork drives the idle guard (break at 3). A pre-move (unblock/timeout/dispatch/reject), an
  // integration, or a dispatch that returned a REAL transition all count. A dispatch that returns
  // only 'none' (transient) does NOT — otherwise a task that re-dispatches and keeps failing would
  // hold idle at 0 forever and only the looser noGain guard (15) would catch it.
  // Why is a pending task still sitting there? At a no-progress exit this is the whole question, and
  // the report used to answer it by pointing at blocked/ and rejected/ — the two folders a gated
  // PENDING task is not in. Recompute each iteration so the last one describes the state we stopped in.
  lastGated = sched
    .filter((t) => t.folder === 'pending' && !depsSatisfied(t, idx, quarantined))
    .map((t) => {
      const unmet = (t.deps || []).filter((d) => {
        const dep = idx.resolve(d)
        if (!dep) return true
        return quarantined.has(dep.stem) || !depsSatisfied({ deps: [d], slug: t.slug }, idx, quarantined)
      })
      const first = unmet[0] || ''
      const dep = first ? idx.resolve(first) : null
      return {
        stem: t.stem,
        dep: first || '(unresolvable)',
        why: !dep ? 'dependency names no task on this board'
          : quarantined.has(dep.stem) ? `dependency ${dep.stem} is held out by an integrity finding`
          : heldOut.has(dep.stem) ? `dependency ${dep.stem} is held out (${(heldOut.get(dep.stem) || {}).why})`
          : `dependency ${dep.stem} is ${dep.folder}, not accepted`,
      }
    })

  const didWork = preActions.length > 0 || integratedThisIter > 0 || productiveDispatch
  idle = didWork ? 0 : idle + 1
  // Progress is not only "terminal went up". On a scoped run a task that becomes terminal-accepted
  // COLLAPSES out of the next snapshot's working set, so `terminal` can stay flat while `total`
  // shrinks by the same one — real progress that the old guard read as none. Seventeen same-slug or
  // chain-dependent scoped tasks would exhaust NO_GAIN_LIMIT and exit 'no-progress' with the work
  // still there. A member can only leave the scope by finishing, vanishing, or being held out, and
  // all three are reported — so a shrinking denominator is always progress or always visible.
  noGain = (terminal > prevTerminal || (prevTotal >= 0 && total < prevTotal)) ? 0 : noGain + 1
  prevTerminal = terminal
  prevTotal = total
  // BREAK, never return: the run must fall through to Drain and the unlock, or a finished run holds its
  // own lock for LOCK_FRESH_MIN while its report tells the operator to re-run.
  if (capReached) { stopReason = 'agent-cap-reached'; break }
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
Final integration drain. Run  bash ${sq(STORE)} snapshot --digest --mode ${mode}${ONLY_FLAGS}  and return its stdout VERBATIM in snapshotJson — copy it exactly, add nothing, drop nothing (set doctorOk true, doctorSummary "drain", doctorFatals []).`,
    shellOpts({ label: 'drain:scan', phase: 'Drain', schema: SCAN_RESULT }),
    () => null,
  )
  let snap2 = null
  try { snap2 = rescan ? JSON.parse(rescan.snapshotJson) : null } catch (e) { snap2 = null }
  // The drain relays the same way the loop does, so verify it the same way. A SHORT drain snapshot is
  // worse than none: it would list fewer accepted tasks than exist and the run would report a clean
  // finish having integrated only part of the work. Fall back to the last VERIFIED snapshot instead —
  // it is stale, never truncated, and the integrator is idempotent against a stale entry.
  if (snap2) {
    const drc2 = relayCheck(snap2, store)
    if (!drc2.ok) {
      log(`drain: snapshot relay incomplete (${drc2.why}) — draining off the last verified snapshot instead`)
      relayFailures.push({ iteration: 'drain', expected: drc2.expected, got: drc2.got, why: drc2.why })
      snap2 = null
    }
  }
  // BUG-6a: if the drain scan itself can't emit (it routes through the same schema-forced agent as the
  // main scan), drain off the last good in-memory snapshot instead of skipping integration entirely. A
  // stale snapshot may list a just-integrated task as still-accepted, so exclude stems already integrated
  // this run; the LP-CAS integrator's O(1) already-integrated check makes a folded task a no-op (exit 0)
  // even if one slips through.
  if (!snap2) snap2 = lastSnapshot
  // A held-out task is held out here too. The drain runs AFTER the loop, off a fresh snapshot that
  // knows nothing about this run's quarantine — so without this, the one pass that exists to catch
  // stragglers would cheerfully integrate the very task the integrity gate refused to touch.
  // The set is the LAST ITERATION'S LIVE one, not every stem ever held: a card whose FATAL an
  // operator fixed mid-run went on to be accepted, and excluding it here stranded that work
  // unintegrated with nothing in the report saying why.
  const drainHold = new Set(stillHeld().map((h) => h.stem))
  if (snap2 && drainHold.size) snap2 = applyQuarantine(snap2, drainHold)
  finalSnap = snap2 || lastSnapshot
  if (snap2) {
    const idx2 = indexTasks((snap2.tasks || []).concat(snap2.inactive || []), snap2.satisfiedDeps)
    const left = topoIntegrationOrder((snap2.tasks || []).filter((t) => t.folder === 'accepted' && t.slug && t.slug !== 'none' && !t.hasIntegratedAt && t.hasWorktreeBranch && !integratedStems.includes(t.stem) && (!runScope || runScope.has(t.stem))), idx2)
    for (const t of left) {
      // single defensive pass: an exit-7 here is intentionally left for the next /go run (no resolver post-loop)
      attemptedIntegrate.add(t.stem)
      const r = await safeAgent(integratePrompt(t, false), shellOpts({ label: `drain:${t.slug}`, phase: 'Drain', schema: INTEGRATE_RESULT }), () => ({ outcome: 'transient', note: 'drain integrate non-emit' }))
      collectIntegrateWarnings(t, r)
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
await unlock('Drain')

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
  .filter((t) => (!runScope || runScope.has(t.stem)))
  .filter((t) => t.folder === 'blocked' && ((t.blockCount || 0) >= BLOCK_CAP || (t.rejectionCount || 0) >= REJECT_CAP))
  .map((t) => ({ stem: t.stem, blockCount: t.blockCount || 0, rejectionCount: t.rejectionCount || 0, needsTask: parkedNeeds.get(t.stem) || '' }))
const capParkedStems = new Set(capParked.map((n) => n.stem))
const depParked = [...parkedThisRun].filter((s) => !capParkedStems.has(s)).map((s) => ({ stem: s, blockCount: 0, rejectionCount: 0, needsTask: parkedNeeds.get(s) || '' }))
// A token-stranded task is parked in blocked/ with its counts untouched, so it matches neither the
// cap filter above nor parkedThisRun. Surface it on its own or the one class of park the operator
// cannot fix from the task file alone would be the one class the report omits.
const alreadyParked = new Set([...capParkedStems, ...parkedThisRun])
const tokenParked = [...new Set(tokenStrandedStems)].filter((s) => !alreadyParked.has(s))
  .map((s) => ({ stem: s, blockCount: 0, rejectionCount: 0, needsTask: 'clean-checkout token never restored — verify the worktree branch, then re-run /go to re-dispatch' }))
const needsOperator = [...capParked, ...depParked, ...tokenParked]
// Tasks the run REFUSED to touch, and why. `completed` is true only when the run both reached
// `complete` AND held nothing out inside its scope — a run that finished every task it was allowed to
// touch, while refusing one it was asked to, has not completed the backlog, and saying so is the
// point. Automation reading `completed` gets the same honest answer the note does.
const heldOutList = stillHeld().filter((h) => !runScope || runScope.has(h.stem))
// Everything ever held out, including entries whose hold was lifted mid-run. `heldOut` drives what
// the run CLAIMS; this is the audit trail, so a transient integrity failure is never invisible.
const heldOutEver = [...heldOut.values()].filter((h) => !runScope || runScope.has(h.stem))
return {
  completed: stopReason === 'complete' && heldOutList.length === 0,
  stopReason, // complete | partial | no-progress | max-iterations | scan-degraded | relay-truncated | agent-cap-reached | (aborts return earlier)
  mode,
  // Run scope (3.2.3). All three are null/empty on an unscoped run. scopeFilter is the operator's raw
  // words (a natural-language filter resolves to stems in the SKILL, so this is the only record of what
  // was actually asked for); scopedTo is the seed; scopeResolved is what ran, including deps pulled in.
  scopeFilter: SCOPE_FILTER || null,
  scopedTo: ONLY,
  scopeResolved: runScope ? [...runScope] : null,
  scopeSource: SCOPE_SOURCE,
  // 3.4.0. heldOut: what the run would not touch (quarantined by an integrity finding, paused, or
  // vanished from the board mid-run). fatalsNotGating: findings that name nothing this run can act on
  // — reported so they are never silent, acted on by nobody. gated: why a pending task never moved,
  // answered from the scheduling view instead of by pointing at folders it is not in. relay: what the
  // snapshot hop did, so a near-miss is visible BEFORE it becomes an abort on some later run.
  heldOut: heldOutList,
  heldOutEver,
  fatalsNotGating: lastFatalsNotGating,
  gated: lastGated,
  relay: { failures: relayFailures, verified: relayFailures.length === 0 },
  iterations: iter,
  finalCounts,
  integrated,
  rejectedAtIntegration,
  // A review-time clean-checkout auto-reject used to be recorded nowhere, so a run could charge a
  // rejection to every task it dispatched and still report completed:true with an empty reject list.
  rejectedAtReview: [...new Set(autoRejectedStems)],
  drainedPostLoop: drained,
  // 3.5.0. "<stem>: WARN: ..." lines the integrator printed: cycle edits it dropped, and uncommitted
  // root work a landing overwrote (with the Recover: command that exists nowhere else). Capped so a
  // pathological run cannot grow the payload a resumed turn has to read; the log keeps every one.
  // The in-loop aborts carry the same list (abortWarnings), since a run can land work and then abort.
  integrationWarnings: [...integrationWarnings].slice(0, INTEGRATION_WARN_CAP),
  needsOperator,
  // Without these a run that silently degraded to 3.1.0 dispatch everywhere is indistinguishable from
  // a fully escalated one — the single most misleading way this feature could fail.
  agentsUsed,
  agentCap: AGENT_CAP,
  // Whether harnesses were authored by the dedicated persona or by the default agent. Without this a
  // run that silently degraded is indistinguishable from one that did not.
  workflowArchitectInstalled: registryHas('workflow-architect'),
  // 3.4.0 cost legibility. Which model each TIER ran on, and how many agents each tier spent. A run
  // that silently routed every specialist to the session model — because the project declares no
  // frontmatter models, or because an older bootstrap relayed none — is otherwise indistinguishable
  // from one that honoured them, and the bill is the only place the difference shows up.
  models: { shell: SHELL_MODEL, judge: MODELS.judge || null, author: MODELS.author || null, agentModels, efforts: { shell: EFFORTS.shell || null } },
  agentsByTier,
  maxReject: REJECT_CAP,
  maxBlock: BLOCK_CAP,
  lanes: LANES,
  escalation: {
    enabled: ESCALATE,
    reviewEnabled: ESCALATE_REVIEW,
    authored: esc.authored,
    amended: esc.amended,
    preflightRejected: esc.preflight,
    fellBack: esc.fellBack,
    refused: esc.refused,
    shallow: esc.shallow,
    stagesReplayed: esc.replayed,
    faults: esc.faults,
  },
  // A SCOPED run never says "Backlog": it finished the tasks it was given, and claiming the board is
  // done when 600 other cards were never looked at is the report reading an operator cannot trust.
  note: (stopReason === 'complete'
    ? (runScope ? `Scope 100% terminal (${runScope.size} task(s)).` : 'Backlog 100% terminal.')
    : stopReason === 'partial'
      ? `Everything this run was allowed to touch is terminal, but ${heldOutList.length} task(s) were HELD OUT and never ran: ${heldOutList.map((h) => `${h.stem} (${h.why})`).join(', ')}. The backlog is NOT complete.`
      : stopReason === 'no-progress'
        ? `No progress for 3 iterations — user intervention needed.${lastGated.length ? ` ${lastGated.length} pending task(s) are gated: ${lastGated.slice(0, 3).map((g) => `${g.stem} (${g.why})`).join('; ')}${lastGated.length > 3 ? ', ...' : ''}.` : ''}${heldOutList.length ? ` ${heldOutList.length} task(s) held out: ${heldOutList.map((h) => h.stem).join(', ')}.` : ''} Also check blocked/ and rejected/.`
        : stopReason === 'agent-cap-reached'
          ? `Stopped at the run's agent ceiling (${agentsUsed}/${AGENT_CAP}) with in-flight work finished and integrated. Nothing lost — every completed harness stage is on disk under the same attempt key, so re-running /go replays them for free and continues.`
          : stopReason === 'relay-truncated'
            ? `The snapshot could not be relayed intact from the store to the orchestrator after retries${relayFailures.length ? ` (${relayFailures[relayFailures.length - 1].why})` : ''}. The board was read fine — the hop through the scan agent was short, which on a large store means the payload is too big for one response. Nothing was mis-scheduled and nothing is lost. Narrow the run (/go <ids>, or set a focus), or raise shellModel, then re-run.`
            : stopReason === 'scan-degraded'
              ? 'Scan could not emit a snapshot after retries + schema-less text fallback; stopped the loop and drained integratable work. Nothing lost (git + .backlog/ are durable) — re-run /go to continue.'
              : 'Hit the iteration cap.')
    + (heldOutList.length && stopReason !== 'partial' && stopReason !== 'no-progress'
      ? ` ${heldOutList.length} task(s) were held out and never ran: ${heldOutList.map((h) => `${h.stem} (${h.why})`).join(', ')}.`
      : '')
    + (lastFatalsNotGating.length
      ? ` ${lastFatalsNotGating.length} integrity FATAL(s) named tasks outside this run and did not gate it — run /whip-doctor to see them.`
      : '')
    + (ESCALATE && esc.authored === 0 && esc.fellBack > 0
      ? ` ⚑ NO harness was authored this run (${esc.fellBack} fell back to single-agent dispatch) — check that acf-whip/skills/lib/bin/acfw-child-* are executable and that .claude/agents/ is populated.`
      : '')
    + (needsOperator.length ? ` ${needsOperator.length} task(s) parked for an operator (re-block/rejection cap reached): ${needsOperator.map((n) => n.stem).join(', ')}.` : '')
    + (integrationWarnings.size
      ? ` ${integrationWarnings.size} integration WARN(s)${integrationWarnings.size > INTEGRATION_WARN_CAP ? ` (the first ${INTEGRATION_WARN_CAP} are in integrationWarnings; the workflow log has every one)` : ' in integrationWarnings'}: relay them verbatim, since one may hold the only Recover: command for overwritten work.`
      : '')
    + (reconciled ? ' (integration tallies reconciled against final on-disk state).' : ''),
  // 3.5.0 (plan section 4). The completion payload is the one thing a resumed turn reliably reads
  // after a long background run: compaction keeps only the head of go/SKILL.md, and its step 5 is
  // far below that. So the command lives HERE, with this run's own stopReason and mode already in
  // it. `--if-cycle` prints nothing and reads no store outside a planned cycle, which keeps a
  // plan-less run's ending exactly as before. Only this return carries it: an aborted run's `reason`
  // is its next step, and no abort above gains a nextStep.
  nextStep: `Run: bash ${sq(CYCLE)} status --if-cycle --after-run ${stopReason} --mode ${mode} — print its output verbatim (it prints nothing outside a planned cycle).`,
}
