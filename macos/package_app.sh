#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=macos/version.env
source "$ROOT_DIR/macos/version.env"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/AutoRoute.app"
ZIP_NAME="AutoRoute-$AUTOROUTE_VERSION.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing $APP_DIR; run bash macos/build_app.sh first." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP_DIR"
rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
cd "$ROOT_DIR/dist"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_NAME"
shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"
echo "Created $ZIP_PATH"
echo "SHA-256: $ZIP_PATH.sha256"
