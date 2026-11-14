#!/bin/sh
# 跑单元测试。全部在临时目录里的假家目录上运行，不碰真实家目录。
#
# 需要 Xcode 的工具链：Swift Testing 的宏插件只随 Xcode 提供。
# 只编译引擎和 acm 命令行的话，用 CommandLineTools 就够（swift build --product acm）。
set -e
cd "$(dirname "$0")/.."
if [ -z "$DEVELOPER_DIR" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
./scripts/embed-catalog.sh
swift test "$@"
