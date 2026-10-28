# Security policy

## Report a vulnerability

Do not open a public issue. Report it privately instead, in either of two ways:

- On GitHub: open the repository's **Security** tab and choose **Report a vulnerability**
  (https://github.com/fib7/acf-tools/security/advisories/new).
- By email to acf@fib7.ai.

Tell us which plugin and version is affected, what an attacker can do with it, and the steps to
reproduce it. We reply to every report and tell you when a fix ships.

## Supported versions

Only the latest version of each plugin receives fixes: the version listed in
`.claude-plugin/marketplace.json` on `main`. To update an installed plugin, run
`claude plugin marketplace update acf-tools`, then `claude plugin update <plugin>@acf-tools`.

## What is in scope

The plugins run hooks and scripts on your machine with your permissions:

- acf-whip runs git operations on your repository and, if you configure one, talks to an external
  task store (beads, multica or Linear) or a spec tool.
- acf-advisor sends prompts to the OpenAI-compatible endpoint you configure.
- acf-mission-control fetches LiteLLM's public model price table.

A vulnerability in Claude Code itself belongs with Anthropic, not here.
