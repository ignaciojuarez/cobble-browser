#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Use a full Xcode installation; no separate build-kit checkout is required.
export DEVELOPER_DIR="${DEVELOPER_DIR:-${XCODE_APP:-${COBBLE_XCODE:-/Applications/Xcode.app}}/Contents/Developer}"

exec xcodebuild -project "$ROOT/Cobble.xcodeproj" -scheme Cobble \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO "$@" test
