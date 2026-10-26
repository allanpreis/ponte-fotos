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

// This verifies PhotoKit metadata, not exported original bytes or HDR playback.
struct PFImportVerification: Equatable {
    let problems: [PFMessage]
    var isVerified: Bool { problems.isEmpty }
    var summary: PFMessage {
        isVerified ? M("Presença, data, localização e tipo Live Photo conferidos no Fotos. O conteúdo do original e a reprodução HDR não foram conferidos.") : PFMessage.joined(problems, separator: " ")
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
    func verify(id: String, asset: PFReverseAsset) async throws -> PFImportVerification
    func validate(asset: PFReverseAsset, original: URL, paired: URL?) async throws
    func listAlbums() async throws -> [PFPhotosAlbum]
    func prepareDestination(_ destination: PFPhotosDestination) throws
    func addExisting(id: String, destination: PFPhotosDestination) async throws -> String
    func create(asset: PFReverseAsset, original: URL, paired: URL?, destination: PFPhotosDestination) async throws -> PFPhotosImportResult
}
@MainActor final class PFReversePhotoLibrary: PFReversePhotos {
    var canRead: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }
    func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else { throw BridgeError(message: M("Permita acesso completo ao Fotos para importar e conferir o histórico sem criar cópias repetidas.")) }
    }
    func exists(_ id: String) -> Bool { PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count == 1 }
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
    @Published var selection = Set<String>()
    @Published var albumID = "" {
        didSet {
            if albumID != oldValue && !importing { generation = UUID(); items = []; selection = []; assets = [:] }
        }
    }
    @Published var destinationMode: PFPhotosDestinationMode = .new
    @Published var photosAlbums: [PFPhotosAlbum] = []
    @Published var destinationAlbumID = ""
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
    func loadPhotosAlbums() async {
        guard !busy && !importing && !loadingDestinations else { return }
        loadingDestinations = true; busy = true; defer { loadingDestinations = false; busy = false }
        do {
            let rows = try await photos.listAlbums()
            photosAlbums = rows
            if !rows.contains(where: { $0.id == destinationAlbumID }) { destinationAlbumID = "" }
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
    private let history: PFReverseHistory
    private let photos: PFReversePhotos
    private var assets: [String: PFReverseAsset] = [:]
    private var cancellationRequested = false
    private var pauseAfterItem = false
    private var generation = UUID()
    init(history: PFReverseHistory = PFReverseDiskHistory(), photos: PFReversePhotos? = nil,
         connect: @escaping (String, String, String) async throws -> PFReverseRemote = { address, key, profileID in
             let credential = try await IMManagementStore.verify(address: address, key: key)
             return PFReverseHTTP(client: IMClient(address: address, credential: credential), profileID: profileID)
         }) {
        self.history = history; self.photos = photos ?? PFReversePhotoLibrary(); self.connect = connect
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
            remote = value; sourceContext = context
            albums = rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            // An explicit refresh must not silently switch the user's source album.
            albumID = previousAlbum.isEmpty ? (albums.first?.id ?? "") : (albums.contains { $0.id == previousAlbum } ? previousAlbum : "")
            statusMessage = M("Escolha um álbum para revisar os originais.")
        } catch { if token == generation { statusMessage = PFMessage.error(error) } }
    }
    func loadAlbum(preflight: (([String]) async throws -> Void)? = nil) async {
        guard !busy && !importing, let remote else { return }
        busy = true; defer { busy = false }; selection = []; items = []; assets = [:]
        let token = generation, album = albumID
        do {
            try await validateSource(preflight)
            guard generation == token else { return }
            let ids = try await remote.ids(album: album)
            var rows: [PFReverseItem] = [], loaded: [String: PFReverseAsset] = [:]
            let records = try history.load(scope: remote.scope)
            for id in ids {
                try Task.checkCancellation(); guard generation == token else { return }
                let asset = try await remote.asset(id)
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
            assets = loaded; items = rows; statusMessage = M("\(rows.count) originais encontrados. Selecione os itens para importar.")
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
            let asset = try await remote.asset(id)
            guard token == generation else { return }
            guard asset.id == id, asset.item.selectable, asset.checksum == pending.checksum else {
                throw BridgeError(message: M("O original ou seus metadados mudaram. Consulte o álbum novamente antes de importar."))
            }
            try await photos.authorize()
            guard token == generation else { return }
            let report = try await photos.verify(id: photosID, asset: asset)
            guard token == generation else { return }
            recordVerification(report, id: id)
            guard report.isVerified else { statusMessage = report.summary; return }
            // Re-read after suspension: never overwrite a different recovery result.
            var current = try history.load(scope: remote.scope)
            guard let index = current.lastIndex(where: { $0.assetID == id && $0.pending && $0.photosID == photosID && $0.checksum == pending.checksum }) else { return }
            current[index].pending = false
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
        cancellationRequested = true; showConfirmation = false
        if !importing { generation = UUID(); items = []; selection = []; assets = [:] }
    }
    func invalidate() { invalidateConnection() }
    func invalidateConnection() {
        sourceContext = nil
        generation = UUID(); cancellationRequested = true; showConfirmation = false
        if !importing { remote = nil; albums = []; items = []; selection = []; assets = [:] }
    }
    // Dependency injection keeps tests entirely outside the user's Photos library and network.
    func use(remote: PFReverseRemote, assets: [PFReverseAsset]) {
        guard !importing else { return }; self.remote = remote; self.assets = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }); items = assets.map(\.item)
    }
    func importSelected(preflight: (([String]) async throws -> Void)? = nil) async {
        guard !busy && !importing && !loadingDestinations, let remote else { return }
        let selected = items.filter { selection.contains($0.id) && $0.selectable }.compactMap { assets[$0.id] }
        guard !selected.isEmpty, var target = destination, target.isValid else { statusMessage = M("Selecione originais válidos e informe o álbum de destino."); return }
        importing = true; cancellationRequested = false; pauseAfterItem = false; showConfirmation = false; done = 0; total = selected.count
        let token = generation
        defer {
            importing = false
            if pauseAfterItem { invalidateConnection() }
            if token != generation { self.remote = nil; items = []; albums = []; assets = [:]; selection = [] }
        }
        do {
            try await validateSource(preflight)
            guard token == generation else { return }
            try await photos.authorize()
            try photos.prepareDestination(target)
            var records = try history.load(scope: remote.scope)
            for originalAsset in selected {
                if cancellationRequested || pauseAfterItem || generation != token { statusMessage = M("Importação interrompida entre itens. \(done) concluídos."); return }
                let asset = try await remote.asset(originalAsset.id)
                guard asset.item.selectable, asset.checksum == originalAsset.checksum, asset.livePhotoVideoId == originalAsset.livePhotoVideoId,
                      asset.item.captureDate == originalAsset.item.captureDate, asset.item.latitude == originalAsset.item.latitude, asset.item.longitude == originalAsset.item.longitude else { throw BridgeError(message: M("O original ou seus metadados mudaram. Consulte o álbum novamente antes de importar.")) }
                if records.contains(where: { $0.assetID == asset.id && $0.pending }) { throw BridgeError(message: M("Há um resultado pendente para este item. Confira o Fotos antes de repetir.")) }
                if let previous = records.last(where: { $0.assetID == asset.id && $0.checksum == asset.checksum }), let id = previous.photosID, photos.exists(id) {
                    if cancellationRequested || generation != token { return }
                    let verification: PFImportVerification
                    do { verification = try await photos.verify(id: id, asset: asset) }
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
                    if cancellationRequested || generation != token { return }
                    let albumID = try await photos.addExisting(id: id, destination: target)
                    rememberResolvedAlbum(id: albumID, destination: target)
                    target = .existing(id: albumID, title: target.title)
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
                    guard video.type == "VIDEO", video.isOffline != true, video.isTrashed != true else { throw BridgeError(message: M("Vídeo da Live Photo indisponível.")) }
                    paired = try await remote.download(video, directory: dir)
                }
                if cancellationRequested || generation != token { statusMessage = M("Importação interrompida antes de gravar no Fotos."); return }
                try await photos.validate(asset: asset, original: file, paired: paired)
                if cancellationRequested || generation != token { statusMessage = M("Importação interrompida antes de gravar no Fotos."); return }
                // Persist intent BEFORE PhotoKit. Crashes/ambiguous errors must never trigger blind retries.
                records.removeAll { $0.assetID == asset.id }
                records.append(PFReverseRecord(assetID: asset.id, checksum: asset.checksum, photosID: nil, pending: true))
                try history.save(records, scope: remote.scope)
                let result = try await photos.create(asset: asset, original: file, paired: paired, destination: target)
                rememberResolvedAlbum(id: result.albumID, destination: target)
                target = .existing(id: result.albumID, title: target.title)
                records[records.count - 1].photosID = result.assetID
                try history.save(records, scope: remote.scope)
                setCanRecheck(true, id: asset.id)
                let verification: PFImportVerification
                do { verification = try await photos.verify(id: result.assetID, asset: asset) }
                catch {
                    let report = PFImportVerification(problems: [M("Não foi possível concluir a conferência no Fotos. Confira a biblioteca antes de repetir.")])
                    recordVerification(report, id: asset.id)
                    throw error
                }
                recordVerification(verification, id: asset.id)
                guard verification.isVerified else { throw BridgeError(message: verification.summary) }
                records[records.count - 1].pending = false
                try history.save(records, scope: remote.scope)
                setCanRecheck(false, id: asset.id)
                markImported(asset.id); done += 1
            }
            statusMessage = M("\(done) itens confirmados no Fotos da Apple. Os originais do Immich foram preservados.")
        } catch { statusMessage = PFMessage.error(error) + M(" Importação interrompida; confira os itens e o histórico antes de repetir.") }
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
