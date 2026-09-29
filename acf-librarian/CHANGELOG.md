# Changelog: acf-librarian

All notable changes to acf-librarian. Format loosely follows Keep a Changelog. Releases before 1.3.0
are recorded only in the git history.

## 1.3.0: convention documents that update themselves

- **Your convention documents now update themselves.** Before this release the SessionStart hook
  copied `docs/acf/organization.md` and `docs/acf/git/commit-conventions.md` into a project once and
  never touched them again. Every fix to the conventions stayed out of every existing project, and
  each session kept injecting the stale copy as mandatory rules. The hook now recognises an unedited
  copy by its content, checks it against `content/.digests.json` (the sha256 of every template
  version this plugin has shipped), and replaces it with the current template. This also works on
  copies made by earlier releases, which carry no marker. Each installed or refreshed copy now
  starts with a marker line, `<!-- acf-librarian-template: <template> sha256:<12 hex> -->`.
- **A copy you edited is never overwritten.** When the template changes, you get one line naming
  the file and the template to merge from, plus the marker line that silences the notice until the
  template changes again. A copy written by a newer acf-librarian is loaded as is, with one line
  telling you to update the plugin. A missing document is installed exactly as before. If it cannot
  be created, the session still gets the plugin template, under the old "Error initializing" status
  and with one line saying why.
- **The conventions cover acf-whip 3.5.0's cycle records.** `docs/cycles/<YYYYMMDD-slug>/` is a new
  naming class, Dated living records: the folder name is the ID, so never rename or move it. The
  files inside are updated in place until the cycle closes, and machine files are for tooling only.
  `docs/acf/lessons/` holds timeless one-rule lessons. Neither folder is required, so the audit never
  creates them in a project that does not use acf-whip.
- **The git conventions drop a stale section.** "Worktree-Aware Commits (acf-whip 1.2.0+)" described
  acf-whip internals that have since changed. It is replaced by one rule: `ACFW-*` trailers are
  load-bearing, so never strip, reword or squash them away.

### `/audit-acf-conventions` stops damaging files it does not own

- **Cycle folders are reported, never renamed.** Folders without an acf `Format` stamp in their
  `record.md` belong to another tool and are skipped.
- **Lessons are reported, never renamed.** A lesson's slug is its identity. A lesson the audit
  renamed came back under its old name on the next `/retro`, and the rule then existed in two files.
- **Some broken links are reported but never edited**: those in `docs/cycles/`,
  `docs/retrospectives/`, symlinked docs, and plugin-installed documents (`organization.md`,
  `commit-conventions.md`, acf-whip's `docs/acf/backlog/` and `docs/acf/style/`, and anything whose
  first line is a plugin marker). Editing a plan re-arms its approval. Editing a pristine installed
  document made it look customised, which turned off its template refresh for good.
- **The link check skips inline code spans.** It read the conventions document's own backticked
  examples as broken links on every fresh project, and `--fix` rewrote them into wrong examples.
- **The rename that strips `-vN` suffixes works on macOS.** BSD sed read `\+` as a literal plus, so
  those suffixes were never stripped there.

### If you customised a convention document

The hook leaves an edited copy alone and prints a one-line notice. Paste these into your copy, then
make its first line the marker the notice shows.

**`docs/acf/organization.md`**

In the `docs/` tree, under `acf/`, after the `git/` line:

```
│   ├── lessons/               # one-rule lessons from /retro (TIMELESS; if using acf-whip)
```

In the same tree, after the `architecture/` line:

```
├── cycles/                     # acf-whip cycle records (DATED, LIVING until closed; if using acf-whip)
```

Replace the `snapshots/planning/` line with:

```
    └── planning/              # Planning snapshots (acf-whip plans live in docs/cycles/)
```

Under Timeless Documents, replace the first Required Locations line with:

```
- `docs/acf/` (and subdirectories like `docs/acf/git/`, `docs/acf/lessons/`)
```

A new section, after Timeless Documents and before Exceptions:

```
### Dated Living Records (folder name is the ID)

**Format**: `YYYYMMDD-description/` folder holding fixed file names
- The folder name is the record's ID: NEVER rename or move it (tools find a record by its name and ignore a renamed one)
- Update the files inside in place until the record is closed, then leave them frozen
- Machine files are tooling-only: NEVER hand-edit them (in a cycle, `record.md` is written only by acf-whip)
- Not a temporal snapshot: no new file per update, no date on the files inside

**Location**: `docs/cycles/` (acf-whip creates it on first use; it is optional, so an audit never requires or creates it)

**Examples**:
- ✅ `docs/cycles/20260928-owner-seat-notice/plan.md` (you edit the plan)
- ✅ `docs/cycles/20260928-owner-seat-notice/record.md` (acf-whip writes the record)
- ❌ `docs/cycles/owner-seat-notice/` (missing date: acf-whip ignores the folder)
- ❌ renaming `20260928-owner-seat-notice/` to `20261001-owner-seat-notice/` (the name no longer matches the recorded ID, so acf-whip stops recognising the record)
```

At the end of Cross-Reference Requirements:

```
- Fix broken links under `docs/cycles/` and `docs/retrospectives/` by hand only: editing a cycle's `plan.md` re-arms its approval, and a retrospective is a frozen record
```

Optional, a correction: the worktree **Configurable** rule now names `.acfwhip/config` or the legacy
`.backlog/.acfw-config` as where `ACFW_WORKTREE_DIR` and `ACFW_BRANCH_PREFIX` live.

**`docs/acf/git/commit-conventions.md`**

Replace the whole "Worktree-Aware Commits (acf-whip 1.2.0+)" section with:

```
## Tool Trailers

`ACFW-*` trailers written by acf-whip are load-bearing: never strip, reword or squash them away (see docs/acf/backlog/workflow.md).
```
