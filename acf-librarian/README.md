# ACF Librarian Plugin

> **SHHH!** The librarian is watching. Everything must be in its proper place.

**ACF (Agentic Continuous Flow)** is software development where humans govern intelligent agent
swarms rather than write code directly. When agents write most of a project's files, the rules for
naming and placing those files have to be where the agents read them. The librarian puts them there.
At the start of every session it injects your project's naming, layout, documentation and commit
conventions into Claude's context.

There are no enforcement scripts, and nothing blocks a badly named file. Claude follows the
conventions because they are in front of it; `/audit-acf-conventions` finds the places it didn't.

---

## What It Does

1. **Installs the conventions.** When `docs/acf/organization.md` or
   `docs/acf/git/commit-conventions.md` is missing, the SessionStart hook creates it from the
   plugin's template. On later sessions it refreshes a copy you never edited to the current
   template. An edited copy is never overwritten; you get a one-line notice instead.
2. **Injects them into every session**, wrapped in instructions that tell Claude to follow them
   strictly.
3. **Sets rules for documentation.** The Documentation Writing Standards (section 10 of
   `docs/acf/organization.md`) keep code snippets to 2-3 lines, prefer tables to prose, ban
   marketing words, and set a 40-70% token-reduction target.
4. **Commits by the rules.** `/commit` groups changes into atomic conventional commits and stages
   each file by name, never with `git add -A` or `git add .`.
5. **Audits the project.** `/audit-acf-conventions` lists each violation with a suggested fix, and
   `--fix` applies the fixes it is allowed to make.

---

## Installation

### Install from this repository

```bash
# Clone acf-tools (if you haven't already)
git clone https://github.com/yourusername/acf-tools.git
cd /path/to/parent/directory  # Directory CONTAINING acf-tools

# Start Claude Code
claude
```

In Claude Code:
```shell
# Add marketplace
/plugin marketplace add ./acf-tools

# Install plugin
/plugin install acf-librarian@acf-tools

# Restart Claude Code if prompted
```

The plugin is enabled once it is installed; there is no separate `/plugin enable` step.

**On the first session** the SessionStart hook creates `docs/acf/organization.md` and
`docs/acf/git/commit-conventions.md` if they are missing, then injects both into the session
context.

**On later sessions** (1.3.0+), a copy you never edited is replaced with the current template when
the plugin ships a new one, so convention fixes reach existing projects. The hook recognises an
unedited copy by its content, which also covers copies made by releases before 1.3.0. Each
installed or refreshed copy starts with a marker line,
`<!-- acf-librarian-template: <template> sha256:<12 hex> -->`, naming the template it came from.

---

## Usage

### Daily Workflow

There is nothing to run. With the conventions in context, Claude should:
- name documents by class: temporal (`YYYYMMDD-description.md`) or timeless (`feature-name.md`)
- put scripts in a script directory, never the project root
- lay out `docs/` the way `docs/acf/organization.md` describes

### Check Compliance

Run the audit whenever you want a check:

```bash
/audit-acf-conventions
```

It lists each violation with a suggested fix. Fix them by hand, ask Claude, or run
`/audit-acf-conventions --fix`, then audit again until the report comes back clean.

**What `--fix` never touches** (1.3.0+). These are reported, never edited, renamed or moved:
- acf-whip cycle folders in `docs/cycles/` (the folder name is the cycle's ID). A folder without an
  acf `Format` stamp in its `record.md` belongs to another tool and is skipped
- lessons in `docs/acf/lessons/` (a lesson's slug is its identity: `/retro` updates it by name)
- broken links in `docs/cycles/`, `docs/retrospectives/`, symlinked docs, and plugin-installed
  documents: `organization.md`, `commit-conventions.md`, acf-whip's `docs/acf/backlog/` and
  `docs/acf/style/`, and any doc whose first line is a plugin marker. An audit edit to an installed
  document makes it look customised, which stops its template refresh for good

The link check skips inline code spans and fenced blocks: those are examples.

### Create Commits

`/commit` turns your uncommitted changes into convention-compliant commits:

```bash
/commit
```

It groups related changes into atomic commits, writes each message as `<type>(<scope>): <subject>`,
stages files by name (never `git add -A` or `git add .`), and never skips pre-commit hooks. It
reports tersely, such as "Done. Committed 3 files."

### Customize Conventions

Both documents are yours to change:
```bash
# Edit organization conventions
code docs/acf/organization.md

# Edit git commit conventions
code docs/acf/git/commit-conventions.md

# Or ask Claude to help
"Add a convention for test files in my conventions"
"Update git conventions to require issue numbers in commit messages"
```

Then reload the session:
```bash
/clear  # Reloads with your updated conventions
```

From then on, Claude works from your version.

The hook never overwrites an edited copy. When a later plugin release changes the template, each
session prints one line naming the file and the template to merge from, plus the marker line to
put first in your copy. Once your copy starts with that marker, the notice stops until the
template changes again. The CHANGELOG lists what each template change added, ready to paste.

---

## Customization Examples

Examples of edits to `docs/acf/organization.md`:

### Add Tech-Stack Rules

```markdown
## 10. Go-Specific Conventions

### Go Module Structure
- `cmd/` - Main applications
- `internal/` - Private application code
- `pkg/` - Public library code

### Go Naming
- Use snake_case for test files: `user_service_test.go`
- Use lowercase for package names: `userservice`
```

### Add Team-Specific Rules

```markdown
## 11. Team Conventions

### Branch Naming
- Feature: `feature/TICKET-123-description`
- Bug: `bug/TICKET-123-description`
- Hotfix: `hotfix/TICKET-123-description`

### PR Requirements
- All PRs must have `/audit-acf-conventions` passing
- All PRs must link to ticket
```

### Modify Temporal Categories

```markdown
## 2. Naming Conventions (MODIFIED)

### Temporal Documents (MUST have YYYYMMDD prefix)

**Required Locations**:
- docs/research/
- docs/retrospectives/
- docs/snapshots/implementation/
- docs/experiments/           # ← ADDED: Your custom category
- docs/analysis/              # ← ADDED: Your custom category
```

### Customize Git Conventions

Project-specific git rules go in `docs/acf/git/commit-conventions.md`:

````markdown
## Commit Message Format (MODIFIED)

```
<type>(<scope>): <subject> [TICKET-123]

[optional body]
```

**Types**: feat, fix, docs, style, refactor, perf, test, build, ci, chore

**Subject**: Imperative mood, no capitalization, no period, max 50 chars

**Ticket reference**: REQUIRED in all commits (format: [TICKET-123])

## Branch Naming Rules (ADDED)

- Feature: `feature/TICKET-123-description`
- Bug: `bug/TICKET-123-description`
- Hotfix: `hotfix/TICKET-123-description`
````

Reload after editing:
```bash
/clear  # Librarian reads updated conventions
```

---

## What the Conventions Cover

A summary of the default templates. The installed files are the reference.

### 1. Directory Structure
- Required top-level directories
- Required `docs/` subdirectories
- Required `.backlog/` subdirectories (if using ACF)

### 2. Naming Conventions
- **Temporal documents**: `YYYYMMDD-description.md` (research, retrospectives, snapshots)
- **Timeless documents**: `feature-name.md` (acf, patterns, architecture, etc.), including acf-whip's one-rule lessons in `docs/acf/lessons/`
- **Dated living records** (1.3.0+): a `YYYYMMDD-description/` folder whose name is its ID, such as an acf-whip cycle in `docs/cycles/`. Never rename or move it; the files inside are updated in place until the record closes, and machine files (a cycle's `record.md`) are for tooling only
- **Exceptions**: README.md, CLAUDE.md, LICENSE

`docs/cycles/` and `docs/acf/lessons/` belong to acf-whip. Neither is required, so the audit never
reports them missing and never creates them.

### 3. Script Organization
- Scripts go in `scripts/`, `ops/scripts/`, `tools/` or `plugins/*/scripts/`, never in the project
  root (`setup.py` and `manage.py` excepted)
- Names follow the `action-target.sh` format

### 4. Root Directory Rules
- Allowed: README, CLAUDE, LICENSE, package manifests, config files
- Forbidden: stray scripts, docs, log files, temporary files

### 5. Link Validation
- Internal links use relative paths and must resolve
- Broken links under `docs/cycles/` and `docs/retrospectives/` are fixed by hand only: editing a cycle's `plan.md` re-arms its approval, and a retrospective is a frozen record

### 6. Single Source of Truth
- Link to the authoritative source; never duplicate its content

### 7. Git Commit Conventions
- Format: `<type>(<scope>): <subject>`, with types feat, fix, docs, style, refactor, perf, test,
  build, ci, chore
- Subject: imperative mood, no capitalization, no period, 50 characters at most
- Stage files by name (`git add path/to/specific/file.ext`). Never `git add -A`, `git add .`,
  `git add --all` or `git commit -a`
- One task, one commit, made when the task is done; the project builds after every commit

### 8. Documentation Writing Standards

All documentation has to be token-efficient: 40-70% fewer tokens than a verbose draft, with no
information lost.

| Rule | What it asks for |
|------|------------------|
| Code snippets | No function or method implementations, no algorithm pseudocode, no config file contents over 3 lines. API signatures, type definitions and CLI commands are allowed, 2-3 lines at most |
| Examples | 1-2 representative lines plus "..." for a repeated pattern |
| Format | Tables over prose for comparisons and options (50-70% reduction); "A → B → C" instead of mermaid for a simple sequence; inline lists for enumerations ("**Tools**: Read, Write, Edit"); grouped prohibitions ("**FORBIDDEN**: Edit/Write, Bash, Tests") |
| Language | No "comprehensive", "robust", "seamless" or "elegant". Write testable statements, such as "Response time < 200ms" |
| Preservation | When compressing an existing document, keep every instruction, 1-2 examples per pattern, and all emphasis (CAPS, bold, !, emojis). Someone must still be able to do the task from the shorter version |

---

## Example: Librarian in Action

### Before

```
project/
├── migrate.sh                   # ❌ Script in root
├── notes.md                     # ❌ Doc in root
├── output.log                   # ❌ Log in root
└── docs/
    └── research/
        └── findings.md          # ❌ Missing YYYYMMDD prefix
```

### The Audit

```bash
/audit-acf-conventions

🚨 ACF Convention Audit Report

📚 The librarian has reviewed your project... and she has CONCERNS.

❌ migrate.sh (script in project root)
   📋 Move to: scripts/migrate.sh

❌ notes.md (documentation in root)
   📋 Move to: docs/development/notes.md

❌ output.log (log file in root)
   📋 Remove or move to: logs/output.log

❌ docs/research/findings.md (missing YYYYMMDD prefix)
   📋 Rename to: docs/research/20251107-findings.md

---

📊 Summary: 4 violations found

📚 Librarian's note: *adjusts glasses sternly* This is a LIBRARY, not a junk drawer!
```

### After Fixes

```
project/
├── docs/
│   ├── development/
│   │   └── notes.md             # ✅ Proper location
│   └── research/
│       └── 20251107-findings.md # ✅ Temporal naming
├── scripts/
│   └── migrate.sh               # ✅ Organized
└── logs/
    └── output.log               # ✅ Proper location
```

---

## The Librarian's Voice

The audit speaks as a stern librarian. She is strict about the rules and passive-aggressive about
violations (*adjusts glasses*, *sighs at your file naming*, *taps her pen at your verbose
documentation*). Underneath she is helpful: every complaint comes with the fix, and compliance
earns a reserved nod. The persona is only in the wording. The findings are file paths and fixes.

```
📚 SHHH! The librarian is watching...

📚 *Adjusts glasses disapprovingly at your file naming*

📚 Librarian's note: Scripts belong in scripts/.
   This is not amateur hour!

📚 Librarian's note: Temporal documents REQUIRE YYYYMMDD prefix.
   I'm not filing this under "whenever you felt like it."

📚 *Taps pen at your 50-line code example*
   Two lines. Not fifty. Show the pattern, not the implementation.

📚 Librarian's note: "Comprehensive" is banned. Be specific.
   "Response time < 200ms" - now THAT's proper documentation.

📚 *Sighs at your verbose prose*
   Tables over paragraphs. I don't have all day.

📚 *Nods approvingly* Adequate organization. Lean documentation.
   You may proceed.
```

She is modelled on every librarian who ever shushed you, or adjusted her glasses when you put a
book back on the wrong shelf.

---

## How It Works

### Architecture: Pure Context Injection

One SessionStart hook does the work; the two skills are commands you run. There are no enforcement
scripts and no file watchers.

```
Session Start
    ↓
SessionStart Hook Fires
    ↓
Check: docs/acf/organization.md exists?
├─ NO  → Create from template
├─ YES, unedited older template → refresh it to the current template
├─ YES, edited → keep it; one notice line until its first line carries the current
│                <!-- acf-librarian-template: ... --> marker
└─ YES, current → read it
    ↓
Check: docs/acf/git/commit-conventions.md exists?
├─ NO  → Create from template
├─ YES, unedited older template → refresh it to the current template
├─ YES, edited → keep it; one notice line until its first line carries the current
│                <!-- acf-librarian-template: ... --> marker
└─ YES, current → read it
    ↓
Wrap BOTH with STRICT compliance instructions
    ↓
Inject into Claude's session context
    ↓
Claude sees conventions as MANDATORY REQUIREMENTS
    ↓
Follows them automatically throughout session
```

**Key files:**

| File | Purpose |
|------|---------|
| `hooks/handlers/session-start.py` | Initialize, refresh & inject both convention sets |
| `content/organization-template.md` | Default ACF organization conventions |
| `content/git-commit-conventions-template.md` | Default git conventions |
| `content/.digests.json` | sha256 of every template version ever shipped (how the hook tells an unedited copy from an edited one) |
| `skills/lib/gen-digests.sh` | Regenerates the digest manifest at release |
| `tests/` | Offline suites: `template-refresh.test.sh`, `conventions.test.sh` |
| `skills/audit-acf-conventions/SKILL.md` | Compliance checker |
| `skills/commit/SKILL.md` | Conventional commit enforcer |
| `docs/acf/organization.md` | Your project's organization conventions (created by hook) |
| `docs/acf/git/commit-conventions.md` | Your project's git conventions (created by hook) |

### Design Choices

The hook wraps the conventions in instructions that call them mandatory, so Claude reads them as
requirements rather than background. They are still instructions, not a gate. Claude can miss one,
and the audit is how you find out. The 40-70% token reduction is a target Claude is told to meet,
not a guarantee.

The conventions are ordinary Markdown in your repository. You edit them directly, review changes
in pull requests, and git keeps the history.

### Implementation
- 14 files, two of them offline test suites
- No dependencies beyond Python stdlib (the tests and the digest generator need bash and git)
- SessionStart hook handles dual initialization and refresh (organization + git)
- Two slash commands: `/audit-acf-conventions` (report; `--fix` repairs what it may) and `/commit` (git workflow)

---

## Compared With Other Approaches

| Instead of | The difference |
|------------|----------------|
| Enforcement scripts | Scripts are code to maintain, and they can break a workflow. The librarian has no enforcement code; Claude applies the rules itself |
| Pre-commit hooks | A hook sees a violation at commit time, after the file exists. The librarian's rules are in context while Claude writes the file |
| Linters | Linters check code and are configured per tech stack. These conventions cover file names, folders and docs, and read the same in any stack |
| A conventions document on its own | Easy to forget. This one is injected at the start of every session |

The tradeoff: nothing here blocks a bad file name or a banned word.

---

## Integration with ACF Workflow

The librarian works on its own. acf-whip's `/go` does not run `/audit-acf-conventions` or `/commit`,
and neither plugin needs the other installed. The audit does know acf-whip's records: cycle folders
and lessons are report-only, and so are broken links in plugin-installed documents (see Check
Compliance above), so `--fix` leaves them alone.

To make the audit part of review, put it on your PR checklist:
```markdown
## PR Checklist
- [ ] Code review passed
- [ ] Tests passing
- [ ] `/audit-acf-conventions` clean ← The librarian approves
```

---

## Troubleshooting

### Conventions not loading?

```bash
# Verify plugin enabled
/plugin list

# Should show: acf-librarian (enabled)

# Reload session
/clear
```

### Conventions file missing?

The hook recreates a missing file whenever a session starts, `/clear` included. To check, and to
reset the plugin if the file stays missing:

```bash
# Check if files exist
ls docs/acf/organization.md
ls docs/acf/git/commit-conventions.md

# If missing, disable and re-enable plugin
/plugin disable acf-librarian
/plugin enable acf-librarian
```

### Claude not following conventions?

Claude can still miss a convention. Ask it to check:

```
"Check the ACF conventions in your context. Am I following them?"
```

Or run the audit:
```bash
/audit-acf-conventions  # The librarian will find any violations
```

### Custom conventions not applying?

After editing `docs/acf/organization.md` or `docs/acf/git/commit-conventions.md`:
```bash
/clear  # MUST reload session to inject updated conventions
```

---

## Contributing

Contributions to the default templates and the audit are welcome.

### Adding Convention Categories

1. Edit `content/organization-template.md`
2. Add a numbered section with its rules
3. Give examples (✅ good, ❌ bad)
4. Update `/audit-acf-conventions` if the rule needs a check
5. Run `bash skills/lib/gen-digests.sh`, then `bash tests/template-refresh.test.sh`, and commit
   `content/.digests.json` with the template. Without the regenerated manifest, every installed copy
   of the new template is treated as edited at the next template change, and never refreshes again
6. Add a CHANGELOG entry with the lines you added, ready to paste, for users whose copy is edited

### Improving Audit Logic

1. Edit `skills/audit-acf-conventions/SKILL.md`
2. Add the detection, with a fix for every finding
3. Run `bash tests/conventions.test.sh`: it extracts the marked blocks from SKILL.md and runs them
   against scratch repositories
4. Try the audit on a real project

### Librarian Personality

New librarian lines are welcome, as long as she stays disapproving.

---

## License

Copyright 2025-2026 Fibonacci Seven, LLC. Licensed under the Apache License, Version 2.0; see [LICENSE](LICENSE).
