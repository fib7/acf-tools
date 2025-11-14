# Quality Gates - Next.js/TypeScript

## Zero Bypass Tolerance

**ABSOLUTELY FORBIDDEN**: Bypassing quality gates is STRICTLY PROHIBITED. **NO EXCEPTIONS.**

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

- **Routes**: 80% minimum coverage
- **Core Logic**: 90% minimum coverage
- **Utilities**: 85% minimum coverage
- **Components**: 80% minimum coverage

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

**MANDATORY**: All hooks must pass. NO --no-verify allowed.

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

- **Server Components**: Default for all pages
- **Client Components**: Only when necessary, marked with 'use client'
- **Metadata**: Proper SEO metadata exports
- **Loading States**: loading.tsx for each route group
- **Error Boundaries**: error.tsx for each route group

### API Route Standards

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

1. **Attempts 1-10**: Fix actual issues
2. **After 10 attempts**: Move task to blocked with failure report

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

**NEVER use**:

- `git commit --no-verify`
- `git push --no-verify`
- `SKIP=lint git commit`
- `// @ts-ignore`
- `// eslint-disable`
- Disabling rules in config files
- Lowering coverage thresholds

## Continuous Integration

All CI pipelines must include:

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

Failed CI blocks merge. NO exceptions.
