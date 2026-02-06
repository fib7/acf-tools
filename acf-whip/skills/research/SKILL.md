---
name: research
description: Conduct research using MCP tools, create temporal documentation, generate backlog task
argument-hint: "[topic]"
allowed-tools:
  - Bash
  - Grep
  - Glob
  - Read
  - Task
  - TodoWrite
  - mcp__perplexity__perplexity_search_web
  - mcp__context7__resolve-library-id
  - mcp__context7__get-library-docs
  - mcp__figma-dev-mode-mcp-server__get_code
  - mcp__figma-dev-mode-mcp-server__get_variable_defs
  - mcp__figma-dev-mode-mcp-server__get_screenshot
---

# /research - Research Workflow

Research command. Delegates to research-agent for structured research using MCP tools (Perplexity, Context7, Figma).

## Purpose

Single-phase research workflow:
1. Launch research-agent for comprehensive research
2. Create temporal documentation (`docs/research/YYYYMMDD-topic.md`)
3. Automatically generate backlog task from findings

## Temporal Naming (MANDATORY)

**ALL research documents MUST follow temporal naming convention**:

- **Format**: `docs/research/YYYYMMDD-description.md`
- **Date**: Current date in YYYYMMDD format (NO hyphens in date portion)
- **Description**: lowercase, hyphen-separated topic
- **Reference**: See `docs/acf/organization.md` (Section 2: Temporal vs Timeless)

**Examples**:
- ✅ `docs/research/20251117-postgresql-performance-tuning.md`
- ✅ `docs/research/20251030-figma-component-extraction.md`
- ✅ `docs/research/20251115-nextjs-server-components.md`
- ❌ `docs/research/database-research.md` (missing date)
- ❌ `docs/research/2025-11-17-performance.md` (hyphens in date)
- ❌ `docs/research/PostgreSQL-Performance.md` (not lowercase)

## Execution Flow

### Step 1: Verify Prerequisites

```bash
if [ ! -d ".backlog" ]; then
  echo "Error: .backlog/ directory not found. Run /whip-init first."
  exit 1
fi

if [ ! -f "docs/acf/research-protocol.md" ]; then
  echo "Warning: Research protocol not found. Run /whip-init to install."
fi

if [ ! -f "docs/acf/organization.md" ]; then
  echo "Error: Organization conventions not found. Install acf-librarian plugin."
  exit 1
fi
```

### Step 2: Parse Research Scope

Extract topic from user input:
```bash
# User provides: /research "Next.js 15 server components best practices"
topic="Next.js 15 server components best practices"

# Sanitize for filename: lowercase, hyphens, alphanumeric only
filename_topic=$(echo "$topic" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g')
# Result: "nextjs-15-server-components-best-practices"
```

### Step 3: Generate Temporal Filename

```bash
# Get current date in YYYYMMDD format
current_date=$(date +%Y%m%d)

# Construct temporal filename
research_file="docs/research/${current_date}-${filename_topic}.md"
# Example: "docs/research/20251117-nextjs-15-server-components-best-practices.md"

echo "📝 Research document: $research_file"
```

### Step 4: Create Todo

```markdown
TodoWrite: Single todo for research task
- Content: "Research: {topic}"
- Status: in_progress
- ActiveForm: "Researching {topic}"
```

### Step 5: Launch research-agent

Use Task tool to delegate to research-agent:

```markdown
**Task**: Conduct comprehensive research on: {topic}

**Research Protocol**: Follow `docs/acf/research-protocol.md` for tool selection and synthesis requirements

**Tool Selection** (from research-protocol.md):
- **Figma MCP**: MANDATORY if Figma URL/node provided in topic
  - Extract node ID from URL
  - Use get_code() for component specs
  - Use get_variable_defs() for design tokens
  - Use get_screenshot() for visual reference
- **Context7**: Library documentation, API references, framework guides
  - Resolve library ID first
  - Request topic-specific documentation
  - Prefer official docs over blog posts
- **Perplexity**: Best practices, architecture patterns, security, performance
  - Use recency filter: "day" (breaking changes), "week" (recent releases), "month" (standard)
  - Cross-reference multiple sources
  - Prioritize official sources and technical depth

**Temporal Filename (MANDATORY)**:
- Output file: `{research_file}`
- Format enforced: YYYYMMDD-description.md
- NO hyphens in date portion
- Lowercase, hyphen-separated description

**Deliverable**:
Create research document at `{research_file}` with:
1. **Summary**: Key findings (2-3 sentences)
2. **Context**: Why this research matters (1-2 paragraphs)
3. **Findings**: Structured analysis with evidence
   - Use tables for comparisons
   - Quote relevant documentation
   - Include code signatures (NOT implementations)
   - Quantify performance/tradeoffs
4. **Recommendations**: Specific, actionable guidance
5. **Sources**: Links with recency dates
6. **Implementation Path**: Create task in `.backlog/pending/` based on findings

**Style Requirements**: Follow `docs/acf/style/research-documents.md`
- Direct, factual analysis (no promotional language)
- Evidence-based claims
- Objective assessment with tradeoffs
- Token-optimized (tables > prose, compressed examples)

**Backlog Task Creation (MANDATORY)**:
After completing research, create task in `.backlog/pending/` using task-engineer pattern:
- Reference research document in Documentation field
- Set priority based on findings (high/medium/low)
- Include specific acceptance criteria from research
- Assign to appropriate specialist agent
```

### Step 6: Exit

Research-agent handles:
- MCP tool usage
- Research synthesis
- Documentation creation (temporal naming enforced)
- Backlog task generation

## Usage Examples

### Basic Research
```bash
/research "Next.js 15 server components best practices for video processing"
```
Output: `docs/research/20251117-nextjs-15-server-components-best-practices-for-video-processing.md`

### Library Documentation Research
```bash
/research "Prisma query optimization patterns for PostgreSQL time-series data"
```
Uses Context7 for Prisma docs, creates: `docs/research/20251117-prisma-query-optimization-patterns-for-postgresql-time-series-data.md`

### Figma Component Research
```bash
/research "UI component from Figma: https://figma.com/design/ABC123/node-id=1-2"
```
Uses Figma MCP (MANDATORY), creates: `docs/research/20251117-ui-component-from-figma.md`

### Architecture Research
```bash
/research "Compare event-driven vs request-response for microservices communication"
```
Uses Perplexity with architecture focus, creates: `docs/research/20251117-compare-event-driven-vs-request-response-for-microservices-communication.md`

## Success Criteria

✅ Research document created with temporal naming: `YYYYMMDD-topic.md`
✅ MCP tools used appropriately (Figma/Context7/Perplexity)
✅ Evidence-based analysis with sources
✅ Backlog task created in `.backlog/pending/`
✅ Task references research document
✅ Recommendations are specific and actionable

## Anti-Patterns

❌ **Don't**: Create research docs without dates
✅ **Do**: Always use `YYYYMMDD-description.md` format

❌ **Don't**: Skip Figma MCP when Figma URL provided
✅ **Do**: MANDATORY Figma usage for design research

❌ **Don't**: Use generic filenames like "research-findings.md"
✅ **Do**: Descriptive topic: "20251117-nextjs-server-components.md"

❌ **Don't**: Include implementation code in research docs
✅ **Do**: Show signatures, shapes, patterns only (2-3 lines max)

❌ **Don't**: Skip backlog task creation
✅ **Do**: Always create task from research findings

## Output Format

```
🔍 Research Started

Topic: Next.js 15 server components best practices
Temporal file: docs/research/20251117-nextjs-server-components-best-practices.md

Phase 1: Tool Selection
- Context7: Resolving Next.js library documentation...
- Perplexity: Searching best practices (recency: week)...

Phase 2: Research Synthesis
- Analyzing findings...
- Comparing approaches...
- Documenting recommendations...

Phase 3: Documentation
- Created: docs/research/20251117-nextjs-server-components-best-practices.md
- Sections: Summary, Context, Findings, Recommendations, Sources

Phase 4: Task Creation
- Created task: frontend-042-implement-server-components (medium priority)
- Location: .backlog/pending/frontend-042-implement-server-components.md
- References: docs/research/20251117-nextjs-server-components-best-practices.md

✅ Research complete. Review document and task in .backlog/pending/
```

## Integration with ACF Workflow

**Research → Task → Implementation**:
1. `/research "topic"` → Creates research doc + task
2. `/task` reads research doc → Decomposes into subtasks
3. `/go` executes tasks → Implements findings

**Documentation Conventions**:
- Research docs are TEMPORAL (YYYYMMDD prefix)
- Architecture docs are TIMELESS (update in place)
- See `docs/acf/organization.md` for full conventions
