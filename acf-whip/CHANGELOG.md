# acf-whip changelog

All notable changes to acf-whip. The format loosely follows Keep a Changelog.

## 3.5.0: the ACF cycle, out of the box

Before 3.5.0, acf-whip ran the middle of the job: `/task` decomposed a scope and `/go` built it.
Deciding what to build, keeping the plan, checking the result against it and learning from what went
wrong were left to whatever pipeline each user had. 3.5.0 adds both ends and joins them into one
cycle, PLAN → DECOMPOSE → BUILD → VERIFY → RETRO, with a single human approval. The plan, its record,
the retro and the lessons are files in your repo, committed to its history. Small work keeps the old
route: `/task "<scope>"`, then `/go`.

### Added

- **`/whip`, the front door.** A bare `/whip` prints where you are, what needs you, and the one
  command to run next. `acfw-cycle` derives the stage from git and the task store on every call and
  never stores it; the skill prints its output verbatim. `/whip "<goal>"` sends small work to
  `/task` and risky work to a plan. Risky means data, a schema or a migration; auth, secrets,
  payments or personal data; a breaking change to a public contract; three or more modules; or a new
  user flow. `/whip <file.md>` adopts a plan written anywhere else (superpowers, spec-kit, Claude
  plan mode, by hand) and never writes to the source file. `/whip --abandon` closes a cycle you no
  longer want.
- **A plan is a folder in your repo, and approval binds its bytes.** `docs/cycles/YYYYMMDD-<slug>/`
  holds `plan.md` (yours), `record.md` and, later, `retro.md`. `record.md` carries the approval
  stamp, the deliverable-to-task map and a newest-first Plan Log, and only `acfw-cycle` writes it.
  One "yes" on the approval card approves the content hash that card showed, and `approve --expect`
  refuses any other (exit 9), so an approval cannot bind text nobody saw. The approval holds only
  while `record.md`'s `Approved Content`, its newest `approved` row and the hash of `plan.md` agree
  at HEAD. Edit the plan afterwards and `/whip` says "amended since approval": the approved text
  keeps building, and your edit builds only once it is approved. Every plan event is its own
  pathspec commit, `docs(plan): <event> <slug>`, with an `ACFW-Plan-Event` trailer for audit.
- **`/task --plan` builds exactly what you approved.** Your "yes" starts it in the background.
  Planners read a frozen copy of the approved `plan.md` and decompose only the deliverables that have
  no task yet. The validation gate rejects a task that names no deliverable, names only covered
  ones, or reuses an id the store already has. Each task carries
  `Documentation: docs/cycles/<ID>/plan.md (D2)`. The task map is committed to `record.md` before
  any task exists, and every create, commit and focus change waits for that record to succeed, so a
  refused record creates nothing. The run sets your `/go` focus to the plan's unfinished tasks, and
  `/go` launches on exactly that focus without asking again. A D-id is permanent once a task names
  it: re-approving a plan that renumbers or removes a recorded D is refused (exit 8), so a task never
  counts toward a deliverable it was not built for.
- **Coverage per deliverable.** `/whip` shows each D as ✓ (every task accepted and, in default mode,
  integrated), ◐ (not finished, whether started or not), ✗ (a task is blocked), `?` (accepted, but
  nothing proves the change reached trunk) or cancelled (all its tasks archived). When a cycle
  cannot move, you get a card naming the root blocker and the exact reply to give, never a `/go`
  that has nothing to run. A `?` holds the close: `/whip` shows that card's reply before `/retro`,
  so a clean close cannot bury work that nobody has shown reached trunk. In a planned cycle, `/go`'s
  run report ends with a `nextStep` that prints this table. After a close, `/whip` says how many
  commits are not pushed yet. Pushing is up to you.
- **`/retro` closes a cycle, on every task store.** A clean cycle closes with one
  `acfw-cycle close <plan> none` call and zero agents. When a task was reworked or stuck, or a
  deliverable is not met, a retro agent reads the triggered tasks through
  `acfw-store read --materialize` (which carries reviewer comments on beads and linear), their
  commits and the recorded lessons. It writes `docs/cycles/<ID>/retro.md`, at most 3 one-rule
  lessons in `docs/acf/lessons/<slug>.md`, and a retro-actions cycle that you approve on the same
  card as any plan. Each action item's heading says `[sensor]` or `[guide]` and whether it loosens a
  control, because the card shows only headings. A script check refuses malformed output before
  anything is committed. `/retro` never deletes a lesson: it lists one that a test now enforces
  under `## Retire`, and you run the `git rm`. The spec-tool verdicts committed at approval are an
  input: when a declared tool had flagged the cause, the retro proposes tightening that declaration
  (`policy=block`, `at=plan,task`) and never proposes loosening one. The only time `/retro` refuses
  is while `/go` runs. `/retro --force <task>...` analyzes work done without a plan.
- **Every `/task` reads the lessons.** Planners and critics run `acfw-cycle lessons` (read-only) and
  copy a relevant rule into the constraints of any task that walks into it, in plan mode and in free
  text. `/whip` cites the lessons a goal walks into in the plan's Risks.
- **Spec tools plug in with one committed file.** A declaration in `.acfwhip/spec-tools/<name>`
  turns any command into a plan reviewer. This line is a whole tool:
  `review=grep -nwE 'TBD|TODO|FIXME' "$ACFW_SPEC_FILE"; test $? -eq 1`. Findings go on the approval
  card. A `policy=block` tool needs GO on the exact approved bytes, or your recorded
  `yes, override <tool>`. An `at=task` tool reviews what `/task` writes (free text or `--plan`), and
  a task it still rejects is held in draft. A workbench driver lets you `/whip --push` the plan
  elsewhere and `/whip --pull` it back with a 3-way merge that keeps your local edits. Push and pull
  take plans only: you fix a held task where it lives (its `.backlog/draft/` file, or the backend's
  own editor), then `/whip --review <task>` checks it again. Tools never run in `/go`, and a tool
  that cannot run never blocks. A new or changed declaration runs only after you have seen it in
  full and replied "run tools", and a credential literal in a committed file stops every tool
  (exit 20). Shipped: `no-tbd`, `vale`, `claude-critic`, an in-session `spec-critic` agent, a `dir`
  folder workbench, and a GapTrap driver as the worked example of a paid remote reviewer. The
  GapTrap driver never pays twice for the same bytes: it writes each paid request down before
  sending it, and looks up a lost reply with a free call instead of resending. Guide:
  `spec-tools/README.md`; protocol: `spec-tools/CONTRACT.md`; GapTrap setup, cost and egress:
  `spec-tools/gaptrap/README.md`.
- **The cycle stops for a person at four gates, listed in one place.** The gates are plan approval,
  retro action-item approval, parked work (blocked at the cap, dependency-missing, draft, a ✗
  deliverable) and ship. A rejection under the cap, a merge conflict, a red gate in a worktree or an
  advisory finding is never a reason to page you. The list lives in `skills/whip/SKILL.md`, and
  `docs/acf/backlog/workflow.md` points to it.

### Changed

- **Tasks can no longer edit a cycle.** The integrator drops any `docs/cycles/` change from a
  candidate, names the dropped paths in a WARN, and says so again when the task then delivers
  nothing. Both `/go` staging paths and the transition writer skip `docs/cycles` in every spelling
  git reads as that path (`docs//cycles`, `docs/./cycles`, `././docs/cycles`), the bare folder
  included, and the writer stages an ancestor (`docs`, `.`) with `docs/cycles` excluded. An unstaged
  plan amendment or an untracked draft cycle at the root is therefore never committed with a task,
  and neither is one you staged with `git add`. Every writer that commits at the trunk root now names
  the paths it wrote instead of committing the whole index: task transitions and their deliverables,
  the non-`files` deliverables commit, the `files` store's create, field and body edits,
  `/whip-move`, `doctor --fix`, and the `/task --plan` writer. Before, whichever of them ran first
  committed everything you had staged, a plan amendment included, under a `task: ...` subject, and
  the approval stopped holding at HEAD. A free-text `/task` keeps its 3.4.x commit unchanged. The
  writer now also refuses a bare `.backlog` or `.acfwhip` (exit 2); it used to stage the whole task
  store. When trunk has deleted the cycle a task edited, the drop resolves that modify/delete
  conflict instead of stalling every `/go`.
- **No shipped agent pattern grants edit authority any more.** `retro-pattern.md` gave the generated
  retro agent "EXCLUSIVE authority to modify agent instructions, workflows, and quality standards"
  and let it "commit process changes to git". `precommit-pattern.md`, the retro manifest, the
  backlog README sample and the specialist manifests `/whip-add-agents` writes repeated the grant.
  That was a standing licence for one agent to loosen any control with no human involved. Changes to
  agent files, workflow docs and quality gates are now action items a human approves. phase17 fails
  if a pattern ships a grant again, and if a skill that another skill invokes sets
  `disable-model-invocation` (the Skill tool would refuse the handoff). Existing projects keep their
  generated files: see Upgrading.
- **`/retro`'s `--focus`, `--agent` and `--timeframe` flags are gone.** It no longer writes into
  `.backlog/pending/`.
- **`/whip-init`** pins `ACFW_INTEGRATION_MODE=default` in a new project only, lists `/whip`, keeps
  every hook of the `.pre-commit-config.yaml` it writes out of `docs/cycles/`, and adds
  `docs/cycles/` to an existing `.prettierignore` or `.markdownlintignore`. Its CLAUDE.md Next Steps
  line now points at `/whip`; a re-run replaces the old line only when it is byte-identical.
- **`/whip-doctor`** no longer counts edits under `docs/cycles/` as `dirty-trunk-root`. You amend an
  approved `plan.md` at the root by design, and no landing can overwrite it.
- **`ACFW_TRUNK_BRANCH`** in `.acfwhip/config` (the env var wins) pins the branch plan events may
  land on. Unset, a cycle's events commit only on the branch it was created on;
  `rm .acfwhip/run/cycle/<ID>/branch` moves it.
- **`append_log_row FILE ROW [HEADING] [CAP]`** takes a section heading and a cap. `CAP=none` keeps
  every row, so a user's `ACFW_LOG_ROW_CAP` never truncates a Plan Log. Every 2-argument caller is
  byte-identical to 3.4.3.
- **`workflow.md`** documents the `docs(plan)` subjects, the `ACFW-Plan-Event` trailer and which
  merge methods keep it, and `task-template.md` documents the `(D<n>, ...)` suffix on
  `Documentation`. Both are managed documents: unedited copies refresh at the next session.

### Fixed

- **Every integration printed a false "overwrote uncommitted work" WARN, and following its recovery
  advice un-landed the integration.** `land()` checked the root checkout with `git status`, which
  compares against HEAD. The compare-and-swap had already moved HEAD to the new trunk while the
  index still held the old one, so every path the landing changed looked staged: the WARN fired on
  every integration that changed a file, with a "snapshot" of work that never existed. Its advice,
  `git stash apply <snapshot>`, replayed the new trunk back to the old one plus your edits, so it
  reverted every other path the landing had changed, and committing that tree undid the
  integration. The check now compares against the tree the root held before the landing, and it
  counts untracked files the landing overwrote. The snapshot is built in a throwaway index from
  exactly the overwritten paths, so it never takes `index.lock`, and it keeps those untracked files.
  The `Recover:` command, `git diff --binary <observed> <snapshot> | git apply -3`, re-applies only
  your edits on top of the landed content, 3-way (a clash leaves conflict markers) and staged;
  `git show <snapshot>:<path>` shows one path as it was. The snapshot is an unreferenced commit, so
  `git gc` prunes it after `gc.pruneExpire` (two weeks by default).
- **`/task` on the `files` store dropped a task's dependencies when its author left out the line.**
  The writer stamps the validated dependency graph over each authored task file. When the file had
  no `Dependencies` line, the insert branch rendered `a\\` plus a newline, which GNU sed
  (`unknown command`) and BSD sed (`extra characters after \`) both reject. The task kept no
  dependencies, silently, and `/go` could dispatch it before its upstream landed. The stamp now uses
  the one `a\` form both accept, and phase20-task-plan runs both branches under `/bin/bash`.
- **`/retro` did nothing useful on most projects.** It gated on
  `ls .backlog/blocked/ .backlog/rejected/` (`/go` empties `rejected/`, so a task reworked and then
  accepted never triggered it); tested `[ -d .backlog ]`, which fails on beads, multica and linear; grepped
  `rejection_count` where the field is `Rejection Count`; and wrote improvement tasks straight into
  `.backlog/pending/`, around the `/task` validation gate. The rewrite reads tasks through the store
  on every backend, and its trigger thresholds live only in `acfw-cycle triggers`.
- **The WARNs an integration printed never reached the `/go` report.** Nothing read the integrate
  agent's note for a task that landed, so the `Recover:` command for overwritten root work was at
  best in the workflow log, and the snapshot it names is referenced by no ref. The report now
  carries `integrationWarnings` (at most 20; the workflow log keeps all of them) on the final
  return and on every abort inside the loop, so a run that landed work and then aborted still hands
  you the command.
- **`dirty-trunk-root` counted a quoted `.backlog/` path as dirty.** `git status --porcelain` quotes
  a path with unusual characters, and the leading quote dodged the exclusion. Both doctor batteries
  strip it first.
- **Skill text lost its `$0`, `$1` and `$2`.** Claude Code replaces `$<digit>` in a skill with the
  skill's arguments whenever any are passed, so an awk `$0` became your goal text: whip-init's Next
  Steps update silently did nothing, and the same code sat in `/whip` and `/retro`. Every skill now
  writes awk fields as `$(N)` and shell positionals as `${N}`, and `run-all.sh` fails on a bare
  `$<digit>` in any SKILL.md. Every skill also writes the plugin root braced, `${CLAUDE_PLUGIN_ROOT}`,
  the only form the loader substitutes.
- **A dead `/go` held you for half an hour.** A run that died with its session (a closed terminal, a
  crash, `claude -p` reaching its background-wait limit) left a fresh run lock, and `/whip` said only
  "wait: /go is running". The lock now gets a NEED YOU card with its age and the one command that
  clears it. The next `/go` redispatches the interrupted task.
- **`/whip-init` on a plain Node project installed gates that failed every commit.** A `package.json`
  without Express, Fastify or NestJS was not detected as Node at all, and the Node pre-commit config
  ran `npm run build`, `npm run lint` and a TypeScript ESLint setup the project did not have. Plain
  Node is detected; npm hooks run only when their script exists and a commit stages JS or TS;
  formatters no longer touch `.backlog/`, `.acfwhip/`, `docs/acf/` or `docs/cycles/` (a formatted
  managed doc can never refresh again, and a reflowed ledger marker failed the integration commit);
  a frontend next to a Go or Python backend gets its own gates doc; the ruff pin moves to v0.16.9.
- **A healed task stayed on the "needs operator" list.** A task parked for a missing clean-checkout
  token, re-dispatched and then accepted still appeared in the run report as "token never
  restored" on a run that ended complete. The report now lists only tasks whose last token event
  is still the park.
- **The templates disagreed about who moves task files.** `README.sample.md` and several agent and
  manifest templates told specialists and the reviewer to move task files; `workflow.md` gives every
  move to `/go`. They now agree. The research-agent template no longer relies on
  `CLAUDE_PLUGIN_ROOT`, which is empty inside a project agent.

### Upgrading

Nothing is required to keep working as before: `/task "<scope>"` then `/go` behaves as in 3.4.3.
To use the cycle in an existing project:

1. **Pin the integration mode**, if you have not. Unpinned, `/go` infers it from `CLAUDE.md` on each
   run, and an inferred `override` never integrates, so a planned cycle would never finish. `/whip`
   shows a card naming `ACFW_INTEGRATION_MODE` once a cycle task is accepted with no ledger marker,
   and its REPLY names the file your project reads. acf-whip reads only one config file, the first
   of `.acfwhip/config` and `.backlog/.acfw-config` that exists, and never merges the two. So never
   create `.acfwhip/config` next to an existing `.backlog/.acfw-config`: the new file hides every
   key in the old one, your worktree dir and branch prefix included. This appends to the file that
   is already active (`acfw-store info` names it as `configFile`), for the local-trunk default:
   ```bash
   cfg=.acfwhip/config
   [ ! -f .acfwhip/config ] && [ -f .backlog/.acfw-config ] && cfg=.backlog/.acfw-config
   mkdir -p "$(dirname "$cfg")"
   # A last line with no newline would glue the pin onto that line's value.
   [ -s "$cfg" ] && [ -n "$(tail -c1 "$cfg")" ] && echo >> "$cfg"
   printf 'ACFW_INTEGRATION_MODE=default\n' >> "$cfg"
   ```
   Teams that merge through PRs pin `override` in the same file.
2. **Keep formatters out of `docs/cycles/`.** `acfw-cycle` hashes `plan.md` and `record.md` and
   commits them itself. A pre-commit hook that rewrites either one fails the commit (exit 10,
   `record.md` restored byte for byte) or changes what was committed (exit 11). Add a top-level
   `exclude: '^docs/cycles/'` to `.pre-commit-config.yaml`, and a `docs/cycles/` line to
   `.prettierignore` and `.markdownlintignore` if you have them. If `.pre-commit-config.yaml`
   already has a top-level `exclude:`, add `|^docs/cycles/` to that regex instead: a second
   `exclude:` key is a duplicate YAML key, which is either an error or silently replaces yours.
3. **Take the edit grant out of your generated retro agent.** `.claude/agents/retro.md` was written
   once by `/whip-init` and still carries it. `/retro`'s prompt overrides it during a retro, but `/go`
   still dispatches the agent with that file as its system prompt. Do not re-run `/whip-init` for
   this: it either overwrites the file or leaves it alone. Edit it by hand:
   1. Replace the `description:` line with:
      `description: Use this agent for root cause analysis of work that went wrong - reworked, stuck or unmet tasks - and to propose fixes. It writes the retro doc, one-rule lessons and proposed action items that /retro names, and changes no agent file, workflow or quality standard itself; a human approves every change.`
   2. Replace the line that starts `**MANDATORY**: You conduct retrospectives` with:
      `**MANDATORY**: You find why work went wrong and propose what should change. You do not make the change: a human approves it first.`
   3. Under `## Core Responsibilities`, replace `- Agent instruction updates` with
      `- Proposing fixes as action items a human approves`.
   4. Under `**CAN:**`, delete `- **Modify agent instructions** (EXCLUSIVE)`,
      `- **Update quality standards** (EXCLUSIVE)`, `- Update workflow documentation` and
      `- Commit process changes to git`. Add
      `- Write the retro doc, lessons and action-item plan that a /retro prompt names` and
      `- Propose changes to agent files, workflow and quality gates as action items`.
   5. Under `**CANNOT:**`, add
      `- Change an agent file, a workflow doc or a quality standard on your own → propose it as an action item; a human approves it on the plan card`,
      `- Delete or retire a lesson → list it under ## Retire; a human runs the git rm` and
      `- Commit, create tasks or move tasks`.
   6. In `## Retrospective Process`, replace `5. **Update agent manifests** if needed (if using manifest system)`
      with `5. **Propose manifest changes** as action items (if using manifest system)`.

   In `.claude/agents/precommit.md`, replace `- Modify process → retro (exclusive authority)` with
   `- Change the workflow or quality process → a /retro action item, approved by a human`.

   If you use agent manifests, fix two more places. In `docs/agents/retro.md`, replace the
   `**Scope**:` line with
   `**Scope**: Retro docs, one-rule lessons, proposed action items (a retro-actions cycle a human approves)`
   and the `**IS**:` line with
   `**IS**: Root cause analysis, one-rule lessons, proposed action items (in the order of preference the /retro prompt gives)`.
   In every specialist manifest `/whip-add-agents` wrote (`docs/agents/<agent>.md`), change the
   footer `**Manifest Maintained By**: retro agent` to
   `**Manifest Maintained By**: the project (changes go through /retro action items a human approves)`.
4. **Know what a squash merge does to plan commits.** Each plan event is its own commit with one
   trailer line, `ACFW-Plan-Event: <event> <c12> <cycle-id>`. Merge commits, rebase and fast-forward
   keep it. A squash merge may drop it or indent it inside the squashed body, which costs one WARN in
   `/whip` and nothing else: the approval gate is a content check made at HEAD and never reads
   trailers. Push plan commits with the rest of trunk. `/whip` warns while one is not on your
   upstream, because a teammate without it would decompose the plan a second time.
5. **Update acf-librarian to 1.3.0 alongside.** Its conventions know `docs/cycles/` and
   `docs/acf/lessons/`, and its audit reports what it finds there instead of editing it. The 1.2.x
   audit's `--fix` rewrites broken links in any doc, a cycle's `plan.md` included (which re-arms that
   plan's approval), and renames a lesson whose slug looks dated or versioned.
6. **Optional: point CLAUDE.md at `/whip`.** If your CLAUDE.md has the line `/whip-init` wrote
   before 3.5.0, the first line below, replace it with the second:
   ```
   **Next Steps**: 1) `/whip-add-agents` for specialists, 2) `/task` to decompose scope, 3) `/go` for execution
   **Next Steps**: `/whip` shows where you are and the one command to run next (`/whip "<goal>"` → `/task` → `/go` → `/retro`). `/retro` records one-rule lessons in `docs/acf/lessons/`, relevant when changing an area a lesson names.
   ```

## 3.4.3: fixes that 3.5.0 builds on

- **Harness stages now get their stage rules.** `childPreamble`, the rules that tell every stage of an
  authored harness that the worktree already exists and that the locked checkout is the only
  clean-checkout, was defined in 3.2.0 and never called. So every implement, gate-fix and review-lens
  stage got the bare specialist or reviewer prompt, whose STEP 0 is "run clean-checkout", and
  clean-checkout.sh is not reentrant: its `stash push -u` can sweep a sibling stage's uncommitted
  work into the shared `refs/stash`. The rules now wrap `impl` and `review` stages. `direct` and
  `resolve` prompts are unchanged byte for byte, because "you may only add commits" is false for a
  task with no worktree and for a resolver sitting in the integrator's mid-cherry-pick tree. The
  per-stage run-lock heartbeat comes back with it, so a live `/go` is no longer seen as stale.
- **The clean-checkout token is re-recorded when a harness attaches to an existing worktree.**
  Skipping STEP 0 removed the only token write in that case, which is normal for every same-slug
  sibling after the first and for a re-dispatch after a failed token write. Such a task was parked,
  re-queued and replayed from its ledger with no token, forever. `/go` now re-runs the locked
  command once per dispatch before the harness, only on a clean attached tree. A tree it cannot
  read counts as dirty, and a worktree path containing a space is parsed whole, so the probe can
  never let a stash run over live work. With the review panel on (`escalateReview`), a missing token
  now leaves the task in review for the token gate instead of costing it a life.
- **The files store finds a paused or retired task by its full stem.** `read` and every other
  subcommand matched keys with a substring glob over the active folders, so the full stem of a task
  in `draft/` or `archive/` came back missing, or as an active task whose stem contains it, and
  `transition <stem> draft` could park the wrong card. An exact stem now resolves in every state
  folder before any partial matching, as it already did on beads, multica and linear.
- **The files doctor reports a paused dependency as `WARN|dep-inactive`.** It raised
  `FATAL|dangling-dep` for a dependency sitting in `draft/` or `archive/`, which held the dependent
  task out of the run. The generic battery already warned there. Only a dependency that exists in
  no folder is still FATAL.
- **`/research` works without acf-librarian and on every store.** It hard-exited when
  `docs/acf/organization.md` was missing; it now warns, names what is degraded, and continues. On
  beads, multica and linear it no longer refuses over a missing `.backlog/`, and it files its
  follow-up task through `acfw-store create` instead of writing into `.backlog/pending/`, where
  those stores never look. It no longer refuses over `/go`-only pins it never reads. A new offline
  suite, `phase19-research-preflight`, runs the skill's own preflight shell.

## 3.4.2: what the review found in 3.4.1

The same reviewer read the 3.4.1 fixes and left seven comments, all on code written in that pass.
Six were real, and one of them was a defect that a 3.4.1 fix had introduced.

- **The deliverables-commit handler reported success on failure.** `if ! cmd; then rc=$?` captures
  the status of the negation, always 0 inside the branch, so `exit "$rc"` exited 0 on the one
  failure it had just been added to surface, and left the deliverables staged and uncommitted. It
  is the same shape as clean-checkout's unreachable exit 99, written into the commit that fixed that
  one. Review and testing both miss it, because the happy path is identical, so `run-all.sh` now
  greps every shell file for the pattern and fails the suite instead of relying on care.
- **A stale remote-tracking ref could excuse a reintroduced attributed commit** in the pre-push
  gate. `--remotes=<remote>` is a cached belief about the destination. If someone else deletes or
  rewrites a branch there, the stale local ref hides the commit and rev-list still succeeds.
  Fetching on every push is the wrong trade, so the check runs only when the exclusion is
  load-bearing, and then one `ls-remote` settles it. Detecting staleness needs both directions. The
  case that excuses a commit is a tracking ref for a branch the remote no longer has at all, and
  comparing only the refs the remote reports cannot see it.
- **`price_map: False` survived exactly one session** (acf-mission-control 1.3.4). The opt-out lives
  in the file the self-upgrade replaces, so the next SessionStart read the fresh plugin copy and
  resumed fetching. The setting is now carried across the copy. Its detection was also a bare
  substring test: it missed `"price_map" : False` and accepted a commented-out one.
- **`accepted-branchless-unverified` had no clearing path** on a non-`files` store after 3.4.1
  removed the `--integrated-at` ack. The runbook now names all three endings, with a verified recipe
  for writing a marker by hand and a warning that a marker for work that never landed turns a
  visible warning into a silent hole.
- The advisor README's manual board command referenced a variable nothing sets, and the pre-push
  test scored its allowed-merge case on the absence of a word instead of the push's exit status.

## 3.4.1: what an external review found in 3.4.0

An automated reviewer read the whole 3.2.3→3.4.0 range on a downstream sync and raised 35 findings.
Nineteen survived a check against the code followed by an adversarial attempt to refute them. Nine
that looked real did not survive, which is why every entry below states its trigger and not only
its claim.

### A resolved conflict could silently drop trunk commits

LP-CAS reads `OBSERVED` from the live trunk tip at the top of every invocation. In `--post-resolver`
mode the integration worktree is still detached at the tip the first process saw, because
`cherry-pick --no-commit` does not move `HEAD` and neither does `--quit`. So the candidate was
parented on the old tip while `land()` compare-and-swapped against the new one.

Those are different refs, and the CAS **succeeded anyway**: `update-ref`'s three-argument form checks
only that trunk still equals the value handed to it, never that the new commit descends from it.
Trunk was force-moved to a commit whose ancestry skipped everything committed while the resolver
agent worked: other tasks' integrations, their ledger markers, and on the `files` store every
`.backlog` transition, since `apply-transition.sh` commits to trunk on a different serialization
chain than integrate and both run inside one dispatch wave. `land()`'s own resync then deleted those
files from the working tree as "changed paths". Only the reflog could recover them, and nothing
reported the loss.

The resolver window is an LLM agent run, so trunk moving inside it is ordinary. The base now comes
from the integration worktree, so a moved trunk fails the CAS and exits `11 cas-lost`, which the
caller already retries. Initial mode was never affected. Post-resolver mode had exactly one test
before this, and that test never moved trunk.

### A failed write reported success

`apply-transition.sh` printed `ok:` unconditionally, so a failed `git add` or `git commit` at the
trunk root reached the orchestrator as an applied transition. The task file had already moved on
disk, so `/go` read the move and believed the state change was durable. A whole run's board progress
could exist only as uncommitted working-tree state, which the next clean-checkout or resync
discards. Anything that makes `git commit` fail does this: `commit.gpgsign` with no usable key, a
husky/lint-staged or `core.hooksPath` pre-commit hook, an unset user identity, an `index.lock` held
past the backoff. Both statuses propagate now, which also makes the documented exit 99 reachable for
the first time.

### Adjacent defects

- **`clean-checkout.sh`'s exit 99 was unreachable.** `if ! cmd; then rc=$?` captures the status of
  the negation, always 1, so every worktree-add failure was reported as "another agent owns this
  branch". That is a different diagnosis with a different remedy: defer and take another task,
  instead of retrying this one next iteration.
- **The hydrator wrote to clean-checkout's stdout**, which by contract carries the absolute worktree
  path and nothing else. On any project with a `.worktreeinclude`, the first checkout of every slug
  printed three lines where one was promised. `WT=$(clean-checkout.sh …)` broke outright, and the
  agent paths left the cheapest model in the system to guess which line was the path.
- **`--integrated-at` was advertised on stores that cannot take it.** No adapter maps the field (the
  in-tree ledger is the oracle on every backend), so multica and linear exited 2 and beads stored
  nothing. It ran before the transition, so an operator who followed the doctor's own printed ack
  lost the state change too: the task they believed closed out was still in review. It is refused up
  front now, and the three places that advertised it say `files` only.
- **`price_map: False` still hit the network** (acf-mission-control 1.3.3): the setting suppressed
  the pricing but not the detached rate-table fetch it exists to prevent.
- **Two tests were false greens.** `STUB_DOCTOR_RC=1 D_F=$(…)` is two assignments, not a prefixed
  command, so the stub never saw the variable and the contract's exit-1 arm went untested. A
  regression that folded "ran, found FATALs" into the could-not-run class would have shipped green
  and aborted every `/go` on any board with a real FATAL. And the artifact-provenance fixture
  silently became current content on a truncated history, then failed while pointing at the wrong
  subsystem.
- **The pre-push attribution gate had the wrong range and could skip silently.** It inspected
  `<old tip>..<new tip>` on an existing branch, so merging any external history dragged in commits
  already published on that same remote. And `for c in $(git rev-list …)` inspects nothing when
  rev-list fails, which let a push through unchecked. Both are fixed, and
  `.githooks/pre-push.test.sh` now pins all five properties. The hook had no tests at all, and it is
  the check that still applies after a cherry-pick, a rebase replay or `--no-verify`.
- **Documentation was false about shipped code.** The recovery runbook still described the
  board-wide FATAL gate that 3.4.0 replaced with per-task quarantine. `workflow.md` gave the
  rejection cap as 5 against a shipped 3, and credited task-engineer with moves the orchestrator
  performs. The README claimed the doctor FATALs on a missing slug, when it derives one. The doctor
  still listed a stray-`Integrated-At` check that no longer exists, and `clean-checkout`'s exit table
  left out the code it returns on every non-`files` store.

## 3.4.0: the snapshot no longer goes through an agent unbounded, and a bare `/go` no longer means "everyone's board"

A team running a large shared board reported four problems. Each of the first four sections below
takes one of them and the defects underneath it.

### The snapshot must not pass through an LLM unbounded

A `/go` scoped to five task ids stopped with "/go was scoped to tasks that do not exist in the
backlog", naming three that were all present. The board had several hundred cards and its snapshot was several
hundred KB. `/go`'s scan agent reads the store walk's stdout with its Bash tool and copies it into one
schema string. On that payload the copy came back short (valid JSON, two of five tasks) and nothing
checked it. The scheduler planned over a board that did not exist, could not find the ids it had
been handed, and refused. An operator reading that message goes looking for a typo they did not
make. Raising `shellModel` does not fix this. It only moves the failure to a bigger board.

**Narrowing happens in the store.** `acfw-store snapshot --only <key>...` emits the **closure** of the
named tasks (the seeds plus every dependency that is not accepted-terminal), so a five-task run
relays five records whatever the board's size. It is implemented once, as a dispatcher post-stage
(`skills/lib/bin/acfw-scope-snapshot.sh`) over the final enriched JSON, so every backend gets it
without forking. An adapter sees `--only` only when it declares the new `snapshot-only` capability.
A raw adapter must keep listing everything: the closure walk and the store-wide `counts` are
computed from the full set, and narrowing at the adapter would make both wrong without any error.
The same stage gives the raw adapters a **real `--digest`**. Terminal-accepted dependency targets
collapse to `satisfiedDeps`, non-targets drop to counts, and an accepted but unintegrated task stays
whole. `--digest` had been a documented no-op on every non-`files` backend since 3.1.0, which is how
a lived-in board came to relay every card it had. Seeds resolve by exact id, then stem, then
**backend id** (so `/go MUL-4821` works), then *unique* stem prefix. An ambiguous prefix is reported
with its candidates and never resolved by first match, which on a large board would silently pick
whichever card was listed first.

**The relay proves it arrived.** Every snapshot now leads with a `relay` header: per-array entry
counts plus the UTF-8 byte sum of every stem. The consumer recomputes both. A model that tidies a
header it can see can forge a count, so the byte sum adds a second number derived from content.
Because the header is the first key, an echo cut off at the tail still carries the expectation it
fails. A short relay goes into the existing retry → text-fallback ladder. If it stays short, the run
ends as **`relay-truncated`**, which names the real cause and its remedy, never as a missing id. What
the check proves is bounded and written down: no entry was dropped, added, or replaced by one with a
different stem length. An equal-length substitution passes, on purpose. A length sum is the strongest
check that jq, bash and JS all compute identically, and truncation is the failure seen in
practice, while substitution is not. The ids a caller named get a stronger guarantee: every seed
the store resolved must be present, exactly, in the relayed index, or the run refuses as a relay
failure instead of accusing the operator of a typo. The doctor's findings ride the same hop, so
`SUMMARY|fatal=N` is cross-checked against the lines relayed. A dropped FATAL would silently un-hold
the task it names.

`--full-to` tees the pre-narrowing snapshot so that `doctor --snapshot` reads the scheduler's own
store walk instead of taking a second one, which on a live shared board could straddle a colleague's
transition.

**Two defects found while building it, both live before 3.4.0.** A `blocked` dependency was not
pulled into a scope, because `isTerminal` counts blocked as terminal. But a blocked task is
*retryable*, and the pass that lifts it runs over the scope, so it could never be lifted, its
dependent could never dispatch, and the run exited `no-progress` with the requested task untouched.
Second, a scoped run's `noGain` counter reset only when `terminal` rose. A finished task collapses
out of the working set, so seventeen same-slug tasks exhausted the fifteen-iteration budget and
exited `no-progress` with the work done. On `files`, `/go <a-finished-task>` also reported the id as
nonexistent, because the digest drops a terminal accepted task that nothing depends on. The seed is
now kept through the collapse.

### One malformed card no longer blocks everyone's runs

A single long-cancelled card with a hand-edited state blocked every `/go` for a whole team,
including runs scoped to tasks that never touched it. The integrity gate ran before anything else,
read the whole board, and treated every FATAL the same way.

FATALs now have two scopes. **Repo-scoped** ones (detached HEAD, a worktree on the wrong branch, a
battery that could not run, an unreadable backend) abort as before. **Task-scoped** ones hold out
that one task: it is never dispatched, transitioned or integrated, it still gates its dependents, and
the report names it. The rest of the board runs. A finding whose task field names nothing the
scheduler can act on gates nothing and is reported as `fatalsNotGating`; aborting on those would
bring back the board-wide gate this release removes. Matching is by exact whip key. `CONTRACT.md`
now makes field 3 a routing decision instead of a label, because a prefix or slug matched loosely
would attach a finding to the wrong task, and that is the one way per-task quarantine is less safe
than aborting.

Holding a task out changes what "done" means, so there is a new terminal reason: **`partial`**, with
`completed: false` and a `heldOut[]` naming each task and why (`quarantined`, `paused`, `vanished`).
A run that finished everything it was *allowed* to touch has not finished the backlog, and an
operator must not have to infer the difference. `gated[]` explains a `no-progress` exit by naming
the dependency each pending task is waiting on, instead of pointing at folders it is not in.

This has three consequences. A held-out task keeps its worktree slug reserved, because freeing it
would let a same-slug sibling's `clean-checkout` sweep its uncommitted work into the shared stash.
The quarantine is recomputed every iteration, so a card an operator fixes mid-run comes straight
back. And the post-loop drain applies it too; otherwise the one pass that exists to catch stragglers
would integrate a task the gate had refused. Quarantine is workflow-only: the legacy markdown
loop still refuses on any FATAL, and `skills/go/SKILL.md` says so and why.

### A bare `/go` runs your focus

`/go` with no arguments meant "the whole backlog". On a checkout whose backlog is its own, that is
what the operator meant. On a shared board it never is, so the only safe habit was naming ids every
time, which is the complaint that started this work. Dropping arguments entirely would have removed
selective launch, which is worse.

The **focus** is the third option: a small, per-checkout list of the tasks you are working on, which
a bare `/go` runs. `/task` sets it to the tasks it just created, chained onto each `create` with
`&&` so that a create failing on a duplicate id never enters it. The ordinary path, plan → `/task` →
`/go`, then needs no arguments at all and still runs only your own work. `/whip-focus` manages the
focus by hand. It is gitignored, per-checkout state, because a focus is one person's selection and
never a fact about the project: two people on one board have two focuses.

The focus holds script-resolved stems only. `set` and `add` resolve every token through the store,
and if any token is unknown or an ambiguous prefix they refuse the whole operation and write
nothing. A focus holding raw arguments would inherit every ambiguity of what was typed, and a
selection that silently changes meaning is worse than none. Without `jq` the resolution reads the
snapshot with `sed`; the `files` backend runs without `jq`, so there that is the normal path, not a
fallback. The first version scanned the whole document for `"key":"value"` pairs:
`acfw-focus set <two ids>` wrote thirteen entries, including a commit SHA, a trunk path and the word
`pending`, and exited 0 reporting success. Every field is now bounded to its own delimited object,
and an arithmetic guard refuses the whole operation unless the store resolved exactly as many
entries as there were distinct tokens. `show --live` also says when it cannot answer, instead of
falling back to a bare stem list that looks identical to a list of runnable work.

Adding to a focus whose tasks are all done replaces it; otherwise finished work would ride into
every later run's scope. That check no longer depends on `--no-resolve`, which had exempted the one
caller that matters, since both `/task` writers pass it. Every write refusal is now the script's
exit. `write_focus` ran as the last stage of a pipeline, so its own `exit` (and the hard refusal when
`.acfwhip/run/` cannot be gitignored) ended only a subshell, and the next line printed
"focus set: N task(s)" with status 0.

With no focus, a bare `/go` follows a per-store policy: `files` drains the whole backlog as before,
and every shared API-backed store **refuses** and names the three ways forward. `/go --all` is always
the explicit "yes, everything". An explicit `/go <ids>` never writes the focus. Turning a one-off
selection into the standing default would mean the next bare `/go` ran something nobody chose.

**Pausing is now a state.** `/whip-move <task> draft` pauses a task and `archive` cancels it, on
every backend. Both are inert to the scheduler and still resolve as dependencies, so a dependent
reads as gated, not dangling. Dropping a task from a focus is documented as *not* pausing it: a
scoped run pulls in unmet dependencies, so a dropped task that something else needs comes straight
back. `drop` does now resolve ids, native ids and prefixes, as the docs always claimed. Before, it
matched stored stems literally and printed "focus now: N" after removing nothing.

A parked task's worktree and branch are no longer reaped either. The orphan reaper builds its
liveness census from the active folders, and draft and archive are not among them. So the supported
way to pause work was also a way to have the next bootstrap `doctor --fix` force-remove the worktree
and delete the branch of a committed but unintegrated deliverable, with `/go` discarding that pass's
output. Parked slugs are now `WARN|parked-task-worktree`: reported and never reaped, because a
leftover worktree an operator can see is better than a deletion nobody can.

On **multica and Linear**, `doctor --fix` no longer overwrites a human hold. A native
`blocked`/`cancelled` against a runnable whip state was treated as drift and repaired, so every `/go`
bootstrap silently un-parked every card the team had parked. It is now `WARN|native-hold`, names the
remedy, and leaves the card alone. Linear keys on the workflow state *type* (`canceled`, which only
`archive` maps to), so a hold there is unambiguous. multica's `blocked` is a value whip projects onto
itself, so a stale write and a human hold cannot be told apart. The finding says so and names the
re-sync command instead of claiming a certainty it does not have.

### Agents are routed by what they do

Before 3.4.0, routing had one knob, `shellModel`. In `/task` exactly one call took the cheap tier.
The agent-registry `ls`, both single-writer calls (whose prompts are a fixed list of
`acfw-store create` lines) and the report-only doctor all inherited the session model, paying
frontier generation cost to echo command output. Specialists and reviewers ignored the `model:`
frontmatter of the agents the project installed, which is where a project says "this kind of work
runs on that model".

Tiers are named for what the agent does. **shell** runs a fixed command and copies stdout into a
schema; one helper applies it, so a new stage cannot forget. **judge** covers the `/task` planners,
judge and critic. **author** writes task documents. The `agentType` classes now route by the
installed agent's declared model. The architect and the conflict resolver stay on the session model
on purpose: one authors executable harnesses, the other resolves real merge conflicts. Resolution is
env > `.acfwhip/config` > default (`ACFW_MODEL_SHELL`/`_JUDGE`/`_AUTHOR`), so a team pins its cost
policy once per repo. judge and author ship unset and inherit the session model as before. Both
reports gain `models` and `agentsByTier`. The lesson from 3.2.0, that a run which silently degraded
looks the same as one that did not, applies to cost as much as to depth.

A shell-tier `effort` knob exists and ships **unset**. Haiku is absent from the documented
effort-support table, and the effect of a low setting on verbatim-copy fidelity is undocumented, so
it is opt-in. A team can now measure it safely, because a short relay is detected instead of
believed.

Raising the shell tier was the workaround suggested for the truncated snapshot. It is the wrong
lever: it would triple the cost of the most frequent agent class and still fail on a large board.
That tier stays cheap, and the payload is bounded instead.

### Adjacent defects fixed on the way

- **`cyclic-deps` reported every task a cycle could reach**, not the cycle. The detector peeled
  nodes with no dependents and reported whatever survived, so on `a→{b,c}, b→a` it named `a`, `b`
  **and** `c`. A Tarjan SCC pass shared by both batteries replaces it. This matters more from here
  on, because an over-broad cycle report now holds healthy cards out of a run instead of only adding
  noise.
- **The orphan reaper destroyed unlanded deliverables.** In default mode every accepted slug counted
  as spent, so the next bootstrap `doctor --fix` removed the worktree of an accepted but unintegrated
  task and `-D`'d its branch. A task ends up in that state on purpose when the drain leaves an
  exit-7 conflict "for the next `/go` run", and by accident when a crash lands between accept and
  integrate. The next scan then read `hasWorktreeBranch=false` and called the task terminal, and
  the deliverable was gone with nothing saying so. A slug is spent once its change is on trunk, and
  both batteries now agree on that.
- **`dup-folder-unresolvable` was invisible to the gate.** It existed only inside the `--fix` block,
  whose stdout `/go` discards, so the gate saw `REPAIRABLE|dup-folder`, called the board repairable,
  and dispatched against a stem no writer can address. Both passes compute it now.
- **Every pre-dispatch abort releases the run lock.** A run that stopped before dispatching anything
  left its own heartbeat fresh, so an operator who fixed a typo in ten seconds was refused for the
  next half hour with "another /go run appears active". Nothing had been dispatched, so there was
  nothing to protect. Aborts also carry their `stopReason` now; `skills/go/SKILL.md` had documented
  it for two releases without it ever being emitted. The one abort that still held the lock, a
  snapshot missing its runtime-terminal counts, releases it too.
- **A quarantined dependency did not gate its dependents.** Both dispatch queues called
  `depsSatisfied(t, idx)` without the quarantine set. The parameter is optional by signature, so
  nothing failed: the check became a no-op in the two places that dispatch, while the three places
  that only report passed the set. A task whose dependency an integrity FATAL held out ran anyway
  whenever that dependency was accepted-terminal (the duplicate-key shape the check exists for), and
  the same iteration reported it as gated. The test that covered it passed for the wrong reason.
- **A recovered task was reported as held out, and its work was stranded.** `heldOut` was both the
  run's history and the input to every decision. A card whose FATAL an operator fixed mid-run made
  the run report `partial` even though it ran, and the post-loop drain re-quarantined from the same
  map, excluding the accepted work of the task the operator had just repaired. The live set and
  the audit trail are separate now (`heldOut` vs `heldOutEver`, with `lifted` on the recovered ones).
- **A missing relay header passed.** The header is SHOULD for a third-party adapter, but every
  adapter acf-whip ships emits one. The threat is a model shortening what it echoes, and such a
  model is at least as likely to drop a header it does not understand as to recompute it. On
  `files`, `beads`, `multica` and `linear` a missing header is now a relay failure.
- **A dependency token that prefixed its own task was reported as a cycle.** The resolver's prefix
  fallback never excluded the depending stem. So `feature-231-api-v2`, declaring a dependency on a
  `feature-231-api` that no longer exists, prefix-matched itself, the self-loop branch fired, and
  `/go` refused to dispatch against a cycle that was not there. Which stem won depended on awk hash
  order, so the result was not even reproducible across platforms. The finding is now
  `dangling-dep`, which is true and names the thing to fix; a genuine self-dependency is still a
  cycle.
- **A trailing `--mode` spun forever.** `shift 2` with one argument left is an error that shifts
  nothing, so the parse loop never advanced. In `acfw-store` it also appended two array elements per
  turn, so it grew without bound instead of only hanging. Every flag added in this release already
  had the guard. Only `--mode` was missed, in three files, plus all four value flags in
  `whip-move.sh`.
- **`acfw-store info` could emit invalid JSON.** `grep -c` prints `0` *and* exits 1, so `|| echo 0`
  appended a second zero and an emptied focus produced `"focusCount":00`. jq tolerates that and
  `JSON.parse` rejects it, in the single object `/go` step 2 reads to decide what to run.
- **`agentsByTier` undercounted.** Tiers were incremented in the option helpers, but `safeAgent`
  charges up to three real agents per invocation on a retry, and every agent a child harness spent
  went into `agentsUsed` and into no tier at all. Agents are now counted where they are charged, with
  a `child` tier and an `untiered` bucket, so a dispatch through neither helper shows up as a number
  instead of vanishing. `/task`'s two recon agents were such a dispatch.
- **`efforts.shell` had no way in.** The `/go` skill documented it, both workflows read it and both
  reports echoed it, but nothing produced it: no config key, no `info` field, no skill passing it.
  `ACFW_EFFORT_SHELL` now resolves env > `.acfwhip/config` and refuses an unrecognised value, because
  a rejected option would fail every agent call in the run.
- **Linear's drift loop could mis-split its own input.** Tab is IFS *whitespace*, so a run of tabs
  collapses. An issue with no `stateId` shifted every later field left, the state type came back
  empty, and the `native-hold` guard silently never fired, so the loop repaired a cancellation a
  person had made.

### Compatibility

The contract stays at v1 and every change is additive. New capability: `snapshot-only`. New
dispatcher-implemented options: `snapshot --only` and `--full-to`. New snapshot fields: `relay{}`,
`scope{}`, `scopeApplied`, `scopeCounts`, `inactive[]` on `files`, and `backendId` in
`satisfiedDeps`. Two new `acfw-store info` fields: `efforts{}` beside `models{}`, and
`bareGo`/`focusFile`/`focusCount`. New report fields:
`heldOut`/`heldOutEver`/`fatalsNotGating`/`gated`/`relay`/`models`/`agentsByTier`. One new WARN
code: `parked-task-worktree`. A third-party adapter that emits no `relay` header is tolerated: the
consumer logs once that completeness cannot be verified and proceeds, because refusing would brick
every such backend on upgrade. `deps[]` are still stems. The `backendId` resolver serves seeds only,
never dependency tokens, which both doctors resolve by stem or prefix and would FATAL on as a native
id. The child-harness skeleton gained args, so its contract stamp goes to v2, and a harness authored
against the previous skeleton is re-scaffolded instead of byte-diffed against a template it
predates.

Still open, as in 3.2.3: the run lock is per-checkout and `transition` has no compare-and-swap, so
`atomic-claim` remains unimplemented. Scoping and the focus narrow what one person's run touches.
They do not make two concurrent runs against one shared board safe.

## 3.3.1: two ways to lose work on the default backend

After release, the 3.3.0 tree itself was audited, subsystem by subsystem, and every candidate defect
went to an independent agent whose job was to refute it. Seventeen survived. **Two of them lose work
on the default `files` store with no operator error involved. Neither is a regression from 3.3.0;
both predate it.** The rest follow the pattern 3.3.0 named and did not finish clearing out: a guard,
a flag or a test that answers a question it had no way to ask.

**The integrator reverted work it never landed.** After a compare-and-swap onto trunk, `land()`
resynced the root checkout with `checkout --no-overlay -- . ':(exclude).backlog'`, which covers the
whole tree. The exclusion spared uncommitted task-file state, which is what it was added for, and
nothing else. A `Worktree: none` task edits tracked files in that same tree by design, and it does
so *concurrently*: `/go` starts the prior-integrate pass as a floating promise and awaits it only
after the dispatch barrier that runs the direct queue. So a direct task's deliverable was reverted
mid-flight. The backlog writer then staged an unchanged file, the committed-deliverable check passed
against that file's pre-existing history, and the task was reported **accepted and integrated with
none of its content anywhere**. Nothing was logged. The pathspec is now the landing's own
`OBSERVED..NEW` diff. An empty diff skips the checkout instead of degrading to `-- .`, which is why
the guard is a shell test and not an `xargs -r` pipeline (BSD `xargs` has no `-r`). When a path this
landing *does* change is also dirty, the overwrite cannot be avoided, but it is reported with a
`stash create` snapshot. That is a commit object that touches neither the working tree nor
`refs/stash`, so it cannot race a sibling stage the way `clean-checkout.sh`'s `stash push -u` would.

**`doctor --fix` deleted every copy of a duplicated task.** The `dup-folder` repair picked the
survivor by reading `Status` from the first-listed copy and removed every copy that did not match
it. That read was never validated, and it could come back empty in two ways: an unparseable
`Status` line (the same malformed copy whose status-sync repair is skipped), or a detail string the
`sed` cannot match, which returns the whole detail and turns the probe path into one that does not
exist. With an empty keeper no folder matched, the skip never fired, and the loop `git rm`'d all of
them. The `|| rm -f` fallback then unlinked an untracked copy outright, with no history to recover
it from. `/go` runs `doctor --fix` at bootstrap with its output discarded, so this also erased the
FATAL that should have stopped the run before it dispatched. A duplicate whose survivor cannot be
identified is not repairable: the repair now emits `FATAL|dup-folder-unresolvable` and leaves every
copy intact. It had **no test at all**; it has five now.

**A lost clean-checkout token was a permanent fixed point.** A missing token on a task that *does*
have a worktree branch is mechanical, so the review gate left the task in `in-review/` for the next
iteration. But nothing in the loop can write a token. `clean-checkout.sh` is its only writer and runs
at dispatch, and the reviewer is explicitly forbidden from writing one. So the task sat in
`in-review/` across every later run, the run ended `no-progress` with committed work never
integrated, and the slug claim starved every same-slug sibling for the whole run, every run. That
branch of the gate now re-reviews once, which is enough when the cause was a lost `append_log_row`
race, and then parks the task in `blocked/` as `needsOperator`, charging no rejection for a fault the
orchestrator could not write its way out of. The most common cause is fixed at the source.
`clean-checkout.sh` discarded the store's return code, sent the adapter's diagnosis to `/dev/null`
and exited 0, while on a non-`files` store that call is the **only** durable write of the token. It
now retries the contract's transient code, and only that one, and exits 6 instead of printing a
worktree path as though the token were recorded. Linear's `issue_has_token` was the one `gql` caller
in that file that did not propagate `GQL_ERRCODE`, so a single 429 read as "this specialist never
entered a worktree". multica's two paid fallbacks had the same shape. 3.3.0 missed them because they
answer through the token list, not through the metadata helpers that release made tri-state.

**A scoped `/go` called an unknown state complete.** `expandScope` refused a seed by listing `draft`
and `archive`, but the enricher defines the inactive set by *exclusion*. A card whose state was
absent or out of vocabulary therefore had no folder at all and passed straight through. The
scheduling view came back empty, and an empty scoped view reports complete: "Backlog 100% terminal",
zero agents, `integrated: []`. It was byte for byte the failure already fixed once for `draft`. The
scheduling view is now passed in and asked directly. Terminal seeds stay exempt, so scoping to
collapsed accepted work still resolves.

**The legacy loop integrated nothing.** Step 4.5a filled `INTEGRATE_QUEUE`, and Step 4.5b iterated
`SORTED_QUEUE`, which nothing in the plugin assigns. So `integrate-lpcas.sh` never ran, no ledger
marker ever landed, the terminal count could never reach the total, and every deliverable stayed on
an unmerged branch. This is the fallback path 3.3.0 deliberately routes operators into when the
Workflow tool refuses a launch. Step 4.5a also promised a topological sort in prose and did not
perform one. It does now, and a cycle emits its members in input order instead of stranding them.
The static gate that should have caught this listed two variable names by hand. It now derives them
from the skills, and on the previous tree it flags `INTEGRATE_QUEUE`.

**One unreadable document blanked the whole session payload.** 3.3.0 guarded the artifact sync loop
because the hook had just gained destination-side I/O. The guard did not cover the second read:
`main()` opens `docs/acf/style/task-descriptions.md` again to build the payload body, inside its
single `try`. That file is the *first entry in the managed list*, the document the refresh mechanism
explicitly invites consumers to edit. One cp1252 smart quote, and the catch-all replaced the entire
`additionalContext` with an errno string. The mandatory style guide, the task-store warning and the
could-not-sync notice all went missing together, on every session, permanently. The existing
bad-byte fixture wrote to `workflow.md`, the one managed document that is *not* read twice, which is
why it passed while this bug was live. There is now a fixture per managed destination. The recovery
runbook also joins the managed set. `whip-init` installs six documents and that list carried three,
so a pre-LP-CAS runbook telling an operator to rebase a worktree branch could sit unrefreshed
forever.

**Also fixed:**

- `--quiet` was honoured by the adapter half of a merged doctor report and nowhere else, so hundreds
  of advisory WARNs went through the scan agent every iteration, against the limit `workflow.md`
  states as a requirement. The flag is now peeked instead of consumed, and filtering happens at
  print time, with the tallies taken over the unfiltered set so it can never change the gate
  decision.
- `ACFW_INPROGRESS_TIMEOUT_HOURS` had its documented env-over-config precedence inverted, by the same
  source-the-config trap the file documents nine lines above for `ACFW_INTEGRATION_MODE`. One run
  could time a task out in the scheduler while its own doctor reported nothing.
- An `agentCap` at or below the fixed 150-agent reserve made the CLOSE rung fire at *zero* agents
  used, reporting `agent-cap-reached` and "Nothing lost." for a run that dispatched nothing. That
  rung is not gated on `ESCALATE`, so `escalate: false` hit it too.
- `research-agent-pattern.md` told non-code agents the materialized spec is "a materialized copy the
  orchestrator syncs back". Nothing syncs it back, so an agent that took the template at its word
  lost its whole deliverable.
- `/whip-add-agents` re-rendered the 265-line sample over `.backlog/README.md` to change one line,
  replacing the team's gate commands and thresholds while reporting only "(agent list updated)".

**`beads` is no longer the backend nothing can test.** multica sends every call through
`ACFW_MULTICA_BIN` and linear through `ACFW_LINEAR_TRANSPORT`, which is what let 3.3.0 run the frozen
conformance spec offline against a fake CLI. beads resolved `bd` straight from `PATH`. It has the
seam now, and a static gate holds all three to it. The fake `bd` that would let its suite run
offline is the remaining work, and the seam is what makes it possible.

**Two tests in this release could not fail.** Linear's "`--quiet` keeps every FATAL" compared 0 to 0,
because no fixture in that suite ever produced a FATAL: with the adapter's `--quiet` branch reverted
to its v3.2.3 shape, the run still printed `ALL GREEN`. And the small-cap escalation test asserted
that a cap of 10 makes the ladder "fire immediately", which was the defect written down as a
requirement. Every fix above has an assertion verified to go red when the fix is reverted.

Deferred on purpose: `--digest` is a no-op on every non-`files` backend. The dispatcher never passes
the flag to the enricher, and the enricher never collapses terminal-accepted tasks into
`satisfiedDeps` the way the `files` scanner does, so a large board relays its whole snapshot through
one agent's structured output. The fix is not patch-sized. It needs flag plumbing, a three-way split
so that an accepted but unintegrated task stays a full object, and counts taken before the collapse.
It lands in 3.4.0 with the `--only` filter, which shares its measurement.

## 3.3.0: the non-`files` backends stop being invisible

Every defect in this release was found against a live non-`files` store, and they share one cause:
**`files` was the only backend the test suite could see.** `run-all.sh` marked the three adapter
suites OPTIONAL, each skipped unless a live server was reachable, and the runner counted a `SKIP` as
a pass. So the backends were green by absence on every developer machine and in CI. The contract's
own executable spec, `phase9-store-conformance.test.sh`, defaulted to the `files` adapter, so it
only ever ran against the one implementation that already worked.

That is fixed first, because nothing else in this list could have been caught without it. The
multica suite now writes an offline fake of the CLI and runs the frozen conformance spec against it
with no server, no credentials and no skip. The fake is injected at the `ACFW_MULTICA_BIN` seam that
the adapter already sends every call through, the same shape the Linear suite has used for its
GraphQL emulator since 3.1.0. Fixing the runner's skip detection then un-masked the Linear suite. It
had been reported as skipped, and therefore could not fail, only because it skips its live-server
half. Both are now first-class; only `beads` still skips, because it needs a real `bd`.

**The orchestrator charged a spurious rejection to every code task.** `runReviewAndIntegrate` has two
callers with opposite freshness guarantees, and its deterministic clean-checkout gate assumed the
fresh one. On the inline path the task object is the one the scanner produced *before* this
iteration dispatched the implementer, so on a first attempt both `hasCleanCheckoutToken` and
`hasWorktreeBranch` are false, and false-with-no-branch is the gate's most destructive arm. Every
code task, on every backend including `files`, was hard-rejected on its first completion and charged
one of its three lives, then recovered the next iteration once the branch existed. That recovery is
why the bug went undiagnosed from 3.2.0 on. The gate now applies only where the scan observed the
task *after* the implementation ran. A specialist that did skip clean-checkout is still
caught by the reviewer's own rule on the live document. The auto-reject was also the one unlogged
outcome in that function and appeared in no run tally, so a run could reject everything it
dispatched and still report `completed: true`.

**`/whip-doctor --fix` destroyed deliverables on non-`files` stores.** `doctor.sh` is the `files`
engine: every task check is gated on a `.backlog/<state>/` directory, so on another backend all of
them were skipped and the summary reported `ok=true` on zero evidence. The worktree pass is not
gated. It built its live-slug set from the now-empty task table, concluded that every acf-whip
worktree was orphaned, and under `--fix` ran `git worktree remove --force` plus `git branch -D` on
each. In override mode that branch is the operator's only copy of an accepted but unintegrated
deliverable, as a comment in `doctor.sh` itself says. `doctor.sh` and `scan-backlog.sh` now refuse
when the resolved store is not `files`, on stderr and with no parseable output; a refusal that a
caller could read as a clean report would be the same defect one layer up. Every skill that invoked
a battery by path now goes through the dispatcher, and a static gate keeps it that way.

**Absence of findings was treated as health, in four places.** The dispatcher discarded the adapter
doctor's exit status (it took the pipe's) and turned a failed snapshot into a WARN, so an unreachable
backend, an expired token or a crashed adapter produced `ok=true`, `exit 0`, and `/go`'s startup hard
gate dispatched against a board nobody had read. `beads`' doctor skipped its entire per-issue battery
on a failed export, with no `else`. Its `read --materialize` silently left out the audit trail that
the reviewer greps for the clean-checkout token, which reads exactly like a task that never ran it.
Linear's `gql` returned success on a body that was not JSON at all. All four now report the failure,
and the dispatcher reports a battery that could not run as `FATAL|doctor-unavailable` instead of
staying silent. `/go`'s gates tell the operator which failure they hit, because "the backlog is
inconsistent" sends someone whose store is unreachable to a tool that cannot reach it either.

**Transients were written into durable state.** multica's metadata helpers answered a three-valued
question (the key holds X, the key is absent, the read failed) with one value, so a timeout or a 5xx
looked the same as "absent", and the read-modify-write callers wrote that made-up answer back. It
was reproduced against the offline fake, with the fault aimed only at the read so the write path
stayed live: a rejection counter went from 2 to 1, and a dependency list of three entries collapsed
to the one being added. A third case made the idempotence guard miss and re-ran a transition that
had already landed. Both helpers are tri-state now, and the four call sites refuse instead of
writing.

**One inert card gated a whole board.** multica reported any `whip_state` outside the canonical nine
as a FATAL. But the scheduler dispatches on exact state equality, so a card in a state it does not
name can never be dispatched, transitioned or integrated, and cannot make a run wrong. It is now a
WARN with the retire command in the detail. Relatedly, both doctor batteries decided "is this a gate
FATAL?" by `folder == accepted`. That is right on `files`, whose scanner never emits `draft` or
`archive`, and wrong everywhere else, where the adapter lists them: a draft stub with no agent file
produced `FATAL|unknown-agent` and blocked `/go` outright. The tier now asks the real question,
whether the task is in the dispatch path. `draft` and `archive` move to a sibling `inactive[]` array
that dependency resolution still sees but nothing schedules, counts or checks. A task that depends on
a draft now reports `WARN|dep-inactive` with the remedy, instead of a false `FATAL|dangling-dep`.

**`--quiet` hid the gate decision.** Both API adapters suppressed every finding line, FATALs
included. Without `doctor-complete` the dispatcher recomputes `ok=` from the lines it receives, so a
swallowed FATAL became `ok=true` for the startup gate and every recheck, while the verbose
`/whip-doctor` path showed the same FATAL. That is how one backlog got two contradictory verdicts on
the same day.

**`hasCleanCheckoutToken` was answered for only one or two states.** The contract defines it as a
flat per-task boolean, and two consumers read it. multica answered it for `in-review` alone, so every
task lifted from `completed` into review read its token as absent and had its review skipped.
Widening it there costs nothing, because since 3.2.0 the transition log lives in the issue
description, which the snapshot already fetches, and the change removed a quadratic re-parse too.
Where each answer costs a request, the paid set is now bounded to the states where a wrong answer
costs something. The new `token-all-states` capability lets a consumer tell "no token" from "not
scanned". Without it, every finished task on Linear carried a permanent false advisory.

**The plugin could not fix a document it had already shipped.** The SessionStart hook copied three
plugin-owned documents into a consumer project and never looked at them again. So a correction made
here never reached a consumer's copy, which aged in place in their repository and read as their own
documentation. That is the mechanism behind the whole shipped-template defect class. The obvious fix
(stamp a version, compare, upgrade) does nothing on the release that introduces it, because every
existing copy predates stamping and an unstamped file must never be clobbered. So a pristine copy is
now recognised by its **content**: `content/.digests.json` carries the sha256 of every version of
each managed document this plugin has shipped, and a local copy that matches any of them is
refreshed. A copy that matches none was edited by hand. It is never touched, and it is reported as
behind.

**What the plugin ships now agrees with what it requires.** The reviewer template contradicted
itself: its first section ordered the reviewer to move task files, and Step 10, two hundred lines
later, said it must not. Obeying the first is worse than useless. The writer is idempotent, so a task
the reviewer already moved makes the transition a no-op, which silently drops the rejection
increment. The template also told reviewers to escalate at five rejections while the orchestrator
blocks at three, so that branch was unreachable. `research-agent-pattern.md` told a non-code agent to
move and commit its own task file and never mentioned `deliverableFiles`, the one field that keeps a
research document safe from the next `clean-checkout`. Eleven templates hardcoded `.backlog/` with no
hint that it is one backend's layout. And `workflow-architect`, selected by `/go` since 3.2.0 and
documented in three places, was created by no installer, so the headline capability silently fell
back to the default agent on every project for two releases. It now exists, `whip-init` installs it,
and its absence is logged and reported. `phase17-template-drift` pins all of this to values read from
the runtime source, so the test cannot drift away from what it guards.

**`derive_slug` truncated ids.** Its fallback matched four digits followed by an unanchored `.*`, so
`bug-62015-alpha` and `bug-62017-beta` both derived `bug-6201`: two tasks on one worktree branch,
which is the one thing a per-task slug exists to prevent. The sequence number is now unbounded and
anchored, an id the pattern cannot account for gives up instead of matching a prefix of itself, and a
collision is a FATAL naming both tasks. The category vocabulary gains the conventional-commit types
beyond the original eight, and its two implementations are pinned to each other.

**Doctor cost, measured.** No board above 337 tasks had ever been timed, so "more than ten minutes"
could not be attributed to anything. At 600 tasks the two superlinear graph passes are **not** the
bottleneck: memoising the dependency resolver and turning the glob-overlap pass from pairwise into an
index moved wall-clock time by about 3%. What those changes fixed is the output. One advisory per
overlapping *pair* meant 120 pending tasks produced 541 lines to read past; now they produce 121. The
real gain is `--active-only` on the bootstrap re-scan: 30.4s down to 8.7s from one word, with a
byte-identical FATAL set, as `doctor.sh`'s header has promised since 2.x. `tests/perf-doctor.sh`
records the baseline. Batching the per-file extraction is the next real gain, and it is deliberately
not attempted. Rewriting that layer is worth its risk only against a measured need, and 8s at 600
tasks is not one yet.

**Also fixed:**

- `/go` and `/task` launch by registered name instead of by a path under the plugin cache, which the
  Workflow tool refuses for anyone who installed this plugin normally.
- The legacy fallback loop, which they now route into, runs. Before, it used bash 4 associative
  arrays and dropped every non-code task into an array nothing read.
- `args.maxReject`/`args.maxBlock` bind all four cap decision sites, not only the one that already
  accepted them.
- `args.planners` is passed through now.
- `/task`'s scratch directory moves under the already-ignored `.acfwhip/run/`.
- `doctor --snapshot FILE` lets a caller that already holds a full snapshot spare the dispatcher a
  second store walk. It refuses a narrowed or digest snapshot as a usage error, because the graph
  invariants cannot be computed from a subset.

**Reviewed before shipping.** The diff above went through an adversarial review of its own, and
thirteen follow-up commits landed before release. Three fixed regressions this work had introduced.
The SessionStart hook gained destination-side I/O with no per-artifact guard, so one non-UTF-8 byte
in a document the release invites consumers to edit discarded the entire session payload.
`--active-only` on the bootstrap gate silently dropped the two content-loss FATALs, which are the
ones that mark a destroyed document. And unioning `inactive[]` into the dependency index made
`/go <a-draft-task>` answer "complete" instead of "not actionable".

The rest shared one pattern: **a guard that reports success on the exact condition it exists to
catch.** The derived-slug registry was a shell variable assigned inside a command substitution, so
it never accumulated and its FATAL was unreachable. The four new multica read guards interpolated a
variable set in a subshell, and printed a dangling colon instead of the backend's error.
`run-all.sh`'s write-only-array gate used `grep -c` with `|| echo 0`, which produced `"0\n0"` and an
arithmetic abort, so it could not fail for any input. The reviewer's clean-checkout backstop, cited
in a code comment to justify weakening the deterministic gate, grepped for a row that the reviewer's
own Step 0 writes. And five assertions, including two written as proof that these fixes work, passed
with the code under test deleted.

Every fix above now has an assertion verified to go red when the fix is reverted.

All contract changes are additive; `ACFW_CONTRACT_VERSION` stays `1`.

## 3.2.3: /go can be pointed at part of the backlog

`/go` took the whole backlog or nothing. No argument, env var, config key or adapter flag selected
tasks. `skills/go/SKILL.md` was the only whip skill with no `argument-hint`, `whip-go.workflow.js`
read thirteen args and none of them selected tasks, `scan-backlog.sh` parsed three flags,
`adapters/CONTRACT.md` had no filter verb, and the multica adapter's `cmd_snapshot` says outright
that its flags "are hints; a full snapshot is always valid". This was never a regression: no revision
of the skill or the workflow has ever supported it.

On a backlog a team shares, this cost more than convenience. One person's `/go` is everyone's `/go`,
so people stopped running the shipped orchestrator and hand-wrote throwaway workflows instead, which
takes a frontier model every time, for work the plugin already does.

**`/go` now takes arguments, in two forms that resolve to one mechanism.**

```
/go                                          every actionable task (unchanged)
/go api-014-token-refresh ui-021-login-form  exactly those, plus their unmet dependencies
/go frontend tasks only                      everything a frontend agent owns
/go bugfixes                                 the fix/bug tasks
```

Ids pass straight through. A natural-language filter is matched **in the skill, once, before
launch**, against the fields every backend's snapshot already projects (`agent`, `slug`,
`priority`, `stem`, `touchesGlobs`), then shown to the operator and confirmed. Either way the
workflow receives a concrete stem list, so the orchestrator stays deterministic and the selected set
cannot drift mid-run. Passing the predicate down and re-evaluating it every iteration would have cost
an agent call each time and brought back the unpredictability that drove people off `/go` in the
first place. The snapshot has no title or body. A predicate the projected fields cannot decide asks
for ids instead of guessing, and a filter that matches nothing stops instead of falling back to the
whole backlog.

**The index stays whole; only the scheduling view narrows.** The obvious implementation, filtering
`tasks[]`, is wrong, and nothing would show it. `tasks[]` is the bounded working set that
`indexTasks` builds dependency resolution from, and `depsSatisfied` treats an unresolvable dependency
token as dangling and refuses to dispatch (conservative by design; the doctor FATALs on the same
condition). Narrowing the array would strand every scoped task that depends on something outside the
scope. So `idx` is built from the full set, and a separate `sched` view feeds the six planning sites
and nothing else: the unblock/timeout plan, the in-review, completed, pending and rejected queues,
and the integration candidates.

**Completion is counted over the scope.** `total` and `terminal` came from `snap.counts`, which is
store-wide. Reusing it for a scoped run makes `terminal === total` unreachable, so the run would burn
all fifteen `NO_GAIN_LIMIT` iterations and exit `no-progress` with its work done. A scoped run counts
`isTerminal` over its own tasks, and a scope that is already entirely terminal stops at once instead
of spinning past the `total > 0` guard.

**Unmet dependencies are pulled in; terminal ones are not.** `expandScope` walks the seed's
transitive dependencies and adds any that are not terminal, so a scoped task cannot sit gated
forever behind something the operator forgot to name. An accepted and integrated dependency needs
nothing and is left alone. Cycles terminate. The pulled-in stems are named in the run log and in
`scopeResolved`.

**Nothing outside the scope is touched.** It is not dispatched, transitioned or integrated,
including by the post-loop drain, and `needsOperator` is filtered to the scope too. That is what
makes a scoped run safe on a backlog other people are working in. An id that matches no task aborts
the run (`stopReason: 'scope-unresolved'`) instead of silently running less than was asked for.

The `RunReport` carries `scopeFilter`, `scopedTo` and `scopeResolved`. `scopeFilter` holds the
operator's words and is the only record of a natural-language filter, since `only` holds resolved
stems. With no arguments all three are null and behaviour is byte-identical to 3.2.2.

Scoping does not fix the deeper hazard it exposes. On a shared non-files backend the run lock is
still per-checkout and `transition` is still a read-modify-write with no compare-and-swap, so two
runners can still collide. Scoping lowers the odds by keeping runners out of each other's tasks; the
`atomic-claim` capability named in `CONTRACT.md` remains unimplemented.

New suite `tests/phase14-go-scope.test.mjs` (37 assertions) covers `expandScope` through the same
`<scheduler-pure>` extraction phase2 uses, and guards the wiring structurally. This feature breaks
silently in two ways, a planning site reverting to `tasks` or completion reverting to
`snap.counts`, and neither fails visibly at runtime.

## 3.2.2: the transition writer stops destroying the task it is moving

A `/go` run aborted at iteration 4 with two FATALs about missing metadata fields. The task file
behind them had been 17507 bytes and 219 lines one commit earlier. It was now **267 bytes and one
line**: a single transition-log row, the one that transition was itself writing.
`apply-transition.sh` committed the wreck twenty lines after producing it. Nothing warned and nothing
failed. The writer moved the file, staged it and committed it exactly as if the transition had
worked. The report came from a downstream project
(`docs/research/20260824-acf-whip-task-file-clobber.md`), and its diagnosis of the blast radius and
the manual repair was correct.

**`append_log_row` could write a file's replacement from a read that returned nothing.** It is a
read-modify-write: awk reads the task file, and the result replaces the original. Run it against a
file another process had momentarily emptied and awk emits *only* the new row, because it saw no
table and its terminal clause appends one. `[ -s "$tmp" ]` then passes, because a row is not empty.
The `else` fallback was no safer: `printf '%s\n' "$row" >> "$file"` **creates** the same corpse from
an empty or absent file. Both guards let the wreck through, and one of them manufactured it.

What was *not* wrong matters here, because the field report guessed and its guess implies a
different fix. A **table-less** input was always handled correctly. Every non-table line reaches an
unconditional `print`, so such a file is emitted in full with the row appended at EOF, which is the
documented legacy behavior, pinned by a test since 2.1.0. **Only a zero-byte read** produces a lone
row. Guarding against "no table" would have fixed nothing and broken a tested path.

Four changes make the function structurally unable to shrink a file:

- It **refuses** an absent, empty or whitespace-only target up front, and again inside awk
  (`END { if (NR == 0) exit 3 }`), so the gap between the two checks is closed instead of trusted.
- The write-back is an **atomic same-directory rename**, not `cat "$tmp" > "$file"`. That matters
  twice. `>` truncates in place, so the old code was *itself* a zero-byte window for every other
  reader: the doctor's field lookups, `scan-backlog.sh`, the reviewer's token grep. Every other
  task-file writer in the tree already used temp-plus-rename; this one function did not. The temp
  file has to be created beside the target, because on macOS `$TMPDIR` is a different filesystem from
  the repo, and `mv` across filesystems degrades to copy-and-truncate, which would reopen the window
  being closed.
- A **first-line comparison** runs before the rename. onetrueawk does not report a stdout write
  error, so a full disk could otherwise rename a half-written file over a good one.
- The EOF fallback now runs only against a file the refusal gate has already proved healthy.

It returns `0`, `3` (refused, file untouched) or `1` (environmental: file intact, row not written),
and never `2`, so a refusal cannot be misread as a usage error. All four call sites opt in
individually. A lost *log row* must not strand a state *move*, so the two shell callers warn, while
the two adapters fail.

**`apply-transition.sh` will not commit a corpse.** The truncation was the accident; committing it
was the defect. The writer ran `sed`, `append_log_row`, `mv`, `git add` and `git commit` with no
content assertion anywhere. `assert_task_intact` now brackets the mutations, once on entry and once
just before the move, and refuses with a new **exit 4**: the file stays where it is, nothing is
staged or committed, and the recovery command is printed. The two checks are kept apart on purpose.
Failing *on entry* means someone else broke the file. Failing *before the commit* means it broke under
this writer, which is a live concurrency fault worth chasing. The files adapter maps 4 to contract
exit 7 ("invalid state or value"), not contract 4, which means "conflict (duplicate key)" and would
send an operator hunting for a duplicate id that does not exist.

**`collapsed-task-file` is now its own FATAL.** The doctor reported the wreck as
`unparseable-frontmatter` plus `missing-worktree-slug`. That reads as *someone fat-fingered the
metadata* and sends you to re-type two fields, when the whole document is gone and is sitting one
commit back in git. The discriminator is unambiguous and costs nothing on the happy path, since it
runs only for a file that already failed the field lookup: no `#` heading, and every non-blank line a
table row. It is FATAL even in `accepted/`, skipping the usual rule that terminal tasks are only
advisory, because this is content loss, not a structural quirk. It is deliberately **not**
`--fix`-able, for the same reason as `control-bytes`: restoring from `HEAD` would silently discard
the clean-checkout token row, which is uncommitted by design, and `--fix` must never commit a torn
write as "healed".

**Also fixed: the LP-CAS integrator's root resync, two bugs in three lines.** `land()` advanced trunk
and then resynced `ROOT` with `git reset --hard "$TRUNK" >/dev/null 2>&1 || true`. Between those two
statements, and permanently whenever the resync failed (`git_with_lock_backoff` returns 99 under
lock contention, and `|| true` swallowed it), **ROOT's index held the old tree while HEAD pointed at
the new one**. Any `.backlog` commit landing in that gap is built from that index, which produces a
commit whose parent is the integration and whose tree is its predecessor: it silently reverts every
code change just landed. The index repair is now unconditional and its failure is fatal. Separately,
`reset --hard` rewrote `.backlog/` as well, discarding uncommitted task state at the root: the
clean-checkout token (which the files adapter calls uncommitted *by design*, and whose loss `/go`
already works around as a "mechanism" fault) and any operator repair made between runs. The worktree
half is now `checkout --no-overlay "$TRUNK" -- . ':(exclude).backlog'`, which is provably a no-op on
committed content. `strip_backlog_from_index` restores `.backlog` to `OBSERVED`, and the
compare-and-swap lands only if trunk is still exactly `OBSERVED`, so the two `.backlog` trees are
identical and excluding it can only spare uncommitted work. **Both `--no-overlay` and the order are
load-bearing.** Overlay mode, the default, never removes files, so an integration that deleted or
renamed a path would leave a resurrected copy on disk. It would go unnoticed, because `git status`
shows it as `??` and the `dirty-trunk-root` check skips `??`. And the checkout must run *before* the
index reset. Reset first, and the deleted path becomes untracked at that instant, after which
checkout can no longer remove it.

**Also fixed: `strip_backlog_from_index` leaked additions.** It ran
`git checkout <tree> -- .backlog` in overlay mode, so a candidate that *added* a `.backlog/X.md`
absent from the observed trunk survived the strip, was picked up by the following `git add -A`, and
rode into trunk. That is exactly the phantom the function exists to stop: deletions and
modifications were reverted, additions were not. A failed strip is no longer swallowed either; it
quarantines the candidate.

**Also fixed: the same clobber on the multica backend, with no concurrency required.**
`jq -r '.description // ""'` yields a zero-byte file for an issue with no description. The old
`append_log_row` wrote its row into that empty file, so the `[ -s "$desc" ]` guard below it *passed*
and the adapter replaced a live issue description with one log row. The new refusal closes this, and
the guard now does the job it was written for.

**Deliberately not done.** A real mutex shared by every `.backlog` writer. It is the only thing that
would close the remaining hole (below), and it is not obviously worth its cost. macOS ships neither
`flock(1)` nor `lockf(1)`, so it would mean a hand-rolled `mkdir` spinlock with stale-lock reaping
across agents that get killed mid-run. That adds a new way to wedge a system whose stated design is
that the lock is git itself. Also not done: `--fix` auto-repair of a collapsed file from git history,
for the reason given above.

**Still open.** A *partial* (non-empty) read is not covered. `- **ID**:` and `- **Status**:` sit in
the first few lines, so a file truncated in its tail passes both assertions having lost its body.
Concurrent writers still lose a *row* to last-rename-wins; neither destroys the file, and the multica
adapter has documented that parity since 3.2.0. And `evidenceSink` / `reviewSink` still instruct
agents to write the live task document; the two changes above make that non-destructive without
stopping it. What emptied the file in the original incident was never identified. There was no
`reset --hard`, no stash and no integration within minutes of it, so the remaining candidates are a
sibling `append_log_row`'s own truncation window and an agent's Write. That is why the fix does not
depend on the mechanism: it defends the read, not one particular racer.

`tests/phase11-checkout-reentrancy` has launched two concurrent `clean-checkout.sh` against the same
task file since 3.2.0 but asserted only their exit codes, so the suite ran the corruption scenario
and never looked at the file. It checks the file now. Regressions also cover the refusal paths, the
rename (by inode), the collapse discriminator against both a corpse and an ordinary field-less file,
`--fix` declining to heal it, temp-file invisibility to every `*.md` consumer, the multica empty
description, and an integration that deletes a file while `.backlog` is dirty. Suite: **754
assertions**, green on stock macOS bash 3.2 with BSD sed/awk.

## 3.2.1: the integration mode is a setting, and override mode survives a run

Override (PR) mode had been documented since 2.x, but almost nobody could reach it in practice.
Selecting it was an LLM judgement made per run from `CLAUDE.md`, and `skills/go/SKILL.md` said so
outright ("no plugin code special-cases the override"). The legacy loop's `ACFW_INTEGRATION_OVERRIDE`
switch was read in three places and **assigned nowhere in the tree**. For a team with a protected
trunk and review-gated merges, one misread of project instructions folded accepted work into trunk
past review. Reported by @golb, who found the read-with-no-writer by grepping the full tarball; the
pin below is their design.

**`ACFW_INTEGRATION_MODE` pins the mode.** It is an env var or a key in the committed config,
resolved exactly like `ACFW_STORE` (env > config > unpinned), and `acfw-store info` reports it as
`integrationMode`. Unpinned keeps the prose fallback, so existing projects behave the same as before.

Pinning it, though, only made a **broken** mode reliably reachable. Three defects meant override mode
had probably never completed a multi-task run:

- **The legacy loop still auto-integrated.** `ACFW_INTEGRATION_OVERRIDE` gated the terminal counts
  and the post-loop drain, but *not* Step 4.5, the pass that does the cherry-pick. Its skip was prose
  addressed to Claude. So a correctly pinned override run changed how tasks were counted and nothing
  about where the code went. The guard is executable now.
- **The run aborted on the first cross-slug dependency.** In override mode the scheduler deliberately
  dispatches a task whose cross-slug dependency is accepted but unintegrated (`depsSatisfied` blocks
  only in default mode). The doctor was mode-blind and called exactly that
  `FATAL|cross-slug-dep-not-integrated`, and a mid-run FATAL aborts before dispatch. Scheduler and
  doctor disagreed by construction, the same defect class the 3.0.1 `integGate` fix closed for
  default mode. Both doctors now take `--mode` (defaulting to the resolved pin) and relax the gate
  in lockstep.
- **`doctor --fix` deleted the branch you were going to PR from.** `accepted` was excluded from
  `LIVE_SLUGS`, so an accepted task's worktree counted as an orphan, and `--fix` ran
  `worktree remove --force` + `branch -D` on it, unpushed, at every `/go` bootstrap. That is harmless
  in default mode, where the change is already on trunk. In override mode it destroyed the only copy
  of the deliverable. It was also what "healed" the FATAL above. Accepted slugs now stay live while
  the operator owns integration.

An **unrecognized value is FATAL** (`acfw-store` exits 2 on every subcommand, not only `info`)
instead of degrading to unpinned with a warning. Degrading would flip delivery semantics anyway,
back to the model judgement the pin exists to replace, and the warning would land on a shell-runner
agent's stderr inside an unattended run where nobody reads it. This is not a corner case. The config
parser strips quotes and trailing whitespace but **not** a trailing comment, so
`ACFW_INTEGRATION_MODE=override # PR per group` was an unrecognized value that looked like a pin.

Also:

- The mode is exported through the adapter env contract and the workflow's agent `ENV` prefix, so
  every doctor, scan and integrate call resolves the same value the orchestrator is scheduling
  under. This is additive; `ACFW_CONTRACT_VERSION` stays `1`.
- `/whip-init` scaffolds the key, commented out, in both config homes.
- The pre-loop switch derivation moved after the detached-HEAD refusal and became `if/fi` instead of
  `[ ... ] && export`, which evaluates to exit 1 whenever the mode is not override.
- `content/backlog/README.sample.md` no longer tells projects that integration is
  "project-decided". That has been false since 3.0.0 and is the likeliest source of the original
  expectation.

**Deliberately not done:** pushing, `gh pr create`, PR-state-aware terminal checks, and reading
`PR Group` (still stored, still drives nothing). Override mode stops at accepted and gets out of the
way. Also unchanged: `.backlog/` state transitions are committed on the trunk branch in **both**
modes (`apply-transition.sh` refuses to run off trunk), so a files-backed run puts bookkeeping
commits on local trunk regardless of mode. The answer there is a non-files task store, where task
state lives outside git entirely.

`tests/phase13-integration-mode` covers the precedence chain, the FATAL classes including the
trailing-comment case, and a fixture-level regression for each of the three defects above (28
checks).

## 3.2.0: per-task authored child workflows (locked skeleton, open body)

Before 3.2.0, every dispatched unit, from a one-line config bump to a cross-cutting refactor, was
executed by **exactly one `agent()` call**. The orchestrator's loop was sound; the leaf was not.
There was no variation in model, effort, depth or fan-out, and `specialistPrompt` did not even inject
the task's description or acceptance criteria. It passed a file path and left a single agent to read
it.

Each unit now runs as **its own nested workflow**, whose harness a **workflow-architect** agent
authors for that specific task. `/go` calls `workflow({scriptPath})`, and the child's return value is
consumed exactly where a single specialist's return value used to be.

**Locked skeleton, open body.** A shipped, unit-tested skeleton (`skills/lib/child-skeleton.js.tmpl`)
owns everything that must not be authored away: the `meta` frame, the single `clean-checkout`, the
`runStage`/`runWave` primitives, the progress ledger, the budget guard, the fault typer, the commit
verifier, the review-panel arithmetic and the sole `return`. The architect fills exactly **four
marked regions**, and a shipped validator byte-diffs every locked segment before `/go` will run the
file.

Free-form generated harnesses were designed and rejected. Their own premortem was fatal. The
keystone defect *inverted* the durability requirement: two competing resume mechanisms cancelled
each other out, the script skipped a stage and returned `null`, and the first `null` dereference
made every resumed harness return `'none'` forever, an infinite task cycle with no counter to stop
it. Limiting the mutation surface to four regions cuts roughly fourteen classes of generated-code
throw to about one, which is what lets the repair loop converge.

**Durability across a throw** (the binding requirement). Each stage's own agent appends to a stage
ledger. It has to be the agent, because a workflow script has no filesystem, and that is why the
record survives both the script throwing and the architect's repair edit. When a child throws, a
scout reconciles that ledger against git, and the architect is re-invoked with the set of completed
stages. The amended run replays those stages in **zero agents**. Reconciliation trusts a
commit-bearing entry only when git confirms it with an `ACFW-Stage:` trailer, and every disagreement
resolves toward an **informed re-run**, never toward a skip: applying a stage twice is worse than
re-running one.

Convergence is **measured, not counted**: another amend round is granted only if the last one moved
the ledger or the branch, or changed the pre-flight error. `MAX_AMEND=2` is the ceiling, and it is
rarely reached.

**The default harness is deliberately shallow**: checkout, implement, a bounded gate loop,
adversarial diff review, verify. Those five stages hold the only three mechanisms a script
structurally buys over one strong agent: a schema-**observed** advance condition (one agent conflates
"I ran the gates" with "the gates passed"), a fresh-context reviewer of the diff, and a durable
ledger. The architect is told that keeping this shape and declaring `shallow: true` is a *correct*
answer, and `escalation.shallow` is reported so you can see whether it took that option.

**The worktree contract** is forced by the code, not chosen. `clean-checkout.sh` is not reentrant.
Its exit-2 mutual exclusion fires only when a worktree is *created*, so a second invocation against
a live worktree goes straight past it into `git stash push -u … || true` and silently sweeps a
sibling stage's in-flight work into the **shared** `refs/stash`. So there is exactly one
`clean-checkout` per (task, attempt), in the locked prologue, guarded by an **observation**
(`git worktree list --porcelain`) instead of a ledger record, because a lost ledger entry must never
be able to trigger a second stash. Only one agent may write the tree at a time, and "write" includes
running the build or test suite. `runWave` forces mutating stages to run one after another, so the
rule is structural and not a request in a prompt.

**Seams.** Implementation and LP-CAS conflict resolution escalate by default. Conflict resolution
fans out reads and fans in the write. Analysts are read-only and never `git add`, because staging
clears a path's unmerged state regardless of content, and the integrator's completion oracle is
exactly that state being empty. One stager then touches the enumerated paths. The resolver is
**not** escalated inside `priorIntegratePass`, which runs concurrently with the dispatch wave. The
**multi-lens review panel ships off** (`args.escalateReview`). It is the only *subtractive* seam,
and it runs against a hard 3-rejection terminal. When it is on, aggregation is a strict majority with
**no veto**, and `rejectionIncrement` is clamped so a panel of any size costs at most one life per
round.

**Survivability.** The runtime caps total agents per run and children share the counter, so the
parent keeps its own ledger and degrades FULL → LEAN → DIRECT → CLOSE. CLOSE trims new dispatch
*before* the pre-move (a task moved to in-progress and then abandoned would sit there until the 8h
sweep) and **breaks** instead of returning, so Drain and the unlock still run and the report is
clean. The dispatch wave is chunked and wrapped in try. A cap exception is thrown at the top of
`parallel()` itself, and uncaught it would escape the loop and the script: no report, no unlock, and
the lock held for 30 minutes. `LANES = max(2, POOL-2)` is safe under both readings of whether a
parent thunk awaiting `workflow()` holds a concurrency slot. `floor(POOL/2)` was rejected because on
4 cores it serializes the whole backlog. **D2 is honoured as policy, not guaranteed as outcome**:
above roughly 80 tasks the tail of a run executes as plain 3.1.0, and the report says so.

**`/task`** gets recon (existing ids, *slugs already in use*, the real code surface, and the bodies
of the agent definitions), two competing planners and a judge, and an advisory completeness critic.
It gets **no architect and no child workflow**: its pipeline is the same on every invocation, so
there is no shape to discover, and its per-unit authoring fan-out already existed.

**Also fixed** (independent of the feature, and landed first):
- **Run-killer:** an unguarded `await priorIntegratePass`. `integrateOne` dispatched the conflict
  resolver through a bare `agent()`, and `serializeIntegrate` returns the un-swallowed promise, so a
  resolver non-emit propagated out of the loop *and the script*: no report, no unlock, lock held.
- **Livelock:** a reviewer that rejected without setting `rejectionIncrement` wrote `inc:0`, so
  Rejection Count never advanced and the task cycled forever, caught only by the loose
  `NO_GAIN_LIMIT`. `inc` is now derived from the transition, and `ACFW_RESULT` gains an optional
  `faultClass: quality|mechanism`, so "reject, and this is not the task's fault" can still be said.
  This carries the mechanism-vs-quality budget split that 3.0.0 set up for the integrator over to
  review.
- A deterministic, typed clean-checkout auto-reject on the parent side. A missing token with the
  branch present means the token was lost, not the work (mechanism, retried); no branch at all is a
  real reject.
- `whip-init` gitignores `.acfwhip/run/` and `.acfwhip/specs/` unconditionally. **Never gitignore
  `.acfwhip/` wholesale**: `.acfwhip/config` is committed and its values overwrite inherited env.
- `task-template.md` said Rejection Count max 5 while the cap has been 3.

**Adapters, `CONTRACT.md`, `scan-backlog.sh` and the task template are unchanged.** No new scanned
field was needed, which is the payoff of gating on budget instead of on complexity.

New: `skills/lib/child-skeleton.js.tmpl`, `skills/lib/bin/acfw-child-{scaffold,validate,ledger}`,
`acfw-child-validate.mjs`, and five test files. Suite: **645 assertions**, green on stock macOS bash
3.2 with BSD sed/awk, plus `tests/run-all.sh`, so a new suite cannot silently stop being run.

Kill switch: `args.escalate: false` reverts to byte-identical 3.1.0 dispatch.

**Runtime facts verified against a live nested run** (recorded so the next author does not have to
re-derive them):

| Question | Answer |
|---|---|
| Does `workflow({scriptPath}, args)` run a child? | Yes. |
| Can the child dispatch its own agents? | Yes. |
| Does the second argument arrive as a real **object**? | Yes: `args.foo` is readable in the child. The skeleton's whole `const A = args \|\| {}` unpacking depends on this. |
| Does the child's return value reach the parent? | Yes, verbatim. |
| Do the child's agents count against the **parent's** run? | Yes: the parent run reported the child's agent count as its own. The CAP_RESERVE ladder rests on exactly this. |
| Message when the path is unreadable | `Workflow script file not found: <path>`. It deliberately does not match the kill-switch pattern, so it becomes one repairable amend round instead of disabling escalation for the whole run. |
| Message when the ref is malformed | `workflow() expects a workflow name (string) or {scriptPath: string}`. Also not a kill-switch match. |

Still **unverified, and deliberately not depended on**: whether a parent thunk awaiting `workflow()`
holds a concurrency slot. `LANES = max(2, POOL-2)` is correct under both readings, so the open
question affects throughput, not correctness. Do not probe it from inside `/go`: under the
pessimistic reading, the probe *is* the deadlock. Runtime resume across the nesting boundary is
likewise unused. The stage ledger is the durability mechanism, and if resume does reach into
children, the only effect is that some replays come from the journal instead of
`args.priorStages`, with the same values, strictly faster.

### multica: the audit trail moves out of the comment thread and into the task document

`acfw-store-multica` posted every state change as an issue comment
(`whip-transition | ts | from | to | agent | notes`), and the `clean-checkout` token with it. On this
backend that is the wrong surface. **A comment thread is a live agent channel**: an assigned agent
reads it, and comment activity triggers comment-scoped tasks. Orchestrator bookkeeping was landing
inside a conversation an agent is expected to act on.

Transitions and `log-event` rows now splice into the stored document's `## Transition Log` table
through the *shared* `append_log_row`, in the files-adapter row shape. A multica-backed task
document reads exactly like a files-backed one, and gets that helper's cap and never-drop-a-row
fallback without extra code. The `comment` subcommand still writes a real comment, and real comments
are now all the thread holds.

Three things get simpler as a result. `snapshot.hasCleanCheckoutToken` no longer pays for a
`comment list --full` per in-review task: it reads the description `issue list` already returned,
then `issue get`, then the comment scan. `read --materialize` no longer synthesizes an audit
section, and renders real comments under `## Store Comments`. And the stored `description` no
longer carries an empty Transition Log table forever.

- **Upgrading mid-flight is safe.** The comment scan survives as the token scan's last step, and
  `--materialize` still renders comments, so a task that entered review *before* this change keeps
  resolving instead of being auto-rejected.
- **`NOTES` is escaped** (newlines and tabs become spaces, `|` becomes `\|`) before it enters the
  table. This backend re-reads its own rows, so a newline would corrupt the splice and a bare pipe
  would add phantom columns. `apply-transition.sh` escapes neither and has the same latent hazard;
  the fix is worth backporting.
- **Failure handling is asymmetric by design.** `transition` writes its row last and best-effort
  (the `whip_state` write is the commit point, and a lost row must not report a completed move as
  failed), but it now WARNs instead of swallowing the error. `log-event` stays strict.
- `beads` and `linear` are **unchanged** and keep the comment behavior. `CONTRACT.md` now states the
  audit-row location as a per-adapter choice instead of implying one rule.
- New offline gate `tests/phase12-multica-transition-log.test.sh` (33 assertions) drives the adapter
  through a fake `multica` CLI it builds itself, and the same fake runs the frozen 36-assertion
  store-conformance suite green. `tests/run-all.sh` also gained a `bash -n` static gate over every
  adapter. The adapters had been outside every gate, so a syntax error in one stayed invisible until
  a run hit that backend.

## 3.1.1: the beads adapter uses Dolt, the engine `bd` ships

- **`ACFW_STORE=beads` could not initialize at all.** The adapter ran `bd init --backend=sqlite`,
  and **every released `bd` rejects that flag**: v1.0.4 errors after a deprecation notice, and v1.1.0
  returns `--backend=sqlite is no longer supported`. Beads removed the SQLite backend in v0.58.0 and
  has defaulted to **Dolt** since v0.50.0; SQLite exists again only on unreleased `main`. The adapter
  now passes `--backend=dolt`, the one value v1.0.4, v1.1.0 and `main` all accept, so task state
  lives in an embedded Dolt database under `.beads/`. No migration is possible or needed, because a
  sqlite-backed store created by this adapter never existed.
- **`bd init`'s side effects on the repo are now suppressed, and one of them was a run-killer.**
  init passes `--skip-hooks --skip-agents --non-interactive`. Without `--skip-hooks`, bd installs
  hooks into `.beads/hooks/` and sets a repo-wide `core.hooksPath`, which lives in `.git/config` and
  is therefore **shared by every git worktree**. Every commit whip makes (specialists,
  `apply-transition.sh`, `integrate-lpcas.sh`, `whip-move.sh`) would spawn a `bd` hook contending
  for the same single-writer Dolt lock, and the hook can stage `.beads/issues.jsonl` into a pending
  commit, which makes LP-CAS candidates depend on the environment instead of the branch tree.
  `--skip-agents` stops bd writing `AGENTS.md`/`CLAUDE.md`/`.claude/settings.json` into the host
  repo.
- **`init` refuses a dirty index (exit 8).** `bd init` ends in a bare `git commit --no-verify` with
  no pathspec, so it commits the *whole* index, and anything staged would be swept into a
  `bd init:` commit. A non-cgo `bd` now also fails with a typed exit 5 that names the build fix,
  instead of a raw engine error.
- **Lock matcher widened to Dolt's vocabulary.** Retries now key on `locked by another dolt process`,
  `noms lock`, `lock file`, `deadlock found` and `lock wait timeout exceeded`, alongside
  `database is locked`. Dolt's server-mode string is
  `database "<name>" is locked by another dolt process`, with the database name mid-string, so the
  old substring test missed it.
- **The contract's concurrency note was wrong, and is corrected.** `adapters/CONTRACT.md` told
  adapter authors they see a "single sequential writer". Only *transitions* are serialized: `/go`
  dispatches specialists with `parallel()`, and each one independently runs `read --materialize` and
  `log-event`. Adapters must be concurrency-safe on those verbs and **must never block
  indefinitely**; they exit 99 instead. The gloss for exit 99 now covers "timed out waiting for the
  backend".
- **Known limitation, documented and not fixed:** embedded Dolt is single-writer by file lock, and
  `bd` waits for it with unbounded backoff against a context with no timeout, so a contended `bd`
  process *hangs* instead of erroring. The retry cannot fire, and `clean-checkout.sh`'s `|| WARN`
  catches a non-zero exit but not a hang. Recovery and the planned fix (an adapter-side wall clock →
  exit 99) are written up in `adapters/beads/README.md`.
- **The version floor is now stated correctly: the beads adapter needs a `bd` built from beads
  `main`.** The reason is not Dolt. `bd create --status` landed on 2026-07-05 and is in no release.
  Documented in `adapters/beads/README.md`.
- Regression tests: `tests/phase9-adapter-beads.test.sh` **had been skipping unconditionally**. Its
  capability probe required the same `--backend=sqlite` that no released `bd` has, and its build
  recipe was `CGO_ENABLED=0`, which produces a binary that cannot open embedded Dolt at all. Both are
  fixed, the hardcoded personal `BEADS_SRC` path is gone, and six assertions are added (backend is
  dolt, no `*.db`, `core.hooksPath` unset, no `.beads/hooks/`, no agent files, dirty-index refusal).
  Now green: 36 conformance + 12 beads-specific.

## 3.1.0: pluggable task stores (files / beads / multica / linear behind an executable adapter contract)

`.backlog/` is now one task-store backend among several. Task state goes through a dispatcher
(`skills/lib/bin/acfw-store`) and an **executable adapter contract** (`adapters/CONTRACT.md`,
contract v1, modelled on git remote helpers: one executable per backend, JSON I/O, typed exit codes,
capability flags). There is no migration: `files` stays the default, and an existing `.backlog/`
project resolves and behaves exactly as on 3.0.1 with no action.

- **Contract v1 + dispatcher.** Required subcommands: `capabilities`, `snapshot`, `read`, `create`,
  `transition` (plus optional `init`, `update-field`, `update-body`, `log-event`, `comment`,
  `doctor`, `sync`). The dispatcher resolves the backend (`ACFW_STORE` env → config → `files`) and
  discovers the adapter (`$ACFW_STORE_ADAPTER_PATH` → project-local `.acfwhip/adapters/` → shipped
  `adapters/<backend>/` → `$PATH`), so a third party adds a backend by committing one executable,
  with no fork. It also makes up for missing capabilities. Raw snapshots are enriched with the git
  facts (LP-CAS ledger oracle, worktree branches, terminal-count model; see
  `acfw-enrich-snapshot.sh`). The dispatcher commits `--stage` deliverables to trunk when the
  adapter cannot co-commit them. Non-files doctors merge store-native findings with the generic
  graph/git battery (`acfw-doctor-generic.sh`).
- **files adapter** (`adapters/files/`): a thin shim over the unmoved 3.0.x engines
  (`scan-backlog.sh`, `apply-transition.sh`, `doctor.sh`). Behavior is byte-identical, and all three
  can still be invoked directly.
- **beads adapter** (`adapters/beads/`): whip states as `bd` custom statuses, deterministic
  `whip-<stem>` ids (stable as LP-CAS keys), native dependency edges (cycle-checked), `whip_*`
  metadata for slugs and counters, one-call snapshots via `bd export`, audit rows and clean-checkout
  tokens as comments. sqlite backend; single-writer discipline documented.
- **multica adapter** (`adapters/multica/`): canonical state in `whip_state` metadata, with the
  native status as a doctor-repairable display projection; server-side `whip_key` resolution; deps
  in `whip_deps` (multica has no dependency API, and whip's scheduler computes readiness, as it
  always did); paginated snapshots; comments as the durable audit trail; a crash-safe create that
  writes `whip_key` last.
- **linear adapter** (`adapters/linear/`): Linear has no custom fields, so canonical whip state lives
  in the official integration-state mechanism, one **attachment** per issue. Its `metadata` holds the
  `whip_*` keys, and its deterministic URL (`https://acfw.fib7.ai/<namespace>/<stem>`) is both the
  idempotent write key and the exact `attachmentsForURL` lookup handle. Native status is a lossy
  per-team projection by workflow-state *type* (doctor-repairable). The task document is the issue
  description, comments are the audit trail, and deps ride `whip_deps`, with native `blocks`
  relations as best-effort mirrors. The adapter speaks GraphQL directly (curl + jq, injectable
  transport, no third-party CLI) and needs `LINEAR_API_KEY` + `ACFW_LINEAR_TEAM`.
- **`adapters/README.md`** documents the store layer end to end: architecture, dispatcher mechanics
  (resolution, discovery, env, exit codes), the capability-compensation table, data-flow
  walkthroughs (snapshot/transition/materialize), a guide to writing your own adapter, and a backend
  comparison table.
- **Workflows are store-parametric.** `whip-go`/`whip-task` take a `store` arg (from
  `acfw-store info` at launch). Every writer action is now **stem-keyed**: the adapter resolves the
  task's current state, which holds up better on resume than folder paths. On non-files stores,
  dispatched agents read a spec **materialized** from the store (`read --materialize` →
  `.acfwhip/specs/`), evidence and review comments flow back via `acfw-store comment`, the
  clean-checkout token is recorded via `log-event`, and `/task` authors into `.acfwhip/staging/`
  before the single writer ingests via `create`. Prompts and commands on the files path are
  byte-identical to 3.0.1.
- **Config gets a backend-neutral home**: `.acfwhip/config`, which is read first and wins over the
  legacy `.backlog/.acfw-config` (the legacy file keeps working untouched). The run lock moves to
  `.acfwhip/run/acfw-run.json` on non-files stores. `whip-init` gains a task-store selection, and
  `whip-move`, `whip-doctor`, `retro`, `research` and the SessionStart hook are store-aware. The
  **LP-CAS ledger stays git-native on every backend**: integration truth never moves into a store.
- The legacy (non-workflow) `/go` markdown loop is declared **files-only**.
- Regression tests: new `phase9-store-conformance.test.sh`, the executable contract spec (36
  assertions, run against every adapter). The beads wrapper builds and uses a real `bd`, the multica
  wrapper is skip-guarded on `MULTICA_TEST_SERVER`, and the linear wrapper runs the full conformance
  suite offline against a GraphQL emulator pinned to doc-verified API semantics, with a live path
  skip-guarded on `LINEAR_TEST_API_KEY`. New `phase9-dispatcher.test.sh` (37 assertions: resolution
  precedence, discovery order, enrichment against a seeded ledger marker, stage compensation, doctor
  merge). Phases 0–8 pass unchanged.

## 3.0.1: field-inventory residue (oracle agreement, deliverable durability, run lock)

A field inventory of 31 defects, taken across ~890 tasks and 195 runs (2.0.3 → 3.0.0). LP-CAS had already removed most of them by construction: whole-branch rebase, the cached snapshot ref, poison quarantine on a stale base, re-rejecting landed work, branch-ref resets, `Integrated-At` drift, duplicate-id aborts, re-dispatch livelock, uncaught schema errors, unsafe resume, final-iteration unblock, EOF transition-log growth, non-atomic Status+move, doctor scan cost, and worktrees for non-code tasks. What follows is the residue, plus one live run-killer the inventory implied but had not isolated.

- **Oracle agreement inside the doctor (run-killer, found while verifying this release).** `whip-doctor`'s `cross-slug-dep-not-integrated` gate read the **inert** `Integrated-At` field, while the scheduler reads the ledger. A dependency whose change was on trunk (marker present) but whose `worktree/<slug>` branch had not been reaped yet (nothing reaps it until a later `--fix`) therefore read as "not integrated". `/go` dispatched the dependent, because the marker said it was satisfied, and the next per-iteration `doctor --quiet --active-only` recheck FATAL'd on it and **aborted the whole run**. Both the full and the `--active-only` passes now fold ledger truth into the column the gate reads. The gate still fires when the dependency has not landed.
- **`Worktree: none` deliverables can no longer be lost (P0).** A non-code task writes standalone files (e.g. `docs/research/*.md`) into the shared root and may not commit them. Nothing ever staged those paths, so the next checkout or stash destroyed them. The direct agent now reports `deliverableFiles`, and `apply-transition.sh --stage <path>` (repeatable) stages them **by explicit path in the same commit as the state move**. State namespaces (`.backlog/`, `.acfwhip/`), absolute paths and `..` are refused before any mutation. A missing path is skipped and never strands the transition, and a crash between `mv` and `commit` is repaired on the idempotent re-apply. The reviewer rejects an uncommitted deliverable.
- **Run lock (WHIP-15).** `/go` refuses to start while `.backlog/.acfw-run.json` is fresher than 30 minutes, because two concurrent runs had collided on slugs and on the shared root index. Freshness is the existing heartbeat's **mtime**: no PID, no daemon, no new file. The writer touches it each batch, a clean finish removes it, and after a crash it expires on its own. Override: `rm .backlog/.acfw-run.json`.
- **A dirty orphan worktree is never force-removed (WHIP-26).** The `--fix` reaper checked only that a slug had no live task, then ran `git worktree remove --force`, discarding modified *and* untracked files (thousands of cassettes, a unique findings doc, an `.env`). Dirty orphans now emit `WARN|orphaned-worktree-dirty` and are left for a human; clean ones are still reaped.
- **`--add-dep` writes the format the parsers read (WHIP-19).** `whip-move --add-dep` wrote JSON-style `[a, b]`. `doctor`, `scan-backlog` and `/task` all split on commas without stripping brackets, so both ids resolved to nothing → false `FATAL|dangling-dep` → `/go` blocked. It now writes a bare comma list, and `doctor --fix` repairs already-damaged backlogs (`REPAIRABLE|bracketed-deps`) in the bootstrap pass.
- **A NUL byte is one clear FATAL, not a cascade (WHIP-22).** `grep` treats a task file containing a NUL as binary, so every field lookup silently returned nothing, and a well-formed task reported `unparseable-frontmatter` **and** `missing-worktree-slug`, aborting runs. `FATAL|control-bytes` now names the byte count and the strip recipe, and the file is skipped instead of mis-parsed. Deliberately **not** `--fix`-able: a NUL usually marks a torn write, and the bootstrap `--fix` must never commit a half-written task as healed. Scoped to NUL: ESC and formfeed pasted from terminal output parse fine and are not flagged.
- **Dependencies are stamped from the validated plan (WHIP-18).** `/task` validated the dependency graph in JS, then had an author agent transcribe the `Dependencies` line into markdown, where it could be lost without any error. A whole decomposition once came out as `Dependencies: none`, and `/go` dispatched downstream tasks before their upstreams landed. The single committer now overwrites that line from the validated plan before `git add`.
- **Three advisories that make silent losses visible.** `accepted-branchless-unverified`: an accepted code task with no branch and no ledger marker is still counted terminal (a FATAL would deadlock every pre-ledger backlog), but it is now surfaced with its ack (`whip-move <stem> accepted --integrated-at <sha>`). This is the mode that shipped an accepted billing engine that was absent from trunk. `dirty-trunk-root`: tracked files dirty at the shared root outside `.backlog/`, which the next integration resync discards. `trunk-unpushed`: local trunk ahead of `origin/<trunk>`. LP-CAS lands **locally and never pushes**, by design: a push per landing would need credentials in every agent env, fire CI per task, and drag network faults into the integrator's exit taxonomy. No network access: the check reads the local remote-tracking ref only.
- **Docs.** `skills/go/SKILL.md`'s bash fallback still invoked the **deleted** `integrate-worktree.sh`, a `rebase --continue` resolver flow, and completion math that grepped `Integrated-At`. It is rewritten to the LP-CAS two-call protocol with the exact exit map. The new `content/backlog/recovery-runbook.md` (shipped by `/whip-init` as `docs/acf/backlog/recovery-runbook.md`) maps every doctor finding and integrator exit code to a recovery, and documents crash recovery (re-running `/go` *is* the resume), the run lock, and parking a task via `draft/`. Standalone `hydrate-worktree.sh` use is documented. The task-authoring style now requires acceptance criteria that can be verified inside the worktree/gate environment; validation against a live environment belongs in a separate deploy-gated task.
- **Deliberately not done:** per-iteration checkpoint journaling (every transition and landing is already a commit; re-running `/go` is the resume), a `resumeFromRunId` guard (the concept does not exist here), a `Human-Gated` field (`draft/` already is the human gate), a landed/unimplemented classifier (the marker oracle made it `git cat-file -e`), and pushing to origin.
- Regression tests: +50 assertions across `phase1` (control-bytes, bracket heal, dirty-orphan skip, oracle agreement on both doctor paths, the advisory trio), `phase3` (`--stage` atomicity, refusals, missing-path skip, crash rescue) and `phase4` (bare-comma deps). Full suite: 205 assertions, all green on stock macOS bash 3.2 / BSD sed+awk+find.

## 3.0.0: LP-CAS integration engine (Ledger-In-Tree Compare-And-Swap)

Driving `/go` against a long-lived, high-churn trunk (~658 tasks) produced runs that never converged (aborted or no-progress, ~0 net integrated). A field report traced 18 failure classes in the 2.5.0 code to their root causes. The keystone was `refs/acfw/trunk-snapshot`, a **cached base ref** refreshed by a non-force fetch whose exit status was discarded. Once trunk history is rewritten, that fetch becomes non-fast-forward, git silently refuses it, and every worktree rebased or reset onto a frozen base (observed 1292 commits stale). That one defect cascaded into false dep-blocks, phantom-conflict reject-loops, re-queuing of integrated work, branch resurrection, and the one-layer-per-run stall. Three further classes survived the 2.5.0 patch: a `.backlog` bookkeeping commit stamped as the integration point (#16), parallel same-file tasks silently losing the second write (#17), and a botched conflict resolution masquerading as a coverage regression (#18).

Instead of patching the model again, 3.0.0 **re-architects integration so the faults cannot arise by construction**. A 5-persona / 2-round / 3-model advisory board arrived at this design almost unanimously.

**The one invariant.** A task `K` is integrated **iff** `git cat-file -e <live-trunk-tip>:.acfwhip/integrated/<shard>/<K>.json` succeeds. Integration truth is a fact about git (an in-tree ledger marker), never a markdown field, folder location, or commit trailer. `Integrated-At` is now **inert** (kept for display; nothing reads it).

- **No cached base ref (keystone; #1/#9/#10 gone).** `refs/acfw/trunk-snapshot` and the entire rebase-into-snapshot re-align pass are deleted. `clean-checkout` forks a worktree from the **live** trunk and only records a fork-base ref; it never rebases or resets the branch. There is no snapshot to go stale.
- **Single-parent candidate + cherry-pick, no rebase or replay (#3).** The integrator (`skills/integrate-lpcas/`) publishes the task's change as one single-parent commit at `refs/acfw/patch/<key>` (tree = branch tip, parent = fork-base) and applies it onto the live trunk with `git cherry-pick --no-commit`. The base is the candidate's own parent, never a merge-base against trunk. A long-lived branch is never stale and never drags in a phantom range.
- **Marker co-committed with the change (#5/#7/#11/#16).** The change **and** its ledger marker enter trunk in the *same* single-parent commit, after the gate passes, landed by compare-and-swap (`update-ref <new> <observed>`). "Marker on trunk ⟺ change on trunk" is a structural identity: a bookkeeping commit can never be the integration point, and "done yet absent from trunk" cannot be constructed.
- **Same-file parallelism is surfaced, never silently lost (#17).** A second task touching the same file is cherry-picked onto a live trunk that already contains the first. A clean 3-way merge lands gate-verified; textual overlap is a **mechanism conflict → resolver** (not a drop); a broken auto-merge **fails the union gate → quality reject**. Slug partitioning is relaxed accordingly.
- **Union gate + parse-sanity before landing (#8/#18).** The project gate (`ACFW_GATE_CMD` in `.acfw-config`) runs on the candidate tree via direct exec with `pipefail` (no masked pipes). A cheap parse/lint check (`ACFW_PARSE_SANITY_CMD`) runs first, so a botched conflict resolution surfaces as `resolution-syntax-broken` (**mechanism**, re-resolve) instead of masquerading as a coverage regression.
- **Typed faults (#6/#13).** A poison or malformed candidate quarantines **that id only**, and the run continues; a duplicate id no longer aborts all 600+ tasks. A mechanism fault (conflict, cas-loss, fetch) gets a bounded retry and is never a quality reject. A quality fault (gate) means reject or redesign. Mechanism and quality consume separate budgets.
- **Git is the only oracle (scanner + doctor).** `scan-backlog` derives integration state from the ledger (`acfw_integrated_keys`), not from `Integrated-At` or the folder. `whip-doctor` drops the metadata-vs-git reconciliation invariants, including the "clear stray Integrated-At" repair that itself re-armed integration (#5), so by construction it can no longer touch integration state. It also downgrades `duplicate-id` from a run-aborting FATAL to an advisory quarantine.
- **Retired:** `skills/integrate-worktree/` (the rebase-into-snapshot fold), `refs/acfw/trunk-snapshot`, `Integrated-At`-as-authority, and the doctor invariants that existed only to reconcile metadata against git.
- **Migration is by self-heal (no separate backfill step).** On the first 3.0 run, a legacy accepted task with a reaped branch is already terminal (nothing to integrate). One whose branch still exists re-folds idempotently: the code is already on trunk, so the cherry-pick is empty and only the marker lands. No accepted work is destroyed. The integrator never mutates the worktree branch, and CAS-land only ever advances trunk from the exact tip it observed.
- **Deferred to 3.1+:** micro-batch ledger train (gate-once + CAS-whole-chain + bisect-evict); bounded self-heal for external rewrite-away. 3.0 ships the simplest correct core (per-task gate, K=1).
- Regression tests: new `tests/phase8-lpcas-integrate.test.sh` (46 assertions: stale-base land, #16 marker co-commit, #17 same-file union + conflict, #18 parse-sanity, idempotency, poison, union gate, CAS); `tests/phase6-worktree-codeonly.test.sh` rewritten for the snapshot-free producer + end-to-end producer→integrator landing; `phase0`/`phase1`/`phase3` updated to the LP-CAS model; `integrate-worktree`'s `phase7` retired (superseded by phase8).

## 2.5.0: patch-id-aware integration (heals legacy branches, never destroys accepted work)

This release comes from a field report on driving `/go` against a long-lived `develop` repo (~640 accepted tasks, branches born before 2.4.1). The 2.4.1 code-only architecture only helps branches it created, so legacy `worktree/<slug>` branches (no fork-base ref) still fell back to a far-back merge-base and replayed ~1000 phantom commits, which produced the accepted→rejected reject-loop. Accepted but unintegrated work whose equivalent code was already on trunk never registered as terminal, which stalled `/go` on "needs operator". And a botched or aborted integration could destroy the branch's code, leaving it only in dangling commits.

- **Integration is now patch-id aware.** A shared primitive (`acfw_pending_code_commits`) lists a branch's real code commits that are not yet on trunk *by patch-id*, dropping `.backlog` phantoms and commits already applied. If the set is empty, the task is stamped `Integrated-At` and reaped with **no rebase and no conflict**. That cures the phantom-conflict reject-loop and the "done-modulo-integration" stall, and stops re-runs from re-rejecting work that is already integrated. Otherwise exactly those commits are replayed onto fresh trunk via cherry-pick (clean code-only branches fast-forward first), so a legacy branch with ~1000 phantom commits replays its one real commit.
- **Contaminated branches self-salvage in-path.** The exit-8 "contaminated → park for operator" path is retired. The patch-id replay rebuilds a `.backlog`-carrying branch as code-only (the phantom commits are dropped), folding the real code and stamping `Integrated-At` instead of dead-ending. `clean-checkout` heals the same legacy branches at task start (no more far-back merge-base fallback) and records a fork-base ref so they stay code-only from then on.
- **Integration never destroys accepted work.** Before any branch mutation the integrator records `refs/acfw/preintegrate/<slug>` (the pre-integration tip) and prints an `ACFW-INTEGRATE: recovery` line. A resolver failure restores the branch from it (exit 6, code survives) instead of leaving it in dangling commits. The conflict resolver now runs a cherry-pick (`--continue`/`--abort`) and is explicitly forbidden from `git reset`/`checkout`/`switch`, from deleting branches, and from moving HEAD off the branch.
- **RunReport reconciled against disk.** `integrated` / `rejectedAtIntegration` are re-derived from the final on-disk snapshot (folder + `Integrated-At`) and cross-referenced with what the run attempted. A post-resolver agent non-emit can no longer report `rejectedAtIntegration: []` while the folder says rejected, or list a rejected task under `integrated`.
- Regression tests: `tests/phase7-patchid-integration.test.sh` (short-circuit, legacy far-back reduction, backup-ref recovery), extended `tests/phase6-worktree-codeonly.test.sh` (in-path salvage + legacy clean-checkout heal) and `tests/phase2-scheduler.test.mjs` (`reconcileIntegrationTallies`). `tests/phase0-extraction.test.sh` updated to the cherry-pick resolver model.

## 2.4.1: worktree branches are code-only (fix integrate reject-loop)

- Fixes a `/go` reject-loop. Long-lived `worktree/<slug>` branches accumulated trunk `.backlog` task-transition commits (one field case: 367 commits ahead, 366 of them phantom). The whole-branch rebase at integrate time then produced phantom conflicts, cycling tasks accepted→rejected endlessly.
- A worktree branch is now **code-only by construction**. A per-slug fork-base ref (`refs/acfw/forkbase/<slug>`) records the trunk SHA the branch's code sits on. Both `clean-checkout` (re-sync) and `integrate-worktree` (pre-FF rebase) now replay only the branch's own commits via `git rebase --onto <trunk-snapshot> <base>`, instead of merging trunk's `.backlog` history in or rebasing the whole branch back.
- A pre-integrate guard refuses any branch carrying `.backlog/` commits (`git log <trunk>..<branch> -- .backlog/` non-empty) → exit 8 / `contaminated`. `/go` parks that task for an operator (manual recovery: cherry-pick the tip code commit onto trunk) instead of rejecting or re-running it.
- `apply-transition.sh` gains a defensive trunk-only assertion.
- Regression test: `tests/phase6-worktree-codeonly.test.sh`.

## 2.4.0: worktree ownership scoping + configurable namespace

- Fixes a field report that `/go`'s startup pruned unrelated worktrees. The bootstrap's `whip-doctor --fix` orphan reaper and the `worktree-wrong-branch` FATAL used to iterate over every directory under `.worktree/`, force-removing or FATAL-aborting on worktrees a user kept for parallel research or benchmarking.
- The doctor now manages **only** worktrees on acf-whip's own branch namespace (`<ACFW_BRANCH_PREFIX>/<slug>`, default `worktree/<slug>`). An ownership guard skips any directory that is on a foreign branch, detached (mid-rebase), or not a registered worktree: no FATAL, no removal.
- The worktree directory and branch prefix are configurable via `.backlog/.acfw-config` (`ACFW_WORKTREE_DIR` default `.worktree`, `ACFW_BRANCH_PREFIX` default `worktree`), resolved by a shared `acfw_load_namespace` in `skills/lib/acfw-git.sh` and threaded through `clean-checkout`/`integrate-worktree`/`doctor`/`scan-backlog`. The scan digest emits `branchPrefix`/`worktreeDir` so prompt text matches a custom prefix. Defaults preserve prior behavior byte for byte.
- `<repo-root>/.worktree/` (gitignored, ephemeral) is now a documented ACF organization convention (librarian `organization-template.md`).
- Regression test: `tests/phase1-doctor-hydrate.test.sh` (foreign-worktree-survives + custom-namespace round-trip).

## 2.3.0: orchestrator hardening

From a field bug report of two `/go` crashes, a livelock and a barrier stall:

- **Streaming lifecycle**: each dispatched unit runs its own specialist→review→integrate cycle instead of holding the wave at a per-iteration `parallel()` barrier. A fast task is reviewed, accepted and integrated while a multi-hour task in the same wave is still running. Explicit serialization (a write promise-chain and an integrate lock) keeps the single-writer and topological-integration invariants, and cross-slug dependents are gated at dispatch. `tests/phase5-streaming.test.mjs` proves it with a construction that deadlocks under the old barrier.
- A read-only scan that fails to emit `StructuredOutput` no longer aborts. It retries, falls back to a schema-less text scan (parsing the JSON the model printed), and if even that fails the loop degrades to a `scan-degraded` stop + drain off the last good snapshot, returning a clean report. A genuine mid-run integrity FATAL still aborts. Drain reuses the last good snapshot too (`tests/phase4-scan-degrade.test.mjs`).
- New **`/whip-move`** operator command wraps `apply-transition.sh` for validated manual close-out (move a task, set `Integrated-At`, add a dependency) with atomic `Status:` sync (`tests/phase4-whip-move.test.sh`).
- A specialist may report `blocked_reason: dependency-missing` + `needs_task`. The orchestrator then parks the task for an operator immediately, naming the task to create, instead of re-dispatching it up to the `Block-Count` cap. Unit-tested in `tests/phase2-scheduler.test.mjs`.
- Per-wave dispatch logging names what is in flight. The git-worktree branch registry remains the parallelism lock (one specialist per `Worktree:` slug).

## 2.2.0: per-ticket latency

On a 337-task backlog the per-iteration scan took ~48s (`scan-backlog.sh`) + ~22s (`whip-doctor`), plus a ~50KB / ~16,800-token verbatim Opus echo, ~99% of it terminal accepted files that never change. Three fixes:

- `scan-backlog.sh --digest` emits a small scheduling snapshot (counts + actionable tasks + accepted integration candidates + compact `satisfiedDeps`), classifying the accepted folder in one batched grep+awk pass (the per-file `field()` loop was ~240–600× slower). The scan drops to ~1.6s and the echo to <1KB. JS `indexTasks(tasks, satisfiedDeps)` synthesizes a terminal dep object, so the `isTerminal`/`depsSatisfied` bodies are unchanged.
- `whip-doctor --active-only` runs the full integrity pass over the active folders and feeds accepted tasks in as cheap batched stubs (advisory only, never a gate FATAL). The per-iteration recheck drops to ~0.1s with identical FATAL/ok output.
- Deterministic shell-runner agents (scan, single writer, integrate, bootstrap, drain) run on a fast model (`SHELL_MODEL`, overridable via `shellModel`), since they only run a script and copy stdout. Specialists, reviewers and conflict resolvers keep the session model.
- Net: per-iteration overhead fell from ~70s + a multi-minute echo to ~2–3s. Pure scheduling/terminal logic lives behind `// <scheduler-pure>` markers, unit-tested by `tests/phase2-scheduler.test.mjs`; the shell layer is tested by `tests/phase1-doctor-hydrate.test.sh` + `tests/phase3-reliability.test.sh`.

## 2.1.0: reliability hardening

From a multi-wave field retro where 2 of 4 runs crashed and one aborted at iteration 2:

- Every schema `agent()` call is wrapped in bounded retry + graceful degrade, so a single StructuredOutput non-emit no longer aborts a multi-hour run (the writer defers, integrate stays transient, the scan re-scans and then aborts cleanly).
- A durable per-task `Block-Count` breaks the specialist re-dispatch livelock. A task whose real blocker is unmodeled stops being re-queued after a cap (default 3) and surfaces as `needsOperator` instead of spinning.
- `apply-transition.sh` syncs `Status:` to the destination folder atomically with the move (the folder is the source of truth), so a stale Status can no longer self-inflict the `status-folder-mismatch` FATAL. The doctor now treats that mismatch as REPAIRABLE.
- Completion requires no queued unblock, so a cross-slug dep integrated in the final iteration never strands its blocked dependent. `integrate-worktree` treats an empty (no-commits-ahead) branch as terminal. Transition rows splice into the `## Transition Log` table and are capped (shared `append_log_row`).

## 2.0.3: state-machine parity

- The `/go` workflow performs the two transitions the workflow migration had dropped: the **blocked→pending** unblock when deps resolve (gated on rejection count, so max-rejection redesign blocks stay for a human) and the **in-progress→blocked** timeout past the operator threshold (`ACFW_INPROGRESS_TIMEOUT_HOURS`, default 8h, emitted by `scan-backlog.sh`). A backlog whose pending tasks are gated on blocked tasks now runs to completion instead of exiting `no-progress`.
- `/task` aborts up front when no specialist agents are installed.
- Retained accepted tasks that are dependency targets are emitted slim, and a single garbled snapshot echo triggers one re-scan before aborting.

## 2.0.2: scale fix

- The snapshot is a bounded working set: full task objects only for actionable tasks and their dependency targets, while terminal and historical accepted tasks collapse into aggregate `runtimeTerminalDefault`/`runtimeTerminalOverride` counts that drive completion. The per-iteration scan no longer balloons into a backlog-sized blob the workflow agent must echo, which had caused a multi-minute stall on a ~300-task backlog.
- The doctor's new `--quiet` mode bounds the gate report to FATAL + `BREAKDOWN` + `SUMMARY`.

## 2.0.1: self-healing

- Doctor severity is scoped to the dispatch path: accepted and historical tasks are advisory (WARN, never blocking), so a pre-2.0.0 backlog runs instead of aborting the gate.
- `/go` counts a branchless historical accepted task as terminal (derived at runtime via `hasWorktreeBranch`, with no file rewrites) and never re-integrates it (`integrate-worktree` exits 4 on a missing branch).
- Parallelization is the default at planning and execution: a distinct slug per independent surface (concurrent), a shared slug only on real file-surface overlap, and dependencies only where one task consumes another's output.
- `/whip-doctor` is the integrity battery (now emitting a grouped `BREAKDOWN` line) and runs as a startup and per-iteration gate. `scan-backlog.sh` emits the read-only snapshot the scheduler runs on (now including `hasWorktreeBranch`). `.worktreeinclude` hydrates git-ignored config into fresh worktrees.

---

`/task` and `/go` are **workflow-native**: they run as dynamic workflows (`workflows/whip-task.workflow.js`, `workflows/whip-go.workflow.js`) whose loop, slug partition, dependency gate and topological integration live in a deterministic script, so Claude's context stays flat across iterations. The legacy single-context loop is the automatic fallback when dynamic workflows are unavailable. Worktree slugs are enforced in three layers: schema-required at decomposition → JS validation gate (kebab-case, acyclic deps, unique ids) → at dispatch, the doctor self-heals a missing slug on an active task. See `content/backlog/workflow.md` for the state-machine spec.
