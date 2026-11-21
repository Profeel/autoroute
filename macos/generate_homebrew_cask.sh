#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=macos/version.env
source "$ROOT_DIR/macos/version.env"
ZIP_PATH="$ROOT_DIR/dist/AutoRoute-$AUTOROUTE_VERSION.zip"
SHA_PATH="$ZIP_PATH.sha256"
OUTPUT_PATH="${1:-$ROOT_DIR/dist/autoroute.rb}"

if [[ ! -f "$ZIP_PATH" || ! -f "$SHA_PATH" ]]; then
  echo "Build and package a real release candidate before generating a cask." >&2
  exit 1
fi
read -r SHA256 _ < "$SHA_PATH"
TEMPLATE="$(<"$ROOT_DIR/macos/autoroute.rb.template")"
CONTENT="${TEMPLATE//@VERSION@/$AUTOROUTE_VERSION}"
CONTENT="${CONTENT//@SHA256@/$SHA256}"
printf '%s\n' "$CONTENT" > "$OUTPUT_PATH"
echo "Generated $OUTPUT_PATH from the local release artifact. Publish the asset and tap separately."
