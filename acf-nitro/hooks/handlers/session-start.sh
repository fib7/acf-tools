#!/usr/bin/env python3
"""ACF Nitro Mode - SessionStart Hook

Injects parallel execution enforcement instructions from external markdown file.
Content stored in ../content/parallel-enforcement.md for maintainability.
"""

import json
import sys
from pathlib import Path

def main():
    # Get plugin root (3 levels up: handlers -> hooks -> plugin-root)
    plugin_root = Path(__file__).parent.parent.parent
    content_file = plugin_root / "content" / "parallel-enforcement.md"

    # Read parallel enforcement content
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
