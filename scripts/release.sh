#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${RELEASE_TAG:-0.0.0}"
VERSION="${VERSION#v}"
OUT_DIR="$ROOT/dist"
STAGE="$OUT_DIR/OpenCode-Unlimited-$VERSION"
ZIP="$OUT_DIR/OpenCode-Unlimited-$VERSION.zip"
TAR="$OUT_DIR/OpenCode-Unlimited-$VERSION.tar.gz"

rm -rf "$STAGE" "$ZIP" "$TAR"
mkdir -p "$STAGE"

for item in bin lib plugins install.ps1 install.sh README.md; do
  cp -r "$ROOT/$item" "$STAGE/"
done

mkdir -p "$OUT_DIR"
(cd "$STAGE" && zip -r -q "$ZIP" .)
(cd "$STAGE" && tar -czf "$TAR" .)

HASH=$(shasum -a 256 "$ZIP" | awk '{print $1}')
SIZE=$(du -k "$ZIP" | cut -f1)

echo "artifact : $ZIP"
echo "size     : ${SIZE} KB"
echo "sha256   : $HASH"

