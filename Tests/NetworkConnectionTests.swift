import Foundation

@main struct NetworkConnectionTests {
    static func main() throws {
        var profile = ConnectionProfile(localAddress: "  http://immich.local:2283/ \n", remoteAddress: " https://photos.example.com ", homeSSID: "Casa", mode: .automatic)
        try profile.validate()
        precondition(profile.candidates(ssid: "Casa").map(\.kind) == ["Local", "Remota"])
        precondition(profile.candidates(ssid: "Casa").first?.address == "http://immich.local:2283/")
        precondition(profile.candidates(ssid: "Vizinho").map(\.kind) == ["Remota"])
        precondition(profile.candidates(ssid: nil).map(\.kind) == ["Remota"])
        precondition(profile.candidates(ssid: "casa").map(\.kind) == ["Remota"])
        profile.homeSSID = ""
        precondition(profile.candidates(ssid: "").map(\.kind) == ["Remota"])
        profile.mode = .local
        profile.remoteAddress = ""
        try profile.validate()
        precondition(profile.candidates(ssid: nil).map(\.kind) == ["Local"])
        profile.mode = .remote
        expectInvalid(profile)
        profile.remoteAddress = "http://photos.example.com:2283"
        try profile.validate()
        for invalid in ["ftp://photos.example.com", "https://", "https://user:secret@photos.example.com", "https://photos.example.com?key=secret", "https://photos.example.com/#fragment", "https://photos.example.com:70000", "https://photos example.com"] {
            profile.remoteAddress = invalid
            expectInvalid(profile)
        }
        profile.remoteAddress = "https://photos.example.com"
        try profile.validate()
        precondition(profile.candidates(ssid: "Casa").map(\.kind) == ["Remota"])
        let restored = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
        precondition(restored == profile)
        profile.mode = .automatic
        profile.localAddress = ""
        try profile.validate()
        precondition(profile.candidates(ssid: "Casa").map(\.kind) == ["Remota"])
        print("NetworkConnectionTests: políticas local/remota/automática, SSID desconhecido, URLs e persistência passaram.")
    }

    static func expectInvalid(_ profile: ConnectionProfile) {
        do { try profile.validate(); fatalError("URL inválida foi aceita") }
        catch is BridgeError { }
        catch { fatalError("Erro inesperado: \(error)") }
    }
}
