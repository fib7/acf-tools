# acf-whip Task-Store Adapter Contract (v1)

acf-whip's task store is pluggable. An **adapter** is one executable named
`acfw-store-<backend>` that implements the subcommands below. The dispatcher
(`skills/lib/bin/acfw-store`) resolves the active backend, locates the adapter,
exports the environment contract, and compensates for optional capabilities.

**Shipped adapters**: `files` (default, `.backlog/` folders in git), `beads`, `multica`, `linear`.

This document is the normative spec. For the architecture, dispatcher mechanics, capability
compensation, data-flow walkthroughs, and a write-your-own authoring guide, see `adapters/README.md`.

## Adding a backend without forking

1. Write one executable implementing this contract (any language).
2. Drop it at `<repo>/.acfwhip/adapters/acfw-store-<backend>` (commit it), or install it on `$PATH`.
3. Set `ACFW_STORE=<backend>` in `<repo>/.acfwhip/config`.
4. Verify: `ADAPTER=<path> bash tests/phase9-store-conformance.test.sh` must pass.

**Discovery order** (first executable wins): `$ACFW_STORE_ADAPTER_PATH` (colon-separated dirs) → `<repo>/.acfwhip/adapters/` → `<plugin>/adapters/<backend>/` → `$PATH`.

**Backend resolution**: `ACFW_STORE` env → `ACFW_STORE=` key in config → `files`.
**Config resolution**: `$ACFW_CONFIG_FILE` → `<repo>/.acfwhip/config` → `<repo>/.backlog/.acfw-config` (legacy).

## Invocation

```
acfw-store-<backend> <subcommand> [args...]
```

JSON results on stdout (exactly one object), diagnostics on stderr. Non-JSON line protocols (`ok:`/`noop:`/`warn:` for transition; `SEV|code|task|detail` + `SUMMARY|` for doctor) are part of the contract where noted.

**Environment** (set by the dispatcher; adapters must also work when invoked directly, falling back to `git rev-parse --show-toplevel`):

| Var | Meaning |
|---|---|
| `ACFW_TRUNK_ROOT` | absolute repo root |
| `ACFW_TRUNK_BRANCH` | trunk branch name (may be empty) |
| `ACFW_STORE_CONFIG` | resolved config file path (may be empty/absent) |
| `ACFW_INTEGRATION_MODE` | `override`, `default`, or empty (unpinned). Whether the operator owns integration. Most adapters can ignore it — the dispatcher already passes `--mode` to `snapshot`; it is exported so the git-side batteries (`acfw-doctor-generic.sh`) resolve the same value the orchestrator is scheduling under. Added in 3.2.1; additive, so `ACFW_CONTRACT_VERSION` is still `1`. |
| `ACFW_CONTRACT_VERSION` | `1` |
| `ACFW_PLUGIN_LIB` | absolute path of `skills/lib/` (bash adapters may source `acfw-git.sh`) |

Backend-specific env (`BD_*`, `ACFW_BEADS_*`, `MULTICA_*`, …) passes through untouched.

**Exit codes**: `0` ok / idempotent no-op · `2` usage · `3` not found / ambiguous · `4` conflict (duplicate key) · `5` backend unavailable · `6` auth · `7` invalid state or value · `8` policy refusal · `99` transient — backend locked, or timed out waiting for it (caller may retry).

## Task model

- **Key** = the task *stem* (`feature-001-yaml-processor`). Caller-supplied, stable, kebab-safe. It names the LP-CAS ledger marker and is the only task reference in the contract. Adapters may accept a unique prefix; ambiguity is exit 3.
- **States** (whip-canonical): `draft`, `pending`, `in-progress`, `completed`, `in-review`, `accepted`, `rejected`, `blocked`, plus `archive`. Adapters map these to native backend states however they like; `snapshot`/`read` always report the whip-canonical name. A state outside this list is **quarantine, not corruption**: the scheduler dispatches on exact state equality, so a task in a state it does not name is inert — it can never be dispatched, transitioned or integrated, and cannot make a run wrong. Report it as `WARN`, never `FATAL`; a gate-blocking finding there aborts a whole board over one inert card. The same reasoning sets the severity tier for structural defects generally: `accepted` (terminal), `draft` (the human gate) and `archive` (retired) are **out of the dispatch path**, so defects there are advisory; every other state gates.
- **Body** = the task document markdown as the backend stores it (files: the whole file; beads/multica: the issue description). `create` ingests a full task document with `- **Field**: value` metadata bullets; adapters parse the fields they map natively.
- **Integration state is NOT the adapter's business.** The LP-CAS ledger (`.acfwhip/integrated/` in the git tree) stays git-native; the dispatcher merges `hasIntegratedAt` and integration counts into snapshots for adapters without `snapshot-enriched`.

## Required subcommands

### `capabilities`
```json
{"backend":"<name>","contractVersion":1,"commitsToGit":<bool>,"capabilities":["snapshot","read","create","transition",...]}
```
Capability flags: `snapshot-enriched`, `stage`, `update-field`, `update-body`, `log-event`, `comment`, `doctor`, `doctor-fix`, `doctor-complete`, `init`, `sync`, `atomic-claim`. `commitsToGit` = state writes produce trunk commits (files: true).

### `snapshot [--digest] [--counts-only] [--mode default|override]`
One BacklogSnapshot JSON object. Adapter-owned fields per task: `stem`, `id`, `folder` (whip state), `status`, `slug` (worktree), `agent`, `priority`, `deps[]` (stems), `touchesGlobs[]`, `rejectionCount` (number), `blockCount` (number), `lastTransitionTs` (`YYYY-MM-DD HH:MM:SS` UTC), `hasCleanCheckoutToken` (bool), plus top-level `counts{<state>:n,...}` and `generatedAt`. `--digest`/`--counts-only`/`--mode` may be treated as hints (a full snapshot is always acceptable).

**`tasks[]` is the ACTIVE working set**: the seven states the scheduler can act on (`pending`,
`in-progress`, `completed`, `in-review`, `blocked`, `rejected`, `accepted`). `draft` and `archive`
belong in a sibling **`inactive[]`** array of the same shape. An adapter may simply list everything in
`tasks[]` — the dispatcher's enricher performs the split — but an adapter with `snapshot-enriched`
owns it, because nothing downstream will do it for them. The distinction is load-bearing in three
places: a scoped run counts `tasks[]` as its completion denominator and `isTerminal` is false for both
inactive states, so a draft in there makes `terminal === total` unreachable; the per-task doctor
battery raises findings against every entry; and `inactive[]` is still unioned into the dependency
index, so a task depending on a draft reports `WARN|dep-inactive` (gated, with the remedy) instead of
`FATAL|dangling-dep` (a lie — the dep exists).

Adapters **without** `snapshot-enriched` emit `"raw":true` and omit git-derived facts (`trunkSha`, `hasIntegratedAt`, `hasWorktreeBranch`, `worktrees[]`, `isCodeMutating`, `ageHours`, integrated/terminal counts) — the dispatcher fills them. Adapters must **not** emit `store`; the dispatcher injects it. The `files` snapshot (see `skills/go/bin/scan-backlog.sh`) is the reference shape.

### `read [--body] [--materialize DIR] <key>`
```json
{"stem":"...","folder":"<whip-state>","fields":{"id":"...","status":"...","priority":"...","agent":"...","worktree":"...","pr_group":"...","touches_globs":"...","dependencies":"...","rejection_count":0,"block_count":0},"body":"..."}
```
`body` only with `--body`. `--materialize DIR` writes a full task document to `DIR/<key>.md` and prints that path instead of JSON — this is how specialists and `clean-checkout` get a spec file on non-files backends (files prints the real root path). A materialized document MUST contain: the current metadata bullets, the body, **and the stored audit trail** — every `log-event` row and `comment`, verbatim. Rows an adapter already keeps in the document (files, multica) satisfy this inline via the `## Transition Log` table; anything held out-of-document is appended oldest-first under a heading of the adapter's choosing (`## Store Comments`, `## Store Audit Trail`). The audit trail is load-bearing: the quality-reviewer's auto-reject greps the refreshed materialized document for the `| clean-checkout | ok |` token that `log-event` recorded — from wherever it lives.

### `create [--folder pending] [--file PATH | stdin] [--stem KEY] [--set Field=Value]...`
Ingest one task document. Key = `--stem` or the `--file` basename. Duplicate key → exit 4 (never upsert). `--set` overrides a metadata field after parse (e.g. `--set 'Dependencies=a, b'`). Optional fields honored where native: `parent_key`, `stage` (multica `--parent/--stage`, beads `--parent`; files ignores). Returns `{"key":"..."}`.

### `transition [--stage PATH]... <key> <TO_STATE> [AGENT] [NOTES] [RINC] [BINC]`
The positional tail mirrors `apply-transition.sh` argument-for-argument. Semantics:
- **Idempotent**: already in `TO_STATE` → `noop:` line, exit 0, no counter bumps.
- Appends an audit/transition-log row. **Where** is the adapter's choice: files and multica splice it into the task document's `## Transition Log` table (shared `append_log_row` — newest-first, capped, appended at EOF when the document has no table); beads and linear post it as an issue comment. Prefer the document when the backend's comment stream is an agent-facing channel.
- `RINC=1` + `TO_STATE=rejected` bumps rejection count; `BINC=1` + `TO_STATE=blocked` bumps block count.
- `archive` is a legal target. Invalid state → exit 7. Unknown key → exit 3.
- `--stage PATH` (capability `stage`): co-commit repo-relative deliverable files with the state change. Refuse empty/absolute/`..`/`.backlog/`/`.acfwhip/` paths (exit 2). Adapters without `stage` never see the flag — the dispatcher commits deliverables to trunk itself first.

Output: `ok:`/`noop:`/`warn:` lines (echoed verbatim into run reports).

## Optional subcommands (capability-gated)

| Subcommand | Contract |
|---|---|
| `init` | Create/verify the store. Idempotent. Config via env. |
| `update-field <key> [--set Field=Value]... [--add-dep ID]...` | Field edits. `Dependencies` via `--set` is full replacement (bare comma list); `--add-dep` appends. State changes are refused (exit 2) — use `transition`. Dependency tokens may name **not-yet-created keys** — adapters must record and report them verbatim, never drop them (graph-backed stores keep an out-of-graph dep record as the contract-of-record; the doctor, not the adapter, flags dangling deps). |
| `update-body <key>` | Replace the task document/description from stdin. Refuse empty input. |
| `log-event <key> --row "\| ... \|"` | Append one machine-greppable event row (the `clean-checkout \| ok` token). Must surface in later `snapshot.hasCleanCheckoutToken`. |
| `comment <key> [--author A]` | Free-form evidence/review note from stdin. |
| `doctor [--fix] [--quiet] [--active-only]` | Store-native integrity findings: `SEV\|code\|task\|detail` lines + `SUMMARY\|fatal=N\|repairable=N\|warn=N\|ok=bool`. Exit 0 iff no FATAL. **`--quiet` suppresses the ADVISORY dump (WARN/REPAIRABLE), never the gate decision: every `FATAL\|` line MUST still be printed.** Without `doctor-complete` the dispatcher recomputes `ok=` from the lines it receives, so an adapter that swallows its FATALs under `--quiet` reports a clean board to `/go`'s startup gate while the verbose operator path shows the same FATAL — two tools disagreeing about one backlog. **Exit status is load-bearing**: `0` = ran, clean; `1` = ran, found FATALs (already emitted as lines); anything else = the battery COULD NOT RUN, and the dispatcher turns that into `FATAL\|doctor-unavailable` rather than silence, because absence of findings is not health. `doctor-complete` = covers the full battery (files); without it the dispatcher merges in the generic graph/git checks. |
| `sync` | Durability flush (beads: `bd export` JSONL — bd's own `export.auto` defaults to false, so this is the only thing that refreshes the mirror). Best-effort; dispatcher never fails on it. |

## Conformance

`tests/phase9-store-conformance.test.sh` is the executable spec: capabilities → idempotent init → create + duplicate-conflict → snapshot field fidelity → full lifecycle with reject loop (counter bumps, re-apply no-op) → block → read/body/materialize round-trips → update-field → typed errors → doctor protocol. An adapter that passes it (and, for `stage`, the dispatcher test) conforms.

### Concurrency

**State transitions are serialized**: only the /go orchestrator moves tasks between states, so read-modify-write counter bumps inside `transition` are acceptable, and `atomic-claim` remains an optional capability for future parallel *writers*.

**Everything else is not.** /go dispatches specialists with `parallel()`, and each one independently runs `read --materialize` and — via `clean-checkout.sh` — `log-event`. So `read`, `log-event` and `comment` **are invoked concurrently, by design**. An adapter must therefore:

- be safe under concurrent invocation of those subcommands, and
- **never block indefinitely** waiting for a backend lock. Bound the wait and exit `99` (transient); a caller can retry an error, but it cannot recover from a hang, and one stuck adapter process stalls the whole run.

A backend whose client library waits forever on lock contention (embedded Dolt behind `bd` is one) needs the adapter to impose its own wall clock.
