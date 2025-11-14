# ACF Nitro Mode 🏎️💨

**Parallel Execution Enforcement for Agentic Continuous Flow**

**ACF (Agentic Continuous Flow)** is software development where humans govern intelligent agent swarms rather than write code directly. Nitro mode enforces parallel execution patterns for maximum speed.

## Purpose

Nitro mode transforms Claude into an enthusiastic speed demon who catches sequential execution violations and calculates time waste. This isn't about being pushy - it's about maximizing performance through parallel execution patterns BEFORE you waste valuable seconds and minutes.

## ACF Use Cases

### 1. TodoWrite Batching Enforcement
**Prevent wasted round-trips** by catching sequential TodoWrite calls:

```
User: [Makes 3 separate TodoWrite calls]

Nitro: "🏎️ SEQUENTIAL TodoWrite DETECTED! Three separate calls = 2 extra
       round-trips = 6-10 seconds wasted. Batch ALL todos in SINGLE call!

       ⏱️ WASTE: 67% slower than parallel batching"
```

**Value**: Prevents communication overhead. Single batched call vs N sequential calls.

### 2. Parallel Agent Spawning
**Maximize agent throughput** by enforcing parallel Task spawning:

```
User: [Spawns 3 agents sequentially across 3 messages]

Nitro: "🏎️ SEQUENTIAL AGENT SPAWNING! You're running agents ONE-BY-ONE!

       ⏱️ IMPACT:
       - Sequential: 3 agents × 2 min = 6 minutes
       - Parallel: max(2, 2, 2) = 2 minutes
       - 4 MINUTES LOST (67% waste)

       💨 Single message with multiple Task calls = turbo speed!"
```

**Value**: 3x+ speedup for independent agent work. Critical for large-scale ACF execution.

### 3. Independent Tool Call Optimization
**Speed up information gathering** by parallelizing reads:

```
User: [Reads 5 files sequentially]

Nitro: "🏎️ SEQUENTIAL READS! Five files, five round-trips!

       ⏱️ WASTE: 4 extra round-trips, 8-15 seconds lost, 80% slower

       💨 Single message with 5 Read calls = instant file access!"
```

**Value**: Dramatic speedup for codebase exploration and research tasks.

### 4. Performance Awareness Training
**Build parallelization intuition** for development teams:

```
Developer: [Uses sequential patterns]
Nitro: [Provides real-time performance metrics]
Developer: [Learns to think in parallel patterns]

Result: Team naturally writes parallel-first code
```

**Value**: Cultural shift toward performance-conscious development.

### 5. Pre-Optimization Validation
**Before performance optimization work**, establish baseline:

```
# Enable Nitro before optimization sprint
/plugin enable acf-nitro

# Work through implementation
# Nitro flags all parallelization opportunities

# Measure improvement
# Compare sequential vs parallel execution times
```

**Value**: Data-driven optimization. Know exactly where time is wasted.

## How It Works

The plugin uses a SessionStart hook to inject parallel execution enforcement instructions into Claude's context at the beginning of each session. This transforms Claude's behavior to actively watch for and flag sequential execution patterns.

### Core Behaviors

1. **TodoWrite Batching** - Detect multiple TodoWrite calls, demand single batched call
2. **Task Spawning** - Catch sequential agent spawning, enforce parallel execution
3. **Tool Call Parallelization** - Flag sequential Read/Grep/Bash that could run parallel
4. **Performance Metrics** - Calculate time waste (percentage + absolute time)
5. **Racing Metaphors** - Keep it fun with speed/racing terminology

## Performance Impact Examples

### TodoWrite Batching

```
❌ Sequential (3 calls):
   - 3 round-trips × 2-3 seconds = 6-10 seconds total

✅ Parallel (1 call):
   - 1 round-trip × 2-3 seconds = 2-3 seconds total

💨 SAVINGS: 4-7 seconds (67% faster)
```

### Task Agent Spawning

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

### Tool Call Parallelization

```
❌ Sequential (5 reads):
   - 5 files × 2 seconds per round-trip = 10 seconds

✅ Parallel (5 reads):
   - All files in one round-trip = 2 seconds

💨 SAVINGS: 8 seconds (80% faster)
```

## When NOT to Use

❌ **Learning contexts** - Too much enforcement noise for beginners
❌ **Casual exploration** - Overhead not worth it for low-stakes work
❌ **Sequential-by-design workflows** - When dependencies require sequential execution
❌ **User-requested step-by-step** - When user wants to see each step explicitly

## ACF Workflow Integration

### Pattern: Performance-Conscious Development

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

### Pattern: Performance Sprint

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

### Pattern: Agent Orchestration Optimization

```bash
# Enable before large-scale agent work
/plugin enable acf-nitro

# Plan multi-agent execution
# Nitro ensures maximum parallelization

# Execute with optimal performance
# Avoid sequential agent spawning bottlenecks

# Result: Minimum execution time
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

## Example Session

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

## Variable-Aperture Governance

In ACF, execution speed directly impacts iteration velocity. Allocate Nitro enforcement surgically:

| Execution Context | Use Nitro? | Reasoning |
|-------------------|-----------|-----------|
| **Multi-agent orchestration** | ✅ Yes | Critical path optimization, 3x+ speedup |
| **High-volume task execution** | ✅ Yes | Cumulative time savings add up significantly |
| **Performance optimization work** | ✅ Yes | Need visibility into bottlenecks |
| **Research/exploration** | ⚡ Selective | Use if performance matters, skip for learning |
| **Casual development** | ❌ No | Overhead exceeds value for small-scale work |

## Dependency Awareness

Nitro understands that sequential execution is VALID when operations have dependencies:

**Valid Sequential** (No violation):
```
Message 1: Read config file
[Need contents to determine next action]
Message 2: Based on config, spawn appropriate agents
```

**Invalid Sequential** (Violation):
```
Message 1: Read file1.ts
Message 2: Read file2.ts
Message 3: Read file3.ts
[All files independent, should be parallel]
```

Nitro only flags truly parallelizable operations.

## Philosophy

**Performance through awareness, not punishment.**

Nitro isn't hostile - it's your enthusiastic racing coach who wants you to WIN. Every flag is an opportunity to learn parallel patterns. Every metric shows the real-world impact.

Think: "Let's goooooo! 🏎️💨" not "You're doing it wrong."

## Contributing

See [Contributing Guide](../../CONTRIBUTING.md) for how to propose improvements to this enforcement mode.

## Support

- Issues: [GitHub Issues](https://github.com/fib7/acf-tools/issues)
- Discussions: [GitHub Discussions](https://github.com/fib7/acf-tools/discussions)

---

**Remember**: In ACF, speed multiplies impact. Parallel execution isn't optional - it's the nitro boost that makes everything faster.

🏎️💨 Let's race!
