#!/usr/bin/env node
// acfw-child-validate.mjs — the deep pre-flight for an architect-authored acf-whip child workflow.
//
// Dependency-free (node/bun/deno, no packages). Invoked by the acfw-child-validate bash wrapper, which
// falls back to a grep battery when no JS runtime is present.
//
// The point of this file: turn generated-code defects into ERROR STRINGS the architect can repair,
// BEFORE any child agent spawns. Every check here is a throw class that would otherwise cost a full
// child execution to discover — and several (a forbidden global on a rarely-taken branch, a nesting
// violation, a dropped stage key) would not be caught by executing the harness either.
//
// Emits ONE JSON line on stdout and always exits 0: the verdict lives in the JSON, so a non-zero exit
// can never be confused with "the validator itself broke".

import { readFileSync, statSync } from 'node:fs'
import { execFileSync } from 'node:child_process'

const MAX_BYTES = 524288
const CONTRACT = 'acfw-child-contract: v1'

const errors = [], warnings = []
const err = (m) => errors.push(m)
const warn = (m) => warnings.push(m)

// ---------------------------------------------------------------------------------------------
// argv
// ---------------------------------------------------------------------------------------------
const argv = process.argv.slice(2)
const scriptPath = argv[0]
const trunkRoot = argv[1]
const flag = (n, d) => { const i = argv.indexOf(n); return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d }
const kind = flag('--kind', 'impl')
const requireStages = String(flag('--require-stages', '')).split(',').map((s) => s.trim()).filter(Boolean)
const fanoutMax = parseInt(flag('--fanout', '1'), 10) || 1
const budget = parseInt(flag('--budget', '8'), 10) || 8
const scaffoldBin = flag('--scaffold', '')
const registry = String(flag('--registry', '')).split(',').map((s) => s.trim()).filter(Boolean)

// The bash wrapper runs V-SKEL and the literal-token battery (so those never degrade) and hands its
// findings in via files — arbitrary prose with quotes and backslashes, which is exactly what argv
// escaping and in-awk JSON splicing both get wrong. This process emits the single merged verdict.
const readLines = (p) => {
  if (!p) return []
  try { return readFileSync(p, 'utf8').split('\n').map((s) => s.trim()).filter(Boolean) } catch (e) { return [] }
}
const shellErrors = readLines(flag('--shell-errors', ''))
const shellWarnings = readLines(flag('--shell-warnings', ''))

const emit = (extra = {}) => {
  const allErrors = [...shellErrors, ...errors]
  process.stdout.write(JSON.stringify({
    ok: allErrors.length === 0, parser: 'node', errors: allErrors,
    warnings: [...shellWarnings, ...warnings],
    plan: extra.plan || [], stageCount: extra.stageCount || 0,
    mutatingStages: extra.mutatingStages || 0, contract: extra.contract || '',
  }) + '\n')
  process.exit(0)
}

// ---------------------------------------------------------------------------------------------
// V-SIZE + read
// ---------------------------------------------------------------------------------------------
let src = ''
try {
  const st = statSync(scriptPath)
  if (!st.isFile()) { err(`V-SIZE: '${scriptPath}' is not a regular file`); emit() }
  if (st.size > MAX_BYTES) { err(`V-SIZE: ${st.size} bytes exceeds the ${MAX_BYTES}-byte limit`); emit() }
  src = readFileSync(scriptPath, 'utf8')
} catch (e) {
  err(`V-SIZE: cannot read '${scriptPath}': ${e.message}`)
  emit()
}

// ---------------------------------------------------------------------------------------------
// V-CONTRACT
// ---------------------------------------------------------------------------------------------
if (!src.includes(CONTRACT)) {
  // Distinct from "tampered": a file stamped by an OLDER plugin must be re-authored from scratch,
  // not amended, because its locked segments will never match the current template.
  err(`V-CONTRACT: skeleton-version-skew — the file does not carry '${CONTRACT}'. Re-scaffold from the current template instead of amending.`)
  emit({ contract: 'skew' })
}

// ---------------------------------------------------------------------------------------------
// Region split. Segments alternate LOCKED / FREE on the four marker pairs.
// ---------------------------------------------------------------------------------------------
const REGIONS = ['meta', 'plan', 'pre', 'body']
function split(text) {
  const locked = [], free = {}
  let cursor = 0, out = text
  for (const r of REGIONS) {
    const open = out.indexOf(`// <acfw-${r}>`, cursor)
    const close = out.indexOf(`// </acfw-${r}>`, open + 1)
    if (open < 0 || close < 0) return null
    const openEnd = open + `// <acfw-${r}>`.length
    locked.push(out.slice(cursor, openEnd))
    free[r] = { text: out.slice(openEnd, close), start: openEnd }
    cursor = close
  }
  locked.push(out.slice(cursor))
  return { locked, free }
}

const parts = split(src)
if (!parts) {
  err('V-SKEL: one or more // <acfw-*> ... // </acfw-*> marker pairs are missing or out of order. Re-run acfw-child-scaffold and re-fill.')
  emit()
}

// ---------------------------------------------------------------------------------------------
// V-SKEL — byte-diff every locked segment against the pristine scaffold for this kind.
// Trailing whitespace and line endings are normalised on BOTH sides (an editor stripping a trailing
// space must not be a validation failure); LEADING whitespace is significant and is not normalised.
// ---------------------------------------------------------------------------------------------
const norm = (s) => s.replace(/\r\n/g, '\n').split('\n').map((l) => l.replace(/[ \t]+$/, '')).join('\n')
if (scaffoldBin) {
  let ref = ''
  try {
    ref = execFileSync('bash', [scaffoldBin, '--stdout', '--kind', kind, '--stem', 'x', '--meta-name', 'x'], { encoding: 'utf8' })
  } catch (e) { warn(`V-SKEL: could not render the reference skeleton (${String(e.message).slice(0, 120)}) — locked segments NOT verified`) }
  if (ref) {
    const rp = split(ref)
    if (!rp) warn('V-SKEL: the reference skeleton did not split; locked segments NOT verified')
    else {
      for (let i = 0; i < rp.locked.length; i++) {
        // The last locked segment of the reference carries the scaffold's DEFAULT body only if the
        // architect kept it; bodies live in a free region, so every locked index is comparable.
        if (norm(parts.locked[i] || '') !== norm(rp.locked[i] || '')) {
          err(`V-SKEL: locked-region-modified:segment${i} — a locked segment differs from the shipped skeleton. You may only edit inside the four // <acfw-*> regions.`)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// The offset-preserving lexer.
//
// Blanks out the CONTENTS of string literals, template literal chunks, comments, and regex literals,
// replacing each character with a space and preserving newlines — so every downstream check keeps
// accurate line numbers while being blind to prose.
//
// Two properties that matter, both learned the hard way:
//   * `Date.now()` inside a PROMPT is not a defect. Without this it is a false positive on every
//     harness whose prompt tells an agent to shell out to `date`.
//   * `s.replace(/'/g, ...)` must not be read as an unterminated string. Regex literals are lexed.
// Template SUBSTITUTIONS (${...}) are deliberately left VISIBLE: code there really does execute.
// ---------------------------------------------------------------------------------------------
function stripLiterals(text) {
  const out = text.split('')
  const blank = (i) => { if (out[i] !== '\n') out[i] = ' ' }
  const n = text.length
  let i = 0
  const tmplStack = []          // depth of ${ } nesting inside template literals
  let prevSignificant = ''

  const regexAllowed = () => {
    if (prevSignificant === '') return true
    if ('(,=:[!&|?{};+-*%~^<>'.includes(prevSignificant)) return true
    return false
  }

  while (i < n) {
    const c = text[i]
    // line comment
    if (c === '/' && text[i + 1] === '/') {
      blank(i); blank(i + 1); i += 2
      while (i < n && text[i] !== '\n') { blank(i); i++ }
      continue
    }
    // block comment
    if (c === '/' && text[i + 1] === '*') {
      blank(i); blank(i + 1); i += 2
      while (i < n && !(text[i] === '*' && text[i + 1] === '/')) { blank(i); i++ }
      if (i < n) { blank(i); blank(i + 1); i += 2 }
      continue
    }
    // single / double quoted string
    if (c === "'" || c === '"') {
      const q = c
      i++ // keep the opening quote visible so a checker can still see a string existed
      while (i < n) {
        if (text[i] === '\\') { blank(i); blank(i + 1); i += 2; continue }
        if (text[i] === q) break
        if (text[i] === '\n') break // unterminated; bail rather than eat the file
        blank(i); i++
      }
      i++
      prevSignificant = q
      continue
    }
    // template literal
    if (c === '`') {
      i++
      while (i < n) {
        if (text[i] === '\\') { blank(i); blank(i + 1); i += 2; continue }
        if (text[i] === '`') break
        if (text[i] === '$' && text[i + 1] === '{') {
          // leave the substitution VISIBLE — it is executable code
          i += 2
          let depth = 1
          while (i < n && depth > 0) {
            if (text[i] === '{') depth++
            else if (text[i] === '}') depth--
            if (depth === 0) break
            i++
          }
          i++
          continue
        }
        blank(i); i++
      }
      i++
      prevSignificant = '`'
      continue
    }
    // regex literal
    if (c === '/' && regexAllowed()) {
      const start = i
      let j = i + 1, inClass = false, closed = false
      while (j < n) {
        if (text[j] === '\\') { j += 2; continue }
        if (text[j] === '\n') break
        if (inClass) { if (text[j] === ']') inClass = false }
        else if (text[j] === '[') inClass = true
        else if (text[j] === '/') { closed = true; break }
        j++
      }
      if (closed) {
        for (let k = start + 1; k < j; k++) blank(k)
        i = j + 1
        while (i < n && /[gimsuy]/.test(text[i])) i++
        prevSignificant = '/'
        continue
      }
      i = start
    }
    if (!/\s/.test(c)) prevSignificant = c
    i++
  }
  return out.join('')
}

const lineOf = (text, idx) => text.slice(0, idx).split('\n').length

// Top-level keys of an object literal (given its text starting at '{'), skipping nested objects and
// arrays. Run this on the LEXED slice: braces inside prompt prose would otherwise throw off the depth.
function topLevelKeys(objText) {
  const keys = []
  let d = 0
  for (let i = 0; i < objText.length; i++) {
    const c = objText[i]
    if (c === '{') { d++; continue }
    if (c === '}') { d--; if (d <= 0) break; continue }
    if (c === '[') { let ad = 0; for (; i < objText.length; i++) { if (objText[i] === '[') ad++; else if (objText[i] === ']') { ad--; if (ad === 0) break } } continue }
    if (d === 1) {
      const m = objText.slice(i).match(/^([A-Za-z_$][\w$]*)\s*:/)
      if (m) { keys.push(m[1]); i += m[0].length - 1 }
    }
  }
  return keys
}

// Build a code-only view of the whole file, then take the free regions out of it so every check runs
// on code with prose already removed but with offsets intact.
const codeAll = stripLiterals(src)
const freeCode = {}
for (const r of REGIONS) {
  const f = parts.free[r]
  freeCode[r] = { code: codeAll.slice(f.start, f.start + f.text.length), raw: f.text, start: f.start }
}
const allFree = REGIONS.map((r) => freeCode[r])
const scanFree = (re, cb) => {
  for (const r of REGIONS) {
    const { code, start } = freeCode[r]
    re.lastIndex = 0
    let m
    while ((m = re.exec(code)) !== null) cb(r, m, lineOf(src, start + m.index))
    }
}

// ---------------------------------------------------------------------------------------------
// V-META — a pure object literal. The runtime parses meta BEFORE the code exists.
// ---------------------------------------------------------------------------------------------
{
  const metaRaw = freeCode.meta.raw
  for (const [tok, why] of [['`', 'template literal'], ['${', 'interpolation'], ['require', 'require()']]) {
    if (metaRaw.includes(tok)) err(`V-META: the meta region contains a ${why} — it MUST be a pure literal (the runtime parses it before your code runs)`)
  }
  if (/[^:]\/\/|\bconcat\b|\+\s*\w/.test(freeCode.meta.code.replace(/\/\/[^\n]*/g, ''))) {
    if (/\+/.test(freeCode.meta.code)) err('V-META: the meta region contains a concatenation — it MUST be a pure literal')
  }
  if (!/name\s*:\s*['"]/.test(metaRaw)) err('V-META: meta.name is missing or is not a string literal')
  if (!/description\s*:\s*['"]/.test(metaRaw)) err('V-META: meta.description is missing or is not a string literal')
  const stem = flag('--stem', '')
  if (stem && !metaRaw.includes(stem)) {
    warn(`V-META: meta.name does not contain the stem '${stem}' — every concurrent harness will collapse into one indistinguishable group in /workflows`)
  }
}

// ---------------------------------------------------------------------------------------------
// V-COMPILE — exactly the wrap the runtime uses. A plain `node --check` FALSE-POSITIVES on every
// valid script here, because the runtime compiles the body inside an async function, making
// top-level await and top-level return legal.
// ---------------------------------------------------------------------------------------------
try {
  const body = src.replace(/^export const meta/m, 'const meta')
  // eslint-disable-next-line no-new-func
  new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow',
    `return (async () => {\n${body}\n})()`)
} catch (e) {
  err(`V-COMPILE: the script does not parse: ${String(e.message).slice(0, 300)}`)
}

// ---------------------------------------------------------------------------------------------
// V-GLOBALS / V-DIRECT / V-WORKTREE / V-BOUND / V-RETURN — forbidden constructs in FREE regions.
// ---------------------------------------------------------------------------------------------
const FORBIDDEN = [
  [/\bDate\s*\.\s*now\b/g, 'V-GLOBALS', 'Date.now() throws at the runtime (it would break resume). Have an AGENT shell out to `date -u +%FT%TZ` instead.'],
  [/\bMath\s*\.\s*random\b/g, 'V-GLOBALS', 'Math.random() throws at the runtime. Vary behaviour by stage index instead.'],
  [/\bnew\s+Date\s*\(\s*\)/g, 'V-GLOBALS', 'argless new Date() throws at the runtime.'],
  [/\bworkflow\s*\(/g, 'V-GLOBALS', 'workflow() is FORBIDDEN: nesting is one level only and YOU ARE that level. Calling it throws.'],
  [/\brequire\s*\(/g, 'V-GLOBALS', 'require() — a workflow script has no Node API. Agents do all I/O.'],
  [/\bimport\s*\(/g, 'V-GLOBALS', 'dynamic import() — a workflow script has no module loader.'],
  [/^\s*import\s+/gm, 'V-GLOBALS', 'import statement — a workflow script has no module loader.'],
  [/\bprocess\s*\./g, 'V-GLOBALS', 'process.* — a workflow script has no Node API.'],
  [/\bchild_process\b/g, 'V-GLOBALS', 'child_process — a workflow script cannot spawn. Agents run commands.'],
  [/\beval\s*\(/g, 'V-GLOBALS', 'eval() is forbidden.'],
  [/\bfs\s*\./g, 'V-GLOBALS', 'fs.* — a workflow script has NO filesystem. Agents do all I/O.'],
  [/(^|[^.\w])agent\s*\(/g, 'V-DIRECT', 'a bare agent() call — every dispatch must go through runStage() so it is budgeted, ledgered and replayable.'],
  [/(^|[^.\w])parallel\s*\(/g, 'V-DIRECT', 'a bare parallel() call — all fan-out must go through runWave() so mutating stages stay serialized.'],
  [/(^|[^.\w])pipeline\s*\(/g, 'V-DIRECT', 'a bare pipeline() call — use runWave().'],
  [/\bisolation\s*:/g, 'V-WORKTREE', "isolation: — acf-whip provides its OWN worktree isolation; a runtime worktree would put the agent where clean-checkout does not resolve."],
  [/while\s*\(\s*true\s*\)/g, 'V-BOUND', 'while (true) — you have no clock and no timer, so an unbounded loop hangs the whole /go iteration. Use a literal integer bound.'],
  [/for\s*\(\s*;\s*;\s*\)/g, 'V-BOUND', 'for (;;) — see V-BOUND: every loop needs a literal integer bound.'],
]
for (const [re, code, why] of FORBIDDEN) {
  scanFree(re, (region, m, line) => err(`${code}: line ${line} (${region} region): ${why}`))
}

// V-WORKTREE: the literal words, checked on the RAW text (they live inside prompts, which the lexer blanks)
for (const r of REGIONS) {
  const raw = freeCode[r].raw
  if (raw.includes('clean-checkout')) {
    err(`V-WORKTREE: the ${r} region mentions 'clean-checkout'. Exactly ONE clean-checkout runs per task, in the locked prologue — a second one silently stashes a sibling stage's in-flight work into the shared refs/stash.`)
  }
  if (/\.worktree\//.test(raw)) {
    err(`V-WORKTREE: the ${r} region contains a '.worktree/' path literal. The worktree path is not knowable at authoring time — it is the locked checkout stage's stdout, already bound to WT.`)
  }
  if (raw.includes('.acfwhip/integrated')) {
    err(`V-GIT: the ${r} region references .acfwhip/integrated — that is the LP-CAS ledger; writing it QUARANTINES this task.`)
  }
}

// V-GIT: forbidden git verbs, checked on RAW text (they are prompt instructions, not code)
const GIT_FORBIDDEN = ['git merge', 'git rebase', 'git pull', 'git reset', 'git stash', 'worktree remove', 'branch -D']
const GIT_FORBIDDEN_RESOLVE = ['cherry-pick --continue', 'cherry-pick --commit', 'cherry-pick --abort', 'cherry-pick --quit']
// A prompt may legitimately FORBID a verb ("never run git reset", or a multi-line FORBIDDEN: block).
// Only flag an occurrence that is NOT governed by a nearby prohibition. The window spans newlines,
// because a FORBIDDEN: block lists several verbs across several lines — a [^\n] window flags the
// shipped resolve body against itself.
const PROHIBITED_NEAR = /(never|not|forbidden|do not|don't|must not)/i
function isProhibitionContext(text, at) {
  return PROHIBITED_NEAR.test(text.slice(Math.max(0, at - 240), at))
}
for (const r of REGIONS) {
  const raw = freeCode[r].raw
  const scanVerb = (g, msg) => {
    let from = 0, at
    while ((at = raw.indexOf(g, from)) >= 0) {
      if (!isProhibitionContext(raw, at)) { err(msg); return }
      from = at + g.length
    }
  }
  for (const g of GIT_FORBIDDEN) {
    scanVerb(g, `V-GIT: the ${r} region instructs '${g}'. A child may only add commits to its own branch — the integrator rebuilds the candidate from the branch tree, so history rewriting and trunk merges corrupt it.`)
  }
  if (kind === 'resolve') {
    for (const g of [...GIT_FORBIDDEN_RESOLVE, 'git add -A', 'git add .']) {
      scanVerb(g, `V-GIT: the ${r} region instructs '${g}' in a resolve harness. The integrator owns the commit and already runs add -A; doing this strands or corrupts the cherry-pick.`)
    }
  }
}

// V-RETURN: no top-level return in a free region except `return finish(`
scanFree(/^[ \t]*return\b(?![ \t]*finish\s*\()/gm, (region, m, line) => {
  err(`V-RETURN: line ${line} (${region} region): a top-level return. Only 'return finish(...)' may return from a free region.`)
})

// V-PHASE: warning only
scanFree(/(^|[^.\w])phase\s*\(/g, (region, m, line) => {
  warn(`V-PHASE: line ${line} (${region} region): phase() is a NO-OP inside a child. Use log() and a distinctive meta.name for observability.`)
})

// ---------------------------------------------------------------------------------------------
// V-LOOP — every runStage/runWave inside a for/while body must carry `iteration:`.
//
// Without this the stage key is constant, the ledger replays the FIRST result on every later
// iteration, and a "loop until green" silently freezes on its first failure while looking healthy.
// ---------------------------------------------------------------------------------------------
{
  const code = freeCode.body.code
  const start = freeCode.body.start
  const loopRe = /\b(for|while)\s*\(/g
  let m
  while ((m = loopRe.exec(code)) !== null) {
    // find the loop body block
    let i = m.index + m[0].length - 1
    let depth = 0
    // skip the header parens
    for (; i < code.length; i++) {
      if (code[i] === '(') depth++
      else if (code[i] === ')') { depth--; if (depth === 0) { i++; break } }
    }
    while (i < code.length && /\s/.test(code[i])) i++
    let bodyText = '', bodyStart = i
    if (code[i] === '{') {
      let d = 0
      for (; i < code.length; i++) {
        if (code[i] === '{') d++
        else if (code[i] === '}') { d--; if (d === 0) { i++; break } }
      }
      bodyText = code.slice(bodyStart, i)
    } else {
      const nl = code.indexOf('\n', i)
      bodyText = code.slice(i, nl < 0 ? code.length : nl)
    }
    const callRe = /\brunStage\s*\(|\brunWave\s*\(/g
    let c
    while ((c = callRe.exec(bodyText)) !== null) {
      // look at the object literal that follows, to the matching close brace
      const objStart = bodyText.indexOf('{', c.index)
      if (objStart < 0) continue
      let d = 0, j = objStart
      for (; j < bodyText.length; j++) {
        if (bodyText[j] === '{') d++
        else if (bodyText[j] === '}') { d--; if (d === 0) { j++; break } }
      }
      const obj = bodyText.slice(objStart, j)
      if (!/\biteration\s*:/.test(obj)) {
        err(`V-LOOP: line ${lineOf(src, start + bodyStart + c.index)}: a runStage/runWave inside a loop without 'iteration:'. Its ledger key would be constant, so iterations 2+ replay iteration 1's recorded result instead of running. Add  iteration: <the loop variable>.`)
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// V-DEREF — a member access two levels deep on a stage result must use ?.
// runStage returns { __failed: true } on flakiness, so `r.a` is always safe but `r.a.b` is not.
// ---------------------------------------------------------------------------------------------
{
  const code = freeCode.body.code
  const start = freeCode.body.start
  // identifiers assigned from runStage/runWave
  const ids = new Set()
  const assignRe = /(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*await\s+run(?:Stage|Wave)\s*\(/g
  let a
  while ((a = assignRe.exec(code)) !== null) ids.add(a[1])
  for (const id of ids) {
    const deep = new RegExp(`\\b${id.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&')}\\.([\\w$]+)\\.`, 'g')
    let d
    while ((d = deep.exec(code)) !== null) {
      const at = d.index + d[0].length - 1
      if (code[at] === '.' && code[at - 1] !== '?') {
        // allow `?.` form
        const seg = code.slice(d.index, at + 1)
        if (!seg.includes('?.')) {
          err(`V-DEREF: line ${lineOf(src, start + d.index)}: '${d[0]}' dereferences a stage result two levels deep without '?.'. runStage returns { __failed: true } on agent flakiness, so this throws a TypeError deep in the run. Use '${id}.${d[1]}?.'`)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// V-PLAN — PLANNED must be a pure literal array; keys unique kebab; budget respected.
// V-AGENTS — every agentType is a string literal in the registry.
// V-STAGES — every required (already-completed) stage key survives the amend.
// V-SCHEMA — schema literals are well formed.
// V-FANWRITE — a fanned spec that references WT must be mutates:true.
// ---------------------------------------------------------------------------------------------
let plan = [], stageCount = 0, mutatingStages = 0
{
  const raw = freeCode.plan.raw
  const m = raw.match(/PLANNED\s*=\s*(\[[\s\S]*?\])\s*(?:;|\n\s*(?:const|let|var|SHALLOW)|$)/)
  if (!m) {
    err("V-PLAN: the plan region must declare  PLANNED = [ { key, label, agentType, producesCommit, mutates, maxAgents }, ... ]  as a pure array literal.")
  } else {
    const arrText = m[1]
    if (/`|\$\{|\brequire\b|\bawait\b|=>/.test(arrText)) {
      err('V-PLAN: PLANNED must be a PURE literal — no template literals, interpolation, arrow functions or await.')
    } else {
      try {
        // eslint-disable-next-line no-new-func
        plan = new Function(`return ${arrText}`)()
      } catch (e) { err(`V-PLAN: PLANNED is not a valid array literal: ${String(e.message).slice(0, 160)}`) }
    }
    if (Array.isArray(plan)) {
      const seen = new Set()
      let sum = 0
      for (const p of plan) {
        if (!p || typeof p !== 'object') { err('V-PLAN: every PLANNED entry must be an object'); continue }
        const k = String(p.key || '')
        if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(k)) err(`V-PLAN: stage key '${k}' must be lowercase-kebab`)
        if (seen.has(k)) err(`V-PLAN: duplicate stage key '${k}' — keys are durable ledger keys and must be unique`)
        seen.add(k)
        if (p.agentType && !registry.includes(String(p.agentType))) {
          err(`V-AGENTS: PLANNED stage '${k}' names agentType '${p.agentType}', which is not installed. Installed: ${registry.join(', ') || '(none)'}`)
        }
        if (p.mutates === true) mutatingStages++
        sum += Number(p.maxAgents || 1)
      }
      stageCount = plan.length
      if (sum > budget) err(`V-PLAN: the plan's maxAgents sum (${sum}) exceeds your ceiling of ${budget}. Reduce the harness.`)
    }
  }
}

// V-AGENTS on the authored stages: agentType must be a string literal (or A.agentType), never computed.
//
// The POSITION is found in the lexed code (so an `agentType:` mentioned inside prompt prose is
// invisible), but the VALUE is read from the RAW text at that same offset — the lexer is
// offset-preserving precisely so these two views can be combined. Reading the value from the lexed
// text would see every literal blanked to spaces and reject every valid harness.
// The plan region is skipped: V-PLAN already checks PLANNED's agentTypes against the registry.
for (const region of ['pre', 'body']) {
  const { code, raw, start } = freeCode[region]
  const re = /agentType\s*:\s*/g
  let m
  while ((m = re.exec(code)) !== null) {
    const at = m.index + m[0].length
    const tail = raw.slice(at, at + 200)
    const v = (tail.match(/^[^,}\n]*/) || [''])[0].trim()
    const line = lineOf(src, start + m.index)
    if (/^A\.agentType$/.test(v)) continue
    const lit = v.match(/^['"]([^'"]*)['"]$/)
    if (!lit) {
      err(`V-AGENTS: line ${line}: agentType must be a STRING LITERAL or A.agentType, not a computed value (${v.slice(0, 40)}). An unknown agent type throws at dispatch, and the architect cannot fix a value the parent injected.`)
      continue
    }
    if (lit[1] === '') continue // explicit "no agentType" is fine
    if (registry.length && !registry.includes(lit[1])) {
      err(`V-AGENTS: line ${line}: agentType '${lit[1]}' is not installed. Installed: ${registry.join(', ')}`)
    }
  }
}

// V-STAGES — the mechanical half of the durability guarantee.
for (const need of requireStages) {
  const base = need.split('#')[0]
  const inPlan = plan.some && plan.some((p) => p && String(p.key) === base)
  const inBody = new RegExp(`key\\s*:\\s*['"]${base.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}['"]`).test(freeCode.body.raw)
  if (!inPlan) err(`V-STAGES: completed stage '${need}' is missing from PLANNED. You were handed its recorded result; dropping or renaming it would REDO work that is already done.`)
  if (!inBody) err(`V-STAGES: completed stage '${need}' has no runStage/runWave call in the body. Keep its key VERBATIM so its recorded result replays.`)
}

// V-SCHEMA — every JSON-Schema-shaped object literal must be structurally valid.
//
// Triggered by SHAPE (an object literal carrying `required: [...]`), not by position. Keying off
// `schema: {` would miss the overwhelmingly common form — schemas declared once as
// `const GT = { ... }` and referenced later as `schema: GT` — which is exactly how the shipped default
// body writes them. A `required` naming a key absent from `properties` makes the runtime reject the
// tool definition, and the resulting TypeError surfaces deep in the run, after real work.
for (const region of REGIONS) {
  const { code, raw, start } = freeCode[region]
  const stack = []
  const done = new Set()
  for (let i = 0; i < code.length; i++) {
    const ch = code[i]
    if (ch === '{') { stack.push(i); continue }
    if (ch === '}') { stack.pop(); continue }
    if (ch !== 'r' || !/^required\s*:\s*\[/.test(code.slice(i, i + 24))) continue
    const open = stack.length ? stack[stack.length - 1] : -1
    if (open < 0 || done.has(open)) continue
    done.add(open)
    let d = 0, j = open
    for (; j < code.length; j++) {
      if (code[j] === '{') d++
      else if (code[j] === '}') { d--; if (d === 0) { j++; break } }
    }
    const obj = raw.slice(open, j)
    const line = lineOf(src, start + open)
    // `type:` must be a TOP-LEVEL key. Testing the whole object text matches the nested
    // `properties: { ok: { type: 'boolean' } }` of a schema that has no top-level type at all,
    // which silently accepts exactly the malformed shape this check exists to catch.
    if (!topLevelKeys(code.slice(open, j)).includes('type')) {
      err(`V-SCHEMA: line ${line}: a schema-shaped literal has no top-level 'type'. A malformed schema is rejected by the runtime and throws at the stage that uses it, deep in the run.`)
      continue
    }
    const req = obj.match(/required\s*:\s*\[([^\]]*)\]/)
    const propsIdx = obj.search(/properties\s*:\s*\{/)
    if (!req) continue
    const keys = req[1].split(',').map((s) => s.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean)
    if (propsIdx < 0) {
      if (keys.length) err(`V-SCHEMA: line ${line}: 'required' names ${keys.length} key(s) but the schema has no 'properties'.`)
      continue
    }
    const propsText = obj.slice(propsIdx)
    for (const k of keys) {
      if (!new RegExp(`(^|[{,\\s])${k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*:`).test(propsText)) {
        err(`V-SCHEMA: line ${line}: 'required' names '${k}' but 'properties' has no such key. The runtime rejects the tool definition and the stage throws.`)
      }
    }
  }
}

// V-FANWRITE — a runWave spec that tells its agent to WRITE, without mutates:true.
//
// Deliberately NOT "references WT": read-only analysis inside the worktree is the legitimate parallel
// lane (recon, call-site census, per-file conflict analysis, review lenses), and every one of those
// needs the path in order to read. Flagging the reference rejects the shipped resolve harness against
// itself. The hazard is concurrent WRITING, so the proxy is a write verb — and a prompt that
// PROHIBITS the verb ("you may NOT edit", "never run git add") is not an instruction to do it.
{
  const raw = freeCode.body.raw
  const WRITE_VERB = /\bgit\s+(?:add|commit|checkout|apply)\b|\b(?:edit|modify|rewrite|create|delete|remove)\b|\brun the (?:build|tests?|quality gates?)\b/gi
  const waveRe = /runWave\s*\(/g
  let m
  while ((m = waveRe.exec(raw)) !== null) {
    const seg = raw.slice(m.index, m.index + 6000)
    const specRe = /\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}/g
    let s
    while ((s = specRe.exec(seg)) !== null) {
      const spec = s[0]
      if (!/\bkey\s*:/.test(spec)) continue
      if (/\bmutates\s*:\s*true/.test(spec)) continue
      WRITE_VERB.lastIndex = 0
      let w
      while ((w = WRITE_VERB.exec(spec)) !== null) {
        if (isProhibitionContext(spec, w.index)) continue
        err(`V-FANWRITE: line ${lineOf(src, freeCode.body.start + m.index)}: a fanned stage instructs '${w[0]}' but is not mutates:true. Fanned agents run CONCURRENTLY and only one may hold the worktree — a second writer's clean tree is another's half-finished edit. Mark it mutates:true (runWave then serializes it) or make the stage genuinely read-only.`)
        break
      }
    }
  }
}

// V-FANOUT — a literal fan wider than the parent's ceiling
if (Array.isArray(plan)) {
  const widest = plan.reduce((a, p) => Math.max(a, Number((p && p.maxAgents) || 1)), 0)
  if (widest > fanoutMax * 4) {
    warn(`V-FANOUT: a stage declares maxAgents ${widest} while the parent's per-fan-out ceiling is ${fanoutMax}; runWave will chunk it, so this only costs wall clock.`)
  }
}

emit({ plan, stageCount, mutatingStages, contract: 'v1' })
