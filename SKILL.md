---
name: Boris-Token-Slim
description: 审计精简 Claude Code 隐性 token 开销——CLAUDE.md 臃肿、MEMORY 过期、插件爆炸、MCP 常驻、死 symlink、重复 skill。触发：优化 token、Claude Code 变慢、claude 变笨、slim down claude code、/Boris-Token-Slim。
user-invocable: true
---

# Boris-Token-Slim

> Cut the invisible tax Claude Code pays before every prompt.
> 砍掉 Claude Code 每次请求前的隐性税。

## 为什么需要这个 skill

每次 Claude Code 请求的 context 里，真正回答你问题的内容可能只占 **27%**，剩下 73% 是：
- 每轮加载的 CLAUDE.md / MEMORY.md
- 每个激活插件注入的 UserPromptSubmit hook
- 每个连接 MCP 的 tool schema
- 扫描到但从没用到的 skill 清单
- 死 symlink（指向不存在目录的 skill，仍占清单位置）
- 过期的项目状态记录

这些是"不 instrument 永远看不见"的浪费。原始出处：[I tracked 430 hours of Claude Code usage. 73% was wasted on these 9 patterns.](https://youmind.com/s/MieRjYvn3NFzLd)

## 执行协议（必须按顺序）

### Phase 0: 运行审计脚本

```bash
bash scripts/audit.sh
```

输出 7 行核心指标 + 8 个 gotcha 检测结果（指标包括 CLAUDE.md / MEMORY.md 大小、插件数、MCP 数、本地 skill 数、commands 下子目录数、活动 hooks，附每项推荐上限；gotcha 包括死 symlink、_archive 陷阱、sub-plugin 爆炸等）。把表格直接贴给用户，让他看见基线。

### Phase 0.5: 回溯分析过往 session（可选但推荐）

```bash
python3 scripts/analyze.py --days 30
```

这会扫 `~/.claude/projects/**/*.jsonl` 给出过去 30 天的真实 token 消耗、cache 命中、最贵 session 排行、Pattern 2/4 风险标记。**与 audit.sh 互补**：
- audit.sh 看"现在的 overhead 配置"（静态）
- analyze.py 看"过去花了多少钱、哪些 session 最浪费"（历史）

如果用户问"哪个项目/会话最烧 token"，跑 analyze.py 而不是 audit.sh。如果用户问"该清理什么"，跑 audit.sh。

### Phase 1: 确认范围

向用户展示基线 + 本 skill 将按 4-5 步清理：
1. 插件清理（最高 ROI）
2. MEMORY.md 索引化
3. CLAUDE.md 精简
4. MCP 常驻审计
5.（可选）skill 审计——需要重启 Claude Code 才能看到 symlink 清单真实变化

用 `AskUserQuestion` 问用户从哪步开始（可多选）。每步都要用 `TaskCreate` 立个 task 跟踪。

### Phase 2: 逐步清理

所有清理严格遵守 **3 条铁律**：

#### 铁律 1：归档不删除

永远 `mv` 到 `~/.claude/_tokenslim_archive_<YYYYMMDD>/` 子目录，**绝不 `rm`**。
用户如果发现删错了，能 `mv` 回来。

```bash
ARCHIVE_ROOT=~/.claude/_tokenslim_archive_$(date +%Y%m%d)
mkdir -p "$ARCHIVE_ROOT"/{plugins,memory,skills,mcp-backup}
```

#### 铁律 2：commands/_archive 陷阱

Claude Code harness 会递归扫描 `~/.claude/commands/` **所有子目录**，包括名叫 `_archive/` 的。把 scientific-skills 挪到 `~/.claude/commands/_archive/` **没用**——skill 清单里它们还在，名字更长（变成 `_archive:xxx:yyy`）。

必须挪到 `~/.claude/` 下、commands/ **以外**的目录：
```bash
# ❌ 错误
mv ~/.claude/commands/scientific-skills ~/.claude/commands/_archive/

# ✅ 正确
mv ~/.claude/commands/scientific-skills ~/.claude/_commands_archive/
```

同理，skills/ 下的归档也不能放在 `~/.claude/skills/_archive/`（harness 会扫），要放在 `~/.claude/_skills_archive/` 或类似目录。

#### 铁律 3：重启才能看到 skill 清单变化

Claude Code 只在 session 启动时扫描 skill 清单。symlink 删除、目录归档后，**当前 session 的 system-reminder 里 skill 清单不会更新**。要求用户 `/exit` 重启后，skill 清单才真正干净。

告诉用户："skill 审计必须重启后做，我在上下文里看到的清单和实际不同步。"

### Phase 3: 各步详细做法

#### 步骤 A：插件清理（Pattern 3 & 9）

1. `cat ~/.claude/plugins/installed_plugins.json | python3 -c "import json,sys; d=json.load(sys.stdin); [print(k) for k in sorted(d.get('plugins',{}).keys())]"` 列出全部
2. **按营销套件分组**问用户（AskUserQuestion 多选）：
   - 金融服务套件（equity-research / investment-banking / private-equity / sp-global / lseg / wealth-management / financial-analysis）
   - HuggingFace 子套件（8 个 hugging-face-* 通常可以只留 huggingface-skills 入口）
   - 集成服务（Notion / supabase / vercel / figma / gitlab / telegram / playwright）
   - 重复/冷门（同名插件从不同 marketplace 装了两次，prompts.chat 预设库，claude-code-setup 装完就没用）
3. 批量卸载：
   ```bash
   for p in "$@"; do claude plugin uninstall -y "$p"; done
   ```
4. **不要自动卸载 superpowers / compound-engineering / github / context7** 等核心高频插件，除非用户明确说不用。

#### 步骤 B：MEMORY.md 索引化（Pattern 1 的变体）

MEMORY.md 应该是**索引**，不是**项目状态日志**。典型垃圾：
- `project_xxx_current_state.md` 这种"当前状态"快照，过期即垃圾
- `project_xxx_v1_upgrade_pending.md` 这种"待完成"任务，完成后没删
- `project_xxx_shipped.md` 这种"已交付"记录，commit message 已覆盖
- 已被弃用模块的配置说明（例：MEMORY 说"mempalace 已移除"，但 CLAUDE.md 里还有 3 段 mempalace 配置）

保留标准：
- ✅ Feedback 类（通用教训，跨会话有用）
- ✅ Reference 类（决策结论、存放规范、链接资源）
- ❌ Project 状态快照（时间一过就是骗人）

做法：
1. `Read` MEMORY.md
2. 按保留/归档分类，每条过一遍
3. 问用户："归档到 `memory/archive/` 还是直接删？"（推荐归档）
4. 重写 MEMORY.md 为纯索引（每行 <150 字符，`- [Title](file.md) — one-line hook` 格式）

#### 步骤 C：CLAUDE.md 精简（Pattern 1）

典型可删内容：
- **Anthropic 博客最佳实践**照搬（Long-Running Agent 9 小节、Compound Engineering 原理等）——harness 本身已内置 TaskCreate / plan mode / subagent / memory，冗余
- **已废弃模块的详细配置**（例：mempalace 整段，但 MEMORY 说已移除）
- **Skill 触发说明**（harness 的 skill 系统会自动路由，CLAUDE.md 里再写 `/hermes-status 触发 hermes-status` 是重复）
- **过度解释型规则**（把"提交前 commit what/why/how"写成 3 段说明，1 句话够了）

保留核心：
- 身份 + 沟通风格
- 项目级工作流入口
- 安全红线（部署确认、不复述密钥、push 确认）
- 服务器操作链条（SSH/Docker）

目标：1500 tokens 以内（约 3000 字节中文，或 6000 字节英文）。

#### 步骤 D：MCP 常驻审计（Pattern 6）

```bash
python3 -c "import json; d=json.load(open('/Users/\$USER/.claude.json')); print('user MCP:', list(d.get('mcpServers',{}).keys())); [print(f'proj {p}:', list(d.get('projects',{}).get(p,{}).get('mcpServers',{}).keys())) for p in d.get('projects',{}) if d['projects'][p].get('mcpServers')]"
```

常见可候删：
- `task-master-ai`（harness 的 TaskCreate/Update/List 功能重复）
- `chrome-devtools`（低频，用到时再 `claude mcp add`）
- 项目级 MCP 在全局目录里常驻（挪到对应项目）

卸载：`claude mcp remove <name>`

#### 步骤 E：Skill 审计（**必须提醒用户重启**）

1. **先处理死 symlink**：
   ```bash
   cd ~/.claude/skills
   for s in *; do
     [ -L "$s" ] && [ ! -e "$s" ] && rm "$s"
   done
   ```
   这些指向不存在目录的 symlink 是纯浪费——占 skill 清单名字但读不到内容。

2. **检测 `~/.claude/commands/` 子目录下的大类 skill pack**（如 scientific-skills 142 个子 skill）：
   ```bash
   find ~/.claude/commands -maxdepth 2 -type d | head
   ```
   整目录挪到 `~/.claude/_commands_archive/`（注意铁律 2）。

3. **本地 skills 分类审计**（需重启 Claude Code）：
   按命名规律分组（perspective 系列 / 写作系列 / UI 模板系列 / 编程角色短名 / dbs 系列等），用 `AskUserQuestion` 让用户勾选分组，全组归档 or 全组保留。
   不要一条条问——每次 AskUserQuestion 最多 4 题，4 选项，按组问最高效。

4. **Skill description 精简**（高 ROI、容易遗漏的子步骤）：
   每个启用 skill 的 `description` 字段会出现在**每次会话**的 system-reminder 里。10 个 description 各 500 字符 = 5000 字符/会话永久燃烧。

   快速识别：
   ```python
   import os, re, yaml
   for d in sorted(os.listdir('/Users/USER/.claude/skills')):
       f = os.path.join(os.path.realpath(os.path.join('/Users/USER/.claude/skills', d)), 'SKILL.md')
       if os.path.isfile(f):
           m = re.match(r'^---\n(.*?)\n---', open(f).read(), re.S)
           if m:
               try: print(f"{len(yaml.safe_load(m.group(1)).get('description','')):4d}  {d}")
               except: print(f"   ?  {d}  YAML BROKEN")
   ```

   按字符数倒序，处理 >200c 的；典型可砍掉 50–70%。详细方法（压缩原则、YAML 陷阱、批量改写脚本）见 `references/skill-description-slimming.md`。

5. **清理 user-invocable-skills.json 失效条目**：
   ```python
   import json, os
   F = '/Users/USER/.claude/user-invocable-skills.json'
   cfg = json.load(open(F))
   cfg['userInvokableSkills'] = [s for s in cfg['userInvokableSkills']
                                  if os.path.exists(os.path.join('/Users/USER/.claude/skills', s))]
   json.dump(cfg, open(F, 'w'), ensure_ascii=False, indent=2)
   ```
   归档 skill 后斜杠菜单白名单常残留失效条目，用户点中即报错。

### Phase 4: 报告

结束时输出 before/after 表：

| 指标 | 优化前 | 优化后 | 变化 |
|------|--------|--------|------|
| CLAUDE.md | XXXX B | YYYY B | -Z% |
| MEMORY.md | XXXX B | YYYY B | -Z% |
| 插件 | N | M | -K |
| MCP 常驻 | N | M | -K |
| Skill 清单 | N | M | -K% |

告诉用户：
1. 重启 Claude Code（`/exit` 再开）让插件卸载和 skill 清单变化生效
2. 养成 3 个习惯：默认关 extended thinking、方向错了立刻 Esc、对话超 20 条 `/compact`
3. 每周或每月跑一次 `bash scripts/audit.sh` 复查指标是否回涨

## 参考资料

- `references/9-patterns.md` — 原文 9 个浪费模式速查
- `references/gotchas.md` — 本 skill 作者踩过的坑（dead symlinks、\_archive 位置、sub-plugin 爆炸、YAML 陷阱）
- `references/archive-layout.md` — 归档目录结构规范
- `references/methodology.md` — analyze.py 的数据源/计费公式/方法学
- `references/skill-description-slimming.md` — Skill description 精简方法论（审计/分级/压缩原则/YAML 陷阱/批量改写脚本）
- `scripts/audit.sh` — 一键审计脚本，输出 9 指标表
- `scripts/analyze.py` — 回溯解析 transcript JSONL，给出 cost/cache/Pattern 风险报告
- `scripts/archive-helper.sh` — 批量归档工具

## 非目标

- 不自动卸载任何东西（铁律 1：归档不删除，且全部交互确认）
- 不改 Claude 订阅/API key/provider 配置
- 不处理 1 小时 cache 升级（那要改 `ANTHROPIC_BASE_URL` 背后的转发方配置，超出 skill 范围）
- 不评估"该不该买更贵的订阅"——本 skill 只负责砍开销，不负责增预算
