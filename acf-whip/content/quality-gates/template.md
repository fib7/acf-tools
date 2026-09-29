# Quality Gates - [Your Stack]

> **Template instructions**: replace every [bracketed] placeholder with your stack's details, then
> work through the Customization Checklist at the end.

A [Your Stack] task is not done until every command under Quality Requirements passes.

## Zero Bypass Tolerance

Never bypass a quality gate, for any reason. Fix the code until the gate passes, or report the task
blocked under the Quality Gate Protocol below.

## Quality Requirements

### Core Quality Tools

```bash
# MANDATORY - Must all pass
[linting-command]              # Example: eslint, ruff, golangci-lint
[type-checking-command]        # Example: tsc, mypy (if applicable)
[formatting-command]           # Example: prettier, black, gofmt
[test-command]                 # Example: jest, pytest, go test
[build-command]                # Example: build verification
```

### Test Coverage

**Customize:** set thresholds that fit how mature your project is and how much risk it can carry.

- **[Category 1]**: [X]% minimum (e.g., Core Logic: 90%)
- **[Category 2]**: [X]% minimum (e.g., API Endpoints: 95%)
- **[Category 3]**: [X]% minimum (e.g., Services: 85%)
- **[Category 4]**: [X]% minimum (e.g., Utilities: 80%)

## Code Standards

### Linting Configuration

```[config-format]
# [config-file-name]
# Example: .eslintrc.json, pyproject.toml, .golangci.yml

[Your linting rules configuration]

# Key rules to enforce:
- No unused variables
- No console.log / print statements (except logging)
- No commented code
- Proper error handling
- [Stack-specific rules]
```

### Type Checking Configuration (if applicable)

```[config-format]
# [config-file-name]
[Your type checking configuration]

# Key settings:
- Strict mode: enabled
- No implicit any
- No untyped functions
- [Stack-specific settings]
```

### Formatting Configuration

```[config-format]
# [config-file-name]
[Your formatting configuration]

# Key settings:
- Line length: [X] characters
- Indentation: [spaces/tabs]
- Quote style: [single/double]
- [Stack-specific settings]
```

## [Framework] Specific Requirements

### [Feature Area 1]

**Customize:** add the requirements your framework and libraries impose, for example:

- API route standards
- Component patterns
- State management rules
- Database query patterns
- Async/concurrency requirements

### [Feature Area 2]

[Your framework-specific standards]

## Pre-commit Hooks

```yaml
# [pre-commit config file]
# Example: .husky/pre-commit, .pre-commit-config.yaml

[Your pre-commit hook configuration]

# Must include:
- Linting
- Formatting
- Type checking (if applicable)
```

## Quality Gate Protocol

### When Checks Fail

1. **Attempts 1-10**: fix the underlying problem, not the check, and rerun.
2. **After 10 attempts**: stop and report the task blocked, with this report.

### Failure Report Format

```markdown
# Quality Gate Failure Report

## Task: [task-name]

## Component: [Your Stack]

## Attempts: 10

## Failures:

1. [Tool 1]: X errors/warnings
2. [Tool 2]: Y issues
3. [Tool 3]: Z% coverage (required: [X]%)

## Attempted Fixes:

1. [Fix description] - Failed: [reason]
2. [Fix description] - Failed: [reason]

## Blockers:

- [Specific blocker requiring intervention]
```

## Forbidden Bypass Methods

**Customize:** list every way to bypass a gate on your stack. The entries below are examples from
several stacks: keep the ones that apply and add your own.

Never use any of these:

- `git commit --no-verify`
- `git push --no-verify`
- `// @ts-ignore` (TypeScript)
- `# type: ignore` (Python)
- `//nolint` (Go)
- `/* eslint-disable */` (JavaScript)
- Disabling rules in config files
- Lowering coverage thresholds
- [Stack-specific bypass methods]

## Performance Requirements (Optional - Customize)

**Customize:** fill this in only if your project has performance targets it must meet. Otherwise
delete the section.

### Example Targets

- API response time: < [X]ms (p90)
- Build time: < [X] minutes
- Test execution: < [X] seconds
- Memory usage: < [X]MB
- [Stack-specific metrics]

### Optimization Patterns

[Your performance optimization guidelines]

## Dependencies Management

**Customize:** the commands your project uses to manage dependencies.

```bash
# Add dependency
[command to add package]

# Update dependencies
[command to update]

# Lock dependencies
[command to lock versions]

# Security audit
[command to check vulnerabilities]
```

### Security Requirements

- Run security audit [frequency: weekly/monthly]
- Update dependencies [frequency]
- No packages with known vulnerabilities
- Pin production dependencies
- [Stack-specific security practices]

## Continuous Integration

**Customize:** your CI pipeline, running the gates above.

```yaml
# [CI Platform: GitHub Actions, GitLab CI, etc.]
jobs:
  quality:
    steps:
      - name: Checkout
        [checkout step]

      - name: Setup
        [setup environment step]

      - name: Install dependencies
        run: [install command]

      - name: Lint
        run: [linting command]

      - name: Type check
        run: [type checking command]

      - name: Format check
        run: [formatting check command]

      - name: Test
        run: [test command with coverage]

      - name: Build
        run: [build command]
```

A failed CI run blocks the merge, with no exceptions.

---

## Customization Checklist

Before anyone works from this doc:

- [ ] Replace `[Your Stack]` with the stack's name
- [ ] Define linting command and configuration
- [ ] Define type checking command (if applicable) and configuration
- [ ] Define formatting command and configuration
- [ ] Define test command with coverage
- [ ] Set coverage thresholds for each code category
- [ ] Add framework-specific requirements (2-3 sections)
- [ ] Configure pre-commit hooks
- [ ] List all forbidden bypass methods for your stack
- [ ] Define performance requirements (if applicable)
- [ ] Document dependency management workflow
- [ ] Set up CI pipeline configuration
- [ ] Add security audit requirements
- [ ] Run every command in your project and confirm it works
- [ ] Walk the team through the gates
