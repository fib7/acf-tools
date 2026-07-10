---
name: whip-init
description: Initialize ACF Whip backlog workflow system in project
argument-hint: "[--with-specialists]"
allowed-tools:
  - Bash
  - Write
  - Read
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
---

# /whip-init - Initialize Backlog Workflow

Explicit initialization command. Sets up complete backlog workflow system with quality gates and universal agents.

## Purpose

Initialize ACF Whip backlog workflow in the current project:
- Create `.backlog/` directory structure (9 state folders)
- **Generate** universal agents to `.claude/agents/` (customized from patterns)
- **Optionally generate** specialized agents (with `--with-specialists` flag)
- Generate agent manifests in `docs/agents/` (Priority 1/2/3 structure)
- Install stack-specific quality gate configuration
- Initialize core documentation (via SessionStart hook)
- Add CLAUDE.md section for backlog workflow

**Key Changes**:
- Universal agents are now **GENERATED** from patterns and customized for each project's tech stack, not copied verbatim
- **NEW**: `--with-specialists` flag auto-generates specialized agents (python-engineer, react-engineer, etc.) based on tech stack detection, eliminating the need for separate `/whip-add-agents` command

## Execution Flow

**Note**: This command uses Read/Write tools to:
1. Copy configuration files (pre-commit, docs) from the plugin directory to the project
2. **Generate** agents by reading pattern templates and customizing them for this project

The `${CLAUDE_PLUGIN_ROOT}` variable is automatically resolved by Claude Code and points to the installed plugin location. If files cannot be read, Claude will report clear errors.

### Step 1: Detect Tech Stack

Scan project for tech stack indicators:

```bash
# Backend: go.mod → "go" | requirements.txt/pyproject.toml → "python" | package.json + (fastify|express|@nestjs) → "nodejs"
# Frontend: package.json + "next" → "nextjs" | + "react" → "react" | + "vue" → "vue"
# Infrastructure flags: has_docker, has_k8s, has_ci, detected_ci_tool, detected_orchestration, has_monitoring
# Docker: Dockerfile|docker-compose.yml → has_docker=true, detected_orchestration="docker-compose"
# K8s: k8s/|kubernetes/|skaffold.yaml|helm/|charts/ → has_k8s=true, detected_orchestration="kubernetes"
# CI/CD: .github/workflows → "github-actions" | .gitlab-ci.yml → "gitlab-ci" | .circleci/config.yml → "circleci" | Jenkinsfile → "jenkins"
# Monitoring: prometheus.yml|monitoring/|grafana/ → has_monitoring=true
# suggest_devops=true if has_docker OR has_k8s OR has_ci
```

### Step 2: User Customization

Use AskUserQuestion to gather preferences:

| Question | Options | Default | Variable |
|----------|---------|---------|----------|
| **Priority System** | 3-level (high/medium/low) or 5-level (blocker/critical/high/medium/low) | 3-level (smaller projects), 5-level (team > 5) | `priority_system` |
| **Coverage Thresholds** | 60% (rapid prototyping), 80% (standard), 95% (critical systems) | 80% | `coverage_threshold` |
| **Quality Gate Strictness** | Standard (10 retry attempts), Aggressive (5 retry attempts) | Standard | `max_retries` |
| **DevOps Agent** | "Yes, create devops" (for Docker/K8s/CI/CD), "No, skip devops" (add later via /whip-add-agents) | "Yes" if `suggest_devops=true`, else "No" | `create_devops` |

### Step 3: Create .backlog/ Structure

**Check if .backlog/ already exists**:
```bash
if [ -d ".backlog" ]; then
    echo "⚠️  .backlog/ directory already exists. Skipping directory creation."
    echo "   Verifying folder structure..."
else
    echo "Creating .backlog/ structure..."
fi
```

Create 9 state folders and .gitkeep files (only if missing):

```bash
for folder in draft pending in-progress completed in-review blocked rejected accepted archive; do
  mkdir -p ".backlog/$folder"
  touch ".backlog/$folder/.gitkeep"
done
```

**Verify structure**:
```bash
echo "✓ .backlog/ structure verified:"
ls -1 .backlog/ | grep -v README.md | xargs -I {} echo "  - {}"
```

### Step 3.5: Configure Worktree Concurrency, Env Hydration, and Doctor Config

**3.5a — gitignore entries.** Add the per-task worktree dir (default `.worktree/`, or the
`ACFW_WORKTREE_DIR` you set in 3.5c) and `.backlog/.acfw-run.json` (the `/go` run heartbeat)
to `.gitignore`. ACF convention: per-task worktrees live at `<repo-root>/.worktree/` and are
gitignored (see `docs/acf/organization.md` → "Per-Task Worktree Directory").

```bash
WT_DIR="${ACFW_WORKTREE_DIR:-.worktree}"   # honor a custom dir if .acfw-config sets one
ensure_gitignore() { # <pattern> <comment>
  if [ -f .gitignore ] && grep -qxF "$1" .gitignore; then return; fi
  printf '\n# %s\n%s\n' "$2" "$1" >> .gitignore
  echo "✓ Added $1 to .gitignore"
}
ensure_gitignore "${WT_DIR%/}/" 'ACF Whip per-task worktrees (clean-checkout-before-task)'
ensure_gitignore '.backlog/.acfw-run.json' 'ACF Whip /go run heartbeat'
```

**3.5b — `.worktreeinclude` manifest.** Scaffold a starter manifest (if missing) listing
untracked dev files to copy/symlink into each fresh worktree so specialists can run a full
dev sandbox. Default mode is **copy**; `link:` symlinks; `secret:` copies with stripped
perms. Every listed path MUST be git-ignored (a tracked path is a hard error). Large dep
trees default to **copy** (isolated, race-free) — switch a line to `link:` only if tasks
never run installs inside the worktree.

```bash
if [ ! -f .worktreeinclude ]; then
  cat > .worktreeinclude <<'EOF'
# .worktreeinclude — untracked files to hydrate into each fresh .worktree/<slug>.
# Honored by clean-checkout-before-task. Default mode: copy. Modes: copy: / link: / secret:.
# Every path MUST be git-ignored. Globs allowed. Edit to match your project.
#
# Local environment (copied so a worktree owns its own and edits don't leak across slugs):
# .env
# .env.local
#
# Dependency trees (COPY = isolated & safe; switch to `link:` only if no in-worktree installs):
# node_modules
# .venv
#
# Symlink large read-only caches to save disk:
# link: .cache
#
# Secrets are copied with stripped perms and NEVER symlinked:
# secret: .secrets/local.key
EOF
  echo "✓ Created starter .worktreeinclude (edit to match your project)"
else
  echo "✓ .worktreeinclude already present"
fi
```

**3.5c — doctor config.** Scaffold `.backlog/.acfw-config` with the operator-tunable
in-progress timeout (default 8h; lower it for overnight runs so an agent killed mid-edit
frees its slug sooner) and the worktree namespace acf-whip owns. Read by `doctor.sh`,
`scan-backlog.sh`, `clean-checkout.sh`, `integrate-lpcas.sh`, and `/go`.

```bash
if [ ! -f .backlog/.acfw-config ]; then
  cat > .backlog/.acfw-config <<'EOF'
# ACF Whip runtime config (sourced by doctor.sh, scan-backlog.sh, clean-checkout.sh,
# integrate-lpcas.sh, and /go).

# Hours before an in-progress task is flagged stale / timed out to blocked.
ACFW_INPROGRESS_TIMEOUT_HOURS=8

# Worktree namespace acf-whip OWNS and may create/remove. acf-whip only ever touches
# worktrees on the <ACFW_BRANCH_PREFIX>/<slug> branch — any other worktree (including one
# you park under ACFW_WORKTREE_DIR for your own research/benchmarking) is left untouched.
# Change these ONLY on a fresh backlog: existing worktrees are pinned to the old namespace.
ACFW_WORKTREE_DIR=.worktree
ACFW_BRANCH_PREFIX=worktree

# LP-CAS (3.0.0) integration gates, run by integrate-lpcas on the CANDIDATE tree (trunk + the
# task's change) before it lands — the backstop that catches a union-level break a per-worktree
# gate cannot see (#8) and a botched conflict resolution (#18). Both optional; empty = skip.
#   ACFW_PARSE_SANITY_CMD — cheap parse/lint, run first; failure = mechanism (re-resolve), not a reject.
#   ACFW_GATE_CMD         — the full union gate; failure = quality reject. CWD is the candidate worktree.
# Example (uncomment + adapt to your stack):
# ACFW_PARSE_SANITY_CMD='npx tsc --noEmit'
# ACFW_GATE_CMD='npm test --silent'
EOF
  echo "✓ Created .backlog/.acfw-config (timeout=8h, worktree namespace .worktree / worktree)"
fi
```

**3.5d — verify shipped scripts.** The worktree/integrity scripts ship in the plugin and
are invoked by both the legacy and workflow paths. Verify availability:

```bash
for s in skills/clean-checkout-before-task/bin/clean-checkout.sh \
         skills/integrate-lpcas/bin/integrate-lpcas.sh \
         skills/whip-doctor/bin/doctor.sh \
         skills/lib/acfw-git.sh; do
  [ -f "${CLAUDE_PLUGIN_ROOT}/$s" ] || echo "WARN: missing ${CLAUDE_PLUGIN_ROOT}/$s — concurrency/integrity will not work." >&2
done
```

### Step 4: Install Quality Gate Configuration

**Install pre-commit configuration** (skip if `.pre-commit-config.yaml` exists):

| Stack | Pre-commit Config Source | Quality Gates Doc Source | Destination |
|-------|-------------------------|-------------------------|-------------|
| **Go** | `${CLAUDE_PLUGIN_ROOT}/content/pre-commit-configs/.pre-commit-config-go.yaml` | `${CLAUDE_PLUGIN_ROOT}/content/quality-gates/go.md` | `.pre-commit-config.yaml`, `docs/development/quality-gates-go.md` |
| **Python** | `${CLAUDE_PLUGIN_ROOT}/content/pre-commit-configs/.pre-commit-config-python.yaml` | `${CLAUDE_PLUGIN_ROOT}/content/quality-gates/python-fastapi.md` | `.pre-commit-config.yaml`, `docs/development/quality-gates-python.md` |
| **Node.js** | `${CLAUDE_PLUGIN_ROOT}/content/pre-commit-configs/.pre-commit-config-nodejs.yaml` | `${CLAUDE_PLUGIN_ROOT}/content/quality-gates/nextjs-typescript.md` | `.pre-commit-config.yaml`, `docs/development/quality-gates-nodejs.md` |

Use Read/Write tool sequence for each file. Create `docs/development/` directory if missing (bash mkdir -p).

### Step 5: Initialize Core Documentation

**Install core docs** (Read/Write, skip if exists):

| File | Source | Destination |
|------|--------|-------------|
| **Task style guide** | `${CLAUDE_PLUGIN_ROOT}/content/style/task-descriptions.md` | `docs/acf/style/task-descriptions.md` |
| **Research style guide** | `${CLAUDE_PLUGIN_ROOT}/content/style/research-documents.md` | `docs/acf/style/research-documents.md` |
| **Task template** | `${CLAUDE_PLUGIN_ROOT}/content/backlog/task-template.md` | `docs/acf/backlog/task-template.md` |
| **Workflow** | `${CLAUDE_PLUGIN_ROOT}/content/backlog/workflow.md` | `docs/acf/backlog/workflow.md` |
| **Recovery runbook** | `${CLAUDE_PLUGIN_ROOT}/content/backlog/recovery-runbook.md` | `docs/acf/backlog/recovery-runbook.md` |
| **Research protocol** | `${CLAUDE_PLUGIN_ROOT}/content/acf/research-protocol.md` | `docs/acf/research-protocol.md` |

Create directories if missing.

### Step 5.5: Repository Analysis for Agent Customization

Collect project data before generating agents:

```bash
# Tech stack: From Step 1 (backend, frontend, frameworks)
# Project: project_name=$(basename $(pwd))
# Structure: services/|packages/ → is_monorepo=true | services/ + multiple → has_microservices=true | kafka|rabbitmq|pulsar|nats → has_event_driven=true
# Quality tools: Extract from .pre-commit-config.yaml → quality_tools list
# Coverage/Priority: From Step 2 user selection
# Database: postgres|psycopg|pg → "postgresql" | mongo → "mongodb"
# Doc paths: docs/acf/backlog/task-template.md, docs/development/quality-gates-{stack}.md, docs/acf/backlog/workflow.md

# DevOps-specific (if create_devops=true):
# Monitoring: prometheus.yml|docker-compose.yml → "prometheus-grafana" | datadog → "datadog" | newrelic → "newrelic" | has_k8s → "prometheus-grafana"
# Cloud: terraform/ → google|gcp|gke → "gke" | aws|eks → "eks" | azure|aks → "aks" | skaffold.yaml → check for gke|eks | .github/workflows/ → check for gcloud|aws|azure
# Registry: gcr.io → "gcr" | ecr|amazonaws.com → "ecr" | azurecr.io → "acr" | docker.io|dockerhub → "dockerhub"
# Deployment: has_k8s → "kubernetes" | has_docker + swarm|stack → "docker-swarm" | has_docker → "docker-compose"
```

Store values for agent generation (Step 6).

### Step 6: Generate Universal Agents from Patterns

Create `.claude/agents/` directory if missing. **Generate** 6-7 agents from patterns in `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/universal/{agent}-pattern.md`:

**Always generate**: task-engineer, quality-reviewer, lean-architect, precommit, retro, research-agent
**Conditional**: devops (if `create_devops=true`)

**Customization variables per agent**:

| Agent | Template Variables | Examples |
|-------|-------------------|----------|
| **task-engineer** | `{backend_stack}`, `{frontend_stack}`, `{backend_agent}`, `{frontend_agent}`, `{priority_system}`, `{database_stack}`, `{type_signature_example}`, `{bad_example_code}` | go-engineer, 3-level, postgresql, Go type signatures |
| **quality-reviewer** | `{backend_stack}`, `{frontend_stack}`, `{coverage_threshold}`, `{api_coverage}`, `{core_coverage}`, `{backend_linter}`, `{backend_test_runner}`, `{frontend_linter}` | Coverage 80% → api 90-95%, golangci-lint, go test |
| **lean-architect** | `{backend_stack}`, `{frontend_stack}`, `{database_stack}`, `{infrastructure}`, `{has_microservices}`, `{has_event_driven}`, `{project_name}` | kubernetes, microservices=true |
| **precommit** | `{backend_stack}`, `{frontend_stack}`, `{backend_linter}`, `{backend_formatter}`, `{pre_commit_config_path}` | golangci-lint, gofmt, .pre-commit-config.yaml |
| **retro** | `{project_name}`, `{retrospective_frequency}`, `{has_sla_priorities}` | weekly, sla=true if 5-level |
| **research-agent** | `{project_name}` | Replace project references |
| **devops** | `{LOCAL_ORCHESTRATION}`, `{DEPLOYMENT_TARGET}`, `{CI_TOOL}`, `{MONITORING_STACK}`, `{CLOUD_PROVIDER}`, `{HAS_K8S}`, `{PROJECT_NAME}`, `{ORCHESTRATION_RESPONSIBILITY}`, `{K8S_DELEGATION_SECTION}` | docker-compose, github-actions, prometheus-grafana, gke |

**Coverage threshold logic**: 95% → api 95-98%, core 95% | 80% → api 90-95%, core 90% | 60% → api 75-80%, core 70%

Write generated agents to `.claude/agents/{agent}.md`.

### Step 6.5: Generate Specialized Agents (if --with-specialists flag)

**Check if `--with-specialists` flag is present**:

```bash
if [[ "$*" == *"--with-specialists"* ]]; then
    echo "🚀 --with-specialists flag detected - generating specialized agents..."
    with_specialists=true
else
    echo "📋 Universal agents only (use --with-specialists for auto-generation)"
    with_specialists=false
fi
```

**If `with_specialists=true`**, auto-generate specialized agents based on Step 1 tech stack detection:

**Backend Specialist Mapping**:

| Detection | Agent Created | Template | Output |
|-----------|--------------|----------|--------|
| `backend="python"` | python-engineer | `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/specialist/backend-agent-pattern.md` | `.claude/agents/python-engineer.md` |
| `backend="go"` | go-engineer | `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/specialist/backend-agent-pattern.md` | `.claude/agents/go-engineer.md` |
| `backend="nodejs"` | nodejs-engineer | `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/specialist/backend-agent-pattern.md` | `.claude/agents/nodejs-engineer.md` |

**Frontend Specialist Mapping**:

| Detection | Agent Created | Template | Output |
|-----------|--------------|----------|--------|
| `frontend="nextjs"` | nextjs-engineer | `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/specialist/frontend-agent-pattern.md` | `.claude/agents/nextjs-engineer.md` |
| `frontend="react"` | react-engineer | `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/specialist/frontend-agent-pattern.md` | `.claude/agents/react-engineer.md` |
| `frontend="vue"` | vue-engineer | `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/specialist/frontend-agent-pattern.md` | `.claude/agents/vue-engineer.md` |

**Infrastructure Specialist Mapping**:

| Detection | Agent Created | Template | Output |
|-----------|--------------|----------|--------|
| `has_k8s=true` OR `has_docker=true` | infrastructure-engineer | `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/specialist/infrastructure-agent-pattern.md` | `.claude/agents/infrastructure-engineer.md` |

**Template Variable Replacements**:

**For backend agents** (python/go/nodejs):
- `{stack}` → detected backend value ("python", "go", "nodejs")
- `{language}` → language name ("Python", "Go", "Node.js")
- `{framework}` → framework examples:
  - Python: "FastAPI, Django, Flask"
  - Go: "Gin, Echo, Chi"
  - Node.js: "Express, Fastify, NestJS"
- `{linter}` → linter tools:
  - Python: "ruff" (or "pylint" if .pre-commit-config has pylint)
  - Go: "golangci-lint"
  - Node.js: "eslint"
- `{formatter}` → formatter tools:
  - Python: "ruff format" (or "black")
  - Go: "gofmt"
  - Node.js: "prettier"
- `{test-runner}` → test frameworks:
  - Python: "pytest"
  - Go: "go test"
  - Node.js: "jest" (or "vitest")
- `{type-checker}` → type checking tools:
  - Python: "mypy"
  - Go: "built-in"
  - Node.js: "tsc" (TypeScript)

**For frontend agents** (nextjs/react/vue):
- `{stack}` → detected frontend value ("nextjs", "react", "vue")
- `{framework}` → framework name ("Next.js", "React", "Vue.js")
- `{build-tool}` → build tools:
  - Next.js: "next build"
  - React: "vite" (or "webpack")
  - Vue: "vite" (or "vue-cli")
- `{linter}` → "eslint"
- `{formatter}` → "prettier"
- `{test-runner}` → "vitest" (or "jest")

**For infrastructure agent**:
- `{orchestration}` → detected_orchestration ("docker-compose", "kubernetes", "docker-swarm")
- `{deployment_target}` → deployment environment from Step 5.5
- `{cloud_provider}` → detected cloud ("gke", "eks", "aks", "none")
- `{ci_tool}` → detected_ci_tool ("github-actions", "gitlab-ci", "circleci", "jenkins")
- `{monitoring_stack}` → detected monitoring ("prometheus-grafana", "datadog", "newrelic")

**Generation Process**:
1. Read template from `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/specialist/{type}-agent-pattern.md`
2. Replace all template variables with detected values
3. Write customized agent to `.claude/agents/{stack}-engineer.md`
4. Store created specialist list for Step 7 manifest generation

**Tracking for Step 7**:
```bash
# Store created specialists in array
created_specialists=()

if [ "$backend" != "" ]; then
  created_specialists+=("${backend}-engineer")
fi

if [ "$frontend" != "" ]; then
  created_specialists+=("${frontend}-engineer")
fi

if [ "$has_docker" = true ] || [ "$has_k8s" = true ]; then
  created_specialists+=("infrastructure-engineer")
fi

echo "✅ Created ${#created_specialists[@]} specialized agents: ${created_specialists[*]}"
```

**Result**: 1-3 specialized agents generated automatically based on tech stack, ready for manifest generation in Step 7.

---

### Step 6.75: Check Documentation Index

**Check for docs/README.md as documentation hub**:

If `docs/README.md` exists, read it to discover available documentation. Otherwise fall back to directory scanning.

```bash
# Check if project has a documentation index
has_docs_index=false

if [ -f "docs/README.md" ]; then
  echo "📋 Found docs/README.md - using as documentation index"
  echo "   Claude will read this file to discover available documentation"
  has_docs_index=true
else
  echo "📂 No docs/README.md found - will scan directories for documentation"
fi
```

**Result**: If docs/README.md exists, Claude reads it and naturally understands what documentation is available. Otherwise, falls back to directory scanning in Step 7.

---

### Step 7: Generate Agent Manifests

Create `docs/agents/` directory. **Generate** manifests from patterns with Priority 1/2/3 structure:

**Process**: Read pattern → Extract agent section → Apply customizations → Write to `docs/agents/{agent}.md`

**Documentation discovery**: Claude reads docs/README.md (if exists) or scans standard directories.

#### Universal Agent Manifests (Always Created)

**Generate 6-7 universal manifests**:

**Template**: `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/manifests/universal-manifest-pattern.md` or `devops-manifest-pattern.md`

| Manifest | Customizations |
|----------|----------------|
| **All** | Replace `{stack}` with detected stacks, update quality gates paths: `docs/development/quality-gates-{backend_stack}.md` |
| **task-engineer** | Update Priority 1 docs, match project structure |
| **quality-reviewer** | Coverage thresholds from Step 2, quality gates for detected stacks, backend/frontend sections |
| **lean-architect** | Priority 2 docs from project, add microservices/event-driven if detected |
| **precommit** | Reference `.pre-commit-config.yaml` from Step 4 |
| **retro** | SLA compliance metrics if 5-level priorities |
| **research-agent** | Project name |
| **devops** | `{CONDITIONAL_DOCS_P1}` from docs/operations/ scan (deployment.md, monitoring.md, environment.md, troubleshooting.md), `{CONDITIONAL_DOCS_P2}` from docs/operations/ci-cd.md + docs/architecture/service-architecture.md + docs/development/local-development.md, `{CONDITIONAL_QUALITY_GATES}` based on detected_orchestration (docker-compose/k8s validation), infrastructure values from Step 5.5, `{CURRENT_DATE}` |

#### Specialist Agent Manifests (If --with-specialists)

**If `with_specialists=true` (from Step 6.5)**, generate manifests for created specialists:

**Process**: For each specialist in `created_specialists[]` array:
1. Read appropriate template:
   - Backend specialists: `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/manifests/backend-manifest-pattern.md`
   - Frontend specialists: `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/manifests/frontend-manifest-pattern.md`
   - Infrastructure specialist: `${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/manifests/infrastructure-manifest-pattern.md`
2. Replace template variables with project-specific values
3. Write to `docs/agents/{stack}-engineer.md`

**Specialist Manifest Templates**:

| Specialist | Template | Variables Replaced |
|-----------|----------|-------------------|
| **python-engineer** | backend-manifest-pattern.md | `{stack}=python`, `{language}=Python`, `{framework}=FastAPI/Django/Flask`, `{linter}=ruff`, `{test_runner}=pytest`, `{type_checker}=mypy`, quality gates path |
| **go-engineer** | backend-manifest-pattern.md | `{stack}=go`, `{language}=Go`, `{framework}=Gin/Echo/Chi`, `{linter}=golangci-lint`, `{test_runner}=go test`, `{type_checker}=built-in`, quality gates path |
| **nodejs-engineer** | backend-manifest-pattern.md | `{stack}=nodejs`, `{language}=Node.js`, `{framework}=Express/Fastify/NestJS`, `{linter}=eslint`, `{test_runner}=jest`, `{type_checker}=tsc`, quality gates path |
| **nextjs-engineer** | frontend-manifest-pattern.md | `{stack}=nextjs`, `{framework}=Next.js`, `{build_tool}=next build`, `{linter}=eslint`, `{formatter}=prettier`, `{test_runner}=vitest`, quality gates path |
| **react-engineer** | frontend-manifest-pattern.md | `{stack}=react`, `{framework}=React`, `{build_tool}=vite`, `{linter}=eslint`, `{formatter}=prettier`, `{test_runner}=vitest`, quality gates path |
| **vue-engineer** | frontend-manifest-pattern.md | `{stack}=vue`, `{framework}=Vue.js`, `{build_tool}=vite`, `{linter}=eslint`, `{formatter}=prettier`, `{test_runner}=vitest`, quality gates path |
| **infrastructure-engineer** | infrastructure-manifest-pattern.md | `{orchestration}`, `{deployment_target}`, `{cloud_provider}`, `{ci_tool}`, `{monitoring_stack}` from Step 5.5, quality gates path |

**Additional customizations for all specialist manifests**:
- Priority 1 docs: Link to quality gates (`docs/development/quality-gates-{stack}.md`)
- Priority 2 docs: Link to architecture docs if they exist
- Replace project-specific paths discovered via docs/README.md scan

**Tracking**:
```bash
echo "✅ Generated ${#created_specialists[@]} specialist manifests: ${created_specialists[*]}"
```

**Result**: 6-7 universal manifests + 0-3 specialist manifests (if flag used), all with 58-74% token reduction, deeply customized for existing docs and tech stack.

### Step 8: Generate .backlog/README.md

Trigger README generation with installed agents:
```bash
# SessionStart hook pattern
# Scans .claude/agents/*.md
# Replaces {{IMPLEMENTER_AGENTS}} in template
# Writes customized .backlog/README.md
```

### Step 8.25: Initialize CLAUDE.md if Missing

**Purpose**: Ensure CLAUDE.md exists before adding ACF workflow sections in Steps 8.5 and 9.

**Detection**:
```bash
if [ -f "CLAUDE.md" ]; then
    echo "✓ CLAUDE.md found - will enhance with ACF workflow sections"
    claude_md_created=false
else
    echo "📝 CLAUDE.md not found - creating minimal AI instructions file"
    claude_md_created=true
fi
```

**If CLAUDE.md is missing**, create minimal template:

**Implementation**:
1. Get project name: `project_name=$(basename $(pwd))`
2. Read ACF definition from distribution CLAUDE.md (lines 3-5)
3. Generate template content
4. Write to `CLAUDE.md` using Write tool

**Minimal CLAUDE.md template**:
```markdown
# {PROJECT_NAME} - AI Assistant Instructions

## Agentic Continuous Flow (ACF)

**ACF is software development for a world where intelligence exists in silicon as well as carbon.** Humans shift from writing code to governing intelligent agent swarms. Knowledge (ontologies, policies, constraints) becomes the product; code is ephemeral output regenerated on demand. Work flows through multi-dimensional risk evaluation - low-risk tasks execute autonomously, high-risk tasks trigger human review. Systems emerge from agent interactions within knowledge boundaries rather than being engineered top-down. The fundamental inversion: humans govern, agents execute.

---
```

**Template variables**:
- `{PROJECT_NAME}`: Directory basename (`$(basename $(pwd))`)

**Design rationale**:
- **Project header**: Establishes context for AI assistant
- **ACF definition**: Core philosophy (verbatim from distribution CLAUDE.md)
- **Separator**: Clean break before workflow sections (Steps 8.5, 9)
- **Minimal**: No repository metadata, license, or contact info (user can add later)

**Output**:
- If created: `✓ Created CLAUDE.md with minimal AI instructions`
- If exists: `✓ CLAUDE.md found - will enhance with ACF workflow sections`

**Result**: CLAUDE.md guaranteed to exist before Steps 8.5 and 9.

---

### Step 8.5: Generate CLAUDE.md Pure Delegation Section

**Check if "## Pure Delegation Architecture" section exists**:

```bash
if grep -q "## Pure Delegation Architecture" CLAUDE.md; then
    echo "✓ Pure Delegation section already exists - skipping"
else
    echo "📝 Adding Pure Delegation Architecture section to CLAUDE.md..."
fi
```

**If section is missing**, append:

```markdown
---
## Pure Delegation Architecture

**CRITICAL**: General-purpose agent does ORCHESTRATION ONLY (never implements code).

**General agent role**: Task decomposition, coordination, status tracking, quality enforcement
**General agent CANNOT**: Write/modify/fix/refactor code

### Specialist Agent Matrix
| Domain | Agent | Responsibilities |
|--------|-------|------------------|
{AGENT_MATRIX_ROWS}

### Delegation Protocol
1. Receive request → Analyze domain
2. Select specialist → Choose from matrix
3. Delegate with context → WHAT/WHY only, docs refs, quality criteria
4. Coordinate → Track progress, enforce gates
5. Never bypass → Use `/whip-add-agents` if no specialist

**Enforcement**: Pre-tool-use hook validates code mods only from specialists. Violations = rejection.
**Speedup**: 3x+ through parallel execution, eliminates context pollution.
```

**Generate {AGENT_MATRIX_ROWS}** from created agents:

**Universal agents** (always included):
```bash
# Universal: Core/task-engineer, Quality/quality-reviewer, Architecture/lean-architect, Quality/precommit, Process/retro, Research/research-agent
# DevOps: Infrastructure/devops/{detected_orchestration}, CI/CD ({detected_ci_tool}), monitoring (if create_devops=true)
```

**Specialist agents** (conditional based on `--with-specialists` flag):
```bash
# If with_specialists=true:
#   - Backend/{backend_stack}-engineer (from created_specialists[])
#   - Frontend/{frontend_stack}-engineer (from created_specialists[])
#   - Infrastructure/infrastructure-engineer (from created_specialists[] if has_docker or has_k8s)
# If with_specialists=false:
#   - Backend/{backend_stack}-engineer (TBD via /whip-add-agents)
#   - Frontend/{frontend_stack}-engineer (TBD via /whip-add-agents)
```

**Matrix generation logic**:
1. Always add 6-7 universal agent rows
2. If `with_specialists=true`: Add rows for each specialist in `created_specialists[]` array with "✓" prefix
3. If `with_specialists=false`: Add rows with "(TBD via /whip-add-agents)" suffix
4. Replace delegation protocol step 5 based on specialist status:
   - If `with_specialists=true`: "Never bypass → All specialists installed, use appropriate agent"
   - If `with_specialists=false`: "Never bypass → Use `/whip-add-agents` if no specialist"

### Step 9: Add CLAUDE.md Backlog Workflow Section

**Check if "## Backlog Workflow" section exists**:

```bash
if grep -q "## Backlog Workflow" CLAUDE.md; then
    echo "✓ Backlog Workflow section already exists - skipping"
else
    echo "📝 Adding Backlog Workflow section to CLAUDE.md..."
fi
```

**If section is missing**, append:

```markdown
## Backlog Workflow

ACF Whip active. State machine: `pending → in-progress → completed → in-review → [accepted|rejected]` (blocked/retry paths exist).

**Commands**: `/task` (decompose), `/go` (execute all), `/whip-doctor` (backlog integrity check; `--fix` auto-repairs), `/retro` (improvement), `/whip-add-agents` (create specialists)

**Core Docs**: `docs/acf/backlog/workflow.md`, `docs/acf/backlog/recovery-runbook.md`, `docs/acf/backlog/task-template.md`, `docs/acf/style/task-descriptions.md`, `.backlog/README.md`

**Universal Agents**: task-engineer (WHAT/WHY only), quality-reviewer (accept/reject), lean-architect (design, max 2-3 line snippets), retro, precommit, research-agent (Perplexity/Context7)

**Quality Gates**: `docs/development/quality-gates-{stack}.md` | **Zero Bypass Tolerance**: No `--no-verify`, no skipping.

**Next Steps**: 1) `/whip-add-agents` for specialists, 2) `/task` to decompose scope, 3) `/go` for execution
```

### Step 9.5: Gap Analysis and Recommendations

Compare expected state (Steps 1-9) with actual state on disk:

```bash
# 1. Check Universal Agents: expected_agents=(task-engineer quality-reviewer lean-architect precommit retro research-agent [+devops]) → missing_agents=[]
# 2. Check Manifests: docs/agents/{agent}.md → missing_manifests=[]
# 3. Check Core Docs: docs/acf/style/task-descriptions.md, docs/acf/backlog/task-template.md, docs/acf/backlog/workflow.md, docs/acf/backlog/recovery-runbook.md → missing_docs=[]
# 4. Check Quality Gates: .pre-commit-config.yaml, docs/development/quality-gates-{stack}.md → missing_quality_gates=[]
# 5. Check CLAUDE.md Sections (if exists): "## Pure Delegation Architecture", "## Backlog Workflow", devops in matrix (if create_devops=true) → missing_claude_sections=[], outdated_claude_sections=[]
```

**Generate gap report** (if gaps found):

```markdown
⚠️  Gap Analysis: Missing ACF Artifacts

🤖 Missing Universal Agents: {LIST} → Re-run /whip-init or generate from ${CLAUDE_PLUGIN_ROOT}/content/agent-patterns/universal/
📚 Missing Agent Manifests: {LIST} → Re-run /whip-init or /whip-add-agents (58-74% token reduction)
📖 Missing Core Documentation: {LIST} → Copy from ${CLAUDE_PLUGIN_ROOT}/content/
🎯 Missing Quality Gates: {LIST} → Install from ${CLAUDE_PLUGIN_ROOT}/content/pre-commit-configs/
📋 Missing CLAUDE.md Sections: {LIST} → Re-run /whip-init
🔄 Outdated CLAUDE.md Content: {LIST} → Update agent matrix or re-run /whip-init
```

**If no gaps**: `✅ No gaps detected - ACF Whip fully integrated`

### Step 10: Success Report

**Conditional reporting based on `--with-specialists` flag**:

```
✅ ACF Whip Initialized Successfully

📁 .backlog/: 9 state folders (draft, pending, in-progress, completed, in-review, blocked, rejected, accepted, archive)

📋 Core Docs: ✓ task-descriptions.md, ✓ research-documents.md, ✓ research-protocol.md, ✓ task-template.md, ✓ workflow.md, ✓ recovery-runbook.md, ✓ .backlog/README.md

👥 Universal Agents (customized for {stack}):
   ✓ task-engineer, quality-reviewer, lean-architect, retro, precommit, research-agent
{IF create_devops}   ✓ devops ({detected_orchestration}, {detected_ci_tool}, {detected_monitoring}, {detected_cloud}, {deployment_target})

{IF with_specialists}🎯 Specialized Agents (auto-generated from tech stack):
{IF with_specialists}   ✓ {created_specialists[]} ({backend_stack}, {frontend_stack}, {infrastructure})
{IF with_specialists}
{IF with_specialists}📊 Manifests (Priority 1/2/3, 58-74% token reduction): ✓ docs/agents/{6-7 universal + N specialists}.md
{IF NOT with_specialists}📊 Manifests (Priority 1/2/3, 58-74% token reduction): ✓ docs/agents/{6-7 agents}.md

{IF has_docs_index}📋 Documentation Hub: docs/README.md found → Agents will use it for discovery. Keep it updated.
{IF NOT has_docs_index}📂 Documentation: Scanning standard directories. 💡 Create docs/README.md to help agents discover ALL docs.

🎯 Quality Gates: ✓ .pre-commit-config.yaml ({stack}), ✓ docs/development/quality-gates-{stack}.md | Coverage: {threshold}%, Max retries: {attempts}

📋 CLAUDE.md: {created|enhanced} with ✓ ACF definition{if_created}, ✓ Pure Delegation Architecture, ✓ Agent matrix ({total_agents} agents), ✓ Backlog Workflow, ✓ Enforcement: General agent CANNOT modify code

{IF NOT with_specialists}⚠️  Note: Universal agents only created. Specialized agents (python-engineer, react-engineer, etc.)
{IF NOT with_specialists}   are created via /whip-add-agents for better project customization.
{IF NOT with_specialists}
{IF NOT with_specialists}🚀 NEXT: Run /whip-add-agents to auto-generate {backend_stack}-engineer{IF frontend_stack}, {frontend_stack}-engineer{ENDIF}
{IF NOT with_specialists}
🚀 Next Steps:
{IF NOT with_specialists}1. /whip-add-agents (generate specialists for {stack})
{IF with_specialists}1. Review agents in .claude/agents/ and docs/agents/
2. /task "Scope description" (decompose)
3. /go (execute)

📚 Quick Reference: docs/acf/backlog/workflow.md, docs/acf/backlog/recovery-runbook.md, docs/acf/style/task-descriptions.md, docs/acf/backlog/task-template.md, .backlog/README.md, docs/agents/

💡 Key Features: Pattern-based generation (YOUR stack) | Deep manifest customization | Gap analysis on re-init | Pure Delegation (3x+ speedup){IF create_devops} | DevOps agent (infrastructure-aware){IF with_specialists} | Auto-specialist generation (--with-specialists)
```

## Command Options (Optional)

Allow optional flags for automation:

```bash
/whip-init --priority=5-level --coverage=95 --strict
```

**Flags**:
- `--priority=3-level|5-level` - Skip priority system question
- `--coverage=60|80|95` - Skip coverage threshold question
- `--strict` - Use aggressive quality gates (5 retry attempts)
- `--standard` - Use standard quality gates (10 retry attempts)
- `--with-specialists` - Auto-generate specialized agents based on tech stack detection (backend/frontend/infrastructure)

## Validation

Before completing, validate:
- ✅ All 9 .backlog/ folders exist
- ✅ CLAUDE.md exists (created or enhanced)
- ✅ 6 universal agents **generated** in .claude/agents/ (customized for project)
- ✅ 6 agent manifests **generated** in docs/agents/ (with Priority 1/2/3 structure)
- ✅ If `--with-specialists` flag used:
  - ✅ Specialist agents **generated** in .claude/agents/ (1-3 based on tech stack)
  - ✅ Specialist manifests **generated** in docs/agents/ (matching specialist count)
  - ✅ CLAUDE.md agent matrix includes specialists (not "TBD")
- ✅ Core docs exist in docs/acf/
- ✅ Quality gates configured for tech stack
- ✅ .backlog/README.md generated

**Generated files should contain project-specific customizations**, not generic templates.

## Error Handling

**If .backlog/ already exists**:
```
Warning: .backlog/ directory already exists.
Continue and overwrite? [y/N]
```

**If CLAUDE.md sections already exist**:
```
Note: CLAUDE.md sections already present. Skipping duplicate additions.
Re-running /whip-init is safe and idempotent.
```

**If tech stack not detected**:
```
Warning: Could not auto-detect tech stack.
Please specify manually: --backend=go|python|nodejs --frontend=react|nextjs
```

## Success Criteria

✅ .backlog/ structure created with 9 folders
✅ CLAUDE.md created or enhanced
✅ Universal agents installed (6-7 agents)
✅ Specialist agents installed (if --with-specialists flag used)
✅ Agent manifests generated (universal + specialists)
✅ Core documentation initialized
✅ Quality gates configured
✅ .backlog/README.md generated
✅ Validation passed
