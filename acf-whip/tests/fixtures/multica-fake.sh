# multica-fake.sh: SOURCED fixture. Defines multica_fake_install, which writes an offline stand-in
# for the `multica` CLI to a path of the caller's choosing.
#
# Why a sourced installer and not a checked-in executable: the fake was born inside
# phase9-adapter-multica.test.sh as a heredoc, and a second suite (phase20-cycle, 3.5.0) needs the
# SAME stand-in to run every cycle scenario against a non-files backend. Two copies drift: the one
# that stops matching the adapter's real CLI usage keeps passing while testing nothing. One file,
# one installer, and each suite writes it into its own mktemp scratch dir, so no suite depends on an
# executable bit surviving a copy of the plugin tree.
#
# Usage (from a test):
#   . "$ACF_WHIP/tests/fixtures/multica-fake.sh"
#   multica_fake_install "$WORK/multica-fake"          # writes + chmod +x
#   export ACFW_MULTICA_BIN="$WORK/multica-fake" MC_FAKE_STATE="$WORK/state.json"
#
# Behaviour is the phase9 fake's, byte for byte in every path it already had. The one addition is
# MC_FAKE_LOG: when set, every invocation's argv is appended to that file BEFORE fault injection, so
# a suite can prove a code path made zero backend calls (acfw-cycle status --if-cycle must not touch
# the store). Unset, as phase9 leaves it, nothing is written.

multica_fake_install() { # <dest path>
  local dest="${1:?multica_fake_install: destination path required}"
  cat > "$dest" <<'FAKEEOF'
#!/usr/bin/env bash
# multica-fake — an offline stand-in for the `multica` CLI, backed by one JSON file.
#
# The adapter funnels every backend call through multica_call -> "$MULTICA_BIN", and MULTICA_BIN is
# ${ACFW_MULTICA_BIN:-multica}. That single seam is all an offline conformance run needs — the same
# shape phase9-adapter-linear.test.sh already uses for Linear via ACFW_LINEAR_TRANSPORT.
#
# State:   $MC_FAKE_STATE (JSON: {"issues":{<uuid>:{...}},"seq":N})
# Faults:  $MC_FAKE_FAIL  — "<pattern>:<exit>" pairs, comma separated. A pattern is one or more
#            substrings joined by "+", ALL of which must appear in the joined argv. The AND form is
#            what makes a fault precise: "metadata get+whip_rejections" fails the READ of that key
#            without also failing the WRITE, which would mask the very fabrication under test.
#          $MC_FAKE_FAIL_ONCE — same, but each pattern fires once then clears (via $MC_FAKE_FIRED)
# Calls:   $MC_FAKE_LOG — when set, one line per invocation (the joined argv) is appended to it
set -u
STATE="${MC_FAKE_STATE:?MC_FAKE_STATE must be set}"
[ -f "$STATE" ] || printf '{"issues":{},"seq":0}\n' > "$STATE"

ARGV="$*"
[ -n "${MC_FAKE_LOG:-}" ] && printf '%s\n' "$ARGV" >> "$MC_FAKE_LOG"
matches_all() { # <pattern-with-+-separators> — every part must appear in $ARGV
  local part
  for part in $(printf '%s' "$1" | tr '+' '\n'); do
    case "$ARGV" in *"$part"*) ;; *) return 1 ;; esac
  done
  return 0
}
fault() { # honour MC_FAKE_FAIL / MC_FAKE_FAIL_ONCE against the joined argv
  local spec pat code OLDIFS
  # Split on COMMAS only. `$(... | tr ',' ' ')` word-splits on spaces too, so an AND-pattern containing
  # one ("metadata get+whip_state") became two broken specs, the first of which ("metadata") matched
  # every metadata call — defeating the precision the AND form exists to provide.
  OLDIFS="$IFS"; IFS=','
  for spec in ${MC_FAKE_FAIL_ONCE:-}; do
    IFS="$OLDIFS"
    pat="${spec%:*}"; code="${spec##*:}"
    if matches_all "$pat"; then
      if [ -n "${MC_FAKE_FIRED:-}" ] && [ -f "$MC_FAKE_FIRED" ] && grep -qxF "$spec" "$MC_FAKE_FIRED"; then continue; fi
      [ -n "${MC_FAKE_FIRED:-}" ] && echo "$spec" >> "$MC_FAKE_FIRED"
      echo "fake: injected transient for '$pat'" >&2; exit "$code"
    fi
    IFS=','
  done
  IFS="$OLDIFS"
  IFS=','
  for spec in ${MC_FAKE_FAIL:-}; do
    IFS="$OLDIFS"
    pat="${spec%:*}"; code="${spec##*:}"
    case "$code" in ''|*[!0-9]*) echo "fake: malformed MC_FAKE_FAIL spec '$spec' (want <pattern>:<exit>)" >&2; exit 64 ;; esac
    matches_all "$pat" && { echo "fake: injected failure for '$pat'" >&2; exit "$code"; }
    IFS=','
  done
  IFS="$OLDIFS"
}
fault

jqs() { jq "$@" "$STATE"; }
save() { local t; t=$(mktemp); jq "$@" "$STATE" > "$t" && mv "$t" "$STATE"; }

SUB="${1:-}"; shift || true
[ "$SUB" = "issue" ] || { echo "fake: unsupported command '$SUB'" >&2; exit 2; }
ACT="${1:-}"; shift || true

case "$ACT" in
  create)
    TITLE=""; DESC=""; STATUS="todo"; PRIO=""
    while [ $# -gt 0 ]; do case "$1" in
      --title) TITLE="$2"; shift 2 ;;
      --description-stdin) DESC=$(cat); shift ;;
      --status) STATUS="$2"; shift 2 ;;
      --priority) PRIO="$2"; shift 2 ;;
      --output) shift 2 ;;
      *) shift ;;
    esac; done
    ID="iss-$(jqs -r '.seq + 1')"
    save --arg id "$ID" --arg t "$TITLE" --arg d "$DESC" --arg s "$STATUS" --arg p "$PRIO" \
      '.seq += 1 | .issues[$id] = {id:$id, identifier:("T-"+($id|ltrimstr("iss-"))), title:$t, description:$d, status:$s, priority:$p, metadata:{}, comments:[]}'
    jqs -r --arg id "$ID" '.issues[$id] | {id, identifier, title, status}'
    ;;
  list)
    LIMIT=1000; OFFSET=0; MKEY=""; MVAL=""
    while [ $# -gt 0 ]; do case "$1" in
      --limit) LIMIT="$2"; shift 2 ;;
      --offset) OFFSET="$2"; shift 2 ;;
      --metadata) MKEY="${2%%=*}"; MVAL="${2#*=}"; shift 2 ;;
      --project) shift 2 ;;
      --output) shift 2 ;;
      *) shift ;;
    esac; done
    # Real shape: {"issues":[...],"has_more":bool} — the adapter paginates on has_more and counts
    # .issues|length, so a bare array breaks both.
    jqs -r --argjson lim "$LIMIT" --argjson off "$OFFSET" --arg mk "$MKEY" --arg mv "$MVAL" '
      ([.issues[]]
       | if $mk == "" then . else map(select(((.metadata[$mk] // "") | tostring) == $mv)) end
       | sort_by(.id)) as $all
      | {issues: $all[$off:($off + $lim)], has_more: (($off + $lim) < ($all | length))}'
    ;;
  get)
    ID="$1"; shift
    jqs -e -r --arg id "$ID" '.issues[$id] // empty' || { echo "fake: no such issue $ID" >&2; exit 4; }
    ;;
  status)
    ID="$1"; ST="$2"
    jqs -e --arg id "$ID" '.issues | has($id)' >/dev/null || { echo "fake: no such issue $ID" >&2; exit 4; }
    save --arg id "$ID" --arg s "$ST" '.issues[$id].status = $s'
    jqs -r --arg id "$ID" '.issues[$id] | {id, status}'
    ;;
  update)
    ID="$1"; shift
    while [ $# -gt 0 ]; do case "$1" in
      --description-stdin) D=$(cat); save --arg id "$ID" --arg d "$D" '.issues[$id].description = $d'; shift ;;
      --priority) save --arg id "$ID" --arg p "$2" '.issues[$id].priority = $p'; shift 2 ;;
      --output) shift 2 ;;
      *) shift ;;
    esac; done
    jqs -r --arg id "$ID" '.issues[$id] | {id}'
    ;;
  metadata)
    MACT="${1:-}"; shift || true
    ID="$1"; shift
    KEY=""; VAL=""; TYPE="string"
    while [ $# -gt 0 ]; do case "$1" in
      --key) KEY="$2"; shift 2 ;;
      --value) VAL="$2"; shift 2 ;;
      --type) TYPE="$2"; shift 2 ;;
      --output) shift 2 ;;
      *) shift ;;
    esac; done
    case "$MACT" in
      set) if [ "$TYPE" = "number" ]; then save --arg id "$ID" --arg k "$KEY" --argjson v "${VAL:-0}" '.issues[$id].metadata[$k] = $v'
           else save --arg id "$ID" --arg k "$KEY" --arg v "$VAL" '.issues[$id].metadata[$k] = $v'; fi
           printf '{"ok":true}\n' ;;
      # --output json means JSON, not a bare word: the adapter pipes this through jq.
      get) jqs -e --arg id "$ID" --arg k "$KEY" '.issues[$id].metadata[$k] // empty' \
             || { echo "fake: no such metadata key $KEY" >&2; exit 4; } ;;
      *)   echo "fake: unsupported metadata action '$MACT'" >&2; exit 2 ;;
    esac
    ;;
  comment)
    CACT="${1:-}"; shift || true
    ID="$1"; shift
    case "$CACT" in
      add)  C=""; while [ $# -gt 0 ]; do case "$1" in --content-stdin) C=$(cat); shift ;; --output) shift 2 ;; *) shift ;; esac; done
            save --arg id "$ID" --arg c "$C" '.issues[$id].comments += [{content:$c}]'; printf '{"ok":true}\n' ;;
      list) jqs -r --arg id "$ID" '.issues[$id].comments // []' ;;
      *)    echo "fake: unsupported comment action '$CACT'" >&2; exit 2 ;;
    esac
    ;;
  *) echo "fake: unsupported issue action '$ACT'" >&2; exit 2 ;;
esac
FAKEEOF
  chmod +x "$dest"
}
