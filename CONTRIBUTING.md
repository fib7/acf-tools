# Contributing to acf-tools

acf-tools is where the seven ACF plugins are developed and released. Bug reports, fixes and new
ideas are welcome. This page covers what a pull request needs before it can be merged.

For anything bigger than a bug fix, open an issue first, so we can agree on the shape before you
write the code. Each plugin is self-contained: a change to one plugin must never require another
to be installed. When a plugin uses another's files or commands, it checks for them and falls back
when they are absent.

## Set up

```bash
git clone https://github.com/fib7/acf-tools.git
cd acf-tools
git config core.hooksPath .githooks
```

The last line turns on the commit hooks. They reject AI attribution trailers (see
[Commits](#commits)) before a commit is made and again before a push.

You need git, bash, jq, python3 3.8 or later and node. The acf-advisor tests run through
[uv](https://docs.astral.sh/uv/). To try your changes in Claude Code, run
`/plugin marketplace add ./acf-tools` from the clone's parent directory, then install the plugin you
changed with `/plugin install <plugin>@acf-tools`.

## Run the tests

| What you changed | Run |
|---|---|
| acf-whip | `bash acf-whip/tests/run-all.sh` |
| acf-librarian | `bash acf-librarian/tests/conventions.test.sh` and `bash acf-librarian/tests/template-refresh.test.sh` |
| acf-advisor | `cd acf-advisor && uv run python -m unittest lib.test_advisor` |
| `.githooks/` | `bash .githooks/pre-push.test.sh` |
| any `plugin.json` or `marketplace.json` | `claude plugin validate ./<plugin>` and `claude plugin validate .` |

The suites target stock macOS bash 3.2 and BSD tools, so keep scripts portable. In
`run-all.sh`, a required suite that skips counts as a failure. `template-refresh.test.sh` reads
this repository's history, so run it in a full clone, not a shallow one.

## Commits

Use [conventional commits](https://www.conventionalcommits.org/), scoped to the plugin you changed,
and keep each commit to one logical change:

```
fix(acf-whip): keep a held task out of the integrate queue
feat(acf-mission-control): show the cache TTL in the status line
docs(acf-librarian): correct the install path
chore: update marketplace.json
```

**Sign off every commit.** See [Developer Certificate of Origin](#developer-certificate-of-origin).

**No AI attribution.** These lines are not allowed in commit messages or pull request
descriptions:

```
Co-Authored-By: Claude <...>          # any Claude or *@anthropic.com address
Claude-Session: https://claude.ai/...
Generated with [Claude Code]          # and the emoji-prefixed variant
```

A `Co-authored-by:` line naming a human is fine. So are `ACFW-Stage:`, `ACFW-Task:` and
`ACFW-Patch:` trailers: acf-whip relies on them, so never strip them.

If you use Claude Code, turn its attribution off for this clone in `.claude/settings.local.json`:

```json
{
  "attribution": { "commit": "", "pr": "", "sessionUrl": false }
}
```

Other coding agents have an equivalent setting. If a trailer slips in anyway, amend or reword the
commit before you push it.

## Developer Certificate of Origin

By signing off a commit, you certify the [Developer Certificate of Origin 1.1](https://developercertificate.org/):
you wrote the change, or otherwise have the right to submit it under this project's license.

`git commit -s` adds the sign-off line. Its name and email must match the commit's author:

```
Signed-off-by: Your Name <you@example.com>
```

If you forgot it, `git commit --amend -s` fixes the last commit and `git rebase --signoff main`
fixes every commit on your branch. A pull request with an unsigned commit cannot be merged.

## Pull requests

- Branch from `main`. Keep a pull request to one plugin where you can.
- Say what changes for a user of the plugin, and how you tested it.
- Leave version numbers and CHANGELOGs alone. Maintainers bump versions and write the CHANGELOG
  entry at release time, so two open pull requests never fight over the same version.
- Maintainers merge locally rather than with GitHub's merge button, so the commit hooks check every
  commit on its way in. Your pull request shows as merged once that push lands.

## Security issues

Do not open a public issue for a vulnerability. Follow [SECURITY.md](.github/SECURITY.md).

## Code of conduct

Everyone taking part in this project follows the [Code of Conduct](.github/CODE_OF_CONDUCT.md).

## License

acf-tools is licensed under the [Apache License, Version 2.0](LICENSE). Your contributions are
licensed under it too, as section 5 of the license provides.
