# Contributing to Boris-Token-Slim

Thanks for considering a contribution. The bar is low — a useful gotcha report is as valuable as code.

## What we want

| Type | Examples |
|---|---|
| **New gotcha** | A real overhead pattern you hit on your own machine that audit.sh didn't catch. Include reproducer (`ls` output, config snippet, plugin name) |
| **New detector** | A scripts/audit.sh detector for an existing or new gotcha. Must print actionable evidence (path, name, line number) — not just a count |
| **Bug fix** | Anything from the Top-3 list that opens up after a code review |
| **Docs** | Localization, clearer pricing notes, methodology corrections |
| **Test** | More fixtures for `tests/test_analyze.py`. Especially edge cases (compact events, sub-agent transcripts, mid-turn errors) |

## What we don't want

- Hooks / plugins / runtime-resident code. The whole pitch is "zero hooks". A hook-based feature is a different project (and Token Optimizer already does it well — see README).
- Auto-delete logic. Iron rule #1 is "archive, never delete". Anything that calls `rm -rf` on user data needs a very strong justification and an opt-in flag.
- Dependencies. `analyze.py` is stdlib-only on purpose. `audit.sh` shells out to `python3` for JSON parsing only. Adding `requests` / `pandas` / etc. is a no-go.

## Local dev workflow

```bash
git clone https://github.com/ZCDeng/Boris-Token-Slim.git
cd Boris-Token-Slim

# Lint shell
bash -n scripts/audit.sh
bash -n scripts/archive-helper.sh
shellcheck --severity=error scripts/*.sh   # optional but recommended

# Lint python
python3 -m compileall scripts/ tests/

# Run tests
pip install pytest
python3 -m pytest tests/ -v

# Smoke run audit on a fake CLAUDE_HOME (won't touch your real config)
mkdir -p /tmp/fake-claude/{skills,commands,plugins}
echo "" > /tmp/fake-claude/CLAUDE.md
echo '{"plugins":{}}' > /tmp/fake-claude/plugins/installed_plugins.json
CLAUDE_HOME=/tmp/fake-claude bash scripts/audit.sh
```

## Adding a new gotcha detector

Two-step process:

1. **Document the gotcha** in `references/gotchas.md`. Include:
   - **Symptom** (what the user observes)
   - **Root cause** (why it happens — Claude Code internals, plugin behavior, OS quirk)
   - **Detection command** (the one-liner the user could've run themselves)
   - **Fix** (specific commands, not vague advice)

2. **Add the detector** in `scripts/audit.sh` Layer 2:
   - New section `# ---------- Gotcha N: short title ----------`
   - Print **locatable evidence** with `print_finding`. Show paths, plugin names, line numbers. Not "you have N items" — show *which* N items.
   - Cross-reference install state when relevant (e.g. installed vs cache-residue)
   - Update the count in the header (`Fifteen gotcha detectors` → `Sixteen ...`) and the closing `(All fifteen detectors clean.)` line in `audit.sh`
   - Update README detector table

## Adding a fixture for `analyze.py`

`tests/fixtures/*.jsonl` are partial Claude Code session transcripts. To add one:

1. Find a real session transcript that exhibits the edge case (corrupt lines, compact events, etc.)
2. **Strip PII** — replace user content with placeholder text, redact paths if sensitive
3. **Keep the `usage` field intact** — that's what we test against
4. Add a test in `tests/test_analyze.py` that asserts the expected aggregate behavior

## PR conventions

- Branch from `main`, target `main`
- One logical change per PR. If you add a detector, don't also reformat unrelated code.
- Commit message format: `<area>: <imperative>` — e.g. `feat(audit): detect plugin sub-skill bundles`
- Branch protection requires 1 approval before merge. The repo owner usually approves within a day.
- Tests must pass on Python 3.10/3.11/3.12 (CI matrix).

## Reporting issues without code

Open a GitHub issue with:
- What overhead pattern you observed
- What `audit.sh` / `analyze.py` reported (or didn't)
- Output of the reproducer (`ls -la ~/.claude/skills/ | head`, etc.)

Issues that surface a real new pattern are how the gotcha catalog grows. A reproducible report counts as much as a PR — the detector can come later.

## Code of conduct

Be useful, be specific, don't grandstand. We're here to cut tokens, not signal virtue.
