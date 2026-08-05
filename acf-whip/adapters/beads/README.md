# acfw-store-beads — the beads (`bd`) task-store adapter

An acf-whip **task-store adapter** (store contract v1) that keeps backlog task
state in a [beads](https://github.com/steveyegge/beads) **embedded Dolt** database
under `<repo>/.beads/` instead of git-tracked markdown. It implements the contract in
[`../CONTRACT.md`](../CONTRACT.md); the reference adapter is
[`../files/acfw-store-files`](../files/acfw-store-files).

Select it per-repo with `ACFW_STORE=beads` in `<repo>/.acfwhip/config`, or point
the dispatcher at it directly:

```sh
ADAPTER=adapters/beads/acfw-store-beads bash tests/phase9-store-conformance.test.sh
```

## Why beads, and what changes

The `files` backend commits every state change to trunk as a markdown-file move.
The `beads` backend writes to a local Dolt db, so **`commitsToGit` is false** —
state writes produce no trunk commits. The LP-CAS integration ledger
(`.acfwhip/integrated/`) stays git-native and is *not* this adapter's concern;
the dispatcher enriches raw snapshots with the git-derived facts. whip's scheduler
still owns scheduling: this adapter deliberately **bypasses bd's native
ready/claim** machinery and drives beads purely through statuses.

## Model mapping

**Key ↔ id — a deterministic bijection.** The whip key (task stem) maps to the bd
issue id `"<prefix>-<key>"`, where `<prefix>` is `ACFW_BEADS_PREFIX` (default
`whip`). No lookups: `read feature-001` → `bd show whip-feature-001`.

**State — custom statuses are the single source of truth.** `init` configures
`status.custom` so each whip state has a 1:1 bd status:

| whip state    | bd status     | category |
|---------------|---------------|----------|
| `pending`     | `open`        | built-in |
| `in-progress` | `in_progress` | built-in |
| `blocked`     | `blocked`     | built-in |
| `completed`   | `completed`   | custom (wip) |
| `in-review`   | `in_review`   | custom (wip) |
| `accepted`    | `accepted`    | custom (done) |
| `rejected`    | `rejected`    | custom (active) |
| `draft`       | `draft`       | custom (frozen) |
| `archive`     | `closed`      | built-in |

An unrecognized bd status maps to the folder `unknown` (the task is kept, never
silently dropped).

**Fields.** Priority ↔ bd int (`blocker`=0, `critical`=1, `high`=2, `medium`=3,
`low`=4; unknown → 2). Assigned agent ↔ bd assignee. Title ↔ bd title. The whole
task-document markdown ↔ bd description. Everything bd has no native column for
rides in issue **metadata** (never `bd:`/`_`-prefixed):

| metadata key | holds |
|---|---|
| `whip_key` | the task stem (identity marker; only issues carrying it are whip tasks) |
| `whip_worktree` | worktree slug |
| `whip_pr_group` | PR group |
| `whip_touches` | touches-globs (comma-joined) |
| `whip_deps` | dependency stems (comma-joined) — the scheduler's source of truth |
| `whip_rejections` / `whip_blocks` | counters (numeric; stored as strings by `bd`, coerced on read) |
| `whip_last_transition_ts` | `YYYY-MM-DD HH:MM:SS` UTC |

Transition audit rows and the `clean-checkout | ok` token are appended as bd
**comments**; `snapshot.hasCleanCheckoutToken` is a substring match over them.

## Capabilities

```json
{"backend":"beads","contractVersion":1,"commitsToGit":false,
 "capabilities":["snapshot","read","create","transition","update-field",
                 "update-body","log-event","comment","doctor","doctor-fix","init","sync"]}
```

No `snapshot-enriched` (the dispatcher merges git facts into the `"raw":true`
snapshot), no `stage` (the dispatcher commits deliverables to trunk itself), no
`doctor-complete` (the dispatcher merges in the generic graph/git checks).

## Requirements

- **`bd`** on `PATH`, **cgo-enabled** — the embedded Dolt engine sits behind a `cgo`
  build tag, and a `CGO_ENABLED=0` binary cannot open the database at all
  (`embedded Dolt requires CGO`). Official release binaries are cgo-enabled except
  windows-arm64, freebsd-amd64 and android-arm64. Missing `bd` → exit 5; a non-cgo
  `bd` → exit 5 from `init` with the build command to fix it.
- **A beads build from `main`** — see *Version floor* below. Missing → exit 5.
- **`jq`** on `PATH`. Missing → exit 5.
- **bash 3.2** clean (no `declare -A`) — runs under stock macOS `/bin/bash`.

### Version floor

The adapter needs two `bd` features, and one of them is **not in any released
beads**:

| Feature | Used for | Released? |
|---|---|---|
| `bd init --backend=dolt` | selecting the storage engine | yes — accepted by v1.0.4, v1.1.0 and `main` |
| `bd config set status.custom` | the whip state vocabulary | yes — v1.0.4+ |
| `bd create --status` | creating a task directly in its target state | **no** — added 2026-07-05, post-v1.1.0 |

So today this adapter requires a `bd` built from beads `main`:

```sh
CGO_ENABLED=1 go build -tags gms_pure_go -o /usr/local/bin/bd ./cmd/bd
```

Note what this replaced: the adapter previously ran `bd init --backend=sqlite`,
which **every released `bd` rejects** (v1.0.4 errors after a deprecation notice,
v1.1.0 returns `--backend=sqlite is no longer supported`). Beads removed SQLite in
v0.58.0 and has defaulted to Dolt since v0.50.0.

## Concurrency

**Embedded Dolt is single-writer, enforced by a file lock — and reads take it too.**
Every `bd` invocation serializes against every other one in the same repo.

The contract ([`../CONTRACT.md`](../CONTRACT.md)) serializes *state transitions*,
but `read --materialize`, `log-event` and `comment` are invoked **concurrently** by
parallel specialists (`/go` dispatches them with `parallel()`, and each one's
`clean-checkout.sh` records its token through the store).

⚠️ **Known limitation.** `bd` waits for that lock with *unbounded* backoff against a
context with no timeout, so a contended second `bd` process **blocks indefinitely
rather than erroring**. The `database is locked` retry below cannot fire for this
case, and `clean-checkout.sh`'s `|| WARN` guard catches a non-zero exit but not a
hang. On a wide `/go` run this can stall the run.

If a run appears frozen on the beads backend: check for stale `bd` processes
(`pgrep -fl bd`), kill them, and use `bd doctor --fix` to clear a stale lock. The
durable fix — a wall-clock timeout inside the adapter mapping to exit 99 — is not
yet implemented.

## Environment

Standard dispatcher contract (`ACFW_TRUNK_ROOT`, `ACFW_TRUNK_BRANCH`,
`ACFW_STORE_CONFIG`, `ACFW_CONTRACT_VERSION`, `ACFW_PLUGIN_LIB`) plus
`ACFW_BEADS_PREFIX` (issue-id prefix; default `whip`). Direct invocation works
too — env falls back to `git rev-parse --show-toplevel`. Every `bd` runs from the
repo root (bd discovers `.beads/` from cwd, and its `-C` flag refuses a not-yet-
initialized dir), so `--file`/`--materialize` paths are resolved against the
caller's original cwd.

## Testing

```sh
# Conformance (the frozen spec) against a specific bd:
PATH=/path/to/bd-dir:$PATH \
  ADAPTER="$PWD/adapters/beads/acfw-store-beads" \
  bash tests/phase9-store-conformance.test.sh

# Full wrapper: conformance + beads-specific checks. Skips cleanly (exit 0) when
# no capable bd is available and none can be built. Override the build source:
ACFW_BEADS_SRC=/path/to/beads/checkout bash tests/phase9-adapter-beads.test.sh
```

The wrapper resolves a *capable* bd (a cached build → a fresh
`CGO_ENABLED=1 go build -tags gms_pure_go` from the checkout → a feature-probed
`PATH` bd). The build **must** be cgo-enabled or the resulting binary cannot open
embedded Dolt. `ACFW_BEADS_SRC` has no default: without it the test skips.

## Design notes / deviations

- **Duplicate `create` → exit 4 via a pre-check.** `bd create --id X` *silently
  upserts* an existing id (verified against v1.1.0), so the adapter probes
  `bd show` first and refuses when it succeeds. It never calls `create` on a live
  id.
- **Dependencies live in `whip_deps` metadata, with native bd edges as a
  best-effort secondary index.** The scheduler reads deps from `whip_deps` (mirrors
  how the files backend reads the `Dependencies` bullet). Native `bd dep add` edges
  are maintained too (so `bd dep list` / bd graph tooling work), but they require
  the target issue to already exist — a dependency on a not-yet-created task (or a
  phantom reference) is recorded in `whip_deps` only, never lost. A genuine
  dependency **cycle** during create is a hard error (exit 7).
- **`read --materialize` renders the audit trail.** The materialized document is
  the description with its metadata bullets refreshed from live bd fields, followed
  by a `## Store Audit Trail` section listing every stored comment verbatim,
  oldest-first (`bd show` omits comments, so they're fetched via `bd comments
  --json`). This is load-bearing, not cosmetic: `log-event` records the
  `clean-checkout | ok` token as a bd comment, and the quality-reviewer's
  auto-reject greps the refreshed spec for it — without the trail every review
  would auto-reject (contract §`read`).
- **Idempotent `init`, with bd's repo side effects suppressed.** `bd init` runs only
  when `.beads/` is absent (re-init aborts non-zero); `config set status.custom` is
  re-affirmed every time. The call is
  `bd init --backend=dolt --prefix <p> -q --non-interactive --skip-hooks --skip-agents`:
  - `--skip-hooks` is **load-bearing, not hygiene**. Without it bd installs hooks into
    `.beads/hooks/` and sets repo-wide `core.hooksPath` — which lives in `.git/config`
    and is therefore **shared by every git worktree**. Every commit whip makes would
    then spawn a `bd` hook contending for the same single-writer Dolt lock, and the
    hook can stage `.beads/issues.jsonl` into a pending commit, making LP-CAS
    candidates depend on the environment rather than on the branch tree.
  - `--skip-agents` stops bd writing `AGENTS.md`, `CLAUDE.md` and
    `.claude/settings.json` into the host repo.
  - All three flags exist in bd v1.0.4 through `main`, so they are passed unconditionally.
- **`init` refuses a dirty index (exit 8).** `bd init` finishes with a bare
  `git commit --no-verify` and **no pathspec**, so it commits the whole index —
  anything staged at the time would be swept into a `bd init:` commit. The adapter
  refuses instead. `bd init` still creates one commit of its own and appends to the
  project `.gitignore`; that is expected.
- **`doctor`** asserts `bd` reachable, `.beads/` present, `status.custom` exactly
  as expected (FATAL on drift), and per-task id↔key bijection + numeric counters;
  emits the `SEV|code|task|detail` + `SUMMARY|…` protocol and exits 0 iff no FATAL.
- **Retry.** bd calls retry 3×/1 s on a lock failure, then exit 99. The matcher
  mirrors bd's own `isLockError` — `database is locked`, `locked by another dolt
  process`, `noms lock`, `lock file` — plus the MySQL codes server mode surfaces
  (`deadlock found`, `lock wait timeout exceeded`). Dolt's server-mode string is
  `database "<name>" is locked by another dolt process`, with the db name in the
  middle, so a plain `database is locked` substring test misses it. See
  *Concurrency* above for the case retrying cannot cover.
- **`sync` is the only JSONL refresh.** bd's `export.auto` defaults to `false`, so
  `.beads/issues.jsonl` is written only by an explicit `acfw-store sync`. Nothing in
  acf-whip calls `sync` today, so the mirror is opt-in and the working tree stays
  clean during a run.
