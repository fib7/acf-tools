export const meta = {
  name: 'whip-task',
  description: 'Decompose a scope into atomic backlog task files with schema-enforced worktree slugs, a JS validation gate (acyclic deps, unique ids, kebab slugs), parallel authoring, a single committing writer, and a create-time doctor gate.',
  whenToUse: 'Launched by the acf-whip /task skill when dynamic workflows are available. Replaces the Claude-as-orchestrator decomposition loop with a deterministic script so slug/dependency enforcement happens before any file is written.',
  phases: [
    { title: 'Decompose', detail: 'one planner agent splits scope into a validated task graph (bounded re-dispatch on defects)' },
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
const DOCTOR = `${pluginRoot}/skills/whip-doctor/bin/doctor.sh`
const ENV = `export ACFW_TRUNK_ROOT=${sq(trunkRoot)}; export ACFW_TRUNK_BRANCH=${sq(trunkBranch)};`

// ---- enums (mirror task-template.md / task-engineer-pattern.md) ----
const SLUG_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/
const ID_RE = /^(feature|bug|infra|test|docs|refactor|data|ml)-[0-9]{1,4}-[a-z0-9]+(-[a-z0-9]+)*$/
const CATEGORIES = ['feature', 'bug', 'infra', 'test', 'docs', 'refactor', 'data', 'ml']
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
    id: { type: 'string', description: 'category-NNN-descriptive-name, kebab-case; NNN zero-padded; category in feature|bug|infra|test|docs|refactor|data|ml' },
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

// ============================ DECOMPOSE ============================
phase('Decompose')

// Discover the REAL agent registry so the layer-2 gate agrees with the doctor's unknown-agent check.
const REGISTRY = { type: 'object', additionalProperties: false, required: ['agents'], properties: { agents: { type: 'array', items: { type: 'string' } } } }
const reg = await agent(
  `List this project's installed specialist agents. Run exactly:
  ls -1 ${sq(trunkRoot)}/.claude/agents/*.md 2>/dev/null | sed -E 's#.*/##; s#\\.md$##'
Return the basenames (no .md extension, no directory path) as agents[]. If the directory is missing or empty, return an empty array.`,
  { label: 'discover-agents', phase: 'Decompose', schema: REGISTRY },
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

async function plan(extraDefects, prior) {
  const fix = extraDefects && extraDefects.length
    ? `\n\nYOUR PREVIOUS PLAN FAILED VALIDATION. Fix exactly these defects and return a corrected FULL plan:\n- ${extraDefects.join('\n- ')}\n\nPrevious plan was:\n${JSON.stringify(prior, null, 0)}\n`
    : ''
  return agent(
    `You are the task-engineer planner for the acf-whip backlog. Decompose this scope into atomic task stubs.

SCOPE:
${scope}

First, scan the existing backlog so you pick non-colliding ids and avoid duplicating work. Run:
  cd ${sq(trunkRoot)} && grep -rhoE '^- \\*\\*ID\\*\\*: .*' .backlog 2>/dev/null | sort -u; ls .backlog/pending 2>/dev/null
Also read, if present, ${sq(trunkRoot)}/docs/acf/style/task-descriptions.md and ${sq(trunkRoot)}/docs/acf/backlog/task-template.md for the house style (these constrain how you phrase WHAT/WHY).

Then return a DecompositionPlan. Do NOT write any files — another stage does that. Return ONLY the structured plan.
${PLAN_RULES}${fix}`,
    { label: extraDefects && extraDefects.length ? 'plan:retry' : 'plan', phase: 'Decompose', schema: DECOMPOSITION_PLAN, agentType: 'task-engineer' },
  )
}

let planResult = await plan()
let defects = validatePlan(planResult, registeredAgents)
let attempts = 1
const MAX_PLAN_ATTEMPTS = 3
while (defects.length && attempts < MAX_PLAN_ATTEMPTS) {
  log(`plan attempt ${attempts}: ${defects.length} defect(s) — re-dispatching planner`)
  planResult = await plan(defects, planResult)
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

const tasks = planResult.tasks.map((t) => ({
  ...t,
  prGroup: t.prGroup && t.prGroup.trim() ? t.prGroup : t.worktreeSlug,
  filename: `${t.id}.md`,
}))
log(`plan validated after ${attempts} attempt(s): ${tasks.length} task(s) — slugs: ${[...new Set(tasks.map((t) => t.worktreeSlug))].join(', ')}`)

// ============================ AUTHOR (parallel) ============================
phase('Author')

const TEMPLATE_CONTRACT = `
Write the file at ${sq(trunkRoot)}/.backlog/pending/<filename> following docs/acf/backlog/task-template.md EXACTLY. Read that template first (path: ${sq(trunkRoot)}/docs/acf/backlog/task-template.md) — if it is absent, use this structure.

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
      { label: `author:${t.id}`, phase: 'Author', schema: AUTHORED, agentType: 'task-engineer' },
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
if (writtenFiles.length) {
  writeResult = await agent(
    `You are the single backlog writer. ${ENV} Working at the trunk repo root ${sq(trunkRoot)} on branch ${sq(trunkBranch)}.

These task files were just authored under .backlog/pending/:
${writtenFiles.map((f) => `  - .backlog/pending/${f}`).join('\n')}

Do EXACTLY this, nothing else:
1. cd ${sq(trunkRoot)}
2. Verify each listed file exists under .backlog/pending/. If any are missing, report them in note and continue with the ones present.
3. Stage ONLY those files:  git add ${writtenFiles.map((f) => `.backlog/pending/${sq(f)}`).join(' ')}
4. Commit once:  git commit -q -m "task: create ${writtenFiles.length} backlog task(s) [${[...new Set(writtenTasks.map((t) => t.worktreeSlug))].join(', ')}]"
5. Capture the new HEAD sha:  git rev-parse HEAD

Do NOT modify the files. Do NOT touch any other path. Return the WriteResult.`,
    { label: 'write:commit', phase: 'Write', schema: WRITE_RESULT },
  )
}

// ============================ VERIFY (create-time doctor) ============================
phase('Verify')

const doctor = await agent(
  `Run the acf-whip integrity doctor (report-only) and return its result. ${ENV}
Run exactly:  bash ${sq(DOCTOR)} ${sq(trunkRoot)}
Capture stdout. The last line is "SUMMARY|fatal=N|repairable=N|warn=N|ok=true|false". Lines beginning FATAL| are fatal; lines beginning WARN| or REPAIRABLE| are non-fatal. Return the DoctorReport with ok = (the SUMMARY ok field is true), summaryLine = the verbatim SUMMARY line, fatals = the verbatim FATAL lines, warns = the verbatim WARN+REPAIRABLE lines.`,
  { label: 'verify:doctor', phase: 'Verify', schema: DOCTOR_REPORT },
)

// ============================ REPORT ============================
return {
  phase: 'complete',
  scope,
  attempts,
  created: writtenTasks
    .map((t) => ({ id: t.id, slug: t.worktreeSlug, prGroup: t.prGroup, priority: t.priority, agent: t.assignedAgent, deps: t.dependencies })),
  failedAuthors: failedAuthors.map((a) => ({ id: a.id, note: a.note })),
  commit: { committed: writeResult.committed, sha: writeResult.commitSha, note: writeResult.note },
  doctor: { ok: doctor && doctor.ok, summary: doctor && doctor.summaryLine, fatals: (doctor && doctor.fatals) || [] },
  nextStep: 'Run /go to execute the backlog.',
}
