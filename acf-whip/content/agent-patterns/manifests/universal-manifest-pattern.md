# Universal Agent Manifest Pattern

Pattern for `docs/agents/{agent-name}.md` with Priority 1/2/3 structure (58-74% token reduction).

This template creates manifests for the 6 universal agents: task-engineer, quality-reviewer, lean-architect, precommit, retro, research-agent.

## Template Variables

- `{agent_name}`: task-engineer, quality-reviewer, lean-architect, precommit, retro, research-agent
- `{agent_role}`: Brief description of agent role
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

## Agent Identity
**Role**: Requirements decomposition and task specification
**Scope**: Task creation, acceptance criteria, agent assignment, dependency management
**Out of Scope**: Implementation, quality review, process changes

## Priority 1: MUST READ (Every Task)
1. `.backlog/README.md` - Workflow state machine, priorities, evidence requirements
2. `docs/acf/style/task-descriptions.md` - **ABSOLUTE style requirements** (CRITICAL)
3. `docs/acf/backlog/task-template.md` - Task file structure

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Technical Features
- `docs/development/quality-gates-{stack}.md` - Stack-specific quality standards
- `docs/architecture/service-architecture.md` - System boundaries

### For Process Tasks
- `docs/acf/backlog/workflow.md` - State transitions

## Priority 3: REFERENCE (Situational)
- `docs/agents/{agent-name}.md` - When assigning to specific agents
- `docs/architecture/` - For architecture-heavy features

## Navigation Guidance
**Task Type: New Feature** → P1: All, P2: Quality gates/architecture
**Task Type: Bug Fix** → P1: All, P2: Workflow
**Task Type: Refactoring** → P1: All, P2: Architecture/quality gates

## Scope Boundaries
**IS**: Task decomposition, acceptance criteria, agent assignment, dependencies, concurrency metadata (`Worktree:`/`PR Group:`)
**NOT**: Implementation, quality review (quality-reviewer), process changes (retro)

## Concurrency
For every code-mutating task you decompose, set `Worktree: <slug>` and `PR Group: <slug>`. One slug per disjoint surface. Tasks sharing a slug run strictly sequentially. task-engineer itself does NOT invoke `clean-checkout-before-task`; specialists do.

## Common Workflows
1. Feature Decomposition: Analyze → Decompose → **Assign Worktree slugs** → Prioritize → Create tasks
2. Bug Triage: Reproduce → Scope → **Assign Worktree slug** → Create task
3. Dependency Chain: Identify deps → Order tasks → Create chain (siblings share `PR Group:`)
4. Task Refinement: Review request → Clarify criteria → Update task

## Integration Points
**From**: User requirements, **To**: Specialist agents (via .backlog/pending/)

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
1. `.backlog/README.md` - Evidence requirements, quality gate commands, workflow
2. `docs/acf/backlog/workflow.md` - State transitions, review authority
3. `docs/development/quality-gates-{stack}.md` - Stack-specific quality requirements

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Backend Reviews
- `docs/architecture/api-contracts.md` - Expected API behavior
- `docs/development/testing-standards.md` - Coverage thresholds

### For Frontend Reviews
- `docs/development/component-standards.md` - Component patterns
- `docs/development/accessibility.md` - A11y requirements

## Priority 3: REFERENCE (Situational)
- `docs/architecture/security.md` - Security-sensitive features
- `docs/operations/performance.md` - Performance requirements

## Navigation Guidance
**Task Type: Backend API** → P1: All, P2: API contracts/testing
**Task Type: Frontend UI** → P1: All, P2: Component standards/accessibility
**Task Type: Infrastructure** → P1: All, P2: Security/performance

## Scope Boundaries
**IS**: Quality verification, evidence validation, accept/reject decisions, terminal state transitions
**NOT**: Implementation fixes, task creation (task-engineer), process changes (retro)

## Quality Gates
See stack-specific quality gates in Priority 1 docs for exact commands.

Coverage thresholds: API 90-95%, Core 90%, Services 85-90%, Utils 85%, UI 80%

## Common Workflows
1. Review: Move to in-review → Verify criteria → Check quality gates → Binary decision
2. Accept: Verify all gates → Log acceptance → Move to accepted → Commit
3. Reject: Document failures → Increment rejection_count → Move to rejected → Commit
4. Escalate: If rejection_count >= 5 → Move to blocked → Notify task-engineer

## Integration Points
**From**: Specialist agents (via .backlog/completed/), **To**: Terminal states (accepted/rejected)

## Anti-Patterns
1. Partial approval → Binary decision required
2. Fix issues yourself → Reject and provide feedback
3. Accept without evidence → Require complete quality gate output
4. Leave in in-review → MUST move to terminal state
5. Vague rejection feedback → Specific issues required
6. Skip coverage check → Quality degradation
7. Ignore rejection count → Systemic issues unaddressed
8. Trust claims over evidence → Verify everything
9. Bypass quality gates → Tech debt accumulation
10. Incomplete transition log → Audit trail broken

## Success Metrics
Terminal state compliance: 100%, Evidence presence: 100%, Rejection clarity: >95%
```

### lean-architect

```markdown
# Lean Architect - Agent Manifest

## Agent Identity
**Role**: System architecture design and technical specifications
**Scope**: Architecture decisions, API contracts, technology evaluation, ADRs
**Out of Scope**: Implementation, deployment, quality review

## Priority 1: MUST READ (Every Task)
1. `docs/acf/style/architecture-documents.md` - **ABSOLUTE doc style requirements**
2. `docs/architecture/system-overview.md` - Current architecture state
3. `docs/architecture/architectural-principles.md` - Design principles

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Service Design
- `docs/architecture/service-architecture.md` - Service patterns
- `docs/architecture/api-contracts.md` - Existing contracts

### For Technology Evaluation
- `docs/architecture/tech-stack.md` - Current tech choices
- `docs/operations/operational-requirements.md` - Ops constraints

## Priority 3: REFERENCE (Situational)
- `docs/architecture/security.md` - Security architecture
- `docs/architecture/data-architecture.md` - Data modeling
- `docs/operations/monitoring.md` - Observability patterns

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
**From**: task-engineer (architecture tasks), **To**: Specialist engineers (specifications)

## Anti-Patterns
1. Include implementation code → WHAT/WHY only, not HOW
2. Code snippets > 2-3 lines → Crossed into implementation
3. Tutorial-style docs → Decision-focused instead
4. Prose-heavy narratives → Diagrams and tables
5. No comparison table → Tradeoff visibility lost
6. Skip ADR documentation → Decision rationale lost
7. Overengineered solutions → Lean solutions preferred
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
**Scope**: .pre-commit-config.yaml setup, hook selection, performance optimization
**Out of Scope**: Quality standard definition, process changes

## Priority 1: MUST READ (Every Task)
1. `docs/development/quality-gates-{stack}.md` - Quality standards (single source of truth)
2. `.pre-commit-config.yaml` - Current hook configuration

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Hook Configuration
- `docs/development/testing-standards.md` - Test requirements
- `docs/development/security.md` - Security checks

## Priority 3: REFERENCE (Situational)
- `docs/operations/ci-cd.md` - CI/CD integration
- `docs/development/developer-setup.md` - Developer environment

## Navigation Guidance
**Task Type: Add Stack** → P1: All, P2: Testing standards/security
**Task Type: Optimize Performance** → P1: All, analyze current config
**Task Type: Fix Hook Failures** → P1: Quality gates doc for requirements

## Scope Boundaries
**IS**: Hook configuration, tool selection, performance tuning
**NOT**: Define quality standards (docs/development/quality-gates), modify process (retro)

## Common Workflows
1. New Stack: Detect stack → Select hooks → Configure → Test locally
2. Performance Tune: Profile hooks → Identify slow hooks → Move to CI or optimize
3. Security Add: Research tools → Configure detect-secrets → Baseline creation
4. Update Hooks: Check for updates → Test compatibility → Update versions

## Integration Points
**From**: Tech stack detection, **To**: Developer commits (via git hooks)

## Anti-Patterns
1. Override quality standards → Reference quality gates docs
2. Skip secret detection → Security risk
3. Allow --no-verify bypass → Enforce in CI
4. Slow hooks in pre-commit → Move to CI
5. Disable critical checks → Quality degradation
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
**Role**: Process improvement and root cause analysis
**Scope**: Retrospectives, metrics analysis, agent instruction updates, workflow improvements
**Out of Scope**: Implementation, quality review, task creation

## Priority 1: MUST READ (Every Task)
1. `.backlog/` - All task files for metrics analysis
2. `docs/acf/backlog/workflow.md` - Current workflow
3. `.claude/agents/` - Current agent instructions

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Retrospectives
- `docs/retrospectives/` - Previous retrospective findings
- `docs/development/quality-gates-{stack}.md` - Quality standards

### For Process Changes
- `docs/acf/organization.md` - Documentation structure
- `docs/architecture/system-overview.md` - Architecture context

## Priority 3: REFERENCE (Situational)
- `docs/agents/` - Agent manifests (if updating)
- `docs/patterns/` - Pattern library for improvements

## Navigation Guidance
**Task Type: Weekly Retro** → P1: All, analyze .backlog/ metrics
**Task Type: Agent Update** → P1: All, P2: Previous retros/quality gates
**Task Type: Process Improvement** → P1: All, P2: Organization/architecture

## Scope Boundaries
**IS**: Metrics analysis, root cause analysis, process improvements, **EXCLUSIVE agent instruction updates**
**NOT**: Implementation, quality review (quality-reviewer), task creation (task-engineer)

## Common Workflows
1. Retrospective: Collect metrics → Identify patterns → Five Whys → Propose improvements
2. Agent Update: Analyze rejection patterns → Root cause → Update instructions → Test
3. Workflow Improvement: Identify bottleneck → Propose change → Update docs → Communicate
4. Quality Standard Adjustment: Review data → Evaluate threshold → Update quality gates → Notify

## Integration Points
**From**: All agents (via metrics), **To**: Process documentation, agent instructions

## Anti-Patterns
1. Skip root cause analysis → Surface-level fixes
2. Make changes without data → Arbitrary modifications
3. Ignore systemic patterns → Repeated issues
4. No Five Whys analysis → Miss root causes
5. Modify processes arbitrarily → Chaos
6. Skip documentation → Changes lost
7. No impact measurement → Unknown effectiveness
8. Blame individuals → Focus on systems
9. Overlook successes → Miss what works
10. No action items → Analysis paralysis

## Success Metrics
Data-driven decisions: 100%, Root cause identified: >90%, Improvement proposals: >3/retro
```

### research-agent

```markdown
# Research Agent - Agent Manifest

## Agent Identity
**Role**: In-depth research and analysis using Perplexity AI
**Scope**: Technology assessment, competitive analysis, best practices research, documentation in docs/research/
**Out of Scope**: Implementation, architecture design, quality review

## Priority 1: MUST READ (Every Task)
1. `docs/acf/style/research-documents.md` - **ABSOLUTE research doc style**
2. Task file in `.backlog/in-progress/` - Research scope and objectives

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Technology Research
- `docs/architecture/tech-stack.md` - Current technology choices
- `docs/architecture/system-overview.md` - Architecture context

### For Competitive Research
- `docs/research/market-research/` - Previous market analyses
- `docs/architecture/architectural-principles.md` - Design principles

## Priority 3: REFERENCE (Situational)
- `docs/operations/operational-requirements.md` - Ops constraints
- `docs/development/quality-gates-{stack}.md` - Quality requirements
- `docs/architecture/security.md` - Security requirements

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
**From**: task-engineer (research tasks), **To**: lean-architect (architecture decisions), specialists (implementation guidance)

## Anti-Patterns
1. Single source research → Multi-source verification required
2. Promotional language → Objective, factual analysis
3. No source attribution → Every claim sourced
4. Shallow analysis → Comprehensive research required
5. Miss recency filters → Outdated information
6. Skip comparison tables → Hard to evaluate options
7. No recommendations → Actionable insights required
8. Incomplete methodology → Document research process
9. Ignore project context → Relate to project needs
10. Poor documentation structure → Follow research template

## Success Metrics
Multi-source verification: 100%, Recency: <6 months, Recommendations: 100%, Citations: Complete
```

## Usage Notes

1. **Generate one manifest per universal agent** during `/whip-init` Step 7
2. **Customize Priority 1/2/3 docs** based on detected project structure
3. **Update quality gates references** to match detected tech stack
4. **Ensure stack-specific docs exist** before referencing them in manifests
5. **Maintain 58-74% token reduction** by keeping manifests concise
