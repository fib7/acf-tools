#!/usr/bin/env bash
# autopilot-stop.sh: acf-whip's Stop hook. Hands a /whip --auto run its next step at the end of a turn.
#
# It runs at the end of EVERY turn of every session with acf-whip enabled, so the common case (no
# autopilot run in this checkout) costs a file test and nothing else: no JSON parse, no git call.
# With a run, skills/lib/bin/acfw-autopilot `tick` decides, and prints the hook's JSON or nothing.
# A failure of its own exits 0 with no output, so a broken autopilot can never keep a session from
# stopping. Its stderr goes to .acfwhip/run/autopilot/hook.err for diagnosis.
root=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.acfwhip/run/autopilot/state" ]; then
  root="$CLAUDE_PROJECT_DIR"
else
  d="$PWD"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/.acfwhip/run/autopilot/state" ] && { root="$d"; break; }
    d=$(dirname "$d")
  done
fi
[ -n "$root" ] || exit 0

bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/skills/lib/bin/acfw-autopilot"
[ -f "$bin" ] || exit 0
out=$(ACFW_TRUNK_ROOT="$root" bash "$bin" tick 2>>"$root/.acfwhip/run/autopilot/hook.err") || exit 0
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
