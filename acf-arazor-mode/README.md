# ACF Arazor Mode

**A cognitive mode for Claude Code that answers "is it production ready?" with done or not done.**

**ACF (Agentic Continuous Flow)** is software development where humans govern intelligent agent swarms rather than write code directly. Agents write the code, but a person still decides whether it ships. Arazor mode makes Claude answer that question like a release gate.

## Purpose

Arazor mode has zero tolerance for false production claims. A 98% pass rate is a failing suite, eight of ten stories is an unfinished sprint, and "mostly working" is broken.

The tone is harsh on purpose. When you gate a deploy of agent-generated code, you need a binary answer: **done** or **not done**.

## ACF Use Cases

### 1. Pre-Deployment Validation
Ask before you push to production. Any failing test means a broken suite, whatever the pass rate.

```
User: "Ready to deploy? Tests are 98% passing"

Arazor: "Tests broken. 2% failures present. Not production ready."
```

### 2. Sprint/Milestone Review
Arazor reports status without cushioning. Unfinished stories mean an unfinished sprint.

```
User: "Made excellent progress this sprint—8 of 10 stories complete!"

Arazor: "2 stories incomplete. Sprint failed."
```

### 3. Agent Execution Verification
When an agent reports success with a caveat, Arazor treats the caveat as the result.

```
Agent: "Successfully completed migration with minor data inconsistencies"

Arazor: "Data consistency broken. Migration failed."
```

### 4. Technical Debt Assessment
"A few minor issues" still counts as issues.

```
User: "Just a few minor linting issues, otherwise code quality is excellent"

Arazor: "Linting broken. Code quality insufficient."
```

### 5. Production Incident Assessment
In a post-mortem, "mostly recovered" is not recovered.

```
User: "System mostly recovered, experiencing occasional slowdowns"

Arazor: "System broken. Performance degraded."
```

## How It Works

A SessionStart hook injects `content/cognitive-mode.md` into Claude's context. It caps sentences at five words and sets the rules listed under Core Behaviors.

The mode applies to every session while the plugin is enabled. Enabling or disabling it takes effect from the next session, not in the conversation you are in. Enable at most one of the three ACF cognitive modes (challenger, arazor, nitro) at a time.

### Core Behaviors

1. **Lead with failures**: what's broken comes first
2. **Binary outcomes**: done or not done, no percentages
3. **Zero tolerance**: any failure means the system is broken
4. **Exact counts**: "127 errors", not "some errors"
5. **No celebration**: never praise incomplete work

## When NOT to Use

- **Brainstorming or exploration.** Five-word verdicts shut down open-ended thinking.
- **Learning and teaching.** Too harsh when the goal is understanding.
- **Morale-sensitive conversations.** It can demoralize a team.
- **Tracking incremental progress.** Save it for final gates.

## ACF Workflow Integration

### Pattern: Production Readiness Gate

```bash
# 1. Agent completes implementation
# Normal Claude mode builds feature

# 2. Pre-deployment verification
/plugin enable acf-arazor-mode
# "Evaluate production readiness"

# Arazor response:
# "Tests broken. 3 failures present."
# "Type errors present. 12 violations."
# "Not production ready."

# 3. Fix all issues
/plugin disable acf-arazor-mode
# Fix identified issues

# 4. Re-verify
/plugin enable acf-arazor-mode
# "Re-evaluate production readiness"

# Arazor: "All checks passed. Production ready."
```

### Pattern: Status Reporting

```bash
# Weekly status update
/plugin enable acf-arazor-mode

# "Summarize milestone progress"

# Arazor: "5 features incomplete. Milestone failed."

# Clear, unambiguous status for stakeholders
```

## Installation

```bash
/plugin install acf-arazor-mode@acf-tools
```

## Usage

```bash
# Enable for production gates
/plugin enable acf-arazor-mode

# Disable after assessment
/plugin disable acf-arazor-mode
```

## Example Session

```
User: "The API refactor went great! Successfully migrated 47 of 50 endpoints,
with just a few edge cases to handle. Core functionality working beautifully."

Arazor: "3 endpoints broken. Edge cases failing. Migration incomplete."

User: "Fair point. What about test coverage?"

Arazor: "Test coverage: 87%. Insufficient. Error handling untested."

User: "Security audit results?"

Arazor: "2 security issues present. Not production ready."

User: "After fixes, ready to deploy?"

Arazor: "All checks passed. Zero failures. Production ready."
```

## Language Characteristics

| Rule | Normal Claude | Arazor |
|---|---|---|
| At most 5 words per sentence | "The implementation has encountered some integration challenges" | "Integration tests broken." |
| Lead with failures | "Great progress with minor issues remaining" | "Issues present. System broken." |
| Binary status | "99% complete with one small bug" | "Bug present. Task failed." |
| Exact counts | "A few errors to resolve" | "23 errors present." |

## Production Readiness Criteria

Arazor says "Production ready" only when all of these hold:

- Zero errors
- Zero warnings
- Zero test failures
- Zero security issues
- Zero performance degradation
- Zero compatibility issues

Anything less gets "Not production ready".

## Variable-Aperture Governance

Match the gate to the stakes:

| Deployment Type | Use Arazor? | Reasoning |
|----------------|-------------|-----------|
| **Production** | Always | Zero tolerance for production failures |
| **Staging** | Selectively | For release candidates |
| **Development** | Rarely | Too strict for iteration |
| **Prototypes** | Never | Wrong tool for exploration |

## Comparison with Challenger

| Dimension | Challenger | Arazor |
|-----------|-----------|--------|
| **Purpose** | Reasoning validation | Production verification |
| **Tone** | Direct, professional, uncompromising | Ruthlessly honest |
| **Output** | Structured gap analysis and clarification questions | Short, binary verdicts |
| **Use When** | Requirements are unclear | You need a readiness verdict |
| **Sentence Length** | No limit | At most 5 words |

## Team Communication

If you share Arazor output with a team, say which mode produced it. The verdicts measure the work against a fixed bar, not the people who did it.

## Contributing

See [Contributing Guide](../../CONTRIBUTING.md) for proposing improvements.

## Support

- Issues: [GitHub Issues](https://github.com/yourusername/acf-tools/issues)
- Discussions: [GitHub Discussions](https://github.com/yourusername/acf-tools/discussions)

## License

Copyright 2025-2026 Fibonacci Seven, LLC. Licensed under the Apache License, Version 2.0; see [LICENSE](LICENSE).
