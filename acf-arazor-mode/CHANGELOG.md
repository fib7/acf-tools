# Changelog: acf-arazor-mode

All notable changes to acf-arazor-mode. Format loosely follows Keep a Changelog.

## 1.0.5: open source under Apache-2.0

- **Relicensed under the Apache License 2.0.** acf-arazor-mode was proprietary and view-only; you
  can now use, modify and redistribute it under Apache-2.0. `LICENSE` holds the full text and
  `plugin.json` declares `Apache-2.0`. No behavior changes.

## 1.0.4: the SessionStart hook finds its content

- **The mode was never injected.** `hooks/handlers/session-start.sh` computed the plugin root as
  `Path(__file__).parent.parent`, which is `hooks/`, not the plugin root, so it looked for
  `hooks/content/cognitive-mode.md`. That path has never existed. Every SessionStart exited 1 with
  `Content file not found` on stderr and added nothing to the session. The hook had failed this way
  since the first release. The root is now three parents up, as in acf-challenger-mode and acf-nitro, and the
  hook injects `content/cognitive-mode.md` (frontmatter stripped) and exits 0. The handler's comment
  no longer claims the root comes from an environment variable: the code never read
  `CLAUDE_PLUGIN_ROOT`.
