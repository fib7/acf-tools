#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""advisor.py - One-shot Chat Completions client for an OpenAI-compatible endpoint.

Reads the user prompt from stdin, sends it to {BASE_URL}/chat/completions,
prints the assistant's reply to stdout, prints token usage and any reasoning
trace to stderr. Thinking / reasoning mode is ON by default.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


DEFAULT_SYSTEM_PROMPT = (
    "You are an advisor LLM consulted by another AI assistant for a second "
    "opinion. Be direct and concrete. Identify risks, alternatives, and "
    "tradeoffs the asker may have missed. If you disagree, say so plainly. "
    "If the question is underspecified, name what's missing rather than "
    "guessing. No filler, no flattery."
)


def env_or(*names: str, default: str | None = None) -> str | None:
    for n in names:
        v = os.environ.get(n)
        if v:
            return v
    return default


def _parse_dotenv(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not key or not key.replace("_", "").isalnum():
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        out[key] = value
    return out


def load_dotenv(start: Path | None = None, also_local: bool = True) -> Path | None:
    """Walk up from `start` (default CWD) looking for the first .env.

    Stop at the first directory that contains a .env, or that contains a .git
    entry, or at filesystem root. Already-set env vars are never overridden.
    Optionally also loads a sibling .env.local in that same directory.
    Returns the path to the loaded .env, or None if none was found.
    """
    here = (start or Path.cwd()).resolve()
    found: Path | None = None
    for d in [here, *here.parents]:
        candidate = d / ".env"
        if candidate.is_file():
            found = candidate
            break
        if (d / ".git").exists():
            break
    if found is None:
        return None
    parsed = _parse_dotenv(found.read_text(encoding="utf-8", errors="replace"))
    if also_local:
        local = found.parent / ".env.local"
        if local.is_file():
            parsed.update(
                _parse_dotenv(local.read_text(encoding="utf-8", errors="replace"))
            )
    added = 0
    for k, v in parsed.items():
        if k not in os.environ:
            os.environ[k] = v
            added += 1
    print(
        f"[advisor] loaded env from {found} ({added} new var{'s' if added != 1 else ''})",
        file=sys.stderr,
    )
    return found


def redact_headers(headers: dict[str, str]) -> dict[str, str]:
    out = dict(headers)
    if "Authorization" in out:
        out["Authorization"] = "Bearer ***REDACTED***"
    return out


def die(msg: str, code: int = 2) -> None:
    print(f"[advisor] {msg}", file=sys.stderr)
    sys.exit(code)


def build_payload(
    *,
    model: str,
    system: str,
    user: str,
    reasoning_effort: str | None,
    thinking_budget: int | None,
    include_temperature: bool = True,
) -> dict:
    payload: dict = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    if include_temperature:
        payload["temperature"] = 0.3
    if reasoning_effort:
        payload["reasoning_effort"] = reasoning_effort
    if thinking_budget is not None:
        payload["thinking"] = {
            "type": "enabled",
            "budget_tokens": thinking_budget,
        }
    return payload


def post_chat(base_url: str, api_key: str, payload: dict, timeout: float) -> dict:
    url = base_url.rstrip("/") + "/chat/completions"
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code}: {err_body}") from None
    except urllib.error.URLError as e:
        raise RuntimeError(f"network error: {e.reason}") from None


def looks_like_reasoning_field_error(msg: str) -> bool:
    needle = msg.lower()
    return any(
        s in needle
        for s in (
            "reasoning_effort",
            "thinking",
            "unknown parameter",
            "unrecognized parameter",
            "unsupported parameter",
            "extra fields not permitted",
        )
    )


def looks_like_temperature_error(msg: str) -> bool:
    needle = msg.lower()
    return "temperature" in needle and (
        "does not support" in needle
        or "unsupported value" in needle
        or "not supported" in needle
        or "only the default" in needle
    )


def extract_reply(resp: dict) -> tuple[str, str | None]:
    choices = resp.get("choices") or []
    if not choices:
        raise RuntimeError(f"no choices in response: {json.dumps(resp)[:500]}")
    msg = choices[0].get("message") or {}
    content = msg.get("content") or ""
    reasoning = msg.get("reasoning") or msg.get("reasoning_content")
    if isinstance(reasoning, list):
        # Anthropic-style list of blocks
        parts = []
        for b in reasoning:
            if isinstance(b, dict) and b.get("type") == "thinking":
                parts.append(b.get("thinking") or "")
            elif isinstance(b, str):
                parts.append(b)
        reasoning = "\n".join(p for p in parts if p) or None
    if not isinstance(content, str):
        content = json.dumps(content)
    return content, reasoning


def emit_usage(model: str, resp: dict) -> None:
    u = resp.get("usage") or {}
    parts = [f"model={model}"]
    for key, label in (
        ("prompt_tokens", "prompt"),
        ("completion_tokens", "completion"),
        ("total_tokens", "total"),
    ):
        if key in u:
            parts.append(f"{label}={u[key]}")
    details = u.get("completion_tokens_details") or {}
    if "reasoning_tokens" in details:
        parts.append(f"reasoning={details['reasoning_tokens']}")
    print("[advisor] " + " ".join(parts), file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Send stdin to an OpenAI-compatible chat completions endpoint."
    )
    ap.add_argument("--system", default=None, help="Override the default system prompt.")
    ap.add_argument("--model", default=None, help="Override ADVISOR_MODEL for this call.")
    ap.add_argument(
        "--timeout",
        type=float,
        default=float(os.environ.get("ADVISOR_TIMEOUT", "180")),
        help="HTTP timeout in seconds (default: 180, env: ADVISOR_TIMEOUT).",
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
    args = ap.parse_args()

    dotenv_path: Path | None = None
    if not args.no_dotenv:
        dotenv_path = load_dotenv()

    api_key = env_or("LITELLM_API_KEY", "OPENAI_API_KEY")
    if not api_key:
        die("missing API key: set LITELLM_API_KEY or OPENAI_API_KEY")
    base_url = env_or(
        "LITELLM_BASE_URL", "OPENAI_BASE_URL", default="https://api.openai.com/v1"
    )
    model = args.model or env_or("ADVISOR_MODEL", "OPENAI_MODEL")
    if not model:
        die("missing model: set ADVISOR_MODEL (or pass --model)")

    effort_raw = (env_or("ADVISOR_REASONING_EFFORT", default="high") or "").strip().lower()
    reasoning_effort: str | None
    thinking_budget: int | None
    if effort_raw in ("off", "none", "disabled", "false", "0", ""):
        reasoning_effort = None
        thinking_budget = None
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

    system_prompt = args.system or DEFAULT_SYSTEM_PROMPT

    payload = build_payload(
        model=model,
        system=system_prompt,
        user=user_prompt,
        reasoning_effort=reasoning_effort,
        thinking_budget=thinking_budget,
    )

    sending_parts = [
        f"model={model}",
        f"effort={reasoning_effort or 'off'}",
        f"thinking_budget={thinking_budget if thinking_budget is not None else 'off'}",
        f"dotenv={dotenv_path or 'none'}",
    ]
    print("[advisor] sending: " + " ".join(sending_parts), file=sys.stderr)

    if args.debug:
        debug_headers = redact_headers(
            {
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            }
        )
        print(
            f"[advisor] debug: POST {base_url.rstrip('/')}/chat/completions",
            file=sys.stderr,
        )
        print(f"[advisor] debug headers: {json.dumps(debug_headers)}", file=sys.stderr)
        print(
            f"[advisor] debug body: {json.dumps(payload, indent=2)}",
            file=sys.stderr,
        )

    include_temperature = True
    current_effort = reasoning_effort
    current_budget = thinking_budget

    resp = None
    for _ in range(3):
        try:
            resp = post_chat(base_url, api_key, payload, args.timeout)
            break
        except RuntimeError as e:
            msg = str(e)
            if (current_effort is not None or current_budget is not None) and \
                    looks_like_reasoning_field_error(msg):
                print(
                    "[advisor] upstream rejected reasoning fields; retrying without thinking mode",
                    file=sys.stderr,
                )
                current_effort = None
                current_budget = None
            elif include_temperature and looks_like_temperature_error(msg):
                print(
                    "[advisor] upstream rejected temperature override; retrying with default temperature",
                    file=sys.stderr,
                )
                include_temperature = False
            else:
                print(f"[advisor] {msg}", file=sys.stderr)
                return 1
            payload = build_payload(
                model=model,
                system=system_prompt,
                user=user_prompt,
                reasoning_effort=current_effort,
                thinking_budget=current_budget,
                include_temperature=include_temperature,
            )
    if resp is None:
        print("[advisor] gave up after retries", file=sys.stderr)
        return 1

    try:
        content, reasoning = extract_reply(resp)
    except RuntimeError as e:
        print(f"[advisor] {e}", file=sys.stderr)
        return 1

    if reasoning:
        print("[advisor] --- reasoning ---", file=sys.stderr)
        print(reasoning, file=sys.stderr)
        print("[advisor] --- end reasoning ---", file=sys.stderr)

    sys.stdout.write(content)
    if not content.endswith("\n"):
        sys.stdout.write("\n")

    emit_usage(model, resp)

    if current_effort is not None or current_budget is not None:
        details = (resp.get("usage") or {}).get("completion_tokens_details") or {}
        reasoning_tokens = details.get("reasoning_tokens")
        if reasoning_tokens == 0:
            print(
                "[advisor] note: reasoning fields sent but upstream returned 0 reasoning tokens "
                "(model/proxy may not support them - try ADVISOR_REASONING_EFFORT=off to skip the round-trip cost)",
                file=sys.stderr,
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
