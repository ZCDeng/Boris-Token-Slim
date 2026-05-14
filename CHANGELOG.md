# Changelog

All notable changes to Boris-Token-Slim will be documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Detector 15 — Cache-prefix poisoning**: static scan of `CLAUDE.md` / `MEMORY.md` / `memory/*.md` for per-session volatile content (today's date markers, `# currentDate` headings, `Last updated:` stamps, `Generated at` stamps, `Recent N observations` auto-injection, Chinese equivalents `当前日期` / `今天日期` / `更新于`). Anthropic prompt caching hashes the entire block by content — any byte that mutates per session invalidates the cache → you pay full input (1.0x) instead of cache read (0.1x) on the whole file on every session start. The detector reports each match with file path + line number + matched pattern, plus a `$/month` projection (bytes → tokens at ~4:1, 90 session starts/month, Sonnet input pricing × 0.9 cache-miss penalty) so users see the dollar impact directly. Volatility phrasing is matched strictly — bare ISO dates in version markers ("as of 2026-04") or changelog citations do *not* trigger the detector.
- **`Scope & non-scope` section in `references/methodology.md`**: explicit table of what Boris audits (static baseline + retrospective session parsing) vs. what it deliberately does NOT (output-side compression, tool-result body size, model routing, speculative file inclusion). Names the adjacent tools (rtk / caveman / claude-code-router / ccusage / Claude-Code-Usage-Monitor) so users know where to look for the complementary lanes.
- **`tests/test_detector_15.py`**: 6 end-to-end tests that subprocess `audit.sh` against synthetic `CLAUDE_HOME` directories — clean prefix should not fire, poisoned prefix should fire, cost projection appears, and bare ISO dates in prose do not trigger false positives.

### Why this matters

Cache-prefix poisoning is a single-line bug with a 10x cost multiplier. A `# currentDate\nToday's date is 2026-05-14.` block injected by a hook into the user's global `CLAUDE.md` invalidates the entire file's cache prefix — meaning a 5KB `CLAUDE.md` that should cost ~$0.015/month at cached prices instead costs ~$0.15/month at full input prices, just for the daily session starts. The fix is trivial (move the volatile lines to a UserPromptSubmit hook that injects into the user message instead of CLAUDE.md), but the diagnosis was invisible to the previous 14 detectors. Inspiration: Ronin (@DeRonin_) "How To Cut Your AI Coding Bill by 80%" — leak #1 (stable context re-sent every turn) combined with the prompt-cache 10x discount is the dominant fixable waste vector. The scope section makes Boris's complementary role explicit: it audits the cacheable baseline, other tools handle output/routing/runtime.

## [v0.3.0] — 2026-05-09

### Added

- **Three new audit detectors** for skill manifest bloat — the previously-invisible Pattern 1 sub-mode where every enabled skill's `description` field loads into every session's system-reminder:
  - **Detector 12 — Oversized skill descriptions**: lists skills whose `description` exceeds 300 chars (~75 tokens each) with the top 8 offenders by char count and a total-tokens-per-session estimate.
  - **Detector 13 — YAML pitfalls in descriptions**: pattern-matches three write-styles that silently break strict YAML parsers — leading-quote truncation (`description: "foo"bar`), mid-line capitalized English colons (`Triggers:` / `Examples:` / `Note:` triggering "mapping values are not allowed here"), and block scalars (`description: |`) that add hidden newlines. Catches descriptions that look fine in Claude Code's permissive parser but lose their content under PyYAML.
  - **Detector 14 — Orphan slash-menu whitelist entries**: cross-references `~/.claude/user-invocable-skills.json` against actual skill directory presence to find entries pointing at archived/deleted skills (cause `/` menu invocation errors).
- **Skill description slimming methodology** (`references/skill-description-slimming.md`): enumerate-and-rank script, length-based action table (>400c must-fix → <150c leave-alone), compression rules (preserve one-liner + 2–3 trigger phrases; strip exhaustive feature lists / bilingual duplicates / implementation detail), and a batch rewriter that handles symlinks. Real-machine case: 43 skills, 8500c → 2800c (-67%, ~2000 tokens saved per session).
- **`SKILL.md` Phase 3 expansion**: two new sub-steps in skill-audit phase — audit & compress descriptions, and prune `user-invocable-skills.json` of orphaned entries.
- **Gotchas 10 & 11 in `references/gotchas.md`**: YAML pitfalls catalog (10) and slash-menu whitelist orphan pattern (11) with a Python cleanup script.
- **CI smoke fixtures** for detectors 12, 13, 14 — the smoke-audit job now seeds an oversized description, a colon-trap description, and an orphan whitelist entry, then asserts each detector fires.
- **`.gitignore`**: ignore `.claude/` runtime state (e.g. `homunculus/observations.jsonl`) so local plugin state never leaks into commits.

### Why this matters

Skill description bloat is a Pattern 1 sub-mode that the byte counters don't catch — they look at `CLAUDE.md` / `MEMORY.md`, not the skill manifest descriptions injected by the harness. For a 30+ skill setup it's commonly the largest *unaccounted* per-session cost. The YAML pitfalls make it self-perpetuating: descriptions look intact but their semantic boundary is broken, so future tooling can't validate them. v0.3.0 turns the methodology shipped as docs in v0.2.x into automated detectors with locatable evidence — the same contract as detectors 1-11.

### Trust

- Tarball sha256: `66b6a63d33c964748a27971beb4dca0bda3bf2c182a05c78b356bb26eaab0193` (loader/payload split — tarball excludes install.sh/uninstall.sh)
- analyze.py sha256: unchanged from v0.2.0 (no behavior changes)

## [v0.2.0] — 2026-05-07

### Added

- **`--headline` flag**: `python3 scripts/analyze.py --headline` emits a 1-line fact-driven summary (cost / cache hit rate / zero-call MCP servers / duplicate-read tokens). Ledger written to `~/.boris-stats/history.jsonl` (0600 permissions). `BORIS_STATS_DISABLE=1` skips the ledger for read-only use.
- **audit.sh headline integration**: Daily `bash scripts/audit.sh` now shows the headline between the banner and Part 1 (silent-fail if analyze.py is missing or `~/.claude/projects/` is empty).
- **`scripts/headline-only.sh`**: One-command curl-pipe to see YOUR Claude Code stats. Pinned to immutable v0.2.0 tag + sha256-verified. Git primary path with curl/wget single-file fallback. Read-only (never writes ledger).
- **`scripts/install.sh`**: Trust-on-first-use install script. Detects 5 agents (Claude Code / Cursor / Windsurf / Codex / Gemini CLI) via caveman hybrid pattern. Git clone primary + wget/curl tarball fallback with sha256 verification. `--dry-run` support. Idempotent reinstall. Honest-bail for non-CC users with GitHub Issues link. Cleanup-on-fail trap covers post-mv state.
- **`scripts/uninstall.sh`**: Clean removal of install.sh-created files (symlink + clone path). Never touches `~/.boris-stats/` ledger. Supports curl-pipe and `--dry-run`.
- **Zero-estimation duplicate-read tracking**: `analyze_file` attributes real input growth between assistant turns to prior-turn reads (proportional delta), replacing the dashboard's `count × 600` heuristic for headline output.
- **`PROJECTS_ROOT` reads `CLAUDE_HOME` env**: Consistent with audit.sh contract. CI fixture and local behavior unified.
- **README expansion**: Banner author headline pull-quote (real data, ≤200 chars). "30-second test" chapter with curl-pipe command + F9 "what these numbers mean for you" bullet block (Chinese + English). Install/Uninstall sections with curl-pipe commands and transparency table.
- **CI**: `smoke-install` job covers install.sh detection + `--dry-run` + honest-bail + no-agent fallback + uninstall.sh. `smoke-audit` verifies headline token. Shellcheck + bash -n extended to all new scripts.

### Trust

- Tarball sha256: `91f24a21be3cd698c309371e8a257dd9ec14a2d8242252010fc7c65af0853e92` (loader/payload split — tarball excludes install.sh/uninstall.sh)
- analyze.py sha256: `4a3297cf0cc7a436cc663bf9dfeb00635dd98f71000740dffad48eb48e9802a3`
- Both hashes verified client-side before execution. Release asset uploaded via `gh release create`.

### Compared to / inspired by

- [`juliusbrussee/caveman`](https://github.com/juliusbrussee/caveman) (54K stars) — install.sh + headline pattern. Cross-pollination ideation in `~/docs/ideation/2026-05-05-boris-token-slim-caveman-cross-pollination-ideation.md`.
- Planning artifacts: `~/docs/plans/2026-05-06-001-feat-boris-stats-headline-plan.md` (S1), `~/docs/plans/2026-05-07-001-feat-install-sh-multi-agent-plan.md` (S2), `~/docs/plans/2026-05-06-002-meta-v0.2.0-ship-plan.md` (meta).

## [v0.1.0] — 2026-05-06

First tagged release. Repo went from initial commit to feature-complete in 48 hours; this tag captures a known-good baseline for users who want to pin.

### Added

- **8 static metrics** in `audit.sh`: CLAUDE.md bytes (incl. `@-import` expansion), MEMORY.md bytes, plugin count, MCP servers (user + project scope), local skills, big-pack detection in `~/.claude/commands/`, active settings hooks, `BASH_MAX_OUTPUT_LENGTH` cap.
- **11 gotcha detectors** in `audit.sh` with locatable evidence (paths, names, install state):
  1. Dead symlinks under `~/.claude/skills/`
  2. `_archive` trap — archives placed inside `commands/` or `skills/` (still scanned by harness)
  3. Sub-plugin explosion — plugin family clusters with ≥4 siblings
  4. Same-name plugin installed from multiple marketplaces
  5. Project-scope MCP servers hidden in `~/.claude.json::projects`
  6. Zombie configs — `CLAUDE.md` references modules `MEMORY` says are removed
  7. MCP zombie resurrection — plugins that auto-register MCPs
  8. Plugin sub-skill bundles — including cache-residue from uninstalled plugins
  9. Configured-but-uncalled MCP servers (codeburn-inspired)
  10. Junk reads into build/dependency directories (codeburn-inspired)
  11. Duplicate file reads within a single session (codeburn-inspired)
- **Retrospective transcript analyzer** (`scripts/analyze.py`):
  - Parses `~/.claude/projects/**/*.jsonl` with stdlib only.
  - Per-turn pricing using each message's actual model (Sonnet/Opus/Haiku/unknown→Sonnet+stderr warning).
  - Cache hit rate, 5m vs 1h TTL ratio, top-N expensive sessions, Pattern 2/4 risk flags.
  - Counterfactual savings using blended input price (no longer hardcoded to Sonnet).
  - Authoritative since-filter by transcript timestamp, not file mtime — long sessions resumed today don't pollute `--days 7` reports.
  - `--json` mode (schema `boris-token-slim/transcript-analyzer/v2`) with `mcp_usage`, `junk_reads`, `duplicate_reads` segments for downstream consumers.
- **Archive helper** (`scripts/archive-helper.sh`): mv-based archive operations + `clean-dead` symlink command.
- **Tests**: 18 pytest cases covering price tiers, message-level filtering, parser corner cases, cache rate math.
- **CI**: GitHub Actions workflow with shellcheck (errors), Python compile + pytest matrix (3.10/3.11/3.12), audit smoke against fixture `CLAUDE_HOME`.
- **OSS infrastructure**: `CONTRIBUTING.md`, `SECURITY.md` ("never `rm -rf`" promise), MIT `LICENSE`.

### Discovered (gotchas catalog)

These were found while cleaning author's own Claude Code; not in the original 9-pattern article that inspired this work:

- Dead symlinks under `~/.claude/skills/` pointing to `~/.claude/.agents/skills/` (deleted directory).
- `commands/_archive/` trap — moving items inside still gets them scanned with longer prefixed names.
- Sub-plugin explosion — `huggingface-skills` ships 8 sibling plugins; financial-services-plugins ship 7.
- Same-name plugin from different marketplaces (e.g. `homunculus@homunculus` vs `homunculus@humanplane`).
- MCP servers in project scope `~/.claude.json::projects[*].mcpServers` — invisible to user-scope `claude mcp remove` from other dirs.
- MCP zombie resurrection — plugins re-register MCPs you removed via `claude mcp remove`.
- Plugin sub-skill bundles — caches under `~/.claude/plugins/cache/` linger after `claude plugin uninstall` removes the JSON entry.

### Compared to / inspired by

- Article: ["I tracked 430 hours of Claude Code usage. 73% was wasted on these 9 patterns."](https://youmind.com/s/MieRjYvn3NFzLd) by [@Mnilax / Mnimiy](https://x.com/i/status/2050321700802408552), citing the 9-pattern framework attributed to Boris Cherny.
- [`alexgreensh/token-optimizer`](https://github.com/alexgreensh/token-optimizer) — leading live monitoring tool. Boris-Token-Slim is the audit-and-clean complement.
- [`getagentseal/codeburn`](https://github.com/getagentseal/codeburn) — cross-tool TUI dashboard for cost observability. Boris-Token-Slim borrowed the core analytical patterns: detector 9 (uncalled MCP), detector 10 (junk reads), detector 11 (duplicate reads), and the `BASH_MAX_OUTPUT_LENGTH` static metric. CodeBurn observes the input across many tools; Boris-Token-Slim audits-and-cleans for Claude Code specifically.
- [`juliusbrussee/caveman`](https://github.com/juliusbrussee/caveman) — orthogonal output-token compression project. Cross-pollination ideation captured in `~/docs/ideation/2026-05-05-boris-token-slim-caveman-cross-pollination-ideation.md`.

### Notes

- Real-machine data point (author's own setup, 30 days): API-equivalent cost estimate $15,981; cache hit 95.9%; 3 of 4 configured MCP servers had zero calls (~1800 tokens/request of pure tax); `BASH_MAX_OUTPUT_LENGTH` defaulted to 30K and was reduced to 15K (~3,750 tokens saved per bash call).
- Iron rule across the project: **archive, never delete**. All cleanup operations move to `~/.claude/_tokenslim_archive_<YYYYMMDD>/` so users can `mv` back if they regret.

[v0.1.0]: https://github.com/ZCDeng/Boris-Token-Slim/releases/tag/v0.1.0

[v0.3.0]: https://github.com/ZCDeng/Boris-Token-Slim/releases/tag/v0.3.0
[v0.2.0]: https://github.com/ZCDeng/Boris-Token-Slim/releases/tag/v0.2.0
