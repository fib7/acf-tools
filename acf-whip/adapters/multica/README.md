# acfw-store-multica

This adapter keeps acf-whip's backlog in a [Multica](https://multica.ai) workspace, one Multica
issue per whip task (store contract v1). It shells out to the `multica` CLI with `--output json`.

Multica is an API backend, not a git tree, so `commitsToGit` is false. Only the task's state lives
in Multica. The `/go` dispatcher stages code deliverables to trunk itself, because this adapter has
no `stage` capability.

## Canonical state model

Whip state lives in per-issue metadata (`whip_state`). The native Multica issue `status` is a lossy
display copy of it.

- Every read (`snapshot`, `read`) reports the whip state from `whip_state` metadata, never the
  native status.
- `doctor` repairs native `status` from `whip_state`, never the other way round, and leaves a
  human hold alone (see the `doctor` findings below).
- The join key is the metadata field `whip_key`, which holds the task stem. `create` writes it last,
  so if `create` dies halfway the issue has no `whip_key` and `resolve` and `snapshot` never see it.
  The task is orphaned, never duplicated. `create` never upserts: a `whip_key` that already exists,
  in any state, is a typed conflict (exit 4).
- The issue `description` stores the full task document verbatim, so `read --body` and
  `read --materialize` return the spec as written, the same as the files adapter. The scheduler
  reads the structured `whip_*` metadata, which is authoritative.
- `read --materialize` writes the stored document and rewrites its metadata bullets from the current
  `whip_*` metadata, so the spec shows live state instead of the values frozen at create time. It
  then appends any issue comments verbatim, oldest first, under `## Store Comments`. The audit trail
  needs no extra step because it is already in the document (see below). The quality-reviewer's
  re-run of `read --materialize | grep '| clean-checkout | ok |'` reads the same `## Transition Log`
  table it would on a files-backed task.

### State projection (`whip_state` → native `status`)

| whip state | native status | | whip state | native status |
|---|---|---|---|---|
| draft | backlog | | in-review | in_review |
| pending | todo | | accepted | done |
| in-progress | in_progress | | rejected | todo |
| completed | in_review | | blocked | blocked |
| | | | archive | cancelled |

`completed` and `in-review` share a native status, and so do `rejected` and `pending`, so only
`whip_state` metadata can tell them apart. It is the source of truth.

### Priority projection (whip priority → native `priority`)

`blocker`→`urgent`, `critical`→`high`, `high`→`high`, `medium`→`medium`, `low`→`low`. The original
whip priority is kept verbatim in `whip_priority`.

### Metadata key schema (per issue)

`whip_key`, `whip_id`, `whip_state`, `whip_priority`, `whip_worktree`, `whip_agent`,
`whip_pr_group`, `whip_touches` (comma-joined globs), `whip_deps` (comma-joined stems),
`whip_rejections` (number), `whip_blocks` (number), `whip_last_transition_ts`. That is twelve keys,
all primitive values, well under Multica's per-issue limits of 50 keys and 8 KB.

Multica has no dependency API. `whip_deps` is a plain comma list of dependency stems, and whip's
scheduler works out readiness from the snapshot.

## Audit trail: the document, not the comment thread

Transition and `log-event` rows go into the stored document's `## Transition Log` table, not into
comments. The adapter builds each row in the files-adapter shape (`| ts | from | to | agent | notes |`)
and splices it in with the shared `append_log_row` from `skills/lib/acfw-git.sh`. The row inherits
that helper's newest-first order, its `ACFW_LOG_ROW_CAP` bound (default 80 rows) and its EOF
fallback, which never drops a row. A multica-backed task document reads the same as a files-backed
one.

Comments are the wrong place for it on this backend, because a comment thread is a live agent
channel. An assigned agent reads it, and comment activity is what triggers comment-scoped tasks.
Orchestrator bookkeeping posted there would sit inside a conversation an agent is expected to act
on. The `comment` subcommand still writes a real comment, and that is all comments are for now.

Moving the log out of comments made three things simpler:

| | Before | Now |
|---|---|---|
| `snapshot.hasCleanCheckoutToken` | one `issue comment list --full` per in-review task | reads the description already returned by `issue list`; falls back to `issue get`, then to the comment scan |
| `read --materialize` | synthesized a `## Store Audit Trail` section out of comments | the document is already complete; comments append under `## Store Comments` |
| stored `description` | carried an empty `## Transition Log` table forever | carries the live log |

**Upgrading mid-flight is safe.** The token scan still ends with the comment scan, and
`--materialize` still renders comments. A task that entered review before this change, with its
`clean-checkout` token in a comment, keeps resolving and is not auto-rejected. Once a task has been
through the new write path, the fallback costs nothing.

**Failure handling is asymmetric on purpose.** `transition` writes its row last and best-effort.
The `whip_state` write before it is the commit point, and a lost row must not make a completed move
look failed, so a failed row write does not fail the call. It prints a WARN on stderr instead of
vanishing. `log-event` is strict and exits non-zero, because losing the clean-checkout token costs
the task a whole review round.

**Concurrency.** Splicing is a read-modify-write (`issue get` → splice →
`issue update --description-stdin`) with no lock, so two writers on one task at the same moment
could lose a row. The files adapter has the same gap (its `append_log_row` is equally unguarded),
and whip serializes writes per task. The multica CLI exposes no ETag or `If-Match`, so no cheaper
guarantee is available.

## Environment

The first three variables belong to the `multica` CLI itself. The dispatcher passes them through
untouched.

| Var | Meaning |
|---|---|
| `MULTICA_SERVER_URL` | Multica server URL |
| `MULTICA_TOKEN` | a `mul_` PAT (member identity; see the note below) |
| `MULTICA_WORKSPACE_ID` | workspace UUID |
| `ACFW_MULTICA_PROJECT` | Optional. Scope issues to this project id |
| `ACFW_MULTICA_BIN` | Optional. Path to the CLI (default: `multica` on `$PATH`) |

**PAT identity.** The adapter authenticates as a member through a `mul_` PAT, which is what lets it
post top-level (non-reply) comments. Multica rejects top-level comments only from agent-identity
callers running inside a comment-triggered task. Do not run the adapter with `MULTICA_AGENT_ID` or
`MULTICA_TASK_ID` set, or with a task-scoped `mat_` token in the environment.

## Capabilities

```
snapshot read create transition update-field update-body log-event comment doctor doctor-fix init
```

The adapter also declares `token-all-states`: it answers `hasCleanCheckoutToken` for every state,
because the answer comes free from the description the snapshot already fetched.

Left out on purpose:

- `snapshot-enriched`: snapshots are `"raw":true` and the dispatcher fills in the git-derived facts.
- `stage`: the dispatcher commits deliverables to trunk.
- `doctor-complete`: the dispatcher merges in the generic graph and git checks.
- `sync`: there is nothing to flush, because the server is the durable store.

`doctor` reports these findings:

| Severity | Finding | `--fix` |
|---|---|---|
| FATAL | two or more issues share a `whip_key` | no repair |
| WARN (`invalid-state`) | `whip_state` is outside the whip vocabulary, so no scheduler path can dispatch, transition or integrate the card | no repair; retire it with `acfw-store transition <key> archive` |
| WARN (`native-hold`) | native status is `blocked` or `cancelled` while `whip_state` projects to something else | leaves it alone and treats it as a human hold. Park the task with `acfw-store transition <key> draft` (or `archive`); if nobody parked it, re-running the transition re-syncs the status |
| REPAIRABLE | any other native-status drift | reasserts the projection |
| REPAIRABLE | a non-numeric `whip_rejections` or `whip_blocks` | resets it to 0 |

## Requirements

- The `multica` CLI on `$PATH` (or at `ACFW_MULTICA_BIN`). Missing → exit 5.
- `jq`. Missing → exit 5.

Multica CLI failures map to contract exit codes like this:

| Failure | Exit |
|---|---|
| auth 401/403 | 6 |
| 404 | 3 |
| 400/422 | 7 |
| network timeout | 99 |
| other network failure | 5 |
| server 5xx/429 | retried up to 3×, then 99 |

`issue create` is never retried, because a blind retry could create a duplicate issue. Idempotent
writes (metadata, status, PUT) are.

## Known deviations from the files adapter

- **`update-body` replaces the description only.** It does not re-parse the `whip_*` metadata from
  the new body, so edit fields with `update-field` (or `transition`). The files adapter, whose file
  *is* the fields, effectively re-parses.
- **The stored description's bullets freeze at create time; metadata is the truth.** The stored
  document keeps its original `- **Status**: …` and counter bullets while the authoritative values
  move into `whip_*` metadata. `snapshot` and the `fields` of `read` always read metadata, so
  scheduling is never affected. `read --body` returns the stored document verbatim (bullets frozen,
  Transition Log live); `read --materialize` refreshes the bullets from live metadata before it
  writes the spec.
- **`NOTES` is escaped before it enters the table.** Newlines and tabs collapse to spaces and a
  literal `|` becomes `\|`, because this backend re-reads its own rows: a newline would corrupt the
  splice and a bare pipe would add phantom columns. `apply-transition.sh` does neither. The files
  adapter has the same latent hazard and should get the same escaping.

## Testing

Two offline suites cover the adapter. Neither needs a server:

```sh
bash tests/phase12-multica-transition-log.test.sh   # the audit-trail contract
bash tests/phase9-adapter-multica.test.sh           # frozen store-conformance suite + multica checks
```

`phase12` builds its own fake `multica` CLI (JSON files and `jq`) in a temp dir. It checks that rows
splice into the table and not into comments, that `NOTES` containing a pipe or newline cannot break
the table, that the token resolves from the description with zero comments present and also from a
legacy comment, that the cap holds, that a document with no table still keeps its row, and that
`transition` and `log-event` fail asymmetrically.

`phase9-adapter-multica` runs the frozen store-conformance suite against
`tests/fixtures/multica-fake.sh`, a JSON-file-backed fake of the CLI calls the adapter makes, with
fault injection for the transient paths. It then checks multica-specific behavior the frozen spec
cannot express, such as transient handling and the native-hold rule.

Neither fake is a general emulator. Each covers only the invocation shapes the adapter uses, so a
live server stays the authority on real CLI behavior. Two things remain unverified offline, and the
adapter assumes neither: whether `issue list --output json` includes `description` (hence the
`issue get` fallback in the token scan), and Multica's description size limit (bounded by
`ACFW_LOG_ROW_CAP`). `tests/run-all.sh`'s static gates also run `bash -n` on the adapter.

To run the frozen suite against a live server as well, export three variables:

```sh
export MULTICA_TEST_SERVER=https://multica.example.com
export MULTICA_TEST_TOKEN=mul_...
export MULTICA_TEST_WORKSPACE_ID=<workspace-uuid>
bash tests/phase9-adapter-multica.test.sh
```

The live run uses the `multica` on your `$PATH`: the wrapper unsets `ACFW_MULTICA_BIN` for it. It
does not clean up after itself. The `conf-*` issues it creates stay in the workspace, and because
`create` treats an existing `whip_key` as a conflict, a second live run against the same workspace
fails until you delete those issues (or their `whip_key` metadata).

To run only the frozen spec against whatever workspace your `multica` CLI and `MULTICA_*` variables
point at (it leaves the same `conf-*` issues behind):

```sh
ADAPTER=adapters/multica/acfw-store-multica bash tests/phase9-store-conformance.test.sh
```
