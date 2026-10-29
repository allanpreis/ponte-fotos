import Foundation
import SwiftUI
import Photos
import AppKit
import CoreLocation
import CryptoKit

struct PFReverseItem: Identifiable, Equatable {
    let id: String
    let name: String
    let typeLabel: String
    let captureDate: Date?
    let latitude: Double?
    let longitude: Double?
    let isLive: Bool
    var canRecheck = false
    var verification: PFImportVerification? = nil
    var isImported = false
    var issue: String?
    var localizedType: PFMessage? = nil
    var localizedIssue: PFMessage? = nil
    var displayTypeLabel: String { localizedType?.text ?? typeLabel }
    var displayIssue: String? { localizedIssue?.text ?? issue }
    mutating func setIssue(_ value: PFMessage) { localizedIssue = value; issue = value.text }
    var selectable: Bool { issue == nil }
}

// Metadata and optional original-byte checks are distinct; neither certifies HDR playback.
struct PFImportVerification: Equatable {
    let problems: [PFMessage]
    var originalsVerified = false
    var isVerified: Bool { problems.isEmpty }
    var summary: PFMessage {
        guard isVerified else { return PFMessage.joined(problems, separator: " ") }
        return originalsVerified
            ? M("Metadados e bytes dos originais reexportados conferidos no Fotos. A reprodução HDR não foi conferida.")
            : M("Presença, data, localização e tipo Live Photo conferidos no Fotos. O conteúdo do original e a reprodução HDR não foram conferidos.")
    }
    static func evaluate(expected: PFReverseItem, present: Bool, date: Date?, latitude: Double?, longitude: Double?, isLive: Bool) -> Self {
        guard present else { return Self(problems: [M("O item criado não foi encontrado no Fotos.")]) }
        var problems: [PFMessage] = []
        if let expectedDate = expected.captureDate {
            if date.map({ abs($0.timeIntervalSince(expectedDate)) < 1 }) != true { problems.append(M("A data no Fotos difere da origem ou está ausente.")) }
        } else if date != nil { problems.append(M("A data no Fotos difere da origem ou está ausente.")) }
        let coordinatesMatch: Bool
        if let expectedLat = expected.latitude, let expectedLon = expected.longitude, let latitude, let longitude {
            coordinatesMatch = latitude.isFinite && longitude.isFinite && abs(latitude - expectedLat) < 0.00001 && abs(longitude - expectedLon) < 0.00001
        } else { coordinatesMatch = expected.latitude == nil && expected.longitude == nil && latitude == nil && longitude == nil }
        if !coordinatesMatch { problems.append(M("A localização no Fotos difere da origem ou está ausente.")) }
        if isLive != expected.isLive { problems.append(M("O tipo Live Photo no Fotos difere da origem.")) }
        return Self(problems: problems)
    }
}

struct PFReverseAsset: Decodable {
    let id: String
    let ownerId: String
    let originalFileName: String
    let checksum: String
    let type: String
    let fileCreatedAt: String?
    let livePhotoVideoId: String?
    var pairedChecksum: String? = nil // Filled from the paired resource, never trusted from the image response.
    let isOffline: Bool?
    let isTrashed: Bool?
    struct Exif: Decodable { let dateTimeOriginal: String?; let latitude: Double?; let longitude: Double? }
    let exifInfo: Exif?
    var item: PFReverseItem {
        let date = Self.date(exifInfo?.dateTimeOriginal ?? fileCreatedAt)
        let lat = exifInfo?.latitude, lon = exifInfo?.longitude
        var issue: PFMessage?
        if !["IMAGE", "VIDEO"].contains(type) { issue = M("Formato não suportado.") }
        else if isOffline == true || isTrashed == true { issue = M("Original indisponível ou na lixeira.") }
        else if date == nil { issue = M("Data de captura ausente ou inválida. Corrija no Immich antes de importar.") }
        else if !Self.validCoordinates(lat, lon) { issue = M("Localização incompleta ou inválida.") }
        else if !Self.validChecksum(checksum) { issue = M("Checksum original ausente ou inválido.") }
        let label: PFMessage = livePhotoVideoId != nil ? "Live Photo" : type == "VIDEO" ? M("Vídeo") : M("Foto estática")
        return PFReverseItem(id: id, name: Self.safeName(originalFileName), typeLabel: label.text, captureDate: date, latitude: lat, longitude: lon, isLive: livePhotoVideoId != nil, issue: issue?.text, localizedType: label, localizedIssue: issue)
    }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        // Require an explicit timezone: never reinterpret a wall-clock timestamp in the Mac's zone.
        guard value.range(of: "(Z|[+-][0-9]{2}:[0-9]{2})$", options: .regularExpression) != nil else { return nil }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]; return parser.date(from: value)
    }
    static func validCoordinates(_ latitude: Double?, _ longitude: Double?) -> Bool {
        if latitude == nil && longitude == nil { return true }
        guard let latitude, let longitude else { return false }
        return latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    static func safeName(_ name: String) -> String {
        let leaf = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "original"
        let clean = leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        return clean.isEmpty || clean == "." || clean == ".." ? "original" : String(clean.prefix(180))
    }
    static func validChecksum(_ value: String) -> Bool { Data(base64Encoded: value)?.count == 20 || (value.count == 40 && value.allSatisfy { $0.isHexDigit }) }
    static func verify(_ file: URL, checksum: String) throws {
        guard validChecksum(checksum) else {
            throw BridgeError(message: M("O original baixado não corresponde ao checksum do Immich. Nada foi importado."))
        }
        // Share bounded Foundation buffers and per-chunk cancellation with uploads.
        let actual = try ImmichClient.checksum(file)
        let hex = Data(base64Encoded: actual)?.map { String(format: "%02x", $0) }.joined()
        guard actual == checksum || hex == checksum.lowercased() else {
            throw BridgeError(message: M("O original baixado não corresponde ao checksum do Immich. Nada foi importado."))
        }
    }
}

protocol PFReverseRemote {
    var scope: String { get }
    func albums() async throws -> [IMAlbum]
    func ids(album: String) async throws -> [String]
    func asset(_ id: String) async throws -> PFReverseAsset
    func download(_ asset: PFReverseAsset, directory: URL) async throws -> URL
}
struct PFReverseHTTP: PFReverseRemote {
    let client: IMClient
    let profileID: String
    var scope: String { // No key, URL, account name or private environment data in history filenames.
        return SHA256.hash(data: Data((profileID + "|" + client.credential.account.id).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func albums() async throws -> [IMAlbum] { try await client.albums() }
    func ids(album: String) async throws -> [String] { try await client.albumIDs(album).sorted() }
    func asset(_ id: String) async throws -> PFReverseAsset {
        guard UUID(uuidString: id) != nil else { throw BridgeError(message: M("Identificador do arquivo inválido.")) }
        return try JSONDecoder().decode(PFReverseAsset.self, from: await client.data("assets/" + id))
    }
    func download(_ asset: PFReverseAsset, directory: URL) async throws -> URL {
        guard UUID(uuidString: asset.id) != nil else { throw BridgeError(message: M("Identificador do original inválido.")) }
        let api = try ImmichClient(address: client.address, key: client.credential.key)
        // A separate ephemeral, no-redirect session prevents API credentials from following a redirect.
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(for: api.request("assets/" + asset.id + "/original"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try api.check(response)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let destination = directory.appendingPathComponent(UUID().uuidString + "-" + PFReverseAsset.safeName(asset.originalFileName))
        try FileManager.default.moveItem(at: temporary, to: destination)
        do { try PFReverseAsset.verify(destination, checksum: asset.checksum) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return destination
    }
}

struct PFReverseRecord: Codable, Equatable {
    let assetID: String
    let checksum: String
    var photosID: String?
    var pending: Bool
    var pairSignature: String? = nil
    var originalVerificationRequired: Bool? = nil
    var originalsVerified: Bool? = nil
}
protocol PFReverseHistory {
    func load(scope: String) throws -> [PFReverseRecord]
    func save(_ records: [PFReverseRecord], scope: String) throws
}
struct PFReverseDiskHistory: PFReverseHistory {
    private func url(_ scope: String) throws -> URL {
        guard scope.count == 64, scope.allSatisfy({ $0.isHexDigit }) else { throw BridgeError(message: M("Identidade de histórico inválida.")) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PonteFotos/reverse-import", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent(scope + ".json")
    }
    func load(scope: String) throws -> [PFReverseRecord] {
        let file = try url(scope)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([PFReverseRecord].self, from: Data(contentsOf: file))
    }
    func save(_ records: [PFReverseRecord], scope: String) throws {
        let file = try url(scope)
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

struct PFPhotosAlbum: Identifiable, Equatable {
    let id: String
    let title: String
    var label: String
    var fallback: PFMessage? = nil
    var labelSuffix = ""
    var displayTitle: String { fallback?.text ?? title }
    var displayLabel: String { fallback.map { $0.text + labelSuffix } ?? label }
    init(id: String, title: String, label: String? = nil) { self.id = id; self.title = title; self.label = label ?? title }
    static func labeled(_ albums: [PFPhotosAlbum]) -> [PFPhotosAlbum] {
        let counts = Dictionary(grouping: albums, by: \.title)
        return albums.map { album in
            var value = album
            let matching = counts[album.title, default: []]
            if matching.count > 1 {
                let prefix = String(album.id.prefix(8))
                let suffix = matching.filter { $0.id.hasPrefix(prefix) }.count > 1 ? album.id : prefix
                value.labelSuffix = " · \(suffix)"
                value.label = "\(album.title) · \(suffix)"
            }
            return value
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}
enum PFPhotosDestinationMode: String, CaseIterable { case existing, new }
enum PFPhotosDestination: Equatable {
    case existing(id: String, title: String)
    case new(name: String)
    var title: String { switch self { case .existing(_, let title): return title; case .new(let name): return name } }
    var isValid: Bool {
        switch self {
        case .existing(let id, _): return !id.isEmpty
        case .new(let name): return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
struct PFPhotosImportResult { let assetID: String; let albumID: String }

@MainActor protocol PFReversePhotos {
    var canRead: Bool { get }
    func authorize() async throws
    func exists(_ id: String) -> Bool
    func contains(id: String, albumID: String) -> Bool
    func verify(id: String, asset: PFReverseAsset) async throws -> PFImportVerification
    func verifyOriginals(id: String, asset: PFReverseAsset) async throws
    func validate(asset: PFReverseAsset, original: URL, paired: URL?) async throws
    func listAlbums() async throws -> [PFPhotosAlbum]
    func inventory(albumID: String, allowCloud: Bool, root: URL, progress: @escaping (PFMessage, Int, Int) -> Void) async throws -> [PFPhotoOriginalIdentity]
    func validateInventory(albumID: String, identities: [PFPhotoOriginalIdentity]) throws
    func validateInventoryCandidate(albumID: String, identity: PFPhotoOriginalIdentity) throws
    func prepareDestination(_ destination: PFPhotosDestination) throws
    func addExisting(id: String, destination: PFPhotosDestination) async throws -> String
    func create(asset: PFReverseAsset, original: URL, paired: URL?, destination: PFPhotosDestination) async throws -> PFPhotosImportResult
}
extension PFReversePhotos {
    func inventory(albumID: String, allowCloud: Bool, root: URL, progress: @escaping (PFMessage, Int, Int) -> Void) async throws -> [PFPhotoOriginalIdentity] { [] }
    func validateInventory(albumID: String, identities: [PFPhotoOriginalIdentity]) throws {}
    func validateInventoryCandidate(albumID: String, identity: PFPhotoOriginalIdentity) throws {}
    func verifyOriginals(id: String, asset: PFReverseAsset) async throws {
        throw BridgeError(message: M("Não foi possível conferir os bytes dos originais no Fotos. O item permanece pendente."))
    }
    // Unknown membership must stay in the review queue.
    func contains(id: String, albumID: String) -> Bool { false }
}
// TCC can leave a request unanswered after a local-signature update. Never
// keep the import screen locked indefinitely; a late callback is ignored.
private final class PFPhotosAuthorizationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PHAuthorizationStatus, Error>?
    init(_ continuation: CheckedContinuation<PHAuthorizationStatus, Error>) { self.continuation = continuation }
    func finish(_ result: Result<PHAuthorizationStatus, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
enum PFPhotosAuthorization {
    static func request(timeout: TimeInterval = 30, using request: (@escaping @Sendable (PHAuthorizationStatus) -> Void) -> Void) async throws -> PHAuthorizationStatus {
        try await withCheckedThrowingContinuation { continuation in
            let gate = PFPhotosAuthorizationGate(continuation)
            request { gate.finish(.success($0)) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.finish(.failure(BridgeError(message: M("O macOS não respondeu ao pedido de acesso ao Fotos. Confira Privacidade e Segurança → Fotos e tente novamente."))))
            }
        }
    }
}
// Only original resource roles are candidates; rendered/adjusted resources never
// substitute for a missing original. RAW alternatives are ambiguous in this flow.
enum PFOriginalResourceSelection {
    static func indices(types: [PHAssetResourceType], assetType: String, isLive: Bool) throws -> [Int] {
        let wanted: [PHAssetResourceType]
        if isLive, assetType == "IMAGE" { wanted = [.photo, .pairedVideo] }
        else if !isLive, assetType == "IMAGE" { wanted = [.photo] }
        else if !isLive, assetType == "VIDEO" { wanted = [.video] }
        else { throw BridgeError(message: M("Os recursos originais no Fotos estão ausentes ou são ambíguos.")) }
        let originals: Set<PHAssetResourceType> = [.photo, .video, .pairedVideo, .alternatePhoto]
        guard types.filter({ originals.contains($0) }).count == wanted.count else {
            throw BridgeError(message: M("Os recursos originais no Fotos estão ausentes ou são ambíguos."))
        }
        return try wanted.map { role in
            let matching = types.indices.filter { types[$0] == role }
            guard matching.count == 1 else { throw BridgeError(message: M("Os recursos originais no Fotos estão ausentes ou são ambíguos.")) }
            return matching[0]
        }
    }
}
@MainActor final class PFReversePhotoLibrary: PFReversePhotos {
    var canRead: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }
    func authorize() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized { return }
        let status: PHAuthorizationStatus
        if current == .notDetermined {
            status = try await PFPhotosAuthorization.request { completion in
                PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: completion)
            }
        } else { status = current }
        guard status == .authorized else { throw BridgeError(message: M("Permita acesso completo ao Fotos para importar e conferir o histórico sem criar cópias repetidas.")) }
    }
    func inventory(albumID: String, allowCloud: Bool, root: URL, progress: @escaping (PFMessage, Int, Int) -> Void) async throws -> [PFPhotoOriginalIdentity] {
        try await PFPhotoAlbumInventory.scan(albumID: albumID, allowCloud: allowCloud, root: root, progress: progress)
    }
    func validateInventory(albumID: String, identities: [PFPhotoOriginalIdentity]) throws {
        try PFPhotoAlbumInventory.validate(albumID: albumID, identities: identities)
    }
    func validateInventoryCandidate(albumID: String, identity: PFPhotoOriginalIdentity) throws {
        try PFPhotoAlbumInventory.validateCandidate(albumID: albumID, identity: identity)
    }
    func exists(_ id: String) -> Bool { PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count == 1 }
    func contains(id: String, albumID: String) -> Bool {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return false }
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var found = false
        collections.enumerateObjects { collection, _, stop in
            if collection.localIdentifier == albumID { found = true; stop.pointee = true }
        }
        return found
    }
    func verify(id: String, asset: PFReverseAsset) async throws -> PFImportVerification {
        // PhotoKit can briefly lag the completed changes transaction. Only missing
        // visibility is retried, for at most one second; metadata mismatches are final.
        for attempt in 0..<3 {
            if let found = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                return .evaluate(expected: asset.item, present: true, date: found.creationDate,
                                 latitude: found.location?.coordinate.latitude, longitude: found.location?.coordinate.longitude,
                                 isLive: found.mediaSubtypes.contains(.photoLive))
            }
            if attempt < 2 { try await Task.sleep(nanoseconds: 500_000_000) }
        }
        return .evaluate(expected: asset.item, present: false, date: nil, latitude: nil, longitude: nil, isLive: false)
    }
    func verifyOriginals(id: String, asset: PFReverseAsset) async throws {
        try Task.checkCancellation()
        guard canRead, let found = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw BridgeError(message: M("O item criado não foi encontrado no Fotos."))
        }
        guard PFReverseAsset.validChecksum(asset.checksum) else {
            throw BridgeError(message: M("Checksum original ausente ou inválido."))
        }
        let resources = PHAssetResource.assetResources(for: found)
        let indices = try PFOriginalResourceSelection.indices(types: resources.map(\.type), assetType: asset.type, isLive: asset.livePhotoVideoId != nil)
        let checksums: [String]
        if asset.livePhotoVideoId != nil {
            guard let paired = asset.pairedChecksum, PFReverseAsset.validChecksum(paired) else {
                throw BridgeError(message: M("Vídeo da Live Photo indisponível."))
            }
            checksums = [asset.checksum, paired]
        } else { checksums = [asset.checksum] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ponte-original-check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        for (offset, index) in indices.enumerated() {
            try Task.checkCancellation()
            let file = directory.appendingPathComponent("resource-\(offset)")
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
            // writeData has no cancellable request ID. Await completion before
            // cleaning the private directory, even when the surrounding task stops.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resources[index], toFile: file, options: options) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            try Task.checkCancellation()
            let expected = checksums[offset]
            let hashTask = Task.detached(priority: .utility) { try ImmichClient.checksum(file) }
            let actual: String
            do {
                actual = try await withTaskCancellationHandler(operation: { try await hashTask.value }, onCancel: { hashTask.cancel() })
            }
            catch is CancellationError { throw CancellationError() }
            catch { throw BridgeError(message: M("Não foi possível conferir os bytes dos originais no Fotos. O item permanece pendente.")) }
            let hex = Data(base64Encoded: actual)?.map { String(format: "%02x", $0) }.joined()
            guard actual == expected || hex == expected.lowercased() else {
                throw BridgeError(message: M("Os bytes reexportados do Fotos não correspondem ao original do Immich. O item permanece pendente."))
            }
        }
    }
    func validate(asset: PFReverseAsset, original: URL, paired: URL?) async throws {
        if let paired {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let lock = NSLock(); var resumed = false
                PHLivePhoto.request(withResourceFileURLs: [original, paired], placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { photo, info in
                    if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                    lock.lock(); guard !resumed else { lock.unlock(); return }; resumed = true; lock.unlock()
                    if photo != nil { continuation.resume() }
                    else { continuation.resume(throwing: BridgeError(message: M("O par Live Photo não é compatível com o Fotos. Nenhum item estático foi criado em seu lugar."))) }
                }
            }
        }
        let resourceTypes: [PHAssetResourceType] = paired != nil ? [.photo, .pairedVideo] : [asset.type == "VIDEO" ? .video : .photo]
        guard PHAssetCreationRequest.supportsAssetResourceTypes(resourceTypes.map { NSNumber(value: $0.rawValue) }) else { throw BridgeError(message: M("Os recursos deste original não são compatíveis com o Fotos.")) }
    }
    func listAlbums() async throws -> [PFPhotosAlbum] {
        try await authorize()
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var albums: [PFPhotosAlbum] = []
        result.enumerateObjects { collection, _, _ in
            if collection.canPerform(.addContent) {
                var album = PFPhotosAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "")
                if collection.localizedTitle == nil { album.fallback = M("Sem título") }
                albums.append(album)
            }
        }
        return PFPhotosAlbum.labeled(albums)
    }
    private func collection(_ destination: PFPhotosDestination) throws -> PHAssetCollection? {
        guard destination.isValid else { throw BridgeError(message: M("Escolha um álbum existente ou informe o nome do novo álbum.")) }
        guard case .existing(let id, _) = destination else { return nil }
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject,
              album.assetCollectionType == .album, album.assetCollectionSubtype == .albumRegular,
              album.canPerform(.addContent) else {
            throw BridgeError(message: M("O álbum de destino foi removido ou não permite adicionar fotos. Atualize os álbuns do Fotos e selecione novamente."))
        }
        return album
    }
    func prepareDestination(_ destination: PFPhotosDestination) throws { _ = try collection(destination) }
    // Resolving by ID avoids sending photos to a different album with the same title.
    private static func albumRequest(_ destination: PFPhotosDestination, existing: PHAssetCollection?) throws -> (PHAssetCollectionChangeRequest, String) {
        if let existing {
            guard let request = PHAssetCollectionChangeRequest(for: existing) else { throw BridgeError(message: M("O álbum não permite alterações.")) }
            return (request, existing.localIdentifier)
        }
        let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: destination.title.trimmingCharacters(in: .whitespacesAndNewlines))
        let id = request.placeholderForCreatedAssetCollection.localIdentifier
        return (request, id)
    }
    func addExisting(id: String, destination: PFPhotosDestination) async throws -> String {
        let existingAlbum = try collection(destination)
        let found = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard found.count == 1 else { throw BridgeError(message: M("A foto importada não está mais no Fotos. Consulte os itens novamente.")) }
        if let existingAlbum {
            let contents = PHAsset.fetchAssets(in: existingAlbum, options: nil)
            if contents.index(of: found.object(at: 0)) != NSNotFound { return existingAlbum.localIdentifier }
        }
        var albumID: String?, changeError: Error?
        try await PHPhotoLibrary.shared().performChanges {
            do {
                let (request, resolvedID) = try Self.albumRequest(destination, existing: existingAlbum)
                request.addAssets(found); albumID = resolvedID
            } catch { changeError = error }
        }
        if let changeError { throw changeError }
        guard let albumID else { throw BridgeError(message: M("O Fotos não confirmou o álbum de destino.")) }
        return albumID
    }
    func create(asset: PFReverseAsset, original: URL, paired: URL?, destination: PFPhotosDestination) async throws -> PFPhotosImportResult {
        let existingAlbum = try collection(destination)
        var createdID: String?, albumID: String?, changeError: Error?
        try await PHPhotoLibrary.shared().performChanges {
            do {
                // Resolve the album request before requesting any asset creation.
                let (albumRequest, resolvedID) = try Self.albumRequest(destination, existing: existingAlbum)
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = asset.item.captureDate
                if let lat = asset.item.latitude, let lon = asset.item.longitude { request.location = CLLocation(latitude: lat, longitude: lon) }
                else { request.location = nil }
                let resourceOptions = PHAssetResourceCreationOptions(); resourceOptions.originalFilename = PFReverseAsset.safeName(asset.originalFileName); resourceOptions.shouldMoveFile = false
                request.addResource(with: asset.type == "VIDEO" ? .video : .photo, fileURL: original, options: resourceOptions)
                if let paired { request.addResource(with: .pairedVideo, fileURL: paired, options: nil) }
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                createdID = placeholder.localIdentifier; albumID = resolvedID
                albumRequest.addAssets([placeholder] as NSArray)
            } catch { changeError = error }
        }
        if let changeError { throw changeError }
        guard let createdID, let albumID else { throw BridgeError(message: M("Resultado do Fotos sem identificador. Confira a biblioteca antes de repetir.")) }
        return PFPhotosImportResult(assetID: createdID, albumID: albumID)
    }
}

@MainActor final class PFReverseImportModel: ObservableObject {
    @Published var albums: [IMAlbum] = []
    @Published var items: [PFReverseItem] = []
    @Published private(set) var albumQuerySucceeded = false
    @Published private(set) var lastImportSucceeded = false
    @Published var selection = Set<String>()
    @Published var verifyOriginalBytes = false
    @Published var albumID = "" {
        didSet {
            if albumID != oldValue && !importing { generation = UUID(); albumQuerySucceeded = false; lastImportSucceeded = false; items = []; selection = []; assets = [:]; reviewFollowID = nil; restoreFollowDestination() }
        }
    }
    @Published var destinationMode: PFPhotosDestinationMode = .new { didSet { if destinationMode != oldValue { invalidateDestinationComparison() } } }
    @Published var photosAlbums: [PFPhotosAlbum] = []
    @Published var destinationAlbumID = "" { didSet { if destinationAlbumID != oldValue { invalidateDestinationComparison() } } }
    @Published private(set) var existingPhotosCount = 0
    @Published private(set) var existingPhotosConflicts = 0
    @Published private(set) var comparedPhotosDestination = false
    private var comparisonDestinationID: String?
    private var inventoryTask: Task<[PFPhotoOriginalIdentity], Error>?
    @Published private var customDestinationAlbumName: String?
    var destinationAlbumName: String {
        get { customDestinationAlbumName ?? L("Importadas do Immich") }
        set { customDestinationAlbumName = newValue }
    }
    @Published var loadingDestinations = false
    var destination: PFPhotosDestination? {
        switch destinationMode {
        case .existing:
            guard let album = photosAlbums.first(where: { $0.id == destinationAlbumID }) else { return nil }
            return .existing(id: album.id, title: album.displayTitle)
        case .new: return .new(name: destinationAlbumName.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    var destinationLabel: String {
        switch destinationMode {
        case .existing: return photosAlbums.first(where: { $0.id == destinationAlbumID })?.displayLabel ?? L("Selecione um álbum")
        case .new: return L("Novo álbum: ") + destinationAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    var isDestinationValid: Bool { destination?.isValid == true }
    private func invalidateDestinationComparison() {
        guard !importing, comparisonDestinationID != nil else { return }
        inventoryTask?.cancel(); generation = UUID(); albumQuerySucceeded = false; lastImportSucceeded = false
        comparisonDestinationID = nil; comparedPhotosDestination = false; existingPhotosCount = 0; existingPhotosConflicts = 0
        items = []; selection = []; assets = [:]; reviewFollowID = nil
        statusMessage = M("O destino no Fotos mudou. Consulte os itens novamente para comparar os originais.")
    }
    private func scanDestination(_ albumID: String, token: UUID) async throws -> [PFPhotoOriginalIdentity] {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PonteFotos/photos-album-inventory", isDirectory: true)
        let task = Task { [photos, weak self] in
            try await photos.inventory(albumID: albumID, allowCloud: true, root: root) { [weak self] message, _, _ in
                guard let self, self.generation == token else { return }
                self.statusMessage = message
            }
        }
        inventoryTask = task
        defer { inventoryTask = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private enum ExistingPhotoMatch { case missing, verified(String), metadataConflict }
    private typealias InventoryIndex = [String: [PFPhotoOriginalIdentity]]
    private static func identityKey(kind: PFPhotoOriginalIdentity.Kind, checksum: String, pairedChecksum: String?) -> String? {
        guard let checksum = PFPhotoOriginalIdentity.normalizedChecksum(checksum) else { return nil }
        if kind == .live {
            guard let paired = pairedChecksum.flatMap(PFPhotoOriginalIdentity.normalizedChecksum) else { return nil }
            return kind.rawValue + ":" + checksum + ":" + paired
        }
        guard pairedChecksum == nil else { return nil }
        return kind.rawValue + ":" + checksum
    }
    private static func inventoryIndex(_ identities: [PFPhotoOriginalIdentity]) -> InventoryIndex {
        var result: InventoryIndex = [:]
        for identity in identities {
            if let key = identityKey(kind: identity.kind, checksum: identity.checksum, pairedChecksum: identity.pairedChecksum) {
                result[key, default: []].append(identity)
            }
        }
        return result
    }
    private func existingMatch(_ asset: PFReverseAsset, albumID: String, inventory: InventoryIndex, token: UUID) async throws -> ExistingPhotoMatch {
        let kind: PFPhotoOriginalIdentity.Kind = asset.livePhotoVideoId != nil ? .live : asset.type == "VIDEO" ? .video : .image
        guard let key = Self.identityKey(kind: kind, checksum: asset.checksum, pairedChecksum: asset.pairedChecksum) else { return .missing }
        let candidates = inventory[key, default: []]
        guard !candidates.isEmpty else { return .missing }
        for candidate in candidates {
            try Task.checkCancellation()
            guard generation == token, photos.contains(id: candidate.photosID, albumID: albumID) else { throw CancellationError() }
            try photos.validateInventoryCandidate(albumID: albumID, identity: candidate)
            let verification = try await photos.verify(id: candidate.photosID, asset: asset)
            guard generation == token else { throw CancellationError() }
            try photos.validateInventoryCandidate(albumID: albumID, identity: candidate)
            if verification.isVerified { return .verified(candidate.photosID) }
        }
        return .metadataConflict
    }
    func loadPhotosAlbums() async {
        guard !busy && !importing && !loadingDestinations else { return }
        loadingDestinations = true; busy = true; defer { loadingDestinations = false; busy = false }
        do {
            let rows = try await photos.listAlbums()
            photosAlbums = rows
            if !rows.contains(where: { $0.id == destinationAlbumID }) { destinationAlbumID = "" }
            restoreFollowDestination()
            statusMessage = rows.isEmpty ? M("Nenhum álbum editável encontrado. Você pode criar um novo álbum ao importar.") : M("\(rows.count) álbuns do Fotos disponíveis.")
        } catch { photosAlbums = []; destinationAlbumID = ""; statusMessage = PFMessage.error(error) }
    }
    @Published var busy = false
    @Published var importing = false
    var status: String { get { statusMessage.text } set { statusMessage = .verbatim(newValue) } }
    @Published var statusMessage = M("Conecte o Immich para escolher um álbum.")
    @Published var showConfirmation = false
    @Published var done = 0
    @Published var total = 0
    private var sourceContext: [String]?
    private let connect: (String, String, String) async throws -> PFReverseRemote
    private var remote: PFReverseRemote?
    @Published private(set) var followedAlbums: [PFAlbumFollowLink] = []
    private let followStore: PFAlbumFollowStore
    private var reviewFollowID: String?
    var activeFollow: PFAlbumFollowLink? { followedAlbums.first { $0.albumID == albumID && $0.destinationID == destinationAlbumID } ?? followedAlbums.first { $0.albumID == albumID } }
    private func restoreFollowDestination() {
        guard let link = activeFollow else { return }
        destinationMode = .existing; destinationAlbumID = link.destinationID
    }
    func configureBackgroundFollow(immichAlbumID: String, photosAlbumID: String) throws {
        guard !busy, !importing, let remote, let target = photosAlbums.first(where: { $0.id == photosAlbumID }),
              albums.contains(where: { $0.id == immichAlbumID }) else { throw BridgeError(message: M("O álbum de destino do Fotos não está disponível. Atualize a lista antes de continuar.")) }
        albumID = immichAlbumID; destinationMode = .existing; destinationAlbumID = photosAlbumID
        var links = try followStore.load(scope: remote.scope)
        if !links.contains(where: { $0.albumID == immichAlbumID && $0.destinationID == photosAlbumID }) {
            links.append(PFAlbumFollowLink(albumID: immichAlbumID, destinationID: photosAlbumID, destinationTitle: target.displayTitle, completed: [:], lastChecked: nil))
            try followStore.save(links, scope: remote.scope)
        }
        followedAlbums = links
    }
    func startFollowing() {
        guard !busy && !importing, let remote, !albumID.isEmpty,
              case .existing(let id, let title)? = destination, activeFollow == nil else { return }
        do {
            var links = followedAlbums
            links.append(PFAlbumFollowLink(albumID: albumID, destinationID: id, destinationTitle: title, completed: [:], lastChecked: nil))
            try followStore.save(links, scope: remote.scope)
            followedAlbums = links; items = []; selection = []; assets = [:]; reviewFollowID = nil
            statusMessage = M("Acompanhamento salvo. Consulte as novidades para revisar antes de importar.")
        } catch { statusMessage = PFMessage.error(error) }
    }
    func stopFollowing() {
        guard !busy && !importing, let remote, activeFollow != nil else { return }
        do {
            let links = followedAlbums.filter { $0.albumID != albumID }
            try followStore.save(links, scope: remote.scope)
            followedAlbums = links; items = []; selection = []; assets = [:]; reviewFollowID = nil
            statusMessage = M("Acompanhamento removido. Fotos e histórico de importação foram preservados.")
        } catch { statusMessage = PFMessage.error(error) }
    }
    private func followFingerprint(_ asset: PFReverseAsset) -> String {
        let values = [asset.checksum, asset.livePhotoVideoId ?? "", asset.pairedChecksum ?? "", asset.type,
                      asset.item.captureDate.map { String($0.timeIntervalSince1970) } ?? "",
                      asset.item.latitude.map { String($0) } ?? "", asset.item.longitude.map { String($0) } ?? ""]
        return SHA256.hash(data: Data(values.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func completeFollow(_ asset: PFReverseAsset, scope: String, destinationID: String) throws {
        guard let followedID = reviewFollowID else { return }
        guard let index = followedAlbums.firstIndex(where: { $0.albumID == followedID && $0.destinationID == destinationID }) else {
            throw BridgeError(message: M("O acompanhamento mudou. Consulte as novidades novamente."))
        }
        var links = followedAlbums
        links[index].completed[asset.id] = followFingerprint(asset)
        try followStore.save(links, scope: scope)
        followedAlbums = links
    }
    private let history: PFReverseHistory
    private let photos: PFReversePhotos
    private var assets: [String: PFReverseAsset] = [:]
    private var cancellationRequested = false
    private var pauseAfterItem = false
    private var generation = UUID()
    init(history: PFReverseHistory = PFReverseDiskHistory(), followStore: PFAlbumFollowStore = PFAlbumFollowDiskStore(), photos: PFReversePhotos? = nil,
         connect: @escaping (String, String, String) async throws -> PFReverseRemote = { address, key, profileID in
             let credential = try await IMManagementStore.verify(address: address, key: key)
             return PFReverseHTTP(client: IMClient(address: address, credential: credential), profileID: profileID)
         }) {
        self.history = history; self.followStore = followStore; self.photos = photos ?? PFReversePhotoLibrary(); self.connect = connect
    }
    func load(address: String, key: String, profileID: String, expectedUserID: String? = nil, preflight: (([String]) async throws -> Void)? = nil) async {
        guard !importing && !busy else { return }
        busy = true; defer { busy = false }
        let context = [address, key, profileID]
        let previousAlbum = sourceContext == context ? albumID : ""
        invalidateConnection()
        let token = generation
        do {
            guard UUID(uuidString: profileID) != nil else { throw BridgeError(message: M("Salve o perfil de conexão antes de importar.")) }
            try await preflight?(context)
            guard token == generation else { return }
            let value = try await connect(address, key, profileID)
            if let expectedUserID, let http = value as? PFReverseHTTP,
               http.client.credential.account.id != expectedUserID {
                throw BridgeError(message: M("A conta ou o endereço mudou. Atualize os álbuns e revise a seleção antes de importar."))
            }
            let rows = try await value.albums()
            guard token == generation else { return }
            let links = try followStore.load(scope: value.scope)
            remote = value; sourceContext = context; followedAlbums = links
            albums = rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            // An explicit refresh must not silently switch the user's source album.
            albumID = previousAlbum.isEmpty ? (albums.first?.id ?? "") : (albums.contains { $0.id == previousAlbum } ? previousAlbum : "")
            restoreFollowDestination()
            statusMessage = M("Escolha um álbum para revisar os originais.")
        } catch { if token == generation { statusMessage = PFMessage.error(error) } }
    }
    func loadAlbum(preflight: (([String]) async throws -> Void)? = nil) async {
        guard !busy && !importing, let remote else { return }
        busy = true; defer { busy = false }; selection = []; items = []; assets = [:]
        albumQuerySucceeded = false; lastImportSucceeded = false
        comparedPhotosDestination = false; existingPhotosCount = 0; existingPhotosConflicts = 0; comparisonDestinationID = nil
        let targetSnapshot = destination
        let token = generation, album = albumID, follow = activeFollow
        reviewFollowID = nil
        do {
            try await validateSource(preflight)
            guard generation == token else { return }
            let ids = try await remote.ids(album: album)
            var rows: [PFReverseItem] = [], loaded: [String: PFReverseAsset] = [:]
            let records = try history.load(scope: remote.scope)
            for id in ids {
                try Task.checkCancellation(); guard generation == token else { return }
                var asset = try await remote.asset(id)
                if let videoID = asset.livePhotoVideoId {
                    let video = try await remote.asset(videoID)
                    guard video.id == videoID, video.type == "VIDEO", video.isOffline != true, video.isTrashed != true, PFReverseAsset.validChecksum(video.checksum) else {
                        throw BridgeError(message: M("Vídeo da Live Photo indisponível."))
                    }
                    asset.pairedChecksum = video.checksum
                } else { asset.pairedChecksum = nil }
                var item = asset.item
                if let pending = records.last(where: { $0.assetID == id && $0.pending }) {
                    item.setIssue(M("Importação anterior sem confirmação final. Confira o Fotos antes de tentar novamente."))
                    item.canRecheck = pending.photosID?.isEmpty == false
                }
                if photos.canRead, let record = records.last(where: { $0.assetID == id && $0.checksum == asset.checksum && !$0.pending }), let photosID = record.photosID {
                    item.isImported = photos.exists(photosID)
                }
                // No permission prompt occurs while browsing.
                loaded[id] = asset; rows.append(item)
                statusMessage = M("Revisando \(rows.count) de \(ids.count)…")
            }
            guard generation == token, albumID == album else { return }
            let pairedIDs = Set(loaded.values.compactMap(\.livePhotoVideoId))
            rows = rows.filter { !pairedIDs.contains($0.id) }
            if photos.canRead, case .existing(let destinationID, _)? = targetSnapshot {
                comparisonDestinationID = destinationID
                let inventory = try await scanDestination(destinationID, token: token)
                guard generation == token, destination == targetSnapshot else { throw CancellationError() }
                let index = Self.inventoryIndex(inventory)
                var remaining: [PFReverseItem] = []
                for var item in rows {
                    guard let asset = loaded[item.id], item.selectable,
                          !records.contains(where: { $0.assetID == item.id && $0.pending }) else { remaining.append(item); continue }
                    switch try await existingMatch(asset, albumID: destinationID, inventory: index, token: token) {
                    case .missing: remaining.append(item)
                    case .verified: existingPhotosCount += 1
                    case .metadataConflict:
                        existingPhotosConflicts += 1
                        item.setIssue(M("O original já existe no álbum do Fotos, mas a data ou localização difere. Confira esse item antes de importar; nenhuma nova cópia será criada."))
                        remaining.append(item)
                    }
                }
                try photos.validateInventory(albumID: destinationID, identities: inventory)
                guard generation == token, destination == targetSnapshot else { throw CancellationError() }
                rows = remaining; comparedPhotosDestination = true
            }
            if let follow {
                rows = rows.filter { item in
                    // A current byte inventory supersedes old completion receipts.
                    // Only exact matches already removed above can leave this queue.
                    if comparedPhotosDestination { return true }
                    guard item.selectable else { return true }
                    guard !records.contains(where: { $0.assetID == item.id && $0.pending }),
                          let asset = loaded[item.id], follow.completed[item.id] == followFingerprint(asset),
                          photos.canRead, let record = records.last(where: { $0.assetID == item.id && $0.checksum == asset.checksum }),
                          !record.pending, let id = record.photosID, photos.exists(id), photos.contains(id: id, albumID: follow.destinationID) else { return true }
                    return false
                }
                var links = followedAlbums
                guard let index = links.firstIndex(where: { $0.albumID == album && $0.destinationID == follow.destinationID }) else {
                    throw BridgeError(message: M("O acompanhamento mudou. Consulte as novidades novamente."))
                }
                links[index].lastChecked = Date()
                try followStore.save(links, scope: remote.scope)
                followedAlbums = links; reviewFollowID = album
            }
            assets = loaded; items = rows; albumQuerySucceeded = true; statusMessage = follow == nil ? M("\(rows.count) originais encontrados. Selecione os itens para importar.") : M("\(rows.count) itens para revisar no acompanhamento. Nenhuma importação foi iniciada.")
        } catch { if generation == token { statusMessage = PFMessage.error(error) } }
    }
    // Explicit recovery reads an already-known PhotoKit identifier. It never
    // downloads originals, creates assets or changes album membership.
    func recheck(id: String, preflight: (([String]) async throws -> Void)? = nil) async {
        guard !busy && !importing && !loadingDestinations, let remote,
              items.contains(where: { $0.id == id && $0.canRecheck }) else { return }
        busy = true; defer { busy = false }
        let token = generation
        do {
            try await validateSource(preflight)
            guard token == generation else { return }
            let records = try history.load(scope: remote.scope)
            guard let pending = records.last(where: { $0.assetID == id && $0.pending }),
                  let photosID = pending.photosID, !photosID.isEmpty else { return }
            var asset = try await remote.asset(id)
            if let videoID = asset.livePhotoVideoId {
                let video = try await remote.asset(videoID)
                guard video.id == videoID, video.type == "VIDEO", video.isOffline != true, video.isTrashed != true, PFReverseAsset.validChecksum(video.checksum) else {
                    throw BridgeError(message: M("Vídeo da Live Photo indisponível."))
                }
                asset.pairedChecksum = video.checksum
            } else { asset.pairedChecksum = nil }
            guard token == generation else { return }
            guard asset.id == id, asset.item.selectable, asset.checksum == pending.checksum,
                  (asset.livePhotoVideoId == nil && pending.pairSignature == nil) || pending.pairSignature == followFingerprint(asset) else {
                throw BridgeError(message: M("O original ou seus metadados mudaram. Consulte o álbum novamente antes de importar."))
            }
            try await photos.authorize()
            guard token == generation else { return }
            let requiresOriginals = verifyOriginalBytes || pending.originalVerificationRequired == true
            if requiresOriginals {
                var intent = records
                guard let index = intent.lastIndex(where: { $0 == pending }) else { return }
                intent[index].originalVerificationRequired = true; intent[index].originalsVerified = false
                try history.save(intent, scope: remote.scope)
            }
            let report = try await verifyImported(id: photosID, asset: asset, originals: requiresOriginals, generation: token)
            guard token == generation else { return }
            recordVerification(report, id: id)
            guard report.isVerified else { statusMessage = report.summary; return }
            // Re-read after suspension: never overwrite a different recovery result.
            var current = try history.load(scope: remote.scope)
            guard let index = current.lastIndex(where: { $0.assetID == id && $0.pending && $0.photosID == photosID && $0.checksum == pending.checksum }) else { return }
            current[index].pending = false
            if requiresOriginals { current[index].originalVerificationRequired = true; current[index].originalsVerified = report.originalsVerified }
            try history.save(current, scope: remote.scope)
            if let row = items.firstIndex(where: { $0.id == id }) {
                items[row].issue = nil; items[row].localizedIssue = nil; items[row].canRecheck = false
                items[row].isImported = true
            }
            statusMessage = report.summary
        } catch {
            guard token == generation else { return }
            statusMessage = PFMessage.error(error)
        }
    }
    func thumbnail(id: String) async -> NSImage? {
        guard let remote = remote as? PFReverseHTTP, assets[id] != nil else { return nil }
        let token = generation
        guard let data = try? await remote.client.thumbnail(id), token == generation, !Task.isCancelled else { return nil }
        return NSImage(data: data)
    }
    // A route change never replaces the endpoint of an in-flight media pair.
    // Finish this item, then require a fresh source review before continuing.
    func requestPauseAfterItem() {
        if importing { pauseAfterItem = true }
        else { invalidateConnection() }
    }
    private func validateSource(_ preflight: (([String]) async throws -> Void)?) async throws {
        guard let preflight else { return }
        guard let sourceContext else { throw BridgeError(message: M("Atualize os álbuns para validar a conta e o endereço de origem.")) }
        try await preflight(sourceContext)
    }
    func cancel() {
        inventoryTask?.cancel()
        cancellationRequested = true; showConfirmation = false
        if !importing {
            generation = UUID(); items = []; selection = []; assets = [:]
            albumQuerySucceeded = false; lastImportSucceeded = false; comparisonDestinationID = nil
            comparedPhotosDestination = false; existingPhotosCount = 0; existingPhotosConflicts = 0
        }
    }
    func invalidate() { invalidateConnection() }
    func invalidateConnection(preservingProgress: Bool = false) {
        inventoryTask?.cancel(); comparisonDestinationID = nil; comparedPhotosDestination = false; existingPhotosCount = 0; existingPhotosConflicts = 0
        sourceContext = nil; albumQuerySucceeded = false; lastImportSucceeded = false
        generation = UUID(); cancellationRequested = true; showConfirmation = false
        if !importing {
            remote = nil; followedAlbums = []; reviewFollowID = nil; albums = []; albumID = ""; items = []; selection = []; assets = [:]
            if !preservingProgress {
                done = 0; total = 0
                statusMessage = M("Atualize a lista de álbuns, escolha uma origem e consulte os itens para revisar a importação.")
            }
        }
    }
    // Dependency injection keeps tests entirely outside the user's Photos library and network.
    func use(remote: PFReverseRemote, assets: [PFReverseAsset]) {
        guard !importing else { return }; self.remote = remote; self.assets = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }); items = assets.map(\.item)
    }
    func importSelected(preflight: (([String]) async throws -> Void)? = nil) async {
        guard !busy && !importing && !loadingDestinations, let remote else { return }
        lastImportSucceeded = false
        let selected = items.filter { selection.contains($0.id) && $0.selectable }.compactMap { assets[$0.id] }
        guard !selected.isEmpty, var target = destination, target.isValid else { statusMessage = M("Selecione originais válidos e informe o álbum de destino."); return }
        if reviewFollowID != nil {
            guard case .existing(let id, _) = target, activeFollow?.destinationID == id else {
                statusMessage = M("O acompanhamento mudou. Consulte as novidades novamente."); return
            }
        }
        importing = true; cancellationRequested = false; pauseAfterItem = false; showConfirmation = false; done = 0; total = selected.count
        let token = generation
        let verifyBytes = verifyOriginalBytes
        defer {
            importing = false
            if pauseAfterItem { invalidateConnection(preservingProgress: true) }
            if token != generation { self.remote = nil; items = []; albums = []; assets = [:]; selection = [] }
        }
        do {
            try await validateSource(preflight)
            guard token == generation else { return }
            if let followedID = reviewFollowID {
                let currentIDs = Set(try await remote.ids(album: followedID))
                guard token == generation, selected.allSatisfy({ currentIDs.contains($0.id) }) else {
                    throw BridgeError(message: M("O acompanhamento mudou. Consulte as novidades novamente."))
                }
            }
            try await photos.authorize()
            try photos.prepareDestination(target)
            var records = try history.load(scope: remote.scope)
            var inventoryAlbumID: String?
            let destinationInventory: [PFPhotoOriginalIdentity]
            if case .existing(let id, _) = target {
                inventoryAlbumID = id
                destinationInventory = try await scanDestination(id, token: token)
                guard token == generation, !cancellationRequested else { return }
                try photos.validateInventory(albumID: id, identities: destinationInventory)
            } else { inventoryAlbumID = nil; destinationInventory = [] }
            var destinationIndex = Self.inventoryIndex(destinationInventory)
            for originalAsset in selected {
                if cancellationRequested || pauseAfterItem || generation != token { statusMessage = M("Importação interrompida entre itens. \(done) concluídos."); return }
                var asset = try await remote.asset(originalAsset.id)
                if let videoID = asset.livePhotoVideoId {
                    let video = try await remote.asset(videoID)
                    guard video.id == videoID, video.type == "VIDEO", video.isOffline != true, video.isTrashed != true, PFReverseAsset.validChecksum(video.checksum) else {
                        throw BridgeError(message: M("Vídeo da Live Photo indisponível."))
                    }
                    asset.pairedChecksum = video.checksum
                    if let expectedPair = originalAsset.pairedChecksum, expectedPair != video.checksum {
                        throw BridgeError(message: M("O original ou seus metadados mudaram. Consulte o álbum novamente antes de importar."))
                    }
                } else { asset.pairedChecksum = nil }
                guard asset.item.selectable, asset.checksum == originalAsset.checksum, asset.livePhotoVideoId == originalAsset.livePhotoVideoId,
                      asset.item.captureDate == originalAsset.item.captureDate, asset.item.latitude == originalAsset.item.latitude, asset.item.longitude == originalAsset.item.longitude else { throw BridgeError(message: M("O original ou seus metadados mudaram. Consulte o álbum novamente antes de importar.")) }
                if records.contains(where: { $0.assetID == asset.id && $0.pending }) { throw BridgeError(message: M("Há um resultado pendente para este item. Confira o Fotos antes de repetir.")) }
                if let destinationID = inventoryAlbumID {
                    switch try await existingMatch(asset, albumID: destinationID, inventory: destinationIndex, token: token) {
                    case .missing: break
                    case .verified:
                        guard token == generation, !cancellationRequested else { return }
                        recordVerification(PFImportVerification(problems: [], originalsVerified: true), id: asset.id)
                        markImported(asset.id); done += 1; existingPhotosCount += 1
                        continue
                    case .metadataConflict:
                        existingPhotosConflicts += 1
                        let issue = M("O original já existe no álbum do Fotos, mas a data ou localização difere. Confira esse item antes de importar; nenhuma nova cópia será criada.")
                        if let row = items.firstIndex(where: { $0.id == asset.id }) { items[row].setIssue(issue) }
                        selection.remove(asset.id)
                        throw BridgeError(message: issue)
                    }
                }
                if let previous = records.last(where: { $0.assetID == asset.id && $0.checksum == asset.checksum }), let id = previous.photosID, photos.exists(id) {
                    if asset.livePhotoVideoId != nil || previous.pairSignature != nil {
                        guard previous.pairSignature == followFingerprint(asset) else {
                            throw BridgeError(message: M("O par Live Photo mudou ou não foi registrado no histórico antigo. Confira o Fotos antes de reutilizar este item."))
                        }
                    }
                    if cancellationRequested || generation != token { return }
                    let requiresOriginals = verifyBytes || previous.originalVerificationRequired == true
                    if requiresOriginals, let index = records.lastIndex(where: { $0.assetID == asset.id && $0.photosID == id }) {
                        records[index].pending = true
                        records[index].originalVerificationRequired = true; records[index].originalsVerified = false
                        try history.save(records, scope: remote.scope)
                    }
                    let verification: PFImportVerification
                    do { verification = try await verifyImported(id: id, asset: asset, originals: requiresOriginals, generation: token) }
                    catch {
                        let report = PFImportVerification(problems: [M("Não foi possível concluir a conferência no Fotos. Confira a biblioteca antes de repetir.")])
                        recordVerification(report, id: asset.id)
                        if let index = records.lastIndex(where: { $0.assetID == asset.id && $0.photosID == id }) { records[index].pending = true }
                        try history.save(records, scope: remote.scope)
                        setCanRecheck(true, id: asset.id)
                        throw error
                    }
                    recordVerification(verification, id: asset.id)
                    guard verification.isVerified else {
                        if let index = records.lastIndex(where: { $0.assetID == asset.id && $0.photosID == id }) { records[index].pending = true }
                        try history.save(records, scope: remote.scope)
                        setCanRecheck(true, id: asset.id)
                        throw BridgeError(message: verification.summary)
                    }
                    if requiresOriginals, let index = records.lastIndex(where: { $0.assetID == asset.id && $0.photosID == id }) {
                        records[index].pending = false; records[index].originalsVerified = verification.originalsVerified
                        try history.save(records, scope: remote.scope)
                    }
                    if cancellationRequested || generation != token { return }
                    let albumID = try await photos.addExisting(id: id, destination: target)
                    rememberResolvedAlbum(id: albumID, destination: target)
                    target = .existing(id: albumID, title: target.title); inventoryAlbumID = albumID
                    try completeFollow(asset, scope: remote.scope, destinationID: albumID)
                    markImported(asset.id); done += 1; continue
                }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ponte-reverse-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: dir) }
                statusMessage = M("Baixando e verificando \(asset.item.name)…")
                let file = try await remote.download(asset, directory: dir)
                var paired: URL?
                if let videoID = asset.livePhotoVideoId {
                    guard asset.type == "IMAGE" else { throw BridgeError(message: M("Par Live Photo inválido.")) }
                    let video = try await remote.asset(videoID)
                    guard video.id == videoID, video.type == "VIDEO", video.isOffline != true, video.isTrashed != true, video.checksum == asset.pairedChecksum else { throw BridgeError(message: M("Vídeo da Live Photo indisponível.")) }
                    paired = try await remote.download(video, directory: dir)
                }
                if cancellationRequested || generation != token { statusMessage = M("Importação interrompida antes de gravar no Fotos."); return }
                try await photos.validate(asset: asset, original: file, paired: paired)
                if cancellationRequested || generation != token { statusMessage = M("Importação interrompida antes de gravar no Fotos."); return }
                var creationInventory: [PFPhotoOriginalIdentity]?
                if let destinationID = inventoryAlbumID {
                    let fresh = try await scanDestination(destinationID, token: token)
                    try photos.validateInventory(albumID: destinationID, identities: fresh)
                    destinationIndex = Self.inventoryIndex(fresh); creationInventory = fresh
                    switch try await existingMatch(asset, albumID: destinationID, inventory: destinationIndex, token: token) {
                    case .verified:
                        recordVerification(PFImportVerification(problems: [], originalsVerified: true), id: asset.id)
                        markImported(asset.id); done += 1; existingPhotosCount += 1
                        continue
                    case .metadataConflict:
                        throw BridgeError(message: M("O original já existe no álbum do Fotos, mas a data ou localização difere. Confira esse item antes de importar; nenhuma nova cópia será criada."))
                    case .missing: break
                    }
                }
                if let followedID = reviewFollowID {
                    let currentIDs = Set(try await remote.ids(album: followedID))
                    guard currentIDs.contains(asset.id) else { throw BridgeError(message: M("O acompanhamento mudou. Consulte as novidades novamente.")) }
                }
                try await validateSource(preflight)
                guard token == generation, !cancellationRequested else { return }
                if let destinationID = inventoryAlbumID, let fresh = creationInventory { try photos.validateInventory(albumID: destinationID, identities: fresh) }
                // Persist intent BEFORE PhotoKit. Crashes/ambiguous errors must never trigger blind retries.
                records.removeAll { $0.assetID == asset.id }
                records.append(PFReverseRecord(assetID: asset.id, checksum: asset.checksum, photosID: nil, pending: true, pairSignature: asset.livePhotoVideoId == nil ? nil : followFingerprint(asset), originalVerificationRequired: verifyBytes ? true : nil, originalsVerified: verifyBytes ? false : nil))
                try history.save(records, scope: remote.scope)
                let result = try await photos.create(asset: asset, original: file, paired: paired, destination: target)
                rememberResolvedAlbum(id: result.albumID, destination: target)
                target = .existing(id: result.albumID, title: target.title); inventoryAlbumID = result.albumID
                records[records.count - 1].photosID = result.assetID
                try history.save(records, scope: remote.scope)
                setCanRecheck(true, id: asset.id)
                let verification: PFImportVerification
                do { verification = try await verifyImported(id: result.assetID, asset: asset, originals: verifyBytes, generation: token) }
                catch {
                    let report = PFImportVerification(problems: [M("Não foi possível concluir a conferência no Fotos. Confira a biblioteca antes de repetir.")])
                    recordVerification(report, id: asset.id)
                    throw error
                }
                recordVerification(verification, id: asset.id)
                guard verification.isVerified else { throw BridgeError(message: verification.summary) }
                records[records.count - 1].pending = false
                if verifyBytes { records[records.count - 1].originalsVerified = verification.originalsVerified }
                try history.save(records, scope: remote.scope)
                setCanRecheck(false, id: asset.id)
                try completeFollow(asset, scope: remote.scope, destinationID: result.albumID)
                markImported(asset.id); done += 1
            }
            lastImportSucceeded = done == selected.count
            statusMessage = M("\(done) itens confirmados no Fotos da Apple. Os originais do Immich foram preservados.")
        } catch { statusMessage = PFMessage.error(error) + M(" Importação interrompida; confira os itens e o histórico antes de repetir.") }
    }
    private func verifyImported(id: String, asset: PFReverseAsset, originals: Bool, generation token: UUID) async throws -> PFImportVerification {
        var report = try await photos.verify(id: id, asset: asset)
        guard token == generation else { throw CancellationError() }
        try Task.checkCancellation()
        guard report.isVerified, originals else { return report }
        statusMessage = M("Reexportando e conferindo os originais no Fotos…")
        try await photos.verifyOriginals(id: id, asset: asset)
        guard token == generation else { throw CancellationError() }
        try Task.checkCancellation()
        report.originalsVerified = true
        return report
    }
    private func setCanRecheck(_ value: Bool, id: String) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].canRecheck = value }
    }
    private func recordVerification(_ report: PFImportVerification, id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].verification = report
        if !report.isVerified { items[index].setIssue(M("Conferência pendente. Confira o Fotos antes de repetir.")); selection.remove(id) }
    }
    private func rememberResolvedAlbum(id: String, destination: PFPhotosDestination) {
        guard case .new = destination else { return }
        if !photosAlbums.contains(where: { $0.id == id }) { photosAlbums.append(PFPhotosAlbum(id: id, title: destination.title)) }
        photosAlbums = PFPhotosAlbum.labeled(photosAlbums)
        destinationAlbumID = id; destinationMode = .existing
    }
    private func markImported(_ id: String) { if let index = items.firstIndex(where: { $0.id == id }) { items[index].isImported = true }; selection.remove(id) }
}
