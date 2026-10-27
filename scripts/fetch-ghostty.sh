#!/usr/bin/env bash
# Clones ghostty at the pinned commit and applies the external-IO patch.
set -euo pipefail
cd "$(dirname "$0")/.."

PIN="83fb95624b0439ee660c2679b43b38c8b63769cd"   # ghostty v1.4.0

if [ ! -d vendor/ghostty ]; then
  git clone --depth 1 https://github.com/ghostty-org/ghostty.git vendor/ghostty
fi
PATCH="$PWD/patches/libghostty-external-io.patch"
(
  cd vendor/ghostty
  current=$(git rev-parse HEAD 2>/dev/null || true)
  if [ "$current" != "$PIN" ]; then
    git fetch --depth 1 origin "$PIN"
    git checkout -q --detach "$PIN"
  fi
  # Already applied (dirty tree from a previous apply)? Skip quietly.
  git diff --quiet || { echo "patch already applied"; exit 0; }
  # Fresh tree: the patch MUST apply — a silent skip builds the wrong
  # header and Swift fails hours later on missing external-IO symbols.
  git apply "$PATCH"
)
