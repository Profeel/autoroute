#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=macos/version.env
source "$ROOT_DIR/macos/version.env"
APP_DIR="$ROOT_DIR/dist/AutoRoute.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

cd "$ROOT_DIR"

if [[ "${AUTOROUTE_REQUIRE_DEVELOPER_ID:-0}" == "1" && -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Release refused: DEVELOPER_ID_APPLICATION is required; ad-hoc signing cannot produce a formal release." >&2
  exit 2
fi

echo "Building AutoRoute (release, version $AUTOROUTE_VERSION, build $AUTOROUTE_BUILD_NUMBER)..."
swift build -c release --product AutoModel
BIN_PATH="$(swift build -c release --show-bin-path)/AutoModel"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Error: compiled binary not found at $BIN_PATH" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/AutoModel"
chmod +x "$MACOS_DIR/AutoModel"

ICON_SRC="$ROOT_DIR/macos/AppIcon.icns"
if [[ ! -f "$ICON_SRC" ]]; then
  echo "Error: app icon not found at $ICON_SRC" >&2
  exit 1
fi
cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>AutoModel</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>org.automodel.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AutoRoute</string>
  <key>CFBundleDisplayName</key>
  <string>AutoRoute</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$AUTOROUTE_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$AUTOROUTE_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
EOF

plutil -lint "$APP_DIR/Contents/Info.plist"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --deep --options runtime --sign "$DEVELOPER_ID_APPLICATION" "$APP_DIR"
  echo "Developer ID signature applied; notarization is still required for distribution."
else
  # Optional per-clone pin: a stable local development identity preserves Keychain
  # access across rebuilds. Explicitly configured identities must never fall back.
  LOCAL_SIGN_ID="${AUTOROUTE_LOCAL_SIGNING_ID:-$(git config --local --get autoroute.localSigningIdentity 2>/dev/null || true)}"
  if [[ -n "$LOCAL_SIGN_ID" ]]; then
    codesign --force --deep --sign "$LOCAL_SIGN_ID" "$APP_DIR"
    echo "Local development signature applied; this is not a notarized distribution."
  else
    codesign --force --deep --sign - "$APP_DIR"
    echo "WARNING: ad-hoc signature is for local development only; this app is not a notarized distribution." >&2
  fi
fi
codesign --verify --deep --strict "$APP_DIR"
if [[ "${AUTOROUTE_REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
  SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
  if ! grep -F "Authority=$DEVELOPER_ID_APPLICATION" <<< "$SIGNATURE_INFO" >/dev/null; then
    echo "Release refused: the app is not signed by the requested Developer ID certificate; ad-hoc or an unexpected identity is not publishable." >&2
    exit 2
  fi
fi

echo "Built and verified: $APP_DIR"
