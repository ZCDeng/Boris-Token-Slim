# Archive Layout（归档目录规范）

本 skill 的铁律 1 是"归档不删除"。本文件规定归档目录的布局，保证：
- 永远不覆盖历史归档
- 能看出每次归档的时间和目标
- 能 `mv` 回去恢复

## 根目录

```
~/.claude/_tokenslim_archive_<YYYYMMDD>/
```

日期按**本次清理的启动日**。同一天多次清理共用同一个根目录。

## 子目录

```
~/.claude/_tokenslim_archive_20260504/
├── plugins.log                 # 记录卸载了哪些 plugin（不可 mv 回来）
├── mcp-backup.json             # ~/.claude.json 清理前的副本
├── claude-md.before.md         # CLAUDE.md 清理前的副本
├── memory-md.before.md         # MEMORY.md 清理前的副本
├── memory/                     # 归档的 memory_*.md
│   ├── project_hermes_status.md
│   └── ...
├── skills/                     # 归档的 ~/.claude/skills/<name>/
│   ├── py/
│   └── ...
└── commands/                   # 归档的 ~/.claude/commands/<name>/（大类 skill pack）
    └── scientific-skills/
```

## 恢复操作

**恢复某个 skill**：
```bash
mv ~/.claude/_tokenslim_archive_20260504/skills/py ~/.claude/skills/
```

**恢复 CLAUDE.md**：
```bash
cp ~/.claude/_tokenslim_archive_20260504/claude-md.before.md ~/.claude/CLAUDE.md
```

**恢复某个 plugin**：
```bash
# plugin 不能 mv 回来，要重装
claude plugin install <name>@<marketplace>
# plugins.log 里记录了原始 marketplace
```

## 铁律 2 提醒

归档根**必须放在 `~/.claude/` 下但 `commands/` 和 `skills/` 以外**。

❌ **错误**：
```
~/.claude/skills/_archive/      # harness 会扫 skills/ 全部子目录
~/.claude/commands/_archive/    # harness 会扫 commands/ 全部子目录
```

✅ **正确**：
```
~/.claude/_tokenslim_archive_<date>/
```

## 清理归档

归档留 30-60 天观察期。确认没有回滚需求后，可以整目录删：
```bash
rm -rf ~/.claude/_tokenslim_archive_20260404  # 一个月前的
```

或压缩：
```bash
tar czf ~/.claude/_tokenslim_archive_20260404.tar.gz \
  ~/.claude/_tokenslim_archive_20260404 && \
  rm -rf ~/.claude/_tokenslim_archive_20260404
```
