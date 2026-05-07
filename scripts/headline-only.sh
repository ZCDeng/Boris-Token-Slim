#!/usr/bin/env bash
# Boris-Token-Slim · headline-only curl-pipe entry
# bash <(curl -fsSL https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/v0.2.0/scripts/headline-only.sh)
#
# Runs analyze.py --headline on YOUR Claude Code sessions.
# Pinned to immutable v0.2.0 tag + sha256-verified. Read-only:
# BORIS_STATS_DISABLE=1 is set so the ledger is never written.
#
# Requires python3 + (git or curl or wget). No other deps.
set -euo pipefail

VERSION="v0.2.0"
REPO_URL="https://github.com/ZCDeng/Boris-Token-Slim.git"
RAW_BASE="https://raw.githubusercontent.com/ZCDeng/Boris-Token-Slim/${VERSION}"
EXPECTED_ANALYZE_SHA256="4a3297cf0cc7a436cc663bf9dfeb00635dd98f71000740dffad48eb48e9802a3"

# ── helpers ──────────────────────────────────────────────────────────────
has() { command -v "$1" >/dev/null 2>&1; }

# ── main ──────────────────────────────────────────────────────────────────
main() {
  # Deps
  if ! has python3; then
    echo "error: python3 is required but not found in PATH" >&2
    echo "install python3 first: https://www.python.org/downloads/" >&2
    exit 1
  fi
  if ! has curl && ! has wget; then
    echo "error: at least one of curl or wget is required but neither found in PATH" >&2
    exit 1
  fi

  # tmpdir — declare first so trap doesn't act on unset variable
  local tmpdir=""
  trap 'test -n "${tmpdir:-}" && rm -rf -- "$tmpdir"' EXIT INT TERM HUP
  tmpdir=$(mktemp -d)

  local analyze_path="$tmpdir/analyze.py"
  local trust_note=""

  if has git; then
    # Primary path: git clone (tag→commit integrity verified by git)
    if ! git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$tmpdir/repo" >/dev/null 2>&1; then
      echo "error: git clone failed — tag $VERSION may not exist yet or network is unavailable" >&2
      echo "try the wget fallback: remove git from PATH and re-run, or wait a moment and try again" >&2
      exit 1
    fi
    analyze_path="$tmpdir/repo/scripts/analyze.py"
    trust_note="# running analyze.py from ZCDeng/Boris-Token-Slim@${VERSION} (clone, sha256 verified) · BORIS_STATS_DISABLE=1 set"
  else
    # Fallback: single-file fetch (F11 — git absent, curl/wget fallback)
    if has curl; then
      curl -fsSL "${RAW_BASE}/scripts/analyze.py" -o "$analyze_path"
    else
      wget -qO "$analyze_path" "${RAW_BASE}/scripts/analyze.py"
    fi
    trust_note="# running analyze.py from ZCDeng/Boris-Token-Slim@${VERSION} (single-file fetch, sha256 verified) · BORIS_STATS_DISABLE=1 set"
  fi

  # Sha256 verify (both paths)
  if [ "$EXPECTED_ANALYZE_SHA256" != "<release-time fill>" ]; then
    local actual
    actual=$(python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$analyze_path" 2>/dev/null)
    if [ -z "$actual" ]; then
      echo "error: sha256 computation failed (python3 hashlib)" >&2
      exit 1
    fi
    if [ "$actual" != "$EXPECTED_ANALYZE_SHA256" ]; then
      cat >&2 <<EOF
sha256 mismatch for analyze.py @ ${VERSION}:
  expected: $EXPECTED_ANALYZE_SHA256
  actual:   $actual
This may indicate a corrupted fetch or an unexpected file on the release.
Please try again or open an issue:
  https://github.com/ZCDeng/Boris-Token-Slim/issues
EOF
      exit 1
    fi
  fi

  # Run: BORIS_STATS_DISABLE=1 (read-only, no ledger write)
  echo "$trust_note"
  BORIS_STATS_DISABLE=1 python3 "$analyze_path" --headline --days 30

  echo ""
  echo "# script source: https://github.com/ZCDeng/Boris-Token-Slim/blob/${VERSION}/scripts/headline-only.sh"
}

main "$@"
