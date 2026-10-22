import Foundation
import Combine
import CoreWLAN
import CoreLocation
import Network

enum ConnectionMode: String, Codable, CaseIterable, Identifiable {
    case automatic, local, remote
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automático"
        case .local: return "Local"
        case .remote: return "Remoto"
        }
    }
}

struct ConnectionCandidate: Equatable {
    let address: String
    let kind: String
}

struct ConnectionProfile: Codable, Equatable {
    var id: String = UUID().uuidString
    var localAddress: String = ""
    var remoteAddress: String = ""
    var homeSSID: String = ""
    var mode: ConnectionMode = .local

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func recognizes(address: String) -> Bool {
        guard let incoming = try? ImmichClient(address: address, key: "compare-address-only").base else { return false }
        return [localAddress, remoteAddress].contains { value in
            (try? ImmichClient(address: value, key: "compare-address-only").base) == incoming
        }
    }

    func candidates(ssid: String?) -> [ConnectionCandidate] {
        let local = clean(localAddress), remote = clean(remoteAddress)
        switch mode {
        case .local: return local.isEmpty ? [] : [ConnectionCandidate(address: local, kind: "Local")]
        case .remote: return remote.isEmpty ? [] : [ConnectionCandidate(address: remote, kind: "Remota")]
        case .automatic:
            var result: [ConnectionCandidate] = []
            let home = clean(homeSSID)
            if !home.isEmpty, ssid == home, !local.isEmpty {
                result.append(ConnectionCandidate(address: local, kind: "Local"))
            }
            if !remote.isEmpty, !result.contains(where: { $0.address == remote }) {
                result.append(ConnectionCandidate(address: remote, kind: "Remota"))
            }
            return result
        }
    }

    func validate() throws {
        func address(_ raw: String, name: String, required: Bool) throws {
            let value = clean(raw)
            if value.isEmpty && !required { return }
            guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }),
                  let parts = URLComponents(string: value),
                  let scheme = parts.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil,
                  parts.url != nil else {
                throw BridgeError(message: "Informe uma URL \(name) válida, sem usuário, senha ou parâmetros.")
            }
            if let port = parts.port, !(1...65535).contains(port) {
                throw BridgeError(message: "A porta da URL \(name) é inválida.")
            }
        }
        try address(localAddress, name: "local", required: mode == .local)
        try address(remoteAddress, name: "remota", required: mode != .local)
    }
}

@MainActor
final class NetworkObserver: NSObject, ObservableObject, CLLocationManagerDelegate, CWEventDelegate {
    @Published private(set) var ssid: String?
    @Published private(set) var locationStatus = "Permita Localização para identificar o Wi-Fi."
    var onChange: (() -> Void)?
    private let locationManager = CLLocationManager()
    private let wifiClient = CWWiFiClient()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "PonteFotos.network")
    private var started = false

    override init() {
        super.init()
        locationManager.delegate = self
        refreshSSID()
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSSID()
                self?.onChange?()
            }
        }
        wifiClient.delegate = self
        try? wifiClient.startMonitoringEvent(with: .ssidDidChange)
        monitor.start(queue: queue)
        refreshSSID()
    }

    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
        refreshSSID()
    }

    func refreshSSID() {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            ssid = wifiClient.interface()?.ssid()
            locationStatus = ssid == nil ? "Wi-Fi indisponível; será usada a conexão remota no modo automático." : "Wi-Fi identificado neste Mac."
        case .denied, .restricted:
            ssid = nil
            locationStatus = "Localização não permitida; use a conexão remota ou escolha Local manualmente."
        case .notDetermined:
            ssid = nil
            locationStatus = "Permita Localização para identificar o Wi-Fi."
        @unknown default:
            ssid = nil
            locationStatus = "Não foi possível identificar o Wi-Fi."
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.refreshSSID()
            if let self, self.started { try? self.wifiClient.startMonitoringEvent(with: .ssidDidChange) }
            self?.onChange?()
        }
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.refreshSSID()
            self?.onChange?()
        }
    }

    deinit {
        monitor.cancel()
        try? wifiClient.stopMonitoringAllEvents()
    }
}
