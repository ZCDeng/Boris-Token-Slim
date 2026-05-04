#!/usr/bin/env bash
# Boris-Token-Slim archive helper
# Usage:
#   archive-helper.sh init           # create today's archive root with subdirs
#   archive-helper.sh backup         # snapshot CLAUDE.md / MEMORY.md / .claude.json
#   archive-helper.sh mv-skill NAME  # move ~/.claude/skills/NAME to archive
#   archive-helper.sh mv-mem FILE    # move memory file to archive
#   archive-helper.sh clean-dead     # remove dead symlinks in ~/.claude/skills/
#   archive-helper.sh restore        # list recent archives for manual restore

set -eu

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
DATE="$(date +%Y%m%d)"
ARCHIVE_ROOT="$CLAUDE_HOME/_tokenslim_archive_$DATE"

# Cross-platform Claude Code project dir encoding (see audit.sh for rationale).
HOME_ENCODED="-${HOME#/}"
HOME_ENCODED="${HOME_ENCODED//\//-}"
PROJECT_MEM_DIR="$CLAUDE_HOME/projects/$HOME_ENCODED/memory"

cmd="${1:-}"

die() { echo "error: $*" >&2; exit 1; }

init_archive() {
  mkdir -p "$ARCHIVE_ROOT"/{memory,skills,commands,mcp-backup}
  echo "archive root: $ARCHIVE_ROOT"
}

backup_configs() {
  init_archive
  [ -f "$CLAUDE_HOME/CLAUDE.md" ] && cp "$CLAUDE_HOME/CLAUDE.md" "$ARCHIVE_ROOT/claude-md.before.md" && echo "  backed up CLAUDE.md"
  # Find MEMORY.md (location varies by user)
  for mem in "$PROJECT_MEM_DIR/MEMORY.md" "$CLAUDE_HOME/memory/MEMORY.md"; do
    [ -f "$mem" ] && cp "$mem" "$ARCHIVE_ROOT/memory-md.before.md" && echo "  backed up MEMORY.md ($mem)" && break
  done
  [ -f "$HOME/.claude.json" ] && cp "$HOME/.claude.json" "$ARCHIVE_ROOT/mcp-backup/claude.json" && echo "  backed up ~/.claude.json"
}

move_skill() {
  local name="${1:-}"
  [ -z "$name" ] && die "usage: archive-helper.sh mv-skill NAME"
  local src="$CLAUDE_HOME/skills/$name"
  [ -e "$src" ] || [ -L "$src" ] || die "$src does not exist"
  init_archive
  mv "$src" "$ARCHIVE_ROOT/skills/"
  echo "archived skill: $name"
}

move_mem() {
  local file="${1:-}"
  [ -z "$file" ] && die "usage: archive-helper.sh mv-mem FILE"
  # Search for the file
  local src=""
  for dir in "$PROJECT_MEM_DIR" "$CLAUDE_HOME/memory"; do
    if [ -f "$dir/$file" ]; then
      src="$dir/$file"
      break
    fi
  done
  [ -z "$src" ] && die "memory file not found: $file"
  init_archive
  mv "$src" "$ARCHIVE_ROOT/memory/"
  echo "archived memory: $file"
}

clean_dead_symlinks() {
  local count=0
  local skill_dir="$CLAUDE_HOME/skills"
  [ -d "$skill_dir" ] || die "$skill_dir not found"
  for s in "$skill_dir"/*; do
    if [ -L "$s" ] && [ ! -e "$s" ]; then
      rm "$s"
      count=$((count+1))
    fi
  done
  echo "removed $count dead symlinks"
}

list_archives() {
  echo "recent archives:"
  ls -d "$CLAUDE_HOME"/_tokenslim_archive_* 2>/dev/null | sort -r | head -5
  echo ""
  echo "to restore a skill:  mv <archive>/skills/<name> ~/.claude/skills/"
  echo "to restore CLAUDE.md: cp <archive>/claude-md.before.md ~/.claude/CLAUDE.md"
}

case "$cmd" in
  init)        init_archive ;;
  backup)      backup_configs ;;
  mv-skill)    shift; move_skill "$@" ;;
  mv-mem)      shift; move_mem "$@" ;;
  clean-dead)  clean_dead_symlinks ;;
  restore)     list_archives ;;
  "")          echo "usage: $0 {init|backup|mv-skill NAME|mv-mem FILE|clean-dead|restore}"; exit 1 ;;
  *)           die "unknown command: $cmd" ;;
esac
