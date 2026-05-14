#!/usr/bin/env bash
# Boris-Token-Slim audit script
# Two layers:
#   1. Eight static metrics (sizes, counts, thresholds — including codeburn-inspired
#      CLAUDE.md @-import expansion and BASH_MAX_OUTPUT_LENGTH cap)
#   2. Fifteen gotcha detectors (concrete evidence: paths, names, line numbers)
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
# LAYER 1 · Static metrics
# ============================================================================
claude_md_bytes=$(bytes_of "$CLAUDE_HOME/CLAUDE.md")

# CLAUDE.md @-import expansion (codeburn-inspired): a CLAUDE.md that imports
# other markdown via lines like '@./imports/foo.md' or '@/abs/path.md' loads
# all of those files' contents into every API call. We compute the total
# expanded line count (with cycle detection, max depth 5).
claude_md_expanded_lines=0
claude_md_imports=0
if [ -f "$CLAUDE_HOME/CLAUDE.md" ] && command -v python3 >/dev/null 2>&1; then
  read -r claude_md_expanded_lines claude_md_imports <<<$(pyf '
import os, re, sys
ROOT = sys.argv[1]
PATTERN = re.compile(r"^@(\.\.?/[^\s]+|/[^\s]+)", re.MULTILINE)
MAX_DEPTH = 5
def expand(path, seen, depth):
    if depth > MAX_DEPTH or path in seen: return (0, 0)
    seen.add(path)
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except (OSError, IOError):
        return (0, 0)
    lines = text.count("\n") + 1
    imports = 0
    base = os.path.dirname(path)
    for m in PATTERN.finditer(text):
        raw = m.group(1)
        resolved = raw if raw.startswith("/") else os.path.normpath(os.path.join(base, raw))
        if not os.path.exists(resolved): continue
        nl, ni = expand(resolved, seen, depth+1)
        lines += nl
        imports += 1 + ni
    return (lines, imports)
total_lines, total_imports = expand(ROOT, set(), 0)
print(f"{total_lines} {total_imports}")
' "$CLAUDE_HOME/CLAUDE.md")
  claude_md_expanded_lines="${claude_md_expanded_lines:-0}"
  claude_md_imports="${claude_md_imports:-0}"
fi

# Bash output limit (codeburn-inspired): if BASH_MAX_OUTPUT_LENGTH > 30K
# (the default cap), every bash tool call's tail is uncapped noise that
# pads context. Codeburn's empirical recommendation is 15K.
bash_output_limit=0
bash_output_source="default"
for profile in .zshrc .bashrc .bash_profile .profile; do
  pf="$HOME/$profile"
  [ -f "$pf" ] || continue
  # Look for `export BASH_MAX_OUTPUT_LENGTH=<n>`
  found=$(grep -E '^[[:space:]]*export[[:space:]]+BASH_MAX_OUTPUT_LENGTH[[:space:]]*=[[:space:]]*["'\'']?[0-9]+' "$pf" 2>/dev/null | tail -1 | sed -E 's/.*=[[:space:]]*["'\'']?([0-9]+).*/\1/')
  if [ -n "$found" ]; then
    bash_output_limit="$found"
    bash_output_source="~/$profile"
    break
  fi
done
if [ "$bash_output_limit" = "0" ] && [ -n "${BASH_MAX_OUTPUT_LENGTH:-}" ]; then
  bash_output_limit="$BASH_MAX_OUTPUT_LENGTH"
  bash_output_source="env BASH_MAX_OUTPUT_LENGTH"
fi
[ "$bash_output_limit" = "0" ] && bash_output_limit=30000  # default

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

EOF

# 30-day fact-driven headline (pure-fact, no estimation).
# BORIS_STATS_DISABLE=1 → read-only diagnostic — ledger is not polluted
# by daily automate runs. Silent-fail on missing analyze.py or empty
# ~/.claude/projects/ so audit.sh never breaks on the headline path.
headline=$(BORIS_STATS_DISABLE=1 python3 "$(dirname "$0")/analyze.py" --headline --days 30 2>/dev/null)
[ -n "$headline" ] && printf '\n  %s\n' "$headline"

cat <<EOF
PART 1 · Eight static metrics

Metric                              Value        Target       Status
─────────────────────────────────── ──────────── ──────────── ──────────
1. CLAUDE.md bytes                  $(printf '%-12s' "$claude_md_bytes")  < 1500        $(flag_over "$claude_md_bytes" 1500)
   CLAUDE.md @-import expanded ln   $(printf '%-12s' "$claude_md_expanded_lines")  < 200         $(flag_over "$claude_md_expanded_lines" 200)
   CLAUDE.md @-imports              $(printf '%-12s' "$claude_md_imports")  varies        —
2. MEMORY.md bytes                  $(printf '%-12s' "$memory_md_bytes")  < 2000        $(flag_over "$memory_md_bytes" 2000)
   Extra .md files in memory dir    $(printf '%-12s' "$memory_extra_files")  < 15          $(flag_over "$memory_extra_files" 15)
3. Installed plugins                $(printf '%-12s' "$plugin_count")  < 15          $(flag_over "$plugin_count" 15)
4. MCP servers (user scope)         $(printf '%-12s' "$mcp_user")  < 4           $(flag_over "$mcp_user" 4)
   MCP servers (project scope)      $(printf '%-12s' "$mcp_project")  varies        —
   MCP total                        $(printf '%-12s' "$mcp_total")  < 6           $(flag_over "$mcp_total" 6)
5. Skills in ~/.claude/skills/      $(printf '%-12s' "$skills_total")  < 50          $(flag_over "$skills_total" 50)
6. Big packs in ~/.claude/commands/ $(printf '%-12s' "$commands_subdirs")  0             $(flag_over "$commands_subdirs" 0)
7. Active settings.json hooks       $(printf '%-12s' "$hooks_active")  < 3           $(flag_over "$hooks_active" 3)
8. Bash output limit                $(printf '%-12s' "$bash_output_limit")  ≤ 15000       $(flag_over "$bash_output_limit" 15000)
   ↳ source: $bash_output_source

EOF

# ============================================================================
# LAYER 2 · Fourteen gotcha detectors
# Each prints concrete evidence (paths, names) the user can act on.
# ============================================================================
echo "PART 2 · Fifteen gotcha detectors (with locatable evidence)"
echo "          (dead symlinks · _archive trap · sub-plugin explosion ·"
echo "           same-name plugin · project-scope MCP · zombie configs ·"
echo "           MCP zombie resurrection · embedded sub-skills ·"
echo "           configured-but-uncalled MCP · junk reads · duplicate reads ·"
echo "           oversized skill descriptions · YAML pitfalls · whitelist orphans ·"
echo "           cache-prefix poisoning)"
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

# ---------- Gotcha 10: junk reads (build/dependency directory traversal) ----------
# Codeburn-inspired: scan transcripts for Read/Grep/Glob calls into
# node_modules/.git/dist/etc. These dirs are generated/dependency content
# Claude almost never needs to introspect; each read is ~600 tokens of fluff.
if [ -f "$ANALYZE_PY" ] && command -v python3 >/dev/null 2>&1; then
  # Reuse called_json if Gotcha 9 already computed it; else compute here
  if [ -z "${called_json:-}" ]; then
    called_json=$(python3 "$ANALYZE_PY" --days 30 --top 0 --json 2>/dev/null)
  fi
  if [ -n "${called_json:-}" ]; then
    junk_summary=$(printf '%s' "$called_json" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
junk = d.get("junk_reads", {})
total = junk.get("total", 0)
by_dir = junk.get("by_dir", {})
if total < 3: sys.exit(0)
print(f"TOTAL\t{total}")
for k, v in by_dir.items():
    print(f"DIR\t{k}\t{v}")
' 2>/dev/null)
    if [ -n "$junk_summary" ]; then
      junk_total=$(printf '%s' "$junk_summary" | awk -F'\t' '/^TOTAL/{print $2}')
      details="Claude read $junk_total times into build/dependency directories (last 30 days):"
      details+=$'\n'""
      while IFS=$'\t' read -r kind dir count; do
        [ "$kind" = "DIR" ] || continue
        details+=$'\n'"  $dir/  ${count}× reads"
      done <<< "$junk_summary"
      est=$((junk_total * 600))
      details+=$'\n'""
      details+=$'\n'"Estimated waste: ~${est} tokens (codeburn baseline ~600 tok/read)."
      details+=$'\n'""
      details+=$'\n'"Fix: append to your project CLAUDE.md:"
      details+=$'\n'"  Do not read or search files under these directories unless I explicitly ask:"
      top_dirs=$(printf '%s' "$junk_summary" | awk -F'\t' '/^DIR/{print $2}' | head -6 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
      details+=$'\n'"  $top_dirs"
      print_finding "Reads into build/dependency dirs (codeburn-style)" "$details"
    fi
  fi
fi

# ---------- Gotcha 11: duplicate reads (same file re-read in one session) ----------
if [ -f "$ANALYZE_PY" ] && command -v python3 >/dev/null 2>&1; then
  if [ -z "${called_json:-}" ]; then
    called_json=$(python3 "$ANALYZE_PY" --days 30 --top 0 --json 2>/dev/null)
  fi
  if [ -n "${called_json:-}" ]; then
    dup_summary=$(printf '%s' "$called_json" | python3 -c '
import json, sys, os
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
dups = d.get("duplicate_reads", [])
if not dups: sys.exit(0)
HOME = os.path.expanduser("~")
print(f"COUNT\t{len(dups)}")
total_extra = 0
for entry in dups:
    fp = entry["file"]
    if fp.startswith(HOME): fp = "~" + fp[len(HOME):]
    if len(fp) > 60: fp = "…" + fp[-58:]
    cnt = entry["count"]
    sid = entry["session_id"][:8]
    total_extra += (cnt - 1)
    print(f"FILE\t{cnt}\t{fp}\t{sid}")
print(f"TOTAL_EXTRA\t{total_extra}")
' 2>/dev/null)
    if [ -n "$dup_summary" ]; then
      dup_count=$(printf '%s' "$dup_summary" | awk -F'\t' '/^COUNT/{print $2}')
      total_extra=$(printf '%s' "$dup_summary" | awk -F'\t' '/^TOTAL_EXTRA/{print $2}')
      details="$dup_count files re-read ≥3 times within a single session (last 30 days):"
      details+=$'\n'""
      shown=0
      while IFS=$'\t' read -r kind cnt fp sid; do
        [ "$kind" = "FILE" ] || continue
        details+=$'\n'"  ${cnt}× $fp  [session ${sid}…]"
        shown=$((shown+1))
        [ "$shown" -ge 6 ] && break
      done <<< "$dup_summary"
      [ "$dup_count" -gt "$shown" ] && details+=$'\n'"  ... ($((dup_count - shown)) more)"
      est=$((total_extra * 600))
      details+=$'\n'""
      details+=$'\n'"Estimated waste: ~${est} tokens spent re-reading content already in cache."
      details+=$'\n'""
      details+=$'\n'"Fixes:"
      details+=$'\n'"  • Tools that auto-re-read MEMORY.md every turn (mempalace, claude-mem) are"
      details+=$'\n'"    common culprits — verify they actually need full re-read each time."
      details+=$'\n'"  • Within Claude, prompt 'use the version you already have' before re-Read."
      print_finding "Duplicate file reads in same session (codeburn-style)" "$details"
    fi
  fi
fi

# ---------- Gotchas 12, 13, 14: skill description + whitelist audit ----------
# One Python pass walks ~/.claude/skills/* and emits three TSV sections:
#   OVERSIZED_*  — descriptions > 300 chars (per-session token burn)
#   YAML_TRAP_*  — three patterns that silently break strict YAML parsers
#   ORPHAN_*     — user-invocable-skills.json entries pointing at missing dirs
desc_audit=""
if [ -d "$CLAUDE_HOME/skills" ] && command -v python3 >/dev/null 2>&1; then
  desc_audit=$(pyf '
import os, re, json, sys
skills_dir = sys.argv[1]
whitelist = sys.argv[2]

FM_RE = re.compile(r"^---\n(.*?)\n---", re.S)
RE_LEADING_QUOTE_TRUNC = re.compile(r"^\"[^\"\n]+\"\s*\S+")
RE_MIDLINE_LABEL = re.compile(r" [A-Z][A-Za-z]+:\s")

def parse_description(fm_text):
    lines = fm_text.split("\n")
    for i, line in enumerate(lines):
        if not line.startswith("description:"):
            continue
        rest = line[len("description:"):].lstrip()
        if rest.startswith("|") or rest.startswith(">"):
            block = []
            for j in range(i + 1, len(lines)):
                ln = lines[j]
                if ln.startswith("  ") or ln.strip() == "":
                    block.append(ln.strip())
                else:
                    break
            return "\n".join(b for b in block if b), ["block-scalar"]
        traps = []
        if RE_LEADING_QUOTE_TRUNC.match(rest):
            traps.append("leading-quote-trunc")
        no_url = re.sub(r"https?://\S+", "", rest)
        if RE_MIDLINE_LABEL.search(" " + no_url):
            traps.append("mid-line-colon")
        return rest, traps
    return None, []

OVERSIZED, TRAPS, PRESENT = [], [], set()
try:
    entries = sorted(os.listdir(skills_dir))
except OSError:
    entries = []

for entry in entries:
    full = os.path.join(skills_dir, entry)
    if os.path.exists(full):
        PRESENT.add(entry)
    real = os.path.realpath(full)
    smd = os.path.join(real, "SKILL.md")
    if not os.path.isfile(smd):
        continue
    try:
        text = open(smd, encoding="utf-8", errors="ignore").read()
    except Exception:
        continue
    m = FM_RE.match(text)
    if not m:
        continue
    desc, traps = parse_description(m.group(1))
    if desc and len(desc) > 300:
        OVERSIZED.append((len(desc), entry))
    if traps:
        sample = (desc or "")[:60].replace("\t", " ").replace("\n", " ")
        TRAPS.append((entry, traps, sample))

OVERSIZED.sort(reverse=True)
print(f"OVERSIZED_COUNT\t{len(OVERSIZED)}")
print(f"OVERSIZED_TOTAL_CHARS\t{sum(s for s, _ in OVERSIZED)}")
for sz, name in OVERSIZED[:8]:
    print(f"OVERSIZED\t{sz}\t{name}")

print(f"YAML_TRAPS_COUNT\t{len(TRAPS)}")
for name, traps, sample in TRAPS[:8]:
    joined = ",".join(traps)
    print(f"YAML_TRAP\t{name}\t{joined}\t{sample}")

orphan_count = 0
orphans = []
if whitelist and os.path.isfile(whitelist):
    try:
        cfg = json.load(open(whitelist))
        listed = cfg.get("userInvokableSkills", [])
        if isinstance(listed, list):
            orphans = [s for s in listed if s not in PRESENT]
            orphan_count = len(orphans)
    except Exception:
        pass
print(f"ORPHAN_COUNT\t{orphan_count}")
for o in orphans[:8]:
    print(f"ORPHAN\t{o}")
' "$CLAUDE_HOME/skills" "$CLAUDE_HOME/user-invocable-skills.json")
fi

# ---------- Gotcha 12: oversized skill descriptions ----------
oversized_count=$(printf '%s' "$desc_audit" | awk -F'\t' '/^OVERSIZED_COUNT\t/{print $2; exit}')
oversized_total=$(printf '%s' "$desc_audit" | awk -F'\t' '/^OVERSIZED_TOTAL_CHARS\t/{print $2; exit}')
oversized_count="${oversized_count:-0}"
oversized_total="${oversized_total:-0}"
if [ "$oversized_count" -gt 0 ]; then
  details="$oversized_count skill description(s) > 300 chars (~75 tokens each — every enabled skill's description loads into every session's system-reminder):"
  details+=$'\n'""
  while IFS=$'\t' read -r kind sz name; do
    [ "$kind" = "OVERSIZED" ] || continue
    details+=$'\n'"  ${sz}c  $name"
  done <<< "$desc_audit"
  est_tokens=$((oversized_total / 4))
  details+=$'\n'""
  details+=$'\n'"Total over-threshold chars: $oversized_total (~${est_tokens} tokens / session, permanently)"
  details+=$'\n'""
  details+=$'\n'"Fix: see references/skill-description-slimming.md (compression rules + batch rewriter)."
  print_finding "Oversized skill descriptions (per-session token burn)" "$details"
fi

# ---------- Gotcha 13: YAML pitfalls in skill descriptions ----------
yaml_traps_count=$(printf '%s' "$desc_audit" | awk -F'\t' '/^YAML_TRAPS_COUNT\t/{print $2; exit}')
yaml_traps_count="${yaml_traps_count:-0}"
if [ "$yaml_traps_count" -gt 0 ]; then
  details="$yaml_traps_count skill description(s) match YAML pitfall patterns. Strict parsers (PyYAML) lose the description field even though Claude Code's permissive parser still renders it — downstream tooling silently breaks:"
  details+=$'\n'""
  while IFS=$'\t' read -r kind name traps sample; do
    [ "$kind" = "YAML_TRAP" ] || continue
    details+=$'\n'"  $name  [$traps]"
    [ -n "$sample" ] && details+=$'\n'"    sample: ${sample}..."
  done <<< "$desc_audit"
  details+=$'\n'""
  details+=$'\n'"Patterns:"
  details+=$'\n'"  • leading-quote-trunc  description: \"foo\"bar  (closing \" cuts the rest)"
  details+=$'\n'"  • mid-line-colon       description: ... Triggers: / Examples: / Note: ..."
  details+=$'\n'"  • block-scalar         description: |  (hidden newlines; prefer single-line)"
  details+=$'\n'""
  details+=$'\n'"Fix: see references/skill-description-slimming.md § YAML 写作陷阱."
  print_finding "YAML pitfalls in skill descriptions" "$details"
fi

# ---------- Gotcha 14: orphan slash-menu whitelist entries ----------
orphan_count=$(printf '%s' "$desc_audit" | awk -F'\t' '/^ORPHAN_COUNT\t/{print $2; exit}')
orphan_count="${orphan_count:-0}"
if [ "$orphan_count" -gt 0 ]; then
  details="$orphan_count entry(ies) in ~/.claude/user-invocable-skills.json point at non-existent skill dirs:"
  details+=$'\n'""
  while IFS=$'\t' read -r kind name; do
    [ "$kind" = "ORPHAN" ] || continue
    details+=$'\n'"  $name"
  done <<< "$desc_audit"
  details+=$'\n'""
  details+=$'\n'"Symptom: clicking the entry in / menu fails. Skills that were archived after the whitelist was written stay in the slash menu."
  details+=$'\n'"Fix: see references/gotchas.md § 坑 11 (one-liner cleanup script)."
  print_finding "Orphan slash-menu whitelist entries" "$details"
fi

# ---------- Gotcha 15: cache-prefix poisoning (volatile content in stable prefix) ----------
# Anthropic prompt caching hashes whole blocks. If any byte of CLAUDE.md / MEMORY.md
# mutates per session (today's date, "currentDate" injection, last-updated stamps),
# the entire block misses cache → 10x full input price instead of 0.1x cached read.
# Inspired by Ronin (@DeRonin_) "How To Cut Your AI Coding Bill by 80%" — leak #1:
# stable context re-sent every turn × cache-prefix invalidation = the dominant waste vector.
if command -v python3 >/dev/null 2>&1; then
  # Compute the memory dir only when memory_md is a real file — otherwise
  # `dirname ""` returns "." and the helper would scan the current working
  # directory's *.md files (catastrophic false-positives on CHANGELOG.md
  # / README.md when audit.sh is run from the project tree).
  memory_md_dir=""
  if [ -n "$memory_md" ] && [ -f "$memory_md" ]; then
    memory_md_dir="$(dirname "$memory_md")"
  fi
  poison_out=$(python3 - "$CLAUDE_HOME/CLAUDE.md" "$memory_md" "$memory_md_dir" <<'PYEOF' 2>/dev/null
import os, re, sys

# Candidate files. Each contributes to the stable prefix sent on every session
# start. Mutation in any of them invalidates the cached block for that file.
candidates = []
for arg in sys.argv[1:]:
    if not arg: continue
    if os.path.isfile(arg):
        candidates.append(arg)
    elif os.path.isdir(arg):
        # memory/*.md siblings — these get loaded too
        for f in sorted(os.listdir(arg)):
            if f.endswith(".md") and f != "MEMORY.md":
                full = os.path.join(arg, f)
                if os.path.isfile(full):
                    candidates.append(full)

# Volatility markers. We deliberately do NOT match bare ISO dates — too noisy
# (changelogs, version strings, "as of 2026-05" are stable content). We match
# only the phrasing that signals "this gets rewritten per session".
PATTERNS = [
    # (regex, label)
    (re.compile(r"^#+\s*current[\s_-]?date\b", re.I | re.M), "currentDate heading"),
    (re.compile(r"^#+\s*today\b", re.I | re.M),              "today heading"),
    (re.compile(r"(?i)today'?s? date (is|:)"),               "today's-date marker"),
    (re.compile(r"(?i)current date\s*[:=]"),                 "current-date marker"),
    (re.compile(r"(?i)last updated\s*[:=]\s*\d"),            "last-updated stamp"),
    (re.compile(r"(?i)generated (at|on)\s*[:=]?\s*\d"),      "generated-at stamp"),
    (re.compile(r"(?i)now\s+is\s+\d{4}-\d{2}"),              "now-is marker"),
    (re.compile(r"当前日期"),                                  "当前日期 marker"),
    (re.compile(r"今天[是的]?\s*\d{4}"),                       "今天日期 marker"),
    (re.compile(r"(?i)更新于\s*[:：]?\s*\d{4}"),                "更新于 marker"),
    # Auto-rotating "recent N" injection (claude-mem / mempalace style)
    (re.compile(r"(?i)(recent|last)\s+\d+\s+(events?|observations?|entries|messages?)"), "recent-N injection"),
]

findings = []   # (file, line_no, label, sample)
for path in candidates:
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        continue
    file_bytes = len(text.encode("utf-8"))
    for rx, label in PATTERNS:
        for m in rx.finditer(text):
            line_no = text.count("\n", 0, m.start()) + 1
            line_start = text.rfind("\n", 0, m.start()) + 1
            line_end = text.find("\n", m.end())
            if line_end == -1: line_end = len(text)
            sample = text[line_start:line_end].strip()[:80]
            findings.append((path, line_no, label, sample, file_bytes))

if not findings:
    sys.exit(0)

# Aggregate by file: report one block per file with all matches, and the
# file's full byte size (because the WHOLE file misses cache on any mutation).
by_file = {}
for path, line_no, label, sample, sz in findings:
    by_file.setdefault(path, {"size": sz, "hits": []})["hits"].append((line_no, label, sample))

print(f"POISONED_FILES\t{len(by_file)}")
total_bytes_at_risk = sum(d["size"] for d in by_file.values())
print(f"TOTAL_BYTES_AT_RISK\t{total_bytes_at_risk}")

for path, info in sorted(by_file.items(), key=lambda x: -x[1]["size"]):
    HOME = os.path.expanduser("~")
    display = "~" + path[len(HOME):] if path.startswith(HOME) else path
    print(f"FILE\t{display}\t{info['size']}")
    for line_no, label, sample in info["hits"][:4]:
        print(f"HIT\t{line_no}\t{label}\t{sample}")
PYEOF
)
fi

if [ -n "${poison_out:-}" ]; then
  poisoned_count=$(printf '%s' "$poison_out" | awk -F'\t' '/^POISONED_FILES\t/{print $2; exit}')
  total_bytes=$(printf '%s' "$poison_out" | awk -F'\t' '/^TOTAL_BYTES_AT_RISK\t/{print $2; exit}')
  if [ -n "$poisoned_count" ] && [ "$poisoned_count" -gt 0 ]; then
    # Rough $/month projection. Assumptions disclosed inline.
    # bytes → tokens via the conservative ~4 chars/token ratio (CLAUDE.md is mostly ASCII prose).
    # 90 session starts/month = ~3/day, a reasonable default for an active user.
    # Cache miss penalty = full input (1.0x) instead of cache read (0.1x) → 0.9x of input price.
    # Sonnet input $3/M used as a conservative middle of the road.
    est_tokens=$((total_bytes / 4))
    # Float math via awk — integer arithmetic truncates small-file cost to 0.
    # Formula: tokens × 90 starts × $3/M × 0.9 cache-miss penalty.
    est_dollars_per_month=$(awk -v t="$est_tokens" 'BEGIN { printf "%.2f", t * 90 * 3 * 0.9 / 1000000 }')
    details="$poisoned_count file(s) in the prompt-cache prefix contain per-session volatile content."
    details+=$'\n'"Anthropic caches the WHOLE block by content hash — a single mutating line"
    details+=$'\n'"invalidates the entire file → you pay full input price (10x cached read) on every session start."
    details+=$'\n'""
    while IFS=$'\t' read -r kind a b c d; do
      case "$kind" in
        FILE)
          details+=$'\n'"  $a  (${b} bytes)"
          ;;
        HIT)
          # a=line_no, b=label, c=sample
          short_sample="$c"
          [ ${#short_sample} -gt 60 ] && short_sample="${short_sample:0:58}…"
          details+=$'\n'"    L$a  [$b]  $short_sample"
          ;;
      esac
    done <<< "$poison_out"
    details+=$'\n'""
    details+=$'\n'"Cost shape: ${total_bytes} bytes ≈ ${est_tokens} tokens. Assuming ~90 session starts/month"
    details+=$'\n'"and Sonnet input pricing, mutating prefix costs ≈ \$${est_dollars_per_month}/month over a cached baseline."
    details+=$'\n'"(For Opus-heavy users multiply by 5x. Small numbers compound — multiple poisoned files stack.)"
    details+=$'\n'""
    details+=$'\n'"Fix options:"
    details+=$'\n'"  • Move volatile lines (today's date, currentDate heading) to a UserPromptSubmit"
    details+=$'\n'"    hook that injects them into the USER message instead of CLAUDE.md."
    details+=$'\n'"  • If you actually need the date in CLAUDE.md, put it at the very END so at"
    details+=$'\n'"    least the leading static portion can cache (Anthropic uses suffix breakpoints)."
    details+=$'\n'"  • Recent-N auto-injection (claude-mem/mempalace) belongs in a separate file"
    details+=$'\n'"    NOT in the global stable prefix — re-config the tool to write to a project"
    details+=$'\n'"    file or to a hook-injected user message."
    print_finding "Cache-prefix poisoning (volatile content invalidates 10x discount)" "$details"
  fi
fi

# ============================================================================
# Summary
# ============================================================================
if [ "$issues" -eq 0 ]; then
  echo "  ✅ No gotchas detected. (All fifteen detectors clean.)"
  echo ""
fi

echo ""
echo "─── Recommendations ────────────────────────────────────────────────"
[ "$claude_md_bytes" -gt 1500 ]      && echo "  • CLAUDE.md 超标：删 Anthropic 博客最佳实践照搬段、废弃模块配置、skill 触发说明"
[ "$claude_md_expanded_lines" -gt 200 ]  && echo "  • CLAUDE.md @-import 展开后 $claude_md_expanded_lines 行：精简或拆分被引用的 .md（codeburn 估算每行 ~13 token）"
[ "$memory_md_bytes" -gt 2000 ]      && echo "  • MEMORY.md 超标：归档已完成项目状态快照，只留 feedback/reference"
[ "$memory_extra_files" -gt 15 ]     && echo "  • memory 目录 md 文件太多：归档到 archive/ 子目录"
[ "$plugin_count" -gt 15 ]           && echo "  • 插件太多：检查金融套件/HuggingFace 子套件/同名重复装"
[ "$mcp_total" -gt 6 ]               && echo "  • MCP 常驻太多：task-master-ai / chrome-devtools 等低频可按需启用"
[ "$skills_total" -gt 50 ]           && echo "  • 本地 skill 数量大：分类批量归档（perspective 系列 / 编程角色短名 / 写作全家桶等）"
[ "$dead_symlinks" -gt 0 ]           && echo "  • $dead_symlinks 个死 symlink：bash scripts/archive-helper.sh clean-dead"
[ "$commands_subdirs" -gt 0 ]        && echo "  • commands/ 下有大类 skill pack：整目录挪到 ~/.claude/_commands_archive/"
[ "$hooks_active" -gt 3 ]            && echo "  • hooks 多：审计每个 UserPromptSubmit hook 是否真的每次都需要"
[ "$bash_output_limit" -gt 15000 ]   && echo "  • Bash 输出上限 $bash_output_limit > 15000：在 ~/.zshrc 加 export BASH_MAX_OUTPUT_LENGTH=15000"
[ -n "${poisoned_count:-}" ] && [ "${poisoned_count:-0}" -gt 0 ] && echo "  • 缓存前缀被污染（${poisoned_count} 个文件含每会话变化的标记）：把日期/时间戳移出 CLAUDE.md，10x 杠杆点"

echo ""
if ls -d "$CLAUDE_HOME"/_tokenslim_archive_* >/dev/null 2>&1; then
  arch=$(ls -d "$CLAUDE_HOME"/_tokenslim_archive_* | sort -r | head -1)
  echo "Prior slim archive: $arch"
fi
echo ""
echo "Run 'claude' and say \"/Boris-Token-Slim\" to start guided cleanup."
echo "Run 'python3 scripts/analyze.py' for retrospective per-session token analysis."
echo ""
