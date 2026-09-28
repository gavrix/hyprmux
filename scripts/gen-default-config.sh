#!/usr/bin/env bash
# Embed config/hypermux.conf into the core module as the built-in default.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Sources/HypermuxCore/DefaultConfig.swift"
{
  echo '// Generated from config/hypermux.conf by scripts/gen-default-config.sh. Do not edit.'
  echo 'public let defaultConfig = #"""'
  cat "$ROOT/config/hypermux.conf"
  echo '"""#'
} > "$OUT"
echo "wrote $OUT"
