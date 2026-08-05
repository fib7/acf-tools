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
  state, not the values frozen at create time), and appends any issue comments
  verbatim (oldest-first) under **`## Store Comments`**. The audit trail itself needs
  no synthesis — it already rides the document (see below), so the quality-reviewer's
  re-run of `read --materialize | grep '| clean-checkout | ok |'` reads the same
  `## Transition Log` table it would on a files-backed task.

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
stems, and whip's scheduler computes readiness from the snapshot.

## Audit trail: the document, not the comment thread

**Transitions and `log-event` rows splice into the stored document's `## Transition
Log` table — they are not comments.** The row is built in the files-adapter shape
(`| ts | from | to | agent | notes |`) and spliced by the *shared* `append_log_row`
from `skills/lib/acfw-git.sh`, so it inherits that helper's newest-first ordering,
its `ACFW_LOG_ROW_CAP` bound (default 80 rows) and its never-drop-a-row EOF fallback.
A multica-backed task document therefore reads exactly like a files-backed one.

Why not comments: on this backend **a comment thread is a live agent channel**. An
assigned agent reads it, and comment activity is what triggers comment-scoped tasks.
Orchestrator bookkeeping posted there mixes whip's audit trail into a conversation
an agent is expected to act on. The `comment` subcommand still writes a real comment
— that is what comments are now for.

Three consequences follow, all of them simplifications:

| | Before | Now |
|---|---|---|
| `snapshot.hasCleanCheckoutToken` | one `issue comment list --full` per in-review task | reads the description already returned by `issue list`; falls back to `issue get`, then to the comment scan |
| `read --materialize` | synthesized a `## Store Audit Trail` section out of comments | the document is already complete; comments append under `## Store Comments` |
| stored `description` | carried an empty `## Transition Log` table forever | carries the live log |

**Upgrading mid-flight is safe.** The token scan's last step is still the comment
scan, and `--materialize` still renders comments, so a task that entered review
*before* this change — with its `clean-checkout` token in a comment — keeps resolving
and is not auto-rejected. That fallback costs nothing once a task has been through
the new write path.

**Failure handling is asymmetric on purpose**: `transition` writes its row last and
best-effort (the `whip_state` write above it is the commit point, so a lost row must
not report a completed move as failed) but WARNs on stderr rather than swallowing the
error; `log-event` is strict and exits non-zero, because losing the clean-checkout
token costs the task an entire review round.

**Concurrency**: splicing is a read-modify-write (`issue get` → splice → `issue update
--description-stdin`) with no lock, so two simultaneous writers on one task could lose
a row. This is identical to the files adapter — `append_log_row` there has the same
unguarded shape — and whip serializes writes per task. The multica CLI exposes no
ETag/`If-Match`, so there is no cheaper guarantee available.

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
  and `read --body` returns the stored document verbatim (bullets frozen, Transition
  Log live), whereas `read --materialize` refreshes the bullets from live metadata
  before writing the spec (see the materialize note above).
- **`NOTES` is escaped before it enters the table.** Newlines and tabs collapse to
  spaces and a literal `|` becomes `\|`, because this backend re-reads its own rows:
  a newline would corrupt the splice and a bare pipe would add phantom columns.
  `apply-transition.sh` does neither — worth backporting to the files adapter, which
  has the same latent hazard.

## Testing

Offline, `tests/phase12-multica-transition-log.test.sh` drives the adapter through a
**fake `multica` CLI** (JSON files + `jq`) it builds in its own temp dir, and covers
the audit-trail contract: rows splice into the table and not into comments, `NOTES`
containing a pipe or newline cannot break the table, the token resolves from the
description with zero comments present *and* from a legacy comment, the cap holds, a
table-less document still keeps its row, and `transition`/`log-event` fail
asymmetrically. That fake also runs the frozen store-conformance suite:

```sh
FAKE_STORE=$(mktemp -d) ACFW_MULTICA_BIN=<extracted-fake> \
  ADAPTER="$PWD/adapters/multica/acfw-store-multica" bash tests/phase9-store-conformance.test.sh
```

The fake is deliberately **not** a general emulator — it covers only the invocation
shapes the adapter uses, so the live wrapper below stays the authority on real CLI
behavior. Two things remain unverified offline and are not assumed anywhere: whether
`issue list --output json` includes `description` (hence the `issue get` fallback in
the token scan), and Multica's description size limit (bounded by `ACFW_LOG_ROW_CAP`).
The adapter is additionally gated by `bash -n` in `tests/run-all.sh`'s static gates.

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
