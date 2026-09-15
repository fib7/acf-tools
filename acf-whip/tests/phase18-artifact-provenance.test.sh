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
# "Does not break the session" is NOT exit 0 plus valid JSON: main()'s catch-all satisfies both while
# replacing the entire payload with an errno string. That drops the MANDATORY style-guide injection
# and the store warning — so the assertions have to check the payload SURVIVED, not merely that the
# process did. Both original checks passed green on the broken code, which is how this shipped.
P4="$WORK/hostile"; mkdir -p "$P4/$DEST_REL"   # a DIRECTORY where the file should be
OUT4=$(run_hook "$P4" 2>/dev/null); RC4=$?
check "an unwritable destination does not break the session (exit 0)" "[ $RC4 -eq 0 ]"
check "...and still returns valid hook JSON" "printf '%s' \"\$OUT4\" | python3 -c 'import json,sys; json.load(sys.stdin)'"
check "...and the MANDATORY style guide is still injected" "printf '%s' \"\$OUT4\" | grep -q 'Enforcement Active'"
check "...and the failure is surfaced rather than swallowed" "printf '%s' \"\$OUT4\" | grep -q 'could not sync'"

# The likeliest real trigger is a decode error, not an OSError: these are the documents the refresh
# mechanism invites consumers to EDIT, and one cp1252 smart quote pasted from a word processor is the
# ordinary way a non-UTF-8 byte arrives. An OSError-only guard leaves this case fatal.
P5="$WORK/badbytes"; mkdir -p "$P5/$(dirname "$DEST_REL")"
printf '# Workflow\n\nsmart quote: \223hello\224\n' > "$P5/$DEST_REL"
OUT5=$(run_hook "$P5" 2>/dev/null); RC5=$?
check "a non-UTF-8 byte in an edited document does not break the session" "[ $RC5 -eq 0 ]"
check "...and the style guide still reaches the session" "printf '%s' \"\$OUT5\" | grep -q 'Enforcement Active'"
check "...and the undecodable file is named, not silently skipped" "printf '%s' \"\$OUT5\" | grep -q 'workflow.md'"
check "...and the file itself is left untouched" "grep -q 'smart quote' \"$P5/$DEST_REL\""

# --- 5b. every managed destination, not only the one that is read once -----------------
# P5 above puts its bad bytes in workflow.md — the one managed document main() does NOT read a
# second time, which is why it passed while the defect was live. The style guide IS read twice: it
# is MANAGED[0] and it is also the payload's body, and that second read sat outside the per-artifact
# guard, inside main()'s single try. One bad byte there replaced the ENTIRE additionalContext with
# an errno string — dropping the mandatory style guide, the store warning and the sync notice
# together, on every session, permanently. So every destination gets the fixture, not a chosen one.
DESTS=$(python3 - "$HOOK" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
for m in re.finditer(r'\("content/[^"]+",\s*"([^"]+)"\)', src):
    print(m.group(1))
PY
)
for dest in $DESTS; do
  PB="$WORK/bad-$(printf '%s' "$dest" | tr '/.' '__')"
  mkdir -p "$PB/$(dirname "$dest")"
  printf '# Doc\n\nsmart quote: \223hello\224\n' > "$PB/$dest"
  OUTB=$(run_hook "$PB" 2>/dev/null); RCB=$?
  check "bad bytes in $dest: the session is not broken" "[ $RCB -eq 0 ]"
  check "bad bytes in $dest: the store warning still reaches the session" \
    "printf '%s' \"\$OUTB\" | grep -q 'no acf-whip task store found'"
  check "bad bytes in $dest: task descriptions are still governed" \
    "printf '%s' \"\$OUTB\" | grep -qE 'Enforcement Active|UNGUIDED this session'"
  check "bad bytes in $dest: the edited file is left untouched" \
    "grep -q 'smart quote' \"$PB/$dest\""
done

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
