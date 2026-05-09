"""Tests for scripts/eval.py — counterfactual token audit."""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

_HERE = Path(__file__).parent
_SCRIPT = _HERE.parent / "scripts" / "eval.py"

spec = importlib.util.spec_from_file_location("eval", _SCRIPT)
eval_mod = importlib.util.module_from_spec(spec)
sys.modules["eval"] = eval_mod
spec.loader.exec_module(eval_mod)


def test_estimate_tokens():
    assert eval_mod.estimate_tokens(350) == 100  # 350 / 3.5
    assert eval_mod.estimate_tokens(0) == 0


def test_parse_skill_descriptions_empty():
    with tempfile.TemporaryDirectory() as td:
        result = eval_mod.parse_skill_descriptions(Path(td))
        assert result["count"] == 0
        assert result["total_chars"] == 0


def test_parse_skill_descriptions_with_traps():
    with tempfile.TemporaryDirectory() as td:
        skills = Path(td)
        # Skill with leading-quote trap
        (skills / "quote-trap").mkdir()
        (skills / "quote-trap" / "SKILL.md").write_text(
            '---\nname: q\ndescription: "foo"bar baz\n---\nbody\n'
        )
        # Skill with block scalar
        (skills / "block-trap").mkdir()
        (skills / "block-trap" / "SKILL.md").write_text(
            "---\nname: b\ndescription: |\n  line one\n  line two\n---\nbody\n"
        )
        # Clean skill
        (skills / "clean").mkdir()
        (skills / "clean" / "SKILL.md").write_text(
            "---\nname: c\ndescription: Short desc.\n---\nbody\n"
        )

        result = eval_mod.parse_skill_descriptions(skills)
        assert result["count"] == 3
        assert result["oversized"] == 0  # none > 300c

        by_name = {i["name"]: i for i in result["items"]}
        assert by_name["quote-trap"]["traps"] == ["leading-quote-trunc"]
        assert by_name["block-trap"]["traps"] == ["block-scalar"]
        assert by_name["clean"]["traps"] == []


def test_build_report_honesty_notes():
    """Report must flag MCP and plugin tokens as estimates."""
    current = {
        "claude_md": {"bytes": 2000, "tokens": 571},
        "memory_md": {"bytes": 3000, "tokens": 857},
        "memory_extra_md_files": 0,
        "skill_descriptions": {"count": 10, "total_chars": 5000, "tokens": 1428, "oversized": 5, "top_5": []},
        "mcp": {"user": 2, "project": 1, "total": 3, "tokens_estimated": 1800, "tokens_note": "ESTIMATE"},
        "plugins": {"count": 20, "tokens": None, "tokens_note": "NOT ESTIMATED"},
        "hooks": {"count": 0},
        "bash_output_limit": {"value": 30000, "source": "default"},
    }
    after = eval_mod.compute_after(current, None)
    report = eval_mod.build_report(current, after, None)

    # Must have honesty notes
    notes = report["notes"]
    assert any("Measured" in n for n in notes)
    assert any("ESTIMATE" in n for n in notes)
    assert any("NOT INCLUDED" in n or "NOT ESTIMATED" in n for n in notes)

    # Measured-only should only count exact components
    assert report["measured_only"]["current_tokens"] == 571 + 857 + 1428

    # With-estimates should include MCP
    assert report["with_estimates"]["current_tokens"] == report["measured_only"]["current_tokens"] + 1800


def test_build_report_with_plugin_estimate():
    current = {
        "claude_md": {"bytes": 1000, "tokens": 285},
        "memory_md": {"bytes": 1000, "tokens": 285},
        "memory_extra_md_files": 0,
        "skill_descriptions": {"count": 5, "total_chars": 1000, "tokens": 285, "oversized": 0, "top_5": []},
        "mcp": {"user": 1, "project": 0, "total": 1, "tokens_estimated": 600, "tokens_note": "ESTIMATE"},
        "plugins": {"count": 20, "tokens": 4000, "tokens_note": "user-supplied"},
        "hooks": {"count": 0},
        "bash_output_limit": {"value": 30000, "source": "default"},
    }
    after = eval_mod.compute_after(current, 200)
    report = eval_mod.build_report(current, after, 200)

    # Plugin tokens should be included in with_estimates
    assert report["with_estimates"]["current_tokens"] == 285 + 285 + 285 + 600 + 4000


def test_main_json_output():
    """Smoke: eval.py --json should emit valid JSON."""
    import subprocess
    result = subprocess.run(
        [sys.executable, str(_SCRIPT), "--json"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0
    data = json.loads(result.stdout)
    assert "measured_only" in data
    assert "with_estimates" in data
    assert "notes" in data
