// phase17-template-drift.test.mjs — the shipped templates must not contradict the runtime.
//
// Every file under content/agent-patterns/** becomes an agent's SYSTEM prompt in a consumer project
// (whip-init generates .claude/agents/<name>.md from it). Nothing mechanically tied that markdown to
// the runtime it describes, so the 3.0.0 -> 3.2.0 migration — which moved every state transition from
// the agents to the /go orchestrator and re-cut the rejection budget from 5 to 3 — was applied to the
// code and to the middle of each template, but not to their headline instructions. A reviewer
// generated from the result was told, in its own system prompt, to move task files and to escalate at
// a count the orchestrator makes unreachable.
//
// These assertions read their expected values FROM THE RUNTIME SOURCE, never from a literal here, so
// the test cannot drift away from the thing it is pinning.
//
// Run: node acf-whip/tests/phase17-template-drift.test.mjs

import { readFileSync, readdirSync, statSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join, relative } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..')
const GO = readFileSync(join(ROOT, 'workflows', 'whip-go.workflow.js'), 'utf8')

let PASS = 0, FAIL = 0
const ok = (m) => { PASS++; console.log(`  PASS: ${m}`) }
const bad = (m) => { FAIL++; console.log(`  FAIL: ${m}`) }
const check = (m, c) => (c ? ok(m) : bad(m))

function walk(dir) {
  const out = []
  for (const e of readdirSync(dir)) {
    const p = join(dir, e)
    if (statSync(p).isDirectory()) out.push(...walk(p))
    else if (e.endsWith('.md')) out.push(p)
  }
  return out
}

// Shipped content that becomes agent-facing or consumer-facing text.
const AGENT_TEMPLATES = walk(join(ROOT, 'content', 'agent-patterns'))
const BACKLOG_DOCS = walk(join(ROOT, 'content', 'backlog'))
const ALL = [...AGENT_TEMPLATES, ...BACKLOG_DOCS]
const rel = (p) => relative(ROOT, p)

// ---------------------------------------------------------------------------
// 1. The retry cap is the runtime's. No shipped template may restate the number.
const MAX_REJECT = Number((GO.match(/const MAX_REJECT_RETRY = (\d+)/) || [])[1])
const MAX_BLOCK = Number((GO.match(/const MAX_BLOCK_RETRY = (\d+)/) || [])[1])
check(`the runtime's retry caps are readable from source (reject=${MAX_REJECT}, block=${MAX_BLOCK})`,
  Number.isInteger(MAX_REJECT) && Number.isInteger(MAX_BLOCK))

// A template that names a specific rejection threshold is claiming to know a runtime constant.
// Matches "rejection_count >= N", "rejection_count = N", "At rejection_count=N", "after N rejections".
const CAP_CLAIM = /rejection[_ ]count\s*(?:>=|===?|>)\s*(\d+)|at\s+rejection[_ ]count\s*=\s*(\d+)|after\s+(\d+)\s+rejections?/gi
const capOffenders = []
for (const f of ALL) {
  const text = readFileSync(f, 'utf8')
  let m
  CAP_CLAIM.lastIndex = 0
  while ((m = CAP_CLAIM.exec(text)) !== null) {
    const n = Number(m[1] ?? m[2] ?? m[3])
    if (Number.isInteger(n)) capOffenders.push(`${rel(f)}: "${m[0].trim()}"`)
  }
}
check(`no shipped template names a rejection threshold the runtime owns${capOffenders.length ? ` — found: ${capOffenders.join(' | ')}` : ''}`,
  capOffenders.length === 0)

// ---------------------------------------------------------------------------
// 2. Single writer. Only the orchestrator moves task state.
// An imperative "move it to <state>" aimed at the agent reading the template. Prose that describes
// what the ORCHESTRATOR does ("the orchestrator performs the move") is correct and must not trip.
const MOVE_CLAIM = /(?:^|\n)[^\n]*?\b(?:move|mv)\b[^\n]{0,60}?`?\.backlog\/(accepted|rejected|blocked|in-review|completed|in-progress|pending)\//gi
const moveOffenders = []
for (const f of ALL) {
  const text = readFileSync(f, 'utf8')
  let m
  MOVE_CLAIM.lastIndex = 0
  while ((m = MOVE_CLAIM.exec(text)) !== null) {
    const line = m[0].trim()
    // Allow explicit descriptions of who does it, and the recovery runbook (an operator doc).
    if (/orchestrator|single writer|whip-move|you (?:do not|don.t|never)|never move|do NOT move/i.test(line)) continue
    if (rel(f).includes('recovery-runbook')) continue
    moveOffenders.push(`${rel(f)}: "${line.slice(0, 90)}"`)
  }
}
check(`no shipped template instructs an agent to move task state${moveOffenders.length ? ` — found: ${moveOffenders.join(' | ')}` : ''}`,
  moveOffenders.length === 0)

// The move instruction also hides in AUTHORITY/capability lists, which the pattern above cannot see
// because they name no folder: "Move tasks between states" under **CAN:** grants exactly what the
// rewrite removed, 23 lines after the text forbidding it. Same for committing task state.
const GRANT = /^\s*[-*]\s*(move\s+(a\s+)?tasks?\b(?![^\n]*\borchestrator\b)|commit\s+task\s+(status|state)\b)/gim
const grants = []
for (const f of ALL) {
  const text = readFileSync(f, 'utf8')
  let m
  GRANT.lastIndex = 0
  while ((m = GRANT.exec(text)) !== null) {
    const line = m[0].trim()
    // A line that names who actually does it, or that appears under CANNOT/NEVER, is not a grant.
    const before = text.slice(Math.max(0, m.index - 400), m.index)
    if (/\*\*(CANNOT|NEVER|MUST NOT)/i.test(before.split('**CAN:**').pop() || before)) continue
    if (/orchestrator|single writer|never|do not|cannot/i.test(line)) continue
    grants.push(`${rel(f)}: "${line.slice(0, 70)}"`)
  }
}
check(`no shipped template GRANTS an agent the power to move or commit task state${grants.length ? ` — found: ${grants.join(' | ')}` : ''}`,
  grants.length === 0)

// ---------------------------------------------------------------------------
// 3. The result contract. The orchestrator reads it via StructuredOutput against ACFW_RESULT, and
// the dispatch prompts carry the authoritative field list — so a template must not ship a STALE
// COPY of that list. The failure mode is an anti-instruction: the agent's system prompt names four
// fields while its task prompt names six.
const schemaBlock = GO.match(/const ACFW_RESULT = \{[\s\S]*?\n\}/)
check('the ACFW_RESULT schema is readable from source', !!schemaBlock)
const SCHEMA_FIELDS = schemaBlock
  ? [...schemaBlock[0].matchAll(/^\s{4}(\w+): \{ type:/gm)].map((m) => m[1])
  : []
check(`the schema exposes its fields (${SCHEMA_FIELDS.length} found)`, SCHEMA_FIELDS.length >= 6)

// snake_case is the marker spelling used in prompts; camelCase is the schema spelling.
const snake = (s) => s.replace(/[A-Z]/g, (c) => '_' + c.toLowerCase())
const markerTemplates = AGENT_TEMPLATES.filter((f) => /ACFW-RESULT:/.test(readFileSync(f, 'utf8')))
const staleMarkers = []
for (const f of markerTemplates) {
  const text = readFileSync(f, 'utf8')
  for (const block of text.match(/ACFW-RESULT:[\s\S]{0,600}?```/g) || []) {
    // A block that enumerates fields must not omit one the schema requires of that agent kind.
    // transition/commit_sha/rejection_increment/notes are the always-required four.
    const has = (name) => new RegExp(`^\\s*${snake(name)}:`, 'm').test(block)
    const missing = ['transition', 'notes'].filter((n) => !has(n))
    if (missing.length) staleMarkers.push(`${rel(f)}: block missing ${missing.join(',')}`)
  }
}
check(`every ACFW-RESULT block in a template names at least the core fields${staleMarkers.length ? ` — ${staleMarkers.join(' | ')}` : ''}`,
  staleMarkers.length === 0)

// ---------------------------------------------------------------------------
// 4. Store-agnosticism. A template that hardcodes .backlog/ is wrong on every non-files backend,
// where no such directory exists. Templates may still MENTION it when explicitly fenced as
// files-backend-only, so the assertion is on unfenced use in agent-facing instructions.
// Look ONLY at the ```markdown block: that block is what whip-init renders into
// .claude/agents/<name>.md, i.e. the agent's system prompt. Scanning the whole FILE passes on a note
// written in the installer-facing prose above it, which no agent ever reads — and all eleven notes
// shipped in exactly that position, so this assertion was green while the change reached nobody.
// Take the block to its LAST bare fence: the specialist templates nest a ```bash quality-gates block,
// so stopping at the next fence would truncate and hide most of the prompt.
const emitted = (text) => {
  const i = text.indexOf('```markdown')
  if (i < 0) return ''
  const start = text.indexOf('\n', i) + 1
  const end = text.lastIndexOf('\n```')
  return end <= start ? text.slice(start) : text.slice(start, end)
}
const unfenced = []
for (const f of AGENT_TEMPLATES) {
  const block = emitted(readFileSync(f, 'utf8'))
  if (!/\.backlog\//.test(block)) continue
  const fenced = /files.{0,20}backend|default `?files`?|non-files|store backend|task-store/i.test(block)
  if (!fenced) unfenced.push(rel(f))
}
check(`every agent template mentioning .backlog/ IN THE EMITTED PROMPT says which backend that is${unfenced.length ? ` — unfenced: ${unfenced.join(', ')}` : ''}`,
  unfenced.length === 0)

const misplaced = AGENT_TEMPLATES.filter((f) => {
  const text = readFileSync(f, 'utf8')
  return /Task-store note/.test(text) && !/Task-store note/.test(emitted(text))
}).map(rel)
check(`the task-store note is inside the emitted prompt, not the installer prose${misplaced.length ? ` — outside: ${misplaced.join(', ')}` : ''}`,
  misplaced.length === 0)

// ---------------------------------------------------------------------------
// 5. Every agent type the orchestrator can select must have a template that generates it.
const selected = [...GO.matchAll(/agentType = '([a-z-]+)'|agentType: '([a-z-]+)'|registryHas\('([a-z-]+)'\)/g)]
  .map((m) => m[1] || m[2] || m[3])
const wanted = [...new Set(selected)]
const templateNames = AGENT_TEMPLATES.map((f) => rel(f))
const ungenerated = wanted.filter((a) => !templateNames.some((t) => t.includes(`${a}-pattern.md`)))
check(`every agent the orchestrator selects has a shipped template${ungenerated.length ? ` — missing: ${ungenerated.join(', ')}` : ''} (wanted: ${wanted.join(', ')})`,
  ungenerated.length === 0)

// ---------------------------------------------------------------------------
// 6. The task-id vocabulary exists in TWO implementations — CATEGORIES/ID_RE in
// workflows/whip-task.workflow.js (which decides what /task may CREATE) and ACFW_ID_CATEGORIES in
// skills/whip-doctor/bin/doctor.sh (which decides what a worktree slug is DERIVED from). They are
// the same regex written twice, they drifted apart once, and the consequence of drift is not a
// rejected id: doctor.sh's derivation silently truncated a five-digit sequence number, so two tasks
// differing only in the fifth digit derived the SAME worktree slug. Pin them to each other.
const TASK_JS = readFileSync(join(ROOT, 'workflows', 'whip-task.workflow.js'), 'utf8')
const DOCTOR_SH = readFileSync(join(ROOT, 'skills', 'whip-doctor', 'bin', 'doctor.sh'), 'utf8')

const jsCats = (TASK_JS.match(/const CATEGORIES = \[([^\]]*)\]/) || [])[1]
const jsList = jsCats ? jsCats.split(',').map((x) => x.trim().replace(/^'|'$/g, '')).filter(Boolean) : []
const shCats = (DOCTOR_SH.match(/ACFW_ID_CATEGORIES='([^']*)'/) || [])[1]
const shList = shCats ? shCats.split('|') : []

check(`both implementations declare the vocabulary (js=${jsList.length}, sh=${shList.length})`,
  jsList.length > 0 && shList.length > 0)
check(`the two vocabularies are identical${jsList.join('|') !== shList.join('|') ? ` — js=[${jsList.join('|')}] sh=[${shList.join('|')}]` : ''}`,
  jsList.join('|') === shList.join('|'))

// The sequence number must be unbounded in BOTH, or one of them truncates what the other accepts.
check('the id regex does not bound the sequence number (a bounded one truncates in derive_slug)',
  /\[0-9\]\+-/.test(TASK_JS.match(/const ID_RE = new RegExp\(`([^`]*)`\)/)?.[1] || ''))
check('derive_slug does not bound the sequence number either',
  !/ACFW_ID_CATEGORIES\)-\[0-9\]\{/.test(DOCTOR_SH) && /\$ACFW_ID_CATEGORIES\)-\[0-9\]\+-/.test(DOCTOR_SH))

// And the schema description must be generated from the list, not restated as prose.
check('the id schema description is interpolated from CATEGORIES, not hardcoded',
  /category one of \$\{CATEGORIES\.join/.test(TASK_JS))

// ---------------------------------------------------------------------------
// No shipped document may contain the literal clean-checkout token. It is what
// snapshot.hasCleanCheckoutToken and the reviewer's pre-review check both grep for, so a task
// document that copies it from a template claims a checkout that never happened — disabling the one
// diagnostic aimed at exactly that condition. task-template.md carried it as a worked example, and
// whip-task instructs authors to follow that template "EXACTLY".
const tokenLiteral = []
for (const f of walk(join(ROOT, 'content'))) {
  if (/\| clean-checkout \| ok \|/.test(readFileSync(f, 'utf8'))) tokenLiteral.push(rel(f))
}
check(`no shipped document contains the literal clean-checkout token${tokenLiteral.length ? ` — found in: ${tokenLiteral.join(', ')}` : ''}`,
  tokenLiteral.length === 0)

// ---------------------------------------------------------------------------
// whip-init's "always generate" list and its gap-analysis list must agree — and both must agree with
// the templates that exist. They drifted the moment workflow-architect was added: the installer
// created it while the gap analysis still enumerated six agents, so a project missing it would be
// reported complete by the very check that exists to find missing agents.
const INIT = readFileSync(join(ROOT, 'skills', 'whip-init', 'SKILL.md'), 'utf8')
const always = (INIT.match(/\*\*Always generate\*\*: ([^\n]+)/) || [])[1] || ''
const alwaysList = always.split(',').map((x) => x.trim()).filter(Boolean)
const expected = (INIT.match(/expected_agents=\(([^)]*)\)/) || [])[1] || ''
const expectedList = expected.replace(/\[\+[a-z]+\]/g, '').split(/\s+/).map((x) => x.trim()).filter(Boolean)

check(`whip-init declares an always-generate list (${alwaysList.length} agents)`, alwaysList.length >= 6)
const missingFromGap = alwaysList.filter((a) => !expectedList.includes(a))
check(`every always-generate agent is in the gap-analysis list${missingFromGap.length ? ` — missing: ${missingFromGap.join(', ')}` : ''}`,
  missingFromGap.length === 0)
const noTemplate = alwaysList.filter((a) => !AGENT_TEMPLATES.some((t) => rel(t).endsWith(`${a}-pattern.md`)))
check(`every always-generate agent has a shipped template${noTemplate.length ? ` — missing: ${noTemplate.join(', ')}` : ''}`,
  noTemplate.length === 0)

// ---------------------------------------------------------------------------
// Every consumer that asks the store "what ids / slugs are taken?" must union inactive[]. The split
// moved draft and archive out of tasks[], so a query reading tasks[] alone stopped seeing them — and
// /task would then mint an id or a worktree slug a draft already holds. The files branch of the same
// query greps .backlog recursively, which includes draft/ and archive/, so missing the union also
// makes the two backends disagree about what is taken.
const TASKJS = readFileSync(join(ROOT, 'workflows', 'whip-task.workflow.js'), 'utf8')
const bareTasksQueries = (TASKJS.match(/jq -r '\.tasks\[\]\? \| \.(id|slug)'/g) || [])
check(`whip-task's recon queries union inactive[]${bareTasksQueries.length ? ` — still bare: ${bareTasksQueries.join(', ')}` : ''}`,
  bareTasksQueries.length === 0)
check('...and they do query both arrays',
  (TASKJS.match(/\(\.tasks\[\]\?, \.inactive\[\]\?\)/g) || []).length >= 2)


// ---- no template may promise a sync-back the runtime does not perform ----------------------
// research-agent-pattern.md told non-code agents the materialized spec is "a materialized copy the
// orchestrator syncs back". `update-body` is invoked NOWHERE in workflows/ or skills/, the path is
// gitignored, and the next `read --materialize` truncates it — so a research agent that believed it
// lost its entire deliverable and was rejected each round. The claim is pinned to the runtime: if a
// real sync-back is ever wired up, this assertion stops firing on its own.
{
  const RUNTIME = [
    readFileSync(join(ROOT, 'workflows', 'whip-go.workflow.js'), 'utf8'),
    readFileSync(join(ROOT, 'workflows', 'whip-task.workflow.js'), 'utf8'),
  ].join('\n')
  const syncBackExists = /update-body/.test(RUNTIME)
  const claimants = AGENT_TEMPLATES.filter((p) => /syncs? back/i.test(readFileSync(p, 'utf8')))
  check(
    `no shipped template claims a sync-back while the runtime has none${claimants.length ? ` — ${claimants.map((p) => relative(ROOT, p)).join(', ')}` : ''}`,
    syncBackExists || claimants.length === 0,
  )
  // Any template that TELLS AN AGENT ABOUT A TASK FILE must say the path is backend-dependent —
  // otherwise an agent on a non-files store is never told the document it was handed is a read-only
  // copy. Templates that never mention one (lean-architect, precommit, retro, workflow-architect)
  // are correctly silent, so the predicate is "mentions a task path", not "is a universal".
  const mentionsTaskPath = (src) => /TASK_FILE|\.backlog\//.test(src)
  const missing = AGENT_TEMPLATES.filter((p) => {
    const src = readFileSync(p, 'utf8')
    return mentionsTaskPath(src) && !/Task-store note/.test(src)
  })
  check(
    `every template that names a task path carries the task-store note${missing.length ? ` — missing: ${missing.map((p) => relative(ROOT, p)).join(', ')}` : ''}`,
    missing.length === 0,
  )
}

// ---- the installers must not rewrite a document the project owns ---------------------------
// .backlog/README.md carries the team's gate commands, coverage thresholds and evidence rules.
// /whip-add-agents re-rendered the 265-line sample over it to change one line, reporting only
// "(agent list updated)", while the SessionStart hook builds a whole digest manifest to avoid
// exactly that for three sibling documents.
{
  for (const skill of ['whip-add-agents', 'whip-init']) {
    const src = readFileSync(join(ROOT, 'skills', skill, 'SKILL.md'), 'utf8')
    const guarded = /exists\("\.backlog\/README\.md"\)/.test(src)
      || /does not already exist/.test(src)
      || /[Nn]ever overwrite an existing `?\.backlog\/README\.md/.test(src)
    check(`${skill} does not blind-write .backlog/README.md`, guarded)
  }
}

// ---- 3.4.0 surfaces the skills must actually document ---------------------------------------
// Each of these is a promise the plugin makes in one place and keeps in another. A skill that stops
// naming one does not break a run; it makes the feature undiscoverable, which is how `/go` ended up
// with no argument-hint for a whole release while being scopeable.
{
  const go = readFileSync(join(ROOT, 'skills', 'go', 'SKILL.md'), 'utf8')
  check('/go advertises --all in its argument-hint', /argument-hint:.*--all/.test(go))
  check('/go advertises that no args means the focus', /argument-hint:.*focus/.test(go))
  check('/go documents the bare-go refusal on a shared store', /bareGo/.test(go) && /refuse/.test(go))
  check('/go documents the held-out tasks a run reports', /heldOut/.test(go))
  check('/go documents that a short relay is NOT a missing id', /relay-truncated/.test(go))
  check('/go documents that an explicit scope never writes the focus',
    /never (touch|write)/.test(go) && /focus/.test(go))
  check('/go says the legacy loop keeps the stricter gate', /legacy loop.{0,400}refuse|refuses on ANY FATAL/s.test(go))

  const move = readFileSync(join(ROOT, 'skills', 'whip-move', 'SKILL.md'), 'utf8')
  check('/whip-move lists draft and archive as states', /draft/.test(move) && /archive/.test(move))
  check('...and says which is pause and which is cancel', /PAUSE/.test(move) && /CANCEL/.test(move))
  check('...and warns that dropping from a focus is not pausing', /focus does not pause|dropping a task from a run focus does not pause/i.test(move))

  const focus = readFileSync(join(ROOT, 'skills', 'whip-focus', 'SKILL.md'), 'utf8')
  check('/whip-focus exists and has an argument-hint', /argument-hint:/.test(focus))
  check('...and points at whip-move for pausing', /whip-move/.test(focus))

  const task = readFileSync(join(ROOT, 'skills', 'task', 'SKILL.md'), 'utf8')
  check('/task says it sets the focus', /focus/.test(task))

  const doctor = readFileSync(join(ROOT, 'skills', 'whip-doctor', 'SKILL.md'), 'utf8')
  check('/whip-doctor no longer lists status-vs-folder mismatch as FATAL',
    !/FATAL.{0,200}status-vs-folder mismatch/s.test(doctor))
  check('...and documents the repo/task FATAL split', /Repo-scoped/.test(doctor) && /Task-scoped/.test(doctor))
  check('...and documents native-hold', /native hold|native-hold/.test(doctor))
}

// ---- the /task writers must carry the focus chain and the ignore rule ------------------------
// Both are shell-semantics guarantees, not agent judgement: a create that fails must not put its id
// in the focus, and a project that predates .acfwhip/run/ must not start tracking it.
{
  const src = readFileSync(join(ROOT, 'workflows', 'whip-task.workflow.js'), 'utf8')
  check('the focus binary is resolved from the plugin root, not hand-spelled in a prompt',
    /const FOCUS = `\$\{pluginRoot\}\/skills\/lib\/bin\/acfw-focus`/.test(src))
  check('both /task writers chain the focus update',
    (src.match(/\$\{sq\(FOCUS\)\} add --no-resolve --by task/g) || []).length === 2)
  // Chained with && onto each create, not run once at the end: a create that fails with a duplicate
  // id must not put that id in the focus, and shell semantics decide that more reliably than an
  // agent re-reading which of its own commands succeeded.
  check('the non-files writer chains it onto each create (so a failed create is excluded)',
    /create --file[\s\S]{0,200}&& rm -f[\s\S]{0,60}&& bash \$\{sq\(FOCUS\)\} add --no-resolve/.test(src))
  check('the writer prompt still ensures .acfwhip/run/ is gitignored', /grep -qxF '\.acfwhip\/run\/' \.gitignore/.test(src))
}

// ---- every new suite is REQUIRED, never optional ---------------------------------------------
// 3.3.0's lesson: a suite marked OPTIONAL skipped without a live server and a SKIP counted as a
// pass, so three adapters were green by absence for two releases.
{
  const runAll = readFileSync(join(ROOT, 'tests', 'run-all.sh'), 'utf8')
  const optional = (runAll.match(/^OPTIONAL="([\s\S]*?)"/m) || [, ''])[1]
  for (const suite of ['phase18-focus', 'phase19-files-only', 'phase19-doctor-graph', 'phase19-relay',
    'phase19-quarantine', 'phase19-routing']) {
    check(`${suite} is registered`, new RegExp(`^${suite}$`, 'm').test(runAll))
    check(`...and is not OPTIONAL`, !new RegExp(`\\b${suite}\\b`).test(optional))
  }
}

// ---- managed content digests must cover what shipped -----------------------------------------
// An installed copy is refreshed only when its sha256 matches a version this plugin has shipped.
// Editing a managed document without regenerating the manifest makes every installed copy read as
// hand-edited, so it is never refreshed again.
{
  const manifest = JSON.parse(readFileSync(join(ROOT, 'content', '.digests.json'), 'utf8'))
  const { createHash } = await import('node:crypto')
  for (const [rel, digests] of Object.entries(manifest.artifacts)) {
    const sha = createHash('sha256').update(readFileSync(join(ROOT, rel))).digest('hex')
    check(`${rel} — the shipped file's digest is in the manifest`, digests.includes(sha))
  }
}

console.log(`\nphase17-template-drift: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL === 0 ? 0 : 1)
