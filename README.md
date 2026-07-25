# ACF Tools - Agentic Engineering Toolkit Distribution

## Agentic Continuous Flow (ACF)

**ACF is software development for a world where intelligence exists in silicon as well as carbon.** Humans shift from writing code to governing intelligent agent swarms. Knowledge (ontologies, policies, constraints) becomes the product; code is ephemeral output regenerated on demand. Work flows through multi-dimensional risk evaluation - low-risk tasks execute autonomously, high-risk tasks trigger human review. Systems emerge from agent interactions within knowledge boundaries rather than being engineered top-down. The fundamental inversion: humans govern, agents execute.

---

## Plugin Collection

This repository contains 7 specialized plugins for Agentic Continuous Flow workflows:

### Cognitive Modes (4 plugins)

Specialized cognitive modes that enforce specific thinking patterns and validation approaches:

- **acf-challenger-mode** - Reasoning validation mode with intellectually aggressive logic enforcement
- **acf-arazor-mode** - Production verification mode with ruthless honesty and zero tolerance for false claims
- **acf-nitro** - Parallel execution enforcement mode that catches sequential violations and enforces speed optimization
- **acf-mission-control** - Status line HUD for tracking position, git branch, and context fuel with color-coded indicators. **Accurate cost** as of 1.3.0: prices the session from transcript token usage against the LiteLLM rate table, so models behind a gateway — which Claude Code reports as `$0.00` — bill correctly

### Workflow Tools (3 plugins)

Functional tools for ACF workflow automation and convention enforcement:

- **acf-librarian** - Convention enforcement through context injection, auto-initializes organization standards, audits compliance
- **acf-whip** - Task workflow enforcer with zero tolerance backlog automation from decomposition to acceptance. **Concurrency-safe** as of 1.2.0: tasks declare `Worktree:` and `PR Group:` slugs; `/go` partitions on `Worktree:` and dispatches at most one specialist per slug. Specialists invoke `clean-checkout-before-task` (Step 0) which uses git's worktree branch registry as the lock. No custom locks, daemons, or schedulers. **Pluggable task stores** as of 3.1.0: `.backlog/` files (default), [beads](https://github.com/gastownhall/beads), [multica](https://github.com/multica-ai/multica), or [Linear](https://linear.app) behind an executable adapter contract — third-party backends drop in without forking (`acf-whip/adapters/CONTRACT.md`; mechanics and authoring guide: `acf-whip/adapters/README.md`).
- **acf-advisor** - Lean `advisor` skill for consulting another LLM (thinking/reasoning mode on by default) via any OpenAI-compatible endpoint. Env-var driven (`LITELLM_API_KEY` / `LITELLM_BASE_URL` / `ADVISOR_MODEL`, with `OPENAI_*` fallbacks). Single uv-run script, stdlib only. Use it for second opinions, design review, or domain expertise outside Claude's strengths.

---

## Installation

### Prerequisites

- Claude Code CLI installed
- Git repository initialized in your project

### Quick Install

#### Install from Local Repository (Development/Testing)

1. **Clone this repository**:
   ```bash
   git clone <repository-url> acf-tools
   cd /path/to/parent/directory  # Directory CONTAINING acf-tools
   ```

2. **Start Claude Code and add marketplace**:
   ```bash
   claude
   ```

   In Claude Code:
   ```shell
   /plugin marketplace add ./acf-tools
   ```

3. **Install plugins** (choose what you need):
   ```shell
   # Install individual plugins
   /plugin install acf-challenger-mode@acf-tools
   /plugin install acf-whip@acf-tools
   /plugin install acf-librarian@acf-tools

   # Browse all available plugins
   /plugin
   ```

4. **Restart Claude Code if prompted**:
   - Plugins activate after restart
   - See individual plugin READMEs for configuration options

### Debug Installation Issues

If plugins don't appear after installation:

```bash
# Enable debug mode to see plugin loading details
claude --debug

# Check marketplace added
/plugin marketplace list
# Should show: acf-tools

# Verify plugins available
/plugin
# Should show plugins from acf-tools marketplace

# Validate individual plugin
cd acf-tools/acf-challenger-mode
claude plugin validate .
```

### Plugin Selection Guide

**Start with these for most projects**:
- `acf-whip` - Core backlog workflow
- `acf-librarian` - Organization and conventions

**Add cognitive modes as needed**:
- `acf-challenger-mode` - When reviewing requirements or architecture
- `acf-arazor-mode` - Before deployments or status reporting
- `acf-nitro` - For performance-critical workflows

**Optional enhancements**:
- `acf-mission-control` - Visual status tracking

---

## Plugin Details

| Plugin | Category | Purpose | Key Features |
|--------|----------|---------|--------------|
| **acf-challenger-mode** | Cognitive | Logic validation | Attacks gaps in reasoning, finds contradictions, enforces consistency |
| **acf-arazor-mode** | Cognitive | Production verification | Binary true/false only, ruthless honesty, deployment readiness checks |
| **acf-nitro** | Cognitive | Parallel enforcement | Catches sequential execution, calculates time waste, enforces TodoWrite batching |
| **acf-mission-control** | Functional | Status HUD | Color-coded context tracking (green→yellow→red), git branch display, self-priced session cost (LiteLLM rate table) |
| **acf-librarian** | Functional | Conventions | Auto-initializes docs/acf/organization.md, audit command, naming enforcement |
| **acf-whip** | Functional | Workflow automation | Task decomposition, backlog state machine, quality gates, agent generation |
| **acf-advisor** | Functional | Second-opinion LLM client | OpenAI-compatible endpoint, env-var configured, thinking mode on by default |

---

## Command Reference

### acf-whip (Workflow Automation)

| Command | Flags/Arguments | Purpose |
|---------|----------------|---------|
| `/whip-init` | `--priority=3-level\|5-level`<br>`--coverage=60\|80\|95`<br>`--strict\|--standard`<br>`--with-specialists`<br>`--store=files\|beads\|multica\|linear` | Initialize backlog workflow: creates the task store (`.backlog/` structure on the default files backend; `beads`/`multica`/`linear` configure `ACFW_STORE` in `.acfwhip/config` instead), installs quality gates, generates universal agents + manifests. Use `--with-specialists` to auto-generate stack-specific agents (python-engineer, react-engineer, etc.) |
| `/task "<scope>"` | Scope description (string) | Decompose scope into atomic backlog tasks. Pure orchestration - analyzes requirements via Perplexity/Context7/Figma, creates tasks following WHAT/WHY style (never HOW), spawns task-engineer agents in parallel |
| `/go` | None | Continuous backlog execution until 100% complete. Loops through: quality gate auto-fix → scan states → process transitions → **partition pending by `Worktree:` slug → dispatch one specialist per slug (parallel across slugs)** → check completion. Terminal states: accepted/blocked |
| `/research "<topic>"` | Topic description (string) | Conduct research using MCP tools (Perplexity, Context7, Figma). Creates temporal doc `docs/research/YYYYMMDD-topic.md`, generates backlog task from findings |
| `/retro` | `--focus=<area>` (optional)<br>`--agent=<name>` (optional)<br>`--timeframe=<days>` (optional) | Retrospective analysis of blocked/rejected tasks. Applies Five Whys methodology, identifies systemic issues, creates improvement tasks in `.backlog/pending/` |
| `/whip-add-agents` | `--backend=go\|python\|nodejs\|rust`<br>`--frontend=react\|nextjs\|vue\|angular`<br>`--data=dagster\|bentoml\|airflow`<br>`--infrastructure=k8s\|docker\|terraform`<br>`--specialized=temporal\|event-bus\|graphql` | Generate specialist agents + manifests from patterns. Auto-detects tech stack if no flags provided. Creates agent implementation (`.claude/agents/`) + comprehensive manifest (`docs/agents/`) with Priority 1/2/3 structure |

### acf-librarian (Convention Enforcement)

| Command | Flags/Arguments | Purpose |
|---------|----------------|---------|
| `/audit-acf-conventions` | `--fix` (optional) | Scan project for ACF convention violations: directory structure, temporal/timeless naming (YYYYMMDD prefix), script organization, broken links, root directory cleanliness, documentation verbosity. Default: read-only reporting. With `--fix`: automatically fixes all identified issues |

### Cognitive Modes (Hook-Based)

**No slash commands** - These plugins inject behavioral constraints via SessionStart hooks:

- **acf-challenger-mode** - Logic validation enforcer (attacks gaps, finds contradictions, blocks incomplete specs)
- **acf-arazor-mode** - Production verification enforcer (binary true/false only, deployment readiness)
- **acf-nitro** - Parallel execution enforcer (catches sequential violations, calculates time waste)
- **acf-mission-control** - Status line HUD (color-coded context tracking, git branch display)

**Activation:** Automatic on session start after plugin installation

---

## Documentation

Each plugin contains its own README.md with:
- Detailed feature descriptions
- Usage examples
- Configuration options
- Integration guidelines

See individual plugin directories for complete documentation.

---

## Contributing

This is a distribution repository. For plugin development and contributions:

1. Report issues in individual plugin READMEs
2. Follow conventional commit format for updates
3. Test all plugins before distribution updates

---

## License

Proprietary License - Copyright 2025 Fibonacci Seven, LLC. Commercial use requires license. See LICENSE file in repository root and each plugin directory.

---

## Learn More

**ACF Concepts**:
- Pure delegation architecture (3x speedup through orchestrator/specialist separation)
- Evidence-based validation (eliminates false compliance)
- Transactional documents (complete audit trail)
- Agent manifests (58-74% context reduction)

**Contact**: acf@fib7.ai
