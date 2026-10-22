import Foundation

@main struct ConnectionResolverTests {
    static let identity = ConnectionIdentity(userID: "same-user", serverVersion: "Immich 3.3.0")
    static let profile = ConnectionProfile(localAddress: "http://immich.local:2283", remoteAddress: "http://photos.example.com:2283", homeSSID: "MinhaRedeDeTeste", mode: .automatic)

    static func main() async throws {
        var calls: [String] = []
        let local = try await ConnectionResolver.resolve(profile: profile, ssid: "MinhaRedeDeTeste", key: "test-key", expectedUserID: "same-user") { address, key in
            precondition(key == "test-key")
            calls.append(address)
            return identity
        }
        precondition(local.candidate.kind == "Local" && local.identity == identity)
        precondition(calls == [profile.localAddress])

        for reason in ["Tempo esgotado.", "Servidor respondeu HTTP 503."] {
            calls = []
            let remote = try await ConnectionResolver.resolve(profile: profile, ssid: "MinhaRedeDeTeste", key: "test-key", expectedUserID: "same-user") { address, _ in
                calls.append(address)
                if address == profile.localAddress { throw ConnectionProbeError.unavailable(reason) }
                return identity
            }
            precondition(remote.candidate.kind == "Remota")
            precondition(calls == [profile.localAddress, profile.remoteAddress])
        }

        for error in [ConnectionProbeError.authentication, .invalidServer] {
            calls = []
            await expectBlocked {
                _ = try await ConnectionResolver.resolve(profile: profile, ssid: "MinhaRedeDeTeste", key: "test-key", expectedUserID: nil) { address, _ in
                    calls.append(address)
                    throw error
                }
            }
            precondition(calls == [profile.localAddress])
        }
        calls = []
        await expectBlocked {
            _ = try await ConnectionResolver.resolve(profile: profile, ssid: "MinhaRedeDeTeste", key: "test-key", expectedUserID: "other-user") { address, _ in
                calls.append(address)
                return identity
            }
        }
        precondition(calls == [profile.localAddress])

        for ssid: String? in [nil, "Another Wi-Fi"] {
            calls = []
            let remote = try await ConnectionResolver.resolve(profile: profile, ssid: ssid, key: "test-key", expectedUserID: nil) { address, _ in
                calls.append(address)
                return identity
            }
            precondition(remote.candidate.kind == "Remota" && calls == [profile.remoteAddress])
        }
        calls = []
        await expectBlocked {
            _ = try await ConnectionResolver.resolve(profile: ConnectionProfile(), ssid: nil, key: "test-key", expectedUserID: nil) { address, _ in
                calls.append(address)
                return identity
            }
        }
        precondition(calls.isEmpty)
        calls = []
        await expectBlocked {
            _ = try await ConnectionResolver.resolve(profile: profile, ssid: "MinhaRedeDeTeste", key: "test-key", expectedUserID: nil) { address, _ in
                calls.append(address)
                throw ConnectionProbeError.unavailable("Sem acesso.")
            }
        }
        precondition(calls == [profile.localAddress, profile.remoteAddress])
        calls = []
        await expectBlocked {
            _ = try await ConnectionResolver.resolve(profile: profile, ssid: "MinhaRedeDeTeste", key: "test-key", expectedUserID: nil) { address, _ in
                calls.append(address)
                throw URLError(.timedOut)
            }
        }
        precondition(calls == [profile.localAddress])
        print("ConnectionResolverTests: 11 cenários passaram; fallback apenas para indisponibilidade tipada, identidade e autenticação protegidas.")
    }

    static func expectBlocked(_ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("Conexão insegura aceita") }
        catch is BridgeError { }
        catch { fatalError("Erro inesperado: \(error)") }
    }
}
