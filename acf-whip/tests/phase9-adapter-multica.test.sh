#!/usr/bin/env bash
# phase9-adapter-multica.test.sh — live wrapper that runs the store-conformance
# suite against the multica adapter. It SKIPs cleanly (exit 0) unless a throwaway
# multica server is provided, because the adapter talks to a real API — there is
# no offline stub (build one in scratchpad if you need to exercise it without a
# server; see adapters/multica/README.md).
#
# To run against a live server, export ALL of:
#   MULTICA_TEST_SERVER       e.g. https://multica.example.com
#   MULTICA_TEST_TOKEN        a `mul_` PAT with issue read/write in the workspace
#   MULTICA_TEST_WORKSPACE_ID the workspace UUID
# Optional:
#   MULTICA_TEST_PROJECT      scope conformance issues to this project id
#   ACFW_MULTICA_BIN          path to the `multica` CLI (default: `multica` on PATH)
#
# The conformance run creates issues keyed conf-a / conf-b in the workspace; the
# EXIT trap tears them down (status→cancelled and whip_key metadata deleted, so a
# re-run starts clean — multica has no `issue delete`, but a key-less issue is
# invisible to the adapter's resolve/snapshot).

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ACF_WHIP/adapters/multica/acfw-store-multica"

if [ -z "${MULTICA_TEST_SERVER:-}" ] || [ -z "${MULTICA_TEST_TOKEN:-}" ] || [ -z "${MULTICA_TEST_WORKSPACE_ID:-}" ]; then
  echo "SKIP: multica adapter live test needs MULTICA_TEST_SERVER, MULTICA_TEST_TOKEN, and MULTICA_TEST_WORKSPACE_ID"
  exit 0
fi

MULTICA_BIN="${ACFW_MULTICA_BIN:-multica}"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (required by the multica adapter)"; exit 0; }
command -v "$MULTICA_BIN" >/dev/null 2>&1 || { echo "SKIP: multica CLI '$MULTICA_BIN' not found (set ACFW_MULTICA_BIN)"; exit 0; }
[ -x "$ADAPTER" ] || { echo "FATAL: adapter not executable: $ADAPTER" >&2; exit 1; }

# Map the test-scoped vars onto the native CLI env the adapter passes through.
export MULTICA_SERVER_URL="$MULTICA_TEST_SERVER"
export MULTICA_TOKEN="$MULTICA_TEST_TOKEN"
export MULTICA_WORKSPACE_ID="$MULTICA_TEST_WORKSPACE_ID"
[ -n "${MULTICA_TEST_PROJECT:-}" ] && export ACFW_MULTICA_PROJECT="$MULTICA_TEST_PROJECT"

# Teardown: neutralize the conformance issues so re-runs are clean. Deleting the
# whip_key metadata makes each issue invisible to the adapter (there is no CLI
# issue-delete); cancelling is best-effort cosmetic.
cleanup() {
  local k id
  local -a largs
  for k in conf-a conf-b mat-tok; do
    largs=(issue list --metadata "whip_key=$k" --limit 1 --output json)
    [ -n "${ACFW_MULTICA_PROJECT:-}" ] && largs+=(--project "$ACFW_MULTICA_PROJECT")
    id=$(LC_ALL=C "$MULTICA_BIN" "${largs[@]}" 2>/dev/null | jq -r '.issues[0].id // empty')
    [ -n "$id" ] || continue
    LC_ALL=C "$MULTICA_BIN" issue status "$id" cancelled >/dev/null 2>&1 || true
    LC_ALL=C "$MULTICA_BIN" issue metadata delete "$id" --key whip_key >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

echo "== multica adapter conformance (live server: $MULTICA_SERVER_URL) =="
cleanup   # clear any leftovers from a prior aborted run before we start
ADAPTER="$ADAPTER" bash "$ACF_WHIP/tests/phase9-store-conformance.test.sh"; conf_rc=$?

# Targeted: the clean-checkout token must survive `read --materialize`. The frozen
# conformance materializes a token-less task, so it does NOT cover the reviewer's
# auto-reject grep — this does. Create a task, log the token via log-event, then
# grep the refreshed materialized document for it.
echo
echo "== materialize audit-trail token check =="
tok_rc=0
work=$(mktemp -d "${TMPDIR:-/tmp}/acfw-mtok.XXXXXX")
cat > "$work/mat-tok.md" <<'DOC'
# Task: mat-tok

## Metadata

- **ID**: mat-tok
- **Status**: pending
- **Priority**: high
- **Assigned Agent**: test-agent
- **Worktree**: slug-mat-tok
- **PR Group**: slug-mat-tok
- **Touches Globs**: none
- **Dependencies**: none
- **Rejection Count**: 0
- **Block-Count**: 0

## Description

materialize token round-trip spec
DOC
if "$ADAPTER" create --file "$work/mat-tok.md" --folder pending >/dev/null &&
   "$ADAPTER" log-event mat-tok --row '| 2026-07-15 10:00:00 | clean-checkout | ok | clean-checkout-before-task | slug-mat-tok | worktree/slug-mat-tok |' >/dev/null &&
   MAT=$("$ADAPTER" read --materialize "$work" mat-tok) &&
   grep -q '| clean-checkout | ok |' "$MAT"; then
  echo "  PASS: materialized document exposes the clean-checkout token"
else
  echo "  FAIL: clean-checkout token missing from materialized document"
  tok_rc=1
fi
rm -rf "$work"

[ "$conf_rc" -eq 0 ] && [ "$tok_rc" -eq 0 ]
