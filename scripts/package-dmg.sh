#!/bin/sh
# 先运行测试与 build-app.sh，再将已构建的 App 打包成 DMG。
set -eu
cd "$(dirname "$0")/.."

APP="build/Agent CLI Manager.app"
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || { echo "请先运行 ./scripts/build-app.sh" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")
ARCH=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/$EXECUTABLE" | tr ' ' '-')
NAME="Agent-CLI-Manager-$VERSION-$ARCH"
OUT="$(pwd)/build/release"
DMG="$OUT/$NAME.dmg"

codesign --verify --deep --strict "$APP"
python3 scripts/check-release-privacy.py
python3 scripts/check-release-privacy.py "$APP"

mkdir -p "$OUT"
STAGE=$(mktemp -d /tmp/acm-dmg.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 1' HUP INT TERM

ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/Agent CLI Manager.app"
ln -s /Applications "$STAGE/Applications"
python3 scripts/check-release-privacy.py "$STAGE"
hdiutil create -volname "Agent CLI Manager $VERSION" -srcfolder "$STAGE" \
    -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
(cd "$OUT" && shasum -a 256 "$NAME.dmg" > SHA256SUMS)
echo "完成：$DMG"
cat "$OUT/SHA256SUMS"
