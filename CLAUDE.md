# ACF Tools Distribution - AI Assistant Instructions

## Agentic Continuous Flow (ACF)

**ACF is software development for a world where intelligence exists in silicon as well as carbon.** Humans shift from writing code to governing intelligent agent swarms. Knowledge (ontologies, policies, constraints) becomes the product; code is ephemeral output regenerated on demand. Work flows through multi-dimensional risk evaluation - low-risk tasks execute autonomously, high-risk tasks trigger human review. Systems emerge from agent interactions within knowledge boundaries rather than being engineered top-down. The fundamental inversion: humans govern, agents execute.

---

## Repository Overview

**Purpose**: Plugin distribution for ACF cognitive modes and workflow tools

**What this repository IS**:
- Distribution package for 7 ACF plugins
- Self-contained plugin implementations ready for installation
- Marketplace registry for Claude Code plugin ecosystem

**What this repository is NOT**:
- Not an active development project (plugins are developed elsewhere)
- Not a pattern extraction toolkit (no complex documentation workflow)
- Not a documentation repository (each plugin is self-documented)

**Repository type**: Distribution (maintain plugin quality, publish updates, synchronize marketplace)

---

## Plugin Inventory

| Plugin | Type | Purpose | Files |
|--------|------|---------|-------|
| **acf-challenger-mode** | Cognitive | Logic validation enforcer | 6 |
| **acf-arazor-mode** | Cognitive | Production verification enforcer | 6 |
| **acf-nitro** | Cognitive | Parallel execution enforcer | 6 |
| **acf-mission-control** | Functional | Status line HUD | 6 |
| **acf-librarian** | Functional | Convention enforcement | 9 |
| **acf-whip** | Functional | Backlog workflow automation (workflow-native, concurrency-safe) | 58 |
| **acf-advisor** | Functional | Consult another LLM (thinking-on) via OpenAI-compatible endpoint | 17 |

**Total**: 108 plugin files + 10 project/docs files = 118 tracked files.

**acf-whip 2.0.2** makes `/task` and `/go` **workflow-native**: they run as dynamic workflows (`workflows/whip-task.workflow.js`, `workflows/whip-go.workflow.js`) whose loop, slug partition, dependency gate, and topological integration live in a deterministic script — so Claude's context stays flat across iterations — with the legacy single-context loop as the automatic fallback when dynamic workflows are unavailable. Worktree slugs are enforced in three layers: schema-required at decomposition → JS validation gate (kebab-case, acyclic deps, unique ids) → at dispatch the doctor **self-heals** a missing slug on an active task (derives it from the id and writes it in) instead of hard-failing. **2.0.1 self-healing**: doctor severity is scoped to the dispatch path — accepted/historical tasks are advisory (WARN, never blocking), so a pre-2.0.0 backlog runs instead of aborting the gate; `/go` counts a branchless historical accepted task as terminal (runtime-derived via `hasWorktreeBranch`, no file rewrites) and never re-integrates it (integrate-worktree exits 4 on a missing branch). **Parallelization is the default** at both planning and execution: distinct slug per independent surface (concurrent), shared slug only on real file-surface overlap, dependencies only on genuine output consumption. `/whip-doctor` is the integrity battery (now emitting a grouped `BREAKDOWN` line) and runs as a startup + per-iteration gate; `scan-backlog.sh` emits the read-only snapshot the scheduler runs on (now including `hasWorktreeBranch`); `.worktreeinclude` hydrates git-ignored config into fresh worktrees. **2.0.2 scale fix**: the snapshot is a bounded **working set** — full task objects only for actionable tasks plus their dependency targets, while terminal/historical accepted tasks collapse into aggregate `runtimeTerminalDefault`/`runtimeTerminalOverride` counts that drive completion — so the per-iteration scan no longer balloons into a backlog-sized blob the workflow agent must echo (the cause of a multi-minute stall on a ~300-task backlog); the doctor's new `--quiet` mode bounds the gate report to FATAL + `BREAKDOWN` + `SUMMARY`. The git-worktree branch registry remains the parallelism lock (one specialist per `Worktree:` slug). See `acf-whip/content/backlog/workflow.md`.

**Plugin architecture**: Each plugin is fully self-contained with no cross-dependencies. Users can install any combination.

---

## Directory Structure

```
acf-tools/
├── .gitignore                       # Standard exclusions
├── README.md                        # User-facing documentation
├── CLAUDE.md                        # This file (AI instructions)
├── .claude-plugin/
│   └── marketplace.json             # Plugin registry (7 plugins)
├── acf-challenger-mode/             # Logic validation (6 files)
├── acf-arazor-mode/                 # Production verification (6 files)
├── acf-nitro/                       # Parallel enforcement (6 files)
├── acf-mission-control/             # Status HUD (6 files)
├── acf-librarian/                   # Convention enforcement (9 files)
├── acf-whip/                        # Workflow automation, workflow-native (58 files; skills/ + workflows/)
└── acf-advisor/                     # Second-opinion LLM client (17 files)
```

---

## Maintenance Guidelines

### Repository Philosophy

This is a **distribution repository**, not a development repository. The workflow is simple:

1. Receive plugin updates from development sources
2. Test plugin installation and execution
3. Update marketplace.json if versions change
4. Commit and publish to distribution channels

**No complex ACF workflow needed here** - we distribute the ACF tools, we don't use them to build this repository.

### Git Conventions

Use conventional commits for clarity:

```
feat(plugin-name): description    - New features or new plugins
fix(plugin-name): description     - Bug fixes in plugin code
docs(plugin-name): description    - Documentation updates
docs: description                 - Project-level documentation
chore: description                - Maintenance, marketplace updates
```

**Examples**:
```bash
feat(acf-whip): add quality gates for Rust stack
fix(acf-nitro): correct parallel detection in TodoWrite
docs(acf-librarian): update installation instructions
docs: improve README.md quick start guide
chore: update marketplace.json with v1.1.0 versions
```

### Quality Standards

**Plugin integrity checks**:
- Each plugin directory is complete (no missing files)
- No broken internal references within plugins
- README.md accuracy for each plugin
- marketplace.json stays synchronized with plugin versions

**Distribution quality gates**:
- All 7 plugins install without errors
- Hook handlers execute cleanly (bash/python syntax valid)
- Content files are well-formed markdown
- Plugin.json manifests are valid JSON

**Testing workflow**:
1. **Validate plugin structure**: `cd acf-plugin-name && claude plugin validate .`
2. **Add local marketplace**: `/plugin marketplace add ./acf-tools`
3. **Install plugin**: `/plugin install acf-plugin-name@acf-tools`
4. **Verify installation**: `/plugin list` (should show plugin enabled)
5. **Start debugging**: `claude --debug` (to see plugin loading details)
6. **Test functionality**:
   - Check commands appear: `/help`
   - Verify hooks trigger correctly
   - Test plugin-specific features
7. **Iterate on changes**:
   - `/plugin uninstall acf-plugin-name@acf-tools`
   - Make modifications to plugin files
   - `/plugin install acf-plugin-name@acf-tools`
   - Repeat testing

---

## Plugin Update Workflow

When receiving plugin updates from development:

### 1. Receive Update
- Copy updated plugin directory to this repository
- Note version changes and new features

### 2. Validate Update
```bash
# Check plugin structure
ls -la acf-plugin-name/

# Validate JSON manifests
cat acf-plugin-name/.claude-plugin/plugin.json | jq .

# Check hooks configuration
cat acf-plugin-name/hooks/hooks.json | jq .
```

### 3. Update Marketplace
- Edit `.claude-plugin/marketplace.json`
- Update version number for the plugin
- Update description if features changed
- Validate JSON syntax

### 4. Test Installation
```bash
# Install locally
cp -r acf-plugin-name ~/.config/claude/plugins/

# Test in Claude Code
# Verify expected behavior
# Remove test installation
```

### 5. Commit Changes
```bash
git add acf-plugin-name/ .claude-plugin/marketplace.json
git commit -m "feat(acf-plugin-name): update to v1.x.x"
git push
```

---

## Common Maintenance Tasks

### Adding a New Plugin

1. Copy plugin directory to repository root
2. Add entry to `.claude-plugin/marketplace.json`:
   ```json
   {
     "name": "acf-new-plugin",
     "description": "Brief description",
     "version": "1.0.0",
     "author": {
       "name": "ACF Project",
       "email": "acf@fib7.ai"
     },
     "source": "./acf-new-plugin",
     "category": "productivity",
     "tags": ["relevant", "tags"]
   }
   ```
3. Update README.md to include new plugin
4. Test installation
5. Commit with `feat(acf-new-plugin): add new plugin v1.0.0`

### Updating Plugin Documentation

1. Edit plugin's README.md
2. Verify accuracy against plugin code
3. Update examples if needed
4. Commit with `docs(plugin-name): update documentation`

### Synchronizing Marketplace

1. Review all plugin versions
2. Update `.claude-plugin/marketplace.json` with current versions
3. Validate JSON syntax: `cat .claude-plugin/marketplace.json | jq .`
4. Commit with `chore: synchronize marketplace versions`

---

## File Integrity

**Critical files** (must never be broken):
- `.claude-plugin/marketplace.json` - Valid JSON, correct paths
- Each plugin's `plugin.json` - Valid JSON, correct metadata
- Each plugin's `hooks.json` - Valid JSON, correct hook configuration
- README.md - Accurate plugin descriptions and install instructions

**Validation commands**:
```bash
# Validate all JSON files
find . -name "*.json" -exec sh -c 'echo "Checking {}:" && cat {} | jq .' \;

# Check for broken symlinks
find . -type l ! -exec test -e {} \; -print

# Verify plugin structure
for plugin in acf-*; do
  echo "Checking $plugin..."
  test -f "$plugin/README.md" || echo "  Missing README.md"
  test -f "$plugin/LICENSE" || echo "  Missing LICENSE"
done
```

**Official plugin validation**:
```bash
# Validate plugin structure and manifests (official Claude Code tool)
cd acf-plugin-name
claude plugin validate .

# Check marketplace structure
cd acf-tools
claude plugin validate .
```

---

## Debugging Plugins

### Official Debugging Tools

```bash
# Start Claude Code in debug mode
claude --debug

# Outputs:
# - Plugin loading sequence
# - Plugin manifest validation
# - Hook registration
# - Command registration
# - MCP server initialization
# - Any errors or warnings
```

### Plugin Management Commands

```shell
# List all installed plugins
/plugin list

# List available marketplaces
/plugin marketplace list

# Browse and install plugins interactively
/plugin

# Update marketplace metadata
/plugin marketplace update marketplace-name

# Uninstall for testing iteration
/plugin uninstall plugin-name@marketplace-name
```

### Validation Workflow

```bash
# Before installing, validate plugin structure
cd acf-plugin-name
claude plugin validate .

# Check for common issues:
# - Invalid plugin.json syntax
# - Missing required fields
# - Wrong directory structure
# - Broken file references
```

### Common Issues Reference

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| Plugin not loading | Invalid JSON in plugin.json | Run `claude plugin validate .` |
| Commands not appearing | Wrong directory structure | Ensure `commands/` at plugin root, not in `.claude-plugin/` |
| Hooks not firing | Script not executable | Run `chmod +x hooks/handlers/*.sh` |
| MCP server fails | Missing ${CLAUDE_PLUGIN_ROOT} | Use variable in all plugin file references |
| Path errors | Absolute paths in config | Use relative paths starting with `./` |

---

## Important Notes

### This is NOT a Development Repository

**Do not add**:
- Complex documentation organization (docs/acf/, docs/patterns/, etc.)
- Plugin development infrastructure
- Pattern extraction workflows
- Multi-agent coordination systems
- Complex quality gates for code (these are pure markdown plugins)

**This repository's scope**:
- Distribute 6 working plugins
- Keep marketplace.json synchronized
- Maintain plugin integrity
- Update documentation as plugins evolve

### Plugins Generate Documentation

The plugins themselves CREATE documentation when installed in user projects:

- `acf-librarian` creates `docs/acf/organization.md`
- `acf-whip` creates `.backlog/` structure and workflow docs
- Users don't need pre-existing docs - plugins initialize them

**Do not copy** user project documentation patterns into this distribution repository.

---

## Support and Contact

**Issues**: Report in individual plugin README files or repository issues
**Email**: acf@fib7.ai
**Distribution updates**: Follow git log for changelog

---

**Repository Version**: v1.0
**Last Updated**: 2026-05-28
**Marketplace Plugins**: 7
**Total Files**: 118 (tracked)
