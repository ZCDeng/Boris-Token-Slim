"""Tests for scripts/analyze.py — runs without Claude Code installed."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

# Load analyze.py as a module without requiring it to be on sys.path.
_HERE = Path(__file__).parent
_SCRIPT = _HERE.parent / "scripts" / "analyze.py"
_FIXTURES = _HERE / "fixtures"

spec = importlib.util.spec_from_file_location("analyze", _SCRIPT)
analyze = importlib.util.module_from_spec(spec)
sys.modules["analyze"] = analyze
spec.loader.exec_module(analyze)


# ---------------------------------------------------------------------------
# price_for
# ---------------------------------------------------------------------------
def test_price_for_known_models():
    assert analyze.price_for("claude-sonnet-4-6") == (3.0, 15.0)
    assert analyze.price_for("claude-opus-4-7")   == (15.0, 75.0)
    assert analyze.price_for("claude-haiku-4-5")  == (0.80, 4.0)


def test_price_for_unknown_model_warns_once(capsys):
    # Reset state — analyze module is imported once per pytest session
    analyze._UNKNOWN_MODELS_SEEN.clear()

    p1 = analyze.price_for("claude-future-99")
    p2 = analyze.price_for("claude-future-99")  # same id, second call

    assert p1 == p2 == (3.0, 15.0)  # falls back to Sonnet
    captured = capsys.readouterr()
    # Warning lands on stderr exactly once
    assert captured.err.count("warning: unknown model") == 1
    assert "claude-future-99" in captured.err


def test_price_for_empty_or_none():
    assert analyze.price_for("") == (3.0, 15.0)
    assert analyze.price_for(None) == (3.0, 15.0)


# ---------------------------------------------------------------------------
# analyze_file — three fixtures
# ---------------------------------------------------------------------------
def test_analyze_file_empty_returns_none():
    """A session with only a summary marker (no real assistant turns)
    should return None — we don't want to surface no-op sessions."""
    result = analyze.analyze_file(_FIXTURES / "empty-session.jsonl")
    assert result is None


def test_analyze_file_corrupt_does_not_crash():
    """Mixed valid/corrupt JSONL: malformed lines and weird message shapes
    should be skipped without crashing. The one valid usage line should
    still be aggregated."""
    result = analyze.analyze_file(_FIXTURES / "corrupt-mixed.jsonl")
    assert result is not None
    assert result.assistant_turns >= 1
    assert result.input_tokens == 12
    assert result.output_tokens == 5
    assert result.cache_read == 100
    assert result.user_turns == 1
    # Cost is non-negative and uses Sonnet pricing
    assert result.cost_usd > 0


def test_analyze_file_normal_aggregates_correctly():
    """Three assistant turns: 2 Sonnet + 1 Opus, with a mix of 5m and 1h
    cache writes."""
    result = analyze.analyze_file(_FIXTURES / "normal-session.jsonl")
    assert result is not None
    assert result.assistant_turns == 3
    assert result.user_turns == 3
    # Sums across all turns
    assert result.input_tokens     == 50 + 20 + 10
    assert result.output_tokens    == 100 + 80 + 200
    assert result.cache_write_5m   == 1000
    assert result.cache_write_1h   == 500
    assert result.cache_read       == 1000 + 2000
    # Cache hit rate calculation: 3000 / (80 + 3000 + 1000 + 500)
    expected = 3000 / (80 + 3000 + 1000 + 500) * 100
    assert abs(result.cache_hit_rate - expected) < 0.01
    # Cost positive
    assert result.cost_usd > 0


def test_analyze_file_normal_uses_first_model_seen():
    """The session has both Sonnet and Opus turns; we record the first
    model seen (which is what the dashboard displays)."""
    result = analyze.analyze_file(_FIXTURES / "normal-session.jsonl")
    assert result is not None
    assert "sonnet" in result.model.lower()  # first turn was Sonnet


# ---------------------------------------------------------------------------
# render_text — minimal smoke test
# ---------------------------------------------------------------------------
def test_render_text_handles_empty_session_list():
    out = analyze.render_text([], top_n=10)
    assert "No Claude Code transcripts found" in out


def test_render_text_includes_dashboard_for_one_session():
    s = analyze.analyze_file(_FIXTURES / "normal-session.jsonl")
    assert s is not None
    out = analyze.render_text([s], top_n=5)
    # Dashboard contains the standard headers
    assert "Boris-Token-Slim" in out
    assert "Cache hit rate" in out
    assert "Top" in out


# ---------------------------------------------------------------------------
# parse_iso_timestamp — for since-filtering by transcript content
# ---------------------------------------------------------------------------
def test_parse_iso_timestamp_handles_z_suffix():
    """Claude Code transcripts use 'YYYY-MM-DDTHH:MM:SS.fffZ' format."""
    from datetime import datetime, timezone
    dt = analyze.parse_iso_timestamp("2026-04-01T10:00:00.000Z")
    assert dt is not None
    assert dt.tzinfo is not None
    assert dt == datetime(2026, 4, 1, 10, 0, 0, tzinfo=timezone.utc)


def test_parse_iso_timestamp_returns_none_on_garbage():
    assert analyze.parse_iso_timestamp("") is None
    assert analyze.parse_iso_timestamp("not a date") is None


def test_parse_iso_timestamp_handles_naive_iso():
    """Some transcript writers omit the Z. We default to UTC."""
    from datetime import timezone
    dt = analyze.parse_iso_timestamp("2026-04-01T10:00:00")
    assert dt is not None
    assert dt.tzinfo == timezone.utc


def test_old_session_with_recent_mtime_has_correct_last_ts():
    """The fixture has messages from 2026-01-15 only.
    analyze_file should record last_ts = 2026-01-15T09:00:05Z.
    main()'s authoritative since-filter would then drop it from a
    --days 7 window even if the file mtime got bumped by a touch."""
    s = analyze.analyze_file(_FIXTURES / "old-session-recent-mtime.jsonl")
    assert s is not None
    assert s.last_ts.startswith("2026-01-15")
    last_dt = analyze.parse_iso_timestamp(s.last_ts)
    assert last_dt is not None
    # The fixture's last timestamp is 2026-01-15. A since=2026-04-01 cutoff
    # would correctly drop this session if main() filters by last_ts.
    from datetime import datetime, timezone
    cutoff = datetime(2026, 4, 1, tzinfo=timezone.utc)
    assert last_dt < cutoff


def test_analyze_file_with_since_skips_old_messages():
    """When since is provided, analyze_file should skip messages older
    than the cutoff. The old-session fixture has only 2026-01-15 messages,
    so a since=2026-04-01 cutoff should yield zero assistant_turns."""
    from datetime import datetime, timezone
    cutoff = datetime(2026, 4, 1, tzinfo=timezone.utc)
    s = analyze.analyze_file(_FIXTURES / "old-session-recent-mtime.jsonl",
                             since=cutoff)
    assert s is not None  # returns empty stats, not None, in since mode
    assert s.assistant_turns == 0
    assert s.input_tokens == 0


def test_analyze_file_with_since_keeps_recent_messages():
    """The normal-session fixture has 2026-04-01 messages.
    A since=2026-03-01 cutoff should keep all of them; a since=2026-05-01
    cutoff should drop all of them."""
    from datetime import datetime, timezone
    early_cutoff = datetime(2026, 3, 1, tzinfo=timezone.utc)
    s = analyze.analyze_file(_FIXTURES / "normal-session.jsonl",
                             since=early_cutoff)
    assert s is not None
    assert s.assistant_turns == 3  # all kept

    late_cutoff = datetime(2026, 5, 1, tzinfo=timezone.utc)
    s = analyze.analyze_file(_FIXTURES / "normal-session.jsonl",
                             since=late_cutoff)
    assert s is not None
    assert s.assistant_turns == 0  # all filtered


def test_analyze_file_no_since_preserves_legacy_behavior():
    """Without since, the non-CC JSONL detection should still kick in
    and return None for files with no usage data."""
    s = analyze.analyze_file(_FIXTURES / "empty-session.jsonl")
    assert s is None  # legacy: no since, no usage → None
