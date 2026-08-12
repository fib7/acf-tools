#!/usr/bin/env bash
# phase13-integration-mode.test.sh — verifies the machine pin for the /go integration mode:
#   - resolution precedence: ACFW_INTEGRATION_MODE env > config key > "" (unpinned)
#   - `acfw-store info` carries the pin as "integrationMode", empty when unpinned
#   - an unrecognized value warns on stderr and resolves to "" (unpinned) — a typo must
#     never silently flip delivery semantics in either direction
#   - the SKILL.md legacy-loop extraction snippet parses the field byte-for-byte
# Run: bash acf-whip/tests/phase13-integration-mode.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE="$ACF_WHIP/skills/lib/bin/acfw-store"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p13mode.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk
unset ACFW_STORE ACFW_CONFIG_FILE ACFW_INTEGRATION_MODE 2>/dev/null || true

# ---- unpinned ----
INFO=$(bash "$STORE" info)
check "no pin -> integrationMode is empty" "printf '%s' \"\$INFO\" | grep -q '\"integrationMode\":\"\"'"

# ---- config pin ----
mkdir -p .acfwhip; printf 'ACFW_INTEGRATION_MODE=override\n' > .acfwhip/config
INFO=$(bash "$STORE" info)
check "config pins override" "printf '%s' \"\$INFO\" | grep -q '\"integrationMode\":\"override\"'"

# ---- env beats config ----
INFO=$(ACFW_INTEGRATION_MODE=default bash "$STORE" info)
check "env beats config" "printf '%s' \"\$INFO\" | grep -q '\"integrationMode\":\"default\"'"

# ---- typo resolves to unpinned, with a warning ----
ERR="$WORK/err"; INFO=$(ACFW_INTEGRATION_MODE=oevrride bash "$STORE" info 2>"$ERR")
check "typo resolves to unpinned" "printf '%s' \"\$INFO\" | grep -q '\"integrationMode\":\"\"'"
check "typo warns on stderr" "grep -q 'unrecognized ACFW_INTEGRATION_MODE' \"$ERR\""

# ---- the SKILL.md extraction snippet parses the field ----
GOT=$(bash "$STORE" info | sed -E 's/.*"integrationMode":"([^"]*)".*/\1/')
check "SKILL extraction snippet reads the pin" "[ \"\$GOT\" = override ]"

echo
echo "phase13-integration-mode: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
