# S4 Eval Harness — Counterfactual Token Audit

> **Why this exists:** Boris-Token-Slim's core claim is "reduces input-token overhead." Caveman got 54K stars with a "65% output reduction" headline backed by a 3-arm eval. We need our equivalent — but Boris audits **input** overhead (system context), not output. A 3-arm API re-run doesn't add information here because savings are **configuration-fixed** (same per-request tax regardless of prompt). This harness measures that directly.

## Method

**Configuration analysis** — no API calls, no cost, fully reproducible.

Measures five components of per-request structural overhead from the user's `~/.claude/` configuration:

| Component | Measurement | Threshold | Counterfactual |
|-----------|-------------|-----------|----------------|
| `CLAUDE.md` | Exact bytes | < 1500 B | Cap at 1500 B |
| `MEMORY.md` | Exact bytes | < 2000 B | Cap at 2000 B |
| Skill descriptions | Exact chars per `description` field | < 300 c | Compress oversized to ~150 c |
| MCP servers | Count (from `~/.claude.json`) | < 6 | Cap at 6 × 600 tokens |
| Plugins | Count (from `installed_plugins.json`) | < 15 | Cap at 15 |

### Honesty contract

- **Measured** (exact): CLAUDE.md, MEMORY.md, skill descriptions — all from file-system byte counts.
- **Estimated** (flagged): MCP schema size (600 tokens/server, codeburn empirical). Plugin hook context **not auto-estimated** — no reliable public data. Pass `--plugin-hook-tokens N` to include your own measurement.

## Usage

```bash
# Text report (default)
python3 scripts/eval.py

# JSON output
python3 scripts/eval.py --json

# With user-supplied plugin hook estimate
python3 scripts/eval.py --plugin-hook-tokens 200

# Save to file
python3 scripts/eval.py --json -o evals/result-$(date +%Y%m%d).json
```

## Output format

### Text report

```
─ Measured components (exact) ────────────────────────────────────────
  CLAUDE.md            6948c  →   1985t  |  after:   1500c  →    428t
  MEMORY.md            6818c  →   1948t  |  after:   2000c  →    571t
  Skill descriptions   8500c  →   2428t  |  after:   3400c  →    971t
    (43 skills, 12 oversized)

  Measured subtotal:  6361t  →  1970t  (save 4391t, 69.0%)

─ Estimated components ───────────────────────────────────────────────
  MCP servers           6  →  ~ 3600t  |  after:   4  →  ~ 2400t
  Plugins              25  |  after:  15

  With estimates:     9961t  →  4370t  (save 5591t, 56.1%)
```

### JSON schema

```json
{
  "generated_at": "2026-05-09T10:00:00Z",
  "method": "configuration-analysis",
  "notes": ["..."],
  "current": { "claude_md": {...}, "memory_md": {...}, "skill_descriptions": {...}, "mcp": {...}, "plugins": {...} },
  "after_boris": { "claude_md": {...}, "memory_md": {...}, "skill_descriptions": {...}, "mcp": {...}, "plugins": {...} },
  "measured_only": { "current_tokens": 6361, "after_tokens": 1970, "saved_tokens": 4391, "saved_percent": 69.0 },
  "with_estimates": { "current_tokens": 9961, "after_tokens": 4370, "saved_tokens": 5591, "saved_percent": 56.1 }
}
```

## Why no 3-arm API re-run?

Caveman's 65% number came from re-running the **same prompts** with/without caveman compression and measuring output-token differences. That makes sense because output depends on prompt.

Boris saves **input** tokens — specifically, the fixed system context injected before every request (`CLAUDE.md`, `MEMORY.md`, skill descriptions, MCP schemas). These are:
1. **Identical on every request** within a session
2. **Independent of the user prompt**
3. **Measurable from file system** without calling the API

Re-running 20 prompts through the API with different system contexts would give the *same* per-request delta as simply counting the bytes and dividing by chars-per-token. The API call adds noise (caching, model variation) without adding signal.

## Limitations

- **Plugin hook context**: Not included in default output. If you instrument your setup and find a per-plugin hook size, pass `--plugin-hook-tokens N`.
- **Chars-per-token**: Uses a blended 3.5 chars/token. CJK-heavy configs may underestimate; English-heavy may overestimate. The error is consistent across current/after so the *percentage* remains accurate.
- **Assumes threshold compliance**: The "after" state assumes the user fully applies all Boris thresholds. Real-world savings depend on which recommendations the user actually follows.

## CI integration

The eval.py smoke test runs on every PR (see `.github/workflows/ci.yml`):
```bash
python3 scripts/eval.py --json > /tmp/eval-smoke.json
python3 -c "import json; d=json.load(open('/tmp/eval-smoke.json')); assert 'measured_only' in d"
```

## History

- **v0.3.0**: Initial eval harness (S4 from cross-pollination ideation). Replaces the hypothetical "20-session 3-arm API eval" with a configuration-analysis approach that's honest, free, and reproducible.
