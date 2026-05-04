#!/usr/bin/env bash
# Boris-Token-Slim audit script
# Scans ~/.claude for the 9 overhead patterns and outputs a dashboard table.
# Exit code 0 always (this is a report, not a gate).

set -u

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
MEMORY_DIR="${MEMORY_DIR:-$HOME/.claude/projects/-Users-$USER/memory}"

# ---------- helpers ----------
bytes_of() {
  local f="$1"
  [ -f "$f" ] && wc -c < "$f" | tr -d ' ' || echo 0
}

flag() {
  local v="$1" threshold="$2" direction="${3:-over}"
  if [ "$direction" = "over" ]; then
    [ "$v" -gt "$threshold" ] && echo "⚠️ over" || echo "✅ ok"
  else
    [ "$v" -lt "$threshold" ] && echo "⚠️ under" || echo "✅ ok"
  fi
}

count_dir() {
  [ -d "$1" ] && ls "$1" 2>/dev/null | wc -l | tr -d ' ' || echo 0
}

# ---------- 1. CLAUDE.md bloat ----------
claude_md_bytes=$(bytes_of "$CLAUDE_HOME/CLAUDE.md")

# ---------- 2. MEMORY.md bloat ----------
memory_md=""
for candidate in "$MEMORY_DIR/MEMORY.md" "$HOME/.claude/memory/MEMORY.md"; do
  [ -f "$candidate" ] && memory_md="$candidate" && break
done
memory_md_bytes=$(bytes_of "$memory_md")
memory_extra_files=0
if [ -n "$memory_md" ]; then
  memory_dir=$(dirname "$memory_md")
  memory_extra_files=$(find "$memory_dir" -maxdepth 1 -name "*.md" ! -name "MEMORY.md" 2>/dev/null | wc -l | tr -d ' ')
fi

# ---------- 3. Plugin count ----------
plugin_count=0
installed_json="$CLAUDE_HOME/plugins/installed_plugins.json"
if [ -f "$installed_json" ]; then
  plugin_count=$(python3 -c "import json; d=json.load(open('$installed_json')); print(len(d.get('plugins',{})))" 2>/dev/null || echo 0)
fi

# Detect duplicate plugin names across marketplaces
plugin_dups=0
if [ -f "$installed_json" ]; then
  plugin_dups=$(python3 -c "
import json
d = json.load(open('$installed_json'))
names = [k.split('@')[0] for k in d.get('plugins', {})]
dups = {n for n in set(names) if names.count(n) > 1}
print(len(dups))
" 2>/dev/null || echo 0)
fi

# ---------- 4. MCP servers ----------
mcp_user=0
mcp_project=0
claude_json="$HOME/.claude.json"
if [ -f "$claude_json" ]; then
  mcp_user=$(python3 -c "
import json
d = json.load(open('$claude_json'))
print(len(d.get('mcpServers', {})))
" 2>/dev/null || echo 0)
  mcp_project=$(python3 -c "
import json
d = json.load(open('$claude_json'))
total = 0
for p, pd in d.get('projects', {}).items():
    total += len(pd.get('mcpServers', {}))
print(total)
" 2>/dev/null || echo 0)
fi
mcp_total=$((mcp_user + mcp_project))

# ---------- 5. Skills ----------
skills_total=$(count_dir "$CLAUDE_HOME/skills")
dead_symlinks=0
if [ -d "$CLAUDE_HOME/skills" ]; then
  for s in "$CLAUDE_HOME/skills"/*; do
    [ -L "$s" ] && [ ! -e "$s" ] && dead_symlinks=$((dead_symlinks+1))
  done
fi

# ---------- 6. Commands/ big packs (scientific-skills-style) ----------
commands_subdirs=0
if [ -d "$CLAUDE_HOME/commands" ]; then
  # Count subdirs that look like skill packs (>20 children themselves)
  while IFS= read -r -d '' d; do
    children=$(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    [ "$children" -gt 20 ] && commands_subdirs=$((commands_subdirs+1))
  done < <(find "$CLAUDE_HOME/commands" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

# ---------- 7. Hooks ----------
hooks_active=0
for f in "$CLAUDE_HOME/settings.json" "$CLAUDE_HOME/settings.local.json"; do
  [ -f "$f" ] || continue
  count=$(python3 -c "
import json
d = json.load(open('$f'))
hooks = d.get('hooks', {})
total = sum(len(v) if isinstance(v, list) else 1 for v in hooks.values())
print(total)
" 2>/dev/null || echo 0)
  hooks_active=$((hooks_active + count))
done

# ---------- 8. Archive existence ----------
archive_exists="no"
ls -d "$CLAUDE_HOME"/_tokenslim_archive_* >/dev/null 2>&1 && archive_exists="yes"

# ---------- report ----------
cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║         Boris-Token-Slim  ·  Claude Code Overhead Audit      ║
╚══════════════════════════════════════════════════════════════╝

Metric                              Value        Target       Status
─────────────────────────────────── ──────────── ──────────── ──────────
1. CLAUDE.md bytes                  $(printf '%-12s' "$claude_md_bytes")  < 1500        $(flag "$claude_md_bytes" 1500 over)
2. MEMORY.md bytes                  $(printf '%-12s' "$memory_md_bytes")  < 2000        $(flag "$memory_md_bytes" 2000 over)
   Extra .md files in memory dir    $(printf '%-12s' "$memory_extra_files")  < 15          $(flag "$memory_extra_files" 15 over)
3. Installed plugins                $(printf '%-12s' "$plugin_count")  < 15          $(flag "$plugin_count" 15 over)
   Duplicate plugin names           $(printf '%-12s' "$plugin_dups")  0             $(flag "$plugin_dups" 0 over)
4. MCP servers (user scope)         $(printf '%-12s' "$mcp_user")  < 4           $(flag "$mcp_user" 4 over)
   MCP servers (project scope)      $(printf '%-12s' "$mcp_project")  varies        —
   MCP total                        $(printf '%-12s' "$mcp_total")  < 6           $(flag "$mcp_total" 6 over)
5. Skills in ~/.claude/skills/      $(printf '%-12s' "$skills_total")  < 50          $(flag "$skills_total" 50 over)
   Dead symlinks (broken)           $(printf '%-12s' "$dead_symlinks")  0             $(flag "$dead_symlinks" 0 over)
6. Big packs in ~/.claude/commands/ $(printf '%-12s' "$commands_subdirs")  0             $(flag "$commands_subdirs" 0 over)
7. Active settings.json hooks       $(printf '%-12s' "$hooks_active")  < 3           $(flag "$hooks_active" 3 over)
8. Prior slim archive exists        $(printf '%-12s' "$archive_exists")  —            —

EOF

# Summary advice
echo "Recommendations:"
[ "$claude_md_bytes" -gt 1500 ]      && echo "  • CLAUDE.md 超标：删 Anthropic 博客最佳实践照搬段、废弃模块配置、skill 触发说明"
[ "$memory_md_bytes" -gt 2000 ]      && echo "  • MEMORY.md 超标：归档已完成项目状态快照，只留 feedback/reference"
[ "$memory_extra_files" -gt 15 ]     && echo "  • memory 目录 md 文件太多：归档到 archive/ 子目录"
[ "$plugin_count" -gt 15 ]           && echo "  • 插件太多：检查金融套件/HuggingFace 子套件/同名重复装"
[ "$plugin_dups" -gt 0 ]             && echo "  • 有同名插件装了两次：$(python3 -c "import json; d=json.load(open('$installed_json')); names=[k.split('@')[0] for k in d.get('plugins',{})]; print(','.join(sorted({n for n in set(names) if names.count(n)>1})))")"
[ "$mcp_total" -gt 6 ]               && echo "  • MCP 常驻太多：task-master-ai / chrome-devtools 等低频可按需启用"
[ "$skills_total" -gt 50 ]           && echo "  • 本地 skill 数量大：分类批量归档（perspective 系列 / 编程角色短名 / 写作全家桶等）"
[ "$dead_symlinks" -gt 0 ]           && echo "  • 有 $dead_symlinks 个死 symlink：直接 rm 安全，它们只占清单位置"
[ "$commands_subdirs" -gt 0 ]        && echo "  • commands/ 下有大类 skill pack（如 scientific-skills）：整目录挪到 ~/.claude/_commands_archive/（注意不要放 commands/_archive）"
[ "$hooks_active" -gt 3 ]            && echo "  • hooks 多：审计每个 UserPromptSubmit hook 是否真的每次都需要"

echo ""
echo "Run 'claude' and say \"/Boris-Token-Slim\" to start guided cleanup."
echo ""
