import Foundation

struct ConnectionResolution {
    let candidate: ConnectionCandidate
    let identity: ConnectionIdentity
}

enum ConnectionResolver {
    static func resolve(
        profile: ConnectionProfile,
        ssid: String?,
        key: String,
        expectedUserID: String?,
        probe: (String, String) async throws -> ConnectionIdentity = {
            try await ImmichClient(address: $0, key: $1).probe()
        }
    ) async throws -> ConnectionResolution {
        try profile.validate()
        let candidates = profile.candidates(ssid: ssid)
        guard !candidates.isEmpty else {
            throw BridgeError(message: M("Configure uma URL disponível para o modo escolhido."))
        }
        var lastUnavailable: ConnectionProbeError?
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                let identity = try await probe(candidate.address, key)
                try Task.checkCancellation()
                if let expectedUserID, expectedUserID != identity.userID {
                    throw BridgeError(message: M("Este endereço respondeu com outra conta ou servidor. A troca foi bloqueada. Confira as URLs e a chave."))
                }
                return ConnectionResolution(candidate: candidate, identity: identity)
            } catch let error as ConnectionProbeError {
                guard error.canFallback else {
                    throw BridgeError(message: PFMessage.error(error))
                }
                lastUnavailable = error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BridgeError {
                throw error
            } catch {
                throw BridgeError(message: PFMessage.error(error))
            }
        }
        throw BridgeError(message: lastUnavailable.map(PFMessage.error) ?? M("Nenhum endereço respondeu."))
    }
}
