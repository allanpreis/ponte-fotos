import Foundation

/// A transfer owns this value for its whole batch. Resolving a transfer never changes
/// the primary connection or chooses a new destination between a Live Photo's resources.
struct PFTransferConnection {
    let profile: ConnectionProfile
    let credential: IMCredential
    let resolution: ConnectionResolution

    var profileID: String { profile.id }
    var address: String { resolution.candidate.address }
    var userID: String { resolution.identity.userID }
    var explanation: PFMessage { resolution.reason }

    static func uploadPermissions(addingToAlbum: Bool = false, creatingAlbum: Bool = false, applyingReview: Bool = false) -> Set<String> {
        var required: Set<String> = ["asset.upload", "asset.read"]
        if addingToAlbum || creatingAlbum { required.formUnion(["album.read", "albumAsset.create"]) }
        if creatingAlbum { required.insert("album.create") }
        if applyingReview { required.insert("asset.update") }
        return required
    }

    static let importPermissions: Set<String> = ["asset.read", "asset.download", "album.read"]

    static func resolve(
        profile: ConnectionProfile,
        credential: IMCredential,
        requiredPermissions: Set<String>,
        probe: (String, String) async throws -> ConnectionIdentity = {
            try await ImmichClient(address: $0, key: $1).probe()
        },
        permissions: (String, IMCredential) async throws -> Set<String> = {
            try await IMClient(address: $0, credential: $1).permissions()
        }
    ) async throws -> PFTransferConnection {
        try Task.checkCancellation()
        guard UUID(uuidString: profile.id) != nil,
              let userID = UUID(uuidString: credential.account.id)?.uuidString.lowercased(),
              !credential.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError(message: M("Selecione uma conta válida antes de transferir."))
        }
        let resolved = try await ConnectionResolver.resolve(
            profile: profile, key: credential.key, expectedUserID: userID, probe: probe
        )
        try Task.checkCancellation()
        let granted = try await permissions(resolved.candidate.address, credential)
        try Task.checkCancellation()
        let missing = requiredPermissions.subtracting(granted)
        guard granted.contains("all") || missing.isEmpty else {
            throw BridgeError(message: M("A conta selecionada não tem as permissões necessárias: \(missing.sorted().joined(separator: ", "))."))
        }
        return PFTransferConnection(profile: profile, credential: credential, resolution: resolved)
    }
}
