# Boris-Token-Slim

> Cut the invisible tax Claude Code pays before every prompt.
> 砍掉 Claude Code 每次请求前的隐性税。

A Claude Code [skill](https://docs.claude.com/en/docs/claude-code/skills) that audits and trims the hidden overhead in your `~/.claude/` setup — bloated `CLAUDE.md`, stale `MEMORY.md`, plugin explosion, always-on MCP servers, dead symlinks, and the `scientific-skills` 142-pack that everyone installs and never uses.

> **Boris Cherny, the creator of Claude Code at Anthropic, just listed 9 patterns that waste 73% of your tokens.**
>
> *— [@Mnilax, on X](https://x.com/i/status/2050321700802408552) · 5.5K likes*

Boris Cherny (Claude Code's creator) first surfaced the **9-pattern framework** on a podcast; [@Mnilax / Mnimiy](https://youmind.com/s/MieRjYvn3NFzLd) then instrumented **430 hours** of his own Claude Code usage with an HTTP proxy and put hard percentages on each pattern — **73% of all tokens were waste**, 27% productive. This skill operationalizes both: the 9 categories + 7 additional gotchas the author hit cleaning his own machine (most notably: `commands/_archive/` still gets scanned by the harness, so moving stuff there makes names *longer*).

---

## 中文介绍

> **Boris Cherny——Anthropic 的 Claude Code 作者——在一期 podcast 里列出了 9 种浪费你 73% token 的模式。**
>
> *— [@Mnilax 在 X 的推文](https://x.com/i/status/2050321700802408552) · 5490 赞*

Boris Cherny（Claude Code 作者）先在 podcast 里提出**9 模式分类框架**；[@Mnilax（Mnimiy）](https://youmind.com/s/MieRjYvn3NFzLd) 随后用 HTTP proxy 拦截了自己 **430 小时**、6M tokens、\$1340 的 Claude Code 流量，给每条模式打上硬数据——真正回答你问题的 productive token 只占 **27%**，剩下 **73% 花在你看不见的 9 个地方**。

- 你还没打一个字，**~14%** 额度已经花在加载 `CLAUDE.md` 上
- 对话到第 30 条，每条都在重读前面 29 条——**~13%** 全是重读
- 装了 4 个插件你早忘了的，每次请求先注入 **~11%** 的 hook 上下文
- 12 个 MCP 常驻，每个每次都送 tool schema——**~6%** 的税
- 221 个 skill 清单占位，其中 81 个 symlink 指向已被删目录（本 skill 作者实测）
- 你抱怨 "Claude 变笨了"——绝大多数时候不是模型退化，是你的 overhead 长了

**如果你每周撞 Max 额度超过一次，你至少中了 4 条，大概率 7 条。**

---

### 这个 skill 做什么

一键扫 `~/.claude/` 给 9 项指标诊断表，然后**交互式**引导你清理（**不是自动删**）：

| 指标 | 阈值 | 常见超标原因 |
|------|------|------|
| `CLAUDE.md` | < 1500 字节 | 照搬 Anthropic 博客最佳实践、已废弃模块的配置仍在加载 |
| `MEMORY.md` | < 2000 字节 | 把"当前项目状态"写进去，过期即垃圾 |
| 插件数 | < 15 | 金融套件 7 件套、HuggingFace 8 子件、同名插件不同市场装两次 |
| MCP 常驻 | < 6 | `task-master-ai` 和 harness 内置 TaskCreate 重复、低频 MCP 常驻 |
| Skill 数 | < 50 | scientific-skills 142 包一次性挂载、死 symlink 占清单位置 |
| 死 symlink | = 0 | 指向 `~/.claude/.agents/skills/*` 等已删目录的僵尸链接 |

### 独有的 7 个坑（原文没提）

1. **`commands/_archive/` 陷阱**——挪进去名字反而更长（被前缀成 `_archive:xxx:yyy`），必须挪出 `commands/` 目录才真正隔离
2. **死 symlink 占位**——81 个指向不存在目录的 symlink 仍在 skill 清单里（作者实测）
3. **Sub-plugin 爆炸**——装 `huggingface-skills` 出来 8 个兄弟插件，每个独立占 hook 预算
4. **同名 plugin 装两次**——同一 plugin 被多个 marketplace 收录，不小心装了两份
5. **MCP 藏在 project scope**——`claude mcp list` 显示 6 个，`~/.claude.json` 根下只有 2 个，剩下在 `projects[<path>].mcpServers` 里悄悄激活
6. **重启才能看到真实 skill 清单**——Claude Code 只在 session 启动时扫 skill，清理后的变化当前 session 看不到
7. **僵尸配置**——`MEMORY.md` 写着"2026-04-XX 已移除 XX 模块"，但 `CLAUDE.md` 里那个模块的 3 段配置还在每轮加载

### 铁律：归档不删除

所有动作都 `mv` 到 `~/.claude/_tokenslim_archive_<YYYYMMDD>/`，反悔能 `mv` 回来。

### 30 秒体验

只看报告不做修改：
```bash
git clone https://github.com/ZCDeng/Boris-Token-Slim.git
bash Boris-Token-Slim/scripts/audit.sh
```

接入 Claude Code 做交互清理：
```bash
ln -s "$(pwd)/Boris-Token-Slim" ~/.claude/skills/Boris-Token-Slim
# Claude Code 里说："/Boris-Token-Slim" 或 "审计我的 claude code token 消耗"
```

作者本机实测：`CLAUDE.md -83% / MEMORY.md -79% / 插件 -55% / skill 清单 -72%`，每轮请求基线回收 ~8000-10000 tokens。

---

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

### Option C: Retrospective transcript analysis (no Claude needed)

```bash
python3 ~/projects/Boris-Token-Slim/scripts/analyze.py --days 30
```

Parses every Claude Code session transcript in `~/.claude/projects/` and gives you:

- Total cost estimate (using Anthropic's published pricing × the `usage` field Claude Code already records)
- Cache hit rate, 5m vs 1h TTL ratio
- Top N most expensive sessions
- Pattern 2 risk: sessions ≥ 30 turns
- Pattern 4 risk: sessions with cache hit < 50%
- Counterfactual: how much you'd save if cache hit reached 85%

`--json` mode emits stable schema for CI / cron pipelines. See [`references/methodology.md`](references/methodology.md) for the math.

---

## How this compares to Token Optimizer

[`alexgreensh/token-optimizer`](https://github.com/alexgreensh/token-optimizer) is the leading live monitoring tool in this space (12 hooks, live dashboard, Smart Compaction). This skill takes a complementary approach:

| | Token Optimizer | Boris-Token-Slim |
|---|---|---|
| **Mode** | Live monitoring | Audit + retrospective analysis |
| **Architecture** | 12 hooks (PreTool, PostTool, SessionStart, PreCompact, …) | Zero hooks. Pure scripts. |
| **Self-overhead** | Each Read/Bash/Edit/Agent triggers a Python launcher | None |
| **Time window** | Since install | All sessions ever recorded |
| **Detection style** | Token counters & dashboards | Locatable evidence (paths, line numbers, install state) |
| **License** | PolyForm-Noncommercial | MIT |
| **Best for** | Continuous live coaching | Quarterly cleanup, post-restart audit, one-time reset |

Use both. Token Optimizer is your dashboard. Boris-Token-Slim is your annual physical.

## What it audits

| # | Pattern | Threshold |
|---|---------|-----------|
| 1 | `CLAUDE.md` bytes | < 1500 |
| 2 | `MEMORY.md` bytes | < 2000 |
| 2a | Extra `.md` files in memory dir | < 15 |
| 3 | Installed plugins | < 15 |
| 4 | MCP servers (user + project scope) | < 6 |
| 5 | Skills in `~/.claude/skills/` | < 50 |
| 6 | Big packs in `~/.claude/commands/` (like `scientific-skills`) | 0 |
| 7 | Active `settings.json` hooks | < 3 |

Plus **9 gotcha detectors** that print actionable evidence (paths, names, line numbers):

| # | Detector | What it finds |
|---|----------|---------------|
| 1 | Dead symlinks | Broken `~/.claude/skills/*` symlinks (e.g. pointing to deleted `.agents/skills/`) |
| 2 | `_archive` trap | Archive dirs *inside* `commands/` or `skills/` (still scanned by harness) |
| 3 | Sub-plugin explosion | Plugin family clusters with ≥4 siblings (e.g. `hugging-face-*`) |
| 4 | Same-name plugin | Same bare name installed from multiple marketplaces |
| 5 | Project-scope MCP | MCPs hidden in `~/.claude.json::projects[*].mcpServers` |
| 6 | Zombie configs | `CLAUDE.md` references modules `MEMORY` says are removed |
| 7 | Archive layout | Archives in `_archive/` instead of `~/.claude/_*_archive/` |
| 8 | MCP zombie resurrection | Plugins that auto-register MCPs (so `claude mcp remove` is reverted on restart) |
| 9 | Plugin sub-skill bundles | Plugins shipping ≥5 `SKILL.md` files; **distinguishes installed vs cache-residue** |

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
