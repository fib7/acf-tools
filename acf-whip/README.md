# ACF Whip - Hostile Workflow Enforcer

**Zero tolerance backlog automation from decomposition to acceptance with aggressive quality gates.**

**ACF (Agentic Continuous Flow)** is software development where humans govern intelligent agent swarms rather than write code directly. Whip automates the complete task lifecycle with zero tolerance for incomplete work.

Standalone ACF plugin that implements complete backlog workflow: task decomposition, continuous execution, quality review, and retrospective analysis. Enforces strict task description style and generates specialist agents on demand.

## Overview

ACF Whip is a hostile workflow enforcer that automates the entire task lifecycle:

```
/task → decompose scope into atomic tasks (WHAT/WHY only, no HOW)
         ↓
/go → continuous execution until 100% complete (loops until all terminal)
         ↓
quality gates → zero bypass tolerance (all must pass)
         ↓
review → binary accept/reject (no partial credit)
         ↓
/retro → analyze failures, create improvement tasks
```

**Philosophy**: Zero tolerance for incomplete work. Binary outcomes. Evidence required. No shortcuts.

---

## Features

### 🔥 Hostile Task Style Enforcement

**MANDATORY compliance** with `docs/acf/style/task-descriptions.md`:
- Binary language only ("API validates token" NOT "improve validation")
- WHAT/WHY specification, NEVER HOW (specialists decide implementation)
- Max 2-3 line code snippets (signatures only, NO implementations)
- Banned words: comprehensive, robust, elegant, enhance, optimize

**Violations = Immediate rejection**

### ⚡ Workflow-native orchestration (2.0.0)

When dynamic workflows are available (Claude Code ≥ 2.1.154), `/task` and `/go` run as **dynamic workflows** (`workflows/whip-task.workflow.js`, `workflows/whip-go.workflow.js`):

- **Flat context**: the loop, slug partition, dependency gate, and topological integration order run inside a deterministic script — intermediate state lives in script variables, not Claude's context — so context stays flat no matter how many tasks/iterations. (This is the fix for the old "stop work to dump history" problem.)
- **Schema-enforced worktree slugs**: `/task`'s planner cannot omit a slug; a JS validation gate (kebab-case, slug ≠ id, acyclic deps, unique ids) runs before any file is written; the doctor FATALs on a missing slug at dispatch.
- **Integrity-gated**: the doctor runs as a hard gate at startup and a recheck every iteration.
- **Automatic fallback**: if dynamic workflows are off, both commands fall back to the legacy single-context loop (same behavior, byte-compatible).

### 🔌 Pluggable task stores (3.1.0)

Task state lives behind an **executable adapter contract** (`adapters/CONTRACT.md`, contract v1).
The `acfw-store` dispatcher resolves the configured backend and routes every read/write —
`snapshot`, `transition`, `read`, `create`, `doctor` — to its adapter:

| Backend | State lives in | Select with |
|---|---|---|
| `files` (default) | `.backlog/<state>/*.md` committed on trunk | nothing — zero-config default |
| `beads` | [beads](https://github.com/gastownhall/beads) (`bd`, sqlite) | `ACFW_STORE=beads` in `.acfwhip/config` |
| `multica` | [multica](https://github.com/multica-ai/multica) server | `ACFW_STORE=multica` + `MULTICA_*` env |
| `linear` | [Linear](https://linear.app) issues (attachment metadata) | `ACFW_STORE=linear` + `LINEAR_API_KEY`/`ACFW_LINEAR_TEAM` env |

- **Zero migration**: existing `.backlog/` projects run unchanged; `files` behavior is byte-identical to 3.0.x.
- **Third-party backends without forking**: drop one executable at `.acfwhip/adapters/acfw-store-<name>`, set `ACFW_STORE=<name>`, pass the conformance test (`ADAPTER=<path> bash tests/phase9-store-conformance.test.sh`). Contract, discovery order, JSON shapes and exit codes: `adapters/CONTRACT.md`; architecture, dispatcher mechanics, and an authoring walkthrough: `adapters/README.md`.
- **What never moves into a backend**: the LP-CAS integration ledger (`.acfwhip/integrated/` in the git tree) — integration truth stays git-native on every store.

### 🔄 Continuous Backlog Execution

`/go` loops until 100% complete:
- Processes ALL state transitions each iteration
- Quality gate auto-fix before processing
- Parallel agent spawning for independent tasks (one specialist per worktree slug)
- Dependency-gated dispatch (same-slug needs accepted; cross-slug needs integrated)
- Autonomous integration into local trunk with specialist-driven conflict resolution
- Exits only when all tasks in terminal states (accepted/blocked)
- No manual intervention needed

### 🩺 Backlog Integrity Doctor

`/whip-doctor [--fix]` is the integrity battery (~18 invariants across FATAL/REPAIRABLE/WARN): status-vs-folder mismatch, missing/empty worktree slug, unknown agent, dangling/cyclic deps, cross-slug dependent dispatched before integration, orphaned worktrees, stale in-progress, and more. It runs automatically as a `/go` startup gate and per-iteration recheck, and at `/task` create-time.

### 📦 Worktree Env Hydration

A committed `.worktreeinclude` manifest lists git-ignored files (`.env`, `node_modules`, `.venv`, local config) to copy/symlink into each fresh `.worktree/<slug>` so specialists run a full dev/test sandbox. Allowlist-only with a hard secret denylist (refuses to symlink `.env*`/`*.pem`/`*.key`/`id_*`/`credentials*`/`*.p12`, requires every entry to be git-ignored, treats a tracked path as an error).

### 🤖 Agent + Manifest Generator

`/whip-add-agents` creates specialist agents on demand:
- **Analyzes repository**: Tech stack detection, complexity assessment
- **Creates TWO files per agent**:
  - `.claude/agents/{agent}.md` (implementation, core instructions)
  - `docs/agents/{agent}.md` (manifest with Priority 1/2/3 docs, 58-74% token reduction)
- **Generates quality gates**: Stack-specific documentation if missing
- **Updates configuration**: `.backlog/README.md`, `CLAUDE.md`
- **User args override auto-detection**: `--backend=go --frontend=react`

### 📋 State Machine

User-specified custom flow:

```
pending → in-progress → completed → in-review → [accepted | rejected]
            ↓                                          ↓
         blocked                                    pending (retry)
```

**Terminal states**: `accepted` (success), `blocked` (failure after 3 retries or unresolvable)

### 🪝 SessionStart Hook

**Passive documentation setup** (runs automatically on every session):
- Copies `task-descriptions.md` to `docs/acf/style/` (if missing)
- Copies `task-template.md` to `docs/acf/backlog/` (if missing)
- Copies `workflow.md` to `docs/acf/backlog/` (if missing)
- Generates `.backlog/README.md` **only if `.backlog/` directory already exists**
- Injects style guide into session context for enforcement

⚠️ **SessionStart hook does NOT create `.backlog/` structure or install agents.** Run `/whip-init` for complete initialization.

### 🚀 Pure Delegation Enforcement

`/whip-init` adds **Pure Delegation Architecture** section to `CLAUDE.md` (if exists):
- **CRITICAL RULE**: General-purpose agent CANNOT modify code directly
- **Orchestration ONLY**: Task decomposition, coordination, quality gates
- **Agent Matrix**: Up-to-date table of all agents with specializations
- **Delegation Protocol**: 5-step process ensuring specialists handle implementation
- **Enforcement**: Pre-tool-use hook validates (conceptual - not yet implemented)
- **Result**: 3x+ speedup through parallel specialist execution

**Matrix Example**:
| Domain | Agent | Responsibilities |
|--------|-------|------------------|
| Core | task-engineer | Task decomposition (WHAT/WHY only) |
| Backend | go-engineer | Go implementation |
| Infrastructure | devops | Docker, K8s, CI/CD, monitoring |

### 📚 docs/README.md Support

If your project has a `docs/README.md` file, acf-whip agents will read it to discover documentation instead of blind directory scanning.

**How it works**:
- `/whip-init` checks for `docs/README.md`
- If exists: Agents read it to understand what documentation is available
- If missing: Agents scan standard directories (`docs/architecture/`, `docs/operations/`, etc.)

**Benefits**:
- Agents discover ALL documentation (not just standard directories)
- You control what's documented and prioritized
- Natural language index (no special format required)

**Simple example** `docs/README.md`:
```markdown
# Project Documentation

## Core
- [Architecture](./architecture/) - System design
- [Quality Gates](./development/quality-gates-go.md) - Go quality standards

## Guides
- [API Development](./guides/api-development.md) - Building APIs
```

**Template**: See `content/templates/docs-readme-template.md` for a starting point.

### 🔍 Gap Analysis on Re-Init

Running `/whip-init` on existing project performs **non-destructive gap detection**:
- **Checks**: Universal agents, manifests, core docs, quality gates, CLAUDE.md sections
- **Reports**: Missing artifacts with actionable recommendations
- **Never overwrites**: Existing files preserved, gaps highlighted
- **Example output**:
```
⚠️  Gap Analysis: Missing ACF Artifacts

🤖 Missing Universal Agents:
   - devops
   → Fix: Re-run /whip-init or manually generate

📚 Missing Agent Manifests:
   - task-engineer.md, devops.md
   → Manifests provide 58-74% token reduction

✅ No gaps detected - ACF Whip fully integrated
```

---

## Installation

### Prerequisites

- Claude Code CLI installed
- Git repository for your project
- Python 3.8+ (for SessionStart hook)

### Install Plugin

```bash
# Add the acf-tools marketplace
/plugin marketplace add ./acf-tools
# OR from GitHub (when published):
# /plugin marketplace add owner/acf-tools

# Install acf-whip plugin
/plugin install acf-whip@acf-tools

# Restart Claude Code if prompted
```

### Verify Installation

```shell
# Check plugin installed
/plugin list
# Should show: acf-whip@acf-tools (enabled)

# Start a session in your project
# You should see:
```
# ACF Task Description Style Guide (Enforcement Active)

The following style guide is MANDATORY for all task descriptions...
```

This confirms SessionStart hook is active.

**Debug if not working:**
```bash
# Enable debug mode to see plugin loading
claude --debug

# Verify plugin structure
cd /path/to/acf-tools/acf-whip
claude plugin validate .
```

---

## Quick Start

⚠️ **REQUIRED FIRST STEP**: You MUST run `/whip-init` after plugin installation to create the `.backlog/` structure, install agents, and configure quality gates. The SessionStart hook alone does NOT perform complete initialization.

### 1. Initialize Backlog Workflow

```bash
/whip-init
```

**What it does**:
- Detects tech stack (Go, Python, Node.js, React, Next.js, K8s, Docker, CI/CD, etc.)
- Detects infrastructure (Docker, Kubernetes, GitHub Actions, monitoring)
- Creates `.backlog/` structure (9 state folders)
- **Generates 6-7 universal agents** to `.claude/agents/` (customized from patterns, devops optional)
- Configures quality gates (`.pre-commit-config.yaml`)
- Generates `.backlog/README.md`
- **Deep manifest customization**: Analyzes existing `docs/` for Priority 1/2/3 references
- **CLAUDE.md Pure Delegation enforcement**: Adds delegation rules + agent matrix (if CLAUDE.md exists)
- **Gap analysis**: Non-destructive detection of missing artifacts on re-init

**Output**:
```
✅ ACF Whip Initialized Successfully

📁 Directory Structure Created:
   .backlog/ (9 state folders)

📋 Core Documentation Initialized:
   ✓ docs/acf/style/task-descriptions.md
   ✓ docs/acf/backlog/task-template.md
   ✓ docs/acf/backlog/workflow.md
   ✓ .backlog/README.md

👥 Universal Agents Generated (customized for your stack): (6-7)
   ✓ task-engineer (with {stack}-specific examples)
   ✓ quality-reviewer (with {stack} quality gates)
   ✓ lean-architect, retro, precommit, research-agent
   ✓ devops (optional, if infrastructure detected)

📊 Agent Manifests Generated:
   ✓ docs/agents/*.md (Priority 1/2/3 structure, 58-74% token reduction)
   ✓ Deep customization analyzing existing docs/

🎯 Quality Gates Configured

📋 CLAUDE.md Enhanced (if exists):
   ✓ Pure Delegation Architecture section
   ✓ Agent matrix (6-7 agents)
   ✓ Enforcement: General agent CANNOT modify code

Next Steps: Run /whip-add-agents
```

### 2. Generate Specialist Agents

```bash
# Auto-detect tech stack
/whip-add-agents

# OR specify explicitly
/whip-add-agents --backend=go --frontend=react
```

**What it does**:
- Analyzes repository structure
- Detects missing specialist agents
- Creates `.claude/agents/{agent}.md` (implementation)
- Creates `docs/agents/{agent}.md` (manifest with Priority 1/2/3 docs)
- Generates quality gate docs (if missing)
- Updates `.backlog/README.md` with new agents

**Output**:
```
✅ Created 3 specialist agents + manifests

📋 go-engineer
   - Implementation: .claude/agents/go-engineer.md
   - Manifest: docs/agents/go-engineer.md
   - Quality Gates: docs/development/quality-gates-go.md

📋 react-engineer
   ...

Next Steps: Run /task to decompose work
```

### 3. Decompose Scope Into Tasks

```bash
/task "Implement user authentication system with JWT tokens"
```

**What it does**:
- Reads `docs/acf/style/task-descriptions.md` (style enforcement)
- Minimal research (Perplexity, Context7, Figma if applicable)
- Decomposes scope into atomic tasks (WHAT/WHY only)
- Validates against style guide
- Spawns task-engineer agents in parallel
- Creates tasks in `.backlog/pending/`

**Output**:
```
🔥 Task Decomposition Started

✓ Style guide loaded
✓ Research complete
✓ 3 atomic tasks identified
✓ Style validation passed

Created tasks:
- backend-001-user-auth-api.md (high, go-engineer)
- backend-002-user-profile-mgmt.md (high, go-engineer)
- backend-003-password-reset-flow.md (medium, go-engineer)

Next step: Run /go
```

### 4. Execute Backlog

```bash
/go
```

**What it does**:
- Loops until 100% tasks in terminal states
- Each iteration:
  1. Quality gate auto-fix
  2. Scan ALL states
  3. Process ALL transitions
  4. Spawn agents in parallel
  5. Check completion
- Exits when all tasks accepted/blocked OR intervention needed

**Output**:
```
🔥 /go - Continuous Backlog Execution Started

🔄 Iteration 1
  🔧 Auto-fixing quality gates...
  📊 Scanning states... (5 pending)
  ⚡ Processing transitions...
  🚀 Spawning agents (parallel)...
  📊 Progress: 0/5 terminal

🔄 Iteration 2
  ...
  📊 Progress: 2/5 terminal (2 accepted)

🔄 Iteration 3
  ...
  📊 Progress: 5/5 terminal (5 accepted, 0 blocked)

✅ Backlog 100% complete!
   Accepted: 5
   Blocked: 0
   Iterations: 3
```

### 5. Retrospective (if failures)

```bash
/retro
```

**What it does**:
- Phase 1: retro agent analyzes blocked/rejected tasks (Five Whys)
- Phase 2: task-engineer creates improvement tasks
- Creates report in `docs/retrospectives/YYYYMMDD-topic.md`

---

## Commands Reference

### /task - Pure Orchestration

**Purpose**: Decompose scope into atomic tasks (NEVER implements)

**Execution**: runs as the `whip-task` dynamic workflow when available (schema-enforced slugs + JS validation gate + create-time doctor, before any file is written); otherwise the legacy single-context decomposition.

**Usage**:
```bash
/task "Scope description"
/task "Add real-time notifications. Figma: https://figma.com/design/ABC/App?node-id=1-2"
```

**Behavior**:
1. Reads style guide (mandatory)
2. Minimal research (Perplexity, Context7, Figma)
3. Decomposes into atomic tasks (WHAT/WHY only)
4. Validates against style guide
5. Spawns task-engineer agents (parallel)
6. Exits immediately

**Style Enforcement**:
- ✅ Binary language ("API validates token")
- ✅ WHAT/WHY only (no HOW)
- ✅ Max 2-3 line code snippets
- ❌ NO implementation details
- ❌ NO banned words

**Output**: Tasks created in `.backlog/pending/`

---

### /go - Continuous Execution

**Purpose**: Execute entire backlog until 100% complete

**Execution**: runs as the `whip-go` dynamic workflow when available (the loop/partition/dependency-gate/integration live in a script, so Claude's context stays flat across iterations); otherwise the legacy single-context loop. Both refuse to dispatch against a FATAL-failing backlog (doctor startup gate).

**Usage**:
```bash
/go
```

**Behavior**:
- Loops until ALL tasks in terminal states
- Each iteration:
  - Quality gate auto-fix (stack-specific)
  - Scan ALL states (pending, in-progress, completed, in-review, rejected, blocked)
  - Process ALL transitions (TodoWrite single call)
  - Spawn agents in parallel
  - Check completion
- Exits: 100% complete OR no progress for 3 iterations

**State Transitions Processed**:
- `rejected` → `pending` (retry if <3 attempts, block if ≥3)
- `blocked` → `pending` (dependencies resolved)
- `pending` → `in-progress` (specialist agents start)
- `completed` → `in-review` → `accepted|rejected` (quality-reviewer)
- `in-progress` → `blocked` (timeout 48h)

**Output**: Continuous progress until completion

---

### /whip-doctor - Backlog Integrity

**Purpose**: Diagnose (and optionally repair) backlog + worktree health

**Usage**:
```bash
/whip-doctor          # report only
/whip-doctor --fix    # apply the REPAIRABLE class, then re-scan
```

**Checks** (FATAL / REPAIRABLE / WARN): status-vs-folder mismatch, missing/empty worktree slug on a code task, unknown Assigned Agent, duplicate IDs, dangling/cyclic dependencies, cross-slug dependent dispatched before integration, worktree on the wrong branch, detached HEAD; stray `Integrated-At`, out-of-range Rejection Count, dup-folder, orphaned worktree; missing clean-checkout token, lingering in-review, stale in-progress, cross-slug glob overlap.

**Output**: `SEVERITY|CODE|TASK_ID|DETAIL` lines + a `SUMMARY|fatal=N|repairable=N|warn=N|ok=…` line; exit 0 iff no FATAL. Runs automatically as a `/go` startup gate and per-iteration recheck.

---

### /retro - Retrospective Analysis

**Purpose**: Root cause analysis and improvement task creation

**Usage**:
```bash
/retro
```

**Behavior**:
- **Phase 1**: retro agent
  - Scans `.backlog/blocked/` and `.backlog/rejected/`
  - Applies Five Whys methodology
  - Detects systemic vs individual issues
  - Creates report in `docs/retrospectives/YYYYMMDD-topic.md`
- **Phase 2**: task-engineer
  - Reviews retrospective findings
  - Creates improvement tasks in `.backlog/pending/`
  - Prioritizes systemic issues as high

**Output**: Retrospective report + improvement tasks

---

### /research - Research Workflow

**Purpose**: Conduct structured research using MCP tools, create temporal documentation, generate backlog task

**Usage**:
```bash
/research "Next.js 15 server components best practices"
/research "Prisma query optimization for PostgreSQL time-series data"
/research "UI component from Figma: https://figma.com/design/ABC/node-id=1-2"
```

**Behavior**:
1. Verifies prerequisites (`.backlog/`, `docs/acf/research-protocol.md`, `docs/acf/organization.md`)
2. Generates temporal filename: `docs/research/YYYYMMDD-{topic}.md`
3. Launches research-agent for comprehensive research
4. **MCP Tool Selection** (from research-protocol.md):
   - **Figma MCP**: MANDATORY when Figma URL/node provided
   - **Context7**: Library documentation, API references
   - **Perplexity**: Best practices, architecture, security, performance
5. Creates research document with evidence-based analysis
6. **Automatically generates backlog task** from findings

**Temporal Naming (MANDATORY)**:
- Format: `docs/research/YYYYMMDD-description.md`
- Date: Current date in YYYYMMDD (NO hyphens)
- Description: lowercase, hyphen-separated
- Reference: `docs/acf/organization.md`

**Style Requirements** (from `docs/acf/style/research-documents.md`):
- Direct, factual analysis (no promotional language)
- Evidence-based claims with source attribution
- Quantified comparisons (not "faster", use "3x faster")
- Tables for comparisons (not prose)
- Code snippets ≤3 lines

**Output**: Research document (`docs/research/YYYYMMDD-topic.md`) + backlog task (`.backlog/pending/`)

---

### /whip-init - Initialize Workflow

**Purpose**: Explicit project initialization

**Usage**:
```bash
/whip-init
```

**Behavior**:
1. Detects tech stack (package files scan)
2. Asks user for customization (priority system, coverage thresholds)
3. Analyzes repository for agent customization data
4. Creates `.backlog/` structure (9 folders)
5. Installs quality gate config (`.pre-commit-config.yaml`)
6. **Generates 6 universal agents** from patterns to `.claude/agents/` (customized for project)
7. Generates agent manifests in `docs/agents/` (Priority 1/2/3 structure)
8. Triggers SessionStart hook behavior (copies docs, generates README)
9. Adds CLAUDE.md section (if exists)

**Output**: Complete backlog workflow initialized

---

### /whip-add-agents - Agent + Manifest Generator

**Purpose**: Create missing specialist agents

**Usage**:
```bash
# Auto-detect
/whip-add-agents

# User-specified (PRIORITY)
/whip-add-agents --backend=go --frontend=nextjs
/whip-add-agents --backend=python --data=dagster --infrastructure=k8s
```

**Behavior**:
1. **Parse user args** (override auto-detection)
2. **Repository analysis**:
   - Scan directory structure
   - Detect tech stack indicators
   - Analyze CLAUDE.md for mentions
   - Check existing agents (avoid duplication)
   - Assess complexity (LOC, polyglot, microservices)
3. **Study existing conventions**:
   - Read existing agent implementations
   - Read existing manifests
   - Extract patterns (structure, sections, formats)
4. **Generate agent files**:
   - **Implementation**: `.claude/agents/{agent}.md` (small, core instructions)
   - **Manifest**: `docs/agents/{agent}.md` (Priority 1/2/3 docs, navigation guidance, 10 anti-patterns)
5. **Generate quality gates**: `docs/development/quality-gates-{stack}.md` (if missing)
6. **Update configuration**:
   - Regenerate `.backlog/README.md` with new agents
   - Update `CLAUDE.md` agent assignments (if exists)
   - Install pre-commit hooks (if missing)

**Tech Stack Detection**:
- **Backend**: `go.mod` → go-engineer, `requirements.txt` → python-engineer, `package.json` + express/fastify → nodejs-backend-engineer
- **Frontend**: `package.json` + next → nextjs-engineer, + react → react-engineer
- **Data**: Dagster/BentoML files → data-engineer/ml-ops-engineer
- **Infrastructure**: `k8s/` → k8s-engineer, `docker-compose.yml` → devops

**Output**: Agent implementations + manifests + quality gates + updated config

---

## Universal Agents

All projects get **6-7 universal agents** (devops optional) **GENERATED FROM PATTERNS** and customized for the project's tech stack:

**Key Change**: Universal agents are no longer generic files copied verbatim. They're **generated** from patterns and customized with:
- Stack-specific examples (Go/Python/Node.js syntax)
- Quality gate tool references matching your `.pre-commit-config.yaml`
- Coverage thresholds from your initialization choices
- Priority system (3-level vs 5-level SLA-based)
- Agent assignment matrices reflecting your actual agents
- **Infrastructure detection** (Docker, K8s, CI/CD, monitoring)

**The 6 core universal agents**:

### task-engineer
- **Role**: Task decomposition (WHAT/WHY only, no HOW)
- **Authority**: Create tasks, set priorities, assign agents
- **Prohibition**: ZERO implementation code
- **Style**: Enforces `task-descriptions.md` style guide

### quality-reviewer
- **Role**: Binary accept/reject decisions
- **Authority**: Accept completed work, reject with reasons
- **Prohibition**: NEVER fixes code, only identifies issues
- **Critical**: MUST move tasks to terminal state (accepted/rejected)

### lean-architect
- **Role**: System architecture design (WHAT/WHY not HOW)
- **Authority**: Design architectures, define contracts, document decisions
- **Prohibition**: NO implementation code
- **Style**: Max 2-3 line code snippets (interfaces only)

### retro
- **Role**: Process improvement and retrospectives
- **Authority**: Conduct retrospectives, analyze metrics, **update agent instructions** (EXCLUSIVE)
- **Method**: Five Whys root cause analysis

### precommit
- **Role**: Pre-commit hook configuration
- **Authority**: Configure hooks, select repositories, optimize execution
- **Prohibition**: Cannot modify quality standards (retro authority)

### research-agent
- **Role**: Evidence-based research
- **Authority**: Conduct research, create comprehensive reports
- **Tools**: **MANDATORY Perplexity usage** for all research

### devops (Optional, Infrastructure-Aware)
- **Role**: Infrastructure, CI/CD, and deployment operations
- **Authority**: Configure Docker/K8s, setup monitoring, CI/CD pipelines, troubleshooting
- **Created When**: Docker, Kubernetes, or CI/CD platform detected (user can skip)
- **Customization**: Generated with detected orchestration (docker-compose/kubernetes), CI tool (github-actions/gitlab-ci), monitoring stack (prometheus-grafana/datadog), cloud provider (gke/eks/aks)
- **Prohibition**: Cannot design K8s manifests (delegates to k8s-engineer if exists)
- **Manifest**: Deeply customized analyzing `docs/operations/` for Priority 1/2/3 docs

---

## Agent Manifest System

### Purpose

Achieve **58-74% token reduction** through priority-ordered documentation.

### Structure

Every manifest has:

1. **Agent Identity**: Role, tech focus, scope, out of scope
2. **Priority 1: MUST READ** (5-8 docs, used in 80%+ tasks)
3. **Priority 2: SHOULD READ** (10-15 docs, used in 40-80% tasks)
4. **Priority 3: REFERENCE** (situational, <40% tasks)
5. **Navigation Guidance**: Task-specific reading paths
6. **Scope Boundaries**: IS/NOT responsible for
7. **Quality Gates**: Stack-specific commands
8. **Common Workflows**: 5 standard patterns
9. **Integration Points**: Handoffs to/from other agents
10. **Anti-Patterns**: 10 common mistakes with explanations
11. **Quick Reference**: Copy-paste commands, evidence templates
12. **Success Metrics**: First-pass acceptance rate, doc usage

### Example Priority 1 Docs

```markdown
## Priority 1: MUST READ (Every Task)

1. `.backlog/README.md` - Workflow, priorities, evidence
2. `docs/acf/style/task-descriptions.md` - Task requirements format
3. `docs/acf/backlog/task-template.md` - Task file structure
4. `docs/development/quality-gates-go.md` - Quality requirements
5. `docs/architecture/service-architecture.md` - System design
```

### Navigation Guidance

```markdown
**Task Type: New API Endpoint**
**Reading Path**:
1. Priority 1: All docs
2. Priority 2: API contracts, error handling, authentication
3. Reference: Security (if auth-related), monitoring (if critical)
```

---

## Quality Gates

### Zero Bypass Tolerance

**ABSOLUTE PROHIBITIONS**:
- ❌ `git commit --no-verify`
- ❌ `SKIP={hook-name}`
- ❌ Lowering coverage thresholds
- ❌ Commenting out failing tests

**Enforcement**: CI re-runs all quality gates. Bypasses = immediate rejection.

### Stack-Specific Commands

**Go**:
```bash
golangci-lint run ./...
go test ./... -v -race -cover
go build ./...
go mod tidy && git diff --exit-code go.mod go.sum
```

**Python**:
```bash
ruff check .
ruff format . --check
mypy . --strict
pytest --cov --cov-report=term
```

**Node.js/TypeScript**:
```bash
npm run lint
npm run typecheck
npm test --coverage
npm run build
```

### Coverage Thresholds

| Code Type | Minimum Coverage |
|-----------|------------------|
| API endpoints | 90-95% |
| Core logic | 90% |
| Services | 85-90% |
| Utilities | 85% |
| UI components | 80% |

### Failure Protocol

- Attempts 1-10: Fix actual issues
- After 10 attempts: Move task to blocked with failure report
- If systemic (3+ similar failures): Run `/retro`

---

## Task Description Style Guide

### MANDATORY Rules

**Binary Language**:
- ✅ "API validates token" NOT "improve validation"
- ✅ "Returns 401 for invalid credentials"
- ❌ "Enhance authentication system"

**WHAT/WHY Only** (NO HOW):
- ✅ WHAT: "POST /api/v1/auth/login endpoint"
- ✅ WHY: "Enable user authentication"
- ✅ CONSTRAINTS: "Response < 200ms"
- ❌ HOW: "Use bcrypt for hashing, JWT for tokens"

**Code Snippet Limits**:
- ✅ ALLOWED (2-3 lines): `POST /api/v1/auth`, `{"token": "jwt"}`, `Returns 400 for missing fields`
- ❌ PROHIBITED: Function implementations, algorithms, config files

**Banned Words**:
- comprehensive, systematic, significant, substantial
- robust, elegant, achievement
- enhance, optimize, streamline (unless specific: "optimize query from 2s to 200ms")

### Golden Rule

If a specialist agent can read your task and say **"I know WHAT to build and WHY"**, you've succeeded.

If they say **"I just need to copy-paste this code"**, you've failed.

---

## Configuration

### SessionStart Hook

Automatically initializes on every session:

```python
# Location: hooks/handlers/session-start.py

def main():
    # 1. Check/copy docs to docs/acf/ (only when missing)
    check_and_copy("task-descriptions.md", "docs/acf/style/")
    check_and_copy("task-template.md", "docs/acf/backlog/")
    check_and_copy("workflow.md", "docs/acf/backlog/")

    # 2. Warn if .backlog/ is missing (README.md is not auto-generated)

    # 3. Inject style guide into session context
    return hookSpecificOutput with style guide enforcement
```

`.backlog/README.md` is created once by `/whip-init` and never rewritten by the
SessionStart hook — user edits are preserved across sessions.

---

## Examples

### Example 1: Backend API Development

```bash
# 1. Initialize
/whip-init

# 2. Generate Go backend agent
/whip-add-agents --backend=go

# 3. Decompose scope
/task "Implement REST API for user management with CRUD operations"

# Output: Creates 3 tasks
# - backend-001-user-api-endpoints.md (POST/GET/PUT/DELETE)
# - backend-002-user-validation-middleware.md (input validation)
# - backend-003-user-integration-tests.md (API tests)

# 4. Execute backlog
/go

# Output: Loops through:
# Iteration 1: Start all 3 tasks (parallel)
# Iteration 2: Complete tasks, trigger reviews
# Iteration 3: All accepted, exit 100% complete
```

### Example 2: Full-Stack Feature

```bash
# 1. Generate both backend and frontend agents
/whip-add-agents --backend=go --frontend=react

# 2. Decompose full-stack scope
/task "Add user profile page with avatar upload. Figma: https://figma.com/design/ABC/App?node-id=1-2"

# Output: Creates tasks for both stacks
# - backend-001-profile-api.md (go-engineer)
# - backend-002-avatar-upload-s3.md (go-engineer)
# - frontend-001-profile-page.md (react-engineer)

# 3. Execute (cross-stack coordination via dependencies)
/go
```

### Example 3: Quality Gate Failure Recovery

```bash
# Scenario: Task fails quality gates 3 times
/go

# Output in iteration 5:
# ⚠️  feature-001 rejected 3 times (coverage 75% vs 85% required)
# Continuing...

# Iteration 10: Still failing
# → Moved to blocked with failure report

# Run retrospective
/retro

# Output:
# Root Cause: Test coverage requirements unclear in task description
# Created improvement task: docs-001-clarify-coverage-requirements.md
```

---

## Troubleshooting

### Tasks Stuck in in-review

**Problem**: quality-reviewer didn't move tasks to terminal state

**Solution**:
```bash
# Manually check in-review tasks
ls .backlog/in-review/

# Force re-review
mv .backlog/in-review/*.md .backlog/completed/
/go
```

**Prevention**: quality-reviewer agent enforces terminal state movement

### No Progress for 3 Iterations

**Problem**: Tasks blocked or circular dependencies

**Solution**:
```bash
# Check blocked tasks
ls .backlog/blocked/

# Read blocker reports
cat .backlog/blocked/*.md

# Run retrospective to analyze
/retro
```

### Style Guide Violations

**Problem**: task-engineer creates tasks with implementation details

**Solution**:
- SessionStart hook injects style guide enforcement
- `/task` command validates before spawning agents
- If violations persist, run `/retro` to update task-engineer instructions

### Agent Generation Errors

**Problem**: `/whip-add-agents` can't detect tech stack

**Solution**:
```bash
# Use explicit flags
/whip-add-agents --backend=go --frontend=react

# Or check project structure
ls -la  # Verify go.mod, package.json, etc. exist
```

---

## Architecture

### Plugin Structure

```
plugins/acf-whip/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── skills/                      # 6 slash commands
│   ├── task/SKILL.md
│   ├── go/SKILL.md
│   ├── retro/SKILL.md
│   ├── research/SKILL.md
│   ├── whip-init/SKILL.md
│   └── whip-add-agents/SKILL.md
├── hooks/
│   ├── hooks.json
│   └── handlers/
│       └── session-start.py     # Auto-initialization
└── content/                      # Templates and patterns
    ├── acf/
    │   └── research-protocol.md  # Research MCP tool usage
    ├── style/
    │   ├── task-descriptions.md
    │   └── research-documents.md # Research documentation style
    ├── backlog/
    │   ├── task-template.md
    │   ├── workflow.md
    │   └── README.sample.md
    ├── quality-gates/            # 5 stack docs
    ├── pre-commit-configs/       # 3 stack configs
    └── agent-patterns/           # Agent generation patterns
        ├── universal/            # 6 universal agent patterns
        │   ├── task-engineer-pattern.md
        │   ├── quality-reviewer-pattern.md
        │   ├── lean-architect-pattern.md
        │   ├── precommit-pattern.md
        │   ├── retro-pattern.md
        │   └── research-agent-pattern.md
        ├── specialist/           # 4 specialist agent patterns
        │   ├── backend-agent-pattern.md
        │   ├── frontend-agent-pattern.md
        │   ├── data-agent-pattern.md
        │   └── infrastructure-agent-pattern.md
        └── manifests/            # 5 manifest generation patterns
            ├── universal-manifest-pattern.md
            ├── backend-manifest-pattern.md
            ├── frontend-manifest-pattern.md
            ├── data-manifest-pattern.md
            └── infrastructure-manifest-pattern.md
```

### Command Flow

```
User Request
    ↓
/task → Read style guide → Research → Decompose → Validate → Spawn task-engineers → Exit
    ↓
.backlog/pending/ (tasks created)
    ↓
/go → Loop: Scan states → Process transitions → Spawn agents → Check completion
    ↓
quality-reviewer → Accept/Reject → Move to terminal state
    ↓
.backlog/accepted/ OR .backlog/blocked/
    ↓
/retro → Analyze failures → Create improvement tasks
```

### Agent Generation Flow

```
/whip-add-agents
    ↓
Parse user args (priority) → Repository analysis → Study existing conventions
    ↓
For each missing agent:
    ↓
Generate implementation (.claude/agents/{agent}.md)
    ↓
Generate manifest (docs/agents/{agent}.md) with Priority 1/2/3
    ↓
Generate quality gates (docs/development/quality-gates-{stack}.md)
    ↓
Update .backlog/README.md with new agents
    ↓
Update CLAUDE.md (if exists)
```

---

## Contributing

### Pattern Extraction

To contribute new patterns:

1. Identify universal pattern in production
2. Strip project-specific details
3. Add PARAMETERIZE markers
4. Create multi-stack examples
5. Test template clarity
6. Submit PR with comprehensive documentation

### Agent Templates

To add new agent patterns:

1. Create `{type}-agent-pattern.md` in `content/agent-patterns/`
2. Create `{type}-manifest-pattern.md` with Priority 1/2/3 structure
3. Update `/whip-add-agents` command to recognize new type
4. Test agent generation with pattern
5. Submit PR with usage examples

---

## License

Proprietary License - Copyright 2025 Fibonacci Seven, LLC. See LICENSE file in repository root.

---

## Acknowledgments

Distilled from production ACF implementations.

---

## Support

Issues: https://github.com/fib7/acf-tools/issues

Documentation: https://github.com/fib7/acf-tools/tree/main/docs

---

**Version**: 1.0.0
**Last Updated**: 2025-11-07
**Status**: Stable

Zero tolerance. Binary outcomes. Evidence required. No shortcuts.
