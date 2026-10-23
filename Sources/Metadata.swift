import Foundation

struct CaptureMetadata: Codable {
    let date: Date?
    let latitude: Double?
    let longitude: Double?
    let favorite: Bool
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    func xmp() -> String {
        var fields = ""
        if let date { fields += "<exif:DateTimeOriginal>\(Self.iso(date))</exif:DateTimeOriginal><xmp:CreateDate>\(Self.iso(date))</xmp:CreateDate>" }
        if let latitude, let longitude {
            fields += "<exif:GPSLatitude>\(Self.gps(latitude, positive: "N", negative: "S"))</exif:GPSLatitude>"
            fields += "<exif:GPSLongitude>\(Self.gps(longitude, positive: "E", negative: "W"))</exif:GPSLongitude>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:xmp="http://ns.adobe.com/xap/1.0/">\(fields)</rdf:Description></rdf:RDF></x:xmpmeta>
        """
    }
    static func gps(_ value: Double, positive: String, negative: String) -> String {
        let absolute = abs(value), degrees = Int(abs(value))
        return String(format: "%d,%.8f%@", locale: Locale(identifier: "en_US_POSIX"), degrees, (absolute - Double(degrees)) * 60, value < 0 ? negative : positive)
    }
    func verify(_ remote: RemoteAsset, liveVideoID: String?) -> Bool {
        guard let date, let captured = Self.parse(remote.fileCreatedAt), abs(date.timeIntervalSince(captured)) < 1 else { return false }
        if let latitude, let longitude {
            guard let lat = remote.exifInfo?.latitude, let lon = remote.exifInfo?.longitude,
                  abs(lat - latitude) < 0.00001, abs(lon - longitude) < 0.00001 else { return false }
        }
        if let liveVideoID, remote.livePhotoVideoId != liveVideoID { return false }
        return remote.exifInfo != nil
    }
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
struct RemoteAsset: Decodable {
    struct Exif: Decodable { let latitude: Double?; let longitude: Double? }
    let fileCreatedAt: String
    let exifInfo: Exif?
    let livePhotoVideoId: String?
}
struct UploadResult: Codable { let id: String; let status: String }

struct MetadataOverride: Codable {
    var date: Date?
    var latitude: Double?
    var longitude: Double?
    var hasChanges: Bool { date != nil || latitude != nil }
    func applying(to original: CaptureMetadata) -> CaptureMetadata {
        CaptureMetadata(date: date ?? original.date, latitude: latitude ?? original.latitude, longitude: longitude ?? original.longitude, favorite: original.favorite)
    }
    static func coordinates(_ latitude: String, _ longitude: String) throws -> (Double, Double) {
        func number(_ text: String) -> Double? { Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")) }
        guard let lat = number(latitude), let lon = number(longitude), lat.isFinite, lon.isFinite,
              (-90...90).contains(lat), (-180...180).contains(lon) else {
            throw BridgeError(message: L("Informe latitude entre −90 e 90 e longitude entre −180 e 180. Exemplo: −23,55052 e −46,63331."))
        }
        return (lat, lon)
    }
}
