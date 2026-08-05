# acf-whip Task-Store Adapters — Architecture & Authoring Guide

How the pluggable task-store layer works. The normative spec (subcommand semantics, JSON
shapes, exit codes) is [`CONTRACT.md`](./CONTRACT.md); this document explains the machinery
around it and how to build a backend of your own.

## Architecture

```
/task, /go workflows · skills (whip-move, clean-checkout, doctor) · operator
        │  task references are STEMS (never file paths)
        ▼
skills/lib/bin/acfw-store                     ← dispatcher
  resolve backend → locate adapter → export env → exec
  compensate: enrich raw snapshots · commit --stage deliverables · merge doctor reports
        │
        ├── adapters/files/acfw-store-files       (default; shim over the 3.0.x engines)
        ├── adapters/beads/acfw-store-beads       (bd issue tracker, embedded Dolt)
        ├── adapters/multica/acfw-store-multica   (multica server, via CLI)
        ├── adapters/linear/acfw-store-linear     (Linear workspace, GraphQL)
        └── <repo>/.acfwhip/adapters/acfw-store-<x>   (your backend — no fork)
```

Two truths anchor the design:

- **The store owns task state. Git owns integration state.** The LP-CAS ledger
  (`.acfwhip/integrated/<shard>/<key>.json` in the trunk tree) is the sole integration oracle on
  every backend — adapters never see, store, or fake it. The dispatcher merges ledger facts into
  snapshots so the scheduler gets one coherent picture.
- **One sequential writer.** The `/go` orchestrator serializes all state writes. Adapters may rely
  on this: read-modify-write counter bumps are legal; no locking is required of the adapter.

## Dispatcher mechanics

| Concern | Resolution (first match wins) |
|---|---|
| Backend | `ACFW_STORE` env → `ACFW_STORE=` key in config → `files` |
| Config file | `ACFW_CONFIG_FILE` env → `<repo>/.acfwhip/config` → `<repo>/.backlog/.acfw-config` (legacy) |
| Adapter executable | `$ACFW_STORE_ADAPTER_PATH` (colon-separated dirs) → `<repo>/.acfwhip/adapters/` → `<plugin>/adapters/<backend>/` → `$PATH` — named `acfw-store-<backend>` |
| Run lock | files: `.backlog/.acfw-run.json` · non-files: `.acfwhip/run/acfw-run.json` (gitignored) |

Every adapter invocation receives the env contract: `ACFW_TRUNK_ROOT`, `ACFW_TRUNK_BRANCH`,
`ACFW_STORE_CONFIG`, `ACFW_CONTRACT_VERSION=1`, `ACFW_PLUGIN_LIB` (bash adapters may source
`acfw-git.sh` from it). Backend-native env (`BD_*`, `MULTICA_*`, `LINEAR_API_KEY`, …) passes
through untouched — credentials live in the operator's shell, never in the repo.

`acfw-store info` prints the resolved picture (`{"store","configFile","adapter","runLock",
"contractVersion"}`) — the workflows call it once at bootstrap; it is also the first thing to
check when a backend misbehaves.

**Exit codes** (uniform across dispatcher and adapters): `0` ok/idempotent no-op · `2` usage ·
`3` not found/ambiguous · `4` conflict (duplicate key) · `5` backend unavailable · `6` auth ·
`7` invalid state/value · `8` policy refusal · `99` transient (retryable).

## Capability compensation

Adapters declare capability flags via `capabilities`; the dispatcher probes them lazily (at most
once per call) and fills the gaps, so a minimal adapter still yields full whip behavior:

| Missing capability | Dispatcher compensation |
|---|---|
| `snapshot-enriched` | Raw snapshot (`"raw":true`) is piped through `acfw-enrich-snapshot.sh`: adds `trunkSha`, `hasIntegratedAt` (LP-CAS ledger lookup), `hasWorktreeBranch`, `worktrees[]`, `isCodeMutating`, `ageHours`, and recomputes the integrated/terminal count model |
| `stage` | `transition --stage PATH` deliverables are validated (repo-relative, no `..`, never `.backlog/`/`.acfwhip/`) and committed to trunk by the dispatcher (`task: <stem> deliverables`) before the adapter transition runs — deliverables are repo-tree artifacts and must land in git no matter where state lives |
| `doctor-complete` | Adapter's store-native findings (if it has `doctor` at all) are merged with the generic battery (`acfw-doctor-generic.sh`: dependency graph, duplicate ids, worktree/git invariants — computed from the enriched snapshot) into one report with a recomputed `SUMMARY\|` line |
| `sync` | Skipped silently (durability flush is best-effort by contract) |

The `store` field in snapshots is always injected by the dispatcher — adapters must not emit it.

## Data flow on non-files backends

**Snapshot → scheduler.** `acfw-store snapshot` = adapter emits the raw BacklogSnapshot (per-task
`stem/folder/deps/slug/counters/...` from its backend) → dispatcher injects `store` and enriches
with git facts → the pure-JS scheduler in `whip-go.workflow.js` partitions by worktree slug and
gates on dependencies exactly as on files. Readiness is always computed whip-side; no backend's
native "ready"/"blocked" logic is trusted.

**Transition → audit.** Every state write goes through `acfw-store transition <stem> <state>
[AGENT] [NOTES] [RINC] [BINC]` — same positional tail on every backend. The adapter applies the
state change idempotently, bumps rejection/block counters when told, and appends the transition
row to its audit medium (files: the Transition Log table; beads/multica/linear: a comment).

**Materialize → review.** Specialists and reviewers need a task *document*. On files that is the
real `.backlog/<state>/<stem>.md`; elsewhere `acfw-store read --materialize .acfwhip/specs`
renders one: current metadata bullets + body + **`## Store Audit Trail`** (every `log-event` row
and `comment`, verbatim, oldest-first). The audit trail is load-bearing — the quality reviewer's
auto-reject greps the refreshed document for the `| clean-checkout | ok |` token that
`clean-checkout-before-task` recorded via `log-event`. An adapter that drops stored events breaks
review on its backend. Evidence and review notes flow back through `acfw-store comment`; `/task`
authors new tasks into `.acfwhip/staging/` and the single writer ingests them via
`acfw-store create`.

## Shipped backends compared

| | `files` (default) | `beads` | `multica` | `linear` |
|---|---|---|---|---|
| State lives in | `.backlog/<state>/*.md` on trunk | `bd` embedded Dolt, whip states as custom statuses | `whip_state` issue metadata (native status = display projection) | `whip_*` metadata on one attachment per issue (native status = display projection) |
| Key resolution | filename stem | deterministic id `whip-<stem>` | server-side `whip_key` metadata filter | attachment URL `https://acfw.fib7.ai/<ns>/<stem>` via `attachmentsForURL` |
| Task document | the file itself | issue description | issue description | issue description |
| Audit trail | Transition Log table in-file | `bd` comments | comments | comments |
| Dependencies | `Dependencies:` field | `whip_deps` + native edges (cycle-checked) | `whip_deps` (no dependency API) | `whip_deps` + best-effort native `blocks` relations |
| `commitsToGit` | true (`stage`, `doctor-complete`, `snapshot-enriched`) | false | false | false |
| Prerequisites | none | cgo-enabled `bd` on PATH (see [beads/README.md](./beads/README.md) — currently needs a build from beads `main`) | `multica` CLI + `MULTICA_SERVER_URL`/`MULTICA_TOKEN`/`MULTICA_WORKSPACE_ID` | `curl`+`jq` + `LINEAR_API_KEY`/`ACFW_LINEAR_TEAM` |

Details per backend: [`files/`](./files/) · [`beads/README.md`](./beads/README.md) ·
[`multica/README.md`](./multica/README.md) · [`linear/README.md`](./linear/README.md).

## Writing your own adapter

1. **One executable, any language**, named `acfw-store-<backend>`. Implement the five required
   subcommands (`capabilities`, `snapshot`, `read`, `create`, `transition`) per
   [`CONTRACT.md`](./CONTRACT.md); add optional ones behind capability flags as your backend allows.
2. **Pick your state doctrine.** If the backend has no free-form task state (most trackers),
   copy the multica/linear pattern: store whip-canonical state in backend metadata as the single
   source of truth and project it onto native status for display; the doctor repairs native status
   *from* whip state, never the reverse. Write the join key **last** on create so a half-created
   record is invisible (crash-safe).
3. **Honor the invariants that bite:** duplicate `create` is exit 4, never an upsert · dependency
   tokens may name not-yet-created keys — record and report them verbatim · `read --materialize`
   MUST include the stored audit trail · counters are JSON numbers · transitions are idempotent
   (`noop:`, exit 0, no bumps).
4. **Drop it in** at `<repo>/.acfwhip/adapters/acfw-store-<backend>` (commit it) or on `$PATH`,
   set `ACFW_STORE=<backend>` in `.acfwhip/config` — no fork, no dispatcher change.
5. **Prove it**: `ADAPTER=<path> bash tests/phase9-store-conformance.test.sh` (36 assertions) is
   the executable spec — an adapter that passes it, conforms. `tests/phase9-dispatcher.test.sh`
   covers the compensation paths. The linear adapter's test shows how to conformance-test an
   HTTP backend offline via an injectable transport.

Shell adapters must stay bash-3.2-clean (macOS: no `declare -A`); `jq` is an accepted dependency
for non-files adapters (exit 5 with a clear message when missing).
