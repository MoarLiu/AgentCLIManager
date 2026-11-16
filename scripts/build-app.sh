#!/bin/sh
# 构建并组装「Agent CLI Manager.app」。
#
#   ./scripts/build-app.sh            构建 release 并签名
#   CONFIG=debug ./scripts/build-app.sh
#   CODESIGN_IDENTITY="名字" ./scripts/build-app.sh   指定签名身份（默认 ad-hoc）
#
# 不修改系统的 xcode-select：需要 Xcode 工具链时只对本次命令设置 DEVELOPER_DIR。
set -e
cd "$(dirname "$0")/.."

APP_NAME="Agent CLI Manager"
EXECUTABLE="AgentCLIManager"
BUNDLE_ID="dev.agentclimanager.AgentCLIManager"
VERSION="0.2.2"
BUILD="4"
CONFIG="${CONFIG:-release}"
SCRATCH_PATH="${SCRATCH_PATH:-.build}"

# SwiftUI 的宏（@State 等）在 macOS 27 SDK 里需要 SwiftUIMacros 插件，
# 它只随 Xcode 提供，CommandLineTools 里没有。引擎和测试不受影响。
if [ -z "$DEVELOPER_DIR" ]; then
    if [ -d /Applications/Xcode.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        echo "警告：没有找到 Xcode。SwiftUI 界面需要 Xcode 的工具链才能编译。" >&2
    fi
fi

./scripts/embed-catalog.sh
# 发布构建关闭调试信息，并映射诊断字符串中的源码路径。
if [ "$CONFIG" = "release" ]; then
    set -- -debug-info-format none \
        -Xswiftc -file-prefix-map -Xswiftc "$(pwd)=/src/AgentCLIManager" \
        -Xswiftc -strict-concurrency=complete
else
    set --
fi
swift build -c "$CONFIG" --scratch-path "$SCRATCH_PATH" --product "$EXECUTABLE" "$@"
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH_PATH" --show-bin-path)"

OUT="build/$APP_NAME.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$OUT/Contents/MacOS/$EXECUTABLE"
if [ "$CONFIG" = "release" ]; then
    /usr/bin/strip -S "$OUT/Contents/MacOS/$EXECUTABLE"
fi
printf 'APPL????' > "$OUT/Contents/PkgInfo"

if [ ! -f assets/AppIcon.icns ] && [ -f scripts/make-icon.swift ]; then
    ./scripts/make-icon.sh || echo "图标生成失败，继续（App 会用默认图标）" >&2
fi
if [ -f assets/AppIcon.icns ]; then
    cp assets/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
fi

# 工具标识：只读 bundle 内的图，运行时不联网
if [ -d assets/tool-logos ]; then
    mkdir -p "$OUT/Contents/Resources/tool-logos"
    find assets/tool-logos -name '*.png' -exec cp {} "$OUT/Contents/Resources/tool-logos/" \;
    cp assets/tool-logos/README.md assets/tool-logos/*-LICENSE.txt "$OUT/Contents/Resources/tool-logos/"
fi

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# 签名。默认 ad-hoc：不动用你钥匙串里的任何私钥。
# 想让系统授权在重新构建后依然有效，用固定身份：CODESIGN_IDENTITY="你的身份名"
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$OUT"
if [ "$IDENTITY" = "-" ]; then echo "已 ad-hoc 签名"; else echo "已用「$IDENTITY」签名"; fi

echo "完成：$OUT"
