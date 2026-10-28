# ACF Nitro Mode

Nitro makes Claude point out work that ran one step at a time when it could have run in parallel:
several TodoWrite calls where one would do, agents spawned in separate messages, independent files
read one by one. Each callout estimates the time lost and shows the batched version.

**ACF (Agentic Continuous Flow)** is software development where humans govern intelligent agent swarms rather than write code directly. Nitro is the ACF cognitive mode for parallel execution.

## How it works

A SessionStart hook injects `content/parallel-enforcement.md` into Claude's context at the start of
every session. Those instructions tell Claude to watch for three patterns:

1. **TodoWrite batching**: several TodoWrite calls where one call with the full list would do.
2. **Agent spawning**: Task agents launched one message at a time when they could all start from
   one message.
3. **Independent tool calls**: Read, Grep or Bash calls that don't depend on each other but ran in
   sequence.

Every callout has the same shape: the sequential pattern it saw, the waste as a percentage and in
seconds or minutes, the parallel version, and a line of encouragement. The persona is an excitable
racing coach, so its output is full of racing metaphors, capital letters and emoji. It is written to
encourage, not to scold.

The numbers are estimates built from assumed round-trip and agent times. Nitro doesn't time
anything.

## What it catches

### Separate TodoWrite calls

Three calls where one would do cost two extra round-trips:

```
User: [Makes 3 separate TodoWrite calls]

Nitro: "🏎️ SEQUENTIAL TodoWrite DETECTED! Three separate calls = 2 extra
       round-trips = 6-10 seconds wasted. Batch ALL todos in SINGLE call!

       ⏱️ WASTE: 67% slower than parallel batching"
```

### Agents spawned one at a time

Three independent agents that take 2 minutes each finish in 6 minutes one after another, and in 2
minutes when they start together. This is where parallel execution saves the most:

```
User: [Spawns 3 agents sequentially across 3 messages]

Nitro: "🏎️ SEQUENTIAL AGENT SPAWNING! You're running agents ONE-BY-ONE!

       ⏱️ IMPACT:
       - Sequential: 3 agents × 2 min = 6 minutes
       - Parallel: max(2, 2, 2) = 2 minutes
       - 4 MINUTES LOST (67% waste)

       💨 Single message with multiple Task calls = turbo speed!"
```

### Independent reads

Five reads in five messages cost four extra round-trips. It adds up during codebase exploration and
research, where reads come in batches:

```
User: [Reads 5 files sequentially]

Nitro: "🏎️ SEQUENTIAL READS! Five files, five round-trips!

       ⏱️ WASTE: 4 extra round-trips, 8-15 seconds lost, 80% slower

       💨 Single message with 5 Read calls = instant file access!"
```

## The arithmetic

The worked examples below use round figures: 2-3 seconds per round-trip and 2 minutes per agent.
Nitro's callouts pick their own rough numbers, so the two don't always match.

### TodoWrite batching

```
❌ Sequential (3 calls):
   - 3 round-trips × 2-3 seconds = 6-10 seconds total

✅ Parallel (1 call):
   - 1 round-trip × 2-3 seconds = 2-3 seconds total

💨 SAVINGS: 4-7 seconds (67% faster)
```

### Agent spawning

```
❌ Sequential (3 agents):
   - Agent 1: 2 minutes
   - Agent 2: 2 minutes (waits for 1)
   - Agent 3: 2 minutes (waits for 2)
   - Total: 6 minutes

✅ Parallel (3 agents):
   - All spawn simultaneously
   - Total: max(2, 2, 2) = 2 minutes

💨 SAVINGS: 4 minutes (67% faster)
```

### Tool calls

```
❌ Sequential (5 reads):
   - 5 files × 2 seconds per round-trip = 10 seconds

✅ Parallel (5 reads):
   - All files in one round-trip = 2 seconds

💨 SAVINGS: 8 seconds (80% faster)
```

## Example session

```
User: [Creates 4 todos with separate TodoWrite calls]

Nitro: "🏎️ SEQUENTIAL TodoWrite DETECTED!

Four separate TodoWrite calls? That's running four drag races
back-to-back instead of side-by-side!

⏱️ PERFORMANCE IMPACT:
- 3 extra round-trips
- ~9-12 seconds wasted
- 75% slower than batching

💨 NITRO PATTERN:
TodoWrite {
  todos: [
    { content: 'Task 1', status: 'pending', activeForm: '...' },
    { content: 'Task 2', status: 'pending', activeForm: '...' },
    { content: 'Task 3', status: 'pending', activeForm: '...' },
    { content: 'Task 4', status: 'pending', activeForm: '...' }
  ]
}

Single call. All todos. Maximum speed. Let's gooooo! 🏁"

User: [Fixes pattern, uses single TodoWrite]

Nitro: "🏆 NOW THAT'S RACING! Single batched call = turbo performance!
You just saved ~10 seconds. Keep that parallel execution mindset!"
```

## Installation

```bash
/plugin install acf-nitro@acf-tools
```

## Usage

```bash
# Enable for performance-critical work
/plugin enable acf-nitro

# Disable when enforcement not needed
/plugin disable acf-nitro
```

## With a team, or before an optimization pass

Nitro flags each sequential pattern as it happens. Left on for a team, that feedback is meant to
make batching the default habit:

```
Developer: [Uses sequential patterns]
Nitro: [Provides real-time performance metrics]
Developer: [Learns to think in parallel patterns]

Result: Team naturally writes parallel-first code
```

Before optimization work, turn it on to find where sequential execution happens, then compare
timings before and after:

```
# Enable Nitro before optimization sprint
/plugin enable acf-nitro

# Work through implementation
# Nitro flags all parallelization opportunities

# Measure improvement
# Compare sequential vs parallel execution times
```

## Workflow patterns

The same on/off pattern fits three kinds of work.

### Day-to-day development

```bash
# Start session with Nitro active
/plugin enable acf-nitro

# Develop with real-time performance feedback
# Nitro flags parallelization opportunities as you work

# Build muscle memory for parallel patterns
# Gradually internalize the optimizations

# Optional: Disable for non-critical work
/plugin disable acf-nitro
```

### Performance sprint

```bash
# Before optimization sprint
/plugin enable acf-nitro

# Establish baseline (how much sequential execution exists?)
# Work through codebase, noting all violations

# Fix violations systematically
# Measure improvements with Nitro's metrics

# After sprint
# Compare before/after execution times
```

### Large multi-agent runs

```bash
# Enable before large-scale agent work
/plugin enable acf-nitro

# Plan multi-agent execution
# Nitro ensures maximum parallelization

# Execute with optimal performance
# Avoid sequential agent spawning bottlenecks

# Result: Minimum execution time
```

## When not to use it

- **Learning**: the callouts are noise for a beginner.
- **Casual exploration**: the overhead isn't worth it for low-stakes work.
- **Work that is sequential by design**: each step needs the previous step's result.
- **Step-by-step on request**: the user wants to see each step on its own.

## Variable-Aperture Governance

Faster execution means more iterations in the same time. Turn Nitro on where speed pays and off
where it doesn't:

| Execution Context | Use Nitro? | Reasoning |
|-------------------|-----------|-----------|
| **Multi-agent orchestration** | Yes | Parallel spawning saves the most time (6 minutes down to 2 in the example above) |
| **High-volume task execution** | Yes | A few seconds saved per batch add up over many tasks |
| **Performance optimization work** | Yes | You want every sequential step flagged |
| **Research/exploration** | Selectively | Use it if speed matters, skip it while learning |
| **Casual development** | No | On small work the callouts cost more attention than they save |

## Dependency awareness

Sequential execution is correct when one operation needs another's result, and Nitro is told not to
flag it.

**Valid sequential** (no violation):
```
Message 1: Read config file
[Need contents to determine next action]
Message 2: Based on config, spawn appropriate agents
```

**Invalid sequential** (violation):
```
Message 1: Read file1.ts
Message 2: Read file2.ts
Message 3: Read file3.ts
[All files independent, should be parallel]
```

The instructions also exempt error-handling and conditional flows, step-by-step work the user asked
for, resource limits the user mentions, and acf-whip tasks that share a `Worktree:` slug, which run
one after another on the same branch by design. Nitro is a prompt, not a static check, so it can
still misjudge a dependency.

## Contributing

See the [Contributing Guide](../../CONTRIBUTING.md) to propose changes to this mode.

## Support

- Issues: [GitHub Issues](https://github.com/fib7/acf-tools/issues)
- Discussions: [GitHub Discussions](https://github.com/fib7/acf-tools/discussions)

## License

Copyright 2025-2026 Fibonacci Seven, LLC. Licensed under the Apache License, Version 2.0; see [LICENSE](LICENSE).
