# Task Description Style

## For: task-engineer when creating task files in .backlog/

## Core Principles

- **Tone**: Blunt, direct statements
- **Requirements**: Binary (works or doesn't)
- **Evidence**: Concrete, measurable criteria
- **Language**: Direct, no cushioning

## Banned Language

**NEVER use**:
- "comprehensive", "systematic", "significant", "substantial", "robust", "elegant"
- "achievement", "progress", "improvement" (unless 100% complete)
- "enhance", "optimize", "streamline" (be specific instead)

## Required Language

- **Binary**: "API endpoint validates token" NOT "improve validation"
- **Specific**: "Response time < 200ms" NOT "fast response"
- **Testable**: "Returns 401 for missing token" NOT "handles auth errors"

## Abstraction Level Rules

**CRITICAL**: Tasks specify WHAT and WHY, NEVER HOW.

**Task-engineer responsibilities**:
- WHAT needs to be done (outcomes, capabilities, interfaces)
- WHY it's needed (business value, architectural alignment)
- WHAT constraints apply (performance, security, compatibility)

**Specialist agent responsibilities** (NOT in task descriptions):
- HOW to implement (algorithms, data structures, patterns)
- WHICH libraries/frameworks to use (unless mandated by architecture)
- HOW to structure code (file organization, class design)

**Boundary test**: If you're describing step-by-step implementation, STOP. You've crossed into specialist territory.

## Code Snippet Policy

**ABSOLUTE PROHIBITIONS**:
- Function/method implementations
- Algorithm pseudocode (use natural language)
- Configuration file contents (describe requirements instead)
- Database queries (specify data requirements)
- API call sequences (describe workflow outcomes)

**ALLOWED** (sparingly, 2-3 lines max):
- API endpoint signatures: `POST /api/v1/pipelines`
- Response shape: `{"pipeline_id": "uuid", "status": "pending"}`
- Error codes: `Returns 400 for invalid YAML`
- Type signatures: `func ProcessYAML(input []byte) (*Workflow, error)`

**When in doubt**: Use natural language, not code.

## Technical Requirements Boundaries

### ✅ CORRECT - Specification Level

**What to modify**:
- "Modify services/user-api/handlers/pipeline.go"
- "Add validation to yaml-processor service"
- "Update catalog-stub Method Registry lookup"

**Pattern references**:
- "Follow repository pattern from user-api/repository/"
- "Use error handling pattern from docs/development/error-handling.md"
- "Apply middleware pattern for authentication"

**Interface contracts**:
- "YAML processor accepts []byte, returns WorkflowSpec or ValidationError"
- "Method Registry returns 404 for unknown methods"
- "API returns 201 with Location header on success"

**Constraints**:
- "Response time < 200ms for YAML validation"
- "Support YAML files up to 1MB"
- "Zero database queries in validation path"

### ❌ WRONG - Implementation Level

**Detailed algorithms**:
- "Parse YAML using yaml.Unmarshal, iterate through sources array, for each source call ValidateMethod..."
- "Initialize a map[string]interface{}, populate keys..."

**Library-specific code**:
```go
func ProcessYAML(data []byte) error {
    var config Config
    if err := yaml.Unmarshal(data, &config); err != nil {
        return err
    }
    // ...
}
```

**Configuration details**:
```yaml
database:
  host: localhost
  port: 5432
  max_connections: 100
```

**Step-by-step instructions**:
- "First, create a struct for Pipeline. Then add a method Parse() that unmarshals YAML. Then iterate..."

## Examples

### Acceptance Criteria Examples

**✅ GOOD - Binary, Testable, Outcome-Focused**:
- [ ] user-api returns 201 with pipeline_id when YAML is valid
- [ ] yaml-processor rejects YAML with unknown methods (returns 400)
- [ ] Integration test covers YAML submission → Temporal workflow creation
- [ ] YAML validation completes in < 200ms for 100KB files
- [ ] catalog-stub returns method schema for "social.twitter.search"

**❌ BAD - Vague, Implementation-Focused**:
- [ ] Enhance API error handling
- [ ] Improve YAML validation robustness
- [ ] Comprehensively test the pipeline flow
- [ ] Add proper logging throughout the codebase
- [ ] Refactor the validation logic for better maintainability

### Technical Requirements Examples

**✅ GOOD - Specification Level**:

```markdown
### Implementation Details
- Modify services/user-api/handlers/pipeline.go to add POST /api/v1/pipelines endpoint
- YAML processor validates against catalog-stub Method Registry
- Return 400 with error details for validation failures
- Follow repository pattern from user-api/repository/
- Use structured logging with correlation IDs

### Testing Requirements
- Unit tests for YAML validation rules (valid/invalid schemas)
- Integration test: submit YAML → verify Temporal workflow created
- Error case: unknown method name returns 400 with method name in error
```

**❌ TERRIBLE - Implementation Level with Code Snippets**:

```markdown
### Implementation Details
First, update pipeline.go:

func HandlePipelineSubmit(c *gin.Context) {
    var req PipelineRequest
... 20 lines of implementatino code
    db.Create(&spec)

    c.JSON(201, gin.H{"pipeline_id": spec.ID})
}

Then add validation helper in validator.go:

func ValidateMethod(name string) error {
    // implementation here
}
```

**Why TERRIBLE**:
- 50+ lines of implementation code
- Prescribes exact algorithm
- Dictates code structure
- Leaves nothing for specialist agent to decide
- Creates maintenance burden (code duplicated in task + implementation)

**✅ CORRECT Alternative**:

```markdown
### Implementation Details
- Add POST /api/v1/pipelines endpoint to user-api
- Accept JSON body with yaml_content field (string, max 1MB)
- Validate YAML structure and method names against catalog-stub
- Return 201 with pipeline_id on success, 400 with error details on failure
- Follow user-api error handling pattern (docs/development/error-handling.md)
- Use repository pattern for database operations

### Validation Requirements
- All method names must exist in catalog-stub Method Registry
- All method params must match schema from catalog-stub
- Pipeline name must be 1-100 characters
- Sources array must have 1-20 entries

### Testing Requirements
- Unit tests for validation rules (15+ test cases)
- Integration test: valid YAML → 201 response with pipeline_id
- Integration test: invalid method → 400 with "method not found: {name}"
- Integration test: catalog-stub down → 503 with retry guidance
```

### Edge Cases Examples

**✅ GOOD - Describes Scenario and Expected Outcome**:
```markdown
## Edge Cases to Handle
- Empty YAML file: Return 400 "pipeline must have at least one source"
- YAML > 1MB: Return 413 "payload too large"
- Catalog-stub unavailable: Return 503 "method registry unavailable, retry in 30s"
- Unknown method name: Return 400 with "method not found: {method_name}, see /api/v1/methods"
- Circular dependencies in transforms: Return 400 "circular dependency detected: A → B → A"
```

**❌ BAD - Implementation Details**:
```markdown
## Edge Cases to Handle
- Empty YAML: Check len(yamlBytes) == 0 before unmarshaling, if true return early with error
- Large files: In the handler, add c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 1048576)
- Catalog-stub down: Wrap the HTTP call in retry logic with exponential backoff, use time.Sleep(backoff)
- Circular deps: Build a graph using map[string][]string and run DFS to detect cycles
```

### Out of Scope Examples

**✅ GOOD - Clear Boundaries**:
```markdown
## Out of Scope
- Pipeline execution (handled by Temporal workflows in separate task)
- User authentication (Kong API Gateway handles this)
- Rate limiting (Redis-based rate limiter already in place)
- Webhook notifications (deferred to Phase 2)
- YAML syntax highlighting in UI (frontend task)
```

**❌ BAD - Vague**:
```markdown
## Out of Scope
- Other features
- Future enhancements
- Non-critical items
```

## Summary

**For task-engineer**: Your job is to create specifications that empower specialist agents, not constrain them.

**Golden Rule**: If a specialist agent can read your task and say "I know WHAT to build and WHY", you've succeeded. If they say "I just need to copy-paste this code", you've failed.

**Enforcement**: quality-reviewer MUST reject tasks with extensive code snippets or implementation algorithms. Rejected tasks move back to pending/ with comments citing this guide.

---

**Last Updated**: 2025-10-28
