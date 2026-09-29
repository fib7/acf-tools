# Quality Gates - Node.js

For every Node.js project that is not Next.js: a plain CLI or library, Express, Fastify, NestJS,
React or Vue, in JavaScript or TypeScript. Next.js projects use the Next.js/TypeScript gates. A task
is not done until the gates under Quality Requirements pass.

## Zero Bypass Tolerance

Never bypass a quality gate, for any reason. Fix the code until the gate passes, or report the task
blocked under the Quality Gate Protocol below.

## The Rule: Gates Are the Project's Own Scripts

The gates are the scripts in `package.json`. Run the ones the project defines. A gate the project
has not defined is skipped, never invented: a plain project has no build step, no linter and no
TypeScript, and a gate that demands one fails every task for a reason no task can fix.
`npm run <name> --if-present` handles this. It runs the script when it exists and exits 0 when it
does not.

Adding a tool the project does not use (ESLint, TypeScript, a bundler, a test framework) is a
decision for a task that says so, never a side effect of passing the gates.

## Quality Requirements

### Mandatory, every task

```bash
npm test                          # the project's test runner: node --test, jest, vitest, mocha
```

`npm test` must pass. If `package.json` has no `test` script, or still has npm init's placeholder
(`echo "Error: no test specified" && exit 1`), a task that adds behavior adds a test script with its
tests. `"test": "node --test"` needs no dependency.

### When the project defines them

```bash
npm run lint --if-present         # the project's linter (eslint, biome, standard, ...)
npm run typecheck --if-present    # TypeScript projects
npm run build --if-present        # projects with a build step
```

TypeScript project (`tsconfig.json` exists) with no `typecheck` script: run `npx tsc --noEmit`.
ESLint configured (`eslint.config.*` or `.eslintrc*`) with no `lint` script: run `npx eslint .`.
prettier in `package.json`: `npx prettier --check .` must pass.

Use the project's package manager: `pnpm-lock.yaml` means `pnpm`, `yarn.lock` means `yarn`,
`bun.lock`/`bun.lockb` means `bun`, otherwise `npm`.

### Test Coverage

| Code Type | Minimum Coverage |
|-----------|------------------|
| Core logic | 90% |
| Request handlers / CLI commands | 85% |
| Utilities | 85% |
| UI components | 80% |

Measure it with the runner the project already uses:

| Runner | Coverage command |
|--------|------------------|
| `node --test` | `node --test --experimental-test-coverage` (Node 20+); add `--test-coverage-lines=80 --test-coverage-branches=80 --test-coverage-functions=80` to enforce (Node 22.8+) |
| jest | `npx jest --coverage` (thresholds: `coverageThreshold` in the jest config) |
| vitest | `npx vitest run --coverage` (needs `@vitest/coverage-v8`; thresholds: `test.coverage.thresholds`) |
| mocha | `npx c8 mocha` (needs `c8`) |

Passing a gate is no reason to install a coverage tool the project lacks. Report the coverage the
existing runner can measure, and name the tool that is missing.

## Code Standards

- **Module system**: follow `package.json` `"type"`. `"module"` means ESM (`import`), absent or
  `"commonjs"` means CommonJS (`require`). Never mix the two in one package.
- **Built-ins**: import with the `node:` prefix (`node:fs`, `node:test`, `node:assert`).
- **Async errors**: every promise is awaited or has a rejection handler. An unhandled rejection
  crashes the process on Node 15+.
- **CLI exit codes**: a CLI exits non-zero on failure (`process.exitCode = 1`), and prints errors
  to stderr, not stdout.
- **Dependencies**: the standard library first. A new runtime dependency needs a reason in the task
  evidence.
- **Engines**: code runs on the Node version in `package.json` `"engines"` (or `.nvmrc`).

## Pre-commit Hooks

The installed `.pre-commit-config.yaml` enforces the gates on commit and push. Its hooks run only
what the project has:

- `npm run lint|typecheck|build --if-present` on a commit that stages source or JSON
- `npm test --if-present` on push, skipped while the script is still npm init's placeholder
- the project's own prettier, when `package.json` declares it

None of them fire until someone runs `pre-commit install`, plus
`pre-commit install --hook-type pre-push` for the test hook.

The config never touches `docs/cycles/` (cycle records), `docs/acf/` (plugin-managed docs),
`.backlog/` (task state) or `.acfwhip/` (config and the LP-CAS ledger). acf-whip commits those
itself, and a hook that rewrites one fails that commit.

To run every hook by hand:

```bash
pre-commit run --all-files
```

A frontend next to a Go or Python backend reads this doc too. Its repo gets the backend's config,
which runs none of the npm hooks, so run the gates above yourself before you mark a task complete.

## Quality Gate Protocol

### When Checks Fail

1. **Attempts 1-10**: fix the underlying problem, not the check, and rerun.
2. **After 10 attempts**: stop and report the task blocked, with this report.

### Failure Report Format

```markdown
# Quality Gate Failure Report

## Task: [task-name]

## Component: Node.js

## Attempts: 10

## Failures:

1. npm test: X failing tests
2. npm run lint: X errors (if the project defines lint)
3. Coverage: X% (required: 90% core logic)

## Attempted Fixes:

1. [Fix description] - Failed: [reason]

## Blockers:

- [Specific blocker requiring intervention]
```

## Forbidden Bypass Methods

Never use any of these:

- `git commit --no-verify`
- `git push --no-verify`
- `SKIP=<hook> git commit`
- `test.skip`, `it.only`, `describe.skip` left in committed tests
- `// eslint-disable` or `// @ts-ignore` to silence a real finding
- Deleting or weakening a failing test
- Lowering coverage thresholds

## Continuous Integration

CI runs the same gates the project defines:

```yaml
# GitHub Actions example
jobs:
  quality:
    steps:
      - run: npm ci
      - run: npm run lint --if-present
      - run: npm run typecheck --if-present
      - run: npm test
      - run: npm run build --if-present
```

A failed CI run blocks the merge, with no exceptions.
