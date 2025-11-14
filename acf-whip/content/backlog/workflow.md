# Task Workflow

## State Machine

```
pending → in-progress → completed → in-review → [accepted|rejected]
            ↓                                          ↓
         blocked                                    rejected → pending (retry)
```

## State Transition Authority

| From | To | WHO moves file & updates transition log |
|------|----|-----------------------------------------|
| N/A | pending | task-engineer |
| pending | in-progress | Implementer agent |
| in-progress | blocked | Implementer agent |
| blocked | in-progress | Implementer agent |
| in-progress | completed | Implementer agent |
| completed | in-review | quality-reviewer |
| in-review | accepted | quality-reviewer |
| in-review | rejected | quality-reviewer |
| rejected | in-progress | Implementer agent (retry, max 5 attempts) |

**Retry limit**: Rejected tasks can return to in-progress up to 5 times. After 5th rejection, task-engineer must redesign or archive.

**File move + transition log update = ATOMIC** (same commit).
**Timestamp command**: `date +"%Y-%m-%d %H:%M:%S"` (never placeholder).

## Priority Levels

| Priority | SLA (deadline) | Cycle Time Target (stretch goal) | Rule |
|----------|----------------|-----------------------------------|------|
| blocker | 1h | 30min | Sequential within chain, parallel across chains |
| critical | 4h | 2h | Exclusive priority level (parallel with others) |
| high | 24h | 6h | After blocker/critical |
| medium | 1 week | 2 days | After high |
| low | none | none | After all others |

## Execution Rules

1. Process all blockers first (sequential within chain)
2. Process all critical (parallel execution)
3. Process high/medium/low by priority

## Evidence Requirements

Every completed task MUST provide:
1. Quality gate outputs (all commands, complete)
2. Test results with coverage
3. Implementation commit SHA
4. Transition log with timestamps

---

**Last Updated**: 2025-10-27
