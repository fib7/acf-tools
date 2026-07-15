# acfw-store-linear

The **linear** task-store adapter for acf-whip (store contract v1). It backs
acf-whip's backlog with a [Linear](https://linear.app) team — **one Linear issue
per whip task** — speaking Linear's GraphQL API directly with `curl` + `jq`. There
is no official Linear CLI, so the adapter is the client.

Linear is an API backend, not a git tree, so `commitsToGit` is **false**: the
`/go` dispatcher stages code deliverables to trunk itself (this adapter has no
`stage` capability) and only the task's *state* lives in Linear.

Select it per-repo with `ACFW_STORE=linear` in `<repo>/.acfwhip/config`, or point
the dispatcher at it directly:

```sh
ADAPTER=adapters/linear/acfw-store-linear bash tests/phase9-store-conformance.test.sh
```

## Canonical state model

Linear issues have **no custom fields**, so the authoritative whip state cannot
live on the issue. The load-bearing idea:

- **Whip state lives in ONE Attachment per issue.** The attachment's `metadata`
  (a key/value JSONObject) holds every `whip_*` field; the native workflow-state is
  a **lossy display projection** of `whip_state`. Every read (`snapshot`, `read`)
  reports the whip-canonical name from metadata; `doctor` repairs the native state
  *from* `whip_state`, never the reverse.
- **The attachment `url` is the join key and an idempotency handle.** It is
  `https://acfw.fib7.ai/<namespace>/<stem>`. Re-running `attachmentCreate` with the
  same `url`+`issueId` **updates the attachment in place** (upsert), so counter
  bumps are a plain read-modify-write of one attachment.
- **The key attachment is written LAST on `create`.** A crash mid-create leaves an
  issue with no key attachment — invisible to `resolve`/`snapshot` — which
  **orphans** (never duplicates) the task. `create` never upserts; a URL that
  already resolves is a typed conflict (exit 4).
- **The full task document is the issue `description`**, so `read --body` and
  `read --materialize` round-trip the spec (body parity with the files adapter).
- **`read --materialize`** writes the stored document, **refreshes its metadata
  bullets in place from the live attachment metadata** (they froze at create time),
  then appends a **`## Store Audit Trail`** section with every comment verbatim
  (oldest-first). Transition rows and — crucially — the `clean-checkout` token
  (which rides a comment) live there, so the quality-reviewer's re-run of
  `read --materialize | grep '| clean-checkout | ok |'` sees the token.

### State projection (`whip_state` → native workflow-state)

Native states are per-team and typed. The adapter fetches the team's states once
per invocation and picks the **lowest-`position` state of the target type**;
`completed`/`in-review` prefer a state literally named **"In Review"** when the
team has one.

| whip state | native type | | whip state | native type |
|---|---|---|---|---|
| draft | backlog | | in-review | started ("In Review") |
| pending | unstarted | | accepted | completed |
| in-progress | started | | rejected | unstarted |
| completed | started ("In Review") | | blocked | started |
| | | | archive | canceled |

`completed`/`in-review` and `pending`/`rejected` collapse onto the same native
type — that collapse is exactly why `whip_state` metadata, not the native state, is
the source of truth.

### Priority projection (whip priority → Linear priority int)

| whip | Linear | | whip | Linear |
|---|---|---|---|---|
| blocker | 1 (urgent) | | medium | 3 (medium) |
| critical | 2 (high) | | low | 4 (low) |
| high | 2 (high) | | unknown/empty | 0 (none) |

The verbatim whip priority is preserved in `whip_priority`.

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
| `whip_deps` | dependency stems (comma-joined) — MAY name not-yet-created keys; recorded verbatim, never validated |
| `whip_rejections` / `whip_blocks` | counters (JSON numbers) |
| `whip_last_transition_ts` | `YYYY-MM-DD HH:MM:SS` UTC |

Metadata values are strings or numbers only (Linear's constraint). Transition audit
rows (`whip-transition | ts | from | to | agent | notes`) and the `clean-checkout`
token are recorded as issue **comments**; `snapshot.hasCleanCheckoutToken` is a
substring scan over the comments of `in-review`/`completed` issues only.

Dependencies also get a **best-effort** native `issueRelationCreate type:blocks`
edge for each dep whose issue already exists — non-fatal, swallowed on failure.
`whip_deps` metadata is always the contract-of-record.

## Namespace (multi-repo isolation)

Several repos can share one Linear team+label. The attachment-URL **namespace**
keeps their tasks apart; `snapshot`/`doctor` only consider issues whose key
attachment URL starts with this repo's namespace prefix. Resolution order:

| source | value |
|---|---|
| `ACFW_LINEAR_URL_NS` | used verbatim when set |
| `acfw_load_namespace` | else `ACFW_BRANCH_PREFIX` (from `.acfwhip/config`) |
| repo dir basename | final fallback |

To share a team across repos, give each repo a distinct `ACFW_LINEAR_URL_NS` (or a
distinct `ACFW_LINEAR_LABEL`).

## Environment

| Var | Meaning |
|---|---|
| `LINEAR_API_KEY` | **(required)** personal API key; sent as the `Authorization` header with **no** `Bearer` prefix |
| `ACFW_LINEAR_TEAM` | **(required)** team KEY (e.g. `ENG`); resolved to a team id |
| `ACFW_LINEAR_PROJECT` | *(optional)* project id (or name → best-effort resolved) |
| `ACFW_LINEAR_LABEL` | *(optional)* marker label name (default `acf-whip`) |
| `ACFW_LINEAR_URL_NS` | *(optional)* attachment-URL namespace (see above) |
| `ACFW_LINEAR_URL` | *(optional)* GraphQL endpoint (default `https://api.linear.app/graphql`) |
| `ACFW_LINEAR_TRANSPORT` | *(optional)* test hook — a command replacing the whole `curl`; reads a request JSON on stdin, prints the response body |

Get the API key from Linear → Settings → Security & access → Personal API keys.
Tokens are **never** stored in-repo.

## Capabilities

```
snapshot read create transition update-field update-body log-event comment doctor doctor-fix init
```

Deliberately **absent**: `snapshot-enriched` (snapshots are `"raw":true`; the
dispatcher fills git-derived facts), `stage` (dispatcher commits deliverables to
trunk), `doctor-complete` (dispatcher merges the generic graph/git checks), and
`sync` (nothing to flush — Linear is the durable store).

`doctor` findings: **FATAL** = duplicate key URL on >1 issue, key attachment with
no whip metadata; **REPAIRABLE** (`--fix`) = native workflow-state drift (reasserts
the projection via `issueUpdate`).

## Requirements & limits

- **`jq`** on `$PATH`. Missing → exit 5.
- **`curl`** on `$PATH` (default transport). Missing → exit 5 (unless
  `ACFW_LINEAR_TRANSPORT` is set).
- **bash 3.2** clean (no `declare -A`, no `${var,,}`) — runs under stock macOS bash.
- Linear API-key rate limits: 5,000 requests/h and 3,000,000 complexity points/h
  per user (max 10,000 points/query). The adapter is chatty (create ≈ 6 requests);
  a large backlog stays well within budget, but keep `snapshot` off tight loops.

Exit-code mapping (transport/GraphQL → contract): HTTP 401/403 → **6**; 429 →
**99**; other 5xx / network / transport failure → **5**; GraphQL entity-not-found →
**3**; other GraphQL errors → **5**. Not-found is usually detected as an empty
`attachmentsForURL` result (→ exit 3), not a GraphQL error.

## Known deviations from the files adapter

- **`update-body` replaces the description only.** The `whip_*` metadata projection
  is edited via `update-field`/`transition`, not re-parsed from the replacement
  body.
- **The stored description's bullets freeze at create time; metadata is the truth.**
  `read --body` returns the frozen document verbatim; `read --materialize` refreshes
  the bullets from live metadata before writing the spec.

## Testing

Offline, the adapter is validated by `bash -n` and by running the full
store-conformance suite against a **local Node GraphQL emulator** (a JSON-file-backed
fake of `api.linear.app` — *not* an HTTP server, not shipped) wired in through
`ACFW_LINEAR_TRANSPORT`. The shipped wrapper does this plus linear-specific checks
(duplicate-URL conflict, native-status-drift repair, materialized audit trail,
attachment-upsert no-dup):

```sh
bash tests/phase9-adapter-linear.test.sh          # emulator conformance (no network)
```

Against a **live** team, export the guarded vars (otherwise the live path SKIPs and
never touches the real API):

```sh
export LINEAR_TEST_API_KEY=lin_...   LINEAR_TEST_TEAM=ENG
# optional: LINEAR_TEST_PROJECT=<id>
bash tests/phase9-adapter-linear.test.sh
```

The live path creates `conf-a`/`conf-b`/etc. issues (namespace `acfw-livetest`);
Linear has no issue-delete API, so clean them up in the UI afterward.
