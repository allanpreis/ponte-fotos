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
        let validCoordinates: [(String, Double)] = [
            ("23,30,30S", -23.508333333333333), ("46,30,15W", -46.50416666666667),
            (" 23 , 30 , 30 S ", -23.508333333333333), ("23,30.5S", -23.508333333333333),
            ("-23.5083333333", -23.5083333333), ("23.5N", 23.5), ("46.5E", 46.5),
            ("-23,30,30S", -23.508333333333333), ("90,0,0N", 90), ("180,0W", -180),
            ("0,0,30S", -0.008333333333333333), ("+23.5N", 23.5)
        ]
        for (input, expected) in validCoordinates {
            guard let actual = ExternalReader.coordinate(input) else { preconditionFailure("Coordenada válida rejeitada: \(input)") }
            precondition(abs(actual - expected) < 0.000000001, "Segundos ou hemisfério incorretos: \(input)")
        }
        let invalidCoordinates = ["", "23,broken,30S", "23,,30S", "23,30,S", "23,30,30,1S",
                                  "23,60S", "23,30,60S", "23,-1S", "23,30,-1S", "23.5,30S",
                                  "23,30.5,30S", "nan", "inf", "1e2", "91N", "90,0,1S", "181E",
                                  "-23N", "+23S", "23Q", "23NS", "23s", ",23S", "23S trailing"]
        for input in invalidCoordinates { precondition(ExternalReader.coordinate(input) == nil, "Coordenada inválida aceita: \(input)") }
        precondition(ExternalReader.coordinate("46W", latitude: true) == nil)
        precondition(ExternalReader.coordinate("23N", latitude: false) == nil)
        precondition(ExternalReader.coordinate("91", latitude: true) == nil)
        func gpsXMP(_ latitude: String?, _ longitude: String?) -> String {
            let latitudeXML = latitude.map { "<exif:GPSLatitude>\($0)</exif:GPSLatitude>" } ?? ""
            let longitudeXML = longitude.map { "<exif:GPSLongitude>\($0)</exif:GPSLongitude>" } ?? ""
            return CaptureMetadata(date: nil, latitude: nil, longitude: nil, favorite: false).xmp()
                .replacingOccurrences(of: "</rdf:Description>", with: latitudeXML + longitudeXML + "</rdf:Description>")
        }
        try Data(gpsXMP("23,30,30S", "46,30,15W").utf8).write(to: xmp)
        let secondsOverride = try await ExternalReader.read(original)
        precondition(abs(secondsOverride.metadata.latitude! - (-23.508333333333333)) < 0.000000001)
        precondition(abs(secondsOverride.metadata.longitude! - (-46.50416666666667)) < 0.000000001)
        let invalidSidecars: [(String?, String?)] = [
            ("23,broken,30S", "46,30W"), ("23,30S", nil), (nil, "46,30W"),
            ("", "46W"), ("23,60S", "46W"), ("23S", "181W"), ("23E", "46W"), ("-23N", "46W")
        ]
        for (latitude, longitude) in invalidSidecars {
            try Data(gpsXMP(latitude, longitude).utf8).write(to: xmp)
            do {
                _ = try await ExternalReader.read(original)
                preconditionFailure("XMP GPS inválido não pode usar o EXIF silenciosamente")
            } catch {
                precondition(error.localizedDescription.contains("XMP inválido"))
            }
        }
        let blockedScan = await ExternalReader.scan(folder)
        precondition(blockedScan.media.count == 1 && blockedScan.issues == 1)
        // A sidecar without GPS still allows the original EXIF GPS.
        try Data(gpsXMP(nil, nil).utf8).write(to: xmp)
        let noSidecarGPS = try await ExternalReader.read(original)
        precondition(noSidecarGPS.metadata.latitude == -23.5 && noSidecarGPS.metadata.longitude == -46.5)
        precondition(!ExternalReader.supported(folder.appendingPathComponent("notes.txt")))
        let result = await ExternalReader.scan(folder)
        precondition(result.media.count == 2 && result.issues == 0)
        if CommandLine.arguments.contains("--keep") { print("FIXTURE: \(folder.path)") }
        print("\(10 + validCoordinates.count + invalidCoordinates.count + 3 + 4 + invalidSidecars.count) verificações externas passaram: EXIF/GPS, XMP prioritário, segundos e rejeição de GPS inválido/parcial sem fallback silencioso.")
    }
}
