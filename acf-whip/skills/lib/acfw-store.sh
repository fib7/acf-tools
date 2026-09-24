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
# An unrecognized value is a FATAL (exit 2), not a warning that degrades to "". The instinct behind
# the warning was right — a typo must never silently flip delivery semantics in EITHER direction,
# because silently enabling local-trunk folds is as bad as silently disabling them — but degrading to
# "" flips them anyway: it hands the decision back to the model, which is the thing the pin exists to
# stop depending on, and the warning that says so lands on a shell-runner agent's stderr inside an
# unattended /go where nobody reads it. Refusing to run is the only outcome that cannot be missed.
# This is NOT a corner case. acfw_config_get strips surrounding quotes and trailing whitespace but
# NOT a trailing comment, so the natural
#     ACFW_INTEGRATION_MODE=override   # PR per group, never fold to trunk
# resolves to the literal 'override   # PR per group, never fold to trunk'. Under the old rule that
# config reads "pinned to override" and behaves as unpinned. Compare ACFW_STORE, where a bogus value
# already fails loud at adapter lookup (bin/acfw-store, exit 5); this closes the same gap here.
acfw_resolve_integration_mode() { # <repo-root>
  local m="${ACFW_INTEGRATION_MODE:-}"
  [ -n "$m" ] || m=$(acfw_config_get "${1:-}" ACFW_INTEGRATION_MODE)
  case "$m" in
    override|default|"") printf '%s' "$m" ;;
    *) echo "FATAL: unrecognized ACFW_INTEGRATION_MODE='$m' (expected 'override', 'default', or unset). Refusing to guess: this key decides whether accepted work folds into the local trunk. Note a trailing '# comment' is part of the value." >&2
       return 2 ;;
  esac
}

# acfw_resolve_models <repo-root> — print "shell<TAB>judge<TAB>author": the model each AGENT TIER
# runs on, resolved env > config > default. One knob per tier instead of one knob for everything.
#
# The tiers are about what the agent DOES, not about who calls it:
#   shell  — runs a fixed command and copies its stdout into a schema. Zero reasoning, and by far the
#            most frequent class, so it defaults to a fast/cheap model (haiku). Raising this tier was
#            the workaround suggested for the truncated-snapshot failure; it is the wrong lever —
#            bounding the payload is the fix, and this tier stays cheap because of it.
#   judge  — decomposition planners, the judge that picks between them, the critic. Real reasoning.
#   author — the agents that write task documents. Real reasoning.
# Specialists and reviewers are NOT here: they route by the `model:` frontmatter of the agent the
# project installed, which is where a project already expresses "this work runs on that model".
# Unset means "inherit the session model", which is the right default for anything that reasons.
acfw_resolve_models() { # <repo-root>
  local root="${1:-}" shell judge author
  shell="${ACFW_MODEL_SHELL:-}";  [ -n "$shell" ]  || shell=$(acfw_config_get "$root" ACFW_MODEL_SHELL)
  judge="${ACFW_MODEL_JUDGE:-}";  [ -n "$judge" ]  || judge=$(acfw_config_get "$root" ACFW_MODEL_JUDGE)
  author="${ACFW_MODEL_AUTHOR:-}"; [ -n "$author" ] || author=$(acfw_config_get "$root" ACFW_MODEL_AUTHOR)
  [ -n "$shell" ] || shell=haiku
  printf '%s\t%s\t%s' "$shell" "$judge" "$author"
}

# acfw_resolve_efforts <repo-root> — print the reasoning effort pinned for the SHELL tier, or "".
# Ships unset on purpose: the shell tier's model is absent from the documented effort-support table,
# and the effect of a low setting on verbatim-copy fidelity is undocumented. It is offered as a knob
# a team can now measure safely, because a short relay is DETECTED rather than believed — so it needs
# a way in. It had none until 3.4.0's cleanup: both workflows read `args.efforts` and both echo it in
# their report, but nothing produced it, so the documentation described a dial with no shaft.
# Vocabulary is the runtime's ('low'|'medium'|'high'|'xhigh'|'max'); an unrecognised value is refused
# rather than passed through, because a rejected option would fail every agent call in the run.
acfw_resolve_efforts() { # <repo-root>
  local root="${1:-}" e
  e="${ACFW_EFFORT_SHELL:-}"; [ -n "$e" ] || e=$(acfw_config_get "$root" ACFW_EFFORT_SHELL)
  case "$e" in
    ''|low|medium|high|xhigh|max) : ;;
    *) echo "FATAL: ACFW_EFFORT_SHELL='$e' is not a recognised effort (low|medium|high|xhigh|max). Unset it or fix the pin." >&2; return 2 ;;
  esac
  printf '%s' "$e"
}

# acfw_resolve_bare_go <repo-root> [store] — print 'all' or 'refuse': what a bare `/go` with no saved
# focus does. On the files backend the backlog is this checkout's own, so draining it is what the
# operator meant and the default stays 'all' (byte-identical to every release before 3.4.0). On a
# shared API-backed board it is emphatically not: one person's bare `/go` would be everyone's, which
# is how teams end up hand-authoring throwaway orchestrators instead of running the shipped one. There
# the default is 'refuse' — say what would run and make the operator choose. Pinnable either way.
acfw_resolve_bare_go() { # <repo-root> [store]
  local root="${1:-}" store="${2:-}" v
  [ -n "$store" ] || store=$(acfw_resolve_store "$root")
  v="${ACFW_GO_BARE:-}"
  [ -n "$v" ] || v=$(acfw_config_get "$root" ACFW_GO_BARE)
  if [ -z "$v" ]; then
    if [ "$store" = "files" ]; then v=all; else v=refuse; fi
  fi
  case "$v" in
    all|refuse) printf '%s' "$v" ;;
    *) echo "FATAL: unrecognized ACFW_GO_BARE='$v' (expected 'all' or 'refuse'). Refusing to guess: this key decides whether a bare /go drains the whole shared board." >&2
       return 2 ;;
  esac
}

# acfw_focus_path <repo-root> — print the per-checkout run focus file. Untracked by construction:
# .acfwhip/run/ is gitignored, and a focus is one person's current selection in one checkout, never
# a fact about the project.
acfw_focus_path() { # <repo-root>
  printf '%s/.acfwhip/run/focus' "${1:-}"
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
