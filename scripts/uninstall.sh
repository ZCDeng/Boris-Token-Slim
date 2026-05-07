#!/usr/bin/env bash
# Boris-Token-Slim uninstall script
# Removes only what install.sh created: symlink + clone path.
# Never touches ~/.boris-stats/ ledger (your data).
# Supports curl-pipe: bash <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/v0.2.0/scripts/uninstall.sh)
set -euo pipefail

INSTALL_PARENT="$HOME/.local/share/boris-token-slim"
SKILL_SYMLINK="$HOME/.claude/skills/boris-token-slim"
LEDGER_DIR="$HOME/.boris-stats"

DRY_RUN=false

# ── helpers ──────────────────────────────────────────────────────────────
is_symlink()      { [ -L "${1:-}" ]; }
symlink_target()  { readlink "${1:-}" 2>/dev/null || true; }

usage() {
  cat <<'USAGE'
Usage: bash uninstall.sh [--dry-run] [--help]

  --dry-run  Print what would be removed without touching files.
  --help     Show this message.
USAGE
}

_do_or_say() {
  local desc="$1"; shift
  if $DRY_RUN; then
    echo "  would $desc"
    return 0
  fi
  "$@"
}

# ── uninstall ─────────────────────────────────────────────────────────────
_uninstall() {
  local unlinked=false
  local removed_clone=false

  # Check symlink
  if ! is_symlink "$SKILL_SYMLINK"; then
    if [ -e "$SKILL_SYMLINK" ]; then
      echo "found $SKILL_SYMLINK but it is not a symlink (directory or regular file)"
      echo "this was not created by install.sh — please remove it manually if desired"
    else
      echo "no install detected ($SKILL_SYMLINK does not exist)"
    fi
    echo ""
    echo "ledger at $LEDGER_DIR kept (your data)"
    exit 0
  fi

  local target
  target=$(symlink_target "$SKILL_SYMLINK")

  # Only uninstall if the symlink target looks like our install pattern
  case "$target" in
    "$INSTALL_PARENT/"*)
      ;;
    *)
      echo "found $SKILL_SYMLINK → $target"
      echo "this symlink was not created by install.sh — please remove it manually if desired"
      echo ""
      echo "ledger at $LEDGER_DIR kept (your data)"
      exit 0
      ;;
  esac

  # Unlink symlink
  _do_or_say "unlink $SKILL_SYMLINK" \
    unlink "$SKILL_SYMLINK"
  unlinked=true

  # Remove clone path
  if [ -d "$target" ]; then
    _do_or_say "rm -rf $target" \
      rm -rf "$target"
    removed_clone=true
  fi

  # Rmdir parent if empty
  if [ -d "$INSTALL_PARENT" ]; then
    local remaining
    remaining=$(ls -A "$INSTALL_PARENT" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${remaining:-0}" -eq 0 ]; then
      _do_or_say "rmdir $INSTALL_PARENT (empty)" \
        rmdir "$INSTALL_PARENT"
    fi
  fi

  # Summary
  local actions=""
  $unlinked && actions+="  unlinked $SKILL_SYMLINK"$'\n'
  $removed_clone && actions+="  removed clone at $target"$'\n'
  [ -n "$actions" ] && echo "$actions"

  echo "removed Boris-Token-Slim install."
  echo "ledger at $LEDGER_DIR kept (your data — rm -rf ~/.boris-stats/ if you want to remove it too)"
}

# ── main ──────────────────────────────────────────────────────────────────
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --help)    usage; exit 0 ;;
      *)
        echo "unknown flag: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if $DRY_RUN; then
    echo "# --dry-run: no files will be modified"
    echo ""
  fi

  _uninstall
}

main "$@"
