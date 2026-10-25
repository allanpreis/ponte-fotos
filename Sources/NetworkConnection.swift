import Foundation
import Combine
import Network

enum ConnectionMode: String, Codable, CaseIterable, Identifiable {
    case automatic, local, remote
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return L("Automático")
        case .local: return L("Local")
        case .remote: return L("Remoto")
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
    // Retained only to decode and round-trip profiles saved before availability routing.
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

    func candidates() -> [ConnectionCandidate] {
        let local = clean(localAddress), remote = clean(remoteAddress)
        switch mode {
        case .local: return local.isEmpty ? [] : [ConnectionCandidate(address: local, kind: "Local")]
        case .remote: return remote.isEmpty ? [] : [ConnectionCandidate(address: remote, kind: "Remota")]
        case .automatic:
            var result: [ConnectionCandidate] = []
            if !local.isEmpty {
                result.append(ConnectionCandidate(address: local, kind: "Local"))
            }
            let remoteBase = try? ImmichClient(address: remote, key: "compare-address-only").base
            if !remote.isEmpty, !result.contains(where: {
                (try? ImmichClient(address: $0.address, key: "compare-address-only").base) == remoteBase
            }) {
                result.append(ConnectionCandidate(address: remote, kind: "Remota"))
            }
            return result
        }
    }

    func validate() throws {
        func address(_ raw: String, name: PFMessage, required: Bool) throws {
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
                throw BridgeError(message: M("Informe uma URL \(name) válida, sem usuário, senha ou parâmetros."))
            }
            if let port = parts.port, !(1...65535).contains(port) {
                throw BridgeError(message: M("A porta da URL \(name) é inválida."))
            }
        }
        try address(localAddress, name: M("local"), required: mode == .local)
        try address(remoteAddress, name: M("remota"), required: mode == .remote)
        if mode == .automatic, clean(localAddress).isEmpty, clean(remoteAddress).isEmpty {
            throw BridgeError(message: M("Configure uma URL disponível para o modo escolhido."))
        }
    }
}

/// Only changes that can affect routing should invalidate a verified connection.
/// Gateway changes also matter when Wi-Fi, Ethernet or VPN reuse an interface.
struct NetworkRoutingSnapshot: Equatable {
    let status: NWPath.Status
    let interfaces: Set<String>
    var gateways: Set<String> = []
}

struct NetworkRoutingChanges {
    private var previous: NetworkRoutingSnapshot?

    mutating func update(_ snapshot: NetworkRoutingSnapshot?) -> Bool {
        // Wait for NWPathMonitor's first path before emitting an initial change.
        guard let snapshot, snapshot != previous else { return false }
        previous = snapshot
        return true
    }
}

@MainActor
final class NetworkObserver: ObservableObject {
    var onChange: (() -> Void)?
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "PonteFotos.network")
    private var started = false
    private var routingChanges = NetworkRoutingChanges()

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = Set(path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                .map { "\($0.type):\($0.name)" })
            let snapshot = NetworkRoutingSnapshot(status: path.status, interfaces: interfaces,
                gateways: Set(path.gateways.map { String(describing: $0) }))
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.routingChanges.update(snapshot) { self.onChange?() }
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
