#!/usr/bin/env bash
set -u

KEYCHAIN_PATH="${AUTOROUTE_NOTARY_KEYCHAIN:-}"
TEMP_DIR="${AUTOROUTE_RELEASE_TEMP_DIR:-}"

if [[ -n "$KEYCHAIN_PATH" ]]; then
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
fi

if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
  case "$(basename "$TEMP_DIR")" in
    autoroute-release.*)
      rm -rf -- "$TEMP_DIR"
      ;;
    *)
      echo "Refusing to remove an unexpected release temporary directory: $TEMP_DIR" >&2
      exit 1
      ;;
  esac
fi
