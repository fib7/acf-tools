# DevOps Agent Manifest Pattern

Pattern for `docs/agents/devops.md`. Unlike the specialist patterns, its Priority 1 and 2 lists are
not fixed: build them from the docs that exist in the project, as described below the template.

## Template Variables

- `{LOCAL_ORCHESTRATION}`: docker-compose, tilt, skaffold
- `{DEPLOYMENT_TARGET}`: kubernetes, docker-swarm, vms
- `{CI_TOOL}`: github-actions, gitlab-ci, circleci
- `{MONITORING_STACK}`: prometheus-grafana, datadog, newrelic
- `{CLOUD_PROVIDER}`: gke, eks, aks, onprem
- `{CONDITIONAL_DOCS_P1}`: Generated list based on docs/ scan
- `{CONDITIONAL_DOCS_P2}`: Generated list based on docs/ scan
- `{CONDITIONAL_QUALITY_GATES}`: Generated based on orchestration type

## Manifest Template

```markdown
# devops Documentation Manifest

## Agent Identity

**Role**: DevOps, deployment, and monitoring specialist

**Technology Focus**: {LOCAL_ORCHESTRATION}, {DEPLOYMENT_TARGET}, {MONITORING_STACK}, CI/CD

**Scope**: {LOCAL_ORCHESTRATION} orchestration, production deployment, monitoring stack, troubleshooting, CI/CD pipelines

**Out of Scope**: K8s manifests → k8s-engineer | Application code → specialists

---

## Priority 1: MUST READ

{CONDITIONAL_DOCS_P1}

---

## Priority 2: SHOULD READ

{CONDITIONAL_DOCS_P2}

---

## Scope Boundaries

**IS**: {LOCAL_ORCHESTRATION}, deployment workflows, monitoring ({MONITORING_STACK}), troubleshooting, CI/CD

**NOT**: K8s manifests → k8s-engineer | Application logic → specialists

---

## Quality Gates

{CONDITIONAL_QUALITY_GATES}

---

## Concurrency
**Step 0** (every workflow): invoke `clean-checkout-before-task` before any edit. Commit on
`worktree/<slug>`, never on `main`, and commit code only: never the task file, never task state. The
token `clean-checkout: ok` must be in the task's transition log. The skill writes it, and review
auto-rejects a task without it.

## Common Workflows

1. **Local Deploy**: Step 0 → Config → Deploy → Verify → Troubleshoot
2. **CI Pipeline**: Step 0 → Configure → Test → Deploy → Monitor
3. **Monitoring**: Step 0 → Install → Configure → Test → Document
4. **Troubleshoot**: Step 0 → Logs → Metrics → Debug → Fix

---

## Anti-Patterns

| Never | Always | Why |
|-------|--------|-----|
| Skip health checks | Verify all services | Silent failures |
| Hardcode secrets | Use env/Vault | Security risk |
| Deploy without tests | Run quality gates | Break production |
| Ignore monitoring | Set up alerts | Miss incidents |

---

**Last Updated**: {CURRENT_DATE}
```

## Conditional Priority 1 Docs

**Standard locations to check** (in order of priority):

1. `docs/operations/deployment.md` (core)
2. `docs/operations/monitoring.md` (core)
3. `docs/operations/environment.md` (core)
4. `docs/architecture/local-vs-production.md` (context)
5. `docs/operations/troubleshooting.md` (frequent)

**Generation logic**:
```bash
# Check existence and build P1 list
priority1_docs=""
doc_number=1

if [ -f "docs/operations/deployment.md" ]; then
  priority1_docs+="${doc_number}. **\`docs/operations/deployment.md\`**\n"
  doc_number=$((doc_number + 1))
fi

if [ -f "docs/operations/monitoring.md" ]; then
  priority1_docs+="${doc_number}. **\`docs/operations/monitoring.md\`**\n"
  doc_number=$((doc_number + 1))
fi

# ... continue for other docs
```

**If no operations docs exist** (true of every new project), do not tell the agent to create them.
A MUST READ entry that is a to-do turns every devops task into a documentation task. Write this
instead:
```markdown
## Priority 1: MUST READ

1. The task document at the path your prompt gives
2. The Quality Gates section below

This project has no `docs/operations/` docs yet. Create one only when your task asks for it.
```

## Conditional Priority 2 Docs

**Standard locations to check**. List only the files that exist (`[ -f <path> ]`), and drop a
sub-heading whose docs are all absent. If none of them exist, the whole section body is
`No project docs yet.`

1. `docs/operations/troubleshooting.md`
2. `docs/operations/ci-cd.md`
3. `docs/architecture/service-architecture.md` → Services section
4. `docs/development/local-development.md`

**Format**:
```markdown
## Priority 2: SHOULD READ

### For Deployment Tasks
- **\`docs/operations/troubleshooting.md\`** - Common issues and solutions
- **\`docs/architecture/service-architecture.md\`** → Services - Dependencies and ports

### For CI/CD Configuration
- **\`docs/operations/ci-cd.md\`** - Pipeline patterns
```

## Conditional Quality Gates

**For Docker Compose**:
````markdown
```bash
# Docker Compose validation
docker-compose -f ops/local/compose.yml config

# Health checks
ops/scripts/health_check.sh
```
````

**For Kubernetes**:
````markdown
```bash
# K8s validation (delegates actual manifests to k8s-engineer)
kubectl apply --dry-run=client -f k8s/

# Health checks
kubectl get pods --all-namespaces
```
````

**For CI/CD** (GitHub Actions example):
````markdown
```bash
# Lint GitHub Actions workflows
actionlint .github/workflows/*.yml

# Test workflows locally (optional)
act -l
```
````

## Example: Generated Manifest (Docker Compose + GitHub Actions)

```markdown
# devops Documentation Manifest

## Agent Identity

**Role**: DevOps, deployment, and monitoring specialist

**Technology Focus**: docker-compose, kubernetes, prometheus-grafana, CI/CD

**Scope**: docker-compose orchestration, production deployment, monitoring stack, troubleshooting, CI/CD pipelines

**Out of Scope**: K8s manifests → k8s-engineer | Application code → specialists

---

## Priority 1: MUST READ

1. **`docs/operations/deployment.md`**
2. **`docs/operations/monitoring.md`**
3. **`docs/operations/environment.md`**
4. **`docs/architecture/local-vs-production.md`**

---

## Priority 2: SHOULD READ

### For Deployment Tasks
- **`docs/operations/troubleshooting.md`** - Common issues
- **`docs/architecture/service-architecture.md`** → Services

### For CI/CD
- **`docs/operations/ci-cd.md`** - Pipeline patterns

---

## Scope Boundaries

**IS**: docker-compose, deployment workflows, monitoring (prometheus-grafana), troubleshooting, CI/CD

**NOT**: K8s manifests → k8s-engineer | Application logic → specialists

---

## Quality Gates

```bash
# Docker Compose validation
docker-compose -f ops/local/compose.yml config

# Health checks
ops/scripts/health_check.sh
```

---

## Concurrency
**Step 0** (every workflow): invoke `clean-checkout-before-task` before any edit. Commit on
`worktree/<slug>`, never on `main`, and commit code only: never the task file, never task state. The
token `clean-checkout: ok` must be in the task's transition log. The skill writes it, and review
auto-rejects a task without it.

## Common Workflows

1. **Local Deploy**: Step 0 → Config → Deploy → Verify → Troubleshoot
2. **CI Pipeline**: Step 0 → Configure → Test → Deploy → Monitor
3. **Monitoring**: Step 0 → Install → Configure → Test → Document
4. **Troubleshoot**: Step 0 → Logs → Metrics → Debug → Fix

---

## Anti-Patterns

| Never | Always | Why |
|-------|--------|-----|
| Skip health checks | Verify all services | Silent failures |
| Hardcode secrets | Use env/Vault | Security risk |
| Deploy without tests | Run quality gates | Break production |
| Ignore monitoring | Set up alerts | Miss incidents |

---

**Last Updated**: 2025-11-09
```
