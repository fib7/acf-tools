// phase19-routing.test.mjs — model routing by agent TIER, and its visibility in the report (3.4.0).
//
// WHY THIS EXISTS. Until 3.4.0 routing was one knob (`shellModel`) plus silence. Everything that was
// not explicitly marked cheap inherited the session model, and nothing reported which model ran what.
// Two consequences, both invisible:
//
//   * In /task, exactly ONE call took the cheap tier. The agent-registry `ls`, BOTH single-writer
//     calls (whose prompts are a fixed list of `acfw-store create` lines) and the report-only doctor
//     all inherited the session model — frontier generation cost to echo command output.
//   * Specialists and reviewers ignored the `model:` frontmatter of the agents the PROJECT installed,
//     which is exactly where a project says "this kind of work runs on that model".
//
// The suggested workaround for the truncated-snapshot failure was to raise `shellModel`. That is the
// wrong lever — it would triple the cost of the most frequent agent class and still fail on a large
// board — so the shell tier stays cheap and the payload is bounded instead (phase19-relay).
//
// Structural assertions carry their weight here: a new shell stage that forgets `shellOpts` silently
// inherits the session model, and nothing at runtime would say so.
//
// Run: node acf-whip/tests/phase19-routing.test.mjs

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const GO = join(HERE, '..', 'workflows', 'whip-go.workflow.js')
const TASK = join(HERE, '..', 'workflows', 'whip-task.workflow.js')
const SKEL = join(HERE, '..', 'skills', 'lib', 'child-skeleton.js.tmpl')

let PASS = 0, FAIL = 0
const ok = (m) => { PASS++; console.log(`  PASS: ${m}`) }
const bad = (m) => { FAIL++; console.log(`  FAIL: ${m}`) }
const check = (m, cond) => (cond ? ok(m) : bad(m))

const goSrc = readFileSync(GO, 'utf8')
const taskSrc = readFileSync(TASK, 'utf8')
const skelSrc = readFileSync(SKEL, 'utf8')

// ============================ structural: one helper, no strays ============================
{
  // The whole point of a single helper is that a shell stage cannot forget the model. If a raw
  // `model: SHELL_MODEL` reappears at a call site, that guarantee is gone and nothing else notices.
  const strays = goSrc.split('\n').filter((l) => /model: SHELL_MODEL/.test(l) && !/function shellOpts|Object\.assign\(\{\}, o/.test(l))
  check('whip-go routes every shell-tier call through shellOpts (no raw model: SHELL_MODEL left)',
    strays.length === 0)
  check('whip-go declares the shellOpts helper', /function shellOpts\(o\) \{/.test(goSrc))
  check('...which is the single place the shell model is applied',
    (goSrc.match(/model: SHELL_MODEL/g) || []).length === 1)
  check('...and it counts what it spends', /agentsByTier\.shell\+\+/.test(goSrc))

  const taskStrays = taskSrc.split('\n').filter((l) => /model: SHELL_MODEL/.test(l) && !/Object\.assign\(\{\}, o/.test(l))
  check('whip-task has no raw model: SHELL_MODEL at a call site either', taskStrays.length === 0)
  check('whip-task declares the same helper', /function shellOpts\(o\) \{/.test(taskSrc))
}

// ============================ the /task shell sites that used to pay frontier rates =========
{
  for (const [label, why] of [
    ["discover-agents", 'the agent-registry ls'],
    ["recon:backlog", 'the backlog walk'],
    ["write:ingest", 'the single writer (non-files): a fixed list of acfw-store create lines'],
    ["write:commit", 'the single writer (files): a fixed list of git commands'],
    ["verify:doctor", 'the report-only doctor: one fixed command'],
  ]) {
    const re = new RegExp(`shellOpts\\(\\{ label: '${label}'`)
    check(`whip-task: ${label} takes the shell tier (${why})`, re.test(taskSrc))
  }
  // ...and the judgement calls must NOT have been swept into the cheap tier along with them.
  for (const label of ['judge:plan', 'critic:completeness']) {
    check(`whip-task: ${label} is NOT shell-tier (it is real judgement)`,
      !new RegExp(`shellOpts\\(\\{ label: '${label}'`).test(taskSrc))
    check(`whip-task: ${label} is routed as a judge-tier call`,
      new RegExp(`tierOpts\\(\\{ label: '${label}'[\\s\\S]{0,200}?'judge'\\)`).test(taskSrc))
  }
  check('whip-task: the competing planners are judge-tier', /tierOpts\(\{ label: extraDefects[\s\S]{0,260}?'judge'\)/.test(taskSrc))
  check('whip-task: the task-document authors are author-tier', /tierOpts\(\{ label: `author:\$\{t\.id\}`[\s\S]{0,200}?'author'\)/.test(taskSrc))
  check('whip-task: judge and author ship UNSET (inherit the session model)',
    /MODELS\.judge \|\| null/.test(taskSrc) && !/MODELS\.judge \|\| '/.test(taskSrc))
}

// ============================ agentType dispatches honour the project's frontmatter =========
{
  check('whip-go reads declared models from the agent registry at bootstrap',
    /agentModels: \{ type: 'array'/.test(goSrc) && /grep -l \'\^model:\'/.test(goSrc))
  check('...as an OPTIONAL schema field (an older bootstrap must still validate)',
    !/required: \[[^\]]*'agentModels'/.test(goSrc))
  check('...parsed into a name->model map', /agentModels\[name\] = m/.test(goSrc))
  check('specialist dispatches route through typedOpts', /const opts = typedOpts\(baseOpts, 'specialist'\)/.test(goSrc))
  check('reviewer dispatches route through typedOpts', (goSrc.match(/typedOpts\(\{ label: `review:/g) || []).length === 2)
  check('the conflict resolver is counted but never re-modelled', /typedOpts\(ropts, 'resolver'\)/.test(goSrc))
  check('the architect is counted too', /agentsByTier\.architect\+\+/.test(goSrc))
  // An agent with no declared model must keep inheriting the session model — absence is not a value.
  check('typedOpts only sets a model when the agent declares one',
    /const m = out\.agentType && agentModels\[out\.agentType\]\s*\n\s*if \(m\) out\.model = m/.test(goSrc))
}

// ============================ the child harness inherits the routing ========================
{
  check('the skeleton accepts the parent\'s agent-model map', /const AGENT_MODELS = \(A\.agentModels/.test(skelSrc))
  check('...and applies it to agentType stages', /AGENT_MODELS\[spec\.agentType\]/.test(skelSrc))
  check('...without overriding a stage that pinned its own model', /&& !o\.model && AGENT_MODELS/.test(skelSrc))
  check('the skeleton accepts a pinned shell effort', /const SHELL_EFFORT = A\.shellEffort/.test(skelSrc))
  check('...applied only to shell-model stages', /spec\.model === SHELL && SHELL_EFFORT/.test(skelSrc))
  check('the parent passes both down to the child', /shellEffort: EFFORTS\.shell \|\| '', agentModels,/.test(goSrc))
  // A harness authored against the previous skeleton must be re-scaffolded, not byte-diffed against a
  // template it predates — that is what the contract stamp is for.
  check('the skeleton contract stamp was bumped', /acfw-child-contract: v2/.test(skelSrc))
  const val = readFileSync(join(HERE, '..', 'skills', 'lib', 'bin', 'acfw-child-validate.mjs'), 'utf8')
  const valSh = readFileSync(join(HERE, '..', 'skills', 'lib', 'bin', 'acfw-child-validate'), 'utf8')
  check('...and both validators agree on it',
    /acfw-child-contract: v2/.test(val) && /acfw-child-contract: v2/.test(valSh))
}

// ============================ effort ships unset, deliberately ==============================
{
  check('the shell effort is opt-in, not a default',
    /const EFFORTS = \(args && args\.efforts/.test(goSrc) && !/efforts\.shell \|\| 'low'/.test(goSrc))
  check('...applied only when pinned', /if \(EFFORTS\.shell\) out\.effort = EFFORTS\.shell/.test(goSrc))
  check('...and the reason is written down where the next reader will look',
    /absent from the documented effort/.test(goSrc) && /undocumented/.test(goSrc))
}

// ============================ the report says what it spent =================================
{
  check('the RunReport carries the resolved models', /models: \{ shell: SHELL_MODEL, judge:/.test(goSrc))
  check('...including the per-agent map that was actually used', /agentModels,/.test(goSrc))
  check('...and the per-tier agent counts', /\n  agentsByTier,/.test(goSrc))
  check('the /task report carries the same block', /models: \{ shell: SHELL_MODEL, judge:/.test(taskSrc) && /\n  agentsByTier,/.test(taskSrc))
  check('the tier counters cover every routed class',
    /agentsByTier = \{ shell: 0, specialist: 0, review: 0, architect: 0, resolver: 0 \}/.test(goSrc))
}

// ============================ config resolution, end to end ================================
{
  const lib = readFileSync(join(HERE, '..', 'skills', 'lib', 'acfw-store.sh'), 'utf8')
  check('acfw_resolve_models resolves env > config > default', /acfw_resolve_models\(\) \{/.test(lib))
  check('...defaulting only the shell tier', /\[ -n "\$shell" \] \|\| shell=haiku/.test(lib))
  // The shell tier has a hardcoded default (haiku); judge and author deliberately do NOT — an unset
  // tier inherits the session model, and inventing a default for a reasoning tier would quietly
  // downgrade every decomposition on every project that never asked for it.
  check('...leaving judge and author with no hardcoded default',
    !/\|\| judge=[a-z]/.test(lib) && !/\|\| author=[a-z]/.test(lib))
  const store = readFileSync(join(HERE, '..', 'skills', 'lib', 'bin', 'acfw-store'), 'utf8')
  check('acfw-store info reports the resolved models', /"models":\{"shell":"%s","judge":"%s","author":"%s"\}/.test(store))
}

console.log(`\nphase19-routing: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL ? 1 : 0)
