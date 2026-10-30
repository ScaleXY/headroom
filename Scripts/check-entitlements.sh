#!/bin/bash
# Fails when a provisioning profile doesn't grant what the entitlements file asks for. Signing
# with an entitlement the profile lacks still succeeds, but the app is then killed at launch.
#   Scripts/check-entitlements.sh <profile.provisionprofile> <entitlements.plist>
set -euo pipefail
profile="$1" entitlements="$2"
granted=$(mktemp)
trap 'rm -f "$granted"' EXIT
security cms -D -i "$profile" | plutil -extract Entitlements xml1 -o "$granted" -

if [ "$(security cms -D -i "$profile" | plutil -extract ExpirationDate raw -o - - 2>/dev/null | cut -c1-10)" \< "$(date -u +%Y-%m-%d)" ]; then
  echo "error: $profile has expired." >&2
  exit 1
fi

status=0
for key in com.apple.developer.icloud-container-identifiers com.apple.developer.icloud-services \
           com.apple.developer.icloud-container-environment com.apple.developer.aps-environment; do
  wanted=$(plutil -extract "$key" json -o - "$entitlements" 2>/dev/null || true)
  [ -n "$wanted" ] || continue
  have=$(plutil -extract "$key" json -o - "$granted" 2>/dev/null || true)
  if [ -z "$have" ]; then
    echo "error: the profile doesn't grant $key." >&2
    status=1
    continue
  fi
  # Every requested value must appear among the granted ones (profiles often grant arrays or "*").
  for value in $(printf '%s' "$wanted" | tr -d '[]"' | tr ',' ' '); do
    case "$have" in
      *"\"$value\""*|*'"*"'*) ;;
      *) echo "error: the profile grants $key = $have, not $value." >&2; status=1 ;;
    esac
  done
done
exit $status
