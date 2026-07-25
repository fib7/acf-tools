#!/usr/bin/env python3
# mission-control-version: 1.3.0
"""ACF Mission Control - Status Line HUD

Two-line "Mission Control" status line for Claude Code.

Line 1 (identity): model · directory · git branch + dirty
Line 2 (telemetry): fuel gauge · window · cost · duration · lines · cache · limits

Driven by the JSON Claude Code sends on stdin — see
https://code.claude.com/docs/en/statusline for the field schema — plus a
self-computed cost figure. Claude Code only prices models it ships rates for, so
anything behind a proxy (`nebius/zai-org/GLM-5.2`, `zai-org/GLM-5.2`, ...) reads
as ~$0.00. When the LiteLLM price map resolves the live model id, the HUD prices
the session itself from transcript token usage and marks the figure `≈`.

Extra modes (not the HUD):
  --refresh-prices          fetch + distill the LiteLLM price map into the cache
  --price-check <model-id>  show which price entry a model id maps onto

Requirements: Python 3.6+, standard library only (json, sys, os, subprocess,
time, urllib). Network is optional: with no cached price map the HUD falls back
to Claude Code's own cost figure.
"""

import json
import os
import subprocess
import sys
import time

# --------------------------------------------------------------------------- #
# Configuration — flip these per project (this file is a local copy you own).  #
# --------------------------------------------------------------------------- #
CONFIG = {
    # Optional segments (core: model, dir, branch, fuel bar are always shown)
    "cost": True,          # session cost
    "rate_limits": True,   # 5h / 7d usage (auto-hidden for non-Pro/Max)
    "git_dirty": True,     # modified / staged counts
    "duration": True,      # session wall-clock
    "lines": True,         # +added/-removed
    "cache": True,         # prompt-cache warmth (needs refreshInterval)

    # Presentation
    "glyphs": "sleek",     # icon theme: sleek | emoji | nerd | text
    "color": True,         # master color switch (also honors NO_COLOR env var)
    "single_line": False,  # collapse to one line
    "bar_width": 10,       # fuel gauge cells

    # Thresholds
    "cache_ttl": 300,      # seconds; Anthropic prompt-cache default TTL
    "ctx_warn": 70,        # context %: yellow at/above
    "ctx_crit": 90,        # context %: red at/above
    "cost_warn": 5.0,      # $: yellow at/above
    "cost_crit": 20.0,     # $: red at/above

    # Cost accuracy — price the session from the LiteLLM map instead of trusting
    # Claude Code's figure, which is ~$0.00 for any model it has no rates for.
    "price_map": True,     # False -> always show Claude Code's own cost
    "price_ttl": 86400,    # seconds before the cached price map is refreshed
    "price_aliases": {},   # {"nebius/zai-org/GLM-5.2": "zai/glm-5.2"} — pin a mapping
}

# Upstream rate table. Keys are `provider/model` or bare model names; the leading
# segments are routing, not identity, so `nebius/zai-org/GLM-5.2` prices as GLM-5.2.
PRICE_URL = (
    "https://raw.githubusercontent.com/BerriAI/litellm/main/"
    "model_prices_and_context_window.json"
)
FETCH_TIMEOUT = 8      # seconds; the refresher runs detached, never the HUD
LOCK_TTL = 600         # seconds a refresh may hold the fetch before others retry
DEDUP_WINDOW = 64      # requestIds remembered; duplicate records are consecutive

# --------------------------------------------------------------------------- #
# ANSI palette                                                                 #
# --------------------------------------------------------------------------- #
RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
BLUE = "\033[94m"
MAGENTA = "\033[95m"
CYAN = "\033[96m"

# Distinct color per model family — match family name only, never version digits.
MODEL_COLORS = {
    "opus": MAGENTA + BOLD,   # premium / expensive
    "sonnet": CYAN,
    "haiku": GREEN,
    "fable": BLUE,
}

COLOR_ENABLED = CONFIG["color"] and not os.environ.get("NO_COLOR")

# --------------------------------------------------------------------------- #
# Glyph themes — every segment's icon resolves through here so the look is one #
# switch (CONFIG["glyphs"]). Glyphs inherit their segment's ANSI color; an     #
# empty string means "no icon" (the spacing helper drops the would-be space).  #
#                                                                              #
#   sleek  monochrome geometric — default; standard Unicode, no special font   #
#   emoji  the original pictographs (regression-preserving)                    #
#   nerd   Nerd Font private-use glyphs — REQUIRES a Nerd Font installed       #
#   text   no pictographs at all; color + labels carry the meaning             #
# --------------------------------------------------------------------------- #
GLYPHS = {
    "sleek": {
        "model": "◆", "dir": "▸", "branch": "⎇",
        "modified": "✎", "staged": "⊕",
        "fuel": "", "bar_open": "", "bar_close": "",
        "bar_fill": "▰", "bar_empty": "▱",
        "cost": "", "dur": "",
        "warm": "●", "cooling": "◐", "cold": "○",
    },
    "emoji": {
        "model": "🚀", "dir": "📁", "branch": "🌿",
        "modified": "✎", "staged": "⊕",
        "fuel": "⛽", "bar_open": "[", "bar_close": "]",
        "bar_fill": "█", "bar_empty": "░",
        "cost": "💰", "dur": "⏱",
        "warm": "🔥", "cooling": "🔥", "cold": "❄",
    },
    "nerd": {
        # FontAwesome glyphs from any Nerd Font; render as boxes without one.
        "model": "", "dir": "", "branch": "",
        "modified": "✎", "staged": "⊕",
        "fuel": "", "bar_open": "", "bar_close": "",
        "bar_fill": "▰", "bar_empty": "▱",
        "cost": "", "dur": "",
        "warm": "", "cooling": "", "cold": "",
    },
    "text": {
        "model": "", "dir": "", "branch": "",
        "modified": "✎", "staged": "⊕",
        "fuel": "", "bar_open": "[", "bar_close": "]",
        "bar_fill": "█", "bar_empty": "░",
        "cost": "", "dur": "",
        "warm": "", "cooling": "", "cold": "",
    },
}

GLYPH = GLYPHS.get(CONFIG["glyphs"], GLYPHS["sleek"])

# Structural anchor colors — give each line-1 leading glyph a stable identity hue
# so segments are findable at a glance (model = its family color, dir = blue,
# branch = cyan). Scoped to the line-art themes: emoji glyphs keep their own
# built-in color (preserving the original look), text has no glyph to paint.
ANCHOR_COLORS = CONFIG["glyphs"] in ("sleek", "nerd")


def lead(glyph):
    """Prefix an icon with a trailing space — or emit nothing for empty icons."""
    return (glyph + " ") if glyph else ""


def anchor(glyph, color):
    """Leading icon in its structural color (line-art themes), with a space."""
    if not glyph:
        return ""
    return (paint(glyph, color) if ANCHOR_COLORS else glyph) + " "


def paint(text, color):
    """Wrap text in an ANSI color (no-op when color is disabled or empty)."""
    if not COLOR_ENABLED or not color:
        return text
    return "{}{}{}".format(color, text, RESET)


def zone_color(value, warn, crit):
    """Green/yellow/red by health zone."""
    if value >= crit:
        return RED
    if value >= warn:
        return YELLOW
    return GREEN


def g(data, path, default=None):
    """Safe dotted lookup: g(data, 'a.b.c'). Returns default on any miss/None."""
    cur = data
    for key in path.split("."):
        if not isinstance(cur, dict) or cur.get(key) is None:
            return default
        cur = cur[key]
    return cur


def model_color(name):
    low = name.lower()
    for family, color in MODEL_COLORS.items():
        if family in low:
            return color
    return CYAN


def fmt_window(size):
    """200000 -> '200k', 1000000 -> '1M'."""
    if size >= 1_000_000:
        millions = size / 1_000_000
        return ("{:g}M".format(millions))
    return "{}k".format(size // 1000)


def fmt_duration(ms):
    secs = ms // 1000
    mins, _ = divmod(secs, 60)
    hours, mins = divmod(mins, 60)
    if hours:
        return "{}h{:02d}m".format(hours, mins)
    return "{}m".format(mins)


def git_info(session_id):
    """Return (branch, modified, staged) using a 5s session-keyed cache.

    Mirrors the official 'cache expensive operations' pattern. Returns
    ('', 0, 0) when not in a git repo or on any failure.
    """
    cache_file = "/tmp/mc-statusline-{}".format(session_id or "nosess")
    try:
        fresh = (
            os.path.exists(cache_file)
            and (time.time() - os.path.getmtime(cache_file)) <= 5
        )
    except OSError:
        fresh = False

    if not fresh:
        branch, modified, staged = "", 0, 0
        try:
            subprocess.check_output(
                ["git", "rev-parse", "--git-dir"], stderr=subprocess.DEVNULL
            )
            branch = subprocess.check_output(
                ["git", "branch", "--show-current"],
                stderr=subprocess.DEVNULL,
            ).decode().strip()
            mod_out = subprocess.check_output(
                ["git", "diff", "--numstat"], stderr=subprocess.DEVNULL
            ).decode().strip()
            stg_out = subprocess.check_output(
                ["git", "diff", "--cached", "--numstat"], stderr=subprocess.DEVNULL
            ).decode().strip()
            modified = len(mod_out.split("\n")) if mod_out else 0
            staged = len(stg_out.split("\n")) if stg_out else 0
        except Exception:
            pass
        try:
            with open(cache_file, "w") as fh:
                fh.write("{}|{}|{}".format(branch, modified, staged))
        except OSError:
            return branch, modified, staged

    try:
        with open(cache_file) as fh:
            branch, modified, staged = fh.read().split("|")
        return branch, int(modified), int(staged)
    except (OSError, ValueError):
        return "", 0, 0


def cache_warmth(transcript_path, ttl):
    """Heuristic prompt-cache staleness from transcript mtime vs the TTL.

    Returns (state, color) where state is 'warm'/'cooling'/'cold', or None when
    it can't be determined. The caller maps the state to a themed glyph.
    """
    if not transcript_path:
        return None
    try:
        idle = time.time() - os.path.getmtime(transcript_path)
    except OSError:
        return None
    if idle < 0.8 * ttl:
        return "warm", GREEN
    if idle < ttl:
        return "cooling", YELLOW
    return "cold", RED


# --------------------------------------------------------------------------- #
# Price map — a distilled copy of LiteLLM's rate table on disk.                #
# The raw file is 1.6MB of mostly capability flags; we keep the five rates      #
# that bill tokens, which parses in single-digit milliseconds per render.       #
# --------------------------------------------------------------------------- #
RATE_FIELDS = (
    ("i", "input_cost_per_token"),
    ("o", "output_cost_per_token"),
    ("r", "cache_read_input_token_cost"),
    ("w", "cache_creation_input_token_cost"),
    ("w1h", "cache_creation_input_token_cost_above_1hr"),
)
TOKEN_KEYS = ("i", "o", "r", "w5", "w1h", "ws")


def price_cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(
        os.path.expanduser("~"), ".cache"
    )
    return os.path.join(base, "acf-mission-control")


def price_cache_path():
    return os.path.join(price_cache_dir(), "prices.json")


def distill_prices(raw):
    """Strip the rate table down to the fields that bill tokens."""
    out = {}
    for key, spec in raw.items():
        if key == "sample_spec" or not isinstance(spec, dict):
            continue
        entry = {}
        for short, full in RATE_FIELDS:
            val = spec.get(full)
            if isinstance(val, (int, float)):
                entry[short] = val
        if "i" not in entry and "o" not in entry:
            continue  # image/audio-only or unpriced entries can't price a session
        search = spec.get("search_context_cost_per_query")
        if isinstance(search, dict):
            val = search.get("search_context_size_medium")
            if isinstance(val, (int, float)):
                entry["s"] = val
        provider = spec.get("litellm_provider")
        if isinstance(provider, str):
            entry["p"] = provider
        out[key] = entry
    return out


def refresh_prices():
    """Fetch, distill and atomically install the price map. Never raises.

    The lock file is a last-attempt timestamp, never cleared: concurrent sessions
    cooperate, and an offline machine retries at most once per LOCK_TTL instead of
    spawning a doomed fetch on every render.
    """
    import urllib.request

    lock = os.path.join(price_cache_dir(), "prices.lock")
    try:
        os.makedirs(price_cache_dir(), exist_ok=True)
        if os.path.exists(lock) and (time.time() - os.path.getmtime(lock)) < LOCK_TTL:
            return False
        with open(lock, "w") as fh:
            fh.write(str(int(time.time())))
    except OSError:
        return False

    try:
        request = urllib.request.Request(
            PRICE_URL, headers={"User-Agent": "acf-mission-control"}
        )
        raw = urllib.request.urlopen(request, timeout=FETCH_TIMEOUT).read()
        models = distill_prices(json.loads(raw.decode("utf-8")))
        if not models:
            return False
        tmp = price_cache_path() + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(
                {"fetched": int(time.time()), "source": PRICE_URL, "models": models},
                fh,
                separators=(",", ":"),
            )
        os.replace(tmp, price_cache_path())
        return True
    except Exception:  # noqa: BLE001 - a stale map beats a broken status line
        return False


def load_prices():
    try:
        with open(price_cache_path()) as fh:
            blob = json.load(fh)
    except (OSError, ValueError):
        return None
    models = blob.get("models")
    return models if isinstance(models, dict) else None


def prices_age():
    """Seconds since the cached map was written, or None when there is none."""
    try:
        return time.time() - os.path.getmtime(price_cache_path())
    except OSError:
        return None


def spawn_refresh():
    """Kick off a detached refresh — the HUD must never wait on the network."""
    try:
        subprocess.Popen(
            [sys.executable or "python3", os.path.abspath(__file__), "--refresh-prices"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception:  # noqa: BLE001 - non-blocking by design
        pass


def price_index(models):
    """Lookup tables built once per render: exact (lowercased) and by basename."""
    lower, base = {}, {}
    for key in models:
        lower[key.lower()] = key
        base.setdefault(key.rsplit("/", 1)[-1].lower(), []).append(key)
    return {"models": models, "lower": lower, "base": base}


def resolve_model(model_id, idx):
    """Map a live model id onto a price-map key. Returns (key, how) or (None, None).

    Provider prefixes are routing, not identity: `nebius/zai-org/GLM-5.2` is
    GLM-5.2 served by nebius, so segments are dropped left to right until a rate
    entry matches, then the bare model name is looked up wherever it is published.
    """
    if not model_id or not idx:
        return None, None

    aliases = CONFIG.get("price_aliases") or {}
    alias = aliases.get(model_id) or aliases.get(model_id.lower())
    if alias and alias in idx["models"]:
        return alias, "alias"

    segments = model_id.split("/")
    for start in range(len(segments)):
        hit = idx["lower"].get("/".join(segments[start:]).lower())
        if hit:
            return hit, "exact" if start == 0 else "suffix"

    candidates = idx["base"].get(segments[-1].lower())
    if not candidates:
        return None, None

    prefixes = set(seg.lower() for seg in segments[:-1])

    def rank(key):
        spec = idx["models"][key]
        # Prefer the provider actually serving it, then the most complete rates,
        # then alphabetical so the same id always resolves the same way.
        return (0 if (spec.get("p") or "").lower() in prefixes else 1, -len(spec), key)

    return sorted(candidates, key=rank)[0], "basename"


def scan_usage(transcript_path, session_id):
    """Per-model token totals from the transcript, parsing only what's new.

    State lives in /tmp keyed by session — the same pattern git_info() uses — so
    a long session re-reads only the bytes appended since the last render.

    Claude Code writes one assistant record per content block and every record
    repeats the whole request's usage, so totals are deduplicated on requestId;
    summing raw records overstates cost by 3-4x.
    """
    if not transcript_path:
        return None
    try:
        st = os.stat(transcript_path)
    except OSError:
        return None

    state_file = "/tmp/mc-cost-{}".format(session_id or "nosess")
    try:
        with open(state_file) as fh:
            state = json.load(fh)
    except (OSError, ValueError):
        state = {}
    if not isinstance(state, dict):
        state = {}
    # A different/rotated/truncated transcript invalidates the incremental state.
    if (
        state.get("path") != transcript_path
        or state.get("ino") != st.st_ino
        or state.get("offset", 0) > st.st_size
    ):
        state = {}

    offset = state.get("offset", 0)
    totals = state.get("tok") or {}
    recent = state.get("req") or []

    if offset >= st.st_size:
        return totals

    try:
        with open(transcript_path, "rb") as fh:
            fh.seek(offset)
            blob = fh.read()
    except OSError:
        return totals or None

    # Stop at the last newline: the tail may be a half-written record, and byte
    # offsets must be counted on bytes, not characters.
    cut = blob.rfind(b"\n") + 1
    if cut == 0:
        return totals or None

    for line in blob[:cut].decode("utf-8", "replace").splitlines():
        if '"usage"' not in line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict) or record.get("type") != "assistant":
            continue
        message = record.get("message") or {}
        usage = message.get("usage") or {}
        if not usage:
            continue

        request_id = record.get("requestId") or message.get("id")
        if request_id:
            if request_id in recent:
                continue
            recent.append(request_id)
            if len(recent) > DEDUP_WINDOW:
                del recent[:-DEDUP_WINDOW]

        creation = usage.get("cache_creation") or {}
        if creation:
            write_5m = creation.get("ephemeral_5m_input_tokens") or 0
            write_1h = creation.get("ephemeral_1h_input_tokens") or 0
        else:
            write_5m = usage.get("cache_creation_input_tokens") or 0
            write_1h = 0
        server = usage.get("server_tool_use") or {}

        # Sidechains (subagents) bill to the same session, so they count here too.
        bucket = totals.setdefault(message.get("model") or "unknown", {})
        for key, value in (
            ("i", usage.get("input_tokens")),
            ("o", usage.get("output_tokens")),
            ("r", usage.get("cache_read_input_tokens")),
            ("w5", write_5m),
            ("w1h", write_1h),
            ("ws", server.get("web_search_requests")),
        ):
            if value:
                bucket[key] = bucket.get(key, 0) + value

    try:
        with open(state_file, "w") as fh:
            json.dump(
                {
                    "path": transcript_path,
                    "ino": st.st_ino,
                    "offset": offset + cut,
                    "req": recent,
                    "tok": totals,
                },
                fh,
            )
    except OSError:
        pass

    return totals


def price_tokens(tokens, spec):
    """Dollar cost of one model's token totals under one rate entry."""
    rate_in = spec.get("i", 0.0)
    # Entries that list no cache pricing bill cached tokens as plain input.
    rate_read = spec.get("r", rate_in)
    rate_write = spec.get("w", rate_in)
    return (
        tokens.get("i", 0) * rate_in
        + tokens.get("o", 0) * spec.get("o", 0.0)
        + tokens.get("r", 0) * rate_read
        + tokens.get("w5", 0) * rate_write
        + tokens.get("w1h", 0) * spec.get("w1h", rate_write)
        + tokens.get("ws", 0) * spec.get("s", 0.0)
    )


def session_cost(transcript_path, session_id):
    """Session cost from transcript usage x LiteLLM rates.

    Returns (cost, unpriced). cost is None when nothing could be priced — the
    caller then falls back to Claude Code's own figure. unpriced flags that some
    model burned tokens at rates we don't have, so the total reads low.
    """
    models = load_prices()
    if not models:
        return None, False
    totals = scan_usage(transcript_path, session_id)
    if not totals:
        return None, False

    idx = price_index(models)
    cost, priced, unpriced = 0.0, False, False
    for model_id, tokens in totals.items():
        key, _ = resolve_model(model_id, idx)
        if key is None:
            if any(tokens.get(name) for name in TOKEN_KEYS):
                unpriced = True
            continue
        cost += price_tokens(tokens, models[key])
        priced = True
    return (cost if priced else None), unpriced


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        print(lead(GLYPH["model"]) + "Mission Control")
        return

    sep = paint(" · ", DIM)

    # ---- Line 1: identity --------------------------------------------------
    model = g(data, "model.display_name", "Claude")
    window_size = g(data, "context_window.context_window_size", 200000)
    is_1m = window_size >= 1_000_000

    model_label = anchor(GLYPH["model"], model_color(model)) + paint(model, model_color(model))
    if is_1m:
        model_label += paint(" [1m]", CYAN + BOLD)

    line1 = [model_label]

    current_dir = g(data, "workspace.current_dir") or g(data, "cwd", "")
    if current_dir:
        line1.append(anchor(GLYPH["dir"], BLUE) + paint(os.path.basename(current_dir), DIM))

    branch, modified, staged = git_info(g(data, "session_id", ""))
    # Prefer explicit worktree branch when Claude Code provides one.
    branch = g(data, "worktree.branch") or g(data, "workspace.git_worktree") or branch
    if branch:
        seg = anchor(GLYPH["branch"], CYAN) + branch
        if CONFIG["git_dirty"]:
            if modified:
                seg += " " + paint("{}{}".format(GLYPH["modified"], modified), YELLOW)
            if staged:
                seg += " " + paint("{}{}".format(GLYPH["staged"], staged), GREEN)
        line1.append(seg)

    # ---- Line 2: telemetry -------------------------------------------------
    line2 = []

    pct_raw = g(data, "context_window.used_percentage", 0) or 0
    pct = int(pct_raw)
    width = CONFIG["bar_width"]
    filled = max(0, min(width, pct * width // 100))
    bar = paint(GLYPH["bar_fill"] * filled, zone_color(pct, CONFIG["ctx_warn"], CONFIG["ctx_crit"]))
    bar += GLYPH["bar_empty"] * (width - filled)
    pct_txt = paint("{}%".format(pct), zone_color(pct, CONFIG["ctx_warn"], CONFIG["ctx_crit"]))
    line2.append(
        lead(GLYPH["fuel"]) + GLYPH["bar_open"] + bar + GLYPH["bar_close"] + " " + pct_txt
    )
    line2.append(paint(fmt_window(window_size), (CYAN + BOLD) if is_1m else DIM))

    if CONFIG["cost"]:
        computed, unpriced = None, False
        if CONFIG["price_map"]:
            age = prices_age()
            if age is None or age > CONFIG["price_ttl"]:
                spawn_refresh()
            computed, unpriced = session_cost(
                g(data, "transcript_path"), g(data, "session_id", "")
            )
        # Claude Code's figure only covers models it ships rates for; ours covers
        # whatever the price map resolves. Prefer ours, fall back to theirs.
        cost = computed if computed is not None else g(data, "cost.total_cost_usd")
        if cost is not None:
            c_color = zone_color(cost, CONFIG["cost_warn"], CONFIG["cost_crit"])
            # Below warn threshold, keep it muted rather than green.
            if cost < CONFIG["cost_warn"]:
                c_color = DIM
            text = "{}{}${:.2f}{}".format(
                GLYPH["cost"],
                "≈" if computed is not None else "",
                cost,
                "?" if unpriced else "",  # some tokens burned at unknown rates
            )
            line2.append(paint(text, c_color))

    if CONFIG["duration"]:
        dur = g(data, "cost.total_duration_ms")
        if dur is not None:
            line2.append(paint(GLYPH["dur"] + fmt_duration(dur), DIM))

    if CONFIG["lines"]:
        added = g(data, "cost.total_lines_added")
        removed = g(data, "cost.total_lines_removed")
        if added is not None or removed is not None:
            line2.append(
                "{}/{}".format(
                    paint("+{}".format(added or 0), GREEN),
                    paint("-{}".format(removed or 0), RED),
                )
            )

    if CONFIG["cache"]:
        warmth = cache_warmth(g(data, "transcript_path"), CONFIG["cache_ttl"])
        if warmth:
            state, color = warmth
            line2.append(paint(lead(GLYPH[state]) + state, color))

    if CONFIG["rate_limits"]:
        rl = []
        five = g(data, "rate_limits.five_hour.used_percentage")
        seven = g(data, "rate_limits.seven_day.used_percentage")
        if five is not None:
            rl.append("5h " + paint("{:.0f}%".format(five), zone_color(five, 70, 90)))
        if seven is not None:
            rl.append("7d " + paint("{:.0f}%".format(seven), zone_color(seven, 70, 90)))
        if rl:
            line2.append(" ".join(rl))

    # ---- Emit --------------------------------------------------------------
    if CONFIG["single_line"]:
        print(sep.join(line1 + line2))
    else:
        print(sep.join(line1))
        print(sep.join(line2))


def fmt_age(seconds):
    if seconds is None:
        return "never fetched"
    if seconds < 3600:
        return "{:.0f}m old".format(seconds / 60)
    if seconds < 86400:
        return "{:.0f}h old".format(seconds / 3600)
    return "{:.0f}d old".format(seconds / 86400)


def price_check(model_id):
    """Show how a model id maps onto the price map. Debug mode, not the HUD."""
    if not model_id:
        print("usage: status-line.py --price-check <model-id>")
        return 2

    models = load_prices()
    if not models:
        print("no price map cached at {}".format(price_cache_path()))
        print("run: {} --refresh-prices".format(os.path.basename(__file__)))
        return 1

    print("price map     : {} entries, {}".format(len(models), fmt_age(prices_age())))
    print("cache         : {}".format(price_cache_path()))
    print("model id      : {}".format(model_id))

    key, how = resolve_model(model_id, price_index(models))
    if key is None:
        print("matched key   : none — no entry for '{}'".format(model_id.split("/")[-1]))
        print("               pin one via CONFIG['price_aliases']")
        return 1

    spec = models[key]
    print("matched key   : {}  (via {})".format(key, how))
    print("provider      : {}".format(spec.get("p", "?")))
    for label, short in (
        ("input", "i"),
        ("output", "o"),
        ("cache read", "r"),
        ("cache write", "w"),
        ("cache write 1h", "w1h"),
    ):
        val = spec.get(short)
        rate = "${:.2f} / Mtok".format(val * 1e6) if val is not None else "n/a"
        print("{:<14}: {}".format(label, rate))
    if spec.get("s") is not None:
        print("{:<14}: ${:.4f} / query".format("web search", spec["s"]))
    return 0


if __name__ == "__main__":
    argv = sys.argv[1:]
    if argv and argv[0] == "--refresh-prices":
        ok = refresh_prices()
        print("price map refreshed" if ok else "price map unchanged (locked or fetch failed)")
        sys.exit(0 if ok else 1)
    elif argv and argv[0] == "--price-check":
        sys.exit(price_check(argv[1] if len(argv) > 1 else ""))
    else:
        main()
