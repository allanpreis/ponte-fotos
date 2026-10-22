import Foundation
@main struct ReviewAlbumTests {
    static func main() throws {
        let (lat, lon) = try MetadataOverride.coordinates(" -23,55052 ", "−46,63331")
        precondition(lat == -23.55052 && lon == -46.63331)
        for pair in [("91","0"),("0","181"),("nan","0"),("","0"),("12","abc")] {
            do { _ = try MetadataOverride.coordinates(pair.0, pair.1); fatalError("Coordenada inválida aceita") } catch is BridgeError { }
        }
        let original = CaptureMetadata(date: Date(timeIntervalSince1970: 100), latitude: nil, longitude: nil, favorite: true)
        let edit = MetadataOverride(date: nil, latitude: lat, longitude: lon)
        let effective = edit.applying(to: original)
        precondition(effective.date == original.date && effective.favorite && effective.latitude == lat)
        let saved = try JSONDecoder().decode(MetadataOverride.self, from: JSONEncoder().encode(edit))
        precondition(saved.longitude == lon && saved.hasChanges)
        let success = [AlbumAddResult(id: "a", success: true, error: nil), AlbumAddResult(id: "b", success: false, error: "duplicate")]
        try AlbumAddResult.validate(success, expected: ["a", "b"])
        for results in [[AlbumAddResult](), [AlbumAddResult(id: "a", success: false, error: "no_permission")]] {
            do { try AlbumAddResult.validate(results, expected: ["a"]); fatalError("Álbum não confirmado aceito") } catch is BridgeError { }
        }
        let album = try JSONDecoder().decode(ImmichAlbum.self, from: Data(#"{"id":"abc","albumName":"Férias","shared":true,"assetCount":17}"#.utf8))
        precondition(album.albumName == "Férias" && album.shared == true)
        print("12 verificações passaram: coordenadas, persistência, metadados efetivos, resposta de álbum e erros por item.")
    }
}
