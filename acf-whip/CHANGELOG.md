# Changelog — acf-whip

All notable changes to acf-whip. Format loosely follows Keep a Changelog.

## 3.3.1 — two ways to lose work on the default backend

3.3.0 was audited in its own right after release, subsystem by subsystem, with every candidate
defect handed to an independent agent whose job was to refute it. Seventeen survived. **Two of them
lose work on the default `files` store, with no operator error involved, and neither is a regression
from that release — both predate it.** The rest are the same pattern 3.3.0 named and did not finish
draining: a guard, a flag or a test that answers a question it could not actually ask.

**The integrator reverted work it never landed.** After a compare-and-swap onto trunk, `land()`
resynced the root checkout with `checkout --no-overlay -- . ':(exclude).backlog'` — the whole tree.
The exclusion spared uncommitted task-file state, which is what it was added for, and nothing else.
A `Worktree: none` task edits tracked files in that same tree by design, and it does so
*concurrently*: `/go` starts the prior-integrate pass as a floating promise and awaits it only after
the dispatch barrier that runs the direct queue. So a direct task's deliverable was reverted
mid-flight, the backlog writer then staged an unchanged file, the committed-deliverable check passed
against that file's pre-existing history, and the task was reported **accepted and integrated with
none of its content anywhere**. Nothing was logged. The pathspec is now the landing's own
`OBSERVED..NEW` diff; an empty diff skips the checkout rather than degrading to `-- .`, which is why
the guard is a shell test and not an `xargs -r` pipeline (BSD `xargs` has no `-r`). Where a path this
landing *does* change is also dirty the overwrite is unavoidable, but it is reported with a
`stash create` snapshot — a commit object that touches neither the working tree nor `refs/stash`, so
it cannot race a sibling stage the way `clean-checkout.sh`'s `stash push -u` would.

**`doctor --fix` deleted every copy of a duplicated task.** The `dup-folder` repair picked the
survivor by reading `Status` from the first-listed copy and removing everything that did not match
it. That read was never validated, and it has two ways to come back empty: an unparseable `Status`
line — the same malformed copy whose status-sync repair is skipped — or a detail string the `sed`
cannot match, which returns the whole detail and makes the probe path one that does not exist. With
an empty keeper no folder ever matched, the skip never fired, and the loop `git rm`'d all of them;
the `|| rm -f` fallback then unlinked an untracked copy outright, with no history to recover it
from. `/go` runs `doctor --fix` at bootstrap with its output discarded, so this also erased the FATAL
that should have stopped the run before it dispatched. A repair that cannot identify the survivor is
not repairable: it emits `FATAL|dup-folder-unresolvable` and leaves every copy intact. The repair had
**no test at all**; it has five now.

**A lost clean-checkout token was a permanent fixed point.** A missing token on a task that *does*
have a worktree branch is mechanical, so the review gate left it in `in-review/` for the next
iteration. But nothing in the loop can write a token: `clean-checkout.sh` is its only writer and it
runs at dispatch, and the reviewer is explicitly forbidden from writing one. So the task sat in
`in-review/` across every future run, the run ended `no-progress` with committed work never
integrated, and the slug claim starved every same-slug sibling for the whole run, every run. The arm
re-reviews once — enough when the cause was a lost `append_log_row` race — then parks the task in
`blocked/` as `needsOperator`, charging no rejection for a fault the orchestrator could not write its
way out of. Its most common cause is fixed at the source: `clean-checkout.sh` discarded the store's
return code, sent the adapter's diagnosis to `/dev/null` and exited 0, while on a non-`files` store
that call is the **only** durable write of the token. It now retries the contract's transient code
and only that one, and exits 6 rather than printing a worktree path as though the token were
recorded. Linear's `issue_has_token` was the one `gql` caller in that file not propagating
`GQL_ERRCODE`, so a single 429 read as "this specialist never entered a worktree"; multica's two paid
fallbacks had the same shape, having been missed in 3.3.0 because they answer through the token list
rather than through the metadata helpers that release made tri-state.

**A scoped `/go` called an unknown state complete.** `expandScope` refused a seed by enumerating
`draft` and `archive`, but the enricher defines the inactive set by *exclusion* — so a card whose
state is absent or out of vocabulary has no folder at all and sailed through. The scheduling view
came back empty, and an empty scoped view reports complete: "Backlog 100% terminal", zero agents,
`integrated: []`. Byte-for-byte the failure already fixed once for `draft`. The scheduling view is
passed in and asked directly now; terminal seeds stay exempt so scoping to collapsed-accepted work
still resolves.

**The legacy loop integrated nothing.** Step 4.5a filled `INTEGRATE_QUEUE`; Step 4.5b iterated
`SORTED_QUEUE`, which is assigned nowhere in the plugin — so `integrate-lpcas.sh` never ran, no
ledger marker ever landed, the terminal count could never reach total, and every deliverable stayed
on an unmerged branch. This is the fallback path 3.3.0 deliberately routes operators into when the
Workflow tool refuses a launch. Step 4.5a also promised a topological sort in prose and did not
perform one; it does now, with a cycle emitting its members in input order rather than stranding
them. The static gate that should have caught this enumerated two variable names; it derives them
from the skills now, and on the previous tree it names `INTEGRATE_QUEUE`.

**One unreadable document blanked the whole session payload.** 3.3.0 guarded the artifact sync loop
because the hook had just gained destination-side I/O. It did not cover the second read: `main()`
opens `docs/acf/style/task-descriptions.md` again to build the payload body, inside its single `try`
— and that file is the *first entry in the managed list*, the document the refresh mechanism
explicitly invites consumers to edit. One cp1252 smart quote and the catch-all replaced the entire
`additionalContext` with an errno string, dropping the mandatory style guide, the task-store warning
and the could-not-sync notice together, on every session, permanently. The existing bad-byte fixture
wrote to `workflow.md`, the one managed document *not* read twice, which is why it passed while this
was live; there is a fixture per managed destination now. The recovery runbook also joins the managed
set — `whip-init` installs six documents and that list carried three, so a pre-LP-CAS runbook telling
an operator to rebase a worktree branch could age in place forever.

**Also**: `--quiet` was honoured by the adapter half of a merged doctor report and nowhere else, so
hundreds of advisory WARNs went through the scan agent every iteration against the bound
`workflow.md` states as a requirement — it is peeked rather than consumed now, filtered at print
time, with the tallies over the unfiltered set so it can never change the gate decision;
`ACFW_INPROGRESS_TIMEOUT_HOURS` had its documented env-over-config precedence inverted by the same
source-the-config trap the file documents nine lines above for `ACFW_INTEGRATION_MODE`, so one run
could time a task out in the scheduler while its own doctor reported nothing; an `agentCap` at or
below the fixed 150-agent reserve made the CLOSE rung fire at *zero* agents used, reporting
`agent-cap-reached` and "Nothing lost." for a run that dispatched nothing — and that rung is not
gated on `ESCALATE`, so `escalate: false` hit it too; `research-agent-pattern.md` told non-code
agents the materialized spec is "a materialized copy the orchestrator syncs back", which nothing
does, so an agent that believed it lost its whole deliverable; and `/whip-add-agents` re-rendered the
265-line sample over `.backlog/README.md` to change one line, replacing the team's gate commands and
thresholds while reporting only "(agent list updated)".

**`beads` is no longer the backend nothing can test.** multica funnels every call through
`ACFW_MULTICA_BIN` and linear through `ACFW_LINEAR_TRANSPORT`, which is what let 3.3.0 run the frozen
conformance spec offline against a fake CLI. beads resolved `bd` straight from `PATH`. It has the
seam now, and a static gate holds all three — the fake `bd` that makes its suite run offline is the
remaining work, and the seam is what unblocks it.

**Two tests in this release could not fail.** Linear's "`--quiet` keeps every FATAL" compared 0 to 0,
because no fixture in that suite ever produced a FATAL — reverting the adapter's `--quiet` branch to
its v3.2.3 shape still went ALL GREEN. And the small-cap escalation test asserted that a cap of 10
makes the ladder "fire immediately", which was the defect stated as a requirement. Every fix above
has an assertion verified to go red when the fix is reverted.

Deferred deliberately: `--digest` is a no-op on every non-`files` backend (the dispatcher never
passes the flag to the enricher, and the enricher never collapses terminal-accepted into
`satisfiedDeps` the way the `files` scanner does), so a large board relays its whole snapshot through
one agent's structured output. The fix is not patch-sized — it needs flag plumbing, a three-way split
so an accepted-but-unintegrated task stays a full object, and counts taken before the collapse — and
it lands in 3.4.0 with the `--only` filter, which shares its measurement.

## 3.3.0 — the non-`files` backends stop being invisible

Every defect in this release was found against a live non-`files` store, and they share one cause:
**`files` is the only backend the test suite could see.** `run-all.sh` marked the three adapter
suites OPTIONAL, each skipped unless a live server was reachable, and the runner counted a `SKIP` as
a pass — so the backends were green by absence on every developer machine and in CI. The contract's
own executable spec, `phase9-store-conformance.test.sh`, defaulted to the `files` adapter: the
"executable spec" only ever ran against the one implementation that already worked.

That is fixed first, because nothing else in this list could have been caught without it. The
multica suite now writes an offline fake of the CLI — injected at the `ACFW_MULTICA_BIN` seam the
adapter already funnels every call through, the same shape the Linear suite has used for its GraphQL
emulator since 3.1.0 — and runs the frozen conformance spec with no server, no credentials and no
skip. Fixing the runner's skip detection then un-masked the Linear suite, which had been reported as
skipped (and therefore could not fail) merely because it skips its live-server half. Both are now
first-class; only `beads` still skips, because it needs a real `bd`.

**The orchestrator charged a spurious rejection to every code task.** `runReviewAndIntegrate` has two
callers with opposite freshness guarantees, and its deterministic clean-checkout gate assumed the
fresh one. On the inline path the task object is the one the scanner produced *before* this iteration
dispatched the implementer, so on a first attempt both `hasCleanCheckoutToken` and
`hasWorktreeBranch` are false — and false-with-no-branch is the gate's most destructive arm. Every
code task, on every backend including `files`, was hard-rejected on its first completion and charged
one of its three lives, then recovered next iteration once the branch existed. The recovery is why
this survived undiagnosed since 3.2.0. The gate now applies only where the scan observed the task
*after* the implementation ran; a specialist that genuinely skipped clean-checkout is still caught by
the reviewer's own rule on the live document. The auto-reject was also the one unlogged outcome in
that function and appeared in no run tally, so a run could reject everything it dispatched and still
report `completed: true`.

**`/whip-doctor --fix` destroyed deliverables on non-`files` stores.** `doctor.sh` is the `files`
engine: every task check is gated on a `.backlog/<state>/` directory, so on another backend all of
them were skipped and the summary reported `ok=true` against zero evidence. The worktree pass is not
gated — it built its live-slug set from the now-empty task table, concluded every acf-whip worktree
was orphaned, and under `--fix` ran `git worktree remove --force` plus `git branch -D` on each. In
override mode that branch is the operator's only copy of an accepted-but-unintegrated deliverable,
which `doctor.sh` says in its own comment. Both it and `scan-backlog.sh` now refuse when the resolved
store is not `files`, on stderr, with no parseable output — a refusal a caller could read as a clean
report is the same defect one layer up. Every skill that invoked a battery by path now goes through
the dispatcher, and a static gate keeps it that way.

**Absence of findings was treated as health, in four places.** The dispatcher discarded the adapter
doctor's exit status (it took the pipe's) and turned a failed snapshot into a WARN, so an unreachable
backend, an expired token or a crashed adapter produced `ok=true`, `exit 0` — and `/go`'s startup
hard gate dispatched against a board nobody had read. `beads`' doctor skipped its entire per-issue
battery on a failed export with no `else`; its `read --materialize` silently omitted the audit trail
the reviewer greps for the clean-checkout token, which reads exactly like a task that never ran it.
Linear's `gql` returned success on a body that was not JSON at all. All four now say so, and the
dispatcher reports a battery that could not run as `FATAL|doctor-unavailable` rather than as silence.
`/go`'s gates tell the operator which failure they hit, because "the backlog is inconsistent" sends
someone whose store is unreachable to a tool that also cannot reach it.

**Transients were written into durable state.** multica's metadata helpers answered a three-valued
question — the key holds X, the key is absent, I could not ask — with one value, so any timeout or
5xx was indistinguishable from "absent" and the read-modify-write callers wrote the fabrication.
Demonstrated against the offline fake, with the fault targeting only the read so the write path stays
live: a rejection counter went from 2 to 1, and a dependency list of three entries collapsed to the
one being added. A third case made the idempotence guard miss and re-ran a transition that had
already landed. Both helpers are tri-state now and the four call sites refuse rather than write.

**One inert card gated a whole board.** multica reported any `whip_state` outside the canonical nine
as a FATAL. But the scheduler dispatches on exact state equality, so a card in a state it does not
name can never be dispatched, transitioned or integrated — it cannot make a run wrong. It is a WARN
with the retire command in the detail. Relatedly, both doctor batteries computed "is this a gate
FATAL?" as `folder == accepted`, which is right on `files` (whose scanner never emits `draft` or
`archive`) and wrong everywhere else, where the adapter lists them: a draft stub with no agent file
produced `FATAL|unknown-agent` and blocked `/go` outright. The tier is now the real question — is
this task in the dispatch path? — and `draft`/`archive` move to a sibling `inactive[]` array that
dependency resolution still sees but nothing schedules, counts or checks. A task depending on a draft
now reports `WARN|dep-inactive` with the remedy instead of `FATAL|dangling-dep`, which was a lie.

**`--quiet` hid the gate decision.** Both API adapters suppressed every finding line, FATALs
included. Without `doctor-complete` the dispatcher recomputes `ok=` from the lines it receives, so a
swallowed FATAL became `ok=true` for the startup gate and every recheck — while the verbose
`/whip-doctor` path showed the same FATAL. That is how one backlog produced two contradictory
verdicts on the same day.

**`hasCleanCheckoutToken` was answered for one or two states.** The contract defines it as a flat
per-task boolean, and two consumers read it. multica answered it for `in-review` alone, so every task
lifted from `completed` into review read its token as absent and had its review skipped. Widening it
there is free — since 3.2.0 the transition log lives in the issue description, which the snapshot
already fetches — and it removed a quadratic re-parse at the same time. Where each answer costs a
request, the paid set is bounded to the states where a wrong answer costs something now, and the new
`token-all-states` capability is what lets a consumer tell "no token" from "not scanned": without it
every finished task on Linear carried a permanent false advisory.

**The plugin could not fix a document it had already shipped.** The SessionStart hook copied three
plugin-owned documents into a consumer project and never looked at them again, so every correction
made here aged in place in someone else's repository and was attributed to their own documentation —
the mechanism behind the whole shipped-template defect class. The obvious fix does nothing on the
release that introduces it: stamp a version, compare, upgrade, but every existing copy predates
stamping and an unstamped file must never be clobbered. So a pristine copy is now recognised by its
**content**: `content/.digests.json` carries the sha256 of every version of each managed document
this plugin has shipped, and a local copy matching any of them is refreshed. One matching none was
edited by hand, is never touched, and is reported as behind.

**What the plugin ships now agrees with what it requires.** The reviewer template argued with itself
— its first section ordered the reviewer to move task files, Step 10 two hundred lines later said it
must not — and obeying the first is worse than useless: the writer is idempotent, so a task the
reviewer already moved makes the transition a no-op, which silently drops the rejection increment.
It told reviewers to escalate at five rejections while the orchestrator blocks at three, making the
branch unreachable. `research-agent-pattern.md` instructed a non-code agent to move and commit its own
task file and never mentioned `deliverableFiles` at all — the one field standing between a research
document and the next `clean-checkout`. Eleven templates hardcoded `.backlog/` with no indication
that it is one backend's layout. And `workflow-architect`, selected by `/go` since 3.2.0 and
documented in three places, was created by no installer — so the headline capability degraded to the
default agent on every project, silently, for two releases. It now exists, `whip-init` installs it,
and its absence is logged and reported. `phase17-template-drift` pins all of this to values read from
the runtime source, so the test cannot drift away from what it guards.

**`derive_slug` truncated ids.** Its fallback matched four digits followed by an unanchored `.*`, so
`bug-62015-alpha` and `bug-62017-beta` both derived `bug-6201` — two tasks on one worktree branch,
which is the one thing a per-task slug exists to prevent. The sequence number is unbounded and
anchored now, an id the pattern cannot account for gives up rather than matching a prefix of itself,
and a collision is a FATAL naming both. The category vocabulary gains the conventional-commit types
beyond the original eight, and its two implementations are pinned to each other.

**Doctor cost, measured.** No board above 337 tasks had ever been timed, so "more than ten minutes"
could not be attributed. At 600 tasks the two superlinear graph passes are **not** the bottleneck:
memoising the dependency resolver and inverting the glob-overlap pass from pairwise to indexed moved
wall-clock by about 3%. What they fixed is the output — one advisory per overlapping *pair* meant 120
pending tasks produced 541 lines to read past, now 121. The win is `--active-only` on the bootstrap
re-scan: 30.4s to 8.7s, from one word, with a byte-identical FATAL set, which `doctor.sh`'s header has
promised since 2.x. `tests/perf-doctor.sh` records the baseline. Batching the per-file extraction is
the next real win and is deliberately not attempted: rewriting that layer earns its risk against a
measured need, and 8s at 600 tasks is not one yet.

**Also**: `/go` and `/task` launch by registered name rather than by a path under the plugin cache,
which the Workflow tool refuses for anyone who installed this plugin normally; the legacy fallback
loop they now route into actually runs (it used bash 4 associative arrays, and dropped every non-code
task into an array nothing read); `args.maxReject`/`args.maxBlock` bind all four cap decision sites,
not the one that already accepted them; `args.planners` is finally passed through; `/task`'s scratch
directory moves under the already-ignored `.acfwhip/run/`; and `doctor --snapshot FILE` lets a caller
with a full snapshot spare the dispatcher a second store walk, refusing a narrowed or digest one as a
usage error because the graph invariants cannot be computed from a subset.

**Reviewed before shipping, and it mattered.** The diff above was put through an adversarial review
of its own, and thirteen follow-up commits landed before release. Three were regressions this work
introduced: the SessionStart hook gained destination-side I/O with no per-artifact guard, so one
non-UTF-8 byte in a document the release invites consumers to edit discarded the entire session
payload; `--active-only` on the bootstrap gate silently dropped the two content-loss FATALs, which
are the ones that mark a destroyed document; and unioning `inactive[]` into the dependency index made
`/go <a-draft-task>` answer "complete" instead of "not actionable".

The rest were a single pattern worth naming: **a guard that reports success on the exact condition it
exists to catch.** The derived-slug registry was a shell variable assigned inside a command
substitution, so it never accumulated and its FATAL was unreachable. The four new multica read guards
interpolated a variable set in a subshell, printing a dangling colon instead of the backend's error.
`run-all.sh`'s write-only-array gate used `grep -c` with `|| echo 0`, producing `"0\n0"` and an
arithmetic abort, so it could not fail for any input. The reviewer's clean-checkout backstop — cited
in a code comment to justify weakening the deterministic gate — greped for a row the reviewer's own
Step 0 writes. And five assertions, including two written as proof that these fixes work, passed with
the code under test deleted.

Every fix above now has an assertion verified to go red when the fix is reverted.

All contract changes are additive; `ACFW_CONTRACT_VERSION` stays `1`.

## 3.2.3 — /go can be pointed at part of the backlog

`/go` took the whole backlog or nothing. There was no way to say "run these two tasks" — not an
argument, not an env var, not a config key, not an adapter flag. `skills/go/SKILL.md` was the only
whip skill with no `argument-hint`, `whip-go.workflow.js` read thirteen args and none of them
selected tasks, `scan-backlog.sh` parsed three flags, `adapters/CONTRACT.md` had no filter verb, and
the multica adapter's `cmd_snapshot` says outright that its flags "are hints; a full snapshot is
always valid". This was never a regression: no revision of the skill or the workflow has ever
supported it.

The cost was not ergonomic. On a backlog shared by a team, one person's `/go` is everyone's `/go`,
so people stopped running the shipped orchestrator and hand-authored throwaway workflows instead —
which needs a frontier model to write, every time, for work the plugin already does.

**`/go` now takes arguments, in two forms that resolve to one mechanism.**

```
/go                                          every actionable task (unchanged)
/go api-014-token-refresh ui-021-login-form  exactly those, plus their unmet dependencies
/go frontend tasks only                      everything a frontend agent owns
/go bugfixes                                 the fix/bug tasks
```

Ids pass straight through. A natural-language filter is matched **in the skill, once, before
launch** — against the fields every backend's snapshot already projects (`agent`, `slug`,
`priority`, `stem`, `touchesGlobs`) — then shown to the operator and confirmed. The workflow
receives a concrete stem list either way, so the orchestrator stays deterministic and the selected
set cannot drift mid-run. Passing the predicate down and re-evaluating it per iteration would have
cost an agent call each time and reintroduced exactly the unpredictability that drove people off
`/go` in the first place. There is no title or body in the snapshot; a predicate that cannot be
decided from the projected fields asks for ids rather than guessing, and a filter that matches
nothing stops instead of falling back to the whole backlog.

**The index stays whole; only the scheduling view narrows.** The obvious implementation — filter
`tasks[]` — is wrong, and quietly so. `tasks[]` is the bounded working set that `indexTasks` builds
dependency resolution from, and `depsSatisfied` treats an unresolvable dep token as dangling and
refuses to dispatch (conservative by design, and the doctor FATALs on the same condition). Narrowing
the array would therefore strand every scoped task that depends on something outside the scope. So
`idx` is built from the full set and a separate `sched` view feeds the six planning sites — the
unblock/timeout plan, the in-review, completed, pending and rejected queues, and the integration
candidates — and nothing else.

**Completion is counted over the scope.** `total`/`terminal` came from `snap.counts`, which is
store-wide; reusing it for a scoped run makes `terminal === total` unreachable, so the run would
burn all fifteen `NO_GAIN_LIMIT` iterations and exit `no-progress` having done its work. A scoped
run counts `isTerminal` over its own tasks, and a scope that is already entirely terminal stops
immediately rather than spinning past the `total > 0` guard.

**Unmet dependencies are pulled in, terminal ones are not.** `expandScope` walks the seed's
transitive deps and adds any that are not terminal, so a scoped task cannot sit gated forever behind
something the operator forgot to name; an accepted-and-integrated dep needs nothing and is left
alone. Cycles terminate. The pulled-in stems are named in the run log and in `scopeResolved`.

**Nothing outside the scope is touched** — not dispatched, not transitioned, not integrated,
including by the post-loop drain, and `needsOperator` is filtered to the scope too. That is what
makes a scoped run safe against a backlog other people are working in. An id matching no task aborts
the run (`stopReason: 'scope-unresolved'`) instead of silently running less than was asked for.

The `RunReport` carries `scopeFilter` (the operator's words — the only record of a natural-language
filter, since `only` holds resolved stems), `scopedTo` and `scopeResolved`. With no arguments every
one of these is null and behaviour is byte-identical to 3.2.2.

Scoping is not a fix for the deeper hazard it makes visible: on a shared non-files backend the run
lock is still per-checkout and `transition` is still a read-modify-write with no compare-and-swap,
so two runners can still collide. Scoping reduces the odds by keeping runners out of each other's
tasks; the `atomic-claim` capability named in `CONTRACT.md` remains unimplemented.

New suite `tests/phase14-go-scope.test.mjs` (37 assertions) covers `expandScope` through the same
`<scheduler-pure>` extraction phase2 uses, and guards the wiring structurally — the two ways this
feature breaks silently are a planning site reverting to `tasks` and completion reverting to
`snap.counts`, neither of which fails visibly at runtime.

## 3.2.2 — the transition writer stops destroying the task it is moving

A `/go` run aborted at iteration 4 with two FATALs about missing metadata fields. The task file
behind them had been 17507 bytes and 219 lines one commit earlier; it was now **267 bytes and one
line** — a single transition-log row. The row was the one that transition was itself writing, and
`apply-transition.sh` committed the wreck twenty lines after producing it. Nothing warned, nothing
failed: the writer moved the file, staged it, and committed it exactly as if the transition had
worked. Reported from a downstream project (`docs/research/20260824-acf-whip-task-file-clobber.md`),
whose diagnosis of the blast radius and the manual repair was correct.

**`append_log_row` could write a file's replacement from a read that returned nothing.** It is a
read-modify-write: awk reads the task file, and the result replaced the original. Run it against a
file some other process had momentarily emptied and awk emits *only* the new row — no table was
seen, so the terminal clause appends one. `[ -s "$tmp" ]` then passes, because a row is not empty.
The `else` fallback was no safer: `printf '%s\n' "$row" >> "$file"` **creates** the identical corpse
from an empty or absent file. Both guards admitted the wreck; one of them manufactured it.

Worth being precise about what was *not* wrong, because the field report guessed and the guess
implies a different fix: a **table-less** input was always handled correctly. Every non-table line
reaches an unconditional `print`, so such a file is emitted in full with the row appended at EOF —
the documented legacy behavior, pinned by a test since 2.1.0. **Only a zero-byte read** produces a
lone row. Guarding "no table" would have fixed nothing and broken a tested path.

Four changes make the function structurally incapable of shrinking a file:

- It **refuses** an absent, empty, or whitespace-only target up front, and again inside awk
  (`END { if (NR == 0) exit 3 }`) so the gap between the two checks is closed rather than trusted.
- The write-back is an **atomic same-directory rename**, not `cat "$tmp" > "$file"`. That matters
  twice over: `>` truncates in place, so the old code was *itself* a zero-byte window for every
  other reader — the doctor's field lookups, `scan-backlog.sh`, the reviewer's token grep. Every
  other task-file writer in the tree already used temp-plus-rename; this one function did not. The
  temp must be born beside the target, because `$TMPDIR` is a different filesystem from the repo on
  macOS and `mv` across one degrades to copy-and-truncate — reopening the window being closed.
- A **first-line comparison** before the rename. onetrueawk does not report a stdout write error, so
  a full disk could otherwise rename a half-written file over a good one.
- The EOF fallback now runs only against a file the refusal gate already proved healthy.

It returns `0` / `3` (refused, file untouched) / `1` (environmental, file intact, row not written),
and never `2`, so a refusal can never be misread as a usage error. All four call sites opt in
individually: a lost *log row* must not strand a state *move*, so the two shell callers warn, while
the two adapters fail.

**`apply-transition.sh` will not commit a corpse.** The truncation was the accident; committing it
was the defect. This writer ran `sed`, `append_log_row`, `mv`, `git add`, `git commit` with no
content assertion anywhere. `assert_task_intact` now brackets the mutations — once on entry, once
immediately before the move — and refuses with a new **exit 4**, leaving the file where it is,
nothing staged, nothing committed, and the recovery command printed. The two call sites are kept
apart deliberately: *on-entry* means someone else broke the file, *pre-commit* means it broke under
this writer, which is a live concurrency fault worth chasing. The files adapter maps 4 to contract
exit 7 ("invalid state or value") — not contract 4, which means "conflict (duplicate key)" and would
send an operator hunting a duplicate id that does not exist.

**`collapsed-task-file` is now its own FATAL.** The doctor reported the wreck as
`unparseable-frontmatter` plus `missing-worktree-slug`, which reads as *someone fat-fingered the
metadata* and sends you to re-type two fields — when the whole document is gone and is sitting one
commit back in git. The discriminator is unmistakable and costs nothing on the happy path (it runs
only for a file that already failed the field lookup): no `#` heading, and every non-blank line a
table row. It is FATAL even in `accepted/`, skipping the usual terminal-tasks-are-advisory tier,
because this is content loss rather than a structural quirk. Deliberately **not** `--fix`-able, for
`control-bytes`' reason: restoring from `HEAD` would silently discard the clean-checkout token row,
which is uncommitted by design, and `--fix` must never commit a torn write as "healed".

**Also fixed — the LP-CAS integrator's root resync, which was two bugs sharing three lines.**
`land()` advanced trunk and then resynced `ROOT` with `git reset --hard "$TRUNK" >/dev/null 2>&1 ||
true`. Between those two statements — and permanently, whenever the resync failed, since
`git_with_lock_backoff` returns 99 under lock contention and `|| true` ate it — **ROOT's index held
the old tree while HEAD pointed at the new one**. Any `.backlog` commit landing in that gap builds
from that index and produces a commit whose parent is the integration and whose tree is its
predecessor: it silently reverts every code change just landed. The index repair is now
unconditional and its failure fatal. Separately, `reset --hard` rewrote `.backlog/` as well,
discarding uncommitted task state at the root — the clean-checkout token (which the files adapter
calls uncommitted *by design*, and whose loss `/go` already works around as a "mechanism" fault) and
any operator repair made between runs. The worktree half is now
`checkout --no-overlay "$TRUNK" -- . ':(exclude).backlog'`, provably a no-op on committed content:
`strip_backlog_from_index` restores `.backlog` to `OBSERVED`, and the compare-and-swap only lands if
trunk is still exactly `OBSERVED`, so the two `.backlog` trees are identical and excluding it can
only spare uncommitted work. **`--no-overlay` is load-bearing and so is the order.** Overlay mode —
the default — never removes files, so an integration that deleted or renamed a path would leave a
resurrected copy on disk, invisible because `git status` shows it as `??` and the `dirty-trunk-root`
check skips `??`. And the checkout must run *before* the index reset: reset first and the deleted
path becomes untracked at that instant, after which checkout can no longer remove it.

**Also fixed — `strip_backlog_from_index` leaked additions.** It used `git checkout <tree> --
.backlog` in overlay mode, so a candidate that *added* a `.backlog/X.md` absent from the observed
trunk survived the strip, was picked up by the following `git add -A`, and rode into trunk. That is
precisely the phantom the function exists to stop: deletions and modifications were reverted,
additions were not. A failed strip is no longer swallowed either — it quarantines the candidate.

**Also fixed — the same clobber on the multica backend, with no concurrency required.**
`jq -r '.description // ""'` yields a zero-byte file for an issue with no description; the old
`append_log_row` wrote its row into that void, so the `[ -s "$desc" ]` guard below it *passed* and
the adapter replaced a live issue description with one log row. The refusal closes it; the guard is
finally meaningful rather than defeated.

**Deliberately not done.** A real mutex shared by every `.backlog` writer. It is the only thing that
would close the remaining hole (below), and it is not obviously worth its cost: macOS ships neither
`flock(1)` nor `lockf(1)`, so it means a hand-rolled `mkdir` spinlock with stale-lock reaping across
agents that get killed mid-run — a new wedging failure mode in a system whose stated design is that
the lock is git itself. Also not done: `--fix` auto-repair of a collapsed file from git history, for
the reason given above.

**What is still open, stated plainly.** A *partial* (non-empty) read is not covered: `- **ID**:` and
`- **Status**:` sit in the first few lines, so a file truncated in its tail passes both assertions
having lost its body. Concurrent writers still lose a *row* to last-rename-wins — neither destroys
the file, and the multica adapter has documented that parity since 3.2.0. And `evidenceSink` /
`reviewSink` still instruct agents to write the live task document; the two changes above make that
non-destructive without stopping it. The emptier in the original incident was never identified —
there was no `reset --hard`, no stash and no integration within minutes of it, so the surviving
candidates are a sibling `append_log_row`'s own truncation window and an agent's Write. The fix is
deliberately mechanism-agnostic for that reason: it defends the read, not one particular racer.

`tests/phase11-checkout-reentrancy` has launched two concurrent `clean-checkout.sh` against the same
task file since 3.2.0 and asserted only their exit codes — the suite ran the corruption scenario and
looked away from the file. It now checks the file. Regressions also cover the refusal paths, the
rename (by inode), the collapse discriminator against both a corpse and an ordinary field-less file,
`--fix` declining to heal it, temp-file invisibility to every `*.md` consumer, the multica empty
description, and an integration that deletes a file while `.backlog` is dirty. Suite: **754
assertions**, green on stock macOS bash 3.2 with BSD sed/awk.

## 3.2.1 — the integration mode is a setting, and override mode survives a run

Override (PR) mode was documented since 2.x and reachable in practice by almost nobody. Selecting it
was an LLM judgement made per run from `CLAUDE.md` — `skills/go/SKILL.md` said so outright ("no plugin
code special-cases the override") — and the legacy loop's `ACFW_INTEGRATION_OVERRIDE` switch was read
in three places and **assigned nowhere in the tree**. For a team with a protected trunk and review-gated
merges, one misread of project instructions folded accepted work into trunk past review. Reported by
@golb, who found the read-with-no-writer by grepping the full tarball; the pin below is their design.

**`ACFW_INTEGRATION_MODE` pins the mode** — env var or a key in the committed config, resolved exactly
like `ACFW_STORE` (env > config > unpinned) and reported by `acfw-store info` as `integrationMode`.
Unpinned keeps the prose fallback, so existing projects behave identically.

Pinning it, though, only made a **broken** mode reliably reachable. Three defects meant override mode
had probably never completed a multi-task run:

- **The legacy loop still auto-integrated.** `ACFW_INTEGRATION_OVERRIDE` gated the terminal counts and
  the post-loop drain, but *not* Step 4.5 — the pass that actually cherry-picks. Its skip was prose
  addressed to Claude. So a correctly-pinned override run changed how tasks were counted and nothing
  about where the code went. The guard is now executable.
- **The run aborted on the first cross-slug dependency.** In override mode the scheduler deliberately
  dispatches a task whose cross-slug dep is accepted-but-unintegrated (`depsSatisfied` blocks only in
  default mode), but the doctor was mode-blind and called exactly that `FATAL|cross-slug-dep-not-
  integrated` — and a mid-run FATAL aborts before dispatch. Scheduler and doctor disagreed by
  construction: the same defect class the 3.0.1 `integGate` fix closed for default mode. Both doctors
  now take `--mode` (defaulting to the resolved pin) and relax the gate in lockstep.
- **`doctor --fix` deleted the branch you were going to PR from.** `accepted` was excluded from
  `LIVE_SLUGS`, so an accepted task's worktree was an orphan and `--fix` ran `worktree remove --force`
  + `branch -D` on it — unpushed, at every `/go` bootstrap. Harmless in default mode (the change is
  already on trunk); in override mode it destroyed the deliverable's only home. Darkly, it was also
  what "healed" the FATAL above. Accepted slugs now stay live while the operator owns integration.

An **unrecognized value is FATAL** (`acfw-store` exits 2 on every subcommand, not just `info`) rather
than degrading to unpinned with a warning. Degrading flips delivery semantics anyway — back to the
model judgement the pin exists to replace — and the warning lands on a shell-runner agent's stderr
inside an unattended run where nobody reads it. This is not a corner case: the config parser strips
quotes and trailing whitespace but **not** a trailing comment, so `ACFW_INTEGRATION_MODE=override
# PR per group` was an unrecognized value that read as a pin.

Also: the mode is exported through the adapter env contract and the workflow's agent `ENV` prefix, so
every doctor/scan/integrate call resolves the same value the orchestrator is scheduling under (additive
— `ACFW_CONTRACT_VERSION` stays `1`); `/whip-init` scaffolds the key, commented, in both config homes;
the pre-loop switch derivation moved after the detached-HEAD refusal and became `if/fi` rather than
`[ ... ] && export`, which evaluates to exit 1 whenever the mode is not override; and
`content/backlog/README.sample.md` no longer tells projects that integration is "project-decided",
which has been false since 3.0.0 and is the likeliest source of the original expectation.

**Deliberately not done:** pushing, `gh pr create`, PR-state-aware terminal checks, and reading
`PR Group` (still stored, still drives nothing). Override mode stops at accepted and gets out of the
way. Also unchanged: `.backlog/` state transitions are committed on the trunk branch in **both** modes
(`apply-transition.sh` refuses to run off-trunk), so a files-backed run puts bookkeeping commits on
local trunk regardless of mode — the answer there is a non-files task store, where task state lives
outside git entirely.

`tests/phase13-integration-mode` covers the precedence chain, the FATAL classes including the
trailing-comment case, and a fixture-level regression for each of the three defects above (28 checks).

## 3.2.0 — per-task authored child workflows (locked skeleton, open body)

Until now every dispatched unit — a one-line config bump and a cross-cutting refactor alike — was
executed by **exactly one `agent()` call**. The orchestrator's loop was good; the leaf was not. There
was no model, effort, depth or fan-out variation, and `specialistPrompt` did not even inject the task's
description or acceptance criteria: it passed a file path and let a single agent read it.

Each unit now runs as **its own nested workflow**, whose harness a **workflow-architect** agent authors
for that specific task. `/go` calls `workflow({scriptPath})`; the child's return value is consumed
exactly where a single specialist's return value used to be.

**Locked skeleton, open body.** A shipped, unit-tested skeleton
(`skills/lib/child-skeleton.js.tmpl`) owns everything that must not be authored away: the `meta` frame,
the single `clean-checkout`, the `runStage`/`runWave` primitives, the progress ledger, the budget guard,
the fault typer, the commit verifier, the review-panel arithmetic and the sole `return`. The architect
fills exactly **four marked regions**, and a shipped validator byte-diffs every locked segment before
`/go` will run the file.

Free-form generated harnesses were designed and rejected. Their own premortem was fatal, and the
keystone defect *inverted* the durability requirement: two competing resume mechanisms cancelled, the
script skipped a stage and returned `null`, and the first `null` deref made every resumed harness
return `'none'` forever — a counter-free infinite task cycle. Constraining the mutation surface to four
regions collapses roughly fourteen generated-code throw classes to about one, which is what lets the
repair loop converge.

**Durability across a throw** (the binding requirement). Each stage's own agent appends to a stage
ledger — the agent, because a workflow script has no filesystem, which is exactly why the record
survives both the script throwing and the architect's repair edit. When a child throws, a scout
reconciles that ledger against git and the architect is re-invoked with the completed-stage set; the
amended run replays those stages in **zero agents**. Reconciliation trusts a commit-bearing entry ONLY
when git confirms it with an `ACFW-Stage:` trailer, and every disagreement resolves toward an
**informed re-run**, never toward a skip — double-applying a stage is worse than re-running one.

Convergence is **measured, not counted**: another amend round is granted only if the last one moved the
ledger or the branch, or changed the pre-flight error. `MAX_AMEND=2` is the ceiling, rarely the cost.

**The default harness is deliberately shallow** — checkout, implement, a bounded gate loop, adversarial
diff review, verify. Those five hold the only three mechanisms a script structurally buys over one
strong agent: a schema-**observed** advance condition (one agent conflates "I ran the gates" with "the
gates passed"), a fresh-context reviewer of the diff, and a durable ledger. The architect is told that
keeping this shape and declaring `shallow: true` is a *correct* answer, and `escalation.shallow` is
reported so you can see whether it takes the invitation.

**The worktree contract**, forced by the code rather than chosen: `clean-checkout.sh` is not reentrant.
Its exit-2 mutual exclusion fires only on worktree *creation*, so a second invocation against a live
worktree sails past it into `git stash push -u … || true` and silently sweeps a sibling stage's
in-flight work into the **shared** `refs/stash`. Therefore exactly ONE `clean-checkout` per (task,
attempt), in the locked prologue, guarded by an **observation** (`git worktree list --porcelain`) rather
than a ledger record — a lost ledger entry must never be able to trigger a second stash. Only one agent
may write the tree at a time, and "write" includes running the build or test suite. `runWave` forces
mutating stages sequential, so the rule is structural rather than a prompt request.

**Seams.** Implementation and LP-CAS conflict resolution escalate by default. Conflict resolution fans
out READ and fans in WRITE: analysts are read-only and never `git add` (staging clears a path's unmerged
state regardless of content, and the integrator's completion oracle is exactly that state being empty),
then one stager touches the enumerated paths. The resolver is **not** escalated inside
`priorIntegratePass`, which runs concurrently with the dispatch wave. The **multi-lens review panel
ships off** (`args.escalateReview`) — it is the only *subtractive* seam, and it runs against a hard
3-rejection terminal. When enabled, aggregation is strict majority with **no veto**, and
`rejectionIncrement` is clamped so a panel of any size costs at most one life per round.

**Survivability.** The runtime caps total agents per run and children share the counter, so the parent
keeps its own ledger and degrades FULL → LEAN → DIRECT → CLOSE. CLOSE trims new dispatch *before* the
pre-move (a task moved to in-progress and then abandoned would sit there until the 8h sweep) and
**breaks** rather than returns, so Drain and the unlock still run and the report is clean. The dispatch
wave is chunked and try-wrapped: a cap exception is thrown at the top of `parallel()` itself and,
uncaught, would escape the loop and the script — no report, no unlock, lock held 30 minutes.
`LANES = max(2, POOL-2)` is safe under both readings of whether a parent thunk awaiting `workflow()`
holds a concurrency slot; `floor(POOL/2)` was rejected because on 4 cores it serializes the whole
backlog. **D2 is honoured as policy, not guaranteed as outcome**: above roughly 80 tasks the tail of a
run executes as plain 3.1.0, and the report says so.

**`/task`** gets recon (existing ids *and slugs already in use*, the real code surface, and the agent
definitions' bodies), two competing planners judged, and an advisory completeness critic — but **no
architect and no child workflow**: its pipeline is identical every invocation, so there is no shape to
discover, and its per-unit authoring fan-out already existed.

**Also fixed** (independent of the feature, landed first):
- **Run-killer:** an unguarded `await priorIntegratePass`. `integrateOne` dispatched the conflict
  resolver through a bare `agent()` and `serializeIntegrate` returns the un-swallowed promise, so a
  resolver non-emit propagated out of the loop *and the script* — no report, no unlock, lock held.
- **Livelock:** a reviewer that rejected without setting `rejectionIncrement` wrote `inc:0`, so
  Rejection Count never advanced and the task cycled forever, caught only by the loose `NO_GAIN_LIMIT`.
  `inc` is now derived from the transition, and `ACFW_RESULT` gains an optional
  `faultClass: quality|mechanism` so "reject, and this is not the task's fault" stays expressible —
  extending the mechanism-vs-quality budget separation 3.0.0 established for the integrator to review.
- A deterministic parent-side clean-checkout AUTO-REJECT, typed: token missing with the branch present
  means the token was lost, not the work (mechanism, retried); no branch at all is a real reject.
- `whip-init` gitignores `.acfwhip/run/` and `.acfwhip/specs/` unconditionally. **Never `.acfwhip/`
  wholesale** — `.acfwhip/config` is committed and its values overwrite inherited env.
- `task-template.md` said Rejection Count max 5 while the cap has been 3.

**Adapters, `CONTRACT.md`, `scan-backlog.sh` and the task template are UNCHANGED** — no new scanned
field was needed, which is the payoff of gating on budget rather than on complexity.

New: `skills/lib/child-skeleton.js.tmpl`, `skills/lib/bin/acfw-child-{scaffold,validate,ledger}`,
`acfw-child-validate.mjs`, and five test files. Suite: **645 assertions**, green on stock macOS bash 3.2
with BSD sed/awk, plus `tests/run-all.sh` so a new suite cannot silently stop being run.

Kill switch: `args.escalate: false` reverts to byte-identical 3.1.0 dispatch.

**Runtime facts verified against a live nested run** (recorded so the next author does not re-derive them):

| Question | Answer |
|---|---|
| Does `workflow({scriptPath}, args)` run a child? | Yes. |
| Can the child dispatch its own agents? | Yes. |
| Does the second argument arrive as a real **object**? | Yes — `args.foo` is readable in the child. The skeleton's whole `const A = args \|\| {}` unpacking depends on this. |
| Does the child's return value reach the parent? | Yes, verbatim. |
| Do the child's agents count against the **parent's** run? | Yes — the parent run reported the child's agent count as its own. This is exactly the premise the CAP_RESERVE ladder rests on. |
| Message when the path is unreadable | `Workflow script file not found: <path>` — deliberately does NOT match the kill-switch pattern, so it becomes one repairable amend round rather than disabling escalation for the whole run. |
| Message when the ref is malformed | `workflow() expects a workflow name (string) or {scriptPath: string}` — also not a kill-switch match. |

Still **unverified, and deliberately not depended on**: whether a parent thunk awaiting `workflow()`
holds a concurrency slot. `LANES = max(2, POOL-2)` is correct under both readings, so the open question
is a throughput one, not a correctness one. Do not probe it from inside `/go` — under the pessimistic
reading the probe *is* the deadlock. Runtime resume across the nesting boundary is likewise unused: the
stage ledger is the durability mechanism, and if resume does reach into children the only effect is that
some replays come from the journal instead of `args.priorStages` — same values, strictly faster.

### multica: the audit trail moves out of the comment thread and into the task document

`acfw-store-multica` posted every state change as an issue comment
(`whip-transition | ts | from | to | agent | notes`), and the `clean-checkout` token with it. On this
backend that is the wrong surface: **a comment thread is a live agent channel** — an assigned agent
reads it and comment activity triggers comment-scoped tasks — so orchestrator bookkeeping landed inside
a conversation an agent is expected to act on.

Transitions and `log-event` rows now splice into the stored document's `## Transition Log` table via the
*shared* `append_log_row`, in the files-adapter row shape. A multica-backed task document reads exactly
like a files-backed one, and inherits that helper's cap and never-drop-a-row fallback for free. The
`comment` subcommand still writes a real comment — that is now all comments are.

Three things simplify as a consequence: `snapshot.hasCleanCheckoutToken` stops paying a
`comment list --full` per in-review task (it reads the description `issue list` already returned, then
`issue get`, then the comment scan); `read --materialize` no longer synthesizes an audit section, and
renders genuine comments under `## Store Comments`; and the stored `description` stops carrying an
empty Transition Log table forever.

- **Upgrading mid-flight is safe.** The comment scan survives as the token scan's last step and
  `--materialize` still renders comments, so a task that entered review *before* this change keeps
  resolving instead of being auto-rejected.
- **`NOTES` is escaped** (newlines/tabs → spaces, `|` → `\|`) before entering the table. This backend
  re-reads its own rows, so a newline would corrupt the splice and a bare pipe would add phantom
  columns. `apply-transition.sh` does neither and has the same latent hazard — worth backporting.
- **Failure handling is asymmetric by design**: `transition` writes its row last and best-effort (the
  `whip_state` write is the commit point; a lost row must not report a completed move as failed) but
  now WARNs instead of swallowing the error, while `log-event` stays strict.
- `beads` and `linear` are **unchanged** — they keep the comment behavior. `CONTRACT.md` now states the
  audit-row location as a per-adapter choice rather than implying one rule.
- New offline gate `tests/phase12-multica-transition-log.test.sh` (33 assertions) drives the adapter
  through a fake `multica` CLI it builds itself; the same fake runs the frozen 36-assertion
  store-conformance suite green. `tests/run-all.sh` also gained a `bash -n` static gate over every
  adapter — they were outside every gate, so a syntax error in one was invisible until a run hit that
  backend.

## 3.1.1 — the beads adapter uses Dolt, the engine `bd` actually ships

- **`ACFW_STORE=beads` could not initialize at all.** The adapter ran
  `bd init --backend=sqlite`, and **every released `bd` rejects that flag**: v1.0.4 errors after a
  deprecation notice, v1.1.0 returns `--backend=sqlite is no longer supported`. Beads removed the
  SQLite backend in v0.58.0 and has defaulted to **Dolt** since v0.50.0; SQLite exists again only on
  unreleased `main`. The adapter now passes `--backend=dolt` — the one value v1.0.4, v1.1.0 and
  `main` all accept — so task state lives in an embedded Dolt database under `.beads/`. No migration
  is possible or needed: a sqlite-backed store created by this adapter never existed.
- **`bd init`'s repo side effects are now suppressed, and one of them was a run-killer.** init passes
  `--skip-hooks --skip-agents --non-interactive`. Without `--skip-hooks`, bd installs hooks into
  `.beads/hooks/` and sets repo-wide `core.hooksPath` — which lives in `.git/config` and is therefore
  **shared by every git worktree**. Every commit whip makes (specialists, `apply-transition.sh`,
  `integrate-lpcas.sh`, `whip-move.sh`) would spawn a `bd` hook contending for the same single-writer
  Dolt lock, and the hook can stage `.beads/issues.jsonl` into a pending commit — making LP-CAS
  candidates a function of the environment instead of the branch tree. `--skip-agents` stops bd
  writing `AGENTS.md`/`CLAUDE.md`/`.claude/settings.json` into the host repo.
- **`init` refuses a dirty index (exit 8).** `bd init` ends in a bare `git commit --no-verify` with
  no pathspec, so it commits the *whole* index — anything staged would be swept into a `bd init:`
  commit. A non-cgo `bd` now also fails with a typed exit 5 naming the build fix, instead of a raw
  engine error.
- **Lock matcher widened to Dolt's vocabulary.** Retries now key on `locked by another dolt process`,
  `noms lock`, `lock file`, `deadlock found` and `lock wait timeout exceeded` alongside
  `database is locked`. Dolt's server-mode string is `database "<name>" is locked by another dolt
  process` — the db name sits mid-string, so the old substring test missed it.
- **The contract's concurrency note was wrong, and is corrected.** `adapters/CONTRACT.md` told
  adapter authors they see a "single sequential writer". Only *transitions* are serialized: `/go`
  dispatches specialists with `parallel()`, and each independently runs `read --materialize` and
  `log-event`. Adapters must be concurrency-safe on those verbs and **must never block
  indefinitely** — exit 99 instead. Exit 99's gloss now covers "timed out waiting for the backend".
- **Known limitation, documented not fixed:** embedded Dolt is single-writer by file lock and `bd`
  waits for it with unbounded backoff against a context with no timeout, so a contended `bd` process
  *hangs* rather than erroring — the retry cannot fire, and `clean-checkout.sh`'s `|| WARN` catches
  a non-zero exit but not a hang. Recovery and the planned fix (an adapter-side wall clock → exit 99)
  are written up in `adapters/beads/README.md`.
- **Version floor is now honest: the beads adapter needs a `bd` built from beads `main`.** Not
  because of Dolt, but because `bd create --status` landed 2026-07-05 and is in no release. Documented
  in `adapters/beads/README.md`.
- Regression tests: `tests/phase9-adapter-beads.test.sh` **had been skipping unconditionally** — its
  capability probe required the same `--backend=sqlite` no released `bd` has, and its build recipe was
  `CGO_ENABLED=0`, which produces a binary that cannot open embedded Dolt at all. Both fixed, the
  hardcoded personal `BEADS_SRC` path dropped, and six assertions added (backend is dolt, no `*.db`,
  `core.hooksPath` unset, no `.beads/hooks/`, no agent files, dirty-index refusal). Now green:
  36 conformance + 12 beads-specific.

## 3.1.0 — pluggable task stores (files / beads / multica / linear behind an executable adapter contract)

`.backlog/` is now ONE task-store backend among several. Task state routes through a dispatcher
(`skills/lib/bin/acfw-store`) and an **executable adapter contract** (`adapters/CONTRACT.md`, contract
v1, git-remote-helper style: one executable per backend, JSON I/O, typed exit codes, capability
flags). Zero migration: `files` stays the default; an existing `.backlog/` project resolves and
behaves exactly as on 3.0.1 with no action.

- **Contract v1 + dispatcher.** Required subcommands `capabilities`/`snapshot`/`read`/`create`/
  `transition` (+ optional `init`, `update-field`, `update-body`, `log-event`, `comment`, `doctor`,
  `sync`). The dispatcher resolves the backend (`ACFW_STORE` env → config → `files`), discovers the
  adapter (`$ACFW_STORE_ADAPTER_PATH` → project-local `.acfwhip/adapters/` → shipped
  `adapters/<backend>/` → `$PATH` — third parties add a backend by committing ONE executable, no
  fork), and compensates for missing capabilities: raw snapshots are enriched with the git facts
  (LP-CAS ledger oracle, worktree branches, terminal-count model — `acfw-enrich-snapshot.sh`),
  `--stage` deliverables are committed to trunk by the dispatcher when the adapter can't co-commit
  them, and non-files doctors merge store-native findings with the generic graph/git battery
  (`acfw-doctor-generic.sh`).
- **files adapter** (`adapters/files/`) is a thin shim over the unmoved 3.0.x engines
  (`scan-backlog.sh`, `apply-transition.sh`, `doctor.sh`) — byte-identical behavior, all directly
  invocable as before.
- **beads adapter** (`adapters/beads/`): whip states as `bd` custom statuses, deterministic
  `whip-<stem>` ids (LP-CAS-key stable), native dependency edges (cycle-checked), `whip_*` metadata
  for slugs/counters, one-call snapshots via `bd export`, audit rows + clean-checkout tokens as
  comments. sqlite backend; single-writer discipline documented.
- **multica adapter** (`adapters/multica/`): canonical state in `whip_state` metadata with the native
  status as a doctor-repairable display projection, `whip_key` server-side resolution, deps in
  `whip_deps` (multica has no dependency API — whip's scheduler computes readiness, as it always
  did), paginated snapshots, comments as the durable audit trail, crash-safe `whip_key`-last create.
- **linear adapter** (`adapters/linear/`): Linear has no custom fields, so canonical whip state
  lives in the official integration-state mechanism — one **attachment** per issue whose `metadata`
  holds the `whip_*` keys and whose deterministic URL (`https://acfw.fib7.ai/<namespace>/<stem>`)
  doubles as the idempotent write key and the exact `attachmentsForURL` lookup handle; native
  status is a lossy per-team projection by workflow-state *type* (doctor-repairable), the task
  document is the issue description, comments are the audit trail, deps ride `whip_deps` with
  native `blocks` relations as best-effort mirrors. Speaks GraphQL directly (curl + jq, injectable
  transport — no third-party CLI); needs `LINEAR_API_KEY` + `ACFW_LINEAR_TEAM`.
- **`adapters/README.md`** documents the store layer end to end: architecture, dispatcher
  mechanics (resolution, discovery, env, exit codes), the capability-compensation table, data-flow
  walkthroughs (snapshot/transition/materialize), a write-your-own authoring guide, and a
  backend comparison table.
- **Workflows are store-parametric.** `whip-go`/`whip-task` take a `store` arg (from
  `acfw-store info` at launch); every writer action is now **stem-keyed** (the adapter resolves the
  task's current state — strictly more robust on resume than folder paths). On non-files stores,
  dispatched agents read a spec **materialized** from the store (`read --materialize` →
  `.acfwhip/specs/`), evidence/review comments flow back via `acfw-store comment`, the
  clean-checkout token is recorded via `log-event`, and `/task` authors into `.acfwhip/staging/`
  before the single writer ingests via `create`. Prompts and commands on the files path are
  byte-identical to 3.0.1.
- **Config gains a backend-neutral home**: `.acfwhip/config` (first match wins over the legacy
  `.backlog/.acfw-config`, which keeps working untouched); run lock moves to
  `.acfwhip/run/acfw-run.json` on non-files stores. `whip-init` gains a task-store selection;
  `whip-move`/`whip-doctor`/`retro`/`research` and the SessionStart hook are store-aware. The
  **LP-CAS ledger stays git-native on every backend** — integration truth never moves into a store.
- The legacy (non-workflow) `/go` markdown loop is declared **files-only**.
- Regression tests: new `phase9-store-conformance.test.sh` (the executable contract spec — 36
  assertions, run against every adapter; beads wrapper builds/uses a real `bd`, multica wrapper is
  skip-guarded on `MULTICA_TEST_SERVER`, linear wrapper runs the full conformance suite offline
  against a GraphQL emulator pinned to doc-verified API semantics with a live path skip-guarded on
  `LINEAR_TEST_API_KEY`), `phase9-dispatcher.test.sh` (37 assertions: resolution
  precedence, discovery order, enrichment against a seeded ledger marker, stage compensation,
  doctor merge). Phases 0–8 pass unchanged.

## 3.0.1 — field-inventory residue (oracle agreement, deliverable durability, run lock)

A 31-defect field inventory taken across ~890 tasks and 195 runs (2.0.3 → 3.0.0). Most entries were already dead by construction under LP-CAS — whole-branch rebase, the cached snapshot ref, poison quarantine on a stale base, re-rejecting landed work, branch-ref resets, `Integrated-At` drift, duplicate-id aborts, re-dispatch livelock, uncaught schema errors, unsafe resume, final-iteration unblock, EOF transition-log growth, non-atomic Status+move, doctor scan cost, and worktrees for non-code tasks. What follows is the residue, plus one live run-killer the inventory implied but had not isolated.

- **Oracle agreement inside the doctor (run-killer, found while verifying this release).** `whip-doctor`'s `cross-slug-dep-not-integrated` gate read the **inert** `Integrated-At` field, while the scheduler reads the ledger. So a dep whose change was on trunk (marker present) but whose `worktree/<slug>` branch had not been reaped yet — nothing reaps it until a later `--fix` — read as "not integrated": `/go` dispatched the dependent (marker says satisfied) and the next per-iteration `doctor --quiet --active-only` recheck FATAL'd on it and **aborted the whole run**. Both the full and `--active-only` passes now fold ledger truth into the column the gate reads. The gate still fires when the dep genuinely has not landed.
- **`Worktree: none` deliverables can no longer be lost (P0).** A non-code task writes standalone files (e.g. `docs/research/*.md`) into the shared root and may not commit; nothing ever staged those paths, so the next checkout/stash destroyed them. The direct agent now reports `deliverableFiles`, and `apply-transition.sh --stage <path>` (repeatable) stages them **by explicit path in the same commit as the state move**. State namespaces (`.backlog/`, `.acfwhip/`), absolute paths and `..` are refused before any mutation; a missing path is skipped, never stranding the transition; a crash between `mv` and `commit` is repaired on the idempotent re-apply. The reviewer rejects an uncommitted deliverable.
- **Run lock (WHIP-15).** `/go` refuses to start while `.backlog/.acfw-run.json` is fresher than 30 minutes — two concurrent runs collided on slugs and on the shared root index. Freshness is the existing heartbeat's **mtime**: no PID, no daemon, no new file. The writer touches it each batch; a clean finish removes it; a crash self-expires it. Override: `rm .backlog/.acfw-run.json`.
- **A dirty orphan worktree is never force-removed (WHIP-26).** The `--fix` reaper checked only that a slug had no live task, then ran `git worktree remove --force` — discarding modified *and* untracked files (thousands of cassettes, a unique findings doc, an `.env`). Dirty orphans now emit `WARN|orphaned-worktree-dirty` and are left for a human; clean ones are still reaped.
- **`--add-dep` writes the format the parsers read (WHIP-19).** `whip-move --add-dep` emitted JSON-style `[a, b]`; `doctor`, `scan-backlog` and `/task` all split on commas without stripping brackets, so both ids resolved to nothing → false `FATAL|dangling-dep` → `/go` blocked. It now writes a bare comma list, and `doctor --fix` repairs already-damaged backlogs (`REPAIRABLE|bracketed-deps`) at the bootstrap pass.
- **A NUL byte is one clear FATAL, not a cascade (WHIP-22).** `grep` treats a NUL-bearing task file as binary, so every field lookup silently returns nothing and a well-formed task reported `unparseable-frontmatter` **and** `missing-worktree-slug`, aborting runs. `FATAL|control-bytes` now names the byte count and the strip recipe, and the file is skipped rather than mis-parsed. Deliberately **not** `--fix`-able: a NUL usually marks a torn write, and the bootstrap `--fix` must never commit a half-written task as healed. Scoped to NUL — ESC/formfeed pasted from terminal output parse fine and are not flagged.
- **Dependencies are stamped from the validated plan (WHIP-18).** `/task` validated the dependency graph in JS, then let an author agent transcribe the `Dependencies` line into markdown — a silent-loss channel (a whole decomposition once emerged `Dependencies: none`, and `/go` dispatched downstream tasks before their upstreams landed). The single committer now overwrites that line from the validated plan before `git add`.
- **Three advisories that make silent losses visible.** `accepted-branchless-unverified` — an accepted code task with no branch and no ledger marker is still counted terminal (a FATAL would deadlock every pre-ledger backlog) but is now surfaced with its ack (`whip-move <stem> accepted --integrated-at <sha>`); this is the mode that shipped an accepted billing engine absent from trunk. `dirty-trunk-root` — tracked files dirty at the shared root outside `.backlog/`, which the next integration resync discards. `trunk-unpushed` — local trunk ahead of `origin/<trunk>`; LP-CAS lands **locally and never pushes**, by design (a push per landing would need credentials in every agent env, fire CI per task, and drag network faults into the integrator's exit taxonomy). Zero network: reads the local remote-tracking ref only.
- **Docs.** `skills/go/SKILL.md`'s bash fallback still invoked the **deleted** `integrate-worktree.sh`, a `rebase --continue` resolver flow, and `Integrated-At`-grep completion math; rewritten to the LP-CAS two-call protocol with the exact exit map. New `content/backlog/recovery-runbook.md` (shipped by `/whip-init` as `docs/acf/backlog/recovery-runbook.md`) maps every doctor finding and integrator exit code to a recovery, and documents crash recovery (re-running `/go` *is* the resume), the run lock, and parking a task via `draft/`. Standalone `hydrate-worktree.sh` use documented; task-authoring style now requires acceptance criteria verifiable inside the worktree/gate environment (live-environment validation belongs in a separate deploy-gated task).
- **Deliberately not done:** per-iteration checkpoint journaling (every transition and landing is already a commit; re-running `/go` is the resume), a `resumeFromRunId` guard (the concept does not exist here), a `Human-Gated` field (`draft/` already is the human gate), a landed/unimplemented classifier (the marker oracle made it `git cat-file -e`), and pushing to origin.
- Regression tests: +50 assertions across `phase1` (control-bytes, bracket heal, dirty-orphan skip, oracle agreement on both doctor paths, the advisory trio), `phase3` (`--stage` atomicity, refusals, missing-path skip, crash rescue), `phase4` (bare-comma deps). Full suite: 205 assertions, all green on stock macOS bash 3.2 / BSD sed+awk+find.

## 3.0.0 — LP-CAS integration engine (Ledger-In-Tree Compare-And-Swap)

Driving `/go` against a long-lived, high-churn trunk (~658 tasks) produced non-converging runs (aborted or no-progress, ~0 net integrated). A field report root-caused 18 failure classes against the 2.5.0 code. The keystone: `refs/acfw/trunk-snapshot` was a **cached base ref** refreshed by a non-force fetch whose exit status was discarded — once trunk history is rewritten the fetch becomes non-fast-forward, git silently refuses it, and every worktree rebased/reset onto a frozen base (observed 1292 commits stale). That single defect cascaded into false dep-blocks, phantom-conflict reject-loops, re-queuing of integrated work, branch resurrection, and the one-layer-per-run stall. Three further classes survived the 2.5.0 patch: a `.backlog` bookkeeping commit getting stamped as the integration point (#16), parallel same-file tasks silently losing the second write (#17), and a botched conflict resolution masquerading as a coverage regression (#18).

Rather than patch the model again, 3.0.0 **re-architects integration so the faults cannot arise by construction** — the near-unanimous output of a 5-persona / 2-round / 3-model advisory board.

**The one invariant.** A task `K` is integrated **iff** `git cat-file -e <live-trunk-tip>:.acfwhip/integrated/<shard>/<K>.json` succeeds. Integration truth is a fact about git — an in-tree ledger marker — never a markdown field, folder location, or commit trailer. `Integrated-At` is now **inert** (kept for display; nothing reads it).

- **No cached base ref (keystone, #1/#9/#10 gone).** `refs/acfw/trunk-snapshot` and the entire rebase-into-snapshot re-align pass are deleted. `clean-checkout` forks a worktree from the **live** trunk and only records a fork-base ref; it never rebases or resets the branch. There is no snapshot to go stale.
- **Single-parent candidate + cherry-pick, no rebase/replay (#3).** The integrator (`skills/integrate-lpcas/`) publishes the task's change as one single-parent commit at `refs/acfw/patch/<key>` (tree = branch tip, parent = fork-base) and applies it onto the live trunk with `git cherry-pick --no-commit` — base = the candidate's own parent, never a merge-base vs trunk. A long-lived branch is never stale and never drags a phantom range.
- **Marker co-committed with the change (#5/#7/#11/#16).** The change **and** its ledger marker enter trunk in the *same* single-parent commit, after the gate passes, landed by compare-and-swap (`update-ref <new> <observed>`). "Marker on trunk ⟺ change on trunk" is a structural identity — a bookkeeping commit can never be the integration point, and "done yet absent from trunk" is unconstructable.
- **Same-file parallelism is surfaced, never silently lost (#17).** A second task touching the same file is cherry-picked onto the live trunk already containing the first: clean 3-way → lands gate-verified; textual overlap → **mechanism conflict → resolver** (not a drop); broken auto-merge → **union gate fails → quality reject**. Slug partitioning is relaxed accordingly.
- **Union gate + parse-sanity before landing (#8/#18).** The project gate (`ACFW_GATE_CMD` in `.acfw-config`) runs on the candidate tree via direct exec with `pipefail` (no masked pipes). A cheap parse/lint check (`ACFW_PARSE_SANITY_CMD`) runs first, so a botched conflict resolution surfaces as `resolution-syntax-broken` (**mechanism**, re-resolve) instead of masquerading as a coverage regression.
- **Typed faults (#6/#13).** Poison/malformed candidate → quarantine **that id only** (the run continues — a duplicate id no longer aborts all 600+ tasks); mechanism (conflict / cas-loss / fetch) → bounded retry, never a quality reject; quality (gate) → reject/redesign. Mechanism and quality consume separate budgets.
- **Git is the only oracle (scanner + doctor).** `scan-backlog` derives integration state from the ledger (`acfw_integrated_keys`), not `Integrated-At`/folder. `whip-doctor` drops the metadata-vs-git reconciliation invariants (the "clear stray Integrated-At" repair that itself re-armed integration, #5) — it can no longer touch integration state, by construction — and downgrades `duplicate-id` from a run-aborting FATAL to an advisory quarantine.
- **Retired:** `skills/integrate-worktree/` (the rebase-into-snapshot fold), `refs/acfw/trunk-snapshot`, `Integrated-At`-as-authority, and the doctor invariants that existed only to reconcile metadata against git.
- **Migration is by self-heal (no separate backfill step).** On the first 3.0 run, a legacy accepted task with a reaped branch is already terminal (nothing to integrate); one whose branch still exists re-folds idempotently — the code is already on trunk, so the cherry-pick is empty and only the marker lands. No accepted work is destroyed: the integrator never mutates the worktree branch, and CAS-land only ever advances trunk from the exact tip it observed.
- **Deferred to 3.1+:** micro-batch ledger train (gate-once + CAS-whole-chain + bisect-evict); bounded self-heal for external rewrite-away. 3.0 ships the simplest correct core (per-task gate, K=1).
- Regression tests: new `tests/phase8-lpcas-integrate.test.sh` (46 assertions: stale-base land, #16 marker co-commit, #17 same-file union + conflict, #18 parse-sanity, idempotency, poison, union gate, CAS); `tests/phase6-worktree-codeonly.test.sh` rewritten for the snapshot-free producer + end-to-end producer→integrator landing; `phase0`/`phase1`/`phase3` updated to the LP-CAS model; `integrate-worktree`'s `phase7` retired (superseded by phase8).

## 2.5.0 — patch-id-aware integration (heals legacy branches, never destroys accepted work)

From a field report driving `/go` against a long-lived `develop` repo (~640 accepted tasks, branches born before 2.4.1): the 2.4.1 code-only architecture only helps branches it created, so legacy `worktree/<slug>` branches (no fork-base ref) still fell back to a far-back merge-base and replayed ~1000 phantom commits → the accepted→rejected reject-loop; accepted-but-unintegrated work whose equivalent code was already on trunk never registered terminal, stalling `/go` on "needs operator"; and a botched/aborted integration could destroy the branch's code (surviving only in dangling commits).

- **Integration is now patch-id aware.** A shared primitive (`acfw_pending_code_commits`) lists a branch's genuine code commits not yet on trunk *by patch-id*, dropping `.backlog` phantoms and already-applied commits. If the set is EMPTY, the task is stamped `Integrated-At` and reaped with **no rebase and no conflict** — curing the phantom-conflict reject-loop and the "done-modulo-integration" stall, and stopping re-runs from re-rejecting already-integrated work. Otherwise exactly those commits are replayed onto fresh trunk via cherry-pick (clean code-only branches fast-forward first), so a legacy branch with ~1000 phantom commits replays its ONE real commit.
- **Contaminated branches self-salvage in-path.** The exit-8 "contaminated → park for operator" path is retired: a `.backlog`-carrying branch is reconstructed code-only by the patch-id replay (the phantom commits are dropped), folding the real code and stamping `Integrated-At` instead of dead-ending. `clean-checkout` heals the same legacy branches at task-start (no more far-back merge-base fallback), recording a fork-base ref so they stay code-only thereafter.
- **Integration never destroys accepted work.** Before any branch mutation the integrator records `refs/acfw/preintegrate/<slug>` (the pre-integration tip) and prints an `ACFW-INTEGRATE: recovery` line; a resolver failure restores the branch from it (exit 6, code survives) instead of leaving it in dangling commits. The conflict resolver now runs a cherry-pick (`--continue`/`--abort`) and is explicitly forbidden from `git reset`/`checkout`/`switch`/branch-deletion or moving HEAD off the branch.
- **RunReport reconciled against disk.** `integrated` / `rejectedAtIntegration` are re-derived from the final on-disk snapshot (folder + `Integrated-At`) cross-referenced with what the run attempted, so a post-resolver agent non-emit can no longer report `rejectedAtIntegration: []` while the folder says rejected, nor list a rejected task under `integrated`.
- Regression tests: `tests/phase7-patchid-integration.test.sh` (short-circuit, legacy far-back reduction, backup-ref recovery), extended `tests/phase6-worktree-codeonly.test.sh` (in-path salvage + legacy clean-checkout heal) and `tests/phase2-scheduler.test.mjs` (`reconcileIntegrationTallies`). `tests/phase0-extraction.test.sh` updated to the cherry-pick resolver model.

## 2.4.1 — worktree branches are code-only (fix integrate reject-loop)

- Fixes a `/go` reject-loop: long-lived `worktree/<slug>` branches accumulated trunk `.backlog` task-transition commits (one field case: 367 commits ahead, 366 of them phantom). The whole-branch rebase at integrate time then produced phantom conflicts, cycling tasks accepted→rejected endlessly.
- A worktree branch is now **code-only by construction**. A per-slug fork-base ref (`refs/acfw/forkbase/<slug>`) records the trunk SHA the branch's code sits on. Both `clean-checkout` (re-sync) and `integrate-worktree` (pre-FF rebase) now replay ONLY the branch's own commits via `git rebase --onto <trunk-snapshot> <base>` instead of merging trunk's `.backlog` history in or whole-branch rebasing it back.
- Pre-integrate guard refuses any branch carrying `.backlog/` commits (`git log <trunk>..<branch> -- .backlog/` non-empty) → exit 8 / `contaminated`. `/go` parks that task for an operator (manual recovery: cherry-pick the tip code commit onto trunk) instead of rejecting/re-running.
- `apply-transition.sh` gains a defensive trunk-only assertion.
- Regression test: `tests/phase6-worktree-codeonly.test.sh`.

## 2.4.0 — worktree ownership scoping + configurable namespace

- Fixes a field report that `/go`'s startup pruned unrelated worktrees: the bootstrap's `whip-doctor --fix` orphan reaper + `worktree-wrong-branch` FATAL used to iterate every directory under `.worktree/`, force-removing or FATAL-aborting on worktrees a user kept for parallel research/benchmarking.
- The doctor now manages **only** worktrees on acf-whip's own branch namespace (`<ACFW_BRANCH_PREFIX>/<slug>`, default `worktree/<slug>`). An ownership guard skips any directory that is on a foreign branch, detached (mid-rebase), or not a registered worktree — no FATAL, no removal.
- Worktree directory and branch prefix are configurable via `.backlog/.acfw-config` (`ACFW_WORKTREE_DIR` default `.worktree`, `ACFW_BRANCH_PREFIX` default `worktree`), resolved by a shared `acfw_load_namespace` in `skills/lib/acfw-git.sh` and threaded through `clean-checkout`/`integrate-worktree`/`doctor`/`scan-backlog`. Scan digest emits `branchPrefix`/`worktreeDir` so prompt text matches a custom prefix. Defaults preserve prior behavior byte-for-byte.
- `<repo-root>/.worktree/` (gitignored, ephemeral) is now a documented ACF organization convention (librarian `organization-template.md`).
- Regression test: `tests/phase1-doctor-hydrate.test.sh` (foreign-worktree-survives + custom-namespace round-trip).

## 2.3.0 — orchestrator hardening

From a field bug report — two `/go` crashes, a livelock, a barrier stall:

- **Streaming lifecycle**: each dispatched unit runs its own specialist→review→integrate cycle instead of holding the wave at a per-iteration `parallel()` barrier. A fast task is reviewed, accepted, and integrated while a multi-hour task in the same wave is still running. Single-writer and topological-integration invariants are preserved by explicit serialization (write promise-chain + integrate lock); cross-slug dependents are gated at dispatch. Proven by `tests/phase5-streaming.test.mjs` (a construction that deadlocks under the old barrier).
- A read-only scan that fails to emit `StructuredOutput` no longer aborts: it retries, falls back to a schema-less text scan (parse the JSON the model printed), and if even that fails the loop degrades to a `scan-degraded` stop + drain off the last good snapshot, returning a clean report. A genuine mid-run integrity FATAL still aborts. Drain reuses the last good snapshot too (`tests/phase4-scan-degrade.test.mjs`).
- New **`/whip-move`** operator command wraps `apply-transition.sh` for validated manual close-out (move a task, set `Integrated-At`, add a dependency) with atomic `Status:` sync (`tests/phase4-whip-move.test.sh`).
- A specialist may report `blocked_reason: dependency-missing` + `needs_task`; the orchestrator parks the task for an operator immediately, naming the task to create, instead of re-dispatching to the `Block-Count` cap. Unit-tested in `tests/phase2-scheduler.test.mjs`.
- Per-wave dispatch logging names what is in flight. The git-worktree branch registry remains the parallelism lock (one specialist per `Worktree:` slug).

## 2.2.0 — per-ticket latency

On a 337-task backlog the per-iteration scan was ~48s (`scan-backlog.sh`) + ~22s (`whip-doctor`) plus a ~50KB / ~16,800-token verbatim Opus echo, ~99% of it terminal accepted files that never change. Three fixes:

- `scan-backlog.sh --digest` emits a small scheduling snapshot (counts + actionable tasks + accepted integration candidates + compact `satisfiedDeps`), classifying the accepted folder in one batched grep+awk pass (the per-file `field()` loop was ~240–600× slower). Scan drops to ~1.6s, echo to <1KB. JS `indexTasks(tasks, satisfiedDeps)` synthesizes a terminal dep object so `isTerminal`/`depsSatisfied` bodies are unchanged.
- `whip-doctor --active-only` runs the full integrity pass over active folders and feeds accepted tasks as cheap batched stubs (advisory only, never a gate FATAL), dropping the per-iteration recheck to ~0.1s with identical FATAL/ok output.
- Deterministic shell-runner agents (scan, single writer, integrate, bootstrap, drain) run on a fast model (`SHELL_MODEL`, overridable via `shellModel`) — they only run a script and copy stdout — while specialists/reviewers/conflict-resolvers keep the session model.
- Net: per-iteration overhead fell from ~70s + a multi-minute echo to ~2–3s. Pure scheduling/terminal logic lives behind `// <scheduler-pure>` markers, unit-tested by `tests/phase2-scheduler.test.mjs`; the shell layer by `tests/phase1-doctor-hydrate.test.sh` + `tests/phase3-reliability.test.sh`.

## 2.1.0 — reliability hardening

From a multi-wave field retro where 2 of 4 runs crashed and one aborted at iteration 2:

- Every schema `agent()` call is wrapped in bounded retry + graceful degrade, so a single StructuredOutput non-emit no longer aborts a multi-hour run (writer defers, integrate stays transient, scan re-scans then aborts cleanly).
- Durable per-task `Block-Count` breaks the specialist re-dispatch livelock — a task whose real blocker is unmodeled stops being re-queued after a cap (default 3) and surfaces as `needsOperator` instead of spinning.
- `apply-transition.sh` syncs `Status:` to the destination folder atomically with the move (folder is the source of truth), so a stale Status can no longer self-inflict the `status-folder-mismatch` FATAL. The doctor now treats that mismatch as REPAIRABLE.
- Completion requires no queued unblock, so a cross-slug dep integrated in the final iteration never strands its blocked dependent. `integrate-worktree` treats an empty (no-commits-ahead) branch as terminal. Transition rows splice into the `## Transition Log` table and cap (shared `append_log_row`).

## 2.0.3 — state-machine parity

- The `/go` workflow performs the two transitions the workflow migration had dropped: **blocked→pending** unblock when deps resolve (gated on rejection-count so max-rejection redesign blocks stay for a human) and **in-progress→blocked** timeout past the operator threshold (`ACFW_INPROGRESS_TIMEOUT_HOURS`, default 8h, emitted by `scan-backlog.sh`). A backlog whose pending tasks are gated on blocked tasks now runs to completion instead of exiting `no-progress`.
- `/task` aborts up front when no specialist agents are installed.
- Retained dependency-target accepted tasks are emitted slim; a single garbled snapshot echo triggers one re-scan before aborting.

## 2.0.2 — scale fix

- The snapshot is a bounded working set — full task objects only for actionable tasks plus their dependency targets, while terminal/historical accepted tasks collapse into aggregate `runtimeTerminalDefault`/`runtimeTerminalOverride` counts that drive completion. The per-iteration scan no longer balloons into a backlog-sized blob the workflow agent must echo (the cause of a multi-minute stall on a ~300-task backlog).
- The doctor's new `--quiet` mode bounds the gate report to FATAL + `BREAKDOWN` + `SUMMARY`.

## 2.0.1 — self-healing

- Doctor severity is scoped to the dispatch path: accepted/historical tasks are advisory (WARN, never blocking), so a pre-2.0.0 backlog runs instead of aborting the gate.
- `/go` counts a branchless historical accepted task as terminal (runtime-derived via `hasWorktreeBranch`, no file rewrites) and never re-integrates it (`integrate-worktree` exits 4 on a missing branch).
- Parallelization is the default at planning and execution: distinct slug per independent surface (concurrent), shared slug only on real file-surface overlap, dependencies only on genuine output consumption.
- `/whip-doctor` is the integrity battery (now emitting a grouped `BREAKDOWN` line) and runs as a startup + per-iteration gate; `scan-backlog.sh` emits the read-only snapshot the scheduler runs on (now including `hasWorktreeBranch`); `.worktreeinclude` hydrates git-ignored config into fresh worktrees.

---

`/task` and `/go` are **workflow-native**: they run as dynamic workflows (`workflows/whip-task.workflow.js`, `workflows/whip-go.workflow.js`) whose loop, slug partition, dependency gate, and topological integration live in a deterministic script — so Claude's context stays flat across iterations — with the legacy single-context loop as the automatic fallback when dynamic workflows are unavailable. Worktree slugs are enforced in three layers: schema-required at decomposition → JS validation gate (kebab-case, acyclic deps, unique ids) → at dispatch the doctor self-heals a missing slug on an active task. See `content/backlog/workflow.md` for the state-machine spec.
