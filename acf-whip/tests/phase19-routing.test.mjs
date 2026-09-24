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
  // Counting moved OUT of the option helpers in 3.4.0's cleanup: safeAgent charges up to three real
  // agents per invocation on a retry, and every agent a child harness spent was in agentsUsed and in
  // no tier at all — so the tiers summed to a fraction of the total while the skill told the operator
  // this field said what each tier spent. Tag at the helper, charge where the agent is actually paid.
  check('...and it TAGS the tier rather than counting at the call site', /tierOf\.set\(out, 'shell'\)/.test(goSrc))
  check('...with a single charge point that moves both ledgers together',
    /function charge\(opts, n\) \{[\s\S]{0,200}?agentsUsed \+= k[\s\S]{0,200}?agentsByTier\[t\]/.test(goSrc))
  check('...used by safeAgent, so a RETRY is charged too', /charge\(opts\)/.test(goSrc))
  check('...and by agentC', /async function agentC\(p, o\) \{ charge\(o\)/.test(goSrc))
  check('...no raw agentsUsed++ survives outside the charge point', !/agentsUsed\+\+/.test(goSrc))

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
  // The recon pair explores and synthesises, so it belongs on the session model — but it was routed
  // through NEITHER helper, which meant it appeared in no tier while the /go skill told operators
  // agentsByTier says what each tier spent. Unset model, counted spend.
  for (const label of ['recon:surface', 'recon:conventions']) {
    check(`whip-task: ${label} is counted, on its own unset tier`,
      new RegExp(`tierOpts\\(\\{ label: '${label}'[\\s\\S]{0,160}?'recon'\\)`).test(taskSrc))
  }
  check('whip-task: the recon tier exists in the ledger',
    /agentsByTier = \{ shell: 0, judge: 0, author: 0, recon: 0 \}/.test(taskSrc))
  // STRUCTURAL: every dispatch in the file goes through a tier helper. A new agent() that forgets
  // silently inherits the session model AND vanishes from the cost report.
  {
    const unrouted = taskSrc.split('\n')
      .map((l, i) => [i + 1, l])
      .filter(([, l]) => /(await |\(\) => )agent\(/.test(l))
      .filter(([n]) => {
        const win = taskSrc.split('\n').slice(n - 1, n + 45).join('\n')
        return !/(shellOpts|tierOpts)\(\{/.test(win)
      })
    check(`whip-task: every agent() dispatch is tiered (unrouted: ${unrouted.map(([n]) => n).join(', ') || 'none'})`,
      unrouted.length === 0)
  }
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
  check('the architect is tagged too', /tierOf\.set\(aopts, 'architect'\)/.test(goSrc))
  check('child-harness agents are attributed to their own tier, not left off the tally',
    /tierOf\.set\(CHILD_TIER, 'child'\)/.test(goSrc) && /charge\(CHILD_TIER, budget\)/.test(goSrc))
  check('...and a downward true-up refunds the tier as well as the ledger',
    /agentsByTier\.child -= refund/.test(goSrc))
  // An agent with no declared model must keep inheriting the session model — absence is not a value.
  check('typedOpts only sets a model when the agent declares one',
    /const m = out\.agentType && agentModels\[out\.agentType\]/.test(goSrc))
  check('...and never clobbers a model the caller already chose', /if \(m && !out\.model\) out\.model = m/.test(goSrc))
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
  check('the tier counters cover every routed class, including the child harness',
    /agentsByTier = \{ shell: 0, specialist: 0, review: 0, architect: 0, resolver: 0, child: 0, untiered: 0 \}/.test(goSrc))
  check('...with an untiered bucket, so a dispatch through neither helper shows up instead of vanishing',
    /\|\| 'untiered'/.test(goSrc))
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
