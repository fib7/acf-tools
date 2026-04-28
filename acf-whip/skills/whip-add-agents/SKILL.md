---
name: whip-add-agents
description: Agent + Manifest Generator - Analyzes repository and creates missing specialist agents following ACF conventions
argument-hint: "[agent-types...]"
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - Grep
  - TodoWrite
  - Task
  - mcp__perplexity__perplexity_search_web
---

# /whip-add-agents - Agent + Manifest Generator

**CRITICAL**: This command CREATES NEW AGENTS, not just installs them.

Analyzes repository structure, detects missing specialist agents, and generates both agent implementation files AND comprehensive agent manifests following ACF agent subsystem conventions (58-74% token reduction pattern).

## Purpose

For each missing specialist agent:
1. **Create agent implementation**: `.claude/agents/{agent-name}.md` (small, core instructions)
2. **Create agent manifest**: `docs/agents/{agent-name}.md` (comprehensive, Priority 1/2/3 docs)
3. **Generate quality gates**: `docs/development/quality-gates-{stack}.md` (if missing)
4. **Update configuration**: `.backlog/README.md`, `CLAUDE.md` (if exists)

**User arguments take PRIORITY over auto-detection.**

---

## Execution Flow

### Step 1: Parse User Arguments (PRIORITY)

User arguments OVERRIDE auto-detection:

```bash
/whip-add-agents --backend=go --frontend=nextjs
/whip-add-agents --backend=python --data=dagster
/whip-add-agents --infrastructure=k8s
```

**Supported Flags**:
- `--backend=go|python|nodejs|rust`
- `--frontend=react|nextjs|vue|angular`
- `--data=dagster|bentoml|airflow`
- `--infrastructure=k8s|docker|terraform`
- `--specialized=temporal|event-bus|graphql`

If user provides flags, SKIP auto-detection and create those agents.

### Step 2: Repository Analysis (if no user args OR to supplement)

#### A. Codebase Exploration

Scan directory structure (depth 3-4 levels):

```bash
# Directory scan
tree -L 3 -d

# File type analysis
find . -type f -name "*.go" | wc -l
find . -type f -name "*.py" | wc -l
find . -type f -name "*.ts" -o -name "*.tsx" | wc -l
```

#### B. Tech Stack Indicators

**Backend Detection**:
```bash
# Go
if [ -f "go.mod" ]; then
  backend="go"
  # Check frameworks
  grep -q "github.com/gin-gonic/gin" go.mod && framework="gin"
  grep -q "github.com/labstack/echo" go.mod && framework="echo"
fi

# Python
if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ]; then
  backend="python"
  grep -q "fastapi" requirements.txt && framework="fastapi"
  grep -q "django" requirements.txt && framework="django"
  grep -q "langchain\|langgraph" requirements.txt && ml="true"
fi

# Node.js
if [ -f "package.json" ]; then
  grep -q '"fastify"\|"express"\|"@nestjs"' package.json && backend="nodejs"
fi
```

**Frontend Detection**:
```bash
if [ -f "package.json" ]; then
  grep -q '"next"' package.json && frontend="nextjs"
  grep -q '"react"' package.json && frontend="react"
  grep -q '"vue"' package.json && frontend="vue"
fi
```

**Data/ML Detection**:
```bash
# Dagster
[ -d "dagster" ] || grep -q "dagster" requirements.txt && data="dagster"

# BentoML
grep -q "bentoml" requirements.txt && ml_ops="bentoml"

# Airflow
grep -q "airflow" requirements.txt && data="airflow"
```

**Infrastructure Detection**:
```bash
# Kubernetes
[ -d "k8s" ] || [ -d "kubernetes" ] && infra="k8s"

# Docker Compose
[ -f "docker-compose.yml" ] && infra="docker"

# Terraform
[ -d "terraform" ] && infra="terraform"
```

#### C. Documentation & Configuration Analysis

**Check for documentation index and configuration**:

```bash
# Check if project has documentation hub
if [ -f "docs/README.md" ]; then
  echo "📋 Found docs/README.md - Claude will read it for documentation discovery"
fi

# Check CLAUDE.md for tech stack mentions
if [ -f "CLAUDE.md" ]; then
  echo "📋 Reading CLAUDE.md for project configuration..."
  grep -i "technology\|tech stack\|languages\|frameworks" CLAUDE.md
fi
```

**Note**: Claude reads these files naturally to understand project structure and tech stack.

#### D. Existing Agent Check

Scan `.claude/agents/` to avoid duplication:

```bash
existing_agents=$(ls -1 .claude/agents/*.md 2>/dev/null | xargs -n1 basename | sed 's/\.md$//')
```

#### E. Complexity Assessment

```bash
# Project size
total_files=$(find . -type f -name "*.go" -o -name "*.py" -o -name "*.ts" | wc -l)
total_loc=$(find . -type f \( -name "*.go" -o -name "*.py" -o -name "*.ts" \) -exec wc -l {} + | tail -1 | awk '{print $1}')

# Polyglot detection
languages=0
[ -f "go.mod" ] && languages=$((languages + 1))
[ -f "requirements.txt" ] && languages=$((languages + 1))
[ -f "package.json" ] && languages=$((languages + 1))

echo "Project size: $total_files files, $total_loc LOC"
echo "Languages detected: $languages"
```

#### F. Gap Analysis

Compare detected needs vs installed agents:

```bash
needs=()
[ -n "$backend" ] && ! echo "$existing_agents" | grep -q "${backend}-engineer" && needs+=("${backend}-engineer")
[ -n "$frontend" ] && ! echo "$existing_agents" | grep -q "${frontend}-engineer" && needs+=("${frontend}-engineer")
[ -n "$data" ] && ! echo "$existing_agents" | grep -q "${data}-engineer" && needs+=("data-engineer")
[ -n "$infra" ] && ! echo "$existing_agents" | grep -q "${infra}-engineer" && needs+=("${infra}-engineer")

echo "Missing agents: ${needs[@]}"
```

### Step 3: Study Existing Agent Conventions

#### A. Study Agent Implementation Patterns

Read existing agents in `.claude/agents/` (including universal agents from plugin):

```bash
# Extract patterns
grep "^---" .claude/agents/*.md -A 10  # YAML frontmatter structure
grep "## Core Responsibilities" .claude/agents/*.md -A 5
grep "## Authority" .claude/agents/*.md -A 10
grep "## MANDATORY" .claude/agents/*.md -A 3
```

**Extract Conventions**:
- YAML frontmatter fields (name, role, tech_stack, scope)
- Section headers and order
- Mandatory reading section format
- Scope boundaries format (IS/NOT Responsible For)
- Quality gates section format
- Common workflows format

#### B. Study Agent Manifest Patterns

Read existing manifests in `docs/agents/` (if any exist):

```bash
# Extract manifest structure
grep "## Priority 1:" docs/agents/*.md -A 20
grep "## Priority 2:" docs/agents/*.md -A 20
grep "## Navigation Guidance" docs/agents/*.md -A 10
grep "## Anti-Patterns" docs/agents/*.md -A 15
```

**Extract Conventions**:
- Priority 1/2/3 documentation lists
- Navigation guidance by task type
- Anti-patterns section (5-10 examples)
- Integration points format
- Quick reference format

#### C. Extract Stack-Specific Patterns

For target tech stack, research quality gate patterns:

```bash
# Use Perplexity for best practices
mcp__perplexity__perplexity_search_web:
  query: "{tech-stack} quality gates best practices linting testing coverage"
  recency: "month"

mcp__perplexity__perplexity_search_web:
  query: "{tech-stack} testing strategy unit integration e2e coverage thresholds"
  recency: "month"
```

### Step 4: Generate Agent Implementation Files

For each missing agent, create `.claude/agents/{agent-name}.md`:

#### Template Structure (Small File, Core Instructions)

```markdown
---
name: {agent-name}
description: {role-description}
model: sonnet
color: {color}
---

# {Agent Display Name}

## 🚨 MANDATORY FIRST STEP: Read Your Documentation

**CRITICAL**: Before executing ANY task, you MUST:

1. **Read your manifest**: `docs/agents/{agent-name}.md`
2. **Load Priority 1 documents** (listed in manifest)
3. **Follow navigation guidance** for task type
4. **Implement following workflows** (in manifest)
5. **Avoid anti-patterns** (in manifest)

## Role & Responsibility

{Concise description of what this agent does}

## Scope Boundaries

**IS Responsible For**:
- {capability 1}
- {capability 2}
- {capability 3}

**NOT Responsible For**:
- {out of scope 1} (delegate to {other-agent})
- {out of scope 2}

## Quality Gates

See manifest for complete quality gate requirements: `docs/agents/{agent-name}.md`

**Zero Bypass Tolerance**: All quality gates MUST pass before marking task complete.

**Stack-Specific Commands**:
```bash
{linter-command}
{formatter-command}
{type-checker-command}
{test-command}
{build-command}
```

## Integration Points

**Receives From**: {agent} via {handoff-mechanism}
**Delegates To**: {agent} for {scope}

## Workflow Protocol

**Step 0 (MANDATORY before any edit)**: Invoke the `clean-checkout-before-task` skill. It resolves the task's `Worktree:` slug, lazy-creates `.worktree/<slug>` on branch `worktree/<slug>`, validates the branch, stashes unrelated changes, and logs `clean-checkout: ok` to the task transition log. Without that token, quality-reviewer auto-rejects.

After Step 0 succeeds, all reads, edits, state moves, and commits happen inside the worktree on `worktree/<slug>`. Never commit on `main`.

1. Read Priority 1 docs from manifest
2. Load task-specific docs based on navigation guidance
3. Implement following manifest workflows
4. Run all quality gates
5. Provide evidence of completion
6. Update task status and commit (inside the worktree on `worktree/<slug>`)
```

#### Variable Replacement

**Backend Agent Example** (Go):
```yaml
name: go-engineer
description: Backend implementation specialist for Go services
tech_stack: [Go 1.23, Gin, PostgreSQL, Redis]
scope: Backend services, APIs, data persistence, business logic
```

**Frontend Agent Example** (React):
```yaml
name: react-engineer
description: Frontend implementation specialist for React applications
tech_stack: [React 18, TypeScript, Tailwind CSS, Zustand]
scope: UI components, state management, user interactions, client-side logic
```

#### Quality Gate Commands by Stack

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

**React**:
```bash
npm run lint
npm run typecheck
npm test -- --coverage
npm run build
```

**Next.js**:
```bash
pnpm lint
pnpm typecheck
pnpm test --coverage
pnpm build
```

### Step 5: Generate Agent Manifest Files

For each missing agent, create `docs/agents/{agent-name}.md`:

#### Template Structure (Comprehensive File, 58-74% Token Reduction)

Use plugin's agent pattern templates from `content/agent-patterns/manifests/`:
- `backend-manifest-pattern.md`
- `frontend-manifest-pattern.md`
- `data-manifest-pattern.md`
- `infrastructure-manifest-pattern.md`

**Core Structure**:

```markdown
# {Agent Name} - Agent Manifest

## Agent Identity

**Role**: {role-description}
**Tech Focus**: {primary-technologies}
**Scope**: {what-agent-handles}
**Out of Scope**: {what-agent-does-not-handle}

---

## Priority 1: MUST READ (Every Task)

Documents used in 80%+ of tasks:

1. **`.backlog/README.md`**
   - Why: Task workflow, state transitions, evidence requirements
   - When: Start of every task

2. **`docs/acf/style/task-descriptions.md`**
   - Why: Understanding task requirements (WHAT/WHY not HOW)
   - When: After receiving task, before implementation

3. **`docs/acf/backlog/task-template.md`**
   - Why: Task file structure, transition log format
   - When: Before marking complete, for evidence section

4. **`docs/development/quality-gates-{stack}.md`**
   - Why: Quality gate commands, coverage thresholds
   - When: Before marking complete, during evidence collection

5. **{Project-specific architecture docs}**
   - Why: System design, service boundaries, integration patterns
   - When: Before implementation, for context

---

## Priority 2: SHOULD READ (40-80% of Tasks)

Situational documents based on task type:

### For {Task Type 1}
- `{doc-path}` - {purpose}
- `{doc-path}` - {purpose}

### For {Task Type 2}
- `{doc-path}` - {purpose}
- `{doc-path}` - {purpose}

---

## Priority 3: REFERENCE (Situational, <40% of Tasks)

Use when specific scenarios encountered:

- `{doc-path}` - {when-to-use}
- `{doc-path}` - {when-to-use}

---

## Navigation Guidance

**Task Type**: {type-1}
**Reading Path**:
1. Priority 1: All docs
2. Priority 2: {specific-docs}
3. Reference: {specific-docs}

**Task Type**: {type-2}
**Reading Path**:
1. Priority 1: All docs
2. Priority 2: {specific-docs}
3. Reference: {specific-docs}

---

## Scope Boundaries

### IS Responsible For
- {Specific capability 1 with examples}
- {Specific capability 2 with examples}
- {Specific capability 3 with examples}

### NOT Responsible For
- {Out of scope 1} → Delegate to {other-agent}
- {Out of scope 2} → Delegate to {other-agent}

---

## Quality Gates (Stack-Specific)

### Code Quality
```bash
# Linting
{linter-command}

# Formatting
{formatter-command}

# Type Checking
{type-checker-command}
```

### Testing
```bash
# Unit Tests
{test-command}

# Coverage
{coverage-command}
```

**Coverage Thresholds**:
| Code Type | Threshold | Rationale |
|-----------|-----------|-----------|
| API endpoints | 90-95% | Customer-facing |
| Core logic | 90% | Business logic |
| Services | 85-90% | Integration points |
| Utilities | 85% | Support code |

### Build Verification
```bash
{build-command}
```

### Zero Bypass Tolerance

FORBIDDEN:
- `git commit --no-verify`
- `SKIP={hook-name}`
- Lowering coverage thresholds
- Commenting out failing tests

---

## Common Workflows

### Workflow 1: New Feature Implementation
1. Read Priority 1 docs
2. Read task requirements (WHAT/WHY)
3. Decide HOW to implement
4. Implement with tests
5. Run quality gates
6. Provide evidence, move to completed

### Workflow 2: Bug Fix
1. Read Priority 1 docs
2. Reproduce bug (write failing test)
3. Identify root cause
4. Implement fix
5. Verify test passes
6. Run quality gates, provide evidence

### Workflow 3: Refactoring
1. Read Priority 1 docs + testing strategy
2. Ensure comprehensive test coverage FIRST
3. Make incremental changes
4. Run tests after each change
5. Run quality gates, provide evidence

### Workflow 4: Quality Gate Failure
1. Attempt fix (max 10 attempts)
2. If systemic issue: Call /retro
3. If blocked: Move to blocked with report
4. NEVER bypass quality gates

### Workflow 5: Task Handoff to quality-reviewer
1. Complete all acceptance criteria
2. Run ALL quality gates (capture output)
3. Update evidence section with complete output
4. Move to .backlog/completed/
5. Commit: `task: complete {task-id}`

---

## Integration Points

### Receives Tasks From
- **task-engineer**: Task specifications in `.backlog/pending/`
  - Handoff: Task file with acceptance criteria
  - Expectations: WHAT/WHY specified, HOW is specialist's decision

### Delegates To
- **quality-reviewer**: Completed tasks in `.backlog/completed/`
  - Handoff: Task file with evidence
  - Expectations: All quality gates passed, evidence complete

- **lean-architect**: Architecture decisions beyond scope
  - Handoff: Request for architectural guidance
  - Expectations: WHAT/WHY documented

- **task-engineer**: When task too large or blocked
  - Handoff: Report in task notes
  - Expectations: Clear blocker description

### Collaborates With
- **{other-specialist-agents}**: Cross-stack features
  - Coordination: Via task dependencies

---

## Anti-Patterns

### 1. Implementing Without Reading Manifest
**Problem**: Missing critical context
**Why**: Leads to rework
**Solution**: ALWAYS read manifest first

### 2. Bypassing Quality Gates
**Problem**: Using `--no-verify`
**Why**: Technical debt, bugs in production
**Solution**: Fix actual issues

### 3. Insufficient Test Coverage
**Problem**: <80% coverage
**Why**: Untested code breaks
**Solution**: Write comprehensive tests

### 4. Vague Evidence
**Problem**: "All tests pass" without output
**Why**: quality-reviewer cannot verify
**Solution**: Provide complete command output

### 5. HOW Decisions in Task Descriptions
**Problem**: Asking task-engineer for implementation details
**Why**: Specialist decides HOW
**Solution**: Make implementation decisions independently

### 6. Working on Wrong Task State
**Problem**: Implementing tasks not in in-progress
**Why**: Breaks workflow tracking
**Solution**: Move to in-progress before starting

### 7. Forgetting Task File Updates
**Problem**: Not updating transition log
**Why**: Audit trail broken
**Solution**: Update log at every state change

### 8. Partial Completion
**Problem**: Some acceptance criteria unchecked
**Why**: quality-reviewer auto-rejects
**Solution**: ALL criteria checked before complete

### 9. Not Committing Task File
**Problem**: Code committed but task file not included
**Why**: Atomic commit violated
**Solution**: Include task file in commits

### 10. Ignoring "Out of Scope"
**Problem**: Implementing out-of-scope features
**Why**: Scope creep, duplicated work
**Solution**: Strictly adhere to scope

---

## Quick Reference

### Quality Gate One-Liner
```bash
{linter} && {formatter} && {type-checker} && {test-runner} && {build-command}
```

### Evidence Template
```markdown
## Evidence of Completion

### Quality Gates
```bash
$ {linter-command}
{expected-output}

$ {test-command}
{expected-output}

$ {build-command}
{expected-output}
```

### Test Coverage
```bash
$ {coverage-command}
{coverage-output}
```

### Git Status
```bash
$ git status
{clean-status}
```
```

### Task Transition Commands
```bash
# Start task
mv .backlog/pending/{task}.md .backlog/in-progress/

# Complete task
mv .backlog/in-progress/{task}.md .backlog/completed/

# Block task
mv .backlog/in-progress/{task}.md .backlog/blocked/
```

---

## Success Metrics

- **First-pass acceptance rate**: >85%
- **Priority 1 doc usage**: >80%
- **Quality gate pass rate**: >95%
- **Evidence completeness**: 100%

---

**Last Updated**: {date}
**Agent Version**: 1.0
**Manifest Maintained By**: retro agent
```

### Step 6: Generate Quality Gate Documentation (if missing)

If stack-specific quality gates don't exist:

Create `docs/development/quality-gates-{stack}.md`:

```markdown
# Quality Gates - {Stack}

## Zero Bypass Tolerance

**ABSOLUTE PROHIBITION**: The following bypasses are STRICTLY FORBIDDEN:
- `git commit --no-verify`
- `SKIP={hook-name}` in environment
- `git commit -n`
- Disabling pre-commit hooks
- Lowering coverage thresholds to pass builds
- Commenting out failing tests

**Enforcement**: CI MUST re-run all quality gates. Any bypass detected results in immediate rejection.

## Quality Requirements

### 1. Code Linting
```bash
{linter-command}
```

### 2. Code Formatting
```bash
{formatter-command}
```

### 3. Type Checking
```bash
{type-checker-command}
```

### 4. Testing
```bash
{test-command}
```

**Coverage Thresholds**:
| Code Type | Minimum Coverage |
|-----------|------------------|
| API endpoints | 90-95% |
| Core logic | 90% |
| Services | 85-90% |
| Utilities | 85% |

### 5. Build Verification
```bash
{build-command}
```

## Pre-commit Hooks

See `.pre-commit-config.yaml` for automated enforcement.

## Quality Gate Protocol

**Failure Handling**:
1. Attempts 1-10: Fix actual issues
2. After 10 attempts: Move task to blocked with failure report
3. If systemic issue (3+ similar failures): Run /retro

## Continuous Integration

CI MUST run all quality gates on every PR:
- Linting
- Type checking
- Full test suite with coverage
- Build verification

**No PR merges without passing all gates.**
```

### Step 7: Update Project Configuration

#### A. Update `.backlog/README.md`

Regenerate with new agent list:

```python
# Scan .claude/agents/
agents = glob(".claude/agents/*.md")
agent_names = [basename(a).replace(".md", "") for a in agents]

# Update README
template = read("${CLAUDE_PLUGIN_ROOT}/content/backlog/README.sample.md")
updated = template.replace("{{IMPLEMENTER_AGENTS}}", ", ".join(agent_names))
write(".backlog/README.md", updated)
```

#### B. Update `CLAUDE.md` (if exists)

Add new agents to agent assignment section:

```markdown
## Agent Assignments

### Implementation Agents

- **{agent-name}**: {scope-description}
  - Manifest: `docs/agents/{agent-name}.md`
  - Quality Gates: `docs/development/quality-gates-{stack}.md`
  - Tech Stack: {technologies}
```

#### C. Install Pre-commit Hooks (if not present)

```bash
if [ ! -f ".pre-commit-config.yaml" ]; then
  cp "${CLAUDE_PLUGIN_ROOT}/content/pre-commit-configs/.pre-commit-config-{stack}.yaml" .pre-commit-config.yaml
fi
```

### Step 8: Validation & Report

#### Validation Checks

1. **Agent file valid**:
```bash
# YAML frontmatter parses
head -10 .claude/agents/{agent}.md | grep "^---"

# Manifest reference present
grep "docs/agents/{agent}.md" .claude/agents/{agent}.md
```

2. **Manifest file valid**:
```bash
# Priority sections present
grep "## Priority 1:" docs/agents/{agent}.md
grep "## Priority 2:" docs/agents/{agent}.md
grep "## Priority 3:" docs/agents/{agent}.md

# Anti-patterns section has 5-10 examples
grep -c "^### [0-9]\\." docs/agents/{agent}.md
```

3. **Quality gate docs created**:
```bash
[ -f "docs/development/quality-gates-{stack}.md" ]
```

4. **Cross-references valid**:
```bash
# Agent references manifest
grep -q "docs/agents/{agent}.md" .claude/agents/{agent}.md

# Manifest references quality gates
grep -q "docs/development/quality-gates-{stack}.md" docs/agents/{agent}.md

# README lists agent
grep -q "{agent}" .backlog/README.md
```

#### Success Report

```
✅ Created {N} specialist agents + manifests

{For each agent created:}

📋 {agent-name}
   - Implementation: .claude/agents/{agent-name}.md
   - Manifest: docs/agents/{agent-name}.md
     ├── Priority 1: {N} docs (MUST READ)
     ├── Priority 2: {N} docs (SHOULD READ)
     ├── Priority 3: {N} docs (REFERENCE)
     ├── Navigation Guidance: {N} task types
     └── Anti-Patterns: {N} examples
   - Quality Gates: docs/development/quality-gates-{stack}.md
     ├── Linting: {linter-command}
     ├── Type Checking: {type-checker-command}
     ├── Testing: {test-command} (coverage: {threshold}%)
     └── Build: {build-command}
   - Tech Stack: {technologies}
   - Scope: {scope-description}

Updated Configuration:
  ✓ .backlog/README.md (agent list updated)
  ✓ CLAUDE.md (agent assignments added)
  ✓ .pre-commit-config.yaml ({stack})

Next Steps:
  1. Review generated agents in .claude/agents/
  2. Review manifests in docs/agents/
  3. Customize Priority 2/3 docs if needed
  4. Run /task to decompose work
  5. Run /go to execute backlog
```

---

## Usage Examples

### Auto-Detection

```bash
/whip-add-agents
```

Scans repo, detects Go + React + Kubernetes, creates:
- go-engineer
- react-engineer
- k8s-engineer

### User Specification (Priority)

```bash
/whip-add-agents --backend=python --frontend=nextjs
```

Skips detection, creates:
- python-engineer
- nextjs-engineer

### Mixed

```bash
/whip-add-agents --backend=go
```

Creates go-engineer per user request, then auto-detects other needs.

---

## Success Criteria

✅ Agent implementations created in `.claude/agents/`
✅ Agent manifests created in `docs/agents/` with Priority 1/2/3 structure
✅ Manifests include navigation guidance by task type
✅ Manifests include 5-10 anti-patterns with explanations
✅ Quality gate docs created for new stacks
✅ `.backlog/README.md` updated with new agents
✅ `CLAUDE.md` updated with agent assignments (if exists)
✅ Pre-commit hooks installed for new stacks
✅ All cross-references valid
✅ Validation passed

---

## Anti-Patterns

### ❌ Copying Without Customization

**Never**: Copy existing agent without adapting to tech stack
**Always**: Customize quality gates, tech stack, scope boundaries

### ❌ Missing Manifest

**Never**: Create agent implementation without manifest
**Always**: Create BOTH implementation AND manifest

### ❌ Generic Priority Docs

**Never**: List generic docs in Priority 1/2/3
**Always**: Specify actual project documentation paths

### ❌ Incomplete Anti-Patterns

**Never**: List anti-patterns without explanations
**Always**: Include Problem/Why/Solution for each

### ❌ Ignoring Existing Conventions

**Never**: Create agents with different structure than existing
**Always**: Study existing agents and follow conventions
