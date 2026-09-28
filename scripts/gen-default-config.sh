#!/usr/bin/env bash
# Embed config/hyprmux.conf into the core module as the built-in default.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Sources/HyprmuxCore/DefaultConfig.swift"
{
  echo '// Generated from config/hyprmux.conf by scripts/gen-default-config.sh. Do not edit.'
  echo 'public let defaultConfig = #"""'
  cat "$ROOT/config/hyprmux.conf"
  echo '"""#'
} > "$OUT"
echo "wrote $OUT"
