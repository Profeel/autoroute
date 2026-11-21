#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=macos/version.env
source "$ROOT_DIR/macos/version.env"
APP_DIR="$ROOT_DIR/dist/AutoRoute.app"
ZIP_PATH="${1:-$ROOT_DIR/dist/AutoRoute-$AUTOROUTE_VERSION.zip}"
PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
KEYCHAIN_PATH="${AUTOROUTE_NOTARY_KEYCHAIN:-}"

if [[ -z "$PROFILE" ]]; then
  echo "Set NOTARYTOOL_KEYCHAIN_PROFILE to an existing notarytool Keychain profile." >&2
  exit 2
fi
if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Developer ID signing is required before notarization; refusing an ad-hoc release." >&2
  exit 2
fi
if [[ "${AUTOROUTE_REQUIRE_DEVELOPER_ID:-0}" == "1" && -z "$KEYCHAIN_PATH" ]]; then
  echo "Release refused: AUTOROUTE_NOTARY_KEYCHAIN must point to the temporary keychain prepared for this run." >&2
  exit 2
fi
if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing $APP_DIR; run bash macos/build_app.sh first." >&2
  exit 1
fi
if [[ "${AUTOROUTE_REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
  SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
  if ! grep -F "Authority=$DEVELOPER_ID_APPLICATION" <<< "$SIGNATURE_INFO" >/dev/null; then
    echo "Release refused: the app is not signed by the requested Developer ID certificate; refusing notarization." >&2
    exit 2
  fi
fi
if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Missing $ZIP_PATH; run bash macos/package_app.sh first." >&2
  exit 1
fi

NOTARY_KEYCHAIN_ARGS=()
if [[ -n "$KEYCHAIN_PATH" ]]; then
  NOTARY_KEYCHAIN_ARGS=(--keychain "$KEYCHAIN_PATH")
fi
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$PROFILE" \
  "${NOTARY_KEYCHAIN_ARGS[@]}" \
  --wait
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
spctl -a -vv "$APP_DIR"
bash "$ROOT_DIR/macos/package_app.sh"
echo "Notarization and stapling verified. Rebuilt the final ZIP with its updated SHA-256."
