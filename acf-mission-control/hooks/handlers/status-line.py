#!/usr/bin/env python3
# mission-control-version: 1.1.0
"""ACF Mission Control - Status Line HUD

Two-line "Mission Control" status line for Claude Code.

Line 1 (identity): model · directory · git branch + dirty
Line 2 (telemetry): fuel gauge · window · cost · duration · lines · cache · limits

Driven entirely by the JSON Claude Code sends on stdin (no transcript parsing).
See https://code.claude.com/docs/en/statusline for the field schema.

Requirements: Python 3.6+, standard library only (json, sys, os, subprocess, time).
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
    "cost": True,          # 💰 session cost
    "rate_limits": True,   # 5h / 7d usage (auto-hidden for non-Pro/Max)
    "git_dirty": True,     # ✎ modified / ⊕ staged counts
    "duration": True,      # ⏱ session wall-clock
    "lines": True,         # +added/-removed
    "cache": True,         # 🔥 prompt-cache warmth (needs refreshInterval)

    # Presentation
    "color": True,         # master color switch (also honors NO_COLOR env var)
    "single_line": False,  # collapse to one line
    "bar_width": 10,       # fuel gauge cells

    # Thresholds
    "cache_ttl": 300,      # seconds; Anthropic prompt-cache default TTL
    "ctx_warn": 70,        # context %: yellow at/above
    "ctx_crit": 90,        # context %: red at/above
    "cost_warn": 5.0,      # $: yellow at/above
    "cost_crit": 20.0,     # $: red at/above
}

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

    Returns (label, color) or None when it can't be determined.
    """
    if not transcript_path:
        return None
    try:
        idle = time.time() - os.path.getmtime(transcript_path)
    except OSError:
        return None
    if idle < 0.8 * ttl:
        return "🔥 warm", GREEN
    if idle < ttl:
        return "🔥 cooling", YELLOW
    return "❄ cold", RED


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        print("🚀 Mission Control")
        return

    sep = paint(" · ", DIM)

    # ---- Line 1: identity --------------------------------------------------
    model = g(data, "model.display_name", "Claude")
    window_size = g(data, "context_window.context_window_size", 200000)
    is_1m = window_size >= 1_000_000

    model_label = "🚀 " + paint(model, model_color(model))
    if is_1m:
        model_label += paint(" [1m]", CYAN + BOLD)

    line1 = [model_label]

    current_dir = g(data, "workspace.current_dir") or g(data, "cwd", "")
    if current_dir:
        line1.append("📁 " + paint(os.path.basename(current_dir), DIM))

    branch, modified, staged = git_info(g(data, "session_id", ""))
    # Prefer explicit worktree branch when Claude Code provides one.
    branch = g(data, "worktree.branch") or g(data, "workspace.git_worktree") or branch
    if branch:
        seg = "🌿 " + branch
        if CONFIG["git_dirty"]:
            if modified:
                seg += " " + paint("✎{}".format(modified), YELLOW)
            if staged:
                seg += " " + paint("⊕{}".format(staged), GREEN)
        line1.append(seg)

    # ---- Line 2: telemetry -------------------------------------------------
    line2 = []

    pct_raw = g(data, "context_window.used_percentage", 0) or 0
    pct = int(pct_raw)
    width = CONFIG["bar_width"]
    filled = max(0, min(width, pct * width // 100))
    bar = paint("█" * filled, zone_color(pct, CONFIG["ctx_warn"], CONFIG["ctx_crit"]))
    bar += "░" * (width - filled)
    pct_txt = paint("{}%".format(pct), zone_color(pct, CONFIG["ctx_warn"], CONFIG["ctx_crit"]))
    line2.append("⛽ [{}] {}".format(bar, pct_txt))
    line2.append(paint(fmt_window(window_size), (CYAN + BOLD) if is_1m else DIM))

    if CONFIG["cost"]:
        cost = g(data, "cost.total_cost_usd")
        if cost is not None:
            c_color = zone_color(cost, CONFIG["cost_warn"], CONFIG["cost_crit"])
            # Below warn threshold, keep it muted rather than green.
            if cost < CONFIG["cost_warn"]:
                c_color = DIM
            line2.append(paint("💰${:.2f}".format(cost), c_color))

    if CONFIG["duration"]:
        dur = g(data, "cost.total_duration_ms")
        if dur is not None:
            line2.append(paint("⏱{}".format(fmt_duration(dur)), DIM))

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
            label, color = warmth
            line2.append(paint(label, color))

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


if __name__ == "__main__":
    main()
