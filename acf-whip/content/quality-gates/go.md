# Quality Gates - Go

## Zero Bypass Tolerance

**ABSOLUTELY FORBIDDEN**: Bypassing quality gates is STRICTLY PROHIBITED. **NO EXCEPTIONS.**

## Quality Requirements

### Core Quality Tools

```bash
# MANDATORY - Must all pass
golangci-lint run ./...                 # Comprehensive linting
go test ./... -v -race -cover          # Tests with race detection
go build ./...                          # Build verification
go mod tidy && git diff --exit-code go.mod go.sum  # Dependency hygiene
```

### Test Coverage

- **Core Logic**: 80% minimum
- **Handlers/Controllers**: 85% minimum
- **Services**: 80% minimum
- **Utilities**: 75% minimum

## Code Standards

### golangci-lint Configuration

```yaml
# .golangci.yml
linters:
  enable:
    - errcheck      # Check error handling
    - gosimple      # Simplify code
    - govet         # Go vet
    - ineffassign   # Detect ineffectual assignments
    - staticcheck   # Static analysis
    - typecheck     # Type checking
    - unused        # Find unused code
    - gofmt         # Format check
    - goimports     # Import organization
    - misspell      # Spell checking
    - gocritic      # Code review
    - revive        # General linting
    - gosec         # Security issues

linters-settings:
  errcheck:
    check-blank: true
    check-type-assertions: true
  govet:
    enable-all: true
  gofmt:
    simplify: true
  goimports:
    local-prefixes: github.com/yourorg/yourproject

issues:
  exclude-use-default: false
  max-issues-per-linter: 0
  max-same-issues: 0
```

### Code Organization Standards

```go
// Package documentation required
package mypackage

import (
    // Standard library
    "context"
    "fmt"

    // External packages
    "github.com/gin-gonic/gin"

    // Internal packages
    "github.com/yourorg/yourproject/internal/domain"
)

// Exported functions must have documentation
// ProcessRequest handles incoming API requests.
// Returns error if validation fails.
func ProcessRequest(ctx context.Context, req *Request) (*Response, error) {
    // Implementation
}
```

### Error Handling Standards

```go
// ✅ CORRECT - Proper error handling
result, err := doSomething()
if err != nil {
    return nil, fmt.Errorf("failed to do something: %w", err)
}

// ✅ CORRECT - Custom error types
type ValidationError struct {
    Field string
    Msg   string
}

func (e *ValidationError) Error() string {
    return fmt.Sprintf("%s: %s", e.Field, e.Msg)
}

// ❌ WRONG - Ignoring errors
result, _ := doSomething()  // Never ignore errors

// ❌ WRONG - Not wrapping errors
if err != nil {
    return nil, err  // Should wrap with context
}
```

## Go-Specific Requirements

### Context Propagation

```go
// ✅ CORRECT - Pass context
func ProcessData(ctx context.Context, data []byte) error {
    result, err := service.Process(ctx, data)
    if err != nil {
        return err
    }
    return nil
}

// ❌ WRONG - Missing context
func ProcessData(data []byte) error {
    result, err := service.Process(data)  // Where's the context?
    if err != nil {
        return err
    }
    return nil
}
```

### Concurrency Safety

```go
// ✅ CORRECT - Using sync.Mutex
type SafeCounter struct {
    mu    sync.Mutex
    count int
}

func (c *SafeCounter) Inc() {
    c.mu.Lock()
    defer c.mu.Unlock()
    c.count++
}

// ✅ CORRECT - Using channels
func worker(jobs <-chan Job, results chan<- Result) {
    for job := range jobs {
        results <- process(job)
    }
}

// ❌ WRONG - Race condition
type UnsafeCounter struct {
    count int  // Accessed by multiple goroutines without protection
}
```

### Interface Standards

```go
// ✅ CORRECT - Small, focused interfaces
type Reader interface {
    Read(p []byte) (n int, err error)
}

type Writer interface {
    Write(p []byte) (n int, err error)
}

// ✅ CORRECT - Interface segregation
type Closer interface {
    Close() error
}

type ReadCloser interface {
    Reader
    Closer
}

// ❌ WRONG - God interfaces
type Everything interface {
    Read() error
    Write() error
    Close() error
    Connect() error
    Execute() error
    // ... 20 more methods
}
```

## Testing Requirements

### Test Organization

```go
// Separate test packages for black-box testing
package mypackage_test

import (
    "testing"

    "github.com/yourorg/yourproject/mypackage"
)

func TestProcessRequest(t *testing.T) {
    tests := []struct {
        name    string
        input   *Request
        want    *Response
        wantErr bool
    }{
        {
            name: "valid request",
            input: &Request{ID: "123"},
            want: &Response{Status: "ok"},
            wantErr: false,
        },
        {
            name: "invalid request",
            input: &Request{ID: ""},
            want: nil,
            wantErr: true,
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            got, err := ProcessRequest(context.Background(), tt.input)
            if (err != nil) != tt.wantErr {
                t.Errorf("ProcessRequest() error = %v, wantErr %v", err, tt.wantErr)
                return
            }
            if !reflect.DeepEqual(got, tt.want) {
                t.Errorf("ProcessRequest() = %v, want %v", got, tt.want)
            }
        })
    }
}
```

### Benchmark Requirements

```go
// Performance-critical code must have benchmarks
func BenchmarkProcessRequest(b *testing.B) {
    req := &Request{ID: "123"}

    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        _, _ = ProcessRequest(context.Background(), req)
    }
}
```

## Pre-commit Hooks

The installed `.pre-commit-config.yaml` enforces these gates on commit: gofmt, `go vet ./...`,
`go mod tidy` when go.mod or go.sum changes, `go test ./...` on push, and golangci-lint when it is
installed (required once a `.golangci.yml` exists). It never touches `docs/cycles/` (cycle records),
`docs/acf/` (plugin-managed docs), `.backlog/` (task state) or `.acfwhip/` (config and the LP-CAS
ledger): acf-whip commits those itself, and a hook that rewrites one fails that commit.

```bash
pre-commit run --all-files
```

## Quality Gate Protocol

### When Checks Fail

1. **Attempts 1-10**: Fix actual issues
2. **After 10 attempts**: Move task to blocked with report

### Failure Report Format

```markdown
# Quality Gate Failure Report

## Task: [task-name]

## Component: Go

## Attempts: 10

## Failures:

1. golangci-lint: X issues
2. Tests: Y failures
3. Coverage: Z% (required: 80%)
4. Race detector: N data races found

## Attempted Fixes:

1. [Fix description] - Failed: [reason]
2. [Fix description] - Failed: [reason]

## Blockers:

- [Specific blocker requiring intervention]
```

## Forbidden Bypass Methods

**NEVER use**:

- `//nolint` comments (except with documented justification)
- `git commit --no-verify`
- Disabling linters in config
- Lowering coverage thresholds
- `// +build !test` to skip tests
- Ignoring race detector warnings

## Performance Requirements (Optional - Customize)

### Example for API Services

- API response time: < 100ms (p90)
- Memory allocation: Minimize in hot paths
- Goroutine leaks: Zero tolerance
- Database connection pool: 10-25 connections

### Optimization Patterns

- Use `sync.Pool` for frequently allocated objects
- Prefer value receivers for small structs
- Use buffered channels appropriately
- Profile before optimizing (`pprof`)

## Dependencies Management

```bash
# Add dependency
go get github.com/gin-gonic/gin

# Update dependencies
go get -u ./...

# Tidy dependencies
go mod tidy

# Verify dependencies
go mod verify

# Vendor dependencies (optional)
go mod vendor
```

### Security Requirements

- Run `govulncheck` weekly
- Update dependencies monthly
- No packages with known vulnerabilities
- Use `go.sum` for reproducible builds

## Continuous Integration

```yaml
# GitHub Actions
jobs:
  quality:
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'
      - name: Lint
        uses: golangci/golangci-lint-action@v3
        with:
          version: latest
      - name: Test
        run: go test ./... -v -race -cover -coverprofile=coverage.out
      - name: Coverage check
        run: |
          total=$(go tool cover -func=coverage.out | grep total | awk '{print $3}' | sed 's/%//')
          if (( $(echo "$total < 80" | bc -l) )); then
            echo "Coverage $total% is below 80%"
            exit 1
          fi
      - name: Build
        run: go build ./...
```

Failed CI blocks merge. NO exceptions.
