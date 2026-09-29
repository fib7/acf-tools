# Research Documentation Style

The research-agent follows these rules for every document it writes in `docs/research/`. Someone on
the project should be able to decide from the document, check each claim against its source, and
read the numbers in a table instead of digging them out of paragraphs.

## Core Principles

- **Tone**: direct and factual, with no promotional language
- **Evidence**: every claim names its source
- **Objectivity**: every option comes with its tradeoffs
- **Recency**: for fast-moving tech, sources from the last 6 months
- **Density**: tables over prose, to save tokens

## Temporal Naming (mandatory)

Every research document must be named this way:

- **Format**: `docs/research/YYYYMMDD-description.md`
- **Date**: today's date as YYYYMMDD, with no hyphens inside the date
- **Description**: lowercase words joined by hyphens
- **Reference**: `docs/acf/organization.md`

Right:

- `20251117-postgresql-query-optimization.md`
- `20251030-react-server-components-patterns.md`

Wrong:

- `2025-11-17-research.md` (hyphens in the date)
- `research-findings.md` (no date)

## Banned Language (Marketing Speak)

Never use these words:

- "comprehensive", "systematic", "significant", "substantial", "robust", "elegant", "seamless"
- "achievement", "progress", "improvement", unless a metric quantifies them
- "enhance", "optimize", "streamline": say what changed instead ("Reduce latency from 500ms to 200ms")
- "leverage", "utilize": write "use"
- "facilitate", "enable": say what happens
- "cutting-edge", "state-of-the-art", "best-in-class"

## Required Language (Precise, Testable)

Write claims a reader can check:

| Kind | Write | Instead of |
|------|-------|------------|
| Quantified | "Reduces query time from 500ms to 200ms" | "improves performance" |
| Specific | "PostgreSQL JSONB indexes" | "database optimization" |
| Testable | "Handles 1000 concurrent connections" | "scales well" |
| Comparative | "15% faster than Approach A" | "very fast" |
| Sourced | "Per Next.js docs (2025-11-15)" | "common practice" |

## Code Snippet Policy

Research documents carry no implementation code. Never include:

- Function or method implementations
- Algorithm pseudocode: describe the algorithm in plain language
- Configuration file contents over 3 lines: describe what the config sets, not its exact content
- Database queries: state what data is needed
- API call sequences: describe what the workflow produces
- Multi-file code examples: show the pattern, not the full implementation

Allowed sparingly, 2-3 lines at most:

- API endpoint signatures: `POST /api/v1/resource`
- Response shapes: `{"id": "uuid", "status": "pending"}`
- Error codes: `Returns 400 for invalid input`
- Type signatures: `func Process(input []byte) (*Result, error)`
- CLI commands: `npm install library@latest`

An example of compressing code into prose:

Wrong (nine lines of implementation):
```javascript
function optimizeQuery(query) {
  const cached = cache.get(query.hash);
  if (cached && !cached.isExpired()) {
    return cached.value;
  }
  const result = database.execute(query);
  cache.set(query.hash, result, TTL);
  return result;
}
```

Right (plain language):
> Query optimization uses two-tier caching: in-memory (5min TTL) and Redis (1hr TTL). Cache key is query hash. Returns cached result if valid, otherwise executes query and updates cache.

## Source Attribution Requirements

Every claim needs a source.

Right:
> React Server Components reduce client bundle by 30-40% (Next.js docs, 2025-11-15).

Wrong:
> React Server Components significantly reduce bundle size.

List sources in this format:
```markdown
## Sources

1. [Next.js 15 Documentation - Server Components](https://nextjs.org/docs/app/server-components) (Published: 2025-11-15, Type: Official)
2. [Performance Analysis: RSC vs CSR](https://example.com/article) (Published: 2025-10-20, Type: Blog)
3. [React RFC: Server Components](https://github.com/react/rfcs) (Published: 2024-12-01, Type: Official)
```

**Credibility**, most trusted first:
1. **Official documentation** (highest trust)
2. **Framework maintainer blogs** (high trust)
3. **Peer-reviewed articles** (high trust)
4. **Technical blogs** (medium trust; verify their claims)
5. **Forum posts** (low trust; verify against official sources)

**Recency**, the maximum age of a source:
- Fast-moving tech (frameworks, libraries): <6 months
- Architecture patterns: <12 months
- Security vulnerabilities: <1 month
- Performance benchmarks: <6 months, and name the environment

## Document Structure Requirements

### Required Sections

1. **Summary** (2-3 sentences)
   - Key finding
   - Recommendation
   - Impact

2. **Context** (1-2 paragraphs)
   - Problem statement
   - Why the research was needed
   - Scope: what it covers and what it leaves out

3. **Findings** (grouped by topic)
   - Analysis grounded in evidence
   - A source for each claim
   - Quantified comparisons
   - Tradeoffs

4. **Comparison** (a table)
   - Options side by side
   - Pros and cons
   - Fit for this project

5. **Recommendations** (in priority order)
   - Immediate (this sprint)
   - Short-term (next month)
   - Long-term (quarterly)

6. **Sources** (a numbered list)
   - Title, URL, publish date, type

### Optional Sections

- **Risk Assessment**, for an architectural change
- **Cost Analysis**, for infrastructure or licensing
- **Migration Path**, when the recommendation replaces something that exists

## Format Optimization Requirements

### Tables Over Prose

Right (a table):

| Approach | Latency | Throughput | Complexity |
|----------|---------|------------|------------|
| Current | 500ms | 100 req/s | Low |
| Option A | 200ms | 500 req/s | Medium |
| Option B | 150ms | 800 req/s | High |

Wrong (the same data as prose):
> The current approach has a latency of 500ms and throughput of 100 requests per second with low complexity. Option A reduces latency to 200ms and increases throughput to 500 requests per second but has medium complexity. Option B achieves the best performance with 150ms latency and 800 requests per second but has high complexity.

### Compressed Examples

Right (the pattern, with an ellipsis):
```javascript
const config = {
  api: { timeout: 5000, retries: 3 },
  ... // cache, logging, monitoring configs
}
```

Wrong (the full 15-line config):
```javascript
const config = {
  api: {
    timeout: 5000,
    retries: 3,
    ... [12 more lines]
  }
}
```

### Inline Lists for Simple Enumerations

Right: **Supported databases**: PostgreSQL, MySQL, MongoDB, Redis

Wrong: Supported databases: • PostgreSQL • MySQL • MongoDB • Redis (each on its own line)

## Objectivity Requirements

### Balanced Assessment

Always include the tradeoffs.

Right:
> GraphQL reduces over-fetching (fetch only needed fields) but increases backend complexity (schema design, resolver implementation, N+1 queries). Query performance depends on resolver optimization.

Wrong:
> GraphQL is the best solution for API design. It eliminates over-fetching and provides a great developer experience.

### Comparative Analysis

Show evidence, not opinions.

Right:
> Benchmark (Go 1.21, 16 cores): JSON parsing 450MB/s vs MessagePack 680MB/s (51% faster). MessagePack saves 30% bandwidth but requires schema coordination.

Wrong:
> MessagePack is much faster than JSON and should be used for all APIs.

## Evidence Requirements

### Primary Sources Preferred

Right:
> PostgreSQL 16 introduces parallel hash joins for partitioned tables (PostgreSQL 16 Release Notes, 2023-09-14). Benchmark: 3.2x faster for >10M rows (Postgres documentation).

Wrong:
> I heard PostgreSQL 16 is faster for large datasets.

### Quantify Everything

| Area | Write | Instead of |
|------|-------|------------|
| Performance | "3.2x faster (500ms to 156ms)" | "faster" |
| Performance | "handles 10K concurrent connections" | "scales well" |
| Performance | "p95 latency <50ms" | "low latency" |
| Cost | "$2000/month at 1M API calls" | "expensive" |
| Cost | "30% cost reduction vs current ($500 → $350/month)" | "cheap" |
| Complexity | "requires 3 new services, 2-week migration" | "complex" |
| Complexity | "single config change, zero downtime" | "simple" |

## Anti-Patterns

| Don't | Do |
|-------|----|
| Promotional language ("revolutionary", "game-changing") | A factual assessment with evidence |
| Full implementation code | Signatures, shapes and patterns, 2-3 lines at most |
| Subjective claims without attribution | A source behind every claim |
| Outdated sources (>6 months for fast-moving tech) | Recent, credible sources with publish dates |
| One-sided analysis (only pros, no cons) | A balanced assessment with tradeoffs |
| Vague recommendations ("consider using X") | Specific, actionable recommendations, each with a priority |
| No temporal naming (`research-findings.md`) | A YYYYMMDD prefix, always (`20251117-topic.md`) |

## Validation Checklist

Before you finish a research document, check:

- [ ] Temporal naming: `YYYYMMDD-description.md`
- [ ] Summary of 2-3 specific sentences
- [ ] A source for every claim
- [ ] A publish date for every source
- [ ] No marketing language (check the banned words)
- [ ] Quantified comparisons ("3x faster", not "faster")
- [ ] Comparisons in tables, not prose
- [ ] Code snippets of 3 lines or fewer, or a plain-language description instead
- [ ] Tradeoffs on both sides: pros and cons
- [ ] Recommendations in priority order (immediate, short-term, long-term)
- [ ] A Sources section with credibility indicators
- [ ] Token-optimized (40-70% reduction vs verbose)

## Examples

### A Good Excerpt

```markdown
# Research: PostgreSQL vs MongoDB for Time-Series Data

## Summary

PostgreSQL 14+ with TimescaleDB extension outperforms MongoDB for time-series workloads: 2.4x faster writes (12K vs 5K inserts/sec), 40% storage reduction via compression. Requires PostgreSQL expertise, 2-day migration.

## Findings

### Write Performance

**Evidence** (TimescaleDB benchmark, 2025-10-15):

| Database | Inserts/sec | Compression | Query Latency |
|----------|-------------|-------------|---------------|
| PostgreSQL + TimescaleDB | 12,000 | 60% | p95: 45ms |
| MongoDB (time-series) | 5,000 | 40% | p95: 120ms |

**Tradeoffs**:
- PostgreSQL: Faster, better compression, requires SQL expertise
- MongoDB: Flexible schema, simpler setup, higher storage cost

## Recommendations

**Immediate**: Use PostgreSQL + TimescaleDB for new time-series tables
**Migration**: 2-day effort, zero downtime via dual-write pattern

## Sources

1. [TimescaleDB vs MongoDB Benchmark](https://timescale.com/blog) (Published: 2025-10-15, Type: Vendor)
2. [PostgreSQL 14 Release Notes](https://postgresql.org) (Published: 2023-09-30, Type: Official)
```

### A Bad Excerpt

```markdown
# Research: Database Options

## Introduction

We need to find the best database for our application. There are many great options available today.

## Findings

PostgreSQL is a comprehensive and robust database solution that offers significant improvements over traditional approaches. It's widely used and very powerful.

MongoDB is also a fantastic choice with its elegant document model and seamless scalability. Many developers love using it.

## Recommendation

We should leverage the best database to optimize our data layer and enhance system performance.
```

What is wrong with it:
- No temporal naming
- Marketing language ("comprehensive", "robust", "significant", "fantastic", "elegant", "seamless")
- No source attribution
- Vague claims ("very powerful", "many developers")
- No quantified comparisons
- No tradeoffs
- A vague recommendation

---

`/whip-init` installs this file and skips it when a copy already exists; nothing refreshes it after
that. The full conventions are in `docs/acf/organization.md`.
