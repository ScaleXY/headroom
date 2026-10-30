#!/bin/bash
# Signs with the Apple Development certificate from the environment, without touching your
# keychains: `identity` prints its SHA-1; `open <path>` builds a throwaway keychain holding only
# that certificate (never added to the search list; codesign reaches it with --keychain);
# `close <path>` deletes it.
#   APPLE_DEVELOPER_ACCOUNT_APPLE_DEVELOPMENT_CERTIFICATE_P12_BASE64   the .p12, base64
#   APPLE_DEVELOPER_ACCOUNT_APPLE_DEVELOPMENT_CERTIFICATE_PASSWORD     its password
set -euo pipefail
p12="${APPLE_DEVELOPER_ACCOUNT_APPLE_DEVELOPMENT_CERTIFICATE_P12_BASE64:?not set}"
password="${APPLE_DEVELOPER_ACCOUNT_APPLE_DEVELOPMENT_CERTIFICATE_PASSWORD-}"
file=$(mktemp)
trap 'rm -f "$file"' EXIT
printf '%s' "$p12" | base64 --decode > "$file"
[ -s "$file" ] || { echo "error: the .p12 variable is empty" >&2; exit 1; }

case "$1" in
  identity)
    export P12_PASSWORD="$password"
    cert=$(openssl pkcs12 -in "$file" -nokeys -clcerts -passin env:P12_PASSWORD 2>/dev/null \
        || openssl pkcs12 -in "$file" -nokeys -clcerts -passin env:P12_PASSWORD -legacy 2>/dev/null) \
      || { echo "error: couldn't read the .p12 (wrong password?)" >&2; exit 1; }
    openssl x509 -outform der <<< "$cert" | shasum -a 1 | awk '{print toupper($1)}'
    ;;
  open)
    keychain="$2" secret=$(uuidgen)
    security delete-keychain "$keychain" 2>/dev/null || true
    security create-keychain -p "$secret" "$keychain"
    security set-keychain-settings -lut 3600 "$keychain"
    security unlock-keychain -p "$secret" "$keychain"
    security import "$file" -f pkcs12 -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$secret" "$keychain" >/dev/null
    ;;
  close)
    security delete-keychain "$2" 2>/dev/null || true
    ;;
esac
