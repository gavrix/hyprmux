#!/usr/bin/env bash
# Runs one phase of a demo scenario: run.sh setup|play|teardown FILE.
# A scenario defines play(), and optionally setup() (before recording starts) and
# teardown() (after it stops). Helpers come from lib.sh.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
source "$2"
if declare -F "$1" >/dev/null; then "$1"; fi
