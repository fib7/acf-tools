#!/usr/bin/env bash
# acfw-store.sh — task-store resolution helpers for acf-whip (contract v1).
#
# Source this from any acf-whip bin/ script (acfw-git.sh sources it automatically):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/../../lib/acfw-store.sh"
#
# Single source of truth for WHERE the config lives, WHICH store backend is active,
# WHERE the run lock lives, and WHERE a backend's adapter executable is found.
# Pure path/string logic: no git calls, no writes, no sourcing side effects except
# where explicitly documented. Pure bash 3.2 (no `declare -A`) — macOS ships 3.2.

ACFW_CONTRACT_VERSION=1

# acfw_resolve_config_file <repo-root> — print the path of the EFFECTIVE config file,
# or nothing (exit 1) when none exists. Resolution order (first existing wins):
#   1. $ACFW_CONFIG_FILE            explicit env override (tests, unusual layouts)
#   2. <root>/.acfwhip/config       backend-neutral home (3.1.0+; .acfwhip/ already
#                                   rides trunk for the LP-CAS ledger)
#   3. <root>/.backlog/.acfw-config legacy home (files backend; zero-migration path)
# A project that predates 3.1.0 has only #3 and resolves exactly as before.
acfw_resolve_config_file() { # <repo-root>
  local root="${1:-}"
  if [ -n "${ACFW_CONFIG_FILE:-}" ] && [ -f "$ACFW_CONFIG_FILE" ]; then
    printf '%s' "$ACFW_CONFIG_FILE"; return 0
  fi
  [ -n "$root" ] || return 1
  if [ -f "$root/.acfwhip/config" ]; then
    printf '%s' "$root/.acfwhip/config"; return 0
  fi
  if [ -f "$root/.backlog/.acfw-config" ]; then
    printf '%s' "$root/.backlog/.acfw-config"; return 0
  fi
  return 1
}

# acfw_config_get <repo-root> <KEY> — print one key's value from the effective config
# WITHOUT sourcing it (no side effects on the caller's variables). Last assignment wins,
# surrounding single/double quotes stripped. Empty output when unset or no config.
acfw_config_get() { # <repo-root> <KEY>
  local cfg val
  cfg=$(acfw_resolve_config_file "${1:-}") || return 0
  val=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${2}=" "$cfg" 2>/dev/null | tail -1 \
        | sed -E "s/^[[:space:]]*(export[[:space:]]+)?${2}=//" \
        | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/" \
        | sed -E 's/[[:space:]]+$//')
  printf '%s' "$val"
}

# acfw_resolve_store <repo-root> — print the active store backend name.
# Precedence: $ACFW_STORE env > ACFW_STORE= in the effective config > "files".
# Never empty; never fails.
acfw_resolve_store() { # <repo-root>
  local store="${ACFW_STORE:-}"
  [ -n "$store" ] || store=$(acfw_config_get "${1:-}" ACFW_STORE)
  [ -n "$store" ] || store=files
  printf '%s' "$store"
}

# acfw_resolve_integration_mode <repo-root> — print the pinned integration mode, or nothing.
# Resolution mirrors acfw_resolve_store: ACFW_INTEGRATION_MODE env > ACFW_INTEGRATION_MODE key
# in config > "" (unpinned).
#   override  stop at accepted; the operator integrates (e.g. a PR per PR Group)
#   default   LP-CAS folds every accepted task into the local trunk (Step 4.5)
#   ""        no machine pin — the orchestrator decides by reading project instructions,
#             exactly as before this key existed
# An unrecognized value resolves to "" with a stderr warning, i.e. to the pre-existing
# prose-fallback behavior: a typo must never silently flip delivery semantics in EITHER
# direction (silently enabling local trunk folds is as bad as silently disabling them).
acfw_resolve_integration_mode() { # <repo-root>
  local m="${ACFW_INTEGRATION_MODE:-}"
  [ -n "$m" ] || m=$(acfw_config_get "${1:-}" ACFW_INTEGRATION_MODE)
  case "$m" in
    override|default|"") printf '%s' "$m" ;;
    *) echo "WARN: unrecognized ACFW_INTEGRATION_MODE='$m' — ignoring; the orchestrator falls back to reading project instructions" >&2 ;;
  esac
}

# acfw_run_lock_path <repo-root> [store] — print the /go run-lock (heartbeat) path.
# files keeps the historical .backlog/.acfw-run.json (already gitignored by whip-init);
# every other backend has no .backlog/, so the lock lives under .acfwhip/run/ (gitignored,
# never overlapping the committed .acfwhip/integrated/ ledger shards).
acfw_run_lock_path() { # <repo-root> [store]
  local root="${1:-}" store="${2:-}"
  [ -n "$store" ] || store=$(acfw_resolve_store "$root")
  if [ "$store" = "files" ]; then
    printf '%s/.backlog/.acfw-run.json' "$root"
  else
    printf '%s/.acfwhip/run/acfw-run.json' "$root"
  fi
}

# acfw_plugin_root — print the acf-whip plugin root (parent of skills/), derived from
# this lib's own location so it works from any checkout or plugin-cache path.
acfw_plugin_root() {
  ( cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd )
}

# acfw_locate_adapter <backend> <repo-root> — print the adapter executable for a backend,
# or nothing (exit 1). An adapter is one executable named acfw-store-<backend>.
# Discovery order (first executable wins) — this is the documented third-party path:
#   1. $ACFW_STORE_ADAPTER_PATH     colon-separated dirs (env override)
#   2. <root>/.acfwhip/adapters/    project-local drop-in (commit one executable +
#                                   set ACFW_STORE=<backend>; no plugin fork needed)
#   3. <plugin>/adapters/<backend>/ adapters shipped with acf-whip (files, beads, multica)
#   4. $PATH                        system-installed adapters
acfw_locate_adapter() { # <backend> <repo-root>
  local backend="${1:?backend required}" root="${2:-}" name d found
  name="acfw-store-$backend"
  if [ -n "${ACFW_STORE_ADAPTER_PATH:-}" ]; then
    while IFS= read -r d || [ -n "$d" ]; do
      [ -n "$d" ] && [ -x "$d/$name" ] && { printf '%s' "$d/$name"; return 0; }
    done < <(printf '%s' "$ACFW_STORE_ADAPTER_PATH" | tr ':' '\n')
  fi
  if [ -n "$root" ] && [ -x "$root/.acfwhip/adapters/$name" ]; then
    printf '%s' "$root/.acfwhip/adapters/$name"; return 0
  fi
  d="$(acfw_plugin_root)/adapters/$backend"
  if [ -x "$d/$name" ]; then
    printf '%s' "$d/$name"; return 0
  fi
  found=$(command -v "$name" 2>/dev/null) && { printf '%s' "$found"; return 0; }
  return 1
}
