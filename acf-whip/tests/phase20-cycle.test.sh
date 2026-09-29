#!/usr/bin/env bash
# phase20-cycle.test.sh — acfw-cycle, the deterministic core of the 3.5.0 ACF cycle
# (PLAN -> DECOMPOSE -> BUILD -> VERIFY -> RETRO).
#
# WHAT THIS FILE IS. A spec-first test of acfw-cycle, written from the approved plan and the frozen
# INTERFACES contract, not from the script's code. It pins what other code and the
# operator ACT on: NEXT lines, exit codes, the CHECK/RECORD/INIT/RETRO/TRIGGER machine lines, the
# record.md shape (Metadata bullets, `## Tasks` rows, a newest-first Plan Log with '|' replaced),
# commit subjects, ACFW-Plan-Event trailers, and exactly which paths each commit carries. It does NOT
# pin card prose: a card is read by a human, and a test that froze its wording would only stop anyone
# improving it. Where the spec quotes a phrase as load-bearing ("amended since approval", "stage
# unknown", "jq required", "retiring a lesson is yours", "wait: /go is running") that phrase is pinned.
#
# WHY BOTH BACKENDS. Every scenario runs twice, against the files store and against the offline
# multica fake (tests/fixtures/multica-fake.sh). They differ exactly where the cycle is most fragile:
# a raw adapter's `snapshot --only` drops an accepted seed from tasks[] (it survives only in
# scope.resolved), while the files scanner keeps it. A status that read coverage from tasks[] alone
# would call every finished multica task a phantom and re-decompose it; a files-only suite would pass.
#
# WHY A PLUGIN COPY. `status --if-cycle` must make ZERO acfw-store calls (it runs after every /go, and
# on an API store every call is a board walk). The dispatcher is invoked by path from acfw-cycle's own
# directory, so the only way to count dispatcher calls without editing the shipped tree is to run
# those assertions from a scratch copy whose acfw-store logs and then execs the real one. Adapter
# calls are counted on every run as well, through $ACFW_STORE_ADAPTER_PATH wrappers.
#
# Engine under test: skills/lib/bin/acfw-cycle, run under /bin/bash (3.2 on macOS) when it exists.
# Run: bash acf-whip/tests/phase20-cycle.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ACF_WHIP/skills/lib/bin"
CYCLE="$BIN/acfw-cycle"
STORE_BIN="$BIN/acfw-store"
FOCUS_BIN="$BIN/acfw-focus"
CYBASH=/bin/bash; [ -x "$CYBASH" ] || CYBASH=$(command -v bash)
CY_TIMEOUT="${P20_TIMEOUT:-120}"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (the multica adapter and the store-reading verbs need it)"; exit 0; }
[ -f "$CYCLE" ] || echo "NOTE: $CYCLE does not exist yet; every engine assertion below will fail."

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){
  FAIL=$((FAIL+1)); echo "  FAIL: $1"
  # The last engine call, so a failure report says what the engine actually answered.
  if [ -n "${CY_LAST:-}" ]; then
    echo "        last: $CY_LAST -> rc=${CY_RC:-?} | $(printf '%s\n' "${CY_ALL:-}" | grep -v '^[[:space:]]*$' | head -4 | tr '\n' '|' | cut -c1-320)"
  fi
}
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }
ck(){ local l="$1"; shift; if "$@"; then ok "$l"; else bad "$l"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p20.XXXXXX") || exit 1
WORK=$(cd "$WORK" && pwd -P)   # physical path: the engine prints absolute paths we compare byte-for-byte
trap 'cd /; rm -rf "$WORK"' EXIT
export GIT_EDITOR=true GIT_TERMINAL_PROMPT=0 GIT_CEILING_DIRECTORIES="$WORK"
unset ACFW_LOG_ROW_CAP ACFW_GO_BARE ACFW_INTEGRATION_MODE ACFW_CONFIG_FILE ACFW_TRUNK_BRANCH 2>/dev/null || true
mkdir -p "$WORK/nohooks"
REAL_GIT=$(command -v git)

# ---- the multica stand-in (shared with phase9-adapter-multica) --------------------------------------
. "$ACF_WHIP/tests/fixtures/multica-fake.sh"
FAKE="$WORK/multica-fake"
multica_fake_install "$FAKE"
export MC_FAKE_LOG="$WORK/mc-calls.log"; : > "$MC_FAKE_LOG"

# ---- adapter-call counters: wrappers found first on the documented discovery path -----------------
export P20_CALL_LOG="$WORK/adapter-calls.log"; : > "$P20_CALL_LOG"
mkdir -p "$WORK/adapters"
for b in files multica; do
  cat > "$WORK/adapters/acfw-store-$b" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$b \$*" >> "\${P20_CALL_LOG:-/dev/null}"
# P20_OUTAGE=<rc>: the backend stops answering reads (capabilities still work, as a probe would).
# P20_READ_OUTAGE=<rc>: only a read fails, while the snapshot a moment earlier still answered.
case "\${1:-}" in snapshot|read) [ -n "\${P20_OUTAGE:-}" ] && { echo "p20: simulated store outage" >&2; exit "\$P20_OUTAGE"; } ;; esac
case "\${1:-}" in read) [ -n "\${P20_READ_OUTAGE:-}" ] && { echo "p20: simulated read outage" >&2; exit "\$P20_READ_OUTAGE"; } ;; esac
exec "$ACF_WHIP/adapters/$b/acfw-store-$b" "\$@"
EOF
  chmod +x "$WORK/adapters/acfw-store-$b"
done
export ACFW_STORE_ADAPTER_PATH="$WORK/adapters"

# ---- a scratch plugin copy whose DISPATCHER logs every call (for the zero-call assertions) --------
# Re-synced from the live tree before every counted call, so it never runs stale code.
PCOPY="$WORK/plugin"
pcopy_sync() {
  local d
  for d in skills content adapters spec-tools; do
    [ -d "$ACF_WHIP/$d" ] || continue
    mkdir -p "$PCOPY/$d" && cp -R "$ACF_WHIP/$d/." "$PCOPY/$d/" 2>/dev/null
  done
  mv -f "$PCOPY/skills/lib/bin/acfw-store" "$PCOPY/skills/lib/bin/acfw-store.real"
  cat > "$PCOPY/skills/lib/bin/acfw-store" <<'EOF'
#!/usr/bin/env bash
printf 'acfw-store %s\n' "$*" >> "${P20_DISPATCH_LOG:-/dev/null}"
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/acfw-store.real" "$@"
EOF
  chmod +x "$PCOPY/skills/lib/bin/acfw-store"
}
pcopy_sync
CYCLE_COPY="$PCOPY/skills/lib/bin/acfw-cycle"
export P20_DISPATCH_LOG="$WORK/dispatch-calls.log"; : > "$P20_DISPATCH_LOG"
calls_reset(){ : > "$P20_CALL_LOG"; : > "$P20_DISPATCH_LOG"; : > "$MC_FAKE_LOG"; }
calls_n(){ cat "$P20_CALL_LOG" "$P20_DISPATCH_LOG" "$MC_FAKE_LOG" | grep -c . | tr -d ' '; }
zero_calls(){ [ "$(calls_n)" = 0 ]; }

# ---- a PATH with every tool except jq (the store-free verbs must not need it) ----------------------
NOJQ="$WORK/nojq-bin"; mkdir -p "$NOJQ"
OLDIFS=$IFS; IFS=:
for d in $PATH; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b=${f##*/}; [ "$b" = jq ] && continue
    [ -e "$NOJQ/$b" ] || ln -s "$f" "$NOJQ/$b" 2>/dev/null
  done
done
IFS=$OLDIFS

# ---- a git that fires one `reset --mixed` right before the first commit (land()'s race) ------------
mkdir -p "$WORK/gitwrap"
cat > "$WORK/gitwrap/git" <<EOF
#!/bin/sh
sub=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in
    -C|-c|--git-dir|--work-tree|--namespace) skip=1 ;;
    -*) ;;
    *) sub="\$a"; break ;;
  esac
done
if [ "\$sub" = commit ] && [ -n "\${P20_RESET_ONCE:-}" ] && [ ! -e "\$P20_RESET_ONCE" ]; then
  : > "\$P20_RESET_ONCE"
  "$REAL_GIT" reset -q --mixed >/dev/null 2>&1
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$WORK/gitwrap/git"

# ---- hooks ------------------------------------------------------------------------------------------
mkdir -p "$WORK/hooks-fail" "$WORK/hooks-fmt"
printf '#!/bin/sh\necho "p20: this hook refuses every commit" >&2\nexit 1\n' > "$WORK/hooks-fail/pre-commit"
cat > "$WORK/hooks-fmt/pre-commit" <<'EOF'
#!/bin/sh
# A markdown formatter the way lint-staged runs one: rewrite the staged file, re-add it.
for f in $(git diff --cached --name-only); do
  case "$f" in docs/cycles/*/plan.md) printf '\nreformatted by a hook\n' >> "$f"; git add "$f" ;; esac
done
exit 0
EOF
mkdir -p "$WORK/hooks-ws"
cat > "$WORK/hooks-ws/pre-commit" <<'EOF'
#!/bin/sh
# What the shipped pre-commit configs run on every staged file (trailing-whitespace, end-of-file-fixer,
# mixed-line-ending): a trailing blank, a CR, a missing final newline or trailing blank lines fail the
# commit. The real hooks also rewrite the file; failing is the part that matters here.
rc=0
for f in $(git diff --cached --name-only); do
  git show ":$f" > "$P20_WS_TMP" 2>/dev/null || continue
  [ -s "$P20_WS_TMP" ] || continue
  if grep -q '[[:space:]]$' "$P20_WS_TMP" || [ "$(tail -c 1 "$P20_WS_TMP" | wc -l | tr -d ' ')" != 1 ] || [ -z "$(tail -n 1 "$P20_WS_TMP")" ]; then
    echo "p20 ws hook: fixing $f" >&2; rc=1
  fi
done
exit $rc
EOF
export P20_WS_TMP="$WORK/ws-hook.tmp"
chmod +x "$WORK/hooks-fail/pre-commit" "$WORK/hooks-fmt/pre-commit" "$WORK/hooks-ws/pre-commit"

# =====================================================================================================
# helpers
# =====================================================================================================

# cy <verb> [args] — run acfw-cycle from the repo root; sets CY_RC, CY_OUT (stdout), CY_ERR, CY_ALL.
# A watchdog kills a hung call so an unfinished engine fails the suite instead of wedging it.
cy() {
  CY_LAST="acfw-cycle $*"
  "$CYBASH" "$CYCLE" "$@" </dev/null >"$WORK/cy.out" 2>"$WORK/cy.err" &
  local pid=$! wd
  ( n=0
    while [ $n -lt "$CY_TIMEOUT" ]; do sleep 1; kill -0 "$pid" 2>/dev/null || exit 0; n=$((n+1)); done
    echo "p20 watchdog: killed after ${CY_TIMEOUT}s" >> "$WORK/cy.err"; kill -9 "$pid"
  ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid"; CY_RC=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  CY_OUT=$(cat "$WORK/cy.out"); CY_ERR=$(cat "$WORK/cy.err")
  CY_ALL=$(printf '%s\n%s' "$CY_OUT" "$CY_ERR")
}
cyc(){ pcopy_sync; CYCLE="$CYCLE_COPY" cy "$@"; }   # the same engine, from the counting plugin copy
nj(){ PATH="$NOJQ" cy "$@"; }           # the same engine, with jq hidden

rc_is(){ [ "${CY_RC:-x}" = "$1" ]; }
has(){ printf '%s\n' "$CY_ALL" | grep -qF -- "$1"; }
has_re(){ printf '%s\n' "$CY_ALL" | grep -qE -- "$1"; }
has_rei(){ printf '%s\n' "$CY_ALL" | grep -qiE -- "$1"; }
lacks_re(){ ! has_re "$1"; }
lacks_rei(){ ! has_rei "$1"; }
out_has_line(){ printf '%s\n' "$CY_OUT" | grep -qxF -- "$1"; }
line1(){ printf '%s\n' "$CY_OUT" | head -1; }
line1_is(){ [ "$(line1)" = "$1" ]; }
line1_re(){ line1 | grep -qE -- "$1"; }
lastl(){ printf '%s\n' "$CY_OUT" | awk 'NF{l=$0} END{print l}'; }
lastl_is(){ [ "$(lastl)" = "$1" ]; }
nextl(){ printf '%s\n' "$CY_OUT" | grep '^NEXT ' || true; }
next_count(){ nextl | grep -c . | tr -d ' '; }
next_is(){ [ "$(next_count)" = 1 ] && [ "$(nextl)" = "$1" ]; }
next_re(){ [ "$(next_count)" = 1 ] && nextl | grep -qE -- "$1"; }
next_not_re(){ [ "$(next_count)" = 1 ] && ! nextl | grep -qE -- "$1"; }
silent(){ [ -z "$CY_OUT" ] && [ -z "$CY_ERR" ]; }

# inv — the STATUS/NEED YOU/NEXT invariants every status output must hold: exactly one NEXT line and
# it is the last non-empty line; then either 'NEED YOU: nothing' or >=1 complete WHAT/RISK/REPLY card.
inv() {
  local w r p
  [ "$(next_count)" = 1 ] || return 1
  case "$(lastl)" in "NEXT "*) ;; *) return 1 ;; esac
  printf '%s\n' "$CY_OUT" | grep -q '^NEED YOU: nothing$' && return 0
  w=$(printf '%s\n' "$CY_OUT" | grep -c '^  WHAT ' || true)
  r=$(printf '%s\n' "$CY_OUT" | grep -c '^  RISK ' || true)
  p=$(printf '%s\n' "$CY_OUT" | grep -c '^  REPLY ' || true)
  [ "${w:-0}" -ge 1 ] && [ "$w" = "$r" ] && [ "$w" = "$p" ]
}
has_card(){ printf '%s\n' "$CY_OUT" | grep -q '^  WHAT '; }
card_names(){ printf '%s\n' "$CY_OUT" | grep -E '^  (WHAT|RISK|REPLY) ' | grep -qF -- "$1"; }
need_you_nothing(){ printf '%s\n' "$CY_OUT" | grep -q '^NEED YOU: nothing$'; }

# Coverage: the line(s) naming a deliverable carry its symbol, and none carries a contradicting one.
dlines(){ printf '%s\n' "$CY_OUT" | grep -E "(^|[^A-Za-z0-9])$1([^0-9]|\$)" | grep -v '^NEXT ' || true; }
cov_is() { # <Dn> <✓|◐|✗|?|cancelled>
  local l x; l=$(dlines "$1"); [ -n "$l" ] || return 1
  printf '%s\n' "$l" | grep -qF -- "$2" || return 1
  for x in ✓ ◐ ✗; do [ "$x" = "$2" ] && continue; printf '%s\n' "$l" | grep -qF -- "$x" && return 1; done
  return 0
}
cov_not(){ ! dlines "$1" | grep -qF -- "$2"; }

# Content hash as the contract defines it: CRLF->LF, trailing whitespace stripped, one final newline,
# then git's blob hash. Computed HERE, independently, so the card's content= is checked, not echoed.
# No fixture plan ends in blank lines, so whether "exactly one final newline" also collapses trailing
# blank lines never decides an assertion.
norm(){ awk '{ sub(/\r$/, ""); sub(/[ \t]+$/, ""); print }' "$1"; }
chash(){ norm "$1" | git hash-object --stdin; }
c12(){ chash "$1" | cut -c1-12; }

meta(){ sed -n "s/^- \*\*$1\*\*:[[:space:]]*//p" | head -1 | sed 's/[[:space:]]*$//'; }   # stdin record
hmeta(){ git show "HEAD:$1" 2>/dev/null | meta "$2"; }    # <repo path> <Field>
wmeta(){ meta "$2" < "$1"; }                              # <file> <Field>
has_empty_field(){ grep -qE "^- \*\*$2\*\*:[[:space:]]*\$" "$1"; }
section(){ awk -v h="## $1" '$0==h{f=1;next} f&&/^## /{f=0} f'; }
rows(){ section "$1" | grep '^|' | sed '1,2d'; }          # data rows (header + separator dropped)
cell(){ awk -F'|' -v n="$1" '{ c=$(n+1); gsub(/^[ \t]+|[ \t]+$/, "", c); print c }'; }
hrows(){ git show "HEAD:$1" 2>/dev/null | rows "$2"; }    # <repo path> <heading>
hrow(){ hrows "$1" "Plan Log" | sed -n "${2}p"; }         # <record path> <n> (1 = newest)
hevent(){ hrow "$1" "$2" | cell 2; }

cpaths(){ git diff-tree --no-commit-id --name-only -r --root "${1:-HEAD}" | sort | paste -sd' ' -; }
paths_are(){ [ "$(cpaths HEAD)" = "$(printf '%s\n' "$@" | sort | paste -sd' ' -)" ]; }
csubj(){ git log -1 --format=%s "${1:-HEAD}"; }
subj_is(){ [ "$(csubj)" = "$1" ]; }
trailer_is(){ git log -1 --format=%B HEAD | grep -qx "ACFW-Plan-Event: $1"; }
head_is(){ [ "$(git rev-parse HEAD)" = "$1" ]; }
same(){ cmp -s "$1" "$2"; }
untracked_folder(){ [ -z "$(git ls-files -- "docs/cycles/$1")" ]; }
# approved_since <H0> <record path> — an approval really landed: exit 0 is not enough (a do-nothing
# verb exits 0 too), so HEAD moved, its subject is an approve, and the newest Plan Log row says so.
approved_since(){ rc_is 0 && ! head_is "$1" && csubj | grep -q '^docs(plan): approve ' && [ "$(hevent "$2" 1)" = approved ]; }
# ac_matches <record path> <plan path> — HEAD's Approved Content is v1:<hex>, >=12 lowercase hex, and a
# prefix of the plan's normalized hash. An empty value must FAIL: a bare `case $h in "$ac"*)` with an
# empty $ac is a pattern of `*` and would pass anything.
ac_matches(){
  local ac full; ac=$(hmeta "$1" 'Approved Content'); full=$(chash "$2")
  case "$ac" in v1:*) ac=${ac#v1:} ;; *) return 1 ;; esac
  printf '%s' "$ac" | grep -qE '^[0-9a-f]{12,40}$' || return 1
  case "$full" in "$ac"*) return 0 ;; esac
  return 1
}

new_repo() { # <name> [--agents "<a b>"] [--no-mode] [--no-backlog]
  local name="$1" agents="python-engineer quality-reviewer" mode=default backlog=1 a s
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --agents) agents="$2"; shift 2 ;;
      --no-mode) mode=""; shift ;;
      --no-backlog) backlog=0; shift ;;
      *) echo "new_repo: bad arg $1" >&2; return 2 ;;
    esac
  done
  cd "$WORK" || return 1
  REPO="$WORK/$STORE_NAME-$name"; rm -rf "$REPO"
  git init -q -b trunk "$REPO" && cd "$REPO" || return 1
  git config user.email t@t; git config user.name t; git config core.hooksPath "$WORK/nohooks"
  printf '.acfwhip/run/\n.backlog/.acfw-run.json\n' > .gitignore
  if [ -n "$agents" ]; then
    mkdir -p .claude/agents
    for a in $agents; do printf '# %s\n' "$a" > ".claude/agents/$a.md"; done
  fi
  mkdir -p .acfwhip
  [ -n "$mode" ] && printf 'ACFW_INTEGRATION_MODE=%s\n' "$mode" > .acfwhip/config
  if [ "$STORE_NAME" = files ] && [ "$backlog" = 1 ]; then
    for s in draft pending in-progress completed in-review accepted rejected blocked archive; do
      mkdir -p ".backlog/$s"; : > ".backlog/$s/.gitkeep"
    done
  fi
  if [ "$STORE_NAME" = multica ]; then
    export MC_FAKE_STATE="$REPO.mc.json"; printf '{"issues":{},"seq":0}\n' > "$MC_FAKE_STATE"
  fi
  echo seed > seed
  git add -A && git commit -qm seed
  export ACFW_TRUNK_ROOT="$REPO"
  unset ACFW_TRUNK_BRANCH 2>/dev/null || true
  CY_LAST=""
}

use_store() {
  STORE_NAME="$1"; S="[$1]"
  if [ "$1" = multica ]; then
    export ACFW_STORE=multica ACFW_MULTICA_BIN="$FAKE"
  else
    unset ACFW_STORE ACFW_MULTICA_BIN MC_FAKE_STATE 2>/dev/null || true
  fi
  echo; echo "################################ store: $1 ################################"
}

task() { # <stem> <state> [deps] [rejections] [blocks] [worktree] — one task in the active store, created by the store
  local stem="$1" st="$2" deps="${3:-none}" rc="${4:-0}" bc="${5:-0}" wt="${6:-$1}" doc
  doc="$WORK/doc.$STORE_NAME.$stem.md"
  cat > "$doc" <<EOF
# Task: $stem

- **ID**: $stem
- **Status**: $st
- **Priority**: high
- **Assigned Agent**: python-engineer
- **Worktree**: $wt
- **PR Group**: $stem
- **Touches Globs**: src/$stem/**
- **Dependencies**: $deps
- **Rejection Count**: $rc
- **Block-Count**: $bc

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
EOF
  bash "$STORE_BIN" create --file "$doc" --stem "$stem" --folder "$st" >/dev/null 2>"$WORK/task.err" \
    || { bad "fixture: could not create $stem in $st: $(head -1 "$WORK/task.err")"; return 1; }
}

integrate() { # <stem> — land the LP-CAS ledger marker, the sole integration oracle
  local h mp
  h=$(printf '%s' "$1" | git hash-object --stdin)
  mp=".acfwhip/integrated/$(printf '%s' "$h" | cut -c1-2)/$1.json"
  mkdir -p "$(dirname "$mp")"; printf '{"key":"%s"}\n' "$1" > "$mp"
  git add -- "$mp" && git commit -q -m "integrate $1" -- "$mp"
}

focus(){ bash "$FOCUS_BIN" set --no-resolve --by task "$@" >/dev/null 2>&1 || bad "fixture: focus $*"; }
nofocus(){ rm -f "$REPO/.acfwhip/run/focus"; }

mkplan() { # <file> <H1> <N:text>... — a plan with numbered deliverables; no trailing blank line
  local f="$1" t="$2" it; shift 2
  {
    printf '# %s\n\n## Problem\n\nActor and trigger: a tester runs phase20.\n\n## Scope\n\nThe fixture.\n\n## Deliverables\n' "$t"
    printf '\n<!-- D-ids are permanent: new work takes the next unused number, gaps are fine; to drop one, keep its heading and archive its tasks. -->\n'
    for it in "$@"; do printf '\n### D%s: %s\n\n- AC%s.1: it works\n' "${it%%:*}" "${it#*:}" "${it%%:*}"; done
  } > "$f"
}

fx_init() { # <ID> <H1> <N:text>... — init a feature cycle from an imported plan; sets CID/CPLAN/CREC
  local id="$1" t="$2"; shift 2
  CID="$id"; CPLAN="docs/cycles/$id/plan.md"; CREC="docs/cycles/$id/record.md"
  mkplan "$WORK/src.$STORE_NAME.$id.md" "$t" "$@"
  cy init "$id" --from-file "$WORK/src.$STORE_NAME.$id.md" --kind feature --source "p20 fixture"
  rc_is 0 || bad "fixture: init $id"
}
fx_approve() { # <ID> — approve at the working-tree plan's content hash, as the card shows it
  cy approve "$1" --expect "$(c12 "docs/cycles/$1/plan.md")"
  rc_is 0 || bad "fixture: approve $1"
}
fx_cycle(){ fx_init "$@" && fx_approve "$1"; }
fx_record(){ local id="$1"; shift; cy record "$id" "$@"; rc_is 0 || bad "fixture: record $id $*"; }
unlock() { # <ID> — drop a decomposition lock this test took
  local l
  rm -f "$REPO/.acfwhip/run/cycle-$1.decomposing"
  l=$(line1 | sed -n 's/.*|lock=\([^|]*\)|.*/\1/p')
  case "$l" in *.decomposing) rm -f "$l" ;; esac
}
runlock_path(){ if [ "$STORE_NAME" = files ]; then echo "$REPO/.backlog/.acfw-run.json"; else echo "$REPO/.acfwhip/run/acfw-run.json"; fi; }

# =====================================================================================================
# scenarios
# =====================================================================================================

sc_setup() {
  echo "== $S setup rows: a missing prerequisite always answers /whip-init =="
  local d="$WORK/$STORE_NAME-nogit" saved="${ACFW_TRUNK_ROOT:-}"
  rm -rf "$d"; mkdir -p "$d"; cd "$d"
  unset ACFW_TRUNK_ROOT
  cy status
  [ -n "$saved" ] && export ACFW_TRUNK_ROOT="$saved"
  ck "$S not a git repo: status exits 0" rc_is 0
  ck "$S ...NEXT /whip-init --with-specialists" next_is "NEXT /whip-init --with-specialists"

  new_repo noagents --agents ""
  cy status
  ck "$S no .claude/agents: NEXT /whip-init --with-specialists" next_is "NEXT /whip-init --with-specialists"
  ck "$S ...status invariants hold" inv

  new_repo universal --agents "quality-reviewer task-engineer retro workflow-architect lean-architect"
  cy status
  ck "$S only universal agents: NEXT /whip-init --with-specialists" next_is "NEXT /whip-init --with-specialists"

  if [ "$STORE_NAME" = files ]; then
    new_repo nobacklog --no-backlog
    cy status
    ck "$S files store never initialised (no .backlog/): NEXT /whip-init --with-specialists" \
      next_is "NEXT /whip-init --with-specialists"
  fi

  new_repo ready
  cy status
  ck "$S control: a set-up repo does not answer /whip-init" next_not_re '^NEXT /whip-init'
}

sc_planless() {
  echo "== $S plan-less rows: idle, and a focus with no plan behind it =="
  new_repo idle
  cy status
  ck "$S idle: exit 0" rc_is 0
  ck "$S idle: NEXT /whip \"<goal>\"" next_re '^NEXT /whip "'
  ck "$S idle: NEED YOU: nothing" need_you_nothing
  ck "$S idle: invariants" inv

  task p-001-solo pending
  focus p-001-solo
  cy status
  ck "$S plan-less focus in flight: NEXT /go" next_is "NEXT /go"
  ck "$S ...invariants" inv

  calls_reset; cyc status --if-cycle
  ck "$S --if-cycle on a plan-less focus prints nothing" silent
  ck "$S ...exits 0" rc_is 0
  ck "$S ...with zero acfw-store calls" zero_calls
  calls_reset; cyc status --if-cycle --after-run complete --mode default
  ck "$S --if-cycle --after-run after a plan-less /go prints nothing (the DIRECT route stays byte-identical)" silent
  ck "$S ...with zero acfw-store calls" zero_calls
  nofocus; calls_reset; cyc status --if-cycle
  ck "$S --if-cycle with no focus at all prints nothing, zero calls" eval 'silent && zero_calls && rc_is 0'
}

sc_alpha() {
  echo "== $S init: the cycle folder is the record; the import source is never written =="
  new_repo alpha
  local ID=20260101-alpha P R SRC H0 C12 LOCK FROZEN before RUNLOCK C_NEW C_OLD REC_BEFORE
  P="docs/cycles/$ID/plan.md"; R="docs/cycles/$ID/record.md"
  SRC="docs/superpowers/plans/2026-01-01-alpha.md"
  mkdir -p "$(dirname "$SRC")"
  mkplan "$SRC" "Alpha feature" "1:Alpha" "2:Beta" "3:Gamma"
  git add -- "$SRC" && git commit -qm "a superpowers plan"
  cp "$SRC" "$WORK/alpha-src.orig"
  H0=$(git rev-parse HEAD)

  cy init "$ID" --from-file "$SRC" --kind feature --source "p20 import"
  ck "$S init exits 0" rc_is 0
  ck "$S INIT machine line" line1_is "INIT|$ID|docs/cycles/$ID/plan.md"
  ck "$S plan.md is a byte copy of the source" same "$P" "$SRC"
  ck "$S the source is never written" same "$SRC" "$WORK/alpha-src.orig"
  check "$S ...and git still sees it clean" "[ -z \"\$(git status --porcelain -- '$SRC')\" ]"
  ck "$S nothing committed (HEAD unchanged)" head_is "$H0"
  ck "$S the draft folder is untracked" untracked_folder "$ID"
  check "$S run state never shows in git status" "! git status --porcelain | grep -q 'acfwhip/run'"
  check "$S record.md exists" "[ -f '$R' ]"
  check "$S record.md opens with the self-describing header comment" "head -1 '$R' | grep -q '^<!-- acf-whip cycle record'"
  check "$S record.md H1 is 'Cycle Record: <plan H1>'" "grep -qx '# Cycle Record: Alpha feature' '$R'"
  check "$S Metadata: Format 1" "[ \"\$(wmeta '$R' Format)\" = 1 ]"
  check "$S Metadata: ID is the folder name" "[ \"\$(wmeta '$R' ID)\" = '$ID' ]"
  check "$S Metadata: Status draft" "[ \"\$(wmeta '$R' Status)\" = draft ]"
  check "$S Metadata: Kind feature" "[ \"\$(wmeta '$R' Kind)\" = feature ]"
  check "$S Metadata: Source carries the --source text" "wmeta '$R' Source | grep -qF 'p20 import'"
  check "$S ...plus the original's blob, which the engine appends: '<text> (blob <sha12>)'" \
    "[ \"\$(wmeta '$R' Source)\" = \"p20 import (blob \$(git hash-object '$SRC' | cut -c1-12))\" ]"
  check "$S the 3-way merge base is the normalized import, under gitignored run state" \
    "norm '$SRC' | cmp -s - '$REPO/.acfwhip/run/workbench/$ID/base.md' && git check-ignore -q '.acfwhip/run/workbench/$ID/base.md'"
  check "$S Metadata: Created By is the git email" "[ \"\$(wmeta '$R' 'Created By')\" = t@t ]"
  check "$S Metadata: Created At is 'YYYY-MM-DD HH:MM:SS UTC'" \
    "wmeta '$R' 'Created At' | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC\$'"
  check "$S Metadata: Approved By/At/Content and Retro are present but empty" \
    "has_empty_field '$R' 'Approved By' && has_empty_field '$R' 'Approved At' && has_empty_field '$R' 'Approved Content' && has_empty_field '$R' Retro"
  check "$S sections in order: Metadata, Tasks, Plan Log" \
    "[ \"\$(grep -E '^## ' '$R' | paste -sd, -)\" = '## Metadata,## Tasks,## Plan Log' ]"
  check "$S ## Tasks table header" "section Tasks < '$R' | grep -qx '| Deliverable | Tasks |'"
  check "$S ## Plan Log table header" "section 'Plan Log' < '$R' | grep -qx '| Date Time | Event | By | Content | Details |'"
  check "$S no task rows and no log rows before approval (drafting stays out of record.md)" \
    "[ -z \"\$(rows Tasks < '$R')\" ] && [ -z \"\$(rows 'Plan Log' < '$R')\" ]"
  PEND="$REPO/.acfwhip/run/cycle/$ID/pending.log"
  check "$S the drafted event is pending, one sanitized line" \
    "[ \"\$(grep -c . '$PEND' 2>/dev/null)\" = 1 ] && grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\\|drafted\\|t@t\\|[^|]*\\|[^|]*\$' '$PEND'"

  cp "$P" "$WORK/alpha-plan.before"
  cy init "$ID" --from-file "$SRC" --kind feature --source again
  ck "$S init into an existing folder refuses (3)" rc_is 3
  ck "$S ...and leaves plan.md alone" same "$P" "$WORK/alpha-plan.before"
  before=$(ls docs/cycles | paste -sd, -)
  cy init Bad_Slug --kind feature --source x
  ck "$S a bad slug refuses (3)" rc_is 3
  check "$S ...creating nothing" "[ \"\$(ls docs/cycles | paste -sd, -)\" = '$before' ]"
  cy init 20260101-nokind --source x
  ck "$S init without --kind is a usage error (2)" rc_is 2
  cy init 20260101-badkind --kind epic --source x
  ck "$S init with an unknown --kind is a usage error (2)" rc_is 2
  cy frobnicate
  ck "$S an unknown verb is a usage error (2)" rc_is 2
  cy
  ck "$S no verb is a usage error (2)" rc_is 2

  echo "== $S approve: one yes, bound to the card's content hash =="
  C12=$(c12 "$P")
  sleep 1
  printf '%s|pulled|t@t|-|from dir\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" >> "$PEND"   # as acfw-spec would
  sleep 1
  cy status "$ID"
  ck "$S the approval card prints content=<c12> of the plan" out_has_line "  content=$C12"
  ck "$S ...and the exact REPLY line" out_has_line "  REPLY yes: approve, then start /task --plan in the background (sets your /go focus)"
  ck "$S ...status invariants" inv
  H0=$(git rev-parse HEAD)
  cy approve "$ID" --expect "$C12"
  ck "$S approve exits 0" rc_is 0
  ck "$S approve ends with NEXT /task --plan <plan>" lastl_is "NEXT /task --plan docs/cycles/$ID/plan.md"
  check "$S exactly one commit" "[ \"\$(git rev-list --count $H0..HEAD)\" = 1 ]"
  ck "$S subject: docs(plan): approve alpha" subj_is "docs(plan): approve alpha"
  ck "$S trailer: ACFW-Plan-Event: approved <c12> <ID>" trailer_is "approved $C12 $ID"
  ck "$S the commit carries exactly plan.md and record.md" paths_are "$P" "$R"
  check "$S no AI attribution in the commit" "! git log -1 --format=%B | grep -qiE 'co-authored-by: *claude|claude-session|generated with'"
  check "$S HEAD Status approved" "[ \"\$(hmeta '$R' Status)\" = approved ]"
  check "$S HEAD Approved By is the git email" "[ \"\$(hmeta '$R' 'Approved By')\" = t@t ]"
  check "$S HEAD Approved At is 'YYYY-MM-DD HH:MM:SS UTC'" \
    "hmeta '$R' 'Approved At' | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC\$'"
  ck "$S HEAD Approved Content is v1:<hex>, a >=12-char prefix of the normalized plan hash" ac_matches "$R" "$P"
  check "$S Created At survives approval" "hmeta '$R' 'Created At' | grep -q UTC"
  check "$S Plan Log has the three folded events" "[ \"\$(hrows '$R' 'Plan Log' | grep -c .)\" = 3 ]"
  check "$S newest first: approved, then pulled, then drafted" \
    "[ \"\$(hevent '$R' 1),\$(hevent '$R' 2),\$(hevent '$R' 3)\" = 'approved,pulled,drafted' ]"
  check "$S the approved row: By t@t, Content names c12" \
    "[ \"\$(hrow '$R' 1 | cell 3)\" = t@t ] && hrow '$R' 1 | cell 4 | grep -qF '$C12'"
  check "$S the folded pulled row keeps its cells" \
    "[ \"\$(hrow '$R' 2 | cell 3)\" = t@t ] && [ \"\$(hrow '$R' 2 | cell 5)\" = 'from dir' ]"
  check "$S every Plan Log row has exactly five cells" \
    "! hrows '$R' 'Plan Log' | awk -F'|' 'NF != 7 { bad=1 } END { exit !bad }'"
  check "$S pending.log is folded away" "[ ! -s '$PEND' ]"
  ck "$S plan.md bytes unchanged by approval" same "$P" "$WORK/alpha-plan.before"
  check "$S the cycle folder is clean in git" "[ -z \"\$(git status --porcelain -- docs/cycles)\" ]"

  cy status
  ck "$S an approved cycle of mine with no tasks: bare status says NEXT /task --plan" \
    next_is "NEXT /task --plan docs/cycles/$ID/plan.md"
  ck "$S ...invariants" inv

  echo "== $S check: one machine line, a frozen HEAD copy, a lock that is evidence =="
  LOCK="$REPO/.acfwhip/run/cycle-$ID.decomposing"
  FROZEN="$REPO/.acfwhip/run/cycle/$ID/$C12.md"
  for form in "$ID" "docs/cycles/$ID" "docs/cycles/$ID/" "docs/cycles/$ID/plan.md" "docs/cycles/$ID/record.md" "$REPO/docs/cycles/$ID/plan.md"; do
    cy check "$form"
    ck "$S check accepts <plan> as '$form'" line1_re "^CHECK\\|go\\|cycle=$ID\\|"
    unlock "$ID"
  done
  cy check "$ID"
  ck "$S check exits 0" rc_is 0
  ck "$S CHECK|go line, every field" line1_is \
    "CHECK|go|cycle=$ID|content=$C12|frozen=$FROZEN|lock=$LOCK|uncovered=D1,D2,D3|known=D1,D2,D3|coverage=on|kind=feature"
  check "$S the frozen copy is HEAD:plan.md byte for byte" "git show 'HEAD:$P' | cmp -s - '$FROZEN'"
  check "$S the lock holds ts=<epoch>" "head -1 '$LOCK' 2>/dev/null | grep -qE '^ts=[0-9]+\$'"
  cp "$LOCK" "$WORK/lock.before" 2>/dev/null
  cy check "$ID"
  ck "$S a second check refuses: lock held (7)" rc_is 7
  ck "$S ...CHECK|refuse line with code=7" line1_re "^CHECK\\|refuse\\|cycle=$ID\\|code=7\\|reason=.+"
  ck "$S ...naming the one-command override" has "rm $LOCK"
  ck "$S ...and leaving the other run's lock intact" same "$LOCK" "$WORK/lock.before"
  cy status "$ID"
  ck "$S status shows the held lock with its rm override" has "rm $LOCK"
  rm -f "$LOCK"
  cy check "$ID"
  ck "$S after the rm, check goes again" line1_re "^CHECK\\|go\\|cycle=$ID\\|"
  printf 'ts=%s\n' "$(( $(date -u +%s) - 7200 ))" > "$LOCK"; touch -t 202001010000 "$LOCK"
  cy check "$ID"
  ck "$S a stale lock (>30 min) does not refuse" line1_re "^CHECK\\|go\\|cycle=$ID\\|"
  unlock "$ID"
  RUNLOCK=$(runlock_path); mkdir -p "$(dirname "$RUNLOCK")"; printf '{"pid":1}\n' > "$RUNLOCK"
  cy check "$ID"
  ck "$S a fresh /go run lock refuses check (7)" rc_is 7
  check "$S ...without taking a decomposition lock" "[ ! -e '$LOCK' ]"
  unlock "$ID"
  cy status "$ID"
  ck "$S status: wait: /go is running" has "wait: /go is running"
  # A dead /go leaves a fresh lock; the card is the way out (a lock is evidence, not liveness).
  ck "$S ...with a NEED YOU card for the run lock" has "  WHAT a /go run touched its run lock"
  ck "$S ...naming its one-command override" has "rm $RUNLOCK"
  rm -f "$RUNLOCK"

  echo "== $S /task --plan decomposes the frozen HEAD copy, never the working tree =="
  printf '\n### D4: Extra, unapproved\n\n- AC4.1: it works\n' >> "$P"
  cy check "$ID"
  ck "$S an amended working tree still checks against HEAD" line1_is \
    "CHECK|go|cycle=$ID|content=$C12|frozen=$FROZEN|lock=$LOCK|uncovered=D1,D2,D3|known=D1,D2,D3|coverage=on|kind=feature"
  check "$S the frozen copy is the approved text, not the edit" "git show 'HEAD:$P' | cmp -s - '$FROZEN' && ! grep -q 'D4' '$FROZEN'"
  printf '\nedited mid-run\n' >> "$P"
  check "$S an edit made mid-run does not reach the frozen copy" "git show 'HEAD:$P' | cmp -s - '$FROZEN'"
  unlock "$ID"
  cy status "$ID"
  ck "$S status: amended since approval" has "amended since approval"
  git checkout -q -- "$P"

  echo "== $S record: record-first, its own pathspec commit, idempotent =="
  printf 'unrelated\n' > other.txt; git add other.txt
  printf 'seed, edited\n' > seed
  printf '\nan unapproved body edit\n' >> "$P"
  H0=$(git rev-parse HEAD)
  cy record "$ID" api-001-a=D1 api-002-b=D1,D2 api-003-c=D3
  ck "$S record exits 0" rc_is 0
  ck "$S RECORD|ok|cycle=<ID>|tasks=3" line1_is "RECORD|ok|cycle=$ID|tasks=3"
  check "$S exactly one commit" "[ \"\$(git rev-list --count $H0..HEAD)\" = 1 ]"
  ck "$S subject: docs(plan): decompose alpha" subj_is "docs(plan): decompose alpha"
  ck "$S trailer: ACFW-Plan-Event: decomposed <c12> <ID>" trailer_is "decomposed $C12 $ID"
  ck "$S the commit carries record.md ONLY (dirty plan, staged file and dirty seed stay out)" paths_are "$R"
  check "$S the dirty plan.md edit is still in the working tree" "git diff -- '$P' | grep -q 'an unapproved body edit'"
  check "$S the unrelated staged file is still staged" "git diff --cached --name-only | grep -qx other.txt"
  check "$S the unrelated edit is still a working-tree change" "git diff --name-only | grep -qx seed"
  check "$S ## Tasks: one row per deliverable, D-order, stems sorted" \
    "[ \"\$(hrows '$R' Tasks | paste -sd'#' -)\" = '| D1 | api-001-a, api-002-b |#| D2 | api-002-b |#| D3 | api-003-c |' ]"
  check "$S HEAD Status decomposed" "[ \"\$(hmeta '$R' Status)\" = decomposed ]"
  check "$S newest row: decomposed, Content c12" "[ \"\$(hevent '$R' 1)\" = decomposed ] && hrow '$R' 1 | cell 4 | grep -qF '$C12'"
  check "$S older rows kept below it" "[ \"\$(hrows '$R' 'Plan Log' | grep -c .)\" = 4 ]"
  H0=$(git rev-parse HEAD)
  cy record "$ID" api-003-c=D3 api-001-a=D1 api-002-b=D2,D1
  ck "$S the same mapping in another order is a no-op" line1_is "RECORD|noop|cycle=$ID"
  ck "$S ...exit 0" rc_is 0
  ck "$S ...and commits nothing" head_is "$H0"
  cy record "$ID" api-004-d=D2 api-000-z=D1
  ck "$S a new mapping unions with HEAD's table" line1_re "^RECORD\\|ok\\|cycle=$ID\\|tasks=[0-9]+\$"
  check "$S ...rows rebuilt sorted and unique" \
    "[ \"\$(hrows '$R' Tasks | paste -sd'#' -)\" = '| D1 | api-000-z, api-001-a, api-002-b |#| D2 | api-002-b, api-004-d |#| D3 | api-003-c |' ]"
  H0=$(git rev-parse HEAD)
  for bs in 'bad,stem' 'bad|stem' 'bad stem' '-leading-dash'; do
    cy record "$ID" "$bs=D1"
    check "$S a stem that would corrupt the ## Tasks table ('$bs') is refused (2 or 3)" "rc_is 2 || rc_is 3"
    ck "$S ...committing nothing" head_is "$H0"
  done
  git checkout -q -- "$P" seed; git reset -q -- other.txt; rm -f other.txt
  cy check "$ID"
  ck "$S every deliverable covered: CHECK|noop|...|reason=covered" line1_is "CHECK|noop|cycle=$ID|reason=covered"
  ck "$S ...exit 0" rc_is 0
  check "$S ...and no lock is taken on a no-op" "[ ! -e '$LOCK' ]"

  echo "== $S rule 11: approval binds to the card (--expect) =="
  C_OLD="$C12"
  mkplan "$P" "Alpha feature" "1:Alpha, better" "2:Beta" "3:Gamma"
  C_NEW=$(c12 "$P")
  cp "$R" "$WORK/rec.before"; cp "$P" "$WORK/plan.before"; H0=$(git rev-parse HEAD)
  for exp in "" "$(printf '%s' "$C_NEW" | cut -c1-11)" "$(chash "$P" | tr 'a-f' 'A-F')" "$C_OLD" "zzzzzzzzzzzz"; do
    if [ -z "$exp" ]; then cy approve "$ID"; lab="missing"; else cy approve "$ID" --expect "$exp"; lab="'$exp'"; fi
    ck "$S --expect $lab refuses (9)" rc_is 9
    ck "$S ...HEAD unchanged" head_is "$H0"
    ck "$S ...record.md unchanged" same "$R" "$WORK/rec.before"
    ck "$S ...plan.md unchanged" same "$P" "$WORK/plan.before"
    ck "$S ...and prints no copyable approve command" lacks_re 'approve.*--expect[ =]*[0-9a-f]{12}'
  done
  cy approve "$ID" --expect "$(chash "$P")"
  ck "$S the full 40-hex hash is a valid --expect (prefix match)" approved_since "$H0" "$R"
  C12=$C_NEW

  echo "== $S rule 10: D-ids are permanent once a task names them =="
  mkplan "$P" "Alpha feature" "1:Alpha, better" "2:New work" "3:Beta" "4:Gamma"
  cp "$R" "$WORK/rec.before"; H0=$(git rev-parse HEAD)
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S inserting a new D2 over recorded D1-D3 refuses (8)" rc_is 8
  ck "$S ...saying D-ids are never renumbered" has "D-ids are never renumbered"
  ck "$S ...HEAD unchanged" head_is "$H0"
  ck "$S ...record.md unchanged" same "$R" "$WORK/rec.before"
  cy approve "$ID" --expect "$C12"
  ck "$S rule 11 runs before rule 10 (stale --expect on a renumbered plan is 9)" rc_is 9
  mkplan "$P" "Alpha feature" "1:Alpha, better" "2:Beta"
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S dropping recorded D3 refuses (8)" rc_is 8
  mkplan "$P" "Alpha feature" "1:Alpha, better" "2:Beta, reworded in place" "3:Gamma"
  REC_BEFORE=$(hrows "$R" Tasks)
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S rewording D2 in place approves" approved_since "$H0" "$R"
  ck "$S ...Approved Content follows the new text" ac_matches "$R" "$P"
  check "$S ...newest row approved with the new c12" "[ \"\$(hevent '$R' 1)\" = approved ] && hrow '$R' 1 | cell 4 | grep -qF '$(c12 "$P")'"
  check "$S ...## Tasks untouched" "[ \"\$(hrows '$R' Tasks)\" = \"\$REC_BEFORE\" ]"
  mkplan "$P" "Alpha feature" "1:Alpha, better" "3:Gamma" "2:Beta, reworded in place"
  H0=$(git rev-parse HEAD)
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S reordering deliverables approves" approved_since "$H0" "$R"
  mkplan "$P" "Alpha feature" "1:Alpha, better" "2:Beta, reworded in place" "3:Gamma" "4:Delta"
  H0=$(git rev-parse HEAD)
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S a new id (D4) approves" approved_since "$H0" "$R"
  C12=$(c12 "$P")
  cy check "$ID"
  ck "$S ...and check then sees D4 as the only uncovered deliverable" \
    line1_re "^CHECK\\|go\\|cycle=$ID\\|content=$C12\\|.*\\|uncovered=D4\\|known=D1,D2,D3,D4\\|coverage=on\\|kind=feature\$"
  unlock "$ID"

  echo "== $S the gate is read from HEAD: three matching facts, or no approval =="
  local G; G=$(git rev-parse HEAD)
  sed "s/^- \*\*Approved Content\*\*:.*/- **Approved Content**: v1:000000000000/" "$R" > "$R.t" && mv "$R.t" "$R"
  git commit -qm "hand edit" -- "$R"
  check "$S (fixture: HEAD's Approved Content really is forged)" "[ \"\$(hmeta '$R' 'Approved Content')\" = v1:000000000000 ]"
  cy check "$ID"
  ck "$S Approved Content that does not match the plan hash: check refuses (6)" rc_is 6
  ck "$S ...CHECK|refuse line with code=6" line1_re "^CHECK\\|refuse\\|cycle=$ID\\|code=6\\|reason=.+"
  check "$S ...taking no lock" "[ ! -e '$LOCK' ]"
  cy status "$ID"
  ck "$S ...and status raises a NEED YOU card" has_card
  git reset -q --hard "$G"
  awk -v c="$C12" 'BEGIN{done=0} /^\| / && !done && $0 ~ ("\\| approved \\|") { sub(c, "ffffffffffff"); done=1 } { print }' "$R" > "$R.t" && mv "$R.t" "$R"
  git commit -qm "hand edit row" -- "$R"
  check "$S (fixture: the newest approved row really is forged)" "hrows '$R' 'Plan Log' | grep -q ffffffffffff"
  cy check "$ID"
  ck "$S a hand-edited newest approved row: check refuses (6)" rc_is 6
  git reset -q --hard "$G"
  printf '\nsneaked in after approval\n' >> "$P"; git commit -qm "unapproved body" -- "$P"
  cy check "$ID"
  ck "$S a committed plan.md edit nobody approved: check refuses (6)" rc_is 6
  git reset -q --hard "$G"
  cy check "$ID"
  ck "$S control: the untampered HEAD checks go" line1_re "^CHECK\\|go\\|cycle=$ID\\|"
  unlock "$ID"
  fx_init 20260101-forged "Forged" "1:One"
  local FC; FC=$(c12 docs/cycles/20260101-forged/plan.md)
  sed -e "s/^- \*\*Status\*\*:.*/- **Status**: approved/" -e "s/^- \*\*Approved Content\*\*:.*/- **Approved Content**: v1:$FC/" \
    docs/cycles/20260101-forged/record.md > "$WORK/forged" && mv "$WORK/forged" docs/cycles/20260101-forged/record.md
  printf '| 2026-01-01 00:00:00 | approved | t@t | %s | forged |\n' "$FC" >> docs/cycles/20260101-forged/record.md
  cy check 20260101-forged
  ck "$S an approval that exists only in the working tree is never honoured (6)" rc_is 6
  rm -rf docs/cycles/20260101-forged "$REPO/.acfwhip/run/cycle/20260101-forged"

  echo "== $S fail closed: a Format newer than the script =="
  sed 's/^- \*\*Format\*\*:.*/- **Format**: 2/' "$R" > "$R.t" && mv "$R.t" "$R"
  git commit -qm "format 2" -- "$R"
  cy check "$ID"
  ck "$S check refuses a newer Format (12)" rc_is 12
  printf '\n### D5: Epsilon\n\n- AC5.1: it works\n' >> "$P"
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S approve refuses a newer Format (12)" rc_is 12
  git reset -q --hard "$G"
}

sc_notcycles() {
  echo "== $S ownership is by content: only a stamped folder is a cycle =="
  new_repo own
  task p-900-live pending
  mkdir -p docs/cycles/notes docs/cycles/20260101-nofmt docs/cycles/20260102-wrongid
  printf '# notes\n' > docs/cycles/README.md
  printf '# scratch\n' > docs/cycles/notes/x.md
  printf '# Cycle Record: x\n## Metadata\n- **Status**: approved\n## Tasks\n| Deliverable | Tasks |\n|---|---|\n| D1 | p-900-live |\n' \
    > docs/cycles/20260101-nofmt/record.md
  printf '# plan\n' > docs/cycles/20260101-nofmt/plan.md
  printf '# Cycle Record: y\n## Metadata\n- **Format**: 1\n- **ID**: 20260102-other\n- **Status**: approved\n## Tasks\n| Deliverable | Tasks |\n|---|---|\n| D1 | p-900-live |\n' \
    > docs/cycles/20260102-wrongid/record.md
  printf '# plan\n' > docs/cycles/20260102-wrongid/plan.md
  printf -- '---\ntitle: feat\ntype: feat\n---\n# Feature plan (Compound Engineering)\n## Tasks\n| Deliverable | Tasks |\n|---|---|\n| D1 | p-900-live |\n' \
    > docs/cycles/2026-01-03-feat-plan.md
  mkdir -p docs/other; printf '# plan\n' > docs/other/plan.md
  git add docs && git commit -qm "not cycles"
  focus p-900-live
  cy status
  ck "$S folders without Format/ID, a wrong ID and a CE file are ignored: a plan-less NEXT /go" next_is "NEXT /go"
  ck "$S ...invariants" inv
  calls_reset; cyc status --if-cycle
  ck "$S --if-cycle sees no cycle there: prints nothing, zero calls" eval 'silent && zero_calls'
  for p in docs/cycles/20260101-nofmt docs/cycles/20260102-wrongid docs/cycles/notes docs/cycles/2026-01-03-feat-plan.md docs/other/plan.md 20269999-nosuch; do
    cy check "$p"
    ck "$S check '$p' is not a cycle (3)" rc_is 3
  done
}

sc_trailers() {
  echo "== $S the trailer is audit, never the gate: squash and shallow give a WARN =="
  new_repo trl
  local ID=20260101-trl P R C12 SH TIP
  fx_cycle "$ID" "Trailers" "1:One" "2:Two"; P="docs/cycles/$ID/plan.md"; R="docs/cycles/$ID/record.md"; C12=$(c12 "$P")
  cy check "$ID"
  ck "$S control: an intact trailer gives no trailer WARN" lacks_rei 'warn.*(trailer|squash|shallow)'
  unlock "$ID"
  git commit -q --amend -m "docs(plan): approve trl" -m "    ACFW-Plan-Event: approved $C12 $ID"
  cy check "$ID"
  ck "$S an indented trailer (a squash merge body) still checks go" line1_re "^CHECK\\|go\\|cycle=$ID\\|"
  ck "$S ...and is still found (the lookup allows leading whitespace): no trailer WARN" lacks_rei 'warn.*(trailer|squash)'
  unlock "$ID"
  git commit -q --amend -m "docs(plan): approve trl (squashed, trailer dropped)"
  cy check "$ID"
  ck "$S a dropped trailer still checks go" line1_re "^CHECK\\|go\\|cycle=$ID\\|"
  ck "$S ...with a WARN" has_rei 'warn.*(trailer|squash)'
  unlock "$ID"

  fx_record "$ID" trl-001=D1
  echo later > later.txt; git add later.txt; git commit -qm "later work"
  SH="$WORK/$STORE_NAME-trl-shallow"; rm -rf "$SH"
  git clone -q --depth 1 "file://$REPO" "$SH" 2>/dev/null
  cd "$SH"; git config user.email t@t; git config user.name t; git config core.hooksPath "$WORK/nohooks"
  export ACFW_TRUNK_ROOT="$SH"; REPO="$SH"
  check "$S the clone really is shallow" "[ \"\$(git rev-parse --is-shallow-repository)\" = true ]"
  cy check "$ID"
  ck "$S a shallow clone checks go (never refuses on missing history)" line1_re "^CHECK\\|go\\|cycle=$ID\\|.*\\|uncovered=D2\\|"
  ck "$S ...with a WARN" has_rei 'warn.*(trailer|squash|shallow)'
  unlock "$ID"

  # Missing approved body: the approved blob lives only in commits outside the shallow boundary, and
  # the tip holds an unapproved renumbering. Rule 10 cannot find the last approved body, so it must
  # WARN and skip, never refuse (INTERFACES, ambiguity 2).
  cd "$WORK/$STORE_NAME-trl"; export ACFW_TRUNK_ROOT="$WORK/$STORE_NAME-trl"; REPO="$ACFW_TRUNK_ROOT"
  mkplan "$P" "Trailers" "1:One" "2:Inserted" "3:Two"
  git commit -qm "unapproved renumbering" -- "$P"
  echo more > more.txt; git add more.txt; git commit -qm "more"
  rm -rf "$SH"; git clone -q --depth 1 "file://$REPO" "$SH" 2>/dev/null
  cd "$SH"; git config user.email t@t; git config user.name t; git config core.hooksPath "$WORK/nohooks"
  export ACFW_TRUNK_ROOT="$SH"; REPO="$SH"
  H0=$(git rev-parse HEAD)
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S rule 10 with the approved body out of history: approve proceeds (0)" approved_since "$H0" "$R"
  ck "$S ...and WARNs that it could not check" has_re 'WARN'
  cd "$WORK"; export ACFW_TRUNK_ROOT="$WORK/$STORE_NAME-trl"; REPO="$ACFW_TRUNK_ROOT"; cd "$REPO"
}

sc_txn() {
  echo "== $S transactional commits: a failed commit restores record.md byte for byte =="
  new_repo txn
  local ID=20260101-txn P R H0 C
  fx_init "$ID" "Txn" "1:One"; P="docs/cycles/$ID/plan.md"; R="docs/cycles/$ID/record.md"
  cp "$R" "$WORK/txn.rec"; cp "$P" "$WORK/txn.plan"
  cp "$REPO/.acfwhip/run/cycle/$ID/pending.log" "$WORK/txn.pend" 2>/dev/null || : > "$WORK/txn.pend"
  H0=$(git rev-parse HEAD)
  git config core.hooksPath "$WORK/hooks-fail"
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S approve whose commit a hook refuses exits 10" rc_is 10
  ck "$S ...record.md restored byte for byte" same "$R" "$WORK/txn.rec"
  ck "$S ...plan.md untouched" same "$P" "$WORK/txn.plan"
  ck "$S ...nothing committed" head_is "$H0"
  ck "$S ...the draft is still untracked (no intent-to-add left in the index)" untracked_folder "$ID"
  ck "$S ...the pending events survive for the retry" same "$REPO/.acfwhip/run/cycle/$ID/pending.log" "$WORK/txn.pend"
  git config core.hooksPath "$WORK/nohooks"
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S the retry after the hook is fixed approves" approved_since "$H0" "$R"
  H0=$(git rev-parse HEAD)
  git config core.hooksPath "$WORK/hooks-fail"
  cy record "$ID" txn-001=D1
  ck "$S record whose commit a hook refuses exits 10" rc_is 10
  check "$S ...record.md is HEAD's bytes again" "git diff --quiet -- '$R'"
  ck "$S ...nothing committed" head_is "$H0"
  git config core.hooksPath "$WORK/nohooks"

  echo "== $S approve normalizes plan.md in place, so the shipped whitespace hooks never fail it =="
  new_repo ws
  ID=20260101-ws; P="docs/cycles/$ID/plan.md"; R="docs/cycles/$ID/record.md"
  # A markdown hard break (two trailing blanks), a CRLF line and no final newline: each one alone makes
  # trailing-whitespace or end-of-file-fixer fail a commit.
  printf '# Ws  \n\nA hard break  \nnext line\r\n\n## Deliverables\n\n### D1: One\n\n- AC1.1: ok' > "$WORK/ws.md"
  cy init "$ID" --from-file "$WORK/ws.md" --kind feature --source x
  cp "$P" "$WORK/ws.orig"; C=$(c12 "$P"); H0=$(git rev-parse HEAD)
  git config core.hooksPath "$WORK/hooks-ws"
  printf 'x  \n' > ws-probe.txt; git add ws-probe.txt
  check "$S (fixture: the hook really refuses a trailing blank)" "! git commit -qm probe -- ws-probe.txt 2>/dev/null"
  git reset -q -- ws-probe.txt; rm -f ws-probe.txt
  git config core.hooksPath "$WORK/hooks-fail"
  cy approve "$ID" --expect "$C"
  ck "$S a commit that fails for another reason still exits 10" rc_is 10
  ck "$S ...and plan.md is back to the bytes it had (nothing was approved)" same "$P" "$WORK/ws.orig"
  git config core.hooksPath "$WORK/hooks-ws"
  cy approve "$ID" --expect "$C"
  ck "$S under the whitespace hooks, approve goes on the first try" approved_since "$H0" "$R"
  ck "$S ...at the content the card showed" eval '[ "$(line1)" = "APPROVE|ok|cycle=$ID|content=$C|commit=$(git rev-parse --short=12 HEAD)" ]'
  check "$S ...plan.md now holds its normalized bytes, in the working tree and at HEAD" \
    "norm '$WORK/ws.orig' | cmp -s - '$P' && git show 'HEAD:$P' | cmp -s - '$P'"
  cy record "$ID" ws-001=D1
  ck "$S record.md passes the same hooks (record exits 0)" rc_is 0

  echo "== $S note and close normalize the retro's outputs, so a lesson never fails the whitespace hooks =="
  # The shipped configs exclude docs/cycles/ but not docs/acf/lessons/, and a lesson is an agent file
  # written moments before: a hard break or a missing final newline made close exit 10 once.
  local L1=docs/acf/lessons/keep-it.md L2=docs/acf/lessons/say-why.md RT="docs/cycles/$ID/retro.md"
  mkdir -p docs/acf/lessons
  cy retro-begin "$ID"
  printf '# Say why\n\n**Rule**: say why.  \nno final newline' > "$L2"
  printf '# Mid retro  \r\n\nStill running.' > "$RT"
  cp "$L2" "$WORK/ws-l2.orig"
  cy note "$ID" retro.md --lesson "$L2"
  ck "$S under the whitespace hooks, note with such a lesson goes on the first try" eval 'rc_is 0 && lastl | grep -q "^NOTE|ok|"'
  check "$S ...the lesson is committed normalized" "norm '$WORK/ws-l2.orig' | cmp -s - '$L2' && git show 'HEAD:$L2' | cmp -s - '$L2'"
  cy retro-begin "$ID"
  printf '# Keep it\n\n**Rule**: keep it.  \nA hard break  \nno final newline' > "$L1"
  printf '# Retro  \r\n\nIt went fine.' > "$RT"
  cp "$L1" "$WORK/ws-l1.orig"; cp "$RT" "$WORK/ws-retro.orig"; H0=$(git rev-parse HEAD)
  git config core.hooksPath "$WORK/hooks-fail"
  cy close "$ID" retro.md --lesson "$L1"
  ck "$S a close that fails for another reason exits 10" rc_is 10
  ck "$S ...the lesson is back to the bytes the agent wrote" same "$L1" "$WORK/ws-l1.orig"
  ck "$S ...and so is retro.md" same "$RT" "$WORK/ws-retro.orig"
  ck "$S ...nothing committed" head_is "$H0"
  git config core.hooksPath "$WORK/hooks-ws"
  cy close "$ID" retro.md --lesson "$L1"
  ck "$S under the whitespace hooks, close with such a lesson goes on the first try" eval 'rc_is 0 && lastl | grep -q "^CLOSE|ok|"'
  check "$S ...the lesson and retro.md are committed normalized" \
    "norm '$WORK/ws-l1.orig' | cmp -s - '$L1' && git show 'HEAD:$L1' | cmp -s - '$L1' && norm '$WORK/ws-retro.orig' | cmp -s - '$RT' && git show 'HEAD:$RT' | cmp -s - '$RT'"
  git config core.hooksPath "$WORK/nohooks"

  echo "== $S the add -N retry survives a concurrent reset --mixed (land()) =="
  new_repo ita
  fx_init 20260101-ita "Ita" "1:One"
  rm -f "$WORK/reset-once"
  PATH="$WORK/gitwrap:$PATH" P20_RESET_ONCE="$WORK/reset-once" cy approve 20260101-ita --expect "$(c12 docs/cycles/20260101-ita/plan.md)"
  check "$S the reset really fired between add -N and commit" "[ -e '$WORK/reset-once' ]"
  ck "$S approve still commits" approved_since "$(git rev-parse HEAD~1 2>/dev/null)" docs/cycles/20260101-ita/record.md
  ck "$S ...with both files" paths_are docs/cycles/20260101-ita/plan.md docs/cycles/20260101-ita/record.md

  echo "== $S a hook that rewrites a committed file fails loudly (11) =="
  new_repo fmt
  fx_init 20260101-fmt "Fmt" "1:One"
  git config core.hooksPath "$WORK/hooks-fmt"
  cy approve 20260101-fmt --expect "$(c12 docs/cycles/20260101-fmt/plan.md)"
  check "$S (fixture: the formatter hook really rewrote the plan)" "grep -q 'reformatted by a hook' docs/cycles/20260101-fmt/plan.md"
  ck "$S post-commit hash verify mismatch exits 11" rc_is 11
  check "$S ...and says so" "[ -n \"\$CY_ERR\$CY_OUT\" ]"
  git config core.hooksPath "$WORK/nohooks"
  # The commit LANDED with the pending rows folded in, so they must leave pending.log: a re-approve
  # would fold them twice, and the duplicate breaks newest-first.
  check "$S ...the folded pending events left pending.log (the commit landed)" "! grep -q . '$REPO/.acfwhip/run/cycle/20260101-fmt/pending.log' 2>/dev/null"
  cy approve 20260101-fmt --expect "$(c12 docs/cycles/20260101-fmt/plan.md)"
  ck "$S re-approving the hook's bytes goes" rc_is 0
  check "$S ...and the drafted event is in the Plan Log exactly once" \
    "[ \"\$(hrows docs/cycles/20260101-fmt/record.md 'Plan Log' | cell 2 | grep -cx drafted)\" = 1 ]"

  echo "== $S a hook that STAGES files fails loudly too (11): a plan commit carries only its own paths =="
  new_repo addu
  mkdir -p "$WORK/hooks-addu"
  printf '#!/bin/sh\ngit add -u\nexit 0\n' > "$WORK/hooks-addu/pre-commit"; chmod +x "$WORK/hooks-addu/pre-commit"
  fx_init 20260101-addu "Addu" "1:One"
  echo "an unrelated edit of the user's" >> seed
  git config core.hooksPath "$WORK/hooks-addu"
  cy approve 20260101-addu --expect "$(c12 docs/cycles/20260101-addu/plan.md)"
  git config core.hooksPath "$WORK/nohooks"
  ck "$S a hook that ran git add -u: approve exits 11" rc_is 11
  ck "$S ...naming the path it swept in" has "seed"

  echo "== $S the add -N retry never reads git's (localized) error text =="
  new_repo itade
  mkdir -p "$WORK/gitwrap-de"
  cat > "$WORK/gitwrap-de/git" <<EOF
#!/bin/sh
# A git whose messages are German: the same reset race as gitwrap, with the commit's stderr translated.
sub=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in -C|-c|--git-dir|--work-tree|--namespace) skip=1 ;; -*) ;; *) sub="\$a"; break ;; esac
done
if [ "\$sub" = commit ]; then
  if [ -n "\${P20_RESET_ONCE:-}" ] && [ ! -e "\$P20_RESET_ONCE" ]; then : > "\$P20_RESET_ONCE"; "$REAL_GIT" reset -q --mixed >/dev/null 2>&1; fi
  e=\$(mktemp "\${TMPDIR:-/tmp}/p20de.XXXXXX"); "$REAL_GIT" "\$@" 2>"\$e"; rc=\$?
  sed 's/did not match any file.*/stimmt mit keinen Git bekannten Dateien ueberein/' "\$e" >&2; rm -f "\$e"; exit \$rc
fi
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$WORK/gitwrap-de/git"
  fx_init 20260101-itade "Itade" "1:One"
  rm -f "$WORK/reset-once-de"
  PATH="$WORK/gitwrap-de:$PATH" P20_RESET_ONCE="$WORK/reset-once-de" cy approve 20260101-itade --expect "$(c12 docs/cycles/20260101-itade/plan.md)"
  check "$S (fixture: the reset fired under the German git)" "[ -e '$WORK/reset-once-de' ]"
  ck "$S approve still commits under a localized git" approved_since "$(git rev-parse HEAD~1 2>/dev/null)" docs/cycles/20260101-itade/record.md
}

sc_gitstate() {
  echo "== $S approve refuses mid-merge, mid-rebase, mid-cherry-pick, detached, off trunk =="
  new_repo gst
  local ID=20260101-gst P R T
  git checkout -q -b side; echo side > seed; git commit -qam side
  git checkout -q trunk; echo trunk > seed; git commit -qam trunk-change
  T=$(git rev-parse HEAD)
  fx_init "$ID" "Gst" "1:One"; P="docs/cycles/$ID/plan.md"; R="docs/cycles/$ID/record.md"
  cp "$R" "$WORK/gst.rec"
  git merge -q side >/dev/null 2>&1
  check "$S (fixture: a merge is in progress)" "[ -e .git/MERGE_HEAD ]"
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S mid-merge: approve refuses (5)" rc_is 5
  ck "$S ...record.md unchanged" same "$R" "$WORK/gst.rec"
  git merge --abort
  git cherry-pick side >/dev/null 2>&1
  check "$S (fixture: a cherry-pick is in progress)" "[ -e .git/CHERRY_PICK_HEAD ]"
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S mid-cherry-pick: approve refuses (5)" rc_is 5
  git cherry-pick --abort
  git rebase side >/dev/null 2>&1
  check "$S (fixture: a rebase is in progress)" "[ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]"
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S mid-rebase: approve refuses (5)" rc_is 5
  git rebase --abort
  git checkout -q --detach
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S detached HEAD: approve refuses (5)" rc_is 5
  git checkout -q trunk
  git checkout -q -b worktree/p20
  ACFW_TRUNK_BRANCH=trunk cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S off the trunk branch: approve refuses (5)" rc_is 5
  git checkout -q trunk; git branch -q -D worktree/p20
  ck "$S nothing was committed by any refusal" head_is "$T"
  ck "$S ...and record.md is untouched" same "$R" "$WORK/gst.rec"
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S control: back on trunk with a clean state, approve goes" approved_since "$T" "$R"

  echo "== $S fail closed: conflict markers, a gitignored folder =="
  new_repo cfm
  mkplan "$WORK/cfm.md" "Cfm" "1:One"
  printf '\n<<<<<<< ours\nmine\n=======\ntheirs\n>>>>>>> theirs\n' >> "$WORK/cfm.md"
  H0=$(git rev-parse HEAD)
  cy init 20260101-cfm --from-file "$WORK/cfm.md" --kind feature --source x
  if rc_is 5; then ok "$S a plan with conflict markers refuses at init (5)"
  else
    cy approve 20260101-cfm --expect "$(c12 "$WORK/cfm.md")"
    ck "$S a plan with conflict markers is never approved (5)" rc_is 5
  fi
  ck "$S ...nothing committed" head_is "$H0"
  new_repo ign
  printf 'docs/cycles/\n' >> .gitignore; git commit -qam "ignore cycles"
  H0=$(git rev-parse HEAD)
  mkplan "$WORK/ign.md" "Ign" "1:One"
  cy init 20260101-ign --from-file "$WORK/ign.md" --kind feature --source x
  if rc_is 5; then ok "$S a gitignored cycle folder refuses at init (5)"
  else
    cy approve 20260101-ign --expect "$(c12 "$WORK/ign.md")"
    ck "$S a gitignored cycle folder is never approved (5)" rc_is 5
  fi
  ck "$S ...nothing committed" head_is "$H0"
}

sc_shapes() {
  echo "== $S the D-parser, coverage off, normalization, the subject budget =="
  new_repo dpr
  local ID=20260101-dpr P
  P="docs/cycles/$ID/plan.md"
  cat > "$WORK/dpr.md" <<'EOF'
# D parser

## Deliverables

### D1: Alpha

- AC1.1: ok

### D2 - Beta

- AC2.1: ok

### D3

```markdown
### D9: fenced, not a deliverable
```

### D12: Twelve

## Out of scope

### D7: outside the Deliverables section
EOF
  cy init "$ID" --from-file "$WORK/dpr.md" --kind feature --source x
  fx_approve "$ID"
  cy check "$ID"
  ck "$S D-ids: colon, dash and bare headings count; fenced and out-of-section ones do not" \
    line1_re "^CHECK\\|go\\|cycle=$ID\\|.*\\|uncovered=D1,D2,D3,D12\\|known=D1,D2,D3,D12\\|coverage=on\\|kind=feature\$"
  unlock "$ID"

  ID=20260101-off
  cat > "$WORK/off.md" <<'EOF'
# A foreign plan with no Deliverables section

## Steps

### D1: this heading is not under ## Deliverables

1. do the thing
EOF
  cy init "$ID" --from-file "$WORK/off.md" --kind feature --source "a superpowers plan"
  fx_approve "$ID"
  cy check "$ID"
  ck "$S no ## Deliverables: coverage off, stated in the CHECK line" \
    line1_re "^CHECK\\|go\\|cycle=$ID\\|.*\\|uncovered=\\|known=\\|coverage=off\\|kind=feature\$"
  ck "$S ...and not refused (a foreign plan is a non-gate)" rc_is 0
  unlock "$ID"
  cy record "$ID" off-001=-
  ck "$S record with coverage off takes '-' as the deliverable" line1_re "^RECORD\\|ok\\|cycle=$ID\\|tasks=1\$"
  check "$S ...and writes the row '| - | off-001 |'" "[ \"\$(hrows docs/cycles/$ID/record.md Tasks)\" = '| - | off-001 |' ]"
  cy check "$ID"
  ck "$S ...after which the plan is covered (no re-decomposition)" line1_is "CHECK|noop|cycle=$ID|reason=covered"
  # The same '| - | stem |' row is what --if-cycle intersects with the focus. Read as a table
  # separator, it would make every coverage-off cycle invisible to /go's completion tail.
  focus off-001
  calls_reset; cyc status --if-cycle
  ck "$S --if-cycle finds a coverage-off cycle through its '-' row (prints its status)" eval '! silent && inv'
  nofocus

  ID=20260101-nrm
  printf '# Norm  \r\n\r\n## Deliverables\r\n\r\n### D1: One \t\r\n\r\n- AC1.1: ok\r\n' > "$WORK/nrm.md"
  printf '# Norm\n\n## Deliverables\n\n### D1: One\n\n- AC1.1: ok\n' > "$WORK/nrm.lf"
  cy init "$ID" --from-file "$WORK/nrm.md" --kind feature --source x
  ck "$S a CRLF import is copied verbatim" same "docs/cycles/$ID/plan.md" "$WORK/nrm.md"
  ck "$S ...its merge base is the normalized text (so an unedited plan fast-forwards on a pull)" same "$REPO/.acfwhip/run/workbench/$ID/base.md" "$WORK/nrm.lf"
  cy status "$ID"
  ck "$S its content= is the hash of the NORMALIZED bytes (CRLF, trailing whitespace)" \
    out_has_line "  content=$(git hash-object "$WORK/nrm.lf" | cut -c1-12)"
  H0=$(git rev-parse HEAD)
  cy approve "$ID" --expect "$(git hash-object "$WORK/nrm.lf" | cut -c1-12)"
  ck "$S ...and approves at that hash" approved_since "$H0" "docs/cycles/$ID/record.md"
  ck "$S approve normalized plan.md in place (hash-neutral: the approval still binds the card's content)" \
    eval "same docs/cycles/$ID/plan.md '$WORK/nrm.lf' && ac_matches docs/cycles/$ID/record.md '$WORK/nrm.md'"
  check "$S ...and HEAD holds the normalized bytes, which a trailing-whitespace hook has nothing to fix in" \
    "git show 'HEAD:docs/cycles/$ID/plan.md' | cmp -s - '$WORK/nrm.lf'"
  check "$S ...leaving the cycle folder clean in git" "[ -z \"\$(git status --porcelain -- docs/cycles/$ID)\" ]"

  ID=20260101-this-is-a-very-long-cycle-slug-that-keeps-on-going
  fx_cycle "$ID" "Long" "1:One"
  check "$S a long slug keeps the subject within 50 chars" "[ \"\$(csubj | wc -c | tr -d ' ')\" -le 51 ] && csubj | grep -q '^docs(plan): approve this-is'"

  echo "== $S init from the template, the dated ID, --title, the retro-actions kind =="
  new_repo tmpl
  local D0 D1 LINE
  D0=$(date -u +%Y%m%d)
  cy init beta --kind feature --source "/whip draft"
  D1=$(date -u +%Y%m%d)
  LINE=$(line1)
  check "$S a bare slug is dated with today's UTC date" \
    "[ '$LINE' = 'INIT|$D0-beta|docs/cycles/$D0-beta/plan.md' ] || [ '$LINE' = 'INIT|$D1-beta|docs/cycles/$D1-beta/plan.md' ]"
  check "$S with no --from-file the plugin template is used (it has ## Deliverables)" \
    "grep -qx '## Deliverables' docs/cycles/$D0-beta/plan.md 2>/dev/null || grep -qx '## Deliverables' docs/cycles/$D1-beta/plan.md 2>/dev/null"
  mkdir -p docs/acf/backlog
  printf '# Project template\n\nP20-OVERRIDE-MARKER\n\n## Deliverables\n\n### D1: first\n' > docs/acf/backlog/plan-template.md
  git add docs/acf && git commit -qm "project template"
  cy init 20260101-own --kind feature --source "/whip draft"
  check "$S a project docs/acf/backlog/plan-template.md wins over the plugin's" \
    "grep -q 'P20-OVERRIDE-MARKER' docs/cycles/20260101-own/plan.md"
  cy init 20260101-titled --kind feature --source "/whip draft" --title "Titled Cycle"
  check "$S --title sets the record H1" "grep -qx '# Cycle Record: Titled Cycle' docs/cycles/20260101-titled/record.md"
  mkplan "$WORK/acts.md" "Retro actions" "1:Add a sensor"
  cy init 20260101-acts --from-file "$WORK/acts.md" --kind retro-actions --source "retro 20251231-prev"
  check "$S --kind retro-actions is stamped" "[ \"\$(wmeta docs/cycles/20260101-acts/record.md Kind)\" = retro-actions ]"

  echo "== $S Source: the blob rides on an import, never on a <tool>:<ref> lineage =="
  local SB LONG; SB=$(git hash-object "$WORK/acts.md" | cut -c1-12)
  # acfw-spec splits "<tool>:<ref>" at its first colon to push back to the document the plan came from;
  # a " (blob ...)" suffix there would make the ref unusable.
  cy init 20260101-tref --from-file "$WORK/acts.md" --kind feature --source "gaptrap:SPEC-12"
  check "$S a /whip --from lineage stays exactly <tool>:<ref>" "[ \"\$(wmeta docs/cycles/20260101-tref/record.md Source)\" = 'gaptrap:SPEC-12' ]"
  check "$S ...and still gets its merge base" "[ -s '$REPO/.acfwhip/run/workbench/20260101-tref/base.md' ]"
  # A REF| value pasted with a stray blank or CR: the shape test ran on the raw value, saw prose, added
  # a blob, and only then trimmed, leaving the lineage "gaptrap:SPEC-12 (blob ...)".
  cy init 20260101-tref2 --from-file "$WORK/acts.md" --kind feature --source "gaptrap:SPEC-12 "
  check "$S a lineage with a trailing blank is recorded exactly 'gaptrap:SPEC-12' (trimmed before the blob test)" \
    "[ \"\$(wmeta docs/cycles/20260101-tref2/record.md Source)\" = 'gaptrap:SPEC-12' ]"
  cy init 20260101-tref3 --from-file "$WORK/acts.md" --kind feature --source "$(printf ' gaptrap:SPEC-12\r')"
  check "$S ...and so is one with a leading blank and a trailing CR" \
    "[ \"\$(wmeta docs/cycles/20260101-tref3/record.md Source)\" = 'gaptrap:SPEC-12' ]"
  cy init 20260101-tblank --kind feature --source "   "
  ck "$S a blank-only --source is no source (usage, exit 2)" eval 'rc_is 2 && [ ! -e docs/cycles/20260101-tblank ]'
  cy init 20260101-tblob --from-file "$WORK/acts.md" --kind feature --source "imported from x.md (blob $SB)"
  check "$S a Source that already carries a blob is not given a second one" \
    "[ \"\$(wmeta docs/cycles/20260101-tblob/record.md Source)\" = 'imported from x.md (blob $SB)' ]"
  LONG="imported from /$(printf 'very-long-directory-name/%.0s' 1 2 3 4 5 6 7 8)plan.md"
  cy init 20260101-tlong --from-file "$WORK/acts.md" --kind feature --source "$LONG"
  check "$S a path too long for the 160-char cell keeps its blob (the path is what gets shortened)" \
    "wmeta docs/cycles/20260101-tlong/record.md Source | grep -qE '^imported from /very-long.*\\.\\.\\. \\(blob $SB\\)\$'"
  mkdir -p "$REPO/.acfwhip/run/workbench/20260101-tnone"; echo "a dead draft's base" > "$REPO/.acfwhip/run/workbench/20260101-tnone/base.md"
  cy init 20260101-tnone --kind feature --source "/whip draft"
  check "$S a draft from the template has no blob and no merge base (a dead draft's base is cleared)" \
    "[ \"\$(wmeta docs/cycles/20260101-tnone/record.md Source)\" = '/whip draft' ] && [ ! -e '$REPO/.acfwhip/run/workbench/20260101-tnone/base.md' ]"

  if [ -f "$BIN/acfw-spec" ]; then
    echo "== $S the merge base lets a changed original re-merge with local edits (acfw-spec pull --file) =="
    local IMP="$WORK/imp.$STORE_NAME.md" IP=docs/cycles/20260101-imp/plan.md prc
    printf '# Imp\n\n## Problem\n\nSomething.\n\n## Deliverables\n\n### D1: One\n\n- AC1.1: ok\n' > "$IMP"
    cy init 20260101-imp --from-file "$IMP" --kind feature --source "imported from imp.md"
    sed 's/^Something\.$/Something, clarified here./' "$IP" > "$WORK/imp.p" && mv -f "$WORK/imp.p" "$IP"
    printf '\n### D2: Two\n\n- AC2.1: ok\n' >> "$IMP"
    bash "$BIN/acfw-spec" pull 20260101-imp --file "$IMP" > "$WORK/imp.out" 2>&1; prc=$?
    # With no base every changed region is a conflict (exit 23): the edit and the new D2 are separate.
    check "$S the pull merges both sides: the local edit stays, the original's new D2 arrives" \
      "[ $prc = 0 ] && grep -q '^PULLED|file|merged|' '$WORK/imp.out' && grep -q 'clarified here' '$IP' && grep -q '^### D2: Two' '$IP'"
  fi
}

sc_coverage() {
  echo "== $S VERIFY: coverage ✓ ◐ ✗ ? cancelled, and the triggers that read it =="
  new_repo cov
  local ID=20260101-cov
  task c-001-done accepted; integrate c-001-done
  task c-002-done accepted; integrate c-002-done
  task c-003-open pending
  task c-004-stuck blocked
  task c-005-unver accepted
  task c-006-gone archive
  fx_cycle "$ID" "Coverage" "1:One" "2:Two" "3:Three" "4:Four" "5:Five"
  fx_record "$ID" c-001-done=D1 c-002-done=D2 c-003-open=D2 c-004-stuck=D3 c-005-unver=D4 c-006-gone=D5
  focus c-001-done c-002-done c-003-open c-004-stuck c-005-unver c-006-gone
  cy status
  ck "$S status exits 0" rc_is 0
  ck "$S invariants" inv
  ck "$S D1 accepted and integrated: ✓" cov_is D1 ✓
  ck "$S D2 one done, one pending: ◐" cov_is D2 ◐
  ck "$S D3 a blocked task: ✗" cov_is D3 ✗
  ck "$S D4 accepted, no ledger marker, no branch: ?" cov_is D4 '?'
  ck "$S D4 is never shown ✓ while unverified" cov_not D4 ✓
  ck "$S D5 every task archived: cancelled" cov_is D5 cancelled
  # The ack is files-only: whip-move refuses --integrated-at (exit 2) on every other backend, because
  # no adapter maps Integrated-At and the in-tree ledger is the sole oracle. A card that handed it out
  # there would hand out a failure, so off files the card points at the runbook's marker recipe.
  if [ "$STORE_NAME" = files ]; then
    ck "$S the unverified task gets the --integrated-at ack as a REPLY" card_names "--integrated-at"
  else
    ck "$S the unverified task's card points at the runbook's ledger-marker recipe" card_names "accepted-branchless-unverified"
    ck "$S ...and never hands out the files-only --integrated-at ack, which this backend refuses" eval '! card_names "--integrated-at"'
  fi
  ck "$S a runnable task remains: NEXT /go" next_is "NEXT /go"
  if [ "$STORE_NAME" = multica ]; then
    # This backend's closure drops every accepted seed it calls terminal, branchless-unverified ones
    # included, so ✓ vs ? is settled per seed: the git ledger answers for free, and only a seed with no
    # marker costs one read (to learn whether it is code at all).
    rm -f "$REPO/.acfwhip/run/cycle/$ID/settled"
    calls_reset; cy status
    check "$S only the unmarked accepted seed is read; the marked ones are settled from the ledger" \
      "[ \"\$(grep '^multica read ' \"\$P20_CALL_LOG\" | sort | paste -sd'#' -)\" = 'multica read c-005-unver' ]"
    # Hard rule 1: an accepted seed's code-or-not answer cannot change while it stays accepted, so it
    # costs one read per cycle, never one per bare /whip on an API-billed board.
    calls_reset; cy status
    check "$S a repeat status reads nothing: the seed's verdict is remembered per cycle" "! grep -q '^multica read ' \"\$P20_CALL_LOG\""
    ck "$S ...and D4 is still ? (the cache never turns code into ✓)" cov_is D4 '?'
    calls_reset; cy status --after-run complete --mode default
    check "$S --after-run reads the seed again (live counters after a run)" "grep -q '^multica read c-005-unver' \"\$P20_CALL_LOG\""
    rm -f "$REPO/.acfwhip/run/cycle/$ID/settled"
    MC_FAKE_FAIL="issue get:2" cy status
    # A read that fails is an outage, not "unverified": the ? card would hand out /whip-move pending for
    # work that may be finished (hard rule 9: fail closed on store exit 5/6).
    ck "$S a read that fails: stage unknown, exit 4" eval 'rc_is 4 && has "stage unknown" && next_is "NEXT /whip-doctor"'
    ck "$S ...and never a ✓ it could not prove" cov_not D4 ✓
  fi
  cy triggers "$ID"
  ck "$S triggers exits 0" rc_is 0
  ck "$S ✗ fires gap" out_has_line "TRIGGER|gap|D3"
  ck "$S a blocked task fires stuck" out_has_line "TRIGGER|stuck|c-004-stuck|blocked"
  check "$S cancelled, ◐ and ? fire no gap" "! printf '%s\n' \"\$CY_OUT\" | grep -qE '^TRIGGER\\|gap\\|D(2|4|5)\$'"
  check "$S ...and TRIGGERS|none is not printed alongside triggers" "! printf '%s\n' \"\$CY_OUT\" | grep -q '^TRIGGERS|none'"

  echo "== $S rework / stuck thresholds live in the script (rc>=2, bc>=2) =="
  new_repo trg
  ID=20260101-trg
  task t-001-rework accepted none 2 0; integrate t-001-rework
  task t-002-once accepted none 1 0;   integrate t-002-once
  task t-003-bc accepted none 0 2;     integrate t-003-bc
  task t-004-bc1 accepted none 0 1;    integrate t-004-bc1
  fx_cycle "$ID" "Triggers" "1:One" "2:Two"
  fx_record "$ID" t-001-rework=D1 t-002-once=D1 t-003-bc=D2 t-004-bc1=D2
  focus t-001-rework t-002-once t-003-bc t-004-bc1
  cy triggers "$ID"
  check "$S exactly the rework (rc=2) and stuck (bc=2) triggers; rc=1 and bc=1 stay quiet" \
    "[ \"\$(printf '%s\n' \"\$CY_OUT\" | grep '^TRIGGER' | sort | paste -sd'#' -)\" = 'TRIGGER|rework|t-001-rework|rc=2#TRIGGER|stuck|t-003-bc|bc=2' ]"
  cy status
  ck "$S all terminal with a trigger: NEXT /retro" next_re '^NEXT /retro( |$)'
  ck "$S ...saying which trigger fired" has "trigger fired"
  ck "$S ...invariants" inv
}

sc_phantom() {
  echo "== $S phantom vs accepted-and-absent-from-tasks[] =="
  new_repo ph
  local ID=20260101-ph SNAP
  task ph-001-real accepted; integrate ph-001-real
  fx_cycle "$ID" "Phantom" "1:Real" "2:Ghost"
  fx_record "$ID" ph-001-real=D1 ph-002-ghost=D2
  focus ph-001-real ph-002-ghost
  SNAP=$(bash "$STORE_BIN" snapshot --only ph-001-real --only ph-002-ghost 2>/dev/null)
  check "$S (fixture: the store resolves the real stem and not the ghost)" \
    "printf '%s' \"\$SNAP\" | jq -e '.scope.resolved[\"ph-001-real\"] == \"ph-001-real\" and (.scope.unresolved | index(\"ph-002-ghost\"))' >/dev/null"
  if [ "$STORE_NAME" = multica ]; then
    check "$S (fixture: this backend drops the accepted seed from tasks[], the path under test)" \
      "printf '%s' \"\$SNAP\" | jq -e '[.tasks[] | select(.stem == \"ph-001-real\")] | length == 0' >/dev/null"
  fi
  cy status
  ck "$S status exits 0" rc_is 0
  ck "$S invariants" inv
  ck "$S an accepted task missing from tasks[] is still ✓, not a phantom" cov_is D1 ✓
  ck "$S a recorded stem the store cannot resolve is never ✓" cov_not D2 ✓
  ck "$S ...it gets a NEED YOU card naming it" card_names "ph-002-ghost"
  ck "$S ...and nothing is runnable, so NEXT is not /go" next_not_re '^NEXT /go$'
}

sc_gated() {
  echo "== $S BUILD is runnability-aware: a gated chain names its root blocker =="
  # A blocked task under its lifetime cap is RETRYABLE: /go lifts it back to pending (MAX_BLOCK_RETRY
  # = 3 in whip-go). So a chain ending there can still advance and /go is the honest NEXT. The root
  # that can never move on its own is one PARKED at the cap, a draft, or an archived task.
  new_repo gt0
  local ID=20260101-gt0
  task g-003-root blocked none 0 1
  task g-002-mid pending g-003-root
  fx_cycle "$ID" "Retryable" "1:Mid" "2:Root"
  fx_record "$ID" g-002-mid=D1 g-003-root=D2
  focus g-002-mid g-003-root
  cy status
  ck "$S a chain ending at a RETRYABLE blocked task (bc=1 < cap 3) is not a gate: NEXT /go" next_is "NEXT /go"

  new_repo gt
  ID=20260101-gt
  task g-003-root blocked none 0 3
  task g-002-mid pending g-003-root
  task g-001-top pending g-002-mid
  fx_cycle "$ID" "Gated" "1:Top" "2:Mid" "3:Root"
  fx_record "$ID" g-001-top=D1 g-002-mid=D2 g-003-root=D3
  focus g-001-top g-002-mid g-003-root
  cy status
  ck "$S invariants" inv
  ck "$S a chain ending at a task PARKED at the cap (bc=3): NEXT is neither /go nor /retro (no /go<->/retro loop)" next_not_re '^NEXT /(go|retro)( |$)'
  ck "$S the card names the ROOT blocker" card_names "g-003-root"
  cy status --if-cycle --after-run no-progress --mode default
  ck "$S after a /go that stopped short: NEXT act on the /go report above" next_is "NEXT act on the /go report above"
  ck "$S ...invariants" inv
  cy status --if-cycle --after-run complete --mode default
  ck "$S --after-run complete derives NEXT instead" next_not_re 'act on the /go report above'
  bash "$STORE_BIN" transition g-003-root draft orchestrator "parked" 0 0 >/dev/null 2>&1 || bad "fixture: park g-003-root"
  cy status
  ck "$S a chain ending at a DRAFT task is gated too (not /go)" next_not_re '^NEXT /(go|retro)( |$)'
  ck "$S ...and its card names the draft root" card_names "g-003-root"

  echo "== $S runnable, uncovered, and the store gone =="
  new_repo run
  ID=20260101-run
  task r-001-go pending
  fx_cycle "$ID" "Run" "1:Go"
  fx_record "$ID" r-001-go=D1
  focus r-001-go
  cy status
  ck "$S a runnable cycle task: NEXT /go" next_is "NEXT /go"
  ck "$S ...invariants" inv
  calls_reset; cyc status --if-cycle
  ck "$S --if-cycle with the focus inside a cycle prints status" next_is "NEXT /go"
  check "$S ...(control: the call counters do see its store calls)" "[ \"\$(calls_n)\" -gt 0 ]"
  fx_init 20260101-side "Side" "1:Side"
  cy status
  ck "$S an untracked draft never hijacks NEXT from a cycle in flight" next_is "NEXT /go"
  if [ "$STORE_NAME" = multica ]; then
    MC_FAKE_FAIL="issue list:2" cy status     # the CLI fails; the adapter maps it to exit 5
  else
    P20_OUTAGE=5 cy status                   # the adapter itself answers "backend unavailable"
  fi
  ck "$S store unreachable: status exits 4" rc_is 4
  ck "$S ...stage unknown" has "stage unknown"
  ck "$S ...pointing at /whip-doctor" has "/whip-doctor"

  new_repo unc
  ID=20260101-unc
  task u-001-go pending
  fx_cycle "$ID" "Uncovered" "1:Covered" "2:Not yet"
  fx_record "$ID" u-001-go=D1
  focus u-001-go
  cy status
  ck "$S an uncovered deliverable outranks a runnable task: NEXT /task --plan <plan>" \
    next_is "NEXT /task --plan docs/cycles/$ID/plan.md"
  ck "$S ...invariants" inv

  echo "== $S an unpinned integration mode with accepted-unintegrated cycle work gets one card =="
  new_repo nomode --no-mode
  ID=20260101-nomode
  task m-001-done accepted
  fx_cycle "$ID" "Mode" "1:One"
  fx_record "$ID" m-001-done=D1
  focus m-001-done
  # The config's last line has no newline: a bare `printf ... >> file` REPLY would glue the pin onto
  # it, so the pin is never read and the other key is corrupted.
  printf 'ACFW_WORKTREE_DIR=.worktree' > .acfwhip/config
  cy status
  ck "$S the card names ACFW_INTEGRATION_MODE" has "ACFW_INTEGRATION_MODE"
  ck "$S ...invariants" inv
  local pin_reply
  pin_reply=$(printf '%s\n' "$CY_OUT" | awk '/^  WHAT ACFW_INTEGRATION_MODE is not pinned/ {w=1; next} w && /^  REPLY / {sub(/^  REPLY /, ""); print; exit}')
  ( cd "$WORK" && /bin/bash -c "$pin_reply" ) >/dev/null 2>&1
  check "$S ...its REPLY, run from anywhere, pins the mode on a line of its own" \
    "[ \"\$(cat .acfwhip/config)\" = \"\$(printf 'ACFW_WORKTREE_DIR=.worktree\nACFW_INTEGRATION_MODE=default')\" ]"
  cy status
  ck "$S ...after which the card is gone" lacks_re "ACFW_INTEGRATION_MODE is not pinned"
}

sc_close() {
  echo "== $S RETRO, clean: close none with zero agents =="
  new_repo cln
  local ID=20260101-cln R C12
  R="docs/cycles/$ID/record.md"
  task k-001-a accepted; integrate k-001-a
  task k-002-b accepted; integrate k-002-b
  fx_cycle "$ID" "Clean" "1:One" "2:Two"
  fx_record "$ID" k-001-a=D1 k-002-b=D2
  focus k-001-a k-002-b
  C12=$(c12 "docs/cycles/$ID/plan.md")
  cy triggers "$ID"
  ck "$S a clean cycle: the single line TRIGGERS|none" eval '[ "$CY_OUT" = "TRIGGERS|none" ]'
  cy status
  ck "$S all terminal, never retro'd: NEXT /retro (RETRO is always explicit)" next_re '^NEXT /retro( |$)'
  ck "$S ...naming the cycle right after /retro (a bare /retro resolves its cycle from this line)" next_is "NEXT /retro $ID"
  ck "$S ...coverage ✓ ✓" eval 'cov_is D1 ✓ && cov_is D2 ✓'
  ck "$S ...invariants" inv
  cy close "$ID" none
  ck "$S close none exits 0" rc_is 0
  ck "$S subject: docs(plan): close cln" subj_is "docs(plan): close cln"
  ck "$S trailer: ACFW-Plan-Event: closed <c12> <ID>" trailer_is "closed $C12 $ID"
  ck "$S the commit carries record.md only" paths_are "$R"
  check "$S Status closed, Retro none" "[ \"\$(hmeta '$R' Status),\$(hmeta '$R' Retro)\" = 'closed,none' ]"
  check "$S newest row: closed" "[ \"\$(hevent '$R' 1)\" = closed ]"
  cy status
  ck "$S a closed cycle: NEXT /whip \"<next goal>\"" next_re '^NEXT /whip "'
  ck "$S ...invariants" inv
  calls_reset; cyc status --if-cycle --after-run complete --mode default
  ck "$S --if-cycle over a closed cycle prints nothing, zero calls" eval 'silent && zero_calls'

  echo "== $S RETRO, triggered: governance is enforced by script =="
  new_repo rt
  local AID H0 L=docs/acf/lessons
  ID=20260101-rt; R="docs/cycles/$ID/record.md"
  task rt-001 accepted none 2 0; integrate rt-001
  mkdir -p "$L"; printf '# Old\n\n**Rule**: Old rule.\n' > "$L/old-rule.md"
  git add "$L" && git commit -qm "an existing lesson"
  fx_cycle "$ID" "Retro" "1:One"
  fx_record "$ID" rt-001=D1
  focus rt-001
  C12=$(c12 "docs/cycles/$ID/plan.md")
  cy triggers "$ID"
  ck "$S (the rework trigger fired)" out_has_line "TRIGGER|rework|rt-001|rc=2"
  cy retro-begin "$ID"
  ck "$S retro-begin exits 0" rc_is 0
  check "$S RETRO|begin|cycle=<ID>|head=<HEAD>" \
    "line1 | grep -qE '^RETRO\\|begin\\|cycle=$ID\\|head=[0-9a-f]{7,40}\$' && case '$(git rev-parse HEAD)' in \"\$(line1 | sed 's/.*head=//')\"*) true ;; *) false ;; esac"
  check "$S the baseline is captured under run state" "[ -s '$REPO/.acfwhip/run/cycle/$ID/retro-baseline' ]"
  printf '# Retro\n\nThe bar: one lesson.\n' > "docs/cycles/$ID/retro.md"
  printf '# Keep tests\n\n**Rule**: Always run the suite before approving.\n\n## What happened\n\nx\n' > "$L/keep-tests.md"
  H0=$(git rev-parse HEAD)
  echo stray >> seed
  cy close "$ID" retro.md --lesson "$L/keep-tests.md"
  ck "$S a changed path outside the retro's own set refuses (5)" rc_is 5
  ck "$S ...committing nothing" head_is "$H0"
  git checkout -q -- seed
  rm "$L/old-rule.md"
  cy close "$ID" retro.md --lesson "$L/keep-tests.md"
  ck "$S a deleted lesson refuses (5)" rc_is 5
  ck "$S ...retiring a lesson is yours" has "retiring a lesson is yours"
  ck "$S ...committing nothing" head_is "$H0"
  git checkout -q -- "$L/old-rule.md"
  printf '**Rule**: bad.\n' > "$L/Bad_Slug.md"
  cy close "$ID" retro.md --lesson "$L/Bad_Slug.md"
  ck "$S a lesson slug outside ^[a-z][a-z0-9-]*\$ refuses (3)" rc_is 3
  rm -f "$L/Bad_Slug.md"
  printf '**Rule**: bad.\n' > "$L/api-v2beta.md"
  cy close "$ID" retro.md --lesson "$L/api-v2beta.md"
  ck "$S a -vN anywhere in the slug (api-v2beta: the audit's -v[0-9]+) refuses (3)" rc_is 3
  ck "$S ...committing nothing" head_is "$H0"
  rm -f "$L/api-v2beta.md"
  echo moved > moved.txt; git add moved.txt; git commit -qm "HEAD moves during the retro"
  H0=$(git rev-parse HEAD)
  cy close "$ID" retro.md --lesson "$L/keep-tests.md"
  ck "$S HEAD moved since retro-begin refuses (5)" rc_is 5
  ck "$S ...committing nothing" head_is "$H0"
  check "$S ...and no governance refusal stamped record.md" "git diff --quiet -- '$R'"
  cy retro-begin "$ID"
  AID="$(date -u +%Y%m%d)-rt-retro-actions"
  mkplan "$WORK/rt-acts.md" "Retro actions for rt" "1:Add a sensor for the rework"
  printf '\n## Retire\n\n<!-- Not work for /task: a human runs these git rm commands after approving. -->\n- old-rule: enforced by tests/x.sh: "assert old"\n- `gone-rule`: enforced by tests/y.sh: "assert gone"\n' >> "$WORK/rt-acts.md"
  cy init "$AID" --from-file "$WORK/rt-acts.md" --kind retro-actions --source "retro $ID"
  rc_is 0 || bad "fixture: init $AID"
  cy close "$ID" retro.md --lesson "$L/keep-tests.md" --actions "$AID"
  ck "$S close with a retro doc, a lesson and an actions cycle exits 0" rc_is 0
  ck "$S ...one commit of exactly those paths" paths_are "docs/cycles/$ID/retro.md" "$R" "$L/keep-tests.md" \
    "docs/cycles/$AID/plan.md" "docs/cycles/$AID/record.md"
  ck "$S subject: docs(plan): close rt" subj_is "docs(plan): close rt"
  ck "$S trailer: ACFW-Plan-Event: closed <c12> <ID>" trailer_is "closed $C12 $ID"
  check "$S Status closed, Retro retro.md" "[ \"\$(hmeta '$R' Status),\$(hmeta '$R' Retro)\" = 'closed,retro.md' ]"
  check "$S newest row: closed" "[ \"\$(hevent '$R' 1)\" = closed ]"
  check "$S the actions cycle is stamped retro-actions" "[ \"\$(hmeta docs/cycles/$AID/record.md Kind)\" = retro-actions ]"
  cy status "$AID"
  ck "$S the actions' approval card shows what the yes retires: the exact git rm" \
    out_has_line "  RETIRE (yours, after yes): git rm docs/acf/lessons/old-rule.md"
  ck "$S ...a listed lesson that does not exist gets no git rm" eval '! has "git rm docs/acf/lessons/gone-rule.md" && has "  RETIRE gone-rule: "'
  ck "$S ...the ## Retire list is not a deliverable (the card counts 1)" has "(1 deliverable)"
  ck "$S ...invariants" inv
  mkplan "$WORK/rt-feat.md" "Feature with a retire list" "1:New endpoint"
  printf '\n## Retire\n\n- old-rule: the v1 endpoint goes away\n' >> "$WORK/rt-feat.md"
  cy init 20260101-rtfeat --from-file "$WORK/rt-feat.md" --kind feature --source x
  cy status 20260101-rtfeat
  ck "$S a FEATURE plan's ## Retire is not about lessons: no RETIRE line on its card" eval 'has "  content=" && ! has "RETIRE"'
  rm -rf docs/cycles/20260101-rtfeat
  cy lessons
  ck "$S lessons lists slug: rule, sorted" eval '[ "$CY_OUT" = "keep-tests: Always run the suite before approving.
old-rule: Old rule." ]'

  echo "== $S note: a mid-cycle retro writes a doc and lessons, never a closed row =="
  new_repo nt
  ID=20260101-nt; R="docs/cycles/$ID/record.md"
  task nt-001 pending
  fx_cycle "$ID" "Note" "1:One"
  fx_record "$ID" nt-001=D1
  cy retro-begin "$ID"
  printf '# Mid retro\n' > "docs/cycles/$ID/retro.md"
  mkdir -p "$L"; printf '# Mid\n\n**Rule**: Mid-cycle rule.\n' > "$L/mid-rule.md"
  H0=$(git rev-parse HEAD)
  cy note "$ID" retro.md --lesson "$L/mid-rule.md"
  ck "$S note exits 0" rc_is 0
  check "$S ...one commit carrying the retro doc and the lesson" \
    "[ \"\$(git rev-list --count $H0..HEAD)\" = 1 ] && cpaths HEAD | grep -qF 'docs/cycles/$ID/retro.md' && cpaths HEAD | grep -qF '$L/mid-rule.md'"
  check "$S ...and nothing outside retro.md, record.md and the lesson" \
    "[ -z \"\$(git diff-tree --no-commit-id --name-only -r HEAD | grep -vxF -e 'docs/cycles/$ID/retro.md' -e '$R' -e '$L/mid-rule.md')\" ]"
  check "$S Status stays decomposed" "[ \"\$(hmeta '$R' Status)\" = decomposed ]"
  check "$S no closed row" "! hrows '$R' 'Plan Log' | cell 2 | grep -qx closed"
  # The closing retro rewrites the retro.md the note committed: a MODIFIED tracked file, not a new one.
  cy retro-begin "$ID"
  printf '\n## Findings at the close\n\nMore.\n' >> "docs/cycles/$ID/retro.md"
  H0=$(git rev-parse HEAD)
  cy close "$ID" retro.md
  ck "$S a close after a note accepts the retro.md that note committed, edited since" rc_is 0
  ck "$S ...committing exactly retro.md and record.md" paths_are "docs/cycles/$ID/retro.md" "$R"
  check "$S ...Status closed, Retro retro.md" "[ \"\$(hmeta '$R' Status),\$(hmeta '$R' Retro)\" = 'closed,retro.md' ]"

  echo "== $S a retro-actions cycle closes itself when terminal (derived; no retro-of-retro) =="
  new_repo ra
  ID=20260101-ra; R="docs/cycles/$ID/record.md"
  task ra-001 accepted; integrate ra-001
  mkplan "$WORK/ra.md" "Retro actions" "1:Add the sensor"
  cy init "$ID" --from-file "$WORK/ra.md" --kind retro-actions --source "retro 20251231-prev"
  fx_approve "$ID"
  cy check "$ID"
  ck "$S CHECK carries kind=retro-actions" line1_re "\\|kind=retro-actions\$"
  unlock "$ID"
  fx_record "$ID" ra-001=D1
  focus ra-001
  cy status
  ck "$S a terminal retro-actions cycle never asks for /retro" next_not_re '^NEXT /retro( |$)'
  ck "$S ...it reads as closed: NEXT /whip \"<next goal>\"" next_re '^NEXT /whip "'
  fx_cycle 20260102-after "After" "1:Next thing"
  check "$S the next mutating verb stamps its closed state and row" \
    "[ \"\$(hmeta '$R' Status)\" = closed ] && [ \"\$(hevent '$R' 1)\" = closed ]"
  check "$S ...in its own close commit with its own trailer, landed BEFORE the approve" \
    "[ \"\$(git log -1 --format=%s HEAD~1)\" = 'docs(plan): close ra' ] && git log -1 --format=%B HEAD~1 | grep -qx 'ACFW-Plan-Event: closed $(c12 "docs/cycles/$ID/plan.md") $ID'"
  check "$S ...so HEAD is still the approve commit that APPROVE|ok names" \
    "subj_is 'docs(plan): approve after' && line1 | grep -q \"|commit=\$(git rev-parse --short=12 HEAD)\\\$\""

  echo "== $S ...but never while one of its tasks can still move =="
  new_repo ra2
  ID=20260101-ra2; R="docs/cycles/$ID/record.md"
  task ra2-001 pending
  mkplan "$WORK/ra2.md" "Retro actions two" "1:Add another sensor"
  cy init "$ID" --from-file "$WORK/ra2.md" --kind retro-actions --source "retro 20251231-prev"
  fx_approve "$ID"
  fx_record "$ID" ra2-001=D1
  H0=$(git rev-parse HEAD)
  cy close "$ID" none --if-done
  ck "$S close --if-done on unfinished retro actions is a no-op" eval 'rc_is 0 && line1_is "CLOSE|noop|cycle=$ID|reason=not-done"'
  ck "$S ...committing nothing" head_is "$H0"
  fx_cycle 20260102-after2 "After two" "1:Next thing"
  check "$S the next approve leaves unfinished retro actions open" \
    "[ \"\$(hmeta '$R' Status)\" = decomposed ] && [ \"\$(hevent '$R' 1)\" = decomposed ]"
  H0=$(git rev-parse HEAD)
  cy close 20260102-after2 none --if-done
  ck "$S --if-done never closes a feature cycle (3): those close through /retro" rc_is 3
  ck "$S ...committing nothing" head_is "$H0"
}

sc_history() {
  echo "== $S abandon, older un-retro'd cycles, the draft card, unpushed plan commits =="
  new_repo abn
  local ID=20260101-abn R C12 REASON D ROW
  R="docs/cycles/$ID/record.md"
  task a-001 pending
  fx_cycle "$ID" "Abandon" "1:One"
  fx_record "$ID" a-001=D1
  focus a-001
  C12=$(c12 "docs/cycles/$ID/plan.md")
  REASON="scope moved | see #12$(printf '\001')$(printf 'x%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 87 88 89 90 91 92 93 94 95 96 97 98 99 100 101 102 103 104 105 106 107 108 109 110 111 112 113 114 115 116 117 118 119 120 121 122 123 124 125 126 127 128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 143 144 145 146 147 148 149 150 151 152 153 154 155 156 157 158 159 160 161 162 163 164 165 166 167 168 169 170 171 172 173 174 175 176 177 178 179 180 181 182 183 184 185 186 187 188 189 190 191 192 193 194 195 196 197 198 199 200)"
  cy abandon "$ID" --reason "$REASON"
  ck "$S abandon of a tracked cycle exits 0" rc_is 0
  ck "$S subject: docs(plan): abandon abn" subj_is "docs(plan): abandon abn"
  ck "$S trailer: ACFW-Plan-Event: abandoned <c12> <ID>" trailer_is "abandoned $C12 $ID"
  ck "$S the commit carries record.md only" paths_are "$R"
  check "$S Status abandoned" "[ \"\$(hmeta '$R' Status)\" = abandoned ]"
  ROW=$(hrow "$R" 1)
  check "$S newest row: abandoned" "[ \"\$(printf '%s' \"\$ROW\" | cell 2)\" = abandoned ]"
  check "$S a '|' in a cell becomes '/', so the row keeps exactly five cells" \
    "[ \"\$(printf '%s' \"\$ROW\" | tr -cd '|' | wc -c | tr -d ' ')\" = 6 ] && printf '%s' \"\$ROW\" | grep -qF 'scope moved / see #12'"
  check "$S C0 control characters are stripped" "! git show 'HEAD:$R' | LC_ALL=C grep -q \"\$(printf '\\001')\""
  D=$(printf '%s' "$ROW" | cell 5)
  check "$S a cell is capped at 160 characters" "[ \"\$(printf '%s' \"\$D\" | wc -c | tr -d ' ')\" -le 160 ]"
  calls_reset; cyc status --if-cycle
  ck "$S an abandoned cycle is out of scope: --if-cycle prints nothing, zero calls" eval 'silent && zero_calls'

  new_repo card
  ID=20260101-card
  fx_init "$ID" "Card" "1:One"
  C12=$(c12 "docs/cycles/$ID/plan.md")
  cy status
  ck "$S my single unapproved draft: bare status shows its approval card" out_has_line "  content=$C12"
  ck "$S ...with the exact REPLY line" out_has_line "  REPLY yes: approve, then start /task --plan in the background (sets your /go focus)"
  ck "$S ...invariants" inv
  local H0; H0=$(git rev-parse HEAD)
  cy abandon "$ID"
  ck "$S abandon of an untracked draft exits 0" rc_is 0
  ck "$S ...commits nothing" head_is "$H0"
  ck "$S ...the folder stays untracked" untracked_folder "$ID"
  check "$S ...and is stamped abandoned in the working tree" "[ \"\$(wmeta docs/cycles/$ID/record.md Status)\" = abandoned ]"
  cy status
  ck "$S after abandoning the draft: idle NEXT /whip \"<goal>\"" next_re '^NEXT /whip "'
  check "$S ...and no approval card for it" "! printf '%s\n' \"\$CY_OUT\" | grep -q '^  content='"

  new_repo old
  task o-001-done accepted; integrate o-001-done
  fx_cycle 20260101-old "Old" "1:Old"
  fx_record 20260101-old o-001-done=D1
  task n-001-go pending
  fx_cycle 20260102-new "New" "1:New"
  fx_record 20260102-new n-001-go=D1
  focus n-001-go
  cy status
  ck "$S the focused cycle keeps NEXT: /go" next_is "NEXT /go"
  check "$S an older terminal, un-retro'd cycle shows as an info line naming /retro" \
    "printf '%s\n' \"\$CY_OUT\" | grep -v '^NEXT ' | grep -F '/retro' | grep -qF '20260101-old'"
  ck "$S ...invariants" inv

  # Row 6: plan.md renamed away inside its folder. The folder name is the ID and plan.md its spec,
  # so the only honest NEXT is the exact rename back, found from what git itself tracks.
  new_repo pm
  ID=20260101-pm
  task pm-001 pending
  fx_cycle "$ID" "Plan missing" "1:One"
  fx_record "$ID" pm-001=D1
  focus pm-001
  git mv "docs/cycles/$ID/plan.md" "docs/cycles/$ID/spec.md"
  cy status
  ck "$S plan.md renamed away: NEXT is the exact git mv back" \
    next_is "NEXT git mv docs/cycles/$ID/spec.md docs/cycles/$ID/plan.md"
  ck "$S ...invariants" inv
  git mv "docs/cycles/$ID/spec.md" "docs/cycles/$ID/plan.md"

  new_repo pub
  git clone -q --bare "$REPO" "$REPO.remote.git" 2>/dev/null
  git remote add origin "$REPO.remote.git"; git push -q -u origin trunk 2>/dev/null
  ID=20260101-pub
  fx_cycle "$ID" "Pub" "1:One"
  cy status "$ID"
  ck "$S a plan commit not on @{u} is a WARN: push it" has_rei 'warn.*push'
  git push -q origin trunk 2>/dev/null
  cy status "$ID"
  ck "$S ...gone once pushed" lacks_rei 'warn.*push'
}

sc_lessons_nojq() {
  echo "== $S lessons: read-only, store-free, jq-free =="
  new_repo les
  local L=docs/acf/lessons i
  calls_reset; ACFW_STORE=bogus-store cyc lessons
  ck "$S no lessons dir: exit 0, silent" eval 'rc_is 0 && silent'
  mkdir -p "$L"
  cyc lessons
  ck "$S an empty lessons dir: exit 0, silent" eval 'rc_is 0 && silent'
  printf '# Z\n\n**Rule**: Zed rule.\n' > "$L/zeta-rule.md"
  printf '# A\n\n**Rule**: Alpha rule.\n\n## What happened\n\nx\n' > "$L/alpha-rule.md"
  cyc lessons
  ck "$S two lessons: '<slug>: <rule>', sorted" eval '[ "$CY_OUT" = "alpha-rule: Alpha rule.
zeta-rule: Zed rule." ]'
  ck "$S ...nothing on stderr" eval '[ -z "$CY_ERR" ]'
  printf '# No rule here\n\nprose only\n' > "$L/no-rule.md"
  cyc lessons
  ck "$S a lesson with no Rule line: stdout unchanged" eval '[ "$CY_OUT" = "alpha-rule: Alpha rule.
zeta-rule: Zed rule." ]'
  ck "$S ...and a WARN on stderr naming it" eval 'printf "%s" "$CY_ERR" | grep -q WARN && printf "%s" "$CY_ERR" | grep -q no-rule'
  rm -f "$L/no-rule.md"
  i=1; while [ $i -le 30 ]; do printf '**Rule**: rule %s.\n' "$i" > "$L/bulk-$i.md"; i=$((i+1)); done
  cyc lessons
  ck "$S over 30 lessons: all listed" eval '[ "$(printf "%s\n" "$CY_OUT" | grep -c .)" = 32 ]'
  ck "$S ...with a WARN naming the git rm remedy" eval 'printf "%s" "$CY_ERR" | grep -q WARN && printf "%s" "$CY_ERR" | grep -q "git rm"'
  ck "$S lessons never touched the store (not even with a bogus ACFW_STORE)" zero_calls
  nj lessons
  ck "$S lessons works without jq" eval 'rc_is 0 && [ "$(printf "%s\n" "$CY_OUT" | grep -c .)" = 32 ]'

  echo "== $S the store-free verbs work with jq hidden; the store readers say jq required =="
  new_repo nojq
  check "$S (fixture: jq is really hidden)" "! PATH=\"\$NOJQ\" \"\$CYBASH\" -c 'command -v jq' >/dev/null 2>&1"
  local ID=20260101-nojq
  mkplan "$WORK/nojq.md" "No jq" "1:One" "2:Two"
  nj init "$ID" --from-file "$WORK/nojq.md" --kind feature --source x
  ck "$S init without jq" eval 'rc_is 0 && line1_is "INIT|$ID|docs/cycles/$ID/plan.md" && [ -f "docs/cycles/$ID/record.md" ]'
  H0=$(git rev-parse HEAD)
  nj approve "$ID" --expect "$(c12 "docs/cycles/$ID/plan.md")"
  ck "$S approve without jq" approved_since "$H0" "docs/cycles/$ID/record.md"
  nj check "$ID"
  ck "$S check without jq" line1_re "^CHECK\\|go\\|cycle=$ID\\|"
  unlock "$ID"
  nj record "$ID" nj-001=D1 nj-002=D2
  ck "$S record without jq" line1_re "^RECORD\\|ok\\|cycle=$ID\\|"
  focus nj-001 nj-002
  nj status "$ID"
  ck "$S status (reads the store) without jq exits 4" rc_is 4
  ck "$S ...saying jq required" has "jq required"
  nj triggers "$ID"
  ck "$S triggers without jq exits 4, jq required" eval 'rc_is 4 && has "jq required"'
  nj close "$ID" none
  ck "$S close none without jq" eval 'rc_is 0 && [ "$(hmeta "docs/cycles/$ID/record.md" Status)" = closed ]'
  mkplan "$WORK/nojq2.md" "No jq two" "1:One"
  nj init 20260101-nojq2 --from-file "$WORK/nojq2.md" --kind feature --source x
  nj approve 20260101-nojq2 --expect "$(c12 docs/cycles/20260101-nojq2/plan.md)"
  nj retro-begin 20260101-nojq2
  ck "$S retro-begin without jq" eval 'rc_is 0 && line1_re "^RETRO\\|begin\\|cycle=20260101-nojq2\\|head="'
  printf '# retro\n' > docs/cycles/20260101-nojq2/retro.md
  nj note 20260101-nojq2 retro.md
  ck "$S note without jq" eval 'rc_is 0 && cpaths HEAD | grep -qF docs/cycles/20260101-nojq2/retro.md'
  nj abandon 20260101-nojq2
  ck "$S abandon without jq" eval 'rc_is 0 && [ "$(hmeta docs/cycles/20260101-nojq2/record.md Status)" = abandoned ]'
}

sc_slugs() {
  # Pure library code, so it runs once, not once per store.
  [ "$STORE_NAME" = files ] || return 0
  echo "== $S lesson slugs: acf-librarian's timeless regex, exactly, so the audit never flags one /retro wrote =="
  local s acc="" rej="" leak=""
  for s in api-v2beta auth-v1x x-v10 foo-20260101 20260101-foo v2-api good-lesson v-model level-v keep-tests vitest-runs x-v; do
    if ( . "$ACF_WHIP/skills/lib/acfw-plan.sh"; acfw_lesson_slug_ok "$s" ); then acc="$acc $s"; else rej="$rej $s"; fi
  done
  for s in $acc; do printf '%s\n' "$s" | grep -qE '[0-9]{8}|-v[0-9]+' && leak="$leak $s"; done
  check "$S no accepted slug matches the audit's '[0-9]{8}|-v[0-9]+' (accepted:$acc)" "[ -z '$leak' ]"
  for s in api-v2beta auth-v1x x-v10 foo-20260101 20260101-foo v2-api; do
    check "$S '$s' is refused" "case ' $rej ' in *' $s '*) true ;; *) false ;; esac"
  done
  # Accepted ones, so the rule cannot pass by refusing everything.
  for s in good-lesson v-model level-v keep-tests vitest-runs x-v; do
    check "$S '$s' is accepted" "case ' $acc ' in *' $s '*) true ;; *) false ;; esac"
  done
}

sc_repair() {
  local ID R P A H0 C p1 p2 r1 r2 RA RA1 RA2 L n
  echo "== $S hard rule 4: waiting on out-of-cycle work that moves by itself is /go, never /whip-doctor =="
  # A scoped /go pulls a task's unmet transitive deps into its scope, so a cycle task whose only
  # blocker is outside the cycle and can move is NOT a dead end. It used to count as gated with no
  # root card, and NEXT fell through to /whip-doctor, which then found nothing wrong.
  new_repo ext
  task e-900-ext pending
  task e-901-ext in-progress
  task e-902-ext accepted
  git branch worktree/e-902-ext        # a live task branch and no ledger marker: /go still integrates it
  task e-903-ext blocked none 0 3      # parked at the cap: a human gate
  task e-001-a pending e-900-ext
  task e-002-b pending e-901-ext
  task e-003-c pending e-902-ext
  task e-004-d pending e-903-ext
  task e-005-e pending e-900-ext,e-903-ext
  fx_cycle 20260101-exa "Exa" "1:A";   fx_record 20260101-exa e-001-a=D1
  fx_cycle 20260101-exb "Exb" "1:B";   fx_record 20260101-exb e-002-b=D1
  fx_cycle 20260101-exc "Exc" "1:C";   fx_record 20260101-exc e-003-c=D1
  fx_cycle 20260101-exd "Exd" "1:D";   fx_record 20260101-exd e-004-d=D1
  fx_cycle 20260101-exe "Exe" "1:E";   fx_record 20260101-exe e-005-e=D1
  for ID in exa exb exc; do
    cy status "20260101-$ID"
    case $ID in exa) A="PENDING" ;; exb) A="IN-PROGRESS" ;; *) A="accepted-awaiting-integration" ;; esac
    ck "$S the only cycle task waits on an out-of-cycle $A task: NEXT /go" next_is "NEXT /go"
    ck "$S ...never /whip-doctor, and invariants hold" eval 'lacks_re "^NEXT /whip-doctor" && inv'
  done
  cy status 20260101-exd
  ck "$S control: an out-of-cycle root PARKED at the cap is a gate, its REPLY is NEXT" next_is "NEXT /whip-move e-903-ext pending"
  cy status 20260101-exe
  ck "$S a task waiting on BOTH a movable dep and a parked root: the human gate wins" next_is "NEXT /whip-move e-903-ext pending"

  echo "== $S /go step 3a: the pinned line when the focus IS one approved cycle's unfinished work =="
  new_repo pin
  ID=20260101-pin
  task pn-001-a pending
  task pn-002-b pending
  task pn-003-c accepted none
  fx_cycle "$ID" "Pin" "1:A" "2:B" "3:C"
  fx_record "$ID" pn-001-a=D1 pn-002-b=D2 pn-003-c=D3
  focus pn-001-a pn-002-b
  cy status --if-cycle
  ck "$S focus = every unfinished task of the approved cycle: the exact line /go greps" out_has_line "  focus = the 2 runnable task(s) of approved cycle $ID"
  check "$S ...matching go/SKILL.md's grep byte for byte" \
    "printf '%s\n' \"\$CY_OUT\" | grep -qE '^  focus = the [0-9]+ runnable task\\(s\\) of approved cycle [0-9]{8}-[a-z0-9][a-z0-9-]*\$'"
  ck "$S ...printed first, before any capped fact" eval '[ "$(printf "%s\n" "$CY_OUT" | sed -n 2p)" = "  focus = the 2 runnable task(s) of approved cycle $ID" ]'
  focus pn-001-a pn-002-b pn-003-c
  cy status --if-cycle
  ck "$S a finished cycle task in the focus still matches (counted: the unfinished ones)" out_has_line "  focus = the 2 runnable task(s) of approved cycle $ID"
  focus pn-001-a
  cy status --if-cycle
  ck "$S the focus misses an unfinished cycle task: no line (take the confirmation)" eval '! printf "%s\n" "$CY_OUT" | grep -q "^  focus = "'
  task pn-900-loose pending
  focus pn-001-a pn-002-b pn-900-loose
  cy status --if-cycle
  ck "$S the focus holds a task outside the cycle: no line" eval '! printf "%s\n" "$CY_OUT" | grep -q "^  focus = "'
  focus pn-001-a pn-002-b
  printf '\n### D4: Amended\n' >> "docs/cycles/$ID/plan.md"
  cy status --if-cycle
  ck "$S an uncommitted amendment does not void the approved focus" out_has_line "  focus = the 2 runnable task(s) of approved cycle $ID"
  git checkout -q -- "docs/cycles/$ID/plan.md"
  fx_record "$ID" pn-099-ghost=D1
  focus pn-001-a pn-002-b pn-099-ghost
  cy status --if-cycle
  ck "$S a focus stem the store does not have (phantom): no line, /go asks first" eval 'rc_is 0 && ! printf "%s\n" "$CY_OUT" | grep -q "^  focus = "'

  echo "== $S the per-cycle lock is taken BEFORE record.md is read: concurrent writers lose nothing =="
  new_repo race
  ID=20260101-race; R="docs/cycles/$ID/record.md"; P="docs/cycles/$ID/plan.md"
  fx_cycle "$ID" "Race" "1:One" "2:Two" "3:Three"
  mkdir -p "$WORK/hooks-slow"
  printf '#!/bin/sh\nsleep 2\nexit 0\n' > "$WORK/hooks-slow/pre-commit"; chmod +x "$WORK/hooks-slow/pre-commit"
  git config core.hooksPath "$WORK/hooks-slow"
  "$CYBASH" "$CYCLE" record "$ID" ra-001-a=D1 </dev/null > "$WORK/race1.out" 2>&1 & p1=$!
  sleep 1
  "$CYBASH" "$CYCLE" record "$ID" rb-002-b=D2 </dev/null > "$WORK/race2.out" 2>&1 & p2=$!
  wait $p1; r1=$?; wait $p2; r2=$?
  check "$S two concurrent records both exit 0" "[ $r1 = 0 ] && [ $r2 = 0 ]"
  check "$S ...both mappings are in HEAD's ## Tasks" \
    "hrows '$R' Tasks | grep -qx '| D1 | ra-001-a |' && hrows '$R' Tasks | grep -qx '| D2 | rb-002-b |'"
  check "$S ...and both decomposed rows are in the Plan Log" "[ \"\$(hrows '$R' 'Plan Log' | cell 2 | grep -cx decomposed)\" = 2 ]"
  check "$S ...and neither writer set anything aside as 'local edits'" "! grep -q 'local edits' '$WORK/race1.out' '$WORK/race2.out'"
  # An amendment approve racing the writer's `record` (the /whip flow: yes starts /task --plan in the
  # background, and its writer's first command is record).
  printf '\n### D4: Four\n\n- AC4.1: it works\n' >> "$P"
  C=$(c12 "$P")
  "$CYBASH" "$CYCLE" approve "$ID" --expect "$C" </dev/null > "$WORK/race3.out" 2>&1 & p1=$!
  sleep 1
  "$CYBASH" "$CYCLE" record "$ID" rc-003-c=D3 </dev/null > "$WORK/race4.out" 2>&1 & p2=$!
  wait $p1; r1=$?; wait $p2; r2=$?
  git config core.hooksPath "$WORK/nohooks"
  check "$S approve racing record: both exit 0" "[ $r1 = 0 ] && [ $r2 = 0 ]"
  check "$S ...the amendment is approved at HEAD" "hmeta '$R' 'Approved Content' | grep -q '^v1:$C'"
  check "$S ...and every mapping survived (D1, D2, D3)" \
    "hrows '$R' Tasks | grep -qx '| D1 | ra-001-a |' && hrows '$R' Tasks | grep -qx '| D2 | rb-002-b |' && hrows '$R' Tasks | grep -qx '| D3 | rc-003-c |'"
  cy check "$ID"
  ck "$S ...so check decomposes only the new D4, never D1 again" line1_re "\\|uncovered=D4\\|"
  unlock "$ID"

  echo "== $S an edit made while approve waits is never committed under the card's approval =="
  new_repo wait
  ID=20260101-wait; R="docs/cycles/$ID/record.md"; P="docs/cycles/$ID/plan.md"
  fx_init "$ID" "Wait" "1:One"
  cp "$R" "$WORK/wait.rec"; C=$(c12 "$P"); H0=$(git rev-parse HEAD)
  mkdir -p "$REPO/.acfwhip/run/cycle/$ID/.lock"
  "$CYBASH" "$CYCLE" approve "$ID" --expect "$C" </dev/null > "$WORK/wait.out" 2>&1 & p1=$!
  sleep 2
  printf '\n### D2: Slipped in while approve waited\n' >> "$P"
  rmdir "$REPO/.acfwhip/run/cycle/$ID/.lock"
  wait $p1; r1=$?
  check "$S approve refuses 9: the plan is no longer the one on the card" "[ $r1 = 9 ]"
  ck "$S ...nothing committed" head_is "$H0"
  ck "$S ...record.md untouched" same "$R" "$WORK/wait.rec"
  check "$S ...and no approve command is handed out" "! grep -q 'acfw-cycle approve' '$WORK/wait.out'"

  echo "== $S a stale decompose lock is taken over by exactly one of two concurrent checks =="
  new_repo stale
  ID=20260101-stale
  fx_cycle "$ID" "Stale" "1:One"
  L="$REPO/.acfwhip/run/cycle-$ID.decomposing"; mkdir -p "$(dirname "$L")"; printf 'ts=1\n' > "$L"
  "$CYBASH" "$CYCLE" check "$ID" </dev/null > "$WORK/st1.out" 2>/dev/null & p1=$!
  "$CYBASH" "$CYCLE" check "$ID" </dev/null > "$WORK/st2.out" 2>/dev/null & p2=$!
  wait $p1; r1=$?; wait $p2; r2=$?
  check "$S exactly one CHECK|go" "[ \"\$(cat '$WORK/st1.out' '$WORK/st2.out' | grep -c '^CHECK|go|')\" = 1 ]"
  check "$S ...the other refuses 7 (lock held)" "[ \"\$(cat '$WORK/st1.out' '$WORK/st2.out' | grep -c '^CHECK|refuse|cycle=$ID|code=7|')\" = 1 ]"
  rm -f "$L"
  if command -v perl >/dev/null 2>&1; then
    # A lock with no ts= line is dated by mtime. GNU `stat -f` means --file-system: it prints a report
    # to STDOUT and fails, so trying the BSD form first made the age garbage and the lock fresh forever.
    mkdir -p "$WORK/gnustat"
    cat > "$WORK/gnustat/stat" <<'EOF'
#!/bin/sh
case "$1" in
  -f) printf '  File: "%s"\n    ID: 0        Namelen: 255     Type: apfs\n' "$3"; exit 1 ;;
  -c) exec perl -e 'print((stat($ARGV[0]))[9], "\n")' "$3" ;;
esac
exit 1
EOF
    chmod +x "$WORK/gnustat/stat"
    : > "$L"; touch -t 200001010000 "$L"
    PATH="$WORK/gnustat:$PATH" cy check "$ID"
    ck "$S a ts-less lock from 2000 under GNU stat is stale: check goes" line1_re "^CHECK\\|go\\|cycle=$ID\\|"
    unlock "$ID"
  fi

  echo "== $S a multi-line slug is refused whole (3), and nothing lands outside docs/cycles/ =="
  new_repo nl
  cy init "$(printf 'foo\n../../../../esc')" --kind feature --source x
  ck "$S init with a newline in the slug exits 3" rc_is 3
  check "$S ...writing no escaped folder" "[ ! -e '$REPO/esc' ] && [ ! -e '$REPO/docs/esc' ] && [ ! -e '$WORK/esc' ]"
  check "$S ...and no cycle folder at all" "[ ! -d '$REPO/docs/cycles' ] || [ -z \"\$(ls '$REPO/docs/cycles')\" ]"
  cy init "$(printf '20260101-ok\n../../x')" --kind feature --source x
  ck "$S a multi-line ID exits 3 too" rc_is 3
  fx_cycle 20260101-nl "Nl" "1:One"
  cy record 20260101-nl "$(printf 'nl-001\nx')=D1"
  ck "$S record refuses a multi-line stem (2)" rc_is 2
  cy approve 20260101-nl --expect "$(printf '%s\nzz' "$(c12 docs/cycles/20260101-nl/plan.md)")"
  ck "$S approve refuses a multi-line --expect (9)" rc_is 9

  echo "== $S Metadata values are one cell: --by cannot forge a second Status bullet =="
  new_repo meta
  ID=20260101-meta; R="docs/cycles/$ID/record.md"
  fx_init "$ID" "Meta" "1:One"
  cy approve "$ID" --expect "$(c12 "docs/cycles/$ID/plan.md")" --by "$(printf 'me@x\n- **Status**: closed')"
  ck "$S approve with a multi-line --by still approves" rc_is 0
  check "$S ...HEAD holds exactly one Status bullet, and it says approved" \
    "[ \"\$(git show HEAD:$R | grep -c '^- \\*\\*Status\\*\\*:')\" = 1 ] && [ \"\$(hmeta '$R' Status)\" = approved ]"

  echo "== $S a retro-actions cycle closes itself only when every deliverable is ✓ or cancelled =="
  new_repo rap
  RA=20260101-rap-retro-actions; R="docs/cycles/$RA/record.md"
  task rp-001-park blocked none 0 3
  task rp-002-unver accepted
  task rp-003-done accepted; integrate rp-003-done
  mkplan "$WORK/rap.$STORE_NAME.md" "Retro actions: rap" "1:Park" "2:Unver" "3:Done"
  cy init "$RA" --from-file "$WORK/rap.$STORE_NAME.md" --kind retro-actions --source "retro p20"
  fx_approve "$RA"
  fx_record "$RA" rp-001-park=D1 rp-002-unver=D2 rp-003-done=D3
  cy status "$RA"
  ck "$S parked (✗) and unverified (?) work: NEXT is the parked card's REPLY (redesign inside the cycle), not /whip \"<next goal>\"" next_is "NEXT /whip-move rp-001-park archive, then bash '$CYCLE' record $RA --drop rp-001-park, then /task --plan docs/cycles/$RA/plan.md"
  ck "$S ...and it never says the cycle closes itself" eval '! has "closes itself"'
  fx_cycle 20260101-rap-other "Other" "1:One"
  check "$S an unrelated approve does NOT close it" "[ \"\$(hmeta '$R' Status)\" = decomposed ]"
  check "$S ...and no close commit was made" "! git log --format=%s | grep -q '^docs(plan): close rap-retro-actions'"
  bash "$STORE_BIN" transition rp-001-park archive orchestrator "p20: dropped" 0 3 >/dev/null 2>&1 || bad "fixture: archive rp-001-park"
  cy status "$RA"
  ck "$S D1 cancelled, D2 still ?: NEXT is the ? card's REPLY" next_not_re '^NEXT /whip "'
  ck "$S ...a REPLY a card actually carries" eval 'printf "%s\n" "$CY_OUT" | grep "^  REPLY " | sed "s/^  REPLY //" | grep -qxF -- "$(nextl | sed "s/^NEXT //")"'
  fx_cycle 20260101-rap-other2 "Other two" "1:One"
  check "$S an unverified task survives an unrelated approve too" "[ \"\$(hmeta '$R' Status)\" = decomposed ]"
  integrate rp-002-unver
  cy status "$RA"
  ck "$S every deliverable ✓ or cancelled: it closes itself, NEXT /whip \"<next goal>\"" next_is 'NEXT /whip "<next goal>"'
  fx_cycle 20260101-rap-other3 "Other three" "1:One"
  check "$S ...and the next approve stamps it closed" "[ \"\$(hmeta '$R' Status)\" = closed ]"

  echo "== $S follow-through grades the PREVIOUS retro; this retro's own actions never hijack NEXT =="
  new_repo ft
  fx_cycle 20260101-ft1 "Ft one" "1:One"
  cy retro-begin 20260101-ft1
  printf '# Retro\n' > docs/cycles/20260101-ft1/retro.md
  RA1=20260101-ft1-retro-actions
  mkplan "$WORK/ft1.$STORE_NAME.md" "Retro actions: ft1" "1:X" "2:Y"
  cy init "$RA1" --from-file "$WORK/ft1.$STORE_NAME.md" --kind retro-actions --source "retro ft1"
  cy close 20260101-ft1 retro.md --actions "$RA1"
  ck "$S close with --actions exits 0" rc_is 0
  ck "$S ...the retro's own new actions are not graded as the previous retro" out_has_line "FOLLOW|none"
  nofocus
  cy status
  ck "$S a bare /whip after the retro: NEXT /whip \"<goal>\", not an approval of its actions" next_re '^NEXT /whip "'
  ck "$S ...with the standing card for the actions" card_names "/whip $RA1"
  fx_cycle 20260101-ft2 "Ft two" "1:One"
  cy retro-begin 20260101-ft2
  printf '# Retro\n' > docs/cycles/20260101-ft2/retro.md
  RA2=20260101-ft2-retro-actions
  local FL0 FLX FLA
  FL0=$( . "$ACF_WHIP/skills/lib/acfw-plan.sh"; acfw_plan_follow "$REPO" 20260101-ft2 | head -1 )
  mkplan "$WORK/ft2.$STORE_NAME.md" "Retro actions: ft2" "1:Z"
  cy init "$RA2" --from-file "$WORK/ft2.$STORE_NAME.md" --kind retro-actions --source "retro ft2"
  # The new actions folder sorts last by ID, so without the exclusion it IS the "previous" retro.
  FLX=$( . "$ACF_WHIP/skills/lib/acfw-plan.sh"; acfw_plan_follow "$REPO" 20260101-ft2 | head -1 )
  FLA=$( . "$ACF_WHIP/skills/lib/acfw-plan.sh"; acfw_plan_follow "$REPO" 20260101-ft2 "$RA2" | head -1 )
  check "$S (control: unexcluded, the brand-new actions folder would be graded)" "printf '%s' '$FLX' | grep -q '^FOLLOW|$RA2|'"
  check "$S acfw_plan_follow's extra ids exclude it, restoring the earlier answer" "[ '$FLA' = '$FL0' ]"
  cy close 20260101-ft2 retro.md --actions "$RA2"
  ck "$S the next retro's follow-through names the previous retro's actions" line1_re "^FOLLOW\\|$RA1\\|status=draft\\|ds=2\\|uncovered=D1,D2\$"
  ck "$S ...exactly the line it gave before this retro created $RA2, never naming $RA2" eval '[ "$(line1)" = "$FL0" ] && ! line1 | grep -qF "$RA2"'
  # $RA2's Source is "retro ft2", not "retro 20260101-ft2", so only close's --actions pass-through
  # keeps it out: the two assertions above fail if cmd_close stops passing the id on.

  echo "== $S follow-through grades a plan-less retro's UNTRACKED actions draft; only this retro's own drafts are skipped =="
  new_repo ftpl
  local RAP=20260101-pl-retro-actions FQ=20260102-fq DQ1 DQ2 DQ3
  fx_cycle 20260101-fp "Fp" "1:One"
  # What /retro --force leaves behind: an actions cycle it never commits (approving it commits it).
  cy init "$RAP" --kind retro-actions --source "retro docs/retrospectives/20260101-pl.md" --title "Retro actions: pl"
  mkplan "docs/cycles/$RAP/plan.md" "Retro actions: pl" "1:X" "2:Y"
  check "$S (fixture: the plan-less retro's actions are an untracked draft)" "untracked_folder '$RAP'"
  cy close 20260101-fp none
  ck "$S a clean close reports the plan-less retro's items, not 'no earlier retro'" line1_is "FOLLOW|$RAP|status=draft|ds=2|uncovered=D1,D2"
  ck "$S ...and still closes" eval 'rc_is 0 && lastl | grep -q "^CLOSE|ok|"'
  # A rerun of THIS retro: the first attempt left its draft behind (Source "retro <ID>", once plain as
  # /retro runs init, once with an imported plan's blob). Both sort after $RAP, so grading either
  # would hide the real previous retro.
  DQ1="$FQ-retro-actions"; DQ2="$FQ-retro-actions-2"; DQ3="$FQ-retro-actions-3"
  fx_cycle "$FQ" "Fq" "1:One"
  cy init "$DQ1" --kind retro-actions --source "retro $FQ" --title "Retro actions: fq"
  mkplan "$WORK/fq.$STORE_NAME.md" "Retro actions: fq" "1:Z"
  cy init "$DQ2" --from-file "$WORK/fq.$STORE_NAME.md" --kind retro-actions --source "retro $FQ"
  check "$S (fixture: the imported dead draft's Source carries a blob)" "wmeta docs/cycles/$DQ2/record.md Source | grep -q '^retro $FQ (blob [0-9a-f]\\{12\\})\$'"
  cy retro-begin "$FQ"
  printf '# Retro\n' > "docs/cycles/$FQ/retro.md"
  cy init "$DQ3" --kind retro-actions --source "retro $FQ" --title "Retro actions: fq"
  mkplan "docs/cycles/$DQ3/plan.md" "Retro actions: fq" "1:Z"
  check "$S (control: without the Source rule, a dead draft of this retro is graded)" \
    "( . '$ACF_WHIP/skills/lib/acfw-plan.sh'; acfw_plan_follow '$REPO' '$FQ' '$DQ3' | head -1 ) | grep -q '^FOLLOW|$DQ2|'"
  cy close "$FQ" retro.md --actions "$DQ3"
  ck "$S close skips this retro's own dead drafts and grades the plan-less retro's draft" line1_is "FOLLOW|$RAP|status=draft|ds=2|uncovered=D1,D2"
  ck "$S ...and the close commits" eval 'rc_is 0 && lastl | grep -q "^CLOSE|ok|.*|actions=$DQ3|"'

  echo "== $S a live decomposition: recorded-but-uncreated stems are 'being created', never phantoms =="
  new_repo live
  ID=20260101-live
  fx_cycle "$ID" "Live" "1:One" "2:Two"
  cy check "$ID"
  cy record "$ID" lv-001-a=D1
  focus lv-001-a
  cy status "$ID"
  ck "$S no --drop REPLY for a stem the running writer is about to create" eval '! has "--drop"'
  ck "$S ...it shows as being created" has "(being created)"
  ck "$S ...and NEXT is the decomposition's wait" next_re '^NEXT wait: /task --plan is decomposing'
  cy triggers "$ID"
  ck "$S ...and fires no gap trigger" out_has_line "TRIGGERS|none"
  unlock "$ID"
  cy status "$ID"
  ck "$S the lock gone (the writer died): the phantom card is back" has "--drop lv-001-a"

  echo "== $S CRLF (core.autocrlf=true): the record reads the same =="
  new_repo crlf
  git config core.autocrlf true
  ID=20260101-crlf; R="docs/cycles/$ID/record.md"
  task cr-001-a pending
  fx_cycle "$ID" "Crlf" "1:One" "2:Two"
  fx_record "$ID" cr-001-a=D1
  rm -f "$R"; git checkout -q -- "$R"
  check "$S (fixture: the working record really has CRLF endings)" "grep -q \"\$(printf '\\r')\" '$R'"
  focus cr-001-a
  cy status
  ck "$S a bare status finds the cycle through the focus" eval 'lacks_re "no active cycle" && next_is "NEXT /task --plan docs/cycles/$ID/plan.md"'
  ck "$S ...with no false working-tree approval WARN" eval '! has "exists only in the working tree"'
  cy status --if-cycle --after-run complete --mode default
  ck "$S the /go tail still prints" eval 'inv && [ -n "$CY_OUT" ]'
  cy record "$ID" cr-002-b=D2
  ck "$S record on a CRLF checkout: no 'local edits' set aside" eval 'rc_is 0 && ! has "local edits"'
  fx_init 20260101-crlfd "Crlf draft" "1:One"
  awk '{ printf "%s\r\n", $0 }' docs/cycles/20260101-crlfd/record.md > "$WORK/crlf.tmp" && mv -f "$WORK/crlf.tmp" docs/cycles/20260101-crlfd/record.md
  cy status 20260101-crlfd
  ck "$S a CRLF draft is still a cycle (its approval card shows)" eval 'rc_is 0 && has "  content="'

  echo "== $S a repo path with a space: every pasted path is one shell word =="
  new_repo "sp ace" --no-mode
  ID=20260101-space
  task sp-001-a accepted
  fx_cycle "$ID" "Space" "1:One" "2:Uncovered, so check goes"
  fx_record "$ID" sp-001-a=D1
  focus sp-001-a
  cy status
  ck "$S the pin card's REPLY quotes the config path" has "f='$REPO/.acfwhip/config';"
  local sp_reply
  sp_reply=$(printf '%s\n' "$CY_OUT" | awk '/^  WHAT ACFW_INTEGRATION_MODE is not pinned/ {w=1; next} w && /^  REPLY / {sub(/^  REPLY /, ""); print; exit}')
  ( cd "$WORK" && /bin/bash -c "$sp_reply" ) >/dev/null 2>&1
  check "$S ...and run as pasted, it pins that file and writes no stray one" \
    "grep -qx 'ACFW_INTEGRATION_MODE=default' '$REPO/.acfwhip/config' && [ ! -e '$WORK/$STORE_NAME-sp' ]"
  rm -f "$REPO/.acfwhip/config"
  cy check "$ID"
  cy check "$ID"
  ck "$S the lock refusal's rm quotes the path" has "rm '$REPO/.acfwhip/run/cycle-$ID.decomposing'"
  unlock "$ID"
}

# ---- review round 2: each block below reproduces one reviewed defect, then pins the repair ----------
sc_readfail() {
  echo "== $S a store that answers the snapshot but not a read: fail closed, never a clean close =="
  new_repo rdo
  local ID=20260101-rdo R
  task ro-001-a accepted none 3 2; integrate ro-001-a
  fx_cycle "$ID" "Read outage" "1:One"
  fx_record "$ID" ro-001-a=D1
  focus ro-001-a
  cy triggers "$ID"
  ck "$S healthy: rework fires" out_has_line "TRIGGER|rework|ro-001-a|rc=3"
  ck "$S healthy: stuck fires" out_has_line "TRIGGER|stuck|ro-001-a|bc=2"
  calls_reset; P20_READ_OUTAGE=5 cy triggers "$ID"
  ck "$S read outage: never TRIGGERS|none" eval '! has "TRIGGERS|none"'
  if grep -q ' read ' "$P20_CALL_LOG"; then
    ck "$S ...triggers exits 4" rc_is 4
    ck "$S ...stage unknown: run /whip-doctor" has "stage unknown: run /whip-doctor"
  else
    ck "$S ...(this store keeps accepted tasks in the snapshot: no read, the triggers still fire)" out_has_line "TRIGGER|rework|ro-001-a|rc=3"
  fi
  for a in 5 6 99; do
    P20_READ_OUTAGE=$a cy status
    ck "$S read exit $a in the CLOSE stage: never 'retro: clean'" eval '! has "retro: clean"'
    if [ "$STORE_NAME" = multica ]; then
      ck "$S ...exits 4 with NEXT /whip-doctor" eval 'rc_is 4 && next_is "NEXT /whip-doctor" && inv'
    else
      ck "$S ...the trigger still fires (files needs no read)" eval 'rc_is 0 && has "trigger fired"'
    fi
  done
  P20_READ_OUTAGE=5 cy status --after-run complete --mode default
  ck "$S --after-run with a read outage never says clean" eval '! has "retro: clean"'
  [ "$STORE_NAME" = multica ] && ck "$S ...and exits 4" rc_is 4
  P20_READ_OUTAGE=5 cy close "$ID" none --if-done
  ck "$S close --if-done of a feature cycle is refused before any read (3)" rc_is 3

  echo "== $S a failed read of a finished NON-code task is never a ? card offering to re-run it =="
  new_repo rdn
  ID=20260101-rdn
  task nc-001-a accepted none 0 0 none
  fx_cycle "$ID" "Non code" "1:One"
  fx_record "$ID" nc-001-a=D1
  focus nc-001-a
  cy status
  ck "$S healthy: a non-code accepted task is ✓ and the cycle goes to /retro" eval 'cov_is D1 ✓ && next_re "^NEXT /retro( |$)"'
  rm -f "$REPO/.acfwhip/run/cycle/$ID/settled"
  P20_READ_OUTAGE=5 cy status
  ck "$S read outage: no card hands out /whip-move nc-001-a pending" eval '! has "/whip-move nc-001-a pending"'
  ck "$S ...and nothing says unverified" eval '! has "unverified"'
  [ "$STORE_NAME" = multica ] && ck "$S ...exits 4, NEXT /whip-doctor" eval 'rc_is 4 && next_is "NEXT /whip-doctor"'
  cy status
  ck "$S control: the store back, ✓ again" cov_is D1 ✓
}

sc_resolution2() {
  echo "== $S a tie of candidates never outranks row 3, and is never called idle =="
  new_repo tie
  fx_cycle 20260101-alpha "Alpha" "1:One"
  fx_cycle 20260101-beta "Beta" "1:One"
  nofocus
  cy status
  ck "$S two approved, undecomposed cycles: NEXT /whip <the first>" next_is "NEXT /whip 20260101-alpha"
  ck "$S ...both are listed as cards" eval 'card_names "/whip 20260101-alpha" && card_names "/whip 20260101-beta"'
  ck "$S ...and no idle fact beside them" eval '! has "idle:"'
  ck "$S ...invariants" inv
  mkdir -p "$(dirname "$(runlock_path)")"; : > "$(runlock_path)"
  cy status
  ck "$S a fresh /go run lock wins: NEXT wait" next_is "NEXT wait: /go is running"
  ck "$S ...the candidates are still listed" card_names "/whip 20260101-beta"
  ck "$S ...invariants" inv
  rm -f "$(runlock_path)"

  echo "== $S a focus that reaches a cycle AND holds a plan-less hotfix: row 4 still fires =="
  new_repo hot
  local ID=20260101-hot
  task a-001-one accepted; integrate a-001-one
  task z-hotfix pending
  fx_cycle "$ID" "Hot" "1:One"
  fx_record "$ID" a-001-one=D1
  focus a-001-one z-hotfix
  cy status
  ck "$S the plan-less hotfix can move: NEXT /go (not /retro)" next_is "NEXT /go"
  ck "$S ...and status says why" has "without a plan"
  ck "$S ...no /go step-3a line (the focus is not only this cycle)" eval '! printf "%s\n" "$CY_OUT" | grep -q "^  focus = "'
  ck "$S ...invariants" inv

  echo "== $S a CLOSED cycle's stems left in the focus are not plan-less work =="
  new_repo cfx
  ID=20260101-cfx
  task cf-001-one accepted none 2 0; integrate cf-001-one
  fx_cycle "$ID" "Closed focus" "1:One"
  fx_record "$ID" cf-001-one=D1
  focus cf-001-one
  cy close "$ID" none
  ck "$S (fixture: closed)" rc_is 0
  calls_reset; cyc status
  ck "$S a bare status after the close: no 'plan-less trigger' for the retro'd work" eval '! has "plan-less trigger"'
  ck "$S ...NEXT /whip \"<goal>\"" next_re '^NEXT /whip "'
  ck "$S ...and it asked the store nothing" zero_calls

  echo "== $S row 6 under a live decomposition lock: the card still prints the exact git mv =="
  new_repo pml
  ID=20260101-pml
  task pl-001 pending
  fx_cycle "$ID" "Plan missing locked" "1:One"
  fx_record "$ID" pl-001=D1
  focus pl-001
  printf 'ts=%s\n' "$(date -u +%s)" > "$REPO/.acfwhip/run/cycle-$ID.decomposing"
  git mv "docs/cycles/$ID/plan.md" "docs/cycles/$ID/spec.md"
  cy status
  ck "$S row 3 owns NEXT" next_re '^NEXT wait: /task --plan is decomposing'
  ck "$S ...and the plan-missing card's REPLY is the exact git mv" out_has_line "  REPLY git mv docs/cycles/$ID/spec.md docs/cycles/$ID/plan.md"
  ck "$S ...invariants" inv
  git mv "docs/cycles/$ID/spec.md" "docs/cycles/$ID/plan.md"; rm -f "$REPO/.acfwhip/run/cycle-$ID.decomposing"

  echo "== $S a hand-edited approved row is not a dead end: /whip <ID> shows the approval card =="
  new_repo rmm
  ID=20260101-rmm; local R="docs/cycles/$ID/record.md" C
  task rm-001 pending
  fx_cycle "$ID" "Row mismatch" "1:One"
  fx_record "$ID" rm-001=D1
  C=$(c12 "docs/cycles/$ID/plan.md")
  awk -v c="$C" '/^\| / && !d && $0 ~ ("\\| approved \\|") { sub(c, "ffffffffffff"); d=1 } { print }' "$R" > "$R.t" && mv "$R.t" "$R"
  git commit -qm "hand edit row" -- "$R"
  cy status "$ID"
  ck "$S unchanged plan, every D covered: the explicit status shows the approval card" out_has_line "  content=$C"
  ck "$S ...invariants" inv
  cy approve "$ID" --expect "$C"
  ck "$S ...and approve re-binds it" rc_is 0
  cy check "$ID"
  ck "$S check no longer refuses (covered)" line1_is "CHECK|noop|cycle=$ID|reason=covered"

  echo "== $S /go's step-3a line never stands beside a row-3 wait =="
  new_repo pinw
  ID=20260101-pinw
  task pw-001-a pending
  task pw-002-b pending
  fx_cycle "$ID" "Pin wait" "1:A" "2:B"
  fx_record "$ID" pw-001-a=D1 pw-002-b=D2
  focus pw-001-a pw-002-b
  cy status --if-cycle
  ck "$S control: the line prints" out_has_line "  focus = the 2 runnable task(s) of approved cycle $ID"
  mkdir -p "$(dirname "$(runlock_path)")"; : > "$(runlock_path)"
  cy status --if-cycle
  ck "$S a fresh /go run lock: no line, NEXT wait" eval '! printf "%s\n" "$CY_OUT" | grep -q "^  focus = " && next_is "NEXT wait: /go is running"'
  rm -f "$(runlock_path)"
  printf 'ts=%s\n' "$(date -u +%s)" > "$REPO/.acfwhip/run/cycle-$ID.decomposing"
  cy status --if-cycle
  ck "$S this cycle decomposing: no line, NEXT wait" eval '! printf "%s\n" "$CY_OUT" | grep -q "^  focus = " && next_re "^NEXT wait: /task --plan"'
  rm -f "$REPO/.acfwhip/run/cycle-$ID.decomposing"

  echo "== $S the trailer lookup is cached per commit =="
  cy status "$ID"
  check "$S the verdict is cached under run state, keyed by HEAD" \
    "[ \"\$(cut -d' ' -f1 '$REPO/.acfwhip/run/cycle/$ID/trailer' 2>/dev/null)\" = \"\$(git rev-parse HEAD)\" ]"
  check "$S ...and says found" "[ \"\$(cut -d' ' -f3 '$REPO/.acfwhip/run/cycle/$ID/trailer')\" = 1 ]"
}

sc_writers2() {
  echo "== $S a plan commit verifies ITS commit, not HEAD: another writer committing on top is fine =="
  new_repo busy
  local ID=20260101-busy R="docs/cycles/20260101-busy/record.md" P="docs/cycles/20260101-busy/plan.md" i bg c bad=0 C
  fx_cycle "$ID" "Busy" "1:One" "2:Two" "3:Three"
  rm -f "$WORK/busy.stop"
  ( n=0; while [ ! -e "$WORK/busy.stop" ]; do n=$((n+1)); echo $n > busy.txt
      git add busy.txt >/dev/null 2>&1 && git commit -q -m "busy $n" -- busy.txt >/dev/null 2>&1; sleep 0.1; done ) &
  bg=$!
  for i in 1 2 3 4 5 6; do
    cy record "$ID" "bz-00$i-x=D$(( (i % 3) + 1 ))"
    rc_is 0 || { bad=$((bad+1)); echo "        record $i -> rc=$CY_RC: $(printf '%s' "$CY_ERR" | head -2 | tr '\n' ' ')"; }
  done
  check "$S six records racing a busy committer all exit 0" "[ $bad = 0 ]"
  printf '\n### D4: Four\n\n- AC4.1: it works\n' >> "$P"; C=$(c12 "$P")
  cy approve "$ID" --expect "$C"
  ck "$S an amendment approve racing it exits 0" rc_is 0
  c=$(line1 | sed -n 's/.*|commit=\([0-9a-f]*\)$/\1/p')
  check "$S ...commit= names the approve commit, not whatever is HEAD" \
    "[ -n '$c' ] && [ \"\$(git log -1 --format=%s '$c')\" = 'docs(plan): approve busy' ]"
  check "$S ...which carries exactly plan.md and record.md" "[ \"\$(cpaths '$c')\" = '$P $R' ]"
  cy close "$ID" none
  ck "$S close none racing it exits 0" rc_is 0
  c=$(printf '%s\n' "$CY_OUT" | grep '^CLOSE|ok|' | sed -n 's/.*|commit=\([0-9a-f]*\)$/\1/p')
  check "$S ...commit= names the close commit" "[ -n '$c' ] && [ \"\$(git log -1 --format=%s '$c')\" = 'docs(plan): close busy' ]"
  : > "$WORK/busy.stop"; wait "$bg" 2>/dev/null
  check "$S (fixture: the committer really committed meanwhile)" "[ \"\$(git log --format=%s | grep -c '^busy ')\" -gt 3 ]"
  check "$S every decompose commit carries record.md alone" \
    "[ -z \"\$(git log --format=%H --grep='^docs(plan): decompose busy' | while read -r h; do [ \"\$(cpaths \$h)\" = '$R' ] || echo \$h; done)\" ]"
  check "$S ...and all six mappings are in HEAD's ## Tasks" "[ \"\$(hrows '$R' Tasks | grep -o 'bz-00[0-9]-x' | sort -u | grep -c .)\" = 6 ]"

  # Deterministic form of the same race: a post-commit hook lands another writer's commit before
  # `git commit` even returns, so HEAD is never the plan commit when the checks run.
  mkdir -p "$WORK/hooks-post"
  cat > "$WORK/hooks-post/post-commit" <<'EOF'
#!/bin/sh
[ -n "${P20_IN_HOOK:-}" ] && exit 0
date +%s%N >> busy-post.txt; git add busy-post.txt
P20_IN_HOOK=1 git commit -q -m "another writer" -- busy-post.txt >/dev/null 2>&1
exit 0
EOF
  chmod +x "$WORK/hooks-post/post-commit"
  new_repo post
  ID=20260101-post; R="docs/cycles/$ID/record.md"; P="docs/cycles/$ID/plan.md"
  fx_init "$ID" "Post" "1:One" "2:Two"
  git config core.hooksPath "$WORK/hooks-post"
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S approve with a commit landing right after it: exit 0" rc_is 0
  c=$(line1 | sed -n 's/.*|commit=\([0-9a-f]*\)$/\1/p')
  check "$S ...commit= is the approve commit, and HEAD is not" \
    "[ -n '$c' ] && [ \"\$(git log -1 --format=%s '$c')\" = 'docs(plan): approve post' ] && [ \"\$(git log -1 --format=%s HEAD)\" = 'another writer' ]"
  cy record "$ID" po-001=D1
  ck "$S record: exit 0" eval 'rc_is 0 && line1_is "RECORD|ok|cycle=$ID|tasks=1"'
  cy close "$ID" none
  ck "$S close none: exit 0" rc_is 0
  c=$(printf '%s\n' "$CY_OUT" | grep '^CLOSE|ok|' | sed -n 's/.*|commit=\([0-9a-f]*\)$/\1/p')
  check "$S ...commit= is the close commit" "[ -n '$c' ] && [ \"\$(git log -1 --format=%s '$c')\" = 'docs(plan): close post' ]"
  git config core.hooksPath "$WORK/nohooks"

  echo "== $S intent-to-add waits out a held index.lock instead of failing at once =="
  new_repo itl
  fx_init 20260101-itl "Itl" "1:One"
  local H0; H0=$(git rev-parse HEAD)
  : > .git/index.lock; ( sleep 2; rm -f "$REPO/.git/index.lock" ) & bg=$!
  cy approve 20260101-itl --expect "$(c12 docs/cycles/20260101-itl/plan.md)"
  wait "$bg" 2>/dev/null
  ck "$S a first approve of an untracked draft during a held index.lock still commits" approved_since "$H0" docs/cycles/20260101-itl/record.md

  echo "== $S rule 10 holds while this cycle's /task --plan decomposes (## Tasks still empty) =="
  new_repo r10d
  ID=20260101-r10d; P="docs/cycles/$ID/plan.md"; R="docs/cycles/$ID/record.md"
  fx_cycle "$ID" "R10 racing" "1:Login form" "2:Password reset"
  cy check "$ID"
  ck "$S (fixture: check went and took the lock)" line1_re "^CHECK\\|go\\|cycle=$ID\\|"
  mkplan "$P" "R10 racing" "1:Login form" "2:Audit log" "3:Password reset"
  H0=$(git rev-parse HEAD); cp "$R" "$WORK/r10d.rec"
  cy status "$ID"
  ck "$S the card preview refuses the renumbering" has "D-ids are never renumbered"
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S a renumbered D under a running decomposition: approve refuses 8" rc_is 8
  ck "$S ...nothing committed" head_is "$H0"
  ck "$S ...record.md untouched" same "$R" "$WORK/r10d.rec"
  mkplan "$P" "R10 racing" "1:Login form"
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S a removed D under a running decomposition: approve refuses 8" rc_is 8
  mkplan "$P" "R10 racing" "1:Login form" "2:Password reset" "3:Audit log"
  cy approve "$ID" --expect "$(c12 "$P")"
  ck "$S control: appending D3 still approves" approved_since "$H0" "$R"
  unlock "$ID"

  echo "== $S init refuses a slug whose cycle still exists at HEAD =="
  new_repo inith
  fx_cycle 20260101-dup "Dup" "1:One"
  rm -rf docs/cycles/20260101-dup
  cy init 20260101-dup --kind feature --source x
  ck "$S a cycle deleted only in the working tree: init refuses 3" rc_is 3
  ck "$S ...saying it exists at HEAD" has "exists at HEAD"
  check "$S ...and wrote nothing" "[ ! -e docs/cycles/20260101-dup ]"

  echo "== $S a hook that rewrites record.md fails record and close none loudly (11) =="
  mkdir -p "$WORK/hooks-rec"
  cat > "$WORK/hooks-rec/pre-commit" <<'EOF'
#!/bin/sh
for f in $(git diff --cached --name-only); do
  case "$f" in docs/cycles/*/record.md) printf '\nreformatted by a hook\n' >> "$f"; git add "$f" ;; esac
done
exit 0
EOF
  chmod +x "$WORK/hooks-rec/pre-commit"
  new_repo recfmt
  ID=20260101-recfmt
  fx_cycle "$ID" "Rec fmt" "1:One"
  git config core.hooksPath "$WORK/hooks-rec"
  cy record "$ID" rf-001=D1
  ck "$S record: exit 11" rc_is 11
  ck "$S ...the FATAL names record.md" has "rewrote docs/cycles/$ID/record.md"
  cy close "$ID" none
  ck "$S close none: exit 11" rc_is 11
  ck "$S ...the FATAL names record.md" has "rewrote docs/cycles/$ID/record.md"
  git config core.hooksPath "$WORK/nohooks"

  echo "== $S the spec gate: an edit made while it runs is refused (9); a gate that cannot run is 4, never 2 =="
  local STUB="$WORK/stubplug" SC
  rm -rf "$STUB"; mkdir -p "$STUB"
  for a in skills content adapters; do cp -R "$ACF_WHIP/$a" "$STUB/$a"; done
  cat > "$STUB/skills/lib/bin/acfw-spec" <<'EOF'
#!/usr/bin/env bash
# p20 stub: only the gate does anything.
case "${1:-}" in
  gate) case "${P20_GATE:-ok}" in
          edit)  printf '\nedited while the gate ran\n' >> "$ACFW_TRUNK_ROOT/$2"; exit 0 ;;
          crash) echo "p20 stub: bad declaration" >&2; exit 2 ;;
          *)     exit 0 ;;
        esac ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB/skills/lib/bin/acfw-spec"
  SC="$STUB/skills/lib/bin/acfw-cycle"
  new_repo gate
  mkdir -p .acfwhip/spec-tools; printf 'kind=review\n' > .acfwhip/spec-tools/p20
  ID=20260101-gate; R="docs/cycles/$ID/record.md"; P="docs/cycles/$ID/plan.md"
  fx_init "$ID" "Gate" "1:One"
  H0=$(git rev-parse HEAD); cp "$R" "$WORK/gate.rec"; C=$(c12 "$P")
  P20_GATE=edit CYCLE="$SC" cy approve "$ID" --expect "$C"
  ck "$S plan.md edited after the first hash: approve refuses 9" rc_is 9
  ck "$S ...nothing committed" head_is "$H0"
  ck "$S ...record.md byte-identical" same "$R" "$WORK/gate.rec"
  C=$(c12 "$P")
  P20_GATE=crash CYCLE="$SC" cy approve "$ID" --expect "$C"
  ck "$S a gate that exits 2 (its own declaration error): approve exits 4, not 2 (usage)" rc_is 4
  ck "$S ...saying the gate could not run" has "spec gate could not run"
  ck "$S ...nothing committed" head_is "$H0"
  CYCLE="$SC" cy approve "$ID" --expect "$C"
  ck "$S control: a gate that passes approves" approved_since "$H0" "$R"
}

sc_final350() {
  echo "== $S cards tell the truth: a missing dependency is new work plus a new edge =="
  # The doctor only reports a dangling dependency, so /whip-doctor as the REPLY sent the user round a
  # loop. The remedy is /task for the missing work, then an edge from the dependent to the new id, and
  # whip-move needs the dependent's CURRENT state before any flag (a bare --add-dep is a usage error).
  new_repo dm
  local ID=20260101-dm R
  task dm-001-needs pending dm-999-nope
  fx_cycle "$ID" "Missing dep" "1:Needs"
  fx_record "$ID" dm-001-needs=D1
  focus dm-001-needs
  cy status
  ck "$S invariants" inv
  local wm; wm="$ACF_WHIP/skills/whip-move/bin/whip-move.sh"
  # Files only: its scanner keeps every task in view, so an unresolved token is provably missing. A raw
  # adapter's closure drops accepted deps, so there an unresolved token is usually done work and the
  # classifier (like whip-go's depsSatisfied) must not call it missing.
  if [ "$STORE_NAME" = files ]; then
    ck "$S the missing-dependency card names the missing id" card_names "dm-999-nope"
    ck "$S ...its REPLY is /task plus an --add-dep that names the dependent's state" \
      out_has_line '  REPLY /task "<the missing work>", then /whip-move dm-001-needs pending --add-dep <new id>'
    ck "$S ...and it never hands out /whip-doctor, which only reports the dangling id" eval '! card_names "/whip-doctor"'
    # The REPLY's whip-move half must be a command whip-move accepts, not only a string that reads well.
    bash "$wm" dm-001-needs pending --add-dep dm-002-new >/dev/null 2>"$WORK/wm.err"
    check "$S ...and that whip-move call is accepted (the dependency is added in place)" \
      "grep -q '^- \*\*Dependencies\*\*: dm-999-nope, dm-002-new\$' .backlog/pending/dm-001-needs.md"
  fi

  echo "== $S triggers waits for a live /go, like retro-begin, close and note =="
  new_repo tl
  ID=20260101-tl
  task tl-001-a accepted; integrate tl-001-a
  fx_cycle "$ID" "Trig lock" "1:One"
  fx_record "$ID" tl-001-a=D1
  focus tl-001-a
  mkdir -p "$(dirname "$(runlock_path)")"; printf '{"pid":1}\n' > "$(runlock_path)"
  cy triggers "$ID"
  ck "$S a fresh /go run lock: triggers exits 7" rc_is 7
  ck "$S ...saying wait: /go is running" has "wait: /go is running"
  ck "$S ...and prints no TRIGGER lines (a half-written store is not evidence)" eval '! has_re "^TRIGGER"'
  rm -f "$(runlock_path)"
  cy triggers "$ID"
  ck "$S ...and once the run is gone, the same call answers" eval 'rc_is 0 && [ "$CY_OUT" = "TRIGGERS|none" ]'

  echo "== $S SHIP: after a close, status says how many commits are not pushed =="
  new_repo ship
  git clone -q --bare "$REPO" "$REPO.remote.git" 2>/dev/null
  git remote add origin "$REPO.remote.git"; git push -q -u origin trunk 2>/dev/null
  ID=20260101-ship
  task sh-001-a accepted; integrate sh-001-a
  fx_cycle "$ID" "Ship" "1:One"
  fx_record "$ID" sh-001-a=D1
  focus sh-001-a
  cy close "$ID" none
  ck "$S fixture: the clean close commits" rc_is 0
  cy status
  ck "$S bare status after the close is idle" next_is 'NEXT /whip "<goal>"'
  ck "$S ...and says how many commits are not pushed (shipping is yours)" has_re '^  [0-9]+ commit\(s\) not pushed to origin/trunk \(shipping is yours\)$'
  cy status "$ID"
  ck "$S status <closed ID> (row 12) says it too" eval 'next_is "NEXT /whip \"<next goal>\"" && has_re "^  [0-9]+ commit\\(s\\) not pushed to origin/trunk"'
  git push -q origin trunk 2>/dev/null
  cy status
  ck "$S ...and nothing once everything is pushed" eval '! has "not pushed"'

  echo "== $S CLOSE waits for a ? deliverable: an unverified task never closes clean =="
  new_repo uv
  ID=20260101-uv
  task uv-001-a accepted
  fx_cycle "$ID" "Unverified" "1:One"
  fx_record "$ID" uv-001-a=D1
  focus uv-001-a
  cy status
  ck "$S invariants" inv
  ck "$S D1 is ?" cov_is D1 '?'
  ck "$S all terminal with a ?: NEXT is not /retro (a clean close would bury the ? card)" next_not_re '^NEXT /retro( |$)'
  ck "$S ...and never says clean" eval '! has "retro: clean"'
  if [ "$STORE_NAME" = files ]; then
    ck "$S ...NEXT is the ? card's REPLY (the --integrated-at ack)" next_is "NEXT /whip-move uv-001-a accepted --integrated-at <sha of the commit that holds it>"
  else
    ck "$S ...NEXT is the ? card's REPLY (the runbook's ledger-marker recipe)" next_re '^NEXT .*accepted-branchless-unverified'
  fi
  integrate uv-001-a
  cy status
  ck "$S once the ? is settled, NEXT falls through to /retro" next_is "NEXT /retro $ID"
}

suite() {
  use_store "$1"
  if [ -n "${P20_ONLY:-}" ]; then for a in $P20_ONLY; do "$a"; done; return; fi   # dev: P20_ONLY="sc_txn sc_close"
  sc_setup
  sc_planless
  sc_alpha
  sc_notcycles
  sc_trailers
  sc_txn
  sc_gitstate
  sc_shapes
  sc_coverage
  sc_phantom
  sc_gated
  sc_close
  sc_history
  sc_lessons_nojq
  sc_slugs
  sc_repair
  sc_readfail
  sc_resolution2
  sc_writers2
  sc_final350
}

suite files
suite multica

echo
echo "phase20-cycle: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
