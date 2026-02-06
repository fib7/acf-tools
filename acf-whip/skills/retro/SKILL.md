---
name: retro
description: Conduct retrospective analysis of blocked/rejected tasks and create improvement tasks
allowed-tools:
  - Bash
  - Grep
  - Glob
  - Read
  - Task
  - TodoWrite
---

# /retro - Retrospective Analysis

Hostile retrospective command. Finds root causes of failures and creates tasks to fix them.

## Purpose

Two-phase process:
1. **Phase 1**: Launch retro agent for root cause analysis (Five Whys methodology)
2. **Phase 2**: Launch task-engineer to create improvement tasks based on findings

## Execution Flow

### Phase 1: Root Cause Analysis (retro agent)

Launch retro agent to:
1. Scan blocked/rejected/multi-attempt tasks in `.backlog/`
2. Apply Five Whys methodology to identify root causes
3. Detect systemic vs individual failures
4. Create comprehensive report in `docs/retrospectives/YYYYMMDD-topic.md`

**Analysis Scope**:
- `.backlog/blocked/*.md` - Blocked tasks
- `.backlog/rejected/*.md` - Rejected tasks
- `.backlog/accepted/*.md` - Tasks with rejection cycles (grep rejection_count > 1)
- Quality gate failure patterns
- Agent coordination failures

**Output**: Retrospective report with:
- Root cause analysis (Five Whys for each failure pattern)
- Systemic issues identified
- Instruction gaps detected
- Workflow bottlenecks
- Recommendations with priority levels

### Phase 2: Improvement Task Creation (task-engineer)

Launch task-engineer to:
1. Review retrospective report(s)
2. Create backlog tasks to address root causes:
   - **High priority**: Systemic failures, instruction gaps
   - **Medium priority**: Process improvements, workflow enhancements
   - **Low priority**: Technical debt, documentation gaps
3. Place tasks in `.backlog/pending/`

## Command Implementation

### Step 1: Verify Backlog Exists

```bash
if [ ! -d ".backlog" ]; then
  echo "Error: .backlog/ directory not found. Run /whip-init first."
  exit 1
fi
```

### Step 2: Scan for Failure Patterns

Count tasks in failure states:
```bash
blocked_count=$(ls -1 .backlog/blocked/*.md 2>/dev/null | wc -l)
rejected_count=$(ls -1 .backlog/rejected/*.md 2>/dev/null | wc -l)
```

If no failures found, report and exit:
```
No blocked or rejected tasks found. Retrospective not needed at this time.
```

### Step 3: Launch retro Agent for Analysis

Use Task tool with retro agent:

```markdown
**Task**: Conduct retrospective analysis of backlog failures

**Scope**:
- Analyze tasks in `.backlog/blocked/` and `.backlog/rejected/`
- Apply Five Whys methodology to identify root causes
- Detect systemic vs individual issues
- Check for instruction gaps in:
  - `docs/acf/style/task-descriptions.md`
  - `.backlog/README.md`
  - Agent manifests
  - Quality gates documentation
- Identify workflow bottlenecks
- Analyze agent coordination failures

**Deliverable**:
Create retrospective report in `docs/retrospectives/YYYYMMDD-topic.md` with:
1. Executive Summary (key findings)
2. Failure Analysis (by category)
3. Root Cause Analysis (Five Whys for each pattern)
4. Systemic Issues (vs individual mistakes)
5. Recommendations (prioritized)
6. Action Items (specific, measurable)
```

### Step 4: Wait for Analysis Completion

The retro agent will:
- Read all failure tasks
- Analyze patterns
- Create comprehensive report
- Update instruction documents if gaps found (retro has exclusive authority)

### Step 5: Launch task-engineer for Task Creation

After retro agent completes, launch task-engineer:

```markdown
**Task**: Create improvement tasks based on retrospective findings

**Input**: Read retrospective report(s) in `docs/retrospectives/` (most recent)

**Scope**:
- For each recommendation in retrospective:
  - Create task in `.backlog/pending/`
  - Set appropriate priority (high for systemic, medium for process, low for tech debt)
  - Assign to appropriate agent
  - Include acceptance criteria
  - Reference retrospective report in Documentation field

**Deliverable**:
- Tasks created in `.backlog/pending/` for all actionable recommendations
- Task files follow template from `docs/acf/backlog/task-template.md`
- Commit with message: `task: create improvement tasks from retro YYYYMMDD`
```

## Usage Examples

### Basic Usage
```bash
/retro
```
Analyzes all blocked and rejected tasks from last 7 days.

### Targeted Analysis (if command supports args)
```bash
/retro --focus=quality-gates
```
Focus retrospective on quality gate failures.

```bash
/retro --agent=go-engineer
```
Analyze failures specific to go-engineer tasks.

```bash
/retro --timeframe=30d
```
Analyze failures from last 30 days instead of default 7.

## Success Criteria

✅ Retrospective report created in `docs/retrospectives/`
✅ Root causes identified using Five Whys
✅ Systemic issues distinguished from individual mistakes
✅ Improvement tasks created in `.backlog/pending/`
✅ High-priority tasks address systemic failures
✅ All tasks reference retrospective report

## Anti-Patterns

❌ **Don't**: Run retrospective when no failures present
✅ **Do**: Run after accumulating 5+ blocked/rejected tasks

❌ **Don't**: Skip improvement task creation
✅ **Do**: Create tasks for ALL actionable recommendations

❌ **Don't**: Blame individuals
✅ **Do**: Focus on systemic issues and process improvements

❌ **Don't**: Make recommendations without root cause analysis
✅ **Do**: Apply Five Whys to every failure pattern

## Output Format

```
🔍 Retrospective Analysis Started

Phase 1: Root Cause Analysis (retro agent)
- Blocked tasks found: 3
- Rejected tasks found: 5
- Multi-attempt tasks: 2
- Analyzing patterns...
- Creating retrospective report: docs/retrospectives/20251107-quality-gate-failures.md

Phase 2: Improvement Task Creation (task-engineer)
- Reading retrospective report...
- Creating improvement tasks...
- Created 4 tasks:
  - infra-001-update-quality-gate-docs (high)
  - process-002-add-precommit-hook-validation (high)
  - docs-003-clarify-test-coverage-requirements (medium)
  - tech-004-automate-snapshot-updates (low)

✅ Retrospective complete. Review report and improvement tasks in .backlog/pending/
```
