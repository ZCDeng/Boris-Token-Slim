"""End-to-end tests for Detector 15 (cache-prefix poisoning) in audit.sh.

The detector's logic is inline Python inside scripts/audit.sh, so we test it
the way users hit it: spawn audit.sh with CLAUDE_HOME pointed at a synthetic
dir and grep the stdout. Each test sets up a self-contained fake home so
tests are independent of the developer's real ~/.claude.
"""
from __future__ import annotations

import os
import subprocess
import textwrap
from pathlib import Path

_HERE = Path(__file__).parent
_AUDIT_SH = _HERE.parent / "scripts" / "audit.sh"


def _run_audit(fake_home: Path) -> str:
    """Invoke audit.sh against a synthetic HOME / CLAUDE_HOME and return stdout."""
    env = os.environ.copy()
    env["HOME"] = str(fake_home)
    env["CLAUDE_HOME"] = str(fake_home / ".claude")
    # MEMORY_DIR is computed from $HOME inside the script via an encoding rule;
    # passing it explicitly avoids depending on whatever the developer's
    # encoded-home directory happens to be.
    env["MEMORY_DIR"] = str(fake_home / ".claude" / "projects" / "fake" / "memory")
    result = subprocess.run(
        ["bash", str(_AUDIT_SH)],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return result.stdout


def _make_fake_home(tmp_path: Path) -> Path:
    home = tmp_path / "home"
    (home / ".claude" / "projects" / "fake" / "memory").mkdir(parents=True)
    return home


def test_detector_15_clean_claude_md_no_poison(tmp_path):
    """Stable content with no volatile markers should not trigger Detector 15."""
    home = _make_fake_home(tmp_path)
    (home / ".claude" / "CLAUDE.md").write_text(textwrap.dedent("""
        # Profile
        Some stable instructions.

        Reference 2026-05 article on caching.  # this date is in a version marker, not volatile
        """).strip())
    out = _run_audit(home)
    assert "Cache-prefix poisoning" not in out


def test_detector_15_fires_on_currentdate_heading(tmp_path):
    """The exact pattern the user's harness injects: a # currentDate heading
    followed by Today's date is. Verifies both patterns fire and the file is
    reported with line numbers."""
    home = _make_fake_home(tmp_path)
    (home / ".claude" / "CLAUDE.md").write_text(textwrap.dedent("""
        # Profile
        Stable content.

        # currentDate
        Today's date is 2026-05-14.
        """).strip())
    out = _run_audit(home)
    assert "Cache-prefix poisoning" in out
    assert "currentDate heading" in out
    assert "today's-date marker" in out
    # File path should appear in the finding
    assert "CLAUDE.md" in out


def test_detector_15_fires_on_memory_md_last_updated(tmp_path):
    """MEMORY.md / memory/*.md are also part of the prefix. A 'Last updated'
    stamp in MEMORY.md should trigger the detector."""
    home = _make_fake_home(tmp_path)
    (home / ".claude" / "CLAUDE.md").write_text("# Clean\nStable.\n")
    mem = home / ".claude" / "projects" / "fake" / "memory" / "MEMORY.md"
    mem.write_text(textwrap.dedent("""
        # Memory index
        Stable entries here.

        Last updated: 2026-05-14
        """).strip())
    out = _run_audit(home)
    assert "Cache-prefix poisoning" in out
    assert "last-updated stamp" in out
    assert "MEMORY.md" in out


def test_detector_15_cost_projection_appears(tmp_path):
    """The finding should include a $/month projection so users see the dollar
    impact, not just a token count."""
    home = _make_fake_home(tmp_path)
    # Pad to ~2KB so the projection rounds to a non-zero cents value.
    padding = "\n".join(f"Stable line {i} with realistic prose content." for i in range(50))
    (home / ".claude" / "CLAUDE.md").write_text(
        f"# Profile\n{padding}\n\n# currentDate\nToday's date is 2026-05-14.\n"
    )
    out = _run_audit(home)
    assert "Cache-prefix poisoning" in out
    # Cost shape line should mention bytes, tokens, and a dollar amount.
    assert "Cost shape:" in out
    assert "tokens" in out
    assert "/month" in out
    # Sonnet input pricing should be named so the user can replicate the math.
    assert "Sonnet" in out


def test_detector_15_recent_n_injection_marker(tmp_path):
    """claude-mem / mempalace-style 'recent N observations' auto-injection
    in MEMORY.md should be flagged — it rewrites the file every session."""
    home = _make_fake_home(tmp_path)
    (home / ".claude" / "CLAUDE.md").write_text("# Clean\n")
    mem = home / ".claude" / "projects" / "fake" / "memory" / "MEMORY.md"
    mem.write_text("# Memory\n\n## Recent 20 observations\n- something\n")
    out = _run_audit(home)
    assert "Cache-prefix poisoning" in out
    assert "recent-N injection" in out


def test_detector_15_skips_bare_iso_dates_in_prose(tmp_path):
    """An ISO date used as a version marker or citation should NOT trigger the
    detector — we deliberately match only volatility phrasing to avoid noise
    on changelogs and 'as of YYYY-MM' style references."""
    home = _make_fake_home(tmp_path)
    (home / ".claude" / "CLAUDE.md").write_text(textwrap.dedent("""
        # Profile
        Reference: 2026-05 article on caching strategy.
        Pricing as of 2026-04-01: $3 / $15 per million.
        See commit 2026-03-20 for context.
        """).strip())
    out = _run_audit(home)
    assert "Cache-prefix poisoning" not in out
