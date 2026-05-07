#!/usr/bin/env bash
# Boris-Token-Slim install script
# Single-entry: bash <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/v0.2.0/scripts/install.sh)
#
# Detects 5 agents (Claude Code / Cursor / Windsurf / Codex / Gemini CLI),
# honest-bails for non-CC agents, installs Boris as a Claude Code skill
# (symlink ~/.claude/skills/boris-token-slim → ~/.local/share/boris-token-slim/v0.2.0/).
#
# Trust: tarball sha256-verified (python3 hashlib). Git-clone path trusts
# git's built-in tag→commit integrity. Loader/payload split: install.sh
# itself ships via raw.githubusercontent.com; the tarball is a GitHub
# release asset and excludes install.sh + uninstall.sh.
set -euo pipefail

VERSION="v0.2.0"
REPO_URL="https://github.com/ZCDeng/Boris-Token-Slim.git"
RELEASE_TARBALL_URL="https://github.com/ZCDeng/Boris-Token-Slim/releases/download/${VERSION}/Boris-Token-Slim-${VERSION}.tar.gz"
ISSUES_URL="https://github.com/ZCDeng/Boris-Token-Slim/issues"
EXPECTED_INSTALL_TARBALL_SHA256="<release-time fill>"

INSTALL_PARENT="$HOME/.local/share/boris-token-slim"
INSTALL_DIR="$INSTALL_PARENT/$VERSION"
SKILL_SYMLINK="$HOME/.claude/skills/boris-token-slim"

DRY_RUN=false

# ── helpers ──────────────────────────────────────────────────────────────
has()      { command -v "$1" >/dev/null 2>&1; }
dir_exists() { [ -d "${1:-}" ]; }
is_symlink() { [ -L "${1:-}" ]; }
symlink_target() { readlink "${1:-}" 2>/dev/null || true; }

usage() {
  cat <<'USAGE'
Usage: bash install.sh [--dry-run] [--help]

  --dry-run  Print what would be done without writing files.
  --help     Show this message.
USAGE
}

# ── mutable trap for cleanup-on-fail (F5) ────────────────────────────────
# _cleanup_tmpdir is always set by mktemp. _cleanup_installed is set AFTER
# a successful mv, so that if ln fails post-mv the installed directory is
# also removed — not just the tmpdir.
_cleanup_tmpdir=""
_cleanup_installed=""

_cleanup() {
  if [ -n "${_cleanup_tmpdir:-}" ] && [ -d "$_cleanup_tmpdir" ]; then
    rm -rf -- "$_cleanup_tmpdir"
  fi
  if [ -n "${_cleanup_installed:-}" ] && [ -d "$_cleanup_installed" ]; then
    rm -rf -- "$_cleanup_installed"
  fi
}

trap _cleanup EXIT INT TERM HUP

# ── detection ─────────────────────────────────────────────────────────────
_detect_agents() {
  # caveman hybrid pattern: command:X || dir:$HOME/.X
  # Returns a list of "agent|how|detail" lines.
  local found=""

  # Claude Code
  if has claude; then
    found+="claude|hard|PATH"$'\n'
  elif dir_exists "$HOME/.claude"; then
    found+="claude|soft|~/.claude"$'\n'
  fi

  # Cursor
  if has cursor; then
    found+="cursor|hard|PATH"$'\n'
  elif dir_exists "$HOME/.cursor"; then
    found+="cursor|soft|~/.cursor"$'\n'
  fi

  # Windsurf
  if has windsurf; then
    found+="windsurf|hard|PATH"$'\n'
  elif dir_exists "$HOME/.codeium/windsurf"; then
    found+="windsurf|soft|~/.codeium/windsurf"$'\n'
  elif dir_exists "$HOME/.windsurf"; then
    found+="windsurf|soft|~/.windsurf"$'\n'
  fi

  # Codex (OpenAI)
  if has codex; then
    found+="codex|hard|PATH"$'\n'
  elif dir_exists "$HOME/.codex"; then
    found+="codex|soft|~/.codex"$'\n'
  fi

  # Gemini CLI
  if has gemini; then
    found+="gemini|hard|PATH"$'\n'
  elif dir_exists "$HOME/.gemini"; then
    found+="gemini|soft|~/.gemini"$'\n'
  fi

  printf '%s' "$found"
}

_honest_bail() {
  local detected_agents="$1"
  cat <<EOF

Boris-Token-Slim audits Claude Code sessions only.

EOF
  if [ -n "$detected_agents" ]; then
    echo "Detected:"
    while IFS='|' read -r agent how detail; do
      [ -z "$agent" ] && continue
      echo "  $agent ($how-detected via $detail)"
    done <<< "$detected_agents"
    echo ""
    echo "We don't audit non-Claude-Code agents yet."
  else
    echo "No supported AI coding agent detected."
  fi
  cat <<EOF
Track or request support at:
  $ISSUES_URL
EOF
}

# ── fetch ─────────────────────────────────────────────────────────────────
_do_or_say() {
  # "$@" is the real command. Under --dry-run we print a description instead.
  local desc="$1"; shift
  if $DRY_RUN; then
    echo "  would $desc"
    return 0
  fi
  "$@"
}

_sha256_verify() {
  local tarball="$1" expected="$2"
  local actual
  actual=$(python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$tarball" 2>/dev/null)
  if [ -z "$actual" ]; then
    echo "error: sha256 computation failed (python3 hashlib)" >&2
    return 1
  fi
  if [ "$actual" != "$expected" ]; then
    cat >&2 <<EOF
sha256 mismatch for $VERSION tarball:
  expected: $expected
  actual:   $actual
Install aborted — the fetched tarball does not match the pinned hash.
This may indicate a corrupted download, a network error, or an
unexpected file on the release. Try again or open an issue:
  $ISSUES_URL
EOF
    return 1
  fi
}

_fetch_repo() {
  local dest="$1"

  if has git; then
    _do_or_say "git clone --depth 1 --branch $VERSION $REPO_URL → $dest" \
      git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$dest"
    echo "# fetched via git clone --branch $VERSION (tag→commit integrity verified by git)"
    return 0
  fi

  # Tarball fallback — no git available
  local tarball="$dest.tar.gz"
  if has curl; then
    _do_or_say "curl -fsSL $RELEASE_TARBALL_URL → $tarball" \
      curl -fsSL "$RELEASE_TARBALL_URL" -o "$tarball"
  elif has wget; then
    _do_or_say "wget -qO $tarball $RELEASE_TARBALL_URL" \
      wget -qO "$tarball" "$RELEASE_TARBALL_URL"
  else
    echo "error: neither git, curl, nor wget is available; cannot fetch Boris-Token-Slim" >&2
    echo "install one of: git, curl, or wget" >&2
    return 1
  fi

  # Sha256 verify
  if [ "$EXPECTED_INSTALL_TARBALL_SHA256" != "<release-time fill>" ]; then
    _sha256_verify "$tarball" "$EXPECTED_INSTALL_TARBALL_SHA256" || return 1
    echo "# fetched tarball $VERSION (sha256 verified)"
  else
    echo "# fetched tarball $VERSION (sha256 not yet pinned — this is a pre-release build)"
  fi

  # Extract (tarball has --prefix so top-level dir is Boris-Token-Slim-0.2.0/)
  _do_or_say "tar -xzf $tarball → $dest" \
    tar -xzf "$tarball"
  # After extract, the content is at ./Boris-Token-Slim-$VERSION/
  local extracted_dir="./Boris-Token-Slim-${VERSION}"
  if [ -d "$extracted_dir" ]; then
    _do_or_say "mv $extracted_dir → $dest" \
      mv "$extracted_dir" "$dest"
  fi
  # Clean up tarball
  rm -f "$tarball"
}

# ── install ───────────────────────────────────────────────────────────────
_install_claude_code() {
  # Idempotency check (pre-fetch)
  if [ -e "$SKILL_SYMLINK" ] || [ -L "$SKILL_SYMLINK" ]; then
    if is_symlink "$SKILL_SYMLINK"; then
      local target
      target=$(symlink_target "$SKILL_SYMLINK")
      case "$target" in
        "$INSTALL_PARENT/"*)
          local installed_ver
          installed_ver=$(basename "$target")
          if [ "$installed_ver" = "$VERSION" ]; then
            echo "already installed at $VERSION · run uninstall.sh first then re-run install.sh to switch versions"
          else
            echo "already installed at $installed_ver · to switch to $VERSION, run uninstall.sh first"
          fi
          exit 0
          ;;
        *)
          echo "found existing install at $SKILL_SYMLINK → $target"
          echo "it was not created by this install.sh — please remove it first then re-run install.sh"
          exit 1
          ;;
      esac
    fi
    # Not a symlink (directory, file, broken symlink) → refuse
    echo "found existing install at $SKILL_SYMLINK that was not created by install.sh"
    echo "please remove it first then re-run install.sh"
    exit 1
  fi

  # Deps: python3 required; curl or wget or git required
  if ! has python3; then
    echo "error: python3 is required but not found in PATH" >&2
    echo "install python3 first: https://www.python.org/downloads/" >&2
    exit 1
  fi
  if ! has curl && ! has wget && ! has git; then
    echo "error: at least one of git, curl, or wget is required but none found in PATH" >&2
    exit 1
  fi

  # Main install flow
  echo ""
  echo "installing Boris-Token-Slim $VERSION …"
  echo ""

  _cleanup_tmpdir=$(mktemp -d)
  local repo_dest="$_cleanup_tmpdir/repo"

  _fetch_repo "$repo_dest" || return 1

  _do_or_say "mkdir -p $INSTALL_PARENT" \
    mkdir -p "$INSTALL_PARENT"

  _do_or_say "mv $repo_dest → $INSTALL_DIR" \
    mv "$repo_dest" "$INSTALL_DIR"

  # After successful mv: set mutable installed path so cleanup removes it
  # if a later step (ln) fails (F5 fix).
  _cleanup_installed="$INSTALL_DIR"

  _do_or_say "mkdir -p $(dirname "$SKILL_SYMLINK")" \
    mkdir -p "$(dirname "$SKILL_SYMLINK")"

  _do_or_say "ln -sn $INSTALL_DIR → $SKILL_SYMLINK" \
    ln -sfn "$INSTALL_DIR" "$SKILL_SYMLINK"

  # Success — disarm installed-path cleanup
  _cleanup_installed=""

  cat <<EOF

Boris-Token-Slim $VERSION installed.

  skill:    $SKILL_SYMLINK → $INSTALL_DIR
  source:   $ISSUES_URL
  verify:   ls -la $SKILL_SYMLINK
  uninstall: bash <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/${VERSION}/scripts/uninstall.sh)

Run 'claude' and say "/Boris-Token-Slim" to start a guided audit.
EOF
}

# ── main ──────────────────────────────────────────────────────────────────
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --help)    usage; exit 0 ;;
      --yes)     shift ;;  # reserved for v0.2.x, no-op for now
      *)
        echo "unknown flag: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if $DRY_RUN; then
    echo "# --dry-run: no files will be written"
    echo ""
  fi

  # Detect agents
  local agents
  agents=$(_detect_agents)

  # Build display summary
  local claude_hit=false
  local summary=""
  while IFS='|' read -r agent how detail; do
    [ -z "$agent" ] && continue
    summary+="  $agent ($how-detected via $detail)"$'\n'
    if [ "$agent" = "claude" ]; then
      claude_hit=true
    fi
  done <<< "$agents"

  # Print detect summary
  if [ -n "$summary" ]; then
    echo "detected:"
    printf '%s' "$summary"
    echo ""
  else
    echo "detected: (none)"
    echo ""
  fi

  if $claude_hit; then
    _install_claude_code
  else
    _honest_bail "$(
      while IFS='|' read -r agent how detail; do
        [ -z "$agent" ] && continue
        echo "$agent|$how|$detail"
      done <<< "$agents"
    )"
    echo ""
  fi
}

main "$@"
