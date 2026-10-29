import Foundation
import CryptoKit

struct BridgeError: LocalizedError, PFMessageProviding {
    let pfMessage: PFMessage
    init(message: PFMessage) { pfMessage = message }
    init(message: String) { pfMessage = .verbatim(message) }
    var message: String { pfMessage.text }
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

enum ConnectionProbeError: LocalizedError, PFMessageProviding {
    case authentication
    case unavailable(PFMessage)
    case invalidServer
    static func unavailable(_ reason: String) -> Self { .unavailable(.verbatim(reason)) }

    var canFallback: Bool {
        if case .unavailable = self { return true }
        return false
    }
    var errorDescription: String? { pfMessage.text }
    var pfMessage: PFMessage {
        switch self {
        case .authentication: return M("A chave não foi aceita ou não permite consultar a conta do Immich.")
        case .unavailable(let reason): return M("Não foi possível acessar o Immich. \(reason)")
        case .invalidServer: return M("O endereço não retornou uma identidade válida de um servidor Immich 3.x.")
        }
    }
}

struct ImmichClient {
    let base: URL
    let key: String
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    let transport: URLSession
    init(address: String, key: String, session: URLSession? = nil) throws {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { throw BridgeError(message: M("Informe a URL completa do Immich, com http:// ou https://.")) }
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = "/" + (parts.path.isEmpty ? "api" : parts.path.hasSuffix("api") ? parts.path : parts.path + "/api")
        guard let url = parts.url, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BridgeError(message: M("Informe sua chave de API do Immich.")) }
        self.base = url; self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = session ?? Self.session
    }
    func request(_ path: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method; r.setValue(key, forHTTPHeaderField: "x-api-key"); r.timeoutInterval = 300
        return r
    }
    func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError(message: M("Immich respondeu HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Confira URL, versão e permissões da chave."))
        }
    }
    func test() async throws -> String {
        let (data, response) = try await transport.data(for: request("server/version")); try check(response)
        let version: ServerVersion
        do { version = try JSONDecoder().decode(ServerVersion.self, from: data) }
        catch { throw BridgeError(message: M("O endereço respondeu, mas não retornou uma versão válida do Immich. Confira a URL base do servidor.")) }
        guard version.major == 3 else { throw BridgeError(message: M("Esta versão inicial requer Immich 3.x. Servidor não compatível ou versão indisponível.")) }
        return version.label
    }
    func probe(timeout: TimeInterval = 5) async throws -> ConnectionIdentity {
        try await probe(timeout: timeout, session: transport)
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
                    throw ConnectionProbeError.unavailable(M("Verifique a rede e o endereço configurado."))
                default: throw ConnectionProbeError.invalidServer
                }
            } catch { throw ConnectionProbeError.invalidServer }
            guard let http = response as? HTTPURLResponse else { throw ConnectionProbeError.invalidServer }
            if http.statusCode == 401 || http.statusCode == 403 { throw ConnectionProbeError.authentication }
            if (500..<600).contains(http.statusCode) {
                throw ConnectionProbeError.unavailable(M("Servidor respondeu HTTP \(http.statusCode)."))
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
    func matchesHistory(assetID: String, checksum: String, userID: String, liveVideoID: String? = nil) async throws -> Bool {
        try await matchesHistory(assetID: assetID, checksum: checksum, userID: userID, session: transport, liveVideoID: liveVideoID)
    }
    func matchesHistory(assetID: String, checksum: String, userID: String, session: URLSession, liveVideoID: String? = nil) async throws -> Bool {
        struct HistoryAsset: Decodable { let checksum: String; let ownerId: String; let isTrashed: Bool; let isOffline: Bool; let livePhotoVideoId: String? }
        var r = request("assets/\(assetID)")
        r.timeoutInterval = 5
        let (data, response) = try await session.data(for: r)
        if let response = response as? HTTPURLResponse, response.statusCode == 404 { return false }
        try check(response)
        let asset = try JSONDecoder().decode(HistoryAsset.self, from: data)
        guard !asset.isTrashed && !asset.isOffline else {
            throw BridgeError(message: M("O arquivo existente está na lixeira ou indisponível no Immich. Revise antes de continuar."))
        }
        if let liveVideoID, asset.livePhotoVideoId != liveVideoID {
            throw BridgeError(message: M("O arquivo existente não comprova o vínculo Live Photo esperado. Revise o par no Immich antes de continuar."))
        }
        return asset.checksum == checksum && asset.ownerId == userID
    }
    func info(_ id: String) async throws -> RemoteAsset {
        let (data, response) = try await transport.data(for: request("assets/\(id)")); try check(response)
        return try JSONDecoder().decode(RemoteAsset.self, from: data)
    }
    static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = Insecure.SHA1()
        // Drain Foundation's temporary read buffers per chunk, including for large originals.
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return Data(hash.finalize()).base64EncodedString()
    }
    func upload(file: URL, sidecar: URL, metadata: CaptureMetadata, liveVideoID: String?, checksum: String? = nil, isLiveMotion: Bool = false) async throws -> UploadResult {
        let prepared = try await PFUploadFileIO.prepare(file: file, sidecar: sidecar, metadata: metadata,
                                                       liveVideoID: liveVideoID, checksum: checksum, isLiveMotion: isLiveMotion)
        defer { try? FileManager.default.removeItem(at: prepared.body) }
        try Task.checkCancellation()
        var r = request("assets", method: "POST")
        r.setValue("multipart/form-data; boundary=\(prepared.boundary)", forHTTPHeaderField: "Content-Type")
        r.setValue(prepared.checksum, forHTTPHeaderField: "x-immich-checksum")
        let (data, response) = try await transport.upload(for: r, fromFile: prepared.body); try check(response)
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
                throw BridgeError(message: M("A mídia foi enviada, mas não foi possível confirmar sua inclusão no álbum. Confira acesso de edição e tente novamente."))
            }
        }
    }
}
extension ImmichClient {
    func json(_ path: String, method: String, body: [String: Any]) async throws -> Data {
        var r = request(path, method: method)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.data(for: r); try check(response)
        return data
    }
    func albums(timeout: TimeInterval = 300) async throws -> [ImmichAlbum] {
        var r = request("albums"); r.timeoutInterval = timeout
        let (data, response) = try await transport.data(for: r); try check(response)
        return try JSONDecoder().decode([ImmichAlbum].self, from: data).sorted { $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending }
    }
    func createAlbum(_ name: String) async throws -> ImmichAlbum {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw BridgeError(message: M("Informe o nome do novo álbum.")) }
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


/// Bounded, cancellable disk work shared by uploads and staging. No credentials enter this helper.
enum PFUploadFileIO {
    static let reserveBytes: Int64 = 64 * 1024 * 1024
    struct Prepared {
        let body: URL
        let boundary: String
        let checksum: String
    }
    /// Nil means the filesystem did not report capacity; callers must still handle write errors.
    static func availableCapacity(at directory: URL) -> Int64? {
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        // Prefer immediately free bytes; purgeable/important capacity is only a fallback.
        return values.volumeAvailableCapacity.map(Int64.init) ?? values.volumeAvailableCapacityForImportantUsage
    }
    static func size(of file: URL) throws -> Int64 {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 0 else {
            throw BridgeError(message: M("O tamanho dos arquivos excede o limite suportado."))
        }
        return Int64(size)
    }
    /// Returns false for unknown capacity, never representing an estimate as a guarantee.
    @discardableResult static func checkCapacity(fileSizes: [Int64], overhead: Int64 = 0, availableBytes: Int64?) throws -> Bool {
        var required = reserveBytes
        for size in fileSizes + [overhead] {
            let sum = required.addingReportingOverflow(size)
            guard size >= 0, !sum.overflow else { throw BridgeError(message: M("O tamanho dos arquivos excede o limite suportado.")) }
            required = sum.partialValue
        }
        guard let availableBytes else { return false }
        guard availableBytes >= required else { throw BridgeError(message: M("Espaço livre insuficiente para preparar este arquivo. Libere espaço e tente novamente.")) }
        return true
    }
    static func validatedChecksum(_ checksum: String) throws -> String {
        guard let bytes = Data(base64Encoded: checksum), bytes.count == 20, bytes.base64EncodedString() == checksum else {
            throw BridgeError(message: M("Checksum SHA-1 inválido."))
        }
        return checksum
    }
    static func prepare(file: URL, sidecar: URL, metadata: CaptureMetadata, liveVideoID: String?, checksum: String? = nil, isLiveMotion: Bool = false,
                        directory: URL = FileManager.default.temporaryDirectory,
                        hash: @escaping @Sendable (URL) throws -> String = { try ImmichClient.checksum($0) }) async throws -> Prepared {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let date = metadata.date else { throw BridgeError(message: M("Foto sem data na biblioteca. Revise no Fotos antes de enviar.")) }
            let digest = try validatedChecksum(checksum ?? hash(file))
            let boundary = "Ponte-\(UUID().uuidString)"
            let fields = [("fileCreatedAt", CaptureMetadata.iso(date)), ("fileModifiedAt", CaptureMetadata.iso(date)),
                          ("isFavorite", String(metadata.favorite))] + (isLiveMotion ? [("visibility", "hidden")] : []) + (liveVideoID.map { [("livePhotoVideoId", $0)] } ?? [])
            let parts = [("assetData", file, "application/octet-stream"), ("sidecarData", sidecar, "application/xml")]
            func field(_ name: String, _ value: String) -> Data {
                Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
            }
            func header(_ name: String, _ url: URL, _ mime: String) -> Data {
                let filename = url.lastPathComponent.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
                return Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
            }
            let closing = Data("--\(boundary)--\r\n".utf8)
            let fieldData = fields.map { field($0.0, $0.1) }
            let headers = parts.map { header($0.0, $0.1, $0.2) }
            let overhead = Int64(fieldData.reduce(0) { $0 + $1.count } + headers.reduce(0) { $0 + $1.count } + parts.count * 2 + closing.count)
            try checkCapacity(fileSizes: try parts.map { try size(of: $0.1) }, overhead: overhead, availableBytes: availableCapacity(at: directory))
            try Task.checkCancellation()
            let body = directory.appendingPathComponent("ponte-upload-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: body.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            var completed = false
            defer { if !completed { try? FileManager.default.removeItem(at: body) } }
            let output = try FileHandle(forWritingTo: body)
            defer { try? output.close() }
            for data in fieldData { try Task.checkCancellation(); try output.write(contentsOf: data) }
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                try output.write(contentsOf: headers[index])
                let input = try FileHandle(forReadingFrom: part.1)
                do {
                    while try autoreleasepool(invoking: {
                        try Task.checkCancellation()
                        guard let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
                        try output.write(contentsOf: chunk)
                        return true
                    }) {}
                    try input.close()
                } catch { try? input.close(); throw error }
                try output.write(contentsOf: Data("\r\n".utf8))
            }
            try output.write(contentsOf: closing)
            try Task.checkCancellation()
            try output.close()
            completed = true
            return Prepared(body: body, boundary: boundary, checksum: digest)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
