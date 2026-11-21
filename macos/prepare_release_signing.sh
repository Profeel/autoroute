#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "Release refused: prepare_release_signing.sh is CI-only and would replace the keychain search/default list. Run it only with GITHUB_ACTIONS=true on an ephemeral runner." >&2
  exit 2
fi

# CI-only bootstrap. Secrets are supplied to this step by the workflow, decoded
# into a private temporary directory, and never written to the repository.
required=(
  DEVELOPER_ID_APPLICATION
  DEVELOPER_ID_CERTIFICATE_P12_BASE64
  DEVELOPER_ID_CERTIFICATE_PASSWORD
  NOTARYTOOL_APPLE_ID
  NOTARYTOOL_APPLE_PASSWORD
  NOTARYTOOL_TEAM_ID
  NOTARYTOOL_KEYCHAIN_PROFILE
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Release refused: missing $name. A certificate/private key and notary credentials are required; ad-hoc is not a formal release." >&2
    exit 2
  fi
done
if [[ -z "${GITHUB_ENV:-}" ]]; then
  echo "Release refused: GITHUB_ENV is required so subsequent steps receive only temporary keychain paths." >&2
  exit 2
fi

umask 077
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/autoroute-release.XXXXXXXX")"
KEYCHAIN_PATH="$TEMP_DIR/autoroute-release.keychain-db"
P12_PATH="$TEMP_DIR/developer-id.p12"
KEYCHAIN_PASSWORD="$(uuidgen)-$(uuidgen)"

cleanup_failed_setup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup_failed_setup EXIT

printf '%s' "$DEVELOPER_ID_CERTIFICATE_P12_BASE64" | base64 --decode > "$P12_PATH"
if [[ ! -s "$P12_PATH" ]]; then
  echo "Release refused: the Developer ID PKCS#12 payload is empty or invalid." >&2
  exit 2
fi

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$P12_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "$DEVELOPER_ID_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH" >/dev/null
rm -f -- "$P12_PATH"

# Restrict this ephemeral runner to the temporary signing keychain. Do not
# alter a developer's login keychain when running this script locally.
security list-keychains -d user -s "$KEYCHAIN_PATH"
security default-keychain -d user -s "$KEYCHAIN_PATH"
if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -F "$DEVELOPER_ID_APPLICATION" >/dev/null; then
  echo "Release refused: the imported PKCS#12 does not contain the requested Developer ID Application identity and private key." >&2
  exit 2
fi

# Validate and store notary credentials in the same temporary keychain. The
# password is an argument only within this ephemeral process; shell tracing is
# intentionally not enabled and no credential is written to GITHUB_ENV.
xcrun notarytool store-credentials "$NOTARYTOOL_KEYCHAIN_PROFILE" \
  --apple-id "$NOTARYTOOL_APPLE_ID" \
  --password "$NOTARYTOOL_APPLE_PASSWORD" \
  --team-id "$NOTARYTOOL_TEAM_ID" \
  --keychain "$KEYCHAIN_PATH" \
  --validate

unset DEVELOPER_ID_CERTIFICATE_P12_BASE64 DEVELOPER_ID_CERTIFICATE_PASSWORD NOTARYTOOL_APPLE_PASSWORD
{
  printf 'DEVELOPER_ID_APPLICATION=%s\n' "$DEVELOPER_ID_APPLICATION"
  printf 'NOTARYTOOL_KEYCHAIN_PROFILE=%s\n' "$NOTARYTOOL_KEYCHAIN_PROFILE"
  printf 'AUTOROUTE_NOTARY_KEYCHAIN=%s\n' "$KEYCHAIN_PATH"
  printf 'AUTOROUTE_RELEASE_TEMP_DIR=%s\n' "$TEMP_DIR"
  printf 'AUTOROUTE_REQUIRE_DEVELOPER_ID=1\n'
} >> "$GITHUB_ENV"

echo "Temporary Developer ID keychain and validated notarytool profile are ready; no ad-hoc signing is permitted for this release."
