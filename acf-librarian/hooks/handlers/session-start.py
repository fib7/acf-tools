#!/usr/bin/env python3
"""
ACF Librarian: SessionStart Hook Handler

Initializes and injects ACF naming/organization conventions into session context.

Behavior:
- If docs/acf/organization.md doesn't exist: Create from template
- If docs/acf/organization.md exists: Read current version (may be user-customized)
- Inject conventions into session with STRICT compliance wrapper
"""

import json
import sys
import os
from pathlib import Path


def main():
    """Main hook handler."""
    # Locate plugin root (3 levels up from this script)
    plugin_root = Path(__file__).parent.parent.parent

    # ========================================
    # 1. Initialize organization.md
    # ========================================
    org_template_file = plugin_root / "content" / "organization-template.md"
    org_target_file = Path("docs/acf/organization.md")

    # Initialize or read organization conventions
    if not org_target_file.exists():
        # INITIALIZE: Create from template
        org_target_file.parent.mkdir(parents=True, exist_ok=True)

        try:
            with open(org_template_file, 'r', encoding='utf-8') as f:
                org_template_content = f.read()

            with open(org_target_file, 'w', encoding='utf-8') as f:
                f.write(org_template_content)

            org_conventions = org_template_content
            org_status = "📚 Initialized docs/acf/organization.md with default conventions (you may customize this file)"
        except Exception as e:
            # If template read fails, provide minimal conventions
            org_conventions = "# ACF Conventions\n\nError loading template: " + str(e)
            org_status = "⚠️ Error initializing organization conventions"
    else:
        # READ: Load existing conventions (may be user-customized)
        try:
            with open(org_target_file, 'r', encoding='utf-8') as f:
                org_conventions = f.read()
            org_status = "📚 Loaded conventions from docs/acf/organization.md"
        except Exception as e:
            org_conventions = "# ACF Conventions\n\nError reading file: " + str(e)
            org_status = "⚠️ Error loading organization conventions"

    # ========================================
    # 2. Initialize git commit conventions
    # ========================================
    git_template_file = plugin_root / "content" / "git-commit-conventions-template.md"
    git_target_file = Path("docs/acf/git/commit-conventions.md")

    # Initialize or read git conventions
    if not git_target_file.exists():
        # INITIALIZE: Create from template
        git_target_file.parent.mkdir(parents=True, exist_ok=True)

        try:
            with open(git_template_file, 'r', encoding='utf-8') as f:
                git_template_content = f.read()

            with open(git_target_file, 'w', encoding='utf-8') as f:
                f.write(git_template_content)

            git_conventions = git_template_content
            git_status = "📚 Initialized docs/acf/git/commit-conventions.md with default conventions (you may customize this file)"
        except Exception as e:
            # If template read fails, provide minimal conventions
            git_conventions = "# Git Conventions\n\nError loading template: " + str(e)
            git_status = "⚠️ Error initializing git conventions"
    else:
        # READ: Load existing conventions (may be user-customized)
        try:
            with open(git_target_file, 'r', encoding='utf-8') as f:
                git_conventions = f.read()
            git_status = "📚 Loaded conventions from docs/acf/git/commit-conventions.md"
        except Exception as e:
            git_conventions = "# Git Conventions\n\nError reading file: " + str(e)
            git_status = "⚠️ Error loading git conventions"

    # ========================================
    # 3. Wrap and inject both into context
    # ========================================
    additional_context = f"""# ACF Librarian: STRICT Naming & Organization Enforcement

{org_status}
{git_status}

---

## ⚠️ CRITICAL INSTRUCTION: MANDATORY COMPLIANCE

You MUST STRICTLY follow the naming, organization, and git conventions defined in the documents below.

**These are NOT suggestions. These are ABSOLUTE REQUIREMENTS.**

### When creating, moving, or organizing ANY files or directories:

1. **Consult the conventions below FIRST** - Before any file operation
2. **Apply them EXACTLY** - No approximations, no "close enough"
3. **Do NOT deviate** - Unless user explicitly overrides with clear instruction

### Enforcement Rules:

- ✅ All file naming MUST follow temporal/timeless patterns
- ✅ All directory organization MUST match specified structure
- ✅ All scripts MUST be in designated locations (NEVER project root)
- ✅ All documentation MUST be in docs/ hierarchy
- ✅ All git commits MUST follow conventional commit format
- ✅ All file staging MUST be explicit (NEVER git add -A or git add .)
- ❌ Violations MUST be prevented or corrected immediately

### Documentation Writing Requirements (🚨 CRITICAL):

When creating or modifying ANY documentation:

1. **Minimize code snippets** - Follow Code Snippet Policy in Section 10 below (2-3 lines max, NO function implementations, NO algorithm pseudocode, NO config file contents)
2. **Compress examples** - Use ellipsis "..." for repetitive patterns (show 1-2 lines, target 40-70% reduction)
3. **Use tables** - Convert all comparisons/options/specs from prose to tables (target 50-70% reduction)
4. **Inline lists** - Use compact format for simple enumerations: "**Tools**: Read, Write, Edit" (target 30-40% reduction)
5. **Group prohibitions** - List inline, comma-separated: "**FORBIDDEN**: Edit/Write, Bash execution, Tests" (target 20-30% reduction)
6. **Ban marketing speak** - NO "comprehensive", "robust", "seamless", "elegant" (be specific: "Response time < 200ms")
7. **Preserve critical content** - 100% retention of ALL instructions, examples, emphasis (CAPS, !, emojis), validation requirements

**Token efficiency target**: 40-70% reduction vs verbose baseline while preserving 100% of information.

**See Section 10 in conventions below for complete documentation writing standards.**

**The librarian is watching. Everything in its place, in its leanest form. No exceptions.**

---

# Project Organization Conventions

{org_conventions}

---

# Git Commit Conventions

{git_conventions}

---

## Compliance Verification

To check current project compliance, the user can run:
- `/audit-acf-conventions` - Scan project and report all violations
- `/commit` - Stage and commit changes following git conventions

To customize conventions, the user can edit:
- `docs/acf/organization.md` - Organization and naming conventions
- `docs/acf/git/commit-conventions.md` - Git commit conventions
- Then `/clear` to reload session
"""

    # Output SessionStart hook JSON
    result = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": additional_context
        }
    }

    print(json.dumps(result))
    sys.exit(0)


if __name__ == "__main__":
    main()
