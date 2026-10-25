import Foundation

struct ConnectionResolution {
    let candidate: ConnectionCandidate
    let identity: ConnectionIdentity
    let reason: PFMessage
}

enum ConnectionResolver {
    static func resolve(
        profile: ConnectionProfile,
        key: String,
        expectedUserID: String?,
        probe: (String, String) async throws -> ConnectionIdentity = {
            try await ImmichClient(address: $0, key: $1).probe()
        }
    ) async throws -> ConnectionResolution {
        try profile.validate()
        let candidates = profile.candidates()
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
                let reason: PFMessage
                if profile.mode == .local { reason = M("Modo Local: somente a URL local.") }
                else if profile.mode == .remote { reason = M("Modo Remoto: somente a URL remota.") }
                else if let lastUnavailable {
                    reason = M("URL local indisponível; URL remota validada. \(PFMessage.error(lastUnavailable))")
                } else if candidate.kind == "Local" { reason = M("URL local disponível e identidade validada.") }
                else { reason = M("URL local não configurada; URL remota validada.") }
                return ConnectionResolution(candidate: candidate, identity: identity, reason: reason)
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
