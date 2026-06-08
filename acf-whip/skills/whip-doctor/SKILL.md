---
name: whip-doctor
description: Backlog integrity check for ACF Whip. Scans .backlog/ and the git worktree registry for ~18 invariants (status/folder mismatch, dangling or cyclic dependencies, missing/duplicate worktree slugs, orphaned worktrees, unknown agents, stray Integrated-At, out-of-range Rejection Count, missing clean-checkout tokens, cross-slug glob overlap, stale in-progress). Reports FATAL/REPAIRABLE/WARN; --fix auto-repairs the REPAIRABLE class. Run it before /go, or any time the backlog looks inconsistent.
argument-hint: "[--fix]"
allowed-tools:
  - Bash
  - Read
---

# /whip-doctor

Deterministic backlog integrity gate. The check battery lives in
`${CLAUDE_PLUGIN_ROOT}/skills/whip-doctor/bin/doctor.sh`; this skill runs it and explains
the result. `/go` runs the same script as a startup hard gate and a per-iteration recheck.

## Run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/whip-doctor/bin/doctor.sh"          # report only
bash "${CLAUDE_PLUGIN_ROOT}/skills/whip-doctor/bin/doctor.sh" --fix    # auto-repair REPAIRABLE, then re-scan
```

It prints one finding per line, then a summary:

```
SEVERITY|CODE|TASK_ID|DETAIL
SUMMARY|fatal=N|repairable=N|warn=N|ok=true|false
```

Exit 0 when `ok=true` (no FATAL), exit 1 otherwise.

## Severity classes

- **FATAL** — corruption that MUST block execution: status-vs-folder mismatch,
  duplicate ID across files, dangling or cyclic dependencies, a code-mutating task with
  no `Worktree:` slug, an `Assigned Agent` with no agent file, an acf-whip worktree on the
  wrong branch, a dispatched task whose cross-slug dependency is not yet integrated, detached
  HEAD at the repo root, unparseable frontmatter.
- **REPAIRABLE** — safe to auto-fix with `--fix`, then re-scan to confirm: stray
  `Integrated-At` on a non-accepted task (cleared), `Rejection Count` out of `[0,5]`
  (clamped), the same task present in two folders (kept the one matching its `Status`),
  an orphaned `.worktree/<slug>` with no live task (removed).

**Ownership scope (worktree checks).** The doctor manages **only** worktrees on the
namespace it owns — `<ACFW_BRANCH_PREFIX>/<slug>` (default `worktree/<slug>`), configurable in
`.backlog/.acfw-config`. A directory under `.worktree/` on any other branch, detached (e.g.
mid-rebase), or that is not a registered worktree is treated as **foreign** — your own
parallel research/benchmark work — and is left completely alone: no `orphaned-worktree`, no
`worktree-wrong-branch`, and never removed by `--fix`. Both the wrong-branch FATAL and the
orphan reaper apply only to worktrees in acf-whip's branch namespace.
- **WARN** — surfaced, never blocks: accepted task missing the `clean-checkout | ok`
  token, a task lingering in `in-review/`, an in-progress task past the configurable
  timeout (`ACFW_INPROGRESS_TIMEOUT_HOURS`, default 8h), two pending tasks in different
  slugs that declare overlapping `Touches Globs` (possible mis-partition).

## How to respond

1. Run the report. If `ok=true`, say so and stop.
2. If only REPAIRABLE/WARN findings, summarize them. Offer `--fix` for the repairables.
3. If FATAL findings, list them plainly. FATAL must be resolved before `/go` will dispatch.
   Most FATALs are task-engineer errors (missing slug, bad deps) — route them back to
   `/task` or fix the frontmatter directly at the repo root.
4. After `--fix`, report what was repaired and the post-repair summary.

The doctor **plans and applies** repairs only when invoked with `--fix` and only for the
REPAIRABLE class; inside the `whip-go` workflow the doctor-agent reports and the single
backlog-writer applies, preserving the single-writer invariant.

---

**Last Updated**: 2026-05-28
