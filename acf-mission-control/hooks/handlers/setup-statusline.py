#!/usr/bin/env python3
"""ACF Mission Control - Self-Upgrading Installer

Runs on every SessionStart. Keeps the repo-local
`.claude/scripts/status-line.py` in sync with the version shipped by the plugin:

1. Creates `.claude/scripts/` if missing.
2. Compares the `# mission-control-version:` marker in the plugin source vs the
   local copy (semver tuple compare).
   - No local copy            -> install.
   - plugin version > local   -> back up local to `status-line.py.bak`, overwrite.
   - plugin version <= local  -> leave the local copy alone (no downgrade).
3. Ensures `.claude/settings.json` points statusLine at the local copy and, when
   the cache-warmth segment is in play, injects `refreshInterval` so the
   indicator stays live while the session is idle.
4. Refreshes the cached LiteLLM model rate table when it is older than a day,
   detached, so the status line can price models Claude Code has no rates for.

Non-blocking: any failure exits 0 so a bad upgrade never breaks the session.
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

REFRESH_INTERVAL = 30  # seconds; keeps the cache-warmth indicator current when idle
PRICE_TTL = 86400      # seconds; matches CONFIG["price_ttl"] in status-line.py


def parse_version(text):
    """Extract '# mission-control-version: X.Y.Z' as an int tuple.

    Missing/garbled marker -> (0, 0, 0) so it counts as 'ancient' (upgradeable).
    """
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("# mission-control-version:"):
            raw = line.split(":", 1)[1].strip()
            parts = raw.split(".")
            out = []
            for part in parts[:3]:
                try:
                    out.append(int(part))
                except ValueError:
                    out.append(0)
            while len(out) < 3:
                out.append(0)
            return tuple(out)
    return (0, 0, 0)


def read_text(path):
    try:
        return path.read_text()
    except OSError:
        return ""


def price_cache_age():
    """Seconds since the LiteLLM price map was cached, or None when absent."""
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(
        os.path.expanduser("~"), ".cache"
    )
    cache = Path(base) / "acf-mission-control" / "prices.json"
    try:
        return time.time() - cache.stat().st_mtime
    except OSError:
        return None


def refresh_price_map(script_path):
    """Refresh the model rate table in the background when it has gone stale.

    Detached on purpose: session start never waits on the network, and the status
    line keeps rendering off the previous cache while this runs.
    """
    age = price_cache_age()
    if age is not None and age <= PRICE_TTL:
        return
    try:
        subprocess.Popen(
            [sys.executable or "python3", str(script_path), "--refresh-prices"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception:  # noqa: BLE001 - non-blocking
        pass


def main():
    try:
        hook_input = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        hook_input = {}

    project_dir = hook_input.get("cwd", ".")
    claude_dir = Path(project_dir) / ".claude"
    scripts_dir = claude_dir / "scripts"
    settings_path = claude_dir / "settings.json"
    local_script = scripts_dir / "status-line.py"
    backup_script = scripts_dir / "status-line.py.bak"

    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if not plugin_root:
        sys.exit(0)
    source_script = Path(plugin_root) / "hooks" / "handlers" / "status-line.py"

    try:
        scripts_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        sys.exit(0)

    source_text = read_text(source_script)
    if not source_text:
        sys.exit(0)
    src_version = parse_version(source_text)

    action = None  # "installed" | (old, new) upgrade tuple | None

    if not local_script.exists():
        action = "installed"
    else:
        local_version = parse_version(read_text(local_script))
        if src_version > local_version:
            action = (local_version, src_version)

    if action is not None:
        try:
            if action != "installed":
                # Preserve the prior (possibly customized) copy before overwriting.
                shutil.copy2(local_script, backup_script)
            shutil.copy2(source_script, local_script)
            mode = local_script.stat().st_mode
            local_script.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        except Exception as exc:  # noqa: BLE001 - non-blocking
            print("Mission Control upgrade failed: {}".format(exc), file=sys.stderr)
            sys.exit(0)

    refresh_price_map(local_script)

    # ---- settings.json: ensure statusLine + refreshInterval ----------------
    settings = {}
    if settings_path.exists():
        try:
            with open(settings_path) as fh:
                settings = json.load(fh)
        except (OSError, json.JSONDecodeError):
            settings = {}

    sl = settings.get("statusLine")
    settings_changed = False
    if not isinstance(sl, dict):
        sl = {
            "type": "command",
            "command": ".claude/scripts/status-line.py",
            "padding": 0,
            "refreshInterval": REFRESH_INTERVAL,
        }
        settings["statusLine"] = sl
        settings_changed = True
    else:
        # Add refreshInterval if absent; never clobber a user's custom value.
        if "refreshInterval" not in sl:
            sl["refreshInterval"] = REFRESH_INTERVAL
            settings_changed = True

    if settings_changed:
        try:
            with open(settings_path, "w") as fh:
                json.dump(settings, fh, indent=2)
        except OSError as exc:
            print("Mission Control settings write failed: {}".format(exc), file=sys.stderr)
            sys.exit(0)

    # ---- report ------------------------------------------------------------
    msg = None
    if action == "installed":
        msg = "🚀 Mission Control activated — status line installed to .claude/scripts/"
    elif isinstance(action, tuple):
        old, new = action
        msg = (
            "🚀 Mission Control upgraded v{}→v{} "
            "(previous saved to status-line.py.bak)".format(
                ".".join(map(str, old)), ".".join(map(str, new))
            )
        )

    if msg:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": msg,
            }
        }))

    sys.exit(0)


if __name__ == "__main__":
    main()
