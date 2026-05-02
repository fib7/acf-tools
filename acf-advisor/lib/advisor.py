"""Core advisor logic shared by scripts/advisor.py (CLI) and scripts/board.py (orchestrator).

Single source of truth for HTTP, env resolution, dotenv loading, retries, redaction, and the
default system prompt. Stdlib-only.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path


DEFAULT_SYSTEM_PROMPT = (
    "You are an advisor LLM consulted by another AI assistant for a second "
    "opinion. Be direct and concrete. Identify risks, alternatives, and "
    "tradeoffs the asker may have missed. If you disagree, say so plainly. "
    "If the question is underspecified, name what's missing rather than "
    "guessing. No filler, no flattery."
)


@dataclass
class AdvisorResult:
    """Outcome of a single run_advisor() call."""

    content: str
    reasoning: str | None
    model: str
    prompt_tokens: int | None
    completion_tokens: int | None
    total_tokens: int | None
    reasoning_tokens: int | None


class AdvisorError(RuntimeError):
    """Raised when the advisor call fails after retries."""


def env_or(*names: str, default: str | None = None) -> str | None:
    for n in names:
        v = os.environ.get(n)
        if v:
            return v
    return default


def parse_model_list(env_value: str | None) -> list[str]:
    """Parse a comma-delimited model env var into a list.

    Strips whitespace, drops empty entries. Returns [] for None or empty string.
    A single value (no comma) returns a single-element list — preserves backward-compat
    semantics where ADVISOR_MODEL=foo means "use foo".
    """
    if not env_value:
        return []
    return [m.strip() for m in env_value.split(",") if m.strip()]


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


def load_dotenv(
    start: Path | None = None,
    also_local: bool = True,
    log_prefix: str = "[advisor]",
) -> Path | None:
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
        f"{log_prefix} loaded env from {found} ({added} new var{'s' if added != 1 else ''})",
        file=sys.stderr,
    )
    return found


def redact_headers(headers: dict[str, str]) -> dict[str, str]:
    out = dict(headers)
    if "Authorization" in out:
        out["Authorization"] = "Bearer ***REDACTED***"
    return out


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
        or "deprecated" in needle
    )


def extract_reply(resp: dict) -> tuple[str, str | None]:
    choices = resp.get("choices") or []
    if not choices:
        raise RuntimeError(f"no choices in response: {json.dumps(resp)[:500]}")
    msg = choices[0].get("message") or {}
    content = msg.get("content") or ""
    reasoning = msg.get("reasoning") or msg.get("reasoning_content")
    if isinstance(reasoning, list):
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


def _emit_usage(model: str, resp: dict, log_prefix: str) -> dict:
    """Print [<prefix>] model=… prompt=… completion=… total=… reasoning=… line.

    Returns a dict of the parsed usage values for callers that want to aggregate.
    """
    u = resp.get("usage") or {}
    parts = [f"model={model}"]
    fields = {}
    for key, label in (
        ("prompt_tokens", "prompt"),
        ("completion_tokens", "completion"),
        ("total_tokens", "total"),
    ):
        if key in u:
            parts.append(f"{label}={u[key]}")
            fields[label] = u[key]
    details = u.get("completion_tokens_details") or {}
    if "reasoning_tokens" in details:
        parts.append(f"reasoning={details['reasoning_tokens']}")
        fields["reasoning"] = details["reasoning_tokens"]
    print(f"{log_prefix} " + " ".join(parts), file=sys.stderr)
    return fields


def run_advisor(
    user_prompt: str,
    *,
    system: str | None = None,
    model: str | None = None,
    reasoning_effort: str | None = "high",
    thinking_budget: int | None = 8000,
    timeout: float = 180.0,
    base_url: str | None = None,
    api_key: str | None = None,
    log_prefix: str = "[advisor]",
    debug: bool = False,
    dotenv_path: Path | None = None,
) -> AdvisorResult:
    """Run a single chat-completions call with auto-retry.

    Resolves api_key/base_url/model from env (LITELLM_*/OPENAI_*/ADVISOR_MODEL) when not
    passed explicitly. When ADVISOR_MODEL is comma-delimited, uses the first entry as the
    default unless `model` overrides.

    Prints stderr observability lines using `log_prefix` (default "[advisor]"):
      <prefix> sending: model=… effort=… thinking_budget=… dotenv=…
      <prefix> upstream rejected reasoning fields; retrying without thinking mode  (if applicable)
      <prefix> upstream rejected temperature override; retrying with default temperature  (if applicable)
      <prefix> model=… prompt=… completion=… total=… reasoning=…
      <prefix> note: reasoning fields sent but upstream returned 0 reasoning tokens …  (if applicable)

    Raises AdvisorError on failure (missing key/model, exhausted retries, network error,
    HTTP error not handled by retry, malformed response).
    """
    resolved_api_key = api_key or env_or("LITELLM_API_KEY", "OPENAI_API_KEY")
    if not resolved_api_key:
        raise AdvisorError("missing API key: set LITELLM_API_KEY or OPENAI_API_KEY")

    resolved_base_url = base_url or env_or(
        "LITELLM_BASE_URL", "OPENAI_BASE_URL", default="https://api.openai.com/v1"
    )

    if model is None:
        pool = parse_model_list(env_or("ADVISOR_MODEL", "OPENAI_MODEL"))
        model = pool[0] if pool else None
    if not model:
        raise AdvisorError("missing model: set ADVISOR_MODEL (or pass model=)")

    system_prompt = system if system is not None else DEFAULT_SYSTEM_PROMPT

    sending_parts = [
        f"model={model}",
        f"effort={reasoning_effort or 'off'}",
        f"thinking_budget={thinking_budget if thinking_budget is not None else 'off'}",
        f"dotenv={dotenv_path or 'none'}",
    ]
    print(f"{log_prefix} sending: " + " ".join(sending_parts), file=sys.stderr)

    payload = build_payload(
        model=model,
        system=system_prompt,
        user=user_prompt,
        reasoning_effort=reasoning_effort,
        thinking_budget=thinking_budget,
    )

    if debug:
        debug_headers = redact_headers(
            {
                "Authorization": f"Bearer {resolved_api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            }
        )
        print(
            f"{log_prefix} debug: POST {resolved_base_url.rstrip('/')}/chat/completions",
            file=sys.stderr,
        )
        print(f"{log_prefix} debug headers: {json.dumps(debug_headers)}", file=sys.stderr)
        print(
            f"{log_prefix} debug body: {json.dumps(payload, indent=2)}",
            file=sys.stderr,
        )

    include_temperature = True
    current_effort = reasoning_effort
    current_budget = thinking_budget

    resp: dict | None = None
    last_msg: str | None = None
    for _ in range(3):
        try:
            resp = post_chat(resolved_base_url, resolved_api_key, payload, timeout)
            break
        except RuntimeError as e:
            msg = str(e)
            last_msg = msg
            if (current_effort is not None or current_budget is not None) and \
                    looks_like_reasoning_field_error(msg):
                print(
                    f"{log_prefix} upstream rejected reasoning fields; retrying without thinking mode",
                    file=sys.stderr,
                )
                current_effort = None
                current_budget = None
            elif include_temperature and looks_like_temperature_error(msg):
                print(
                    f"{log_prefix} upstream rejected temperature override; retrying with default temperature",
                    file=sys.stderr,
                )
                include_temperature = False
            else:
                raise AdvisorError(msg) from None
            payload = build_payload(
                model=model,
                system=system_prompt,
                user=user_prompt,
                reasoning_effort=current_effort,
                thinking_budget=current_budget,
                include_temperature=include_temperature,
            )
    if resp is None:
        raise AdvisorError(f"gave up after retries: {last_msg or 'unknown error'}")

    try:
        content, reasoning = extract_reply(resp)
    except RuntimeError as e:
        raise AdvisorError(str(e)) from None

    usage_fields = _emit_usage(model, resp, log_prefix)

    if current_effort is not None or current_budget is not None:
        details = (resp.get("usage") or {}).get("completion_tokens_details") or {}
        reasoning_tokens = details.get("reasoning_tokens")
        if reasoning_tokens == 0:
            print(
                f"{log_prefix} note: reasoning fields sent but upstream returned 0 reasoning tokens "
                "(model/proxy may not support them - try ADVISOR_REASONING_EFFORT=off to skip the round-trip cost)",
                file=sys.stderr,
            )

    return AdvisorResult(
        content=content,
        reasoning=reasoning,
        model=model,
        prompt_tokens=usage_fields.get("prompt"),
        completion_tokens=usage_fields.get("completion"),
        total_tokens=usage_fields.get("total"),
        reasoning_tokens=usage_fields.get("reasoning"),
    )
