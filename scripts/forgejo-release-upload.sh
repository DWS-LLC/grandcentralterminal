#!/usr/bin/env bash
# Upload a file to the Forgejo release for a tag (creates it if missing).
#
# Usage: forgejo-release-upload.sh <tag> <file> [name]
#
# Env:
#   FORGEJO_URL    e.g. https://git.dubey.io (no trailing slash)
#   FORGEJO_REPO   e.g. dubey/grandcentralterminal
#   FORGEJO_TOKEN  API token with repo write
set -euo pipefail

TAG="${1:?usage: $0 <tag> <file> [name]}"
FILE="${2:?usage: $0 <tag> <file> [name]}"
NAME="${3:-$(basename "$FILE")}"
: "${FORGEJO_URL:?FORGEJO_URL required}"
: "${FORGEJO_REPO:?FORGEJO_REPO required}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN required}"

api() {
  curl -fsSL -H "Authorization: token $FORGEJO_TOKEN" \
    -H "Content-Type: application/json" "$@"
}

# Create-or-get: POST 404s when the tag release is missing, GET finds it.
REL_ID=$(api "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/releases/tags/$TAG" \
  2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' \
  2>/dev/null || true)
if [ -z "$REL_ID" ]; then
  REL_ID=$(api -X POST "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/releases" \
    -d "$(printf '{"tag_name":%s,"name":%s}' \
      "$(printf '%s' "$TAG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      "$(printf '%s' "$TAG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  echo "created release $TAG (id $REL_ID)"
fi

curl -fsSL -H "Authorization: token $FORGEJO_TOKEN" \
  -F "attachment=@$FILE;filename=$NAME" \
  "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/releases/$REL_ID/assets?name=$NAME" \
  > /dev/null
echo "uploaded $NAME to $TAG"
