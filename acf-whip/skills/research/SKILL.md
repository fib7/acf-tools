---
name: research
description: Research a topic with MCP tools (Perplexity, Context7, Figma), write a temporal (YYYYMMDD-dated) research document, and generate a backlog task from the findings
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

`/research <topic>` hands the topic to research-agent. It researches with MCP tools (Perplexity,
Context7, Figma), writes one dated document under `docs/research/`, and files a follow-up task in
the backlog based on what it found.

> **Task store**: Step 1 prints the active store as a `Task store: <name>` line, and Step 5 passes
> that name to research-agent. On the default `files` store the follow-up task goes straight into
> `.backlog/pending/`. On any other store research-agent stages it under the gitignored
> `.acfwhip/run/staging/` (or a system temp dir when that path is not ignored) and ingests it with
> `acfw-store create --file <path> --folder pending`. It never creates or tests `.backlog/` there:
> those stores have no such directory, and a task written into one is invisible to them.

## Temporal Naming (required)

Every research document is named `docs/research/YYYYMMDD-description.md`:

- **Date**: the current date as YYYYMMDD, with no hyphens inside the date
- **Description**: the topic, lowercase and hyphen-separated
- **Reference**: `docs/acf/organization.md` (Section 2: Temporal vs Timeless) covers the wider
  convention. The optional acf-librarian plugin installs it; the rules here are complete without it.

**Right**:
- `docs/research/20251117-postgresql-performance-tuning.md`
- `docs/research/20251030-figma-component-extraction.md`
- `docs/research/20251115-nextjs-server-components.md`

**Wrong**:
- `docs/research/database-research.md` (no date)
- `docs/research/2025-11-17-performance.md` (hyphens in the date)
- `docs/research/PostgreSQL-Performance.md` (not lowercase)

## Execution Flow

### Step 1: Verify Prerequisites

```bash
# Resolve the task store BEFORE testing for .backlog/. That directory is where the `files` store keeps
# its tasks and nowhere else: on beads/multica/linear or a third-party adapter it does not exist by
# design, so the unconditional test that stood here refused every non-files project, contradicting the
# task-store note above.
# Resolve ONLY what /research depends on. `acfw-store info` is not that: it also resolves the /go-only
# pins (ACFW_GO_BARE, ACFW_EFFORT_SHELL) and exits 2 before printing anything on a bad one, so a typo
# in a setting this skill never reads stopped research with a false "store could not be resolved".
# acfw_resolve_store is the dispatcher's own precedence (ACFW_STORE env > config > files) against the
# dispatcher's own root (ACFW_TRUNK_ROOT, else the git toplevel), and it never fails. It runs in a bash
# child because the lib is bash and the shell executing this block may not be.
# The plugin root is written in its BRACED form everywhere in this block, never as a bare $-name:
# Claude Code substitutes the braced form into the skill text when it loads the skill, and only that
# form. The Bash tool's environment does not carry the variable (hooks and MCP servers get it, tool
# calls do not), so a bare reference reaches the shell empty and the lib path becomes
# /skills/lib/acfw-store.sh. That refused the files store, which this block used to pass with no plugin
# dependency at all.
trunk_root=${ACFW_TRUNK_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}
store_name=$(bash -c '. "${1}/skills/lib/acfw-store.sh" 2>/dev/null && acfw_resolve_store "${2}"' _ "${CLAUDE_PLUGIN_ROOT}" "$trunk_root")

if [ -z "$store_name" ]; then
  # Empty only when the lib did not load (acfw_resolve_store never prints empty): a broken install, or
  # this block run as copied text whose plugin root was never substituted. The resolver's precedence
  # (ACFW_STORE env > config > files) still settles ONE case without the lib: when nothing pins a
  # store, the answer is `files` by definition, not by guess. That is every project this block served
  # before it depended on the lib, so a broken install is never worse than that. Anything that pins a
  # store may pin a non-files one, and assuming `files` there writes the task where that board never
  # looks. The grep over-matches on purpose (every config candidate, any value): a false refusal names
  # its remedy, a false `files` loses the task silently.
  if [ "${ACFW_STORE:-}" = files ] ||
     { [ -z "${ACFW_STORE:-}" ] &&
       ! grep -Eqs '^[[:space:]]*(export[[:space:]]+)?ACFW_STORE=' ${ACFW_CONFIG_FILE:+"$ACFW_CONFIG_FILE"} \
           "$trunk_root/.acfwhip/config" "$trunk_root/.backlog/.acfw-config"; }; then
    echo "Warning: acf-whip's store library did not load from '${CLAUDE_PLUGIN_ROOT}'. Nothing pins a task store, so it is 'files'. Reinstall acf-whip if this recurs."
    store_name=files
  else
    echo "Error: acf-whip's store library did not load from '${CLAUDE_PLUGIN_ROOT}', and ACFW_STORE is pinned (environment or config), so the task store cannot be resolved without it. Reinstall acf-whip."
    exit 1
  fi
fi

# A shell variable dies with this Bash call, and Step 5 routes the follow-up task by this value:
# printing it is the ONLY way it reaches the model. Unconditional, so a missing line is itself a signal
# that this block did not run as written.
echo "Task store: $store_name"

if [ "$store_name" = "files" ]; then
  # The files store is the ONE place .backlog/ is required, and there nothing else is: research-agent
  # writes .backlog/pending/<stem>.md directly and never calls the dispatcher.
  if [ ! -d ".backlog" ]; then
    echo "Error: .backlog/ directory not found. Run /whip-init first."
    exit 1
  fi
elif ! bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" capabilities >/dev/null; then
  # Every other store files the follow-up task through `acfw-store create`, a FORWARDED dispatcher
  # subcommand, and `capabilities` is the cheapest call down that same path: git repo, the
  # ACFW_INTEGRATION_MODE pin every forwarded call refuses on, and adapter lookup (exit 5 on an
  # ACFW_STORE typo, which info reports as an empty adapter and exit 0). No shipped adapter makes a
  # network call to answer it; beads first checks `bd` and `jq` are installed, which create needs too.
  # So a refusal here is exactly the one create would hit, surfaced before the whole research run
  # rather than after it, with the dispatcher's FATAL naming the cause.
  echo "Error: the '$store_name' task store cannot accept the follow-up task (acfw-store FATAL above). Fix ACFW_STORE / ACFW_INTEGRATION_MODE in .acfwhip/config or the environment, or run /whip-init."
  exit 1
fi

if [ ! -f "docs/acf/research-protocol.md" ]; then
  echo "Warning: Research protocol not found. Run /whip-init to install."
fi

# organization.md is installed by acf-librarian, a SIBLING plugin, and every acf-tools plugin is
# self-contained: optional composition is a presence check plus a fallback. This was a hard exit, so a
# project running acf-whip without acf-librarian could not research at all, over a file whose only use
# here is a naming reference this skill already states in full (Temporal Naming above). Warn, name what
# is lost, continue.
if [ ! -f "docs/acf/organization.md" ]; then
  echo "Warning: docs/acf/organization.md not found (it is created by the optional acf-librarian plugin). Continuing with this skill's built-in temporal naming rules; project-specific organization conventions will not be applied. Install acf-librarian to enforce them."
fi
```

Step 1 always prints a `Task store: <name>` line. Copy that `<name>` verbatim into Step 5's
**Task store** line, because it decides where research-agent files the follow-up task. No line means
Step 1 did not run as written, so run it again. Never assume `files`: on any other store that puts the
task where the board never looks.

If a Warning named `docs/acf/organization.md` or the research protocol
(`docs/acf/research-protocol.md`), list the missing file(s) in Step 5's **Absent references** line.
Otherwise drop that line. research-agent then uses the Temporal Filename rules in place of
`organization.md`, and the Tool Selection rules written into Step 5 in place of
`research-protocol.md`, instead of stalling on a file that does not exist.

### Step 2: Parse Research Scope

Take the topic from the user's input:
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

Delegate to research-agent with the Task tool:

```markdown
**Task**: Conduct comprehensive research on: {topic}

**Task store**: {store_name}

**Absent references**: {missing_files}. Do not stall on them: use the Temporal Filename and Tool
Selection rules in this prompt in their place.

**Research Protocol**: Follow `docs/acf/research-protocol.md` for tool selection and synthesis
requirements when it exists; the Tool Selection rules below summarize it and are sufficient without it

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
6. **Implementation Path**: Create a follow-up task in the task store based on findings (where and
   how: Backlog Task Creation below)

**Style Requirements**: Follow `docs/acf/style/research-documents.md` when it exists (installed by
`/whip-init`); the rules below are sufficient without it
- Direct, factual analysis (no promotional language)
- Evidence-based claims
- Objective assessment with tradeoffs
- Token-optimized (tables > prose, compressed examples)

**Backlog Task Creation (MANDATORY)**:
After completing research, author one task document using task-engineer pattern:
- Reference research document in Documentation field
- Set priority based on findings (high/medium/low)
- Include specific acceptance criteria from research
- Assign to appropriate specialist agent

File it according to **Task store** above:
- `files`: write it to `.backlog/pending/<stem>.md`.
- Any other store: do NOT create or write `.backlog/`. That store never reads it, so a task there
  silently does not exist. Stage the document where it can never be committed, then ingest it:
  1. Pick the staging directory in one Bash call, which prints `<dir>`:
     `d=.acfwhip/run/staging; mkdir -p "$d" && git check-ignore -q "$d/probe.md" || d=$(mktemp -d); echo "$d"`
     (`.acfwhip/run/` is the gitignored run namespace `/task` stages in; a project whose
     `.gitignore` lacks that rule gets a system temp dir instead.)
  2. Write the task to `<dir>/<stem>.md`. The basename becomes the task key.
  3. Run `bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" create --file "<dir>/<stem>.md" --folder pending && rm -f "<dir>/<stem>.md"`
  - Exit 4: the key is taken. Pick a new stem, rename the file to match, re-run step 3. Never overwrite.
  - Exit 99: the backend is busy. Re-run step 3 once.
  - Any other non-zero exit (5 backend unavailable, 6 auth, 7 invalid value, ...): stop and keep the
    file. Put the exit code and the file's full path in your final output, so the task can be ingested
    by hand with the step 3 command.
```

Fill `{missing_files}` from Step 1's Warnings, or drop the **Absent references** line when neither
file was reported missing.

### Step 6: Exit

The skill's part ends here. research-agent runs the MCP tools, writes the document under its
temporal name, and files the backlog task.

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
Uses Context7 for the Prisma docs and creates `docs/research/20251117-prisma-query-optimization-patterns-for-postgresql-time-series-data.md`

### Figma Component Research
```bash
/research "UI component from Figma: https://figma.com/design/ABC123/node-id=1-2"
```
Uses Figma MCP, which a Figma URL makes required, and creates `docs/research/20251117-ui-component-from-figma.md`

### Architecture Research
```bash
/research "Compare event-driven vs request-response for microservices communication"
```
Uses Perplexity, focused on architecture, and creates `docs/research/20251117-compare-event-driven-vs-request-response-for-microservices-communication.md`

## Success Criteria

- The research document has a temporal name: `YYYYMMDD-topic.md`
- The MCP tools used fit the topic (Figma/Context7/Perplexity)
- The analysis cites a source for its evidence
- A backlog task exists in the active store's `pending` state (`.backlog/pending/` on `files`)
- The task references the research document
- The recommendations are specific enough to act on

## Anti-Patterns

| Don't | Do instead |
|---|---|
| Create a research doc without a date | Name it `YYYYMMDD-description.md` |
| Skip Figma MCP when the topic has a Figma URL | Use Figma MCP whenever a Figma URL or node is given |
| Use a generic filename like "research-findings.md" | Name the topic: "20251117-nextjs-server-components.md" |
| Put implementation code in a research doc | Show signatures, shapes and patterns only (2-3 lines max) |
| Skip the backlog task | Always create a task from the findings |

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
- Location: pending in the active store (files: .backlog/pending/frontend-042-implement-server-components.md)
- References: docs/research/20251117-nextjs-server-components-best-practices.md

✅ Research complete. Review the document, and the task in the active store's pending state
   (.backlog/pending/ on files)
```

## Integration with ACF Workflow

**Research → Task → Implementation**:
1. `/research "topic"` writes the research doc and a task
2. `/task` reads the research doc and decomposes it into subtasks
3. `/go` runs the tasks, which implement the findings

**Documentation Conventions**:
- Research docs are temporal: a YYYYMMDD prefix, and a new file for each snapshot rather than an
  edit in place
- Architecture docs are timeless: you update them in place
- `docs/acf/organization.md` (optional, from acf-librarian) has the full conventions
