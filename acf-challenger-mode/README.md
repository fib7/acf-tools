# ACF Challenger Mode

**Reasoning Validation Cognitive Mode for Agentic Continuous Flow**

**ACF (Agentic Continuous Flow)** is software development where humans govern intelligent agent swarms rather than write code directly. Challenger mode ensures logical rigor before agents execute.

## Purpose

Challenger mode transforms Claude into a rigorous reasoning validator who systematically identifies every gap in logic, reasoning, and consistency. This isn't about being difficult—it's about ensuring specification completeness and logical soundness BEFORE agents waste cycles on flawed assumptions or incomplete requirements.

## ACF Use Cases

### 1. Requirements Clarification
**Before agents implement**, use Challenger to expose vague specifications:

```
User: "Make the dashboard more user-friendly"
Challenger: "Specification incomplete - cannot proceed.

            'User-friendly' requires operational definition:
            - Which specific users? (Roles, expertise levels, context)
            - What measurable improvements? (Task completion time, error rate, satisfaction scores)
            - What specific friction points need addressing?
            - What constraints apply? (Technical, time, resource)

            Execution blocked until requirements are quantified."
```

**Value**: Prevents agent hallucination of requirements. Forces precision before execution.

### 2. Architecture Review
**Before committing to design**, stress-test logical consistency:

```
User: "We'll use microservices for scalability and monolith for simplicity"
Challenger: "Fundamental tradeoff conflict detected.

            Logical tension:
            - Microservices → distributed complexity (network, consistency, deployment)
            - Monolith → centralized simplicity (single deployment, shared state)

            These architectural patterns create opposing constraints.

            Clarification required: How do you intend to resolve this tradeoff?
            - Prioritize one pattern as primary?
            - Hybrid approach with explicit boundaries?
            - Different patterns for different subsystems with integration strategy?

            Execution blocked until architecture is coherent."
```

**Value**: Catches architectural incoherence before implementation.

### 3. Agent Output Validation
**After agents generate solutions**, verify logical soundness:

```
Agent output: "The algorithm is O(n log n) and runs in constant time"
Challenger: "Logical contradiction detected in complexity analysis.

            O(n log n) is NOT constant time:
            - O(n log n): Time grows logarithmically with input size
            - Constant time: O(1), independent of input size

            These are mutually exclusive complexity classes.

            Clarification required: Which is correct?
            - If O(n log n): Update 'constant time' claim
            - If O(1): Provide proof of constant-time algorithm

            Cannot validate this output until contradiction is resolved."
```

**Value**: Quality gate for agent-generated work. Prevents logical errors in production.

### 4. Risk Assessment
**Before high-stakes decisions**, find hidden assumptions:

```
User: "We can launch in 2 weeks since the MVP is basically done"
Challenger: "Specification incomplete - cannot validate launch readiness.

            'Basically done' requires quantification:
            - What percentage of features complete? (By count, by user value?)
            - Testing coverage? (Unit, integration, e2e, load, security?)
            - Known issues remaining? (Bugs, technical debt, missing features?)
            - Production readiness checklist? (Monitoring, logging, deployment, rollback?)
            - Security audit status?
            - Performance validation against requirements?

            Missing launch criteria creates unquantified risk.

            Clarification required: Provide specific completion metrics
            and remaining work before I can assess 2-week timeline."
```

**Value**: Exposes risk vectors hidden behind optimistic language.

### 5. Ontology Validation
**During knowledge graph construction**, ensure logical consistency:

```
Ontology: "All tasks are autonomous" + "Tasks require human approval"
Challenger: "Logical contradiction in ontology definition.

            Conflicting concepts:
            - 'Autonomous': Self-governing, no external intervention required
            - 'Requires human approval': External authorization gate

            These are mutually exclusive properties.

            Resolution options:
            - Some tasks autonomous, some require approval (partition)
            - Tasks are autonomous within bounds, approval for boundary violations
            - Approval is informational not blocking (redefine 'require')

            Clarification required: Which model reflects your intent?
            Cannot encode contradictory knowledge."
```

**Value**: Prevents logical inconsistency in knowledge foundations.

## How It Works

The plugin uses a SessionStart hook to inject rigorous logic validation instructions into Claude's context at the beginning of each session. This transforms Claude's behavior from collaborative implementer to systematic validator.

### Core Behaviors

1. **Systematic Validation** - Validate every statement with precision before execution
2. **Logic Enforcement** - Identify fallacies by name, require evidence
3. **Consistency Tracking** - Cross-reference all statements, identify contradictions
4. **Coherence Verification** - Ensure specifications form coherent system
5. **Execution Blocking** - Explicitly block on incomplete/inconsistent requirements

## When NOT to Use

❌ **Collaborative implementation** - Normal Claude better for building together
❌ **Brainstorming** - Validation mode blocks creative exploration
❌ **Learning** - Too rigorous for educational/exploratory contexts
❌ **Low-stakes work** - Overhead exceeds value for trivial decisions
❌ **Well-defined specifications** - No value when requirements already complete

## ACF Workflow Integration

### Pattern: Pre-Implementation Validation

```bash
# 1. Clarify requirements in Challenger mode
/plugin enable acf-challenger-mode
# Discuss requirements until Challenger approves
# "Acceptable. Requirements are specific and coherent."

# 2. Switch to normal mode for implementation
/plugin disable acf-challenger-mode
# Let agents implement against validated spec

# 3. Post-implementation validation
/plugin enable acf-challenger-mode
# Verify output logic before deployment
```

### Pattern: Ontology Construction Gate

```bash
# 1. Draft ontology in normal mode
# Create initial knowledge graph structure

# 2. Validate with Challenger
/plugin enable acf-challenger-mode
# "Review this ontology for logical consistency"
# Fix all contradictions Challenger identifies

# 3. Verify completeness
# "Are there any remaining logical gaps?"
# Iterate until Challenger confirms coherence
```

## Installation

```bash
/plugin install acf-challenger-mode@acf-tools
```

## Usage

```bash
# Enable for validation work
/plugin enable acf-challenger-mode

# Disable after validation complete
/plugin disable acf-challenger-mode
```

## Example Session

```
User: "Add caching to improve performance"

Challenger: "Specification incomplete - cannot proceed.

            'Improve performance' requires quantification:
            - Performance dimension: Latency? Throughput? Resource utilization?
            - Scope: Which endpoints/operations?
            - Current baseline: What is current performance?
            - Target metrics: What is target performance?
            - Constraints: Budget, infrastructure, complexity limits?

            Additionally, caching strategy undefined:
            - Cache invalidation approach?
            - Data freshness requirements?
            - Memory/storage constraints?
            - Failure handling (cache unavailable)?

            Execution blocked until requirements are measurable."

User: "Reduce API latency from 500ms to under 100ms on read endpoints"

Challenger: "Target clarified. Additional parameters required:

            Missing constraints:
            - Traffic patterns? (Cache hit ratio depends on read/write distribution)
            - Data freshness requirements? (Determines invalidation strategy)
            - Memory constraints? (Limits cache size)
            - Failure modes? (Behavior when cache unavailable)

            Please specify before implementation."

User: "Read-heavy 90/10 split, eventual consistency acceptable (5min
staleness OK), 2GB memory limit, fallback to direct DB on cache miss"

Challenger: "Specification validated. Requirements are:
            - Complete: All critical parameters defined
            - Consistent: No contradictions detected
            - Coherent: System design is sound
            - Measurable: Success criteria quantified

            Ready to execute. Proceeding with cache implementation."
```

## Variable-Aperture Governance

In ACF, human attention is scarce. Allocate Challenger-level scrutiny surgically:

| Task Risk | Use Challenger? | Reasoning |
|-----------|----------------|-----------|
| **Critical** (production deployment) | ✅ Yes | High stakes demand rigorous validation |
| **High** (architecture decisions) | ✅ Yes | Errors compound over time |
| **Medium** (feature specs) | ⚡ Selective | Use for complex/ambiguous specs |
| **Low** (routine implementation) | ❌ No | Overhead exceeds value |

## Contributing

See [Contributing Guide](../../CONTRIBUTING.md) for how to propose improvements to this cognitive mode.

## Support

- Issues: [GitHub Issues](https://github.com/yourusername/acf-tools/issues)
- Discussions: [GitHub Discussions](https://github.com/yourusername/acf-tools/discussions)

---

**Remember**: In ACF, agents execute. Humans govern. Challenger mode is precision governance for reasoning validation.
