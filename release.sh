#!/bin/bash
set -e

VERSION=$1
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version>  e.g. ./release.sh 1.2"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEY_FILE="$HOME/.kantracker_release_key"
SPARKLE_SIGN="/opt/homebrew/Caskroom/sparkle/2.9.2/bin/sign_update"
TAP_DIR="$HOME/Documents/Cursor/homebrew-kantracker"
REPO="trmp10/kantracker"
ARCHIVE_PATH="/tmp/KanTracker_${VERSION}.xcarchive"
APP_PATH="/tmp/KanTracker.app"
ZIP_PATH="/tmp/KanTracker.zip"

# Guard: private key must exist
if [ ! -f "$KEY_FILE" ]; then
    echo "Error: private key not found at $KEY_FILE"
    exit 1
fi

echo "→ Bumping version to $VERSION..."
sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $VERSION;/" "$SCRIPT_DIR/KanTracker.xcodeproj/project.pbxproj"

# Increment build number
BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION" "$SCRIPT_DIR/KanTracker.xcodeproj/project.pbxproj" | grep -o '[0-9]*')
NEW_BUILD=$((BUILD + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = $BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$SCRIPT_DIR/KanTracker.xcodeproj/project.pbxproj"

echo "→ Building..."
xcodebuild -scheme KanTracker -configuration Release -archivePath "$ARCHIVE_PATH" archive 2>&1 | tail -3

echo "→ Zipping..."
rm -rf "$APP_PATH" "$ZIP_PATH"
cp -R "$ARCHIVE_PATH/Products/Applications/KanTracker.app" "$APP_PATH"
cd /tmp && zip -r "$ZIP_PATH" "KanTracker.app" > /dev/null
rm -rf "$APP_PATH"

SIZE=$(wc -c < "$ZIP_PATH" | tr -d ' ')
SHA=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')

echo "→ Signing..."
SIGN_OUT=$("$SPARKLE_SIGN" "$ZIP_PATH" --ed-key-file "$KEY_FILE" 2>&1)
ED_SIG=$(echo "$SIGN_OUT" | grep -o 'edSignature="[^"]*"' | cut -d'"' -f2)

echo "→ Updating appcast..."
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
python3 - <<PYEOF
import re

new_item = """    <item>
      <title>KanTracker $VERSION</title>
      <sparkle:version>$NEW_BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <pubDate>$PUBDATE</pubDate>
      <enclosure
        url="https://github.com/$REPO/releases/download/v$VERSION/KanTracker.zip"
        sparkle:edSignature="$ED_SIG"
        length="$SIZE"
        type="application/octet-stream"/>
    </item>"""

path = "$SCRIPT_DIR/docs/appcast.xml"
content = open(path).read()
content = content.replace("  </channel>", new_item + "\n  </channel>", 1)
open(path, "w").write(content)
print("  appcast updated")
PYEOF

echo "→ Committing..."
cd "$SCRIPT_DIR"
git add KanTracker.xcodeproj/project.pbxproj docs/appcast.xml
git commit -m "Release v${VERSION}"
git push

echo "→ Creating GitHub release..."
gh release create "v${VERSION}" "$ZIP_PATH" \
    --title "KanTracker v${VERSION}" \
    --notes "KanTracker v${VERSION}" \
    --repo "$REPO"

echo "→ Updating Homebrew cask..."
cd "$TAP_DIR"
git pull
sed -i '' "s/version \".*\"/version \"${VERSION}\"/" Casks/kantracker.rb
sed -i '' "s/sha256 \".*\"/sha256 \"${SHA}\"/" Casks/kantracker.rb
git add Casks/kantracker.rb
git commit -m "Update KanTracker cask to v${VERSION}"
git push

echo ""
echo "Released v${VERSION} — users will see the update prompt on next check."
