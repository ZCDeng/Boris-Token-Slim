# Gotchas（实战踩坑录）

这些坑原文章没提，是 Boris-Token-Slim 作者实际清理自己的 Claude Code 时发现的。遇到一次就永远记住的那种。

## 坑 1：commands/_archive 仍被 harness 扫描

第一次归档 142 个 scientific-skills 时，移到了 `~/.claude/commands/_archive/scientific-skills-archived-20260504/`，以为就隔离了。

**结果**：重新列 skill 清单发现 142 条全还在，只是前缀从 `scientific-skills:*` 变成 `_archive:scientific-skills-archived-20260504:*`——**名字更长了，token 更浪费了**。

**原因**：Claude Code harness 递归扫描 `~/.claude/commands/` 所有子目录，`_` 前缀不豁免。

**正确做法**：归档目录必须放在 `~/.claude/` 下、`commands/` 和 `skills/` **以外**。推荐：
```
~/.claude/
├── commands/              # harness 会扫
├── skills/                # harness 会扫
├── _commands_archive/     # 归档目标 1（不扫）
├── _skills_archive/       # 归档目标 2（不扫）
└── _tokenslim_archive_<date>/  # 本 skill 归档根
```

## 坑 2：Dead Symlinks 占清单位置

`ls ~/.claude/skills/` 发现 221 个 skill。其中 **81 个是指向 `~/.claude/.agents/skills/*` 的 symlink，但那个目录已经不存在**。

这 81 个死链接：
- 仍然出现在 Claude Code 启动时的 skill 清单注入里（或至少占用扫描时间）
- SKILL.md 读不到
- `ls` 看起来一切正常（broken symlink 不会显眼）

**检测命令**：
```bash
cd ~/.claude/skills
for s in *; do
  [ -L "$s" ] && [ ! -e "$s" ] && echo "DEAD: $s -> $(readlink "$s")"
done
```

**批量删除**（这种删没风险，本来就读不到）：
```bash
cd ~/.claude/skills
for s in *; do
  [ -L "$s" ] && [ ! -e "$s" ] && rm "$s"
done
```

## 坑 3：Sub-plugin 爆炸

装一个 `huggingface-skills@claude-plugins-official` 插件，结果 plugin 列表里出现 8 个：
```
hugging-face-cli
hugging-face-datasets
hugging-face-evaluation
hugging-face-jobs
hugging-face-model-trainer
hugging-face-paper-publisher
hugging-face-tool-builder
hugging-face-trackio
huggingface-skills    # 统一入口
```

每个都是独立插件，独立占 hook 注入和 SessionStart 开销。

**清理策略**：只留统一入口 `huggingface-skills`，8 个子套件全卸。如果临时需要某个专项功能，再装那个子套件。

同样套路：`financial-services-plugins` marketplace 下面 7 件套（equity-research / investment-banking / private-equity / sp-global / lseg / wealth-management / financial-analysis）几乎没人全用。

## 坑 4：同名插件装两次

Plugin 清单里看到：
```
homunculus@homunculus
homunculus@humanplane
```

**原因**：同一个开源 plugin 被多个 marketplace 收录，命令补全或者早期尝试时装了不同出处的两份。

**检测**：
```bash
cat ~/.claude/plugins/installed_plugins.json \
  | python3 -c "import json,sys; d=json.load(sys.stdin); names=[k.split('@')[0] for k in d.get('plugins',{})]; dups=[n for n in set(names) if names.count(n)>1]; print('duplicates:', dups)"
```

## 坑 5：MCP 配置在 project scope 里

`claude mcp list` 显示 6 个 MCP，但 `python3 -c "import json; print(list(json.load(open('~/.claude.json'))['mcpServers'].keys()))"` 只显示 2 个。

**原因**：Claude Code 的 MCP 配置分两个 scope：
- **user scope**：`~/.claude.json` 根下的 `mcpServers`
- **project scope**：`~/.claude.json` 的 `projects[<path>].mcpServers`

当前工作目录匹配的 project scope MCP 也会被激活。你 `claude mcp remove` 卸载用户级的，项目级的还在跑。

**检查所有 scope**：
```bash
python3 -c "
import json
d = json.load(open('/Users/\$USER/.claude.json'))
print('user:', list(d.get('mcpServers',{}).keys()))
for p, pd in d.get('projects', {}).items():
    if pd.get('mcpServers'):
        print(f'project {p}:', list(pd['mcpServers'].keys()))
"
```

## 坑 6：重启才能看到真实 skill 清单

归档了 118 个 skill 后，想在当前 session 验证"清单是不是干净了"——**看不到变化**。Claude Code 只在 session 启动时扫描 skill 清单，system-reminder 里注入的列表是启动时的快照，运行期不刷新。

必须 `/exit` 再开，新 session 的 system-reminder 才会反映清理后的真实清单。

**推论**：skill 审计必须分两次 session 做——
1. Session A：清理 skill，但不能确认清单变化
2. Session B（重启后）：看到真实清单，继续二轮审计

告诉用户这一点，避免他们在 Session A 里反复质疑"为什么还在"。

## 坑 7：MemPalace/类似记忆系统的僵尸配置

如果 CLAUDE.md 里有几段 MemPalace / mempalace / 其他外部记忆系统的配置（hook、MCP 调用、wing 路由等），**先查一下它是否还在用**。

典型僵尸态：
- MEMORY.md 里有条目说 "2026-04-XX 已完全移除 mempalace（claude mcp remove + opencode.json）"
- 但 CLAUDE.md 里仍然保留 3 段 mempalace 配置说明
- 每轮对话这 3 段都在加载

直接删 CLAUDE.md 里的相关段。
