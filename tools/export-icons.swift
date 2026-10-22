// Run from the repository root: swift tools/export-icons.swift
// Native export only: the approved source artwork stays untouched.
import AppKit
import ImageIO
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = CGImageSourceCreateWithURL(root.appendingPathComponent("Assets/AppLogo.png") as CFURL, nil)!
let original = CGImageSourceCreateImageAtIndex(source, 0, nil)!
// Trim the generated transparent margin; macOS supplies the outer icon mask.
let artwork = original.cropping(to: CGRect(x: 100, y: 110, width: 1050, height: 1035))!
func png(_ size: Int, at url: URL) {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
}
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        png(points * scale, at: folder.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
    }
}
png(1024, at: root.appendingPathComponent("Assets/AppLogoDisplay.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", folder.path, "-o", root.appendingPathComponent("Assets/AppIcon.icns").path]
try process.run(); process.waitUntilExit()
precondition(process.terminationStatus == 0)
print("Native icon and Retina display asset exported; AppLogo.png preserved.")
