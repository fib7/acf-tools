---
name: audit-acf-conventions
description: Check project compliance with ACF naming and organization conventions. Use the --fix flag to fix the violations the audit is allowed to change; the rest are reported.
argument-hint: "[--fix]"
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
  - Edit
---

# ACF Audit: Convention Compliance Checker

Scan the current project for violations of the ACF naming and organization conventions in `docs/acf/organization.md`, and report each one with its fix.

**Modes**:
- **Audit mode** (default): report violations and how to fix each. Changes nothing.
- **Fix mode** (`--fix` flag): fix what the audit is allowed to change. Cycle folders, lessons and links in protected documents stay report-only, and verbosity findings are suggestions.

**Note**: the ACF Librarian SessionStart hook has already put the conventions in your context. Use them for what to check and what a correct name looks like.

---

## Pre-Execution Check

Before running, confirm that:
- the ACF conventions are in your context (from the SessionStart hook)
- you are in the project root, not a subdirectory
- `docs/acf/organization.md` exists (the SessionStart hook normally creates it)

**If `docs/acf/organization.md` is missing or empty**:
- **Fix mode** (`--fix`): create it from the plugin template at `${CLAUDE_PLUGIN_ROOT}/content/organization-template.md` and continue
- **Audit mode**: report it as a critical violation and keep checking the other categories

---

## Command

Parse the arguments and, in fix mode, run the safety check below. Then run Steps 0 to 9 in order. Only Step 0 and Step 8 write anything, and only under `--fix`. Step 9 prints the report.

### Argument Parsing

**Check for the `--fix` flag** in the command arguments:

```bash
# Parse arguments for fix mode
fix_mode=false

# Check both $ARGUMENTS (Claude Code environment variable) and positional args
if [[ "$ARGUMENTS" == *"--fix"* ]] || [[ "$*" == *"--fix"* ]]; then
    fix_mode=true
    echo "🔧 FIX MODE ENABLED - Will auto-fix all violations"
else
    fix_mode=false
    echo "📋 AUDIT MODE - Reporting violations only (use --fix to auto-fix)"
fi
```

**Safety check** (fix mode only):
```bash
if [ "$fix_mode" = true ]; then
    # Warn if uncommitted changes exist
    if ! git diff-index --quiet HEAD 2>/dev/null; then
        echo "⚠️  WARNING: You have uncommitted changes."
        echo "   Recommend: git commit or git stash before running --fix"
        echo "   Continue anyway? (Ctrl+C to abort, Enter to continue)"
        read
    fi
fi
```

### Algorithm

#### 0. Initialize Core Files (Fix Mode Bootstrap)

**Before any check runs**, make sure the core ACF files exist, so fix mode can set up a project that has none of them yet.

**A. Initialize `docs/acf/organization.md`** (if missing or empty):

```bash
org_file="docs/acf/organization.md"

if [ ! -f "$org_file" ] || [ ! -s "$org_file" ]; then
    if [ "$fix_mode" = true ]; then
        mkdir -p docs/acf
        # Read template from plugin and write to project
        cat "${CLAUDE_PLUGIN_ROOT}/content/organization-template.md" > "$org_file"
        echo "✅ Initialized docs/acf/organization.md from plugin template"
    else
        echo "❌ CRITICAL: docs/acf/organization.md is missing or empty"
        echo "   📋 Run with --fix to initialize from plugin template"
        echo "   💡 Or run /clear to trigger SessionStart hook"
        # Continue audit with built-in defaults from context
    fi
fi
```

**B. Initialize `CLAUDE.md`** (if missing):

```bash
if [ ! -f "CLAUDE.md" ]; then
    if [ "$fix_mode" = true ]; then
        project_name=$(basename $(pwd))
        # Create minimal CLAUDE.md with ACF conventions reference
        # Content: project header, ACF definition, conventions reference
        echo "✅ Created CLAUDE.md with ACF conventions reference"
    else
        echo "❌ CLAUDE.md is missing"
        echo "   📋 Run with --fix to create with ACF conventions"
    fi
fi
```

**Fix mode CLAUDE.md template** (write if missing):

```markdown
# {PROJECT_NAME} - AI Assistant Instructions

## Agentic Continuous Flow (ACF)

**ACF is software development for a world where intelligence exists in silicon as well as carbon.** Humans shift from writing code to governing intelligent agent swarms. Knowledge (ontologies, policies, constraints) becomes the product; code is ephemeral output regenerated on demand.

---

## Conventions

- **Organization**: `docs/acf/organization.md` (naming, directory structure, documentation standards)
- **Git**: `docs/acf/git/commit-conventions.md` (conventional commits, atomic commits)
- **Audit**: Run `/audit-acf-conventions` to check compliance, `--fix` to auto-fix
```

**C. Make sure `CLAUDE.md` references the conventions** (it exists but has no reference):

If `CLAUDE.md` exists but never mentions `docs/acf/organization.md`:

```bash
if [ -f "CLAUDE.md" ] && ! grep -q "docs/acf/organization.md" CLAUDE.md; then
    if [ "$fix_mode" = true ]; then
        # Append conventions section to existing CLAUDE.md
        echo "✅ Added conventions reference to CLAUDE.md"
    else
        echo "❌ CLAUDE.md exists but does not reference ACF conventions"
        echo "   📋 Run with --fix to add conventions section"
    fi
fi
```

**Append this block** to existing CLAUDE.md (fix mode only):

```markdown

---

## Conventions

- **Organization**: `docs/acf/organization.md` (naming, directory structure, documentation standards)
- **Git**: `docs/acf/git/commit-conventions.md` (conventional commits, atomic commits)
- **Audit**: Run `/audit-acf-conventions` to check compliance, `--fix` to auto-fix
```

---

#### 1. Read Project Conventions

Read `docs/acf/organization.md` for the conventions you are checking against:

```bash
cat docs/acf/organization.md
```

Check against the project's own version of the file, which may be customized. If Step 0 just created it, the template defaults apply.

---

#### 2. Check Directory Structure

Check that every required directory from the conventions exists:

**Core directories to check**:
```bash
# Check each required directory
for dir in docs docs/acf docs/agents docs/architecture docs/development docs/operations docs/patterns docs/research docs/retrospectives docs/snapshots docs/snapshots/implementation docs/snapshots/mappings docs/snapshots/migrations docs/snapshots/evaluations docs/snapshots/planning; do
  if [ ! -d "$dir" ]; then
    echo "MISSING: $dir"
  fi
done
```

**Report format**:
```
❌ Missing: docs/snapshots/implementation/
   📋 Create with: mkdir -p docs/snapshots/implementation/
```

**Never required**: `docs/cycles/` and `docs/acf/lessons/` belong to acf-whip and exist only in projects that use it. Do not report them as missing and never create them (not here, not in 8A), even though the conventions tree lists them.

---

#### 3. Check Naming Conventions

**Temporal directories** (every file must have a YYYYMMDD prefix):

Scan these directories:
- `docs/research/`
- `docs/retrospectives/`
- `docs/snapshots/implementation/`
- `docs/snapshots/mappings/`
- `docs/snapshots/migrations/`
- `docs/snapshots/evaluations/`
- `docs/snapshots/planning/`

Check that every `.md` file except README.md has the prefix:

```bash
# Example for docs/research/
if [ -d docs/research ]; then
  find docs/research -maxdepth 1 -type f -name "*.md" ! -name "README.md" | while read file; do
    basename "$file" | grep -qE '^[0-9]{8}-' || echo "VIOLATION: $file (missing YYYYMMDD prefix)"
  done
fi
```

**Timeless directories** (file names must not contain a date or version):

Scan these directories:
- `docs/acf/`
- `docs/patterns/`
- `docs/agents/`
- `docs/architecture/`
- `docs/operations/`
- `docs/development/`

Check for embedded dates or version numbers. Run this block verbatim for `docs/acf/` and the same `find` for the other timeless directories. Only its `VIOLATION` lines go into `timeless_violations` for Step 8C:

```bash
# acf-librarian:acf-timeless-check (docs/acf/lessons/ is skipped: lesson-check reports those, never renames)
if [ -d docs/acf ]; then
  find docs/acf -type f -name "*.md" ! -name "README.md" ! -name "CLAUDE.md" ! -path "docs/acf/lessons/*" | sort | while IFS= read -r file; do
    basename "$file" | grep -qE '[0-9]{8}|-v[0-9]+' && echo "VIOLATION: $file (has date or version)"
  done
fi
```

**Lessons** (`docs/acf/lessons/`, written by acf-whip `/retro`): the timeless rule applies, so a slug containing `[0-9]{8}` or `-v[0-9]+` is a violation. The audit still must not rename one. `/retro` updates a lesson by rewriting the file under the same slug, so a renamed lesson comes back under its old name on the next `/retro` and the rule then exists twice. The block above skips `docs/acf/lessons/` for that reason. This block reports, and never fixes, a lesson slug that breaks the timeless rule or does not match `^[a-z][a-z0-9-]*$`. Run it verbatim:

```bash
# acf-librarian:lesson-check (report-only: this block never renames, moves or writes anything)
if [ -d docs/acf/lessons ]; then
  find docs/acf/lessons -type f -name "*.md" ! -name "README.md" | sort | while IFS= read -r file; do
    slug=$(basename "$file" .md); why=""
    printf '%s\n' "$slug" | grep -qE '[0-9]{8}|-v[0-9]+' && why="has a date or version"
    printf '%s\n' "$slug" | grep -qE '^[a-z][a-z0-9-]*$' || why="${why:+$why; }must be lowercase letters, digits and hyphens"
    [ -z "$why" ] || echo "REPORT: $file (lesson slug $why; rename it by hand, the audit never renames a lesson)"
  done
fi
```

**Dated living records** (`docs/cycles/`, report-only): each folder is one acf-whip cycle, named by its cycle ID. The audit never renames, moves or writes anything under `docs/cycles/`, in either mode. It decides ownership by content: a folder whose `record.md` has no acf `Format` stamp belongs to another tool and is skipped. The files inside (`plan.md`, `record.md`, `retro.md`) have no date in their names, on purpose. Run this block verbatim:

```bash
# acf-librarian:cycle-check (report-only: this block never renames, moves or writes anything)
if [ -d docs/cycles ]; then
  find docs/cycles -mindepth 1 -maxdepth 1 -type d | sort | while IFS= read -r d; do
    name=${d##*/}; rec="$d/record.md"
    [ -f "$rec" ] && grep -qE '^- \*\*Format\*\*:[[:space:]]*[0-9]' "$rec" || continue
    id=$(sed -n 's/^- \*\*ID\*\*:[[:space:]]*//p' "$rec" | head -1 | tr -d '[:space:]')
    if ! printf '%s\n' "$name" | grep -qE '^[0-9]{8}-[a-z0-9][a-z0-9-]*$'; then
      echo "REPORT: $d (cycle folder missing YYYYMMDD- prefix; acf-whip ignores it until it is renamed back to its ID ${id:-unknown}; /whip prints the exact git mv)"
    elif [ -n "$id" ] && [ "$id" != "$name" ]; then
      echo "REPORT: $d (folder name differs from its recorded ID $id; acf-whip ignores it until it is renamed back; /whip prints the exact git mv)"
    fi
  done
fi
```

**Report format**:
```
❌ docs/research/ml-evaluation.md (missing YYYYMMDD prefix)
   📋 Rename to: docs/research/20251107-ml-evaluation.md
   💡 Use git log to find creation date: git log --follow --diff-filter=A --format=%ad --date=format:%Y%m%d -- docs/research/ml-evaluation.md

❌ docs/acf/architecture-v2.md (has version number)
   📋 Rename to: docs/acf/architecture.md
   💡 Timeless docs update in place - git tracks history

⚠️ docs/cycles/owner-seat-notice (cycle folder missing YYYYMMDD- prefix)
   📋 Report only: rename it back to its ID by hand (/whip prints the exact git mv)
   💡 A cycle folder's name is its ID; the audit never renames it

⚠️ docs/acf/lessons/api-v2beta.md (lesson slug has a date or version)
   📋 Report only: rename it by hand with git mv
   💡 A lesson's slug is its identity; the audit never renames it
```

---

#### 4. Check Script Organization

Find scripts in the project root:

```bash
# Find shell/python scripts in root (excluding framework files)
find . -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" -o -name "*.bash" \) ! -name "setup.py" ! -name "manage.py" 2>/dev/null | while read file; do
  echo "VIOLATION: $file (script in project root)"
done
```

**Report format**:
```
❌ migrate.sh (script in project root)
   📋 Move to: scripts/migrate.sh
   💡 Command: mkdir -p scripts && mv migrate.sh scripts/
```

---

#### 5. Validate Internal Links

Scan every markdown file under `docs/` for broken internal links. The check skips links inside fenced code blocks and inline code spans (`` `[text](path.md)` ``), which are examples, and it skips external links (`http:`, `https:`, `mailto:`, any `scheme:`) and same-page `#anchors`. A `#section` or `?query` suffix is ignored when looking for the file and kept when fixing the link.

**Report-only sources**: broken links in `docs/cycles/` and `docs/retrospectives/` are reported and never edited, in either mode. An edit to a cycle's `plan.md` changes its content hash and re-arms its approval. Only acf-whip writes `record.md`. A retrospective is a frozen record of what was true when someone wrote it. A doc that is a symlink is report-only too, wherever it points: the edit would land in the file behind the link (possibly a cycle's `plan.md`), and that file's links resolve from its own folder.

**Plugin-installed documents are report-only too**: `docs/acf/organization.md`, `docs/acf/git/commit-conventions.md`, everything under `docs/acf/backlog/` and `docs/acf/style/` (acf-whip), and any doc whose first line is an `acf-librarian-template` or `acf-whip-artifact` marker. Both plugins refresh an unedited copy of these to the current template by comparing its content. One audit edit makes the copy look customised, so it never gets another template fix.

Run this block verbatim. With `fix_mode=false` it only reports; Step 8E runs the same block with `fix_mode=true`:

```bash
# acf-librarian:link-check (fix_mode=true rewrites single-match links outside the report-only sources)
python3 - "${fix_mode:-false}" <<'PY'
import os, re, sys
from pathlib import Path
from urllib.parse import unquote

FIX = sys.argv[1] == "true"
PROTECTED = ("docs/cycles/", "docs/retrospectives/")
# Documents a plugin installs and refreshes by content digest. An audit edit makes a pristine copy
# look customised, so neither plugin would ever correct it again: exact paths for copies made before
# the markers existed, the marker for anything else.
MANAGED = ("docs/acf/organization.md", "docs/acf/git/commit-conventions.md")
MANAGED_DIRS = ("docs/acf/backlog/", "docs/acf/style/")
MARKERS = ("<!-- acf-librarian-template:", "<!-- acf-whip-artifact:")
LINK = re.compile(r'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
FENCE = re.compile(r"^\s*(```|~~~)")
# An inline code span is an example, like a fenced block: the conventions document shows
# `[Organization](docs/acf/organization.md)` as a sample, and resolving that from docs/acf/ "found"
# it broken and rewrote the sample. Spans are blanked to spaces, not removed, so a link matched on
# the blanked line sits at the same offsets in the real one, which is where the rewrite splices.
CODE = re.compile(r"(`+)(?!`).*?(?<!`)\1(?!`)")


def prose(line):
    return CODE.sub(lambda m: " " * len(m.group(0)), line)


def managed(path):
    return path in MANAGED or path.startswith(MANAGED_DIRS)

docs = Path("docs")
if not docs.is_dir():
    print("LINKS: 0 broken, 0 fixed, 0 report-only (no docs/)")
    sys.exit(0)
by_name = {}
for p in sorted(docs.rglob("*")):
    if p.is_file():
        by_name.setdefault(p.name, []).append(p)

broken = fixed = report_only = 0
here = os.path.realpath(".")
for src in sorted(docs.rglob("*.md")):
    rel = src.as_posix()
    # Lock by where a write would LAND, not only by how rglob spells the path: a doc symlinked into
    # a cycle (docs/patterns/current-plan.md -> ../cycles/<ID>/plan.md) is written through the link,
    # changing the approved plan's hash. Every symlinked doc is report-only: the edit lands in
    # another file, whose links resolve from another folder than the fix was computed from.
    real = os.path.relpath(os.path.realpath(src), here).replace(os.sep, "/")
    linked = src.is_symlink()
    try:
        with open(src, encoding="utf-8", newline="") as f:
            text = f.read()
    except Exception as exc:
        print(f"SKIPPED: {rel} ({type(exc).__name__})")
        continue
    owned = managed(rel) or managed(real) or text.startswith(MARKERS)
    locked = rel.startswith(PROTECTED) or real.startswith(PROTECTED) or linked or owned
    why = (f"; {rel} is a symlink to {real}" if linked else
           f"; {rel} is plugin-installed and an edit would stop its template refresh" if owned else "")
    lines = text.split("\n")
    in_fence, seen, rewrites = False, set(), {}
    for line in lines:
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in LINK.finditer(prose(line)):
            raw = m.group(1)
            target = raw[1:-1] if raw.startswith("<") and raw.endswith(">") else raw
            if not target or target.startswith("#") or SCHEME.match(target) or raw in seen:
                continue
            seen.add(raw)
            path = re.split(r"[#?]", target, maxsplit=1)[0]
            if not path or (src.parent / path).exists() or (src.parent / unquote(path)).exists():
                continue
            broken += 1
            print(f"BROKEN: {rel} -> {target}")
            hits = by_name.get(Path(path).name, [])
            if len(hits) != 1:
                print(f"   AMBIGUOUS: {len(hits)} files named {Path(path).name}; fix by hand" if hits
                      else "   NOT FOUND: create the file or remove the link")
                continue
            new = os.path.relpath(hits[0], src.parent).replace(os.sep, "/") + target[len(path):]
            if locked:
                report_only += 1
                print(f"   REPORT-ONLY: fix by hand, never by the audit (possible target: {new}{why})")
            elif FIX:
                rewrites[raw] = f"<{new}>" if raw != target else new
            else:
                print(f"   SUGGESTION: {new}")
    if rewrites and not locked:
        # Line by line with the same fence toggle and code-span blanking as detection: a whole-file
        # substitution would also rewrite an identical link inside a fenced or inline example.
        # Splitting on "\n" keeps any "\r".
        in_fence = False
        for i, line in enumerate(lines):
            if FENCE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for raw, new in rewrites.items():
                pat = re.compile(r"\]\(" + re.escape(raw) + r"(?=[)\s])")
                for m in reversed(list(pat.finditer(prose(line)))):
                    s, e = m.span()
                    # The lookahead may have seen a blanked span; the real line must agree.
                    if re.match(r"[)\s]", line[e:e + 1]):
                        line = line[:s] + "](" + new + line[e:]
            lines[i] = line
        for raw, new in rewrites.items():
            fixed += 1
            print(f"   FIXED: {rel}: {raw} -> {new}")
        with open(src, "w", encoding="utf-8", newline="") as f:
            f.write("\n".join(lines))
print(f"LINKS: {broken} broken, {fixed} fixed, {report_only} report-only")
PY
```

**Report format**:
```
❌ docs/README.md → docs/agents/old-path.md (broken link)
   📋 Possible location: docs/agents/universal/README.md
   💡 Update link to correct path

❌ docs/patterns/quality-gates.md → ../acf/missing.md (file doesn't exist)
   📋 Create the file or remove the link

⚠️ docs/cycles/20260928-owner-seat-notice/plan.md → docs/x/README.md (broken link)
   📋 Report only: fix it by hand (a plan edit re-arms the cycle's approval)
```

---

#### 6. Check Root Directory

Scan the project root for files that do not belong there: markdown other than README.md, CLAUDE.md, LICENSE.md and CONTRIBUTING.md; log and evidence files; temporary files. Scripts are Step 4's job.

```bash
# Find markdown files in root (except allowed)
find . -maxdepth 1 -type f -name "*.md" ! -name "README.md" ! -name "CLAUDE.md" ! -name "LICENSE.md" ! -name "CONTRIBUTING.md" 2>/dev/null | while read file; do
  echo "VIOLATION: $file (documentation in root)"
done

# Find log/evidence files
find . -maxdepth 1 -type f \( -name "*.log" -o -name "*-evidence.txt" \) 2>/dev/null | while read file; do
  echo "VIOLATION: $file (log/evidence in root)"
done

# Find temporary files
find . -maxdepth 1 -type f \( -name "temp*" -o -name "test*" -o -name "scratch*" \) 2>/dev/null | while read file; do
  echo "VIOLATION: $file (temporary file in root)"
done
```

**Report format**:
```
❌ test-output.log (log file in root)
   📋 Move to: logs/test-output.log or delete
   💡 Log files should never be in project root

❌ notes.md (documentation in root)
   📋 Move to: docs/development/notes.md or appropriate location
   💡 Only README.md, CLAUDE.md, LICENSE, CONTRIBUTING.md allowed in root
```

---

#### 7. Check Documentation Verbosity

Scan `docs/` for the token-waste patterns that Section 10 of the conventions (Documentation Writing Standards) rules out. Ignore any finding in `docs/cycles/*/record.md`: acf-whip writes it and nobody edits it.

**Long code examples** (a code block over 10 lines):

```bash
# Find code blocks with excessive length
find docs -type f -name "*.md" -exec awk '
  /^```/ {
    in_code = !in_code
    if (in_code) {
      start_line = NR
      count = 0
    } else if (count > 10) {
      printf "%s (line %d): code block %d lines - compress with ellipsis\n", FILENAME, start_line, count
    }
    next
  }
  in_code { count++ }
' {} \;
```

**Mermaid diagrams** (a linear one may read better as a text flow):

```bash
# Find mermaid diagrams that might be better as text flow
grep -rn "^```mermaid" docs/ 2>/dev/null | while IFS=: read file line rest; do
  echo "VERBOSE: $file (line $line) - mermaid diagram detected"
done
```

**Marketing language** (banned words from Section 10):

```bash
# Scan for banned marketing speak
for word in comprehensive systematic significant substantial robust elegant seamless; do
  grep -rni "\b$word\b" docs/ 2>/dev/null | while IFS=: read file line rest; do
    echo "BANNED WORD: $file (line $line) - '$word' detected"
  done
done
```

**Repeated prohibitions** (five or more `- ❌`/`- ✅` bullets in a row that could be grouped on one line):

```bash
# Find patterns like "- ❌ Item" repeated 5+ times suggesting grouping opportunity
find docs -type f -name "*.md" -exec awk '
  /^- [❌✅]/ {
    count++
    if (count == 1) start_line = NR
  }
  !/^- [❌✅]/ && count >= 5 {
    printf "%s (line %d): %d emoji-prefixed items - consider grouping inline\n", FILENAME, start_line, count
    count = 0
  }
  !/^- [❌✅]/ { count = 0 }
' {} \;
```

**Report format**:
```
📝 Documentation Verbosity Issues:

❌ docs/patterns/example.md (line 45): code block 15 lines - compress with ellipsis
   📋 Compress: Show 1-2 representative lines + "..." for pattern
   💡 Target: 40-70% reduction while preserving pattern understanding

❌ docs/architecture/flow.md (line 120): mermaid diagram detected
   📋 Consider: Convert to text flow if linear: "A → B → C → D"
   💡 Target: 40-60% reduction for simple flows

❌ docs/README.md (line 34): 'comprehensive' detected
   📋 Replace with specific, testable statement
   💡 Example: "Response time < 200ms" NOT "fast response"

❌ docs/patterns/rules.md (line 67): 8 emoji-prefixed items - consider grouping inline
   📋 Group inline: "**FORBIDDEN**: Edit/Write, Bash execution, Tests, Build/lint"
   💡 Target: 20-30% reduction vs bullet list format
```

**Note**: these are suggestions, not violations. Fix mode never changes them.

---

#### 8. Apply Fixes (Only if --fix Flag)

**Run this step only when `fix_mode=true`**:

```bash
if [ "$fix_mode" = false ]; then
    echo "📋 Skipping fixes (audit mode) - use --fix flag to auto-fix"
    # Jump to Step 9: Generate Final Report
else
    echo "🔧 Applying fixes..."
fi
```

### A. Create Missing Directories

For each missing directory from Step 2 (never `docs/cycles/` or `docs/acf/lessons/`: Step 2 never reports them):

```bash
# Array of missing directories collected during audit
for dir in "${missing_dirs[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo "✅ Created: $dir"
    fi
done
```

### B. Fix Temporal Naming Violations

For files in temporal directories that lack the YYYYMMDD prefix. Nothing under `docs/cycles/` is ever in this list: a cycle folder's name is its ID, so Step 3 only reports it.

```bash
# Array of temporal violations from Step 3
for file in "${temporal_violations[@]}"; do
    # Get creation date from git log
    date=$(git log --follow --diff-filter=A --format=%ad --date=format:%Y%m%d -- "$file" 2>/dev/null | head -1)

    if [ -z "$date" ]; then
        # Fallback: use file modification date if git history unavailable
        date=$(date -r "$file" +%Y%m%d 2>/dev/null || date +%Y%m%d)
        echo "⚠️  No git history for $file, using modification date: $date"
    fi

    # Construct new filename with YYYYMMDD prefix
    dir=$(dirname "$file")
    basename=$(basename "$file")
    new_name="${dir}/${date}-${basename}"

    # Check for conflicts
    if [ -f "$new_name" ]; then
        echo "❌ Cannot rename $file → $new_name (file exists)"
        continue
    fi

    # Rename file
    mv "$file" "$new_name"
    echo "✅ Renamed: $file → $new_name"
done
```

### C. Fix Timeless Naming Violations

For files in timeless directories whose names contain a date or version. Nothing under `docs/acf/lessons/` is ever in this list: Step 3 only reports a lesson, because renaming one forks it into two files on the next `/retro`. The `case` below skips one anyway.

```bash
# Array of timeless violations from Step 3
for file in "${timeless_violations[@]}"; do
    case "$file" in
        docs/acf/lessons/*|./docs/acf/lessons/*)
            echo "⚠️  Report only: $file (a lesson's slug is its identity; rename it by hand)"
            continue ;;
    esac
    dir=$(dirname "$file")
    basename=$(basename "$file")

    # Remove YYYYMMDD prefix (8 digits + hyphen at start)
    new_basename=$(echo "$basename" | sed 's/^[0-9]\{8\}-//')

    # Remove version suffixes (-v1, -v2, etc.). -E, because BSD sed reads \+ as a literal plus.
    new_basename=$(echo "$new_basename" | sed -E 's/-v[0-9]+//')

    new_name="${dir}/${new_basename}"

    # Skip if name unchanged
    if [ "$file" = "$new_name" ]; then
        continue
    fi

    # Check for conflicts
    if [ -f "$new_name" ]; then
        echo "❌ Cannot rename $file → $new_name (file exists)"
        continue
    fi

    mv "$file" "$new_name"
    echo "✅ Renamed: $file → $new_name"
done
```

### D. Move Scripts from Root

For scripts found in the project root:

```bash
# Array of root scripts from Step 4
if [ ${#root_scripts[@]} -gt 0 ]; then
    # Create scripts/ directory if missing
    mkdir -p scripts

    for script in "${root_scripts[@]}"; do
        basename=$(basename "$script")
        target="scripts/${basename}"

        # Check for conflicts
        if [ -f "$target" ]; then
            echo "❌ Cannot move $script → $target (file exists)"
            continue
        fi

        mv "$script" "$target"
        echo "✅ Moved: $script → $target"
    done
fi
```

### E. Fix Broken Internal Links

Re-run the Step 5 `acf-librarian:link-check` block with `fix_mode=true` on the line before it, in the same Bash call (shell variables do not survive between calls). It rewrites a broken link only when exactly one file under `docs/` has the target's name, keeps any `#section` suffix, preserves line endings, and prints `FIXED` for each rewrite.

- **Never** edit a link in `docs/cycles/` or `docs/retrospectives/`, in a plugin-installed document (`docs/acf/organization.md`, `docs/acf/git/commit-conventions.md`, `docs/acf/backlog/`, `docs/acf/style/`, or any file with a plugin marker on its first line), or in a doc that is a symlink. That holds for this block and for a hand edit with the Edit tool. The block prints `REPORT-ONLY` for these links, and they go into the final report for a human.
- Links inside fenced code blocks and inline code spans are examples: the block neither reports nor rewrites them, even when the same link appears broken in prose on the same line.
- `AMBIGUOUS` and `NOT FOUND` links are reported, not guessed.

### F. Clean Root Directory

For the root files Step 6 found:

```bash
# Array of root violations from Step 6
for file in "${root_violations[@]}"; do
    basename=$(basename "$file")

    # Determine target location based on file type
    case "$basename" in
        *.log)
            target="logs/${basename}"
            mkdir -p logs
            ;;
        *-evidence.txt|*-output.txt)
            target="logs/${basename}"
            mkdir -p logs
            ;;
        *.md)
            # Documentation files (not README/CLAUDE/LICENSE/CONTRIBUTING)
            target="docs/development/${basename}"
            mkdir -p docs/development
            ;;
        temp*|test*|scratch*)
            # Temporary files - offer to delete
            echo "⚠️  Found temporary file: $file"
            echo "   Delete? [y/N]"
            read response
            if [ "$response" = "y" ]; then
                rm "$file"
                echo "✅ Deleted: $file"
                continue
            else
                echo "⏭️  Skipped: $file"
                continue
            fi
            ;;
        *)
            echo "⚠️  Unknown file type: $file (skipping)"
            continue
            ;;
    esac

    # Check for conflicts
    if [ -f "$target" ]; then
        echo "❌ Cannot move $file → $target (file exists)"
        continue
    fi

    mv "$file" "$target"
    echo "✅ Moved: $file → $target"
done
```

### G. Summary of Fixes Applied

```bash
if [ "$fix_mode" = true ]; then
    echo ""
    echo "🎯 Fix Summary:"
    echo "   Core files initialized: docs/acf/organization.md, CLAUDE.md (if missing)"
    echo "   Directories created: ${#missing_dirs[@]}"
    echo "   Files renamed (temporal): ${#temporal_violations[@]}"
    echo "   Files renamed (timeless): ${#timeless_violations[@]}"
    echo "   Scripts moved: ${#root_scripts[@]}"
    echo "   Links fixed: ${#broken_links[@]} (docs/cycles/, docs/retrospectives/ and plugin-installed docs are report-only)"
    echo "   Root files cleaned: ${#root_violations[@]}"
    echo ""
    echo "📋 Re-running audit to verify fixes..."
    # Optionally re-run audit steps 1-7 to confirm 0 violations
fi
```

---

#### 9. Generate Final Report

**Output format** (varies by mode):

### Audit Mode Output

```
🚨 ACF Convention Audit Report

📚 The librarian has reviewed your project...

---

## Core Files
[violations or ✅ docs/acf/organization.md present, ✅ CLAUDE.md present with conventions reference]

## Directory Structure
[violations or ✅ All required directories present]

## Naming Conventions
[violations or ✅ All files follow temporal/timeless patterns]
[docs/cycles/ and docs/acf/lessons/ reports, marked report-only]

## Script Organization
[violations or ✅ No scripts in forbidden locations]

## Link Validation
[violations or ✅ All internal links resolve correctly]
[docs/cycles/, docs/retrospectives/ and plugin-installed doc links, marked report-only]

## Root Directory
[violations or ✅ Root directory is clean]

## Documentation Verbosity (Optimization Suggestions)
[suggestions or ✅ Documentation follows token efficiency patterns]

---

📊 Summary: X violations found, Y optimization opportunities

[If violations:]
📝 Next Steps:
1. Review each violation above
2. Apply the suggested fixes (or run /audit-acf-conventions --fix)
3. Run /audit-acf-conventions again to verify compliance

📚 Librarian's note: *adjusts glasses sternly* Everything must be in its proper place.

[If no violations:]
✅ Project is fully compliant with ACF conventions!

📚 Librarian's note: *nods approvingly* Excellent organization. You may proceed.
```

### Fix Mode Output

```
🔧 ACF Convention Audit & Fix Report

📚 The librarian has inspected AND fixed your project...

---

## Fixes Applied

### Core Files (Bootstrap)
✅ Initialized docs/acf/organization.md from plugin template
✅ Created CLAUDE.md with ACF conventions reference
   (or: ✅ Added conventions reference to existing CLAUDE.md)

### Directory Structure
✅ Created 3 missing directories:
   - docs/snapshots/implementation/
   - docs/research/
   - docs/retrospectives/

### Naming Conventions
✅ Fixed 5 temporal naming violations:
   - docs/research/ml-evaluation.md → docs/research/20251107-ml-evaluation.md
   - docs/retrospectives/sprint-retro.md → docs/retrospectives/20251107-sprint-retro.md
   ...

✅ Fixed 2 timeless naming violations:
   - docs/acf/architecture-v2.md → docs/acf/architecture.md
   ...

### Script Organization
✅ Moved 2 scripts to scripts/:
   - migrate-db.sh → scripts/migrate-db.sh
   - test.py → scripts/test.py

### Link Validation
✅ Fixed 1 broken link:
   - docs/README.md: Updated docs/agents/research-agent.md → docs/agents/universal/research-agent.md
⚠️ 1 report-only link (fix by hand):
   - docs/cycles/20260928-owner-seat-notice/plan.md → docs/x/README.md

### Root Directory
✅ Cleaned 1 file from root:
   - output.log → logs/output.log

### Documentation Verbosity (Suggestions Only)
📝 3 optimization opportunities (not auto-fixed):
   - docs/patterns/example.md (line 45): code block 15 lines - compress with ellipsis
   ...

---

📊 Fix Summary:
   ✅ Total fixes applied: 14
   ✅ Directories created: 3
   ✅ Files renamed: 7
   ✅ Files moved: 3
   ✅ Links fixed: 1
   📝 Optimization suggestions: 3 (manual review)

🔄 Verification: Re-running audit...

[Re-run Steps 1-7 to confirm]

✅ Verification complete: 0 violations remaining!

📚 Librarian's note: *nods with satisfaction* Much better. Everything is now in its proper place.
```

---

## Usage Notes

### Two Modes of Operation

| | Audit (default) | Fix (`--fix`) |
|---|---|---|
| Writes files | No | Yes: creates, renames and moves files, appends to CLAUDE.md, rewrites links, and deletes a temporary root file only if you answer y. Commit or stash first |
| Report-only findings | Reported | Reported, never changed |
| Verbosity findings | Suggested | Suggested, never changed |
| Afterwards | Fix by hand (or ask Claude), then re-run | Re-runs Steps 1-7 to confirm the fixes |

### Usage Examples

**Audit only**:
```bash
/audit-acf-conventions
```

**Audit and fix**:
```bash
/audit-acf-conventions --fix
```

### Iterative Workflow

**Audit mode**: run `/audit-acf-conventions`, fix what it reports (by hand or by asking Claude), and run it again until it comes back clean.

**Fix mode**: commit or stash your changes, run `/audit-acf-conventions --fix`, review the diff, then commit the fixes.

---

## Librarian Personality

**Tone for violations** (audit mode): Stern but helpful
- "The librarian has CONCERNS about..."
- "*adjusts glasses disapprovingly*"
- "This is a LIBRARY, not a junk drawer!"
- "Everything must be in its proper place, in its leanest form."

**Tone for fixes** (fix mode): Brisk, and pleased when done
- "*rolls up sleeves* Let's organize this mess."
- "*files papers with precision*"
- "*nods with satisfaction* Much better."
- "There. Everything in its proper place."

**Tone for verbosity issues**: Impatient but educational
- "*taps pen at your 50-line code example*"
- "Two lines. Not fifty."
- "Tables over paragraphs. I don't have all day."
- "'Comprehensive' is banned. Be specific."

**Tone for compliance**: Approving but reserved
- "*nods approvingly*"
- "Adequate organization. Lean documentation."
- "You may proceed."

The librarian is strict but fair. She wants every file in its place and every doc lean, and under `--fix` she does the filing herself.

---

## Error Handling

If `docs/acf/organization.md` doesn't exist or is empty:

**Fix mode** (`--fix`):
```
📚 docs/acf/organization.md missing or empty - initializing from plugin template...
✅ Initialized docs/acf/organization.md with default conventions
   (you may customize this file and /clear to reload)
```
The audit creates the file from `${CLAUDE_PLUGIN_ROOT}/content/organization-template.md` and carries on.

**Audit mode** (no `--fix`):
```
❌ CRITICAL: docs/acf/organization.md is missing or empty!

Fix options:
- Run /audit-acf-conventions --fix (creates from plugin template)
- Run /clear (triggers SessionStart hook to create it)
- Enable plugin: /plugin enable acf-librarian, then /clear

Continuing audit with conventions from session context...
```
The audit still runs on the conventions the SessionStart hook injected, and reports the missing file as a violation.

If `CLAUDE.md` doesn't exist:

**Fix mode**: creates a minimal CLAUDE.md with a project header and the conventions reference.
**Audit mode**: reports it as a violation, with the fix.

---

## Examples

### Example: Clean Project

```
🚨 ACF Convention Audit Report

📚 The librarian has reviewed your project...

---

## Directory Structure
✅ All required directories present

## Naming Conventions
✅ All files follow temporal/timeless patterns

## Script Organization
✅ No scripts in forbidden locations

## Link Validation
✅ All internal links resolve correctly

## Root Directory
✅ Root directory is clean

---

📊 Summary: 0 violations found

✅ Project is fully compliant with ACF conventions!

📚 Librarian's note: *nods approvingly* Excellent organization. You may proceed.
```

### Example: Multiple Violations

```
🚨 ACF Convention Audit Report

📚 The librarian has reviewed your project... and she has CONCERNS.

---

## Directory Structure

❌ Missing: docs/snapshots/implementation/
   📋 Create with: mkdir -p docs/snapshots/implementation/

❌ Missing: docs/research/
   📋 Create with: mkdir -p docs/research/

## Naming Conventions

❌ docs/retrospectives/sprint-retro.md (missing YYYYMMDD prefix)
   📋 Rename to: docs/retrospectives/20251107-sprint-retro.md
   💡 Use: git log --follow --diff-filter=A --format=%ad --date=format:%Y%m%d -- docs/retrospectives/sprint-retro.md

❌ docs/acf/architecture-v2.md (has version number)
   📋 Rename to: docs/acf/architecture.md
   💡 Timeless docs update in place - git tracks history

## Script Organization

❌ migrate-db.sh (script in project root)
   📋 Move to: scripts/migrate-db.sh
   💡 Command: mkdir -p scripts && mv migrate-db.sh scripts/

❌ test.py (script in project root)
   📋 Move to: scripts/test.py
   💡 Command: mkdir -p scripts && mv test.py scripts/

## Link Validation

❌ docs/README.md → docs/agents/research-agent.md (broken link)
   📋 Correct path: docs/agents/universal/research-agent.md
   💡 File was moved to universal/ subdirectory

## Root Directory

❌ output.log (log file in root)
   📋 Remove or move to: logs/output.log
   💡 Log files should never be in project root

---

📊 Summary: 8 violations found

📝 Next Steps:
1. Review each violation above
2. Apply the suggested fixes (I can help with this!)
3. Run /audit-acf-conventions again to verify compliance

📚 Librarian's note: *adjusts glasses sternly* This is a LIBRARY, not a junk drawer!
     Everything must be in its proper place. Let's get organized.
```

---

## When to Run It

Nothing runs this audit for you. The plugin's only hook is SessionStart, which installs and injects the conventions, and acf-whip's `/go` does not call the audit. Run it before a commit, or put a clean run on your PR checklist.
