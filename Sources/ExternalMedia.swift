import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import AppKit

struct ExternalMedia {
    let url: URL
    let sidecar: URL?
    let metadata: CaptureMetadata
    let note: String
    var isVideo: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true || ["mov","mp4","m4v","avi","mkv","mts","m2ts","webm","3gp"].contains(url.pathExtension.lowercased()) }
}
struct ExternalVolume: Identifiable {
    let url: URL
    let name: String
    var id: String { url.path }
}
@MainActor final class VolumeMonitor: ObservableObject {
    @Published var volumes: [ExternalVolume] = []
    private var observers: [NSObjectProtocol] = []
    init() {
        refresh()
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        }
    }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    func refresh() {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), url.path.hasPrefix("/Volumes/"), values.volumeIsInternal != true, values.volumeIsLocal == true, values.volumeIsBrowsable != false else { return nil }
            return ExternalVolume(url: url, name: values.volumeName ?? url.lastPathComponent)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
struct ExternalScanResult { let media: [ExternalMedia]; let issues: Int }
enum ExternalReader {
    static func supported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["jpg","jpeg","heic","heif","png","tif","tiff","gif","webp","avif","dng","cr2","cr3","nef","arw","raf","orf","rw2","pef","srw","mov","mp4","m4v","avi","mkv","mts","m2ts","webm","3gp"].contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }
    static func parseDate(_ text: String, offset: String? = nil) -> Date? {
        if let date = CaptureMetadata.parse(text) { return date }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.isLenient = false
        if let offset { f.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"; if let date = f.date(from: text + offset) { return date } }
        f.timeZone = .current
        for format in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] { f.dateFormat = format; if let date = f.date(from: text) { return date } }
        return nil
    }
    static func coordinate(_ text: String, latitude: Bool? = nil) -> Double? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardinal: Character?
        if let last = value.last, "NSEW".contains(last) {
            cardinal = last
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else { cardinal = nil }
        if let latitude, let cardinal, !(latitude ? "NS" : "EW").contains(cardinal) { return nil }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (1...3).contains(parts.count) else { return nil }
        func number(_ token: String, signed: Bool, integer: Bool = false) -> Double? {
            let pattern = (signed ? "^[+-]?" : "^") + (integer ? "[0-9]+$" : #"(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#)
            guard token.range(of: pattern, options: .regularExpression) != nil,
                  let number = Double(token), number.isFinite else { return nil }
            return number
        }
        guard let degrees = number(parts[0], signed: true, integer: parts.count > 1) else { return nil }
        var magnitude = abs(degrees)
        if parts.count > 1 {
            guard let minutes = number(parts[1], signed: false, integer: parts.count == 3), minutes < 60 else { return nil }
            magnitude += minutes / 60
        }
        if parts.count == 3 {
            guard let seconds = number(parts[2], signed: false), seconds < 60 else { return nil }
            magnitude += seconds / 3600
        }
        let negative = parts[0].hasPrefix("-")
        let cardinalNegative = cardinal == "S" || cardinal == "W"
        if cardinal != nil {
            if negative && !cardinalNegative { return nil }
            if parts[0].hasPrefix("+") && cardinalNegative { return nil }
        }
        let limit = latitude == true || cardinal == "N" || cardinal == "S" ? 90.0 : 180.0
        guard magnitude <= limit else { return nil }
        return magnitude * ((negative || cardinalNegative) ? -1 : 1)
    }
    static func isoLocation(_ text: String) -> (Double,Double)? {
        let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let lr = Range(match.range(at: 1), in: text), let gr = Range(match.range(at: 2), in: text), let lat = Double(text[lr]), let lon = Double(text[gr]), abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (lat,lon)
    }
    static func sidecar(_ url: URL) -> URL? {
        for candidate in [url.appendingPathExtension("xmp"),url.deletingPathExtension().appendingPathExtension("xmp"),url.appendingPathExtension("XMP"),url.deletingPathExtension().appendingPathExtension("XMP")] {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
    static func read(_ url: URL) async throws -> ExternalMedia {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw BridgeError(message: L("Arquivo indisponível ou sem permissão de leitura.")) }
        var date: Date?, lat: Double?, lon: Double?
        var notes: [String] = []
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            if let value = (exif["DateTimeOriginal"] ?? exif["DateTimeDigitized"] ?? tiff["DateTime"]) as? String {
                date = parseDate(value, offset: exif["OffsetTimeOriginal"] as? String)
                if date != nil { notes.append(exif["OffsetTimeOriginal"] == nil ? L("EXIF · fuso não informado, usando Mac") : "EXIF") }
            }
            if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any], let a = gps["Latitude"] as? Double, let b = gps["Longitude"] as? Double {
                lat = a * ((gps["LatitudeRef"] as? String) == "S" ? -1 : 1)
                lon = b * ((gps["LongitudeRef"] as? String) == "W" ? -1 : 1)
            }
        } else if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true || ["mkv","avi","mts","m2ts"].contains(url.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: url)
            if let metadata = try? await asset.load(.metadata) {
                for item in metadata {
                    let identifier = item.identifier?.rawValue.lowercased() ?? ""
                    guard let value = try? await item.load(.stringValue) else { continue }
                    if identifier.contains("creationdate") || identifier.contains("creation.date") || identifier.contains("©day") || item.commonKey?.rawValue.lowercased() == "creationdate" {
                        if let parsed = parseDate(value) { date = parsed; notes.append("QuickTime") }
                    }
                    if identifier.contains("location"), let location = isoLocation(value) { lat = location.0; lon = location.1 }
                }
            } else { notes.append(L("Metadados do vídeo não legíveis")) }
        }
        let companion = sidecar(url)
        if let companion {
            do {
                let document = try XMLDocument(contentsOf: companion, options: [.nodeLoadExternalEntitiesNever])
                func value(_ names: [String]) -> String? {
                    for name in names {
                        if let node = try? document.nodes(forXPath: "//*[local-name()='\(name)'] | //@*[local-name()='\(name)']").first, let value = node.stringValue { return value }
                    }
                    return nil
                }
                if let text = value(["SubSecDateTimeOriginal","DateTimeOriginal","SubSecCreateDate","CreateDate","CreationDate","MediaCreateDate"]), let parsed = parseDate(text) { date = parsed; notes.append("XMP") }
                let sidecarLatitude = value(["GPSLatitude"]), sidecarLongitude = value(["GPSLongitude"])
                if sidecarLatitude != nil || sidecarLongitude != nil {
                    guard let a = sidecarLatitude, let b = sidecarLongitude,
                          let parsedA = coordinate(a, latitude: true), let parsedB = coordinate(b, latitude: false) else {
                        throw BridgeError(message: L("GPS inválido ou incompleto no XMP."))
                    }
                    lat = parsedA; lon = parsedB
                }
            } catch { throw BridgeError(message: L("XMP inválido em \(url.lastPathComponent). Revise o arquivo auxiliar antes de importar.")) }
        }
        if let a = lat, let b = lon, (!a.isFinite || !b.isFinite || abs(a) > 90 || abs(b) > 180) { lat = nil; lon = nil }
        return ExternalMedia(url: url, sidecar: companion, metadata: CaptureMetadata(date: date, latitude: lat, longitude: lon, favorite: false), note: notes.joined(separator: " · "))
    }
    static func scan(_ folder: URL) async -> ExternalScanResult {
        var media: [ExternalMedia] = [], issues = 0
        let keys: [URLResourceKey] = [.isRegularFileKey,.isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles,.skipsPackageDescendants], errorHandler: { _,_ in issues += 1; return true }) else { return ExternalScanResult(media: [], issues: 1) }
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { issues += 1; continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, supported(url) else { continue }
            do { media.append(try await read(url)) } catch { issues += 1 }
        }
        return ExternalScanResult(media: media.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }, issues: issues)
    }
    static func mergedXMP(_ metadata: CaptureMetadata, sidecar: URL?) throws -> Data {
        guard let sidecar else { return Data(metadata.xmp().utf8) }
        let document = try XMLDocument(contentsOf: sidecar, options: [.nodeLoadExternalEntitiesNever])
        guard let description = try document.nodes(forXPath: "//*[local-name()='Description']").first as? XMLElement else { throw BridgeError(message: L("XMP sem descrição RDF válida.")) }
        description.addNamespace(XMLNode.namespace(withName: "exif", stringValue: "http://ns.adobe.com/exif/1.0/") as! XMLNode)
        description.addNamespace(XMLNode.namespace(withName: "xmp", stringValue: "http://ns.adobe.com/xap/1.0/") as! XMLNode)
        var fields: [String: String] = [:]
        if let date = metadata.date { fields["exif:DateTimeOriginal"] = CaptureMetadata.iso(date); fields["xmp:CreateDate"] = CaptureMetadata.iso(date) }
        if let lat = metadata.latitude, let lon = metadata.longitude { fields["exif:GPSLatitude"] = CaptureMetadata.gps(lat, positive: "N", negative: "S"); fields["exif:GPSLongitude"] = CaptureMetadata.gps(lon, positive: "E", negative: "W") }
        for (name,value) in fields {
            let local = name.split(separator: ":").last!
            for node in try document.nodes(forXPath: "//*[local-name()='\(local)'] | //@*[local-name()='\(local)']") { node.detach() }
            description.addChild(XMLElement(name: name, stringValue: value))
        }
        // Remove higher-priority date tags which could override a manual date correction.
        if metadata.date != nil { for name in ["SubSecDateTimeOriginal","SubSecCreateDate"] { for node in try document.nodes(forXPath: "//*[local-name()='\(name)'] | //@*[local-name()='\(name)']") { node.detach() } } }
        return document.xmlData(options: [.nodePrettyPrint])
    }
}
