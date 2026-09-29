# Research Protocol

How to name a research document, which tool answers which question, and what the finished document
must contain.

## File Naming

Every research document must use a temporal name:

- **Format**: `docs/research/YYYYMMDD-description.md`
- **Date**: the current date as `YYYYMMDD`, with no hyphens inside the date
- **Description**: lowercase words joined by hyphens
- **Reference**: [Organization Conventions](organization.md#2-naming-conventions-temporal-vs-timeless)

| Filename | Verdict |
|---|---|
| `docs/research/20251117-postgresql-performance-tuning.md` | valid |
| `docs/research/20251030-figma-component-extraction.md` | valid |
| `docs/research/20251115-react-server-components.md` | valid |
| `docs/research/database-research.md` | invalid: no date |
| `docs/research/2025-11-17-performance.md` | invalid: hyphens in the date |
| `docs/research/PostgreSQL-Performance.md` | invalid: not lowercase |

Research goes stale: frameworks change and best practice moves on. The date in the name tells a
reader how old a finding is before they act on it. It also lets several snapshots of one topic sit
side by side, so a later retrospective can see what the team knew when it decided.

---

## Tool Selection Matrix

| Need | Tool | When to Use |
|------|------|-------------|
| UI/UX design analysis | Figma MCP | Required whenever the task gives a Figma link or node |
| Library documentation | Context7 | Adding new libraries, updating versions, API questions |
| Best practices | Perplexity | Architecture, patterns, industry standards |
| Security research | Perplexity | Vulnerabilities, patches, security practices |
| Performance research | Perplexity | Optimization techniques, benchmarks |
| Technology comparison | Perplexity | Evaluating alternatives, migration paths |
| Code examples | Context7 | Library usage patterns, implementation examples |

---

## Figma MCP Usage (mcp__figma-dev-mode-mcp-server)

### When Figma Is Required

1. **The task includes a Figma URL or node.** If a task mentions a Figma design or links to one,
   extract the node ID and analyze the design before any other work. Figma always goes first when a
   Figma reference exists.

2. **Node ID extraction.** The URL writes the node ID with a hyphen; the tools take a colon:
   ```
   URL: https://figma.com/design/:fileKey/:fileName?node-id=1-2
   Extract: nodeId = "1:2" (replace - with :)
   Call: get_code(nodeId="1:2")
   ```

3. **Design analysis flow.** Call the three tools in this order:
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

1. When a task gives a Figma URL or node, use the Figma tools.
2. Never skip Figma analysis on a UI task that has a design.
3. Extract node IDs from URLs before calling any tool.
4. Put what the design tells you into the task descriptions.
5. Name the specific Figma nodes in implementation tasks.

### Common Figma Patterns

| Request | Steps |
|---|---|
| Full page: "Implement dashboard from [Figma URL]" | Extract the node ID; `get_code()` for component structure; `get_variable_defs()` for styling; create tasks carrying the design specs |
| Component update: "Update button component per Figma" | `get_code()` for the new design; compare it with the current implementation; create a migration task |
| Design system sync: "Sync design tokens from Figma" | `get_variable_defs()` for all tokens; create token update tasks; include the CSS variable mappings |

---

## Context7 Usage (mcp__context7)

### When Context7 Is Required

1. **Adding a library.** Before you install it, use Context7 to learn its API, usage patterns and
   recommended practice, then implement with those patterns.
2. **Updating a library.** Before you change the version, check the breaking changes and the
   migration guide, then update the code to match.
3. **Usage questions.** For "how do I do X with library Y?", look up the current documentation in
   Context7.
4. **Possible deprecations.** When a method might be deprecated, check it in Context7 and use the
   recommended replacement.

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

### When Perplexity Is Required

| Case | Example query | Recency | Focus |
|---|---|---|---|
| Architecture decisions | "Microservices vs monolith for [use case]?" | `month` | Scalability, complexity, team size |
| Best practices | "[Framework] best practices [year]" | `week` | Recent patterns, performance |
| Security research | "[Technology] security vulnerabilities [year]" | `day` | Latest exploits, mitigations |
| Performance optimization | "[Specific performance issue]" | `month` | Optimization techniques, benchmarks |

### Perplexity Protocol

```javascript
mcp__perplexity__perplexity_search_web {
  query: "[framework/technology] [specific topic] [year]",
  recency: "day" | "week" | "month" | "year"
}
```

Pick the recency filter by how fast the answer changes:
- `day`: breaking changes, security patches, critical bugs
- `week`: recent releases, new features, emerging patterns
- `month`: best practices, architecture patterns (the default)
- `year`: historical context, stable patterns

---

## Research Synthesis Requirements

### Document Structure

````markdown
# Research: [Topic]

## Summary

Key findings (2-3 sentences)

## Context

**Why this research was needed**:
- Problem statement
- Limits of the current approach
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
1. [Small, high-impact change that can land this sprint]
2. [Security or performance fix]

**Short-term** (Next month):
1. [Feature change the findings support]
2. [Optimization the findings justify]

**Long-term** (Quarterly):
1. [Architecture change]
2. [Scaling work]

## Implementation Path

**Next Steps**:
1. Create a task in the store's `pending` state (`.backlog/pending/` on the default `files` store)
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
````

### Style Requirements

Follow `docs/acf/style/research-documents.md`:
- State facts directly, with no promotional language.
- Attribute every claim to a source.
- Weigh tradeoffs, not only benefits.
- Prefer tables to prose; they cost fewer tokens.
- Keep examples to 2-3 lines.

Forbidden:
- Marketing language ("comprehensive", "robust", "elegant")
- Implementation code (show signatures and shapes only)
- Subjective claims without evidence
- Outdated sources (older than 1 year for fast-moving tech)

---

## Project Context Awareness

Before starting research, read:
1. `README.md` - Project overview, tech stack
2. `CLAUDE.md` - Project-specific conventions
3. `package.json` / `go.mod` / `requirements.txt` - Current dependencies
4. `docs/architecture/` - Existing architecture decisions
5. `docs/development/` - Development patterns

Then check that the research is relevant:
- Does it apply to {project_name}'s tech stack?
- Does it solve a real project need?
- Is it compatible with the existing architecture?
- What is the migration path from the current state?

---

## Common Research Anti-Patterns

| Don't | Do |
|---|---|
| Research with no project context | Tailor the research to {project_name}'s needs |
| Include full implementation code | Show signatures, shapes and patterns (2-3 lines max) |
| Use outdated sources for fast-moving tech | Prefer sources from the last 6 months and cross-reference 3 or more |
| Skip Figma MCP when a Figma URL is provided | Analyze the Figma design first on every design task |
| Create research docs without a temporal name | Always use the `YYYYMMDD-description.md` format |
| Finish research without a follow-up task | Create a task from the findings in the store's `pending` state (`.backlog/pending/` on `files`) |

---

## Integration with ACF Workflow

Research → Task → Implementation:
1. `/research "topic"` writes `YYYYMMDD-topic.md` and a follow-up task.
2. `/task` reads the research doc and decomposes it into subtasks.
3. `/go` executes the tasks and implements the findings.

Quality gates:
- The research doc must pass the style guide's validation checklist.
- Sources must be credible and recent.
- Recommendations must be specific enough to act on.
- The follow-up task must reference the research doc.

---

**Last Updated**: Auto-maintained during /whip-init
**Source**: Template customized for {project_name}
