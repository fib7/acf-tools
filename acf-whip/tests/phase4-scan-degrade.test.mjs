// phase4-scan-degrade.test.mjs — guards the BUG-1/BUG-6a scan hardening in whip-go.workflow.js.
//
// A read-only scan (or drain scan) that fails to emit StructuredOutput must NOT abort the whole /go
// run. Two layers protect it: (1) extractJson() recovers the snapshot from a schema-less text scan
// ("the model answered but didn't call the tool"); (2) when even that fails, the loop degrades to a
// graceful `scan-degraded` stop + drain instead of `aborted:true`. This test extracts the pure
// extractJson() from source and asserts the source wiring no longer hard-aborts on a scan non-emit.
//
// Run: node acf-whip/tests/phase4-scan-degrade.test.mjs

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const SRC = join(HERE, '..', 'workflows', 'whip-go.workflow.js')
const text = readFileSync(SRC, 'utf8')

let PASS = 0, FAIL = 0
const ok = (m) => { PASS++; console.log(`  PASS: ${m}`) }
const bad = (m) => { FAIL++; console.log(`  FAIL: ${m}`) }
const check = (m, cond) => (cond ? ok(m) : bad(m))

// ---- extract extractJson() from source (pure, no deps) ----
const m = text.match(/function extractJson\(text\) \{[\s\S]*?\n\}/)
if (!m) { console.error('FATAL: could not find extractJson() in whip-go.workflow.js'); process.exit(1) }
// eslint-disable-next-line no-new-func
const extractJson = new Function(`${m[0]}\nreturn extractJson;`)()

// ============================ extractJson ============================
check('null -> null', extractJson(null) === null)
check('empty -> null', extractJson('') === null)
check('no-json prose -> null', extractJson('the command failed, sorry') === null)
check('bare object parses', JSON.stringify(extractJson('{"counts":{"total":3},"tasks":[]}')) === '{"counts":{"total":3},"tasks":[]}')
check('object with surrounding prose parses', (() => {
  const o = extractJson('Here is the snapshot:\n{"counts":{"total":1},"tasks":[]}\nDone.')
  return o && o.counts && o.counts.total === 1
})())
check('fenced ```json block parses', (() => {
  const o = extractJson('```json\n{"counts":{"total":2},"tasks":[{"stem":"a"}]}\n```')
  return o && o.counts.total === 2 && o.tasks.length === 1
})())
check('fenced ``` (no lang) parses', (() => {
  const o = extractJson('```\n{"counts":{"total":9}}\n```')
  return o && o.counts.total === 9
})())
check('nested-object snapshot parses (outermost braces)', (() => {
  const o = extractJson('{"counts":{"total":5,"accepted":2},"tasks":[{"stem":"x","deps":["y"]}]}')
  return o && o.counts.accepted === 2 && o.tasks[0].deps[0] === 'y'
})())
check('garbage braces -> null (no crash)', extractJson('{ not json at all ]') === null)

// ============================ source wiring (degrade, don't abort) ============================
check('no longer aborts the run on a scan non-emit',
  !text.includes("'scan agent never emitted after retries; re-run /go"))
check('degrades to scan-degraded stop reason instead', text.includes("stopReason = 'scan-degraded'"))
check('scan-degraded path breaks the loop (falls through to Drain)', (() => {
  const i = text.indexOf("stopReason = 'scan-degraded'")
  return i > 0 && text.slice(i, i + 400).includes('break')
})())
check('schema-less text fallback is attempted before degrading', text.includes('textScanFallback('))
check('mid-run integrity FATAL is STILL a hard abort (genuine, not transient)',
  text.includes("stopReason = 'integrity-fatal-midrun'") && text.includes("aborted: true, reason: 'integrity FATAL detected mid-run"))
check('drain falls back to lastSnapshot when its own scan cannot emit (BUG-6a)',
  text.includes('if (!snap2) snap2 = lastSnapshot'))
check('drain excludes stems already integrated this run (stale-snapshot guard)',
  text.includes('!integratedStems.includes(t.stem)'))
check('scan-degraded is reported as a non-completed clean stop', (() => {
  const i = text.indexOf("stopReason === 'scan-degraded'")
  return i > 0 && text.slice(i, i + 300).includes('re-run /go to continue')
})())

console.log(`\nphase4-scan-degrade: ${PASS} passed, ${FAIL} failed`)
process.exit(FAIL === 0 ? 0 : 1)
