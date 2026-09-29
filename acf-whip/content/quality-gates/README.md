# Quality Gates

One document per stack, listing the commands a task's code must pass before review. `/whip-init` and
`/whip-add-agents` copy the matching one into a project as `docs/development/quality-gates-<stack>.md`.
Specialists work to it. The quality-reviewer checks their evidence against it.

## Zero Bypass Tolerance

A gate passes or the task is not done. Never pass `--no-verify` to git, disable a rule, or lower a
threshold to get a failing gate through: each bypass leaves a known failure in the code for someone
else to find later.

Three layers catch a bypass:
- Pre-commit hooks stop the commit
- CI blocks the merge
- Code review catches one written into the code

## Stack Docs

| Stack | Doc |
|-------|-----|
| **Node.js** (plain Node, Express, Fastify, NestJS, React, Vue) | [nodejs.md](nodejs.md) |
| **Next.js/TypeScript** | [nextjs-typescript.md](nextjs-typescript.md) |
| **Python/FastAPI** | [python-fastapi.md](python-fastapi.md) |
| **Go** | [go.md](go.md) |
| **Any other stack** | [template.md](template.md), filled in with [guidelines.md](guidelines.md) |

## Which Doc a Project Gets

`/whip-init` and `/whip-add-agents` both ask [detect-stack.sh](detect-stack.sh), so the two skills
never disagree. It runs from the project root and prints two values for the backend. `gate_stack`
names the pre-commit config to install (`.pre-commit-config-<gate_stack>.yaml`) and the destination,
`docs/development/quality-gates-<gate_stack>.md`. `gates_doc` names the source file in this directory.

| Detected | gate_stack | gates_doc |
|----------|------------|-----------|
| `go.mod` | go | go.md |
| `requirements.txt`, `pyproject.toml`, `setup.py`, `setup.cfg` or `Pipfile` | python | python-fastapi.md |
| `package.json` with `next` | nodejs | nextjs-typescript.md |
| any other `package.json`, including one with no framework at all | nodejs | nodejs.md |

First match wins, top to bottom: a Go module with a `package.json` for tooling gets the Go gates.

A frontend gets gates of its own. Whenever `package.json` has `next`, `react` or `vue`, the detector
also prints `frontend_gate_stack=nodejs` and `frontend_gates_doc` (`nextjs-typescript.md` for Next.js,
`nodejs.md` otherwise), installed as `docs/development/quality-gates-nodejs.md`. In a FastAPI plus
React repo, then, the python-engineer reads the Python gates and the react-engineer reads the Node.js
gates. When the backend is Node.js too, both are the same file.

`--backend=<stack>` and `--frontend=<stack>` override detection for that slot, so a skill's flags pick
the gates. A stack with no shipped doc (`--backend=rust`) gets an empty `gate_stack`, and
`/whip-add-agents` writes its doc from a template instead.

## Sections Every Stack Doc Has

The stack docs cover the same eight things, in roughly this order:

1. **Zero Bypass Tolerance**: the rule that no gate is bypassed
2. **Quality Requirements**: the commands that must pass
3. **Code Standards**: lint, type-check and format configuration
4. **Test Coverage**: minimum coverage per kind of code
5. **Pre-commit Hooks**: what runs on commit
6. **Quality Gate Protocol**: what to do when a gate fails (10 attempts, then blocked)
7. **Forbidden Bypass Methods**: the bypasses the doc bans, each named
8. **Continuous Integration**: what CI runs

## Quick Reference

### Node.js
```bash
npm test                          # the project's own runner (node --test, jest, vitest)
npm run lint --if-present         # only when package.json defines it
npm run typecheck --if-present    # TypeScript projects
npm run build --if-present        # projects with a build step
```

### Next.js/TypeScript
```bash
pnpm build          # Next.js build
pnpm typecheck      # TypeScript strict
pnpm lint           # ESLint
pnpm test --coverage # Jest/Vitest with coverage
```

### Python/FastAPI
```bash
uv run ruff check .           # Linting
uv run ruff format . --check  # Formatting
uv run mypy . --strict        # Type checking
uv run pytest --cov=src       # Tests with coverage
```

### Go
```bash
golangci-lint run ./...                 # Comprehensive linting
go test ./... -v -race -cover          # Tests with race detection
go build ./...                          # Build verification
```

## When a Gate Fails

Fix the underlying problem and run the gate again, up to 10 attempts. After the tenth, the task goes
to `blocked` with a failure report.

The cap stops an agent looping on fixes that don't work. `/go` puts a blocked task back in the queue
until its `Block-Count` reaches the cap (3 by default). From then on it stays in `blocked/` until an
operator clarifies its design or its requirement.

## Name the Command

A gates doc names the exact tool, never the category:

- TypeScript: `tsc --noEmit`, not "type checking"
- Python: `mypy --strict`, not "type hints validation"
- Go: `golangci-lint`, which runs govet among its linters, rather than `go vet` alone

## Coverage Thresholds

Riskier code gets a higher bar. Each stack doc sets its own numbers.

| Code Type | Coverage Threshold | Rationale |
|-----------|-------------------|-----------|
| **API endpoints** | 90-95% | Customer-facing, high impact |
| **Core logic** | 90% | Business logic must be verified |
| **Services** | 85-90% | Integration points need testing |
| **Utilities** | 85% | Support code, lower risk |
| **UI components** | 80% | Visual tests cover part of it |

## Where acf-whip Checks the Gates

- **Review**: the quality-reviewer rejects a task unless its evidence carries the complete output of
  every gate command, each exiting 0. When the multi-lens review panel runs (`args.escalateReview`,
  off by default), its first stage reruns the gates in the task's worktree before any lens reads the
  diff.
- **Commits**: the `.pre-commit-config.yaml` that `/whip-init` installs runs the fast gates on every
  commit, once `pre-commit install` has been run.
- **Parallel runs**: `/go` reviews every task on its own, so running tasks side by side relaxes no
  gate.
- **Specialists**: each one works from the gates doc for its own stack, so a React specialist in a
  Python repo runs the Node.js gates.

## References

- [Backlog Workflow](../backlog-workflow-template.md)
- [Git Commit Conventions](../git-commit-conventions-template.md)
- [Guidelines for Custom Gates](guidelines.md)
