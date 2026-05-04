# 9 Patterns（原文速查）

原始出处：https://youmind.com/s/MieRjYvn3NFzLd

作者用 HTTP proxy 拦截 90 天、430 小时、600 万 input tokens 的 Claude Code 流量，分类统计后发现只有 **27%** 是"真正回答问题"的 productive tokens，剩下 **73%** 是下面 9 个不可见模式。

| # | Pattern | 占比 | 30 秒修复 |
|---|---------|------|----------|
| 1 | CLAUDE.md 臃肿 | ~14% | 砍到 <1500 tokens，删"解释为什么"的冗长规则 |
| 2 | 对话历史重读 | ~13% | 对话超 20 条 `/compact`；up-arrow 编辑而不是追加 |
| 3 | Hook 注入堆叠 | ~11% | 多个插件的 UserPromptSubmit hook 叠加，一次几千 token |
| 4 | Session 恢复 cache miss | ~10% | 默认 5 分钟 cache；保持 session 温热或升级 1h cache |
| 5 | Skill 加载到无关任务 | ~7% | 每个 SKILL.md 800-2500 tokens，大量无关 skill 常驻清单 |
| 6 | "以防万一"的 tool 定义 | ~6% | 12 个 MCP 每次都送 tool schema（每个 ~600 token）|
| 7 | Extended thinking 开太多 | ~5% | 简单任务也烧几千 token 思考；默认关，需要时 Alt+T |
| 8 | 方向错了不中断 | ~4% | 看到偏了立刻 Cmd+. 停，别让它把 400 行写完 |
| 9 | 插件 auto-update 冗余 | ~3% | 每个插件 SessionStart 注入 ~50 token 的 "loaded successfully" |

## 文章作者的具体数据

- 90 天 / 430 小时 active work / 600 万 input tokens / $1340 API spend
- 优化前 productive token share：27%
- 优化后：~65%（不是 100%，overhead 有下限）

## 什么没用

文章里作者试过但**没明显效果**的：
1. 切 Haiku 处理简单任务 → 只省 ~3%；上下文臃肿时便宜模型更贵
2. 每任务 `/clear` → 反效果，丢失需要的上下文
3. 禁掉所有 skill → 初期省 token，后期每次手写 200 token 指令，净负
4. 纯订阅降级 → 每工时成本不变，只是额度吃紧更痛
5. 为 2026-03 的 prompt cache bug 做 workaround → Anthropic 已修，投入时间不值
6. 避开 peak hours → 帮助约 7% 用户，不是主矛盾

## 思维模型

> 不要把每次 session 当白板。每次 session 都是一张预扣发票：
> CLAUDE.md（总扣）+ 插件 hook（总扣）+ skill SKILL.md（相关时扣）+ MCP tool schema（总扣）+ 会话历史（每轮扣）+ cache miss 重编译（每次恢复扣）
> Productive token = 发票扣完剩下的残值

"Claude 变笨了"的抱怨，大部分是 overhead 增长，不是模型退化。模型的 compute budget 没变，但被你臃肿的 CLAUDE.md、12 个 hook 注入、4 个你忘了装的插件占光了。
