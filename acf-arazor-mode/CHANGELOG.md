# Changelog — acf-arazor-mode

All notable changes to acf-arazor-mode. Format loosely follows Keep a Changelog.

## 1.0.4 — the SessionStart hook finds its content

- **The mode was never injected.** `hooks/handlers/session-start.sh` computed the plugin root as
  `Path(__file__).parent.parent`, which is `hooks/`, not the plugin root, so it looked for
  `hooks/content/cognitive-mode.md`. That path has never existed, so every SessionStart exited 1
  with `Content file not found` on stderr and added nothing to the session. It has been this way
  since the first release. The root is now three parents up, the same as in acf-challenger-mode and
  acf-nitro, and the hook injects `content/cognitive-mode.md` (frontmatter stripped) and exits 0.
  The comment that said the root came from an environment variable is also corrected: the code
  never read `CLAUDE_PLUGIN_ROOT`.
