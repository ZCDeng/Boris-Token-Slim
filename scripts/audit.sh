#!/usr/bin/env bash
# Boris-Token-Slim audit script
# Two layers:
#   1. Seven static metrics (sizes, counts, thresholds)
#   2. Nine gotcha detectors (concrete evidence: paths, names, line numbers)
# Exit code 0 always — this is a report, not a gate.

set -u

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
# Claude Code encodes the home path by replacing '/' with '-' (no leading dash).
# macOS: /Users/foo  -> Users-foo  -> dir is "-Users-foo"
# Linux: /home/foo   -> home-foo   -> dir is "-home-foo"
# Strip the leading slash before substitution so we get exactly one leading dash.
HOME_ENCODED="-${HOME#/}"
HOME_ENCODED="${HOME_ENCODED//\//-}"
MEMORY_DIR="${MEMORY_DIR:-$CLAUDE_HOME/projects/$HOME_ENCODED/memory}"
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

# pyf() — like py() but passes file paths as argv instead of interpolating them
# into the Python source. Use for any python3 invocation that needs to read a
# file. The script template should reference the path via sys.argv[1..N].
# Rationale: $HOME or filenames containing single quotes break the naive
# `open('$VAR')` pattern, silently producing empty output via 2>/dev/null.
pyf() {
  local script="$1"; shift
  python3 -c "$script" "$@" 2>/dev/null
}

# ============================================================================
# LAYER 1 · Seven static metrics
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
[ -f "$INSTALLED_JSON" ] && plugin_count=$(pyf 'import json,sys; d=json.load(open(sys.argv[1])); p=d.get("plugins") if isinstance(d,dict) else None; print(len(p) if isinstance(p,dict) else 0)' "$INSTALLED_JSON")
plugin_count="${plugin_count:-0}"

mcp_user=0
mcp_project=0
if [ -f "$CLAUDE_CONFIG" ]; then
  mcp_user=$(pyf 'import json,sys; d=json.load(open(sys.argv[1])); m=d.get("mcpServers") if isinstance(d,dict) else None; print(len(m) if isinstance(m,dict) else 0)' "$CLAUDE_CONFIG")
  mcp_project=$(pyf 'import json,sys; d=json.load(open(sys.argv[1])); projs=d.get("projects") if isinstance(d,dict) else {}; total=0
if isinstance(projs,dict):
    for p in projs.values():
        if isinstance(p,dict):
            m=p.get("mcpServers")
            if isinstance(m,dict): total+=len(m)
print(total)' "$CLAUDE_CONFIG")
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
  c=$(pyf 'import json,sys; d=json.load(open(sys.argv[1])); h=d.get("hooks",{}); print(sum(len(v) if isinstance(v,list) else 1 for v in h.values()))' "$f")
  hooks_active=$((hooks_active + ${c:-0}))
done

# ---------- print metrics ----------
cat <<EOF

╔══════════════════════════════════════════════════════════════════════╗
║         Boris-Token-Slim · Claude Code Overhead Audit                ║
╚══════════════════════════════════════════════════════════════════════╝

PART 1 · Seven static metrics

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
# LAYER 2 · Nine gotcha detectors
# Each prints concrete evidence (paths, names) the user can act on.
# ============================================================================
echo "PART 2 · Nine gotcha detectors (with locatable evidence)"
echo "          (dead symlinks · _archive trap · sub-plugin explosion ·"
echo "           same-name plugin · project-scope MCP · zombie configs ·"
echo "           MCP zombie resurrection · embedded sub-skills ·"
echo "           configured-but-uncalled MCP)"
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
  explosions=$(pyf "
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict): sys.exit(0)
plugins = d.get('plugins') or {}
if not isinstance(plugins, dict): sys.exit(0)
names = list(plugins.keys())
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
" "$INSTALLED_JSON")
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
  dups=$(pyf "
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict): sys.exit(0)
plugins = d.get('plugins') or {}
if not isinstance(plugins, dict): sys.exit(0)
names = [k.split('@') for k in plugins.keys()]
from collections import defaultdict
seen = defaultdict(list)
for parts in names:
    if len(parts) == 2:
        bare, marketplace = parts
        seen[bare].append(marketplace)
for bare, mps in seen.items():
    if len(mps) > 1:
        print(f'{bare}|' + ','.join(mps))
" "$INSTALLED_JSON")
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
  proj_mcps=$(pyf "
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict): sys.exit(0)
projects = d.get('projects') or {}
if not isinstance(projects, dict): sys.exit(0)
for p, pd in projects.items():
    if not isinstance(pd, dict): continue
    mcps = pd.get('mcpServers') or {}
    if not isinstance(mcps, dict): continue
    for name in mcps:
        print(f'{p}|{name}')
" "$CLAUDE_CONFIG")
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
  # Look for "X is removed/deprecated/已移除/已废弃" patterns in memory markdown
  # files. Only treat the FIRST identifier-shaped token at each match as a
  # candidate module name — extracting all 4–30-letter words from the match
  # context picks up English filler like "been" / "already" and produces
  # noisy false positives.
  #
  # The Python helper extracts module names cleanly. The fallback grep handles
  # systems without python3 in PATH (rare but possible).
  if command -v python3 >/dev/null 2>&1; then
    candidates=$(python3 - "$memory_md" "$(dirname "$memory_md")" <<'PYEOF' 2>/dev/null
import os, re, sys
mem = sys.argv[1]
mem_dir = sys.argv[2]
files = [mem]
if os.path.isdir(mem_dir):
    files += [os.path.join(mem_dir, f) for f in os.listdir(mem_dir)
              if f.endswith('.md') and os.path.join(mem_dir, f) != mem]
# Module name: identifier-shaped token at start of line OR following whitespace,
# immediately followed by " is/was/has been ... removed/deprecated/已移除/已废弃"
PATTERN = re.compile(
    r'(?:^|[ \t`*-])([A-Za-z][A-Za-z0-9_-]{3,30})[ \t][^.\n\r]{0,40}?'
    r'(?:已移除|已废弃|is removed|was removed|been removed|completely removed|is deprecated|was deprecated|been deprecated)',
    re.IGNORECASE | re.MULTILINE,
)
seen = set()
for path in files:
    try:
        with open(path, encoding='utf-8', errors='ignore') as f:
            text = f.read()
    except (OSError, IOError):
        continue
    for m in PATTERN.finditer(text):
        seen.add(m.group(1))
for t in sorted(seen):
    print(t)
PYEOF
)
  else
    # Fallback: original two-grep pattern (noisier but works without python3).
    candidates=$(grep -ohiE '([a-zA-Z][a-zA-Z0-9_-]{3,30})[^.]{0,40}(已移除|已废弃|removed|deprecated|completely removed)' \
      "$memory_md" "$(dirname "$memory_md")"/*.md 2>/dev/null | \
      grep -ohE '[a-zA-Z][a-zA-Z0-9_-]{3,30}' | sort -u)
  fi
  for term in $candidates; do
    # Skip super-common English words that pass the regex but aren't module names
    case "$(echo "$term" | tr A-Z a-z)" in
      removed|deprecated|module|skill|plugin|config|the|already|completely|note|fix|status|done|been|have|has|was|were|that|this) continue ;;
    esac
    if grep -qiE "\\b$term\\b" "$CLAUDE_HOME/CLAUDE.md" 2>/dev/null; then
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

# ---------- Gotcha 7: MCP zombie resurrection (claude mcp remove not sticky) ----------
# (Gotcha 2 already covers archive-in-wrong-location for commands/ and skills/.
# A separate "wrong archive layout" detector would only ever fire AS WELL AS
# Gotcha 2, never alone — so we don't carry a redundant numbered slot.)
if [ -f "$CLAUDE_CONFIG" ] && command -v claude >/dev/null 2>&1; then
  # Compare what `claude mcp list` shows vs what's in ~/.claude.json
  # config_mcps is computed for documentation / future use; not directly compared
  # against `claude mcp list` here (we instead grep plugin manifests below).
  config_mcps=$(pyf "
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict): sys.exit(0)
top = d.get('mcpServers') or {}
mcps = set(top.keys()) if isinstance(top, dict) else set()
projects = d.get('projects') or {}
if isinstance(projects, dict):
    for p, pd in projects.items():
        if isinstance(pd, dict):
            sub = pd.get('mcpServers') or {}
            if isinstance(sub, dict):
                mcps |= set(sub.keys())
print('\n'.join(sorted(mcps)))
" "$CLAUDE_CONFIG")
  # Don't run claude mcp list (slow, may prompt) — instead grep plugin manifests
  # to detect MCPs registered via plugins (the actual root cause)
  plugin_mcps=""
  if [ -d "$CLAUDE_HOME/plugins/cache" ]; then
    plugin_mcps=$(find "$CLAUDE_HOME/plugins/cache" -name "plugin.json" -exec \
      grep -lE '"mcpServers"|"mcp"' {} + 2>/dev/null)
  fi
  if [ -n "$plugin_mcps" ]; then
    # Pass manifest paths via stdin as JSON array (avoid f-string injection
    # from filenames containing quotes/backslashes/newlines).
    declared=$(printf '%s\n' "$plugin_mcps" | python3 -c "
import json, sys
manifests = [line for line in sys.stdin.read().splitlines() if line]
out = []
for path in manifests:
    try:
        d = json.load(open(path))
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    mcp_block = d.get('mcpServers')
    extra = d.get('mcp')
    mcps = []
    if isinstance(mcp_block, dict):
        mcps += list(mcp_block.keys())
    if isinstance(extra, dict):
        mcps += list(extra.keys())
    if not mcps:
        continue
    parts = path.split('/cache/')
    if len(parts) < 2: continue
    seg = parts[1].split('/')
    marketplace = seg[0]
    plugin = seg[1] if len(seg) > 1 else seg[0]
    out.append(f'{plugin}@{marketplace}|{\",\".join(mcps)}')
print('\n'.join(out))
" 2>/dev/null)
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

# ---------- Gotcha 8: plugin embeds many SKILL.md files (hidden sub-skills) ----------
if [ -d "$CLAUDE_HOME/plugins/cache" ] && [ -f "$INSTALLED_JSON" ]; then
  installed_set=$(pyf "
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict): sys.exit(0)
plugins = d.get('plugins') or {}
if not isinstance(plugins, dict): sys.exit(0)
print(' '.join(k.split('@')[0] for k in plugins.keys()))
" "$INSTALLED_JSON")
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
    details+=$'\n'"  Per iron rule 1 (archive, never delete), move — don't remove:"
    details+=$'\n'"    ARCH=~/.claude/_tokenslim_archive_\$(date +%Y%m%d)/cache && mkdir -p \"\$ARCH\""
    details+=$'\n'"    mv ~/.claude/plugins/cache/<marketplace>/<plugin-name> \"\$ARCH/\""
    details+=$'\n'""
    details+=$'\n'"For installed entries: consider whether you actually use all bundled skills."
    print_finding "Plugin embeds many sub-skills (hidden inflation + cache residue)" "$details"
  fi
fi

# ---------- Gotcha 9: configured-but-uncalled MCP servers ----------
# Inspired by codeburn's detectUnusedMcp: cross-reference MCP servers in
# ~/.claude.json against actual mcp__<server>__* tool calls in the last 30
# days of transcripts. Servers configured but never called paid tool-schema
# tax every session for zero benefit.
ANALYZE_PY="$(dirname "$0")/analyze.py"
if [ -f "$CLAUDE_CONFIG" ] && [ -f "$ANALYZE_PY" ] && command -v python3 >/dev/null 2>&1; then
  configured_mcps=$(pyf "
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict): sys.exit(0)
out = set()
top = d.get('mcpServers') or {}
if isinstance(top, dict):
    out |= set(top.keys())
projs = d.get('projects') or {}
if isinstance(projs, dict):
    for pd in projs.values():
        if isinstance(pd, dict):
            sub = pd.get('mcpServers') or {}
            if isinstance(sub, dict):
                out |= set(sub.keys())
print('\n'.join(sorted(out)))
" "$CLAUDE_CONFIG")
  if [ -n "$configured_mcps" ]; then
    # Get actual call counts from analyze.py's --json
    called_json=$(python3 "$ANALYZE_PY" --days 30 --top 0 --json 2>/dev/null)
    if [ -n "$called_json" ]; then
      called_mcps=$(printf '%s' "$called_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
mcp = d.get("mcp_usage", {}).get("by_server", {})
for k, v in mcp.items():
    print(f"{k}\t{v}")
' 2>/dev/null)
      # Build lookup tables
      unused_servers=""
      while IFS= read -r srv; do
        [ -z "$srv" ] && continue
        # Check if srv appears in called_mcps
        if ! printf '%s' "$called_mcps" | awk -F'\t' -v s="$srv" '$1 == s { found=1 } END { exit !found }' 2>/dev/null; then
          unused_servers+="$srv"$'\n'
        fi
      done <<< "$configured_mcps"
      if [ -n "$unused_servers" ]; then
        details="MCP servers configured in ~/.claude.json but invoked 0 times in last 30 days of transcripts:"
        details+=$'\n'""
        while IFS= read -r srv; do
          [ -z "$srv" ] && continue
          details+=$'\n'"  $srv  (0 calls)"
        done <<< "$unused_servers"
        details+=$'\n'""
        details+=$'\n'"Each configured MCP ships its tool schema on every API call. Servers that"
        details+=$'\n'"never get invoked pay full schema tax for zero benefit — codeburn estimates"
        details+=$'\n'"~600 tokens per server per request."
        details+=$'\n'""
        details+=$'\n'"Fix: remove from user scope:"
        details+=$'\n'"  claude mcp remove <server>"
        details+=$'\n'"Or, if registered by a plugin (see Gotcha 7), uninstall the plugin instead."
        print_finding "Configured-but-uncalled MCP servers (codeburn-style)" "$details"
      fi
    fi
  fi
fi

# ============================================================================
# Summary
# ============================================================================
if [ "$issues" -eq 0 ]; then
  echo "  ✅ No gotchas detected. (All nine detectors clean.)"
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
