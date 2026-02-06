---
name: audit-acf-conventions
description: Check project compliance with ACF naming and organization conventions. Use --fix flag to automatically fix all violations.
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

**📚 The librarian inspects your project for convention violations.**

Scan the current project for violations of ACF naming and organization conventions defined in `docs/acf/organization.md`.

**Modes**:
- **Audit mode** (default): Report violations with actionable fix suggestions
- **Fix mode** (`--fix` flag): Automatically fix all identified violations

**Note**: The conventions are already in your context (injected by ACF Librarian SessionStart hook).

---

## Pre-Execution Check

**BEFORE RUNNING**, verify:
- ✅ You have the ACF conventions in your context (from SessionStart hook)
- ✅ You're in a project root directory (not inside subdirectories)
- ✅ `docs/acf/organization.md` exists (should be auto-created by plugin)

**If `docs/acf/organization.md` is missing or empty**:
- **Fix mode** (`--fix`): Initialize it from the plugin template at `${CLAUDE_PLUGIN_ROOT}/content/organization-template.md` and continue
- **Audit mode**: Report as a critical violation and continue checking other categories

---

## Command

Audit the project for convention compliance and report all violations with actionable fixes.

### Argument Parsing

**Check for --fix flag** (passed via command arguments):

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

**Safety Check** (if fix mode):
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

**Before any audit checks**, ensure core ACF files exist. This allows fix mode to bootstrap a project from scratch.

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

**C. Ensure `CLAUDE.md` references conventions** (if exists but missing reference):

If `CLAUDE.md` exists but does NOT contain a reference to `docs/acf/organization.md`:

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

Read `docs/acf/organization.md` to confirm the conventions you'll be checking against:

```bash
cat docs/acf/organization.md
```

This ensures you're checking against the project's actual conventions (which may be customized). If the file was just initialized in Step 0, the default template conventions apply.

---

#### 2. Check Directory Structure

Scan for required directories as defined in the conventions:

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

---

#### 3. Check Naming Conventions

**Temporal directories** (files MUST have YYYYMMDD prefix):

Scan these directories:
- `docs/research/`
- `docs/retrospectives/`
- `docs/snapshots/implementation/`
- `docs/snapshots/mappings/`
- `docs/snapshots/migrations/`
- `docs/snapshots/evaluations/`
- `docs/snapshots/planning/`

Check each `.md` file (except README.md) has YYYYMMDD prefix:

```bash
# Example for docs/research/
if [ -d docs/research ]; then
  find docs/research -maxdepth 1 -type f -name "*.md" ! -name "README.md" | while read file; do
    basename "$file" | grep -qE '^[0-9]{8}-' || echo "VIOLATION: $file (missing YYYYMMDD prefix)"
  done
fi
```

**Timeless directories** (files must NOT have dates/versions):

Scan these directories:
- `docs/acf/`
- `docs/patterns/`
- `docs/agents/`
- `docs/architecture/`
- `docs/operations/`
- `docs/development/`

Check for embedded dates or version numbers:

```bash
# Example for docs/acf/
if [ -d docs/acf ]; then
  find docs/acf -type f -name "*.md" ! -name "README.md" ! -name "CLAUDE.md" | while read file; do
    basename "$file" | grep -qE '[0-9]{8}|-v[0-9]+' && echo "VIOLATION: $file (has date or version)"
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
```

---

#### 4. Check Script Organization

Find scripts in forbidden locations (primarily project root):

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

Scan all markdown files for broken internal links:

**Logic**:
1. Find all `.md` files in `docs/`
2. Extract internal links (relative paths, not http/https)
3. For each link, resolve from source file location
4. Check if target exists

**Implementation approach**:
```python
# Pseudocode (implement with Read and Bash tools)
import re
from pathlib import Path

for md_file in Path("docs").rglob("*.md"):
    content = read_file(md_file)

    # Extract markdown links: [text](path)
    links = re.findall(r'\[([^\]]+)\]\(([^)]+)\)', content)

    for link_text, link_path in links:
        # Skip external links
        if link_path.startswith(('http://', 'https://', '#')):
            continue

        # Resolve relative path from source file
        source_dir = md_file.parent
        target = (source_dir / link_path).resolve()

        if not target.exists():
            print(f"BROKEN: {md_file} → {link_path}")
            # Try to find the target file
            filename = Path(link_path).name
            matches = list(Path("docs").rglob(filename))
            if matches:
                print(f"  SUGGESTION: File may have moved to {matches[0]}")
```

**Report format**:
```
❌ docs/README.md → docs/agents/old-path.md (broken link)
   📋 Possible location: docs/agents/universal/README.md
   💡 Update link to correct path

❌ docs/patterns/quality-gates.md → ../acf/missing.md (file doesn't exist)
   📋 Create the file or remove the link
```

---

#### 6. Check Root Directory

Scan project root for forbidden files:

**Forbidden patterns**:
- Documentation files (except allowed ones)
- Log files
- Evidence files
- Temporary files
- Scripts (already checked above)

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

Scan documentation for token waste patterns that violate Section 10 (Documentation Writing Standards):

**Verbose code examples** (>10 lines in code blocks):

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

**Mermaid diagrams** (candidates for text flow conversion):

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

**Repeated prohibitions** (emoji per line instead of grouped):

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

**Note**: These are optimization suggestions, not violations. They help reduce token usage while preserving information.

---

#### 8. Apply Fixes (Only if --fix Flag)

**Execute this step ONLY if `fix_mode=true`**:

```bash
if [ "$fix_mode" = false ]; then
    echo "📋 Skipping fixes (audit mode) - use --fix flag to auto-fix"
    # Jump to Step 9: Generate Final Report
else
    echo "🔧 Applying fixes..."
fi
```

### A. Create Missing Directories

For each missing directory from Step 2:

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

For files in temporal directories missing YYYYMMDD prefix:

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

For files in timeless directories with dates or versions:

```bash
# Array of timeless violations from Step 3
for file in "${timeless_violations[@]}"; do
    dir=$(dirname "$file")
    basename=$(basename "$file")

    # Remove YYYYMMDD prefix (8 digits + hyphen at start)
    new_basename=$(echo "$basename" | sed 's/^[0-9]\{8\}-//')

    # Remove version suffixes (-v1, -v2, etc.)
    new_basename=$(echo "$new_basename" | sed 's/-v[0-9]\+//')

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

For scripts found in project root:

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

For broken markdown links found in Step 5:

```python
# Use Edit tool to fix broken links
# For each broken link:
#   1. Find the actual location of target file
#   2. Calculate correct relative path
#   3. Update link in source markdown

for broken_link in broken_links:
    source_file = broken_link['source']
    old_path = broken_link['link_path']
    target_filename = os.path.basename(old_path)

    # Search for target file in docs/
    matches = glob(f"docs/**/{target_filename}", recursive=True)

    if len(matches) == 1:
        # Found single match - calculate relative path
        source_dir = os.path.dirname(source_file)
        target_path = matches[0]
        rel_path = os.path.relpath(target_path, source_dir)

        # Read source markdown
        content = read_file(source_file)

        # Replace old path with new path
        updated_content = content.replace(f"]({old_path})", f"]({rel_path})")

        # Write back using Edit tool
        edit_file(source_file, content, updated_content)

        print(f"✅ Fixed link in {source_file}: {old_path} → {rel_path}")
    elif len(matches) > 1:
        print(f"⚠️  Multiple matches for {target_filename}, skipping (manual review needed)")
    else:
        print(f"❌ Target not found for {old_path}, skipping")
```

**Implementation note**: Use Edit tool for markdown link updates to preserve file content.

### F. Clean Root Directory

For forbidden files in root directory:

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
    echo "   Links fixed: ${#broken_links[@]}"
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

## Script Organization
[violations or ✅ No scripts in forbidden locations]

## Link Validation
[violations or ✅ All internal links resolve correctly]

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

**Audit Mode** (default - read-only):
- ✅ Scans and reports violations
- ✅ Provides actionable fix suggestions
- ❌ Does NOT modify files
- User or Claude must manually fix violations

**Fix Mode** (`--fix` flag):
- ✅ Scans for violations
- ✅ Automatically fixes all identified issues
- ✅ Verifies fixes by re-running audit
- ⚠️  Modifies files (recommends git commit/stash first)

### Usage Examples

**Audit only**:
```bash
/audit-acf-conventions
```

**Audit and auto-fix**:
```bash
/audit-acf-conventions --fix
```

### Iterative Workflow

**Manual workflow** (audit mode):
1. Run `/audit-acf-conventions`
2. Fix reported violations (manually or ask Claude to fix)
3. Run `/audit-acf-conventions` again
4. Repeat until clean

**Automated workflow** (fix mode):
1. Commit or stash uncommitted changes (recommended)
2. Run `/audit-acf-conventions --fix`
3. Review changes
4. Commit fixes

### Leveraging Context

The conventions are already in your session context from the SessionStart hook. Use them to:
- Understand what to check
- Know the correct format for each category
- Provide context-aware suggestions

---

## Librarian Personality

**Tone for violations** (audit mode): Stern but helpful
- "The librarian has CONCERNS about..."
- "*adjusts glasses disapprovingly*"
- "This is a LIBRARY, not a junk drawer!"
- "Everything must be in its proper place, in its leanest form."

**Tone for fixes** (fix mode): Efficient and satisfaction-expressing
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

**Remember**: The librarian is strict but fair. She wants order AND efficiency, and with `--fix` mode, she'll help you achieve both directly.

---

## Error Handling

If `docs/acf/organization.md` doesn't exist or is empty:

**Fix mode** (`--fix`):
```
📚 docs/acf/organization.md missing or empty - initializing from plugin template...
✅ Initialized docs/acf/organization.md with default conventions
   (you may customize this file and /clear to reload)
```
The audit creates the file from `${CLAUDE_PLUGIN_ROOT}/content/organization-template.md` and continues normally.

**Audit mode** (no `--fix`):
```
❌ CRITICAL: docs/acf/organization.md is missing or empty!

Fix options:
- Run /audit-acf-conventions --fix (creates from plugin template)
- Run /clear (triggers SessionStart hook to create it)
- Enable plugin: /plugin enable acf-librarian, then /clear

Continuing audit with conventions from session context...
```
The audit still runs using conventions already injected by the SessionStart hook, but reports the missing file as a violation.

If `CLAUDE.md` doesn't exist:

**Fix mode**: Creates minimal CLAUDE.md with project header and ACF conventions reference.
**Audit mode**: Reports as violation with fix suggestion.

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

## Integration with ACF Workflow

This command integrates with ACF quality gates:
- Run before commits (pre-commit hook potential)
- Include in PR checklist
- Use as documentation quality gate
- Part of `/go` workflow verification

The librarian ensures your project stays organized throughout development.
