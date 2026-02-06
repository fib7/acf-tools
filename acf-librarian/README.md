# ACF Librarian Plugin

> **SHHH!** The librarian is watching. Everything must be in its proper place.

**ACF (Agentic Continuous Flow)** is software development where humans govern intelligent agent swarms rather than write code directly. The Librarian enforces naming and organization conventions to maintain order in ACF projects. She watches with stern disapproval as you work, adjusting her glasses and pointing at poorly named files.

Nobody likes the hall monitor. Nobody enjoys the strict librarian. But your repository has never been more organized.

---

## What It Does

The ACF Librarian plugin:

1. **Auto-initializes conventions** - Creates `docs/acf/organization.md` AND `docs/acf/git/commit-conventions.md` with comprehensive ACF standards on first session
2. **Injects into context** - Every session loads your project's conventions with STRICT compliance instructions
3. **Enforces compliance** - Claude follows conventions automatically (the librarian is in his context)
4. **Enforces token efficiency** - 🚨 All documentation MUST follow token optimization patterns (40-70% reduction target)
5. **Enforces git discipline** - `/commit` command ensures conventional commits with explicit file staging
6. **Audits your project** - `/audit-acf-conventions` command scans for violations and provides fixes

**Key insight**: No enforcement scripts. Just conventions in context that Claude naturally follows. The librarian doesn't need to DO anything - her presence is enough.

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

**Note**: Plugin is automatically enabled after installation. No separate `/plugin enable` command needed.

**What happens on first session:**
1. SessionStart hook fires
2. Creates `docs/acf/organization.md` (if missing)
3. Creates `docs/acf/git/commit-conventions.md` (if missing)
4. Injects both convention documents into session context
5. Claude now follows ACF conventions automatically (organization + git)

---

## Usage

### Daily Workflow

You don't need to do anything special. The librarian is always watching.

**Claude will automatically:**
- Create files with correct naming (temporal vs timeless)
- Organize scripts in proper directories (never root)
- Structure documentation correctly
- Follow all conventions defined in `docs/acf/organization.md`

**The librarian is in the context.** Claude sees the conventions and follows them.

### Check Compliance

Run periodic audits to catch any violations:

```bash
/audit-acf-conventions
```

**Output**: Detailed report of all violations with actionable fixes.

**Fix workflow:**
1. `/audit-acf-conventions` - See violations
2. Fix them (manually or ask Claude to fix)
3. `/audit-acf-conventions` - Verify clean
4. Repeat until librarian approves

### Create Commits

Use the `/commit` command for convention-compliant git commits:

```bash
/commit
```

**What it does:**
1. Analyzes uncommitted changes
2. Groups related changes into atomic commits
3. Enforces conventional commit format: `<type>(<scope>): <subject>`
4. Requires explicit file staging (NEVER `git add -A` or `git add .`)
5. Reports results with minimal, direct communication

**Example output**: "Done. Committed 3 files."

### Customize Conventions

Your project may have special needs. The librarian understands.

**Edit the conventions files:**
```bash
# Edit organization conventions
code docs/acf/organization.md

# Edit git commit conventions
code docs/acf/git/commit-conventions.md

# Or ask Claude to help
"Add a convention for test files in my conventions"
"Update git conventions to require issue numbers in commit messages"
```

**Reload the session:**
```bash
/clear  # Reloads with your updated conventions
```

Now Claude follows YOUR custom conventions. The librarian is flexible (but still stern).

---

## How It Works

### Architecture: Pure Context Injection

**No enforcement scripts. No file watchers. Just context.**

```
Session Start
    ↓
SessionStart Hook Fires
    ↓
Check: docs/acf/organization.md exists?
├─ NO  → Create from template
└─ YES → Read current version (may be customized)
    ↓
Check: docs/acf/git/commit-conventions.md exists?
├─ NO  → Create from template
└─ YES → Read current version (may be customized)
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
| `hooks/handlers/session-start.py` | Initialize & inject both convention sets |
| `content/organization-template.md` | Default ACF organization conventions |
| `content/git-commit-conventions-template.md` | Default git conventions |
| `skills/audit-acf-conventions/SKILL.md` | Compliance checker |
| `skills/commit/SKILL.md` | Conventional commit enforcer |
| `docs/acf/organization.md` | Your project's organization conventions (created by hook) |
| `docs/acf/git/commit-conventions.md` | Your project's git conventions (created by hook) |

---

## Convention Categories

The librarian enforces these categories:

### 1. Directory Structure
- Required top-level directories
- Required docs/ subdirectories
- Required .backlog/ subdirectories (if using ACF)

### 2. Naming Conventions
- **Temporal documents**: `YYYYMMDD-description.md` (research, retrospectives, snapshots)
- **Timeless documents**: `feature-name.md` (acf, patterns, architecture, etc.)
- **Exceptions**: README.md, CLAUDE.md, LICENSE

### 3. Script Organization
- Scripts MUST be in: `scripts/`, `ops/scripts/`, `tools/`, `plugins/*/scripts/`
- Scripts FORBIDDEN in project root (except `setup.py`, `manage.py`)
- Naming: `action-target.sh` format

### 4. Root Directory Rules
- Allowed: README, CLAUDE, LICENSE, package manifests, config files
- Forbidden: Random scripts, docs, log files, temporary files

### 5. Link Validation
- Internal links must use relative paths
- All links must resolve correctly
- No broken references

### 6. Single Source of Truth
- Link to authoritative source
- Never duplicate content

### 7. Git Commit Conventions (🚨 NEW)

**Conventional commit format**:
- Format: `<type>(<scope>): <subject>`
- Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore
- Subject: Imperative mood, no capitalization, no period, max 50 chars

**File staging discipline (CRITICAL)**:
- ❌ **FORBIDDEN**: `git add -A`, `git add .`, `git add --all`, `git commit -a`
- ✅ **MANDATORY**: Explicit file staging only (`git add path/to/specific/file.ext`)

**Atomic commits**:
- One task = one commit
- Commit after each completed task
- Project builds after every commit

### 8. Documentation Writing Standards (🚨 CRITICAL)

The librarian now enforces **token efficiency** for all documentation:

**Code Snippet Policy (Absolute Prohibitions)**:
- ❌ NO function/method implementations (describe requirements instead)
- ❌ NO algorithm pseudocode (use natural language)
- ❌ NO configuration file contents >3 lines (describe what, not content)
- ✅ ALLOWED: API signatures, type definitions, CLI commands (2-3 lines max)

**Example Compression**:
- Show 1-2 representative lines + "..." for repeated patterns
- Target: 40-70% reduction while preserving pattern understanding

**Format Optimization**:
- Tables over prose for comparisons/options (50-70% reduction)
- Text flow over mermaid for simple sequences: "A → B → C"
- Inline lists for enumerations: "**Tools**: Read, Write, Edit"
- Grouped prohibitions: "**FORBIDDEN**: Edit/Write, Bash, Tests"

**Banned Language (Marketing Speak)**:
- NO "comprehensive", "robust", "seamless", "elegant"
- USE specific, testable statements: "Response time < 200ms"

**Preservation Requirements (100% Compliance)**:
- ALL instructions must be preserved
- ALL critical examples (min 1-2 per pattern)
- ALL emphasis (CAPS, bold, !, emojis)
- Information preservation check: Can user execute task? (YES required)

**Target**: 40-70% token reduction with 100% information preservation

---

## Example: Librarian in Action

### Before (Chaos)

```
project/
├── migrate.sh                   # ❌ Script in root
├── notes.md                     # ❌ Doc in root
├── output.log                   # ❌ Log in root
└── docs/
    └── research/
        └── findings.md          # ❌ Missing YYYYMMDD prefix
```

**Librarian's reaction**: *Adjusts glasses with visible disapproval*

### After Audit

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

**Librarian's reaction**: *Nods approvingly* You may proceed.

---

## Librarian Personality Guide

The librarian is:

### Strict but Fair
- She has RULES and they WILL be followed
- But she'll help you understand WHY
- Violations are met with stern disappointment
- Compliance earns reserved approval

### Passive-Aggressive
- *Adjusts glasses disapprovingly*
- *Sighs heavily at your file naming*
- *Taps her pen at your verbose documentation*
- "This is a LIBRARY, not a junk drawer"
- "Everything must be in its proper place, in its leanest form"

### Technically Correct
- The best kind of correct
- Never wrong about conventions
- Has memorized the entire Dewey Decimal System
- Knows where EVERYTHING belongs

### Secretly Helpful
- Stern exterior, helpful interior
- Provides clear, actionable fixes
- Wants you to succeed (organized)
- Will nod approvingly when you get it right

**Voice examples:**

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

---

## Customization Examples

Your project may need special conventions. Edit `docs/acf/organization.md`:

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

Edit `docs/acf/git/commit-conventions.md` for project-specific git rules:

```markdown
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
```

**After editing**, reload:
```bash
/clear  # Librarian reads updated conventions
```

Now Claude follows YOUR rules.

---

## Integration with ACF Workflow

The librarian integrates seamlessly with ACF:

### Pre-Commit Hooks
```yaml
# .pre-commit-config.yaml (future enhancement)
- repo: local
  hooks:
    - id: acf-audit
      name: ACF Convention Compliance
      entry: claude-code /audit-acf-conventions
      language: system
      pass_filenames: false
```

### PR Checklist
```markdown
## PR Checklist
- [ ] Code review passed
- [ ] Tests passing
- [ ] `/audit-acf-conventions` clean ← The librarian approves
```

### `/go` Command Integration
```bash
# Part of ACF workflow
/go

# Includes:
# 1. Task decomposition
# 2. Implementation
# 3. Tests
# 4. /audit-acf-conventions ← Convention compliance
# 5. /commit ← Git commit with conventions enforcement
```

---

## Why This Works

### Psychological Impact
Claude sees conventions as **MANDATORY REQUIREMENTS** injected into system context. Not suggestions. Not guidelines. **REQUIREMENTS.**

The STRICT compliance wrapper transforms conventions from documentation into imperative instructions.

**Token efficiency enforcement**: By injecting optimization patterns into context, Claude automatically creates lean documentation. Every document becomes 40-70% more token-efficient without manual optimization.

### Technical Simplicity
- No enforcement code to maintain
- No file system watchers
- No complex parsing
- Just pure context injection

### User Control
- Conventions are git-tracked docs
- Direct file editing (no CLI needed)
- Version controlled and reviewable
- Team can iterate on conventions

### Lean Implementation
- 9 files total (~800 lines)
- No dependencies beyond Python stdlib
- SessionStart hook handles dual initialization (organization + git)
- Two slash commands: `/audit-acf-conventions` (read-only) and `/commit` (git workflow)

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

```bash
# Check if files exist
ls docs/acf/organization.md
ls docs/acf/git/commit-conventions.md

# If missing, disable and re-enable plugin
/plugin disable acf-librarian
/plugin enable acf-librarian
```

### Claude not following conventions?

The librarian can't make Claude perfect, but she can remind him:

```
"Check the ACF conventions in your context. Am I following them?"
```

Alternatively, run an audit:
```bash
/audit-acf-conventions  # The librarian will find any violations
```

### Custom conventions not applying?

After editing `docs/acf/organization.md` or `docs/acf/git/commit-conventions.md`:
```bash
/clear  # MUST reload session to inject updated conventions
```

---

## Comparison to Other Approaches

### vs. Enforcement Scripts
- ❌ Scripts: Complex, require maintenance, can break workflows
- ✅ Librarian: Pure context, zero enforcement code, Claude self-governs

### vs. Pre-commit Hooks
- ❌ Hooks: Run only at commit time, blocking, frustrating
- ✅ Librarian: Prevention during development, helpful, educational

### vs. Linters
- ❌ Linters: Code only, require configuration, tech-stack specific
- ✅ Librarian: Documentation focus, universal patterns, one config

### vs. Documentation-Only
- ❌ Docs: Easy to ignore, no enforcement, must remember
- ✅ Librarian: Impossible to ignore (in context), automatic, always present

**The librarian is the perfect middle ground**: Strict enough to ensure compliance, flexible enough to customize, helpful enough to educate.

---

## Contributing

The librarian welcomes contributions to improve the default conventions template.

### Adding Convention Categories

1. Edit `content/organization-template.md`
2. Add new section with clear rules
3. Provide examples (✅ good, ❌ bad)
4. Update `/audit-acf-conventions` if checking logic needed

### Improving Audit Logic

1. Edit `skills/audit-acf-conventions/SKILL.md`
2. Add new violation detection
3. Provide actionable fixes
4. Test with real projects

### Librarian Personality

More stern librarian quotes always welcome. She must maintain her disapproving demeanor.

---

## Acknowledgments

**Inspired by**: Every stern librarian who ever shushed you in a library and adjusted her glasses when you put a book back in the wrong spot.

**Spiritual predecessor**: The hall monitor who wrote you up for running in the halls. You were running. They were technically correct.

**Design philosophy**: "Everything in its place" - Marie Kondo, but for repositories, and with more disapproval.

---

## License

Proprietary License - Copyright 2025 Fibonacci Seven, LLC

**The librarian's note**: Properly licensed software. Commercial use requires explicit license. *Nods approvingly*

---

## Summary

The ACF Librarian plugin enforces naming and organization conventions through pure context injection. She watches your project with stern disapproval, but she wants you to succeed.

**Install it. Enable it. Let her watch.**

Your repository has never been more organized.

📚 *Adjusts glasses* You may proceed.
