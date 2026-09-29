# acf-whip Task-Store Adapter Contract (v1)

acf-whip's task store is pluggable. An **adapter** is one executable named
`acfw-store-<backend>` that implements the subcommands below. The dispatcher
(`skills/lib/bin/acfw-store`) resolves the active backend, finds the adapter, exports the
environment contract, and fills in for optional capabilities the adapter lacks.

**Shipped adapters**: `files` (default, `.backlog/` folders in git), `beads`, `multica`, `linear`.

This document is the normative spec. For the architecture, dispatcher mechanics, capability
compensation, data-flow walkthroughs, and a guide to writing your own adapter, see `adapters/README.md`.

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

**Dispatcher-implemented flags** (consumed by `skills/lib/bin/acfw-store`, never forwarded to an adapter):

`snapshot --only <key>` (repeatable) narrows the emitted view to the **closure** of the named tasks:
the seeds plus every dependency that is not accepted-terminal. A five-task run relays five records
instead of the whole board. `snapshot --full-to FILE` tees the pre-narrowing snapshot to a file, so
the scheduler and the doctor read one store walk instead of two; on a live shared board, two walks
can straddle someone else's transition. The dispatcher implements both once, over the final
enriched JSON.

`--full-to` only matters for an adapter **without** `doctor-complete`, because the file exists to
feed the generic battery. An adapter that owns its whole doctor never reads it: `files` declares
both `doctor-complete` and `snapshot-enriched`, so `acfw-store doctor` execs the adapter, which walks
the store itself and takes no snapshot. On a `snapshot-enriched` adapter the tee happens only when
the call did not narrow. Once the adapter has applied `--digest`/`--only` itself there is no
pre-narrowing form left to write, and writing a narrowed file would silently hand the battery a
partial graph. `doctor --snapshot FILE` refuses a narrowed or digest snapshot for the same reason.

`--only` reaches an adapter **only** when it declares `snapshot-only`. A raw adapter must keep listing
everything: the closure walk and the store-wide `counts` are computed from the full set, and
narrowing at the adapter would make both wrong without any error. Declare `snapshot-only` only if you
also own `snapshot-enriched` and can resolve seeds against states your enriched output no longer
contains. The `files` scanner can: its digest collapses terminal-accepted tasks, so it has to keep a
seed that names one, or the caller is told their id does not exist.

Seed resolution order is **exact `id` → exact `stem` → exact `backendId` → unique stem prefix**. An
ambiguous prefix is reported in `scope.ambiguous` with its candidates and never resolved by first
match, because on a large board first match silently picks whichever card was listed first.

`doctor --snapshot FILE` reuses a snapshot the caller already holds instead of taking a second one.
Without it, every `doctor` on a backend without `doctor-complete` enumerates the store twice: once in
the adapter's own battery and once for the generic graph battery. The file must be a **full**
snapshot. One carrying `scopeApplied: true` or `digest: true` is refused with a typed usage error
(exit 2, no report line), because `dangling-dep`, `cyclic-deps`, `duplicate-id` and
`cross-slug-dep-not-integrated` are whole-graph properties: computed over a subset, they return a
confidently green report while two worktrees race. The refusal is deliberately not a finding, so a
caller cannot read it as "the board is fine".

JSON results go to stdout (exactly one object), diagnostics to stderr. Two non-JSON line protocols are part of the contract where noted: `ok:`/`noop:`/`warn:` for transition, and `SEV|code|task|detail` + `SUMMARY|` for doctor.

**Environment** (set by the dispatcher; adapters must also work when invoked directly, falling back to `git rev-parse --show-toplevel`):

| Var | Meaning |
|---|---|
| `ACFW_TRUNK_ROOT` | absolute repo root |
| `ACFW_TRUNK_BRANCH` | trunk branch name (may be empty) |
| `ACFW_STORE_CONFIG` | resolved config file path (may be empty/absent) |
| `ACFW_INTEGRATION_MODE` | `override`, `default`, or empty (unpinned): whether the operator owns integration. Most adapters can ignore it, since the dispatcher already passes `--mode` to `snapshot`. It is exported so the git-side batteries (`acfw-doctor-generic.sh`) resolve the same value the orchestrator schedules under. Added in 3.2.1; additive, so `ACFW_CONTRACT_VERSION` is still `1`. |
| `ACFW_CONTRACT_VERSION` | `1` |
| `ACFW_PLUGIN_LIB` | absolute path of `skills/lib/` (bash adapters may source `acfw-git.sh`) |

Backend-specific env (`BD_*`, `ACFW_BEADS_*`, `MULTICA_*`, …) passes through untouched.

**Exit codes**: `0` ok / idempotent no-op · `2` usage · `3` not found / ambiguous · `4` conflict (duplicate key) · `5` backend unavailable · `6` auth · `7` invalid state or value · `8` policy refusal · `99` transient: backend locked, or timed out waiting for it (caller may retry).

## Task model

- **Key** = the task *stem* (`feature-001-yaml-processor`). Caller-supplied, stable, kebab-safe. It names the LP-CAS ledger marker and is the only task reference in the contract. Adapters may accept a unique prefix; ambiguity is exit 3.
- **States** (whip-canonical): `draft`, `pending`, `in-progress`, `completed`, `in-review`, `accepted`, `rejected`, `blocked`, plus `archive`. Adapters map these to native backend states however they like; `snapshot`/`read` always report the whip-canonical name. A state outside this list is **quarantine, not corruption**. The scheduler dispatches on exact state equality, so a task in a state it does not name is inert: it can never be dispatched, transitioned or integrated, and cannot make a run wrong. Report it as `WARN`, never `FATAL`; a gate-blocking finding there aborts a whole board over one inert card. The same reasoning sets the severity of structural defects in general. `accepted` (terminal), `draft` (the human gate) and `archive` (retired) are **out of the dispatch path**, so defects there are advisory; every other state gates.
- **Body** = the task document markdown as the backend stores it (files: the whole file; beads/multica: the issue description). `create` ingests a full task document with `- **Field**: value` metadata bullets; adapters parse the fields they map natively.
- **Integration state is not the adapter's business.** The LP-CAS ledger (`.acfwhip/integrated/` in the git tree) stays git-native; the dispatcher merges `hasIntegratedAt` and integration counts into snapshots for adapters without `snapshot-enriched`.

## Required subcommands

### `capabilities`
```json
{"backend":"<name>","contractVersion":1,"commitsToGit":<bool>,"capabilities":["snapshot","read","create","transition",...]}
```
Capability flags: `snapshot-enriched`, `snapshot-only`, `stage`, `update-field`, `update-body`, `log-event`, `comment`, `doctor`, `doctor-fix`, `doctor-complete`, `init`, `sync`, `atomic-claim`, `token-all-states`. Two need more than their name:

- **`token-all-states`**: `snapshot.hasCleanCheckoutToken` is answered for every task state. Declare it when the answer is free (multica reads it out of the description it already fetched). Withhold it when each answer costs a request and you limit the paid set to the states where a wrong answer costs something now (`in-progress`, `completed`, `in-review`), as linear does. The declaration is how a consumer tells "no token" from "not scanned". Without it the dispatcher sets `"tokenAllStates": false` on the snapshot and the generic doctor suppresses its accepted-without-token WARN, which would otherwise stand permanently against every finished task.
- **`snapshot-only`**: the adapter implements `--only` itself. Declare it only alongside `snapshot-enriched`, and only if you can resolve seeds against states your enriched output no longer contains. Otherwise let the dispatcher narrow; it does that for every raw adapter at no cost to you.

`commitsToGit` = state writes produce trunk commits (files: true).

### `snapshot [--digest] [--counts-only] [--mode default|override]`
One BacklogSnapshot JSON object. Adapter-owned fields per task: `stem`, `id`, `folder` (whip state), `status`, `slug` (worktree), `agent`, `priority`, `deps[]` (stems), `touchesGlobs[]`, `rejectionCount` (number), `blockCount` (number), `lastTransitionTs` (`YYYY-MM-DD HH:MM:SS` UTC), `hasCleanCheckoutToken` (bool), plus top-level `counts{<state>:n,...}` and `generatedAt`. `--digest`/`--counts-only`/`--mode` may be treated as hints (a full snapshot is always acceptable).

An entry MAY carry `"slim": true` to mark it a **dependency-resolution stub** rather than a task
record. The `files` scanner emits terminal accepted tasks this way: it keeps only what
`depsSatisfied` reads (`folder`, `slug`, `hasIntegratedAt`, `hasWorktreeBranch`, counts) and drops
the rest, so a lived-in backlog's payload stays small enough for an agent to echo verbatim. A consumer
checking per-task invariants MUST skip slim entries. Every dropped field reads as absent, so a slim
accepted task would otherwise draw a standing `missing-clean-checkout-token` WARN for a token it has.
Dependency resolution MUST still see them.

**`tasks[]` is the active working set**: the seven states the scheduler can act on (`pending`,
`in-progress`, `completed`, `in-review`, `blocked`, `rejected`, `accepted`). `draft` and `archive`
belong in a sibling **`inactive[]`** array of the same shape. An adapter may list everything in
`tasks[]` and let the dispatcher's enricher do the split, but an adapter with `snapshot-enriched`
owns the split, because nothing downstream will do it. The split matters in three places:

- a scoped run counts `tasks[]` as its completion denominator, and `isTerminal` is false for both
  inactive states, so a draft in `tasks[]` makes `terminal === total` unreachable;
- the per-task doctor battery raises findings against every entry;
- `inactive[]` is still unioned into the dependency index, so a task depending on a draft reports
  `WARN|dep-inactive` (gated, with the remedy) instead of `FATAL|dangling-dep`, which would be false:
  the dep exists.

Adapters **without** `snapshot-enriched` emit `"raw":true` and omit git-derived facts (`trunkSha`, `hasIntegratedAt`, `hasWorktreeBranch`, `worktrees[]`, `isCodeMutating`, `ageHours`, integrated/terminal counts); the dispatcher fills them in. Adapters must **not** emit `store`; the dispatcher injects it. The `files` snapshot (see `skills/go/bin/scan-backlog.sh`) is the reference shape.

#### `relay{}`: proving the payload arrived whole

Every snapshot the dispatcher emits leads with a `relay` header. It comes after the two keys the
dispatcher injects (`store`, `tokenAllStates`) and always before `tasks[]`:

```json
{"relay":{"n":12,"tasks":9,"inactive":1,"sat":2,"bytes":214}, ...}
```

`n` is the total entry count across `tasks`/`inactive`/`satisfiedDeps`, the three named fields are the
per-array counts, and `bytes` is the sum of the UTF-8 byte lengths of every `stem` in them.

The header is there because a script produces the snapshot but an agent **delivers** it: `/go`'s
shell-runner reads the store walk's stdout and copies it into one schema string. That echo can come
back short, as valid JSON with fewer tasks, and a shortened board looks exactly like a small one.
The consumer recomputes both numbers and refuses a mismatch. A count alone is forgeable by a model
that tidies a header it can see; the byte sum is a second number, derived from the content. With the
header ahead of `tasks[]`, an echo that loses its tail still carries the expectation it fails.

The check proves no entry was dropped, added, or replaced by one with a different stem length. It
does **not** prove stem identity: an equal-length substitution passes. That is deliberate. A length
sum is the strongest check jq, bash and JS can all compute identically and cheaply, and truncation
has been seen in practice where substitution has not.

Who emits it:

- A raw adapter emits nothing here; the dispatcher's post-stage adds the header.
- Every backend acf-whip ships produces the header (the raw ones through the dispatcher), so on
  `files`, `beads`, `multica` or `linear` the orchestrator treats a **missing** header as a relay
  failure too. A model that drops entries is at least as likely to drop a header it does not
  understand as to recompute one.
- A third-party adapter with `snapshot-enriched` SHOULD emit it. If it doesn't, the consumer logs
  once that completeness cannot be verified and proceeds, because refusing would break every such
  backend on upgrade.

#### `scope{}`: what a narrowed snapshot resolved

Present only when `--only` was given, alongside `"scopeApplied": true` and a `scopeCounts` computed
over the narrowed view. The store-wide `counts` is **never** narrowed: the doctor, the report and an
unscoped completion test all read it.

```json
{"scope":{"seeds":["MUL-4821"],"resolved":{"MUL-4821":"ui-021-login"},"unresolved":[],
          "ambiguous":[{"tok":"ui-021","candidates":["ui-021-login","ui-021-logout"]}],
          "inactiveSeeds":[{"stem":"doc-009","folder":"draft"}],"added":["api-014-token"]}}
```

A seed that exists but is paused or retired goes in `inactiveSeeds`, never `unresolved`: "paused" and
"does not exist" need opposite answers. `added` names the dependencies pulled into the closure. The
closure keeps every dependency that is **not accepted-terminal**, including `blocked` and `rejected`
ones. Those are retryable, and the pass that lifts them runs over the scope, so a closure that left
one out would leave it stuck for good and its dependent could never dispatch.

### `read [--body] [--materialize DIR] <key>`
```json
{"stem":"...","folder":"<whip-state>","fields":{"id":"...","status":"...","priority":"...","agent":"...","worktree":"...","pr_group":"...","touches_globs":"...","dependencies":"...","rejection_count":0,"block_count":0},"body":"..."}
```
`body` is present only with `--body`. `--materialize DIR` writes a full task document to `DIR/<key>.md` and prints that path instead of JSON. That is how specialists and `clean-checkout` get a spec file on non-files backends (files prints the real root path). A materialized document MUST contain the current metadata bullets, the body, **and the stored audit trail**: every `log-event` row and `comment`, verbatim. Adapters that already keep rows in the document (files, multica) satisfy this inline through the `## Transition Log` table; anything held outside the document is appended oldest-first under a heading of the adapter's choice (`## Store Comments`, `## Store Audit Trail`). Review depends on it: the quality-reviewer's auto-reject greps the refreshed materialized document for the `| clean-checkout | ok |` token that `log-event` recorded, wherever it lives.

### `create [--folder pending] [--file PATH | stdin] [--stem KEY] [--set Field=Value]...`
Ingest one task document. Key = `--stem` or the `--file` basename. Duplicate key → exit 4 (never upsert). `--set` overrides a metadata field after parsing (e.g. `--set 'Dependencies=a, b'`). Optional fields are honored where the backend has them natively: `parent_key`, `stage` (multica `--parent/--stage`, beads `--parent`; files ignores both). Returns `{"key":"..."}`.

### `transition [--stage PATH]... <key> <TO_STATE> [AGENT] [NOTES] [RINC] [BINC]`
The positional tail mirrors `apply-transition.sh` argument for argument. Semantics:
- **Idempotent**: already in `TO_STATE` → `noop:` line, exit 0, no counter bumps.
- Appends an audit/transition-log row. **Where** is up to the adapter: files and multica splice it into the task document's `## Transition Log` table (shared `append_log_row`: newest-first, capped, appended at EOF when the document has no table); beads and linear post it as an issue comment. Prefer the document when agents read and act on the backend's comment stream.
- `RINC=1` + `TO_STATE=rejected` bumps the rejection count; `BINC=1` + `TO_STATE=blocked` bumps the block count.
- `archive` is a legal target. Invalid state → exit 7. Unknown key → exit 3.
- `--stage PATH` (capability `stage`): co-commit repo-relative deliverable files with the state change. Refuse empty/absolute/`..`/`.backlog/`/`.acfwhip/` paths (exit 2). Adapters without `stage` never see the flag; the dispatcher commits deliverables to trunk itself first.

Output: `ok:`/`noop:`/`warn:` lines (echoed verbatim into run reports).

## Optional subcommands (capability-gated)

| Subcommand | Contract |
|---|---|
| `init` | Create/verify the store. Idempotent. Config via env. |
| `update-field <key> [--set Field=Value]... [--add-dep ID]...` | Field edits. `Dependencies` via `--set` replaces the whole list (bare comma list); `--add-dep` appends. State changes are refused (exit 2); use `transition`. Dependency tokens may name **not-yet-created keys**: adapters must record and report them verbatim, never drop them (graph-backed stores keep an out-of-graph dep record as the record of truth; the doctor, not the adapter, flags dangling deps). |
| `update-body <key>` | Replace the task document/description from stdin. Refuse empty input. |
| `log-event <key> --row "\| ... \|"` | Append one machine-greppable event row (the `clean-checkout \| ok` token). Token rules below. |
| `comment <key> [--author A]` | Free-form evidence/review note from stdin. |
| `doctor [--fix] [--quiet] [--active-only]` | Store-native integrity findings. Protocol below. |
| `sync` | Durability flush (beads: `bd export` JSONL; bd's own `export.auto` defaults to false, so this is the only thing that refreshes the mirror). Best-effort; the dispatcher never fails on it. |

### `log-event` and the clean-checkout token

A `clean-checkout | ok` row written by `log-event` must show up in later
`snapshot.hasCleanCheckoutToken` answers **in every task state, not only the review ones**. The field
is a flat per-task boolean with no state qualifier: `false` means "this task has no token", and a
consumer cannot tell a real absence from a state the adapter declined to scan. Two consumers depend on
it: the review gate auto-rejects on `false`, and the generic doctor WARNs on an accepted task without
one.

Where each answer costs a request, limit the *paid* set to the states where a wrong answer costs
something now (`in-progress`, `completed`, `in-review`) rather than narrowing the field itself, and
withhold `token-all-states`. Never pay for `accepted` coverage with an N+1 over a backlog that only
grows.

### `doctor` protocol

Output is `SEV|code|task|detail` lines plus `SUMMARY|fatal=N|repairable=N|warn=N|ok=bool`. Exit 0 iff
no FATAL. `doctor-complete` means the adapter covers the full battery (files); without it the
dispatcher merges in the generic graph/git checks.

- **Field 3 is a routing decision** (3.4.0). A task-scoped finding MUST carry the exact whip key, and
  a store- or repo-scoped one MUST carry `-` or `(repo)`. `/go` classifies on it: a repo-scoped FATAL
  aborts the run, a task-scoped one holds out only that task, and a key matching nothing in the
  snapshot is reported but gates nothing. Matching is exact. A prefix or a slug in field 3 would
  attach the finding to the wrong task, which is the one way per-task quarantine is less safe than
  aborting.
- **Never repair a human hold.** If the native status expresses a deliberate pause or cancellation
  while the whip state is runnable, report it (`WARN|native-hold|<key>|...`, naming
  `transition <key> draft`) and leave it alone. `/go` runs `--fix` at bootstrap, so a repair here
  would un-park every card the team parked, on every run. Where you can, take the signal from a
  native field that whip never writes (Linear keys on the state type `canceled`, which only
  `archive` maps to). Where the native value is one whip projects onto itself, like multica's
  `blocked`, a stale write and a human hold look identical: say so in the detail and name the
  re-sync command rather than presenting the finding as certain.
- **`--quiet` suppresses the advisory dump (WARN/REPAIRABLE), never the gate decision: every
  `FATAL|` line MUST still be printed.** Without `doctor-complete` the dispatcher recomputes `ok=`
  from the lines it receives. An adapter that swallows its FATALs under `--quiet` reports a clean
  board to `/go`'s startup gate while the verbose operator path shows the same FATAL, and the two
  tools disagree about one backlog.
- **Exit status carries meaning**: `0` = ran, clean; `1` = ran, found FATALs (already emitted as
  lines); anything else = the battery could not run. The dispatcher turns that into
  `FATAL|doctor-unavailable` rather than silence, because an empty report is not proof of health.

## Conformance

`tests/phase9-store-conformance.test.sh` is the executable spec: capabilities → idempotent init → create + duplicate-conflict → snapshot field fidelity → full lifecycle with reject loop (counter bumps, re-apply no-op) → block → read/body/materialize round-trips → update-field → typed errors → doctor protocol. An adapter that passes it (and, for `stage`, the dispatcher test) conforms.

### Concurrency

**State transitions are serialized.** Only the /go orchestrator moves tasks between states, so
read-modify-write counter bumps inside `transition` are acceptable, and `atomic-claim` remains an
optional capability for future parallel *writers*.

**Nothing else is.** /go dispatches specialists with `parallel()`, and each one runs
`read --materialize` on its own and, through `clean-checkout.sh`, `log-event`. So `read`, `log-event`
and `comment` **are invoked concurrently, by design**. An adapter must therefore:

- be safe under concurrent invocation of those subcommands, and
- **never block indefinitely** waiting for a backend lock. Bound the wait and exit `99` (transient).
  A caller can retry an error but cannot recover from a hang, and one stuck adapter process stalls
  the whole run.

A backend whose client library waits forever on lock contention (embedded Dolt behind `bd` is one)
needs the adapter to impose its own wall clock.
