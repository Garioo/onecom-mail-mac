#!/bin/bash
# Publishes a new version of one.com Mail on GitHub. Everyone with the downloaded app gets it
# through "Check for Updates…" (Sparkle checks every few hours on its own).
#
#   bash release.sh 1.3 "Folders can now be renamed and deleted."
#
# Needs: the GitHub CLI signed in (gh auth login), and the Sparkle signing key in this Mac's
# Keychain (made once with: vendor/Sparkle/bin/generate_keys). Commit your changes first.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: bash release.sh VERSION NOTES}"
NOTES="${2:-}"
REPO="Garioo/onecom-mail-mac"
APP="one.com Mail.app"
NAME="one.com-Mail-$VERSION"

if [ -n "$(git status --porcelain)" ]; then
  echo "Commit (or discard) your changes first, so the release matches what's on GitHub:"
  git status --short
  exit 1
fi
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "Version $VERSION is already released. Pick a higher number."
  exit 1
fi

bash build.sh --fetch >/dev/null
SPARKLE_PUBLIC_KEY="$(vendor/Sparkle/bin/generate_keys -p)"
export SPARKLE_PUBLIC_KEY
bash build.sh --release "$VERSION"

echo "→ Packing…"
# The zip is what Sparkle downloads; the disk image is what people download the first time.
ditto -c -k --sequesterRsrc --keepParent "dist/$APP" "dist/$NAME.zip"
DMG_STAGE="dist/dmg"
mkdir -p "$DMG_STAGE"
ditto "dist/$APP" "$DMG_STAGE/$APP"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -quiet -volname "one.com Mail" -srcfolder "$DMG_STAGE" -ov -format UDZO "dist/$NAME.dmg"
rm -rf "$DMG_STAGE"

echo "→ Signing the update…"
SIGNATURE="$(vendor/Sparkle/bin/sign_update "dist/$NAME.zip")"   # sparkle:edSignature="…" length="…"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "dist/$APP/Contents/Info.plist")"
NOTES_XML="$(printf '%s' "${NOTES:-Version $VERSION}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"

echo "→ Publishing on GitHub…"
git push --quiet origin HEAD
gh release create "v$VERSION" "dist/$NAME.dmg" "dist/$NAME.zip" --repo "$REPO" \
  --title "one.com Mail $VERSION" --notes "${NOTES:-Version $VERSION}"

# The feed goes up only after the files exist, so no one is offered a download that isn't there yet.
cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>one.com Mail</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>$NOTES_XML</p>]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$NAME.zip"
                 type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
git add appcast.xml
git commit --quiet -m "Release $VERSION"
git push --quiet origin HEAD

echo "✓ Released $VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
echo "  Download page to share: https://github.com/$REPO/releases/latest"
