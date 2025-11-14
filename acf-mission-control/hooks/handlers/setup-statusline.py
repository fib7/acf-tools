#!/usr/bin/env python3
"""ACF Mission Control - Auto-Setup Hook

Automatically configures Mission Control status line in project settings on first run.

Runs on: SessionStart (startup, resume, clear)
Effect:
1. Creates .claude/scripts/ directory if missing
2. Copies status-line.py from plugin to .claude/scripts/ if not present
3. Makes script executable
4. Adds statusLine configuration to .claude/settings.json pointing to local copy
"""

import json
import sys
import os
import shutil
import stat
from pathlib import Path

# Read hook input
hook_input = json.load(sys.stdin)

# Get project directory from hook input
project_dir = hook_input.get("cwd", ".")
claude_dir = Path(project_dir) / ".claude"
scripts_dir = claude_dir / "scripts"
settings_path = claude_dir / "settings.json"
local_script_path = scripts_dir / "status-line.py"

# Create .claude directory if it doesn't exist
claude_dir.mkdir(exist_ok=True)

# Create .claude/scripts directory if it doesn't exist
scripts_dir.mkdir(exist_ok=True)

# Get plugin root from environment
plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
if not plugin_root:
    # Can't determine plugin location - skip setup
    sys.exit(0)

source_script = Path(plugin_root) / "hooks" / "handlers" / "status-line.py"

# Copy status-line.py from plugin to .claude/scripts/ if not present
if not local_script_path.exists():
    try:
        shutil.copy2(source_script, local_script_path)

        # Make script executable (chmod +x)
        current_permissions = local_script_path.stat().st_mode
        local_script_path.chmod(current_permissions | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    except Exception as e:
        print(f"Failed to copy status line script: {e}", file=sys.stderr)
        sys.exit(1)

# Read existing settings or create new
if settings_path.exists():
    try:
        with open(settings_path, "r") as f:
            settings = json.load(f)
    except json.JSONDecodeError:
        settings = {}
else:
    settings = {}

# Check if statusLine already configured
if "statusLine" in settings:
    # Already configured - nothing to do
    sys.exit(0)

# Add Mission Control status line configuration (pointing to LOCAL copy via relative path)
settings["statusLine"] = {
    "type": "command",
    "command": ".claude/scripts/status-line.py",
    "padding": 0
}

# Write updated settings
try:
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)

    # Output success message (will be added to context via SessionStart hook)
    output = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "🚀 Mission Control activated - Status line script copied to .claude/scripts/, configured in .claude/settings.json"
        }
    }
    print(json.dumps(output))

except Exception as e:
    # Setup failed - report to user via stderr (non-blocking error)
    print(f"Mission Control setup failed: {e}", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
