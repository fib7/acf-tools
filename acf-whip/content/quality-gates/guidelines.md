# Guidelines for Creating Custom Quality Gates

This guide helps you create quality gates for tech stacks not covered by ready-made templates.

## Process Overview

1. **Identify Core Tools** - What tools enforce quality in your stack?
2. **Define Standards** - What configuration ensures quality?
3. **Set Thresholds** - What coverage/score minimums?
4. **Configure Automation** - How to enforce automatically?
5. **Document Bypasses** - What bypass methods to prohibit?
6. **Integrate with ACF** - How agents/commands reference gates?

## Step 1: Identify Core Tools

### Questions to Answer

**Linting**: What tools check code style and potential bugs?
- JavaScript/TypeScript: ESLint
- Python: Ruff, Pylint, Flake8
- Go: golangci-lint
- Rust: clippy
- Ruby: RuboCop
- Java: Checkstyle, PMD
- C#: Roslyn analyzers

**Type Checking**: Does your language have static typing?
- TypeScript: tsc
- Python: mypy, pyright
- Go: built into compiler
- Rust: built into compiler
- Flow (JavaScript): flow

**Formatting**: What enforces consistent formatting?
- Multi-language: Prettier
- Python: Black, Ruff format
- Go: gofmt, goimports
- Rust: rustfmt
- Ruby: RuboCop
- Java: google-java-format

**Testing**: What runs your tests?
- JavaScript: Jest, Vitest, Mocha
- Python: pytest, unittest
- Go: go test
- Rust: cargo test
- Ruby: RSpec, Minitest
- Java: JUnit

**Build Verification**: How do you ensure code compiles/builds?
- Next.js: `next build`
- Python: `python -m compileall`
- Go: `go build`
- Rust: `cargo build`
- Java: `mvn compile` or `gradle build`

### Document Your Stack's Tools

```markdown
## Quality Requirements for [Your Stack]

### Core Quality Tools

```bash
# Linting
[command]

# Type Checking (if applicable)
[command]

# Formatting
[command]

# Testing
[command]

# Build Verification
[command]
```
```

## Step 2: Define Standards

### Linting Standards

**Strictness Philosophy**: Start strict, loosen if necessary (not the reverse).

**Common Rules Across Languages**:
- No unused variables/imports
- No debug statements (console.log, print, etc.)
- Proper error handling (no ignored errors)
- No commented code
- Consistent naming conventions

**Configuration Principles**:
1. **Use community standards** - Extend well-known configs
   - JavaScript: `eslint:recommended`, `next/core-web-vitals`
   - Python: Ruff's default rule set
   - Go: golangci-lint's recommended linters

2. **Enforce, don't warn** - Rules should be errors, not warnings
   ```javascript
   // ✅ GOOD
   "rules": {
     "no-console": "error"
   }

   // ❌ BAD
   "rules": {
     "no-console": "warn"  // Warnings get ignored
   }
   ```

3. **Document exceptions** - If you disable a rule, explain why
   ```yaml
   # .golangci.yml
   linters-settings:
     errcheck:
       exclude-functions:
         - io.Copy  # Example: Justified exception with reason
   ```

### Type Checking Standards

**Strict Mode**: Always enable strict mode if available.

**No `any` Types**: Prohibit untyped values (TypeScript `any`, Python `Any`).

**Complete Coverage**: All functions must have type annotations.

### Testing Standards

**Coverage Tiers**: Set different thresholds by code criticality.

| Code Criticality | Coverage Threshold | Rationale |
|------------------|-------------------|-----------|
| **Customer-facing APIs** | 90-95% | High impact, must work |
| **Core business logic** | 90% | Critical to functionality |
| **Internal services** | 85-90% | Integration layer |
| **Utilities/helpers** | 80-85% | Lower criticality |
| **UI components** | 75-80% | Visual testing supplements |

**Test Quality**: Coverage alone isn't enough.
- **Meaningful assertions**: Not just "doesn't crash"
- **Edge cases**: Test boundaries, errors, edge conditions
- **Integration tests**: Test actual workflows, not just units

## Step 3: Set Thresholds

### Coverage Thresholds

**Conservative Starting Point** (can adjust based on experience):

```yaml
# Start here, adjust based on your project's maturity
Core Logic: 90%
APIs: 90%
Services: 85%
Utilities: 80%
```

**Factors to Consider**:
- **Project maturity**: New projects can start at 80%, mature at 90%+
- **Team size**: Larger teams need higher coverage (harder to communicate edge cases)
- **Domain criticality**: Financial/medical = higher, internal tools = lower
- **Change frequency**: Fast-changing code needs better tests

### Performance Thresholds (If Applicable)

Only set performance gates if performance is critical.

**Web Applications**:
- Lighthouse score: > 90
- LCP: < 2.5s
- FID: < 100ms
- CLS: < 0.1

**APIs**:
- Response time p90: < 200ms
- Response time p99: < 500ms
- Throughput: > 1000 req/sec (adjust for your scale)

**Build/CI**:
- Build time: < 5 minutes
- Test execution: < 2 minutes
- Total CI time: < 10 minutes

## Step 4: Configure Automation

### Pre-commit Hooks

**Tools**:
- Universal: [pre-commit](https://pre-commit.com/) (multi-language)
- JavaScript: Husky + lint-staged
- Git hooks: native `.git/hooks/`

**What to Run in Pre-commit**:
- ✅ Fast checks: Linting, formatting
- ✅ Modified file checks: Only check staged files
- ❌ Slow checks: Full test suite, build (save for CI)

**Example: Husky + lint-staged (JavaScript)**:

```json
{
  "lint-staged": {
    "*.{ts,tsx}": ["eslint --fix", "prettier --write"],
    "*.{json,md}": ["prettier --write"]
  }
}
```

**Example: pre-commit (Python)**:

```yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format
```

### Continuous Integration

**CI Must Run Full Suite**:
1. All linting (full codebase, not just changes)
2. All type checking
3. All tests with coverage
4. Build verification
5. Security audit (optional but recommended)

**Block on Failure**: CI failure MUST block merge. No exceptions.

**Example: GitHub Actions (Universal Pattern)**:

```yaml
name: Quality Gates
on: [push, pull_request]

jobs:
  quality:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup [Language]
        uses: [setup-action]

      - name: Install dependencies
        run: [install-command]

      - name: Lint
        run: [lint-command]

      - name: Type check
        run: [type-check-command]

      - name: Format check
        run: [format-check-command]

      - name: Test with coverage
        run: [test-command]

      - name: Build
        run: [build-command]

      # Fail job if any step fails
```

## Step 5: Document Bypasses

### Identify Bypass Methods

Every stack has ways to bypass quality checks. Document and prohibit them.

**Common Bypass Patterns**:

| Stack | Bypass Methods |
|-------|----------------|
| **JavaScript/TS** | `// @ts-ignore`, `// eslint-disable`, `--no-verify` |
| **Python** | `# type: ignore`, `# noqa`, `# pragma: no cover` |
| **Go** | `//nolint`, `// +build !test` |
| **Rust** | `#[allow(clippy::...)]`, `#[cfg(not(test))]` |
| **All** | `git commit --no-verify`, lowering thresholds |

### Acceptable Exceptions

**Rare exceptions with justification**:

```typescript
// ✅ ACCEPTABLE - Documented reason
// @ts-ignore: Third-party library has incorrect types, reported upstream (issue #123)
const result = brokenLibrary.method();
```

```go
// ✅ ACCEPTABLE - Legitimate exception
//nolint:errcheck // Closing buffer after write, error not actionable
defer buf.Close()
```

**Unacceptable exceptions**:

```typescript
// ❌ FORBIDDEN - No justification
// @ts-ignore
const result = someCode();
```

### Document in Quality Gate

```markdown
## Forbidden Bypass Methods

**NEVER use**:

- `[bypass method 1]` - [why it's forbidden]
- `[bypass method 2]` - [why it's forbidden]
- Lowering coverage thresholds - [defeats quality assurance]

**Acceptable exceptions** (with justification):

- `[bypass method]` with comment explaining why + link to issue/ADR
```

## Step 6: Integrate with ACF

### Reference in Agent Files

Agents should know their quality gates:

```markdown
# .claude/agents/[stack]-engineer.md

## Quality Gates

**MANDATORY**: All code must pass quality gates before completion.

See [Quality Gates - [Stack]](../../docs/acf/quality-gates-[stack].md)

### Pre-completion Checklist

- [ ] Run linting: `[command]`
- [ ] Run type checking: `[command]`
- [ ] Run tests: `[command]`
- [ ] Run build: `[command]`
- [ ] All quality gates passed

**FORBIDDEN**: `--no-verify`, disabling linters, lowering thresholds
```

### Reference in Quality Reviewer

```markdown
# .claude/agents/quality-reviewer.md

## Stack-Specific Quality Gates

**MANDATORY**: Verify implementation agent ran appropriate quality gates.

- Next.js/TypeScript: [quality-gates-nextjs.md](...)
- Python/FastAPI: [quality-gates-python.md](...)
- [Your Stack]: [quality-gates-[stack].md](...)

### Verification Steps

1. Check quality gate file for stack
2. Verify all commands in "Quality Requirements" section were run
3. Verify no bypass methods were used
4. Verify coverage thresholds met
```

## Example: Creating Quality Gates for Rust

Let's walk through creating gates for Rust as an example.

### Step 1: Identify Tools

```markdown
## Quality Requirements for Rust

### Core Quality Tools

```bash
# Linting
cargo clippy -- -D warnings

# Formatting
cargo fmt -- --check

# Testing
cargo test

# Build
cargo build --release
```
```

### Step 2: Define Standards

```toml
# rust-toolchain.toml
[toolchain]
channel = "stable"
components = ["clippy", "rustfmt"]

# .cargo/config.toml
[target.x86_64-unknown-linux-gnu]
rustflags = ["-D", "warnings"]  # Deny warnings
```

### Step 3: Set Thresholds

Rust doesn't have built-in coverage, but you can use tarpaulin:

```bash
cargo install cargo-tarpaulin
cargo tarpaulin --out Html --output-dir coverage/ --fail-under 80
```

### Step 4: Configure Automation

```yaml
# .pre-commit-config.yaml
repos:
  - repo: local
    hooks:
      - id: cargo-fmt
        name: cargo fmt
        entry: cargo fmt
        language: system
        types: [rust]
        pass_filenames: false

      - id: cargo-clippy
        name: cargo clippy
        entry: cargo clippy -- -D warnings
        language: system
        types: [rust]
        pass_filenames: false
```

### Step 5: Document Bypasses

```markdown
## Forbidden Bypass Methods

**NEVER use**:

- `#[allow(clippy::...)]` without documented justification
- `cargo clippy --fix` without reviewing changes
- `--no-verify` in git commits
- Disabling deny warnings in .cargo/config.toml
```

### Step 6: Complete Quality Gate Document

Create `docs/patterns/quality-gates/rust.md` with all above sections combined.

## Testing Your Quality Gates

### Validation Checklist

Before considering your quality gates complete:

- [ ] All commands run successfully on passing code
- [ ] All commands fail appropriately on bad code
- [ ] Pre-commit hooks prevent bad commits
- [ ] CI blocks merge on quality failure
- [ ] Team understands all requirements
- [ ] Documentation is clear and complete
- [ ] Bypass methods are documented and prohibited

### Test Scenarios

1. **Passing code**: All gates pass
2. **Linting errors**: Gates fail, clear error messages
3. **Type errors**: Gates fail (if applicable)
4. **Low coverage**: Gates fail with coverage report
5. **Build failure**: Gates catch compilation errors
6. **Bypass attempt**: Pre-commit hooks prevent or CI catches

## Maintenance

### When to Update Quality Gates

- **New linters available**: Evaluate and potentially add
- **Team feedback**: Adjust thresholds if too strict/loose
- **Project maturity**: Increase coverage requirements over time
- **Stack upgrades**: Review breaking changes in tools

### Review Schedule

- **Quarterly**: Review thresholds and rules
- **After major version updates**: Review tool configurations
- **When team grows**: Consider stricter gates
- **When velocity drops**: Check if gates too restrictive

---

## Additional Resources

- [Template](template.md) - Start with this template
- [Next.js/TypeScript Example](nextjs-typescript.md) - Reference implementation
- [Python/FastAPI Example](python-fastapi.md) - Reference implementation
- [Go Example](go.md) - Reference implementation
