# acf-whip Spec-Tool Contract (v1)

A **spec tool** reviews a plan or task, or edits a plan somewhere else and hands it back. It plugs
into the cycle through one committed file, `.acfwhip/spec-tools/<name>`, and never touches acf-whip
code. The engine, `skills/lib/bin/acfw-spec`, is the only thing that runs spec tools: it freezes
the input, runs the tool under a watchdog, normalizes the verdict, caches it, and renders the card.

This document is the normative spec. For authoring, examples and the workbench walkthrough, see
`spec-tools/README.md`. `spec-tools/dir/acfw-spec-dir` is the reference driver.

## Declaration

`.acfwhip/spec-tools/<name>` (no extension; `<name>` matches `^[a-z0-9][a-z0-9-]*$`). Other files
in the directory, such as an agent prompt `.md`, are not declarations. A file that reads like one
but has an invalid name (`no_tbd`, a copied `no-tbd.example`) is ignored and flagged: a CARD in
`status`, a WARN in `list`. Plain `key=value` lines, `#` comments. Parsed line by line, never
sourced. Strict: an unknown key, a repeated key, a trailing comment after a value, or a control or
invisible formatting character (a mid-line carriage return, an escape, a bidi override) is a
declaration error: a typo must never loosen a gate, and a trust notice must show exactly what runs.
Never put a credential in it (see Safety).

| Key | Values | Meaning |
|---|---|---|
| `driver=` | a name | runs the executable `acfw-spec-<name>` (discovery below) |
| `review=` | a shell command | runs `bash -c '<command>'`; review only, no wrapper needed |
| `agent=` | a path | a prompt file in `.acfwhip/spec-tools/` with `## review`, `## push`, `## pull` (`## from`) sections, run by an in-session subagent; plan stage only |
| `at=` | `plan`, `task`, `plan,task` | hook points; absent means it runs only when asked (`/whip --review`) |
| `policy=` | `advisory` (default), `block` | block: approval needs GO at the exact approved bytes, or a recorded override; at the task stage, a task without GO is held in draft |
| `rerun=` | `every`, `ask` | default `ask` when capabilities print `COST|`, else `every`. Agent tools have no capabilities verb, so they default to `every`; a paid critic sets `rerun=ask` |
| `timeout=` | 5 to 540 | seconds, default 120 |

Exactly one of `driver=`, `review=`, `agent=`.

**Where a block tool gates.** It gates plan approval when its committed `at=` names `plan` or is
absent (an on-request tool still gates the approval it belongs to). It holds tasks when its
committed `at=` names `task`. A task-only block tool never gates a plan. The card, the hook run,
`review --all` and the gate all use this one rule.

**Policy and `at=` are read from HEAD.** A local edit to a declaration, or to a driver or prompt it
names under `.acfwhip/`, cannot loosen a gate:

- A declaration that is uncommitted or edited, or whose driver or prompt is dirty against HEAD or
  was found via `$ACFW_SPEC_TOOL_PATH` or `$PATH`, still runs, but as advisory and with a WARN. Its
  result can never satisfy a block gate.
- A tool runs at a stage when either the committed or the working-tree `at=` names it: a local edit
  can add a stage, never remove one. A declaration deleted locally keeps running from HEAD until
  the deletion is committed.
- A committed declaration that fails to parse still gates when it could mean block: any `policy`
  line that is not plainly `advisory`, or a misspelled key set to `block`, counts as block. The
  gate then refuses and names the invalid declaration. The override still works.
- A driver or prompt that is a symlink is judged by what runs: every link, and the file it ends at,
  must be inside the repo, committed and clean. Clean means byte-identical to HEAD, compared by
  content, so index flags such as `assume-unchanged` or `skip-worktree` cannot make an edited
  driver look clean.
- A result satisfies a block gate only when it came from the committed declaration and the
  committed version of the driver or prompt. A GO recorded against an older version (before you
  pulled a teammate's fix, say) is shown as stale and does not count.

A script that a `review=` command calls from elsewhere in the repo is not covered: it is outside
what the engine tracks, so a local edit to it goes unnoticed. A block tool that runs repo code should
therefore be a driver committed under `.acfwhip/adapters/`, where a local edit demotes the tool to
advisory.

**Driver discovery** (first executable wins): `$ACFW_SPEC_TOOL_PATH` (colon-separated dirs), then
`<repo>/.acfwhip/adapters/`, then `<acf-whip>/spec-tools/<name>/`, then `$PATH`.

## Invocation

`acfw-spec-<name> <verb>` (drivers) or `bash -c '<command>'` (`review=`), with the working directory
at the repo root, stdin from `/dev/null`, and every input in the environment. Inputs are never
substituted into a command line. Tool-native variables (`GAPTRAP_API_KEY`, ...) pass through; names
a driver lists in `NEEDS|` are also read from a gitignored, untracked `.env`.

| Variable | Meaning |
|---|---|
| `ACFW_SPEC_VERB` | the verb, also passed as `$1`: `capabilities`, `review`, `push`, `pull`, `from` |
| `ACFW_SPEC_STAGE` | `plan` or `task` |
| `ACFW_SPEC_KEY` | the cycle ID (plan stage) or task stem (task stage); empty for `from` |
| `ACFW_SPEC_FILE` | the frozen input: normalized bytes, read-only; for `pull`, the pushed BASE |
| `ACFW_SPEC_BLOB` | `v1:<40 hex>`, the content hash of exactly those bytes (the hash approval binds to) |
| `ACFW_SPEC_OUT` | a fresh, writable output directory for this run |
| `ACFW_SPEC_REF` | the newest `REF` this tool returned for this key (lineage); for `pull`, the pushed REF; for `from`, what the user typed |
| `ACFW_SPEC_SAME_REF` | the `REF` recorded for these exact bytes, if any: reuse it instead of paying again |
| `ACFW_SPEC_STATE` | a directory per tool and key that persists across plan edits; yours |
| `ACFW_SPEC_DEADLINE` | epoch seconds at which the process group is killed |
| `ACFW_SPEC_FRESH` | `1` when the operator asked for a fresh review (skip your own caches) |
| `ACFW_SPEC_TOOL`, `ACFW_SPEC_CONTRACT_VERSION`, `ACFW_TRUNK_ROOT` | declaration name, `1`, repo root |

**Exit codes**: `0` GO · `1` NO-GO · `3` unavailable (unset credential, plan limit, quota, verb not
supported; the first stderr line is the reason) · anything else is an error. The engine normalizes
these to `go | nogo | skip | error`, and a timeout is an error. `skip` and `error` never block and
never hold.

A tool that the engine never started, or cut short, because the shared review budget ran out is
neither skip nor error: it has no result. A block tool still needs GO or the override, a task stays
held, and the next review runs the tool again. The same holds when the engine refuses to run a tool
(not trusted yet, or a credential literal in the task).

## Stdout records

One per line. Unknown lines are ignored (on NO-GO they feed the fallback below).

| Record | Meaning |
|---|---|
| `FINDING\|sev\|fp\|loc\|title` | sev: `critical`, `high`, `medium`, `low`, `info`. fp: stable across runs (a content hash or a slug, never a per-run id). loc: `L<n>`, `D<n>`, `AC<n>.<m>` or `-` |
| `Q\|question (default: X)` | a closed question about the preceding finding |
| `ANSWER\|fp\|decision` | `pull` only: a decision instead of text; the session folds it in like a typed reply |
| `REF\|id` | a plain id (`[A-Za-z0-9][A-Za-z0-9._:-]*`). A link or anything credential-shaped is refused |
| `URL\|link` | shown to the human, stored under `.acfwhip/run/` only, never committed |
| `SUMMARY\|verdict=go` or `nogo` | optional for processes, and must agree with the exit code: a disagreement is NO-GO, and so is any `nogo` among several SUMMARY lines (a tool that echoes its input must not let a planted line decide). Required for agent tools |
| `HINT\|text` | shown with a skip, an error, or a verb the tool does not offer |

`capabilities` prints `VERBS|review push pull from` (what it supports), `NEEDS|<ENV names>`,
`EGRESS|<host>` and, if a run costs money or quota, `COST|<text>`. It must succeed without
credentials. It is cached per driver hash, refreshed when a day old or before a verb is refused as
not offered (a driver may detect features, so a verb its service started offering since the last
probe is not refused from a stale cache), and never called by `status`, `show`, `gate` or `list`.

**Unstructured fallback**: on NO-GO with no `FINDING` records, the first 20 stdout lines become
medium findings; a leading `file:line:` or `line:` becomes `L<line>`. Any linter works as-is.

## Workbench verbs

- `push`: publish `ACFW_SPEC_FILE`. Print `REF|<id>` (required) and optionally `URL|`, `HINT|`.
  Reuse `ACFW_SPEC_SAME_REF` when set. The plan is then OUT until pulled or dropped. A push must
  never destroy remote edits it has not synced: when the remote copy changed since the driver last
  wrote or read it, save a copy (under `ACFW_SPEC_STATE`) and refuse with exit 3 and a `HINT|`, as
  the `dir` driver does.
- `pull`: fetch the document for `ACFW_SPEC_REF` and write it to `$ACFW_SPEC_OUT/remote.md`, or
  print `ANSWER|` lines. The engine normalizes it (CRLF, NBSP, zero-width space, BOM, trailing
  blanks), validates it, and 3-way merges it with `git merge-file`. A pull never approves or commits.
- `from`: fetch the document named by `ACFW_SPEC_REF` into `$ACFW_SPEC_OUT/remote.md` and print its
  `REF|`. Used to start a cycle from a workbench.

## Agent tools

The engine writes a work order and exits 21 with `AGENT|<tool>|<verb>|<prompt command>`. The session
dispatches one subagent per line in a single message; each runs its prompt command and follows it.
The subagent writes records to `<out>/stdout` (and `remote.md` for `pull`/`from`). Re-running the
same `acfw-spec` command collects the result. Agent tools never run at the task stage.

The plan may change between the order and its collection. A collected `push` records BASE as the
bytes the order froze, so the next pull merges the agent's draft against what it drafted from and
keeps every edit made meanwhile. A `pull` or `from` order issued for another base or ref is never
collected: it is discarded and issued again. `prompt` refuses (25) a prompt that changed since it
was trusted, so a subagent is never handed text nobody saw.

## What the engine guarantees

- The tool runs in its own process group. At the deadline the group gets TERM, then KILL 3 s later;
  anything left in the group after the tool exits is swept. At most 540 s per call, tools run
  sequentially at the plan stage and at most 4 at a time at the task stage.
- go/nogo is cached per (key, content, declaration sha, executable path and git hash); skip and
  error are not. A tool is invoked once per content unless the operator asks for `--fresh`. A
  result from one version of the tool is kept when another version runs, and comes back when that
  version is current again, so reverting a local experiment never costs a second paid run.
- The input file is frozen and read-only, and it is exactly the bytes `ACFW_SPEC_BLOB` names.
- Nothing a tool prints reaches git except through Plan Log rows: `|` becomes `/`, control
  characters are stripped, links become `<link>`, and each cell is capped at 160 characters. Every
  plan reviewer gets a `reviewed` row at approval, advisory tools included. One with nothing at the
  approved bytes says why: `not run at this content (stale since <b12>)`, `(untrusted on this
  machine)`, `(agent work order pending)`, `(declaration error)`, or `(never run)`.
- `REVIEWED|<id>|<tool>|<policy>|<verdict>|...` prints the policy in force now, never one cached
  with a result. A block tool whose result cannot stand for those exact bytes reports `nogo`, and its
  path is a `held.md` that says why (a local edit, a dirty driver, no trust, the budget). Such a
  result never releases a task as `go`, `skip` or `advisory`.
- Anything matching `secret-patterns` is shown as `<redacted>` wherever the engine echoes declaration
  or tool text: warnings, errors, CARD and FACT lines, the REVIEW block, push and pull output, and
  Plan Log rows. A `URL|` link is still shown to the operator (never committed); a token inside it
  that matches a pattern is redacted.

## Safety

- **Secret lint**: `spec-tools/secret-patterns` (shape plus length). A match in a declaration, an
  agent prompt, a repo-local driver, a tracked `.mcp.json` or `.env`, or a plan, task or workbench
  text about to be sent stops everything with exit 20 (`review`, `trust`, `push`, `pull`, `from`,
  and `prompt`, which hands the prompt to a subagent). Delete the literal, commit, and rotate the
  key. A committed copy that differs from the working tree is checked as HEAD has it, so a literal
  removed only locally still refuses until the removal is committed. Patterns after a
  `#@scope config` line (the JSON `"...Key": "..."` pair) apply to committed configuration only,
  never to plan, task or workbench text: an API plan is full of fields like `"partitionKey"`.
- **Trust on first use**: a new or changed declaration (or repo, env or `$PATH` executable, or agent
  prompt) is printed in full with a version key (a `TRUST|` notice) and skipped until the operator
  replies "run tools" (`acfw-spec trust`). That reply trusts the version the notice showed, never
  one that changed after it; a changed one is shown instead. A status CARD is not a notice: its
  cells are capped at 160 characters, so it records nothing, and a "run tools" after only a card
  prints the full notice and asks for the reply again. `acfw-spec trust <name>=<key>` trusts
  exactly that version. The records live in the gitignored `.acfwhip/run/spec/trusted` and
  `.acfwhip/run/spec/pending-trust`.
- **Egress**: the committed declaration is the consent. `EGRESS` is shown on `add` and on every
  REVIEW line.

## Engine exit codes (`acfw-spec`)

`0` ran · `2` usage or declaration · `20` credential literal · `21` agent work pending ·
`22` gate unmet · `23` pull conflict · `24` pull refused by validation ·
`25` verb not offered, or the tool could not perform it · `26` workbench state mismatch (OUT)

## Conformance

`tests/phase21-spec-tools.test.sh` is the executable spec for the engine. A driver conforms when
`capabilities` succeeds without credentials, every verb it lists in `VERBS|` follows the exit codes
and records above, and it writes nothing outside `ACFW_SPEC_OUT` and `ACFW_SPEC_STATE`.
