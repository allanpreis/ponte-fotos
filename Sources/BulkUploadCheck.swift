import Foundation

struct PFUploadCheckInput {
    let token: String
    let checksum: String
}

/// The bulk endpoint supplies a candidate, never proof that an original is reusable.
struct PFUploadCheckCandidate {
    let assetID: String
    let isTrashed: Bool
}

enum PFUploadCheckError: Error, LocalizedError, PFMessageProviding {
    case invalidRequest, invalidResponse, rejectedResource
    var pfMessage: PFMessage {
        M("Não foi possível validar a consulta de duplicatas. Nenhum arquivo foi considerado existente.")
    }
    var errorDescription: String? { pfMessage.text }
}

extension ImmichClient {
    /// A client-side bound, independent of any server-version-specific maximum.
    /// nil means only that an older server explicitly lacks this optional endpoint.
    func bulkUploadCheck(_ inputs: [PFUploadCheckInput], session: URLSession? = nil) async throws -> [String: PFUploadCheckCandidate]? {
        struct Entry: Encodable { let id: String; let checksum: String }
        struct Body: Encodable { let assets: [Entry] }
        struct Result: Decodable {
            let id: String
            let action: String
            let reason: String?
            let assetId: String?
            let isTrashed: Bool?
        }
        struct Response: Decodable { let results: [Result] }
        guard Set(inputs.map(\.token)).count == inputs.count,
              inputs.allSatisfy({ !$0.token.isEmpty && Self.validUploadCheckChecksum($0.checksum) }) else {
            throw PFUploadCheckError.invalidRequest
        }
        var candidates: [String: PFUploadCheckCandidate] = [:]
        for offset in stride(from: 0, to: inputs.count, by: 200) {
            try Task.checkCancellation()
            let chunk = Array(inputs[offset..<min(offset + 200, inputs.count)])
            var request = request("assets/bulk-upload-check", method: "POST")
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(Body(assets: chunk.map { Entry(id: $0.token, checksum: $0.checksum) }))
            let (data, response) = try await (session ?? transport).data(for: request)
            try Task.checkCancellation()
            if let response = response as? HTTPURLResponse, [404, 405].contains(response.statusCode) { return nil }
            try check(response)
            guard data.count <= 2_097_152, let body = try? JSONDecoder().decode(Response.self, from: data),
                  body.results.count == chunk.count,
                  Set(body.results.map(\.id)) == Set(chunk.map(\.token)) else { throw PFUploadCheckError.invalidResponse }
            for result in body.results {
                switch result.action {
                case "accept":
                    guard result.reason == nil && result.assetId == nil && result.isTrashed == nil else { throw PFUploadCheckError.invalidResponse }
                case "reject":
                    guard result.reason == "duplicate" else { throw PFUploadCheckError.rejectedResource }
                    guard let assetID = result.assetId.flatMap(UUID.init(uuidString:)), let trashed = result.isTrashed else {
                        throw PFUploadCheckError.invalidResponse
                    }
                    candidates[result.id] = PFUploadCheckCandidate(assetID: assetID.uuidString.lowercased(), isTrashed: trashed)
                default: throw PFUploadCheckError.invalidResponse
                }
            }
        }
        return candidates
    }

    /// Re-read the selected account's current asset. Bulk matches can refer to external
    /// libraries, trash, unavailable resources or Live Photo components, which are not reused.
    /// Video details do not identify reverse Live membership, so this optimization is image-only.
    func verifyUploadCandidate(_ candidate: PFUploadCheckCandidate, checksum: String, userID: String, session: URLSession? = nil) async throws -> Bool {
        struct Asset: Decodable {
            let id: String
            let ownerId: String
            let checksum: String
            let type: String
            let isTrashed: Bool
            let isOffline: Bool
            let libraryId: String?
            let livePhotoVideoId: String?
            enum CodingKeys: String, CodingKey { case id, ownerId, checksum, type, isTrashed, isOffline, libraryId, livePhotoVideoId }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id)
                ownerId = try values.decode(String.self, forKey: .ownerId)
                checksum = try values.decode(String.self, forKey: .checksum)
                type = try values.decode(String.self, forKey: .type)
                isTrashed = try values.decode(Bool.self, forKey: .isTrashed)
                isOffline = try values.decode(Bool.self, forKey: .isOffline)
                // decode Optional, rather than decodeIfPresent: absent safety fields are unknown.
                libraryId = try values.decode(String?.self, forKey: .libraryId)
                livePhotoVideoId = try values.decode(String?.self, forKey: .livePhotoVideoId)
            }
        }
        if candidate.isTrashed { throw PFUploadCheckError.rejectedResource }
        guard let assetID = UUID(uuidString: candidate.assetID),
              let expectedOwner = UUID(uuidString: userID), Self.validUploadCheckChecksum(checksum) else { return false }
        try Task.checkCancellation()
        var request = request("assets/\(assetID.uuidString.lowercased())")
        request.timeoutInterval = 10
        let (data, response) = try await (session ?? transport).data(for: request)
        try Task.checkCancellation()
        if let response = response as? HTTPURLResponse, response.statusCode == 404 { return false }
        try check(response)
        struct Availability: Decodable { let isTrashed: Bool?; let isOffline: Bool? }
        if data.count <= 2_097_152, let availability = try? JSONDecoder().decode(Availability.self, from: data),
           availability.isTrashed == true || availability.isOffline == true {
            throw PFUploadCheckError.rejectedResource
        }
        guard data.count <= 2_097_152, let asset = try? JSONDecoder().decode(Asset.self, from: data) else { return false }
        // Do not fall back to POST for an explicitly unavailable original: the server
        // could return the same duplicate ID instead of restoring or replacing it.
        if asset.isTrashed || asset.isOffline { throw PFUploadCheckError.rejectedResource }
        return UUID(uuidString: asset.id) == assetID && UUID(uuidString: asset.ownerId) == expectedOwner &&
            asset.checksum == checksum && asset.type == "IMAGE" &&
            asset.libraryId == nil && asset.livePhotoVideoId == nil
    }

    private static func validUploadCheckChecksum(_ checksum: String) -> Bool {
        guard let data = Data(base64Encoded: checksum), data.count == 20 else { return false }
        return data.base64EncodedString() == checksum
    }
}
