#!/usr/bin/env bash
# Boris-Token-Slim audit script
# Two layers:
#   1. Nine static metrics (sizes, counts, thresholds)
#   2. Nine gotcha detectors (concrete evidence: paths, names, line numbers)
# Exit code 0 always — this is a report, not a gate.

set -u

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
MEMORY_DIR="${MEMORY_DIR:-$CLAUDE_HOME/projects/-Users-$USER/memory}"
INSTALLED_JSON="$CLAUDE_HOME/plugins/installed_plugins.json"
CLAUDE_CONFIG="$HOME/.claude.json"

# ---------- helpers ----------
bytes_of() {
  local f="$1"
  [ -f "$f" ] && wc -c < "$f" | tr -d ' ' || echo 0
}

flag_over() {
  [ "$1" -gt "$2" ] && echo "⚠️ over" || echo "✅ ok"
}

count_dir() {
  [ -d "$1" ] && ls "$1" 2>/dev/null | wc -l | tr -d ' ' || echo 0
}

py() { python3 -c "$1" 2>/dev/null; }

# ============================================================================
# LAYER 1 · Nine static metrics
# ============================================================================
claude_md_bytes=$(bytes_of "$CLAUDE_HOME/CLAUDE.md")

memory_md=""
for c in "$MEMORY_DIR/MEMORY.md" "$CLAUDE_HOME/memory/MEMORY.md"; do
  [ -f "$c" ] && memory_md="$c" && break
done
memory_md_bytes=$(bytes_of "$memory_md")
memory_extra_files=0
[ -n "$memory_md" ] && memory_extra_files=$(find "$(dirname "$memory_md")" -maxdepth 1 -name "*.md" ! -name "MEMORY.md" 2>/dev/null | wc -l | tr -d ' ')

plugin_count=0
[ -f "$INSTALLED_JSON" ] && plugin_count=$(py "import json; print(len(json.load(open('$INSTALLED_JSON')).get('plugins',{})))")
plugin_count="${plugin_count:-0}"

mcp_user=0
mcp_project=0
if [ -f "$CLAUDE_CONFIG" ]; then
  mcp_user=$(py "import json; d=json.load(open('$CLAUDE_CONFIG')); print(len(d.get('mcpServers',{})))")
  mcp_project=$(py "import json; d=json.load(open('$CLAUDE_CONFIG')); print(sum(len(p.get('mcpServers',{})) for p in d.get('projects',{}).values()))")
fi
mcp_user="${mcp_user:-0}"
mcp_project="${mcp_project:-0}"
mcp_total=$((mcp_user + mcp_project))

skills_total=$(count_dir "$CLAUDE_HOME/skills")
dead_symlinks=0
if [ -d "$CLAUDE_HOME/skills" ]; then
  for s in "$CLAUDE_HOME/skills"/*; do
    [ -L "$s" ] && [ ! -e "$s" ] && dead_symlinks=$((dead_symlinks+1))
  done
fi

commands_subdirs=0
if [ -d "$CLAUDE_HOME/commands" ]; then
  while IFS= read -r -d '' d; do
    children=$(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    [ "$children" -gt 20 ] && commands_subdirs=$((commands_subdirs+1))
  done < <(find "$CLAUDE_HOME/commands" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

hooks_active=0
for f in "$CLAUDE_HOME/settings.json" "$CLAUDE_HOME/settings.local.json"; do
  [ -f "$f" ] || continue
  c=$(py "import json; d=json.load(open('$f')); h=d.get('hooks',{}); print(sum(len(v) if isinstance(v,list) else 1 for v in h.values()))")
  hooks_active=$((hooks_active + ${c:-0}))
done

# ---------- print metrics ----------
cat <<EOF

╔══════════════════════════════════════════════════════════════════════╗
║         Boris-Token-Slim · Claude Code Overhead Audit                ║
╚══════════════════════════════════════════════════════════════════════╝

PART 1 · Nine static metrics

Metric                              Value        Target       Status
─────────────────────────────────── ──────────── ──────────── ──────────
1. CLAUDE.md bytes                  $(printf '%-12s' "$claude_md_bytes")  < 1500        $(flag_over "$claude_md_bytes" 1500)
2. MEMORY.md bytes                  $(printf '%-12s' "$memory_md_bytes")  < 2000        $(flag_over "$memory_md_bytes" 2000)
   Extra .md files in memory dir    $(printf '%-12s' "$memory_extra_files")  < 15          $(flag_over "$memory_extra_files" 15)
3. Installed plugins                $(printf '%-12s' "$plugin_count")  < 15          $(flag_over "$plugin_count" 15)
4. MCP servers (user scope)         $(printf '%-12s' "$mcp_user")  < 4           $(flag_over "$mcp_user" 4)
   MCP servers (project scope)      $(printf '%-12s' "$mcp_project")  varies        —
   MCP total                        $(printf '%-12s' "$mcp_total")  < 6           $(flag_over "$mcp_total" 6)
5. Skills in ~/.claude/skills/      $(printf '%-12s' "$skills_total")  < 50          $(flag_over "$skills_total" 50)
6. Big packs in ~/.claude/commands/ $(printf '%-12s' "$commands_subdirs")  0             $(flag_over "$commands_subdirs" 0)
7. Active settings.json hooks       $(printf '%-12s' "$hooks_active")  < 3           $(flag_over "$hooks_active" 3)

EOF

# ============================================================================
# LAYER 2 · Seven gotcha detectors
# Each prints concrete evidence (paths, names) the user can act on.
# ============================================================================
echo "PART 2 · Nine gotcha detectors (with locatable evidence)"
echo "          (dead symlinks · _archive trap · sub-plugin explosion ·"
echo "           same-name plugin · project-scope MCP · zombie configs ·"
echo "           archive layout · MCP zombie resurrection · embedded sub-skills)"
echo ""

issues=0

print_finding() {
  local title="$1" details="$2"
  issues=$((issues+1))
  echo "┌─ Gotcha #$issues · $title"
  while IFS= read -r line; do
    echo "│  $line"
  done <<< "$details"
  echo "└─"
  echo ""
}

# ---------- Gotcha 1: dead symlinks ----------
if [ "$dead_symlinks" -gt 0 ]; then
  details="$dead_symlinks broken symlinks in ~/.claude/skills/ pointing to non-existent targets:"
  count=0
  for s in "$CLAUDE_HOME/skills"/*; do
    if [ -L "$s" ] && [ ! -e "$s" ]; then
      target=$(readlink "$s" 2>/dev/null || echo "?")
      details+=$'\n'"  $(basename "$s") -> $target"
      count=$((count+1))
      [ "$count" -ge 8 ] && details+=$'\n'"  ... ($((dead_symlinks - 8)) more)" && break
    fi
  done
  details+=$'\n'""
  details+=$'\n'"Fix: bash scripts/archive-helper.sh clean-dead"
  print_finding "Dead symlinks (zero-risk to remove)" "$details"
fi

# ---------- Gotcha 2: commands/_archive trap ----------
trap_dirs=()
if [ -d "$CLAUDE_HOME/commands" ]; then
  while IFS= read -r -d '' d; do
    bn=$(basename "$d")
    case "$bn" in
      _archive*|archive*|_old*|.archive*|backup*)
        trap_dirs+=("$d")
        ;;
    esac
  done < <(find "$CLAUDE_HOME/commands" -mindepth 1 -maxdepth 2 -type d -print0 2>/dev/null)
fi
if [ ${#trap_dirs[@]} -gt 0 ]; then
  details="Found archive-like dirs INSIDE ~/.claude/commands/ — these are still scanned by the harness."
  details+=$'\n'"Worse: skill names get prefixed with the dir name (e.g. _archive:scientific-skills:...) making tokens HIGHER not lower."
  details+=$'\n'""
  for d in "${trap_dirs[@]}"; do
    n=$(find "$d" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
    details+=$'\n'"  $d  ($n items inside)"
  done
  details+=$'\n'""
  details+=$'\n'"Fix: mv $CLAUDE_HOME/commands/_archive $CLAUDE_HOME/_commands_archive"
  print_finding "commands/_archive trap (archive INSIDE commands/)" "$details"
fi

# Same trap for skills/
skills_trap=()
if [ -d "$CLAUDE_HOME/skills" ]; then
  while IFS= read -r -d '' d; do
    bn=$(basename "$d")
    case "$bn" in
      _archive*|archive*|_old*|backup*)
        skills_trap+=("$d")
        ;;
    esac
  done < <(find "$CLAUDE_HOME/skills" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi
if [ ${#skills_trap[@]} -gt 0 ]; then
  details="Found archive-like dirs INSIDE ~/.claude/skills/ — same problem."
  details+=$'\n'""
  for d in "${skills_trap[@]}"; do
    n=$(find "$d" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
    details+=$'\n'"  $d  ($n items inside)"
  done
  details+=$'\n'""
  details+=$'\n'"Fix: mv $CLAUDE_HOME/skills/_archive $CLAUDE_HOME/_skills_archive"
  print_finding "skills/_archive trap (archive INSIDE skills/)" "$details"
fi

# ---------- Gotcha 3: sub-plugin explosion ----------
if [ -f "$INSTALLED_JSON" ]; then
  explosions=$(py "
import json
d = json.load(open('$INSTALLED_JSON'))
names = list(d.get('plugins', {}).keys())
from collections import defaultdict
groups = defaultdict(list)
for full in names:
    bare = full.split('@')[0]
    # Try multiple prefix lengths to catch e.g. 'hugging-face' (2) or 'agent-architecture' (1)
    for n in (3, 2, 1):
        parts = bare.split('-')
        if len(parts) > n:
            prefix = '-'.join(parts[:n])
            groups[prefix].append(full)
            break
# Report any prefix family with >=4 siblings
seen = set()
for prefix, members in sorted(groups.items(), key=lambda x: -len(x[1])):
    members = sorted(set(members))
    sig = tuple(members)
    if sig in seen: continue
    seen.add(sig)
    if len(members) >= 4:
        print(f'{prefix}|{len(members)}|' + ','.join(members))
")
  if [ -n "$explosions" ]; then
    details="Detected plugin family clusters with ≥4 siblings (likely a single umbrella plugin pulling in subs):"
    details+=$'\n'""
    while IFS='|' read -r prefix count members; do
      [ -z "$prefix" ] && continue
      details+=$'\n'"  $prefix-* family: $count plugins"
      i=0
      for m in $(echo "$members" | tr ',' ' '); do
        details+=$'\n'"    - $m"
        i=$((i+1))
        [ $i -ge 5 ] && details+=$'\n'"    - ..." && break
      done
    done <<< "$explosions"
    details+=$'\n'""
    details+=$'\n'"Fix: keep the umbrella entry (e.g. huggingface-skills), uninstall the siblings:"
    details+=$'\n'"     claude plugin uninstall -y <name>@<marketplace>"
    print_finding "Sub-plugin explosion" "$details"
  fi
fi

# ---------- Gotcha 4: same-name plugin from different marketplaces ----------
if [ -f "$INSTALLED_JSON" ]; then
  dups=$(py "
import json
d = json.load(open('$INSTALLED_JSON'))
names = [k.split('@') for k in d.get('plugins', {})]
from collections import defaultdict
seen = defaultdict(list)
for parts in names:
    if len(parts) == 2:
        bare, marketplace = parts
        seen[bare].append(marketplace)
for bare, mps in seen.items():
    if len(mps) > 1:
        print(f'{bare}|' + ','.join(mps))
")
  if [ -n "$dups" ]; then
    details="Same plugin name installed from MULTIPLE marketplaces (silent token duplication):"
    details+=$'\n'""
    while IFS='|' read -r bare mps; do
      [ -z "$bare" ] && continue
      details+=$'\n'"  $bare from: $(echo $mps | tr ',' ' / ')"
    done <<< "$dups"
    details+=$'\n'""
    details+=$'\n'"Fix: pick one marketplace, uninstall the other. Verify which is current with:"
    details+=$'\n'"     ls ~/.claude/plugins/cache/<marketplace>/<plugin>/"
    print_finding "Same-name plugin installed twice" "$details"
  fi
fi

# ---------- Gotcha 5: project-scope MCP hidden in ~/.claude.json ----------
if [ -f "$CLAUDE_CONFIG" ] && [ "$mcp_project" -gt 0 ]; then
  proj_mcps=$(py "
import json
d = json.load(open('$CLAUDE_CONFIG'))
for p, pd in d.get('projects', {}).items():
    mcps = pd.get('mcpServers', {})
    if mcps:
        for name in mcps:
            print(f'{p}|{name}')
")
  if [ -n "$proj_mcps" ]; then
    details="MCP servers configured in PROJECT scope (not visible via 'claude mcp remove' from other dirs):"
    details+=$'\n'""
    while IFS='|' read -r project mcpname; do
      [ -z "$project" ] && continue
      details+=$'\n'"  in $project:"
      details+=$'\n'"    $mcpname"
    done <<< "$proj_mcps"
    details+=$'\n'""
    details+=$'\n'"These auto-activate when you cd into the matching project. To audit/move:"
    details+=$'\n'"  python3 -c \"import json; d=json.load(open('~/.claude.json')); ...\" or edit ~/.claude.json directly."
    print_finding "Project-scope MCP servers (silently active)" "$details"
  fi
fi

# ---------- Gotcha 6: zombie configs (CLAUDE.md mentions a module MEMORY says is removed) ----------
zombie_terms=()
if [ -f "$memory_md" ] && [ -f "$CLAUDE_HOME/CLAUDE.md" ]; then
  # Look for "removed" / "已移除" / "deprecated" / "已废弃" patterns in memory-dir markdown,
  # extract the module name, then grep CLAUDE.md for it.
  candidates=$(grep -ohiE '([a-zA-Z][a-zA-Z0-9_-]{3,30})[^.]{0,40}(已移除|已废弃|removed|deprecated|completely removed)' \
    "$memory_md" "$(dirname "$memory_md")"/*.md 2>/dev/null | \
    grep -ohE '[a-zA-Z][a-zA-Z0-9_-]{3,30}' | sort -u)
  for term in $candidates; do
    # Skip super-common words
    case "$(echo "$term" | tr A-Z a-z)" in
      removed|deprecated|module|skill|plugin|config|the|already|completely|note|fix|status|done) continue ;;
    esac
    if grep -qiE "\b$term\b" "$CLAUDE_HOME/CLAUDE.md" 2>/dev/null; then
      zombie_terms+=("$term")
    fi
  done
fi
if [ ${#zombie_terms[@]} -gt 0 ]; then
  details="MEMORY notes say these modules are removed/deprecated, but CLAUDE.md still mentions them:"
  details+=$'\n'""
  for t in "${zombie_terms[@]}"; do
    line=$(grep -niE "\b$t\b" "$CLAUDE_HOME/CLAUDE.md" | head -2)
    details+=$'\n'"  $t found at:"
    while IFS= read -r ln; do
      details+=$'\n'"    CLAUDE.md:$ln"
    done <<< "$line"
  done
  details+=$'\n'""
  details+=$'\n'"Fix: edit ~/.claude/CLAUDE.md and remove the zombie sections."
  print_finding "Zombie configs (CLAUDE.md ↔ MEMORY conflict)" "$details"
fi

# ---------- Gotcha 7: archive in wrong location ----------
wrong_archives=()
for d in "$CLAUDE_HOME"/skills/_archive* "$CLAUDE_HOME"/commands/_archive* \
         "$CLAUDE_HOME"/skills/archive* "$CLAUDE_HOME"/commands/archive*; do
  [ -e "$d" ] && wrong_archives+=("$d")
done
# These are caught by Gotcha 2 but listed here as policy violation
# (intentionally complementary — Gotcha 2 reports the trap, Gotcha 7
# checks adherence to the recommended layout from references/archive-layout.md)
if [ ${#wrong_archives[@]} -eq 0 ]; then
  # Look for proper Boris-Token-Slim archive existence — informational only
  if ls -d "$CLAUDE_HOME"/_tokenslim_archive_* >/dev/null 2>&1; then
    arch_count=$(ls -d "$CLAUDE_HOME"/_tokenslim_archive_* 2>/dev/null | wc -l | tr -d ' ')
    arch_size=$(du -sh "$CLAUDE_HOME"/_tokenslim_archive_* 2>/dev/null | tail -1 | awk '{print $1}')
    : # no finding; show summary at end
  fi
fi

# ---------- Gotcha 8: MCP zombie resurrection (claude mcp remove not sticky) ----------
if [ -f "$CLAUDE_CONFIG" ] && command -v claude >/dev/null 2>&1; then
  # Compare what `claude mcp list` shows vs what's in ~/.claude.json
  config_mcps=$(py "
import json
d = json.load(open('$CLAUDE_CONFIG'))
mcps = set(d.get('mcpServers',{}).keys())
for p, pd in d.get('projects',{}).items():
    mcps |= set(pd.get('mcpServers',{}).keys())
print('\n'.join(sorted(mcps)))
")
  # Don't run claude mcp list (slow, may prompt) — instead grep plugin manifests
  # to detect MCPs registered via plugins (the actual root cause)
  plugin_mcps=""
  if [ -d "$CLAUDE_HOME/plugins/cache" ]; then
    plugin_mcps=$(find "$CLAUDE_HOME/plugins/cache" -name "plugin.json" -exec \
      grep -lE '"mcpServers"|"mcp"' {} + 2>/dev/null | head -10)
  fi
  if [ -n "$plugin_mcps" ]; then
    # For each plugin manifest with mcpServers, list which MCPs it declares
    declared=$(py "
import json, sys, glob
manifests = '''$plugin_mcps'''.strip().split('\n')
out = []
for path in manifests:
    if not path: continue
    try:
        d = json.load(open(path))
    except Exception:
        continue
    mcps = list((d.get('mcpServers') or {}).keys()) + list((d.get('mcp') or {}).keys() if isinstance(d.get('mcp'), dict) else [])
    if mcps:
        # Walk up two levels to get plugin@marketplace name
        parts = path.split('/cache/')[1].split('/')
        plugin = parts[1] if len(parts) > 1 else parts[0]
        marketplace = parts[0]
        out.append(f'{plugin}@{marketplace}|{\",\".join(mcps)}')
print('\n'.join(out))
")
    if [ -n "$declared" ]; then
      details="Plugins that auto-register MCP servers (will respawn after 'claude mcp remove'):"
      details+=$'\n'""
      while IFS='|' read -r plug mcps; do
        [ -z "$plug" ] && continue
        details+=$'\n'"  $plug → registers: $mcps"
      done <<< "$declared"
      details+=$'\n'""
      details+=$'\n'"To stop the resurrection, uninstall the plugin (not the MCP):"
      details+=$'\n'"  claude plugin uninstall -y <plugin>@<marketplace>"
      print_finding "Plugin-bundled MCP servers (zombie resurrection)" "$details"
    fi
  fi
fi

# ---------- Gotcha 9: plugin embeds many SKILL.md files (hidden sub-skills) ----------
if [ -d "$CLAUDE_HOME/plugins/cache" ] && [ -f "$INSTALLED_JSON" ]; then
  installed_set=$(py "
import json
d = json.load(open('$INSTALLED_JSON'))
print(' '.join(k.split('@')[0] for k in d.get('plugins',{}).keys()))
")
  embeds=$(for p in "$CLAUDE_HOME"/plugins/cache/*/*; do
    [ -d "$p" ] || continue
    plugin_name=$(basename "$p")
    n=$(find "$p" -name "SKILL.md" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -ge 5 ]; then
      # Check if still installed
      installed="?"
      if echo " $installed_set " | grep -q " $plugin_name "; then
        installed="installed"
      else
        installed="UNINSTALLED but cache remains"
      fi
      echo "$n|$(basename "$(dirname "$p")")/$plugin_name|$installed"
    fi
  done | sort -rn)
  if [ -n "$embeds" ]; then
    details="Plugins that bundle ≥5 SKILL.md files (count as 1 plugin but inflate skill scanning):"
    details+=$'\n'""
    while IFS='|' read -r n path status; do
      [ -z "$n" ] && continue
      details+=$'\n'"  $path: $n SKILL.md files  [$status]"
    done <<< "$embeds"
    details+=$'\n'""
    details+=$'\n'"For UNINSTALLED entries: cache remains on disk under ~/.claude/plugins/cache/."
    details+=$'\n'"  Safe to remove the directory once you confirm the plugin is gone:"
    details+=$'\n'"    rm -rf ~/.claude/plugins/cache/<marketplace>/<plugin-name>"
    details+=$'\n'""
    details+=$'\n'"For installed entries: consider whether you actually use all bundled skills."
    print_finding "Plugin embeds many sub-skills (hidden inflation + cache residue)" "$details"
  fi
fi

# ============================================================================
# Summary
# ============================================================================
if [ "$issues" -eq 0 ]; then
  echo "  ✅ No gotchas detected. (All seven detectors clean.)"
  echo ""
fi

echo ""
echo "─── Recommendations ────────────────────────────────────────────────"
[ "$claude_md_bytes" -gt 1500 ]      && echo "  • CLAUDE.md 超标：删 Anthropic 博客最佳实践照搬段、废弃模块配置、skill 触发说明"
[ "$memory_md_bytes" -gt 2000 ]      && echo "  • MEMORY.md 超标：归档已完成项目状态快照，只留 feedback/reference"
[ "$memory_extra_files" -gt 15 ]     && echo "  • memory 目录 md 文件太多：归档到 archive/ 子目录"
[ "$plugin_count" -gt 15 ]           && echo "  • 插件太多：检查金融套件/HuggingFace 子套件/同名重复装"
[ "$mcp_total" -gt 6 ]               && echo "  • MCP 常驻太多：task-master-ai / chrome-devtools 等低频可按需启用"
[ "$skills_total" -gt 50 ]           && echo "  • 本地 skill 数量大：分类批量归档（perspective 系列 / 编程角色短名 / 写作全家桶等）"
[ "$dead_symlinks" -gt 0 ]           && echo "  • $dead_symlinks 个死 symlink：bash scripts/archive-helper.sh clean-dead"
[ "$commands_subdirs" -gt 0 ]        && echo "  • commands/ 下有大类 skill pack：整目录挪到 ~/.claude/_commands_archive/"
[ "$hooks_active" -gt 3 ]            && echo "  • hooks 多：审计每个 UserPromptSubmit hook 是否真的每次都需要"

echo ""
if ls -d "$CLAUDE_HOME"/_tokenslim_archive_* >/dev/null 2>&1; then
  arch=$(ls -d "$CLAUDE_HOME"/_tokenslim_archive_* | sort -r | head -1)
  echo "Prior slim archive: $arch"
fi
echo ""
echo "Run 'claude' and say \"/Boris-Token-Slim\" to start guided cleanup."
echo "Run 'python3 scripts/analyze.py' for retrospective per-session token analysis."
echo ""
