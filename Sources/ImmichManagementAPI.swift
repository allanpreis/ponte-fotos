import Foundation
import Security

struct IMAccount: Codable, Identifiable, Equatable { var id: String; var name: String }
struct IMCredential { let account: IMAccount; let key: String }
struct IMAlbum: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var ownerID: String
    var shared: Bool
    var count: Int
    var readerIDs: [String]
    var writerIDs: [String]
    init(id: String, name: String, ownerID: String, shared: Bool = false, count: Int = 0, readerIDs: [String] = [], writerIDs: [String] = []) {
        self.id = id; self.name = name; self.ownerID = ownerID; self.shared = shared; self.count = count; self.readerIDs = readerIDs; self.writerIDs = writerIDs
    }
}
struct IMAsset: Codable, Identifiable {
    var id: String; var ownerId: String; var originalFileName: String; var checksum: String; var type: String
    var ownerName: String?
    var createdAt = ""; var fileCreatedAt = ""; var localDateTime: String?
    var livePhotoVideoId: String?; var isEdited = false; var isOffline = false; var isTrashed = false
    var stacked = false; var isFavorite = false; var width: Int?; var height: Int?; var fileSize: Int64?
    var people: [String] = []; var albums: [IMAlbum] = []
    var isLive: Bool { type == "IMAGE" && livePhotoVideoId != nil }
    func eligible(allowLive: Bool) -> Bool {
        ["IMAGE", "VIDEO"].contains(type) && !isEdited && !isOffline && !isTrashed && !stacked && !checksum.isEmpty && (livePhotoVideoId == nil || (allowLive && type == "IMAGE"))
    }
    init(id: String, ownerId: String, originalFileName: String, checksum: String, type: String = "IMAGE") {
        self.id = id; self.ownerId = ownerId; self.originalFileName = originalFileName; self.checksum = checksum; self.type = type
    }
}
struct IMPerson: Codable, Identifiable {
    var id: String; var name: String; var birthDate: String?; var accountID: String
    var key: String { accountID + ":" + id }
}
struct IMActionRecord: Codable, Identifiable {
    var id = UUID().uuidString
    var action: String; var assetID: String; var name: String; var ownerID: String
    var keepID: String?; var albumID: String?; var albumName: String?; var status: String; var message: String?
    init(action: String, asset: IMAsset, keepID: String? = nil, album: IMAlbum? = nil, status: String, message: String? = nil) {
        self.action = action; self.assetID = asset.id; self.name = asset.originalFileName; self.ownerID = asset.ownerId
        self.keepID = keepID; self.albumID = album?.id; self.albumName = album?.name; self.status = status; self.message = message
    }
}
typealias IMProgress = (String, Int, Int) -> Void
typealias IMReport = (IMActionRecord) throws -> Void
struct IMHistoryEntry: Codable, Identifiable {
    var id = UUID().uuidString; var date = Date(); var title: String; var kind: String
    var status = "running"; var records: [IMActionRecord] = []; var assets: [IMAsset]
    init(title: String, kind: String, assets: [IMAsset]) { self.title = title; self.kind = kind; self.assets = assets }
}

// API-only DTOs. Persisted snapshots above contain no API keys.
private struct IMRawAlbum: Decodable {
    let id: String; let albumName: String; let ownerId: String?; let shared: Bool?; let assetCount: Int?
    struct User: Decodable { let id: String? }
    let owner: User?
    struct Member: Decodable { let user: User?; let role: String? }
    let albumUsers: [Member]?
    func annotated(_ reader: String, owned: Bool) -> IMAlbum {
        let owner = ownerId ?? self.owner?.id ?? (owned ? reader : "")
        let canWrite = owned || owner == reader || albumUsers?.contains(where: { $0.user?.id == reader && ["owner", "editor"].contains($0.role ?? "") }) == true
        return IMAlbum(id: id, name: albumName, ownerID: owner, shared: shared ?? false, count: assetCount ?? 0, readerIDs: [reader], writerIDs: canWrite ? [reader] : [])
    }
}
private struct IMRawAsset: Decodable {
    let id: String; let ownerId: String; let originalFileName: String; let checksum: String?; let type: String
    struct Owner: Decodable { let name: String? }
    let owner: Owner?
    let fileSize: Int64?; let fileSizeInByte: Int64?
    let createdAt: String?; let fileCreatedAt: String?; let localDateTime: String?; let livePhotoVideoId: String?
    let isEdited: Bool?; let isOffline: Bool?; let isTrashed: Bool?; let isFavorite: Bool?; let width: Int?; let height: Int?
    struct Stack: Decodable { let id: String? }
    struct Exif: Decodable { let exifImageWidth: Int?; let exifImageHeight: Int?; let fileSizeInByte: Int64? }
    struct Person: Decodable { let id: String }
    let stack: Stack?; let exifInfo: Exif?; let people: [Person]?
    var asset: IMAsset {
        var value = IMAsset(id: id, ownerId: ownerId, originalFileName: originalFileName, checksum: checksum ?? "", type: type)
        value.ownerName = owner?.name
        value.createdAt = createdAt ?? ""; value.fileCreatedAt = fileCreatedAt ?? ""; value.localDateTime = localDateTime
        value.livePhotoVideoId = livePhotoVideoId; value.isEdited = isEdited ?? false; value.isOffline = isOffline ?? false
        value.isTrashed = isTrashed ?? false; value.stacked = stack != nil; value.isFavorite = isFavorite ?? false
        value.width = width ?? exifInfo?.exifImageWidth; value.height = height ?? exifInfo?.exifImageHeight
        value.fileSize = exifInfo?.fileSizeInByte ?? fileSizeInByte ?? fileSize; value.people = people?.map(\.id) ?? []
        return value
    }
}
private struct IMRawPerson: Decodable {
    let id: String; let name: String?; let birthDate: String?
    func annotated(_ account: String) -> IMPerson { IMPerson(id: id, name: name?.isEmpty == false ? name! : L("Pessoa sem nome"), birthDate: birthDate, accountID: account) }
}

private struct IMAccessError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct IMClient {
    let credential: IMCredential
    let address: String
    let session: URLSession
    private static let standardSession = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    init(address: String, credential: IMCredential, session: URLSession? = nil) {
        self.address = address; self.credential = credential; self.session = session ?? Self.standardSession
    }
    func data(_ endpoint: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        try Task.checkCancellation()
        let base = try ImmichClient(address: address, key: credential.key).base
        var parts = URLComponents(url: base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw BridgeError(message: L("Endereço da API inválido.")) }
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 20
        r.setValue(credential.key, forHTTPHeaderField: "x-api-key"); r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: r) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw BridgeError(message: L("A consulta ao Immich não foi confirmada. Confira a rede e o histórico antes de repetir uma operação."))
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw BridgeError(message: L("Resposta inválida do Immich.")) }
        guard (200..<300).contains(http.statusCode) else {
            let message: String
            switch http.statusCode {
            case 401: message = L("Chave rejeitada pelo Immich. Reconecte a conta.")
            case 403: message = L("Permissão insuficiente na conta \(credential.account.name). Confira os escopos e o acesso ao álbum.")
            case 404: message = L("Álbum ou arquivo indisponível. Faça uma nova consulta.")
            default: message = L("O Immich respondeu HTTP \(http.statusCode). Confira o histórico antes de repetir.")
            }
            if [401, 403, 404].contains(http.statusCode) { throw IMAccessError(message: message) }
            throw BridgeError(message: message)
        }
        guard data.count <= 32 * 1024 * 1024 else { throw BridgeError(message: L("Resposta maior que o limite da consulta.")) }
        return data
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw BridgeError(message: L("Resposta do Immich incompatível. Atualize a análise antes de continuar.")) }
    }
    func asset(_ id: String) async throws -> IMAsset { try decode(IMRawAsset.self, await data("assets/" + id)).asset }
    func thumbnail(_ id: String) async throws -> Data { try await data("assets/" + id + "/thumbnail", query: [URLQueryItem(name: "size", value: "thumbnail")]) }
    func albums(assetID: String? = nil) async throws -> [IMAlbum] {
        let query = assetID.map { [URLQueryItem(name: "assetId", value: $0)] } ?? []
        let all = try decode([IMRawAlbum].self, await data("albums", query: query))
        let owned = Set(try decode([IMRawAlbum].self, await data("albums", query: query + [URLQueryItem(name: "isOwned", value: "true")])).map(\.id))
        return all.map { $0.annotated(credential.account.id, owned: owned.contains($0.id)) }
    }
    func albumIDs(_ albumID: String) async throws -> Set<String> {
        struct Bucket: Decodable { let timeBucket: String }
        struct Items: Decodable { let id: [String] }
        let query = [URLQueryItem(name: "albumId", value: albumID), URLQueryItem(name: "isTrashed", value: "false"), URLQueryItem(name: "withStacked", value: "false")]
        let buckets = try decode([Bucket].self, await data("timeline/buckets", query: query))
        var ids = Set<String>()
        for bucket in buckets {
            try Task.checkCancellation()
            let items = try decode(Items.self, await data("timeline/bucket", query: query + [URLQueryItem(name: "timeBucket", value: bucket.timeBucket)]))
            ids.formUnion(items.id)
            guard ids.count <= 30000 else { throw BridgeError(message: L("Limite de 30 mil itens por consulta. Escolha menos álbuns.")) }
        }
        return ids
    }
    func people() async throws -> [IMPerson] {
        struct Page: Decodable { let people: [IMRawPerson]; let hasNextPage: Bool?; let total: Int? }
        var page = 1; var result: [IMPerson] = []; var seen = Set<String>()
        while page <= 100 {
            let response = try decode(Page.self, await data("people", query: [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "size", value: "500"), URLQueryItem(name: "withHidden", value: "true")]))
            var added = 0
            for person in response.people where seen.insert(person.id).inserted { result.append(person.annotated(credential.account.id)); added += 1 }
            if response.hasNextPage == false || response.people.isEmpty || (response.hasNextPage == nil && result.count >= (response.total ?? Int.max)) { return result }
            guard added > 0 else { throw BridgeError(message: L("A lista de pessoas repetiu uma página.")) }
            page += 1
        }
        throw BridgeError(message: L("Limite de páginas de pessoas atingido."))
    }
    func person(_ id: String) async throws -> IMPerson { try decode(IMRawPerson.self, await data("people/" + id)).annotated(credential.account.id) }
    func search(personID: String, albumID: String?) async throws -> [IMAsset] { try await search(personID: personID, albumIDs: albumID.map { [$0] } ?? []) }
    func search(personID: String, albumIDs: [String]) async throws -> [IMAsset] {
        struct Search: Decodable { struct Assets: Decodable { let items: [IMRawAsset]; let nextCursor: String? }; let assets: Assets }
        var filter: [String: Any] = ["personIds": ["any": [personID]], "trashedAt": ["eq": NSNull()]]
        if !albumIDs.isEmpty { filter["albumIds"] = ["any": albumIDs] }
        var cursor: String?; var seen = Set<String>(); var result: [String: IMAsset] = [:]
        repeat {
            var body: [String: Any] = ["filter": filter, "size": 250, "withExif": true, "withPeople": true, "withStacked": true]
            if let cursor { body["cursor"] = cursor }
            let response = try decode(Search.self, await data("search/metadata", method: "POST", body: body))
            for raw in response.assets.items { result[raw.id] = raw.asset }
            guard result.count <= 30000 else { throw BridgeError(message: L("Limite de 30 mil arquivos por busca.")) }
            cursor = response.assets.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw BridgeError(message: L("A busca repetiu a página. Faça nova consulta.")) }
        } while cursor != nil
        return Array(result.values).sorted { $0.id < $1.id }
    }
    func matchesPerson(personID: String, assetID: String, albumIDs: [String]) async throws -> Bool {
        struct Search: Decodable { struct Assets: Decodable { struct Item: Decodable { let id: String }; let items: [Item] }; let assets: Assets }
        var filter: [String: Any] = ["id": ["eq": assetID], "personIds": ["any": [personID]], "trashedAt": ["eq": NSNull()]]
        if !albumIDs.isEmpty { filter["albumIds"] = ["any": albumIDs] }
        let response = try decode(Search.self, await data("search/metadata", method: "POST", body: ["filter": filter, "size": 1]))
        return response.assets.items.contains { $0.id == assetID }
    }
    private func albumMutation(_ ids: [String], albumID: String, method: String) async throws {
        struct Result: Decodable { let id: String; let success: Bool; let error: String? }
        let response = try decode([Result].self, await data("albums/" + albumID + "/assets", method: method, body: ["ids": ids]))
        for id in ids {
            guard response.contains(where: { $0.id == id && ($0.success || (method == "PUT" && $0.error == "duplicate")) }) else { throw BridgeError(message: L("O Immich não confirmou a alteração de um vínculo. Confira o histórico e as permissões.")) }
        }
    }
    func add(_ ids: [String], to albumID: String) async throws { try await albumMutation(ids, albumID: albumID, method: "PUT") }
    func unlink(_ ids: [String], from albumID: String) async throws { try await albumMutation(ids, albumID: albumID, method: "DELETE") }
    func trash(_ ids: [String]) async throws { _ = try await data("assets", method: "DELETE", body: ["ids": ids, "force": false]) }
    func permissions() async throws -> Set<String> {
        struct Info: Decodable { let permissions: [String] }
        return Set(try decode(Info.self, await data("api-keys/me")).permissions)
    }
}

struct IMSession {
    let address: String; let profileID: String; let clients: [IMClient]
    init(address: String, profileID: String, credentials: [IMCredential], session: URLSession? = nil) {
        self.address = address; self.profileID = profileID
        self.clients = credentials.map { IMClient(address: address, credential: $0, session: session) }
    }
    func owner(_ ownerID: String) throws -> IMClient {
        guard let client = clients.first(where: { $0.credential.account.id == ownerID }) else { throw BridgeError(message: L("Conecte a conta proprietária de todas as cópias selecionadas antes de continuar.")) }
        return client
    }
    func reader(_ album: IMAlbum) throws -> IMClient {
        guard let client = clients.first(where: { album.readerIDs.contains($0.credential.account.id) || album.ownerID == $0.credential.account.id }) else { throw BridgeError(message: L("Nenhuma conta conectada tem acesso ao álbum \(album.name).")) }
        return client
    }
    func writer(_ album: IMAlbum, requiring permissions: Set<String>, adding assets: [IMAsset]) async throws -> IMClient {
        let candidates = clients.filter { $0.credential.account.id == album.ownerID } + clients.filter {
            $0.credential.account.id != album.ownerID && album.writerIDs.contains($0.credential.account.id)
        }
        for client in candidates {
            try Task.checkCancellation()
            do {
                let granted = try await client.permissions()
                guard granted.contains("all") || permissions.isSubset(of: granted) else { continue }
                // An editor must also be able to see every asset being added.
                // Validate all candidates before any album mutation starts.
                for snapshot in assets {
                    let current = try await client.asset(snapshot.id)
                    guard current.id == snapshot.id, current.ownerId == snapshot.ownerId, current.checksum == snapshot.checksum, current.type == snapshot.type else {
                        throw BridgeError(message: L("Conteúdo ou proprietário da foto mudou; consulte novamente."))
                    }
                }
                return client
            } catch is IMAccessError { continue }
        }
        throw BridgeError(message: L("Nenhuma conta proprietária ou editora conectada tem os escopos e o acesso aos arquivos necessários para alterar o álbum \(album.name). Confira as permissões e consulte novamente."))
    }
    private func union(_ rows: [[IMAlbum]]) -> [IMAlbum] {
        var merged: [String: IMAlbum] = [:]
        for album in rows.flatMap({ $0 }) {
            if var previous = merged[album.id] {
                previous.readerIDs = Array(Set(previous.readerIDs + album.readerIDs)).sorted()
                previous.writerIDs = Array(Set(previous.writerIDs + album.writerIDs)).sorted()
                if previous.ownerID.isEmpty { previous.ownerID = album.ownerID }
                merged[album.id] = previous
            } else { merged[album.id] = album }
        }
        return merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func albums() async throws -> [IMAlbum] {
        var rows: [[IMAlbum]] = []
        for client in clients { rows.append(try await client.albums()) }
        return union(rows)
    }
    func memberships(_ assetID: String) async throws -> [IMAlbum] {
        var rows: [[IMAlbum]] = []
        for client in clients { rows.append(try await client.albums(assetID: assetID)) }
        return union(rows)
    }
    func people() async throws -> [IMPerson] {
        var rows: [IMPerson] = []
        for client in clients { rows += try await client.people() }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func asset(_ asset: IMAsset) async throws -> IMAsset { try await owner(asset.ownerId).asset(asset.id) }
}

enum IMManagementStore {
    private static let service = "br.allan.pontefotos.immich-management"
    private struct StoredAccount: Codable { let account: IMAccount; let key: String }
    private static func query(profileID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: profileID]
    }
    static func credentials(profileID: String) throws -> [IMCredential] {
        var q = query(profileID: profileID); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return [] }
        try ConnectionStore.check(status)
        guard let data = value as? Data else { throw BridgeError(message: L("Não foi possível carregar as contas do Chaves.")) }
        return try JSONDecoder().decode([StoredAccount].self, from: data).map { IMCredential(account: $0.account, key: $0.key) }
    }
    private static func save(_ values: [IMCredential], profileID: String) throws {
        let stored = values.map { StoredAccount(account: $0.account, key: $0.key) }
        let data = try JSONEncoder().encode(stored)
        let q = query(profileID: profileID)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try ConnectionStore.check(SecItemAdd(add as CFDictionary, nil))
        } else { try ConnectionStore.check(status) }
    }
    static func saveCredential(_ credential: IMCredential, profileID: String) throws {
        var values = try credentials(profileID: profileID); values.removeAll { $0.account.id == credential.account.id }; values.append(credential)
        try save(values, profileID: profileID)
    }
    static func removeCredential(accountID: String, profileID: String) throws {
        try save(credentials(profileID: profileID).filter { $0.account.id != accountID }, profileID: profileID)
    }
    static func verify(address: String, key: String) async throws -> IMCredential {
        let identity = try await ImmichClient(address: address, key: key).probe()
        let placeholder = IMCredential(account: IMAccount(id: identity.userID, name: L("Conta Immich")), key: key)
        struct User: Decodable { let id: String; let name: String?; let email: String? }
        let data = try await IMClient(address: address, credential: placeholder).data("users/me")
        let user = try JSONDecoder().decode(User.self, from: data)
        guard user.id.lowercased() == identity.userID else { throw BridgeError(message: L("A identidade da conta mudou durante a conexão.")) }
        return IMCredential(account: IMAccount(id: identity.userID, name: user.name?.isEmpty == false ? user.name! : L("Conta Immich")), key: key)
    }
    private static func historyURL(_ profileID: String) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PonteFotos/management", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Profiles generated by the app are UUIDs; never use a user string as a filesystem path.
        guard UUID(uuidString: profileID) != nil else { throw BridgeError(message: L("Perfil do servidor inválido. Salve a configuração de conexão.")) }
        return directory.appendingPathComponent(profileID + ".json")
    }
    static func history(profileID: String) throws -> [IMHistoryEntry] {
        let url = try historyURL(profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([IMHistoryEntry].self, from: Data(contentsOf: url))
    }
    static func saveHistory(_ entries: [IMHistoryEntry], profileID: String) throws {
        let url = try historyURL(profileID)
        try JSONEncoder().encode(Array(entries.prefix(20))).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
