// phase16-gate-legibility.test.mjs — the doctor gate must say WHICH failure it hit.
//
// Once acfw-store reports a battery that could not run as a typed FATAL rather than as silence
// (doctor-unavailable / snapshot-unavailable), doctorOk goes false for two very different reasons:
// the board is inconsistent, or nobody could read the board. Both gates used to model that as one
// boolean and tell the operator the backlog was inconsistent — sending them to /whip-doctor to fix
// findings that were never produced, on a store /whip-doctor also cannot reach.
//
// Also covers the child kill switch. The runtime spells the name-only restriction two different ways
// (the top-level tool says "named workflows", in-script workflow() says "named bundled workflows"),
// and a permission REFUSAL is a third state the five original classes did not name at all.
//
// Both subjects are EXTRACTED FROM SOURCE rather than re-typed, so this cannot pass against a stale copy.
//
// Run: node acf-whip/tests/phase16-gate-legibility.test.mjs

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(HERE, '..', 'workflows', 'whip-go.workflow.js'), 'utf8')

let P = 0, F = 0
const check = (m, c) => { c ? (P++, console.log('  PASS: ' + m)) : (F++, console.log('  FAIL: ' + m)) }

const m = src.match(/const UNAVAILABLE_RE = [\s\S]*?\n}\n/)
if (!m) { console.log('  FAIL: could not extract doctorVerdict from the workflow source'); F++ }
else {
  const doctorVerdict = new Function(`${m[0]}\nreturn doctorVerdict`)()
  check('real findings -> reported (backlog is known-bad)',
    doctorVerdict(['FATAL|dangling-dep|t1|dep x missing']).reported === true)
  check('only unavailability -> NOT reported (board is unread, not broken)',
    doctorVerdict(['FATAL|doctor-unavailable|-|the multica adapter doctor could not run (exit 5)']).reported === false)
  check('snapshot-unavailable counts as unavailability too',
    doctorVerdict(['FATAL|snapshot-unavailable|-|graph invariants are UNVERIFIED']).reported === false)
  check('both unavailability codes together -> still unread',
    doctorVerdict(['FATAL|doctor-unavailable|-|a', 'FATAL|snapshot-unavailable|-|b']).reported === false)
  // The one that matters most: a genuine defect alongside an unreachable battery must NOT be softened
  // into "we could not check" — that would turn a real integrity abort into an infrastructure excuse.
  check('MIXED (a real finding alongside unavailability) -> reported',
    doctorVerdict(['FATAL|doctor-unavailable|-|a', 'FATAL|cyclic-deps|t2|cycle']).reported === true)
  check('empty list -> reported (nothing to reclassify)', doctorVerdict([]).reported === true)
  check('non-array -> reported (defensive)', doctorVerdict(undefined).reported === true)
  check('the reason carries the adapter detail through to the operator',
    /could not run/.test(doctorVerdict(['FATAL|doctor-unavailable|-|the multica adapter doctor could not run (exit 5)']).why))
}

const kr = src.match(/if \((\/named \(bundled \)\?workflows[^/]*\/i)\.test\(msg\)\)/)
if (!kr) { console.log('  FAIL: could not extract the kill-switch regex from the workflow source'); F++ }
else {
  const re = new Function(`return ${kr[1]}`)()
  for (const [msg, name] of [
    ['this session restricts workflows to named bundled workflows (CLAUDE_WORKFLOW_NAME_ONLY is set)', 'in-script wording'],
    ['This session restricts the Workflow tool to named workflows (CLAUDE_WORKFLOW_NAME_ONLY is set)', 'top-level wording'],
    ['scriptPath must be a script path this tool returned, or a file you can already read', 'path refusal'],
    ['workflow scriptPath outside the readable set', 'permission decision reason'],
    ['workflow is not a function', 'older runtime'],
    ['nesting is limited to one level', 'nesting'],
    ['unknown workflow: whip-go', 'unknown name'],
    ['not available in this build', 'capability absent'],
  ]) check(`kill switch matches: ${name}`, re.test(msg))
  // A repairable child failure must NOT trip the switch, or one bad harness disables escalation
  // for the whole run.
  check('kill switch does NOT match an ordinary child-stage error',
    !re.test("child stage 'implement': gate did not converge after 2 rounds"))
  check('kill switch does NOT match a plain assertion failure',
    !re.test("Cannot read properties of undefined (reading 'passed')"))
}

console.log(`\nphase16-gate-legibility: ${P} passed, ${F} failed`)
process.exit(F === 0 ? 0 : 1)
