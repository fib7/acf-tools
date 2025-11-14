# Research Documentation Style

## For: research-agent when creating research documents in docs/research/

## Core Principles

- **Tone**: Direct, factual analysis (no promotional language)
- **Evidence**: Every claim backed by source attribution
- **Objectivity**: Balanced assessment with tradeoffs
- **Recency**: Sources from last 6 months for fast-moving tech
- **Density**: Token-optimized (tables > prose)

---

## Temporal Naming (MANDATORY)

**ALL research documents MUST follow**:
- **Format**: `docs/research/YYYYMMDD-description.md`
- **Date**: Current date in YYYYMMDD (NO hyphens in date)
- **Description**: lowercase, hyphen-separated
- **Reference**: See `docs/acf/organization.md`

**Examples**:
- ✅ `20251117-postgresql-query-optimization.md`
- ✅ `20251030-react-server-components-patterns.md`
- ❌ `2025-11-17-research.md` (hyphens in date)
- ❌ `research-findings.md` (missing date)

---

## Banned Language (Marketing Speak)

**NEVER use these words**:
- "comprehensive", "systematic", "significant", "substantial", "robust", "elegant", "seamless"
- "achievement", "progress", "improvement" (unless quantified with metrics)
- "enhance", "optimize", "streamline" (be specific: "Reduce latency from 500ms to 200ms")
- "leverage", "utilize" (use "use")
- "facilitate", "enable" (be direct about what happens)
- "cutting-edge", "state-of-the-art", "best-in-class"

---

## Required Language (Precise, Testable)

**ALWAYS use**:
- **Quantified**: "Reduces query time from 500ms to 200ms" NOT "improves performance"
- **Specific**: "PostgreSQL JSONB indexes" NOT "database optimization"
- **Testable**: "Handles 1000 concurrent connections" NOT "scales well"
- **Comparative**: "15% faster than Approach A" NOT "very fast"
- **Sourced**: "Per Next.js docs (2025-11-15)" NOT "common practice"

---

## Code Snippet Policy

**ABSOLUTE PROHIBITIONS**:
- ❌ Function/method implementations
- ❌ Algorithm pseudocode (use natural language description)
- ❌ Configuration file contents >3 lines (describe what, not exact content)
- ❌ Database queries (specify data requirements)
- ❌ API call sequences (describe workflow outcomes)
- ❌ Multi-file code examples (show pattern, not full implementation)

**ALLOWED** (sparingly, 2-3 lines maximum):
- ✅ API endpoint signatures: `POST /api/v1/resource`
- ✅ Response shape: `{"id": "uuid", "status": "pending"}`
- ✅ Error codes: `Returns 400 for invalid input`
- ✅ Type signatures: `func Process(input []byte) (*Result, error)`
- ✅ CLI commands: `npm install library@latest`

**Example compression**:

❌ **Wrong** (10 lines of implementation):
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

✅ **Correct** (natural language):
> Query optimization uses two-tier caching: in-memory (5min TTL) and Redis (1hr TTL). Cache key is query hash. Returns cached result if valid, otherwise executes query and updates cache.

---

## Source Attribution Requirements

**Every claim needs attribution**:

✅ **Correct**:
> React Server Components reduce client bundle by 30-40% (Next.js docs, 2025-11-15).

❌ **Wrong**:
> React Server Components significantly reduce bundle size.

**Source format**:
```markdown
## Sources

1. [Next.js 15 Documentation - Server Components](https://nextjs.org/docs/app/server-components) (Published: 2025-11-15, Type: Official)
2. [Performance Analysis: RSC vs CSR](https://example.com/article) (Published: 2025-10-20, Type: Blog)
3. [React RFC: Server Components](https://github.com/react/rfcs) (Published: 2024-12-01, Type: Official)
```

**Credibility hierarchy**:
1. **Official documentation** (highest trust)
2. **Framework maintainer blogs** (high trust)
3. **Peer-reviewed articles** (high trust)
4. **Technical blogs** (medium trust, verify claims)
5. **Forum posts** (low trust, verify with official sources)

**Recency requirements**:
- Fast-moving tech (frameworks, libraries): <6 months
- Architecture patterns: <12 months
- Security vulnerabilities: <1 month
- Performance benchmarks: <6 months (specify environment)

---

## Document Structure Requirements

### Required Sections

1. **Summary** (2-3 sentences)
   - Key finding
   - Recommendation
   - Impact

2. **Context** (1-2 paragraphs)
   - Problem statement
   - Why research was needed
   - Scope (what's covered, what's not)

3. **Findings** (structured by topic)
   - Evidence-based analysis
   - Source attribution for each claim
   - Quantified comparisons
   - Tradeoffs

4. **Comparison** (table format)
   - Side-by-side analysis
   - Pros/cons
   - Fit for project

5. **Recommendations** (prioritized)
   - Immediate (this sprint)
   - Short-term (next month)
   - Long-term (quarterly)

6. **Sources** (numbered list)
   - Title, URL, publish date, type

### Optional Sections

- **Risk Assessment** (if architectural change)
- **Cost Analysis** (if infrastructure/licensing)
- **Migration Path** (if replacing existing)

---

## Format Optimization Requirements

### Tables Over Prose

✅ **Correct** (table, 60% token reduction):
| Approach | Latency | Throughput | Complexity |
|----------|---------|------------|------------|
| Current | 500ms | 100 req/s | Low |
| Option A | 200ms | 500 req/s | Medium |
| Option B | 150ms | 800 req/s | High |

❌ **Wrong** (prose, verbose):
> The current approach has a latency of 500ms and throughput of 100 requests per second with low complexity. Option A reduces latency to 200ms and increases throughput to 500 requests per second but has medium complexity. Option B achieves the best performance with 150ms latency and 800 requests per second but has high complexity.

### Compressed Examples

✅ **Correct** (pattern with ellipsis):
```javascript
const config = {
  api: { timeout: 5000, retries: 3 },
  ... // cache, logging, monitoring configs
}
```

❌ **Wrong** (full 15-line config):
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

✅ **Correct**: **Supported databases**: PostgreSQL, MySQL, MongoDB, Redis
❌ **Wrong**: Supported databases: • PostgreSQL • MySQL • MongoDB • Redis (each on new line)

---

## Objectivity Requirements

### Balanced Assessment

**ALWAYS include tradeoffs**:

✅ **Correct**:
> GraphQL reduces over-fetching (fetch only needed fields) but increases backend complexity (schema design, resolver implementation, N+1 queries). Query performance depends on resolver optimization.

❌ **Wrong**:
> GraphQL is the best solution for API design. It eliminates over-fetching and provides a great developer experience.

### Comparative Analysis

**Show evidence, not opinions**:

✅ **Correct**:
> Benchmark (Go 1.21, 16 cores): JSON parsing 450MB/s vs MessagePack 680MB/s (51% faster). MessagePack saves 30% bandwidth but requires schema coordination.

❌ **Wrong**:
> MessagePack is much faster than JSON and should be used for all APIs.

---

## Evidence Requirements

### Primary Sources Preferred

✅ **Correct**:
> PostgreSQL 16 introduces parallel hash joins for partitioned tables (PostgreSQL 16 Release Notes, 2023-09-14). Benchmark: 3.2x faster for >10M rows (Postgres documentation).

❌ **Wrong**:
> I heard PostgreSQL 16 is faster for large datasets.

### Quantify Everything

**Performance**:
- NOT "faster" → USE "3.2x faster (500ms to 156ms)"
- NOT "scales well" → USE "handles 10K concurrent connections"
- NOT "low latency" → USE "p95 latency <50ms"

**Cost**:
- NOT "expensive" → USE "$2000/month at 1M API calls"
- NOT "cheap" → USE "30% cost reduction vs current ($500 → $350/month)"

**Complexity**:
- NOT "complex" → USE "requires 3 new services, 2-week migration"
- NOT "simple" → USE "single config change, zero downtime"

---

## Anti-Patterns

❌ **Don't**: Promotional language ("revolutionary", "game-changing")
✅ **Do**: Factual assessment with evidence

❌ **Don't**: Include full implementation code
✅ **Do**: Show signatures, shapes, patterns (2-3 lines max)

❌ **Don't**: Subjective claims without attribution
✅ **Do**: Every claim backed by source

❌ **Don't**: Outdated sources (>6 months for fast-moving tech)
✅ **Do**: Recent, credible sources with publish dates

❌ **Don't**: One-sided analysis (only pros, no cons)
✅ **Do**: Balanced assessment with tradeoffs

❌ **Don't**: Vague recommendations ("consider using X")
✅ **Do**: Specific, actionable recommendations with priority

❌ **Don't**: Missing temporal naming (`research-findings.md`)
✅ **Do**: Always YYYYMMDD prefix (`20251117-topic.md`)

---

## Validation Checklist

Before finalizing research document:

- [ ] Temporal naming: `YYYYMMDD-description.md`
- [ ] Summary (2-3 sentences, specific)
- [ ] All claims have source attribution
- [ ] Sources include publish dates
- [ ] No marketing language (check banned words)
- [ ] Quantified comparisons (not "faster", use "3x faster")
- [ ] Tables used for comparisons (not prose)
- [ ] Code snippets ≤3 lines (or natural language description)
- [ ] Balanced tradeoffs (pros AND cons)
- [ ] Recommendations prioritized (immediate/short/long-term)
- [ ] Sources section with credibility indicators
- [ ] Token-optimized (40-70% reduction vs verbose)

---

## Examples

### ✅ GOOD Research Document Excerpt

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

### ❌ BAD Research Document Excerpt

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

**Problems**:
- ❌ No temporal naming
- ❌ Marketing language ("comprehensive", "robust", "significant", "fantastic", "elegant", "seamless")
- ❌ No source attribution
- ❌ Vague claims ("very powerful", "many developers")
- ❌ No quantified comparisons
- ❌ No tradeoffs
- ❌ Vague recommendation

---

**Last Updated**: Auto-maintained during /whip-init
**Reference**: See `docs/acf/organization.md` for full conventions
