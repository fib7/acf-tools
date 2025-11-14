#!/usr/bin/env python3
"""ACF Mission Control - Status Line Hook

Displays color-coded status line with context usage fuel gauge.

Requirements:
- Python 3.6+ (uses f-strings, pathlib)
- Standard library only (json, sys, os)
"""

import json
import sys
import os

# ANSI color codes
GREEN = '\033[92m'
YELLOW = '\033[93m'
RED = '\033[91m'
RESET = '\033[0m'

# Context limit (78% threshold for auto-compact)
CONTEXT_LIMIT = int(200000 * 0.78)


def get_bar_color(percentage):
    """Return ANSI color code based on context percentage."""
    if percentage < 50:
        return GREEN  # Green zone: 0-50%
    elif percentage < 70:
        return YELLOW  # Caution zone: 50-70%
    else:
        return RED  # Critical zone: 70%+


# Read JSON from stdin
data = json.load(sys.stdin)

# Extract values
model = data["model"]["display_name"]
current_dir = os.path.basename(data["workspace"]["current_dir"])

# Check for git branch
git_branch = ""
if os.path.exists(".git"):
    try:
        with open(".git/HEAD", "r") as f:
            ref = f.read().strip()
            if ref.startswith("ref: refs/heads/"):
                git_branch = f" | ⚡️ {ref.replace('ref: refs/heads/', '')}"
    except Exception:
        pass

transcript_path = data["transcript_path"]

# Parse transcript file to calculate context usage
context_used_token = 0

try:
    with open(transcript_path, "r") as f:
        lines = f.readlines()

        # Iterate from last line to first line
        for line in reversed(lines):
            line = line.strip()
            if not line:
                continue

            try:
                obj = json.loads(line)
                # Check if this line contains required token usage fields
                if (
                    obj.get("type") == "assistant"
                    and "message" in obj
                    and "usage" in obj["message"]
                    and all(
                        key in obj["message"]["usage"]
                        for key in [
                            "input_tokens",
                            "cache_creation_input_tokens",
                            "cache_read_input_tokens",
                            "output_tokens",
                        ]
                    )
                ):
                    usage = obj["message"]["usage"]
                    input_tokens = usage["input_tokens"]
                    cache_creation_input_tokens = usage["cache_creation_input_tokens"]
                    cache_read_input_tokens = usage["cache_read_input_tokens"]
                    output_tokens = usage["output_tokens"]

                    context_used_token = (
                        input_tokens
                        + cache_creation_input_tokens
                        + cache_read_input_tokens
                        + output_tokens
                    )
                    break  # Break after finding first occurrence

            except json.JSONDecodeError:
                # Skip malformed JSON lines
                continue

except FileNotFoundError:
    # If transcript file doesn't exist, keep context_used_token as 0
    pass

context_used_rate = (context_used_token / CONTEXT_LIMIT) * 100

# Create colored progress bar
bar_length = 20
filled_length = int(bar_length * context_used_token // CONTEXT_LIMIT)
bar_color = get_bar_color(context_used_rate)
filled = "█" * filled_length
empty = "░" * (bar_length - filled_length)
bar = f"{bar_color}{filled}{RESET}{empty}"

context_usage = f" | [{bar}] {context_used_rate:.1f}% ({context_used_token:,})"

# Format output (NO brackets around model name)
print(f"{model} | 📁 {current_dir}{git_branch}{context_usage}")
