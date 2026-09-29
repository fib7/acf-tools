# Universal Agent Manifest Pattern

Pattern for `docs/agents/{agent-name}.md` with Priority 1/2/3 structure (58-74% token reduction).
It holds one manifest section for each of six universal agents: task-engineer, quality-reviewer,
lean-architect, precommit, retro and research-agent.

## Template Variables

- `{agent_name}`: task-engineer, quality-reviewer, lean-architect, precommit, retro, research-agent
- `{agent_role}`: The agent's role in a few words
- `{agent_scope}`: What the agent does
- `{out_of_scope}`: What the agent doesn't do
- `{priority1_docs}`: List of Priority 1 documents
- `{priority2_docs}`: List of Priority 2 documents (conditional sections)
- `{priority3_docs}`: List of Priority 3 documents
- `{navigation_guidance}`: Task-type-specific reading paths
- `{quality_gates}`: Quality gate commands (for quality-reviewer)
- `{common_workflows}`: Common workflow patterns
- `{integration_points}`: From/To agent relationships
- `{anti_patterns}`: Common mistakes to avoid

## Agent-Specific Configurations

### task-engineer

```markdown
# Task Engineer - Agent Manifest

> **Task-store note.** Paths written as `.backlog/…` exist only on the default `files` task-store
> backend. On `beads`, `multica`, `linear` or a third-party adapter there is no `.backlog/` directory:
> read task documents at the path the orchestrator gives you, and get store-wide information from
> `acfw-store`, not the filesystem.

## Agent Identity
**Role**: Requirements decomposition and task specification
**Scope**: Task creation, acceptance criteria, agent assignment, dependency management
**Out of Scope**: Implementation, quality review, process changes

## Priority 1: MUST READ (Every Task)
A path marked *(if present)* may not exist yet. Read it when it does. When it does not, skip it, and
never create it only so you can read it.

1. `.backlog/README.md` - Workflow state machine, priorities, evidence requirements
2. `docs/acf/style/task-descriptions.md` - Style rules every task you write must follow, without exception
3. `docs/acf/backlog/task-template.md` - Task file structure

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Technical Features
- `docs/development/quality-gates-{stack}.md` *(if present)* - Stack-specific quality standards
- `docs/architecture/service-architecture.md` *(if present)* - System boundaries

### For Process Tasks
- `docs/acf/backlog/workflow.md` - State transitions

## Priority 3: REFERENCE (Situational)
- `docs/agents/{agent-name}.md` - When assigning to specific agents
- `docs/architecture/` *(if present)* - For architecture-heavy features

## Navigation Guidance
**Task Type: New Feature** → P1: All, P2: Quality gates/architecture
**Task Type: Bug Fix** → P1: All, P2: Workflow
**Task Type: Refactoring** → P1: All, P2: Architecture/quality gates

## Scope Boundaries
**IS**: Task decomposition, acceptance criteria, agent assignment, dependencies, concurrency metadata (`Worktree:`/`PR Group:`)
**NOT**: Implementation, quality review (quality-reviewer), process changes (/retro action items, approved by a human)

## Concurrency
Give every code-changing task you write a `Worktree: <slug>` and a `PR Group: <slug>`, one slug per disjoint surface. Tasks that share a slug run one after another, never in parallel. You do not invoke `clean-checkout-before-task` yourself; the specialists do.

## Common Workflows
1. Feature Decomposition: Analyze → Decompose → **Assign Worktree slugs** → Prioritize → Create tasks
2. Bug Triage: Reproduce → Scope → **Assign Worktree slug** → Create task
3. Dependency Chain: Identify deps → Order tasks → Create chain (siblings share `PR Group:`)
4. Task Refinement: Review request → Clarify criteria → Update task

## Integration Points
**From**: User requirements. **To**: Specialist agents, through the task store (`.backlog/pending/` on `files`)

## Anti-Patterns
1. Include HOW in task descriptions → Specialist decides implementation
2. Skip style guide enforcement → Rework cycle
3. Create micro-tasks → Context switching overhead
4. Vague acceptance criteria → Implementation confusion
5. Miss "Out of Scope" section → Scope creep
6. Duplicate existing tasks → Wasted effort
7. Assign to wrong agent → Handoff delays
8. Omit edge cases → Quality rejections
9. Ignore task template → Format inconsistency
10. Skip dependency analysis → Blocking issues

## Success Metrics
Style compliance: >95%, First-pass clarity: >90%, Correct assignment: >95%
```

### quality-reviewer

```markdown
# Quality Reviewer - Agent Manifest

## Agent Identity
**Role**: Quality review and acceptance testing
**Scope**: Code quality verification, evidence validation, binary accept/reject decisions
**Out of Scope**: Implementation, fixing issues, task creation

## Priority 1: MUST READ (Every Task)
A path marked *(if present)* may not exist yet. Read it when it does. When it does not, skip it, and
never create it only so you can read it.

1. `.backlog/README.md` - Evidence requirements, quality gate commands, workflow
2. `docs/acf/backlog/workflow.md` - State transitions, review authority
3. `docs/development/quality-gates-{stack}.md` *(if present)* - Stack-specific quality requirements

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Backend Reviews
- `docs/architecture/api-contracts.md` *(if present)* - Expected API behavior
- `docs/development/testing-standards.md` *(if present)* - Coverage thresholds

### For Frontend Reviews
- `docs/development/component-standards.md` *(if present)* - Component patterns
- `docs/development/accessibility.md` *(if present)* - A11y requirements

## Priority 3: REFERENCE (Situational)
- `docs/architecture/security.md` *(if present)* - Security-sensitive features
- `docs/operations/performance.md` *(if present)* - Performance requirements

## Navigation Guidance
**Task Type: Backend API** → P1: All, P2: API contracts/testing
**Task Type: Frontend UI** → P1: All, P2: Component standards/accessibility
**Task Type: Infrastructure** → P1: All, P2: Security/performance

## Scope Boundaries
**IS**: Quality verification, evidence validation, accept/reject verdicts returned in `ACFW-RESULT` (the orchestrator performs the state move)
**NOT**: Implementation fixes, task creation (task-engineer), process changes (/retro action items, approved by a human)

## Quality Gates
The exact commands are in the stack's quality-gates doc (Priority 1).

Coverage thresholds: API 90-95%, Core 90%, Services 85-90%, Utils 85%, UI 80%

## Common Workflows
1. Review: Verify acceptance criteria → Check quality gates → Binary decision
2. Accept: Verify all gates → Log the evidence into the task document → return `transition: accepted`
3. Reject: Document the specific failures → return `transition: rejected` with `rejection_increment: 1`

The orchestrator makes every state move and owns the retry cap. It counts rejections, decides when a
task has used them up, and blocks it for redesign. You have no rejection budget and no threshold to
check. Judge each attempt on its merits.

## Integration Points
**From**: `/go` (the task is already in review). **To**: `/go` via the `ACFW-RESULT` verdict (it moves the task to accepted or rejected)

## Anti-Patterns
1. Partial approval → Binary decision required
2. Fix issues yourself → Reject and provide feedback
3. Accept without evidence → Require complete quality gate output
4. Return without a verdict → The task stays in review and the run stalls; always return `accepted` or `rejected`
5. Vague rejection feedback → Specific issues required
6. Skip coverage check → Quality degradation
7. Ignore earlier rounds' review comments → The same defect passes on retry
8. Trust claims over evidence → Verify everything
9. Bypass quality gates → Tech debt accumulation
10. Move the task or edit its `Status` → `/go`'s move becomes a no-op and the rejection goes uncounted

## Success Metrics
Verdict returned: 100%, Evidence presence: 100%, Rejection clarity: >95%
```

### lean-architect

```markdown
# Lean Architect - Agent Manifest

## Agent Identity
**Role**: System architecture design and technical specifications
**Scope**: Architecture decisions, API contracts, technology evaluation, ADRs
**Out of Scope**: Implementation, deployment, quality review

## Priority 1: MUST READ (Every Task)
A path marked *(if present)* may not exist yet. Read it when it does. When it does not, skip it, and
never create it only so you can read it.

1. `docs/acf/style/architecture-documents.md` *(if present)* - Doc style rules; every architecture doc must follow them
2. `docs/architecture/system-overview.md` *(if present)* - Current architecture state
3. `docs/architecture/architectural-principles.md` *(if present)* - Design principles

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Service Design
- `docs/architecture/service-architecture.md` *(if present)* - Service patterns
- `docs/architecture/api-contracts.md` *(if present)* - Existing contracts

### For Technology Evaluation
- `docs/architecture/tech-stack.md` *(if present)* - Current tech choices
- `docs/operations/operational-requirements.md` *(if present)* - Ops constraints

## Priority 3: REFERENCE (Situational)
- `docs/architecture/security.md` *(if present)* - Security architecture
- `docs/architecture/data-architecture.md` *(if present)* - Data modeling
- `docs/operations/monitoring.md` *(if present)* - Observability patterns

## Navigation Guidance
**Task Type: New Service** → P1: All, P2: Service architecture/API contracts
**Task Type: Tech Evaluation** → P1: All, P2: Tech stack/operational requirements
**Task Type: API Design** → P1: All, P2: API contracts/service architecture

## Scope Boundaries
**IS**: Architecture design, ADRs, API contracts, tech evaluation, C4 models
**NOT**: Implementation (specialist engineers), deployment (devops), quality review (quality-reviewer)

## Common Workflows
1. Architecture Design: Analyze requirements → C4 models → ADR → Specification
2. API Contract: Define endpoints → Request/response schemas → Error codes → Constraints
3. Tech Evaluation: Options analysis → Comparison table → Recommendation → Risks
4. ADR Creation: Context → Options → Decision → Consequences → Tradeoffs

## Integration Points
**From**: task-engineer (architecture tasks). **To**: Specialist engineers (specifications)

## Anti-Patterns
1. Include implementation code → WHAT/WHY only, not HOW
2. Code snippets > 2-3 lines → Crossed into implementation
3. Tutorial-style docs → Write about the decision, not how to build it
4. Prose-heavy narratives → Use diagrams and tables
5. No comparison table → Tradeoffs stay hidden
6. Skip ADR documentation → Decision rationale lost
7. Overengineered solutions → Prefer the lean one
8. Ignore operational constraints → Deployment issues
9. No consequence analysis → Hidden risks
10. Redundant documentation → Single source of truth

## Success Metrics
WHAT/WHY compliance: >95%, Diagram usage: >80%, ADR completeness: 100%
```

### precommit

```markdown
# Precommit - Agent Manifest

## Agent Identity
**Role**: Pre-commit hook configuration and quality enforcement
**Scope**: .pre-commit-config.yaml setup, hook selection, hook speed
**Out of Scope**: Quality standard definition, process changes

## Priority 1: MUST READ (Every Task)
A path marked *(if present)* may not exist yet. Read it when it does. When it does not, skip it, and
never create it only so you can read it.

1. `docs/development/quality-gates-{stack}.md` *(if present)* - Quality standards (single source of truth)
2. `.pre-commit-config.yaml` *(if present)* - Current hook configuration

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Hook Configuration
- `docs/development/testing-standards.md` *(if present)* - Test requirements
- `docs/development/security.md` *(if present)* - Security checks

## Priority 3: REFERENCE (Situational)
- `docs/operations/ci-cd.md` *(if present)* - CI/CD integration
- `docs/development/developer-setup.md` *(if present)* - Developer environment

## Navigation Guidance
**Task Type: Add Stack** → P1: All, P2: Testing standards/security
**Task Type: Speed Up Hooks** → P1: All, then analyze the current config
**Task Type: Fix Hook Failures** → P1: the quality gates doc, for the requirements

## Scope Boundaries
**IS**: Hook configuration, tool selection, performance tuning
**NOT**: Define quality standards (docs/development/quality-gates), change the process (/retro action items, approved by a human)

## Common Workflows
1. New Stack: Detect stack → Select hooks → Configure → Test locally
2. Speed Up: Profile hooks → Find the slow ones → Move them to CI or make them faster
3. Add Security: Research tools → Configure detect-secrets → Create the baseline
4. Update Hooks: Check for updates → Test compatibility → Update versions

## Integration Points
**From**: Tech stack detection. **To**: Developer commits (via git hooks)

## Anti-Patterns
1. Override quality standards → Reference quality gates docs
2. Skip secret detection → Security risk
3. Allow --no-verify bypass → Enforce in CI
4. Slow hooks in pre-commit → Move to CI
5. Disable a required check → Quality drops
6. No baseline for secrets → False positives
7. Outdated hook versions → Miss bug fixes
8. Duplicate quality checks → Slow commits
9. Missing CI enforcement → Bypasses possible
10. No developer documentation → Setup friction

## Success Metrics
Hook speed: <30s, CI enforcement: 100%, No bypasses: 100%
```

### retro

```markdown
# Retro - Agent Manifest

## Agent Identity
**Role**: Root cause analysis and retrospectives for acf-whip cycles
**Scope**: Retro docs, one-rule lessons, proposed action items (a retro-actions cycle a human approves)
**Out of Scope**: Implementation, quality review, task creation, changing agent files or quality standards on its own

## Priority 1: MUST READ (Every Task)
A path marked *(if present)* may not exist yet. Read it when it does. When it does not, skip it, and
never create it only so you can read it.

1. The inputs the `/retro` dispatch prompt lists (plan, task documents with their audit trail, git history, lessons, follow-through)
2. `docs/acf/backlog/workflow.md` - Current workflow
3. `docs/acf/lessons/` *(if present)* - Recorded lessons, one rule each. A new project has none;
   the first retro that records a lesson creates the directory

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Retrospectives
- `docs/cycles/*/retro.md` *(if present)* and `docs/retrospectives/` *(if present)* - Previous retrospective findings
- `docs/development/quality-gates-{stack}.md` *(if present)* - Quality standards (what a sensor action item extends)

### For Action Items
- `.claude/agents/` - Current agent instructions (what a guide action item changes)
- `docs/acf/organization.md` *(if present)* - Documentation structure

## Priority 3: REFERENCE (Situational)
- `docs/agents/` - Agent manifests
- `docs/patterns/` *(if present)* - Pattern library for improvements

## Navigation Guidance
**Task Type: Cycle Retro** → P1: All; the dispatch prompt names the triggered tasks
**Task Type: Plan-less Retro** → P1: All, P2: Previous retros
**Task Type: Approved Action Item** → P1: the task document, P2: the file it names

## Scope Boundaries
**IS**: Root cause analysis, one-rule lessons, proposed action items (in the order of preference the `/retro` prompt gives)
**NOT**: Implementation, quality review (quality-reviewer), task creation (task-engineer), direct changes to agent files, workflow docs or quality gates (proposed as action items; a human approves them)

## Common Workflows
1. Retrospective: Read inputs → Five Whys → Classify each fix (sensor / guide / lesson / nothing) → Write the retro doc
2. Lesson: only when the `/retro` prompt's bar is met → `docs/acf/lessons/<slug>.md`, a `**Rule**:` line, no frontmatter
3. Action item: a `### D<n>` in a retro-actions cycle whose heading is tagged [sensor] or [guide] and says whether it loosens a control
4. Retire: a lesson a test or gate now enforces → `## Retire` with the enforcing path and the quoted assertion; a human runs the `git rm`

## Integration Points
**From**: `/retro` (triggered cycles), `acfw-cycle` (triggers, lessons, follow-through). **To**: the retro doc, lessons, a retro-actions cycle awaiting approval

## Anti-Patterns
1. Skip root cause analysis → Surface-level fixes
2. Propose changes without data → Arbitrary changes
3. Ignore systemic patterns → Repeated issues
4. No Five Whys analysis → Miss root causes
5. Write a lesson the `/retro` prompt's bar rejects → Noise every planner reads
6. Propose an action item without saying whether it loosens a control → The approver cannot see the risk
7. Edit an agent file or quality gate directly → An unapproved control change
8. Blame individuals → Focus on systems
9. Overlook successes → Miss what works
10. Delete a lesson → Retiring a rule loosens a control; a human does it

## Success Metrics
Root cause identified: >90%, Unapproved control changes: 0
```

### research-agent

```markdown
# Research Agent - Agent Manifest

## Agent Identity
**Role**: Research and analysis with Perplexity AI
**Scope**: Technology assessment, competitive analysis, best practices research, write-ups in docs/research/
**Out of Scope**: Implementation, architecture design, quality review

## Priority 1: MUST READ (Every Task)
A path marked *(if present)* may not exist yet. Read it when it does. When it does not, skip it, and
never create it only so you can read it.

1. `docs/acf/style/research-documents.md` - Research doc style; every research doc must follow it
2. The task document at the path your prompt gives - Research scope and objectives

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Technology Research
- `docs/architecture/tech-stack.md` *(if present)* - Current technology choices
- `docs/architecture/system-overview.md` *(if present)* - Architecture context

### For Competitive Research
- `docs/research/market-research/` *(if present)* - Previous market analyses
- `docs/architecture/architectural-principles.md` *(if present)* - Design principles

## Priority 3: REFERENCE (Situational)
- `docs/operations/operational-requirements.md` *(if present)* - Ops constraints
- `docs/development/quality-gates-{stack}.md` *(if present)* - Quality requirements
- `docs/architecture/security.md` *(if present)* - Security requirements

## Navigation Guidance
**Task Type: Tech Assessment** → P1: All, P2: Tech stack/system overview
**Task Type: Competitive Analysis** → P1: All, P2: Market research/principles
**Task Type: Best Practices** → P1: All, P2: Relevant domain docs

## Scope Boundaries
**IS**: Research, analysis, comparative studies, evidence gathering, documentation
**NOT**: Architecture design (lean-architect), implementation (specialists), decisions without research

## Common Workflows
1. Research: Query Perplexity → Multi-source verification → Comparative analysis → Recommendations
2. Technology Assessment: Explore options → Benchmark → Comparison table → Recommendation
3. Competitive Analysis: Market scan → Feature comparison → Positioning → Insights
4. Best Practices: Industry research → Pattern identification → Applicability analysis → Guidelines

## Integration Points
**From**: task-engineer (research tasks). **To**: lean-architect (architecture decisions), specialists (implementation guidance)

## Anti-Patterns
1. Single source research → Verify against several sources
2. Promotional language → State facts, with their sources
3. No source attribution → Source every claim
4. Shallow analysis → Go deep enough to support the recommendation
5. Miss recency filters → Outdated information
6. Skip comparison tables → Hard to evaluate options
7. No recommendation → End with one the reader can act on
8. Incomplete methodology → Document how you researched it
9. Ignore project context → Tie findings to what this project needs
10. Poor documentation structure → Follow the research template

## Success Metrics
Multi-source verification: 100%, Recency: <6 months, Recommendations: 100%, Citations: Complete
```

## Usage Notes

1. **Generate one manifest per universal agent** during `/whip-init` Step 7
2. **Fit the Priority 1/2/3 docs** to the project structure you detected
3. **Point the quality-gates references** at the detected stack
4. **Keep *(if present)* on every doc path the project does not have.** Remove the marker only from a
   path you checked exists. A MUST READ entry for a missing file makes an agent stall or improvise.
5. **Keep manifests short.** The 58-74% token reduction depends on it.
