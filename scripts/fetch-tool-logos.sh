#!/bin/sh
# 重新获取工具官方图标，覆盖 assets/tool-logos/*.png。
#
#   ./scripts/fetch-tool-logos.sh           # 覆盖全部
#   ./scripts/fetch-tool-logos.sh kilo-cli  # 只更新某几个
#
# 需要 Xcode 工具链（用 AppKit 栅格化 SVG）。临时文件放在系统临时目录，
# 脚本自身不放进下载目录。来源与授权见 assets/tool-logos/README.md。
set -e
cd "$(dirname "$0")/.."

WORK="${TMPDIR:-/tmp}/acm-tool-logos"
mkdir -p "$WORK/raw"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 Chrome/130 Safari/537.36"

# id=URL
SOURCES="
claude-code=https://claude.com/icon.svg
codex=https://github.com/openai.png
grok-cli=https://grok.com/images/android-chrome-512x512.png
qoder-cli=https://img.alicdn.com/imgextra/i4/O1CN01QkSxiCocd3D0prc8_!!6000000008124-2-tps-412-412.png
pi=https://pi.dev/favicon.svg
cursor-cli=https://cursor.com/marketing-static/apple-touch-icon-light.png
gemini-cli=https://geminicli.com/icon.png
opencode=https://opencode.ai/apple-touch-icon-v3.png
aider=https://github.com/Aider-AI.png
goose=https://raw.githubusercontent.com/block/goose/main/ui/desktop/src/images/icon.png
amp=https://ampcode.com/app-icon.png
crush=https://github.com/charmbracelet.png
copilot-cli=https://raw.githubusercontent.com/primer/octicons/main/icons/copilot-24.svg
qwen-code=https://qwenlm.github.io/qwen-code-docs/favicon.png
cline=https://cline.bot/assets/branding/favicons/apple-touch-icon.png
droid=https://factory.ai/favicon.svg
kilo-cli=https://kilo.ai/favicon/favicon.svg
openhands-cli=https://www.all-hands.dev/favicon.svg
continue-cli=https://continue.dev/favicon.png
kimi-code=https://www.kimi.com/pwa-192.png
iflow-cli=https://cli.iflow.cn/img/favicon.ico
codebuddy-code=https://codebuddy-1328495429.cos.accelerate.myqcloud.com/web/ide/logo.svg
auggie=https://www.augmentcode.com/favicon.svg
kiro-cli=https://kiro.dev/apple-icon.png
"

# 把原图统一成 128×128：自带不透明底板的满尺寸绘制（底板用边缘色补齐成方形），
# 裸字形则白底 + 16% 内边距，保证黑色字形在深色模式下也看得见。
cat > "$WORK/normalize.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
let rawDir = args[1], outDir = args[2], side = 128
for pair in args.dropFirst(3) {
    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
    guard let src = NSImage(contentsOfFile: rawDir + "/" + parts[1]) else {
        FileHandle.standardError.write(Data("无法加载 \(parts[1])\n".utf8)); continue
    }
    let probe = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: probe)
    src.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
    NSGraphicsContext.restoreGraphicsState()
    let mids = [(128, 2), (128, 253), (2, 128), (253, 128)]
        .map { probe.colorAt(x: $0.0, y: $0.1) ?? .clear }
    let tile = mids.allSatisfy { $0.alphaComponent > 0.9 }
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current?.imageInterpolation = .high
    (tile ? mids[0].withAlphaComponent(1) : .white).setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    let inset = tile ? 0.0 : Double(side) * 0.16
    src.draw(in: NSRect(x: inset, y: inset, width: Double(side) - inset * 2, height: Double(side) - inset * 2))
    NSGraphicsContext.restoreGraphicsState()
    try! out.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outDir)/\(parts[0]).png"))
    print("\(parts[0])\t\(tile ? "图块" : "字形")")
}
SWIFT
swiftc -O "$WORK/normalize.swift" -o "$WORK/normalize"

mkdir -p assets/tool-logos
pairs=""
for entry in $SOURCES; do
    id="${entry%%=*}"; url="${entry#*=}"
    if [ "$#" -gt 0 ]; then
        case " $* " in *" $id "*) ;; *) continue;; esac
    fi
    ext="${url##*.}"
    if ! curl -fsSL -A "$UA" --max-time 25 -o "$WORK/raw/$id.$ext" "$url"; then
        echo "跳过 $id：下载失败（保留已有图）" >&2
        continue
    fi
    "$WORK/normalize" "$WORK/raw" "$PWD/assets/tool-logos" "$id=$id.$ext"
done
echo "完成。请重新运行 ./scripts/build-app.sh 把新图打包进 App。"
