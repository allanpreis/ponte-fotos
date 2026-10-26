import Foundation
import CryptoKit

struct PFUploadFollowContext: Equatable {
    let scope: String
    let albumID: String
    let destinationID: String
    let networkRevision: Int
}

enum PFUploadFollowIdentity {
    static func scope(profileID: String, userID: String) -> String {
        SHA256.hash(data: Data((profileID + "|" + userID).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func fingerprint(id: String, modified: Date?, metadata: CaptureMetadata, live: Bool, resources: [String]) -> String {
        let fields = [id, modified.map { String($0.timeIntervalSince1970) } ?? "",
            metadata.date.map { String($0.timeIntervalSince1970) } ?? "",
            metadata.latitude.map { String($0) } ?? "", metadata.longitude.map { String($0) } ?? "",
            String(metadata.favorite), String(live)] + resources
        // Length-prefixing keeps user filenames from introducing delimiter collisions.
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension ImmichClient {
    func uploadFollowAlbumAssetIDs(_ id: String) async throws -> Set<String> {
        guard UUID(uuidString: id) != nil else { throw BridgeError(message: M("Atualize e selecione um álbum de destino.")) }
        struct Album: Decodable { struct Asset: Decodable { let id: String }; let id: String; let assets: [Asset] }
        var r = request("albums/\(id)"); r.timeoutInterval = 15
        let (data, response) = try await transport.data(for: r); try check(response)
        let album = try JSONDecoder().decode(Album.self, from: data)
        guard album.id == id else { throw BridgeError(message: M("Atualize e selecione um álbum de destino.")) }
        return Set(album.assets.map(\.id))
    }
}
