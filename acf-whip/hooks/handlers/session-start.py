#!/usr/bin/env python3
"""
ACF Whip SessionStart Hook
Ensures task description style guide, task template, and workflow docs are initialized.
"""
import hashlib
import json
import sys
from pathlib import Path


# Documents this plugin owns and installs into a consumer project. Keep in sync with the ARTIFACTS
# list in skills/lib/bin/acfw-gen-digests.sh (tests/phase18-artifact-provenance.test.mjs asserts it).
MANAGED = [
    ("content/style/task-descriptions.md", "docs/acf/style/task-descriptions.md"),
    ("content/backlog/task-template.md", "docs/acf/backlog/task-template.md"),
    ("content/backlog/workflow.md", "docs/acf/backlog/workflow.md"),
]

STAMP_PREFIX = "<!-- acf-whip-artifact: "


def plugin_version(plugin_root: Path) -> str:
    """Version from the plugin manifest; '0.0.0' if it cannot be read."""
    try:
        with open(plugin_root / ".claude-plugin" / "plugin.json", encoding="utf-8") as f:
            return str(json.load(f).get("version", "0.0.0"))
    except Exception:
        return "0.0.0"


def strip_stamp(text: str) -> str:
    """Drop a leading provenance stamp so content compares equal across versions.

    The stamp is added at install time, so a stamped local file and the unstamped plugin source must
    hash the same or every managed file would look edited the moment we started stamping.
    """
    if text.startswith(STAMP_PREFIX):
        nl = text.find("\n")
        if nl != -1:
            return text[nl + 1:].lstrip("\n")
    return text


def digest(text: str) -> str:
    return hashlib.sha256(strip_stamp(text).encode("utf-8")).hexdigest()


def known_digests(plugin_root: Path):
    """Every content this plugin has ever shipped, per managed source path.

    This is what makes the mechanism work on the release that introduces it. A stamp-only design
    upgrades nobody the first time: every existing copy predates stamping, an unstamped file must
    never be clobbered, and so the fix reaches no one — the same failure as the drift it addresses.
    Recognising a pristine file by CONTENT sidesteps that entirely.
    """
    try:
        with open(plugin_root / "content" / ".digests.json", encoding="utf-8") as f:
            return json.load(f).get("artifacts", {})
    except Exception:
        return {}


def sync_artifact(plugin_root: Path, src_rel: str, dest_rel: str, version: str, known):
    """Install, refresh, or report one managed artifact. Never overwrites an edited file.

    Returns one of: 'installed' | 'refreshed' | 'current' | ('stale-edited', local_version).
    """
    src = plugin_root / src_rel
    dest = Path(dest_rel)
    try:
        source_text = src.read_text(encoding="utf-8")
    except OSError:
        return None

    stamped = "{}{} v{} -->\n".format(STAMP_PREFIX, src_rel, version) + source_text

    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(stamped, encoding="utf-8")
        return "installed"

    local_text = dest.read_text(encoding="utf-8")
    if digest(local_text) == digest(source_text):
        # Same content. Add the stamp if this copy predates stamping, so later sessions are cheap.
        if not local_text.startswith(STAMP_PREFIX):
            dest.write_text(stamped, encoding="utf-8")
        return "current"

    if digest(local_text) in known.get(src_rel, []):
        # Unedited, just old: a version we shipped. Safe to replace — and this is the ONLY branch
        # that can act on a project that predates stamping.
        dest.write_text(stamped, encoding="utf-8")
        return "refreshed"

    # Edited locally. Never clobber someone's own document; say it is behind and let them decide.
    head = local_text.split("\n", 1)[0]
    local_v = head.split(" v")[-1].replace(" -->", "") if head.startswith(STAMP_PREFIX) else "unstamped"
    return ("stale-edited", local_v)


def main() -> None:
    """Main entry point for SessionStart hook."""
    try:
        plugin_root = Path(__file__).parent.parent.parent

        # 1-3. Keep the plugin-owned documents in sync. These used to be copied once and never looked
        # at again, so a defect corrected here aged in place in every consumer project and was
        # attributed to their own documentation. Refresh what is unedited; never touch what is not.
        version = plugin_version(plugin_root)
        known = known_digests(plugin_root)
        refreshed, stale, unreadable = [], [], []
        for src_rel, dest_rel in MANAGED:
            # Guard EACH artifact, not the loop. Before 3.3.0 this hook short-circuited on
            # `target_path.exists()` and never touched a destination; it now reads and writes every
            # managed document on every session, which introduces failure modes the old code could not
            # have. The likeliest is a decode error, not an OSError: these are exactly the documents
            # the refresh mechanism invites consumers to edit, and one cp1252 smart quote pasted from
            # a word processor raises UnicodeDecodeError. Without a per-artifact guard that propagates
            # to main()'s catch-all, which replaces the WHOLE payload with an errno string — dropping
            # the mandatory style-guide injection, the store warning, and every later document's sync,
            # on every session, permanently. Broad `except Exception` on purpose: a hook that cannot
            # break a session must not be selective about what it survives.
            try:
                outcome = sync_artifact(plugin_root, src_rel, dest_rel, version, known)
            except Exception as exc:  # noqa: BLE001 - non-blocking by contract
                unreadable.append((dest_rel, type(exc).__name__))
                continue
            if outcome == "refreshed":
                refreshed.append(dest_rel)
            elif isinstance(outcome, tuple):
                stale.append((dest_rel, outcome[1]))

        artifact_notice = ""
        if refreshed:
            artifact_notice += (
                "\n\n📄 acf-whip refreshed {} unmodified document(s) to v{}: {}.\n".format(
                    len(refreshed), version, ", ".join(refreshed))
            )
        if unreadable:
            artifact_notice += (
                "\n\n⚠️ acf-whip could not sync {} document(s) and skipped them: {}.\nCheck the file "
                "encoding (UTF-8) and permissions; everything else in this session is unaffected.\n".format(
                    len(unreadable), ", ".join("{} ({})".format(d, e) for d, e in unreadable))
            )
        if stale:
            artifact_notice += (
                "\n\n⚠️ acf-whip documents below the installed plugin version (v{}) that you have "
                "EDITED, so they were left alone: {}.\nThey may contradict the current runtime — "
                "compare against the plugin's copy under content/ and merge what you want.\n".format(
                    version, ", ".join("{} ({})".format(d, v) for d, v in stale))
            )

        # 4. Warn if no task store is initialized. The store is pluggable (3.1.0): the default
        # files backend lives at .backlog/; any other backend is declared by an ACFW_STORE= key
        # in .acfwhip/config (or the legacy .backlog/.acfw-config). Either signal counts as
        # initialized — the warning fires only when NEITHER exists.
        backlog_warning = ""
        store_backend = ""
        for cfg in (Path(".acfwhip/config"), Path(".backlog/.acfw-config")):
            if cfg.exists():
                try:
                    for line in cfg.read_text(encoding="utf-8").splitlines():
                        stripped = line.strip()
                        if stripped.startswith("ACFW_STORE="):
                            store_backend = stripped.split("=", 1)[1].strip().strip("\"'")
                except Exception:
                    pass
                break
        if Path(".backlog").exists() or store_backend:
            if store_backend and store_backend != "files":
                backlog_warning = f"\n\nℹ️ acf-whip task store backend: `{store_backend}` (configured via ACFW_STORE).\n"
        else:
            backlog_warning = "\n\n⚠️ **WARNING**: no acf-whip task store found (no `.backlog/` directory and no `ACFW_STORE` config). Run `/whip-init` to initialize the backlog workflow, install agents, and configure quality gates.\n"

        # 5. Build context with style guide for immediate injection
        style_guide_path = Path("docs/acf/style/task-descriptions.md")
        if style_guide_path.exists():
            with open(style_guide_path, 'r', encoding='utf-8') as f:
                style_guide = f.read()

            additional_context = f"""# ACF Task Description Style Guide (Enforcement Active)

The following style guide is MANDATORY for all task descriptions. task-engineer and /task command MUST enforce these rules.

{style_guide}

**Enforcement**: Every task description will be validated against these rules. Violations result in immediate rejection.
{backlog_warning}{artifact_notice}"""
        else:
            additional_context = f"# ACF Whip Initialized\n\nRun /whip-init to set up backlog workflow.{backlog_warning}{artifact_notice}"

        # 6. Output SessionStart hook JSON
        result = {
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": additional_context
            }
        }

        print(json.dumps(result))
        sys.exit(0)

    except Exception as e:
        # Fail gracefully - don't break the session
        error_result = {
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": f"# ACF Whip Hook Error\n\nSessionStart hook encountered an error: {str(e)}\n\nYou can still use the plugin, but initialization may be incomplete."
            }
        }
        print(json.dumps(error_result))
        sys.exit(0)


if __name__ == "__main__":
    main()
