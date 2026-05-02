#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""board.py - Multi-persona panel orchestrator over lib.advisor.run_advisor().

Reads a JSON manifest from stdin, validates it, runs N personas in parallel for R rounds,
issues a synthesis call, prints structured markdown to stdout and aggregate cost to stderr.

NO HTTP, NO env resolution, NO retry logic — all delegated to lib.advisor.run_advisor().
DRY by construction: same code path as the advisor CLI for every per-persona call.

Manifest schema (validated before any LLM call):
{
  "schema_version": 1,
  "user_prompt": "...",                    # required
  "priority_dimension": "...",             # optional; injected into synthesizer prompt
  "available_models": ["m1", "m2", ...],   # required, non-empty (parsed from ADVISOR_MODEL)
  "personas": [
    {
      "id": "regex_safe_id",               # required, unique, [A-Za-z0-9_.-]{1,64}
      "display_name": "human-readable",    # required
      "system": "system prompt",           # required, non-empty
      "model": "m1" | null                 # optional; if set, MUST be in available_models
    }, ...
  ],                                       # 1..5
  "rounds": 1,                             # int >=1, <= BOARD_MAX_ROUNDS
  "synthesizer_system": "...",             # optional; default = static synthesizer prompt
  "synthesizer_model": "m1" | null,        # optional; defaults to available_models[0]
  "limits": {                              # optional
    "call_timeout_seconds": 600,
    "max_stdout_chars": 200000,
    "max_prompt_chars": 120000,
    "max_transcript_chars": 600000
  }
}

Exit codes:
  0    Synthesis succeeded (possibly degraded — failures listed inline)
  10   Invalid manifest
  20   Zero persona successes in some round
  30   Synthesis call itself failed
  124  Total board timeout exceeded
  130  Interrupted (SIGINT/SIGTERM)
"""

from __future__ import annotations

import json
import os
import re
import signal
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# Make the plugin's lib/ importable.
_PLUGIN_ROOT = Path(__file__).resolve().parent.parent
if str(_PLUGIN_ROOT) not in sys.path:
    sys.path.insert(0, str(_PLUGIN_ROOT))

from lib.advisor import (  # noqa: E402
    AdvisorError,
    AdvisorResult,
    load_dotenv,
    run_advisor,
)


# ---------- Exit codes ----------

EXIT_OK = 0
EXIT_INVALID_MANIFEST = 10
EXIT_NO_PERSONA_SUCCESS = 20
EXIT_SYNTHESIS_FAILED = 30
EXIT_TIMEOUT = 124
EXIT_INTERRUPTED = 130


# ---------- Defaults / env ----------

DEFAULT_BOARD_PARALLELISM = 5
DEFAULT_BOARD_TOTAL_TIMEOUT_SECONDS = 1800
DEFAULT_BOARD_MAX_ROUNDS = 5
DEFAULT_CALL_TIMEOUT_SECONDS = 600

DEFAULT_SYNTHESIZER_SYSTEM = (
    "You are integrating N panel takes into one recommendation. Highlight points of "
    "agreement and disagreement explicitly. Weight by the user-specified priority "
    "dimension when present. Name what's still uncertain. Direct, no flattery, no filler."
)

PERSONA_ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")

LOG_PREFIX = "[board]"


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except ValueError:
        die(f"invalid {name}={raw!r}: expected integer", EXIT_INVALID_MANIFEST)
        return default  # unreachable, but type-checker wants it


def die(msg: str, code: int) -> None:
    print(f"{LOG_PREFIX} {msg}", file=sys.stderr)
    sys.exit(code)


# ---------- Manifest validation ----------

def validate_manifest(m: dict) -> tuple[dict, list[str]]:
    """Return (normalized_manifest, errors). On error, errors is non-empty."""
    errors: list[str] = []

    if not isinstance(m, dict):
        return m, ["manifest must be a JSON object"]

    if m.get("schema_version") != 1:
        errors.append(f"schema_version must be 1, got {m.get('schema_version')!r}")

    user_prompt = m.get("user_prompt")
    if not isinstance(user_prompt, str) or not user_prompt.strip():
        errors.append("user_prompt must be a non-empty string")

    available_models = m.get("available_models")
    if not isinstance(available_models, list) or not available_models:
        errors.append("available_models must be a non-empty list of strings")
        available_models = []
    else:
        for i, mdl in enumerate(available_models):
            if not isinstance(mdl, str) or not mdl.strip():
                errors.append(f"available_models[{i}] must be a non-empty string")

    personas = m.get("personas")
    if not isinstance(personas, list) or not (1 <= len(personas) <= 5):
        errors.append("personas must be a list of 1..5 entries")
        personas = []

    seen_ids: set[str] = set()
    for i, p in enumerate(personas):
        if not isinstance(p, dict):
            errors.append(f"persona {i} must be an object")
            continue
        pid = p.get("id")
        if not isinstance(pid, str) or not PERSONA_ID_RE.match(pid):
            errors.append(
                f"persona {i} id {pid!r} must match [A-Za-z0-9_.-]{{1,64}}"
            )
        elif pid in seen_ids:
            errors.append(f"persona {i} id {pid!r} is not unique")
        else:
            seen_ids.add(pid)
        if not isinstance(p.get("display_name"), str) or not p["display_name"].strip():
            errors.append(f"persona {i} display_name must be a non-empty string")
        if not isinstance(p.get("system"), str) or not p["system"].strip():
            errors.append(f"persona {i} system must be a non-empty string")
        pm = p.get("model")
        if pm is not None:
            if not isinstance(pm, str):
                errors.append(f"persona {i} model must be a string or null")
            elif pm not in available_models:
                errors.append(
                    f"persona {i} model {pm!r} not in available_models"
                )

    rounds = m.get("rounds", 1)
    max_rounds = _env_int("BOARD_MAX_ROUNDS", DEFAULT_BOARD_MAX_ROUNDS)
    if not isinstance(rounds, int) or rounds < 1 or rounds > max_rounds:
        errors.append(
            f"rounds must be an integer in [1, {max_rounds}], got {rounds!r} "
            f"(BOARD_MAX_ROUNDS env var caps it)"
        )

    synth_model = m.get("synthesizer_model")
    if synth_model is not None:
        if not isinstance(synth_model, str):
            errors.append("synthesizer_model must be a string or null")
        elif synth_model not in available_models:
            errors.append(
                f"synthesizer_model {synth_model!r} not in available_models"
            )

    limits = m.get("limits", {}) or {}
    if not isinstance(limits, dict):
        errors.append("limits must be an object")
        limits = {}

    normalized = {
        "schema_version": 1,
        "user_prompt": user_prompt or "",
        "priority_dimension": m.get("priority_dimension"),
        "available_models": available_models,
        "personas": personas,
        "rounds": rounds if isinstance(rounds, int) else 1,
        "synthesizer_system": (
            m.get("synthesizer_system") if isinstance(m.get("synthesizer_system"), str)
            and m["synthesizer_system"].strip() else DEFAULT_SYNTHESIZER_SYSTEM
        ),
        "synthesizer_model": synth_model,
        "limits": {
            "call_timeout_seconds": float(
                limits.get("call_timeout_seconds", DEFAULT_CALL_TIMEOUT_SECONDS)
            ),
            "max_stdout_chars": int(limits.get("max_stdout_chars", 200000)),
            "max_prompt_chars": int(limits.get("max_prompt_chars", 120000)),
            "max_transcript_chars": int(limits.get("max_transcript_chars", 600000)),
        },
    }
    return normalized, errors


# ---------- Model assignment (round-robin auto + explicit pin) ----------

def assign_models(
    personas: list[dict], available_models: list[str]
) -> list[tuple[dict, str]]:
    """Return [(persona, resolved_model), ...] preserving manifest order.

    Personas with `model: null` get round-robin assignment from available_models.
    Personas with an explicit model keep it (already validated to be in pool).
    Same model assigned to multiple personas is allowed (system prompts differentiate).
    """
    assigned: list[tuple[dict, str]] = []
    rr_index = 0
    for p in personas:
        if p.get("model"):
            assigned.append((p, p["model"]))
        else:
            assigned.append((p, available_models[rr_index % len(available_models)]))
            rr_index += 1
    return assigned


# ---------- Per-persona call ----------

def _truncate(text: str, max_chars: int) -> str:
    if len(text) <= max_chars:
        return text
    return text[:max_chars] + "\n\n[… truncated to fit]"


def _build_round_prompt(
    base_user_prompt: str,
    prior_rounds: list[dict],
    max_prompt_chars: int,
    persona_count: int,
) -> str:
    """Construct user prompt for round k > 1 by appending structured prior takes.

    Each persona only sees prior-round takes (never mid-round). Truncation marker
    inserted if a single take exceeds max_prompt_chars / persona_count.
    """
    if not prior_rounds:
        return base_user_prompt

    per_take_cap = max(1000, max_prompt_chars // max(persona_count, 1))
    parts = [base_user_prompt]
    for round_idx, takes in enumerate(prior_rounds, start=1):
        parts.append(f"\n\n## Prior round (k={round_idx}) takes\n")
        for take in takes:
            parts.append(
                f"\n### Persona: {take['display_name']} [{take['id']}] ({take['model']})\n"
            )
            if take.get("ok"):
                parts.append(_truncate(take["content"], per_take_cap))
            else:
                parts.append(f"[persona failed: {take.get('error', 'unknown error')}]")
            parts.append("\n")
    return "".join(parts)


def _call_persona(
    persona: dict,
    model: str,
    user_prompt: str,
    timeout: float,
    log_prefix: str,
) -> dict:
    """Run one persona call. Returns a take dict (always; failures captured inline)."""
    pid = persona["id"]
    started = time.monotonic()
    try:
        result: AdvisorResult = run_advisor(
            user_prompt,
            system=persona["system"],
            model=model,
            timeout=timeout,
            log_prefix=f"{log_prefix}:{pid}",
        )
        return {
            "id": pid,
            "display_name": persona["display_name"],
            "model": result.model,
            "ok": True,
            "content": result.content,
            "reasoning": result.reasoning,
            "prompt_tokens": result.prompt_tokens,
            "completion_tokens": result.completion_tokens,
            "total_tokens": result.total_tokens,
            "reasoning_tokens": result.reasoning_tokens,
            "elapsed_seconds": time.monotonic() - started,
            "error": None,
        }
    except AdvisorError as e:
        return {
            "id": pid,
            "display_name": persona["display_name"],
            "model": model,
            "ok": False,
            "content": "",
            "reasoning": None,
            "prompt_tokens": None,
            "completion_tokens": None,
            "total_tokens": None,
            "reasoning_tokens": None,
            "elapsed_seconds": time.monotonic() - started,
            "error": str(e),
        }


# ---------- SIGINT handling ----------

_interrupted = False


def _install_signal_handlers() -> None:
    def _handler(signum, _frame):
        global _interrupted
        _interrupted = True
        print(
            f"{LOG_PREFIX} received signal {signum}; finishing in-flight calls then exiting",
            file=sys.stderr,
        )

    signal.signal(signal.SIGINT, _handler)
    signal.signal(signal.SIGTERM, _handler)


# ---------- Round runner ----------

def _run_round(
    assigned: list[tuple[dict, str]],
    user_prompt: str,
    parallelism: int,
    call_timeout: float,
    deadline: float,
    log_prefix: str,
) -> list[dict]:
    """Run one round in parallel. Returns takes in MANIFEST ORDER, not completion order."""
    takes: dict[int, dict] = {}
    persona_count = len(assigned)
    with ThreadPoolExecutor(max_workers=min(parallelism, persona_count)) as pool:
        future_to_idx = {
            pool.submit(
                _call_persona, p, model, user_prompt, call_timeout, log_prefix
            ): i
            for i, (p, model) in enumerate(assigned)
        }
        for fut in as_completed(future_to_idx):
            i = future_to_idx[fut]
            if _interrupted or time.monotonic() > deadline:
                # Capture whatever's done; let in-flight ones complete naturally
                # (we rely on the per-call timeout passed to run_advisor() to
                # bound any in-flight request rather than killing it here).
                try:
                    takes[i] = fut.result(timeout=0.001)
                except Exception:
                    persona, model = assigned[i]
                    takes[i] = {
                        "id": persona["id"],
                        "display_name": persona["display_name"],
                        "model": model,
                        "ok": False,
                        "content": "",
                        "reasoning": None,
                        "prompt_tokens": None,
                        "completion_tokens": None,
                        "total_tokens": None,
                        "reasoning_tokens": None,
                        "elapsed_seconds": 0.0,
                        "error": "interrupted or timed out before completion",
                    }
                continue
            takes[i] = fut.result()
    return [takes[i] for i in range(persona_count)]


# ---------- Synthesis ----------

def _synthesize(
    user_prompt: str,
    rounds_takes: list[list[dict]],
    priority_dimension: str | None,
    synth_system: str,
    synth_model: str,
    timeout: float,
    log_prefix: str,
) -> tuple[AdvisorResult | None, str | None]:
    """Run the final synthesis call. Returns (result, error_msg)."""
    parts = [user_prompt, "\n\n# Panel transcript\n"]
    for round_idx, takes in enumerate(rounds_takes, start=1):
        parts.append(f"\n## Round {round_idx}\n")
        for t in takes:
            parts.append(f"\n### {t['display_name']} [{t['id']}] ({t['model']})\n")
            if t["ok"]:
                parts.append(t["content"])
            else:
                parts.append(f"[persona failed: {t['error']}]")
            parts.append("\n")
    if priority_dimension:
        parts.append(
            f"\n\n# Priority dimension\n\n"
            f"Weight your synthesis toward this dimension: **{priority_dimension}**\n"
        )
    synth_user = "".join(parts)
    try:
        return (
            run_advisor(
                synth_user,
                system=synth_system,
                model=synth_model,
                timeout=timeout,
                log_prefix=f"{log_prefix}:synth",
            ),
            None,
        )
    except AdvisorError as e:
        return None, str(e)


# ---------- Output rendering ----------

def _render_panel_markdown(
    rounds_takes: list[list[dict]],
    synth: AdvisorResult | None,
    synth_error: str | None,
) -> str:
    out = ["# Board of Advisors\n"]
    for round_idx, takes in enumerate(rounds_takes, start=1):
        if len(rounds_takes) > 1:
            out.append(f"\n## Round {round_idx}\n")
        for t in takes:
            out.append(f"\n### Advisor ({t['model']}) — {t['display_name']} says:\n\n")
            if t["ok"]:
                out.append(t["content"].rstrip() + "\n")
            else:
                out.append(f"*[persona failed: {t['error']}]*\n")
    out.append("\n## Synthesis\n\n")
    if synth is not None:
        out.append(synth.content.rstrip() + "\n")
    else:
        out.append(f"*[synthesis failed: {synth_error}]*\n")
    return "".join(out)


def _aggregate_cost(rounds_takes: list[list[dict]], synth: AdvisorResult | None) -> dict:
    """Sum token usage by model across all rounds + synthesis. Returns {model: {prompt, completion, total, reasoning}}."""
    by_model: dict[str, dict[str, int]] = {}
    def _add(model: str, fields: dict) -> None:
        slot = by_model.setdefault(
            model, {"prompt": 0, "completion": 0, "total": 0, "reasoning": 0}
        )
        for k in ("prompt", "completion", "total", "reasoning"):
            slot[k] += int(fields.get(k) or 0)

    for takes in rounds_takes:
        for t in takes:
            if t["ok"]:
                _add(
                    t["model"],
                    {
                        "prompt": t.get("prompt_tokens"),
                        "completion": t.get("completion_tokens"),
                        "total": t.get("total_tokens"),
                        "reasoning": t.get("reasoning_tokens"),
                    },
                )
    if synth is not None:
        _add(
            synth.model,
            {
                "prompt": synth.prompt_tokens,
                "completion": synth.completion_tokens,
                "total": synth.total_tokens,
                "reasoning": synth.reasoning_tokens,
            },
        )
    return by_model


# ---------- Main ----------

def main() -> int:
    _install_signal_handlers()

    # Load .env (silent if already loaded by parent process — env is preserved).
    load_dotenv(log_prefix=LOG_PREFIX)

    raw = sys.stdin.read()
    if not raw.strip():
        die("empty stdin: pipe a JSON manifest into board.py", EXIT_INVALID_MANIFEST)
    try:
        manifest_in = json.loads(raw)
    except json.JSONDecodeError as e:
        die(f"invalid manifest: not valid JSON ({e})", EXIT_INVALID_MANIFEST)

    manifest, errors = validate_manifest(manifest_in)
    if errors:
        for err in errors:
            print(f"{LOG_PREFIX} invalid manifest: {err}", file=sys.stderr)
        return EXIT_INVALID_MANIFEST

    parallelism = _env_int("BOARD_PARALLELISM", DEFAULT_BOARD_PARALLELISM)
    total_timeout = _env_int(
        "BOARD_TOTAL_TIMEOUT_SECONDS", DEFAULT_BOARD_TOTAL_TIMEOUT_SECONDS
    )
    deadline = time.monotonic() + total_timeout

    assigned = assign_models(manifest["personas"], manifest["available_models"])

    print(
        f"{LOG_PREFIX} convening: personas={len(assigned)} rounds={manifest['rounds']} "
        f"pool={','.join(manifest['available_models'])} "
        f"parallelism={parallelism} total_timeout={total_timeout}s",
        file=sys.stderr,
    )
    print(
        f"{LOG_PREFIX} limits: call_timeout_seconds={int(manifest['limits']['call_timeout_seconds'])} "
        f"total_timeout_seconds={total_timeout} max_rounds={_env_int('BOARD_MAX_ROUNDS', DEFAULT_BOARD_MAX_ROUNDS)}",
        file=sys.stderr,
    )

    rounds_takes: list[list[dict]] = []
    base_prompt = manifest["user_prompt"]
    call_timeout = manifest["limits"]["call_timeout_seconds"]
    max_prompt_chars = manifest["limits"]["max_prompt_chars"]

    for round_idx in range(manifest["rounds"]):
        if _interrupted:
            print(f"{LOG_PREFIX} interrupted before round {round_idx + 1}", file=sys.stderr)
            return EXIT_INTERRUPTED
        if time.monotonic() > deadline:
            print(
                f"{LOG_PREFIX} total timeout reached before round {round_idx + 1}; running synthesis over completed rounds",
                file=sys.stderr,
            )
            break
        round_user_prompt = (
            base_prompt
            if round_idx == 0
            else _build_round_prompt(base_prompt, rounds_takes, max_prompt_chars, len(assigned))
        )
        takes = _run_round(
            assigned, round_user_prompt, parallelism, call_timeout, deadline, LOG_PREFIX
        )
        rounds_takes.append(takes)

        ok_count = sum(1 for t in takes if t["ok"])
        print(
            f"{LOG_PREFIX} round {round_idx + 1}/{manifest['rounds']}: "
            f"{ok_count}/{len(takes)} personas succeeded",
            file=sys.stderr,
        )
        if ok_count == 0:
            print(f"{LOG_PREFIX} zero persona successes; aborting", file=sys.stderr)
            return EXIT_NO_PERSONA_SUCCESS

    if not rounds_takes:
        print(f"{LOG_PREFIX} no rounds completed", file=sys.stderr)
        return EXIT_TIMEOUT

    synth_model = (
        manifest["synthesizer_model"] or manifest["available_models"][0]
    )
    synth_result, synth_error = _synthesize(
        base_prompt,
        rounds_takes,
        manifest["priority_dimension"],
        manifest["synthesizer_system"],
        synth_model,
        call_timeout,
        LOG_PREFIX,
    )

    sys.stdout.write(
        _render_panel_markdown(rounds_takes, synth_result, synth_error)
    )

    cost_by_model = _aggregate_cost(rounds_takes, synth_result)
    cost_str = " ".join(
        f"{m}={c['total']}(p={c['prompt']}/c={c['completion']}/r={c['reasoning']})"
        for m, c in cost_by_model.items()
    )
    print(f"{LOG_PREFIX} aggregate: {cost_str}", file=sys.stderr)

    if _interrupted:
        return EXIT_INTERRUPTED
    if time.monotonic() > deadline:
        return EXIT_TIMEOUT
    if synth_result is None:
        return EXIT_SYNTHESIS_FAILED

    degraded = sum(1 for r in rounds_takes for t in r if not t["ok"])
    if degraded > 0:
        print(f"{LOG_PREFIX} status=degraded ({degraded} persona-call failure(s))", file=sys.stderr)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
