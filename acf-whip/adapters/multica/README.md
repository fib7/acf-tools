# acfw-store-multica

The **multica** task-store adapter for acf-whip (store contract v1). It backs
acf-whip's backlog with a [Multica](https://multica.ai) workspace — **one Multica
issue per whip task** — by shelling out to the `multica` CLI with `--output json`.

Multica is an API backend, not a git tree, so `commitsToGit` is **false**: the
`/go` dispatcher stages code deliverables to trunk itself (this adapter has no
`stage` capability) and only the task's *state* lives in Multica.

## Canonical state model

The load-bearing idea: **whip state lives in per-issue metadata (`whip_state`);
the native Multica issue `status` is a lossy display projection of it.**

- Every read (`snapshot`, `read`) reports the **whip-canonical** state from
  `whip_state` metadata, never the native status.
- `doctor` repairs native `status` *from* `whip_state`, never the reverse.
- The join key is metadata **`whip_key`** (= the task stem). It is written
  **last** on `create`, so a crash mid-create leaves an issue with no `whip_key`
  — invisible to `resolve`/`snapshot` — which **orphans** (never duplicates) the
  task. `create` never upserts; a pre-existing `whip_key` in any state is a
  typed conflict (exit 4).
- The full task document is stored verbatim as the issue **`description`**, so
  `read --body` and `read --materialize` round-trip the spec (body parity with
  the files adapter). The structured `whip_*` metadata is the authoritative
  projection the scheduler reads.
- `read --materialize` writes the stored document, **refreshes its metadata
  bullets in place from the current `whip_*` metadata** (so the spec reflects live
  state, not the values frozen at create time), and then appends a
  **`## Store Audit Trail`** section with every stored comment verbatim
  (oldest-first). Transition rows and — crucially — the `clean-checkout` token
  (which rides a comment on this backend) live there, so the quality-reviewer's
  re-run of `read --materialize | grep '| clean-checkout | ok |'` sees the token.

### State projection (`whip_state` → native `status`)

| whip state | native status | | whip state | native status |
|---|---|---|---|---|
| draft | backlog | | in-review | in_review |
| pending | todo | | accepted | done |
| in-progress | in_progress | | rejected | todo |
| completed | in_review | | blocked | blocked |
| | | | archive | cancelled |

`completed`/`in-review` and `rejected`/`pending` collapse onto the same native
status — that collapse is exactly why `whip_state` metadata, not `status`, is the
source of truth.

### Priority projection (whip priority → native `priority`)

`blocker`→`urgent`, `critical`→`high`, `high`→`high`, `medium`→`medium`,
`low`→`low`. The verbatim whip priority is preserved in `whip_priority`.

### Metadata key schema (per issue)

`whip_key`, `whip_id`, `whip_state`, `whip_priority`, `whip_worktree`,
`whip_agent`, `whip_pr_group`, `whip_touches` (comma-joined globs),
`whip_deps` (comma-joined stems), `whip_rejections` (number), `whip_blocks`
(number), `whip_last_transition_ts`. Twelve keys, all primitive values — well
under Multica's 50-key / 8 KB per-issue limits.

Multica has **no dependency API**; `whip_deps` is a plain comma list of dependency
stems, and whip's scheduler computes readiness from the snapshot. State
transitions and counter bumps are recorded as issue **comments**
(`whip-transition | ts | from | to | agent | notes`), and the `clean-checkout`
token rides a comment too — `snapshot` greps in-review issues' comments for it.

## Environment

Native `multica` CLI variables, passed through by the dispatcher untouched:

| Var | Meaning |
|---|---|
| `MULTICA_SERVER_URL` | Multica server URL |
| `MULTICA_TOKEN` | a `mul_` PAT (**member** identity — see note) |
| `MULTICA_WORKSPACE_ID` | workspace UUID |
| `ACFW_MULTICA_PROJECT` | *(optional)* scope issues to this project id |
| `ACFW_MULTICA_BIN` | *(optional)* path to the CLI (default: `multica` on `$PATH`) |

**PAT identity note:** the adapter authenticates as a **member** via a `mul_` PAT,
which is what lets it post top-level (non-reply) audit comments. Multica rejects
top-level comments only for *agent*-identity callers running inside a
comment-triggered task; do **not** run the adapter with `MULTICA_AGENT_ID` /
`MULTICA_TASK_ID` set or a task-scoped `mat_` token in the environment.

## Capabilities

```
snapshot read create transition update-field update-body log-event comment doctor doctor-fix init
```

Deliberately **absent**: `snapshot-enriched` (snapshots are `"raw":true`; the
dispatcher fills git-derived facts), `stage` (dispatcher commits deliverables to
trunk), `doctor-complete` (dispatcher merges the generic graph/git checks), and
`sync` (nothing to flush — the server is the durable store).

`doctor` findings: **FATAL** = duplicate `whip_key`, invalid `whip_state`;
**REPAIRABLE** (`--fix`) = native-status drift (reasserts the projection),
non-numeric counters (reset to 0).

## Requirements

- The `multica` CLI on `$PATH` (or `ACFW_MULTICA_BIN`). Missing → exit 5.
- `jq`. Missing → exit 5.

Exit-code mapping (Multica CLI → contract): auth 401/403 → **6**; 404 → **3**;
400/422 → **7**; network timeout → **99**, other network → **5**; server
5xx/429 → retried up to 3× then **99**. `issue create` is **not** retried (a blind
retry could create a duplicate issue); idempotent writes (metadata/status/PUT) are.

## Known deviations from the files adapter

- **`update-body` replaces the description only.** The `whip_*` metadata
  projection is edited through `update-field`/`transition`, not re-parsed from the
  replacement body. (The files adapter, whose file *is* the fields, effectively
  re-parses.) Edit fields with `update-field`.
- **The stored description's bullets freeze at create time; metadata is the
  truth.** The stored document keeps its original `- **Status**: …` / counter
  bullets while the authoritative values move into `whip_*` metadata. `snapshot`
  and `read`'s `fields` always read metadata, so scheduling is never affected —
  and `read --body` returns the frozen document verbatim, whereas `read
  --materialize` refreshes the bullets from live metadata before writing the spec
  (see the materialize note above).

## Testing

Offline, the adapter is validated by: `bash -n`; confirming every CLI invocation
shape against the built `multica --help`; and running the full store-conformance
suite against the adapter through a **local JSON-backed fake CLI** (a scratchpad
emulator of the subcommands used — *not* an HTTP server, and not shipped).

Against a live server, the shipped wrapper drives the real conformance suite:

```sh
export MULTICA_TEST_SERVER=https://multica.example.com
export MULTICA_TEST_TOKEN=mul_...
export MULTICA_TEST_WORKSPACE_ID=<workspace-uuid>
# optional: MULTICA_TEST_PROJECT=<project-id>, ACFW_MULTICA_BIN=/path/to/multica
bash tests/phase9-adapter-multica.test.sh
```

Without those three vars it **SKIPs** (exit 0). It tears down the `conf-a`/`conf-b`
issues it creates (status→cancelled and `whip_key` deleted, so re-runs are clean).

You can also point the frozen conformance spec directly at the adapter:

```sh
ADAPTER=adapters/multica/acfw-store-multica bash tests/phase9-store-conformance.test.sh
```
