# Changelog — acf-whip

All notable changes to acf-whip. Format loosely follows Keep a Changelog.

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
