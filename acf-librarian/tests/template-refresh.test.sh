#!/usr/bin/env bash
# template-refresh.test.sh - the librarian must be able to correct a convention document it shipped.
#
# Before 1.3.0 the SessionStart hook created docs/acf/organization.md and
# docs/acf/git/commit-conventions.md once and never looked at them again, so every convention fixed in
# this plugin aged in place in every existing project and kept being injected as MANDATORY rules. The
# refresh (ported from acf-whip 3.3.0) recognises an unedited copy by CONTENT against a manifest of every
# shipped version, because a version stamp cannot help on the release that introduces it.
#
# What must hold, and why each case is here:
#   - the RETROACTIVE case: an unmarked copy of an old template is refreshed. Without it the mechanism
#     ships inert, since every existing copy predates the marker;
#   - an edited copy is never overwritten, and says so in ONE line, only until the user acknowledges
#     the current template (these two documents invite customisation, so a permanent nag is a defect);
#   - a missing document is installed and injected exactly as the pre-1.3.0 hook did: the payload is
#     diffed against that hook, pulled from git history, not against a hand-copied expectation;
#   - the hook never breaks a session and never dirties a tree when nothing changed;
#   - the manifest covers what ships now, holds no digest nothing justifies, and the generator reproduces
#     it (committed digests and seeds kept, uncommitted drafts dropped, a failed `git show` skipped
#     instead of recording sha256 of nothing);
#   - a missing document that cannot be created is never reported as loaded from that file.
#
# Offline; every fixture lives under mktemp -d. Run: bash acf-librarian/tests/template-refresh.test.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # plugin root
HOOK="$ROOT/hooks/handlers/session-start.py"
GEN="$ROOT/skills/lib/gen-digests.sh"
ORG_SRC="content/organization-template.md"
GIT_SRC="content/git-commit-conventions-template.md"
ORG_DEST="docs/acf/organization.md"
GIT_DEST="docs/acf/git/commit-conventions.md"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }
finish(){ echo; echo "template-refresh: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit $?; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed (the hook needs it)"; echo "template-refresh: 0 passed, 0 failed"; exit 0; }
# Test-side JSON parsing only; the hook itself always runs through its own shebang, as Claude Code does.
if command -v uv >/dev/null 2>&1; then PY(){ uv run --no-project --quiet python3 "$@"; }; else PY(){ python3 "$@"; }; fi
if command -v sha256sum >/dev/null 2>&1; then sha(){ sha256sum | cut -d' ' -f1; }; else sha(){ shasum -a 256 | cut -d' ' -f1; }; fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfl-refresh.XXXXXX") || exit 1
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

run_hook(){ ( cd "$1" && echo '{}' | "${2:-$HOOK}" ); }            # stdout = hook JSON
ctx(){ PY -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
valid_json(){ PY -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["hookEventName"]=="SessionStart"' 2>/dev/null; }
cur_org=$(sha < "$ROOT/$ORG_SRC")
marker(){ printf '<!-- acf-librarian-template: %s sha256:%s -->' "$1" "$(printf '%s' "$2" | cut -c1-12)"; }

# Oldest shipped version of a template, from this repository's history (empty on a shallow clone).
oldest(){ c=$(git -C "$ROOT" log --reverse --format=%H -- "$1" 2>/dev/null | head -1)
  [ -n "$c" ] && git -C "$ROOT" show "$c:./$1" 2>/dev/null; }
OLD_ORG="$WORK/old-org.md"; OLD_GIT="$WORK/old-git.md"
oldest "$ORG_SRC" > "$OLD_ORG"; oldest "$GIT_SRC" > "$OLD_GIT"
HAVE_HISTORY=1
{ [ -s "$OLD_ORG" ] && [ -s "$OLD_GIT" ] && ! cmp -s "$OLD_ORG" "$ROOT/$ORG_SRC" && ! cmp -s "$OLD_GIT" "$ROOT/$GIT_SRC"; } || HAVE_HISTORY=0

echo "== 0. wiring"
check "the hook is executable (hooks.json runs it by path)" "[ -x \"$HOOK\" ]"
HOOK_SET=$(PY - "$HOOK" <<'PY'
import re, sys
print(" ".join(sorted(re.findall(r'\("(content/[^"]+)",\s*"docs/', open(sys.argv[1], encoding="utf-8").read()))))
PY
)
GEN_SET=$(sed -n '/^ARTIFACTS="/,/^"/p' "$GEN" | grep '^content/' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
check "MANAGED in the hook and ARTIFACTS in the generator name the same templates" \
  "[ -n \"$HOOK_SET\" ] && [ \"$HOOK_SET\" = \"$GEN_SET\" ]"
MISSING=$(PY - "$ROOT" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
man = json.loads((root / "content" / ".digests.json").read_text(encoding="utf-8"))["artifacts"]
print(",".join(rel for rel, ds in man.items()
               if hashlib.sha256((root / rel).read_bytes()).hexdigest() not in ds) or "none")
PY
)
check "the manifest covers the CURRENT content of every template (else re-run gen-digests.sh)" "[ \"$MISSING\" = none ]"
check "the manifest never records sha256 of empty content" \
  "! grep -q e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 \"$ROOT/content/.digests.json\""
bash "$GEN" --out "$WORK/regen.json" >/dev/null 2>&1
check "gen-digests.sh reproduces the shipped manifest byte for byte (else re-run it)" \
  "cmp -s \"$WORK/regen.json\" \"$ROOT/content/.digests.json\""
# A digest nothing justifies claims a version shipped that never did: an earlier generator run once
# recorded a working-copy draft and kept it. Justified = a version in this branch's history, the
# working copy, a recorded seed, or a digest the manifest committed at HEAD already holds (that last
# one is how a version survives a history rewrite).
if [ "$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = false ]; then
  JUST="$WORK/justified"; : > "$JUST"
  for f in "$ORG_SRC" "$GIT_SRC"; do
    sha < "$ROOT/$f" >> "$JUST"
    for c in $(git -C "$ROOT" log --full-history --format=%H -- "$f"); do
      git -C "$ROOT" show "$c:./$f" 2>/dev/null > "$WORK/blob" && sha < "$WORK/blob" >> "$JUST"
    done
  done
  grep -oE ':[0-9a-f]{64}"' "$ROOT/content/.digests.json" | tr -d ':"' >> "$JUST"
  git -C "$ROOT" show "HEAD:./content/.digests.json" 2>/dev/null | grep -oE '[0-9a-f]{64}' >> "$JUST"
  UNJUST=$(PY -c 'import json,sys; [print(d) for ds in json.load(open(sys.argv[1]))["artifacts"].values() for d in ds]' \
    "$ROOT/content/.digests.json" | grep -vxF -f "$JUST" | tr '\n' ' ')
  check "every manifest digest is in git history, the working copy, a seed or HEAD's manifest [${UNJUST:-none}]" "[ -z \"$UNJUST\" ]"
else
  echo "  SKIP: shallow clone; digest provenance cannot be checked"
fi

echo "== 1. fresh project: installed, marked, injected exactly as the pre-1.3.0 hook did"
P1="$WORK/fresh"; mkdir -p "$P1"
OUT1=$(run_hook "$P1"); C1=$(printf '%s' "$OUT1" | ctx)
check "organization.md is installed" "[ -f \"$P1/$ORG_DEST\" ]"
check "commit-conventions.md is installed" "[ -f \"$P1/$GIT_DEST\" ]"
check "the first line marks the template digest it was installed from" \
  "[ \"\$(head -1 \"$P1/$ORG_DEST\")\" = \"$(marker "$ORG_SRC" "$cur_org")\" ]"
check "the body under the marker is the template, byte for byte" "tail -n +2 \"$P1/$ORG_DEST\" | cmp -s - \"$ROOT/$ORG_SRC\""
check "same for the git conventions" "tail -n +2 \"$P1/$GIT_DEST\" | cmp -s - \"$ROOT/$GIT_SRC\""
check "the marker is never injected into the session" "! printf '%s' \"\$C1\" | grep -q 'acf-librarian-template:'"
check "the pre-1.3.0 Initialized status line is unchanged" \
  "printf '%s' \"\$C1\" | grep -qx '📚 Initialized docs/acf/organization.md with default conventions (you may customize this file)'"
check "no notice on a fresh install" "! printf '%s' \"\$C1\" | grep -q '⚠️ acf-librarian'"

# The baseline: the hook exactly as it first shipped, run from a plugin tree holding TODAY's templates,
# so the only variable is the hook. Its payload must equal the new hook's, byte for byte.
BASE_C=$(git -C "$ROOT" log --reverse --format=%H -- hooks/handlers/session-start.py 2>/dev/null | head -1)
if [ -n "$BASE_C" ]; then
  OLDP="$WORK/oldplugin"; mkdir -p "$OLDP/hooks/handlers" "$OLDP/content"
  git -C "$ROOT" show "$BASE_C:./hooks/handlers/session-start.py" > "$OLDP/hooks/handlers/session-start.py"
  cp "$ROOT/$ORG_SRC" "$ROOT/$GIT_SRC" "$OLDP/content/"
  B1="$WORK/fresh-baseline"; mkdir -p "$B1"
  BC1=$(cd "$B1" && echo '{}' | PY "$OLDP/hooks/handlers/session-start.py" | ctx)
  check "fresh install: the injected payload is byte-identical to the original hook's" "[ \"\$C1\" = \"\$BC1\" ]"
  # An unmarked copy identical to today's template: the pre-1.3.0 steady state of every project.
  P6="$WORK/unmarked-current"; mkdir -p "$P6/docs/acf/git"
  cp "$ROOT/$ORG_SRC" "$P6/$ORG_DEST"; cp "$ROOT/$GIT_SRC" "$P6/$GIT_DEST"
  B6="$WORK/unmarked-baseline"; cp -R "$P6" "$B6"
  C6=$(run_hook "$P6" | ctx); BC6=$(cd "$B6" && echo '{}' | PY "$OLDP/hooks/handlers/session-start.py" | ctx)
  check "loaded copy: the injected payload is byte-identical to the original hook's" "[ \"\$C6\" = \"\$BC6\" ]"
  check "an unmarked current copy is not rewritten just to add a marker (no churn)" \
    "cmp -s \"$P6/$ORG_DEST\" \"$ROOT/$ORG_SRC\" && cmp -s \"$P6/$GIT_DEST\" \"$ROOT/$GIT_SRC\""
else
  echo "  SKIP: no git history for the hook; the byte-identical baseline cannot be built"
fi

echo "== 2. idempotence"
H1=$(cat "$P1/$ORG_DEST" "$P1/$GIT_DEST" | sha)
C2=$(run_hook "$P1" | ctx)
check "a second session changes nothing" "[ \"\$(cat \"$P1/$ORG_DEST\" \"$P1/$GIT_DEST\" | sha)\" = \"$H1\" ]"
check "...and reports the pre-1.3.0 Loaded line" "printf '%s' \"\$C2\" | grep -qx '📚 Loaded conventions from docs/acf/organization.md'"
check "...with no notice" "! printf '%s' \"\$C2\" | grep -q '⚠️ acf-librarian'"

# A team that links docs/acf/organization.md to a shared file not created yet. The pre-1.3.0 hook saw
# exists() == False and created the target THROUGH the link; refusing the link instead injected an error
# in place of the conventions on every session.
echo "== 2b. a dangling symlink is created through, as the pre-1.3.0 hook did"
PD="$WORK/dangling"; mkdir -p "$PD/docs/acf" "$PD/shared"; ln -s ../../shared/org.md "$PD/$ORG_DEST"
OUTD=$(run_hook "$PD"); CD=$(printf '%s' "$OUTD" | ctx)
check "the link is kept" "[ -L \"$PD/$ORG_DEST\" ]"
check "...and its target now holds the marked template" \
  "[ \"\$(head -1 \"$PD/shared/org.md\")\" = \"$(marker "$ORG_SRC" "$cur_org")\" ] && tail -n +2 \"$PD/shared/org.md\" | cmp -s - \"$ROOT/$ORG_SRC\""
check "...with the Initialized status line, not an error" \
  "printf '%s' \"\$CD\" | grep -qx '📚 Initialized docs/acf/organization.md with default conventions (you may customize this file)' && ! printf '%s' \"\$CD\" | grep -qE '⚠️ (Error|acf-librarian)'"
if [ -n "${OLDP:-}" ]; then
  BD="$WORK/dangling-baseline"; mkdir -p "$BD/docs/acf" "$BD/shared"; ln -s ../../shared/org.md "$BD/$ORG_DEST"
  BCD=$(cd "$BD" && echo '{}' | PY "$OLDP/hooks/handlers/session-start.py" | ctx)
  check "...and the injected payload is byte-identical to the original hook's" "[ \"\$CD\" = \"\$BCD\" ]"
fi
PDM="$WORK/dangling-nodir"; mkdir -p "$PDM/docs/acf"; ln -s ../../shared/org.md "$PDM/$ORG_DEST"
OUTDM=$(run_hook "$PDM" 2>/dev/null); RCDM=$?
check "a link into a missing folder: exit 0 and valid JSON" "[ $RCDM -eq 0 ] && printf '%s' \"\$OUTDM\" | valid_json"
check "...the session still gets the conventions, and is told the copy is missing" \
  "printf '%s' \"\$OUTDM\" | ctx | grep -q 'Dated Living Records' && printf '%s' \"\$OUTDM\" | ctx | grep -q 'could not create docs/acf/organization.md'"
check "...and no folder is created outside docs/ to satisfy the link" "[ ! -e \"$PDM/shared\" ] && [ -L \"$PDM/$ORG_DEST\" ]"
check "...the status says initialization failed, never that the missing file was loaded" \
  "printf '%s' \"\$OUTDM\" | ctx | grep -qx '⚠️ Error initializing organization conventions' && ! printf '%s' \"\$OUTDM\" | ctx | grep -q 'Loaded conventions from docs/acf/organization.md'"
PL="$WORK/loop"; mkdir -p "$PL/docs/acf"; ln -s organization.md "$PL/$ORG_DEST"
OUTL=$(run_hook "$PL" 2>/dev/null); RCL=$?
check "a symlink loop: exit 0, valid JSON, and the link is not replaced by a file" \
  "[ $RCL -eq 0 ] && printf '%s' \"\$OUTL\" | valid_json && [ -L \"$PL/$ORG_DEST\" ] && [ \"\$(readlink \"$PL/$ORG_DEST\")\" = organization.md ]"

if [ "$HAVE_HISTORY" -eq 0 ]; then
  echo "  SKIP: truncated history; no older template version to build the retroactive fixtures from."
  echo "        Run this suite from a full clone."
  finish
fi

echo "== 3. THE RETROACTIVE CASE: an unmarked copy of an old template is refreshed"
P2="$WORK/legacy"; mkdir -p "$P2/docs/acf/git"
cp "$OLD_ORG" "$P2/$ORG_DEST"; cp "$OLD_GIT" "$P2/$GIT_DEST"
C3=$(run_hook "$P2" | ctx)
check "organization.md now holds the current template" "tail -n +2 \"$P2/$ORG_DEST\" | cmp -s - \"$ROOT/$ORG_SRC\""
check "...and is marked with the current digest" "[ \"\$(head -1 \"$P2/$ORG_DEST\")\" = \"$(marker "$ORG_SRC" "$cur_org")\" ]"
check "commit-conventions.md now holds the current template" "tail -n +2 \"$P2/$GIT_DEST\" | cmp -s - \"$ROOT/$GIT_SRC\""
check "the refresh is announced" \
  "printf '%s' \"\$C3\" | grep -q '📚 Updated docs/acf/organization.md to the current plugin template'"
check "the session gets the NEW conventions, not the stale ones" "printf '%s' \"\$C3\" | grep -q 'Dated Living Records'"
check "...and no edited-copy notice" "! printf '%s' \"\$C3\" | grep -q 'has local edits'"

echo "== 4. an edited copy is never overwritten, and says so in one line"
P3="$WORK/edited"; mkdir -p "$P3/docs/acf/git"
cp "$OLD_ORG" "$P3/$ORG_DEST"; printf '\n- docs/experiments/ # a line this team added\n' >> "$P3/$ORG_DEST"
cp "$ROOT/$GIT_SRC" "$P3/$GIT_DEST"
BEFORE=$(sha < "$P3/$ORG_DEST")
C4=$(run_hook "$P3" | ctx)
check "the edited copy is byte-identical afterwards" "[ \"\$(sha < \"$P3/$ORG_DEST\")\" = \"$BEFORE\" ]"
check "...and its local edit is what the session sees" "printf '%s' \"\$C4\" | grep -q 'a line this team added'"
check "exactly one notice line, naming the file" \
  "[ \"\$(printf '%s\n' \"\$C4\" | grep -c 'acf-librarian: docs/acf/organization.md has local edits')\" -eq 1 ]"
check "...which carries the exact marker that silences it" \
  "printf '%s' \"\$C4\" | grep 'has local edits' | grep -qF '$(marker "$ORG_SRC" "$cur_org")'"
check "...and points at the plugin template to merge from" \
  "printf '%s' \"\$C4\" | grep 'has local edits' | grep -qF '$ROOT/$ORG_SRC'"
check "the untouched git conventions get no notice" "! printf '%s' \"\$C4\" | grep -q 'commit-conventions.md has local edits'"

echo "== 5. acknowledging the current template silences the notice"
P4="$WORK/acked"; mkdir -p "$P4/docs/acf"
{ marker "$ORG_SRC" "$cur_org"; echo; cat "$OLD_ORG"; printf '\n- docs/experiments/ # merged by hand\n'; } > "$P4/$ORG_DEST"
BEFORE=$(sha < "$P4/$ORG_DEST")
C5=$(run_hook "$P4" | ctx)
check "an edited copy marked with the current digest is left alone" "[ \"\$(sha < \"$P4/$ORG_DEST\")\" = \"$BEFORE\" ]"
check "...silently" "! printf '%s' \"\$C5\" | grep -q 'has local edits'"
check "...and its marker line is not injected" "! printf '%s' \"\$C5\" | grep -q 'acf-librarian-template:'"
PIN="$WORK/pinned"; mkdir -p "$PIN/docs/acf"
{ marker "$ORG_SRC" "$cur_org"; echo; cat "$OLD_ORG"; } > "$PIN/$ORG_DEST"
BEFORE=$(sha < "$PIN/$ORG_DEST")
CP=$(run_hook "$PIN" | ctx)
check "an UNEDITED old body under the current marker is a deliberate pin: not refreshed" \
  "[ \"\$(sha < \"$PIN/$ORG_DEST\")\" = \"$BEFORE\" ] && ! printf '%s' \"\$CP\" | grep -q 'has local edits'"

echo "== 6. a marker for an older template does not silence anything"
P5="$WORK/stale-ack"; mkdir -p "$P5/docs/acf"
{ marker "$ORG_SRC" "$(sha < "$OLD_ORG")"; echo; cat "$OLD_ORG"; printf '\n- custom\n'; } > "$P5/$ORG_DEST"
BEFORE=$(sha < "$P5/$ORG_DEST")
C6b=$(run_hook "$P5" | ctx)
check "an edited copy synced with an OLD template is left alone" "[ \"\$(sha < \"$P5/$ORG_DEST\")\" = \"$BEFORE\" ]"
check "...and reported" "printf '%s' \"\$C6b\" | grep -q 'acf-librarian: docs/acf/organization.md has local edits'"
P5b="$WORK/marked-old"; mkdir -p "$P5b/docs/acf"
{ marker "$ORG_SRC" "$(sha < "$OLD_ORG")"; echo; cat "$OLD_ORG"; } > "$P5b/$ORG_DEST"
run_hook "$P5b" >/dev/null
check "a pristine old copy with its own old marker IS refreshed" "tail -n +2 \"$P5b/$ORG_DEST\" | cmp -s - \"$ROOT/$ORG_SRC\""

# Section 5 proves a pin holds while the template it names is current. That is the easy half: the pin
# exists for the release AFTER, when the template moves, the marker stops naming the current digest and
# the pinned body (a version this plugin shipped) looks exactly like an unedited old copy. NEXT is this
# plugin one release on: the organization template gains a line and the manifest records it.
echo "== 6b. a pin survives the next template change; a newer plugin's copy is never downgraded"
NEXT="$WORK/plugin-next"; mkdir -p "$NEXT/hooks/handlers" "$NEXT/content"
cp "$HOOK" "$NEXT/hooks/handlers/"; cp "$ROOT/$GIT_SRC" "$NEXT/content/"
{ cat "$ROOT/$ORG_SRC"; printf '\n- docs/next/ # a convention added by the next release\n'; } > "$NEXT/$ORG_SRC"
next_org=$(sha < "$NEXT/$ORG_SRC")
PY - "$ROOT/content/.digests.json" "$NEXT/content/.digests.json" "$ORG_SRC" "$next_org" <<'PY'
import json, sys
man = json.load(open(sys.argv[1], encoding="utf-8"))
man["artifacts"][sys.argv[3]].append(sys.argv[4])
json.dump(man, open(sys.argv[2], "w", encoding="utf-8"))
PY
NEXT_HOOK="$NEXT/hooks/handlers/session-start.py"
BEFORE=$(sha < "$PIN/$ORG_DEST")
CN=$(run_hook "$PIN" "$NEXT_HOOK" | ctx)
check "the pinned copy is byte-identical after the template moved on" "[ \"\$(sha < \"$PIN/$ORG_DEST\")\" = \"$BEFORE\" ]"
check "...its old body is what the session sees" "! printf '%s' \"\$CN\" | grep -q 'a convention added by the next release'"
check "...it is not announced as an unedited older copy" "! printf '%s' \"\$CN\" | grep -q 'was an unedited older copy'"
check "...and the user is told the template moved, with the marker that re-pins it" \
  "printf '%s' \"\$CN\" | grep 'acf-librarian: docs/acf/organization.md has local edits' | grep -qF '$(marker "$ORG_SRC" "$next_org")'"
PN="$WORK/next-refresh"; cp -R "$P1" "$PN"                    # installed by THIS release, untouched since
CPN=$(run_hook "$PN" "$NEXT_HOOK" | ctx)
check "non-vacuity: an unpinned copy this release installed IS refreshed by the next one" \
  "tail -n +2 \"$PN/$ORG_DEST\" | cmp -s - \"$NEXT/$ORG_SRC\" && printf '%s' \"\$CPN\" | grep -q '📚 Updated docs/acf/organization.md'"
# A teammate on the next release refreshed and committed it; this (older) plugin now reads that copy.
BEFORE=$(sha < "$PN/$ORG_DEST")
CO=$(run_hook "$PN" | ctx)
check "a newer plugin's pristine copy is left alone by an older plugin" "[ \"\$(sha < \"$PN/$ORG_DEST\")\" = \"$BEFORE\" ]"
check "...and loaded as is" "printf '%s' \"\$CO\" | grep -q 'a convention added by the next release'"
check "...with no 'local edits' notice" "! printf '%s' \"\$CO\" | grep -q 'has local edits'"
check "...never advising the OLDER marker (a downgrade)" "! printf '%s' \"\$CO\" | grep -qF '$(marker "$ORG_SRC" "$cur_org")'"
check "...and one line saying to update acf-librarian" \
  "[ \"\$(printf '%s\n' \"\$CO\" | grep -c 'acf-librarian: docs/acf/organization.md was written by a newer acf-librarian')\" -eq 1 ]"

echo "== 7. a shared conventions file behind a symlink keeps its link"
P7="$WORK/linked"; mkdir -p "$P7/docs/acf" "$P7/shared"
cp "$OLD_ORG" "$P7/shared/org.md"; ln -s ../../shared/org.md "$P7/$ORG_DEST"
run_hook "$P7" >/dev/null
check "the destination is still a symlink" "[ -L \"$P7/$ORG_DEST\" ]"
check "...and its target was refreshed" "tail -n +2 \"$P7/shared/org.md\" | cmp -s - \"$ROOT/$ORG_SRC\""

echo "== 8. no manifest: every old copy is treated as edited (reported, never clobbered)"
NOMAN="$WORK/plugin-nomanifest"; mkdir -p "$NOMAN/hooks/handlers" "$NOMAN/content"
cp "$HOOK" "$NOMAN/hooks/handlers/"; cp "$ROOT/$ORG_SRC" "$ROOT/$GIT_SRC" "$NOMAN/content/"
P8="$WORK/nomanifest"; mkdir -p "$P8/docs/acf"; cp "$OLD_ORG" "$P8/$ORG_DEST"
C8=$(run_hook "$P8" "$NOMAN/hooks/handlers/session-start.py" | ctx)
check "without a manifest a pristine old copy is NOT overwritten" "cmp -s \"$P8/$ORG_DEST\" \"$OLD_ORG\""
check "...and is reported instead" "printf '%s' \"\$C8\" | grep -q 'has local edits'"

echo "== 9. the hook never breaks a session"
P9="$WORK/dir-in-the-way"; mkdir -p "$P9/$ORG_DEST"
OUT9=$(run_hook "$P9" 2>/dev/null); RC9=$?
check "a directory where organization.md should be: exit 0" "[ $RC9 -eq 0 ]"
check "...valid hook JSON" "printf '%s' \"\$OUT9\" | valid_json"
check "...the pre-1.3.0 error status" "printf '%s' \"\$OUT9\" | ctx | grep -q 'Error loading organization conventions'"
check "...and the git conventions still reach the session" "printf '%s' \"\$OUT9\" | ctx | grep -q '## File Staging Rules'"

P10="$WORK/badbytes"; mkdir -p "$P10/docs/acf"
printf '# Conventions\n\nsmart quote: \223hello\224\n' > "$P10/$ORG_DEST"
OUT10=$(run_hook "$P10" 2>/dev/null); RC10=$?
check "a non-UTF-8 byte in an edited copy: exit 0 and valid JSON" "[ $RC10 -eq 0 ] && printf '%s' \"\$OUT10\" | valid_json"
check "...the file is named in the error" "printf '%s' \"\$OUT10\" | ctx | grep -q 'docs/acf/organization.md'"
check "...and left untouched" "grep -q 'smart quote' \"$P10/$ORG_DEST\""

if [ "$(id -u)" -ne 0 ]; then
  P11="$WORK/readonly-new"; mkdir -p "$P11/docs/acf/git"; chmod 555 "$P11/docs/acf"
  cp "$ROOT/$GIT_SRC" "$P11/$GIT_DEST" 2>/dev/null || true
  OUT11=$(run_hook "$P11" 2>/dev/null); RC11=$?
  check "cannot create organization.md: exit 0 and valid JSON" "[ $RC11 -eq 0 ] && printf '%s' \"\$OUT11\" | valid_json"
  check "...the session still gets the template's conventions" "printf '%s' \"\$OUT11\" | ctx | grep -q 'Dated Living Records'"
  check "...and is told the project copy is missing" "printf '%s' \"\$OUT11\" | ctx | grep -q 'could not create docs/acf/organization.md'"
  check "...under a status that says initialization failed, not 'Loaded conventions from' a missing file" \
    "printf '%s' \"\$OUT11\" | ctx | grep -qx '⚠️ Error initializing organization conventions' && ! printf '%s' \"\$OUT11\" | ctx | grep -q 'Loaded conventions from docs/acf/organization.md'"
  check "...while the git conventions, which did load, still say so" \
    "printf '%s' \"\$OUT11\" | ctx | grep -qx '📚 Loaded conventions from docs/acf/git/commit-conventions.md'"
  check "...and no stray temp file is left behind" "[ -z \"\$(ls -A \"$P11/docs/acf\" | grep -v '^git$')\" ]"

  P12="$WORK/readonly-old"; mkdir -p "$P12/docs/acf"; cp "$OLD_ORG" "$P12/$ORG_DEST"; chmod 555 "$P12/docs/acf"
  OUT12=$(run_hook "$P12" 2>/dev/null); RC12=$?
  check "cannot refresh a pristine old copy: exit 0" "[ $RC12 -eq 0 ]"
  check "...the old copy is intact" "cmp -s \"$P12/$ORG_DEST\" \"$OLD_ORG\""
  check "...and the failed update is surfaced" "printf '%s' \"\$OUT12\" | ctx | grep -q 'could not update docs/acf/organization.md'"
  chmod 755 "$P11/docs/acf" "$P12/docs/acf"
else
  echo "  SKIP: running as root; permission fixtures cannot fail"
fi

echo "== 10. the generator: every shipped version, committed digests kept, drafts dropped, no empty digest"
G="$WORK/genrepo"; mkdir -p "$G/plug/content" "$G/plug/skills/lib"
cp "$GEN" "$G/plug/skills/lib/gen-digests.sh"
mkdir -p "$WORK/nohooks"
git -C "$G" init -q 2>/dev/null
git -C "$G" config user.email t@example.invalid; git -C "$G" config user.name t
git -C "$G" config commit.gpgsign false; git -C "$G" config core.hooksPath "$WORK/nohooks"
v(){ printf '# template v%s\n' "$1"; }
v 1 > "$G/plug/$ORG_SRC"; printf '# git v1\n' > "$G/plug/$GIT_SRC"
git -C "$G" add plug >/dev/null; git -C "$G" commit -qm v1 --no-gpg-sign 2>/dev/null
v 2 > "$G/plug/$ORG_SRC"; git -C "$G" commit -qam v2 --no-gpg-sign
git -C "$G" rm -q "plug/$ORG_SRC"; git -C "$G" commit -qm gone --no-gpg-sign
v 3 > "$G/plug/$ORG_SRC"; git -C "$G" add "plug/$ORG_SRC"; git -C "$G" commit -qm v3 --no-gpg-sign
v 4 > "$G/plug/$ORG_SRC"                                   # working copy, not committed yet
( cd "$WORK" && bash "$G/plug/skills/lib/gen-digests.sh" >/dev/null 2>&1 )
MAN="$G/plug/content/.digests.json"
hasv(){ grep -q "$(v "$1" | sha)" "$MAN"; }          # piped, so the trailing newline is hashed too
check "the manifest is valid JSON" "PY -c 'import json,sys; json.load(open(sys.argv[1]))' \"$MAN\""
check "v1, v2 and v3 from history are recorded" "hasv 1 && hasv 2 && hasv 3"
check "the uncommitted working copy is recorded" "hasv 4"
check "the deleting commit did not record sha256 of empty content" \
  "! grep -q e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 \"$MAN\""
# That run recorded v4 from the working copy; then the template changed again before any commit. v4
# never shipped. The first generator unioned the working-tree manifest, so every such draft stayed in
# the manifest for good, as a version "shipped" that never left an editor.
v 5 > "$G/plug/$ORG_SRC"
bash "$G/plug/skills/lib/gen-digests.sh" >/dev/null 2>&1
check "a re-run after another edit drops the earlier, never-committed draft (v4)" "! hasv 4"
check "...records the new working copy (v5) and keeps every committed version" "hasv 5 && hasv 1 && hasv 2 && hasv 3"
# A history rewrite: a brand-new repository holding only the current files plus the old manifest.
G2="$WORK/rewritten"; mkdir -p "$G2"; cp -R "$G/plug" "$G2/plug"
git -C "$G2" init -q; git -C "$G2" config user.email t@example.invalid; git -C "$G2" config user.name t
git -C "$G2" config core.hooksPath "$WORK/nohooks"
git -C "$G2" add plug >/dev/null; git -C "$G2" commit -qm squashed --no-gpg-sign
bash "$G2/plug/skills/lib/gen-digests.sh" >/dev/null 2>&1
MAN="$G2/plug/content/.digests.json"
check "after a history rewrite, v1, v2 and v3 are still known (the committed manifest keeps them)" "hasv 1 && hasv 2 && hasv 3"
# The protection comes from the manifest COMMITTED at HEAD, not from the working-tree file (which is
# where drafts collect): a committed digest lost from the working-tree copy comes back.
PY - "$MAN" "$(v 1 | sha)" <<'PYEOF'
import json, sys
man = json.load(open(sys.argv[1], encoding="utf-8"))
for ds in man["artifacts"].values():
    if sys.argv[2] in ds:
        ds.remove(sys.argv[2])
json.dump(man, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PYEOF
check "fixture: v1 was removed from the working-tree manifest" "! hasv 1"
bash "$G2/plug/skills/lib/gen-digests.sh" >/dev/null 2>&1
check "...and a regeneration restores it from HEAD's manifest (a jq-style pretty file parses too)" "hasv 1"
printf '# template v0 (pre-history)\n' > "$WORK/v0.md"; V0=$(sha < "$WORK/v0.md")
bash "$G2/plug/skills/lib/gen-digests.sh" --seed "$ORG_SRC" "$WORK/v0.md" >/dev/null 2>&1
check "--seed records a version shipped before the history began" "grep -q $V0 \"$MAN\""
bash "$G2/plug/skills/lib/gen-digests.sh" >/dev/null 2>&1
check "an uncommitted seed survives a later run without --seed, listed under seeded" \
  "grep -q $V0 \"$MAN\" && PY -c 'import json,sys; assert sys.argv[2] in json.load(open(sys.argv[1]))[\"seeded\"]' \"$MAN\" \"$ORG_SRC:$V0\""
check "...and the manifest is still valid JSON" "PY -c 'import json,sys; json.load(open(sys.argv[1]))' \"$MAN\""
: > "$WORK/empty.md"
bash "$G2/plug/skills/lib/gen-digests.sh" --seed "$ORG_SRC" "$WORK/empty.md" >/dev/null 2>&1; RCE=$?
check "--seed refuses an empty file, whose digest would make an empty copy look pristine (exit 2)" "[ $RCE -eq 2 ]"
bash "$G2/plug/skills/lib/gen-digests.sh" --seed content/other.md "$WORK/v0.md" >/dev/null 2>&1; RCS=$?
check "--seed refuses an artifact the plugin does not manage (exit 2)" "[ $RCS -eq 2 ]"
printf '{"broken": true}\n' > "$MAN"
bash "$G2/plug/skills/lib/gen-digests.sh" >/dev/null 2>&1; RCB=$?
check "an unreadable manifest is refused, not silently replaced (exit 2)" \
  "[ $RCB -eq 2 ] && grep -q broken \"$MAN\""
# How this repository syncs with a fork users also install from: a version committed on the fork's line
# reaches main only through a merge that keeps main's file (-s ours). Default history simplification
# follows the TREESAME first parent and never lists the fork's commit, so its template would be missing
# from the manifest and every pristine copy of it would read as edited, forever (the union keeps it out).
G3="$WORK/forkmerge"; mkdir -p "$G3/plug/content" "$G3/plug/skills/lib"
cp "$GEN" "$G3/plug/skills/lib/gen-digests.sh"
git -C "$G3" init -q; git -C "$G3" config user.email t@example.invalid; git -C "$G3" config user.name t
git -C "$G3" config core.hooksPath "$WORK/nohooks"
printf '# fork line v1\n' > "$G3/plug/$ORG_SRC"; printf '# git v1\n' > "$G3/plug/$GIT_SRC"
git -C "$G3" add plug >/dev/null; git -C "$G3" commit -qm v1 --no-gpg-sign
MAINB=$(git -C "$G3" symbolic-ref --short HEAD)
git -C "$G3" checkout -qb fork; printf '# fork line v2\n' > "$G3/plug/$ORG_SRC"; git -C "$G3" commit -qam v2 --no-gpg-sign
git -C "$G3" checkout -q "$MAINB"; git -C "$G3" merge -q -s ours fork --no-edit --no-gpg-sign -m "sync fork"
git -C "$G3" branch -q -D fork
bash "$G3/plug/skills/lib/gen-digests.sh" >/dev/null 2>&1
check "a version that reached main only through a -s ours merge is recorded" \
  "grep -q \"\$(printf '# fork line v2\n' | sha)\" \"$G3/plug/content/.digests.json\""

finish
