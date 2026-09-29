#!/usr/bin/env bash
# phase19-research-preflight.test.sh — /research's Step 1 prerequisite block (3.4.3).
#
# WHY THIS EXISTS. Step 1 of skills/research/SKILL.md is shell a model executes verbatim, and it had
# two refusals that stopped research over things research does not need:
#   - a HARD EXIT when docs/acf/organization.md was missing. That file is installed by acf-librarian, a
#     SIBLING plugin; acf-tools plugins are self-contained, so optional composition is a presence check
#     plus a fallback, and the skill already states the naming rules the file was consulted for.
#   - an UNCONDITIONAL `.backlog/` test, which refused every beads/multica/linear/third-party project:
#     .backlog/ is the files store's home and exists nowhere else.
# Nothing ran that block, so restoring either refusal would have stayed green. The first repair also
# overshot the other way: it resolved the store with `acfw-store info`, which exits 2 before printing
# on a bad /go-only pin (ACFW_GO_BARE, ACFW_EFFORT_SHELL), so a typo in a setting /research never
# reads refused it with a false "store could not be resolved". This suite runs the block as extracted
# from the skill, so it tests the text that ships, not a copy of it.
#
# It runs that text the way Claude Code delivers it, which is not the file on disk: the plugin skill
# loader substitutes the BRACED plugin-root reference into the skill when it loads it, and only that
# form, while the Bash tool's environment does not carry the variable at all. A suite that exported
# the variable passed a block whose bare references reached a real shell empty. So the variable is
# unset here, the braced form is substituted exactly as the loader does it, and a bare reference fails
# statically. Two hand-offs are checked as well: the resolved store must be PRINTED (a shell variable
# dies with its Bash call, so an unprinted store reaches Step 5 as a guess), and a broken install must
# not make the files store worse than before the block depended on the lib.
#
# RESEARCH_SKILL=<path> points it at another revision of the skill (e.g. `git show HEAD:...` saved to
# a file) to confirm a case fails there.
#
# Run: bash acf-whip/tests/phase19-research-preflight.test.sh
set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="${RESEARCH_SKILL:-$ACF_WHIP/skills/research/SKILL.md}"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p19research.XXXXXX"); trap 'rm -rf "$WORK"' EXIT

# The FIRST ```bash fence after the Step 1 heading, up to its closing fence. An empty extraction must
# fail loudly: a renamed heading would otherwise make every "rc=0" case below pass on an empty script.
STEP1_RAW="$WORK/step1.raw.sh"
awk '/^### Step 1:/{s=1} s&&/^```bash$/{f=1;next} f&&/^```$/{exit} f{print}' "$SKILL" > "$STEP1_RAW"
check "Step 1's bash block extracts from the skill (non-empty)" "[ -s '$STEP1_RAW' ]"
check "Step 1 parses under the oldest bash we support (/bin/bash is 3.2 on macOS)" "/bin/bash -n '$STEP1_RAW'"
check "Step 1 has no bash-4 constructs (declare -A, mapfile, readarray)" \
  "! grep -Eq 'declare -A|mapfile|readarray' '$STEP1_RAW'"
check "Step 1 never uses the bare \$CLAUDE_PLUGIN_ROOT (the loader substitutes only the braced form)" \
  "! grep -qF '\$CLAUDE_PLUGIN_ROOT' '$STEP1_RAW'"

# What the model actually receives: the loader's literal replaceAll of the braced reference with the
# plugin's absolute path. The replacement is escaped for sed (\ & |) so an unusual checkout path
# cannot corrupt the emulation into a false pass.
STEP1="$WORK/step1.sh"
esc=$(printf '%s' "$ACF_WHIP" | sed 's/[\\&|]/\\&/g')
sed "s|\${CLAUDE_PLUGIN_ROOT}|$esc|g" "$STEP1_RAW" > "$STEP1"
check "the loader emulation substituted the plugin root into Step 1" \
  "grep -qF '_ \"$ACF_WHIP\" \"\$trunk_root\"' '$STEP1' && grep -qF '$ACF_WHIP/skills/lib/bin/acfw-store' '$STEP1' && ! grep -qF '{CLAUDE_PLUGIN_ROOT}' '$STEP1'"

# Hermetic: every knob the dispatcher and the lib read, cleared. A developer's own ACFW_STORE or
# ACFW_TRUNK_ROOT would otherwise route the scratch repos below to their real store. CLAUDE_PLUGIN_ROOT
# is cleared too: the Bash tool never has it, and exporting it here is what hid the bare references.
unset ACFW_STORE ACFW_CONFIG_FILE ACFW_TRUNK_ROOT ACFW_TRUNK_BRANCH ACFW_INTEGRATION_MODE ACFW_GO_BARE \
      ACFW_EFFORT_SHELL ACFW_STORE_ADAPTER_PATH ACFW_MULTICA_BIN ACFW_LINEAR_TRANSPORT ACFW_BEADS_BIN \
      CLAUDE_PLUGIN_ROOT 2>/dev/null || true

mkrepo(){ # <name> — a fresh git repo; prints its path
  local r="$WORK/$1"
  git init -q -b trunk "$r"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  echo seed > "$r/seed"; git -C "$r" add -A; git -C "$r" commit -qm seed
  printf '%s' "$r"
}
# run <repo> [VAR=value]... — run Step 1, as the loader delivers it, from <repo>'s root. Sets OUT, RC.
# `env` with no assignments still runs the command, so the zero-argument call needs no special case.
run(){
  local r="$1"; shift
  OUT=$(cd "$r" && env "$@" bash "$STEP1" 2>&1); RC=$?
}
# run_raw <repo> [VAR=value]... — the same, on the UNSUBSTITUTED text: the lib cannot load, which is
# how a broken install or a copied block behaves.
run_raw(){
  local r="$1"; shift
  OUT=$(cd "$r" && env "$@" bash "$STEP1_RAW" 2>&1); RC=$?
}
# has_line <exact line> — OUT contains that whole line.
has_line(){ printf '%s\n' "$OUT" | grep -qxF "$1"; }

# ============================ files store =======================================================
FILES=$(mkrepo files); mkdir -p "$FILES/.backlog/pending"
run "$FILES"
check "(a) files + .backlog/ + NO docs/acf/organization.md: continues (rc=0), acf-librarian is optional" "[ $RC -eq 0 ]"
check "(a) ...and says so with a Warning naming the missing file" \
  "printf '%s' \"\$OUT\" | grep -q '^Warning: docs/acf/organization.md not found'"
check "(a) ...and names what is degraded, not just what is missing" \
  "printf '%s' \"\$OUT\" | grep -q 'built-in temporal naming rules'"
check "(a) ...and the missing research protocol is a Warning too, never an Error" \
  "printf '%s' \"\$OUT\" | grep -q '^Warning: Research protocol not found' && ! printf '%s' \"\$OUT\" | grep -q '^Error'"
check "(a) ...and prints the resolved store for Step 5 (Task store: files)" "has_line 'Task store: files'"

mkdir -p "$FILES/docs/acf"; : > "$FILES/docs/acf/organization.md"; : > "$FILES/docs/acf/research-protocol.md"
run "$FILES"
# Exact, not "contains": the store line is the block's whole output here, so a stray line (a lib
# warning, a source error) that a substring check would wave through fails instead.
check "files + everything installed: rc=0 and the ONLY output is 'Task store: files'" \
  "[ $RC -eq 0 ] && [ \"\$OUT\" = 'Task store: files' ]"

NOBL=$(mkrepo files-nobacklog)
run "$NOBL"
check "(c) files store with NO .backlog/: refuses (rc=1) — there it is the store itself" "[ $RC -eq 1 ]"
check "(c) ...naming the fix" "printf '%s' \"\$OUT\" | grep -q '/whip-init'"

# ============================ non-files stores ==================================================
# multica answers `capabilities` before it needs jq or its CLI, so this runs with neither installed.
MUL=$(mkrepo multica)
run "$MUL" ACFW_STORE=multica
check "(b) ACFW_STORE=multica with NO .backlog/: passes (rc=0) — .backlog/ is not that store's home" "[ $RC -eq 0 ]"
check "(b) ...and never creates .backlog/" "[ ! -e '$MUL/.backlog' ]"
check "(b) ...and prints 'Task store: multica', the value Step 5 routes the task by" \
  "has_line 'Task store: multica'"

CFG=$(mkrepo multica-config); mkdir -p "$CFG/.acfwhip"; printf 'ACFW_STORE=multica\n' > "$CFG/.acfwhip/config"
run "$CFG"
check "(b) the store pinned in .acfwhip/config (not env) is honoured the same way" "[ $RC -eq 0 ]"
check "(b) ...and printed the same way (Task store: multica)" "has_line 'Task store: multica'"

UNK=$(mkrepo unknown)
run "$UNK" ACFW_STORE=nosuchstore
check "(d) ACFW_STORE=<unknown>: refuses (rc=1) BEFORE the research run, not at the final create" "[ $RC -eq 1 ]"
check "(d) ...with the dispatcher's FATAL naming the missing adapter" \
  "printf '%s' \"\$OUT\" | grep -q \"no adapter found for store backend 'nosuchstore'\""

# ============================ pins /research does not read ======================================
run "$FILES" ACFW_GO_BARE=al
check "(e) a bad ACFW_GO_BARE (a /go-only pin) does not stop /research on files" "[ $RC -eq 0 ]"
run "$FILES" ACFW_EFFORT_SHELL=hi
check "(e) a bad ACFW_EFFORT_SHELL (a /go-only pin) does not stop /research on files" "[ $RC -eq 0 ]"
run "$MUL" ACFW_STORE=multica ACFW_GO_BARE=al
check "(e) ...nor on a non-files store" "[ $RC -eq 0 ]"
check "(e) ...and never claims the store 'could not be resolved' (it did resolve)" \
  "! printf '%s' \"\$OUT\" | grep -q 'could not be resolved'"

# ACFW_INTEGRATION_MODE is different: every FORWARDED dispatcher call refuses on it, `create` included,
# so on a store that files through the dispatcher it WILL fail, and failing first is the honest answer.
# On files research-agent writes .backlog/pending/ directly and never calls the dispatcher.
run "$MUL" ACFW_STORE=multica ACFW_INTEGRATION_MODE=bogus
check "(f) non-files + bad ACFW_INTEGRATION_MODE: refuses up front (create would refuse after the run)" "[ $RC -eq 1 ]"
check "(f) ...with the dispatcher's FATAL naming the pin" \
  "printf '%s' \"\$OUT\" | grep -q 'ACFW_INTEGRATION_MODE'"
run "$FILES" ACFW_INTEGRATION_MODE=bogus
check "(f) files + bad ACFW_INTEGRATION_MODE: not /research's concern (rc=0)" "[ $RC -eq 0 ]"

# ============================ the store library does not load ===================================
# The unsubstituted text: the plugin root expands empty, as a bare reference did in every real run.
# Where nothing pins a store the resolver's own precedence answers `files` without the lib, so the
# files store must pass exactly as it did before the block depended on the lib. Where anything pins a
# store, assuming `files` is the invisible-task bug, so it must refuse and never print a files line.
run_raw "$FILES"
check "(g) lib not loadable, files, nothing pinned: continues (rc=0), never worse than before" "[ $RC -eq 0 ]"
check "(g) ...resolving 'files' from the precedence, and printing it" "has_line 'Task store: files'"
check "(g) ...with a Warning that the lib did not load, not an Error" \
  "printf '%s' \"\$OUT\" | grep -q '^Warning: acf-whip.s store library did not load' && ! printf '%s' \"\$OUT\" | grep -q '^Error'"
check "(g) ...and no raw shell noise from the failed source" "! printf '%s' \"\$OUT\" | grep -q 'No such file'"
run_raw "$FILES" ACFW_STORE=files
check "(g) lib not loadable, ACFW_STORE=files in the env: the env decides, continues as files" \
  "[ $RC -eq 0 ] && has_line 'Task store: files'"
run_raw "$MUL" ACFW_STORE=multica
check "(g) lib not loadable, ACFW_STORE=multica in the env: refuses (rc=1), never assumes files" \
  "[ $RC -eq 1 ] && ! has_line 'Task store: files'"
check "(g) ...naming the remedy" "printf '%s' \"\$OUT\" | grep -q 'Reinstall acf-whip'"
BLCFG=$(mkrepo files-with-pin); mkdir -p "$BLCFG/.backlog/pending" "$BLCFG/.acfwhip"
printf 'ACFW_STORE=multica\n' > "$BLCFG/.acfwhip/config"
run_raw "$BLCFG"
check "(g) lib not loadable, store pinned in config, a stale .backlog/ present: refuses (rc=1)" \
  "[ $RC -eq 1 ] && ! has_line 'Task store: files'"
printf 'ACFW_STORE=multica\n' > "$WORK/alt-config"
run_raw "$FILES" ACFW_CONFIG_FILE="$WORK/alt-config"
check "(g) lib not loadable, store pinned via ACFW_CONFIG_FILE: refuses (rc=1)" "[ $RC -eq 1 ]"
run "$FILES"
check "(g) the loaded text resolves through the lib (no 'did not load' warning)" \
  "[ $RC -eq 0 ] && ! printf '%s' \"\$OUT\" | grep -q 'did not load'"

# ============================ the shell the model's Bash tool runs ==============================
# The block is not guaranteed to run under bash: Claude Code runs a tool call in the user's shell,
# commonly zsh. -f skips the user's startup files so the run stays hermetic.
if command -v zsh >/dev/null 2>&1; then
  OUT=$(cd "$FILES" && zsh -f "$STEP1" 2>&1); RC=$?
  check "(h) zsh, files + everything installed: rc=0 and the ONLY output is 'Task store: files'" \
    "[ $RC -eq 0 ] && [ \"\$OUT\" = 'Task store: files' ]"
  OUT=$(cd "$MUL" && env ACFW_STORE=multica zsh -f "$STEP1" 2>&1); RC=$?
  check "(h) zsh, ACFW_STORE=multica: rc=0 and prints 'Task store: multica'" \
    "[ $RC -eq 0 ] && has_line 'Task store: multica'"
  OUT=$(cd "$FILES" && zsh -f "$STEP1_RAW" 2>&1); RC=$?
  check "(h) zsh, lib not loadable, nothing pinned: continues as files" \
    "[ $RC -eq 0 ] && has_line 'Task store: files'"
  OUT=$(cd "$MUL" && env ACFW_STORE=multica zsh -f "$STEP1_RAW" 2>&1); RC=$?
  check "(h) zsh, lib not loadable, ACFW_STORE=multica: refuses" "[ $RC -eq 1 ]"
else
  echo "  (zsh not installed: the zsh cases are not run)"
fi

# ============================ Step 5 routes the task by store ===================================
# Step 1 letting non-files stores through is only half the fix: research-agent must then file the
# task where that store reads it. Its prompt said, unconditionally and MANDATORY, to create the task
# in .backlog/pending/, which on linear creates a directory the board never sees.
STEP5="$WORK/step5.md"
awk '/^### Step 5:/{s=1} /^### Step 6:/{exit} s{print}' "$SKILL" > "$STEP5"
check "Step 5 extracts from the skill (non-empty)" "[ -s '$STEP5' ]"
check "Step 5 hands research-agent the resolved store" "grep -qF '**Task store**: {store_name}' '$STEP5'"
check "Step 5 files through acfw-store create on a non-files store" \
  "grep -qF 'acfw-store\" create --file' '$STEP5'"
check "Step 5 keeps .backlog/pending/ for the files store" "grep -q 'files.*\\.backlog/pending/' '$STEP5'"
check "Step 5 no longer orders an unconditional .backlog/pending/ task" \
  "! grep -qF 'create task in \`.backlog/pending/\`' '$STEP5' && ! grep -qF 'Create task in \`.backlog/pending/\`' '$STEP5'"
check "Step 5 never uses the bare \$CLAUDE_PLUGIN_ROOT" "! grep -qF '\$CLAUDE_PLUGIN_ROOT' '$STEP5'"
# The staging location and its cleanup. "A temp path" let research-agent pick the repo root or docs/,
# and on a store that never commits task files nothing ever removed the copy, so it sat untracked in
# the checkout until someone committed it by accident.
check "Step 5 stages a non-files task under the gitignored run namespace, verified ignored" \
  "grep -qF '.acfwhip/run/staging' '$STEP5' && grep -qF 'git check-ignore -q' '$STEP5'"
check "Step 5 removes the staged copy only after a successful create" \
  "grep -qF 'create --file \"<dir>/<stem>.md\" --folder pending && rm -f \"<dir>/<stem>.md\"' '$STEP5'"
check "Step 5 says what to do on a create failure other than a taken key (keep the file, report it)" \
  "grep -q 'Any other non-zero exit' '$STEP5' && grep -q 'keep the' '$STEP5'"
# The staging one-liner is shell a model runs; it must pick the ignored namespace when the rule is
# there and a temp dir when it is not, and never leave an unignored staging path.
PICK=$(grep -o '`d=\.acfwhip/run/staging;[^`]*`' "$STEP5" | tr -d '`')
check "Step 5's staging one-liner extracts" "[ -n \"\$PICK\" ]"
IGN=$(mkrepo stage-ignored); printf '.acfwhip/run/\n' > "$IGN/.gitignore"
got=$(cd "$IGN" && bash -c "$PICK")
check "(i) staging with .acfwhip/run/ ignored: uses .acfwhip/run/staging" "[ \"\$got\" = '.acfwhip/run/staging' ]"
UNIGN=$(mkrepo stage-unignored)
got=$(cd "$UNIGN" && bash -c "$PICK")
check "(i) staging with no ignore rule: falls back to an absolute temp dir outside the checkout" \
  "[ -d \"\$got\" ] && [ \"\${got#/}\" != \"\$got\" ] && [ \"\${got#\"\$UNIGN\"}\" = \"\$got\" ]"
case "$got" in /*) rm -rf "$got" ;; esac

# Step 1's prose and Step 5's template must agree: the store reaches Step 5 as a PRINTED line, and a
# missing reference file is reported to research-agent in a place its prompt actually has.
check "the Step 1 hand-off reads the printed 'Task store:' line" \
  "awk '/^### Step 1:/{s=1} /^### Step 2:/{exit} s{print}' '$SKILL' | grep -qF 'Task store: <name>'"
check "Step 5's template carries an Absent references line for missing reference files" \
  "grep -qF '**Absent references**: {missing_files}' '$STEP5'"
check "Step 5 no longer orders research-protocol.md unconditionally" \
  "grep -A1 -F '**Research Protocol**' '$STEP5' | grep -q 'when it exists'"

echo
echo "phase19-research-preflight: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
