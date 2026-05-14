# Methodology · Transcript Analyzer

`scripts/analyze.py` 在不引入任何 hook 的前提下，回溯计算你的真实 Claude Code token 开销。

## Why retrospective beats live monitoring

| | Token Optimizer (live) | Boris-Token-Slim analyze.py (retrospective) |
|---|---|---|
| 数据来源 | 12 个 hook 实时拦截 tool call | 解析 `~/.claude/projects/**/*.jsonl` |
| 时间窗 | **从安装开始** | **你装 Claude Code 以来的所有 session** |
| 自身开销 | 每次 Read/Bash/Edit/Agent 都跑一次 hook | 0（脚本不在 Claude 进程里跑） |
| 数据精度 | 实测 + 估算混合 | 直接读 Anthropic API 返回的 `usage` 字段 |
| 是否能审计历史 | ❌（装之前的浪费看不到） | ✅ |
| 是否需要常驻 | ✅ | ❌ |

两个工具是互补关系，不是替代。Token Optimizer 适合"持续盯哨"，本工具适合"季度复盘 + 装机/重启后回溯"。

## 数据源 schema

Claude Code 在 `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` 写每条消息。每条 assistant message 形如：

```json
{
  "type": "assistant",
  "message": {
    "role": "assistant",
    "model": "claude-sonnet-4-6",
    "usage": {
      "input_tokens": 0,
      "output_tokens": 247,
      "cache_creation_input_tokens": 4823,
      "cache_read_input_tokens": 18445,
      "cache_creation": {
        "ephemeral_5m_input_tokens": 4823,
        "ephemeral_1h_input_tokens": 0
      },
      "server_tool_use": {
        "web_search_requests": 0,
        "web_fetch_requests": 0
      }
    }
  }
}
```

每个字段都来自 Anthropic API 响应本身，不是估算。

## 计费公式

按 Anthropic 公开价格（2026 年 5 月，Sonnet 4.x）：

| 类型 | 单价（每 1M token） | 倍数 |
|---|---|---|
| input_tokens (raw) | $3.00 | 1.0x |
| cache_read_input_tokens | $0.30 | 0.1x |
| cache_creation 5m TTL | $3.75 | 1.25x |
| cache_creation 1h TTL | $6.00 | 2.0x |
| output_tokens | $15.00 | — |

Opus 单价是 Sonnet 的 5 倍（$15 / $75），Haiku 是 Sonnet 的 ~0.27 倍（$0.80 / $4）。`analyze.py` 按 transcript 里实际记录的 model 字段自动选价表。

## Cache 健康度的两个指标

### 1. Cache hit rate

```
cache_hit_rate = cache_read / (input_tokens + cache_read + cache_write_5m + cache_write_1h)
```

| 区间 | 含义 |
|---|---|
| ≥ 80% | 健康。CLAUDE.md / system prompt / tool schema 都正常被复用 |
| 50–80% | 可疑。可能 session 频繁中断（5min cache 失效）或 CLAUDE.md 在每会话被改 |
| < 50% | 异常。文章 Pattern 4 触发，每次 session 恢复都付全价 |

### 2. 5m vs 1h TTL 占比

```
pct_1h = cache_write_1h / (cache_write_5m + cache_write_1h)
```

5m TTL 是默认值。如果你 session 工作节奏是"集中干 1 小时 + 离开 30 分钟 + 再回来"，5m 会反复 miss + 重写，每次写按 1.25x 计费。1h TTL 写一次 2x，但能撑过一次咖啡时间。

| 区间 | 建议 |
|---|---|
| ≥ 50% | 1h cache 已经在用，节省机制生效 |
| < 50% | 检查 `ANTHROPIC_BASE_URL` 后端是否支持 `cache_control: { ttl: "1h" }` 透传 |

## 浪费会话的两个识别规则

`analyze.py` 自动标记：

### Pattern 2 risk: Long sessions

```python
long_sessions = [s for s in sessions if s.assistant_turns >= 30]
```

文章原话：第 30 条消息时，每条新消息要重读前 29 条历史。第 30 条的 input cost 是第 1 条的 30 倍。

### Pattern 4 risk: Low cache hit

```python
low_cache = [s for s in sessions if s.cache_hit_rate < 50 and s.assistant_turns >= 5]
```

≥5 turn 但 cache hit < 50%——明显异常，要么是这个 session 在不停切换 cwd（CwdChanged hook 触发 cache 清空），要么是 CLAUDE.md 频繁被改写。

## 反事实估算

报告底部的 "Counterfactual" 段是**上限估算**：假设你能把 cache hit 拉到 85%，能省多少钱。这是上界，因为：

- 现实里有些 input 必然 miss（首次读新文件、变量化的 prompt 等）
- 1h cache 写入也按 2x 计，不是免费
- 没把 5m → 1h 升级的写入价差完全算进去（保守估算）

## 不算的部分

- **server_tool_use**（web search / web fetch）— Anthropic 单独计费但 token 字段为 0
- **batch API discounts** — `usage` 不区分是不是 batch 模式
- **discount tiers** — Pro/Team 套餐内的请求按订阅计，但 transcript 仍记录"假如按 API 计价"的 token 数

所以最后输出的 cost 是**"如果你用 API 按表计价的等效成本"**，不是你账单的实际数字。订阅用户看绝对数没意义，但**比较 session 之间的相对值**（哪个最贵、cache 命中如何）依然准。

## Scope & non-scope（坦诚边界）

Boris-Token-Slim 是**静态基线审计 + 回溯 session 解析**——专门盯"装好之后每次启动都在烧的固定开销"。它**不**覆盖运行时 token 开销的全部维度。

| 维度 | Boris 是否覆盖 | 补充工具 |
|---|---|---|
| CLAUDE.md / MEMORY.md 体积 | ✅ 静态指标 1/2 | — |
| 插件 / MCP 常驻 schema 税 | ✅ 静态指标 3/4 + 检测器 9 | — |
| Skill 描述膨胀（每会话灌入 system-reminder） | ✅ 检测器 12/13 | — |
| **缓存前缀污染**（10x 杠杆点） | ✅ 检测器 15（v0.4） | — |
| Session 内 token 累积（duplicate reads / junk reads / 30+ turn 历史滚雪球） | ✅ 检测器 10/11 + analyze.py | — |
| **工具结果体积**（`cargo test` 灌进 context 的 KB 级 raw output） | ❌ 未测量 | [rtk](https://github.com/rtk-ai/rtk) 之类的 stdin/stdout filter |
| **Output token 体积**（模型话痨） | ❌ 未测量 | [caveman](https://github.com/juliusbrussee/caveman) 之类的 verbosity 抑制 |
| **模型路由**（Opus 干 typo fix 这种错配） | ❌ 不建议 | [claude-code-router](https://github.com/musistudio/claude-code-router) / [Anthropic Routing API](https://docs.anthropic.com/) |
| **Speculative file include**（"以防万一加这个文件"） | ❌ 运行时行为 | 写更狠的 CLAUDE.md / 用 `grep` 替代 `Read` |
| 实时账单告警 / 限额 | ❌ 不在范围内 | [ccusage](https://github.com/ryoppippi/ccusage) / [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) |

**为什么这么划线**：Boris 遵守 Iron Rule 1（"审计不注入"）——只读、可重入、零行为修改。任何"压缩输出"或"换模型"都属于**注入式**优化，由专门工具承担。

**思路来源**：检测器 15 + 本节范围划线参考 Ronin (@DeRonin_) "How To Cut Your AI Coding Bill by 80%"（2026 年 5 月）。文章里 leak #1（stable context 每轮重发）和 prompt caching 10x 杠杆，恰好对应 Boris 的核心战场。文章里 leak #3（模型路由错配）和 leak #5（speculative file include）则被本工具明确划在范围外。

## CI / 自动化

`--json` 模式输出稳定 schema (`boris-token-slim/transcript-analyzer/v1`)，可以接到 cron 或 GitHub Actions：

```bash
# 每周日生成上周的 token 报告
0 9 * * 0  python3 ~/projects/Boris-Token-Slim/scripts/analyze.py --days 7 --json > ~/Documents/token-reports/$(date +\%Y-\%m-\%d).json
```
