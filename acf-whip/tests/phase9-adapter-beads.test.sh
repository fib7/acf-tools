#!/usr/bin/env bash
# phase9-adapter-beads.test.sh — exercise the beads (`bd`) store adapter.
#
# Skip-guarded: when no capable `bd` is available and none can be built from the
# beads checkout, this exits 0 with a SKIP: line so CI-less machines don't fail.
# Otherwise it runs the frozen store-conformance spec against the beads adapter,
# then a handful of beads-SPECIFIC assertions (custom-status config, native bd
# status of an accepted task, a native dependency edge, whip_* metadata) that the
# backend-agnostic conformance test can't express.
#
# A "capable" bd = one that supports `--backend=dolt` init + `config set
# status.custom` + `bd create --status`. The last of those landed post-v1.1.0 and
# is NOT in any released bd, so a beads checkout on main is currently required.
# We probe rather than trust the version string. Set ACFW_BEADS_SRC to a beads
# checkout to enable the build; without it the test skips.
#
# The build MUST be cgo-enabled: the embedded Dolt engine sits behind a `cgo`
# build tag, so a CGO_ENABLED=0 bd cannot open the database at all.

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ACF_WHIP/adapters/beads/acfw-store-beads"
[ -x "$ADAPTER" ] || { echo "FATAL: beads adapter not executable: $ADAPTER" >&2; exit 1; }

BEADS_SRC="${ACFW_BEADS_SRC:-}"
BD_CACHE_DIR="${TMPDIR:-/tmp}/acfw-bd-test"

# bd_ok <bin> — true iff <bin> supports the dolt backend + custom statuses +
# `create --status`. Probing init costs an embedded-Dolt engine boot, so callers
# should not call this in a loop.
bd_ok() {
  local bin="$1" d rc
  command -v "$bin" >/dev/null 2>&1 || return 1
  d="$(mktemp -d "${TMPDIR:-/tmp}/acfw-bdok.XXXXXX")" || return 1
  (
    cd "$d" || exit 1
    git init -q . >/dev/null 2>&1
    git config user.email t@t >/dev/null 2>&1; git config user.name t >/dev/null 2>&1
    "$bin" init --backend=dolt --prefix probe -q --non-interactive --skip-hooks --skip-agents >/dev/null 2>&1 || exit 1
    "$bin" config set status.custom "in_review:wip" >/dev/null 2>&1 || exit 1
    # `bd create --status` is post-v1.1.0 and unreleased; the adapter requires it.
    "$bin" create --id probe-1 "probe" --status in_review -q >/dev/null 2>&1 || exit 1
  )
  rc=$?
  rm -rf "$d"
  return $rc
}

# ensure_bd — put a capable bd on PATH (cached build → fresh build → PATH), or fail.
ensure_bd() {
  if [ -x "$BD_CACHE_DIR/bd" ] && bd_ok "$BD_CACHE_DIR/bd"; then
    PATH="$BD_CACHE_DIR:$PATH"; export PATH; return 0
  fi
  if [ -d "$BEADS_SRC" ] && command -v go >/dev/null 2>&1; then
    mkdir -p "$BD_CACHE_DIR"
    echo "phase9-adapter-beads: building bd from $BEADS_SRC (CGO_ENABLED=1, -tags gms_pure_go)…" >&2
    if ( cd "$BEADS_SRC" && CGO_ENABLED=1 go build -tags gms_pure_go -o "$BD_CACHE_DIR/bd" ./cmd/bd ) >/dev/null 2>&1 \
       && bd_ok "$BD_CACHE_DIR/bd"; then
      PATH="$BD_CACHE_DIR:$PATH"; export PATH; return 0
    fi
    echo "phase9-adapter-beads: build from $BEADS_SRC failed or produced an incapable bd." >&2
  fi
  bd_ok "bd" && return 0
  return 1
}

if ! ensure_bd; then
  echo "SKIP: phase9-adapter-beads — no capable 'bd' on PATH and none could be built from '${BEADS_SRC:-<unset>}'."
  echo "      (need a cgo-enabled bd with --backend=dolt + custom statuses + 'create --status';"
  echo "       'create --status' is post-v1.1.0 and unreleased, so set ACFW_BEADS_SRC to a beads"
  echo "       checkout on main to enable the build.)"
  exit 0
fi
echo "phase9-adapter-beads: using bd = $(command -v bd) ($(bd version 2>/dev/null | head -1))"

# ---- 1. the frozen conformance spec ----------------------------------------
echo
echo "== store conformance against the beads adapter =="
ADAPTER="$ADAPTER" bash "$ACF_WHIP/tests/phase9-store-conformance.test.sh"
CONF_RC=$?

# ---- 2. beads-specific assertions ------------------------------------------
echo
echo "== beads-specific checks =="
PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfw-p9beads.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
mkdir -p "$REPO/.claude/agents"; echo "# test-agent" > "$REPO/.claude/agents/test-agent.md"
echo seed > "$REPO/seed"; git -C "$REPO" add -A; git -C "$REPO" commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk
export ACFW_STORE_CONFIG="" ACFW_CONTRACT_VERSION=1 ACFW_PLUGIN_LIB="$ACF_WHIP/skills/lib"

bdq(){ ( cd "$REPO" && bd "$@" ); }              # bd against this repo's .beads
mkdoc(){ # <stem> <worktree> <deps>
  cat <<EOF
# Task: Beads $1

## Metadata

- **ID**: $1
- **Status**: pending
- **Priority**: high
- **Assigned Agent**: test-agent
- **Worktree**: $2
- **PR Group**: $2
- **Touches Globs**: none
- **Dependencies**: $3
- **Rejection Count**: 0
- **Block-Count**: 0

## Description

Beads-specific probe for $1.
EOF
}

"$ADAPTER" init >/dev/null

# ---- storage engine + init side effects ------------------------------------
# The engine must be embedded Dolt, not sqlite: --backend=sqlite is rejected by
# every released bd, which is what made this adapter unusable before.
BKND="$(jq -r '.backend // "dolt"' "$REPO/.beads/metadata.json" 2>/dev/null)"
if [ "$BKND" = "dolt" ]; then ok "storage backend is dolt"; else bad "backend = '$BKND' (want dolt)"; fi
if find "$REPO/.beads" -name '*.db' 2>/dev/null | grep -q .; then bad "a sqlite *.db was created under .beads/"; else ok "no sqlite *.db under .beads/"; fi

# --skip-hooks is load-bearing: core.hooksPath lives in .git/config, which every
# git worktree shares, so bd hooks would fire on every whip commit and contend
# for the same single-writer Dolt lock.
HP="$(git -C "$REPO" config --get core.hooksPath 2>/dev/null || true)"
if [ -z "$HP" ]; then ok "init left core.hooksPath unset (--skip-hooks honored)"; else bad "core.hooksPath = '$HP' (bd installed its hooks)"; fi
if [ -e "$REPO/.beads/hooks" ]; then bad ".beads/hooks/ was installed"; else ok "no .beads/hooks/ installed"; fi

# --skip-agents keeps bd from writing agent instructions into the host repo.
if [ -e "$REPO/AGENTS.md" ] || [ -e "$REPO/CLAUDE.md" ] || [ -e "$REPO/.claude/settings.json" ]; then
  bad "init wrote agent instruction files into the repo"
else ok "init wrote no AGENTS.md/CLAUDE.md/.claude settings (--skip-agents honored)"; fi

# bd init ends in a bare `git commit` with no pathspec, so it would sweep a dirty
# index into its own commit. The adapter must refuse instead (contract code 8).
# This needs a FRESH repo: the guard is scoped to the branch that actually runs
# `bd init`, so on an already-initialized store init is a legitimate no-op.
FRESH="$WORK/fresh"; git init -q -b trunk "$FRESH"
git -C "$FRESH" config user.email t@t; git -C "$FRESH" config user.name t
echo seed > "$FRESH/seed"; git -C "$FRESH" add -A; git -C "$FRESH" commit -qm seed
echo staged > "$FRESH/staged.txt"; git -C "$FRESH" add staged.txt
BEFORE="$(git -C "$FRESH" rev-parse HEAD)"
RC8=0; ( cd "$FRESH" && ACFW_TRUNK_ROOT="$FRESH" "$ADAPTER" init >/dev/null 2>&1 ) || RC8=$?
AFTER="$(git -C "$FRESH" rev-parse HEAD)"
if [ "$RC8" -eq 8 ] && [ "$BEFORE" = "$AFTER" ] && [ ! -d "$FRESH/.beads" ]; then
  ok "init refuses a dirty index with exit 8, makes no commit, creates no store"
else
  bad "dirty-index init: exit=$RC8 (want 8), HEAD moved=$([ "$BEFORE" = "$AFTER" ] && echo no || echo yes), .beads=$([ -d "$FRESH/.beads" ] && echo created || echo absent)"
fi

# custom statuses configured (all five, with correct categories)
CUST="$(bdq statuses --json | jq -c '.custom_statuses | map("\(.name):\(.category)") | sort')"
EXPECT='["accepted:done","completed:wip","draft:frozen","in_review:wip","rejected:active"]'
if [ "$CUST" = "$EXPECT" ]; then ok "init configured the 5 whip custom statuses"; else bad "custom statuses = $CUST (want $EXPECT)"; fi

# create parent + child (child depends on parent), then drive child to accepted.
# The adapter keys a task off the --file basename, so the filenames ARE the stems.
mkdoc bd-parent slug-parent none > "$WORK/bd-parent.md"
mkdoc bd-child  slug-child  bd-parent > "$WORK/bd-child.md"
"$ADAPTER" create --file "$WORK/bd-parent.md" --folder pending >/dev/null
"$ADAPTER" create --file "$WORK/bd-child.md"  --folder pending >/dev/null
"$ADAPTER" transition bd-child accepted quality-reviewer "ship it" 0 0 >/dev/null

# native bd status of an accepted task is the custom `accepted`
BST="$(bdq show whip-bd-child --json | jq -r '.[0].status')"
if [ "$BST" = "accepted" ]; then ok "accepted task has bd status 'accepted'"; else bad "bd status of accepted task = '$BST' (want accepted)"; fi

# native dependency edge is visible via `bd dep list`
DL="$(bdq dep list whip-bd-child --json | jq -r '.[].id' 2>/dev/null)"
if printf '%s\n' "$DL" | grep -q '^whip-bd-parent$'; then ok "dep edge child->parent visible via 'bd dep list'"; else bad "bd dep list did not show whip-bd-parent (got: $DL)"; fi

# whip_worktree metadata is present on the bd issue
WT="$(bdq show whip-bd-parent --json | jq -r '.[0].metadata.whip_worktree')"
if [ "$WT" = "slug-parent" ]; then ok "whip_worktree metadata present via 'bd show --json'"; else bad "whip_worktree = '$WT' (want slug-parent)"; fi

# id<->key bijection: the bd id is exactly <prefix>-<key>
CID="$(bdq show whip-bd-child --json | jq -r '.[0].id')"
if [ "$CID" = "whip-bd-child" ]; then ok "id<->key bijection holds (whip-bd-child)"; else bad "id = '$CID' (want whip-bd-child)"; fi

# materialize must render the stored audit trail so the clean-checkout token that
# log-event recorded (as a bd comment) is greppable in the refreshed spec doc.
"$ADAPTER" log-event bd-parent --row '| 2026-07-15 10:00:00 | clean-checkout | ok | clean-checkout-before-task | slug-parent | worktree/slug-parent |' >/dev/null
mkdir -p "$WORK/specs"
MAT="$("$ADAPTER" read --materialize "$WORK/specs" bd-parent)"
if grep -q '| clean-checkout | ok |' "$MAT" 2>/dev/null; then ok "materialize renders the clean-checkout audit token"; else bad "materialized doc missing clean-checkout token (path: $MAT)"; fi

echo
echo "phase9-adapter-beads: conformance rc=$CONF_RC; beads-specific $PASS passed, $FAIL failed"
[ "$CONF_RC" -eq 0 ] && [ "$FAIL" -eq 0 ]
