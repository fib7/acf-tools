# Research Protocol

## Naming Convention (MANDATORY)

**ALL research documents MUST use temporal naming**:

- **Format**: `docs/research/YYYYMMDD-description.md`
- **Date**: Current date in YYYYMMDD format (NO hyphens in date portion)
- **Description**: lowercase, hyphen-separated topic
- **Reference**: See [Organization Conventions](organization.md#2-naming-conventions-temporal-vs-timeless)

**Examples**:
- ✅ `docs/research/20251117-postgresql-performance-tuning.md`
- ✅ `docs/research/20251030-figma-component-extraction.md`
- ✅ `docs/research/20251115-react-server-components.md`
- ❌ `docs/research/database-research.md` (missing date)
- ❌ `docs/research/2025-11-17-performance.md` (hyphens in date)
- ❌ `docs/research/PostgreSQL-Performance.md` (not lowercase)

**Why temporal naming**:
- Research findings are time-bound (frameworks evolve, best practices change)
- Multiple snapshots track evolution of understanding
- Clear historical context (avoid outdated guidance)
- Enables retrospective analysis

---

## Tool Selection Matrix

| Need | Tool | When to Use |
|------|------|-------------|
| **UI/UX Design Analysis** | Figma MCP | **MANDATORY** when Figma links/nodes provided |
| **Library Documentation** | Context7 | Adding new libraries, updating versions, API questions |
| **Best Practices** | Perplexity | Architecture, patterns, industry standards |
| **Security Research** | Perplexity | Vulnerabilities, patches, security practices |
| **Performance Research** | Perplexity | Optimization techniques, benchmarks |
| **Technology Comparison** | Perplexity | Evaluating alternatives, migration paths |
| **Code Examples** | Context7 | Library usage patterns, implementation examples |

---

## Figma MCP Usage (mcp__figma-dev-mode-mcp-server)

### 🎨 MANDATORY Use Cases

1. **Task Includes Figma URL/Node**
   ```
   Trigger: Task mentions Figma design or includes Figma link
   Action: MUST extract node ID and analyze BEFORE any other work
   Priority: ALWAYS FIRST when Figma reference exists
   ```

2. **Node ID Extraction**
   ```
   URL: https://figma.com/design/:fileKey/:fileName?node-id=1-2
   Extract: nodeId = "1:2" (replace - with :)
   Call: get_code(nodeId="1:2")
   ```

3. **Design Analysis Flow**
   ```javascript
   // 1. Get component code
   mcp__figma-dev-mode-mcp-server__get_code {
     nodeId: "123:456",
     clientFrameworks: "react,nextjs",
     clientLanguages: "typescript,html,css"
   }

   // 2. Get design tokens/variables
   mcp__figma-dev-mode-mcp-server__get_variable_defs {
     nodeId: "123:456"
   }

   // 3. Get screenshot for visual reference
   mcp__figma-dev-mode-mcp-server__get_screenshot {
     nodeId: "123:456"
   }
   ```

### Figma Integration Protocol

**CRITICAL RULES**:
1. **ALWAYS** use Figma tools when URL/node provided
2. **NEVER** skip Figma analysis for UI tasks with designs
3. **EXTRACT** node IDs from URLs before calling tools
4. **INCLUDE** design insights in task descriptions
5. **REFERENCE** specific Figma nodes in implementation tasks

### Common Figma Patterns

**Pattern 1: Full Page Implementation**
```
Input: "Implement dashboard from [Figma URL]"
1. Extract node ID from URL
2. get_code() for component structure
3. get_variable_defs() for styling
4. Create tasks with design specs
```

**Pattern 2: Component Update**
```
Input: "Update button component per Figma"
1. get_code() for new design
2. Compare with existing implementation
3. Create migration task
```

**Pattern 3: Design System Sync**
```
Input: "Sync design tokens from Figma"
1. get_variable_defs() for all tokens
2. Create token update tasks
3. Include CSS variable mappings
```

---

## Context7 Usage (mcp__context7)

### MANDATORY Use Cases

1. **Adding New Libraries**
   ```
   Before: Installing new library
   Action: Use Context7 to understand API, patterns, best practices
   After: Implement with correct patterns
   ```

2. **Updating Existing Libraries**
   ```
   Before: Updating library version
   Action: Check breaking changes, migration guide
   After: Update code for compatibility
   ```

3. **Resolving Usage Questions**
   ```
   Question: "How to implement X with library Y?"
   Action: Context7 lookup for current documentation
   Result: Accurate, up-to-date implementation
   ```

4. **Checking Deprecations**
   ```
   Warning: Method might be deprecated
   Action: Verify with Context7
   Result: Use recommended alternative
   ```

### Context7 Protocol

```javascript
// 1. Resolve library ID
mcp__context7__resolve-library-id {
  libraryName: "library-name"
}

// 2. Get documentation
mcp__context7__get-library-docs {
  context7CompatibleLibraryID: "/org/project",
  topic: "specific feature"
}
```

### {project_name} Specific Libraries

**{tech_stack} Stack**:

{backend_libraries}
{frontend_libraries}

---

## Perplexity Usage (mcp__perplexity)

### MANDATORY Use Cases

1. **Architecture Decisions**
   ```
   Question: "Microservices vs monolith for [use case]?"
   Filter: recency=month
   Focus: Scalability, complexity, team size
   ```

2. **Best Practices Research**
   ```
   Topic: "[Framework] best practices [year]"
   Filter: recency=week
   Focus: Recent patterns, performance
   ```

3. **Security Research**
   ```
   Issue: "[Technology] security vulnerabilities [year]"
   Filter: recency=day
   Focus: Latest exploits, mitigations
   ```

4. **Performance Optimization**
   ```
   Problem: "[Specific performance issue]"
   Filter: recency=month
   Focus: Optimization techniques, benchmarks
   ```

### Perplexity Protocol

```javascript
mcp__perplexity__perplexity_search_web {
  query: "[framework/technology] [specific topic] [year]",
  recency: "day" | "week" | "month" | "year"
}
```

**Recency Guidelines**:
- `day`: Breaking changes, security patches, critical bugs
- `week`: Recent releases, new features, emerging patterns
- `month`: Best practices, architecture patterns (default)
- `year`: Historical context, stable patterns

---

## Research Synthesis Requirements

### Document Structure

```markdown
# Research: [Topic]

## Summary

Key findings (2-3 sentences)

## Context

**Why this research matters**:
- Problem statement
- Current approach limitations
- Research objectives

**Scope**:
- What's covered
- What's out of scope
- Key questions

## Findings

### Finding 1: [Specific Pattern/Solution]

**Evidence**:
- Source 1: [Link] (Published: YYYY-MM-DD, Credibility: Official docs | Blog | Forum)
- Source 2: [Link] (Published: YYYY-MM-DD)
- Source 3: [Link] (Published: YYYY-MM-DD)

**Analysis**:
- Key insight
- Quantified benefits (performance, cost, complexity)
- Tradeoffs

**Code Signature** (2-3 lines max):
```typescript
// Type signature or API shape only (NOT implementation)
interface Example { ... }
```

### Finding 2: [Alternative Approach]

[Similar structure]

## Comparison

| Approach | Pros | Cons | Fit for {project_name} |
|----------|------|------|------------------------|
| Current  | ... | ... | ... |
| Option 1 | ... | ... | ... |
| Option 2 | ... | ... | ... |

## Recommendations

**Immediate** (This sprint):
1. Quick win with high impact
2. Security/performance fix

**Short-term** (Next month):
1. Feature enhancement
2. Optimization opportunity

**Long-term** (Quarterly):
1. Architecture evolution
2. Scaling preparation

## Implementation Path

**Next Steps**:
1. Create task in `.backlog/pending/`
2. Reference this research doc
3. Include specific acceptance criteria

**Acceptance Criteria** (for generated task):
- [ ] Specific, measurable outcome 1
- [ ] Specific, measurable outcome 2
- [ ] Documentation updated

## Sources

1. [Source Title] - [URL] (Published: YYYY-MM-DD, Type: Official | Blog | Forum)
2. [Source Title] - [URL] (Published: YYYY-MM-DD)
3. ...

**Source Quality Requirements**:
- Prefer official documentation
- Recency within 6 months (for fast-moving tech)
- Cross-reference 3+ sources for critical decisions
```

### Style Requirements

**Follow** `docs/acf/style/research-documents.md`:
- Direct, factual analysis (no promotional language)
- Evidence-based claims with source attribution
- Objective assessment with tradeoffs
- Token-optimized (tables > prose)
- Compressed examples (2-3 lines max)

**Forbidden**:
- Marketing language ("comprehensive", "robust", "elegant")
- Implementation code (show signatures/shapes only)
- Subjective claims without evidence
- Outdated sources (>1 year for fast-moving tech)

---

## Project Context Awareness

**Before starting research**, review:
1. `README.md` - Project overview, tech stack
2. `CLAUDE.md` - Project-specific conventions
3. `package.json` / `go.mod` / `requirements.txt` - Current dependencies
4. `docs/architecture/` - Existing architecture decisions
5. `docs/development/` - Development patterns

**Research relevance filter**:
- Does this apply to {project_name}'s tech stack?
- Does this solve an actual project need?
- Is this compatible with existing architecture?
- What's the migration path from current state?

---

## Common Research Anti-Patterns

❌ **Don't**: Generic research without project context
✅ **Do**: Research tailored to {project_name}'s specific needs

❌ **Don't**: Include full implementation code
✅ **Do**: Show signatures, shapes, patterns (2-3 lines max)

❌ **Don't**: Use outdated sources for fast-moving tech
✅ **Do**: Prefer sources from last 6 months, cross-reference 3+

❌ **Don't**: Skip Figma MCP when Figma URL provided
✅ **Do**: MANDATORY Figma analysis for design tasks

❌ **Don't**: Create research docs without temporal naming
✅ **Do**: Always use `YYYYMMDD-description.md` format

❌ **Don't**: Research without creating follow-up task
✅ **Do**: Generate task in `.backlog/pending/` from findings

---

## Integration with ACF Workflow

**Research → Task → Implementation**:
1. `/research "topic"` → Creates `YYYYMMDD-topic.md` + task
2. `/task` reads research doc → Decomposes into subtasks
3. `/go` executes tasks → Implements findings

**Quality Gates**:
- Research doc must pass style guide validation
- Sources must be credible and recent
- Recommendations must be specific and actionable
- Follow-up task must reference research doc

---

**Last Updated**: Auto-maintained during /whip-init
**Source**: Template customized for {project_name}
