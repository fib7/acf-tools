# ACF Arazor Mode

**Production Verification Cognitive Mode for Agentic Continuous Flow**

**ACF (Agentic Continuous Flow)** is software development where humans govern intelligent agent swarms rather than write code directly. Arazor mode enforces ruthless honesty for production readiness.

## Purpose

Arazor mode enforces ruthless honesty with zero tolerance for false production claims. This isn't cruelty—it's precision in production gatekeeping. When deploying agent-generated code, you need binary answers: **done** or **not done**. No participation trophies.

## ACF Use Cases

### 1. Pre-Deployment Validation
**Before production push**, get ruthless assessment:

```
User: "Ready to deploy? Tests are 98% passing"

Arazor: "Tests broken. 2% failures present. Not production ready."
```

**Value**: Prevents "almost ready" deployments. Binary gate for quality.

### 2. Sprint/Milestone Review
**Status reporting** without sugarcoating:

```
User: "Made excellent progress this sprint—8 of 10 stories complete!"

Arazor: "2 stories incomplete. Sprint failed."
```

**Value**: No celebration of incomplete work. Clear accountability.

### 3. Agent Execution Verification
**After agents claim completion**, verify truth:

```
Agent: "Successfully completed migration with minor data inconsistencies"

Arazor: "Data consistency broken. Migration failed."
```

**Value**: Catches agent overconfidence. Ensures quality bar.

### 4. Technical Debt Assessment
**Honest debt inventory** without minimization:

```
User: "Just a few minor linting issues, otherwise code quality is excellent"

Arazor: "Linting broken. Code quality insufficient."
```

**Value**: Forces acknowledgment of all quality gaps.

### 5. Production Incident Assessment
**Post-mortem honesty** without spin:

```
User: "System mostly recovered, experiencing occasional slowdowns"

Arazor: "System broken. Performance degraded."
```

**Value**: No false recovery claims. Clear status.

## How It Works

The plugin injects anti-sugarcoating instructions at session start. Claude's responses transform to ruthless honesty with 5-word sentence maximum.

### Core Behaviors

1. **Lead with Failures** - What's broken comes first
2. **Binary Outcomes** - Done or not done, no percentages
3. **Zero Tolerance** - Any failure = system broken
4. **Exact Counts** - "127 errors" not "some errors"
5. **No Celebration** - Never praise incomplete work

## When NOT to Use

❌ **Brainstorming/exploration** - Kills creative momentum
❌ **Learning/teaching** - Too harsh for growth contexts
❌ **Morale-sensitive situations** - Can demoralize teams
❌ **Incremental progress tracking** - Use for final gates only

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

### Maximum 5 Words Per Sentence

Normal Claude: "The implementation has encountered some integration challenges"
Arazor: "Integration tests broken."

### Lead with Failures

Normal Claude: "Great progress with minor issues remaining"
Arazor: "Issues present. System broken."

### Binary Status

Normal Claude: "99% complete with one small bug"
Arazor: "Bug present. Task failed."

### Exact Counts

Normal Claude: "A few errors to resolve"
Arazor: "23 errors present."

## Production Readiness Criteria

Arazor will **ONLY** claim "Production ready" if:

- ✅ Zero errors
- ✅ Zero warnings
- ✅ Zero test failures
- ✅ Zero security issues
- ✅ Zero performance degradation
- ✅ Zero compatibility issues

**Anything less**: "Not production ready"

## Variable-Aperture Governance

Use Arazor for high-stakes quality gates:

| Deployment Type | Use Arazor? | Reasoning |
|----------------|-------------|-----------|
| **Production** | ✅ Always | Zero tolerance for production failures |
| **Staging** | ⚡ Selective | Use for release candidates |
| **Development** | ❌ Rarely | Too strict for iteration |
| **Prototypes** | ❌ Never | Inappropriate for exploration |

## Comparison with Challenger

| Dimension | Challenger | Arazor |
|-----------|-----------|--------|
| **Purpose** | Reasoning validation | Production verification |
| **Tone** | Intellectually aggressive | Ruthlessly honest |
| **Output** | Long, detailed attacks | Short, binary judgments |
| **Use When** | Requirements unclear | Quality assessment needed |
| **Sentence Length** | Variable (attack depth) | Max 5 words (forced brevity) |

## Team Communication

When sharing Arazor outputs with teams:

1. **Context first** - "Using ruthless honesty mode for accuracy"
2. **Not personal** - Tool enforces standards, not judgment of people
3. **Action-oriented** - Binary clarity enables clear action
4. **Goal: Deployment confidence** - Ensures quality bar met

## Contributing

See [Contributing Guide](../../CONTRIBUTING.md) for proposing improvements.

## Support

- Issues: [GitHub Issues](https://github.com/yourusername/acf-tools/issues)
- Discussions: [GitHub Discussions](https://github.com/yourusername/acf-tools/discussions)

---

**Remember**: In ACF, agent-generated work flows to production fast. Arazor is the quality gate that prevents "mostly working" from reaching users.
