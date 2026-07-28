#!/usr/bin/env bash

# This old name now forwards commands to sim_run.sh.
# It lets old instructions keep working on Ubuntu.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/sim_run.sh" "$@"
