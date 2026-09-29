#!/usr/bin/env python3
"""
ACF Librarian: SessionStart Hook Handler

Initializes, refreshes and injects ACF naming/organization conventions into session context.

Behavior, per convention document (docs/acf/organization.md, docs/acf/git/commit-conventions.md):
- Missing (or a dangling symlink): create it from the plugin template; if that fails, inject the
  template anyway under the pre-1.3.0 "Error initializing" status, plus one line saying why
- An UNEDITED copy of an older template: refresh it to the current template (1.3.0+)
- EDITED or PINNED: never overwrite it; one notice line when the template changed since the copy was based on it
- A pristine copy from a NEWER plugin: load it as is; one notice line to update the plugin
- Inject the project's copy with a STRICT compliance wrapper
"""

import errno
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path


# Documents this plugin installs: (template, destination). Keep in sync with ARTIFACTS in
# skills/lib/gen-digests.sh (tests/template-refresh.test.sh asserts the two agree).
MANAGED = [
    ("content/organization-template.md", "docs/acf/organization.md"),
    ("content/git-commit-conventions-template.md", "docs/acf/git/commit-conventions.md"),
]

# First-line marker written with every install and refresh. It records WHICH template a copy was last
# synced with (by digest, not plugin version: the version moves on releases that never touch a
# template, and a version-keyed marker would nag every customised project on each of them). Its job
# is to keep an edited copy quiet until the template really changes: acf-whip reports an edited
# document on every session forever, which is right for its MANAGED docs but wrong here, because this
# file tells users to customise these two. The hook only ever writes a marker equal to the digest of
# the body below it, so a marker that does NOT match its body is proof a person owns the copy (an
# edit, or a pin), and such a copy is never refreshed. An existing copy is recognised by content (the digest
# manifest), so a copy without the marker is never rewritten just to add it: a session that changes
# nothing must not dirty the user's tree.
MARKER_FMT = "<!-- acf-librarian-template: {src} sha256:{digest} -->"
MARKER_RE = re.compile(r"^<!-- acf-librarian-template: \S+ sha256:([0-9a-f]{12,64}) -->[ \t\r]*$")


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def split_marker(text):
    """(marker digest or None, body). Only a first-line marker counts; the body is what gets hashed
    and injected, so a marked pristine copy compares equal to the unmarked template it came from."""
    first, sep, rest = text.partition("\n")
    m = MARKER_RE.match(first)
    if m and sep:
        return m.group(1), rest
    return None, text


def known_digests(plugin_root):
    """Every template content this plugin has ever shipped, per template path.

    This is what makes the refresh work on the release that introduces it: every existing copy
    predates the marker, and only its content can say it was never edited. An unreadable manifest
    degrades to "every old copy looks edited": reported, never clobbered.
    """
    try:
        with open(plugin_root / "content" / ".digests.json", encoding="utf-8") as f:
            artifacts = json.load(f).get("artifacts", {})
        return {k: set(v) for k, v in artifacts.items() if isinstance(v, list)}
    except Exception:  # noqa: BLE001 - non-blocking by contract
        return {}


def write_atomic(dest, text):
    """Replace dest's content without ever leaving a half-written file.

    A truncated convention document would look EDITED to every later session, so it would never be
    refreshed again, and it would be injected as mandatory rules. Writes go through a symlink to its
    target (a team that links one shared conventions file keeps its link, and a dangling link gets
    its target created, as the pre-1.3.0 open(dest, "w") did), and keep the old mode. The target's
    folder is never created here: the pre-1.3.0 hook failed on a link into a missing folder rather
    than build directories wherever a link pointed, and so does this.
    """
    target = Path(os.path.realpath(str(dest)))
    if target.is_symlink():
        # realpath() hands back a symlink loop unresolved; os.replace() would swap the link itself
        # for a regular file. open(dest, "w") raised ELOOP here, so raise the same.
        raise OSError(errno.ELOOP, "symlink loop", str(dest))
    fd, tmp = tempfile.mkstemp(prefix=".acf-librarian.", dir=str(target.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        try:
            os.chmod(tmp, os.stat(str(target)).st_mode & 0o7777)
        except OSError:
            umask = os.umask(0)
            os.umask(umask)
            os.chmod(tmp, 0o666 & ~umask)   # what a plain open(dest, "w") would have created
        os.replace(tmp, str(target))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def sync(plugin_root, src_rel, dest_rel, known):
    """Install, refresh or read one convention document. Never overwrites an edited copy.

    Returns (outcome, text_to_inject, notice) with outcome one of 'installed' | 'refreshed' |
    'loaded' | 'fallback' (a missing document that could not be created: the plugin template is
    injected, and no project copy exists to claim it was loaded from). Raises InstallError when the
    template itself cannot be read and ReadError when an existing copy cannot be read, so the caller
    keeps the pre-1.3.0 messages for both.
    """
    dest = Path(dest_rel)
    template_path = plugin_root / src_rel

    # exists() follows links, so a DANGLING symlink lands here too, like the pre-1.3.0 hook: a team
    # that links docs/acf/organization.md to a shared file not created yet gets that file created
    # through the link. Excluding links here injected a read error instead, on every session.
    if not dest.exists():
        try:
            template = read_text(template_path)
        except Exception as exc:  # noqa: BLE001
            raise InstallError(exc)
        marked = MARKER_FMT.format(src=src_rel, digest=digest(template)[:12]) + "\n" + template
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)   # the document's own folder, as before
            write_atomic(dest, marked)
        except Exception as exc:  # noqa: BLE001
            # The session still gets the conventions; only the project copy is missing.
            return ("fallback", template,
                    "⚠️ acf-librarian could not create {} ({}); injected the plugin template instead.".format(
                        dest_rel, type(exc).__name__))
        return ("installed", template, None)

    try:
        local = read_text(dest)
    except Exception as exc:  # noqa: BLE001
        raise ReadError(exc)
    marker, body = split_marker(local)

    try:
        template = read_text(template_path)
    except Exception:  # noqa: BLE001 - a broken install cannot compare; behave exactly as before
        return ("loaded", body, None)
    current = digest(template)
    have = digest(body)
    edited = ("⚠️ acf-librarian: {} has local edits, so the updated template was not applied. Merge what "
              "you want from {}, then make its first line {} to silence this.".format(
                  dest_rel, template_path, MARKER_FMT.format(src=src_rel, digest=current[:12])))

    if have == current:
        return ("loaded", body, None)
    if marker and current.startswith(marker):
        # Synced with the current template and changed since: the user's own conventions, nothing new
        # from the plugin. Checked BEFORE the pristine test, so a user who keeps an old template on
        # purpose can pin it by writing the current marker above it.
        return ("loaded", body, None)
    if marker and not have.startswith(marker):
        # Every marker this hook writes equals digest(body), so one that does not describe its body
        # was put there, or kept there, by a person: an edit under an old marker, or a pin (the then
        # current marker written above an old template). Either way the copy is theirs. This MUST
        # come before the pristine test: a pinned body IS a version this plugin shipped, so once the
        # next release moves the template, that test would replace the pin without a word.
        return ("loaded", body, edited)
    if have in known.get(src_rel, ()):
        # Unedited, just old: a version this plugin shipped. The ONLY branch that can act on a
        # project that predates the marker, which is every project on the release that adds it.
        marked = MARKER_FMT.format(src=src_rel, digest=current[:12]) + "\n" + template
        try:
            write_atomic(dest, marked)
        except Exception as exc:  # noqa: BLE001
            return ("loaded", body,
                    "⚠️ acf-librarian could not update {} to the current template ({}); it still holds "
                    "an unedited older version.".format(dest_rel, type(exc).__name__))
        return ("refreshed", template, None)

    if marker:
        # The marker describes its body, yet this plugin never shipped that body: a pristine copy
        # written by a newer (or different) acf-librarian, typically refreshed and committed by a
        # teammate on a later release. The edited notice would tell this user to stamp the OLDER
        # marker over a newer template, a downgrade; the only useful advice is to update the plugin.
        return ("loaded", body,
                "⚠️ acf-librarian: {} was written by a newer acf-librarian than this one; loaded as is. "
                "Update the plugin (/plugin marketplace update, then restart) to stop this notice.".format(
                    dest_rel))

    return ("loaded", body, edited)


class InstallError(Exception):
    pass


class ReadError(Exception):
    pass


def load(plugin_root, src_rel, dest_rel, known, title, what):
    """(conventions, status, notice) for one document, with the pre-1.3.0 wording for every case
    that existed before, so the injected payload only changes when there is news."""
    try:
        outcome, text, notice = sync(plugin_root, src_rel, dest_rel, known)
    except InstallError as e:
        return ("# {}\n\nError loading template: ".format(title) + str(e.args[0]),
                "⚠️ Error initializing {} conventions".format(what), None)
    except ReadError as e:
        return ("# {}\n\nError reading file: ".format(title) + str(e.args[0]),
                "⚠️ Error loading {} conventions".format(what), None)
    except Exception as e:  # noqa: BLE001 - a hook that cannot break a session must not be selective
        return ("# {}\n\nError loading conventions: ".format(title) + str(e),
                "⚠️ Error loading {} conventions".format(what), None)
    if outcome == "installed":
        status = "📚 Initialized {} with default conventions (you may customize this file)".format(dest_rel)
    elif outcome == "refreshed":
        status = "📚 Updated {} to the current plugin template (it was an unedited older copy; see git diff)".format(dest_rel)
    elif outcome == "fallback":
        # The pre-1.3.0 status for a failed create. It then injected an error in place of the rules;
        # the notice below says the template was injected instead, and why the file is missing.
        status = "⚠️ Error initializing {} conventions".format(what)
    else:
        status = "📚 Loaded conventions from {}".format(dest_rel)
    return (text, status, notice)


def main():
    """Main hook handler."""
    # Locate plugin root (3 levels up from this script)
    plugin_root = Path(__file__).parent.parent.parent
    known = known_digests(plugin_root)

    # ========================================
    # 1. Initialize or refresh organization.md
    # ========================================
    org_conventions, org_status, org_notice = load(
        plugin_root, MANAGED[0][0], MANAGED[0][1], known, "ACF Conventions", "organization")

    # ========================================
    # 2. Initialize or refresh git commit conventions
    # ========================================
    git_conventions, git_status, git_notice = load(
        plugin_root, MANAGED[1][0], MANAGED[1][1], known, "Git Conventions", "git")

    notices = "".join("\n" + n for n in (org_notice, git_notice) if n)

    # ========================================
    # 3. Wrap and inject both into context
    # ========================================
    additional_context = f"""# ACF Librarian: STRICT Naming & Organization Enforcement

{org_status}
{git_status}{notices}

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
