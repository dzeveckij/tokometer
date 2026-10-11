#!/bin/zsh
# Builds Tokometer locally and publishes it as a GitHub release.
#   ./release.sh 0.1.0
# Needs a clean working tree and the GitHub CLI (gh) logged in.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version>  e.g. ./release.sh 0.1.0}
TAG=v$VERSION

[[ -z "$(git status --porcelain)" ]] || { echo "Working tree not clean; commit first." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "Tag $TAG already exists." >&2; exit 1; }

VERSION=$VERSION ./build.sh
ZIP=build/Tokometer-$VERSION.zip
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent build/Tokometer.app "$ZIP"

# Point the Homebrew cask at this release.
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/tokometer.rb
git add Casks/tokometer.rb
git commit -q -m "Cask: Tokometer $VERSION"

git tag -a "$TAG" -m "Tokometer $VERSION"
git push origin HEAD "$TAG"
gh release create "$TAG" "$ZIP" --title "Tokometer $VERSION" --generate-notes
