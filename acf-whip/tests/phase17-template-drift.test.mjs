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

import { readFileSync, readdirSync, statSync, existsSync, mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join, relative } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'

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
    'phase19-quarantine', 'phase19-routing', 'phase20-cycle', 'phase20-task-plan', 'phase21-spec-tools',
    'phase21-gaptrap-driver', 'phase21-spec-task', 'phase22-cycle-e2e']) {
    check(`${suite} is registered`, new RegExp(`^${suite}$`, 'm').test(runAll))
    check(`...and is not OPTIONAL`, !new RegExp(`\\b${suite}\\b`).test(optional))
  }
}

// ---- no pattern grants an agent edit authority over the process (3.5.0) ------------------------
// retro-pattern.md told the generated retro agent it had "EXCLUSIVE authority to modify agent
// instructions" and could "commit process changes to git"; precommit-pattern and the universal
// manifest restated the grant. That was a standing licence for one agent to rewrite any other
// agent's instructions or loosen a quality standard with no human in the loop, and it contradicts
// the ratchet /retro now enforces by script: tighten autonomously, loosen only with a human.
// Process changes are action items in a retro-actions cycle that a human approves. A generated
// agent file is frozen in every consumer project, so a grant that ships once lives on there;
// the CHANGELOG carries the paste-in edit, and this pins that no pattern ships one again.
// Two shapes: phrases that are a grant wherever they appear, and a **CAN:** list item that gives
// the agent edit power over agent files, standards or process.
{
  const PHRASES = [
    /\bexclusive(?:ly)?\b[^\n]{0,60}\b(?:authority|instructions?|updates?|modif(?:y|ies|ications?))\b/i,
    /\b(?:authority|modify|update|edit)\b[^\n]{0,60}\(\s*exclusive\s*\)/i,
    /\bcommits?\s+process\s+changes\b/i,
    /\bagent[- ]instruction\s+updates?\b/i,
    // "Manifest Maintained By: retro agent" tells every reader the retro agent edits other agents'
    // manifests: the same grant, as a footer.
    /\bmaintained\s+by\b[^\n]{0,12}\bretro\b/i,
    // The manifest's "Common Workflows" granted it as a pipeline: "Agent Update: Analyze rejection
    // patterns → Root cause → Update instructions → Test". A step that edits is a grant whatever
    // list it sits in.
    // Bare "agent" is not a target: whip-init's "→ Update agent matrix or re-run /whip-init" tells
    // the user what to do, and names nothing an agent edits.
    /→\s*(?:update|modify|edit|change|rewrite)\s+(?:the\s+)?(?:instructions?|agent\s+(?:files?|instructions?|manifests?)|quality\s+(?:gates?|standards?)|workflows?\b|docs?\b|documentation|process(?:es)?\b)/i,
    // ...and as a data-flow line: "**To**: Process documentation, agent instructions".
    /\*\*To\*\*:[^\n]*\b(?:agent\s+instructions?|agent\s+files?|process\s+documentation|quality\s+(?:gates?|standards?))\b/i,
    /\b(?:update|modify|edit|rewrite)\W{0,4}agent\s+manifests?\b/i,
    // "Cannot modify quality standards (retro authority)": a prohibition on one agent that states
    // another holds the power.
    /\(\s*retro\s+authority\s*\)/i,
  ]
  const CAN_GRANT = /\b(?:modify|update|edit|change|rewrite|commit|write)\b[^\n]{0,50}(?:agent instructions?|agent files?|agent manifests?|\.claude\/agents|docs\/agents|quality[- ](?:standards?|gates?)|workflow (?:documentation|docs?)|workflow\.md|process(?:es)?\b)/i
  // A CAN item that only proposes, reads or reports is not a grant, whatever it names.
  const NOT_A_GRANT = /^\s*[-*]\s*(?:propose|read|review|analy[sz]e|list|report)\b/i
  const authorityGrants = (text) => {
    const out = []
    const lines = text.split('\n')
    for (const line of lines) if (PHRASES.some((re) => re.test(line))) out.push(line.trim())
    let inCan = false
    for (const line of lines) {
      if (/^\*\*CAN:\*\*/.test(line)) { inCan = true; continue }
      if (/^\*\*(?:CANNOT|NEVER|MUST NOT)/.test(line) || /^#/.test(line) || /^```/.test(line)) { inCan = false; continue }
      if (inCan && /^\s*[-*]\s/.test(line) && CAN_GRANT.test(line) && !NOT_A_GRANT.test(line) && !out.includes(line.trim())) out.push(line.trim())
    }
    return out
  }
  // Non-vacuity: every grant 3.4.x shipped must still trip the detector, or a reworded matcher
  // could pass by matching nothing.
  const SHIPPED_GRANTS = [
    'description: Use this agent for root cause analysis. Has EXCLUSIVE authority to modify agent instructions, workflows, and quality standards based on data-driven analysis.',
    '**MANDATORY**: You conduct retrospectives and improve processes. EXCLUSIVE authority to modify agent instructions.',
    '**CAN:**\n\n- **Modify agent instructions** (EXCLUSIVE)',
    '**CAN:**\n\n- **Update quality standards** (EXCLUSIVE)',
    '**CAN:**\n\n- Update workflow documentation',
    '**CAN:**\n\n- Commit process changes to git',
    '- Modify process → retro (exclusive authority)',
    '**Scope**: Retrospectives, metrics analysis, agent instruction updates, workflow improvements',
    '**IS**: Metrics analysis, root cause analysis, process improvements, **EXCLUSIVE agent instruction updates**',
    '**Manifest Maintained By**: retro agent',
    '2. Agent Update: Analyze rejection patterns → Root cause → Update instructions → Test',
    '3. Workflow Improvement: Identify bottleneck → Propose change → Update docs → Communicate',
    '4. Quality Standard Adjustment: Review data → Evaluate threshold → Update quality gates → Notify',
    '**From**: All agents (via metrics), **To**: Process documentation, agent instructions',
    '5. **Update agent manifests** if needed (if using manifest system)',
    '- **Authority**: Conduct retrospectives, analyze metrics, **update agent instructions** (EXCLUSIVE)',
    '- **Prohibition**: Cannot modify quality standards (retro authority)',
    // A CAN item that names the file instead of the category is the same grant.
    '**CAN:**\n\n- Edit docs/acf/backlog/workflow.md to add a state',
    '**CAN:**\n\n- Update docs/development/quality-gates-{stack}.md',
    '**CAN:**\n\n- **Modify agent manifests** in docs/agents/',
  ]
  const missed = SHIPPED_GRANTS.filter((g) => authorityGrants(g).length === 0)
  check(`the authority detector catches every grant 3.4.x shipped${missed.length ? ` — missed: ${missed.join(' | ')}` : ''}`,
    missed.length === 0)
  // ...and does not fire on the prohibitions and proposals the rewrite put in their place.
  const ALLOWED = [
    '**CAN:**\n\n- Propose changes to agent files, workflow and quality gates as action items',
    '**CAN:**\n\n- Write the retro doc, lessons and action-item plan that a `/retro` prompt names',
    '**CANNOT:**\n\n- Modify agent instructions',
    '- **critical**: 4h SLA, exclusive priority level',
    '**Manifest Maintained By**: the project (changes go through /retro action items a human approves)',
    '1. Retrospective: Read inputs → Five Whys → Classify each fix (sensor / guide / lesson / nothing) → Write the retro doc',
    '**From**: `/retro` (triggered cycles), `acfw-cycle` (triggers, lessons, follow-through), **To**: the retro doc, lessons, a retro-actions cycle awaiting approval',
    '**Task Type: Approved Action Item** → P1: the task document, P2: the file it names',
    '- `docs/agents/` - Agent manifests',
    '- **Prohibition**: Cannot modify quality standards (a /retro action item, approved by a human)',
    '🔄 Outdated CLAUDE.md Content: {LIST} → Update agent matrix or re-run /whip-init',
  ]
  const falsePos = ALLOWED.filter((g) => authorityGrants(g).length !== 0)
  check(`the authority detector passes prohibitions and proposals${falsePos.length ? ` — fired on: ${falsePos.join(' | ')}` : ''}`,
    falsePos.length === 0)

  // The installers embed agent and manifest templates inline (whip-add-agents writes every specialist
  // manifest from its own SKILL.md), so a grant there reaches generated files as surely as one under
  // content/agent-patterns. The plugin README is where a user learns what each agent may do, and a
  // grant stated there is what they hold the agent to. Scanned whole: none carries prose that trips
  // the detector otherwise.
  const INSTALLERS = ['whip-add-agents', 'whip-init'].map((s) => join(ROOT, 'skills', s, 'SKILL.md'))
  const PLUGIN_README = join(ROOT, 'README.md')
  const grantsFound = []
  for (const f of [...ALL, ...INSTALLERS, PLUGIN_README]) {
    const lines = readFileSync(f, 'utf8').split('\n')
    for (const g of authorityGrants(lines.join('\n'))) grantsFound.push(`${rel(f)}:${lines.findIndex((l) => l.trim() === g) + 1}: "${g.slice(0, 90)}"`)
  }
  check(`no shipped pattern grants an agent edit authority over agent files, standards or process${grantsFound.length ? ` — found: ${grantsFound.join(' | ')}` : ''}`,
    grantsFound.length === 0)

  // The consumer-facing command list said /retro "creates improvement tasks" by writing straight
  // into the store. It creates none: action items become tasks only after a human approves them.
  // Nor does it "update task-engineer instructions": that is an action item a human approves.
  const STALE_RETRO = /\bcreates? improvement tasks\b|\/retro`?\s+to\s+(?:update|modify|edit)\b/i
  const staleRetro = []
  for (const f of [...ALL, PLUGIN_README]) {
    readFileSync(f, 'utf8').split('\n').forEach((l, i) => { if (STALE_RETRO.test(l)) staleRetro.push(`${rel(f)}:${i + 1}`) })
  }
  check(`no shipped doc says /retro creates tasks or edits instructions${staleRetro.length ? ` — found at: ${staleRetro.join(', ')}` : ''}`,
    staleRetro.length === 0)
}

// ---- /retro: the durable bar is stated once, in the dispatch prompt (3.5.0) --------------------
// Compound Engineering culled 89 docs to 55 with one counterfactual bar. A bar restated in several
// places drifts into several bars, and a copy in retro-pattern.md would be frozen into every
// consumer's generated agent file, where no refresh ever corrects it. So it lives once, in the
// prompt /retro sends, which ships with the plugin.
const RETRO = readFileSync(join(ROOT, 'skills', 'retro', 'SKILL.md'), 'utf8')
{
  const BAR = 'Write a lesson only if a future planner, reading the final code, tests and task documents, would still repeat the mistake.'
  const times = RETRO.split(BAR).length - 1
  check(`skills/retro/SKILL.md states the durable bar exactly once (found ${times})`, times === 1)
  const prompt = (RETRO.match(/```text\n([\s\S]*?)\n```/) || [])[1] || ''
  check('...and it is inside the retro dispatch prompt', prompt.includes(BAR))
  for (const s of [
    'If a test, type or `ACFW_GATE_CMD` already catches it, write nothing.',
    'If one could catch it, propose that sensor as a `### D<n>` action item instead.',
    'A fired trigger, effort or diff size does not establish eligibility.',
    'Zero lessons is a valid, common outcome; say why in the retro doc.',
  ]) check(`...with the rest of the bar: "${s.slice(0, 48)}..."`, prompt.includes(s))
  // A copy is any clause of the bar, not only its first sentence: the 3.5.0 retro manifest shipped
  // "Write a lesson a test already enforces" and "Lessons a test could enforce instead: 0", which
  // restate sentences two and three in a file whip-init writes once and never refreshes.
  const BAR_CLAUSE = /would still repeat the mistake|\btests?\s+(?:already|could)\s+(?:enforces?|catch(?:es)?)\b/i
  const clauseProbe = ['5. Write a lesson a test already enforces → Noise every planner reads',
    'Root cause identified: >90%, Lessons a test could enforce instead: 0', 'a planner would still repeat the mistake']
  check('the bar-copy detector catches every restatement 3.5.0 drafts shipped', clauseProbe.every((s) => BAR_CLAUSE.test(s)))
  check('...and passes the pointer that replaced them',
    !BAR_CLAUSE.test("5. Write a lesson the `/retro` prompt's bar rejects → Noise every planner reads"))
  const copies = AGENT_TEMPLATES.filter((f) => BAR_CLAUSE.test(readFileSync(f, 'utf8'))).map(rel)
  check(`no agent pattern carries a copy of the bar (a generated agent file never refreshes)${copies.length ? ` — found in: ${copies.join(', ')}` : ''}`,
    copies.length === 0)
  // Plan §7 RETRO: the spec tools' verdicts on the approved bytes are a retro input. A tool that flagged
  // the cause at approval gets a TIGHTEN proposal, never a loosening one. Three halves, each pinned:
  // the gather step extracts the committed rows, the prompt names the file, and the rule is stated.
  const gather = (RETRO.match(/# >>> retro-gather[\s\S]*?# <<< retro-gather/) || [''])[0]
  check('/retro gather extracts the committed reviewed/overridden Plan Log rows from HEAD into spec-rows.txt',
    /git show "HEAD:docs\/cycles\/\$CYC\/record\.md"/.test(gather) && /## Plan Log/.test(gather)
    && /\(reviewed\|overridden\)/.test(gather) && /spec-rows\.txt/.test(gather))
  check('...the retro prompt lists spec-rows.txt among its inputs', /<IN>\/spec-rows\.txt/.test(prompt))
  check('...and tells the agent to propose tightening a declaration that flagged the cause, never loosening one',
    /Propose tightening that declaration as a `\[sensor\] \[loosens: no\]` item/.test(prompt)
    && /Never propose loosening a declaration\./.test(prompt))
}

// ---- /retro reads what /go produces, through the store, on every backend ----------------------
// The 3.4.x skill gated on `ls .backlog/rejected/` (which /go empties), grepped a field name no
// task carries, ran `[ -d .backlog ]` (absent on every non-files store), and wrote improvement
// tasks straight into .backlog/pending/ around the /task validation gate. Each of these pins one of
// those defects so it cannot come back in a rewrite.
{
  // The skill may NAME .backlog/ to forbid it; what it may not do is address a state folder or
  // test for the directory, which is the files store's layout leaking into every backend.
  const direct = RETRO.match(/\.backlog\/(?:pending|rejected|blocked|accepted|in-review|completed|in-progress|draft|archive)\b|-d\s+\.?\/?\.backlog\b|\bls\b[^\n]*\.backlog/g) || []
  check(`/retro makes no direct .backlog/ read or write${direct.length ? ` — found: ${direct.join(', ')}` : ''}`, direct.length === 0)
  check('/retro reads tasks with read --materialize (it carries the rejection notes)', /read --materialize/.test(RETRO))
  check('...never with the body-only read (bare description on beads and linear)', !/read\s+--body/.test(RETRO))
  check('/retro greps git history with an anchored ACFW-Task line', /--grep="\^ACFW-Task: \$s\\\$"/.test(RETRO))
  for (const verb of ['status', 'triggers', 'retro-begin', 'lessons']) {
    check(`/retro drives acfw-cycle ${verb}`, new RegExp(`acfw-cycle"?\\s+${verb}\\b`).test(RETRO))
  }
  check('/retro closes a clean cycle with `acfw-cycle close <plan> none` (zero agents)', /acfw-cycle" close '<plan>' none/.test(RETRO))
  check('/retro commits a triggered close and a mid-cycle retro through acfw-cycle',
    /acfw-cycle" close '<plan>' retro\.md/.test(RETRO) && /acfw-cycle" note '<plan>' retro\.md/.test(RETRO))
  check('/retro creates the retro-actions cycle with acfw-cycle init --kind retro-actions', /init <slug>-retro-actions --kind retro-actions/.test(RETRO))
  // The approval card renders headings only, so the loosens flag the approver must see lives there.
  check('/retro asks for the loosens flag in the D heading, never on a body line the card cannot show',
    /### D1: \[sensor\] \[loosens: no\] <outcome>/.test(RETRO) && !/\*\*Loosens a control\*\*/.test(RETRO))
  // Thresholds live only in acfw-cycle (the CAP_CLAIM rule, applied to the skill that reads them).
  // Word forms count: "blocked more than once" encodes bc>=2 exactly as "bc>=2" does, and it is the
  // form a prose rewrite reaches for, so the operator-only matcher missed the one 3.5.0 shipped.
  const OP_THRESHOLD = /(?:\brc|\bbc|Rejection Count|Block-Count)\s*(?:>=|≥|>|==?)\s*\d/gi
  const WORD_THRESHOLD = /(?:reject|block)\w*[^\n]{0,20}\b(?:more than once|twice|(?:two|2|three|3) or more|at least (?:two|2|\d))\b/gi
  const wordProbe = ['a task that is blocked, or was blocked more than once', 'rejected twice', 'blocked 2 or more times',
    'a task rejected at least two times']
  check('the word-form threshold detector catches the phrasings a rewrite reaches for',
    wordProbe.every((s) => { WORD_THRESHOLD.lastIndex = 0; return WORD_THRESHOLD.test(s) }))
  WORD_THRESHOLD.lastIndex = 0
  check('...and passes the script-owned wording', !WORD_THRESHOLD.test('a task that is blocked, or was blocked too often on the way'))
  const thresholds = [...(RETRO.match(OP_THRESHOLD) || []), ...(RETRO.match(WORD_THRESHOLD) || [])]
  check(`/retro restates no trigger threshold${thresholds.length ? ` — found: ${thresholds.join(', ')}` : ''}`, thresholds.length === 0)
  const wordOffenders = []
  for (const f of ALL) for (const m of readFileSync(f, 'utf8').match(WORD_THRESHOLD) || []) wordOffenders.push(`${rel(f)}: "${m}"`)
  check(`no shipped template restates a reject or block threshold in words${wordOffenders.length ? ` — found: ${wordOffenders.join(' | ')}` : ''}`,
    wordOffenders.length === 0)
  // Stop rule 4: status signals a fresh run lock as text and exits 0, so the skill must look for the
  // text before choosing ANY path, and must not carve the plan-less path out of the refusal.
  check('/retro detects a running /go from the status text, before routing', /case "\$out" in \*'wait: \/go is running'\*\)/.test(RETRO))
  check('/retro does not exempt the plan-less path from the /go refusal', !/does not wait for a running/i.test(RETRO))
  check('/retro routes --force with task tokens to the plan-less retro whatever NEXT says',
    /`--force` with task tokens and no cycle token: go to \*\*Plan-less retro\*\*[\s\S]{0,80}whatever NEXT says/.test(RETRO))
  check('/retro never runs git rm itself (retiring a lesson loosens a control)', !/^\s*git rm\b/m.test(RETRO))
  // A [guide] item may not target a MANAGED doc: the SessionStart hook refreshes those from the plugin,
  // and an edit flips one to stale-edited for good. The list is read from the hook itself, so a fifth
  // managed doc added there fails here until the prompt and the verify block both name it.
  const HOOK = readFileSync(join(ROOT, 'hooks', 'handlers', 'session-start.py'), 'utf8')
  const managedBlock = (HOOK.match(/^MANAGED = \[([\s\S]*?)^\]/m) || [])[1] || ''
  const MANAGED_DOCS = [...managedBlock.matchAll(/\(\s*"content\/[^"]+",\s*"(docs\/acf\/[^"]+)"\s*\)/g)].map((m) => m[1])
  check(`the MANAGED list is readable from session-start.py (${MANAGED_DOCS.length}: ${MANAGED_DOCS.join(', ')})`,
    MANAGED_DOCS.length >= 4 && MANAGED_DOCS.includes('docs/acf/backlog/workflow.md'))
  const verifyList = ((RETRO.match(/# >>> retro-verify[\s\S]*?split\("([^"]*)"/) || [])[1] || '').split(' ').filter(Boolean)
  const promptText = (RETRO.match(/```text\n([\s\S]*?)\n```/) || [])[1] || ''
  const notInPrompt = MANAGED_DOCS.filter((p) => !promptText.includes(p))
  const notInVerify = MANAGED_DOCS.filter((p) => !verifyList.includes(p))
  check(`the retro prompt names every MANAGED doc a [guide] item may not target${notInPrompt.length ? ` — missing: ${notInPrompt.join(', ')}` : ''}`,
    notInPrompt.length === 0)
  check(`the retro-verify block refuses a [guide] item on every MANAGED doc${notInVerify.length ? ` — missing: ${notInVerify.join(', ')}` : ''} (verify lists ${verifyList.length})`,
    notInVerify.length === 0)
}

// ---- a skill another skill invokes must stay model-invocable (3.5.0, CE #778) ------------------
// `disable-model-invocation: true` makes the Skill tool REFUSE the skill. /whip invokes /task on a
// plain "yes" and /retro invokes /whip to render an approval card; a callee that sets the flag
// turns that one-reply handoff into a silent dead end. The callee set is DERIVED from the shipped
// skill text, never listed here, so a new invocation is covered the day it ships. The floor keeps
// the extractor honest: if it stops finding the two invocations every release depends on, the
// derived set is vacuous and this check proves nothing.
{
  const SKILLS_DIR = join(ROOT, 'skills')
  const local = new Set(readdirSync(SKILLS_DIR).filter((d) => existsSync(join(SKILLS_DIR, d, 'SKILL.md'))))
  const INVOKE = [
    // "invoke the `acf-whip:task` skill", "Invoke the `clean-checkout-before-task` skill"
    /\b[Ii]nvoke\s+(?:the\s+)?`?(?:([a-z][a-z0-9-]*):)?([a-z][a-z0-9-]*)`?\s+skill\b/g,
    // "Specialists invoke `clean-checkout-before-task` as Step 0; that skill uses ..."
    /\b[Ii]nvoke\s+(?:the\s+)?`(?:([a-z][a-z0-9-]*):)?([a-z][a-z0-9-]*)`(?=[^\n]{0,80}\b[Ss]kill\b)/g,
    // "`acf-whip:whip` skill via the Skill tool"
    /`(?:([a-z][a-z0-9-]*):)?([a-z][a-z0-9-]*)`[^\n]{0,40}\bvia the Skill tool\b/g,
    // Skill({ skill: "acf-whip:task" }) / Skill("acf-whip:task")
    /\bSkill\(\s*\{?\s*(?:skill:\s*)?["'](?:([a-z][a-z0-9-]*):)?([a-z][a-z0-9-]*)["']/g,
  ]
  const extract = (text) => {
    const out = []
    for (const re of INVOKE) {
      re.lastIndex = 0
      let m
      while ((m = re.exec(text)) !== null) out.push({ plugin: m[1] || '', name: m[2] })
    }
    return out
  }
  const probe = new Set(extract('On yes, invoke the `acf-whip:task` skill via the Skill tool. Invoke the `clean-checkout-before-task` skill first. Specialists invoke `clean-checkout-before-task` as Step 0; that skill uses the registry. Skill({ skill: "acf-whip:go" }). Then invoke the Skill tool.').map((c) => c.name))
  check(`the invocation extractor recognizes the phrasings shipped skills use (got: ${[...probe].join(', ')})`,
    probe.has('task') && probe.has('clean-checkout-before-task') && probe.has('go') && !probe.has('Skill') && !probe.has('the'))

  const callers = new Map()
  const dangling = []
  for (const d of local) {
    const f = join(SKILLS_DIR, d, 'SKILL.md')
    for (const { plugin, name } of extract(readFileSync(f, 'utf8'))) {
      if (plugin && plugin !== 'acf-whip') continue // another plugin's skill: not ours to pin
      if (!local.has(name)) {
        // Unprefixed prose ("invoke this skill") is not a reference; a qualified one that names no
        // shipped skill is a dangling invocation.
        const ref = `${rel(f)} -> acf-whip:${name}`
        if (plugin && !dangling.includes(ref)) dangling.push(ref)
        continue
      }
      if (!callers.has(name)) callers.set(name, new Set())
      callers.get(name).add(d)
    }
  }
  check(`every acf-whip skill a shipped skill invokes exists${dangling.length ? ` — dangling: ${dangling.join(', ')}` : ''}`,
    dangling.length === 0)
  const frontmatter = (name) => (readFileSync(join(SKILLS_DIR, name, 'SKILL.md'), 'utf8').match(/^---\n([\s\S]*?)\n---/) || [, ''])[1]
  const disabled = [...callers.keys()].filter((n) => /^disable-model-invocation:\s*["']?(?:true|yes|on)["']?\s*$/im.test(frontmatter(n)))
  check(`no invoked skill sets disable-model-invocation (the Skill tool would refuse it)${disabled.length ? ` — ${disabled.map((n) => `${n} (invoked by ${[...callers.get(n)].join(', ')})`).join('; ')}` : ''} [derived callees: ${[...callers.keys()].sort().join(', ')}]`,
    disabled.length === 0)
  for (const floor of ['task', 'clean-checkout-before-task']) {
    check(`non-vacuity floor: the derived callee set contains ${floor}`, callers.has(floor))
  }
}

// ---- the shell /retro ships actually works (bash 3.2, BSD and GNU awk) -------------------------
// /retro's status, gather and verify steps are code the model runs verbatim in a consumer repo. Run
// the marked blocks from SKILL.md itself, under /bin/bash, so what ships is what is tested: a regex
// or quoting slip here would otherwise surface as a retro that silently reads no tasks, or waves
// through a lesson with frontmatter. The blocks source the REAL acfw-plan.sh through a stub plugin,
// because agreeing with that library (fences, the Deliverables rule, slugs, follow-through) with
// the scripts that read plans is the whole point of sourcing it.
{
  const block = (name) => (RETRO.match(new RegExp(`# >>> ${name}[^\\n]*\\n([\\s\\S]*?)\\n# <<< ${name}`)) || [])[1] || ''
  const VERIFY = block('retro-verify')
  const GATHER = block('retro-gather')
  const STATUS = block('retro-status')
  check('SKILL.md carries the marked retro-status, retro-verify and retro-gather blocks',
    VERIFY.length > 0 && GATHER.length > 0 && STATUS.length > 0)
  const BASH = existsSync('/bin/bash') ? '/bin/bash' : 'bash'
  const sh = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`
  const SCRATCH = mkdtempSync(join(tmpdir(), 'phase17-retro-'))
  const put = (root, p, body) => { mkdirSync(dirname(join(root, p)), { recursive: true }); writeFileSync(join(root, p), body) }
  // The blocks' environment must not inherit a store or config pin from whoever runs the suite.
  const ENV = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('ACFW_')))
  // Stub plugin: stub executables in bin/, the real library one level up, where "$B/.." finds it.
  const REAL_LIB = readFileSync(join(ROOT, 'skills', 'lib', 'acfw-plan.sh'), 'utf8')
  const plugin = (name, libExtra = '') => {
    const bin = join(SCRATCH, name, 'skills', 'lib', 'bin')
    mkdirSync(bin, { recursive: true })
    writeFileSync(join(SCRATCH, name, 'skills', 'lib', 'acfw-plan.sh'), REAL_LIB + libExtra)
    return bin
  }
  const BIN = plugin('plugin')
  // A library whose D-id reader disagrees with the verify block's own walk: the cross-check must say so.
  const SKEW_BIN = plugin('plugin-skew', "\nacfw_plan_dids() { printf 'D1\\tx\\nD2\\ty\\nD9\\tz\\n'; }\n")
  const stub = (name, body) => { writeFileSync(join(BIN, name), `#!/bin/bash\n${body}\n`); chmodSync(join(BIN, name), 0o755) }
  // The store stub drains stdin on purpose: the gather loop reads its tokens on stdin, so a call
  // inside it that is not given </dev/null would eat every remaining token. A plain `read` resolves a
  // typed name the way adapters do; MUL-123 is a backend key, answered as pretty-printed JSON.
  stub('acfw-store', [
    'cat >/dev/null',
    '[ "$1" = read ] || exit 2',
    'if [ "$2" = --materialize ]; then',
    '  case "$4" in gone) echo "no such task" >&2; exit 5 ;; esac',
    '  printf "# %s\\n" "$4" > "$3/$4.md"; echo "$3/$4.md"; exit 0',
    'fi',
    'case "$2" in',
    '  gone) echo "no such task" >&2; exit 5 ;;',
    '  MUL-123) printf \'{\\n  "stem": "api-005-quux",\\n  "folder": "pending"\\n}\\n\' ;;',
    '  *) printf \'{"stem":"%s","folder":"pending","fields":{"id":"%s"}}\\n\' "$2" "$2" ;;',
    'esac',
  ].join('\n'))
  stub('acfw-cycle', [
    'case "$1" in',
    '  lessons) echo "pin-lockfile: Pin the lockfile before running install in CI."; echo "WARN: stale.md has no Rule line" >&2 ;;',
    '  status) if [ -n "${STATUS_OUT:-}" ]; then printf "%s\\n" "$STATUS_OUT"; exit "${STATUS_RC:-0}"; fi',
    '          echo "STATUS stub for $2"; echo "NEXT /whip" ;;',
    '  *) exit 2 ;;',
    'esac',
  ].join('\n'))
  stub('acfw-focus', '[ "$1" = path ] && echo "$FOCUS_FILE"')
  try {
    // ---------- status: the /go-running refusal ----------
    // Against the REAL acfw-cycle: its status exits 0 while /go runs, so the only signal is the text.
    const ST = join(SCRATCH, 'status-repo')
    mkdirSync(ST)
    const gitS = (...a) => spawnSync('git', ['-c', 'commit.gpgsign=false', ...a], { cwd: ST, encoding: 'utf8' })
    gitS('init', '-q'); gitS('config', 'user.email', 't@t'); gitS('config', 'user.name', 't')
    put(ST, '.backlog/pending/.gitkeep', '')
    put(ST, '.claude/agents/api-engineer.md', '# api-engineer\n')
    gitS('commit', '-q', '--allow-empty', '-m', 'init')
    const runStatus = (bin, args = [], env = {}) => {
      const r = spawnSync(BASH, ['-c', `B=${sh(bin)}; set -- ${args.map(sh).join(' ')}\n${STATUS}`],
        { cwd: ST, encoding: 'utf8', env: { ...ENV, ...env } })
      return { out: r.stdout || '', status: r.status }
    }
    const REAL_BIN = join(ROOT, 'skills', 'lib', 'bin')
    writeFileSync(join(ST, '.backlog', '.acfw-run.json'), '{}\n')
    let s = runStatus(REAL_BIN)
    check(`status: a fresh /go run lock exits 0 and the block says GO_RUNNING=yes (status=${s.status})`,
      s.status === 0 && /^NEXT wait: \/go is running$/m.test(s.out) && /^GO_RUNNING=yes$/m.test(s.out))
    rmSync(join(ST, '.backlog', '.acfw-run.json'))
    s = runStatus(REAL_BIN)
    check('status: no run lock, no GO_RUNNING line', s.status === 0 && /^NEXT /m.test(s.out) && !/GO_RUNNING/.test(s.out))
    // NEXT is set once, so an earlier row can take it; the fact line alone must still stop the retro.
    s = runStatus(BIN, [], { STATUS_OUT: 'STATUS no active cycle\n  wait: /go is running (its run lock was touched in the last 30 minutes)\n\nNEXT /whip 20260101-a' })
    check('status: the wait fact without a wait NEXT still says GO_RUNNING=yes', /^GO_RUNNING=yes$/m.test(s.out))
    s = runStatus(BIN, ['20260101-a'], { STATUS_OUT: 'stage unknown: run /whip-doctor', STATUS_RC: '4' })
    check('status: a refusal keeps its exit code and its text', s.status === 4 && /stage unknown/.test(s.out) && !/GO_RUNNING/.test(s.out))

    // ---------- the approval card shows what an action item loosens ----------
    // A human's one-word "yes" approves what the card shows, and the card renders deliverable HEADINGS
    // (acfw_plan_dids). The 3.5.0 draft put the loosens flag on a body line, so a loosening reached
    // the approver unseen. Made by the real init, passed by the real verify block, rendered by the
    // real status: if any of the three stops agreeing on where the flag lives, this fails.
    const ini = spawnSync(BASH, [join(REAL_BIN, 'acfw-cycle'), 'init', 'demo-retro-actions', '--kind', 'retro-actions',
      '--source', 'retro 20260928-demo', '--title', 'Retro actions: demo'], { cwd: ST, encoding: 'utf8', env: ENV })
    const AID = ((ini.stdout || '').match(/^INIT\|([^|]+)\|/m) || [])[1] || ''
    check(`card: init --kind retro-actions makes the actions draft (got: ${JSON.stringify((ini.stdout || ini.stderr || '').split('\n')[0])})`,
      ini.status === 0 && /^[0-9]{8}-demo-retro-actions$/.test(AID))
    if (AID) {
      writeFileSync(join(ST, 'docs', 'cycles', AID, 'plan.md'), [
        '# Retro actions: demo', '', '## Problem', '', 'x', '', '## Deliverables', '',
        '### D1: [sensor] [loosens: no] A test fails when the lockfile is unpinned', '', '- AC1.1: the test fails on an unpinned lockfile', '',
        '### D2: [guide] [loosens: yes, drops the manual smoke-test review step] Reviewers skip the smoke step for docs-only tasks', '',
        '- AC2.1: .claude/agents/quality-reviewer.md says so', '',
        '## Retire', '', '<!-- Not work for /task: a human runs these git rm commands after approving. -->', '',
        '- old-rule: enforced by tests/lock.test.sh: "assert pinned"', '',
      ].join('\n'))
      put(ST, 'docs/cycles/20260928-demo/retro.md', '# Retro: demo\n## Lessons\nNone.\n## Retire\nNone.\n')
      const vr = spawnSync(BASH, ['-c', `B=${sh(REAL_BIN)}; MODE=close; DOC=docs/cycles/20260928-demo/retro.md; AID=${sh(AID)}; set --\n${VERIFY}`],
        { cwd: ST, encoding: 'utf8', env: ENV })
      check(`card: the real verify block passes the plan the card is rendered from (got: ${JSON.stringify((vr.stdout || '').trim())})`,
        (vr.stdout || '').trim() === 'VERIFY|ok')
      const cr = spawnSync(BASH, [join(REAL_BIN, 'acfw-cycle'), 'status', AID], { cwd: ST, encoding: 'utf8', env: ENV })
      const card = cr.stdout || ''
      check(`card: status on the actions draft renders an approval card (status=${cr.status})`, cr.status === 0 && /^  WHAT approve /m.test(card) && /^  REPLY yes: approve/m.test(card))
      check('card: the card shows which control an item loosens, and that the other loosens nothing',
        /^  D2: \[guide\] \[loosens: yes, drops the manual smoke-test review step\] Reviewers skip/m.test(card)
        && /^  D1: \[sensor\] \[loosens: no\] /m.test(card))
    }

    // ---------- verify ----------
    const V = join(SCRATCH, 'verify')
    mkdirSync(V)
    const DOC = 'docs/cycles/20260928-demo/retro.md'
    put(V, DOC, '# Retro: demo\n## Triggers\n## Lessons\nNone.\n## Retire\nNone.\n')
    put(V, 'docs/cycles/20260928-noretire/retro.md', '# Retro\n## Lessons\nNone.\n')
    put(V, 'docs/retrospectives/20260928-auth-flake.md', '# Retro\n## Lessons\n## Retire\nNone.\n')
    put(V, 'docs/retrospectives/auth-flake.md', '# Retro\n## Lessons\n## Retire\nNone.\n')
    const LESSON = '**Rule**: Pin the lockfile before running install in CI.\n\n## What happened\nx\n## Root cause\ny\n## Fix\nz\n'
    for (const sl of ['pin-lockfile', 'a-two', 'a-three', 'a-four', 'v2-cache']) put(V, `docs/acf/lessons/${sl}.md`, LESSON)
    put(V, 'docs/acf/lessons/fronted.md', `---\ntags: [x]\n---\n${LESSON}`)
    put(V, 'docs/acf/lessons/two-rules.md', `${LESSON}**Rule**: And another.\n`)
    put(V, 'docs/acf/lessons/20260928-dated.md', LESSON)
    put(V, 'docs/acf/lessons/cache-key-v2.md', LESSON)
    put(V, 'notes/elsewhere.md', LESSON)
    const GOOD_PLAN = [
      '# Retro actions: demo', '## Problem', 'x', '## Deliverables',
      '<!-- D-ids are permanent -->',
      '### D1: [sensor] [loosens: no] A test fails when the lockfile is unpinned', 'AC1.1: the test fails on an unpinned lockfile',
      '```', '### D9: not a deliverable, it is inside a fence', '```',
      '### D2: [guide] [loosens: yes, drops the manual review step] The task-engineer file names the edge-case checklist',
      'Edit .claude/agents/task-engineer.md only.', 'AC2.1: the checklist is present',
      '## Retire', '- old-rule: enforced by tests/lock.test.sh: "assert pinned"', '### D7: after Deliverables, ignored', '',
    ].join('\n')
    put(V, 'docs/cycles/20260928-demo-retro-actions/plan.md', GOOD_PLAN)
    put(V, 'docs/cycles/20260928-bad-retro-actions/plan.md', [
      '## Deliverables',
      '### D1: [loosens: no] no tag here',
      '### D2: [sensor] no loosens tag',
      '### D3: [guide] [loosens: no] Add a rule to docs/acf/backlog/workflow.md',
      '### D4: [sensor] [loosens: no] names workflow.md but is a sensor', 'Touches docs/acf/backlog/workflow.md indirectly.', '',
    ].join('\n'))
    put(V, 'docs/cycles/20260928-nodel-retro-actions/plan.md', '# x\n## Scope\nnothing\n')
    put(V, 'docs/cycles/20260928-empty-retro-actions/plan.md', '## Deliverables\nprose only\n')
    // A fence closed by a line with an info string is NOT closed (CommonMark), so the bare fence
    // after it closes it and D3 is a real deliverable. A toggle-on-any-fence reader hid D3, and with
    // it an untagged item that relaxes a review step in a MANAGED doc.
    put(V, 'docs/cycles/20260928-fence-retro-actions/plan.md', [
      '## Deliverables', '### D1: [sensor] [loosens: no] A test pins the lockfile',
      '```', 'code', '```sh', '```',
      '### D3: Edit docs/acf/backlog/workflow.md to relax the review step', '',
    ].join('\n'))
    put(V, 'docs/cycles/20260928-hashes-retro-actions/plan.md', '## Deliverables ##\n### D1: [sensor] [loosens: no] x\n')
    put(V, 'docs/cycles/20260928-dup-retro-actions/plan.md',
      '## Deliverables\n### D1: [sensor] [loosens: no] one\n### D1: [sensor] [loosens: no] two\n')
    put(V, 'docs/cycles/20260928-bareyes-retro-actions/plan.md', '## Deliverables\n### D1: [sensor] [loosens: yes,] x\n### D2: [sensor] [loosens: maybe] y\n')
    // The 3.5.0 draft's shape: the flag as a body line. acfw_plan_dids reads only headings, so the card
    // never showed it and a "yes" approved a loosening the approver could not see.
    put(V, 'docs/cycles/20260928-bodyflag-retro-actions/plan.md', '## Deliverables\n### D1: [guide] Reviewers skip the smoke step\n**Loosens a control**: yes, drops the smoke-test review\n')
    put(V, 'docs/cycles/20260928-fencedguide-retro-actions/plan.md', [
      '## Deliverables', '### D1: [guide] [loosens: no] Planners see the checklist',
      '```diff', '--- a/docs/acf/style/task-descriptions.md', '```', '',
    ].join('\n'))
    const runVerify = (mode, doc, aid, lessons, bin = BIN) => {
      const r = spawnSync(BASH, ['-c', `B=${sh(bin)}; MODE=${sh(mode)}; DOC=${sh(doc)}; AID=${sh(aid)}; set -- ${lessons.map(sh).join(' ')}\n${VERIFY}`],
        { cwd: V, encoding: 'utf8', env: ENV })
      return (r.stdout || '') + (r.stderr ? `STDERR:${r.stderr}` : '')
    }
    let out = runVerify('close', DOC, '20260928-demo-retro-actions', ['docs/acf/lessons/pin-lockfile.md'])
    check(`verify: a well-formed close retro passes with exactly VERIFY|ok (got: ${JSON.stringify(out.trim())})`, out.trim() === 'VERIFY|ok')
    out = runVerify('close', DOC, '', [])
    check('verify: zero lessons and no actions cycle is a valid outcome', out.trim() === 'VERIFY|ok')
    out = runVerify('planless', 'docs/retrospectives/20260928-auth-flake.md', '', [])
    check('verify: a plan-less doc at docs/retrospectives/YYYYMMDD-<slug>.md passes', out.trim() === 'VERIFY|ok')
    out = runVerify('planless', 'docs/retrospectives/auth-flake.md', '', [])
    check('verify: a plan-less doc without the date prefix is refused', /VERIFY\|a plan-less retro doc is/.test(out))
    out = runVerify('planless', DOC, '', [])
    check('verify: a plan-less retro may not write into a cycle folder', /VERIFY\|retro doc in the wrong place for mode planless/.test(out))
    out = runVerify('close', 'docs/cycles/20260928-noretire/retro.md', '', [])
    check('verify: a retro doc without ## Retire is refused', out.trim() === "VERIFY|retro doc has no '## Retire' section (write None. when nothing retires)")
    out = runVerify('close', DOC, '', ['docs/acf/lessons/fronted.md'])
    check('verify: a lesson with frontmatter is refused', /VERIFY\|lesson has frontmatter/.test(out) && !/VERIFY\|ok/.test(out))
    out = runVerify('close', DOC, '', ['docs/acf/lessons/two-rules.md'])
    check('verify: a lesson with two Rule lines is refused', /exactly one '\*\*Rule\*\*: ' line, found 2/.test(out))
    out = runVerify('close', DOC, '', ['docs/acf/lessons/20260928-dated.md'])
    check('verify: a dated lesson slug is refused (same slug = same lesson)', /VERIFY\|lesson slug must be timeless: .*: 20260928-dated$/m.test(out))
    out = runVerify('close', DOC, '', ['docs/acf/lessons/cache-key-v2.md'])
    check('verify: a -v<n> lesson slug is refused', /VERIFY\|lesson slug must be timeless: .*: cache-key-v2$/m.test(out))
    // The rule is acfw_lesson_slug_ok, the one `close` applies: a leading v<n> is a version too, and
    // a verify that passed it would hand close a lesson it refuses with exit 3.
    out = runVerify('close', DOC, '', ['docs/acf/lessons/v2-cache.md'])
    check('verify: the slug rule is close\'s own (a leading v<n> is refused as a version)', /VERIFY\|lesson slug must be timeless: .*: v2-cache$/m.test(out))
    out = runVerify('close', DOC, '', ['notes/elsewhere.md'])
    check('verify: a lesson outside docs/acf/lessons/ is refused', /VERIFY\|lesson outside docs\/acf\/lessons\//.test(out))
    out = runVerify('close', DOC, '', ['docs/acf/lessons/missing.md'])
    check('verify: a lesson the agent named but did not write is refused', /VERIFY\|lesson file missing/.test(out))
    out = runVerify('close', DOC, '', ['pin-lockfile', 'a-two', 'a-three', 'a-four'].map((sl) => `docs/acf/lessons/${sl}.md`))
    check('verify: a fourth lesson is refused', /VERIFY\|4 lessons: at most 3/.test(out))
    out = runVerify('close', DOC, '20260928-bad-retro-actions', [])
    let lines = out.trim().split('\n')
    check('verify: an untagged action item is refused', lines.some((l) => /^VERIFY\|### D1: \[loosens: no\] no tag here: tag it/.test(l)))
    check('verify: an item without a loosens tag is refused', lines.some((l) => /^VERIFY\|### D2: .*: put \[loosens: no\] or \[loosens: yes, <which control>\] in the heading/.test(l)))
    check('verify: a [guide] item targeting a MANAGED doc is refused', lines.some((l) => /^VERIFY\|### D3: .*may not target docs\/acf\/backlog\/workflow\.md/.test(l)))
    check('verify: a [sensor] item may name a MANAGED doc (only guide edits are banned)', !lines.some((l) => /^VERIFY\|### D4/.test(l)))
    check(`verify: exactly those three failures, no VERIFY|ok (got ${lines.length})`, lines.length === 3 && !/VERIFY\|ok/.test(out))
    out = runVerify('close', DOC, '20260928-nodel-retro-actions', [])
    check('verify: an actions plan with no ## Deliverables is refused', /VERIFY\|actions plan has no ## Deliverables heading/.test(out))
    out = runVerify('close', DOC, '20260928-empty-retro-actions', [])
    check('verify: an actions plan with no D items is refused', /VERIFY\|## Deliverables has no ### D<n> item/.test(out))
    out = runVerify('close', DOC, '20260928-missing-retro-actions', [])
    check('verify: an ACTIONS id whose plan does not exist is refused', /VERIFY\|actions plan missing/.test(out))
    out = runVerify('mid', DOC, '20260928-demo-retro-actions', [])
    check('verify: a mid-cycle retro that made an actions cycle is refused (note takes none)', /VERIFY\|a mid-cycle retro creates no actions cycle/.test(out))
    out = runVerify('close', DOC, '20260928-fence-retro-actions', [])
    lines = out.trim().split('\n')
    check(`verify: a D item after a fence closed CommonMark's way is seen, as coverage sees it (got: ${JSON.stringify(out.trim())})`,
      lines.some((l) => /^VERIFY\|### D3: Edit docs\/acf\/backlog\/workflow\.md.*: tag it/.test(l))
      && lines.some((l) => /^VERIFY\|### D3: .*\[loosens: no\] or/.test(l))
      && !/deliverables as/.test(out) && !/VERIFY\|ok/.test(out))
    out = runVerify('close', DOC, '20260928-hashes-retro-actions', [])
    check(`verify: "## Deliverables ##" is the Deliverables heading, as coverage reads it (got: ${JSON.stringify(out.trim())})`, out.trim() === 'VERIFY|ok')
    out = runVerify('close', DOC, '20260928-dup-retro-actions', [])
    check('verify: a reused D number is refused', /VERIFY\|### D1: \[sensor\] \[loosens: no\] two: D1 is used twice/.test(out) && !/VERIFY\|ok/.test(out))
    out = runVerify('close', DOC, '20260928-bareyes-retro-actions', [])
    check('verify: "[loosens: yes,]" without naming the control, or any other value, is refused',
      /^VERIFY\|### D1: \[sensor\] \[loosens: yes,\] x: put \[loosens/m.test(out) && /^VERIFY\|### D2: \[sensor\] \[loosens: maybe\] y: put \[loosens/m.test(out))
    out = runVerify('close', DOC, '20260928-bodyflag-retro-actions', [])
    check('verify: a loosens flag in the body, where the approval card cannot show it, is refused',
      /^VERIFY\|### D1: \[guide\] Reviewers skip the smoke step: put \[loosens/m.test(out) && !/VERIFY\|ok/.test(out))
    out = runVerify('close', DOC, '20260928-fencedguide-retro-actions', [])
    check('verify: a [guide] item that shows its MANAGED-doc edit in a code block is refused',
      /VERIFY\|### D1: .*may not target docs\/acf\/style\/task-descriptions\.md/.test(out))
    out = runVerify('close', DOC, '20260928-demo-retro-actions', [], SKEW_BIN)
    check(`verify: when its own walk and acfw_plan_dids disagree it says so (got: ${JSON.stringify(out.trim())})`,
      /VERIFY\|this check read the deliverables as 'D1,D2' but coverage reads 'D1,D2,D9'/.test(out) && !/VERIFY\|ok/.test(out))
    check('verify: the block never writes to stderr on these fixtures', !/STDERR:/.test(out))

    // ---------- gather ----------
    const G = join(SCRATCH, 'repo')
    mkdirSync(G)
    const git = (...a) => spawnSync('git', ['-c', 'commit.gpgsign=false', ...a], { cwd: G, encoding: 'utf8' })
    git('init', '-q')
    git('config', 'user.email', 't@t')
    git('config', 'user.name', 't')
    for (const [f, stem] of [['src/foo.txt', 'api-001-foo'], ['src/foobar.txt', 'api-001-foo-bar'], ['src/quux.txt', 'api-005-quux']]) {
      put(G, f, `${stem}\n`)
      git('add', f)
      git('commit', '-q', '-m', `integrate: ${stem}`, '-m', `ACFW-Task: ${stem}`)
    }
    // Records in acfw-cycle's own shape: acfw_plan_scan counts a folder only with Format and a
    // matching ID, which is also what keeps a stray note out of the follow-through.
    const record = (id, { status = 'approved', kind = 'feature', tasks = [] } = {}) => [
      `# Cycle Record: ${id}`, '', '## Metadata', '', '- **Format**: 1', `- **ID**: ${id}`, `- **Status**: ${status}`, `- **Kind**: ${kind}`, '',
      '## Tasks', '', '| Deliverable | Tasks |', '| ----------- | ----- |', ...tasks.map(([d, st]) => `| ${d} | ${st} |`), '',
      '## Plan Log', '', '| Date Time | Event | By | Content | Details |', '| --------- | ----- | -- | ------- | ------- |', '',
    ].join('\n')
    const FEAT = '20260301-feat'
    put(G, `docs/cycles/${FEAT}/record.md`, record(FEAT, { tasks: [['D1', 'api-001-foo, api-002-bar'], ['D2', 'api-006-zed']] }))
    git('add', `docs/cycles/${FEAT}/record.md`)
    git('commit', '-q', '-m', 'docs(plan): decompose feat')
    // The working copy gains a stem HEAD does not have: a forced retro must read the committed record.
    put(G, `docs/cycles/${FEAT}/record.md`, record(FEAT, { tasks: [['D1', 'api-001-foo, api-002-bar, api-099-wt'], ['D2', 'api-006-zed']] }))
    put(G, 'docs/cycles/20260101-a-retro-actions/record.md', record('20260101-a-retro-actions', { status: 'closed', kind: 'retro-actions' }))
    put(G, 'docs/cycles/20260115-x-retro-actions/record.md', record('20260115-x-retro-actions', { kind: 'retro-actions' }))
    put(G, 'docs/cycles/20260115-x-retro-actions-2/record.md', record('20260115-x-retro-actions-2', { status: 'closed', kind: 'retro-actions' }))
    // Newest by ID, but a human rejected it on the card: never "the previous retro's action items".
    put(G, 'docs/cycles/20260201-b-retro-actions/record.md', record('20260201-b-retro-actions', { status: 'abandoned', kind: 'retro-actions' }))
    put(G, 'docs/cycles/20260210-note/record.md', '- **Kind**: retro-actions\n')
    const FOCUS = join(SCRATCH, 'focus')
    writeFileSync(FOCUS, '# store=files\n# setBy=task\n\napi-003-baz\n')
    const runGather = (mode, inDir, tokens, { cyc = '', force = '0', env = {} } = {}) => {
      const r = spawnSync(BASH, ['-c', `B=${sh(BIN)}; MODE=${sh(mode)}; CYC=${sh(cyc)}; FORCE=${sh(force)}; IN=${sh(inDir)}; set -- ${tokens.map(sh).join(' ')}\n${GATHER}`],
        { cwd: G, encoding: 'utf8', env: { ...ENV, TMPDIR: SCRATCH, FOCUS_FILE: FOCUS, ...env } })
      const inPath = ((r.stdout || '').match(/^IN=(.*)$/m) || [])[1] || ''
      const read = (p) => (existsSync(join(inPath, p)) ? readFileSync(join(inPath, p), 'utf8') : '')
      return { out: r.stdout || '', err: r.stderr || '', status: r.status, inPath, read }
    }
    const inDir = (name, triggers) => { const d = join(SCRATCH, name); mkdirSync(d); writeFileSync(join(d, 'triggers.txt'), triggers); return d }
    const IN1 = inDir('in1', 'TRIGGER|rework|api-001-foo|rc=<n>\nTRIGGER|stuck|api-002-bar|blocked\nTRIGGER|stuck|api-001-foo|bc=<n>\nTRIGGER|gap|D2\nTRIGGER|stuck|gone|blocked\n')
    let g = runGather('close', IN1, [], { cyc: FEAT })
    check(`gather: exits 0 and reports its input dir (status=${g.status}${g.err ? `, stderr=${g.err.trim()}` : ''})`, g.status === 0 && g.inPath === IN1)
    const docs = g.read('task-docs.txt')
    check('gather: every task a rework or stuck trigger names is materialized, once each',
      /^api-001-foo\t\S+api-001-foo\.md$/m.test(docs) && /^api-002-bar\t\S+api-002-bar\.md$/m.test(docs) && (docs.match(/^api-001-foo\t/gm) || []).length === 1)
    check('gather: a gap names a deliverable, not a task, so nothing is read for it', !/^D2\t/m.test(docs))
    check('gather: the store stub drained stdin and every token still ran (the loop guards stdin)', /^api-002-bar\t/m.test(docs) && /^gone\t/m.test(docs))
    check('gather: a task the store cannot read is listed UNREADABLE with the store exit code, not skipped',
      /^gone\tUNREADABLE \(acfw-store exit 5\)$/m.test(docs) && /gone\tUNREADABLE/.test(g.out))
    check('gather: TASKS counts every triggered task', /^TASKS=3$/m.test(g.out))
    check('gather: the store\'s own message is printed, so exit 3 is not read as "no such task" when it is an ambiguous prefix',
      /^STORE: no such task$/m.test(g.out))
    check('gather: without --force no manual trigger is added', !/manual/.test(g.read('triggers.txt')))
    const log1 = g.read('git/api-001-foo.log')
    check('gather: the git history is anchored (api-001-foo does not pull in api-001-foo-bar)',
      /Subject: integrate: api-001-foo$/m.test(log1) && !/api-001-foo-bar/.test(log1))
    check('gather: the git history carries the diffstat', /src\/foo\.txt/.test(log1))
    check('gather: recorded lessons and their warnings are captured separately',
      /^pin-lockfile: /m.test(g.read('lessons.txt')) && /^WARN: /m.test(g.read('lessons-warn.txt')))
    let ft = g.read('follow-through.txt')
    check(`gather: follow-through is acfw_plan_follow's: newest retro-actions cycle by ID, abandoned skipped (got: ${JSON.stringify(ft.split('\n')[0])})`,
      /^FOLLOW\|20260115-x-retro-actions-2\|status=closed\|/m.test(ft) && /STATUS stub for 20260115-x-retro-actions-2/.test(ft))
    check('gather: DATE is the UTC date as YYYYMMDD', /^DATE=[0-9]{8}$/m.test(g.out))
    g = runGather('close', inDir('in1b', 'TRIGGERS|none\n'), [], { cyc: '20260115-x-retro-actions-2' })
    check('gather: the follow-through never names the cycle being retro\'d', /^FOLLOW\|20260115-x-retro-actions\|/m.test(g.read('follow-through.txt')))
    // A rerun of this retro that left its own untracked actions draft behind (Source "retro <ID>"):
    // close skips it, so gather must too, or the agent grades this retro against itself. Another
    // cycle's retro still sees it: it IS the previous retro's items there.
    const OWN = '20260302-feat-retro-actions'
    put(G, `docs/cycles/${OWN}/record.md`, record(OWN, { kind: 'retro-actions' }).replace('- **Kind**: retro-actions', `- **Kind**: retro-actions\n- **Source**: retro ${FEAT}`))
    g = runGather('close', inDir('in1c', 'TRIGGERS|none\n'), [], { cyc: FEAT })
    check(`gather: this retro's own untracked actions draft is left out, as close leaves it out (got: ${JSON.stringify(g.read('follow-through.txt').split('\n')[0])})`,
      /^FOLLOW\|20260115-x-retro-actions-2\|/m.test(g.read('follow-through.txt')))
    g = runGather('close', inDir('in1d', 'TRIGGERS|none\n'), [], { cyc: '20260115-x-retro-actions-2' })
    check('gather: another cycle\'s retro still grades that draft', new RegExp(`^FOLLOW\\|${OWN}\\|`, 'm').test(g.read('follow-through.txt')))
    rmSync(join(G, 'docs', 'cycles', OWN), { recursive: true, force: true })

    // --force on a cycle: the manual trigger is recorded, and with nothing named the whole cycle is read.
    const IN2 = inDir('in2', 'TRIGGERS|none\n')
    g = runGather('close', IN2, [], { cyc: FEAT, force: '1' })
    const docs2 = g.read('task-docs.txt')
    check(`gather (--force, nothing fired): every stem the record at HEAD maps is read (got TASKS=${(g.out.match(/^TASKS=(\d+)$/m) || [])[1]})`,
      ['api-001-foo', 'api-002-bar', 'api-006-zed'].every((st) => new RegExp(`^${st}\\t`, 'm').test(docs2)) && /^TASKS=3$/m.test(g.out))
    check('gather (--force): the record is read from HEAD, never the working copy', !/api-099-wt/.test(docs2))
    check('gather (--force): the manual trigger is recorded next to what the script said',
      g.read('triggers.txt') === 'TRIGGERS|none\nTRIGGER|manual|--force\n')
    const IN3 = inDir('in3', 'TRIGGERS|none\n')
    g = runGather('close', IN3, [], { cyc: FEAT })
    check('gather (no --force, nothing fired): reads nothing and leaves the triggers alone',
      /^TASKS=0$/m.test(g.out) && g.read('triggers.txt') === 'TRIGGERS|none\n')
    const IN4 = inDir('in4', 'TRIGGER|rework|api-001-foo|rc=<n>\n')
    runGather('mid', IN4, [], { cyc: FEAT, force: '1' })
    g = runGather('mid', IN4, [], { cyc: FEAT, force: '1' })
    check('gather (--force with a trigger fired): only the triggered tasks, and one manual line however often it runs',
      /^TASKS=1$/m.test(g.out) && /^api-001-foo\t/m.test(g.read('task-docs.txt'))
      && (g.read('triggers.txt').match(/^TRIGGER\|manual\|/gm) || []).length === 1)

    g = runGather('planless', '', [])
    check('gather (plan-less): with no tasks named it reads the /go focus, skipping its header lines',
      g.status === 0 && g.inPath.startsWith(SCRATCH) && /^api-003-baz\t/m.test(g.read('task-docs.txt')) && /^TASKS=1$/m.test(g.out))
    check('gather (plan-less): the trigger is recorded as manual', /^TRIGGER\|manual\|/m.test(g.read('triggers.txt')))
    g = runGather('planless', '', ['api-004-qux'])
    check('gather (plan-less): named tasks replace the focus',
      /^api-004-qux\t/m.test(g.read('task-docs.txt')) && !/api-003-baz/.test(g.read('task-docs.txt')))
    // A typed backend key must become the stem before the anchored grep, or it finds no history.
    g = runGather('planless', '', ['MUL-123', 'gone', 'api-005-quux'])
    const docs5 = g.read('task-docs.txt')
    check(`gather (plan-less): a typed key is resolved to its stem, once, before reading (got: ${JSON.stringify(docs5)})`,
      /^api-005-quux\t\S+api-005-quux\.md$/m.test(docs5) && (docs5.match(/^api-005-quux\t/gm) || []).length === 1 && !/^MUL-123\t/m.test(docs5))
    check('gather (plan-less): the resolved stem finds its landed commits', /Subject: integrate: api-005-quux$/m.test(g.read('git/api-005-quux.log')))
    check('gather (plan-less): a name the store cannot resolve is UNREADABLE with the store exit code',
      /^gone\tUNREADABLE \(acfw-store exit 5\)$/m.test(docs5) && /^TASKS=2$/m.test(g.out))
    g = runGather('planless', '', [], { env: { FOCUS_FILE: join(SCRATCH, 'no-such-focus') } })
    check('gather (plan-less): no tasks and no focus reads nothing and says TASKS=0', g.status === 0 && /^TASKS=0$/m.test(g.out))
    rmSync(join(G, 'docs'), { recursive: true, force: true })
    g = runGather('close', IN1, [], { cyc: FEAT })
    ft = g.read('follow-through.txt')
    check('gather: no retro-actions cycle yet says so instead of failing', g.status === 0 && /^FOLLOW\|none$/m.test(ft) && !/STATUS stub/.test(ft))
  } finally {
    rmSync(SCRATCH, { recursive: true, force: true })
  }
}

// ---- /whip stop rules: plan section 7 makes the override rule 'a stop rule plus a phase17 assertion' --
// The /whip skill is the only thing between a model and an approval commit. Its stop rules are what
// survives compaction, so each safety rule must stay IN that section, not somewhere further down.
{
  const whip = readFileSync(join(ROOT, 'skills', 'whip', 'SKILL.md'), 'utf8')
  const start = whip.search(/^## Stop rules\b/m)
  const after = start < 0 ? -1 : whip.slice(start + 1).search(/^## /m)
  const rules = start < 0 ? '' : (after < 0 ? whip.slice(start) : whip.slice(start, start + 1 + after))
  check('/whip: a "## Stop rules" section exists and is the first ## section', start >= 0 && whip.slice(0, start).search(/^## /m) < 0)
  check('/whip stop rules: --override only when the yes message itself says "override <tool>"',
    /--override <tool>/.test(rules) && /the yes message itself/i.test(rules) && /`override <tool>`/.test(rules))
  check("/whip stop rules: never call a spec tool's MCP tools directly", /never call a spec tool's MCP tools/i.test(rules))
  check('/whip stop rules: a pasted credential is written nowhere, and rotated', /written nowhere/i.test(rules) && /rotate/i.test(rules))
  check('/whip stop rules: script output is printed verbatim', /verbatim/i.test(rules))
  check('/whip stop rules: free text goes in single quotes, never double quotes', /single quotes/i.test(rules) && /never put it in double quotes/i.test(rules))
  // Autopilot (3.6.0): the Stop hook hands the session its next step, so the head of the skill must
  // say that a hook message is an instruction to run ONE named step and never an answer to a card,
  // and that only the judge subagent records a verdict.
  check('/whip stop rules: /go and /retro run only when the acf-whip autopilot hook names them', /acf-whip autopilot/.test(rules) && /do\s+exactly what that message names/i.test(rules))
  check('/whip stop rules: a hook message, notification or judge reply is never a yes', /Only a message the user typed answers a card/.test(rules) && /never a yes/i.test(rules))
  check('/whip stop rules: --approve only from the user\'s own message', /`--approve`[^.]*only when the user's\s+own message contains `--approve`/.test(rules))
  check('/whip stop rules: never run acfw-autopilot verdict, never judge the condition', /Never run `acfw-autopilot verdict`/.test(rules) && /only the judge subagent/i.test(rules))
  // Claude Code substitutes only the braced ${CLAUDE_PLUGIN_ROOT} when it loads a skill: a bare
  // $CLAUDE_PLUGIN_ROOT reaches the shell unexpanded and every command in that block fails.
  const skillsDir = join(ROOT, 'skills')
  const unbraced = []
  for (const d of readdirSync(skillsDir)) {
    const f = join(skillsDir, d, 'SKILL.md')
    try { if (!statSync(f).isFile()) continue } catch { continue }
    readFileSync(f, 'utf8').split('\n').forEach((l, i) => { if (/\$CLAUDE_PLUGIN_ROOT\b/.test(l)) unbraced.push(`skills/${d}/SKILL.md:${i + 1}`) })
  }
  check(`no SKILL.md writes an unbraced $CLAUDE_PLUGIN_ROOT (${unbraced.join(', ') || 'none'})`, unbraced.length === 0)
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
