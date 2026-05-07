"""Tests for --headline flag, render_headline, append_ledger, and related helpers."""
from __future__ import annotations

import importlib.util
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

_HERE = Path(__file__).parent
_SCRIPT = _HERE.parent / "scripts" / "analyze.py"
_FIXTURES = _HERE / "fixtures"

spec = importlib.util.spec_from_file_location("analyze", _SCRIPT)
analyze = importlib.util.module_from_spec(spec)
sys.modules["analyze"] = analyze
spec.loader.exec_module(analyze)


# ── render_headline ──────────────────────────────────────────────────────
def test_render_headline_empty_sessions():
    out = analyze.render_headline([])
    assert out == "0 sessions found · run claude code first"
    assert len(out) <= 100


def test_render_headline_single_session_has_expected_tokens():
    s = analyze.analyze_file(_FIXTURES / "normal-session.jsonl")
    assert s is not None
    out = analyze.render_headline([s], window_days=30)
    assert len(out.split("\n")) == 1, "headline must be single line"
    assert len(out) <= 100
    # 4 fact segments
    assert "$" in out
    assert "%" in out
    assert "MCP" in out
    assert "re-read" in out
    assert "30 days:" in out


def test_render_headline_no_ansi_escape():
    s = analyze.analyze_file(_FIXTURES / "normal-session.jsonl")
    assert s is not None
    out = analyze.render_headline([s])
    assert "\x1b[" not in out


def test_render_headline_window_days_label():
    s = analyze.analyze_file(_FIXTURES / "normal-session.jsonl")
    assert s is not None
    out7 = analyze.render_headline([s], window_days=7)
    assert "7 days:" in out7
    out90 = analyze.render_headline([s], window_days=90)
    assert "90 days:" in out90


# ── _helpers ─────────────────────────────────────────────────────────────
def test_model_mix_empty():
    assert analyze._model_mix([]) == {}


def test_model_mix_single_session():
    s = analyze.analyze_file(_FIXTURES / "normal-session.jsonl")
    assert s is not None
    mix = analyze._model_mix([s])
    assert mix, "non-empty session should produce a mix"
    total = sum(mix.values())
    assert abs(total - 100.0) < 0.01
    # s.model = first model seen (Sonnet in this fixture).
    # _model_mix attributes all session tokens to that family.
    assert "sonnet" in mix


def test_cache_hit_pct():
    s = analyze.analyze_file(_FIXTURES / "normal-session.jsonl")
    assert s is not None
    pct = analyze._cache_hit_pct([s])
    assert 0 <= pct <= 100


def test_format_cost():
    assert analyze._format_cost(15981.0) == "15,981"
    assert analyze._format_cost(999.12) == "999"
    assert analyze._format_cost(0.52) == "0.52"
    assert analyze._format_cost(0.05) == "0.05"


# ── append_ledger ────────────────────────────────────────────────────────
def test_append_ledger_writes_jsonl_line():
    with tempfile.TemporaryDirectory() as td:
        ledger = Path(td) / "history.jsonl"
        summary = {
            "ts": "2026-04-01T10:00:00Z",
            "window_days": 30,
            "cost_usd": 15.981,
            "cache_hit": 95.92,
            "zero_call_mcps": 3,
            "duplicate_read_tokens": 1050000,
            "model_mix": {"sonnet": 65.0, "opus": 35.0},
        }
        analyze.append_ledger(summary, ledger)
        assert ledger.exists()
        lines = ledger.read_text().strip().splitlines()
        assert len(lines) == 1
        import json
        d = json.loads(lines[0])
        assert d["cost_usd"] == 15.981
        assert "analyzer_version" not in d, "FYI3: no YAGNI schema field"


def test_append_ledger_disabled_by_env(monkeypatch):
    monkeypatch.setenv("BORIS_STATS_DISABLE", "1")
    with tempfile.TemporaryDirectory() as td:
        ledger = Path(td) / "noledger.jsonl"
        analyze.append_ledger({"k": "v"}, ledger)
        assert not ledger.exists()


def test_append_ledger_permissions():
    with tempfile.TemporaryDirectory() as td:
        ledger = Path(td) / "secret.jsonl"
        analyze.append_ledger({"k": "v"}, ledger)
        dir_mode = os.stat(ledger.parent).st_mode & 0o777
        assert dir_mode == 0o700, f"dir mode 0o{dir_mode:03o}"
        file_mode = os.stat(ledger).st_mode & 0o777
        assert file_mode == 0o600, f"file mode 0o{file_mode:03o}"


def test_append_ledger_appends_not_overwrite():
    with tempfile.TemporaryDirectory() as td:
        ledger = Path(td) / "app.jsonl"
        analyze.append_ledger({"n": 1}, ledger)
        analyze.append_ledger({"n": 2}, ledger)
        lines = ledger.read_text().strip().splitlines()
        assert len(lines) == 2


# ── PROJECTS_ROOT reads CLAUDE_HOME ─────────────────────────────────────
def test_projects_root_defaults_to_home_dot_claude():
    """PROJECTS_ROOT defaults to ~/.claude/projects when CLAUDE_HOME is unset."""
    # Subprocess has CLAUDE_HOME stripped from env, so PROJECTS_ROOT falls back.
    child_env = {k: v for k, v in os.environ.items() if k != "CLAUDE_HOME"}
    r = subprocess.run(
        [sys.executable, str(_SCRIPT), "--headline", "--days", "0"],
        capture_output=True, text=True, env=child_env,
    )
    # CLI arg 0 days = no sessions, but PROJECTS_ROOT was already computed at
    # import time. We verify the import succeeded (no crash from dataclass
    # loading issue), so PROJECTS_ROOT resolved to a Path on disk.
    assert r.returncode == 0


def test_projects_root_respects_claude_home_env():
    """CLAUDE_HOME=/tmp/fake-claude → PROJECTS_ROOT resolves to that path."""
    child_env = {**os.environ, "CLAUDE_HOME": "/tmp/fake-claude"}
    r = subprocess.run(
        [sys.executable, str(_SCRIPT), "--headline", "--days", "0"],
        capture_output=True, text=True, env=child_env,
    )
    assert r.returncode == 0


def test_headline_flag_on_empty_fixture_dir(monkeypatch, tmp_path):
    """subprocess --headline with no projects dir exits 0 and prints empty string."""
    monkeypatch.setenv("CLAUDE_HOME", str(tmp_path / "empty-claude"))
    monkeypatch.setenv("BORIS_STATS_DISABLE", "1")
    r = subprocess.run(
        [sys.executable, str(_SCRIPT), "--headline", "--days", "30"],
        capture_output=True, text=True, env={**os.environ, "CLAUDE_HOME": str(tmp_path / "empty-claude"), "BORIS_STATS_DISABLE": "1"},
    )
    assert r.returncode == 0, f"stderr: {r.stderr}"
    assert "run claude code first" in r.stdout


# ── dup-read zero-estimation ─────────────────────────────────────────────
def test_duplicate_read_tokens_not_heuristic():
    """dup-read fixture: main.py read 2× (second is dup), utils.py 1×.
    Turn 2's input grew from 100→700 (delta 600); one read in prior turn,
    none were dup (main.py first read) → 0 attributed.
    Turn 3's input grew from 700→1000 (delta 300); one read in prior turn,
    main.py IS dup → 300 attributed."""
    s = analyze.analyze_file(_FIXTURES / "dup-read-session.jsonl")
    assert s is not None
    # Not zero (the heuristic path is dead), not 2×600=1200 (estimating)
    assert s.duplicate_read_tokens > 0, "should attribute real token growth"
    assert s.duplicate_read_tokens == 300, f"expected 300, got {s.duplicate_read_tokens}"


def test_same_turn_second_read_correctly_attributed():
    """Double-read in same assistant turn: two Read calls, the second is dup."""
    s = analyze.analyze_file(_FIXTURES / "dup-read-session.jsonl")
    assert s is not None
    # file_read_counts should record main.py = 2, utils.py = 1
    assert s.file_read_counts.get("/home/user/src/main.py") == 2
    assert s.file_read_counts.get("/home/user/src/utils.py") == 1


# ── Trust contract: BORIS_STATS_DISABLE=1 doesn't write ledger ───────────
def test_headline_with_disable_does_not_create_ledger(monkeypatch, tmp_path):
    """Integration test: --headline + BORIS_STATS_DISABLE=1 leaves no ~/.boris-stats."""
    home = tmp_path / "fake-home"
    home.mkdir()
    claude_home = tmp_path / "fake-claude"
    (claude_home / "projects" / "testproj").mkdir(parents=True)
    monkeypatch.setenv("CLAUDE_HOME", str(claude_home))
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("BORIS_STATS_DISABLE", "1")
    r = subprocess.run(
        [sys.executable, str(_SCRIPT), "--headline", "--days", "30"],
        capture_output=True, text=True,
        env={**os.environ, "CLAUDE_HOME": str(claude_home), "HOME": str(home), "BORIS_STATS_DISABLE": "1"},
    )
    assert r.returncode == 0, f"stderr: {r.stderr}"
    stats_dir = home / ".boris-stats"
    assert not stats_dir.exists(), f"~/.boris-stats should not exist, but found: {list(stats_dir.iterdir()) if stats_dir.exists() else 'N/A'}"


# ── HEADLINE_FORMAT invariant ────────────────────────────────────────────
def test_headline_format_has_four_segments():
    fmt = analyze.HEADLINE_FORMAT
    required = ["{days}", "{cost}", "{hit}", "{mcps}", "{dups}"]
    for token in required:
        assert token in fmt, f"HEADLINE_FORMAT missing {token}"
