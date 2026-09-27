#!/bin/bash
# Full: wrap the already-built Chromium.app. Does not compile Chromium.
# Without HOOK_APP_FILE this is a preflight (exists + idle) only.

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BUILD_TOOLS_ROOT="${BUILD_TOOLS_ROOT:-${BUILD_TOOLS:-$HOME/Developer/build-kit}}"
FULL_APP="$ROOT/.context/Cobble.app"
CHROMIUM_BUILD="${COBBLE_CHROMIUM_BUILD:-$HOME/Developer/cobble-chromium-build}"
CHROMIUM_APP="${COBBLE_CHROMIUM_APP:-$CHROMIUM_BUILD/next-stable/src/out/Cobble/Chromium.app}"
PHASE_FILE="$CHROMIUM_BUILD/evidence/full-chrome-current-phase.json"
COBBLE_APP="${APP:-$ROOT/.context/DerivedData/Build/Products/Debug/Cobble.app}"

require_chromium_app() {
  [[ -d "$CHROMIUM_APP" ]] || {
    printf 'No Chromium.app at %s\nFast WebKit still works. Full does not compile Chromium.\n' \
      "$CHROMIUM_APP" >&2
    exit 1
  }
}

require_chromium_idle() {
  [[ -f "$PHASE_FILE" ]] || return 0
  python3 - "$PHASE_FILE" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
phase = json.loads(path.read_text())
if phase.get("status") == "running":
    sys.exit(
        "Chromium tree has a writer running (%s).\n"
        "Fast WebKit still works. Wait for %s to go idle."
        % (phase.get("phase", "unknown"), path)
    )
PY
}

require_chromium_app
require_chromium_idle
[[ -n "${HOOK_APP_FILE:-}" ]] || exit 0

[[ -d "$COBBLE_APP" ]] || {
  printf 'built Cobble.app is missing: %s\n' "$COBBLE_APP" >&2
  exit 1
}

# The shared runner exports APP, but not CONFIGURATION. Its product directory
# is the configuration actually built, including CONFIGURATION_FULL overrides.
FULL_CONFIGURATION="$(basename "$(dirname "$COBBLE_APP")")"
case "$FULL_CONFIGURATION" in
  Debug|Release) ;;
  *) FULL_CONFIGURATION="${CONFIGURATION:-Debug}" ;;
esac

mkdir -p "$(dirname "$FULL_APP")"
STAGING="$(mktemp -d "$ROOT/.context/full-XXXXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
python3 "$ROOT/Scripts/assemble_chromium.py" "$CHROMIUM_APP" \
  --cobble-app "$COBBLE_APP" \
  --configuration "$FULL_CONFIGURATION" \
  --output "$STAGING/Cobble.app"
xcrun swift "$BUILD_TOOLS_ROOT/macos/quit.swift" com.ignacio.cobble
# Retain the previous app until assembly and signing have succeeded.
if [[ -d "$FULL_APP" ]]; then mv "$FULL_APP" "$STAGING/Previous.app"; fi
if ! mv "$STAGING/Cobble.app" "$FULL_APP"; then
  if [[ -d "$STAGING/Previous.app" ]]; then mv "$STAGING/Previous.app" "$FULL_APP"; fi
  exit 1
fi
printf '%s\n' "$FULL_APP" > "$HOOK_APP_FILE"
