#!/usr/bin/env bash
# Rewrite Casks/gct.rb in the Homebrew tap for a release and push it.
#
# Usage: bump-tap.sh <tag> <zip>
#
# Env:
#   TAP_REPO   default DWS-LLC/homebrew-tap
#   TAP_TOKEN  token with contents:write on the tap (CI)
#   TAP_DIR    existing checkout to write into; no clone, no commit, no push
set -euo pipefail

TAG="${1:?usage: $0 <tag> <zip>}"
ZIP="${2:?usage: $0 <tag> <zip>}"
VER="${TAG#v}"
TAP_REPO="${TAP_REPO:-DWS-LLC/homebrew-tap}"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

PUSH=no
if [ -z "${TAP_DIR:-}" ]; then
  : "${TAP_TOKEN:?TAP_TOKEN required}"
  TAP_DIR="$(mktemp -d)"
  git clone --depth 1 "https://x-access-token:${TAP_TOKEN}@github.com/${TAP_REPO}.git" "$TAP_DIR"
  PUSH=yes
fi

mkdir -p "$TAP_DIR/Casks"
cat > "$TAP_DIR/Casks/gct.rb" <<CASK
cask "gct" do
  version "${VER}"
  sha256 "${SHA}"

  url "https://github.com/DWS-LLC/grandcentralterminal/releases/download/v#{version}/GrandCentralTerminal-#{version}-macos-arm64.zip"
  name "Grand Central Terminal"
  desc "Infinite-canvas terminal with a persistent daemon"
  homepage "https://github.com/DWS-LLC/grandcentralterminal"

  # Brew installs don't self-update; the app points users at brew upgrade.
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Grand Central Terminal.app"

  zap trash: "~/Library/Application Support/Grand Central Terminal"
end
CASK

[ "$PUSH" = yes ] || { echo "wrote $TAP_DIR/Casks/gct.rb"; exit 0; }

cd "$TAP_DIR"
git config user.name "release-bot"
git config user.email "release-bot@users.noreply.github.com"
git add Casks/gct.rb
git diff --cached --quiet && { echo "tap already at $VER"; exit 0; }
git commit -m "gct ${VER}"
git push origin HEAD
echo "tap bumped to $VER"
