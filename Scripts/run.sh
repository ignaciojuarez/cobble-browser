#!/bin/bash
# Thin wrapper around $HOME/Developer/build-kit/macos/run.sh
#   ./Scripts/run.sh local              → terminal menu (Fast / Full)
#   ./Scripts/run.sh local fast|full
#   ./Scripts/run.sh remote fast|full   → mode required; no menu
# Old names still work: fast|send|full|send-full

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_CONFIG="$ROOT/Scripts/run.local.config"
if [[ ! -f "$LOCAL_CONFIG" ]]; then
  COMMON_GIT_DIR="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -z "$COMMON_GIT_DIR" ]] || LOCAL_CONFIG="$COMMON_GIT_DIR/../Scripts/run.local.config"
fi
if [[ -f "$LOCAL_CONFIG" ]]; then
  set -a
  source "$LOCAL_CONFIG"
  set +a
fi
TOOLS="${BUILD_TOOLS:-$HOME/Developer/build-kit}"
RUNNER="$TOOLS/macos/run.sh"

[[ -x "$RUNNER" ]] || {
  printf 'error: clone ignaciojuarez/build-kit to %s\n' "$TOOLS" >&2
  exit 1
}

if [[ -z "${XCODE_APP:-}" && -n "${COBBLE_XCODE:-}" ]]; then
  export XCODE_APP="$COBBLE_XCODE"
fi
if [[ -z "${TEAM_ID:-}" && -n "${COBBLE_DEVELOPMENT_TEAM:-}" ]]; then
  export TEAM_ID="$COBBLE_DEVELOPMENT_TEAM"
fi
if [[ -z "${SEND_TARGET:-}" && -n "${COBBLE_SEND_TARGET:-}" ]]; then
  export SEND_TARGET="$COBBLE_SEND_TARGET"
fi

case "${1:-}" in
  send) set -- remote fast "${@:2}" ;;
  send-full) set -- remote full "${@:2}" ;;
  fast) set -- local fast "${@:2}" ;;
  full) set -- local full "${@:2}" ;;
esac

WHERE=""
MODE=""
PASSTHRU=()
for arg in "$@"; do
  case "$arg" in
    local|remote) WHERE="$arg" ;;
    fast|full|sim) MODE="$arg" ;;
  esac
  PASSTHRU+=("$arg")
done

# Remote runs from another machine (T3 laptop). A menu would appear on this Mac.
if [[ "$WHERE" == remote && -z "$MODE" ]]; then
  printf 'error: remote needs fast or full: ./Scripts/run.sh remote fast|full\n' >&2
  exit 1
fi

if [[ "$MODE" == full ]]; then
  ROOT="$ROOT" bash "$ROOT/Scripts/hook_full.sh"
fi

exec "$RUNNER" --root="$ROOT" ${PASSTHRU[@]+"${PASSTHRU[@]}"}
