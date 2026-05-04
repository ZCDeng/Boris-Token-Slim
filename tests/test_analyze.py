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
