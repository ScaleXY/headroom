#!/bin/zsh
# Writes a version into every file that carries one:
#   Scripts/set-version.sh <version> [build]            e.g. 0.1.2-beta.1 42   (the Mac app and CLI)
#   Scripts/set-version.sh --mobile <version> [build]   e.g. 1.0.1 7           (iPhone, iPad and Watch)
# CFBundleShortVersionString gets the version without its suffix (0.1.2), as macOS expects;
# CFBundleVersion gets <build> when one is given and is left alone otherwise.
# The release workflow runs this with the tag's version, so a tag alone is enough to release.
set -euo pipefail
cd "${0:A:h}/.."

if [[ ${1:-} == --mobile ]]; then
  version=${2:?usage: Scripts/set-version.sh --mobile <version> [build]}
  build=${3:-}
  if [[ ! $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "error: '$version' isn't an App Store version like 1.2.3." >&2
    exit 1
  fi
  sed -i '' -E "s/^HEADROOM_MOBILE_VERSION = .*/HEADROOM_MOBILE_VERSION = $version/" Mobile/Config/Base.xcconfig
  [[ -n $build ]] && sed -i '' -E "s/^HEADROOM_MOBILE_BUILD = .*/HEADROOM_MOBILE_BUILD = $build/" Mobile/Config/Base.xcconfig
  grep -q "^HEADROOM_MOBILE_VERSION = $version\$" Mobile/Config/Base.xcconfig
  echo "Set the iPhone and Watch version to $version${build:+ (build $build)}."
  exit 0
fi

version=${1:?usage: Scripts/set-version.sh <version> [build]}
build=${2:-}
if [[ ! $version =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' ]]; then
  echo "error: '$version' isn't a version like 1.2.3 or 1.2.3-beta.4." >&2
  exit 1
fi

sed -i '' -E "s/^VERSION( *):= .*/VERSION\1:= $version/" Makefile
sed -i '' -E "s/(public static let version = )\"[^\"]*\"/\1\"$version\"/" Sources/HeadroomCLI/HeadroomCLI.swift
sed -i '' -E "s/\"Headroom [^\"]*\"/\"Headroom $version\"/" Packaging/headroom.1
plist_set() { sed -i '' -E "s|(<key>$1</key><string>)[^<]*(</string>)|\\1$2\\2|" Packaging/Info.plist; }
plist_set CFBundleShortVersionString "${version%%-*}"
plist_set HeadroomVersion "$version"
[[ -n $build ]] && plist_set CFBundleVersion "$build"

grep -q "^VERSION *:= $version\$" Makefile
grep -qF "\"$version\"" Sources/HeadroomCLI/HeadroomCLI.swift
grep -qF "\"Headroom $version\"" Packaging/headroom.1
[[ $(plutil -extract CFBundleShortVersionString raw Packaging/Info.plist) == "${version%%-*}" ]]
[[ $(plutil -extract HeadroomVersion raw Packaging/Info.plist) == "$version" ]]
[[ -z $build || $(plutil -extract CFBundleVersion raw Packaging/Info.plist) == "$build" ]]
echo "Set the version to $version${build:+ (build $build)}."
