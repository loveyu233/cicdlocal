#!/usr/bin/env swift
// 从矢量路径生成本项目图标的各个尺寸，不依赖外部图像或字体文件。
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let directory = root.appending(path: "App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
        NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.29, blue: 0.70, alpha: 1),
                   ending: NSColor(srgbRed: 0.16, green: 0.64, blue: 0.91, alpha: 1))!.draw(in: tile, angle: 70)
        let track = NSBezierPath()
        track.move(to: NSPoint(x: 280, y: 512))
        track.line(to: NSPoint(x: 744, y: 512))
        track.lineWidth = 36
        track.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke()
        track.stroke()
        NSColor.white.setFill()
        for x in [280.0, 512.0, 744.0] {
            NSBezierPath(ovalIn: NSRect(x: x - 76, y: 436, width: 152, height: 152)).fill()
        }
        let blue = NSColor(srgbRed: 0.12, green: 0.42, blue: 0.77, alpha: 1)
        blue.setFill()
        NSBezierPath(ovalIn: NSRect(x: 256, y: 488, width: 48, height: 48)).fill()
        let play = NSBezierPath()
        play.move(to: NSPoint(x: 491, y: 474))
        play.line(to: NSPoint(x: 491, y: 550))
        play.line(to: NSPoint(x: 548, y: 512))
        play.close()
        play.fill()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: 711, y: 512))
        check.line(to: NSPoint(x: 735, y: 488))
        check.line(to: NSPoint(x: 780, y: 540))
        check.lineWidth = 18
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        blue.setStroke()
        check.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon-\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appending(path: filename))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]],
                           options: [.prettyPrinted, .sortedKeys]).write(to: directory.appending(path: "Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]],
                           options: [.prettyPrinted]).write(to: directory.deletingLastPathComponent().appending(path: "Contents.json"))
print("应用图标已生成。")
