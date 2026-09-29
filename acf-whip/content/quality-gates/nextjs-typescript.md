# Quality Gates - Next.js/TypeScript

The gates for Next.js projects. They assume the App Router and TypeScript; every other Node.js project
uses the Node.js gates. A Next.js task is not done until every command under Quality Requirements
passes.

## Zero Bypass Tolerance

Never bypass a quality gate, for any reason. Fix the code until the gate passes, or report the task
blocked under the Quality Gate Protocol below.

## Quality Requirements

### Build & Type Checking

```bash
# MANDATORY - Must all pass
pnpm build          # Next.js build must succeed
pnpm typecheck      # TypeScript strict mode
pnpm lint           # ESLint with Next.js config
pnpm test --coverage # Jest/Vitest with coverage
```

### Test Coverage

| Code Type | Minimum Coverage |
|-----------|------------------|
| Routes | 80% |
| Core logic | 90% |
| Utilities | 85% |
| Components | 80% |

### Code Quality Standards

#### ESLint Configuration

```javascript
// Required rules (non-negotiable)
{
  "extends": ["next/core-web-vitals"],
  "rules": {
    "@typescript-eslint/no-explicit-any": "error",
    "@typescript-eslint/explicit-function-return-type": "warn",
    "no-console": ["error", { "allow": ["warn", "error"] }],
    "no-debugger": "error",
    "no-unused-vars": "error"
  }
}
```

#### TypeScript Configuration

```json
// tsconfig.json requirements
{
  "compilerOptions": {
    "strict": true,
    "noImplicitAny": true,
    "strictNullChecks": true,
    "strictFunctionTypes": true,
    "strictBindCallApply": true,
    "noImplicitThis": true,
    "alwaysStrict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true
  }
}
```

### Pre-commit Hooks

Every hook must pass, and `--no-verify` is never allowed. A Husky and lint-staged setup looks like
this:

```yaml
# .husky/pre-commit
#!/bin/sh
. "$(dirname "$0")/_/husky.sh"

pnpm lint-staged
```

```json
// lint-staged.config.js
{
  "*.{ts,tsx}": ["eslint --fix", "prettier --write"],
  "*.{json,md}": ["prettier --write"]
}
```

## Next.js Specific Requirements

### App Router Standards

- **Server Components**: every page is one by default
- **Client Components**: only where a component needs the browser, marked with `'use client'`
- **Metadata**: routes export their SEO metadata
- **Loading States**: a `loading.tsx` in each route group
- **Error Boundaries**: an `error.tsx` in each route group

### API Route Standards

Every API route returns the same response shape, on success and on failure:

```typescript
// Standardized response format
type ApiResponse<T> = {
  success: boolean
  data?: T
  error?: {
    code: string
    message: string
  }
}

// Error handling
try {
  // logic
  return NextResponse.json({ success: true, data })
} catch (error) {
  return NextResponse.json(
    { success: false, error: { code: 'ERROR_CODE', message } },
    { status: 500 }
  )
}
```

### Performance Requirements

- **Bundle Size**: < 200KB for initial load
- **Lighthouse Score**: > 90 for all metrics
- **Core Web Vitals**:
  - LCP < 2.5s
  - FID < 100ms
  - CLS < 0.1

## Quality Gate Protocol

### When Checks Fail

1. **Attempts 1-10**: fix the underlying problem, not the check, and rerun.
2. **After 10 attempts**: stop and report the task blocked, with a failure report in the format below.

### Failure Report Format

```markdown
# Quality Gate Failure Report

## Task: [task-name]

## Component: Next.js/TypeScript

## Attempts: 10

## Failures:

1. ESLint: X errors, Y warnings
2. TypeScript: X type errors
3. Tests: X% coverage (required: 90%)

## Attempted Fixes:

1. [Fix description] - Failed: [reason]
2. [Fix description] - Failed: [reason]

## Blockers:

- [Specific blocker requiring intervention]
```

## Forbidden Bypass Methods

Never use any of these:

- `git commit --no-verify`
- `git push --no-verify`
- `SKIP=lint git commit`
- `// @ts-ignore`
- `// eslint-disable`
- Disabling rules in config files
- Lowering coverage thresholds

## Continuous Integration

Every CI pipeline must run at least these steps:

```yaml
# GitHub Actions example
jobs:
  quality:
    steps:
      - run: pnpm install
      - run: pnpm lint
      - run: pnpm typecheck
      - run: pnpm test --coverage
      - run: pnpm build
```

A failed CI run blocks the merge, with no exceptions.
