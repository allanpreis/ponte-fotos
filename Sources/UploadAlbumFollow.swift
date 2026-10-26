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
    func uploadFollowAlbumAssetIDs(_ id: String, userID: String) async throws -> Set<String> {
        guard UUID(uuidString: id) != nil else { throw BridgeError(message: M("Atualize e selecione um álbum de destino.")) }
        // Immich 3 album details do not embed the assets array. Reuse the
        // timeline-bucket query already used by library management and import.
        let credential = IMCredential(account: IMAccount(id: userID, name: ""), key: key)
        return try await IMClient(address: base.absoluteString, credential: credential, session: transport).albumIDs(id)
    }
}
