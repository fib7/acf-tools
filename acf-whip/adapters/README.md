# acf-whip task-store adapters: architecture and authoring guide

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

Two rules shape the design:

- **The store owns task state. Git owns integration state.** The LP-CAS ledger
  (`.acfwhip/integrated/<shard>/<key>.json` in the trunk tree) is the sole integration oracle on
  every backend. Adapters never see, store, or fake it. The dispatcher merges ledger facts into
  snapshots so the scheduler gets one consistent picture.
- **One sequential writer, for `transition` only.** The `/go` orchestrator serializes state writes,
  so read-modify-write counter bumps inside `transition` are legal. Nothing else is serialized.
  `/go` dispatches specialists with `parallel()`, and each one runs `read --materialize` on its own
  and, through `clean-checkout.sh`, `log-event`. So `read`, `log-event` and `comment` are invoked
  concurrently by design (`CONTRACT.md`, Concurrency). An adapter must be safe under concurrent
  invocation of them and must never block indefinitely on a backend lock: bound the wait and exit
  `99`. Don't read "one sequential writer" as "no locking is ever required". That reading is how an
  unlocked read-modify-write of a shared document ends up on the `log-event` path, where a lost row
  costs a task a whole review round.

## Dispatcher mechanics

| Concern | Resolution (first match wins) |
|---|---|
| Backend | `ACFW_STORE` env → `ACFW_STORE=` key in config → `files` |
| Config file | `ACFW_CONFIG_FILE` env → `<repo>/.acfwhip/config` → `<repo>/.backlog/.acfw-config` (legacy) |
| Adapter executable | `$ACFW_STORE_ADAPTER_PATH` (colon-separated dirs) → `<repo>/.acfwhip/adapters/` → `<plugin>/adapters/<backend>/` → `$PATH`, named `acfw-store-<backend>` |
| Run lock | files: `.backlog/.acfw-run.json` · non-files: `.acfwhip/run/acfw-run.json` (gitignored) |

Every adapter invocation receives the env contract: `ACFW_TRUNK_ROOT`, `ACFW_TRUNK_BRANCH`,
`ACFW_STORE_CONFIG`, `ACFW_CONTRACT_VERSION=1`, `ACFW_INTEGRATION_MODE` (the resolved
`default`/`override` pin), `ACFW_PLUGIN_LIB` (bash adapters may source `acfw-git.sh` from it).
Backend-native env (`BD_*`, `MULTICA_*`, `LINEAR_API_KEY`, …) passes through untouched, so
credentials live in the operator's shell and never in the repo.

`acfw-store info` prints the resolved configuration. The workflows call it once at bootstrap and
both skills branch on it, so it is also the first thing to check when a backend misbehaves:

```json
{"store","configFile","adapter","runLock","integrationMode","bareGo","focusFile","focusCount",
 "models":{"shell","judge","author"},"efforts":{"shell"},"contractVersion"}
```

`bareGo` is what a bare `/go` does when no focus is set (`all` on `files`, `refuse` on every shared
API-backed store). `focusFile`/`focusCount` are the per-checkout run focus. `models` and `efforts`
are the per-tier routing a project pins once in `.acfwhip/config`. An adapter supplies none of these;
the dispatcher resolves them. A third-party adapter author reads this list to know what callers
already have without asking the backend.

**Exit codes** (the same for dispatcher and adapters): `0` ok/idempotent no-op · `2` usage ·
`3` not found/ambiguous · `4` conflict (duplicate key) · `5` backend unavailable · `6` auth ·
`7` invalid state/value · `8` policy refusal · `99` transient (retryable).

## Capability compensation

Adapters declare capability flags via `capabilities`. The dispatcher probes them lazily (at most
once per call) and fills the gaps, so a minimal adapter still gets full whip behavior:

| Missing capability | Dispatcher compensation |
|---|---|
| `snapshot-enriched` | Raw snapshot (`"raw":true`) is piped through `acfw-enrich-snapshot.sh`: adds `trunkSha`, `hasIntegratedAt` (LP-CAS ledger lookup), `hasWorktreeBranch`, `worktrees[]`, `isCodeMutating`, `ageHours`, and recomputes the integrated/terminal count model |
| `stage` | `transition --stage PATH` deliverables are validated (repo-relative, no `..`, never `.backlog/`/`.acfwhip/`) and committed to trunk by the dispatcher (`task: <stem> deliverables`) before the adapter transition runs. Deliverables are files in the repo tree and must land in git no matter where state lives |
| `doctor-complete` | Adapter's store-native findings (if it has `doctor` at all) are merged with the generic battery (`acfw-doctor-generic.sh`: dependency graph, duplicate ids, worktree/git invariants, computed from the enriched snapshot) into one report with a recomputed `SUMMARY\|` line |
| `sync` | Skipped silently (the durability flush is best-effort by contract) |

The dispatcher always injects the `store` field in snapshots; adapters must not emit it.

## Data flow on non-files backends

**Snapshot → scheduler.** `acfw-store snapshot` = adapter emits the raw BacklogSnapshot (per-task
`stem/folder/deps/slug/counters/...` from its backend) → dispatcher injects `store` and enriches
with git facts → **narrows and collapses** (`acfw-scope-snapshot.sh`: `--only` closure, real
`--digest`, the `relay` header) → the pure-JS scheduler in `whip-go.workflow.js` partitions by
worktree slug and gates on dependencies exactly as on files. Readiness is always computed on the
whip side; no backend's native "ready"/"blocked" logic is trusted.

**Why the dispatcher does the narrowing (3.4.0).** A script produces the snapshot, but an agent
delivers it: `/go`'s shell-runner copies the store walk's stdout into one schema string. So the
payload has to fit what a model will echo reliably. `--digest` was a documented no-op on every raw
adapter, so a lived-in board relayed every card it had, and a short echo is valid JSON that looks
exactly like a smaller board. Both halves of the fix live here rather than in each adapter. A raw
adapter keeps listing everything, because the closure walk and the store-wide counts need the full
set. The dispatcher narrows once, for every backend, and states what it emitted. An adapter opts out
only by declaring `snapshot-only`, which means "I resolve seeds myself, including against states my
own output no longer contains".

**Transition → audit.** Every state write goes through `acfw-store transition <stem> <state>
[AGENT] [NOTES] [RINC] [BINC]`, with the same positional tail on every backend. The adapter applies
the state change idempotently, bumps rejection/block counters when told, and appends the transition
row to its audit medium: files and multica write the Transition Log table inside the task document;
beads and linear post a comment.

**Materialize → review.** Specialists and reviewers need a task *document*. On files that is the
real `.backlog/<state>/<stem>.md`; elsewhere `acfw-store read --materialize .acfwhip/specs` renders
one: current metadata bullets, the body, and the stored audit trail (every `log-event` row and
`comment`, verbatim, oldest-first). multica's document already carries its Transition Log and
appends comments under `## Store Comments`; beads and linear append everything under
**`## Store Audit Trail`**. Review breaks without the trail: the quality reviewer's auto-reject greps
the refreshed document for the `| clean-checkout | ok |` token that `clean-checkout-before-task`
recorded via `log-event`, so an adapter that drops stored events makes every review on its backend
fail. Evidence and review notes flow back through `acfw-store comment`. `/task` authors new tasks
into `.acfwhip/run/staging/`, and the single writer ingests them via `acfw-store create`. Before
3.4.0 the staging directory was `.acfwhip/staging/`, which `whip-init` never gitignored, so every
`/task` run on a non-files backend left untracked scratch files in the consumer's tree.

## Shipped backends compared

| | `files` (default) | `beads` | `multica` | `linear` |
|---|---|---|---|---|
| State lives in | `.backlog/<state>/*.md` on trunk | `bd` embedded Dolt, whip states as custom statuses | `whip_state` issue metadata (native status = display projection) | `whip_*` metadata on one attachment per issue (native status = display projection) |
| Key resolution | filename stem | deterministic id `whip-<stem>` | server-side `whip_key` metadata filter | attachment URL `https://acfw.fib7.ai/<ns>/<stem>` via `attachmentsForURL` |
| Task document | the file itself | issue description | issue description | issue description |
| Audit trail | Transition Log table in-file | `bd` comments | Transition Log table in the issue description | comments |
| Dependencies | `Dependencies:` field | `whip_deps` + native edges (cycle-checked) | `whip_deps` (no dependency API) | `whip_deps` + best-effort native `blocks` relations |
| `commitsToGit` | true (`stage`, `doctor-complete`, `snapshot-enriched`, `snapshot-only`) | false | false | false |
| Prerequisites | none | cgo-enabled `bd` on PATH (see [beads/README.md](./beads/README.md); currently needs a build from beads `main`) | `multica` CLI + `MULTICA_SERVER_URL`/`MULTICA_TOKEN`/`MULTICA_WORKSPACE_ID` | `curl`+`jq` + `LINEAR_API_KEY`/`ACFW_LINEAR_TEAM` |

Details per backend: [`files/`](./files/) · [`beads/README.md`](./beads/README.md) ·
[`multica/README.md`](./multica/README.md) · [`linear/README.md`](./linear/README.md).

## Writing your own adapter

1. **One executable, any language**, named `acfw-store-<backend>`. Implement the five required
   subcommands (`capabilities`, `snapshot`, `read`, `create`, `transition`) per
   [`CONTRACT.md`](./CONTRACT.md), and add optional ones behind capability flags as your backend
   allows.
2. **Decide where whip state lives.** If the backend has no free-form task state (most trackers
   don't), copy the multica/linear pattern: store whip-canonical state in backend metadata as the
   single source of truth and project it onto native status for display. The doctor repairs native
   status *from* whip state, never the reverse. Write the join key **last** on create, so a
   half-created record stays invisible if the adapter crashes midway.
3. **Keep the invariants that catch adapters out:** duplicate `create` is exit 4, never an upsert ·
   dependency tokens may name not-yet-created keys; record and report them verbatim ·
   `read --materialize` MUST include the stored audit trail · counters are JSON numbers ·
   transitions are idempotent (`noop:`, exit 0, no bumps) · a clean-checkout token you could not
   read is `hasCleanCheckoutToken: null`, never `false`.
4. **Drop it in** at `<repo>/.acfwhip/adapters/acfw-store-<backend>` (commit it) or on `$PATH`, and
   set `ACFW_STORE=<backend>` in `.acfwhip/config`. No fork, no dispatcher change.
5. **Prove it**: `ADAPTER=<path> bash tests/phase9-store-conformance.test.sh` is the executable
   spec, and an adapter that passes it conforms. `tests/phase9-dispatcher.test.sh` covers the
   compensation paths. The linear adapter's test shows how to conformance-test an HTTP backend
   offline through an injectable transport.

Shell adapters must stay bash-3.2-clean (macOS: no `declare -A`). `jq` is an accepted dependency
for non-files adapters (exit 5 with a clear message when it is missing).
