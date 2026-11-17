#!/usr/bin/env bash
# Run a debug build. Pass --demo for the fake vault: ./Scripts/run_dev.sh --demo
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
swift build
exec .build/debug/VaultBar "$@"
