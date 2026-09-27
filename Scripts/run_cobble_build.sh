#!/bin/bash
# Compatibility shim. Prefer ./Scripts/run.sh local|remote fast|full
exec "$(cd "$(dirname "$0")" && pwd)/run.sh" "$@"
