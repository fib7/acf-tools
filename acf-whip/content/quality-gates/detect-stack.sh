#!/usr/bin/env bash
# detect-stack.sh: report a project's stack for /whip-init and /whip-add-agents, so the two skills
# can never disagree about it. Run it from the project root. It prints shell assignments, one per
# line, safe to eval: every value comes from a fixed vocabulary or a validated flag, never from the
# project's files.
#
#   backend           go | python | nodejs | (empty), or the --backend= flag's value
#   frontend          nextjs | react | vue | (empty), or the --frontend= flag's value
#   node_framework    express | fastify | nestjs | none   (none = plain Node.js; empty = no package.json)
#   node_test_runner  vitest | jest | mocha | node --test | npm test | none
#   node_typescript   true | false
#   node_linter       eslint | npm run lint | none
#   node_formatter    prettier | none
#   node_test_cmd, node_lint_cmd, node_typecheck_cmd, node_format_cmd, node_build_cmd
#                     the gate command for that slot, or empty when the project has no such gate:
#                     npm test, npx vitest run, npx jest, npx mocha | npm run lint, npx eslint . |
#                     npm run typecheck, npx tsc --noEmit | npx prettier --check . | npm run build
#   gate_stack        go | python | nodejs | (empty)
#                     the BACKEND's gates: picks content/pre-commit-configs/.pre-commit-config-<gate_stack>.yaml
#                     and the docs/development/quality-gates-<gate_stack>.md destination. Empty for a
#                     stack with no shipped doc (a flag like --backend=rust) or no stack at all.
#   gates_doc         the content/quality-gates/ source for that destination
#   frontend_gate_stack  nodejs | (empty)
#                     the FRONTEND's gates, set whenever frontend is: every frontend is Node.js tooling,
#                     so a React app next to a Go or Python backend reads quality-gates-nodejs.md, never
#                     the backend's gates. Equal to gate_stack when the backend is Node.js too.
#   frontend_gates_doc   nextjs-typescript.md | nodejs.md | (empty): the source for that destination
#
# Arguments: --backend=<stack> and --frontend=<stack> override detection for that slot, so a skill's
# flags pick the gates. Every other argument is ignored, so a skill can pass all of its flags. A value
# that is not a lowercase stack name is ignored with a warning, which keeps the output safe to eval.
#
# The backend is first match: go.mod, then a Python manifest, then a Node.js server framework. A
# package.json with no server or UI framework is still a Node.js project (node_framework=none): a
# plain CLI or library must not come out as "no stack", which is what the 3.5.0 canary hit.
# TypeScript, a linter and a formatter are reported only when the project has them, because every
# consumer of this output (the pre-commit config, the gates doc, the specialist agent) must not
# require a tool the project never chose.
set -u
LC_ALL=C; export LC_ALL   # [a-z] below means ASCII lowercase, in every locale

flag_backend=""
flag_frontend=""
# Split every argument on whitespace, globbing off: a skill passes its flags as one quoted "$FLAGS",
# because zsh (the shell the Bash tool runs for many users) does not word-split an unquoted $FLAGS.
set -f
for arg in $*; do
  case "$arg" in
    --backend=*) which=backend; v=${arg#--backend=} ;;
    --frontend=*) which=frontend; v=${arg#--frontend=} ;;
    *) continue ;;
  esac
  case "$v" in
    ''|*[!a-z0-9-]*) echo "detect-stack.sh: ignoring --$which: '$v' is not a stack name" >&2; continue ;;
  esac
  if [ "$which" = backend ]; then flag_backend=$v; else flag_frontend=$v; fi
done
set +f

backend="$flag_backend"
frontend="$flag_frontend"
node_framework=""
node_test_runner=""
node_typescript=false
node_linter=none
node_formatter=none
node_test_cmd=""
node_lint_cmd=""
node_typecheck_cmd=""
node_format_cmd=""
node_build_cmd=""
gate_stack=""
gates_doc=""
frontend_gate_stack=""
frontend_gates_doc=""

any_exists() { # <path|glob>... : true when at least one exists (an unmatched glob stays literal)
  local f
  for f in "$@"; do [ -e "$f" ] && return 0; done
  return 1
}

if [ -n "$backend" ]; then
  :   # named by a flag
elif [ -f go.mod ]; then
  backend=go
elif any_exists requirements.txt pyproject.toml setup.py setup.cfg Pipfile; then
  backend=python
fi

if [ -f package.json ]; then
  # One line per fact: "dep <name>", "script <name>", "cfg <tool>", "test <test script>".
  PKG=""
  if command -v node >/dev/null 2>&1; then
    PKG=$(node -e '
      let p = {};
      try { p = JSON.parse(require("fs").readFileSync("package.json", "utf8")) || {}; } catch (e) { process.exit(3); }
      const deps = Object.assign({}, p.optionalDependencies, p.peerDependencies, p.devDependencies, p.dependencies);
      const scripts = p.scripts || {};
      const out = [];
      for (const k of Object.keys(deps)) out.push("dep " + k);
      for (const k of Object.keys(scripts)) out.push("script " + k);
      if (p.eslintConfig) out.push("cfg eslint");
      if (p.prettier) out.push("cfg prettier");
      out.push("test " + String(scripts.test || "").replace(/\s+/g, " "));
      process.stdout.write(out.join("\n") + "\n");
    ' 2>/dev/null) || PKG=""
  fi
  if [ -z "$PKG" ]; then
    # No node (or unparseable JSON): approximate. Every "key": in the file counts as a dependency and
    # as a script, which over-reports and never under-reports. grep -o, not a per-line sed, so a
    # package.json written on one line reads the same as a pretty-printed one.
    PKG=$(grep -oE '"[^"]+"[[:space:]]*:' package.json | sed 's/^"//; s/"[[:space:]]*:$//' \
          | awk '{ print "dep " $0; print "script " $0; if ($0 == "eslintConfig") print "cfg eslint" }')
    PKG="$PKG
test $(grep -oE '"test"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' package.json | head -n 1 \
       | sed 's/^"test"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  fi
  pkg_has() { printf '%s\n' "$PKG" | grep -Eq "^($1)\$"; }

  # Next.js ships react, so it is tested first.
  if [ -n "$frontend" ]; then :   # named by a flag
  elif pkg_has 'dep next'; then frontend=nextjs
  elif pkg_has 'dep react'; then frontend=react
  elif pkg_has 'dep vue'; then frontend=vue
  fi

  if pkg_has 'dep @nestjs/[^ ]+'; then node_framework=nestjs
  elif pkg_has 'dep fastify'; then node_framework=fastify
  elif pkg_has 'dep express'; then node_framework=express
  fi
  if [ -n "$node_framework" ]; then
    [ -z "$backend" ] && backend=nodejs
  elif [ -z "$backend" ] && [ -z "$frontend" ]; then
    backend=nodejs
    node_framework=none
  fi

  test_script=$(printf '%s\n' "$PKG" | sed -n 's/^test //p' | head -n 1)
  case "$test_script" in *'no test specified'*) test_script="" ;; esac   # npm init's placeholder
  case "$test_script" in
    '')
      if pkg_has 'dep vitest'; then node_test_runner=vitest
      elif pkg_has 'dep jest'; then node_test_runner=jest
      elif pkg_has 'dep mocha'; then node_test_runner=mocha
      else node_test_runner=none
      fi ;;
    *vitest*) node_test_runner=vitest ;;
    *jest*) node_test_runner=jest ;;
    *mocha*) node_test_runner=mocha ;;
    *node*--test*) node_test_runner='node --test' ;;
    *) node_test_runner='npm test' ;;
  esac

  if [ -f tsconfig.json ] || pkg_has 'dep typescript'; then node_typescript=true; fi

  if pkg_has 'dep eslint|cfg eslint' || any_exists eslint.config.* .eslintrc .eslintrc.*; then
    node_linter=eslint
  elif pkg_has 'script lint'; then
    node_linter='npm run lint'
  fi

  if pkg_has 'dep prettier|cfg prettier' || any_exists .prettierrc .prettierrc.* prettier.config.*; then
    node_formatter=prettier
  fi

  # The gate commands an agent runs, one per slot. Empty = the project has no such gate, and the
  # slot is dropped: it is never filled with a tool the project does not run.
  if [ -n "$test_script" ]; then node_test_cmd='npm test'
  else
    case "$node_test_runner" in   # a runner installed but never wired to a test script
      vitest) node_test_cmd='npx vitest run' ;;
      jest) node_test_cmd='npx jest' ;;
      mocha) node_test_cmd='npx mocha' ;;
    esac
  fi
  if pkg_has 'script lint'; then node_lint_cmd='npm run lint'
  elif [ "$node_linter" = eslint ]; then node_lint_cmd='npx eslint .'
  fi
  if pkg_has 'script typecheck'; then node_typecheck_cmd='npm run typecheck'
  elif [ "$node_typescript" = true ]; then node_typecheck_cmd='npx tsc --noEmit'
  fi
  [ "$node_formatter" = prettier ] && node_format_cmd='npx prettier --check .'
  pkg_has 'script build' && node_build_cmd='npm run build'
fi

# nextjs-typescript.md is App Router and TypeScript specific; every other Node.js project, plain ones
# included, gets the stack-neutral doc keyed to its own package.json scripts.
node_doc=nodejs.md
[ "$frontend" = nextjs ] && node_doc=nextjs-typescript.md
case "$backend" in
  go) gate_stack=go; gates_doc=go.md ;;
  python) gate_stack=python; gates_doc=python-fastapi.md ;;
  nodejs|'')
    if [ -n "$backend$frontend" ]; then gate_stack=nodejs; gates_doc=$node_doc; fi ;;
  *) ;;   # a flag named a stack with no shipped doc: /whip-add-agents Step 6 writes it from a template
esac
# One gate_stack cannot serve a polyglot repo: the frontend gets the Node.js gates of its own.
if [ -n "$frontend" ]; then frontend_gate_stack=nodejs; frontend_gates_doc=$node_doc; fi

printf "backend='%s'\n" "$backend"
printf "frontend='%s'\n" "$frontend"
printf "node_framework='%s'\n" "$node_framework"
printf "node_test_runner='%s'\n" "$node_test_runner"
printf "node_typescript='%s'\n" "$node_typescript"
printf "node_linter='%s'\n" "$node_linter"
printf "node_formatter='%s'\n" "$node_formatter"
printf "node_test_cmd='%s'\n" "$node_test_cmd"
printf "node_lint_cmd='%s'\n" "$node_lint_cmd"
printf "node_typecheck_cmd='%s'\n" "$node_typecheck_cmd"
printf "node_format_cmd='%s'\n" "$node_format_cmd"
printf "node_build_cmd='%s'\n" "$node_build_cmd"
printf "gate_stack='%s'\n" "$gate_stack"
printf "gates_doc='%s'\n" "$gates_doc"
printf "frontend_gate_stack='%s'\n" "$frontend_gate_stack"
printf "frontend_gates_doc='%s'\n" "$frontend_gates_doc"
