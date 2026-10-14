#!/usr/bin/env bash
# Upload a file to the GitHub release for a tag (creates it if missing).
#
# Usage: github-release-upload.sh <tag> <file> [name]
#
# Env:
#   GITHUB_REPO   e.g. tanishq-dubey/grandcentralterminal
#   GITHUB_TOKEN  token with contents:write on that repo
set -euo pipefail

TAG="${1:?usage: $0 <tag> <file> [name]}"
FILE="${2:?usage: $0 <tag> <file> [name]}"
NAME="${3:-$(basename "$FILE")}"
: "${GITHUB_REPO:?GITHUB_REPO required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN required}"

API="https://api.github.com/repos/$GITHUB_REPO"
api() {
  curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" "$@"
}

# Create-or-get: GET 404s when the tag has no release yet.
REL_ID=$(api "$API/releases/tags/$TAG" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)
if [ -z "$REL_ID" ]; then
  REL_ID=$(api -X POST "$API/releases" \
    -d "{\"tag_name\":\"$TAG\",\"name\":\"$TAG\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  echo "created release $TAG (id $REL_ID)"
fi

api -X POST -H "Content-Type: application/octet-stream" \
  --data-binary "@$FILE" \
  "https://uploads.github.com/repos/$GITHUB_REPO/releases/$REL_ID/assets?name=$NAME" \
  > /dev/null
echo "uploaded $NAME to $TAG (github)"
