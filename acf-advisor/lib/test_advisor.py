"""Stdlib unittest for advisor payload-shape contracts.

Run: `uv run python -m unittest acf-advisor.lib.test_advisor`
or:  `cd acf-advisor && uv run python -m unittest lib.test_advisor`

No network. Locks in the regression guards for the v1.3.1→v1.3.2 fix:
- modern Claude routes to claude_adaptive (`thinking.type=adaptive`, `output_config.effort`)
- unknown / non-claude-prefixed aliases default to reasoning_effort-only (no legacy
  `thinking.type=enabled` shape leaks out)
- ADVISOR_PROFILE override wins over regex
- shape-swap retry detector recognises the literal Anthropic 400 message
"""

from __future__ import annotations

import os
import unittest

from lib.advisor import (
    build_payload,
    check_env,
    looks_like_anthropic_adaptive_required,
    resolve_param_profile,
)


def _payload(model: str, *, effort="high", budget=8000, force_profile=None):
    return build_payload(
        model=model,
        system="sys",
        user="hi",
        reasoning_effort=effort,
        thinking_budget=budget,
        force_profile=force_profile,
    )


class ProfileResolutionTests(unittest.TestCase):
    def setUp(self):
        # Each test starts with no override; restore on tear-down.
        self._saved = os.environ.pop("ADVISOR_PROFILE", None)

    def tearDown(self):
        os.environ.pop("ADVISOR_PROFILE", None)
        if self._saved is not None:
            os.environ["ADVISOR_PROFILE"] = self._saved

    def test_modern_claude_routes_to_adaptive(self):
        for model in (
            "claude-opus-4-7",
            "claude-sonnet-4-7",
            "claude-haiku-4-7",
            "anthropic/claude-opus-4-7",
            "claude-opus-5-0",        # future version — proves no version rot
            "claude-sonnet-9-0",
        ):
            with self.subTest(model=model):
                self.assertEqual(resolve_param_profile(model), "claude_adaptive")

    def test_gemini_routes_to_thinking_level(self):
        for model in (
            "gemini/gemini-3-pro",
            "gemini/gemini-4-flash",  # future — no version rot
            "gemini/gemini-9",
        ):
            with self.subTest(model=model):
                self.assertEqual(resolve_param_profile(model), "gemini_thinking_level")

    def test_openai_reasoning_family_routes_to_reasoning_only(self):
        for model in ("gpt-5", "openai/gpt-5", "o1", "o3", "o9"):
            with self.subTest(model=model):
                self.assertEqual(resolve_param_profile(model), "openai_reasoning_only")

    def test_unknown_alias_falls_through_to_default(self):
        # Aliases that don't start with a recognised provider/family prefix.
        for model in (
            "proxy/claude-opus-4-7",
            "bedrock/anthropic.claude-opus-4-7",
            "acf-opus-thinking",
            "vendor-x-llm",
        ):
            with self.subTest(model=model):
                self.assertEqual(resolve_param_profile(model), "default")

    def test_advisor_profile_override_wins(self):
        os.environ["ADVISOR_PROFILE"] = "claude_legacy_thinking"
        self.assertEqual(resolve_param_profile("claude-opus-4-7"), "claude_legacy_thinking")

    def test_advisor_profile_unknown_value_falls_back_to_regex(self):
        os.environ["ADVISOR_PROFILE"] = "garbage"
        self.assertEqual(resolve_param_profile("claude-opus-4-7"), "claude_adaptive")


class PayloadShapeTests(unittest.TestCase):
    def setUp(self):
        self._saved = os.environ.pop("ADVISOR_PROFILE", None)

    def tearDown(self):
        os.environ.pop("ADVISOR_PROFILE", None)
        if self._saved is not None:
            os.environ["ADVISOR_PROFILE"] = self._saved

    def test_modern_claude_payload_uses_adaptive_shape(self):
        p = _payload("claude-opus-4-7")
        self.assertEqual(p["thinking"], {"type": "adaptive"})
        self.assertEqual(p["output_config"], {"effort": "high"})
        self.assertNotIn("reasoning_effort", p)
        self.assertNotIn("temperature", p)

    def test_future_claude_inherits_adaptive_shape(self):
        # Regression guard for "no version pins in regex".
        p = _payload("claude-opus-5-0")
        self.assertEqual(p["thinking"], {"type": "adaptive"})
        self.assertEqual(p["output_config"], {"effort": "high"})

    def test_gemini_payload_uses_reasoning_effort_only(self):
        p = _payload("gemini/gemini-3-pro")
        self.assertEqual(p["reasoning_effort"], "high")
        self.assertNotIn("thinking", p)
        self.assertNotIn("output_config", p)

    def test_openai_o_series_uses_reasoning_effort_only(self):
        p = _payload("o3")
        self.assertEqual(p["reasoning_effort"], "high")
        self.assertNotIn("thinking", p)

    def test_unknown_alias_default_payload_has_no_thinking_block(self):
        # The exact regression that broke modern Claude in v1.3.1: an alias
        # that doesn't match the regex must NOT send thinking.type=enabled.
        p = _payload("proxy/claude-opus-4-7")
        self.assertEqual(p["reasoning_effort"], "high")
        self.assertNotIn("thinking", p)
        self.assertNotIn("output_config", p)

    def test_default_payload_has_no_legacy_thinking_block(self):
        p = _payload("acf-opus-thinking")
        self.assertEqual(p["reasoning_effort"], "high")
        self.assertNotIn("thinking", p)

    def test_legacy_profile_only_via_explicit_override(self):
        p = _payload("claude-opus-4-7", force_profile="claude_legacy_thinking")
        self.assertEqual(p["thinking"], {"type": "enabled", "budget_tokens": 8000})
        self.assertNotIn("output_config", p)
        self.assertNotIn("reasoning_effort", p)

    def test_force_profile_pins_claude_adaptive_for_unknown_alias(self):
        # The retry loop relies on this: on the adaptive-required 400, force_profile
        # makes the rebuilt payload use the adaptive shape regardless of model name.
        p = _payload("proxy/claude-opus-4-7", force_profile="claude_adaptive")
        self.assertEqual(p["thinking"], {"type": "adaptive"})
        self.assertEqual(p["output_config"], {"effort": "high"})

    def test_reasoning_off_sends_temperature_no_thinking(self):
        p = build_payload(
            model="claude-opus-4-7",
            system="sys",
            user="hi",
            reasoning_effort=None,
            thinking_budget=None,
        )
        self.assertEqual(p["temperature"], 0.3)
        self.assertNotIn("thinking", p)
        self.assertNotIn("output_config", p)
        self.assertNotIn("reasoning_effort", p)


class ErrorDetectorTests(unittest.TestCase):
    def test_anthropic_adaptive_required_matches_real_error(self):
        # Verbatim from the user's bug report — regression guard.
        msg = (
            'HTTP 400: AnthropicException - {"type":"error","error":'
            '{"type":"invalid_request_error","message":"\\"thinking.type.enabled\\" '
            'is not supported for this model. Use \\"thinking.type.adaptive\\" '
            'and \\"output_config.effort\\" to control thinking behavior."}}'
        )
        self.assertTrue(looks_like_anthropic_adaptive_required(msg))

    def test_anthropic_adaptive_required_does_not_match_unrelated(self):
        for msg in (
            "HTTP 429: rate limit exceeded",
            "HTTP 400: thinking.budget_tokens too small",
            "HTTP 400: cannot specify both thinking and thinking_level",
        ):
            with self.subTest(msg=msg):
                self.assertFalse(looks_like_anthropic_adaptive_required(msg))


class CheckEnvTests(unittest.TestCase):
    """Guard the structured one-liner that the board skill greps for routing."""

    _ENV_VARS = (
        "LITELLM_API_KEY",
        "OPENAI_API_KEY",
        "LITELLM_BASE_URL",
        "OPENAI_BASE_URL",
        "ADVISOR_MODEL",
        "OPENAI_MODEL",
    )

    def setUp(self):
        self._saved = {k: os.environ.pop(k, None) for k in self._ENV_VARS}

    def tearDown(self):
        for k in self._ENV_VARS:
            os.environ.pop(k, None)
            v = self._saved.get(k)
            if v is not None:
                os.environ[k] = v

    def test_pool_emitted_when_multiple_models(self):
        os.environ["LITELLM_API_KEY"] = "sk-test"
        os.environ["ADVISOR_MODEL"] = "claude-sonnet-4-6,gpt-5,gemini/gemini-3-pro"
        code, msg = check_env(load=False)
        self.assertEqual(code, 0)
        self.assertIn("model=claude-sonnet-4-6", msg)
        self.assertIn(
            "models=claude-sonnet-4-6,gpt-5,gemini/gemini-3-pro",
            msg,
            "pool order must be preserved verbatim",
        )
        self.assertTrue(msg.endswith(" ok"))

    def test_pool_omitted_when_single_model(self):
        # Single model: model= already carries the value; no second field needed,
        # but emitting models= for consistency is fine. Lock the current behavior:
        # we DO emit models= whenever pool is non-empty, even with one entry.
        os.environ["LITELLM_API_KEY"] = "sk-test"
        os.environ["ADVISOR_MODEL"] = "claude-sonnet-4-6"
        code, msg = check_env(load=False)
        self.assertEqual(code, 0)
        self.assertIn("model=claude-sonnet-4-6", msg)
        self.assertIn("models=claude-sonnet-4-6", msg)

    def test_missing_env_returns_2_and_no_models_field(self):
        code, msg = check_env(load=False)
        self.assertEqual(code, 2)
        self.assertIn("model=missing", msg)
        self.assertNotIn("models=", msg)
        self.assertIn("missing=api_key,model", msg)


if __name__ == "__main__":
    unittest.main()
