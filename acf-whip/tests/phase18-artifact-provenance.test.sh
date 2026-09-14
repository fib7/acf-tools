#!/usr/bin/env bash
# phase18-artifact-provenance.test.sh — the plugin must be able to fix a document it already shipped.
#
# The SessionStart hook copied a handful of plugin-owned documents into a consumer project and never
# looked at them again (`if not target_path.exists()`). So every defect corrected in this repo aged in
# place in someone else's, and was attributed to their own documentation — which is the mechanism
# behind the whole shipped-template defect class, not a separate bug.
#
# The obvious fix does nothing on the release that introduces it: stamp a version, compare, upgrade —
# but every EXISTING copy is unstamped, an unstamped file must never be clobbered, and so the first
# release upgrades nobody. That is the same failure mode as the drift it is meant to end. The test
# that matters is therefore the RETROACTIVE one: a copy that predates stamping entirely.
#
# Run: bash acf-whip/tests/phase18-artifact-provenance.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ACF_WHIP/hooks/handlers/session-start.py"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-prov.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
SRC="$ACF_WHIP/content/backlog/workflow.md"
DEST_REL="docs/acf/backlog/workflow.md"
VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ACF_WHIP/.claude-plugin/plugin.json" | head -1)

run_hook() { ( cd "$1" && echo '{}' | python3 "$HOOK" ); }

# --- 1. fresh install ------------------------------------------------------------------
P1="$WORK/fresh"; mkdir -p "$P1"
OUT=$(run_hook "$P1")
check "fresh project: the document is installed" "[ -f \"$P1/$DEST_REL\" ]"
check "fresh install carries a provenance stamp naming the version" \
  "head -1 \"$P1/$DEST_REL\" | grep -q 'acf-whip-artifact: content/backlog/workflow.md v$VERSION'"
check "the stamp does not disturb the body" \
  "tail -n +2 \"$P1/$DEST_REL\" | diff -q - \"$SRC\" >/dev/null"

# --- 2. idempotence --------------------------------------------------------------------
B1=$(shasum -a 256 < "$P1/$DEST_REL")
run_hook "$P1" >/dev/null
check "running again changes nothing" "[ \"\$(shasum -a 256 < \"$P1/$DEST_REL\")\" = \"$B1\" ]"

# --- 3. THE RETROACTIVE CASE. A copy installed by an older release: unstamped, older content.
# Without a pristine-content manifest this branch is unreachable and the whole mechanism ships inert.
P2="$WORK/legacy"; mkdir -p "$P2/$(dirname "$DEST_REL")"
OLDC=$(git -C "$ACF_WHIP" log --format=%H -- content/backlog/workflow.md | sed -n '3p')
git -C "$ACF_WHIP" show "$OLDC:./content/backlog/workflow.md" > "$P2/$DEST_REL"
check "fixture is genuinely an older version (differs from current)" \
  "! diff -q \"$P2/$DEST_REL\" \"$SRC\" >/dev/null"
check "fixture is genuinely unstamped (as a pre-3.3.0 install would be)" \
  "! head -1 \"$P2/$DEST_REL\" | grep -q 'acf-whip-artifact'"
OUT2=$(run_hook "$P2")
check "an UNEDITED copy from an older release IS refreshed" \
  "tail -n +2 \"$P2/$DEST_REL\" | diff -q - \"$SRC\" >/dev/null"
check "...and the refresh is announced to the session" "printf '%s' \"\$OUT2\" | grep -q 'refreshed'"

# --- 4. an edited copy is NEVER overwritten --------------------------------------------
P3="$WORK/edited"; mkdir -p "$P3/$(dirname "$DEST_REL")"
git -C "$ACF_WHIP" show "$OLDC:./content/backlog/workflow.md" > "$P3/$DEST_REL"
printf '\n<!-- a line this team added themselves -->\n' >> "$P3/$DEST_REL"
BEFORE=$(shasum -a 256 < "$P3/$DEST_REL")
OUT3=$(run_hook "$P3")
check "an EDITED copy is left byte-identical" "[ \"\$(shasum -a 256 < \"$P3/$DEST_REL\")\" = \"$BEFORE\" ]"
check "...and the local edit survives" "grep -q 'a line this team added themselves' \"$P3/$DEST_REL\""
check "...and staleness is REPORTED instead" "printf '%s' \"\$OUT3\" | grep -q 'EDITED'"
check "...naming the file" "printf '%s' \"\$OUT3\" | grep -q '$DEST_REL'"

# --- 5. the hook must never break a session -------------------------------------------
P4="$WORK/hostile"; mkdir -p "$P4/$DEST_REL"   # a DIRECTORY where the file should be
OUT4=$(run_hook "$P4" 2>/dev/null); RC4=$?
check "an unwritable destination does not break the session (exit 0)" "[ $RC4 -eq 0 ]"
check "...and still returns valid hook JSON" "printf '%s' \"\$OUT4\" | python3 -c 'import json,sys; json.load(sys.stdin)'"

# --- 6. the manifest must cover what is shipped now ------------------------------------
# If it does not, a freshly installed file is unrecognisable on the next session and every consumer
# is permanently classed as "edited". This is what forces acfw-gen-digests.sh to be re-run.
MISSING=$(python3 - "$ACF_WHIP" <<'PY'
import hashlib, json, sys, pathlib
root = pathlib.Path(sys.argv[1])
man = json.loads((root / "content" / ".digests.json").read_text())["artifacts"]
missing = []
for rel, digests in man.items():
    d = hashlib.sha256((root / rel).read_text(encoding="utf-8").encode()).hexdigest()
    if d not in digests:
        missing.append(rel)
print(",".join(missing))
PY
)
check "every managed artifact's CURRENT content is in the digest manifest${MISSING:+ — stale: $MISSING (run skills/lib/bin/acfw-gen-digests.sh)}" \
  "[ -z \"$MISSING\" ]"

# The hook's MANAGED list and the generator's ARTIFACTS list must not drift.
HOOK_LIST=$(grep -oE '\("content/[^"]+"' "$HOOK" | tr -d '("' | sort)
GEN_LIST=$(sed -n '/^ARTIFACTS="/,/^"/p' "$ACF_WHIP/skills/lib/bin/acfw-gen-digests.sh" | grep '^content/' | sort)
check "the hook and the digest generator manage the same artifact set" "[ \"\$HOOK_LIST\" = \"\$GEN_LIST\" ]"

echo
echo "phase18-artifact-provenance: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
