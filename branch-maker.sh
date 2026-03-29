#!/bin/bash

read -p "Enter the Minecraft version you are updating to: " VERSION

if [ -z "$VERSION" ]; then
    echo "No version entered, exiting."
    exit 1
fi

BRANCH="support/$(git branch --show-current | sed 's/support\///')"
CURRENT=$(git branch --show-current)

echo ""
echo "Current branch: $CURRENT"
echo "Tagging current state as v$VERSION-prev and creating support branch..."

# Tag and freeze current version before moving on
git tag "v$CURRENT-final" 2>/dev/null || true
git checkout -b "support/$CURRENT"
git push origin "support/$CURRENT"

# Go back to main and tag the new target version
git checkout main
git tag "v$VERSION"
git push origin "v$VERSION"

# Create the new working branch for this version
git checkout -b "support/$VERSION"
git push origin "support/$VERSION"

echo ""
echo "Done! You are now on branch: support/$VERSION"
echo "Run your update.sh to pull in the new pack changes."