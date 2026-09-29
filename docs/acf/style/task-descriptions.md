<!-- acf-whip-artifact: content/style/task-descriptions.md v3.5.0 -->
# Task Description Style

## For: task-engineer, whenever it writes a task

A task says what to build, why, and how anyone can tell it is done. How to build it is the specialist's call.

## Core Principles

- **Tone**: blunt and direct, no cushioning
- **Requirements**: binary. It works or it doesn't.
- **Evidence**: concrete, measurable criteria

## Banned Language

**Never use**:
- "comprehensive", "systematic", "significant", "substantial", "robust", "elegant"
- "achievement", "progress", "improvement" (unless the work is 100% complete)
- "enhance", "optimize", "streamline" (name the actual change instead)

## Required Language

- **Binary**: "API endpoint validates token", not "improve validation"
- **Specific**: "Response time < 200ms", not "fast response"
- **Testable**: "Returns 401 for missing token", not "handles auth errors"

## Abstraction Level Rules

A task states WHAT and WHY. It never states HOW.

**task-engineer writes**:
- WHAT needs to be done: outcomes, capabilities, interfaces
- WHY it's needed: business value, fit with the architecture
- WHAT constraints apply: performance, security, compatibility

**The specialist agent decides** (keep these out of the task):
- HOW to implement it: algorithms, data structures, patterns
- WHICH libraries or frameworks to use, unless the architecture mandates one
- HOW to structure the code: file layout, class design

**Boundary test**: if you are writing step-by-step implementation, stop. That work belongs to the specialist.

## Code Snippet Policy

**Never include**:
- Function/method implementations
- Algorithm pseudocode (describe the algorithm in words)
- Configuration file contents (state the requirements)
- Database queries (state the data requirements)
- API call sequences (describe what the workflow must achieve)

**Allowed**, sparingly and 2-3 lines at most:
- API endpoint signatures: `POST /api/v1/pipelines`
- Response shape: `{"pipeline_id": "uuid", "status": "pending"}`
- Error codes: `Returns 400 for invalid YAML`
- Type signatures: `func ProcessYAML(input []byte) (*Workflow, error)`

When in doubt, write it in words.

## Technical Requirements Boundaries

### Right: specification level

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

### Wrong: implementation level

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

**Good: binary, testable, about the outcome**:
- [ ] user-api returns 201 with pipeline_id when YAML is valid
- [ ] yaml-processor rejects YAML with unknown methods (returns 400)
- [ ] Integration test covers YAML submission → Temporal workflow creation
- [ ] YAML validation completes in < 200ms for 100KB files
- [ ] catalog-stub returns method schema for "social.twitter.search"

**Bad: vague, or about the implementation**:
- [ ] Enhance API error handling
- [ ] Improve YAML validation robustness
- [ ] Comprehensively test the pipeline flow
- [ ] Add proper logging throughout the codebase
- [ ] Refactor the validation logic for better maintainability

### Verifiability Boundary

Every acceptance criterion must be verifiable inside the task's worktree and quality-gate environment. A criterion that needs a **live deployed environment** (a staging URL, a real cluster, production telemetry) belongs in its own operator- or deploy-gated task.

A reviewer who cannot verify a criterion has to reject the task. So an unverifiable criterion spends the 3-rejection budget on a task that has no defect.

### Technical Requirements Examples

**Good: specification level**:

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

**Terrible: implementation level, with code**:

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

**Why it's terrible**:
- 50+ lines of implementation code
- Prescribes the exact algorithm
- Dictates the code structure
- Leaves the specialist agent nothing to decide
- Duplicates the code in the task and the implementation, and both then need maintaining

**The same task, written correctly**:

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

**Good: the scenario and the expected outcome**:
```markdown
## Edge Cases to Handle
- Empty YAML file: Return 400 "pipeline must have at least one source"
- YAML > 1MB: Return 413 "payload too large"
- Catalog-stub unavailable: Return 503 "method registry unavailable, retry in 30s"
- Unknown method name: Return 400 with "method not found: {method_name}, see /api/v1/methods"
- Circular dependencies in transforms: Return 400 "circular dependency detected: A → B → A"
```

**Bad: implementation details**:
```markdown
## Edge Cases to Handle
- Empty YAML: Check len(yamlBytes) == 0 before unmarshaling, if true return early with error
- Large files: In the handler, add c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 1048576)
- Catalog-stub down: Wrap the HTTP call in retry logic with exponential backoff, use time.Sleep(backoff)
- Circular deps: Build a graph using map[string][]string and run DFS to detect cycles
```

### Out of Scope Examples

**Good: clear boundaries**:
```markdown
## Out of Scope
- Pipeline execution (handled by Temporal workflows in separate task)
- User authentication (Kong API Gateway handles this)
- Rate limiting (Redis-based rate limiter already in place)
- Webhook notifications (deferred to Phase 2)
- YAML syntax highlighting in UI (frontend task)
```

**Bad: vague**:
```markdown
## Out of Scope
- Other features
- Future enhancements
- Non-critical items
```

## The Test

A specialist who reads your task should be able to say "I know WHAT to build and WHY." If they say "I just need to copy-paste this code", the task has failed.

**Enforcement**: quality-reviewer must reject a task with extensive code snippets or implementation algorithms. A rejected task moves back to pending/ with comments that cite this guide.

---

**Last Updated**: 2025-10-28
