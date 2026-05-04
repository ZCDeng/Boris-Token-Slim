# Boris-Token-Slim

> Cut the invisible tax Claude Code pays before every prompt.
> 砍掉 Claude Code 每次请求前的隐性税。

A Claude Code [skill](https://docs.claude.com/en/docs/claude-code/skills) that audits and trims the hidden overhead in your `~/.claude/` setup — bloated `CLAUDE.md`, stale `MEMORY.md`, plugin explosion, always-on MCP servers, dead symlinks, and the `scientific-skills` 142-pack that everyone installs and never uses.

Inspired by [this article](https://youmind.com/s/MieRjYvn3NFzLd) which proxy-logged 430 hours of Claude Code and found **73% of tokens were waste**. Extended with four real-world gotchas the article doesn't mention (most notably: `commands/_archive/` still gets scanned by the harness, so moving stuff there makes names *longer*).

## Install

### Option A: Use as a Claude Code skill

```bash
git clone https://github.com/ZCDeng/Boris-Token-Slim.git ~/projects/Boris-Token-Slim
ln -s ~/projects/Boris-Token-Slim ~/.claude/skills/Boris-Token-Slim
chmod +x ~/projects/Boris-Token-Slim/scripts/*.sh
```

Then in Claude Code: `/Boris-Token-Slim` or just say "优化我的 Claude Code token 消耗" / "audit my Claude Code overhead".

### Option B: Just run the audit script

```bash
bash ~/projects/Boris-Token-Slim/scripts/audit.sh
```

Outputs a dashboard of your current overhead vs. recommended thresholds. No changes made.

## What it audits

| # | Pattern | Threshold |
|---|---------|-----------|
| 1 | `CLAUDE.md` bytes | < 1500 |
| 2 | `MEMORY.md` bytes | < 2000 |
| 2a | Extra `.md` files in memory dir | < 15 |
| 3 | Installed plugins | < 15 |
| 3a | Duplicate plugin names (same name, different marketplace) | 0 |
| 4 | MCP servers (user + project scope) | < 6 |
| 5 | Skills in `~/.claude/skills/` | < 50 |
| 5a | Dead symlinks (broken) | 0 |
| 6 | Big packs in `~/.claude/commands/` (like `scientific-skills`) | 0 |
| 7 | Active `settings.json` hooks | < 3 |

## What it does (interactive, safe)

When invoked inside Claude Code, the skill walks you through 4-5 cleanup phases:

1. **Plugin cleanup** (highest ROI) — categorical prompts (keep/remove financial suite, HuggingFace sub-plugins, duplicates, etc.)
2. **MEMORY.md index-ification** — archive stale project state snapshots, keep only feedback/reference entries
3. **CLAUDE.md slim** — strip Anthropic-blog boilerplate, dead-module configs, redundant skill triggers
4. **MCP server audit** — move low-frequency MCPs off the always-on list
5. **Skill audit** *(requires restart)* — clean dead symlinks, archive big packs, categorical culling

## Three iron rules

1. **Archive, never delete.** Everything goes to `~/.claude/_tokenslim_archive_<YYYYMMDD>/`. If you regret a choice, `mv` it back.
2. **Don't use `~/.claude/skills/_archive/` or `~/.claude/commands/_archive/`.** The harness scans those. Archive root must be *outside* `skills/` and `commands/`.
3. **Restart between sessions.** Claude Code snapshots the skill list at session start. Cleanup mid-session won't show up until `/exit` → reopen.

## Unique gotchas this skill handles (not in original article)

- **Dead symlinks** — 81 of 221 skills on the author's machine pointed to `~/.claude/.agents/skills/*`, which had been deleted. They still occupied slots in the skill list. See `references/gotchas.md`.
- **`commands/_archive/` trap** — moving 142 `scientific-skills` into `~/.claude/commands/_archive/` made the names *longer* (prefixed with `_archive:`). They must leave `commands/` entirely.
- **Sub-plugin explosion** — `huggingface-skills` installs 8 siblings; `financial-services-plugins` installs 7. Audit strategy: keep the umbrella entry, remove siblings.
- **Same-name plugin installed twice** — across different marketplaces. Easy to miss, shows up as `homunculus@homunculus` + `homunculus@humanplane`.
- **MCP in project scope** — `claude mcp list` shows all, but `~/.claude.json` root only shows user-scope ones. Project-scope MCPs for `/Users/$USER` still activate silently.

## Sample audit output

```
╔══════════════════════════════════════════════════════════════╗
║         Boris-Token-Slim  ·  Claude Code Overhead Audit      ║
╚══════════════════════════════════════════════════════════════╝

Metric                              Value        Target       Status
─────────────────────────────────── ──────────── ──────────── ──────────
1. CLAUDE.md bytes                  6948         < 1500        ⚠️ over
2. MEMORY.md bytes                  6818         < 2000        ⚠️ over
   Extra .md files in memory dir    36           < 15          ⚠️ over
3. Installed plugins                55           < 15          ⚠️ over
   Duplicate plugin names           1            0             ⚠️ over
4. MCP servers (user scope)         2            < 4           ✅ ok
   MCP total                        6            < 6           ⚠️ over
5. Skills in ~/.claude/skills/      221          < 50          ⚠️ over
   Dead symlinks (broken)           81           0             ⚠️ over
6. Big packs in ~/.claude/commands/ 1            0             ⚠️ over
7. Active settings.json hooks       0            < 3           ✅ ok

Recommendations:
  • CLAUDE.md 超标：删 Anthropic 博客最佳实践照搬段、废弃模块配置、skill 触发说明
  • MEMORY.md 超标：归档已完成项目状态快照，只留 feedback/reference
  • ...
```

## Before / after (author's machine)

| Metric | Before | After | Δ |
|--------|--------|-------|---|
| `CLAUDE.md` | 6948 B | 1174 B | **-83%** |
| `MEMORY.md` | 6818 B | 1431 B | **-79%** |
| Plugins | 55 | 25 | **-55%** |
| MCP (always-on) | 6 | 4 | -2 |
| Skill list (local + scientific) | 363 | 103 | **-72%** |

~8000-10000 tokens reclaimed per prompt baseline.

## Habits this skill can't enforce

The article also recommends three behavioral habits this skill won't do for you:
- **Default Extended Thinking OFF.** Turn on with `Alt+T` only when needed.
- **When output drifts, `Cmd+.` / double-Esc immediately.** Don't let it finish 400 wrong lines.
- **At 20 messages, `/compact`.** Not `/clear`. Long conversations tax every turn with the full history.

## License

MIT — see `LICENSE`.

## Contributing

PRs welcome. Especially:
- Additional gotchas you've hit on your own machine
- Audit metrics the script currently misses
- Localization (non-中文 prompt text)

Report token-waste patterns with reproducible evidence (proxy log excerpts, `ls` output, config snippets). Keep recommendations conservative — default to "archive", never "delete".
