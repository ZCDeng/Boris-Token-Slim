# Boris-Token-Slim

[![ci](https://github.com/ZCDeng/Boris-Token-Slim/actions/workflows/ci.yml/badge.svg)](https://github.com/ZCDeng/Boris-Token-Slim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> Cut the invisible tax Claude Code pays before every prompt.
> 砍掉 Claude Code 每次请求前的隐性税。

A Claude Code [skill](https://docs.claude.com/en/docs/claude-code/skills) that audits and trims the hidden overhead in your `~/.claude/` setup — bloated `CLAUDE.md`, stale `MEMORY.md`, plugin explosion, always-on MCP servers, dead symlinks, and the `scientific-skills` 142-pack that everyone installs and never uses.

> **Boris Cherny, the creator of Claude Code at Anthropic, just listed 9 patterns that waste 73% of your tokens.**
>
> *— [@Mnilax, on X](https://x.com/i/status/2050321700802408552) · 5.5K likes*

Boris Cherny (Claude Code's creator) first surfaced the **9-pattern framework** on a podcast; [@Mnilax / Mnimiy](https://youmind.com/s/MieRjYvn3NFzLd) then instrumented **430 hours** of his own Claude Code usage with an HTTP proxy and put hard percentages on each pattern — **73% of all tokens were waste**, 27% productive. This skill operationalizes both: the 9 categories + 11 additional gotchas the author hit cleaning his own machine (most notably: `commands/_archive/` still gets scanned by the harness, so moving stuff there makes names *longer*; and skill `description` fields silently break YAML in three ways while still rendering "fine" in the system-reminder).

> **Author's last 30 days (fact-driven headline):**
> `$15,734 spent | 89.4% cache hit | 4 zero-call MCP servers | 1.5M tokens re-read`
>
> No estimation. No 65% reduction claim. Four numbers your own `~/.claude/projects/` already recorded. Run the 30-second test below to see yours.

---

## 中文介绍

> **Boris Cherny——Anthropic 的 Claude Code 作者——在一期 podcast 里列出了 9 种浪费你 73% token 的模式。**
>
> *— [@Mnilax 在 X 的推文](https://x.com/i/status/2050321700802408552) · 5490 赞*

Boris Cherny（Claude Code 作者）先在 podcast 里提出**9 模式分类框架**；[@Mnilax（Mnimiy）](https://youmind.com/s/MieRjYvn3NFzLd) 随后用 HTTP proxy 拦截了自己的 Claude Code 流量，给每条模式打上硬数据——真正回答你问题的 productive token 只占 **27%**，剩下 **73% 花在你看不见的 9 个地方**。

> **作者最近 30 天真实数据（不估算是多少就是多少）：**
> `$15,734 spent | 89.4% cache hit | 4 zero-call MCP servers | 1.5M tokens re-read`
>
> 零估算。没有"省 65% token"的话术。四个数字你的 `~/.claude/projects/` 已经帮你记好了。跑下面 30 秒测试看你的。

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

### 独有的 11 个坑（原文没提）

1. **`commands/_archive/` 陷阱**——挪进去名字反而更长（被前缀成 `_archive:xxx:yyy`），必须挪出 `commands/` 目录才真正隔离
2. **死 symlink 占位**——81 个指向不存在目录的 symlink 仍在 skill 清单里（作者实测）
3. **Sub-plugin 爆炸**——装 `huggingface-skills` 出来 8 个兄弟插件，每个独立占 hook 预算
4. **同名 plugin 装两次**——同一 plugin 被多个 marketplace 收录，不小心装了两份
5. **MCP 藏在 project scope**——`claude mcp list` 显示 6 个，`~/.claude.json` 根下只有 2 个，剩下在 `projects[<path>].mcpServers` 里悄悄激活
6. **重启才能看到真实 skill 清单**——Claude Code 只在 session 启动时扫 skill，清理后的变化当前 session 看不到
7. **僵尸配置**——`MEMORY.md` 写着"2026-04-XX 已移除 XX 模块"，但 `CLAUDE.md` 里那个模块的 3 段配置还在每轮加载
8. **`claude mcp remove` 静默重生**——某些 plugin 在 SessionStart 自动重新注册 MCP，移除等于白做。差额可由 `claude mcp list` 的数量减去 `~/.claude.json::mcpServers` 数量看出来。
9. **audit.sh 自身的 false negative**——sub-plugin 套件计入 plugin=1 但塞 8 个 SKILL.md 进 `skills/`。交叉 metric 1 与 metric 5 才能识别。
10. **Skill description 的 YAML 雷区**——前置双引号截断、mid-line 英文 `Triggers:`/`Examples:` 触发 mapping 错误、block scalar 暗藏换行字符。harness 用宽松 parser 显示"正常"，PyYAML 严格视角下却拿不到 description。
11. **`user-invocable-skills.json` 残留**——归档/删除 skill 后斜杠菜单白名单不会自动同步，用户点中失效条目就报错。

新增的 **Skill description 精简方法论**（坑 10 的解法）独立成篇：见 [`references/skill-description-slimming.md`](references/skill-description-slimming.md)。每个启用 skill 的 description 都注入每次会话的 system-reminder——典型 30+ skill 的机器，可压 50–70%（实测 8500c → 2800c，省每会话 ~2000 tokens）。

### 铁律：归档不删除

所有动作都 `mv` 到 `~/.claude/_tokenslim_archive_<YYYYMMDD>/`，反悔能 `mv` 回来。

### 30-second test: what does YOUR Claude Code look like?

One copy-paste command. No clone. No install. Read-only (never writes files).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/v0.3.0/scripts/headline-only.sh)
```

You'll get a single line like: `30 days: $X,XXX spent | XX% cache hit | X zero-call MCP servers | XXX tokens re-read`

**What these numbers mean for you** (author's sample: 30 days, ~70 sessions, long-context + large-model heavy):

- Short, single-Q&A sessions → your duplicate-read count will be lower than the author's (you don't lean on re-reads).
- Heavy Haiku / small-model user → your cost line will be 5-10x lower (pricing per 1M tokens scales steeply by model).
- You barely use MCP → your "zero-call MCP" count will be 0 (if you haven't configured any, this category doesn't apply).

The script is **pinned to the immutable v0.3.0 tag**, sha256-verified, and falls back to a single-file curl/wget download if git is missing. No telemetry, no ledger write. Script source: [headline-only.sh](https://github.com/ZCDeng/Boris-Token-Slim/blob/v0.3.0/scripts/headline-only.sh).

### 30 秒测试：你的 Claude Code 长什么样？

一条命令，复制粘贴就出结果。不 clone，不装东西，只读（不写任何文件）。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/v0.3.0/scripts/headline-only.sh)
```

你会得到一行像这样的输出：`30 days: $X,XXX spent | XX% cache hit | X zero-call MCP servers | XXX tokens re-read`

**数字怎么读**（作者样本：30 天 ~70 sessions，长 context + 大模型为主）：

- 短任务 / 一问一答为主 → 你的重复读（dup-read）会比作者低（你不靠重复读同一文件吃饭）。
- 小模型（Haiku）为主 → 你的 cost 同比缩水 5-10 倍（per 1M token 定价跨模型级差极大）。
- MCP 用得少 → "zero-call MCP servers" 计数往往是 0（没装就不会有这块浪费）。

脚本 **pin 在 immutable v0.3.0 tag**，sha256 校验，没有 git 时自动降级走 curl/wget 单文件下载。不上报数据，不写 ledger。脚本源码：[headline-only.sh](https://github.com/ZCDeng/Boris-Token-Slim/blob/v0.3.0/scripts/headline-only.sh)。

作者本机实测：`CLAUDE.md -83% / MEMORY.md -79% / 插件 -55% / skill 清单 -72%`，每轮请求基线回收 ~8000-10000 tokens。

---

## Install (Claude Code skill)

One command. Detects Claude Code / Cursor / Windsurf / Codex / Gemini CLI — installs only for Claude Code, honest-bails for others.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/v0.3.0/scripts/install.sh)
```

The script is **pinned to the immutable v0.3.0 tag**, sha256-verified (tarball over the full bundle, hash embedded in the script), and falls back to curl/wget if git is missing. `--dry-run` prints what would happen without touching files.

| What `install.sh` installs | Where |
|---|---|
| Boris-Token-Slim skill | `~/.claude/skills/boris-token-slim/` (symlink → `~/.local/share/boris-token-slim/v0.3.0/`) |
| Clone / extracted bundle | `~/.local/share/boris-token-slim/v0.3.0/` (XDG, 68 KB) |
| Ledger (headline history) | `~/.boris-stats/history.jsonl` (0600, append-only, only on manual `--headline` runs) |

**What it does NOT install**: no hooks, no cron, no shell config changes, no floor files (`.cursor/rules`, `AGENTS.md`).

### 安装（Claude Code skill）

一条命令。自动检测 Claude Code / Cursor / Windsurf / Codex / Gemini CLI——只装 Claude Code，检测到其他 agent 会诚实告诉你目前不支持。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/v0.3.0/scripts/install.sh)
```

脚本 **pin 在 immutable v0.3.0 tag**，tarball sha256 校验（内嵌 hash），没有 git 时自动走 curl/wget。`--dry-run` 只打印会做什么、不真碰文件。

| `install.sh` 装了什么 | 落点 |
|---|---|
| Boris-Token-Slim skill | `~/.claude/skills/boris-token-slim/`（symlink → `~/.local/share/boris-token-slim/v0.3.0/`） |
| Clone / 解压 bundle | `~/.local/share/boris-token-slim/v0.3.0/`（XDG，68 KB） |
| Ledger（headline 历史） | `~/.boris-stats/history.jsonl`（0600 权限，append-only，仅手动 `--headline` 时写） |

**不会装的**：不注入 hook、不加 cron、不改 shell config、不投放 floor 文件（`.cursor/rules`、`AGENTS.md`）。

After install, in Claude Code: `/Boris-Token-Slim` or say "审计我的 claude code token 消耗".

### Uninstall

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/v0.3.0/scripts/uninstall.sh)
```

Removes the symlink and clone path. **Never touches `~/.boris-stats/`** (your data). `--dry-run` supported.

### 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/v0.3.0/scripts/uninstall.sh)
```

删 symlink 和 clone 路径。**不动 `~/.boris-stats/`**（你的数据）。支持 `--dry-run`。

### Option B: Just run the audit script (no install)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/v0.3.0/scripts/audit.sh)
```

Outputs a dashboard of your current overhead vs. recommended thresholds. No changes made.

### Option C: Retrospective transcript analysis

```bash
python3 <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/v0.3.0/scripts/analyze.py) --days 30
```

Parses every Claude Code session transcript in `~/.claude/projects/` and gives you:

- Total cost estimate (using Anthropic's published pricing × the `usage` field Claude Code already records)
- Cache hit rate, 5m vs 1h TTL ratio
- Top N most expensive sessions
- Pattern 2 risk: sessions ≥ 30 turns
- Pattern 4 risk: sessions with cache hit < 50%
- Counterfactual: how much you'd save if cache hit reached 85%

`--json` mode emits stable schema for CI / cron pipelines. See [`references/methodology.md`](references/methodology.md) for the math.

### Option D: Counterfactual token audit (no API calls)

```bash
python3 <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/v0.3.0/scripts/eval.py)
```

Measures your **current** `~/.claude/` configuration's structural input-token overhead and computes a counterfactual "after Boris" estimate using the skill's own thresholds. Pure file-system analysis — no API calls, no cost, fully reproducible.

- Exact measurements: `CLAUDE.md`, `MEMORY.md`, skill descriptions
- Estimates (flagged): MCP schema size (codeburn empirical), optional plugin hook context
- Output: text report + JSON with `measured_only` and `with_estimates` headlines

See [`evals/README.md`](evals/README.md) for the design rationale (why this replaces the hypothetical 3-arm API re-run).

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

## How this compares to CodeBurn

[`getagentseal/codeburn`](https://github.com/getagentseal/codeburn) is a popular cross-tool TUI dashboard (5K+ stars) for cost observability across 18 AI coding tools. We borrowed two ideas from it (see Detector 9 and the MCP usage section in `analyze.py`), but the projects target different jobs:

| | CodeBurn | Boris-Token-Slim |
|---|---|---|
| **Job** | Observe how much you spent | Find what to change |
| **Scope** | 18 providers (Claude/Codex/Cursor/Copilot/...) | Claude Code only |
| **Output** | Live TUI dashboard, menu bar widget | Static report, archive-then-clean operations |
| **Stack** | TypeScript + Ink/React + LiteLLM | Bash + stdlib Python |
| **Size** | ~1MB / 32 src files / 27 tests | ~14KB / 3 scripts / 9 tests |
| **License** | MIT | MIT |

If you want **dashboards**, install codeburn (`npm install -g codeburn`). If you want **specific cleanup operations** with locatable evidence and an archive-not-delete safety contract, you're in the right place.

## What it audits

| # | Pattern | Threshold |
|---|---------|-----------|
| 1 | `CLAUDE.md` bytes | < 1500 |
| 1a | `CLAUDE.md` @-import expanded lines | < 200 |
| 2 | `MEMORY.md` bytes | < 2000 |
| 2a | Extra `.md` files in memory dir | < 15 |
| 3 | Installed plugins | < 15 |
| 4 | MCP servers (user + project scope) | < 6 |
| 5 | Skills in `~/.claude/skills/` | < 50 |
| 6 | Big packs in `~/.claude/commands/` (like `scientific-skills`) | 0 |
| 7 | Active `settings.json` hooks | < 3 |
| 8 | `BASH_MAX_OUTPUT_LENGTH` env / shell profile | ≤ 15000 |

Plus **14 gotcha detectors** that print actionable evidence (paths, names, line numbers):

| # | Detector | What it finds |
|---|----------|---------------|
| 1 | Dead symlinks | Broken `~/.claude/skills/*` symlinks (e.g. pointing to deleted `.agents/skills/`) |
| 2 | `_archive` trap | Archive dirs *inside* `commands/` or `skills/` (still scanned by harness) |
| 3 | Sub-plugin explosion | Plugin family clusters with ≥4 siblings (e.g. `hugging-face-*`) |
| 4 | Same-name plugin | Same bare name installed from multiple marketplaces |
| 5 | Project-scope MCP | MCPs hidden in `~/.claude.json::projects[*].mcpServers` |
| 6 | Zombie configs | `CLAUDE.md` references modules `MEMORY` says are removed |
| 7 | MCP zombie resurrection | Plugins that auto-register MCPs (so `claude mcp remove` is reverted on restart) |
| 8 | Plugin sub-skill bundles | Plugins shipping ≥5 `SKILL.md` files; **distinguishes installed vs cache-residue** |
| 9 | Configured-but-uncalled MCP | MCPs configured but invoked 0 times in last 30 days of transcripts (codeburn-style) |
| 10 | Junk reads | Read/Grep into `node_modules`/`.git`/`dist`/etc (codeburn-style) |
| 11 | Duplicate reads | Same file re-read ≥3 times in one session (codeburn-style) |
| 12 | **Oversized skill descriptions** | Skill `description` fields > 300 chars (every enabled skill loads into every session's system-reminder) |
| 13 | **YAML pitfalls in descriptions** | Three patterns that silently break strict YAML parsers: leading-quote truncation, mid-line capitalized colons, block scalars |
| 14 | **Orphan slash-menu whitelist** | `user-invocable-skills.json` entries pointing at archived/deleted skill dirs (cause `/` menu errors) |

## What it does (interactive, safe)

When invoked inside Claude Code, the skill walks you through 4-5 cleanup phases:

1. **Plugin cleanup** (highest ROI) — categorical prompts (keep/remove financial suite, HuggingFace sub-plugins, duplicates, etc.)
2. **MEMORY.md index-ification** — archive stale project state snapshots, keep only feedback/reference entries
3. **CLAUDE.md slim** — strip Anthropic-blog boilerplate, dead-module configs, redundant skill triggers
4. **MCP server audit** — move low-frequency MCPs off the always-on list
5. **Skill audit** *(requires restart)* — clean dead symlinks, archive big packs, categorical culling, **compress oversized `description` fields** (every enabled skill's description is injected into every session's system-reminder — see [`references/skill-description-slimming.md`](references/skill-description-slimming.md)), **prune `user-invocable-skills.json`** of entries pointing at archived skills (otherwise the slash menu errors on click)

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
- **MCP zombie resurrection** — some plugins re-register MCPs on SessionStart, so `claude mcp remove` is reverted on restart. Detect via `claude mcp list` count vs. `~/.claude.json::mcpServers` count.
- **Skill description YAML traps** — leading double-quotes truncate, mid-line English `Triggers:` / `Examples:` break strict YAML, block scalars carry hidden newlines. The harness uses a permissive parser so descriptions look fine while strict tooling sees 0 chars. See [`references/skill-description-slimming.md`](references/skill-description-slimming.md) for the full audit + batch-rewrite playbook.
- **Slash-menu whitelist orphans** — `~/.claude/user-invocable-skills.json` is not synced when skills are archived/deleted; clicking a stale entry errors out. Phase 5 prunes it after skill cleanup.

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

MIT — see [`LICENSE`](LICENSE).

## Security

Never `rm -rf`; everything goes through archive. See [`SECURITY.md`](SECURITY.md) for the full policy and threat model.

## Contributing

PRs welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for local dev workflow, lint commands, and how to add a new gotcha detector.

Two things especially valued:
- **New gotcha reports** with reproducible evidence (proxy log excerpts, `ls` output, config snippets)
- **New detectors** that print actionable evidence — paths, plugin names, install state — not just counts

Iron rule: archive, never delete.

## Tests

```bash
pip install pytest
python3 -m pytest tests/ -v
```

CI runs shellcheck + Python compile + pytest on Python 3.10/3.11/3.12 + a smoke audit against a fixture `CLAUDE_HOME` on every PR.
