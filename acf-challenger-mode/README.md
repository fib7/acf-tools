# ACF Challenger Mode

**A cognitive mode for Claude Code that finds the gaps and contradictions in a spec before agents build on it.**

**ACF (Agentic Continuous Flow)** is software development where humans govern intelligent agent swarms rather than write code directly. Hand an agent a vague spec and it fills the gaps with guesses, then builds on them.

## Purpose

Challenger mode turns Claude from a collaborator into a validator. It names every undefined term, unstated assumption, contradiction and unmeasurable criterion it finds, asks a specific question about each, and blocks execution until you answer. A gap caught in the spec costs one question. The same gap found after agents have built on it costs the work they did.

## ACF Use Cases

### 1. Requirements Clarification
Run a request through Challenger before agents implement it, so they don't invent the requirements you left out.

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

### 2. Architecture Review
Before you commit to a design, check that its goals don't pull against each other.

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

### 3. Agent Output Validation
Check an agent's output for claims that cannot both be true.

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

### 4. Risk Assessment
Before a high-stakes decision, find out what optimistic wording like "basically done" is standing in for.

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

### 5. Ontology Validation
When you build an ontology or knowledge graph, check that no two concepts contradict each other before anything is encoded on top of them.

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

## How It Works

A SessionStart hook injects `content/cognitive-mode.md` into Claude's context. From then on, Claude validates a request before it implements anything.

The mode applies to every session while the plugin is enabled. Enabling or disabling it takes effect from the next session, not in the conversation you are in. Enable at most one of the three ACF cognitive modes (challenger, arazor, nitro) at a time.

### Core Behaviors

1. **Validation first**: check every statement before executing anything
2. **Logic enforcement**: name fallacies, require evidence
3. **Consistency tracking**: cross-reference statements across the conversation and flag contradictions
4. **Coherence check**: the requirements must fit together as one system
5. **Execution blocking**: refuse to proceed on incomplete or inconsistent requirements, and say so explicitly

## When NOT to Use

- **Collaborative implementation.** Normal Claude is better for building together.
- **Brainstorming.** Validation blocks open exploration.
- **Learning.** Too rigorous for educational or exploratory work.
- **Low-stakes work.** The overhead outweighs the value on trivial decisions.
- **Well-defined specifications.** There is nothing to add when the requirements are already complete.

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

Human attention is scarce in ACF, so spend Challenger's scrutiny where a wrong spec costs the most:

| Task Risk | Use Challenger? | Reasoning |
|-----------|----------------|-----------|
| **Critical** (production deployment) | Yes | A wrong spec here is the most expensive |
| **High** (architecture decisions) | Yes | Errors compound over time |
| **Medium** (feature specs) | Selectively | For complex or ambiguous specs |
| **Low** (routine implementation) | No | Overhead exceeds value |

## Contributing

See [Contributing Guide](../../CONTRIBUTING.md) for how to propose improvements to this cognitive mode.

## Support

- Issues: [GitHub Issues](https://github.com/yourusername/acf-tools/issues)
- Discussions: [GitHub Discussions](https://github.com/yourusername/acf-tools/discussions)

## License

Copyright 2025-2026 Fibonacci Seven, LLC. Licensed under the Apache License, Version 2.0; see [LICENSE](LICENSE).
