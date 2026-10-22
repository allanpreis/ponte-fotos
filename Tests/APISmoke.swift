import Foundation
@main struct APISmoke {
    static func main() async throws {
        let client = try ImmichClient(address: "http://127.0.0.1:18761", key: "fixture-only")
        let albums = try await client.albums(); precondition(albums.count == 1)
        let album = try await client.createAlbum(" Teste "); precondition(album.id == "album-1")
        try await client.addToAlbum(album.id, assetIDs: ["photo-1"])
        try await client.applyReview(MetadataOverride(date: Date(timeIntervalSince1970: 0), latitude: -23.5, longitude: -46.5), to: "photo-1")
        print("Fluxo HTTP local passou: listar, criar, adicionar e atualizar revisão com os corpos esperados.")
    }
}
