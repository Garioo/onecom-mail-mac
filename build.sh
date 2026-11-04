#!/bin/bash
# Builds "one.com Mail.app" from this folder. Requires Xcode Command Line Tools (xcode-select --install).
#
#   bash build.sh                    build, install into /Applications and open it (quits a running copy first)
#   bash build.sh --no-install       only build the app here
#   bash build.sh --release 1.3      build the version people download (used by release.sh): Intel + Apple
#                                    silicon, Sparkle updates from GitHub, no link back to this folder
#   bash build.sh --fetch            only download Sparkle into vendor/
#
# The app itself runs "build.sh --update <pid> <app path>" when you click Install Update.
set -euo pipefail
cd "$(dirname "$0")"
SRC="$(pwd)"

# Everything is also written to build.log in this folder (so errors can be read without copy-pasting).
exec > >(tee "$SRC/build.log") 2>&1
echo "Build started $(date)"

MODE="${1:-install}"
EXE="OneMail"
# Builds from this folder are a separate app, "one.com Mail Dev", so it can sit next to the
# downloaded one.com Mail without the two mixing up settings, windows or updates.
if [ "$MODE" = "--release" ]; then
  APP="one.com Mail.app"; NAME="one.com Mail"; BUNDLE_ID="local.personal.onecom-mail"; ICON_ARGS=""
else
  APP="one.com Mail Dev.app"; NAME="one.com Mail Dev"; BUNDLE_ID="local.personal.onecom-mail.dev"; ICON_ARGS="dev"
fi
# Releases run on Intel and Apple silicon Macs; everyday builds only for this Mac.
if [ "$MODE" = "--release" ]; then ARCHS="arm64 x86_64"; else ARCHS="$(uname -m)"; fi
VERSION="1.2"
if [ "$MODE" = "--release" ]; then VERSION="${2:?usage: build.sh --release <version>}"; fi

# Sparkle (the standard Mac updater) is downloaded once into vendor/ and checked against its known hash.
SPARKLE_VERSION="2.6.4"
SPARKLE_SHA256="50612a06038abc931f16011d7903b8326a362c1074dabccb718404ce8e585f0b"
SPARKLE="vendor/Sparkle"
if [ ! -d "$SPARKLE/Sparkle.framework" ]; then
  echo "→ Downloading Sparkle $SPARKLE_VERSION…"
  rm -rf vendor && mkdir -p vendor/dl "$SPARKLE"
  curl -sSLf -o vendor/dl/Sparkle.tar.xz \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA256  vendor/dl/Sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
  tar -xf vendor/dl/Sparkle.tar.xz -C "$SPARKLE"
fi
if [ "$MODE" = "--fetch" ]; then echo "SPARKLE_OK"; exit 0; fi

# Sign with your Apple Development certificate when there is one: a stable signature means macOS
# doesn't ask again for Keychain access after every update. Otherwise ad-hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
IDENTITY="${IDENTITY:--}"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install the Xcode Command Line Tools first:"
  echo "    xcode-select --install"
  exit 1
fi

# Build into a staging folder so a failed build never breaks the working app.
STAGE="build/$APP"
rm -rf build
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

echo "→ Compiling app…"
SLICES=()
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos12.0" \
    -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework Cocoa -framework SwiftUI -framework WebKit -framework Network -framework Security \
    -framework UserNotifications -framework ServiceManagement -framework UniformTypeIdentifiers \
    OneMail.swift Updater.swift RichText.swift MailMIME.swift MailIMAP.swift MailStore.swift MailViews.swift \
    MailCleanup.swift MailSmart.swift \
    -o "build/$EXE-$arch"
  SLICES+=("build/$EXE-$arch")
done
lipo -create "${SLICES[@]}" -output "$STAGE/Contents/MacOS/$EXE"
mkdir -p "$STAGE/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$STAGE/Contents/Frameworks/Sparkle.framework"

echo "→ Drawing icon…"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" AppIcon.swift -o build/makeicon
build/makeicon build/icon_1024.png
if [ -n "$ICON_ARGS" ]; then
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" DevBadge.swift -o build/devbadge
  build/devbadge build/icon_1024.png
fi
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  d=$((s * 2))
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $d $d build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"

STAMP="$(date +%s)"
if [ "$MODE" = "--release" ]; then
  : "${SPARKLE_PUBLIC_KEY:?release.sh sets SPARKLE_PUBLIC_KEY}"
  # Release builds update from GitHub through Sparkle instead of rebuilding from this folder.
  EXTRA_KEYS="  <key>SUFeedURL</key><string>https://raw.githubusercontent.com/Garioo/onecom-mail-mac/main/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>21600</integer>"
else
  SRC_XML_KEY="1"
  EXTRA_KEYS=""
fi
SRC_XML="$(printf '%s' "$SRC" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$STAMP</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal, unofficial app for one.com email.</string>
${SRC_XML_KEY:+  <key>OneMailSourceFolder</key><string>$SRC_XML</string>
}  <key>OneMailBuildStamp</key><string>$STAMP</string>
$EXTRA_KEYS
</dict>
</plist>
PLIST

echo "→ Signing ($([ "$IDENTITY" = "-" ] && echo ad-hoc || echo "$IDENTITY"))…"
# Inside out: Sparkle's helpers, the framework, then the app.
FW="$STAGE/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$IDENTITY" "$FW/XPCServices/Installer.xpc"
codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
codesign --force --sign "$IDENTITY" "$FW/Autoupdate"
codesign --force --sign "$IDENTITY" "$FW/Updater.app"
codesign --force --sign "$IDENTITY" "$STAGE/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$STAGE"
codesign --verify --deep --strict "$STAGE"

if [ "$MODE" = "--release" ]; then
  rm -rf dist && mkdir -p dist
  ditto "$STAGE" "dist/$APP"
  rm -rf build
  echo "BUILD_OK"
  echo "✓ Release build: $SRC/dist/$APP"
  exit 0
fi

# Keep a copy of the latest build next to the sources.
rm -rf "$SRC/$APP"
ditto "$STAGE" "$SRC/$APP"
rm -rf build
echo "BUILD_OK"

install_to() {
  local target="$1"
  if [ "$target" != "$SRC/$APP" ]; then
    rm -rf "$target"
    ditto "$SRC/$APP" "$target"
  fi
}

case "$MODE" in
  --no-install)
    echo "✓ Built: $SRC/$APP"
    ;;
  --update)
    PID="$2"
    TARGET="$3"
    # The app quits now; carry on quietly, swap in the new version and reopen it.
    exec >/dev/null 2>&1
    while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
    install_to "$TARGET"
    open "$TARGET"
    ;;
  *)
    TARGET="/Applications/$APP"
    if pgrep -f "$APP/Contents/MacOS/$EXE" >/dev/null 2>&1; then
      echo "→ Quitting the running app…"
      osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
      for _ in $(seq 1 50); do
        pgrep -f "$APP/Contents/MacOS/$EXE" >/dev/null 2>&1 || break
        sleep 0.2
      done
    fi
    echo "→ Installing to /Applications…"
    install_to "$TARGET"
    open "$TARGET"
    echo "✓ Installed and opened: $TARGET"
    echo "  From now on, updates install from inside the app (Update Ready → Install)."
    ;;
esac
