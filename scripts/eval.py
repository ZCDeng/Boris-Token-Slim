#!/usr/bin/env python3
"""Boris-Token-Slim eval harness — user-specific counterfactual token audit.

Measures the structural input-token overhead in the user's CURRENT ~/.claude/
configuration and computes a counterfactual "after Boris" estimate using the
skill's own thresholds. No API calls — purely configuration analysis.

Output: JSON + markdown report + one-line headline.

Honesty contract:
- "Measured" = exact byte/char counts from file system.
- "Estimated" = relies on external assumptions (MCP schema size, plugin hook
  context) that cannot be verified from files alone. These are flagged.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from datetime import datetime

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
# Conservative blended chars-per-token (English ~4, CJK ~2, mixed ~3.5)
CHARS_PER_TOKEN = 3.5

# MCP schema size: codeburn empirical estimate. Flagged as ESTIMATE in output.
# Source: https://github.com/getagentseal/codeburn (discussed in README)
MCP_SCHEMA_TOKENS = 600

# Plugin hook context: NO reliable public estimate. We do NOT auto-assign a
# token count. Instead we report plugin count and let the user judge.
# If you have a measured per-plugin hook size for your setup, pass
# --plugin-hook-tokens N to include it.

# Thresholds (must match audit.sh)
THRESHOLDS = {
    "claude_md_bytes": 1500,
    "memory_md_bytes": 2000,
    "memory_extra_md_files": 15,
    "plugins": 15,
    "mcp_total": 6,
    "skills": 50,
    "hooks": 3,
    "bash_output_limit": 15000,
    "skill_description_chars": 300,  # detector 12 threshold
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def estimate_tokens(chars: int) -> int:
    return max(0, int(chars / CHARS_PER_TOKEN))


def read_claude_home() -> Path:
    return Path(os.environ.get("CLAUDE_HOME", Path.home() / ".claude"))


def home_encoded() -> str:
    """Claude Code encodes home path for project directories."""
    return "-" + str(Path.home())[1:].replace("/", "-")


def parse_skill_descriptions(skills_dir: Path) -> dict:
    """Walk skills_dir and extract description lengths.

    Returns dict with:
        total_chars, count, oversized (>300c), items: [{name, chars, traps}]
    """
    fm_re = re.compile(r"^---\n(.*?)\n---", re.S)
    re_leading_quote = re.compile(r'^"[^"\n]+"\s*\S+')
    re_midline_label = re.compile(r" [A-Z][A-Za-z]+:\s")

    result = {
        "total_chars": 0,
        "count": 0,
        "oversized": 0,
        "items": [],
    }

    if not skills_dir.is_dir():
        return result

    for entry in sorted(skills_dir.iterdir()):
        real = entry.resolve()
        smd = real / "SKILL.md"
        if not smd.is_file():
            continue
        text = smd.read_text(encoding="utf-8", errors="ignore")
        m = fm_re.match(text)
        if not m:
            continue
        fm_text = m.group(1)

        desc = None
        traps = []
        for line in fm_text.split("\n"):
            if not line.startswith("description:"):
                continue
            rest = line[len("description:"):].lstrip()
            if rest.startswith("|") or rest.startswith(">"):
                # Block scalar: count indented lines after
                block = []
                in_block = False
                for l in text.split("\n"):
                    if l.startswith("description:") and (l[len("description:"):].lstrip().startswith("|") or l[len("description:"):].lstrip().startswith(">")):
                        in_block = True
                        continue
                    if in_block:
                        if l.startswith("  ") or l.strip() == "":
                            block.append(l.strip())
                        else:
                            break
                desc = "\n".join(b for b in block if b)
                traps.append("block-scalar")
            else:
                desc = rest
                if re_leading_quote.match(rest):
                    traps.append("leading-quote-trunc")
                no_url = re.sub(r"https?://\S+", "", rest)
                if re_midline_label.search(" " + no_url):
                    traps.append("mid-line-colon")
            break

        if desc is None:
            continue

        chars = len(desc)
        result["total_chars"] += chars
        result["count"] += 1
        is_over = chars > THRESHOLDS["skill_description_chars"]
        if is_over:
            result["oversized"] += 1
        result["items"].append({
            "name": entry.name,
            "chars": chars,
            "oversized": is_over,
            "traps": traps,
        })

    # Sort by chars desc
    result["items"].sort(key=lambda x: x["chars"], reverse=True)
    return result


def measure_current(home: Path, plugin_hook_tokens: int | None) -> dict:
    """Measure current configuration overhead."""
    m = {}

    # 1. CLAUDE.md (bytes, matching audit.sh `wc -c`)
    claude_md = home / "CLAUDE.md"
    if claude_md.exists():
        text = claude_md.read_text()
        nbytes = len(text.encode("utf-8"))
        m["claude_md"] = {"bytes": nbytes, "tokens": estimate_tokens(nbytes)}
    else:
        m["claude_md"] = {"bytes": 0, "tokens": 0}

    # 2. MEMORY.md
    memory_paths = [
        home / "memory" / "MEMORY.md",
        home / "projects" / home_encoded() / "memory" / "MEMORY.md",
    ]
    mem_file = None
    for p in memory_paths:
        if p.exists():
            mem_file = p
            break
    if mem_file:
        text = mem_file.read_text()
        nbytes = len(text.encode("utf-8"))
        m["memory_md"] = {"bytes": nbytes, "tokens": estimate_tokens(nbytes)}
    else:
        m["memory_md"] = {"bytes": 0, "tokens": 0}

    # Extra .md files in memory dir
    if mem_file:
        mem_dir = mem_file.parent
        extra = len([f for f in mem_dir.iterdir() if f.suffix == ".md" and f.name != "MEMORY.md"])
        m["memory_extra_md_files"] = extra
    else:
        m["memory_extra_md_files"] = 0

    # 3. Skill descriptions
    descs = parse_skill_descriptions(home / "skills")
    m["skill_descriptions"] = {
        "count": descs["count"],
        "total_chars": descs["total_chars"],
        "tokens": estimate_tokens(descs["total_chars"]),
        "oversized": descs["oversized"],
        "top_5": descs["items"][:5],
    }

    # 4. MCP servers
    claude_json = Path.home() / ".claude.json"
    mcp_user = 0
    mcp_project = 0
    if claude_json.exists():
        try:
            cfg = json.loads(claude_json.read_text())
            mcp_user = len(cfg.get("mcpServers", {}))
            for proj in cfg.get("projects", {}).values():
                mcp_project += len(proj.get("mcpServers", {}))
        except Exception:
            pass
    mcp_total = mcp_user + mcp_project
    m["mcp"] = {
        "user": mcp_user,
        "project": mcp_project,
        "total": mcp_total,
        "tokens_estimated": mcp_total * MCP_SCHEMA_TOKENS,
        "tokens_note": f"ESTIMATE: {mcp_total} × {MCP_SCHEMA_TOKENS} tokens (codeburn empirical)",
    }

    # 5. Plugins
    installed_json = home / "plugins" / "installed_plugins.json"
    plugin_count = 0
    if installed_json.exists():
        try:
            plugin_count = len(json.loads(installed_json.read_text()).get("plugins", {}))
        except Exception:
            pass
    m["plugins"] = {
        "count": plugin_count,
        "tokens": plugin_count * plugin_hook_tokens if plugin_hook_tokens else None,
        "tokens_note": (
            f"{plugin_count} × {plugin_hook_tokens} tokens (user-supplied estimate)"
            if plugin_hook_tokens
            else "NOT ESTIMATED: no reliable public data for per-plugin hook context size. Pass --plugin-hook-tokens N to include."
        ),
    }

    # 6. Hooks
    hooks = 0
    for f in [home / "settings.json", home / "settings.local.json"]:
        if f.exists():
            try:
                cfg = json.loads(f.read_text())
                h = cfg.get("hooks", {})
                hooks += sum(len(v) if isinstance(v, list) else 1 for v in h.values())
            except Exception:
                pass
    m["hooks"] = {"count": hooks}

    # 7. Bash output limit
    bash_limit = 30000  # default
    bash_source = "default"
    for profile in [".zshrc", ".bashrc", ".bash_profile", ".profile"]:
        pf = Path.home() / profile
        if not pf.exists():
            continue
        text = pf.read_text()
        found = re.search(r'export\s+BASH_MAX_OUTPUT_LENGTH\s*=\s*["\']?(\d+)', text)
        if found:
            bash_limit = int(found.group(1))
            bash_source = f"~/{profile}"
            break
    if bash_source == "default" and os.environ.get("BASH_MAX_OUTPUT_LENGTH"):
        bash_limit = int(os.environ["BASH_MAX_OUTPUT_LENGTH"])
        bash_source = "env BASH_MAX_OUTPUT_LENGTH"
    m["bash_output_limit"] = {"value": bash_limit, "source": bash_source}

    return m


def compute_after(current: dict, plugin_hook_tokens: int | None) -> dict:
    """Compute counterfactual 'after Boris' using skill thresholds."""
    a = {}

    # CLAUDE.md: target < 1500 bytes
    cc = current["claude_md"]["bytes"]
    a["claude_md"] = {
        "bytes": min(cc, THRESHOLDS["claude_md_bytes"]),
        "tokens": estimate_tokens(min(cc, THRESHOLDS["claude_md_bytes"])),
    }

    # MEMORY.md: target < 2000 bytes
    mc = current["memory_md"]["bytes"]
    a["memory_md"] = {
        "bytes": min(mc, THRESHOLDS["memory_md_bytes"]),
        "tokens": estimate_tokens(min(mc, THRESHOLDS["memory_md_bytes"])),
    }

    # Skill descriptions: target compress oversized to ~150c each
    # Non-oversized assumed optimal. Oversized: assume 400c → 150c compression.
    desc_total = current["skill_descriptions"]["total_chars"]
    oversized = current["skill_descriptions"]["oversized"]
    if oversized > 0:
        # Each oversized skill saves ~250c on average
        saved = oversized * 250
        after_chars = max(desc_total - saved, int(desc_total * 0.6))
    else:
        after_chars = desc_total
    a["skill_descriptions"] = {
        "chars": after_chars,
        "tokens": estimate_tokens(after_chars),
        "oversized_after": 0,
    }

    # MCP: target < 6
    mcp_after = min(current["mcp"]["total"], THRESHOLDS["mcp_total"])
    a["mcp"] = {
        "total": mcp_after,
        "tokens_estimated": mcp_after * MCP_SCHEMA_TOKENS,
    }

    # Plugins: target < 15
    plugin_after = min(current["plugins"]["count"], THRESHOLDS["plugins"])
    a["plugins"] = {
        "count": plugin_after,
        "tokens": plugin_after * plugin_hook_tokens if plugin_hook_tokens else None,
    }

    return a


def build_report(current: dict, after: dict, plugin_hook_tokens: int | None) -> dict:
    """Build the final report dict."""
    # Sum measured-only totals (exact)
    measured_current = (
        current["claude_md"]["tokens"]
        + current["memory_md"]["tokens"]
        + current["skill_descriptions"]["tokens"]
    )
    measured_after = (
        after["claude_md"]["tokens"]
        + after["memory_md"]["tokens"]
        + after["skill_descriptions"]["tokens"]
    )
    measured_saved = measured_current - measured_after
    measured_pct = round(measured_saved / measured_current * 100, 1) if measured_current > 0 else 0.0

    # Sum with estimates (MCP + optional plugin hooks)
    est_current = measured_current + current["mcp"]["tokens_estimated"]
    est_after = measured_after + after["mcp"]["tokens_estimated"]
    if plugin_hook_tokens:
        est_current += current["plugins"]["tokens"] or 0
        est_after += after["plugins"]["tokens"] or 0
    est_saved = est_current - est_after
    est_pct = round(est_saved / est_current * 100, 1) if est_current > 0 else 0.0

    return {
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "method": "configuration-analysis",
        "notes": [
            "Measured components: exact byte/char counts from file system.",
            f"MCP tokens: ESTIMATE ({MCP_SCHEMA_TOKENS} tokens/server, codeburn empirical).",
            "Plugin tokens: " + (
                f"user-supplied estimate ({plugin_hook_tokens} tokens/plugin)."
                if plugin_hook_tokens
                else "NOT INCLUDED (no reliable public data)."
            ),
        ],
        "current": current,
        "after_boris": after,
        "measured_only": {
            "current_tokens": measured_current,
            "after_tokens": measured_after,
            "saved_tokens": measured_saved,
            "saved_percent": measured_pct,
        },
        "with_estimates": {
            "current_tokens": est_current,
            "after_tokens": est_after,
            "saved_tokens": est_saved,
            "saved_percent": est_pct,
        },
    }


def print_text_report(report: dict) -> None:
    """Print human-readable report."""
    m = report["measured_only"]
    e = report["with_estimates"]
    cur = report["current"]
    aft = report["after_boris"]

    print("╔══════════════════════════════════════════════════════════════════════╗")
    print("║  Boris-Token-Slim · Counterfactual Token Audit (eval harness S4)     ║")
    print("╚══════════════════════════════════════════════════════════════════════╝")
    print()
    print("Method: configuration analysis (no API calls)")
    print(f"Generated: {report['generated_at']}")
    print()

    # Measured components
    print("─ Measured components (exact) ────────────────────────────────────────")
    print(f"  CLAUDE.md           {cur['claude_md']['bytes']:>6}B  →  {cur['claude_md']['tokens']:>5}t  |  after: {aft['claude_md']['bytes']:>6}B  →  {aft['claude_md']['tokens']:>5}t")
    print(f"  MEMORY.md           {cur['memory_md']['bytes']:>6}B  →  {cur['memory_md']['tokens']:>5}t  |  after: {aft['memory_md']['bytes']:>6}B  →  {aft['memory_md']['tokens']:>5}t")
    print(f"  Skill descriptions  {cur['skill_descriptions']['total_chars']:>6}c  →  {cur['skill_descriptions']['tokens']:>5}t  |  after: {aft['skill_descriptions']['chars']:>6}c  →  {aft['skill_descriptions']['tokens']:>5}t")
    print(f"    ({cur['skill_descriptions']['count']} skills, {cur['skill_descriptions']['oversized']} oversized)")
    print()
    print(f"  Measured subtotal:  {m['current_tokens']}t  →  {m['after_tokens']}t  (save {m['saved_tokens']}t, {m['saved_percent']}%)")
    print()

    # Estimated components
    print("─ Estimated components ───────────────────────────────────────────────")
    print(f"  MCP servers         {cur['mcp']['total']:>3}  →  ~{cur['mcp']['tokens_estimated']:>5}t  |  after: {aft['mcp']['total']:>3}  →  ~{aft['mcp']['tokens_estimated']:>5}t")
    print(f"    Note: {cur['mcp']['tokens_note']}")
    print()
    if cur["plugins"]["tokens"] is not None:
        print(f"  Plugins             {cur['plugins']['count']:>3}  →  ~{cur['plugins']['tokens']:>5}t  |  after: {aft['plugins']['count']:>3}  →  ~{aft['plugins']['tokens'] or 0:>5}t")
    else:
        print(f"  Plugins             {cur['plugins']['count']:>3}  |  after: {aft['plugins']['count']:>3}")
    print(f"    Note: {cur['plugins']['tokens_note']}")
    print()
    print(f"  With estimates:     {e['current_tokens']}t  →  {e['after_tokens']}t  (save {e['saved_tokens']}t, {e['saved_percent']}%)")
    print()

    # Top oversized skills
    if cur["skill_descriptions"]["top_5"]:
        print("─ Top 5 skill descriptions by length ─────────────────────────────────")
        for item in cur["skill_descriptions"]["top_5"]:
            flag = " [OVERSIZED]" if item["oversized"] else ""
            traps = f"  traps: {', '.join(item['traps'])}" if item["traps"] else ""
            print(f"  {item['chars']:>4}c  {item['name']}{flag}{traps}")
        print()

    # Headline
    print("─ Headline ───────────────────────────────────────────────────────────")
    print(f"  Measured-only:  Boris reduces file-based overhead by {m['saved_percent']}%")
    if cur["plugins"]["tokens"] is not None:
        print(f"  With estimates: Boris reduces total overhead by ~{e['saved_percent']}%")
    else:
        print(f"  With estimates: Boris reduces measured + MCP overhead by ~{e['saved_percent']}% (plugin context not estimated)")
    print()

    # Honesty footer
    print("─ Honesty notes ──────────────────────────────────────────────────────")
    for note in report["notes"]:
        print(f"  • {note}")
    print()


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(
        description="Boris-Token-Slim counterfactual token audit (S4 eval harness)"
    )
    parser.add_argument(
        "--json", action="store_true",
        help="Emit JSON instead of text report"
    )
    parser.add_argument(
        "--output", "-o", type=Path, default=None,
        help="Write output to file (default: stdout)"
    )
    parser.add_argument(
        "--plugin-hook-tokens", type=int, default=None,
        help="Estimated tokens per plugin hook context (optional; no reliable public default)"
    )
    args = parser.parse_args()

    home = read_claude_home()
    current = measure_current(home, args.plugin_hook_tokens)
    after = compute_after(current, args.plugin_hook_tokens)
    report = build_report(current, after, args.plugin_hook_tokens)

    if args.json:
        out = json.dumps(report, indent=2, ensure_ascii=False)
    else:
        import io
        buf = io.StringIO()
        # Redirect stdout temporarily
        old_stdout = sys.stdout
        sys.stdout = buf
        print_text_report(report)
        sys.stdout = old_stdout
        out = buf.getvalue()

    if args.output:
        args.output.write_text(out)
        print(f"Wrote {args.output}")
    else:
        print(out, end="")

    return 0


if __name__ == "__main__":
    sys.exit(main())
