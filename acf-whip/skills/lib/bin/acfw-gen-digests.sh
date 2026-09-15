#!/usr/bin/env bash
# acfw-gen-digests.sh — regenerate content/.digests.json, the pristine-content manifest.
#
# WHY THIS EXISTS. The SessionStart hook copies a handful of plugin-owned documents into a consumer
# project and, until now, never touched them again — so every template defect aged in place in
# someone else's repository and got attributed to their own documentation. The obvious fix (stamp a
# version on install, compare, upgrade) does nothing on the release that introduces it: every existing
# copy is UNSTAMPED, an unstamped file must never be clobbered, and so the first release upgrades
# nobody. That is the same failure mode as the fix it is meant to complete.
#
# The way out is to recognise a pristine file by its CONTENT rather than by a stamp it predates. Every
# version of a managed artifact this plugin has ever shipped is in git history; if a consumer's local
# copy hashes to any of them, it is unedited-and-stale and safe to replace. If it hashes to none, they
# changed it, and it must never be overwritten — only reported.
#
# Run from the plugin root, at RELEASE time, whenever a managed artifact changes:
#   bash skills/lib/bin/acfw-gen-digests.sh
#
# tests/phase18-artifact-provenance.test.mjs fails if the CURRENT content of a managed artifact is
# missing from the manifest, which is what forces this to be re-run.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # plugin root
cd "$HERE" || exit 1

# The artifacts this plugin owns and installs into consumer projects. Keep in sync with
# hooks/handlers/session-start.py MANAGED (phase18 asserts the two agree).
ARTIFACTS="
content/style/task-descriptions.md
content/backlog/task-template.md
content/backlog/workflow.md
content/backlog/recovery-runbook.md
"

sha() { shasum -a 256 | cut -d' ' -f1; }

OUT="content/.digests.json"
{
  printf '{\n'
  printf '  "_comment": "sha256 of every version of each managed artifact this plugin has shipped. A consumer copy matching any of these is unedited-and-stale, so it is safe to refresh; one matching none was edited by hand and is never overwritten. Regenerate with skills/lib/bin/acfw-gen-digests.sh.",\n'
  printf '  "artifacts": {\n'
  first_a=1
  for f in $ARTIFACTS; do
    [ -f "$f" ] || { echo "WARN: managed artifact missing: $f" >&2; continue; }
    [ "$first_a" -eq 1 ] && first_a=0 || printf ',\n'
    printf '    "%s": [' "$f"
    # Every distinct historical content, newest first, plus the working-tree content (which may not
    # be committed yet at release time — the point is that the file we are about to ship is known).
    { printf '%s\n' "$(sha < "$f")"
      for c in $(git log --format=%H -- "$f" 2>/dev/null); do
        # "./" makes git resolve the path relative to CWD; a bare path is resolved from the REPO
        # root, which is one level up from the plugin root and silently yields nothing.
        git show "$c:./$f" 2>/dev/null | sha
      done
    } | awk 'NF && !seen[$0]++' | {
      first_d=1
      while IFS= read -r d; do
        [ "$first_d" -eq 1 ] && first_d=0 || printf ', '
        printf '"%s"' "$d"
      done
    }
    printf ']'
  done
  printf '\n  }\n}\n'
} > "$OUT"

command -v jq >/dev/null 2>&1 && { jq . "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"; }
echo "wrote $OUT ($(grep -c '"' "$OUT") lines of digests)"
