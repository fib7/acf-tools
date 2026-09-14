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

console.log(`\nphase17-template-drift: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL === 0 ? 0 : 1)
