#!/usr/bin/env bash
# Writes release notes for a tag to stdout: a Claude-written summary of the commits since the
# previous release, then install instructions and the full changelog link.
#
#   Scripts/release-notes.sh v0.1.4 [previous-tag]
#
# Needs ANTHROPIC_API_KEY, jq, curl, and the tags fetched (git fetch --tags). Without a previous
# tag, a stable release is compared with the last stable tag before it and a pre-release with the
# last tag of any kind.
set -euo pipefail

tag=${1:?usage: Scripts/release-notes.sh <tag> [previous-tag]}
previous=${2:-}
repo=${GITHUB_REPOSITORY:-ScaleXY/headroom}
model=${RELEASE_NOTES_MODEL:-claude-opus-5-5}
: "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY}"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "No tag $tag here; fetch the tags first." >&2; exit 1; }
version=${tag#v}
case "$version" in *-*) prerelease=1 ;; *) prerelease= ;; esac

if [ -z "$previous" ]; then
  # versionsort.suffix sorts v0.1.0-beta.4 before v0.1.0, so the tag after ours is the one before it.
  tags=$(git -c versionsort.suffix=- tag --list 'v*' --sort=-v:refname | sed -n "/^$(printf '%s' "$tag" | sed 's/[.]/\\./g')\$/,\$p" | tail -n +2)
  [ -z "$prerelease" ] && previous=$(printf '%s\n' "$tags" | grep -v -- '-' | head -n 1 || true)
  [ -n "$previous" ] || previous=$(printf '%s\n' "$tags" | head -n 1)
fi

if [ -n "$previous" ]; then
  range="$previous..$tag"
  compare="https://github.com/$repo/compare/$previous...$tag"
else
  range="$tag"
  compare="https://github.com/$repo/commits/$tag"
fi

# Commit messages carry the detail; trailers are noise.
commits=$(git log --no-merges --reverse --format='commit %h%n%s%n%n%b%n' "$range" | grep -v -i '^Co-Authored-By:' || true)
[ -n "$commits" ] || { echo "No commits in $range." >&2; exit 1; }
files=$(git diff --stat=200 "${previous:-$(git hash-object -t tree /dev/null)}" "$tag")
# The top of the README says what Headroom is, for context.
about=$(git show "$tag:README.md" 2>/dev/null | sed -n '1,/^## /p' | sed -e 's/<[^>]*>//g' -e '/^## /d' -e '/^[[:space:]]*$/d' || true)

read -r -d '' system <<'EOF' || true
You write the release notes for Headroom, a macOS menu bar app that shows whether a person's Claude and Codex plan allowances will last the week. Readers are Mac users deciding whether to update, not developers of the app.

Write from the commits you're given:
- Open with one short sentence on what the release is about.
- Then a bulleted list of the changes people will notice, most important first. Start each bullet with a bold phrase naming the change, then say in plain language what is different for the user. Group related commits into one bullet.
- Leave out changes users won't notice (CI, tests, refactors, build scripts, repository docs) unless they change how Headroom is installed or updated. If nothing user-facing changed, write a single sentence saying it's a maintenance release and what it improves.
- Don't invent changes or details the commits don't support.
- No headings, no title, no version number, no install instructions, no changelog link, no preamble or closing remarks. Output only the Markdown for the notes.

An example of the style:

The first stable release of Headroom, now published from ScaleXY.

- **Signed and notarized.** Headroom is signed with a Developer ID and notarized by Apple, so it opens without any security warnings.
- **Fixed a crash at launch** on Macs other than the one that built the app; cost estimates now load from inside the app.
- **Cleaner 5-hour graph.** Its labels no longer overlap.
EOF

user="<release>Headroom $version${prerelease:+ (pre-release)}, changes since ${previous:-the first commit}</release>

<about>
$about
</about>

<commits>
$commits
</commits>

<files_changed>
$files
</files_changed>"

request=$(jq -n --arg model "$model" --arg system "$system" --arg user "$user" '{
  model: $model,
  max_tokens: 16000,
  output_config: {effort: "medium"},
  fallbacks: "default",
  system: $system,
  messages: [{role: "user", content: $user}]
}')

response=$(curl -sS --fail-with-body --retry 3 --retry-all-errors --max-time 600 https://api.anthropic.com/v1/messages \
  -H "content-type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2026-10-21" \
  -H "anthropic-beta: server-side-fallback-2026-07-01" \
  -d "$request") || { echo "The Claude API request failed: $response" >&2; exit 1; }

stop=$(jq -r '.stop_reason' <<<"$response")
[ "$stop" = end_turn ] || { echo "Claude stopped with $stop: $(jq -c '.stop_details' <<<"$response")" >&2; exit 1; }
summary=$(jq -r '[.content[] | select(.type == "text") | .text] | join("")' <<<"$response")
[ -n "$summary" ] || { echo "Claude returned no text." >&2; exit 1; }

printf '%s\n\n' "$summary"
if [ -n "$prerelease" ]; then
  cat <<EOF
Install this pre-release:
\`\`\`
curl -fsSL https://raw.githubusercontent.com/$repo/main/install.sh | bash -s -- --version $tag
\`\`\`

EOF
else
  cat <<EOF
Install or update:
\`\`\`
curl -fsSL https://raw.githubusercontent.com/$repo/main/install.sh | bash
\`\`\`
Or with Homebrew: \`brew upgrade --cask ai-headroom\`.

EOF
fi
printf '**Full changelog:** %s\n' "$compare"
