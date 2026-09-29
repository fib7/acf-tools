#!/usr/bin/env bash
# spec-tool-fake.sh: a configurable stand-in for ANY spec tool (acf-whip 3.5.0, phase21-spec-tools).
#
# WHY ONE FAKE FOR EVERY KIND. acfw-spec runs three kinds of tool (a `driver=` executable, a
# `review=` shell command, an `agent=` prompt) and the only thing it may assume about any of them is
# the protocol in spec-tools/CONTRACT.md: env in, exit code + line records out. So one program that
# speaks that protocol, and nothing else, is enough to exercise every engine path. A test installs it
# as a driver through a two-line wrapper (`exec /bin/bash spec-tool-fake.sh --ctl DIR --tag T "$@"`)
# or names it directly in a `review=` line.
#
# WHY BEHAVIOUR LIVES IN A CONTROL DIR AND NOT IN THE DECLARATION. The engine caches a verdict per
# (key, blob, HEAD declaration sha, resolved driver path + hash), and trust-on-first-use re-arms on
# any declaration change. A test that re-wrote the declaration to change what the tool does would
# reset the very cache and trust it is trying to observe. So the declaration (and the wrapper) stay
# byte-stable and a test flips files in --ctl DIR between calls. The ctl dir travels on argv, not in
# env, so this works even if the engine scrubs the environment it hands a tool.
#
# Usage: spec-tool-fake.sh --ctl <dir> [--tag <label>] [<verb>]
#   The verb is $ACFW_SPEC_VERB (the contract: env only), falling back to argv, then `review`.
#
# Control files, all optional, read at call time ("X | V.X" = verb-specific file wins over X):
#   calls              APPENDED, one line per invocation:
#                        <verb> stage=<s> key=<k> blob=<b> tag=<t> pid=<p> pgid=<g>
#   env.<pid>, last-env  written: the ACFW_SPEC_* / ACFW_TRUNK_ROOT env this call saw, plus
#                        FAKE_FILE_WRITABLE / FAKE_OUT_IS_DIR / FAKE_STATE_IS_DIR probes
#   file.<pid>           written: a copy of $ACFW_SPEC_FILE as this call saw it
#   exit  | V.exit       exit status (default 0 = GO)
#   stdout| V.stdout     bytes copied to stdout (records, or unstructured linter noise)
#   stderr| V.stderr     bytes copied to stderr (exit 3: the first line is the reason)
#   sleep | V.sleep      seconds to sleep AFTER output, BEFORE exit (a slow or hung tool); the
#                        sleeper's pid goes to sleep.pid (latest) and sleep.pids (all)
#   trap-term            present: this process ignores SIGTERM, so only KILL stops it
#   grandchild           "plain" | "ignore-term": fork a curl-like background sleeper that keeps
#                        our stdout open and outlives us unless its process GROUP is killed;
#                        its pid goes to grandchild.pid (latest) and grandchild.pids (all)
#   fake.pid, fake.pids  written: this process's pid (latest / all), so a suite's cleanup trap
#                        can reap every one a broken engine leaves behind
#   running.<pid>, conc  concurrency probe: each call holds running.<pid> for its whole life and, on
#                        start, APPENDS to conc how many calls were running (itself included). A job
#                        ends only after its tool exits, so max(conc) is the engine's real peak.
#   grandchild.secs      how long that sleeper lives (default 120)
#   verbs                comma list for the capabilities VERBS| record (default: review)
#   cost / needs / egress  payloads for COST| / NEEDS| / EGRESS| (a line is printed only if the file exists)
#   V.remote             pull/from: copied to $ACFW_SPEC_OUT/remote.md (the workbench's text)
#   pushed.md            written by push: the bytes the engine asked us to push
#
# Built-in verb behaviour on top of the files above:
#   capabilities   prints VERBS|, and NEEDS|/EGRESS|/COST| when configured; exit 0
#   <not offered>  a verb missing from `verbs` exits 3 with "verb <v> not offered" (contract: exit 3
#                  = unavailable, first stderr line is the reason)
#   push           default records REF|fake-ref-1 and URL|https://fake.example.test/spec/fake-ref-1
#                  (overridden by push.stdout); the pushed bytes land in pushed.md
#   pull, from     V.remote -> $ACFW_SPEC_OUT/remote.md when present
#
# bash 3.2 (macOS /bin/bash) compatible: no associative arrays, no mapfile, no ${x,,}.
set -u

CTL="" TAG="-"
while [ $# -gt 0 ]; do
  case "$1" in
    --ctl) CTL="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done
[ -n "$CTL" ] && [ -d "$CTL" ] || { echo "spec-tool-fake: --ctl <existing dir> required" >&2; exit 2; }

VERB="${ACFW_SPEC_VERB:-${1:-review}}"

# pick <name>: the verb-specific control file wins over the generic one.
pick() { if [ -f "$CTL/$VERB.$1" ]; then printf '%s' "$CTL/$VERB.$1"; elif [ -f "$CTL/$1" ]; then printf '%s' "$CTL/$1"; fi; }

PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
printf '%s stage=%s key=%s blob=%s tag=%s pid=%s pgid=%s\n' \
  "$VERB" "${ACFW_SPEC_STAGE:-}" "${ACFW_SPEC_KEY:-}" "${ACFW_SPEC_BLOB:-}" "$TAG" "$$" "${PGID:-?}" >> "$CTL/calls"
echo "$$" > "$CTL/fake.pid"
echo "$$" >> "$CTL/fake.pids"       # every pid ever, so a cleanup trap can reap all of them
: > "$CTL/running.$$"
trap 'rm -f "$CTL/running.$$"' EXIT
ls "$CTL" 2>/dev/null | grep -c '^running\.' >> "$CTL/conc"
[ -n "${PGID:-}" ] && echo "$PGID" > "$CTL/fake.pgid"

# Probe what the engine promised a tool: a frozen, read-only input file, an existing OUT dir, a
# STATE dir. Recorded rather than asserted here so the suite owns every verdict.
{
  env | grep -E '^(ACFW_SPEC_[A-Z_]*|ACFW_TRUNK_ROOT)=' | sort
  if [ -n "${ACFW_SPEC_FILE:-}" ] && [ -e "$ACFW_SPEC_FILE" ]; then
    if [ -w "$ACFW_SPEC_FILE" ]; then echo "FAKE_FILE_WRITABLE=yes"; else echo "FAKE_FILE_WRITABLE=no"; fi
  fi
  if [ -n "${ACFW_SPEC_OUT:-}" ] && [ -d "$ACFW_SPEC_OUT" ]; then echo "FAKE_OUT_IS_DIR=yes"; else echo "FAKE_OUT_IS_DIR=no"; fi
  if [ -n "${ACFW_SPEC_STATE:-}" ] && [ -d "$ACFW_SPEC_STATE" ]; then echo "FAKE_STATE_IS_DIR=yes"; else echo "FAKE_STATE_IS_DIR=no"; fi
} > "$CTL/env.$$" 2>/dev/null
cp "$CTL/env.$$" "$CTL/last-env" 2>/dev/null
[ -n "${ACFW_SPEC_FILE:-}" ] && [ -f "$ACFW_SPEC_FILE" ] && cp "$ACFW_SPEC_FILE" "$CTL/file.$$" 2>/dev/null

[ -f "$CTL/trap-term" ] && trap '' TERM

VERBS=review
[ -f "$CTL/verbs" ] && VERBS=$(tr -d ' \n' < "$CTL/verbs")

if [ "$VERB" = capabilities ]; then
  echo "VERBS|$VERBS"
  [ -f "$CTL/needs" ]  && echo "NEEDS|$(head -1 "$CTL/needs")"
  [ -f "$CTL/egress" ] && echo "EGRESS|$(head -1 "$CTL/egress")"
  [ -f "$CTL/cost" ]   && echo "COST|$(head -1 "$CTL/cost")"
  exit 0
fi

case ",$VERBS," in
  *",$VERB,"*) ;;
  *) echo "verb $VERB not offered by this fake (verbs: $VERBS)" >&2
     echo "HINT|this tool offers: $VERBS"
     exit 3 ;;
esac

case "$VERB" in
  push)
    [ -n "${ACFW_SPEC_FILE:-}" ] && [ -f "$ACFW_SPEC_FILE" ] && cp "$ACFW_SPEC_FILE" "$CTL/pushed.md"
    if [ -z "$(pick stdout)" ]; then
      echo "REF|fake-ref-1"
      echo "URL|https://fake.example.test/spec/fake-ref-1"
    fi
    ;;
  pull|from)
    R=$(pick remote)
    if [ -n "$R" ] && [ -n "${ACFW_SPEC_OUT:-}" ]; then
      mkdir -p "$ACFW_SPEC_OUT" && cp "$R" "$ACFW_SPEC_OUT/remote.md"
    fi
    ;;
esac

F=$(pick stdout); [ -n "$F" ] && cat "$F"
F=$(pick stderr); [ -n "$F" ] && cat "$F" >&2

# The curl-like grandchild: a background process that holds our stdout pipe open and would outlive
# us. Killing only the tool's pid leaves it running and leaves the engine blocked reading the pipe;
# only a kill of the whole process group reaps it. That is the watchdog property under test.
GC_SECS=120; [ -f "$CTL/grandchild.secs" ] && GC_SECS=$(head -1 "$CTL/grandchild.secs")
# A simple command with `&`, never `( exec sleep ) &`: bash 3.2 forks twice for the latter, so `$!`
# names an intermediate shell and not the sleeper, and a check on it proves nothing.
if [ -f "$CTL/grandchild" ]; then
  if [ "$(head -1 "$CTL/grandchild")" = ignore-term ]; then
    trap '' TERM                       # an ignored disposition survives fork+exec into the child
    sleep "$GC_SECS" &
    GC=$!
    [ -f "$CTL/trap-term" ] || trap - TERM
  else
    sleep "$GC_SECS" &
    GC=$!
  fi
  echo "$GC" > "$CTL/grandchild.pid"
  echo "$GC" >> "$CTL/grandchild.pids"
fi

# The hang itself. Backgrounded + wait (not a foreground `sleep`) so its pid is on record: an engine
# that kills only this shell's pid orphans the sleep too, and a suite must be able to see and reap it.
F=$(pick sleep)
if [ -n "$F" ]; then
  sleep "$(head -1 "$F")" &
  SLP=$!
  echo "$SLP" > "$CTL/sleep.pid"
  echo "$SLP" >> "$CTL/sleep.pids"
  wait "$SLP"
fi

RC=0; F=$(pick exit); [ -n "$F" ] && RC=$(head -1 "$F")
exit "$RC"
