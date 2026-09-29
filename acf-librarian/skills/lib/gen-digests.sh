#!/usr/bin/env bash
# gen-digests.sh - regenerate content/.digests.json, the pristine-template manifest.
#
# WHY THIS EXISTS. The SessionStart hook copies two templates into a consumer project
# (docs/acf/organization.md, docs/acf/git/commit-conventions.md) and, before 1.3.0, never touched
# them again: every convention fixed here aged in place in every existing project, and the session
# kept injecting the stale copy as MANDATORY rules. Stamping a version on install cannot fix that on
# the release that introduces it: every existing copy is unstamped, an unstamped file must never be
# clobbered, and so the first release would upgrade nobody.
#
# The way out (ported from acf-whip's acfw-gen-digests.sh) is to recognise a pristine copy by its
# CONTENT. Every version of a template this plugin has shipped is in git history; a consumer copy that
# hashes to one of them is unedited-and-stale and safe to replace. One that hashes to none was edited
# and is never overwritten, only reported.
#
# What goes in, per template:
#   - every version in this branch's history, and the working copy (the content about to ship);
#   - every digest the manifest COMMITTED AT HEAD already records. This repository's history has been
#     rewritten before; a rewrite that drops a template version would otherwise turn every pristine
#     copy of it into an "edited" one on the next regeneration, silently and forever. So a digest
#     that has been committed here never leaves the manifest; prune one only by hand, in a commit;
#   - every --seed, this run's and those the manifest records under "seeded".
# What does NOT: a digest only the working-tree manifest holds. That is a draft, recorded by an
# earlier run between two edits of an uncommitted template. Unioning the working-tree file (as this
# script first did) made every draft permanent, so the manifest claimed as "shipped" content that
# never left a developer's editor. Re-running after each template edit is therefore safe: the draft
# from the previous run drops out. A failed `git show` (the commit that deleted a path, a pruned
# object) is skipped rather than hashed: sha256("") would make an EMPTY consumer file look pristine.
#
# Outside a git checkout nothing can tell a draft from a committed digest, so every recorded digest
# is kept (with a WARN).
#
# Run from anywhere, at RELEASE time, after the last template edit (re-running is harmless):
#   bash skills/lib/gen-digests.sh                        # rewrite content/.digests.json
#   bash skills/lib/gen-digests.sh --out <file>           # write elsewhere (tests diff it)
#   bash skills/lib/gen-digests.sh --seed <artifact> <file>
#       record a version shipped before this repository's history began (pre-extraction builds).
#
# tests/template-refresh.test.sh fails when the manifest is missing the CURRENT template content,
# holds a digest nothing justifies, or differs from what this script would produce.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # plugin root

# The templates this plugin installs into consumer projects, as plugin-root-relative paths. Keep in
# sync with MANAGED in hooks/handlers/session-start.py (the test asserts the two agree).
ARTIFACTS="
content/organization-template.md
content/git-commit-conventions-template.md
"

MANIFEST="content/.digests.json"
OUT=""
SEEDS=""   # newline-separated "artifact<TAB>abs-file" pairs (bash 3.2: no arrays of pairs needed)
TAB=$(printf '\t')

die() { echo "gen-digests: $*" >&2; exit 2; }
is_artifact() { case "$ARTIFACTS" in *"
$1
"*) return 0 ;; esac; return 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || die "--out needs a path"; OUT=$2; shift 2 ;;
    --seed)
      [ $# -ge 3 ] || die "--seed needs <artifact> <file>"
      is_artifact "$2" || die "--seed: '$2' is not a managed artifact"
      [ -f "$3" ] || die "--seed: no such file: $3"
      # An empty seed would record sha256(""), the digest that makes an empty consumer file pristine.
      [ -s "$3" ] || die "--seed: empty file: $3"
      SEEDS="$SEEDS$2$TAB$(cd "$(dirname "$3")" && pwd)/$(basename "$3")
"
      shift 3 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Resolve --out against the caller's CWD before moving to the plugin root.
if [ -n "$OUT" ]; then
  case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac
fi
cd "$HERE" || exit 1
[ -n "$OUT" ] || OUT="$HERE/$MANIFEST"

if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 | cut -d' ' -f1; }
else die "need sha256sum or shasum"; fi

HAVE_GIT=0
git rev-parse --git-dir >/dev/null 2>&1 && HAVE_GIT=1
[ "$HAVE_GIT" -eq 1 ] || echo "gen-digests: WARN not a git checkout; keeping every recorded digest, drafts included" >&2

# A manifest flattened to one line, so this script's one-line arrays and a jq-pretty-printed file
# parse alike. Refuse one without an "artifacts" object: the committed digests are the only thing
# standing between a history rewrite and every consumer's pristine copy being misclassified as edited.
flat() { tr '\n' ' '; }
need_artifacts() {
  case "$1" in *'"artifacts"'*) ;; *) die "$2 has no \"artifacts\" object; fix or remove it by hand" ;; esac
}
CUR=""
if [ -f "$MANIFEST" ]; then
  CUR=$(flat < "$MANIFEST"); need_artifacts "$CUR" "$MANIFEST"
fi
BASE=""
if [ "$HAVE_GIT" -eq 1 ]; then
  # "./" resolves the path from the CWD (the plugin root), not from the repository root.
  if git cat-file -e "HEAD:./$MANIFEST" 2>/dev/null; then
    BASE=$(git show "HEAD:./$MANIFEST" | flat); need_artifacts "$BASE" "$MANIFEST at HEAD"
  fi
else
  BASE=$CUR
fi

# Digests one flattened manifest records for one artifact, under "artifacts". The key is matched
# with its closing quote, so a "seeded" entry ("<artifact>:<digest>") can never be mistaken for it.
digests_in() {
  [ -n "$1" ] || return 0
  _re=$(printf '%s' "$2" | sed 's/[.[\/*^$]/\\&/g')
  printf '%s' "$1" | sed -n "s/.*\"$_re\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" |
    grep -oE '[0-9a-f]{64}'
}
# Seeds a flattened manifest records for one artifact: "seeded" entries "<artifact>:<digest>".
seeded_in() {
  [ -n "$1" ] || return 0
  # An ERE escape, not digests_in's sed one: GNU grep 3.8+ warns on the "\/" that sed's delimiter needs.
  _ere=$(printf '%s' "$2" | sed 's/[].[*^$+?(){}|\\]/\\&/g')
  printf '%s' "$1" | grep -oE "\"$_ere:[0-9a-f]{64}\"" | grep -oE '[0-9a-f]{64}'
}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/gen-digests.XXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT
: > "$TMPD/seeded"

{
  printf '{\n'
  printf '  "_comment": "sha256 of every version of each acf-librarian template ever shipped. A consumer copy matching one is unedited, so the SessionStart hook may refresh it; one matching none was edited and is never overwritten. Regenerate with skills/lib/gen-digests.sh: a digest committed here is never dropped, a --seed is kept under seeded, and an uncommitted draft is.",\n'
  printf '  "artifacts": {\n'
  first=1
  for f in $ARTIFACTS; do
    [ -f "$f" ] || die "managed artifact missing: $f"
    list="$TMPD/list"
    : > "$list"
    sha < "$f" >> "$list"                        # the content about to ship, committed or not
    digests_in "$BASE" "$f" >> "$list"
    {
      seeded_in "$BASE" "$f"
      seeded_in "$CUR" "$f"
      printf '%s' "$SEEDS" | while IFS="$TAB" read -r a file; do
        [ "$a" = "$f" ] && sha < "$file"
      done
    } | grep -E '^[0-9a-f]{64}$' | LC_ALL=C sort -u | sed "s|^|$f:|" >> "$TMPD/seeded"
    grep -F "$f:" "$TMPD/seeded" | sed 's/.*://' >> "$list"
    if [ "$HAVE_GIT" -eq 1 ]; then
      # --full-history: default simplification follows a merge's TREESAME parent and never walks the
      # other one, so a version that reached this branch only through a merge that kept this side's
      # file (how the fork users also install from is synced: `merge -s ours`) would never be listed.
      # Not --all: other refs (topic branches, refs/stash) hold content that never shipped, and would
      # make the manifest depend on whichever clone ran this.
      for c in $(git log --full-history --format=%H -- "$f" 2>/dev/null); do
        git show "$c:./$f" > "$TMPD/blob" 2>/dev/null || continue
        sha < "$TMPD/blob" >> "$list"
      done
    fi
    [ "$first" -eq 1 ] && first=0 || printf ',\n'
    printf '    "%s": [' "$f"
    grep -E '^[0-9a-f]{64}$' "$list" | LC_ALL=C sort -u | awk 'NR > 1 { printf ", " } { printf "\"%s\"", $0 }'
    printf ']'
  done
  printf '\n  },\n'
  printf '  "seeded": ['
  LC_ALL=C sort -u "$TMPD/seeded" | awk 'NR > 1 { printf ", " } { printf "\"%s\"", $0 }'
  printf ']\n}\n'
} > "$TMPD/out" || exit 1

# Same-directory temp + rename, so an interrupted run never leaves a half-written manifest behind.
mkdir -p "$(dirname "$OUT")" && cp "$TMPD/out" "$OUT.tmp.$$" && mv "$OUT.tmp.$$" "$OUT" ||
  { rm -f "$OUT.tmp.$$"; die "cannot write $OUT"; }
n=$(sed -n '/"artifacts"/,/^  }/p' "$OUT" | grep -oE '"[0-9a-f]{64}"' | wc -l | tr -d ' ')
echo "wrote $OUT ($n digests)"
