import Foundation
import CryptoKit

struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct ServerVersion: Decodable {
    let major: Int
    let minor: Int
    let patch: Int
    var label: String { "Immich \(major).\(minor).\(patch)" }
}

struct ConnectionIdentity: Equatable {
    let userID: String
    let serverVersion: String
}

enum ConnectionProbeError: LocalizedError {
    case authentication
    case unavailable(String)
    case invalidServer

    var canFallback: Bool {
        if case .unavailable = self { return true }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .authentication: return "A chave não foi aceita ou não permite consultar a conta do Immich."
        case .unavailable(let reason): return "Não foi possível acessar o Immich. \(reason)"
        case .invalidServer: return "O endereço não retornou uma identidade válida de um servidor Immich 3.x."
        }
    }
}

struct ImmichClient {
    let base: URL
    let key: String
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    init(address: String, key: String) throws {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { throw BridgeError(message: "Informe a URL completa do Immich, com http:// ou https://.") }
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = "/" + (parts.path.isEmpty ? "api" : parts.path.hasSuffix("api") ? parts.path : parts.path + "/api")
        guard let url = parts.url, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BridgeError(message: "Informe sua chave de API do Immich.") }
        self.base = url; self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func request(_ path: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method; r.setValue(key, forHTTPHeaderField: "x-api-key"); r.timeoutInterval = 300
        return r
    }
    func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError(message: "Immich respondeu HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Confira URL, versão e permissões da chave.")
        }
    }
    func test() async throws -> String {
        let (data, response) = try await Self.session.data(for: request("server/version")); try check(response)
        let version: ServerVersion
        do { version = try JSONDecoder().decode(ServerVersion.self, from: data) }
        catch { throw BridgeError(message: "O endereço respondeu, mas não retornou uma versão válida do Immich. Confira a URL base do servidor.") }
        guard version.major == 3 else { throw BridgeError(message: "Esta versão inicial requer Immich 3.x. Servidor não compatível ou versão indisponível.") }
        return version.label
    }
    func probe(timeout: TimeInterval = 5) async throws -> ConnectionIdentity {
        try await probe(timeout: timeout, session: Self.session)
    }
    // Separate session permits deterministic HTTP fixtures without changing upload behavior.
    func probe(timeout: TimeInterval, session: URLSession) async throws -> ConnectionIdentity {
        func fetch(_ path: String, authenticated: Bool) async throws -> Data {
            var r = request(path)
            r.timeoutInterval = timeout.isFinite && timeout > 0 ? timeout : 5
            if !authenticated { r.setValue(nil, forHTTPHeaderField: "x-api-key") }
            let data: Data
            let response: URLResponse
            do { (data, response) = try await session.data(for: r) }
            catch let error as URLError {
                switch error.code {
                case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                     .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                     .dataNotAllowed:
                    throw ConnectionProbeError.unavailable("Verifique a rede e o endereço configurado.")
                default: throw ConnectionProbeError.invalidServer
                }
            } catch { throw ConnectionProbeError.invalidServer }
            guard let http = response as? HTTPURLResponse else { throw ConnectionProbeError.invalidServer }
            if http.statusCode == 401 || http.statusCode == 403 { throw ConnectionProbeError.authentication }
            if (500..<600).contains(http.statusCode) {
                throw ConnectionProbeError.unavailable("Servidor respondeu HTTP \(http.statusCode).")
            }
            guard (200..<300).contains(http.statusCode) else { throw ConnectionProbeError.invalidServer }
            return data
        }
        let versionData = try await fetch("server/version", authenticated: false)
        guard let version = try? JSONDecoder().decode(ServerVersion.self, from: versionData), version.major == 3,
              version.minor >= 0, version.patch >= 0 else { throw ConnectionProbeError.invalidServer }
        struct User: Decodable { let id: String }
        let userData = try await fetch("users/me", authenticated: true)
        guard let user = try? JSONDecoder().decode(User.self, from: userData), let id = UUID(uuidString: user.id) else {
            throw ConnectionProbeError.invalidServer
        }
        return ConnectionIdentity(userID: id.uuidString.lowercased(), serverVersion: version.label)
    }
    func matchesHistory(assetID: String, checksum: String, userID: String) async throws -> Bool {
        try await matchesHistory(assetID: assetID, checksum: checksum, userID: userID, session: Self.session)
    }
    func matchesHistory(assetID: String, checksum: String, userID: String, session: URLSession) async throws -> Bool {
        struct HistoryAsset: Decodable { let checksum: String; let ownerId: String }
        var r = request("assets/\(assetID)")
        r.timeoutInterval = 5
        let (data, response) = try await session.data(for: r)
        try check(response)
        let asset = try JSONDecoder().decode(HistoryAsset.self, from: data)
        return asset.checksum == checksum && asset.ownerId == userID
    }
    func info(_ id: String) async throws -> RemoteAsset {
        let (data, response) = try await Self.session.data(for: request("assets/\(id)")); try check(response)
        return try JSONDecoder().decode(RemoteAsset.self, from: data)
    }
    static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = Insecure.SHA1()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return Data(hash.finalize()).base64EncodedString()
    }
    func upload(file: URL, sidecar: URL, metadata: CaptureMetadata, liveVideoID: String?) async throws -> UploadResult {
        guard let date = metadata.date else { throw BridgeError(message: "Foto sem data na biblioteca. Revise no Fotos antes de enviar.") }
        let boundary = "Ponte-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: body.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: body) }
        let output = try FileHandle(forWritingTo: body)
        do {
            func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
            func field(_ name: String, _ value: String) throws {
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
            }
            try field("fileCreatedAt", CaptureMetadata.iso(date)); try field("fileModifiedAt", CaptureMetadata.iso(date))
            try field("isFavorite", String(metadata.favorite))
            if let liveVideoID { try field("livePhotoVideoId", liveVideoID) }
            for (name, url, mime) in [("assetData", file, "application/octet-stream"), ("sidecarData", sidecar, "application/xml")] {
                let filename = url.lastPathComponent.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n")
                let input = try FileHandle(forReadingFrom: url)
                do { while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { try output.write(contentsOf: chunk) }; try input.close() }
                catch { try? input.close(); throw error }
                try write("\r\n")
            }
            try write("--\(boundary)--\r\n"); try output.close()
        } catch { try? output.close(); throw error }
        var r = request("assets", method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.setValue(try Self.checksum(file), forHTTPHeaderField: "x-immich-checksum")
        let (data, response) = try await Self.session.upload(for: r, fromFile: body); try check(response)
        return try JSONDecoder().decode(UploadResult.self, from: data)
    }
}

struct ImmichAlbum: Decodable, Identifiable {
    let id: String
    let albumName: String
    let shared: Bool?
}
struct AlbumAddResult: Decodable {
    let id: String
    let success: Bool
    let error: String?
    static func validate(_ results: [Self], expected: [String]) throws {
        for id in expected {
            guard let result = results.first(where: { $0.id == id }), result.success || result.error == "duplicate" else {
                throw BridgeError(message: "A mídia foi enviada, mas não foi possível confirmar sua inclusão no álbum. Confira acesso de edição e tente novamente.")
            }
        }
    }
}
extension ImmichClient {
    func json(_ path: String, method: String, body: [String: Any]) async throws -> Data {
        var r = request(path, method: method)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await Self.session.data(for: r); try check(response)
        return data
    }
    func albums(timeout: TimeInterval = 300) async throws -> [ImmichAlbum] {
        var r = request("albums"); r.timeoutInterval = timeout
        let (data, response) = try await Self.session.data(for: r); try check(response)
        return try JSONDecoder().decode([ImmichAlbum].self, from: data).sorted { $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending }
    }
    func createAlbum(_ name: String) async throws -> ImmichAlbum {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw BridgeError(message: "Informe o nome do novo álbum.") }
        return try JSONDecoder().decode(ImmichAlbum.self, from: await json("albums", method: "POST", body: ["albumName": cleaned]))
    }
    func addToAlbum(_ id: String, assetIDs: [String]) async throws {
        guard !assetIDs.isEmpty else { return }
        let data = try await json("albums/\(id)/assets", method: "PUT", body: ["ids": assetIDs])
        let results = try JSONDecoder().decode([AlbumAddResult].self, from: data)
        try AlbumAddResult.validate(results, expected: assetIDs)
    }
    func applyReview(_ edit: MetadataOverride, to id: String) async throws {
        guard edit.hasChanges else { return }
        var body: [String: Any] = [:]
        if let date = edit.date { body["dateTimeOriginal"] = CaptureMetadata.iso(date) }
        if let latitude = edit.latitude, let longitude = edit.longitude { body["latitude"] = latitude; body["longitude"] = longitude }
        _ = try await json("assets/\(id)", method: "PUT", body: body)
    }
}
