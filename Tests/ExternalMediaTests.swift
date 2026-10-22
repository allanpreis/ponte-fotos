import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@main struct ExternalMediaTests {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ponte-external-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if !CommandLine.arguments.contains("--keep") { try? FileManager.default.removeItem(at: folder) } }
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!
        func write(_ name: String, props: [CFString:Any]) -> URL {
            let url = folder.appendingPathComponent(name)
            let target = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(target, image, props as CFDictionary)
            precondition(CGImageDestinationFinalize(target)); return url
        }
        let emptyURL = write("missing.jpg", props: [:])
        let empty = try await ExternalReader.read(emptyURL)
        precondition(empty.metadata.date == nil && empty.metadata.latitude == nil) // No filesystem date fallback.
        let original = write("capture.jpg", props: [kCGImagePropertyExifDictionary: ["DateTimeOriginal":"2020:04:05 12:30:00","OffsetTimeOriginal":"-03:00"],kCGImagePropertyGPSDictionary:["Latitude":23.5,"LatitudeRef":"S","Longitude":46.5,"LongitudeRef":"W"]])
        let embedded = try await ExternalReader.read(original)
        precondition(embedded.metadata.date == CaptureMetadata.parse("2020-04-05T15:30:00Z"))
        precondition(embedded.metadata.latitude == -23.5 && embedded.metadata.longitude == -46.5)
        let xmp = original.appendingPathExtension("xmp")
        let override = CaptureMetadata(date: CaptureMetadata.parse("2021-01-02T03:04:05Z"),latitude: -22,longitude: -43,favorite: false)
        try Data(override.xmp().replacingOccurrences(of:"</rdf:Description>",with:"<xmp:Label>preserve-me</xmp:Label></rdf:Description>").utf8).write(to: xmp)
        let withXMP = try await ExternalReader.read(original)
        precondition(withXMP.metadata.date == override.date && withXMP.metadata.latitude == -22)
        let changed = CaptureMetadata(date: CaptureMetadata.parse("2022-02-03T00:00:00Z"),latitude: -21,longitude: -42,favorite: false)
        let merged = try ExternalReader.mergedXMP(changed, sidecar: xmp)
        precondition(String(data: merged, encoding: .utf8)!.contains("preserve-me"))
        try merged.write(to: xmp)
        let reread = try await ExternalReader.read(original)
        precondition(reread.metadata.date == changed.date && reread.metadata.longitude == -42)
        precondition(ExternalReader.isoLocation("-23.5000-046.5000+010.0/")?.1 == -46.5)
        precondition(ExternalReader.coordinate("23,30S") == -23.5)
        precondition(!ExternalReader.supported(folder.appendingPathComponent("notes.txt")))
        let result = await ExternalReader.scan(folder)
        precondition(result.media.count == 2 && result.issues == 0)
        if CommandLine.arguments.contains("--keep") { print("FIXTURE: \(folder.path)") }
        print("10 verificações externas passaram: ausência sem fallback, EXIF/GPS, XMP prioritário e preservado, coordenadas e scan.")
    }
}
