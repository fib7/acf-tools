#!/usr/bin/env python3
"""ACF Arazor Mode - SessionStart Hook

Injects cognitive mode instructions from external markdown file.
Content stored in ../content/cognitive-mode.md for maintainability.
"""

import json
import sys
from pathlib import Path

def main():
    # Get plugin root (3 levels up: handlers -> hooks -> plugin-root).
    # This file is <root>/hooks/handlers/session-start.sh, so __file__.parent
    # is handlers/ and the root is three parents up, not two. Through 1.0.3 it
    # was two, resolving to <root>/hooks/content/cognitive-mode.md, a path that
    # has never existed: every SessionStart exited 1 with the error on stderr,
    # a non-blocking hook failure, and injected nothing, so arazor mode was
    # installed-but-inert from the first release. Derived from __file__ rather
    # than CLAUDE_PLUGIN_ROOT, which the old comment claimed but never read, to
    # stay identical to challenger and nitro and to keep the handler runnable
    # by hand without the env var.
    plugin_root = Path(__file__).parent.parent.parent
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
