#!/bin/sh
# 生成 assets/AppIcon.icns。
set -e
cd "$(dirname "$0")/.."
mkdir -p assets
ICONSET="assets/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o assets/AppIcon.icns
rm -rf "$ICONSET"
echo "已生成 assets/AppIcon.icns"
