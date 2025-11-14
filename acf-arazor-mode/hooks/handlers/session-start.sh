#!/usr/bin/env python3
"""ACF Arazor Mode - SessionStart Hook

Injects cognitive mode instructions from external markdown file.
Content stored in ../content/cognitive-mode.md for maintainability.
"""

import json
import sys
from pathlib import Path

def main():
    # Get plugin root from environment variable
    plugin_root = Path(__file__).parent.parent
    content_file = plugin_root / "content" / "cognitive-mode.md"

    # Read cognitive mode content
    try:
        with open(content_file, 'r', encoding='utf-8') as f:
            # Skip YAML frontmatter if present
            lines = f.readlines()
            start_idx = 0
            if lines and lines[0].strip() == '---':
                # Find end of frontmatter
                for i, line in enumerate(lines[1:], 1):
                    if line.strip() == '---':
                        start_idx = i + 1
                        break

            content = ''.join(lines[start_idx:]).strip()

    except FileNotFoundError:
        print(json.dumps({
            "error": f"Content file not found: {content_file}"
        }), file=sys.stderr)
        sys.exit(1)

    except Exception as e:
        print(json.dumps({
            "error": f"Failed to read content: {str(e)}"
        }), file=sys.stderr)
        sys.exit(1)

    # Output SessionStart hook JSON
    result = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": content
        }
    }

    print(json.dumps(result))
    sys.exit(0)

if __name__ == "__main__":
    main()
