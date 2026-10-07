#!/usr/bin/env bash
# Clones ghostty at the pinned commit and applies the external-IO patch.
set -euo pipefail
cd "$(dirname "$0")/.."

PIN="a4aacd918ba9e79929ff608034c60a4341773ef0"   # upstream master, 2026-10-06

if [ ! -d vendor/ghostty ]; then
  git clone --depth 1 https://github.com/ghostty-org/ghostty.git vendor/ghostty
fi
(
  cd vendor/ghostty
  current=$(git rev-parse HEAD 2>/dev/null || true)
  if [ "$current" != "$PIN" ]; then
    git fetch --depth 1 origin "$PIN"
    git checkout -q --detach "$PIN"
  fi
  git apply --check ../patches/libghostty-external-io.patch 2>/dev/null &&
    git apply ../patches/libghostty-external-io.patch ||
    git diff --quiet || echo "patch already applied"
)
echo "vendor/ghostty ready at $PIN + patches/libghostty-external-io.patch"
