---
name: commit
description: Stage and commit changes following conventional commit format. Atomic commits (one logical change each), never bypasses pre-commit hooks, terse reports.
allowed-tools:
  - Bash
  - Read
  - Grep
---

# commit: stage and commit following the project's conventions

The rules live in the project's git conventions file: `docs/acf/git/commit-conventions.md`, or the
equivalent file if the project keeps its conventions elsewhere. This skill runs git directly and
spawns no agents.

## Before you start

Check that:
- the directory is a git repository;
- pre-commit hooks are installed, if the project configures them;
- there are uncommitted changes;
- quality gates pass, or the hooks will enforce them at commit time.

### Arguments: $ARGUMENTS

## Conventions

You must follow every rule in the conventions file. The ones every commit touches:

- Format: `<type>(<scope>): <subject>`
- Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert
- Subject: imperative mood, not capitalized, no trailing period, 50 characters at most
- Body: wrapped at 72 characters, says what changed and why, not how
- Attribution: no AI-generated footers

## Steps

1. **Read the changes.** Run `git status`, group the modified files by logical area or scope, and
   pick the commit type for each group.
2. **Stage one group.** Add only the files for the current logical change, by name. Never run
   `git add -A` or `git add .`.
3. **Write the message.** Type per the conventions, an optional scope for the affected area, and a
   subject that completes the sentence "This commit will...". Add a body after a blank line when the
   change needs context.
4. **Commit.** Run the commit and report whether it succeeded.
5. **Verify.** Check the new commit against every rule in the conventions file, not only the format
   line.
6. **Repeat** steps 1-5 until `git status` shows no uncommitted changes.

## Rules

- **Atomic commits**: one logical change per commit.
- **The project must build after every commit.**
- **No AI attribution or co-authorship lines**, ever.
- **Never bypass pre-commit hooks**: no `--no-verify`, and no other way around them.
- **The conventions file decides** anything this page does not cover.

## Reporting

Report the result in as few words as it takes. No softening.

- "Done. Committed 3 files."
- "Done. Created X commits:\n[well formatted table of all commits with hashes, authors and descriptions]"
- "Failed. 5 test failures."
- "Quality gates not met."
