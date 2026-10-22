import Foundation
@main struct MetadataTests {
    static func main() throws {
        let date = CaptureMetadata.parse("2020-01-02T03:04:05Z")!
        let metadata = CaptureMetadata(date: date, latitude: -23.5, longitude: -46.625, favorite: true)
        let document = try XMLDocument(xmlString: metadata.xmp())
        assert(document.rootElement() != nil)
        assert(metadata.xmp().contains("23,30.00000000S"))
        assert(metadata.xmp().contains("46,37.50000000W"))
        assert(metadata.xmp().contains("2020-01-02T03:04:05Z"))
        func remote(_ date: String, _ latitude: Double, _ live: String? = nil) -> RemoteAsset {
            RemoteAsset(fileCreatedAt: date, exifInfo: .init(latitude: latitude, longitude: -46.625), livePhotoVideoId: live)
        }
        assert(metadata.verify(remote("2020-01-02T03:04:05.000Z", -23.5), liveVideoID: nil))
        assert(!metadata.verify(remote("2026-10-12T03:04:05Z", -23.5), liveVideoID: nil))
        assert(!metadata.verify(remote("2020-01-02T03:04:05Z", 23.5), liveVideoID: nil))
        assert(!metadata.verify(remote("2020-01-02T03:04:05Z", -23.5), liveVideoID: "paired"))
        assert(metadata.verify(remote("2020-01-02T03:04:05Z", -23.5, "paired"), liveVideoID: "paired"))
        let missing = CaptureMetadata(date: nil, latitude: nil, longitude: nil, favorite: false)
        assert(!missing.xmp().contains("DateTimeOriginal"))
        assert(!missing.xmp().contains("GPSLatitude"))
        assert(!missing.verify(remote("2020-01-02T03:04:05Z", -23.5), liveVideoID: nil))
        print("11 verificações passaram: XML, GPS, data, ausência e Live Photo.")
    }
}
