#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""advisor.py - One-shot Chat Completions client for an OpenAI-compatible endpoint.

Reads the user prompt from stdin, sends it to {BASE_URL}/chat/completions,
prints the assistant's reply to stdout, prints token usage and any reasoning
trace to stderr. Thinking / reasoning mode is ON by default.

Thin CLI wrapper around lib.advisor.run_advisor() — single source of truth.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# Make the plugin's lib/ importable when run via `uv run --script` or directly.
_PLUGIN_ROOT = Path(__file__).resolve().parent.parent
if str(_PLUGIN_ROOT) not in sys.path:
    sys.path.insert(0, str(_PLUGIN_ROOT))

from lib.advisor import (  # noqa: E402
    AdvisorError,
    DEFAULT_SYSTEM_PROMPT,
    check_env,
    env_or,
    load_dotenv,
    parse_model_list,
    run_advisor,
)


def die(msg: str, code: int = 2) -> None:
    print(f"[advisor] {msg}", file=sys.stderr)
    sys.exit(code)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Send stdin to an OpenAI-compatible chat completions endpoint."
    )
    sys_group = ap.add_mutually_exclusive_group()
    sys_group.add_argument(
        "--system",
        default=None,
        help="Override the default system prompt (inline; visible in `ps` — prefer --system-file).",
    )
    sys_group.add_argument(
        "--system-file",
        default=None,
        help="Override the default system prompt by reading it from a file.",
    )
    ap.add_argument("--model", default=None, help="Override ADVISOR_MODEL for this call.")
    ap.add_argument(
        "--timeout",
        type=float,
        default=max(float(os.environ.get("ADVISOR_TIMEOUT", "600")), 300.0),
        help="HTTP timeout in seconds (default: 600, minimum: 300, env: ADVISOR_TIMEOUT).",
    )
    ap.add_argument(
        "--no-dotenv",
        action="store_true",
        default=os.environ.get("ADVISOR_NO_DOTENV") == "1",
        help="Disable .env auto-load from CWD upward (env: ADVISOR_NO_DOTENV=1).",
    )
    ap.add_argument(
        "--debug",
        action="store_true",
        help="Print the JSON request body (key redacted) to stderr.",
    )
    ap.add_argument(
        "--check-env",
        action="store_true",
        help="Resolve env (dotenv + shell) without any HTTP call. Exit 0 if api_key+model are set, 2 if missing. Prints structured one-liner to stderr.",
    )
    args = ap.parse_args()

    if args.check_env:
        code, msg = check_env(load=not args.no_dotenv)
        print(msg, file=sys.stderr)
        return code

    dotenv_path: Path | None = None
    if not args.no_dotenv:
        dotenv_path = load_dotenv()

    # Resolve model: explicit --model wins; else first entry of (possibly comma-delimited)
    # ADVISOR_MODEL / OPENAI_MODEL. Single-value env is unchanged from prior behavior.
    if args.model:
        model = args.model
    else:
        pool = parse_model_list(env_or("ADVISOR_MODEL", "OPENAI_MODEL"))
        model = pool[0] if pool else None
    if not model:
        die("missing model: set ADVISOR_MODEL (or pass --model)")

    # Reasoning effort + thinking budget from env.
    effort_raw = (env_or("ADVISOR_REASONING_EFFORT", default="high") or "").strip().lower()
    if effort_raw in ("off", "none", "disabled", "false", "0", ""):
        reasoning_effort = None
        thinking_budget: int | None = None
    else:
        if effort_raw not in ("low", "medium", "high"):
            die(
                f"invalid ADVISOR_REASONING_EFFORT={effort_raw!r}; "
                "expected one of: low, medium, high, off"
            )
        reasoning_effort = effort_raw
        try:
            thinking_budget = int(env_or("ADVISOR_THINKING_BUDGET", default="8000"))
        except ValueError:
            die("ADVISOR_THINKING_BUDGET must be an integer")

    user_prompt = sys.stdin.read()
    if not user_prompt.strip():
        die("empty stdin: pipe the question/context into advisor.py")

    # Resolve system prompt: --system inline > --system-file path > default.
    if args.system is not None:
        system_prompt: str | None = args.system
    elif args.system_file is not None:
        try:
            system_prompt = Path(args.system_file).read_text(encoding="utf-8")
        except OSError as e:
            die(f"cannot read --system-file {args.system_file!r}: {e}")
    else:
        system_prompt = None  # run_advisor() will use DEFAULT_SYSTEM_PROMPT

    try:
        result = run_advisor(
            user_prompt,
            system=system_prompt if system_prompt is not None else DEFAULT_SYSTEM_PROMPT,
            model=model,
            reasoning_effort=reasoning_effort,
            thinking_budget=thinking_budget,
            timeout=args.timeout,
            debug=args.debug,
            dotenv_path=dotenv_path,
        )
    except AdvisorError as e:
        print(f"[advisor] {e}", file=sys.stderr)
        return 1

    if result.reasoning:
        print("[advisor] --- reasoning ---", file=sys.stderr)
        print(result.reasoning, file=sys.stderr)
        print("[advisor] --- end reasoning ---", file=sys.stderr)

    sys.stdout.write(result.content)
    if not result.content.endswith("\n"):
        sys.stdout.write("\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
