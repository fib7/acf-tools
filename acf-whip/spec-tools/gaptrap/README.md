# GapTrap spec reviewer

`acfw-spec-gaptrap` is an acf-whip spec-tool driver. It sends a plan to
[GapTrap](https://app.gaptrap.ai) for gap analysis and turns the report into findings and
questions on the `/whip` approval card. It speaks JSON-RPC to GapTrap's MCP endpoint with curl
and jq. You do not register an MCP server, and nothing in your session calls GapTrap directly:
every review goes through `acfw-spec`, which caches, gates and records it.

The protocol it implements is in `../CONTRACT.md`.

## Set it up in three steps

**1. Get a key, once per machine.** In GapTrap open Profile, then API keys, then create a key.
You need a Solo plan or higher, or an active trial. The key is shown once.

Do this in a separate terminal, never at the Claude Code prompt: the transcript keeps what you
type there. Copy the key, then put it in your shell profile:

```bash
printf 'export GAPTRAP_API_KEY=%s\n' "$(pbpaste)" >> ~/.zshrc
pbcopy < /dev/null        # clear the clipboard
```

Or put it in the repo's `.env`, but only if git ignores that file (`git check-ignore -q .env`
succeeds and `git ls-files .env` prints nothing):

```bash
printf 'GAPTRAP_API_KEY=%s\n' "$(pbpaste)" >> .env
```

Restart Claude Code after you edit your shell profile, because the session reads its environment
at startup. The `.env` file is read on every run. The driver reads only `GAPTRAP_*` names from it,
never sources it, and refuses it when git tracks it or does not ignore it.

**2. Declare the tool, once per repo.** In Claude Code:

```
/whip --tools add gaptrap
```

This copies `gaptrap.example` to `.acfwhip/spec-tools/gaptrap` and runs the free `tools/list`
probe. It prints the driver path, whether the key is set (never its value), the verbs, the egress
host and the cost. Then it commits the declaration. The shipped declaration is `at=plan`,
`policy=advisory`, `timeout=300`. A key that GapTrap refuses shows up here as
`capabilities probe failed: unauthorized ...`, so a typo is caught before the first plan.

**3. Plan as usual.**

```
/whip "<your goal>"
```

The approval card shows GapTrap's verdict, its findings numbered F1, F2 and so on, and its closed
questions numbered Q1, Q2 and so on. Answer them, ignore them with a reason, or reply `yes`.

## What leaves your machine

| Sent to GapTrap | Why |
|---|---|
| The plan text, at the exact bytes under review | GapTrap analyzes it and stores it as a spec in your GapTrap account or org |
| The file name `<cycle-id>.<tag>.md` | Stored with the spec. The 8-character tag names this attempt, so the driver can find the spec again if the reply is lost |
| `GAPTRAP_TEMPLATE_ID`, `GAPTRAP_FOLDER_ID`, `GAPTRAP_MODE` when set | Passed to `create_spec` |
| The API key, in an Authorization header over https | Authentication. Plain http is refused except for localhost. curl runs with `-q`, so no `~/.curlrc` setting can trace or print the header |

Nothing else is sent: no other files, no git history, no task documents unless a declaration says
`at=task`. The host is `GAPTRAP_MCP_URL` (default `app.gaptrap.ai`), and every REVIEW line on the
card names it.

What comes back: findings, questions, a verdict, the GapTrap spec id and a report link. The spec id
is committed in the plan's Plan Log when you approve. The link is shown but never committed.

The committed declaration is the consent for the whole team. Delete `.acfwhip/spec-tools/gaptrap`
and commit to stop sending plans.

## Cost

- **1 billing unit per review of new plan bytes.** That is one GapTrap `create_spec`. Solo includes
  15 a month; Team pools 15 per seat.
- **Free:** polling the analysis status, reading the report, reviewing the same bytes again,
  pushing bytes that were already reviewed, and the `tools/list` probe.
- **Every plan edit is new bytes.** Because the driver reports a cost, `acfw-spec` treats GapTrap as
  `rerun=ask`: it reviews on the first card, then shows the last result as stale until you reply
  `review`.
- **The driver never bills twice for the same bytes.** The spec id is saved the moment the
  `create_spec` reply is read, even when the watchdog stops the run in that instant. A timeout, a
  watchdog kill or a crash leaves it saved, and the next review of the same bytes resumes polling it
  at no cost. A finished result is re-read for free. A `failed` analysis is remembered as failed, so
  the next card does not pay again; edit the plan, or review with `--fresh` to pay for one more try.
- **A lost reply is looked up, never resent.** GapTrap bills the unit before it answers, so a
  `create_spec` that timed out, got a 5xx, or was killed mid-request may already be paid for. The
  driver writes down the attempt before it sends it, and the next review asks the free
  `list_specs` for a spec with that attempt's file name. If GapTrap made it, the review uses it for
  free. If it is still missing after 90 seconds, GapTrap made nothing and the review sends it again.
  The only blind resend is a request that never left your machine (no DNS, no connection).
- **When the quota runs out** the card says `SKIPPED: quota_exceeded`. Under `policy=advisory` your
  `yes` still approves.

What can still cost a second unit: deleting the driver's state directory, or reviewing the same bytes
from another clone, since each clone keeps its own state.

## How a review runs

1. `create_spec` with `format: markdown`. The attempt is written to the tool state before the
   request goes out, and the returned spec id is written before anything else happens.
2. Poll `get_analysis_status` every 3 seconds until the analysis completes, then poll
   `get_analysis_report` until `contractStatus` is `ready` or `failed`. GapTrap writes the verdict
   twice: the first write can say GO while its template check is still running, and the second can
   change it to NO-GO. The driver waits for the second.
3. Map the report to records:

| GapTrap field | Record |
|---|---|
| `gaps[]` severity, title | `FINDING\|<severity>\|<fp>\|<loc>\|<title>` |
| `gaps[].pattern` plus `extraction_text` | `fp`: a content hash, so the same gap keeps its id across revisions (GapTrap's own `gap_id` changes on every run) |
| `gaps[].source_offset` | `loc` as `L<n>`, the plan line the quote starts on, or `-` |
| `gaps[].resolution_questions` | one `Q\|<question>` per question, after its finding |
| spec id | `REF\|<id>` |
| report link | `URL\|<link>`: `/orgs/<org>/report/<id>` for an org key, `/report/<id>` for a personal key |
| `verdict` | exit 0 for GO, 1 for NO-GO, plus a `SUMMARY` line |

The full report JSON is kept next to the review output as `gaptrap-report.json`.

If the deadline arrives while GapTrap is still checking the template, a NO-GO is reported (the
second write can only add NO-GO) and a GO is reported as an error, never as GO. Either way the spec
stays saved and the next review picks it up for free.

GapTrap sometimes never finishes the second write, for example when its server stops between the
two. Fifteen minutes after the spec was created, the driver takes the first write's verdict, the
same thing GapTrap does when its own template check runs out of time. The `SUMMARY` line then says
`contract extraction never finished`.

## Push, pull and from

`/whip --push` hands the plan to GapTrap so you can read the report there. It reuses the spec that
was already reviewed at these bytes (0 units) or creates one (1 unit). With a personal key the push
says so: only you can open that report, so use an org key if teammates should see it. A push of
bytes whose analysis failed pays for a new attempt, and the next review reads that one.

The driver lists pull and from, but GapTrap cannot serve them yet. It has no MCP tool that returns
spec text or your answers, the Fork editor copies plain text, and Export is shaped by GapTrap's
template. Until GapTrap ships them, `/whip --pull` and `/whip --from gaptrap <link>` stop with
`pull is not offered yet` or `from is not offered yet` and a hint: read the report in GapTrap, then
edit the plan here, or copy the spec's text into a `.md` file and run `/whip <that file>`. Note that
GapTrap's Enrich and Re-analyze rewrite a plan into Feature Contract headings, which a pull would
refuse because `## Deliverables` is gone.

## GapTrap features the driver turns on by itself

The driver asks GapTrap which tools it has (`tools/list`, free) before each paid `create_spec` and
on each push, pull and from, and uses each of these the day GapTrap lists it. There is nothing to configure and nothing to re-add:
the verbs the driver reports never change, so a cached answer cannot hide a new feature.

| When GapTrap lists | You get |
|---|---|
| `get_spec` | Pull as text: the newest version of the pushed spec (drafts skipped), checked against its `contentSha256`, then merged into the plan. From: the exact spec you link, as the start of a new cycle |
| `list_answers` | Pull as decisions: the answers you typed in GapTrap come back as `ANSWER` records tied to the card's findings, and the session folds them in like typed replies |
| `parentSpecId` on `create_spec` | Each re-review continues the plan's lineage in GapTrap, which makes re-analysis free there and stops GapTrap asking questions you already answered |
| `idempotencyKey` on `create_spec` | A reply lost in transit is simply resent: GapTrap hands back the same spec instead of a second charge. A `--fresh` review gets a new key, so it really does run again |

## Settings

All settings come from the environment, or from a gitignored `.env` (every one below except
`GAPTRAP_POLL_INTERVAL`, which the driver reads from the environment only). None belong in the
committed declaration.

| Variable | Default | Meaning |
|---|---|---|
| `GAPTRAP_API_KEY` | none, required | Your key |
| `GAPTRAP_MCP_URL` | `https://app.gaptrap.ai/mcp` | The endpoint. Must be https |
| `GAPTRAP_APP_URL` | the endpoint's origin | The web app used in report links |
| `GAPTRAP_TEMPLATE_ID` | GapTrap's built-in Feature Contract | Review against a custom template |
| `GAPTRAP_FOLDER_ID` | none | File reviews in a folder (org keys only) |
| `GAPTRAP_MODE` | `standard` | `standard` or `multipass` |
| `GAPTRAP_POLL_INTERVAL` | `3` | Seconds between polls |

GapTrap's built-in template requires an outcome, an actor and trigger, and functional acceptance.
The acf plan template carries an `**Actor & trigger**:` line so plans do not get a structural NO-GO
every round. If your plans follow another shape, author a template in GapTrap and set
`GAPTRAP_TEMPLATE_ID`.

## When it does not run

The card shows the first line the driver printed. Exit 3 means the tool is unavailable and the
review is skipped; exit 2 means it could not run and the next card retries.

| First line starts with | Meaning |
|---|---|
| `GAPTRAP_API_KEY is not set` | Step 1 is missing, or Claude Code was not restarted after it |
| `unauthorized` | The key was revoked or mistyped, or the person who minted an org key left the org |
| `plan_required` | The key's account or org is below Solo and has no trial |
| `quota_exceeded` | This period's spec units are used up |
| `spec_too_large` | The plan is over GapTrap's 1 MiB limit |
| `HTTP 404 ... check GAPTRAP_MCP_URL` | The endpoint is wrong |
| `create_spec outcome unknown` | The reply to a paid request was lost. The next review looks the spec up for free before it would pay again |
| `create_spec from Ns ago has not shown up` | That lookup ran too soon to be sure GapTrap made nothing. Review again in a minute |
| `not enough time left` | Under 20 seconds were left, too few to hear a paid request's reply, so nothing was sent |
| `timeout` | GapTrap was still working at the deadline; the next review resumes it for free |
| `failed` | GapTrap could not analyze these bytes; remembered, so it is not retried at a cost |
| `stuck` | The analysis made no progress for 15 minutes; review with `--fresh` to resubmit |
| `pull is not offered yet`, `from is not offered yet` | GapTrap does not list `get_spec` or `list_answers` yet (see above) |

## State

The driver keeps its state in the directory `acfw-spec` gives it (under `.acfwhip/run/spec/`,
which git ignores), one file per exact plan bytes in each folder:

| Folder | Holds |
|---|---|
| `creating/` | a paid request that was sent but not yet answered, by its attempt tag |
| `pending/` | the spec id of an analysis still running |
| `done/` | the spec id of a finished review, re-read for free |
| `failed/` | the spec id of an analysis GapTrap could not do, so it is not paid for again |
| `gen/` | how many fresh attempts these bytes have had (it changes the attempt tag) |

`lineage` lists the specs reviewed for the plan. Deleting the directory is safe; the next review of
those bytes then costs a unit again.

## Testing

`tests/phase21-gaptrap-driver.test.sh` runs offline. It replays GapTrap replies through the
`ACFW_GAPTRAP_TRANSPORT` seam, kills runs with TERM and SIGKILL at the costly moments, and exercises
the real curl path with a fake `curl` while `ps` checks that the key is in no process's arguments.
