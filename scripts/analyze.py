#!/usr/bin/env python3
"""
Boris-Token-Slim · transcript analyzer
Reads native Claude Code session transcripts (~/.claude/projects/**/*.jsonl)
and reports retrospective token usage, cache health, and top wasteful sessions.

Key insight: Token Optimizer measures FROM install time. This script
measures BACKWARDS — every session you've ever run is fair game.

Usage:
    python3 analyze.py                       # last 30 days, all projects
    python3 analyze.py --days 7              # last 7 days
    python3 analyze.py --since 2026-04-01    # since date
    python3 analyze.py --top 20              # top 20 wasteful sessions
    python3 analyze.py --json                # machine-readable output
    python3 analyze.py --project PATH        # filter by project dir name
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field, asdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterator

# ---------------------------------------------------------------------------
# Pricing table (USD per 1M tokens, public Anthropic pricing as of 2026)
# Update when Anthropic changes prices. Cache reads are 0.1x base, cache
# writes are 1.25x (5m) / 2x (1h) of base input.
# ---------------------------------------------------------------------------
PRICES = {
    # model_id_substring -> (input, output) per 1M tokens
    "opus":    (15.0, 75.0),
    "sonnet":  (3.0,  15.0),
    "haiku":   (0.80, 4.0),
}

CACHE_READ_MULT  = 0.1
CACHE_WRITE_5M   = 1.25
CACHE_WRITE_1H   = 2.0

PROJECTS_ROOT = Path.home() / ".claude" / "projects"

# Track unknown models so we warn once per ID, not per session
_UNKNOWN_MODELS_SEEN: set[str] = set()


def price_for(model: str) -> tuple[float, float]:
    if not model:
        return PRICES["sonnet"]
    m = model.lower()
    for key, val in PRICES.items():
        if key in m:
            return val
    if model not in _UNKNOWN_MODELS_SEEN:
        _UNKNOWN_MODELS_SEEN.add(model)
        print(
            f"warning: unknown model id {model!r}, falling back to Sonnet pricing "
            f"({PRICES['sonnet'][0]}/{PRICES['sonnet'][1]} per 1M)",
            file=sys.stderr,
        )
    return PRICES["sonnet"]


@dataclass
class SessionStats:
    session_id: str
    project: str
    file: Path
    first_ts: str = ""
    last_ts: str = ""
    model: str = ""
    user_turns: int = 0
    assistant_turns: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read: int = 0
    cache_write_5m: int = 0
    cache_write_1h: int = 0
    web_search_calls: int = 0
    web_fetch_calls: int = 0
    cost_usd: float = 0.0

    @property
    def cache_hit_rate(self) -> float:
        denom = self.input_tokens + self.cache_read + self.cache_write_5m + self.cache_write_1h
        return (self.cache_read / denom * 100) if denom else 0.0

    @property
    def total_input_equivalent(self) -> int:
        """Sum of all input-side tokens (raw + cached)."""
        return self.input_tokens + self.cache_read + self.cache_write_5m + self.cache_write_1h

    @property
    def avg_turn_size(self) -> float:
        return (self.total_input_equivalent / self.assistant_turns) if self.assistant_turns else 0.0


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------
def iter_session_files(since: datetime | None, project_filter: str | None) -> Iterator[Path]:
    if not PROJECTS_ROOT.exists():
        return
    for project_dir in PROJECTS_ROOT.iterdir():
        if not project_dir.is_dir():
            continue
        if project_filter and project_filter not in project_dir.name:
            continue
        for jsonl in project_dir.glob("*.jsonl"):
            try:
                mtime = datetime.fromtimestamp(jsonl.stat().st_mtime, tz=timezone.utc)
            except OSError:
                continue
            if since and mtime < since:
                continue
            yield jsonl


def analyze_file(path: Path) -> SessionStats | None:
    """Aggregate a single session file. Returns None for non-CC transcripts."""
    stats = SessionStats(
        session_id=path.stem,
        project=path.parent.name,
        file=path,
    )
    saw_assistant_with_usage = False

    try:
        with path.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue

                ts = d.get("timestamp", "")
                if ts:
                    if not stats.first_ts:
                        stats.first_ts = ts
                    stats.last_ts = ts

                msg = d.get("message")
                if not isinstance(msg, dict):
                    continue
                role = msg.get("role")

                if role == "user":
                    stats.user_turns += 1
                elif role == "assistant":
                    stats.assistant_turns += 1
                    if not stats.model:
                        stats.model = msg.get("model") or ""
                    u = msg.get("usage") or {}
                    if not isinstance(u, dict):
                        continue
                    inp = u.get("input_tokens") or 0
                    out = u.get("output_tokens") or 0
                    cr  = u.get("cache_read_input_tokens") or 0
                    cc  = u.get("cache_creation") or {}
                    if not isinstance(cc, dict):
                        cc = {}
                    c5  = cc.get("ephemeral_5m_input_tokens") or 0
                    c1  = cc.get("ephemeral_1h_input_tokens") or 0

                    if inp or out or cr or c5 or c1:
                        saw_assistant_with_usage = True

                    stats.input_tokens   += inp
                    stats.output_tokens  += out
                    stats.cache_read     += cr
                    stats.cache_write_5m += c5
                    stats.cache_write_1h += c1

                    sti = u.get("server_tool_use") or {}
                    if isinstance(sti, dict):
                        stats.web_search_calls += sti.get("web_search_requests") or 0
                        stats.web_fetch_calls  += sti.get("web_fetch_requests") or 0
    except (OSError, IOError):
        return None

    if not saw_assistant_with_usage:
        # Likely a non-CC JSONL (e.g. claude-mem observer logs)
        return None

    in_p, out_p = price_for(stats.model)
    stats.cost_usd = (
        stats.input_tokens   * in_p / 1_000_000 +
        stats.cache_read     * in_p * CACHE_READ_MULT  / 1_000_000 +
        stats.cache_write_5m * in_p * CACHE_WRITE_5M   / 1_000_000 +
        stats.cache_write_1h * in_p * CACHE_WRITE_1H   / 1_000_000 +
        stats.output_tokens  * out_p / 1_000_000
    )
    return stats


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
def humanize(n: int) -> str:
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n/1_000:.1f}K"
    return str(n)


def fmt_usd(x: float) -> str:
    if x >= 100:
        return f"${x:.0f}"
    if x >= 1:
        return f"${x:.2f}"
    return f"${x:.3f}"


def render_text(sessions: list[SessionStats], top_n: int) -> str:
    if not sessions:
        return "No Claude Code transcripts found in ~/.claude/projects/.\n"

    out = []
    push = out.append

    # ---- Aggregate ----
    total_inp     = sum(s.input_tokens for s in sessions)
    total_out     = sum(s.output_tokens for s in sessions)
    total_cr      = sum(s.cache_read for s in sessions)
    total_c5      = sum(s.cache_write_5m for s in sessions)
    total_c1      = sum(s.cache_write_1h for s in sessions)
    total_cost    = sum(s.cost_usd for s in sessions)
    total_a_turns = sum(s.assistant_turns for s in sessions)

    denom = total_inp + total_cr + total_c5 + total_c1
    cache_hit = (total_cr / denom * 100) if denom else 0
    cache_write_total = total_c5 + total_c1
    pct_1h = (total_c1 / cache_write_total * 100) if cache_write_total else 0

    push("╔══════════════════════════════════════════════════════════════════════╗")
    push("║   Boris-Token-Slim · Transcript Analyzer (retrospective)             ║")
    push("╚══════════════════════════════════════════════════════════════════════╝")
    push("")
    push(f"Sessions analyzed:       {len(sessions)}")
    push(f"Total assistant turns:   {total_a_turns:,}")
    push(f"Estimated total cost:    {fmt_usd(total_cost)}")
    push("")
    push("─── Token totals ───────────────────────────────────────────────────────")
    push(f"  Raw input               {humanize(total_inp):>10}    {fmt_usd(total_inp * 3 / 1_000_000):>8}  (full price)")
    push(f"  Cache read              {humanize(total_cr):>10}    {fmt_usd(total_cr * 3 * 0.1 / 1_000_000):>8}  (0.1x — cheap)")
    push(f"  Cache write 5m TTL      {humanize(total_c5):>10}    {fmt_usd(total_c5 * 3 * 1.25 / 1_000_000):>8}  (1.25x)")
    push(f"  Cache write 1h TTL      {humanize(total_c1):>10}    {fmt_usd(total_c1 * 3 * 2 / 1_000_000):>8}  (2x)")
    push(f"  Output                  {humanize(total_out):>10}    {fmt_usd(total_out * 15 / 1_000_000):>8}")
    push("")
    push("─── Cache health ──────────────────────────────────────────────────────")
    flag_hit = "✅" if cache_hit >= 80 else ("⚠️ " if cache_hit >= 50 else "🚨")
    push(f"  Cache hit rate          {cache_hit:5.1f}%   {flag_hit}  (target: ≥ 80%)")
    flag_1h = "✅" if (cache_write_total == 0 or pct_1h >= 50) else "⚠️ "
    push(f"  Cache writes on 1h TTL  {pct_1h:5.1f}%   {flag_1h}  (1h is 2x but amortizes; if low, you're paying 1.25x repeatedly)")

    # Wasteful = high cost AND low cache hit (Pattern 4 + 1)
    push("")
    push(f"─── Top {top_n} costly sessions ──────────────────────────────────────────")
    push(f"{'session':36s}  {'cost':>7s}  {'turns':>5s}  {'avg/turn':>10s}  {'hit':>6s}")
    sorted_sessions = sorted(sessions, key=lambda s: -s.cost_usd)[:top_n]
    for s in sorted_sessions:
        sid = s.session_id[:12] + "…" if len(s.session_id) > 12 else s.session_id
        proj = s.project[-22:] if len(s.project) > 22 else s.project
        push(f"  {sid:14s} {proj:>22s}  {fmt_usd(s.cost_usd):>7s}  {s.assistant_turns:>5d}  {humanize(int(s.avg_turn_size)):>10s}  {s.cache_hit_rate:5.1f}%")

    # Pattern 2 detection: long sessions
    long_sessions = [s for s in sessions if s.assistant_turns >= 30]
    if long_sessions:
        push("")
        push(f"─── Long sessions (≥30 turns) — Pattern 2 risk ─────────────────────────")
        push(f"  {len(long_sessions)} sessions exceed 30 assistant turns")
        push(f"  At turn 30, each new turn re-reads ~30× the first turn's history.")
        push(f"  Action: consider /compact at turn 20.")

    # Pattern 4 detection: low cache hit
    low_cache = [s for s in sessions if s.cache_hit_rate < 50 and s.assistant_turns >= 5]
    if low_cache:
        push("")
        push(f"─── Low cache hit (< 50%, ≥5 turns) — Pattern 4 risk ───────────────────")
        push(f"  {len(low_cache)} sessions paid full price for content that should have cached.")
        for s in low_cache[:5]:
            push(f"    {s.session_id[:12]}…  {s.cache_hit_rate:.1f}% hit  ({fmt_usd(s.cost_usd)})")

    push("")
    push("─── Counterfactual: hypothetical savings ───────────────────────────────")
    if denom > 0 and cache_hit < 85:
        # If your global cache hit jumped to 85%, how much would input-side
        # cost change? Treat the additional reads as 0.1x (cache_read price)
        # vs the original mix.
        target_hit = 0.85
        actual_read = total_cr
        ideal_read  = denom * target_hit
        delta_read  = max(0, ideal_read - actual_read)
        # That delta has to come from somewhere — assume it was raw input @ 1.0x
        # Savings = delta * (1.0 - 0.1) * base_price
        save = delta_read * 3 * 0.9 / 1_000_000
        push(f"  If your cache hit reached 85% globally: ~{fmt_usd(save)} saved")
    elif cache_hit >= 85:
        push(f"  Cache hit already ≥ 85%. No quick win on this axis.")
    if cache_write_total > 0 and pct_1h < 50:
        # 5m TTL writes that get re-created within the same session waste 1.25x
        # 1h would amortize. Assume half the 5m writes could've been 1h.
        save_1h = total_c5 * 0.5 * 3 * (1.25 - 0.0) / 1_000_000  # rough upper bound
        push(f"  If you upgrade to 1h cache TTL: ~{fmt_usd(save_1h)} saved (rough)")
    push("")
    push("Pricing notes: Sonnet base $3/$15 per 1M (in/out). Cache read 0.1x, write 1.25x (5m) or 2x (1h).")
    push("This is a RETROSPECTIVE estimate. Actual billing may differ slightly with batching/discounts.")

    return "\n".join(out) + "\n"


def render_json(sessions: list[SessionStats]) -> str:
    payload = {
        "schema": "boris-token-slim/transcript-analyzer/v1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "session_count": len(sessions),
        "totals": {
            "input_tokens":      sum(s.input_tokens for s in sessions),
            "output_tokens":     sum(s.output_tokens for s in sessions),
            "cache_read":        sum(s.cache_read for s in sessions),
            "cache_write_5m":    sum(s.cache_write_5m for s in sessions),
            "cache_write_1h":    sum(s.cache_write_1h for s in sessions),
            "cost_usd_estimate": round(sum(s.cost_usd for s in sessions), 4),
            "assistant_turns":   sum(s.assistant_turns for s in sessions),
        },
        "sessions": [
            {
                "session_id":      s.session_id,
                "project":         s.project,
                "first_ts":        s.first_ts,
                "last_ts":         s.last_ts,
                "model":           s.model,
                "user_turns":      s.user_turns,
                "assistant_turns": s.assistant_turns,
                "input_tokens":    s.input_tokens,
                "output_tokens":   s.output_tokens,
                "cache_read":      s.cache_read,
                "cache_write_5m":  s.cache_write_5m,
                "cache_write_1h":  s.cache_write_1h,
                "cache_hit_rate":  round(s.cache_hit_rate, 2),
                "cost_usd":        round(s.cost_usd, 4),
            }
            for s in sorted(sessions, key=lambda x: -x.cost_usd)
        ],
    }
    return json.dumps(payload, indent=2)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> int:
    p = argparse.ArgumentParser(description="Retrospective Claude Code transcript analyzer.")
    p.add_argument("--days", type=int, default=30, help="Look back N days (default: 30). Ignored if --since is set.")
    p.add_argument("--since", help="ISO date (e.g. 2026-04-01). Overrides --days.")
    p.add_argument("--top", type=int, default=10, help="Show top N costly sessions (default: 10).")
    p.add_argument("--project", help="Substring filter on project directory name.")
    p.add_argument("--json", action="store_true", help="Emit machine-readable JSON instead of dashboard.")
    args = p.parse_args()

    if args.since:
        try:
            since = datetime.fromisoformat(args.since).replace(tzinfo=timezone.utc)
        except ValueError:
            print(f"error: --since must be ISO date (YYYY-MM-DD), got {args.since!r}", file=sys.stderr)
            return 2
    else:
        since = datetime.now(tz=timezone.utc) - timedelta(days=args.days)

    sessions: list[SessionStats] = []
    for f in iter_session_files(since=since, project_filter=args.project):
        s = analyze_file(f)
        if s:
            sessions.append(s)

    if args.json:
        print(render_json(sessions))
    else:
        print(render_text(sessions, top_n=args.top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
