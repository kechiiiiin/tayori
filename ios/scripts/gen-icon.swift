// アプリアイコン（1024px）を描く: `swift scripts/gen-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
// 便り = 封筒。モックのアクセント色（#c2552d）の地に白い封筒と、未読の丸
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
// 封筒
let env = NSRect(x: 192, y: 262, width: 640, height: 460)
let body = NSBezierPath(roundedRect: env, xRadius: 44, yRadius: 44)
NSColor(white: 1, alpha: 0.97).setFill()
body.fill()
let flap = NSBezierPath()
flap.move(to: NSPoint(x: env.minX + 30, y: env.maxY - 24))
flap.line(to: NSPoint(x: env.midX, y: env.midY - 10))
flap.line(to: NSPoint(x: env.maxX - 30, y: env.maxY - 24))
flap.lineWidth = 30
flap.lineCapStyle = .round
flap.lineJoinStyle = .round
NSColor(red: 0.76, green: 0.33, blue: 0.18, alpha: 0.9).setStroke()
flap.stroke()
// 未読の丸
let dot = NSBezierPath(ovalIn: NSRect(x: 700, y: 640, width: 170, height: 170))
NSColor(red: 0.96, green: 0.85, blue: 0.55, alpha: 1).setFill()
dot.fill()
NSColor.white.setStroke()
dot.lineWidth = 22
dot.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
