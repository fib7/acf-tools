# ACF Naming & Organization Conventions

> This file defines the naming and organization conventions for this ACF project.
> The ACF Librarian plugin injects these rules into every session.
>
> **You may customize these conventions for your project** - just edit this file and `/clear` to reload.

---

## 1. Directory Structure Requirements

### Required Top-Level Directories

```
project-root/
├── docs/                        # ALL documentation (MANDATORY)
├── .backlog/                   # Task state machine (if using ACF workflow)
├── .worktree/                  # Per-task git worktrees (if using ACF workflow; gitignored, ephemeral)
├── .claude/                    # Claude configuration
└── [source code directories]   # src/, cmd/, app/, etc.
```

### Required docs/ Subdirectories

```
docs/
├── README.md                   # Documentation navigation hub (MANDATORY)
├── acf/                        # ACF process documentation (TIMELESS)
│   ├── git/                   # Git conventions (commit-conventions.md)
│   └── organization.md        # Naming/organization conventions
├── agents/                     # Agent manifests (TIMELESS, if used)
├── architecture/               # Technical design (TIMELESS)
├── development/                # Developer workflow (TIMELESS)
├── operations/                 # DevOps, deployment (TIMELESS)
├── patterns/                   # Reusable patterns (TIMELESS)
├── research/                   # Research findings (TEMPORAL - YYYYMMDD)
├── retrospectives/             # Retrospectives (TEMPORAL - YYYYMMDD)
└── snapshots/                  # Temporal documents (YYYYMMDD)
    ├── implementation/         # Implementation status
    ├── mappings/              # Cross-reference mappings
    ├── migrations/            # Migration plans
    ├── evaluations/           # Tech evaluations
    └── planning/              # Planning snapshots
```

### Required .backlog/ Subdirectories (if using ACF)

```
.backlog/
├── draft/
├── pending/
├── in-progress/
├── completed/
├── in-review/
├── accepted/
├── rejected/
├── blocked/
├── .metrics/
└── README.md
```

### Per-Task Worktree Directory (if using ACF workflow)

Git worktrees for parallel task execution MUST live at the repo root in `.worktree/`.

**Location**:
- ✅ `<repo-root>/.worktree/<slug>` (dot-prefixed, at repo root)
- ❌ `.claude/.worktree/` (wrong location)
- ❌ `../<repo>-<branch>/` (sibling/external paths)
- ❌ `worktrees/` or `worktree/` (wrong name / missing dot)

**Rules**:
- **Ephemeral**: created on demand by `clean-checkout-before-task`, removed after integration. Never commit worktree contents.
- **Gitignored**: `.worktree/` MUST be in `.gitignore` (added by `/whip-init`).
- **Branch namespace**: each worktree is checked out on `worktree/<slug>`. acf-whip manages **only** worktrees on this branch namespace — any other worktree you park under `.worktree/` (e.g. research/benchmarking) is left untouched.
- **Configurable**: the directory and branch prefix are overridable via `.backlog/.acfw-config` (`ACFW_WORKTREE_DIR`, `ACFW_BRANCH_PREFIX`) — set them only on a fresh backlog.

---

## 2. Naming Conventions: Temporal vs Timeless

### Temporal Documents (MUST have YYYYMMDD prefix)

**Format**: `YYYYMMDD-description.md`
- Date format: YYYYMMDD (NO hyphens in date portion)
- Description: lowercase, hyphen-separated
- Create NEW file for each snapshot (don't update in place)

**Required Locations**:
- `docs/research/`
- `docs/retrospectives/`
- `docs/snapshots/implementation/`
- `docs/snapshots/mappings/`
- `docs/snapshots/migrations/`
- `docs/snapshots/evaluations/`
- `docs/snapshots/planning/`

**Examples**:
- ✅ `20251104-plugin-completion.md`
- ✅ `20251030-architecture-evaluation.md`
- ✅ `20250115-migration-plan.md`
- ❌ `2025-11-04-report.md` (hyphens in date)
- ❌ `research-findings.md` (missing date)
- ❌ `20251104_report.md` (underscore instead of hyphen)

### Timeless Documents (NO dates, update in place)

**Format**: `feature-name.md`
- Lowercase only
- Hyphen-separated words
- NO dates, NO version numbers
- Update in place (git tracks history)

**Required Locations**:
- `docs/acf/` (and subdirectories like `docs/acf/git/`)
- `docs/patterns/`
- `docs/agents/`
- `docs/architecture/`
- `docs/operations/`
- `docs/development/`

**Examples**:
- ✅ `parallel-execution.md`
- ✅ `quality-gates.md`
- ✅ `system-architecture.md`
- ❌ `quality-gates-v2.md` (version number)
- ❌ `architecture-20251104.md` (date embedded)
- ❌ `QualityGates.md` (not lowercase)

### Exceptions (Standard Conventions)

These files may use uppercase:
- `README.md` (standard)
- `CLAUDE.md` (standard)
- `LICENSE` (standard)
- `CONTRIBUTING.md` (standard)
- `.env.example`, `.gitignore` (config files)

---

## 3. Script Organization Rules

### Scripts MUST Be In Designated Directories

**Allowed locations**:
- ✅ `scripts/` (root-level utility scripts)
- ✅ `ops/scripts/` (operations scripts)
- ✅ `tools/` (development tools)
- ✅ `plugins/*/scripts/` (plugin-specific scripts)
- ✅ `.github/workflows/` (GitHub Actions)

**FORBIDDEN location**:
- ❌ Project root (`/*.sh`, `/*.py`, `/*.bash`)
  - **Exception**: Framework files (`setup.py`, `manage.py`)

### Script Naming Convention

**Format**: `action-target.{sh|py|bash}`
- Action: verb (archive, migrate, generate, deploy)
- Target: what it operates on
- Clear, descriptive, hyphen-separated

**Examples**:
- ✅ `archive-old-docs.sh`
- ✅ `migrate-agents.py`
- ✅ `generate-report.sh`
- ✅ `deploy-staging.sh`
- ❌ `script1.sh` (meaningless)
- ❌ `temp.py` (meaningless)
- ❌ `util.sh` (too vague)

---

## 4. Root Directory Rules

### Allowed in Project Root

- ✅ `README.md`, `CLAUDE.md`, `LICENSE`, `CONTRIBUTING.md`
- ✅ Configuration files: `.gitignore`, `.env.example`, `.editorconfig`
- ✅ Package manifests: `package.json`, `go.mod`, `pyproject.toml`, `Cargo.toml`, `pom.xml`
- ✅ Build config: `Makefile`, `Dockerfile`, `docker-compose.yml`
- ✅ CI directories: `.github/`, `.gitlab-ci.yml`, `.circleci/`
- ✅ Framework files: `setup.py`, `manage.py` (Python), `mix.exs` (Elixir)

### Forbidden in Project Root

- ❌ Scripts: `*.sh`, `*.py`, `*.bash` (except framework files above)
- ❌ Evidence files: `*-evidence.txt`, `*.log`
- ❌ Documentation: `*.md` (except README/CLAUDE/LICENSE/CONTRIBUTING)
- ❌ Temporary files: `temp*`, `test*`, `scratch*`
- ❌ Data files: `*.csv`, `*.json` (unless config), `*.txt` (except LICENSE)

---

## 5. Internal Link Validation

### All Internal Links MUST:

1. **Use relative paths** (not absolute)
2. **Resolve correctly** from source file location
3. **Point to existing files** (no broken links)

### Link Format

**Markdown format**: `[Link Text](relative/path/to/file.md)`

**Examples**:
- ✅ `[Organization](docs/acf/organization.md)` (from root)
- ✅ `[Agents](../agents/README.md)` (from docs/patterns/)
- ✅ `[Quality Gates](../../patterns/quality-gates.md)` (from docs/agents/universal/)
- ❌ `[Broken](/absolute/path/file.md)` (absolute path)
- ❌ `[Missing](non-existent-file.md)` (file doesn't exist)

### Cross-Reference Requirements

- Every reference must stay synchronized
- No duplicated content (link to single source of truth)
- Update all referencing documents when moving files

---

## 6. Single Source of Truth Principle

**Every piece of information has EXACTLY ONE authoritative location.**

### Rules:

- ✅ **Link to source**: `See [Git Conventions](docs/acf/git/commit-conventions.md)`
- ❌ **Don't copy/paste**: Duplicating commit format rules into multiple docs

### When Information Changes:

1. Update the single authoritative source
2. All references automatically stay current (they link, not copy)
3. No synchronization burden

---

## 7. Documentation Organization

### Documentation Hub Pattern

`docs/README.md` is the **mandatory navigation hub**:
- Links to all major doc categories
- Organized by user intent ("I want to...")
- Quick reference to key documents

### Hierarchical Organization

```
docs/
├── README.md                    # Hub (navigation)
├── [category]/
│   ├── README.md               # Category overview
│   ├── specific-topic.md       # Timeless topic
│   └── subtopic.md             # Timeless subtopic
└── [temporal-category]/
    ├── README.md               # Category overview
    └── YYYYMMDD-snapshot.md    # Temporal snapshot
```

---

## 8. Customization Guide

**This file is YOUR project's conventions document.**

To customize for your project:

1. **Add project-specific conventions**:
   - Team-specific naming patterns
   - Additional required directories
   - Tech-stack-specific rules

2. **Modify existing rules** (if needed):
   - Adjust directory structure for your needs
   - Add exceptions for your tech stack
   - Define custom categories

3. **Reload session**:
   ```bash
   /clear  # Reloads with your updated conventions
   ```

4. **Commit changes**:
   ```bash
   git add docs/acf/organization.md
   git commit -m "docs(acf): customize organization conventions for project"
   ```

**The librarian will enforce YOUR conventions**, not just the defaults.

---

## 9. Compliance Checking

To verify project compliance with these conventions:

```bash
/audit-acf-conventions
```

This command scans your project and reports:
- Missing required directories
- Naming convention violations
- Scripts in wrong locations
- Broken internal links
- Root directory violations

Fix violations and re-run until clean.

---

## 10. Documentation Writing Standards: Token Efficiency

**🚨 CRITICAL**: All documentation MUST follow token optimization patterns.

**Target**: 40-70% token reduction vs verbose baseline while preserving 100% of information.

### Code Snippet Policy (ABSOLUTE PROHIBITIONS)

**NEVER include**:
- ❌ Function/method implementations (describe requirements instead)
- ❌ Algorithm pseudocode (use natural language description)
- ❌ Configuration file contents >3 lines (describe what, not exact content)
- ❌ Database queries (specify data requirements)
- ❌ API call sequences (describe workflow outcomes)
- ❌ Multi-file code examples (show pattern, not full implementation)

**ALLOWED** (sparingly, 2-3 lines maximum):
- ✅ API endpoint signatures: `POST /api/v1/pipelines`
- ✅ Response shape: `{"pipeline_id": "uuid", "status": "pending"}`
- ✅ Error codes: `Returns 400 for invalid YAML`
- ✅ Type signatures: `func ProcessYAML(input []byte) (*Workflow, error)`
- ✅ CLI commands: `docker run -p 8080:80 myapp`

### Example Compression Rules

**Long examples** (>5 lines showing repeated pattern):
- ✅ Show 1-2 representative lines + "..." for pattern
- ❌ Show 10+ lines of repetitive structure
- **Target**: 40-70% reduction while preserving pattern understanding

**Before** (12 lines):
```javascript
TodoWrite { todos: [
  { content: "Task 1", status: "pending", activeForm: "Working on 1" },
  { content: "Task 2", status: "pending", activeForm: "Working on 2" },
  { content: "Task 3", status: "pending", activeForm: "Working on 3" },
  { content: "Task 4", status: "pending", activeForm: "Working on 4" },
  { content: "Task 5", status: "pending", activeForm: "Working on 5" },
  { content: "Task 6", status: "pending", activeForm: "Working on 6" },
  { content: "Task 7", status: "pending", activeForm: "Working on 7" }
]}
```

**After** (4 lines, 67% reduction):
```javascript
TodoWrite { todos: [
  { content: "Task 1", status: "pending", activeForm: "Working on 1" },
  ... // 5-10 todos total
]}
```

**Multiple examples** (5+ showing same pattern):
- ✅ Keep 1-2 most representative examples
- ❌ Show 8 variations of the same concept
- **Target**: 60-80% reduction

### Format Optimization Requirements

**Tables over prose**:
- ✅ Use tables for comparisons, options, specifications, tool parameters
- ❌ Avoid paragraph descriptions of structured data
- **Target**: 50-70% reduction for comparison content

**Before** (5 lines prose):
> The pending state indicates work not started. The in_progress state means currently working. The completed state shows finished work. The blocked state indicates dependencies preventing progress. The rejected state means quality gate failure.

**After** (table, 60% reduction):
| State | Meaning |
|-------|---------|
| pending | Not started |
| in_progress | Currently working |
| completed | Finished |
| blocked | Dependency preventing progress |
| rejected | Quality gate failure |

**Text flow over diagrams**:
- ✅ Simple flows: "A → B → C → D"
- ❌ Mermaid diagrams for linear sequences
- **Target**: 40-60% reduction for simple flows

**Compact lists**:
- ✅ Inline format: "**Tools**: Read, Write, Edit, Grep, Glob, Bash"
- ❌ Bullet list: Each tool on separate line with explanation
- **Target**: 30-40% reduction for simple enumerations

### Grouped Content Rules

**Prohibitions/permissions** (list inline, comma-separated):
- ✅ "**FORBIDDEN**: Edit/Write, Bash execution, Tests, Build/lint, Git ops, Package install"
- ❌ Bullet list with ❌ emoji prefix per line
- **Target**: 20-30% reduction

**Before** (15 lines with emoji per line):
```markdown
🔴 FORBIDDEN ACTIONS:
- ❌ Edit files
- ❌ Write files
- ❌ Run bash commands
- ❌ Execute tests
- ❌ Run build process
- ❌ Run linters
- ❌ Git operations
- ❌ Install packages
```

**After** (1 line, 93% reduction):
```markdown
**FORBIDDEN**: Edit/Write, Bash execution, Tests, Build/lint, Git ops, Package install
```

**Repeated messaging** (consolidate to single authoritative section):
- ✅ One "Delegation Protocol" section with all rules
- ❌ Same delegation rules repeated in 3+ sections
- **Target**: 60-80% reduction

### Banned Language (Marketing Speak)

**NEVER use these words**:
- "comprehensive", "systematic", "significant", "substantial", "robust", "elegant", "seamless"
- "achievement", "progress", "improvement" (unless 100% complete with metrics)
- "enhance", "optimize", "streamline" (be specific: "Response time < 200ms")
- "leverage", "utilize" (use "use")
- "facilitate", "enable" (be direct about what happens)

### Required Language (Precise, Testable)

**ALWAYS use**:
- **Binary**: "API validates token" NOT "improve validation"
- **Specific**: "Response time < 200ms" NOT "fast response"
- **Testable**: "Returns 401 for missing token" NOT "handles auth errors"
- **Quantified**: "Reduces 12 files to 4" NOT "consolidates files"
- **Active voice**: "System validates input" NOT "Input is validated"

### Preservation Requirements (100% Compliance)

**MUST preserve** when optimizing existing documentation:
- ✅ All instructions (every rule, guideline, protocol)
- ✅ All critical examples (minimum 1-2 per pattern)
- ✅ All anti-patterns and their rules
- ✅ All emphasis (CAPS LOCK, **bold**, *italic*, !, emojis in headers)
- ✅ All validation requirements
- ✅ All technical constraints
- ✅ All success metrics

**Information preservation check**:
- Can user still execute the task with optimized version? → YES required
- Are all "MUST"/"NEVER" rules still present? → YES required
- Are critical examples still demonstrating the pattern? → YES required

### Style Requirements

**Tone**: Direct, intellectually rigorous, essential information only
**Structure**: Headers, bullets, tables, code blocks (NOT long paragraphs)
**Sections**: <30 lines per section (break into subsections if needed)

**Forbidden patterns**:
- ❌ NO em dashes (use hyphens or colons)
- ❌ NO AI meta-talk ("As an AI...", "I should note...", "It's worth mentioning...")
- ❌ NO theatrical language ("blazingly fast", "powerful", "cutting-edge")
- ❌ NO vague terminology without definition
- ❌ NO content duplication (link to single source of truth)

### Optimization Target

**All documentation created should achieve**:
- 40-70% token reduction vs verbose baseline
- 100% information preservation (zero loss of instructions)
- Maximum semantic density (every token earns its place)
- Scannable structure (tables, bullets, headers, NOT prose)

### Validation

Before finalizing any documentation, verify:
1. ✅ No code implementations (only signatures/examples allowed)
2. ✅ Examples compressed (1-2 lines + "..." for patterns)
3. ✅ Tables used for comparisons (NOT prose)
4. ✅ No marketing language (be specific and testable)
5. ✅ All critical content preserved (instructions, examples, emphasis)
6. ✅ Token count 40-70% below verbose equivalent

---

**Last Updated**: Auto-maintained by ACF Librarian plugin
**Source**: This file is the single source of truth for project conventions
