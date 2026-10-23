import Foundation
import Network

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
        routingNotifications()
        print("NetworkConnectionTests: políticas, URLs, persistência e deduplicação de notificações de rede passaram.")
    }

    static func routingNotifications() {
        var changes = NetworkRoutingChanges()
        var notifications: [NetworkRoutingSnapshot] = []
        func receive(_ snapshot: NetworkRoutingSnapshot?) {
            if changes.update(snapshot), let snapshot { notifications.append(snapshot) }
        }
        let home = NetworkRoutingSnapshot(status: .satisfied, interfaces: ["wifi:en0"], ssid: "Casa")

        // Authorization can arrive before NWPathMonitor has delivered a path.
        receive(nil)
        precondition(notifications.isEmpty)
        receive(home)
        precondition(notifications == [home], "The initial known path must emit once.")
        for _ in 0..<20 { receive(home) }
        precondition(notifications == [home], "Repeated path/auth/SSID callbacks must not restart a connection.")

        let lost = NetworkRoutingSnapshot(status: .unsatisfied, interfaces: [], ssid: nil)
        receive(lost); receive(lost)
        precondition(notifications == [home, lost], "A real network loss must emit once.")
        receive(home)
        precondition(notifications == [home, lost, home], "Restoring the same Wi-Fi must still emit.")

        let away = NetworkRoutingSnapshot(status: .satisfied, interfaces: ["wifi:en0"], ssid: "Outra rede")
        receive(away); receive(away)
        precondition(notifications.last == away && notifications.count == 4)
        let unidentified = NetworkRoutingSnapshot(status: .satisfied, interfaces: ["wifi:en0"], ssid: nil)
        receive(unidentified); receive(unidentified)
        precondition(notifications.last == unidentified && notifications.count == 5)
        receive(away)
        precondition(notifications.last == away && notifications.count == 6, "Newly authorized SSID identification changes routing.")

        let ethernet = NetworkRoutingSnapshot(status: .satisfied, interfaces: ["wiredEthernet:en4"], ssid: "Outra rede")
        receive(ethernet)
        precondition(notifications.last == ethernet && notifications.count == 7)
        let otherEthernet = NetworkRoutingSnapshot(status: .satisfied, interfaces: ["wiredEthernet:en5"], ssid: "Outra rede")
        receive(otherEthernet)
        precondition(notifications.last == otherEthernet && notifications.count == 8, "Changing interfaces of the same type must emit.")

        let both = NetworkRoutingSnapshot(status: .satisfied, interfaces: ["wifi:en0", "wiredEthernet:en5"], ssid: "Outra rede")
        receive(both)
        receive(NetworkRoutingSnapshot(status: .satisfied, interfaces: ["wiredEthernet:en5", "wifi:en0"], ssid: "Outra rede"))
        precondition(notifications.last == both && notifications.count == 9, "Interface order must not cause a reconnect.")
        let requiresConnection = NetworkRoutingSnapshot(status: .requiresConnection, interfaces: both.interfaces, ssid: both.ssid)
        receive(requiresConnection); receive(requiresConnection)
        precondition(notifications.last == requiresConnection && notifications.count == 10)
        receive(both)
        precondition(notifications.last == both && notifications.count == 11)
    }

    static func expectInvalid(_ profile: ConnectionProfile) {
        do { try profile.validate(); fatalError("URL inválida foi aceita") }
        catch is BridgeError { }
        catch { fatalError("Erro inesperado: \(error)") }
    }
}
