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

PROJECTS_ROOT = Path(os.environ.get("CLAUDE_HOME", str(Path.home() / ".claude"))) / "projects"

# Headline format strings (single source of truth — referenced by render_headline,
# tests, and any callers checking format invariants). Format params:
#   days, cost (formatted str), hit (str %), mcps (int), dups (humanized str)
HEADLINE_FORMAT = "{days} days: ${cost} spent | {hit}% cache hit | {mcps} zero-call MCP servers | {dups} tokens re-read"
HEADLINE_EMPTY = "0 sessions found · run claude code first"

# Junk-read detection (codeburn-inspired): paths under these dirs are
# generated/dependency content that Claude usually shouldn't be reading.
import re
JUNK_DIRS = (
    'node_modules', '.git', 'dist', 'build', '__pycache__', '.next',
    '.nuxt', '.output', 'coverage', '.cache', '.tsbuildinfo',
    '.venv', 'venv', '.svn', '.hg',
)
JUNK_PATTERN = re.compile(r'/(?:' + '|'.join(re.escape(d) for d in JUNK_DIRS) + r')/')

READ_TOOLS = frozenset(['Read', 'Grep', 'Glob', 'FileReadTool', 'GrepTool', 'GlobTool'])

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
    mcp_calls: dict[str, int] = field(default_factory=dict)  # {server_name: call_count}
    # Read tool call telemetry (codeburn-inspired)
    junk_reads: list[str] = field(default_factory=list)        # paths under node_modules/.git/etc
    file_read_counts: dict[str, int] = field(default_factory=dict)  # {abs_path: count} for dup detection
    cost_usd: float = 0.0
    # Real-token-cost of duplicate reads: when an assistant turn re-reads a
    # file already seen this session, the next assistant turn's input grows by
    # the result content. We attribute that growth proportionally across the
    # prior turn's reads (per-read share = delta / num_reads_in_prior_turn).
    # This replaces the dashboard's `count × 600` heuristic for the headline
    # output. Junk paths are excluded.
    duplicate_read_tokens: int = 0

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
    """Yield candidate session JSONL files.

    The since-filter here is a CHEAP PRESCREEN by file mtime — it skips
    files whose mtime is older than `since`, which is correct because
    a file's mtime is always >= its newest message's timestamp. (A
    long-running session that resumes will have its mtime updated.)

    The PRECISE filter happens in main() after analyze_file() reads
    `stats.last_ts` from the JSONL contents — that's the authoritative
    cutoff. mtime is a 1000x cheaper first pass.
    """
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


def parse_iso_timestamp(ts: str) -> datetime | None:
    """Parse an ISO-8601 timestamp from a transcript message into UTC datetime.
    Claude Code uses 'YYYY-MM-DDTHH:MM:SS.fffZ'. Returns None on failure.
    """
    if not ts:
        return None
    try:
        # Replace trailing Z with +00:00 for fromisoformat compatibility on 3.10
        normalized = ts.replace("Z", "+00:00") if ts.endswith("Z") else ts
        dt = datetime.fromisoformat(normalized)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, TypeError):
        return None


def analyze_file(path: Path, since: datetime | None = None) -> SessionStats | None:
    """Aggregate a single session file. Returns None for non-CC transcripts.

    If `since` is provided, messages with timestamps older than that
    cutoff are skipped during aggregation. This is essential for
    long-running sessions that resume across many days — without it,
    a `--days 7` report would still count tokens, MCP calls, and
    duplicate reads from message #1 dating to weeks ago.
    """
    stats = SessionStats(
        session_id=path.stem,
        project=path.parent.name,
        file=path,
    )
    saw_assistant_with_usage = False
    # State for zero-estimation duplicate-read tracking. Reads in assistant
    # turn N produce tool_results that enter turn N+1's input context. We
    # measure the actual input growth between turns and attribute it
    # proportionally across the prior turn's reads. Junk-path reads are
    # skipped (covered by junk_reads telemetry).
    pending_reads: list[tuple[str, bool]] = []  # (file_path, is_duplicate) of prev assistant turn
    prev_total_input = 0

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
                    # Skip messages older than --since cutoff. We still update
                    # first_ts/last_ts to reflect the FILTERED window so the
                    # session is correctly displayed.
                    if since is not None:
                        msg_dt = parse_iso_timestamp(ts)
                        if msg_dt is not None and msg_dt < since:
                            continue
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
                    # Extract tool_use blocks for MCP call accounting (codeburn-inspired)
                    # and dup-read tracking (capture is_dup BEFORE incrementing
                    # file_read_counts so the first read of a file isn't tagged dup).
                    content = msg.get("content")
                    new_pending: list[tuple[str, bool]] = []
                    if isinstance(content, list):
                        for blk in content:
                            if not isinstance(blk, dict): continue
                            if blk.get("type") != "tool_use": continue
                            name = blk.get("name") or ""
                            if name.startswith("mcp__"):
                                # mcp__<server>__<tool>
                                parts = name.split("__")
                                if len(parts) >= 2 and parts[1]:
                                    server = parts[1]
                                    stats.mcp_calls[server] = stats.mcp_calls.get(server, 0) + 1
                            elif name in READ_TOOLS:
                                # Capture file_path from Read/Grep/Glob input
                                inp = blk.get("input") or {}
                                if not isinstance(inp, dict): continue
                                fp = inp.get("file_path") or inp.get("path") or inp.get("pattern") or ""
                                if not isinstance(fp, str) or not fp: continue
                                # Junk-read detection
                                if JUNK_PATTERN.search(fp):
                                    stats.junk_reads.append(fp)
                                # Duplicate-read detection (per-session, normalized path).
                                # Capture is_dup BEFORE bumping count.
                                prior_count = stats.file_read_counts.get(fp, 0)
                                is_dup = prior_count >= 1
                                stats.file_read_counts[fp] = prior_count + 1
                                new_pending.append((fp, is_dup))
                    u = msg.get("usage") or {}
                    if not isinstance(u, dict):
                        # No usage on this turn — can't compute delta. Drop
                        # new_pending; we lose attribution for these reads,
                        # but pending_reads carries forward unchanged so the
                        # next valid usage turn still attributes prev turn.
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

                    # Dup-read attribution: prev turn's pending reads ↦ this
                    # turn's input growth. Compute BEFORE we accumulate the
                    # session totals so prev_total_input represents the
                    # context size as the prev turn's tool_results entered.
                    current_total_input = inp + cr + c5 + c1
                    if pending_reads:
                        delta = max(0, current_total_input - prev_total_input)
                        if delta > 0:
                            cost_per_read = delta / len(pending_reads)
                            for read_fp, is_dup in pending_reads:
                                if is_dup and not JUNK_PATTERN.search(read_fp):
                                    stats.duplicate_read_tokens += int(cost_per_read)
                    pending_reads = new_pending
                    prev_total_input = current_total_input

                    stats.input_tokens   += inp
                    stats.output_tokens  += out
                    stats.cache_read     += cr
                    stats.cache_write_5m += c5
                    stats.cache_write_1h += c1

                    # Per-turn pricing: use THIS turn's model, not a single
                    # session-wide model. A session that starts with Sonnet
                    # then promotes to Opus mid-stream would otherwise be
                    # priced entirely at Sonnet rates (5x undercount on Opus).
                    turn_model = msg.get("model") or stats.model or ""
                    in_p, out_p = price_for(turn_model)
                    stats.cost_usd += (
                        inp * in_p / 1_000_000
                        + cr  * in_p * CACHE_READ_MULT  / 1_000_000
                        + c5  * in_p * CACHE_WRITE_5M   / 1_000_000
                        + c1  * in_p * CACHE_WRITE_1H   / 1_000_000
                        + out * out_p / 1_000_000
                    )

                    sti = u.get("server_tool_use") or {}
                    if isinstance(sti, dict):
                        stats.web_search_calls += sti.get("web_search_requests") or 0
                        stats.web_fetch_calls  += sti.get("web_fetch_requests") or 0
    except (OSError, IOError):
        return None

    if not saw_assistant_with_usage:
        # When `since` was applied, an empty result is a legitimate
        # "session existed but all of it predates the cutoff" case —
        # return an empty SessionStats so main() can count it as filtered.
        # Without `since`, an empty result means the file is a non-CC JSONL
        # (e.g. claude-mem observer logs) — return None to drop it.
        if since is not None:
            return stats
        return None

    # cost_usd was already accumulated per-turn during the message loop.
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

    # Compute token-weighted blended input/output prices across the actual
    # session model mix, so the breakdown table reconciles with the headline
    # Estimated total cost — a Sonnet-only formula misprices Opus-heavy runs
    # by 5x.
    weighted_in = 0.0
    weighted_out_cost = 0.0
    weighted_in_tokens = 0
    weighted_out_tokens = 0
    for s in sessions:
        in_p, out_p = price_for(s.model)
        weighted_in += (s.input_tokens + s.cache_read + s.cache_write_5m + s.cache_write_1h) * in_p
        weighted_in_tokens += (s.input_tokens + s.cache_read + s.cache_write_5m + s.cache_write_1h)
        weighted_out_cost += s.output_tokens * out_p
        weighted_out_tokens += s.output_tokens
    blended_in = (weighted_in / weighted_in_tokens) if weighted_in_tokens else PRICES["sonnet"][0]
    blended_out = (weighted_out_cost / weighted_out_tokens) if weighted_out_tokens else PRICES["sonnet"][1]

    push("─── Token totals (blended across model mix) ────────────────────────────")
    push(f"  Raw input               {humanize(total_inp):>10}    {fmt_usd(total_inp * blended_in / 1_000_000):>8}  (full price)")
    push(f"  Cache read              {humanize(total_cr):>10}    {fmt_usd(total_cr * blended_in * 0.1 / 1_000_000):>8}  (0.1x — cheap)")
    push(f"  Cache write 5m TTL      {humanize(total_c5):>10}    {fmt_usd(total_c5 * blended_in * 1.25 / 1_000_000):>8}  (1.25x)")
    push(f"  Cache write 1h TTL      {humanize(total_c1):>10}    {fmt_usd(total_c1 * blended_in * 2 / 1_000_000):>8}  (2x)")
    push(f"  Output                  {humanize(total_out):>10}    {fmt_usd(total_out * blended_out / 1_000_000):>8}")
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
        # vs the original mix. Use blended input price so Opus-heavy
        # sessions aren't underestimated by 5x.
        target_hit = 0.85
        actual_read = total_cr
        ideal_read  = denom * target_hit
        delta_read  = max(0, ideal_read - actual_read)
        # That delta has to come from somewhere — assume it was raw input @ 1.0x
        # Savings = delta * (1.0 - 0.1) * blended_in_price
        save = delta_read * blended_in * 0.9 / 1_000_000
        push(f"  If your cache hit reached 85% globally: ~{fmt_usd(save)} saved")
    elif cache_hit >= 85:
        push(f"  Cache hit already ≥ 85%. No quick win on this axis.")
    if cache_write_total > 0 and pct_1h < 50:
        # 5m TTL writes that get re-created within the same session waste 1.25x
        # 1h would amortize. Assume half the 5m writes could've been 1h.
        # Same blended-price reasoning as above.
        save_1h = total_c5 * 0.5 * blended_in * 1.25 / 1_000_000  # rough upper bound
        push(f"  If you upgrade to 1h cache TTL: ~{fmt_usd(save_1h)} saved (rough)")
    push("")
    push(f"Pricing: blended {fmt_usd(blended_in)}/M input, {fmt_usd(blended_out)}/M output across the model mix in this window.")
    push("Cache read 0.1x, write 1.25x (5m) or 2x (1h). Retrospective estimate; batching/discounts may differ slightly.")

    # MCP usage: which servers actually get called, which never do
    mcp_totals: dict[str, int] = {}
    sessions_with_mcp = 0
    for s in sessions:
        if s.mcp_calls:
            sessions_with_mcp += 1
        for server, n in s.mcp_calls.items():
            mcp_totals[server] = mcp_totals.get(server, 0) + n
    if mcp_totals or sessions_with_mcp:
        push("")
        push("─── MCP usage (real tool_use call counts) ──────────────────────────────")
        sorted_mcp = sorted(mcp_totals.items(), key=lambda x: -x[1])
        for server, n in sorted_mcp:
            push(f"  {server:30s}  {n:>6d} calls")
        push("")
        push(f"  {sessions_with_mcp} of {len(sessions)} sessions invoked at least one MCP tool.")
        push("  Servers configured in ~/.claude.json but absent from this list paid the")
        push("  tool-schema overhead every session for zero benefit.")

    # Junk-read detection (codeburn-inspired)
    junk_total = sum(len(s.junk_reads) for s in sessions)
    if junk_total >= 3:
        from collections import Counter
        junk_dirs = Counter()
        for s in sessions:
            for p in s.junk_reads:
                # Bucket by which JUNK_DIRS prefix was matched
                m = JUNK_PATTERN.search(p)
                if m:
                    junk_dirs[m.group(0).strip('/')] += 1
        push("")
        push("─── Junk reads (build / dependency directories) ────────────────────────")
        for d, n in junk_dirs.most_common(8):
            push(f"  {d:25s}  {n:>6d} reads")
        # Codeburn's tokens-per-read estimate: 600
        est_saved = junk_total * 600
        push("")
        push(f"  Total: {junk_total} reads × ~600 tokens estimated = ~{est_saved:,} tokens of context fluff.")
        push(f"  Recommend tell Claude in CLAUDE.md to avoid {', '.join(d for d,_ in junk_dirs.most_common(5))}.")

    # Duplicate-read detection (within-session, codeburn-inspired)
    duplicate_pairs = []  # (session_id, file_path, count)
    for s in sessions:
        for fp, count in s.file_read_counts.items():
            # Skip junk-bucket files (already covered above)
            if JUNK_PATTERN.search(fp): continue
            if count >= 3:
                duplicate_pairs.append((s.session_id, fp, count))
    if duplicate_pairs:
        # Sort by count desc, top 8
        duplicate_pairs.sort(key=lambda x: -x[2])
        push("")
        push("─── Duplicate reads (same file re-read in same session) ────────────────")
        for sid, fp, count in duplicate_pairs[:8]:
            short_fp = fp if len(fp) <= 60 else "…" + fp[-58:]
            push(f"  {count:>3}× {short_fp}    [session {sid[:8]}…]")
        total_dup = sum(c - 1 for _, _, c in duplicate_pairs)  # extra reads beyond first
        push("")
        push(f"  {len(duplicate_pairs)} files re-read ≥3 times. ~{total_dup * 600:,} tokens spent re-reading already-cached content.")

    return "\n".join(out) + "\n"


def render_json(sessions: list[SessionStats]) -> str:
    # Aggregate MCP call counts across sessions for downstream consumers
    # (audit.sh detector, CI dashboards). Cross-references against
    # ~/.claude.json::mcpServers happen in the consumer, not here — we
    # report only what the transcripts actually called.
    mcp_totals: dict[str, int] = {}
    sessions_with_mcp = 0
    for s in sessions:
        if s.mcp_calls:
            sessions_with_mcp += 1
        for server, n in s.mcp_calls.items():
            mcp_totals[server] = mcp_totals.get(server, 0) + n
    # Junk + duplicate read aggregates
    from collections import Counter
    junk_by_dir: Counter = Counter()
    for s in sessions:
        for p in s.junk_reads:
            m = JUNK_PATTERN.search(p)
            if m: junk_by_dir[m.group(0).strip('/')] += 1
    duplicate_reads = []
    for s in sessions:
        for fp, count in s.file_read_counts.items():
            if JUNK_PATTERN.search(fp): continue
            if count >= 3:
                duplicate_reads.append({
                    "session_id": s.session_id,
                    "file": fp,
                    "count": count,
                })
    duplicate_reads.sort(key=lambda x: -x["count"])
    payload = {
        "schema": "boris-token-slim/transcript-analyzer/v2",
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
            "web_search_calls":  sum(s.web_search_calls for s in sessions),
            "web_fetch_calls":   sum(s.web_fetch_calls for s in sessions),
        },
        "mcp_usage": {
            "sessions_with_mcp_calls": sessions_with_mcp,
            "by_server": dict(sorted(mcp_totals.items(), key=lambda x: -x[1])),
        },
        "junk_reads": {
            "total": sum(junk_by_dir.values()),
            "by_dir": dict(junk_by_dir.most_common()),
        },
        "duplicate_reads": duplicate_reads[:20],  # top 20
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
                "mcp_calls":       dict(s.mcp_calls),
            }
            for s in sorted(sessions, key=lambda x: -x.cost_usd)
        ],
    }
    return json.dumps(payload, indent=2)


# ---------------------------------------------------------------------------
# Headline (1-line fact-driven summary, pipe-safe, no ANSI)
# ---------------------------------------------------------------------------
_MODEL_FAMILIES = ("opus", "sonnet", "haiku")


def _model_family(model: str) -> str:
    m = (model or "unknown").lower()
    for key in _MODEL_FAMILIES:
        if key in m:
            return key
    return "unknown"


def _model_mix(sessions: list[SessionStats]) -> dict[str, float]:
    """Token-weighted distribution across model families. Returns
    {family: pct} where pct is rounded to 2 decimals. Empty input → {}."""
    families: dict[str, int] = {}
    total = 0
    for s in sessions:
        ftokens = s.input_tokens + s.cache_read + s.cache_write_5m + s.cache_write_1h
        if ftokens <= 0:
            continue
        fam = _model_family(s.model)
        families[fam] = families.get(fam, 0) + ftokens
        total += ftokens
    if total <= 0:
        return {}
    return {k: round(v / total * 100, 2) for k, v in families.items()}


def _zero_call_mcp_count(sessions: list[SessionStats]) -> int:
    """Count of MCP servers configured in ~/.claude.json but invoked 0 times
    in the supplied sessions. Mirrors audit.sh Gotcha 9 logic. Returns 0 if
    the config is missing or unreadable — headline still emits a number."""
    config_path = Path.home() / ".claude.json"
    if not config_path.exists():
        return 0
    try:
        d = json.loads(config_path.read_text())
    except (OSError, json.JSONDecodeError):
        return 0
    if not isinstance(d, dict):
        return 0
    configured: set[str] = set()
    top = d.get("mcpServers") or {}
    if isinstance(top, dict):
        configured |= set(top.keys())
    projects = d.get("projects") or {}
    if isinstance(projects, dict):
        for pd in projects.values():
            if isinstance(pd, dict):
                sub = pd.get("mcpServers") or {}
                if isinstance(sub, dict):
                    configured |= set(sub.keys())
    called: set[str] = set()
    for s in sessions:
        called |= set(s.mcp_calls.keys())
    return len(configured - called)


def _cache_hit_pct(sessions: list[SessionStats]) -> float:
    """Aggregate cache hit rate across sessions."""
    total_inp = sum(s.input_tokens for s in sessions)
    total_cr  = sum(s.cache_read for s in sessions)
    total_c5  = sum(s.cache_write_5m for s in sessions)
    total_c1  = sum(s.cache_write_1h for s in sessions)
    denom = total_inp + total_cr + total_c5 + total_c1
    return (total_cr / denom * 100) if denom else 0.0


def _format_cost(cost_usd: float) -> str:
    """Format cost as plain-comma integer when ≥ 1, else 2 decimals.
    Returns the part inside the dollar sign (HEADLINE_FORMAT prepends $)."""
    if cost_usd >= 1:
        return f"{cost_usd:,.0f}"
    return f"{cost_usd:.2f}"


def render_headline(sessions: list[SessionStats], window_days: int = 30) -> str:
    """1-line fact-driven headline. ≤100 chars target, no ANSI, no trailing newline.
    Empty sessions → HEADLINE_EMPTY constant (still ≤100 chars)."""
    if not sessions:
        return HEADLINE_EMPTY
    total_cost = sum(s.cost_usd for s in sessions)
    cache_hit = _cache_hit_pct(sessions)
    zero_call_mcps = _zero_call_mcp_count(sessions)
    dup_tokens = sum(s.duplicate_read_tokens for s in sessions)
    return HEADLINE_FORMAT.format(
        days=window_days,
        cost=_format_cost(total_cost),
        hit=f"{cache_hit:.1f}",
        mcps=zero_call_mcps,
        dups=humanize(dup_tokens),
    )


# ---------------------------------------------------------------------------
# Ledger (append-only JSONL of headline runs)
# ---------------------------------------------------------------------------
def append_ledger(stats_summary: dict, path: Path) -> None:
    """Append one JSONL line to the ledger. Honors BORIS_STATS_DISABLE=1
    env (no-op when set). Creates parent dir mode 0o700 and file mode 0o600
    so cost/model_mix/file paths are not readable by other users on shared
    hosts. Schema is the caller's responsibility — see main()'s summary dict."""
    if os.environ.get("BORIS_STATS_DISABLE"):
        return
    parent = path.parent
    old_umask = os.umask(0o077)
    try:
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if not path.exists():
            path.touch(mode=0o600)
        line = json.dumps(stats_summary, separators=(",", ":"))
        with path.open("a") as f:
            f.write(line + "\n")
    finally:
        os.umask(old_umask)


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
    p.add_argument("--headline", action="store_true",
                   help="Emit a 1-line fact-driven headline (cost/cache hit/zero-call MCPs/dup-read tokens) and append a JSONL ledger row. Set BORIS_STATS_DISABLE=1 to skip the ledger write (curl-pipe / audit.sh use this).")
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
    skipped_by_timestamp = 0
    for f in iter_session_files(since=since, project_filter=args.project):
        s = analyze_file(f, since=since)
        if not s:
            continue
        # If the session has zero post-cutoff content (every message was
        # older than --since), it's a long-running session whose mtime
        # got bumped without new activity — skip it.
        if since and s.assistant_turns == 0:
            skipped_by_timestamp += 1
            continue
        sessions.append(s)

    if skipped_by_timestamp and not args.json:
        print(
            f"# note: skipped {skipped_by_timestamp} session(s) whose last message "
            f"predates --since cutoff (file mtime updated by resume but no new content)",
            file=sys.stderr,
        )

    if args.headline:
        print(render_headline(sessions, window_days=args.days))
        # Ledger write — silent no-op under BORIS_STATS_DISABLE=1.
        # The audit.sh integration and headline-only.sh curl-pipe both set
        # this env so the ledger only grows on user-initiated runs.
        if not os.environ.get("BORIS_STATS_DISABLE"):
            ledger_path = Path.home() / ".boris-stats" / "history.jsonl"
            summary = {
                "ts": datetime.now(timezone.utc).isoformat(),
                "window_days": args.days,
                "cost_usd": round(sum(s.cost_usd for s in sessions), 4),
                "cache_hit": round(_cache_hit_pct(sessions), 2),
                "zero_call_mcps": _zero_call_mcp_count(sessions),
                "duplicate_read_tokens": sum(s.duplicate_read_tokens for s in sessions),
                "model_mix": _model_mix(sessions),
            }
            append_ledger(summary, ledger_path)
        return 0
    elif args.json:
        print(render_json(sessions))
    else:
        print(render_text(sessions, top_n=args.top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
