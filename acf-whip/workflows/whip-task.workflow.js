export const meta = {
  name: 'whip-task',
  description: 'Decompose a scope into atomic backlog task files with schema-enforced worktree slugs, a JS validation gate (acyclic deps, unique ids, kebab slugs), parallel authoring, a single committing writer, and a create-time doctor gate.',
  whenToUse: 'Launched by the acf-whip /task skill when dynamic workflows are available. Replaces the Claude-as-orchestrator decomposition loop with a deterministic script so slug/dependency enforcement happens before any file is written.',
  phases: [
    { title: 'Recon', detail: 'parallel read-only agents map existing ids/slugs, the real code surface, and the project conventions' },
    { title: 'Decompose', detail: 'competing planners split the scope; a judge picks or merges; a completeness critic attacks the winner (bounded re-dispatch on defects)' },
    { title: 'Author', detail: 'one task-engineer per task writes its file in parallel (no commit)' },
    { title: 'Write', detail: 'one writer stages + commits all new pending tasks' },
    { title: 'Verify', detail: 'create-time doctor integrity gate' },
  ],
}

// ---- args ----
const scope = args && args.scope
const pluginRoot = (args && args.pluginRoot) || ''
const trunkRoot = (args && args.trunkRoot) || ''
const trunkBranch = (args && args.trunkBranch) || ''
if (!scope || !pluginRoot || !trunkRoot) {
  return { error: 'whip-task.workflow.js requires args.scope, args.pluginRoot, args.trunkRoot', got: { hasScope: !!scope, pluginRoot, trunkRoot } }
}

// ---- shell helpers (these strings land in agent prompts; agents run the bash) ----
const sq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`
// Task-store backend (3.1.0): 'files' authors straight into .backlog/pending/ and commits (byte-
// identical to 3.0.x); any other backend authors into a .acfwhip/run/staging/ scratch dir and the single
// writer ingests each file into the store via `acfw-store create` (dep-stamp folded into --set).
const store = (args && args.store) || 'files'
const filesStore = store === 'files'
const STORE = `${pluginRoot}/skills/lib/bin/acfw-store`
// The run focus (3.4.0): the tasks a bare `/go` runs in THIS checkout. /task sets it to what it just
// created, so the common path — plan, /task, /go — needs no arguments and still runs only your own
// work. Chained onto each `create` with && rather than written in one go at the end: a create that
// fails with a duplicate id must not put that id in the focus, and shell semantics decide that more
// reliably than an agent re-reading which of its commands succeeded.
const FOCUS = `${pluginRoot}/skills/lib/bin/acfw-focus`
const ENV = `export ACFW_TRUNK_ROOT=${sq(trunkRoot)}; export ACFW_TRUNK_BRANCH=${sq(trunkBranch)}; export ACFW_STORE=${sq(store)};`
// ============================ model routing (3.4.0) ============================
// Same three-tier policy as /go, and for the same reason: an agent is routed by what it DOES.
//
//   SHELL  — runs a fixed command and copies its stdout into a schema. Zero reasoning. Until 3.4.0
//            exactly ONE call here took this tier (recon:backlog), while the agent-registry `ls`, BOTH
//            single-writer calls (whose prompts are a fixed list of `acfw-store create` lines) and the
//            report-only doctor all inherited the session model — paying frontier generation cost to
//            echo command output. They take the shell tier now.
//   JUDGE  — the competing planners, the judge between them, the completeness critic. Real judgement:
//            the slug partition and the dependency graph have several defensible answers.
//   AUTHOR — the task-engineer agents that write each task document. Real writing.
//
// judge/author ship UNSET, which inherits the session model exactly as before. A project that wants a
// cheaper decomposition pins them once in .acfwhip/config; the skill passes them through.
const MODELS = (args && args.models && typeof args.models === 'object') ? args.models : {}
const SHELL_MODEL = (args && args.shellModel) || MODELS.shell || 'haiku'
const EFFORTS = (args && args.efforts && typeof args.efforts === 'object') ? args.efforts : {}
const agentsByTier = { shell: 0, judge: 0, author: 0 }
function shellOpts(o) {
  const out = Object.assign({}, o, { model: SHELL_MODEL })
  if (EFFORTS.shell) out.effort = EFFORTS.shell
  agentsByTier.shell++
  return out
}
function tierOpts(o, tier) {
  const out = Object.assign({}, o)
  if (MODELS[tier]) out.model = MODELS[tier]
  if (agentsByTier[tier] != null) agentsByTier[tier]++
  return out
}
// How many independent planners compete. The slug partition and the dependency graph are genuine
// judgement calls with several defensible answers, which is the one place in /task where
// generate-then-judge beats one shot.
const PLANNERS = (args && typeof args.planners === 'number') ? Math.max(1, Math.min(3, args.planners)) : 2
// Non-files stores author into a scratch dir before the single writer ingests them. It used to be
// .acfwhip/staging/, which whip-init gitignores nowhere — so every /task run on a non-files backend
// left untracked scratch files in the consumer's tree, and `git status` never came back clean.
// Relocating it under the already-ignored .acfwhip/run/ namespace is the fix: one less ignore pattern
// to add, and it works on every project already initialised, including ones that never re-run
// /whip-init. (.acfwhip/ must never be ignored wholesale — config/ and integrated/ are committed.)
const AUTHOR_DIR = filesStore ? `.backlog/pending` : `.acfwhip/run/staging`

// ---- enums (mirror task-template.md / task-engineer-pattern.md) ----
const SLUG_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/
// Task-id category vocabulary. Mirrored by ACFW_ID_CATEGORIES in skills/whip-doctor/bin/doctor.sh —
// the two are the same regex and drifted apart once already, so change them together. The list now
// spans the conventional-commit types beyond the original eight, because teams put the originating
// ticket's category in the id and an unrecognised prefix was rejected outright.
const CATEGORIES = ['feature', 'bug', 'infra', 'test', 'docs', 'refactor', 'data', 'ml', 'chore', 'perf', 'ci', 'build', 'style']
// The sequence number is [0-9]+, not [0-9]{1,4}: a five-digit ticket number in the id was rejected
// here while doctor.sh's slug derivation silently TRUNCATED it to four, so two tasks whose ids
// differed only in the fifth digit derived the same worktree slug. Nothing derives ordering from
// this segment, so there is no reason to bound it.
const ID_RE = new RegExp(`^(${CATEGORIES.join('|')})-[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$`)
const PRIORITIES = ['blocker', 'critical', 'high', 'medium', 'low']
// The valid set of agents is the project's REAL registry (.claude/agents/*.md), discovered at runtime
// below — NOT a hardcoded list. A static list drifts from what whip-init/whip-add-agents actually
// generate and from the doctor's unknown-agent gate, which would block /go after files are written.

// ---- schemas ----
const TASK_STUB = {
  type: 'object',
  additionalProperties: false,
  required: ['id', 'title', 'category', 'priority', 'assignedAgent', 'isCodeMutating', 'worktreeSlug', 'prGroup', 'touchesGlobs', 'dependencies', 'estimatedHours', 'what', 'why', 'constraints', 'outOfScope'],
  properties: {
    id: { type: 'string', description: `category-NNN-descriptive-name, kebab-case; NNN zero-padded; category one of ${CATEGORIES.join('|')}` },
    title: { type: 'string', description: 'Clear human task title' },
    category: { type: 'string', enum: CATEGORIES },
    priority: { type: 'string', enum: PRIORITIES },
    assignedAgent: { type: 'string', description: 'one of the project\'s installed .claude/agents (the prompt lists the valid names)' },
    isCodeMutating: { type: 'boolean', description: 'true if the task changes code; false only for research-only or docs-only-outside-the-codebase tasks' },
    worktreeSlug: { type: 'string', description: 'kebab-case slug shared by tasks touching the same surface area; literal "none" ONLY when isCodeMutating is false. NEVER equal to the task id (one-slug-per-task defeats batching).' },
    prGroup: { type: 'string', description: 'kebab-case slug; defaults to the same value as worktreeSlug' },
    touchesGlobs: { type: 'array', items: { type: 'string' }, description: 'file globs this task modifies (e.g. services/api/**, go.mod); ["none"] ONLY when isCodeMutating is false' },
    dependencies: { type: 'array', items: { type: 'string' }, description: 'ids of OTHER tasks in this same plan that must complete first; [] if none' },
    estimatedHours: { type: 'string', description: 'realistic estimate; split tasks larger than ~8h' },
    what: { type: 'string', description: 'WHAT to build — binary, testable outcomes. No HOW, no code.' },
    why: { type: 'string', description: 'WHY — business value / user impact' },
    constraints: { type: 'string', description: 'performance / security / compatibility constraints' },
    outOfScope: { type: 'string', description: 'explicit out-of-scope boundary (mandatory)' },
  },
}
const DECOMPOSITION_PLAN = {
  type: 'object',
  additionalProperties: false,
  required: ['tasks', 'summary'],
  properties: {
    tasks: { type: 'array', items: TASK_STUB },
    summary: { type: 'string', description: 'one-line summary of the decomposition' },
  },
}
const AUTHORED = {
  type: 'object',
  additionalProperties: false,
  required: ['id', 'filename', 'written', 'note'],
  properties: {
    id: { type: 'string' },
    filename: { type: 'string', description: 'basename written under .backlog/pending/, e.g. feature-001-user-auth.md' },
    written: { type: 'boolean', description: 'true if the file was written successfully' },
    note: { type: 'string', description: 'short status or error detail' },
  },
}
const WRITE_RESULT = {
  type: 'object',
  additionalProperties: false,
  required: ['committed', 'commitSha', 'files', 'note'],
  properties: {
    committed: { type: 'boolean' },
    commitSha: { type: 'string', description: 'HEAD sha after the commit, or "n/a"' },
    files: { type: 'array', items: { type: 'string' } },
    note: { type: 'string' },
  },
}
const DOCTOR_REPORT = {
  type: 'object',
  additionalProperties: false,
  required: ['ok', 'summaryLine', 'fatals', 'warns'],
  properties: {
    ok: { type: 'boolean', description: 'true when SUMMARY ok=true (no FATAL findings)' },
    summaryLine: { type: 'string', description: 'the verbatim SUMMARY|... line' },
    fatals: { type: 'array', items: { type: 'string' }, description: 'verbatim FATAL|... finding lines' },
    warns: { type: 'array', items: { type: 'string' }, description: 'verbatim WARN|... and REPAIRABLE|... finding lines' },
  },
}

// ---- the JS validation gate (layer 2) ----
function validatePlan(plan, registeredAgents) {
  const defects = []
  const tasks = (plan && Array.isArray(plan.tasks)) ? plan.tasks : []
  if (!tasks.length) { defects.push('plan contains no tasks'); return defects }
  const idset = new Set()
  for (const t of tasks) {
    if (idset.has(t.id)) defects.push(`duplicate task id "${t.id}" — ids must be unique`)
    idset.add(t.id)
  }
  for (const t of tasks) {
    if (!ID_RE.test(t.id || '')) defects.push(`task "${t.id}": id must match <category>-<NNN>-<kebab-name> with category in ${CATEGORIES.join('|')}`)
    if (!PRIORITIES.includes(t.priority)) defects.push(`task "${t.id}": priority "${t.priority}" must be one of ${PRIORITIES.join('|')}`)
    if (registeredAgents.length && !registeredAgents.includes(t.assignedAgent)) defects.push(`task "${t.id}": assignedAgent "${t.assignedAgent}" is not an installed agent (no .claude/agents/${t.assignedAgent}.md)`)
    if (t.isCodeMutating) {
      if (t.worktreeSlug === 'none' || !SLUG_RE.test(t.worktreeSlug || '')) defects.push(`task "${t.id}": code-mutating task needs a kebab-case worktreeSlug (not "none", not empty)`)
      if (t.worktreeSlug && t.worktreeSlug === t.id) defects.push(`task "${t.id}": worktreeSlug must NOT equal the task id — siblings touching the same surface share one slug`)
      const globs = (Array.isArray(t.touchesGlobs) ? t.touchesGlobs : []).filter((g) => g && g !== 'none')
      if (!globs.length) defects.push(`task "${t.id}": code-mutating task needs non-empty touchesGlobs (the files it will modify)`)
    } else {
      if (t.worktreeSlug !== 'none') defects.push(`task "${t.id}": non-code task must set worktreeSlug to the literal "none" (got "${t.worktreeSlug}")`)
    }
    for (const d of (Array.isArray(t.dependencies) ? t.dependencies : [])) {
      if (d === t.id) defects.push(`task "${t.id}": cannot depend on itself`)
      else if (!idset.has(d)) defects.push(`task "${t.id}": dependency "${d}" is not another task in this plan`)
    }
  }
  // acyclic check over in-plan dependency edges (DFS 3-color)
  const adj = new Map(tasks.map((t) => [t.id, (Array.isArray(t.dependencies) ? t.dependencies : []).filter((d) => idset.has(d))]))
  const color = new Map([...idset].map((i) => [i, 0])) // 0 white, 1 gray, 2 black
  let cyclic = false
  const dfs = (u) => {
    color.set(u, 1)
    for (const v of (adj.get(u) || [])) {
      if (color.get(v) === 1) { cyclic = true; return }
      if (color.get(v) === 0) dfs(v)
    }
    color.set(u, 2)
  }
  for (const i of idset) if (color.get(i) === 0) dfs(i)
  if (cyclic) defects.push('dependency graph contains a cycle — dependencies must be acyclic')
  return defects
}

// ============================ RECON ============================
phase('Recon')

// Discover the REAL agent registry so the layer-2 gate agrees with the doctor's unknown-agent check.
const REGISTRY = { type: 'object', additionalProperties: false, required: ['agents'], properties: { agents: { type: 'array', items: { type: 'string' } } } }
const reg = await agent(
  `List this project's installed specialist agents. Run exactly:
  ls -1 ${sq(trunkRoot)}/.claude/agents/*.md 2>/dev/null | sed -E 's#.*/##; s#\\.md$##'
Return the basenames (no .md extension, no directory path) as agents[]. If the directory is missing or empty, return an empty array.`,
  shellOpts({ label: 'discover-agents', phase: 'Decompose', schema: REGISTRY }),
)
const registeredAgents = (reg && Array.isArray(reg.agents)) ? reg.agents : []
// Empty registry: abort before writing any files. validatePlan can only check assignedAgent against
// installed agents; with none installed it would pass ANY name, and /go's doctor then FATALs every
// task (unknown-agent) at the bootstrap gate — a backlog that /task accepted but /go can never
// dispatch. Fail loudly here with the fix (run /whip-init) instead of producing a stuck backlog.
if (!registeredAgents.length) {
  return {
    phase: 'decompose',
    aborted: true,
    reason: 'no specialist agents installed (.claude/agents/ is empty) — /go cannot dispatch to agents that do not exist',
    nextStep: 'Run /whip-init (and /whip-add-agents) to scaffold specialist agents, then re-run /task.',
  }
}
const agentLine = registeredAgents.length
  ? `assignedAgent MUST be one of this project's installed agents: ${registeredAgents.join(', ')}.`
  : `assignedAgent should name an installed specialist agent (run /whip-init to generate them); no registry was found at .claude/agents/, so choose a sensible specialist name.`

// ---- 3.2.0 recon: three read-only agents, in parallel, feeding the planners ----
// The planner is the real bottleneck in /task: ONE agent, ONE shot, deciding the worktree slug
// partition (which IS /go's only concurrency partition) and the dependency graph (which IS its
// serialization order). validatePlan is purely STRUCTURAL — it proves the graph is acyclic and the
// slugs are kebab-case, and it cannot see a missing task, an over-shared slug that silently serializes
// half the run, a spurious ordering dep, or globs that overlap across distinct slugs.
const RECON_BACKLOG = {
  type: 'object', additionalProperties: false, required: ['ids', 'slugsInUse', 'liveBranches', 'note'],
  properties: {
    ids: { type: 'array', items: { type: 'string' } },
    slugsInUse: { type: 'array', items: { type: 'string' }, description: 'Worktree slugs already claimed by existing tasks' },
    liveBranches: { type: 'array', items: { type: 'string' }, description: 'worktree/<slug> branches that currently exist' },
    note: { type: 'string' },
  },
}
const RECON_SURFACE = {
  type: 'object', additionalProperties: false, required: ['modules', 'testLayout', 'note'],
  properties: {
    modules: { type: 'array', items: { type: 'string' }, description: 'real repo paths/globs this scope actually touches, most specific first' },
    testLayout: { type: 'string', description: 'where tests live and how they are named/run' },
    note: { type: 'string' },
  },
}
const RECON_CONVENTIONS = {
  type: 'object', additionalProperties: false, required: ['agents', 'gateCommands', 'styleNotes', 'note'],
  properties: {
    agents: { type: 'array', items: { type: 'string' }, description: 'one line per installed agent: "<name>: <what it is actually for>"' },
    gateCommands: { type: 'string', description: 'the literal quality-gate commands this repo uses' },
    styleNotes: { type: 'string', description: 'house rules a task description must obey' },
    note: { type: 'string' },
  },
}

const [rBacklog, rSurface, rConv] = await parallel([
  () => agent(`${ENV}
Read-only reconnaissance of the EXISTING backlog. Change nothing.
1. Every existing task id:
${filesStore
    ? `     cd ${sq(trunkRoot)} && grep -rhoE '^- \\*\\*ID\\*\\*: .*' .backlog 2>/dev/null | sed -E 's/^- \\*\\*ID\\*\\*: *//' | sort -u`
    : `     cd ${sq(trunkRoot)} && bash ${sq(STORE)} snapshot 2>/dev/null | jq -r '(.tasks[]?, .inactive[]?) | .id' 2>/dev/null | sort -u`}
2. Every Worktree slug ALREADY CLAIMED by an existing task (INCLUDING draft and archived ones — the
   dispatcher splits those into inactive[], but a slug they hold is still taken):
${filesStore
    ? `     cd ${sq(trunkRoot)} && grep -rhoE '^- \\*\\*Worktree\\*\\*: .*' .backlog 2>/dev/null | sed -E 's/^- \\*\\*Worktree\\*\\*: *//' | tr -d ' ' | sort -u`
    : `     cd ${sq(trunkRoot)} && bash ${sq(STORE)} snapshot 2>/dev/null | jq -r '(.tasks[]?, .inactive[]?) | .slug' 2>/dev/null | sort -u`}
3. Live worktree branches:  git -C ${sq(trunkRoot)} worktree list --porcelain | sed -n 's#^branch refs/heads/##p'
Return the ReconBacklog.`, shellOpts({ label: 'recon:backlog', phase: 'Recon', schema: RECON_BACKLOG })),

  () => agent(`${ENV}
Read-only reconnaissance of the CODE SURFACE this scope touches. Change nothing, write nothing.

SCOPE:
${scope}

Explore ${sq(trunkRoot)} and report the REAL paths involved — the modules, packages or services this
scope would actually modify, as concrete globs a task's "Touches Globs" field could use verbatim. Be
specific: "services/user-api/**" not "the backend". Also report where the tests for those paths live
and how they are named. If the scope spans several independent surfaces, list them separately and most
specific first — that separation is what lets the planner give each one its own worktree slug and run
them in parallel.
Return the ReconSurface.`, { label: 'recon:surface', phase: 'Recon', schema: RECON_SURFACE }),

  () => agent(`${ENV}
Read-only reconnaissance of this project's CONVENTIONS. Change nothing.
1. Read the BODY of each installed agent definition and summarize what it is actually for, one line each:
     ${registeredAgents.map((a) => `${trunkRoot}/.claude/agents/${a}.md`).slice(0, 12).join('\n     ')}
   (A bare list of names cannot tell a planner which specialist a task belongs to.)
2. The literal quality-gate commands: docs/development/quality-gates-*.md, Makefile, package.json
   scripts, pyproject.toml, .pre-commit-config.yaml, go.mod — whichever exist.
3. House style for task descriptions: docs/acf/style/task-descriptions.md and
   docs/acf/backlog/task-template.md if present, plus CLAUDE.md conventions.
Return the ReconConventions.`, { label: 'recon:conventions', phase: 'Recon', schema: RECON_CONVENTIONS }),
])

const reconBundle = `
════════════ RECON (read-only agents already gathered this for you) ════════════
EXISTING TASK IDS (do not collide): ${((rBacklog && rBacklog.ids) || []).slice(0, 80).join(', ') || '(none)'}
SLUGS ALREADY CLAIMED: ${((rBacklog && rBacklog.slugsInUse) || []).join(', ') || '(none)'}
LIVE WORKTREE BRANCHES: ${((rBacklog && rBacklog.liveBranches) || []).join(', ') || '(none)'}
  ^ A NEW task that claims a slug already owned by an in-flight branch will serialize behind it.
    Reuse a slug ONLY when the new task genuinely writes the same files.
REAL CODE SURFACE FOR THIS SCOPE:
${((rSurface && rSurface.modules) || []).map((m) => `  - ${m}`).join('\n') || '  (recon found nothing — be conservative with touchesGlobs)'}
  tests: ${(rSurface && rSurface.testLayout) || '(unknown)'}
INSTALLED SPECIALISTS AND WHAT THEY ARE FOR:
${((rConv && rConv.agents) || []).map((a) => `  - ${a}`).join('\n') || '  (no descriptions available)'}
QUALITY GATES: ${(rConv && rConv.gateCommands) || '(unknown)'}
HOUSE STYLE: ${(rConv && rConv.styleNotes) || '(none found)'}
`
log(`recon: ${((rBacklog && rBacklog.ids) || []).length} existing id(s), ${((rBacklog && rBacklog.slugsInUse) || []).length} slug(s) in use, ${((rSurface && rSurface.modules) || []).length} surface path(s)`)

// ============================ DECOMPOSE ============================
phase('Decompose')

const PLAN_RULES = `
RULES (these are enforced by an automatic gate AFTER you respond; violating them forces a re-run):
- One logical feature = one task (NOT micro-tasks). A feature's API + validation + tests + docs are ONE task. Mixed-stack work for one feature (backend + frontend) is ONE task.
- Each task states WHAT (binary, testable outcomes) and WHY (value); NEVER HOW (no algorithms, no code, no library mandates). Banned words: comprehensive, systematic, significant, substantial, robust, elegant, enhance, optimize, streamline.
- id format: <category>-<NNN>-<kebab-name>, category in ${CATEGORIES.join('|')}, NNN zero-padded; pick NNN to NOT collide with existing .backlog ids you scanned. ids unique within the plan.
- WORKTREE SLUG (load-bearing — it IS the parallelism partition): set isCodeMutating true for any task that changes code. Every code-mutating task MUST have a kebab-case worktreeSlug. DEFAULT TO MAXIMUM PARALLELISM — give every INDEPENDENT surface its own slug so those tasks run concurrently. SHARE a slug ONLY when tasks write the SAME files/module (they must serialize on one branch, and usually share a prGroup). Over-sharing serializes work that could run in parallel; one-slug-per-task (worktreeSlug == id) is the opposite error and defeats batching of genuinely same-surface work — do neither. Use worktreeSlug "none" and touchesGlobs ["none"] ONLY for genuinely non-code tasks (research-only or docs-only outside the codebase).
- prGroup defaults to the worktreeSlug value.
- touchesGlobs: the concrete file globs the task will modify (e.g. services/user-api/**, go.mod). Two different-slug tasks SHOULD NOT overlap globs (overlap is a mis-partition signal — either they share a surface and should share a slug, or the globs are too broad). Be specific.
- DEPENDENCIES (the other parallelism lever): reference only OTHER task ids in this plan; the graph MUST be acyclic. Declare a dependency ONLY when a task genuinely consumes another's output. Do NOT add ordering or convenience deps — every unnecessary dependency serializes work that could otherwise run in parallel. Prefer the empty set.
- ${agentLine}
`

// Each competing planner gets a different EMPHASIS. Identical prompts produce correlated plans and the
// judge has nothing to choose between; the disagreements are the point.
const PLANNER_ANGLES = [
  'Bias toward MAXIMUM PARALLELISM: give every genuinely independent surface its own worktree slug, and declare a dependency only where one task truly consumes another\'s output. Then re-read your own graph and delete every dependency you cannot justify in one sentence.',
  'Bias toward COHESION and correct sequencing: group work that touches the same files onto one slug so it cannot conflict, and make sure nothing is scheduled before the thing it actually needs. Then check you have not serialized two surfaces that never touch the same file.',
  'Bias toward COMPLETENESS: start from the acceptance criteria the scope implies and work backwards. Make sure migration, tests, docs and rollback are represented wherever the scope needs them, without inventing work the scope does not ask for.',
]

async function plan(angle, idx, extraDefects, prior) {
  const fix = extraDefects && extraDefects.length
    ? `\n\nYOUR PREVIOUS PLAN FAILED VALIDATION. Fix exactly these defects and return a corrected FULL plan:\n- ${extraDefects.join('\n- ')}\n\nPrevious plan was:\n${JSON.stringify(prior, null, 0)}\n`
    : ''
  return agent(
    `You are the task-engineer planner for the acf-whip backlog. Decompose this scope into atomic task stubs.

SCOPE:
${scope}
${reconBundle}
YOUR ANGLE: ${angle}

Read, if present, ${sq(trunkRoot)}/docs/acf/style/task-descriptions.md and ${sq(trunkRoot)}/docs/acf/backlog/task-template.md for the house style (these constrain how you phrase WHAT/WHY). The recon above already gathered the existing ids and slugs — do not re-scan them.

Then return a DecompositionPlan. Do NOT write any files — another stage does that. Return ONLY the structured plan.
${PLAN_RULES}${fix}`,
    tierOpts({ label: extraDefects && extraDefects.length ? `plan:retry${idx}` : `plan:${idx}`, phase: 'Decompose', schema: DECOMPOSITION_PLAN, agentType: 'task-engineer' }, 'judge'),
  )
}

// ---- generate K competing plans, keep the structurally valid ones, judge ----
const candidates = (await parallel(
  PLANNER_ANGLES.slice(0, PLANNERS).map((angle, i) => () => plan(angle, i)),
)).filter(Boolean)

const scored = candidates.map((p, i) => ({ plan: p, idx: i, defects: validatePlan(p, registeredAgents) }))
const valid = scored.filter((s) => !s.defects.length)
log(`decompose: ${candidates.length} plan(s) proposed, ${valid.length} structurally valid`)

let planResult = null
if (valid.length === 1) {
  planResult = valid[0].plan
} else if (valid.length > 1) {
  // The judge chooses between REAL alternatives, so it must state a reason — a judge that cannot say
  // why is a judge that picked at random.
  const JUDGE = {
    type: 'object', additionalProperties: false, required: ['choice', 'reason'],
    properties: {
      choice: { type: 'integer', description: 'the index of the plan you are adopting' },
      reason: { type: 'string', description: 'one line: what makes that partition better HERE' },
    },
  }
  const j = await agent(
    `Two or more independent planners decomposed the same scope. Adopt the better partition.

SCOPE:
${scope}
${reconBundle}
${valid.map((s, i) => `──────── PLAN ${i} (${s.plan.tasks.length} tasks) ────────\n${JSON.stringify(s.plan, null, 0)}`).join('\n\n')}

JUDGE ON THESE, in order:
1. THE WORKTREE SLUG PARTITION. In acf-whip the slug IS the parallelism lock: two tasks sharing a slug
   run strictly sequentially on one branch. Over-sharing silently serializes work that could have run
   concurrently; one-slug-per-task defeats batching of genuinely same-surface work and produces
   conflicting branches. Which plan's partition matches the REAL code surface above?
2. THE DEPENDENCY GRAPH. Every unnecessary edge serializes work. Which plan declares only genuine
   producer/consumer edges?
3. COMPLETENESS against the scope, without inventing work the scope does not ask for.
4. Whether touchesGlobs are concrete real paths (from recon) rather than plausible-looking fiction —
   the doctor's cross-slug overlap check is inert against invented globs.

Return the index of the plan you adopt and one line on why.`,
    tierOpts({ label: 'judge:plan', phase: 'Decompose', schema: JUDGE, agentType: 'task-engineer' }, 'judge'),
  )
  const pick = (j && Number.isInteger(j.choice) && valid[j.choice]) ? valid[j.choice] : valid[0]
  planResult = pick.plan
  log(`decompose: adopted plan ${pick.idx}${j && j.reason ? ` — ${String(j.reason).slice(0, 160)}` : ''}`)
} else {
  // Nothing was structurally valid: fall back to the bounded repair loop on the least-broken plan.
  scored.sort((a, b) => a.defects.length - b.defects.length)
  planResult = scored.length ? scored[0].plan : null
}

let defects = validatePlan(planResult, registeredAgents)
let attempts = 1
const MAX_PLAN_ATTEMPTS = 3
while (defects.length && attempts < MAX_PLAN_ATTEMPTS) {
  log(`plan attempt ${attempts}: ${defects.length} defect(s) — re-dispatching planner`)
  planResult = await plan(PLANNER_ANGLES[0], 0, defects, planResult)
  defects = validatePlan(planResult, registeredAgents)
  attempts++
}
if (defects.length) {
  return {
    phase: 'decompose',
    aborted: true,
    reason: 'decomposition failed validation after bounded retries; no files written',
    attempts,
    defects,
    plan: planResult,
  }
}

// ---- completeness critic: ADVISORY, never blocking ----
// It emits defects in validatePlan's shape so it re-enters the SAME bounded repair loop with no new
// machinery. But its findings are advisory by design: structural defects are objective and abort at
// the cap, whereas "you forgot a task" is a judgement, and letting it abort would make /task refuse to
// produce a structurally valid plan on subjective grounds.
const CRITIC = {
  type: 'object', additionalProperties: false, required: ['defects'],
  properties: { defects: { type: 'array', items: { type: 'string' }, description: 'one line each; empty if the plan is sound' } },
}
let critique = []
{
  const c = await agent(
    `Attack this decomposition. You are the last check before these tasks are written to disk and executed.

SCOPE:
${scope}
${reconBundle}
ADOPTED PLAN:
${JSON.stringify(planResult, null, 0)}

Report ONLY defects you can name concretely. Look for:
  * a task the scope REQUIRES that is missing entirely (the most expensive defect — /go executes what
    is written and nothing else)
  * two tasks sharing a worktree slug that do NOT touch the same files (silently serialized)
  * two tasks with DIFFERENT slugs whose touchesGlobs overlap (they will conflict at integration)
  * a dependency edge with no real producer/consumer relationship (pure serialization)
  * an acceptance criterion that cannot be verified from inside a single worktree
  * a task assigned to a specialist whose stated purpose does not match the work
  * HOW-level prescription in a description (banned: algorithms, code, library mandates)

Return an empty array if the plan is sound. Do NOT invent defects to look thorough.`,
    tierOpts({ label: 'critic:completeness', phase: 'Decompose', schema: CRITIC, agentType: 'task-engineer' }, 'judge'),
  )
  critique = (c && Array.isArray(c.defects)) ? c.defects.filter((d) => typeof d === 'string' && d.trim()) : []
  if (critique.length) {
    log(`critic: ${critique.length} advisory defect(s) — one repair round`)
    const repaired = await plan(PLANNER_ANGLES[0], 0, critique, planResult)
    const repairedDefects = repaired ? validatePlan(repaired, registeredAgents) : ['critic repair produced no plan']
    if (!repairedDefects.length) {
      planResult = repaired
      critique = []
      log('critic: repair adopted')
    } else {
      // The repair broke something structural. Keep the structurally valid plan and surface the
      // critique in the report rather than shipping a plan that cannot be dispatched.
      log(`critic: repair failed structural validation (${repairedDefects.length} defect(s)) — keeping the original plan and surfacing the critique`)
    }
  }
}

const tasks = planResult.tasks.map((t) => ({
  ...t,
  prGroup: t.prGroup && t.prGroup.trim() ? t.prGroup : t.worktreeSlug,
  filename: `${t.id}.md`,
}))
log(`plan validated after ${attempts} attempt(s): ${tasks.length} task(s) — slugs: ${[...new Set(tasks.map((t) => t.worktreeSlug))].join(', ')}`)

// ============================ AUTHOR (parallel) ============================
phase('Author')

const TEMPLATE_CONTRACT = `
Write the file at ${sq(trunkRoot)}/${AUTHOR_DIR}/<filename> (create the directory if missing) following docs/acf/backlog/task-template.md EXACTLY. Read that template first (path: ${sq(trunkRoot)}/docs/acf/backlog/task-template.md) — if it is absent, use this structure.

The metadata block is NOT YAML — it is a "## Metadata" section of "- **Field**: value" bullets. Emit, in order:
  # Task: <title>
  ## Metadata
  - **ID**: <id>
  - **Status**: pending
  - **Priority**: <priority>
  - **Estimated Hours**: <estimatedHours>
  - **Assigned Agent**: <assignedAgent>
  - **Worktree**: <worktreeSlug>
  - **PR Group**: <prGroup>
  - **Touches Globs**: <comma-separated globs, or "none">
  - **Dependencies**: <comma-separated ids, or "none">
  - **Integrated-At**:
  - **Rejection Count**: 0
  - **Created By**: task-engineer
  - **Created At**: <REAL UTC timestamp> UTC
  - **Documentation**: none

Then these sections (rich, house-style, binary/testable, WHAT/WHY only, NO implementation code beyond 2-3 line signatures):
  ## Description   (WHAT + WHY)
  ## Acceptance Criteria   (at least 3 binary checkbox items, plus the 4 standard trailing checkboxes: all tests pass; quality gates pass; documentation updated if needed; changes committed with conventional message)
  ## Technical Requirements   (specification level — what to modify, patterns to follow, interface contracts; NO step-by-step HOW)
  ## Edge Cases to Handle
  ## Out of Scope   (MANDATORY)
  ## Transition Log
  with a seed row built from a REAL timestamp via:  date -u +"%Y-%m-%d %H:%M:%S"
  exact seed row format:  | <ts> | draft | pending | task-engineer | Initial task creation |

CRITICAL: get the real timestamp from \`date -u +"%Y-%m-%d %H:%M:%S"\` — NEVER a placeholder. The "Created At" field appends " UTC". Do NOT git add or git commit — a separate writer commits. Do NOT enter a worktree. Write ONLY this one file.`

const authored = (await parallel(
  tasks.map((t) => () =>
    agent(
      `You are task-engineer authoring ONE backlog task file. ${ENV}

Task stub (authoritative metadata — reproduce these field values verbatim):
${JSON.stringify({ id: t.id, title: t.title, priority: t.priority, estimatedHours: t.estimatedHours, assignedAgent: t.assignedAgent, worktreeSlug: t.worktreeSlug, prGroup: t.prGroup, touchesGlobs: t.touchesGlobs, dependencies: t.dependencies }, null, 0)}

Scope material to expand into rich WHAT/WHY/criteria/edge-cases/out-of-scope:
WHAT: ${t.what}
WHY: ${t.why}
CONSTRAINTS: ${t.constraints}
OUT OF SCOPE: ${t.outOfScope}

Write to EXACTLY this filename — do NOT rename it or add a descriptive suffix; the id IS the stem: ${t.filename}
${TEMPLATE_CONTRACT}

Return the AuthoredTask structured result (its id MUST be "${t.id}" and its filename MUST be "${t.filename}").`,
      tierOpts({ label: `author:${t.id}`, phase: 'Author', schema: AUTHORED, agentType: 'task-engineer' }, 'author'),
    ),
  ),
)).filter(Boolean)

// Key off the AUTHORITATIVE task (matched by returned id), NOT the agent-returned filename — a
// divergent filename must not corrupt the commit slug list or drop a task from the report.
const writtenIds = new Set(authored.filter((a) => a.written).map((a) => a.id))
const failedAuthors = authored.filter((a) => !a.written)
const writtenTasks = tasks.filter((t) => writtenIds.has(t.id))
const writtenFiles = writtenTasks.map((t) => t.filename)

// ============================ WRITE (single committer) ============================
phase('Write')

let writeResult = { committed: false, commitSha: 'n/a', files: writtenFiles, note: 'no files to commit' }
if (writtenFiles.length && !filesStore) {
  // Non-files store: the single writer INGESTS each staged document into the task store. The
  // validated dependency graph is stamped via --set (the same silent-loss defense as the sed
  // stamp below — the store copy, not the authored line, is what /go schedules from).
  const createLines = writtenTasks.map((t) => {
    const deps = (Array.isArray(t.dependencies) ? t.dependencies : []).join(', ') || 'none'
    return `  bash ${sq(STORE)} create --file ${sq(`${trunkRoot}/${AUTHOR_DIR}/${t.filename}`)} --folder pending --set ${sq(`Dependencies=${deps}`)} && rm -f ${sq(`${trunkRoot}/${AUTHOR_DIR}/${t.filename}`)} && bash ${sq(FOCUS)} add --no-resolve --by task ${sq(t.id)}`
  }).join('\n')
  writeResult = await agent(
    `You are the single backlog writer. ${ENV} Working at the trunk repo root ${sq(trunkRoot)}.

These task documents were just authored under ${AUTHOR_DIR}/ and must be ingested into the '${store}' task store.

FIRST, make sure the scratch namespace is ignored — a project initialised before this directory
existed has no rule for it, and a half-ingested run would otherwise leave untracked files behind:

  cd ${sq(trunkRoot)} && grep -qxF '.acfwhip/run/' .gitignore 2>/dev/null || printf '\n# ACF Whip /go run state (per-task harness scripts, stage ledgers, /task staging)\n.acfwhip/run/\n' >> .gitignore

THEN run these commands IN ORDER, one at a time (each creates one task in the store, then removes the staged file; a "already exists" failure with exit code 4 means a duplicate id — record it in note and continue):
${createLines}

Return the WriteResult: committed = true when every create succeeded, commitSha "n/a", files = the staged basenames, note = any failures.`,
    shellOpts({ label: 'write:ingest', phase: 'Write', schema: WRITE_RESULT }),
  )
} else if (writtenFiles.length) {
  // The dependency graph was validated in JS (in-plan, acyclic, no self-edges) and is authoritative.
  // The Dependencies LINE, though, was transcribed into markdown by an author agent from a prompt blob —
  // a silent-loss channel: a whole decomposition once emerged "Dependencies: none" and /go dispatched
  // downstream tasks before their upstreams landed. Stamp the validated value over whatever was written,
  // in the committer (it runs after every author, before `git add`, so the stamp rides the same commit).
  // Injection-safe: ID_RE admits only kebab-case ids, so no sed metacharacter can reach these lines.
  const depStamps = writtenTasks.map((t) => {
    const deps = (Array.isArray(t.dependencies) ? t.dependencies : []).join(', ') || 'none'
    const f = `.backlog/pending/${t.filename}`
    return `   if grep -qE '^- \\*\\*Dependencies\\*\\*:' ${sq(f)}; then sed -i.bak -E 's|^- \\*\\*Dependencies\\*\\*:.*|- **Dependencies**: ${deps}|' ${sq(f)}; else sed -i.bak -E '/^- \\*\\*Status\\*\\*:/a\\\\\n- **Dependencies**: ${deps}' ${sq(f)}; fi; rm -f ${sq(`${f}.bak`)}`
  }).join('\n')

  writeResult = await agent(
    `You are the single backlog writer. ${ENV} Working at the trunk repo root ${sq(trunkRoot)} on branch ${sq(trunkBranch)}.

These task files were just authored under .backlog/pending/:
${writtenFiles.map((f) => `  - .backlog/pending/${f}`).join('\n')}

Do EXACTLY this, nothing else:
1. cd ${sq(trunkRoot)}
2. Verify each listed file exists under .backlog/pending/. If any are missing, report them in note and continue with the ones present.
3. Stamp the VALIDATED dependency graph over each file's Dependencies line (the plan is authoritative; the authored line is not). Run these, skipping any whose file is missing:
${depStamps}
4. Stage ONLY those files:  git add ${writtenFiles.map((f) => `.backlog/pending/${sq(f)}`).join(' ')}
5. Commit once:  git commit -q -m "task: create ${writtenFiles.length} backlog task(s) [${[...new Set(writtenTasks.map((t) => t.worktreeSlug))].join(', ')}]"
6. Capture the new HEAD sha:  git rev-parse HEAD
7. Point this checkout's run focus at the tasks you just created, so a bare /go runs them and nothing else (best-effort — if it fails, say so in note and continue; the tasks are already committed):
   bash ${sq(FOCUS)} add --no-resolve --by task ${writtenTasks.map((t) => sq(t.id)).join(' ')}

Make NO other edit to the files. Do NOT touch any other path. Return the WriteResult.`,
    shellOpts({ label: 'write:commit', phase: 'Write', schema: WRITE_RESULT }),
  )
}

// ============================ VERIFY (create-time doctor) ============================
phase('Verify')

const doctor = await agent(
  `Run the acf-whip integrity doctor (report-only) and return its result. ${ENV}
Run exactly:  bash ${sq(STORE)} doctor
Capture stdout. The last line is "SUMMARY|fatal=N|repairable=N|warn=N|ok=true|false". Lines beginning FATAL| are fatal; lines beginning WARN| or REPAIRABLE| are non-fatal. Return the DoctorReport with ok = (the SUMMARY ok field is true), summaryLine = the verbatim SUMMARY line, fatals = the verbatim FATAL lines, warns = the verbatim WARN+REPAIRABLE lines.`,
  shellOpts({ label: 'verify:doctor', phase: 'Verify', schema: DOCTOR_REPORT }),
)

// ============================ REPORT ============================
return {
  phase: 'complete',
  scope,
  attempts,
  plannersRun: candidates.length,
  recon: {
    existingIds: ((rBacklog && rBacklog.ids) || []).length,
    slugsInUse: (rBacklog && rBacklog.slugsInUse) || [],
    surface: (rSurface && rSurface.modules) || [],
  },
  // Advisory findings the critic raised that survived (the repair either was not attempted or would
  // have broken structural validity). Surfaced, never silently dropped — a "missing task" defect is
  // the most expensive kind, because /go executes what is written and nothing else.
  critique,
  created: writtenTasks
    .map((t) => ({ id: t.id, slug: t.worktreeSlug, prGroup: t.prGroup, priority: t.priority, agent: t.assignedAgent, deps: t.dependencies })),
  failedAuthors: failedAuthors.map((a) => ({ id: a.id, note: a.note })),
  commit: { committed: writeResult.committed, sha: writeResult.commitSha, note: writeResult.note },
  doctor: { ok: doctor && doctor.ok, summary: doctor && doctor.summaryLine, fatals: (doctor && doctor.fatals) || [] },
  // 3.4.0 cost legibility, same contract as /go's RunReport: which model each tier ran on and how
  // many agents each tier spent. A decomposition that silently ran every planner on the session model
  // because a config pin was misspelled is otherwise indistinguishable from one that honoured it.
  models: { shell: SHELL_MODEL, judge: MODELS.judge || null, author: MODELS.author || null, efforts: { shell: EFFORTS.shell || null } },
  agentsByTier,
  focus: { count: writtenTasks.length, note: 'a bare /go runs these and nothing else; /go --all runs the whole backlog' },
  nextStep: critique.length
    ? `Run /go — it runs these ${writtenTasks.length} task(s) as your focus. NOTE: ${critique.length} advisory critique(s) were left unresolved — review them first.`
    : `Run /go — it runs these ${writtenTasks.length} task(s) as your focus (/go --all runs the whole backlog).`,
}
