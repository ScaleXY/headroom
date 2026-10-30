#!/bin/bash
# Prints the SHA-1 of every certificate a provisioning profile allows to sign with.
#   Scripts/profile-certificates.sh <profile.provisionprofile>
set -euo pipefail
plist=$(security cms -D -i "$1")
count=$(plutil -extract DeveloperCertificates raw -o - - <<< "$plist")
for ((i = 0; i < count; i++)); do
  plutil -extract "DeveloperCertificates.$i" raw -o - - <<< "$plist" | base64 --decode | shasum -a 1 | awk '{print toupper($1)}'
done
