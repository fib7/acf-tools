# acfw-store-linear

This adapter keeps acf-whip's backlog in a [Linear](https://linear.app) team, one Linear issue per
whip task (store contract v1). It calls Linear's GraphQL API directly with `curl` and `jq`. Linear
has no official CLI, so the adapter is the client.

Linear is an API backend, not a git tree, so `commitsToGit` is false. Only the task's state lives in
Linear. The `/go` dispatcher stages code deliverables to trunk itself, because this adapter has no
`stage` capability.

Select it per repo with `ACFW_STORE=linear` in `<repo>/.acfwhip/config`, or point the dispatcher at
it directly:

```sh
ADAPTER=adapters/linear/acfw-store-linear bash tests/phase9-store-conformance.test.sh
```

## Canonical state model

Linear issues have no custom fields, so whip's authoritative state cannot live on the issue itself.
It lives in an attachment instead.

- **One attachment per issue holds the whip state.** Its `metadata` (a key/value JSONObject) carries
  every `whip_*` field. The native workflow state is a lossy display copy of `whip_state`. Every read
  (`snapshot`, `read`) reports the whip state name from metadata, and `doctor` repairs the native
  state from `whip_state`, never the other way round.
- **The attachment `url` is the join key and the idempotency handle.** Its form is
  `https://acfw.fib7.ai/<namespace>/<stem>`. Calling `attachmentCreate` again with the same `url`
  and `issueId` updates that attachment in place, so bumping a counter is a plain read-modify-write
  of one attachment.
- **`create` writes the key attachment last.** If `create` dies halfway, the issue has no key
  attachment and `resolve` and `snapshot` never see it. The task is orphaned, never duplicated.
  `create` never upserts: a URL that already resolves is a typed conflict (exit 4).
- **The issue `description` holds the full task document**, so `read --body` and
  `read --materialize` return the spec as written, the same as the files adapter.
- **`read --materialize`** writes the stored document and rewrites its metadata bullets from the
  live attachment metadata, since the stored bullets froze at create time. Then it appends a
  `## Store Audit Trail` section with every comment verbatim, oldest first. Transition rows and the
  `clean-checkout` token both ride comments, so both land in that section. That is where the
  quality-reviewer's re-run of `read --materialize | grep '| clean-checkout | ok |'` finds the token.

### State projection (`whip_state` → native workflow-state)

Native states are per team and typed. The adapter fetches the team's states once per invocation and
picks the lowest-`position` state of the target type. For `completed` and `in-review` it prefers a
state named "In Review" (matched case-insensitively) when the team has one.

| whip state | native type | | whip state | native type |
|---|---|---|---|---|
| draft | backlog | | in-review | started ("In Review") |
| pending | unstarted | | accepted | completed |
| in-progress | started | | rejected | unstarted |
| completed | started ("In Review") | | blocked | started |
| | | | archive | canceled |

`completed` and `in-review` land on the same native type, and so do `pending` and `rejected`, so
only `whip_state` in metadata can tell them apart. It is the source of truth.

### Priority projection (whip priority → Linear priority int)

| whip | Linear | | whip | Linear |
|---|---|---|---|---|
| blocker | 1 (urgent) | | medium | 3 (medium) |
| critical | 2 (high) | | low | 4 (low) |
| high | 2 (high) | | unknown/empty | 0 (none) |

The original whip priority is kept verbatim in `whip_priority`.

### Metadata key schema (per key attachment)

| key | holds |
|---|---|
| `whip_key` | the task stem (identity marker) |
| `whip_state` | whip-canonical state (source of truth) |
| `whip_priority` | verbatim whip priority |
| `whip_agent` | assigned agent |
| `whip_worktree` | worktree slug |
| `whip_pr_group` | PR group |
| `whip_touches` | touches-globs (comma-joined) |
| `whip_deps` | dependency stems (comma-joined). May name keys that do not exist yet; stored verbatim, never validated |
| `whip_rejections` / `whip_blocks` | counters (JSON numbers) |
| `whip_last_transition_ts` | `YYYY-MM-DD HH:MM:SS` UTC |

Linear accepts only string and number metadata values. Transition audit rows
(`whip-transition | ts | from | to | agent | notes`) and the `clean-checkout` token go into issue
comments. `snapshot.hasCleanCheckoutToken` is a substring scan over the comments of `in-progress`,
`completed` and `in-review` issues. Issues in other states are not scanned. Each scan is one request.
If it still fails after one retry (a rate limit, a 5xx, a dropped connection), that issue reports
`null`, meaning unknown, never `false`, and stderr says how many. The review gate parks a task on
`false`, so a rate-limited read reported as `false` would park work that has its token.

For each dependency whose issue already exists, the adapter also tries to add a native
`issueRelationCreate type:blocks` edge. That step is best-effort: a failure is swallowed and never
fails the call. The contract reads `whip_deps` metadata, not these edges.

## Namespace (multi-repo isolation)

Several repos can share one Linear team and label. The namespace in the attachment URL keeps their
tasks apart: `snapshot` and `doctor` only consider issues whose key attachment URL starts with this
repo's namespace prefix. The adapter resolves the namespace in this order:

| source | value |
|---|---|
| `ACFW_LINEAR_URL_NS` | used verbatim when set |
| `acfw_load_namespace` | else `ACFW_BRANCH_PREFIX` (from `.acfwhip/config`) |
| repo dir basename | final fallback |

To share a team across repos, give each repo its own `ACFW_LINEAR_URL_NS` (or its own
`ACFW_LINEAR_LABEL`).

## Environment

| Var | Meaning |
|---|---|
| `LINEAR_API_KEY` | Required. Personal API key, sent as the `Authorization` header as-is, without a `Bearer` prefix |
| `ACFW_LINEAR_TEAM` | Required. Team key such as `ENG` (not the team id); the adapter resolves it to a team id |
| `ACFW_LINEAR_PROJECT` | Optional. Project id (a name is resolved best-effort) |
| `ACFW_LINEAR_LABEL` | Optional. Marker label name (default `acf-whip`) |
| `ACFW_LINEAR_URL_NS` | Optional. Attachment-URL namespace (see above) |
| `ACFW_LINEAR_URL` | Optional. GraphQL endpoint (default `https://api.linear.app/graphql`) |
| `ACFW_LINEAR_TRANSPORT` | Optional test hook: a command that replaces the whole `curl` call. It reads the request JSON on stdin and prints the response body |

Create the API key in Linear under Settings → Security & access → Personal API keys. Keep it in the
environment, never in the repo.

## Capabilities

```
snapshot read create transition update-field update-body log-event comment doctor doctor-fix init
```

Left out on purpose:

- `snapshot-enriched`: snapshots are `"raw":true` and the dispatcher fills in the git-derived facts.
- `stage`: the dispatcher commits deliverables to trunk.
- `doctor-complete`: the dispatcher merges in the generic graph and git checks.
- `sync`: there is nothing to flush, because Linear is the durable store.
- `token-all-states`: each token answer costs a request, so the scan stays on the three states
  above.

`doctor` reports these findings:

| Severity | Finding | `--fix` |
|---|---|---|
| FATAL | the same key URL on more than one issue; a key attachment with no whip metadata | no repair |
| WARN (`native-hold`) | the issue is canceled in Linear while `whip_state` is anything but `archive` | leaves it alone and treats the cancellation as intentional. Park the task with `acfw-store transition <key> draft`, or `archive` to retire it |
| REPAIRABLE | any other drift of the native workflow state | reasserts the projection through `issueUpdate` |

## Requirements & limits

- `jq` on `$PATH`. Missing → exit 5.
- `curl` on `$PATH` for the default transport. Missing → exit 5, unless `ACFW_LINEAR_TRANSPORT` is
  set.
- bash 3.2 clean (no `declare -A`, no `${var,,}`), so it runs under stock macOS bash.
- Linear's API-key rate limits are 5,000 requests/h and 3,000,000 complexity points/h per user, with
  at most 10,000 points per query. The adapter is chatty (a `create` takes about 6 requests). A
  large backlog still fits the budget, but keep `snapshot` out of tight loops.

Transport and GraphQL failures map to contract exit codes like this:

| Failure | Exit |
|---|---|
| HTTP 401/403 | 6 |
| HTTP 429 | 99 |
| other 5xx, network or transport failure | 5 |
| GraphQL entity-not-found | 3 |
| any other GraphQL error | 5 |

Not-found usually shows up as an empty `attachmentsForURL` result (exit 3) rather than as a GraphQL
error.

## Known deviations from the files adapter

- **`update-body` replaces the description only.** It does not re-parse the `whip_*` metadata from
  the new body. Change those fields with `update-field` or `transition`.
- **The stored description's bullets freeze at create time; metadata is the truth.** `read --body`
  returns the frozen document verbatim. `read --materialize` refreshes the bullets from live
  metadata before it writes the spec.

## Testing

Offline, `bash -n` checks the adapter's syntax and the full store-conformance suite runs against a
local Node GraphQL emulator, wired in through `ACFW_LINEAR_TRANSPORT`. The emulator is a
JSON-file-backed fake of `api.linear.app` that the test writes into its temp directory. It is not an
HTTP server and does not ship as a file of its own. On top of the conformance suite, the shipped
wrapper checks the duplicate-URL conflict, the repair of native-status drift, the materialized audit
trail, and that an attachment upsert creates no duplicate:

```sh
bash tests/phase9-adapter-linear.test.sh          # emulator conformance (no network)
```

To run against a live team as well, export the guarded variables. Without them the live path SKIPs
and never touches the real API:

```sh
export LINEAR_TEST_API_KEY=lin_...   LINEAR_TEST_TEAM=ENG
# optional: LINEAR_TEST_PROJECT=<id>
bash tests/phase9-adapter-linear.test.sh
```

The live path creates `conf-a`, `conf-b` and other issues under the namespace `acfw-livetest`.
Linear has no issue-delete API, so clean them up in the UI afterwards.
