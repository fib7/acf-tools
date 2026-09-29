# Quality Gates - Python/FastAPI

## Zero Bypass Tolerance

**ABSOLUTELY FORBIDDEN**: Bypassing quality gates is STRICTLY PROHIBITED. **NO EXCEPTIONS.**

## Python Environment Requirements

### Package Management

**Recommended**: UV for fast, reliable package management

```bash
# ✅ RECOMMENDED
uv run python script.py
uv run pytest
uv pip install package

# ✅ ACCEPTABLE - virtualenv
source .venv/bin/activate
python script.py
```

## Quality Requirements

### Code Quality Tools

```bash
# MANDATORY - Must all pass
ruff check .                 # Linting (or: uv run ruff check .)
ruff format . --check        # Formatting (or: uv run ruff format . --check)
mypy . --strict              # Type checking (or: uv run mypy . --strict)
pytest --cov=src             # Tests with coverage (or: uv run pytest --cov=src)
```

### Test Coverage

- **Core Logic**: 90% minimum
- **API Endpoints**: 95% minimum
- **Services**: 90% minimum
- **Utilities**: 85% minimum

## Code Standards

### Ruff Configuration

```toml
# pyproject.toml
[tool.ruff]
line-length = 100
target-version = "py311"

[tool.ruff.lint]
select = [
    "E",   # pycodestyle errors
    "W",   # pycodestyle warnings
    "F",   # pyflakes
    "I",   # isort
    "B",   # flake8-bugbear
    "C4",  # flake8-comprehensions
    "UP",  # pyupgrade
    "ARG", # flake8-unused-arguments
    "SIM", # flake8-simplify
]
ignore = []

[tool.ruff.format]
quote-style = "double"
indent-style = "space"
```

### Mypy Configuration

```toml
# pyproject.toml
[tool.mypy]
strict = true
python_version = "3.11"
warn_return_any = true
warn_unused_configs = true
disallow_untyped_defs = true
disallow_any_unimported = true
no_implicit_optional = true
warn_redundant_casts = true
warn_unused_ignores = true
warn_no_return = true
```

### Pytest Configuration

```toml
# pyproject.toml
[tool.pytest.ini_options]
minversion = "7.0"
testpaths = ["tests"]
pythonpath = ["src"]
addopts = [
    "--strict-markers",
    "--cov=src",
    "--cov-report=term-missing",
    "--cov-report=html",
    "--cov-fail-under=90"
]
```

## FastAPI Specific Requirements

### API Standards

```python
from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel, Field
from typing import Optional, List

# Response models with validation
class ApiResponse(BaseModel):
    success: bool
    data: Optional[dict] = None
    error: Optional[str] = None

# Proper error handling
@app.post("/analyze", response_model=ApiResponse)
async def analyze(request: AnalysisRequest) -> ApiResponse:
    try:
        result = await process_analysis(request)
        return ApiResponse(success=True, data=result)
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e)
        )
    except Exception as e:
        logger.error(f"Analysis failed: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Internal server error"
        )
```

### Async Requirements

- ALL database operations must be async
- ALL external API calls must be async
- Use `httpx` for HTTP requests (not `requests`)
- Use `asyncio` for concurrent operations

### Type Safety

```python
# ✅ CORRECT - Fully typed
from typing import List, Dict, Optional, Any
from datetime import datetime

async def process_data(
    input: str,
    metadata: Dict[str, Any],
    timestamp: datetime
) -> Dict[str, List[float]]:
    ...

# ❌ WRONG - Missing types
async def process_data(input, metadata, timestamp):
    ...
```

## Pre-commit Hooks

The installed `.pre-commit-config.yaml` enforces these gates on commit: ruff and ruff format always,
mypy once the project configures it (`[tool.mypy]` in pyproject.toml, `mypy.ini`, or `[mypy]` in
setup.cfg), and pytest on push once the project declares it. mypy and pytest run in the project's
own environment: uv, poetry, `.venv`, or PATH. Set `strict = true` under `[tool.mypy]` so the hook
enforces the `--strict` gate above. The config never touches `docs/cycles/` (cycle records),
`docs/acf/` (plugin-managed docs), `.backlog/` (task state) or `.acfwhip/` (config and the LP-CAS
ledger): acf-whip commits those itself, and a hook that rewrites one fails that commit. ruff runs at
the version the config pins and reads your `[tool.ruff]`; keep that pin at or above the ruff you use.

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

## Component: Python/FastAPI

## Attempts: 10

## Failures:

1. Ruff: X errors found
2. Mypy: X type errors
3. Pytest: X% coverage (required: 90%)

## Attempted Fixes:

1. [Fix description] - Failed: [reason]
2. [Fix description] - Failed: [reason]

## Blockers:

- [Specific blocker requiring intervention]
```

## Forbidden Bypass Methods

**NEVER use**:

- `# type: ignore`
- `# noqa`
- `# pragma: no cover`
- `--no-verify` in commits
- Lowering coverage requirements
- Disabling mypy strict mode
- Using `Any` type unnecessarily

## Performance Requirements (Optional - Customize)

### Example for API Services

- API response time: < 200ms (p90)
- Concurrent requests: 100+ minimum
- Memory usage: < 512MB per worker
- Database connection pool: 10-20 connections

### Optimization Patterns

- Use `asyncio.gather()` for parallel operations
- Implement connection pooling for database
- Cache frequently accessed data
- Stream large files instead of loading to memory

## Dependencies Management

### Using UV (Recommended)

```bash
# Add dependency
uv pip install fastapi

# Add dev dependency
uv pip install --dev pytest pytest-cov

# Lock dependencies
uv pip freeze > requirements.txt

# Install from lock file
uv pip install -r requirements.txt
```

### Using virtualenv

```bash
# Create virtual environment
python -m venv .venv

# Activate
source .venv/bin/activate  # Linux/Mac
.venv\Scripts\activate     # Windows

# Install dependencies
pip install -r requirements.txt
```

### Security Requirements

- Run `pip audit` or `uv pip audit` weekly
- Update dependencies monthly
- No packages with known vulnerabilities
- Pin all production dependencies

## Continuous Integration

```yaml
# GitHub Actions
jobs:
  quality:
    steps:
      - uses: actions/checkout@v3
      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.11'
      - name: Install dependencies
        run: pip install -r requirements.txt
      - name: Lint
        run: ruff check .
      - name: Format check
        run: ruff format . --check
      - name: Type check
        run: mypy . --strict
      - name: Test
        run: pytest --cov=src --cov-fail-under=90
```

Failed CI blocks merge. NO exceptions.
