#!/usr/bin/env bash
# Usage: packaging/release.sh            (after `git push origin vX.Y.Z`)
# Computes the source tarball sha256 for the current version's tag and publishes
# Formula/pier.rb to StepanBlaha/homebrew-tap.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/PierCore/Version.swift)"
TAG="v${VERSION}"
URL="https://github.com/StepanBlaha/pier/archive/refs/tags/${TAG}.tar.gz"

git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null \
  || { echo "tag ${TAG} is not on origin; push it first"; exit 1; }

SHA="$(curl -fsSL "$URL" | shasum -a 256 | awk '{print $1}')"
echo "pier ${VERSION}  sha256 ${SHA}"

TAP="$(mktemp -d)/homebrew-tap"
gh repo clone StepanBlaha/homebrew-tap "$TAP" -- --quiet
mkdir -p "$TAP/Formula"
sed -e "s/{{VERSION}}/${VERSION}/g" -e "s/{{SHA256}}/${SHA}/g" packaging/pier.rb.template > "$TAP/Formula/pier.rb"

cd "$TAP"
git add Formula/pier.rb
if git diff --cached --quiet; then echo "formula unchanged"; exit 0; fi
git commit -q -m "pier ${VERSION}"
git push -q origin HEAD
echo "Published Formula/pier.rb (${VERSION}) to StepanBlaha/homebrew-tap"
