// 生成 App 图标的各个尺寸。由 scripts/make-icon.sh 调用：
//   swift scripts/make-icon.swift <输出的 .iconset 目录>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("用法：make-icon.swift <iconset 目录>\n".utf8))
    exit(2)
}
let outputDir = arguments[1]
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let size = CGFloat(pixels)

    // macOS 图标的留白与圆角比例
    let inset = size * 0.098
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = tile.width * 0.2237
    let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.33, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.13, alpha: 1),
    ])?.draw(in: shape, angle: -90)

    // 提示符 >_
    let fontSize = tile.width * 0.36
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let prompt = NSAttributedString(string: ">_", attributes: [
        .font: font,
        .foregroundColor: NSColor(calibratedWhite: 0.97, alpha: 1),
    ])
    let textSize = prompt.size()
    prompt.draw(at: NSPoint(
        x: tile.minX + tile.width * 0.15,
        y: tile.midY - textSize.height / 2 + tile.height * 0.06
    ))

    // 右下角的清理标记
    let badgeDiameter = tile.width * 0.34
    let badge = NSRect(
        x: tile.maxX - badgeDiameter - tile.width * 0.09,
        y: tile.minY + tile.height * 0.09,
        width: badgeDiameter, height: badgeDiameter
    )
    NSColor(calibratedRed: 0.98, green: 0.47, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(ovalIn: badge).fill()

    let cross = NSBezierPath()
    let arm = badgeDiameter * 0.19
    cross.move(to: NSPoint(x: badge.midX - arm, y: badge.midY - arm))
    cross.line(to: NSPoint(x: badge.midX + arm, y: badge.midY + arm))
    cross.move(to: NSPoint(x: badge.midX - arm, y: badge.midY + arm))
    cross.line(to: NSPoint(x: badge.midX + arm, y: badge.midY - arm))
    cross.lineWidth = max(1, badgeDiameter * 0.11)
    cross.lineCapStyle = .round
    NSColor.white.setStroke()
    cross.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    guard let data = render(pixels: variant.pixels) else {
        FileHandle.standardError.write(Data("渲染 \(variant.name) 失败\n".utf8))
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: outputDir + "/" + variant.name + ".png"))
}
print("已生成 \(variants.count) 个尺寸")
