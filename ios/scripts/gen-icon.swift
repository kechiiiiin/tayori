// アプリアイコン（1024px）を描く: `swift scripts/gen-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
// 音沙汰 = 四方から寄せる波が、真ん中の一点（手元）に届く形。モックのアクセント色（#c2552d）の地に、外の半透明の弧→内の白い弧→黄色い点
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(starting: NSColor(red: 0.84, green: 0.40, blue: 0.24, alpha: 1), ending: NSColor(red: 0.70, green: 0.30, blue: 0.16, alpha: 1))!
    .draw(in: rect, angle: -90)
// 下書き（140×140・上が y=0）の座標を 1024px（下が y=0）へ
let k = CGFloat(size) / 140
func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * k, y: CGFloat(size) - y * k) }
let center = pt(70, 70)
// 四方（斜め4方向）から寄せる弧。方向は AppKit の角度（上が正）
let diagonals: [CGFloat] = [135, 45, -45, -135]
func ring(radius: CGFloat, half: CGFloat, alpha: CGFloat) {
    NSColor(white: 1, alpha: alpha).setStroke()
    for d in diagonals {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius * k, startAngle: d - half, endAngle: d + half, clockwise: false)
        arc.lineWidth = 7 * k
        arc.lineCapStyle = .round
        arc.stroke()
    }
}
ring(radius: 44, half: 16.8, alpha: 0.5)   // 外側（半透明）
ring(radius: 26, half: 19.0, alpha: 0.97)  // 内側（白）
// 真ん中の一点（手元）
let r = 11 * k
NSColor(red: 0.96, green: 0.85, blue: 0.55, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
