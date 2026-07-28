#!/usr/bin/env bash

# This old name now forwards commands to sim_run.sh.
# It checks for WSL2 first, so it cannot be used on normal Ubuntu by mistake.
set -euo pipefail

if ! grep -qi microsoft /proc/version 2>/dev/null; then
    echo "ERROR: This script only works in WSL2." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/sim_run.sh" "$@"
