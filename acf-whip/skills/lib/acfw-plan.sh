#!/usr/bin/env bash
# acfw-plan.sh — pure helpers for acf-whip cycle documents (3.5.0).
#
# Source this from acfw-cycle, acfw-spec, or a test:
#   . "<plugin>/skills/lib/acfw-plan.sh"
#
# WHY A SEPARATE LIB. Three programs must agree, byte for byte, on what a plan IS: acfw-cycle
# (approval, coverage, rule 10), acfw-spec (the blob a reviewer saw), and the tests that pin both. A
# second copy of the D-id parser or the content hash is a second definition of "the approved plan",
# and the first time they disagree an approval binds bytes nobody reviewed. So every definition lives
# here once: stdin/file in, stdout out, no store calls, no git writes, no jq, bash 3.2, BSD+GNU awk.
# A few helpers near the end READ git (trailers, the last approved body, porcelain); none writes.
# acfw-cycle also keeps its classifier, cycle scan and renderers here, so the rules that decide a
# stage are testable with plain text fixtures and no store at all.
#
# WHAT IS PINNED (INTERFACES.md; changing any of these un-approves every existing plan):
#   normalize   CRLF->LF, trailing whitespace stripped per line, trailing blank lines dropped,
#               exactly one final newline. Nothing else: no heading rewrites, no stripping of
#               comments. A normalization that "cleans up" content would let two different texts
#               share one approval.
#   content     v1:<git hash-object of the normalized bytes>. The v1: prefix is what lets a future
#               normalization change say so instead of silently invalidating every approval.
#   D-ids       only under the FIRST "## Deliverables" heading, only "### D<n>" headings, fenced
#               code blocks skipped. A fenced example that shows the template must never become
#               a deliverable, and a normalizing edit (em dash to colon) must never make one vanish,
#               which is why the heading regex keys on the number alone: ^### D([0-9]+)([^0-9]|$).
#
# Every helper that takes a <file> also accepts "-" for stdin.

# ---- identity checks ---------------------------------------------------------------------------
# A cycle folder name IS the cycle id: dated so names never collide across months, kebab so it is a
# safe path segment, a git pathspec, and a commit-subject fragment all at once.
#
# WHOLE-STRING, NEVER LINE-BASED. `printf %s "$v" | grep -qE '^...$'` passes when ANY line matches,
# so "foo<LF>../../../esc" was a valid slug and init wrote plan.md outside docs/cycles/. A case
# pattern sees the whole value, and an explicit character list (no a-z range) means the same thing
# in every locale: bash 3.2 collates ranges, so [a-z] can match capitals under en_US.
acfw_slug_ok() { case "${1:-}" in ""|-*|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;; esac; }
acfw_cycle_id_ok() {
  case "${1:-}" in [0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]-?*) ;; *) return 1 ;; esac
  acfw_slug_ok "${1:9}"
}
# A task stem as the store prints it (record's <stem>=<Ds>): alphanumeric start, then [A-Za-z0-9._-].
acfw_stem_ok() {
  case "${1:-}" in ""|[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*) return 1 ;; esac
  case "$1" in *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) return 1 ;; esac
}
# acfw_hex_ok <value> <min-length>: lowercase hex only, at least <min> characters (rule 11's --expect).
acfw_hex_ok() { case "${1:-}" in ""|*[!0123456789abcdef]*) return 1 ;; esac; [ "${#1}" -ge "${2:-1}" ]; }
# Lesson slugs are TIMELESS on purpose: "same slug = update" is how a contradicted lesson is rewritten
# in place. acf-librarian's audit checks every lesson slug against `[0-9]{8}|-v[0-9]+` and reports a
# hit on every run (1.3.0 reports lessons and never renames them; an older --fix renamed them, which
# forked one rule into two files on the next /retro). So the two middle checks are that regex exactly,
# anywhere in the slug: a looser `-v2-` test let api-v2beta through, and the audit then flagged a lesson
# acf-whip had just written. A leading version (v2-api) is refused too, which the audit does not ask
# for. The charset check runs first, so the greps only ever see one line.
acfw_lesson_slug_ok() {
  case "${1:-}" in ""|[!abcdefghijklmnopqrstuvwxyz]*|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;; esac
  printf '%s' "$1" | grep -qE '[0-9]{8}' && return 1
  printf '%s' "$1" | grep -qE -- '-v[0-9]+' && return 1
  printf '%s' "$1" | grep -qE '^v[0-9]+' && return 1
  return 0
}

# ---- normalization and content hash -------------------------------------------------------------
acfw_plan_normalize() { # <file|->
  local src="${1:--}"
  # Streaming: blank lines are held back and only emitted when a later non-blank line proves they
  # were interior, so trailing blank lines vanish without buffering the file. [[:space:]] in the C
  # locale includes \r, so stripping trailing whitespace is also the CRLF->LF rewrite.
  LC_ALL=C awk '
    { sub(/[[:space:]]+$/, "") }
    $0 == "" { held++; next }
    { while (held > 0) { print ""; held-- } print; any=1 }
    END { if (!any) print "" }
  ' "$src"
}

acfw_plan_content() { # <file|-> -> v1:<40 hex>
  local h
  h=$(acfw_plan_normalize "${1:--}" | git hash-object --stdin 2>/dev/null) || return 1
  [ -n "$h" ] || return 1
  printf 'v1:%s\n' "$h"
}

# c12 of any content token: "v1:<hex>", bare "<hex>", or empty. Always the first 12 hex after v1:.
acfw_plan_c12() { local v="${1:-}"; v="${v#v1:}"; printf '%s' "${v:0:12}"; }

# ---- the fence-aware section walker -------------------------------------------------------------
# One awk prelude shared by every reader below, so "inside a fence" means the same thing everywhere.
# CommonMark: up to 3 spaces of indent, then ``` or ~~~ (3+); closed by the same char, at least as
# long, with nothing after it. No interval expressions: onetrueawk (macOS) predates them.
ACFW_PLAN_AWK_FENCE='
function fence_step(line,   s, ind, ch, n, rest) {
  s = line; ind = 0
  while (ind < 3 && substr(s, 1, 1) == " ") { s = substr(s, 2); ind++ }
  if (substr(s, 1, 3) != "```" && substr(s, 1, 3) != "~~~") return 0
  ch = substr(s, 1, 1); n = 0
  while (substr(s, n + 1, 1) == ch) n++
  rest = substr(s, n + 1)
  if (!inFence) { inFence = 1; fch = ch; flen = n; return 1 }
  if (ch == fch && n >= flen && rest ~ /^[ \t]*$/) { inFence = 0; return 1 }
  return 1
}
function h2text(line,   t) { t = line; sub(/^##[ \t]+/, "", t); sub(/[ \t]+#+[ \t]*$/, "", t); sub(/[ \t]+$/, "", t); return t }
'

# acfw_plan_dids <file|-> -> "D<n>\t<heading text>" per deliverable; rc 3 when there is no
# "## Deliverables" heading at all (coverage OFF), rc 0 otherwise (even with zero D headings).
acfw_plan_dids() { # <file|->
  LC_ALL=C awk "$ACFW_PLAN_AWK_FENCE"'
    { line = $0; sub(/\r$/, "", line) }
    fence_step(line) { next }
    inFence { next }
    line ~ /^##[ \t]/ {
      if (inDel) { inDel = 0; done = 1 }
      else if (!done && h2text(line) == "Deliverables") { inDel = 1; seen = 1 }
      next
    }
    inDel && line ~ /^### D[0-9]+([^0-9]|$)/ {
      rest = substr(line, 6); n = ""
      while (substr(rest, 1, 1) ~ /[0-9]/) { n = n substr(rest, 1, 1); rest = substr(rest, 2) }
      sub(/^[ \t]+/, "", rest)
      # The separator is optional and cosmetic: colon (the template), hyphen, or an en/em dash a
      # human or formatter typed. Stripping all four keeps rule 10 comparing the words, not the glyph.
      if (substr(rest, 1, 1) == ":" || substr(rest, 1, 1) == "-") rest = substr(rest, 2)
      else if (substr(rest, 1, 3) == "\342\200\224" || substr(rest, 1, 3) == "\342\200\223") rest = substr(rest, 4)
      sub(/^[ \t]+/, "", rest); sub(/[ \t]+#+[ \t]*$/, "", rest); sub(/[ \t]+$/, "", rest)
      gsub(/\t/, " ", rest)
      printf "D%d\t%s\n", n + 0, rest
    }
    END { exit (seen ? 0 : 3) }
  ' "${1:--}"
}

# acfw_plan_section <file|-> <heading> -> the body lines of the first "## <heading>" section
# (fence-aware; the fenced lines themselves are included verbatim, only headings inside them are inert).
acfw_plan_section() { # <file|-> <heading>
  ACFW_SEC="${2:-}" LC_ALL=C awk "$ACFW_PLAN_AWK_FENCE"'
    BEGIN { want = ENVIRON["ACFW_SEC"] }
    { line = $0; sub(/\r$/, "", line) }
    fence_step(line) { if (inSec) print line; next }
    inFence { if (inSec) print line; next }
    line ~ /^#[ \t]/ || line ~ /^##[ \t]/ {
      if (inSec) { inSec = 0; done = 1 }
      else if (!done && line ~ /^##[ \t]/ && h2text(line) == want) inSec = 1
      next
    }
    inSec { print line }
  ' "${1:--}"
}

# acfw_plan_retire_slugs <file|-> -> one lesson slug per "- <slug>: ..." bullet of the first
# "## Retire" section (a retro-actions plan lists there the lessons a test or gate now enforces).
# Backticks around the slug are tolerated, since a model writes them unasked. Anything that is not a
# bullet naming a slug (the HTML comment, "None.") yields nothing, so a stray line never becomes a
# `git rm` on the approval card.
acfw_plan_retire_slugs() { # <file|->
  acfw_plan_section "${1:--}" Retire \
    | LC_ALL=C sed -n 's/^[[:space:]]*[-*][[:space:]]\{1,\}`\{0,1\}\([abcdefghijklmnopqrstuvwxyz][abcdefghijklmnopqrstuvwxyz0123456789-]*\)`\{0,1\}:.*/\1/p' \
    | awk '!seen[$0]++'
}

# acfw_plan_h1 <file|-> -> the first "# " heading text outside fences, or nothing.
acfw_plan_h1() { # <file|->
  LC_ALL=C awk "$ACFW_PLAN_AWK_FENCE"'
    { line = $0; sub(/\r$/, "", line) }
    fence_step(line) { next }
    inFence { next }
    line ~ /^#[ \t]+[^ \t]/ { t = line; sub(/^#[ \t]+/, "", t); sub(/[ \t]+#*[ \t]*$/, "", t); print t; exit }
  ' "${1:--}"
}

# acfw_plan_has_conflict <file|-> -> rc 0 when the file carries git conflict markers. "=======" alone
# is NOT a marker here: it is also a setext H1 underline, and refusing a plan over its own title would
# be a false refusal with no way out.
acfw_plan_has_conflict() { grep -qE '^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\|)( |$)' "${1:--}" 2>/dev/null; }

# ---- rule 10: D-ids are permanent once a task names them ---------------------------------------
# acfw_plan_rule10 <old-file> <new-file> <recorded-Ds-csv>  -> 0 ok · 8 violation (reason on stdout)
# Violation: a recorded D is gone, or a recorded D's heading text now sits under another id. That
# second case is the dangerous one: inserting a new D2 over recorded D1..D3 keeps the id "D2" alive,
# so a presence check alone passes, while coverage would mark the NEW D2 done through the OLD D2's
# task and decompose the old one a second time. Comparing the words catches it; rewording in place
# and reordering pass, because neither moves a recorded heading's words to a different id.
acfw_plan_rule10() { # <old> <new> <csv>
  local old="$1" new="$2" csv="${3:-}" od nd
  case "$csv" in ""|"-") return 0 ;; esac
  od=$(acfw_plan_dids "$old" 2>/dev/null) || true
  nd=$(acfw_plan_dids "$new" 2>/dev/null) || true
  ACFW_R10_OLD="$od" ACFW_R10_NEW="$nd" ACFW_R10_REC="$csv" LC_ALL=C awk '
    function norm(s) { s = tolower(s); gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
    BEGIN {
      n = split(ENVIRON["ACFW_R10_OLD"], L, "\n")
      for (i = 1; i <= n; i++) if (L[i] != "") { split(L[i], f, "\t"); otext[f[1]] = norm(f[2]); num = substr(f[1], 2) + 0; if (num > max) max = num }
      n = split(ENVIRON["ACFW_R10_NEW"], L, "\n")
      for (i = 1; i <= n; i++) if (L[i] != "") { split(L[i], f, "\t"); ntext[f[1]] = norm(f[2]); if (!(norm(f[2]) in where)) where[norm(f[2])] = f[1]; num = substr(f[1], 2) + 0; if (num > max) max = num }
      n = split(ENVIRON["ACFW_R10_REC"], R, ",")
      why = ""
      for (i = 1; i <= n; i++) {
        d = R[i]; gsub(/[ \t]/, "", d); if (d == "" || d == "-") continue
        if (!(d in ntext)) { why = d " is gone from the plan"; bad = d; break }
        t = otext[d]
        if (t != "" && (t in where) && where[t] != d && ntext[d] != t) { why = d " \"" t "\" now sits under " where[t]; bad = d; break }
      }
      if (why == "") exit 0
      printf "%s. D-ids are never renumbered: new work takes D%d; to drop %s, keep its heading and archive its tasks (it shows cancelled)\n", why, max + 1, bad
      exit 8
    }'
}

# ---- record.md readers (the machine document; see content/backlog/record-template.md) -----------
# acfw_plan_meta <file|-> <Field> -> the value of "- **Field**:" inside "## Metadata", trimmed.
acfw_plan_meta() { # <file|-> <Field>
  ACFW_MK="${2:-}" LC_ALL=C awk '
    BEGIN { k = ENVIRON["ACFW_MK"]; p = "- **" k "**:" }
    /^## / { sec = $0; sub(/^##[ \t]+/, "", sec); sub(/[ \t\r]+$/, "", sec); next }
    sec == "Metadata" && index($0, p) == 1 { v = substr($0, length(p) + 1); sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v); print v; exit }
  ' "${1:--}"
}

# A table separator is a line made ONLY of pipes, colons, dashes and blanks. The whole line has to
# match: a prefix test (`^\|[ :-]+\|`) also matches the coverage-off row `| - | off-001 |`, which then
# vanishes as a "separator", leaves the plan uncovered forever, and has /task --plan decompose it again
# on every run.
ACFW_PLAN_AWK_SEP='function is_sep(l) { return (l ~ /^[| \t\r:-]+$/ && l ~ /-/) }'

# acfw_plan_tasks <file|-> -> "<D>\t<stem,stem>" per "## Tasks" body row (D is "D<n>" or "-").
acfw_plan_tasks() { # <file|->
  LC_ALL=C awk "$ACFW_PLAN_AWK_SEP"'
    /^## / { sec = $0; sub(/^##[ \t]+/, "", sec); sub(/[ \t\r]+$/, "", sec); hdr = 0; next }
    sec != "Tasks" { next }
    /^\|/ {
      if (is_sep($0)) { hdr = 2; next }
      if (hdr < 2) { hdr = 1; next }
      n = split($0, c, "|"); d = c[2]; s = c[3]
      gsub(/[ \t]/, "", d); gsub(/[ \t]/, "", s)
      if (d != "") print d "\t" s
    }
  ' "${1:--}"
}

# acfw_plan_log_latest <file|-> <event> -> "ts\tevent\tby\tcontent\tdetails" of the NEWEST row (first
# from the top: the Plan Log is newest-first) whose Event cell equals <event>.
acfw_plan_log_latest() { # <file|-> <event>
  ACFW_EV="${2:-}" LC_ALL=C awk "$ACFW_PLAN_AWK_SEP"'
    BEGIN { want = ENVIRON["ACFW_EV"] }
    /^## / { sec = $0; sub(/^##[ \t]+/, "", sec); sub(/[ \t\r]+$/, "", sec); hdr = 0; next }
    sec != "Plan Log" { next }
    /^\|/ {
      if (is_sep($0)) { hdr = 2; next }
      if (hdr < 2) { hdr = 1; next }
      n = split($0, c, "|")
      for (i = 2; i <= 6; i++) { sub(/^[ \t]+/, "", c[i]); sub(/[ \t]+$/, "", c[i]) }
      if (c[3] == want) { print c[2] "\t" c[3] "\t" c[4] "\t" c[5] "\t" c[6]; exit }
    }
  ' "${1:--}"
}

# ---- record.md writers (stdout filters; the caller renames the result into place) --------------
# acfw_plan_record_set <file> <Field> <Value> [<Field> <Value>]... -> file with those Metadata
# bullets replaced. A bullet the document lacks is added at the end of the Metadata list, so a record
# written by an older template gains the field instead of silently losing the write.
acfw_plan_record_set() { # <file> (<Field> <Value>)...
  local f="$1" i=0; shift
  local envs=()
  # Every value is one cell: `approve --by` is typed by a person, and a newline in it would commit a
  # second "- **Status**:" bullet that one reader honours and another ignores.
  while [ $# -ge 2 ]; do
    i=$((i + 1)); envs[${#envs[@]}]="ACFW_SK$i=$1"; envs[${#envs[@]}]="ACFW_SV$i=$(acfw_plan_cell "$2")"; shift 2
  done
  # Two passes over the same file: the first finds the last Metadata bullet (where a missing field
  # goes), the second rewrites. Simpler than tracking blank lines in one pass, and just as atomic,
  # because the caller renames the whole output into place.
  env ACFW_SN="$i" ${envs[@]+"${envs[@]}"} LC_ALL=C awk '
    BEGIN { n = ENVIRON["ACFW_SN"] + 0; for (i = 1; i <= n; i++) { k[i] = ENVIRON["ACFW_SK" i]; v[i] = ENVIRON["ACFW_SV" i] } }
    function emit(i) { if (v[i] == "") print "- **" k[i] "**:"; else print "- **" k[i] "**: " v[i]; done[i] = 1 }
    /^## / { sec = $0; sub(/^##[ \t]+/, "", sec); sub(/[ \t\r]+$/, "", sec) }
    NR == FNR { if (sec == "Metadata" && $0 ~ /^- \*\*[^*]+\*\*:/) last = FNR; next }
    FNR == 1 { sec = "" }
    /^## / { sec = $0; sub(/^##[ \t]+/, "", sec); sub(/[ \t\r]+$/, "", sec) }
    sec == "Metadata" && $0 ~ /^- \*\*[^*]+\*\*:/ {
      hit = 0
      for (i = 1; i <= n; i++) if (!done[i] && index($0, "- **" k[i] "**:") == 1) { emit(i); hit = 1; break }
      if (!hit) print
      if (FNR == last) for (i = 1; i <= n; i++) if (!done[i]) emit(i)
      next
    }
    { print }
  ' "$f" "$f"
}

# acfw_plan_record_tasks <file> <rows-file> -> file with the "## Tasks" table body replaced by the
# rows in <rows-file> (already-rendered "| D1 | a, b |" lines). rc 3 when the section or its table
# separator is missing: the template always has both, so their absence means a hand-mangled record,
# and rebuilding a table somewhere guessed would be the tool writing where it cannot see.
acfw_plan_record_tasks() { # <file> <rows-file>
  ACFW_ROWS_FILE="$2" LC_ALL=C awk "$ACFW_PLAN_AWK_SEP"'
    BEGIN { rf = ENVIRON["ACFW_ROWS_FILE"] }
    /^## / { if (inBody) inBody = 0; sec = $0; sub(/^##[ \t]+/, "", sec); sub(/[ \t\r]+$/, "", sec); print; next }
    sec == "Tasks" && !placed && /^\|/ && is_sep($0) {
      print
      while ((getline r < rf) > 0) print r
      close(rf); placed = 1; inBody = 1; next
    }
    inBody && /^\|/ { next }
    inBody { inBody = 0 }
    { print }
    END { if (!placed) exit 3 }
  ' "$1"
}

# ---- cells, subjects ----------------------------------------------------------------------------
# acfw_plan_cell <text> -> one table cell: "|" -> "/", newlines/tabs -> space, other C0 stripped,
# trimmed, at most 160 characters (never a split UTF-8 sequence: the byte cut is re-validated).
acfw_plan_cell() {
  local s
  s=$(printf '%s' "${1:-}" | tr '\n\t\r' '   ' | tr -d '\000-\037' | tr '|' '/' \
      | LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ "${#s}" -gt 160 ] || [ "$(printf '%s' "$s" | LC_ALL=C wc -c | tr -d ' ')" -gt 160 ]; then
    s=$(printf '%s' "$s" | LC_ALL=C awk '{ printf "%s", substr($0, 1, 160) }')
    s=$(printf '%s' "$s" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || printf '%s' "$s")
  fi
  printf '%s' "$s"
}

# acfw_plan_subject <event> <cycle-id> -> "docs(plan): <event> <slug>", at most 50 characters, where
# slug is the id minus its date. The commit convention caps subjects at 50; a truncated slug still
# names the cycle because the full id rides in the ACFW-Plan-Event trailer.
acfw_plan_subject() { # <event> <id>
  local pre="docs(plan): $1 " slug="${2#[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-}" max
  max=$((50 - ${#pre}))
  [ "$max" -lt 1 ] && max=1
  slug="${slug:0:$max}"
  while [ "${slug%-}" != "$slug" ]; do slug="${slug%-}"; done
  printf '%s%s' "$pre" "$slug"
}

# ---- coverage, runnability, triggers: the one classifier ---------------------------------------
# acfw_plan_classify — stdin: tagged TSV, stdout: tagged TSV. PURE: every store fact arrives as input
# (acfw-cycle flattens the snapshot with jq, then calls this), so the rules below are testable
# without a store and are the SAME for status, triggers and check's callers.
#
# Env: ACFW_CL_MODE default|override · ACFW_CL_STORE <backend> · ACFW_CL_RCAP / ACFW_CL_BCAP caps (3)
#      ACFW_CL_CREATING=1 while this cycle's decompose lock is fresh (unresolved recorded stems are
#      being created by the running writer, not phantoms)
# In:  T stem id folder slug rc bc hasInteg(0/1) hasBranch(0/1) deps-csv integratedAt   (tasks+inactive)
#      X <same as T>        a per-stem `acfw-store read` result (accepted-terminal seeds a closure dropped)
#      G stem               the LP-CAS ledger marker for stem is in HEAD's tree (git, never the store)
#      S stem id            satisfiedDeps
#      R tok stem · U tok · A tok cands · I stem folder          the snapshot's scope{}
#      K D<n> text          known deliverables, plan order
#      D D<n>|- stem,stem   the record's ## Tasks rows
#      F stem               extra subjects (a plan-less focus)
# Out (a "-" stands for an empty field, so bash `read` never shifts columns):
#      ST stem class folder rc bc adv(0/1) wait(0/1)
#      CV D<n>|- sym text stem:class,...         sym: none ✓ ◐ ✗ ? cancelled
#      RB root kind dependent detail              root blockers of every waiting subject
#      TR rework|stuck|gap subject detail
#      SM adv=<n> wait=<n> final=<n> absent=<csv> integ=<n> unverified=<csv> phantom=<csv> clean=0|1
#         adv counts a waiting task whose unsatisfied deps reach work that moves on its own and no
#         human gate (hard rule 4); clean = every CV row is ✓ or cancelled
#
# Classes: done unverified integ inflight pending rejected blocked parked draft archived inert phantom
#          creating
#   phantom  the store does not answer for the recorded stem exactly (unresolved, ambiguous, or it
#            resolved to a DIFFERENT stem: resolved[tok] must equal tok)
#   done     accepted and terminal for the mode. A seed resolved but absent from tasks[] is accepted-
#            terminal (the closure drops those; without --digest that absence is the proof, never a
#            phantom), but "terminal" there includes BRANCHLESS-UNVERIFIED: the scope post-stage
#            calls a branchless code task terminal so the scheduler never waits on it. So in default
#            mode an absent seed is done only with a ledger marker (G) or when an X read proves it
#            non-code; otherwise it is unverified, never a silent check mark on a raw adapter while
#            files shows ? for the same task
#   integ    accepted, code, live branch, no ledger marker (default mode): /go still integrates it
#   unverified accepted, code, no branch, no marker, no Integrated-At ack: done as far as the
#            scheduler knows, but nobody can say the change reached trunk (coverage "?")
acfw_plan_classify() {
  LC_ALL=C awk -F'\t' '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function z(v) { return (v == "" ? "-" : v) }   # never an empty field: bash `read` collapses tabs
    BEGIN { mode = ENVIRON["ACFW_CL_MODE"]; store = ENVIRON["ACFW_CL_STORE"]
            rcap = ENVIRON["ACFW_CL_RCAP"] + 0; bcap = ENVIRON["ACFW_CL_BCAP"] + 0
            if (rcap < 1) rcap = 3; if (bcap < 1) bcap = 3; if (mode != "override") mode = "default"
            creating = (ENVIRON["ACFW_CL_CREATING"] == "1") }
    function put(s, a) { has[s] = 1; tid[s] = a[3]; fold[s] = a[4]; slug[s] = a[5]; rc[s] = a[6] + 0; bc[s] = a[7] + 0
                         integ[s] = a[8]; br[s] = a[9]; deps[s] = a[10]; iat[s] = a[11]; if (a[3] != "") byid[a[3]] = s }
    $1 == "T" { if ($2 == "") next; split($0, a, "\t"); if (!(($2) in xread)) put($2, a); next }
    $1 == "X" { if ($2 == "") next; split($0, a, "\t"); put($2, a); xread[$2] = 1; next }
    $1 == "G" { gled[$2] = 1; next }
    $1 == "S" { sat[$2] = 1; if ($3 != "") satid[$3] = $2; next }
    $1 == "R" { res[$2] = $3; nres++; next }
    $1 == "U" { unres[$2] = 1; next }
    $1 == "A" { amb[$2] = $3; next }
    $1 == "I" { inact[$2] = $3; next }
    $1 == "K" { nk++; kd[nk] = $2; ktext[$2] = $3; next }
    $1 == "D" { nd++; drow[nd] = $2; dst[$2] = $3; m = split($3, arr, ","); for (j = 1; j <= m; j++) inD[trim(arr[j])] = 1; next }
    $1 == "F" { nf++; foc[nf] = $2; next }

    function lookup(s) {
      if ((s in unres) || (s in amb)) return 0
      if (nres > 0 && (s in res) && res[s] != s) return 0
      if (s in has) return 1
      if (s in inact) { has[s] = 1; fold[s] = inact[s]; return 1 }
      if (nres > 0 && (s in res)) { absent[s] = 1; return 1 }
      if (s in sat) { absent[s] = 1; return 1 }
      return 0
    }
    function klass(s,   f, code) {
      if (s in K_) return K_[s]
      # record-first commits a stem BEFORE the writer creates it, so while the decompose lock of this cycle
      # is fresh an unresolved RECORDED stem is being created, not a phantom: a phantom card there would
      # hand out `record --drop` for a task the running writer is about to create.
      if (!lookup(s)) return (K_[s] = ((creating && (s in inD)) ? "creating" : "phantom"))
      if ((s in absent) && !(s in has)) return (K_[s] = ((mode == "override" || (s in gled)) ? "done" : "unverified"))
      f = fold[s]
      if (f == "archive") return (K_[s] = "archived")
      if (f == "draft") return (K_[s] = "draft")
      if (f == "blocked") return (K_[s] = ((rc[s] >= rcap || bc[s] >= bcap) ? "parked" : "blocked"))
      if (f == "rejected") return (K_[s] = "rejected")
      if (f == "pending") return (K_[s] = "pending")
      if (f == "in-progress" || f == "completed" || f == "in-review") return (K_[s] = "inflight")
      if (f == "accepted") {
        if (mode == "override") return (K_[s] = "done")
        code = (slug[s] != "" && slug[s] != "none")
        if (!code || integ[s] == "1" || integ[s] == "true") return (K_[s] = "done")
        if (br[s] == "1" || br[s] == "true") return (K_[s] = "integ")
        if (iat[s] ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]/) return (K_[s] = "done")
        return (K_[s] = "unverified")
      }
      return (K_[s] = "inert")
    }
    # Dependency token -> stem, mirroring indexTasks.resolve (id, stem, satisfiedDeps, UNIQUE prefix).
    function dres(tok,   k, c, n) {
      if (tok in has) return tok
      if (tok in byid) return byid[tok]
      if (tok in sat) return tok
      if (tok in satid) return satid[tok]
      n = 0; for (k in has) if (index(k, tok) == 1) { c = k; n++ }
      return (n == 1) ? c : ""
    }
    # Mirrors depsSatisfied in whip-go.workflow.js, one dependency at a time. A token the snapshot
    # cannot resolve is a dangling dep on files (the scanner keeps every active task AND every accepted
    # dep target, so absence proves nonexistence) but NOT on a raw adapter, whose closure drops
    # accepted-terminal deps: there absence is the common case of "done", and calling it dangling would
    # gate finished work forever.
    function unsat1(t, d,   ds) {
      ds = dres(d)
      if (ds == "") return (store == "files")
      if (!(ds in has)) return 0
      if (fold[ds] != "accepted") return 1
      return (mode == "default" && slug[ds] != slug[t] && slug[ds] != "none" && (br[ds] == "1" || br[ds] == "true") && !(integ[ds] == "1" || integ[ds] == "true"))
    }
    function depsat(t,   n, i, arr, d) {
      n = split(deps[t], arr, ",")
      for (i = 1; i <= n; i++) { d = trim(arr[i]); if (d != "" && d != "none" && unsat1(t, d)) return 0 }
      return 1
    }
    function adv(s,   c) {
      if (s in ADV_) return ADV_[s]
      c = klass(s)
      if (c == "inflight" || c == "rejected" || c == "integ") return (ADV_[s] = 1)
      if (c == "pending" || c == "blocked") return (ADV_[s] = depsat(s))
      return (ADV_[s] = 0)
    }
    function waiting(s,   c) {
      c = klass(s)
      if (c == "draft" || c == "inert" || c == "phantom" || c == "creating") return 1
      if ((c == "pending" || c == "blocked") && !adv(s)) return 1
      return 0
    }
    # walk(s): over the UNSATISFIED dependency closure of a waiting pending/blocked task, RA[s] = it
    # reaches a task that advances on its own, RX[s] = it reaches a root only a human clears (paused,
    # cancelled, parked, phantom, unknown state, a missing dep, or a dependency cycle). Hard rule 4:
    # a cycle task waiting on an out-of-cycle task that /go can move is NOT a dead end, because a
    # scoped /go pulls unmet transitive deps into its scope. Without this it counted as gated, no root
    # card fired, and NEXT fell through to /whip-doctor, which then found nothing wrong.
    function walk(s, depth,   n, i, arr, d, ds, k) {
      if (WK[s] == 2) return
      if (WK[s] == 1 || depth > 64) { RX[s] = 1; return }   # a cycle: the doctor reports cyclic-deps
      WK[s] = 1; RA[s] = 0; RX[s] = 0
      n = split(deps[s], arr, ",")
      for (i = 1; i <= n; i++) {
        d = trim(arr[i]); if (d == "" || d == "none" || !unsat1(s, d)) continue
        ds = dres(d)
        if (ds == "") { RX[s] = 1; continue }
        k = klass(ds)
        if (k == "creating") continue                        # the running /task writer creates it
        if (adv(ds)) { RA[s] = 1; continue }
        if (k == "pending" || k == "blocked") { walk(ds, depth + 1); if (RA[ds]) RA[s] = 1; if (RX[ds] || WK[ds] == 1) RX[s] = 1; continue }
        if (k != "done" && k != "unverified") RX[s] = 1
      }
      WK[s] = 2
    }
    # Root blocker: follow unsatisfied deps until something that will never advance on its own.
    function roots(s, dependent, depth,   c, n, i, arr, d, ds, k) {
      if (depth > 64 || ((s SUBSEP dependent) in seenR)) return
      seenR[s, dependent] = 1
      c = klass(s)
      if (c == "draft")   { rb(s, "paused", dependent); return }
      if (c == "inert")   { rb(s, "invalid-state", dependent); return }
      if (c == "phantom") { rb(s, "phantom", dependent); return }
      if (c == "archived"){ rb(s, "cancelled", dependent); return }
      if (c == "parked")  { rb(s, "parked", dependent); return }
      if (c != "pending" && c != "blocked") return
      if (adv(s)) return
      n = split(deps[s], arr, ",")
      for (i = 1; i <= n; i++) {
        d = trim(arr[i]); if (d == "" || d == "none" || !unsat1(s, d)) continue
        ds = dres(d)
        if (ds == "") { rb(d, "missing", s); continue }
        k = klass(ds)
        if (k == "done" || k == "unverified" || k == "creating") continue
        if (adv(ds)) continue
        roots(ds, s, depth + 1)
      }
    }
    function rb(root, kind, dependent) {
      if ((root SUBSEP kind) in rbSeen) return
      rbSeen[root, kind] = 1
      printf "RB\t%s\t%s\t%s\t%s\n", root, kind, z(dependent), ((root in has) ? "rc=" rc[root] " bc=" bc[root] : "-")
    }
    END {
      # subjects: every recorded stem, then plan-less focus stems
      for (i = 1; i <= nd; i++) { m = split(dst[drow[i]], arr, ","); for (j = 1; j <= m; j++) { s = trim(arr[j]); if (s != "" && !(s in subj)) { subj[s] = 1; ns++; sl[ns] = s } } }
      for (i = 1; i <= nf; i++) { s = trim(foc[i]); if (s != "" && !(s in subj)) { subj[s] = 1; ns++; sl[ns] = s } }
      nadv = 0; nwait = 0; nfin = 0; ab = ""; uv = ""; ph = ""; nint = 0
      for (i = 1; i <= ns; i++) {
        s = sl[i]; c = klass(s); av = adv(s); w = (av ? 0 : waiting(s))
        # Hard rule 4: waiting only on work that moves by itself (and on no human gate) is advancing.
        if (w && (c == "pending" || c == "blocked")) { walk(s, 0); if (RA[s] && !RX[s]) { av = 1; w = 0 } }
        if (av) nadv++; else if (w) nwait++; else nfin++
        if ((s in absent) && !(s in xread)) ab = ab (ab == "" ? "" : ",") s
        if (c == "unverified") uv = uv (uv == "" ? "" : ",") s
        if (c == "phantom") ph = ph (ph == "" ? "" : ",") s
        if (c == "integ") nint++
        printf "ST\t%s\t%s\t%s\t%d\t%d\t%d\t%d\n", s, c, z(fold[s]), rc[s], bc[s], av, w
        if (w) roots(s, "", 0)
        if (fold[s] == "accepted" && rc[s] >= 2) printf "TR\trework\t%s\trc=%d\n", s, rc[s]
        if (fold[s] == "blocked") printf "TR\tstuck\t%s\tblocked\n", s
        else if (bc[s] >= 2) printf "TR\tstuck\t%s\tbc=%d\n", s, bc[s]
      }
      # coverage, in plan order, then recorded rows the plan no longer names, then the "-" row
      for (i = 1; i <= nk; i++) { order[++no] = kd[i]; inK[kd[i]] = 1 }
      for (i = 1; i <= nd; i++) if (!(drow[i] in inK) && drow[i] != "-") order[++no] = drow[i]
      if ("-" in dst) order[++no] = "-"
      for (i = 1; i <= no; i++) {
        d = order[i]; m = split(dst[d], arr, ","); list = ""; live = 0; arch = 0; ok = 0; q = 0; blk = 0; phn = 0
        for (j = 1; j <= m; j++) {
          s = trim(arr[j]); if (s == "") continue
          c = klass(s); list = list (list == "" ? "" : ",") s ":" c
          if (c == "archived") { arch++; continue }
          live++
          if (c == "done") ok++
          else if (c == "unverified") q++
          else if (c == "blocked" || c == "parked") blk++
          else if (c == "phantom") phn++
        }
        if (list == "") sym = "none"
        else if (live == 0) sym = "cancelled"
        else if (blk > 0 || phn > 0) sym = "\342\234\227"
        else if (ok == live) sym = "\342\234\223"
        else if (ok + q == live) sym = "?"
        else sym = "\342\227\220"
        # clean = every deliverable is finished for good (✓ or cancelled). A retro-actions cycle closes
        # itself only then: parked (✗) or unverified (?) work counts as "final" to the scheduler, and
        # closing over it would bury a human gate in a cycle nothing resolves any more.
        if (sym != "\342\234\223" && sym != "cancelled") dirty = 1
        printf "CV\t%s\t%s\t%s\t%s\n", d, sym, z(ktext[d]), z(list)
        if (d != "-" && (blk > 0 || phn > 0)) printf "TR\tgap\t%s\t-\n", d
      }
      printf "SM\tadv=%d\twait=%d\tfinal=%d\tabsent=%s\tinteg=%d\tunverified=%s\tphantom=%s\tclean=%d\n", nadv, nwait, nfin, ab, nint, uv, ph, (dirty || no == 0) ? 0 : 1
    }
  '
}

# ---- cycle folder scan, follow-through, rendering (pure: files in, text out) ---------------------
# acfw_plan_scan <repo-root> -> "id \t status \t kind \t approvedBy \t createdBy \t stems-csv" per cycle
# (an empty field is "-"). One awk pass over docs/cycles/*/record.md: no git, no store. A folder
# counts only if its name is an ID and its record.md carries Format plus an ID equal to it, so a
# stray note or another tool's plan dropped into docs/cycles/ is ignored by construction.
acfw_plan_scan() { # <repo-root>
  set -- "${1:-.}"/docs/cycles/*/record.md
  [ -e "$1" ] || return 0
  LC_ALL=C awk "$ACFW_PLAN_AWK_SEP"'
    function f(v) { return (v == "" ? "-" : v) }
    function flush(   n, p, dir) {
      if (file == "") return
      n = split(file, p, "/"); dir = p[n - 1]
      if (dir ~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[a-z0-9][a-z0-9-]*$/ && fmt != "" && id == dir)
        print dir "\t" f(st) "\t" f(kind) "\t" f(ab) "\t" f(cb) "\t" f(stems)
    }
    FNR == 1 { flush(); file = FILENAME; sec = ""; fmt = ""; id = ""; st = ""; kind = ""; ab = ""; cb = ""; stems = ""; hdr = 0; got = " " }
    /^## / { sec = $0; sub(/^##[ \t]+/, "", sec); sub(/[ \t\r]+$/, "", sec); hdr = 0; next }
    sec == "Metadata" && /^- \*\*[^*]+\*\*:/ {
      k = $0; sub(/^- \*\*/, "", k); v = k; sub(/\*\*:.*$/, "", k); sub(/^[^*]*\*\*:[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v)
      # FIRST bullet per key wins, exactly as acfw_plan_meta reads it: if resolution and load_cycle
      # disagreed about a duplicated Status, one would skip a cycle the other acts on.
      if (index(got, " " k " ")) next
      got = got k " "
      if (k == "Format") fmt = v; else if (k == "ID") id = v; else if (k == "Status") st = v
      else if (k == "Kind") kind = v; else if (k == "Approved By") ab = v; else if (k == "Created By") cb = v
      next
    }
    sec == "Tasks" && /^\|/ {
      if (is_sep($0)) { hdr = 2; next }
      if (hdr < 2) { hdr = 1; next }
      split($0, c, "|"); s = c[3]; gsub(/[ \t]/, "", s); if (s != "") stems = stems (stems == "" ? "" : ",") s
    }
    END { flush() }' "$@"
}

# acfw_plan_follow <repo-root> <this-cycle-id> [<exclude-id>...] -> "FOLLOW|<id>|status=..|ds=..|
# uncovered=.." (or FOLLOW|none) plus one human line: did the PREVIOUS retro's action items get
# decomposed? Store-free, so a clean close costs no board walk; whether their tasks FINISHED is what
# `status <id>` answers. `close ... --actions <new>` passes the folder this retro just created (and any
# dead draft of its own): by ID it is the newest retro-actions cycle, and reporting it would grade this
# retro against itself. Nothing else is excluded, untracked drafts included.
acfw_plan_follow() { # <repo-root> <this-cycle-id> [<exclude-id>...]
  local root="$1" me="$2" line pid pst pds prec punc
  shift 2
  line=$(acfw_plan_scan "$root" | ACFW_FX=" $me $* " awk -F'\t' 'BEGIN { x = ENVIRON["ACFW_FX"] }
    !index(x, " " $1 " ") && $3 == "retro-actions" && $2 != "abandoned"' | LC_ALL=C sort | tail -1)
  if [ -z "$line" ]; then echo "FOLLOW|none"; echo "follow-through: no earlier retro-actions cycle"; return 0; fi
  pid=$(printf '%s' "$line" | cut -f1); pst=$(printf '%s' "$line" | cut -f2)
  pds=$(acfw_plan_dids "$root/docs/cycles/$pid/plan.md" 2>/dev/null | cut -f1)
  prec=$(acfw_plan_tasks "$root/docs/cycles/$pid/record.md" | awk -F'\t' '$2 != "" {print $1}')
  punc=$(printf '%s\n' "$pds" | grep -v '^$' | while IFS= read -r d; do printf '%s\n' "$prec" | grep -qxF "$d" || echo "$d"; done | paste -sd, -)
  printf 'FOLLOW|%s|status=%s|ds=%s|uncovered=%s\n' "$pid" "$pst" "$(printf '%s\n' "$pds" | grep -c '^D')" "$punc"
  printf 'follow-through: retro actions %s are %s; not yet decomposed: %s\n' "$pid" "$pst" "${punc:-none}"
}

# acfw_plan_coverage_text <mode> — stdin: acfw_plan_classify output -> the STATUS coverage block.
acfw_plan_coverage_text() { # <mode>
  LC_ALL=C awk -F'\t' -v mode="${1:-default}" '
    function lab(c, f) {
      if (c == "done") return ""
      if (c == "unverified") return " (accepted, unverified)"; if (c == "integ") return " (awaiting integration)"
      if (c == "inflight") return " (" f ")"; if (c == "parked") return " (blocked at the cap)"
      if (c == "draft") return " (paused)"; if (c == "archived") return " (cancelled)"
      if (c == "phantom") return " (not in the store)"; if (c == "inert") return " (unknown state)"
      if (c == "creating") return " (being created)"
      return " (" c ")"
    }
    $1 == "ST" { fo[$2] = $4 }
    $1 == "CV" { n++; d[n] = $2; sy[n] = $3; tx[n] = ($4 == "-" ? "" : $4); li[n] = ($5 == "-" ? "" : $5) }
    END {
      if (!n) exit
      print "  coverage (" mode " mode)"
      for (i = 1; i <= n; i++) {
        s = sy[i]; l = li[i]; if (s == "none") { s = "\302\267"; l = "" }
        line = (d[i] == "-") ? "    (coverage off) " s : "    " d[i] " " s (tx[i] == "" ? "" : " " tx[i])
        if (l != "") { m = split(l, it, ","); sep = ":"; for (j = 1; j <= m; j++) { k = index(it[j], ":"); st = substr(it[j], 1, k - 1); line = line sep " " st lab(substr(it[j], k + 1), fo[st]); sep = "," } }
        else if (s == "\302\267") line = line " (not decomposed)"
        print line
      }
    }'
}

# acfw_plan_task_rows — stdin "D<n>|-\tstem" pairs -> "## Tasks" rows: one per deliverable in D-order
# ("-" last), stems sorted, unique, comma+space separated.
acfw_plan_task_rows() {
  LC_ALL=C awk -F'\t' 'NF >= 2 && $2 != "" { k = ($1 == "-") ? 999999 : substr($1, 2) + 0; print k "\t" $1 "\t" $2 }' \
    | LC_ALL=C sort -t"$(printf '\t')" -k1,1n -k3,3 -u \
    | LC_ALL=C awk -F'\t' '$2 != p { if (p != "") print "| " p " | " l " |"; p = $2; l = $3; next } { l = l ", " $3 } END { if (p != "") print "| " p " | " l " |" }'
}

# acfw_plan_fill <template> — stdout: the template with {{TITLE}} {{ID}} {{KIND}} {{SOURCE}}
# {{CREATED_BY}} {{CREATED_AT}} replaced from ACFW_FILL_<NAME> env vars. index/substr, never gsub:
# a title may contain "&" or "\", which a gsub replacement string would reinterpret.
acfw_plan_fill() { # <template>
  LC_ALL=C awk '
    function rep(s, tok, v,   i) { while ((i = index(s, tok)) > 0) s = substr(s, 1, i - 1) v substr(s, i + length(tok)); return s }
    { s = $0; n = split("TITLE ID KIND SOURCE CREATED_BY CREATED_AT", k, " ")
      for (i = 1; i <= n; i++) s = rep(s, "{{" k[i] "}}", ENVIRON["ACFW_FILL_" k[i]]); print s }' "$1"
}

# ---- read-only git and file helpers (no store, no writes) ----------------------------------------
# acfw_plan_lock_age <file> -> minutes since the lock was written (its ts= line, else mtime); empty if absent.
acfw_plan_lock_age() {
  local f="$1" ts
  [ -f "$f" ] || return 0
  ts=$(sed -n 's/^ts=\([0-9][0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1)
  # GNU first: on coreutils `stat -f` means --file-system, prints a filesystem report to STDOUT and
  # fails, and a `||` fallback would append to that. BSD rejects -c with nothing on stdout. A value
  # that is still not a number (hand-made lock, exotic stat) dates the lock to the epoch: stale,
  # never "fresh forever", which would refuse every check with no way out but the printed rm.
  [ -n "$ts" ] || ts=$(stat -c %Y "$f" 2>/dev/null) || ts=$(stat -f %m "$f" 2>/dev/null)
  case "$ts" in ""|*[!0123456789]*) ts=0 ;; esac
  printf '%s' $(( ($(date -u +%s) - ts) / 60 ))
}

# acfw_plan_trailer_seen <root> <folder-rel> <event> <c12> <id> -> 0 when a commit touching the folder
# carries "ACFW-Plan-Event: <event> <c12> <id>". Indented trailers count: a squash that indents them
# keeps the audit, so it must not raise the missing-trailer WARN.
acfw_plan_trailer_seen() {
  git -C "$1" log -n 200 --format=%B -- "$2" 2>/dev/null \
    | grep -qE "^[[:space:]]*ACFW-Plan-Event:[[:space:]]+$3[[:space:]]+$4[0-9a-f]*[[:space:]]+$5[[:space:]]*$"
}

# acfw_plan_old_body <root> <plan-rel> <c12> <out-file> -> 0 and <out-file> holds the last APPROVED
# body: the newest plan.md blob (200 commits, path-limited) whose content hash starts with <c12>.
# Found by content, never through trailers, so a squash or shallow clone cannot hide it.
acfw_plan_old_body() {
  local sha
  [ -n "$3" ] || return 1
  for sha in $(git -C "$1" log -n 200 --format=%H -- "$2" 2>/dev/null); do
    git -C "$1" show "$sha:$2" > "$4" 2>/dev/null || continue
    [ "$(acfw_plan_c12 "$(acfw_plan_content "$4")")" = "$3" ] && return 0
  done
  return 1
}

# acfw_plan_porcelain <root> -> "XY\tpath\thash" per changed path (untracked files listed one by one,
# rename origins as "RO"). The hash makes a further edit to an ALREADY-dirty file visible: comparing
# status letters alone would let a retro rewrite a file that was modified before it started.
acfw_plan_porcelain() {
  git -C "$1" status --porcelain=v1 -z --untracked-files=all 2>/dev/null | {
    skip=0
    while IFS= read -r -d '' rec; do
      if [ $skip = 1 ]; then skip=0; printf 'RO\t%s\t-\n' "$rec"; continue; fi
      xy="${rec:0:2}"; p="${rec:3}"
      case "$xy" in R*|C*) skip=1 ;; esac
      h=-; [ -f "$1/$p" ] && h=$(git -C "$1" hash-object -- "$p" 2>/dev/null)
      printf '%s\t%s\t%s\n' "$xy" "$p" "$h"
    done
  }
}

# acfw_plan_blocker <kind> <root> <dependent> <detail> <cycle-id> <plan-rel> <acfw-cycle path> [<in-cycle>] [<dep-state>]
# -> "what\trisk\treply" for one root blocker. Cards tell the truth about lifetime counters: moving a
# capped task back to pending buys exactly one more attempt, because the counters never reset.
# <in-cycle> is how the cycle's ## Tasks holds the root: "sole:<Ds>" (every D naming it names only it),
# "shared:<Ds>", or empty (not a task of this cycle). A parked SOLE task is redesigned inside the
# cycle: archived, dropped from the map (its D turns uncovered) and re-decomposed by /task --plan. A
# free-text /task there made a task no cycle owns, the D showed cancelled, and the cycle closed clean
# with the deliverable never redone. Shared, dropping it leaves the D covered, so /task --plan would
# do nothing: the new task is mapped by hand instead.
# <dep-state> (9th, optional) is the dependent's current state. whip-move takes a state before any
# flag ("pass the current state to edit in place"), so `/whip-move <d> --add-dep <id>` without one is a
# usage error: every REPLY that adds a dependency names the state the dependent is in (pending if unknown).
acfw_plan_blocker() {
  local k="$1" r="$2" d="$3" det="$4" s="" m="${8:-}" add="" dl ds="${9:-}"
  case "$ds" in pending|in-progress|completed|in-review|accepted|rejected|blocked|draft|archive) ;; *) ds=pending ;; esac
  [ -n "$d" ] && s="$d waits on it: "
  [ -n "$d" ] && add="; then point $d at the new task: /whip-move $d $ds --add-dep <new id>"
  dl="${m#*:}"; [ "$dl" = - ] && dl="the plan (coverage off)"
  case "$k" in
    paused)    printf '%s%s is paused (draft)\tit and everything behind it stay put; if a spec tool held it, /whip --review %s shows why\t/whip-move %s pending\n' "$s" "$r" "$r" "$r" ;;
    cancelled) printf '%s%s is cancelled (archived)\t%s can never start while it depends on a cancelled task\t/whip-move %s pending\n' "$s" "$r" "${d:-its dependent}" "$r" ;;
    parked) case "$m" in
      sole:*)   printf "%s%s is blocked at the cap (%s)\t/whip-move %s pending buys exactly one more attempt: the counters are lifetime and stay where they are. To redesign it inside the cycle instead, the reply archives it and hands %s back to /task --plan%s\t/whip-move %s archive, then bash '%s' record %s --drop %s, then /task --plan %s\n" \
                  "$s" "$r" "$det" "$r" "$dl" "$add" "$r" "$7" "$5" "$r" "$6" ;;
      shared:*) printf "%s%s is blocked at the cap (%s)\t/whip-move %s pending buys exactly one more attempt: the counters are lifetime and stay where they are. To redesign it inside the cycle instead: /whip-move %s archive, /task \"<new scope>\", then bash '%s' record %s <new stem>=%s%s\t/whip-move %s pending\n" \
                  "$s" "$r" "$det" "$r" "$r" "$7" "$5" "${m#*:}" "$add" "$r" ;;
      *)        printf '%s%s is blocked at the cap (%s)\t/whip-move %s pending buys exactly one more attempt: the counters are lifetime and stay where they are. To redesign instead: /whip-move %s archive, then /task "<new scope>"%s\t/whip-move %s pending\n' \
                  "$s" "$r" "$det" "$r" "$r" "${d:+ and /whip-move $d $ds --add-dep <new id>}" "$r" ;;
    esac ;;
    # The doctor only reports a dangling dependency; the remedy is new work plus a new edge. The old
    # token stays in the list until someone deletes it, so the RISK says so; a typo is fixed in place.
    missing)   printf "%s depends on '%s', which no task in the store matches\tthe doctor holds %s out of every run until that dependency resolves. After adding the new id, delete '%s' from %s's Dependencies line; if '%s' is a typo, fix it there instead\t/task \"<the missing work>\", then /whip-move %s %s --add-dep <new id>\n" "$d" "$r" "$d" "$r" "$d" "$r" "$d" "$ds" ;;
    invalid-state) printf '%s%s is in a state acf-whip does not recognise\tthe scheduler treats it as inert, so nothing behind it moves\t/whip-doctor\n' "$s" "$r" ;;
    phantom)   printf "%s records task %s, but the store has no task with exactly that key\tits deliverable can never finish, and /task --plan still counts it as decomposed\tbash '%s' record %s --drop %s, then /task --plan %s\n" "$5" "$r" "$7" "$5" "$r" "$6" ;;
    *) return 1 ;;
  esac
}
