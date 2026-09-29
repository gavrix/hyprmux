#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PROTO_DIR="$ROOT/Sources/AndroidEmulatorBridge/Protos"
GENERATED_DIR="$ROOT/Sources/AndroidEmulatorBridge/Generated"
PROTO=android_emulator.proto

find_plugin() {
  name=$1
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return
  fi

  find "$ROOT/.build/checkouts" -path "*/.build/*/debug/$name" -type f -perm +111 2>/dev/null \
    | head -n 1
}

PROTOC=${PROTOC:-$(command -v protoc || true)}
SWIFT_PLUGIN=${PROTOC_GEN_SWIFT:-$(find_plugin protoc-gen-swift)}
GRPC_PLUGIN=${PROTOC_GEN_GRPC_SWIFT:-$(find_plugin protoc-gen-grpc-swift)}

if [ -z "$PROTOC" ] || [ -z "$SWIFT_PLUGIN" ] || [ -z "$GRPC_PLUGIN" ]; then
  echo "protoc, protoc-gen-swift, and protoc-gen-grpc-swift are required" >&2
  echo "Build the package plugins or put them on PATH, then retry." >&2
  exit 1
fi

PROTOC_PREFIX=$(CDPATH= cd -- "$(dirname "$PROTOC")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

"$PROTOC" \
  --plugin="protoc-gen-swift=$SWIFT_PLUGIN" \
  --plugin="protoc-gen-grpc-swift=$GRPC_PLUGIN" \
  --proto_path="$PROTO_DIR" \
  --proto_path="$PROTOC_PREFIX/include" \
  --swift_opt=Visibility=Internal \
  --swift_out="$TMP" \
  --grpc-swift_opt=Client=true,Server=false,Visibility=Internal \
  --grpc-swift_out="$TMP" \
  "$PROTO_DIR/$PROTO"

# Generators can append extra blank lines. Keep checked-in output diff-clean.
for generated in "$TMP"/*.swift; do
  perl -0pi -e 's/\n+\z/\n/' "$generated"
done

mkdir -p "$GENERATED_DIR"
cp "$TMP/android_emulator.pb.swift" "$GENERATED_DIR/AndroidEmulator.pb.swift"
cp "$TMP/android_emulator.grpc.swift" "$GENERATED_DIR/AndroidEmulator.grpc.swift"
