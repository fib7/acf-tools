# Guidelines for Creating Custom Quality Gates

acf-whip ships gates docs for Go, Python, Node.js and Next.js. For any other stack (`--backend=rust`,
say), `/whip-add-agents` writes a starter `docs/development/quality-gates-<stack>.md` from a template
of its own. This guide covers what a complete gates doc needs, whether you are filling out that
starter or starting from [template.md](template.md).

## Process Overview

1. **Identify core tools**: which tools lint, type-check, format, test and build your stack
2. **Define standards**: the configuration those tools run with
3. **Set thresholds**: coverage minimums, and performance targets if you need them
4. **Configure automation**: pre-commit hooks and CI
5. **Document bypasses**: every way to skip a check, each one banned
6. **Integrate with ACF**: point the agents at the doc

## Step 1: Identify Core Tools

### Tools by Stack

| Stack | Lint | Type check | Format | Test | Build |
|-------|------|------------|--------|------|-------|
| JavaScript/TypeScript | ESLint | tsc; flow for Flow | Prettier (multi-language) | Jest, Vitest, Mocha | `next build` (Next.js) |
| Python | Ruff, Pylint, Flake8 | mypy, pyright | Black, Ruff format | pytest, unittest | `python -m compileall` |
| Go | golangci-lint | built into the compiler | gofmt, goimports | `go test` | `go build` |
| Rust | clippy | built into the compiler | rustfmt | `cargo test` | `cargo build` |
| Ruby | RuboCop | | RuboCop | RSpec, Minitest | |
| Java | Checkstyle, PMD | | google-java-format | JUnit | `mvn compile` or `gradle build` |
| C# | Roslyn analyzers | | | | |

### Document Your Stack's Tools

List the commands in the doc. Leave out any slot your stack has no tool for.

````markdown
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
````

## Step 2: Define Standards

### Linting Standards

Start strict and loosen a rule only when you have to, never the reverse.

Rules worth having in any language:
- No unused variables or imports
- No debug statements (`console.log`, `print` and the like)
- No ignored errors
- No commented-out code
- Consistent naming

Three principles for the configuration:

1. **Extend a community config** instead of writing rules from scratch:
   - JavaScript: `eslint:recommended`, `next/core-web-vitals`
   - Python: Ruff's default rule set
   - Go: golangci-lint's recommended linters

2. **Make every rule an error, not a warning**:
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

3. **Say why whenever you disable a rule**, in a comment beside it:
   ```yaml
   # .golangci.yml
   linters-settings:
     errcheck:
       exclude-functions:
         - io.Copy  # Example: Justified exception with reason
   ```

### Type Checking Standards

Always turn on strict mode when the checker has one. Prohibit untyped values (`any` in TypeScript,
`Any` in Python). Every function must have type annotations.

### Testing Standards

Set coverage thresholds by how critical the code is:

| Code Criticality | Coverage Threshold | Rationale |
|------------------|-------------------|-----------|
| **Customer-facing APIs** | 90-95% | High impact, must work |
| **Core business logic** | 90% | Everything else depends on it |
| **Internal services** | 85-90% | Integration layer |
| **Utilities/helpers** | 80-85% | Lower risk |
| **UI components** | 75-80% | Visual tests cover part of it |

Coverage alone isn't enough. Assert on results, not only that the code ran without crashing. Test
boundaries and error paths. Write integration tests that run real workflows, not only units.

## Step 3: Set Thresholds

### Coverage Thresholds

A conservative starting point, to adjust as you learn what your project needs:

```yaml
# Start here, adjust based on your project's maturity
Core Logic: 90%
APIs: 90%
Services: 85%
Utilities: 80%
```

Then adjust for:
- **Project maturity**: a new project can start at 80%, a mature one at 90% or more
- **Team size**: larger teams need more, since edge cases are harder to communicate across them
- **Domain**: financial or medical code higher, internal tools lower
- **Change frequency**: code that changes often needs better tests

### Performance Thresholds (If Applicable)

Set performance gates only when performance is a requirement.

**Web applications**:
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

Tools:
- Any language: [pre-commit](https://pre-commit.com/)
- JavaScript: Husky + lint-staged
- Plain git: native `.git/hooks/`

Keep the commit hook fast. Run the linter and formatter on staged files only, and leave the full test
suite and the build to CI.

Husky and lint-staged (JavaScript):

```json
{
  "lint-staged": {
    "*.{ts,tsx}": ["eslint --fix", "prettier --write"],
    "*.{json,md}": ["prettier --write"]
  }
}
```

pre-commit (Python):

```yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format
```

### Continuous Integration

CI must run the full suite:
1. Linting, on the whole codebase rather than only the changes
2. Type checking
3. Every test, with coverage
4. Build verification
5. A security audit (optional, recommended)

A CI failure must block the merge, with no exceptions.

A GitHub Actions workflow that fits any stack:

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

Every stack has ways to skip a check. List them in the doc and ban them.

| Stack | Bypass Methods |
|-------|----------------|
| **JavaScript/TS** | `// @ts-ignore`, `// eslint-disable`, `--no-verify` |
| **Python** | `# type: ignore`, `# noqa`, `# pragma: no cover` |
| **Go** | `//nolint`, `// +build !test` |
| **Rust** | `#[allow(clippy::...)]`, `#[cfg(not(test))]` |
| **All** | `git commit --no-verify`, lowering thresholds |

### Acceptable Exceptions

A rare exception is acceptable when the comment gives the reason:

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

Without one, it is not:

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

Point each specialist's agent file at its gates doc, and give it a pre-completion checklist:

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

List the gates doc for every stack in the project in the quality-reviewer's agent file:

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

### Step 1: Identify Tools

````markdown
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
````

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

Cargo has no coverage command of its own. cargo-tarpaulin adds one:

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

Combine the sections above into `docs/patterns/quality-gates/rust.md`.

## Testing Your Quality Gates

### Validation Checklist

Prove each gate both ways before you call the doc finished:

- [ ] Clean code passes every command
- [ ] Lint errors and type errors (where the stack has types) fail their gate with a clear message
- [ ] Low coverage fails with a coverage report
- [ ] A build failure is caught
- [ ] Pre-commit hooks stop a bad commit, and CI blocks the merge
- [ ] A bypass attempt is stopped by the hooks or caught by CI
- [ ] The doc lists every bypass method and bans it
- [ ] The team knows the requirements

## Maintenance

| When | What to do |
|------|------------|
| Every quarter | Review thresholds and rules |
| A new linter comes out | Evaluate it and decide whether to add it |
| A tool ships a major version | Review its breaking changes and your configuration |
| The team says a gate is too strict or too loose | Adjust the threshold |
| The project matures | Raise coverage requirements |
| The team grows | Consider stricter gates |
| Velocity drops | Check whether the gates are too restrictive |

## Additional Resources

- [Template](template.md): start here
- Finished examples: [Next.js/TypeScript](nextjs-typescript.md), [Python/FastAPI](python-fastapi.md),
  [Go](go.md), [Node.js](nodejs.md)
