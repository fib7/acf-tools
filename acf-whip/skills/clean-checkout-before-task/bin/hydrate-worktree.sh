#!/usr/bin/env bash
# hydrate-worktree.sh — populate a fresh worktree with untracked dev files per .worktreeinclude,
# so specialists can run a full dev sandbox/test env from inside the worktree.
#
# Usage: hydrate-worktree.sh <REPO_ROOT> <WORKTREE_PATH> [<TASK_FILE>]
#
# Manifest: $REPO_ROOT/.worktreeinclude (line-oriented, glob-capable):
#   # comment
#   <path>           default mode: copy
#   copy: <path>     copy (recursive)
#   link: <path>     symlink (DOWNGRADED to copy if the path is secret-sensitive)
#   secret: <path>   copy, then strip group/other perms (0600-ish)
# <path> is relative to REPO_ROOT and may be a glob.
#
# Secret-safety (defense in depth):
#   - allowlist-only: nothing is materialized unless it appears in the manifest.
#   - every entry MUST be git-ignored; a TRACKED path is a hard error (exit 3) — hydration
#     must never risk staging a secret, and tracked files are already in the worktree.
#   - secret-sensitive paths (.env*, *.pem, *.key, id_*, credentials*, *.p12, under .git/)
#     are NEVER symlinked (a symlinked secret edited in a worktree would mutate the real
#     one); link mode is forced to a perms-stripped copy.
#   - hydrated files live under the worktree (itself git-ignored), so they are never committable.
#
# Idempotent: existing targets are skipped. No manifest -> no-op.
# Exit: 0 ok/no-op; 3 manifest names a tracked or non-ignored path.

set -u
REPO_ROOT="${1:?REPO_ROOT required}"
WORKTREE_PATH="${2:?WORKTREE_PATH required}"
TASK_FILE="${3:-}"
MANIFEST="$REPO_ROOT/.worktreeinclude"

[ -f "$MANIFEST" ] || exit 0

# Basename patterns that must never be symlinked (forced to copy).
DENY_BASENAME='^(\.env([.].*)?|.*\.pem|.*\.key|id_[^/]*|credentials.*|.*\.p12)$'

is_denylisted() {
  local rel="$1"
  case "$rel" in
    .git/*|*/.git/*) return 0 ;;
  esac
  basename "$rel" | grep -qE "$DENY_BASENAME"
}

RC=0

hydrate_one() {  # <mode> <relpath>
  local mode="$1" rel="$2"
  local src="$REPO_ROOT/$rel" dst="$WORKTREE_PATH/$rel"

  [ -e "$src" ] || { echo "WARN: hydrate skip (missing source): $rel" >&2; return 0; }

  if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    echo "FATAL: .worktreeinclude names a TRACKED path: $rel (hydration only copies git-ignored files; tracked files are already present)" >&2
    RC=3; return 0
  fi
  if ! git -C "$REPO_ROOT" check-ignore -q -- "$rel"; then
    echo "FATAL: .worktreeinclude names a non-ignored path: $rel (add it to .gitignore or remove it from the manifest)" >&2
    RC=3; return 0
  fi

  [ -e "$dst" ] || [ -L "$dst" ] && { echo "skip (exists): $rel"; return 0; }

  mkdir -p "$(dirname "$dst")"

  if [ "$mode" = "link" ] && is_denylisted "$rel"; then
    echo "WARN: $rel is secret-sensitive; forcing copy instead of symlink" >&2
    mode="secret"
  fi

  case "$mode" in
    link)
      ln -s "$src" "$dst" && echo "hydrated (link): $rel"
      ;;
    secret)
      cp -R "$src" "$dst" && chmod -R go-rwx "$dst" 2>/dev/null
      echo "hydrated (secret-copy): $rel"
      ;;
    copy|*)
      cp -R "$src" "$dst" && echo "hydrated (copy): $rel"
      ;;
  esac
}

while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [ -z "$line" ] && continue

  mode="copy"; pathspec="$line"
  case "$line" in
    link:*)   mode="link";   pathspec="${line#link:}" ;;
    copy:*)   mode="copy";   pathspec="${line#copy:}" ;;
    secret:*) mode="secret"; pathspec="${line#secret:}" ;;
  esac
  pathspec="$(printf '%s' "$pathspec" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

  matched=0
  shopt -s nullglob dotglob
  for abs in "$REPO_ROOT"/$pathspec; do
    matched=1
    rel="${abs#"$REPO_ROOT"/}"
    hydrate_one "$mode" "$rel"
  done
  shopt -u nullglob dotglob
  [ "$matched" = "0" ] && echo "WARN: hydrate pattern matched nothing: $pathspec" >&2
done < "$MANIFEST"

if [ -n "$TASK_FILE" ] && [ -f "$TASK_FILE" ]; then
  TS=$(date -u +"%Y-%m-%d %H:%M:%S")
  printf '| %s | worktree-hydrate | ok | hydrate-worktree | %s |\n' "$TS" "$(basename "$WORKTREE_PATH")" >> "$TASK_FILE"
fi

exit $RC
