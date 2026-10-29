import SwiftUI
import AppKit
import Photos
import UniformTypeIdentifiers
import CryptoKit
import ImageIO
import AVFoundation

struct PhotoItem: Identifiable {
    let asset: PHAsset?
    let resources: [PHAssetResource]
    let metadata: CaptureMetadata
    var external: ExternalMedia? = nil
    var id: String {
        if let asset { return asset.localIdentifier }
        var identity = external?.url.standardizedFileURL.path ?? ""
        if let media = external, let video = media.pairedVideo {
            let parts = [video.standardizedFileURL.path, media.contentChecksum ?? "", media.pairedChecksum ?? "",
                         media.sidecarChecksum ?? "", media.pairedSidecarChecksum ?? ""]
            identity += "|live|" + parts.joined(separator: "|")
        }
        return "file-" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var title: String { external?.url.lastPathComponent ?? resources.first(where: { $0.type == .photo || $0.type == .video })?.originalFilename ?? L("Sem nome") }
    var live: Bool { external?.pairedVideo != nil || asset?.mediaSubtypes.contains(.photoLive) == true }
    var raw: Bool { external.map { UTType(filenameExtension: $0.url.pathExtension)?.conforms(to: .rawImage) == true } ?? resources.contains { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true } }
    var fileNames: String { external.map { [$0.url.path, $0.pairedVideo?.path].compactMap { $0 }.joined(separator: " + ") } ?? resources.map(\.originalFilename).joined(separator: " + ") }
}
struct ResourceDescriptor { let type: PHAssetResourceType; let originalFilename: String }
struct PFPreparedUploadResource {
    let index: Int
    let resource: ResourceDescriptor
    let file: URL
    let sidecar: URL
    let checksum: String
    let bytes: Int64
    let token: String
}
struct PFPreparedUploadItem {
    let position: Int
    let item: PhotoItem
    let resources: [PFPreparedUploadResource]
    let folder: URL
    let multipartBytes: Int64
}
struct PFUploadMetrics {
    var preparedBytes: Int64 = 0
    var uploadedBytes: Int64 = 0
    var uploadedResources = 0
    var reusedResources = 0
    var completedItems = 0
    var processedItems = 0
    var lookupRequests = 0
    var preparationSeconds = 0.0
    var lookupSeconds = 0.0
    var transferSeconds = 0.0
    var verificationSeconds = 0.0
}
struct AlbumItem: Identifiable {
    let id: String; let title: String; let collection: PHAssetCollection?
    var fallback: PFMessage? = nil
    var displayTitle: String { fallback?.text ?? title }
}
@MainActor final class LibraryModel: ObservableObject {
    @Published var items: [PhotoItem] = []
    @Published var albums: [AlbumItem] = []
    @Published var album = "all" {
        didSet { if album != oldValue { invalidateUploadFollowReview(); restoreUploadFollowDestination() } }
    }
    @Published var selection = Set<String>()
    var status: String { get { statusMessage.text } set { statusMessage = .verbatim(newValue) } }
    @Published var statusMessage = M("Conecte sua biblioteca para começar.")
    @Published var showUpload = false
    @Published var showManagement = false
    @Published var managementBusy = false
    @Published var managementModel: IMWorkspaceModel?
    private let managementSession = IMWorkspaceSessionCache()
    @Published var busy = false {
        didSet {
            if !busy && pendingNetworkChange {
                pendingNetworkChange = false
                networkChanged()
            }
        }
    }
    @Published var progress = 0.0
    @Published var resultsMessages: [String: PFMessage] = [:]
    var results: [String: String] {
        get { resultsMessages.mapValues(\.text) }
        set { resultsMessages = newValue.mapValues(PFMessage.verbatim) }
    }
    @Published var address = ""
    @Published var apiKey = "" {
        didSet { if apiKey != oldValue { verifiedUserID = nil; primaryAccountName = ""; resetConnection() } }
    }
    @Published var profile = ConnectionProfile()
    var connectionLabel: String { get { connectionLabelMessage.text } set { connectionLabelMessage = .verbatim(newValue) } }
    @Published var connectionLabelMessage = M("Conexão não testada")
    @Published private(set) var connectionIndicatorMessage = M("Conexão não testada")
    @Published var showConnectionSettings = false
    private let network = NetworkObserver()
    private var networkTask: Task<Void, Never>?
    private var pendingNetworkChange = false
    private var uploading = false
    private var verifiedUserID: String?

    @Published var connected = false
    @Published var serverReady = false
    @Published var connectionSaved = false
    @Published var allowCloud = true
    private var photosExportTask: Task<Void, Error>?
    private var activeExportID: UUID?
    private var activeExportProgress = 0.0
    @Published var stopRequested = false {
        didSet { if stopRequested { photosExportTask?.cancel() } }
    }
    @Published var scanning = false
    private var scanTask: Task<ExternalScanResult, Never>?
    @Published var sourceName: String? {
        didSet { if sourceName != oldValue { invalidateUploadFollowReview() } }
    }
    private var externalItems: [PhotoItem] = []
    private var scopedFolder: URL?
    private var folderScoped = false
    private var offset = 0
    private var fetched: PHFetchResult<PHAsset>?
    private var verifiedConnection = ""
    private let workspaceOverride: URL?
    private let uploadConcurrency: Int
    private let uploadClientFactory: (String, String) throws -> ImmichClient
    @Published private(set) var uploadMetrics: PFUploadMetrics?
    var uploadMetricsMessage: PFMessage? {
        guard let metrics = uploadMetrics else { return nil }
        let verified = metrics.completedItems == 1 ? M("1 item conferido") : M("\(metrics.completedItems) itens conferidos")
        let uploaded = metrics.uploadedResources == 1 ? M("1 recurso enviado") : M("\(metrics.uploadedResources) recursos enviados")
        let reused = metrics.reusedResources == 1 ? M("1 reutilizado") : M("\(metrics.reusedResources) reutilizados")
        return verified + " · " + uploaded + " · " + reused
    }
    private var workspace: URL {
        if let workspaceOverride { return workspaceOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PonteFotos", isDirectory: true)
    }
    @Published var edits: [String: MetadataOverride] = [:]
    @Published var editing: PhotoItem?
    @Published var inspectingMedia: PhotoItem?
    @Published var selectedTransferAccountID = "" {
        didSet { if selectedTransferAccountID != oldValue { invalidateUploadFollowReview() } }
    }
    @Published private(set) var transferAccounts: [IMAccount] = []
    @Published private(set) var transferConnection: PFTransferConnection?
    @Published private(set) var transferStatusMessage = M("Valide a conta para transferir.")
    @Published private(set) var networkRevision = 0
    private var additionalCredentials: [IMCredential] = []
    private let credentialLoader: (String) throws -> [IMCredential]
    private let transferResolver: (ConnectionProfile, IMCredential, Set<String>) async throws -> PFTransferConnection
    // Published account selection may change before SwiftUI runs its onChange hook.
    // Never expose the previous account's validated client during that interval.
    private var currentTransferConnection: PFTransferConnection? {
        guard let value = transferConnection, let credential = selectedTransferCredential,
              value.profile == profile, value.credential.key == credential.key,
              let actualID = UUID(uuidString: value.userID),
              let selectedID = UUID(uuidString: credential.account.id), actualID == selectedID else { return nil }
        return value
    }
    var transferAddress: String { currentTransferConnection?.address ?? "" }
    var transferKey: String { currentTransferConnection?.credential.key ?? "" }
    var transferReady: Bool { currentTransferConnection != nil }
    var transferAccountID: String? { currentTransferConnection?.credential.account.id }
    @Published private(set) var primaryAccountName = ""
    var primaryAccountLabel: String { primaryAccountName.isEmpty ? L("Conta principal") : primaryAccountName }
    // The primary API key and a saved management key can identify the same person.
    // Collapse only the menu presentation; their credentials and scopes stay separate.
    private var primaryTransferAccountUUID: UUID? { verifiedUserID.flatMap(UUID.init(uuidString:)) }
    var additionalTransferMenuAccounts: [IMAccount] {
        guard let primaryID = primaryTransferAccountUUID else { return transferAccounts }
        return transferAccounts.filter { UUID(uuidString: $0.id) != primaryID }
    }
    var primaryTransferMenuSelectionID: String {
        guard let primaryID = primaryTransferAccountUUID,
              UUID(uuidString: selectedTransferAccountID) == primaryID,
              additionalCredentials.contains(where: { $0.account.id == selectedTransferAccountID }) else { return "" }
        return selectedTransferAccountID
    }
    var transferAccountLabel: String {
        guard let credential = currentTransferConnection?.credential else { return L("Conta não validada") }
        return selectedTransferAccountID.isEmpty ? primaryAccountLabel : credential.account.displayName
    }
    private var selectedTransferCredential: IMCredential? {
        if selectedTransferAccountID.isEmpty {
            guard let id = verifiedUserID else { return nil }
            return IMCredential(account: IMAccount(id: id, name: primaryAccountName), key: apiKey)
        }
        return additionalCredentials.first { $0.account.id == selectedTransferAccountID }
    }
    func reloadTransferAccounts() {
        do {
            additionalCredentials = try credentialLoader(profile.id)
            transferAccounts = additionalCredentials.map(\.account).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            if !selectedTransferAccountID.isEmpty && !transferAccounts.contains(where: { $0.id == selectedTransferAccountID }) {
                selectedTransferAccountID = ""; resetTransferConnection()
            }
            if let current = transferConnection, current.credential.key != selectedTransferCredential?.key { resetTransferConnection() }
        } catch { resetTransferConnection(); transferStatusMessage = PFMessage.error(error) }
    }
    func resetTransferConnection() {
        invalidateUploadFollowReview()
        transferConnection = nil; remoteAlbums = []; remoteAlbumID = ""; albumStatusMessage = ""
        transferStatusMessage = M("Valide a conta para transferir.")
    }
    func transferAccountChanged() {
        guard !busy else { return }
        resetTransferConnection()
        Task { await testTransferConnection() }
    }
    func validateTransfer(requiredPermissions: Set<String>) async throws {
        guard let credential = selectedTransferCredential else {
            throw BridgeError(message: M("Teste a conexão principal ou selecione uma conta cadastrada."))
        }
        let selectionSnapshot = selectedTransferAccountID, profileSnapshot = profile, revision = networkRevision
        let resolved: PFTransferConnection
        do { resolved = try await transferResolver(profileSnapshot, credential, requiredPermissions) }
        catch {
            if selectionSnapshot == selectedTransferAccountID && profileSnapshot == profile {
                transferConnection = nil; transferStatusMessage = PFMessage.error(error)
            }
            throw error
        }
        guard selectionSnapshot == selectedTransferAccountID, profileSnapshot == profile,
              revision == networkRevision, selectedTransferCredential?.key == credential.key else {
            throw BridgeError(message: M("A conta ou a rede mudou durante a validação. Valide novamente."))
        }
        // Album choices belong to an account, not to its currently reachable address.
        if let previous = transferConnection, previous.credential.account.id != resolved.credential.account.id || previous.profileID != resolved.profileID {
            remoteAlbums = []; remoteAlbumID = ""
        }
        transferConnection = resolved
        reloadUploadFollows()
        transferStatusMessage = resolved.explanation
    }
    func testTransferConnection() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            reloadTransferAccounts()
            try await validateTransfer(requiredPermissions: [])
            await refreshAlbums(timeout: 5)
        } catch { resetTransferConnection(); transferStatusMessage = PFMessage.error(error) }
    }
    @Published var destination: UploadDestination = .timeline
    @Published var remoteAlbums: [ImmichAlbum] = []
    @Published var remoteAlbumID = ""
    @Published var newAlbumName = ""
    var albumStatus: String { get { albumStatusMessage.text } set { albumStatusMessage = .verbatim(newValue) } }
    @Published var albumStatusMessage: PFMessage = ""
    init(loadSavedState: Bool = true, observeNetwork: Bool = true, initialCredential: IMCredential? = nil,
         credentialLoader: @escaping (String) throws -> [IMCredential] = { try IMManagementStore.credentials(profileID: $0) },
         transferResolver: @escaping (ConnectionProfile, IMCredential, Set<String>) async throws -> PFTransferConnection = {
             try await PFTransferConnection.resolve(profile: $0, credential: $1, requiredPermissions: $2)
         }, workspaceOverride: URL? = nil, uploadConcurrency: Int = 2,
         uploadFollowStore: PFAlbumFollowStore? = nil,
         uploadFollowSource: ((String) throws -> [PhotoItem])? = nil,
         uploadClientFactory: @escaping (String, String) throws -> ImmichClient = { try ImmichClient(address: $0, key: $1) }) {
        self.uploadFollowSource = uploadFollowSource
        self.uploadFollowStore = uploadFollowStore ?? PFAlbumFollowDiskStore(root: (workspaceOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PonteFotos", isDirectory: true)).appendingPathComponent("upload-album-follow", isDirectory: true))
        self.workspaceOverride = workspaceOverride; self.uploadClientFactory = uploadClientFactory
        self.uploadConcurrency = max(1, min(2, uploadConcurrency))
        self.credentialLoader = credentialLoader; self.transferResolver = transferResolver
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PonteFotos/reviews.json")
        do {
            if loadSavedState, let connection = try ConnectionStore.load() {
                address = connection.address; apiKey = connection.key
                if let savedProfile = connection.profile { profile = savedProfile }
                else if !profile.recognizes(address: connection.address) {
                    profile.localAddress = connection.address; profile.mode = .local
                }
                verifiedUserID = connection.userID
                connectionSaved = true; statusMessage = M("Conexão salva carregada. Verificando a rede…")
            }
        } catch { statusMessage = PFMessage.error(error) }
        if let initialCredential { apiKey = initialCredential.key; verifiedUserID = initialCredential.account.id; primaryAccountName = initialCredential.account.name }
        if loadSavedState { edits = (try? JSONDecoder().decode([String: MetadataOverride].self, from: Data(contentsOf: url))) ?? [:] }
        network.onChange = { [weak self] in self?.networkChanged() }
        if observeNetwork { network.start() }
        showConnectionSettings = apiKey.isEmpty
        if connectionSaved { Task { await testConnection() } }
    }
    func saveConnection() {
        do {
            try profile.validate()
            try ConnectionStore.save(address: address, key: apiKey, profile: profile, userID: verifiedUserID)
            connectionSaved = true; statusMessage = M("URLs e chave salvas no Chaves do macOS.")
            Task { await testConnection() }
        }
        catch { statusMessage = PFMessage.error(error) }
    }
    func forgetConnection() {
        do { try ConnectionStore.remove(); connectionSaved = false; verifiedUserID = nil; profile.id = UUID().uuidString; resetConnection(); statusMessage = M("Conexão salva removida do Chaves. Os campos atuais permanecem até fechar.") }
        catch { statusMessage = PFMessage.error(error) }
    }
    @Published private(set) var uploadFollowLinks: [PFAlbumFollowLink] = []
    private let uploadFollowStore: PFAlbumFollowStore
    private let uploadFollowSource: ((String) throws -> [PhotoItem])?
    private var uploadFollowScope: String?
    private var uploadFollowReadFailed = false
    private var uploadFollowReview: PFUploadFollowContext?
    private var uploadFollowFingerprints: [String: String] = [:]
    var activeUploadFollow: PFAlbumFollowLink? {
        guard sourceName == nil, let scope = currentUploadFollowScope, scope == uploadFollowScope else { return nil }
        return uploadFollowLinks.first { $0.albumID == album }
    }
    private var currentUploadFollowScope: String? {
        guard let connection = currentTransferConnection else { return nil }
        return PFUploadFollowIdentity.scope(profileID: connection.profileID, userID: connection.userID)
    }
    private var currentUploadFollowContext: PFUploadFollowContext? {
        guard let scope = currentUploadFollowScope, let link = activeUploadFollow else { return nil }
        return PFUploadFollowContext(scope: scope, albumID: link.albumID, destinationID: link.destinationID, networkRevision: networkRevision)
    }
    var canStartUploadFollow: Bool {
        !busy && connected && sourceName == nil && album != "all" && albums.contains { $0.id == album }
            && transferReady && destination == .existing && remoteAlbums.contains { $0.id == remoteAlbumID }
            && activeUploadFollow == nil && !uploadFollowReadFailed
    }
    private var uploadFollowSelectionReady: Bool {
        guard let context = currentUploadFollowContext else { return true }
        guard uploadFollowReview == context, destination == .existing, remoteAlbumID == context.destinationID else { return false }
        return chosen.allSatisfy { uploadFollowFingerprints[$0.id] == uploadFollowFingerprint($0) }
    }
    private func uploadFollowFingerprint(_ item: PhotoItem) -> String {
        PFUploadFollowIdentity.fingerprint(id: item.id, modified: item.asset?.modificationDate, metadata: metadata(for: item), live: item.live,
            resources: item.resources.map { "\($0.type.rawValue):\($0.originalFilename):\($0.uniformTypeIdentifier)" })
    }
    private func invalidateUploadFollowReview() {
        if uploadFollowReview != nil { items = []; selection = []; fetched = nil; offset = 0 }
        uploadFollowReview = nil; uploadFollowFingerprints = [:]
    }
    private func reloadUploadFollows() {
        guard let scope = currentUploadFollowScope else { return }
        do {
            let links = try uploadFollowStore.load(scope: scope)
            if scope != uploadFollowScope { invalidateUploadFollowReview() }
            uploadFollowLinks = links; uploadFollowScope = scope; uploadFollowReadFailed = false
            restoreUploadFollowDestination()
        } catch {
            invalidateUploadFollowReview(); uploadFollowLinks = []; uploadFollowScope = scope; uploadFollowReadFailed = true
            statusMessage = PFMessage.error(error)
        }
    }
    private func restoreUploadFollowDestination() {
        guard let link = activeUploadFollow else { return }
        destination = .existing; remoteAlbumID = link.destinationID
    }
    func startUploadFollowing() {
        guard canStartUploadFollow, let scope = currentUploadFollowScope,
              let target = remoteAlbums.first(where: { $0.id == remoteAlbumID }) else { return }
        do {
            var links = uploadFollowLinks
            links.append(PFAlbumFollowLink(albumID: album, destinationID: target.id, destinationTitle: target.albumName, completed: [:], lastChecked: nil))
            try uploadFollowStore.save(links, scope: scope)
            uploadFollowLinks = links; uploadFollowScope = scope
            items = []; selection = []; fetched = nil; offset = 0; invalidateUploadFollowReview()
            statusMessage = M("Acompanhamento de envio salvo. Consulte as novidades para revisar antes de enviar.")
        } catch { statusMessage = PFMessage.error(error) }
    }
    func stopUploadFollowing() {
        guard !busy, activeUploadFollow != nil, let scope = currentUploadFollowScope else { return }
        do {
            let links = uploadFollowLinks.filter { $0.albumID != album }
            try uploadFollowStore.save(links, scope: scope)
            uploadFollowLinks = links; invalidateUploadFollowReview(); loadAlbum()
            statusMessage = M("Acompanhamento de envio removido. Fotos e histórico foram preservados.")
        } catch { statusMessage = PFMessage.error(error) }
    }
    private func readUploadFollowItems(_ id: String) throws -> [PhotoItem] {
        if let uploadFollowSource { return try uploadFollowSource(id) }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw BridgeError(message: M("O álbum de origem do Fotos está indisponível. Confira o acesso e consulte novamente."))
        }
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(in: collection, options: options)
        var rows: [PhotoItem] = []
        result.enumerateObjects { asset, _, _ in
            rows.append(PhotoItem(asset: asset, resources: PHAssetResource.assetResources(for: asset).filter { [.photo, .video, .pairedVideo, .alternatePhoto].contains($0.type) },
                metadata: CaptureMetadata(date: asset.creationDate, latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude, favorite: asset.isFavorite)))
        }
        return rows
    }
    func checkUploadFollow() async {
        guard !busy, connected, let context = currentUploadFollowContext, let link = activeUploadFollow else { return }
        busy = true; stopRequested = false; invalidateUploadFollowReview(); items = []; selection = []; fetched = nil; offset = 0
        defer { busy = false }
        do {
            try await validateTransfer(requiredPermissions: ["asset.read", "album.read"])
            guard currentUploadFollowContext == context, let connection = currentTransferConnection else {
                throw BridgeError(message: M("O acompanhamento de envio mudou. Consulte novamente antes de enviar."))
            }
            let client = try uploadClientFactory(connection.address, connection.credential.key)
            let albumIDs = try await client.uploadFollowAlbumAssetIDs(context.destinationID, userID: connection.userID)
            let source = try readUploadFollowItems(context.albumID)
            var queue: [PhotoItem] = [], fingerprints: [String: String] = [:]
            for (index, item) in source.enumerated() {
                try Task.checkCancellation()
                guard !stopRequested, currentUploadFollowContext == context else {
                    throw BridgeError(message: M("O acompanhamento de envio mudou. Consulte novamente antes de enviar."))
                }
                let fingerprint = uploadFollowFingerprint(item)
                var completed = false
                if link.completed[item.id] == fingerprint {
                    let file = ConnectionHistory.recordURL(directory: workspace.appendingPathComponent("history"), profileID: profile.id, userID: connection.userID, itemID: item.id)
                    let records = ConnectionHistory.load([file])
                    let expectedCount = item.external == nil ? item.resources.count : 1
                    if expectedCount > 0 && records.count == expectedCount && Set(records.map(\.resourceIndex)) == Set(0..<expectedCount) {
                        completed = true
                        let paired = records.first { record in item.resources.indices.contains(record.resourceIndex) && item.resources[record.resourceIndex].type == .pairedVideo }?.result.id
                        for record in records {
                            let isPair = item.resources.indices.contains(record.resourceIndex) && item.resources[record.resourceIndex].type == .pairedVideo
                            if !isPair && !albumIDs.contains(record.result.id) { completed = false; break }
                            guard try await client.matchesHistory(assetID: record.result.id, checksum: record.checksum, userID: connection.userID) else { completed = false; break }
                            let remote = try await client.info(record.result.id)
                            if !metadata(for: item).verify(remote, liveVideoID: item.resources.indices.contains(record.resourceIndex) && item.resources[record.resourceIndex].type == .photo ? paired : nil, isLiveMotion: isPair) { completed = false; break }
                        }
                    }
                }
                if !completed { queue.append(item); fingerprints[item.id] = fingerprint }
                statusMessage = M("Consultando novidades: \(index + 1) de \(source.count)…")
                await Task.yield()
            }
            guard !stopRequested, currentUploadFollowContext == context,
                  let index = uploadFollowLinks.firstIndex(where: { $0.albumID == context.albumID && $0.destinationID == context.destinationID }) else {
                throw BridgeError(message: M("O acompanhamento de envio mudou. Consulte novamente antes de enviar."))
            }
            var links = uploadFollowLinks; links[index].lastChecked = Date()
            try uploadFollowStore.save(links, scope: context.scope)
            uploadFollowLinks = links; items = queue; uploadFollowFingerprints = fingerprints; uploadFollowReview = context
            statusMessage = M("\(queue.count) itens para revisar antes do envio. Nada foi enviado automaticamente.")
        } catch { invalidateUploadFollowReview(); items = []; selection = []; statusMessage = PFMessage.error(error) }
    }
    private func validateUploadFollowBeforeSend(_ context: PFUploadFollowContext?) throws {
        guard let context else { return }
        guard currentUploadFollowContext == context, destination == .existing, remoteAlbumID == context.destinationID else {
            throw BridgeError(message: M("O acompanhamento de envio mudou. Consulte novamente antes de enviar."))
        }
        let latest = Dictionary(uniqueKeysWithValues: try readUploadFollowItems(context.albumID).map { ($0.id, uploadFollowFingerprint($0)) })
        guard chosen.allSatisfy({ latest[$0.id] == uploadFollowFingerprints[$0.id] }) else {
            throw BridgeError(message: M("O álbum do Fotos mudou. Consulte as novidades novamente antes de enviar."))
        }
    }
    private func completeUploadFollow(_ item: PhotoItem, context: PFUploadFollowContext?, targetAlbumID: String?) throws {
        guard let context else { return }
        guard currentUploadFollowContext == context, targetAlbumID == context.destinationID,
              let expected = uploadFollowFingerprints[item.id], expected == uploadFollowFingerprint(item),
              let index = uploadFollowLinks.firstIndex(where: { $0.albumID == context.albumID && $0.destinationID == context.destinationID }) else {
            throw BridgeError(message: M("O acompanhamento de envio mudou. Consulte novamente antes de enviar."))
        }
        var links = uploadFollowLinks; links[index].completed[item.id] = expected
        try uploadFollowStore.save(links, scope: context.scope)
        uploadFollowLinks = links; selection.remove(item.id)
    }
    func reviewSelection() {
        guard let item = items.first(where: { selection.contains($0.id) }) else { statusMessage = M("Selecione uma foto para revisar."); return }
        editing = item
    }
    func metadata(for item: PhotoItem) -> CaptureMetadata { edits[item.id]?.applying(to: item.metadata) ?? item.metadata }
    var chosen: [PhotoItem] {
        items.filter { selection.contains($0.id) }.map { PhotoItem(asset: $0.asset, resources: $0.resources, metadata: metadata(for: $0), external: $0.external) }
    }
    func saveReview(_ edit: MetadataOverride?, id: String) throws {
        var updated = edits
        updated[id] = edit?.hasChanges == true ? edit : nil
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = workspace.appendingPathComponent("reviews.json")
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        edits = updated; resultsMessages[id] = M("Revisão salva · pronta para enviar")
    }
    func resetConnection() {
        resetTransferConnection()
        serverReady = false; verifiedConnection = ""; remoteAlbums = []; remoteAlbumID = ""; albumStatusMessage = ""; connectionLabelMessage = M("Conexão não testada")
    }
    var destinationLabel: String {
        switch destination {
        case .timeline: return L("Rolo da câmera, sem adicionar a álbum")
        case .existing: return remoteAlbums.first(where: { $0.id == remoteAlbumID })?.albumName ?? L("Escolha um álbum")
        case .new: return L("Novo álbum: \(newAlbumName)")
        }
    }
    var canSend: Bool {
        uploadFollowSelectionReady && !selection.isEmpty && chosen.allSatisfy { $0.metadata.date != nil } && transferReady && (destination == .timeline || destination == .existing && !remoteAlbumID.isEmpty || destination == .new && !newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    func refreshAlbums(timeout: TimeInterval = 15) async {
        do {
            guard transferReady else { return }
            remoteAlbums = try await ImmichClient(address: transferAddress, key: transferKey).albums(timeout: timeout)
            if let link = activeUploadFollow { destination = .existing; remoteAlbumID = link.destinationID }
            else if !remoteAlbums.contains(where: { $0.id == remoteAlbumID }) { remoteAlbumID = remoteAlbums.first?.id ?? "" }
            albumStatusMessage = remoteAlbums.isEmpty ? M("Nenhum álbum disponível. Você pode criar um.") : M("\(remoteAlbums.count) álbuns disponíveis")
        } catch { remoteAlbums = []; remoteAlbumID = ""; albumStatusMessage = M("Não foi possível listar álbuns: \(PFMessage.error(error))") }
    }
    func cancelScan() { scanTask?.cancel() }
    func chooseFolder(on volume: ExternalVolume? = nil) async {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = L("Ler fotos e vídeos"); panel.message = L("Escolha a pasta a analisar. Os arquivos de origem não serão alterados.")
        panel.directoryURL = volume?.url
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        busy = true; stopRequested = false; progress = 0; statusMessage = M("Analisando arquivos e metadados de \(folder.lastPathComponent)…")
        defer { busy = false }
        if folderScoped { scopedFolder?.stopAccessingSecurityScopedResource() }
        scopedFolder = folder; folderScoped = folder.startAccessingSecurityScopedResource()
        fetched = nil; sourceName = folder.lastPathComponent; items = []; externalItems = []; selection = []; offset = 0
        scanning = true
        let task = Task { await ExternalReader.scan(folder) }; scanTask = task
        let result = await task.value
        scanTask = nil; scanning = false
        guard !task.isCancelled, !Task.isCancelled else {
            statusMessage = M("Análise cancelada. Analise a pasta novamente antes de enviar."); return
        }
        externalItems = result.media.map { PhotoItem(asset: nil, resources: [], metadata: $0.metadata, external: $0) }
        loadMore()
        let missing = externalItems.filter { $0.metadata.date == nil }.count
        statusMessage = M("\(externalItems.count) arquivos encontrados · \(missing) sem data de captura · \(result.issues) arquivos/pastas não lidos. Revise antes de enviar.")
    }
    func connectLibrary() async {
        busy = true; statusMessage = M("Abrindo biblioteca do Fotos…"); defer { busy = false }
        let authorization: PHAuthorizationStatus
        do {
            let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if current == .notDetermined {
                authorization = try await PFPhotosAuthorization.request { completion in
                    PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: completion)
                }
            } else { authorization = current }
        } catch { statusMessage = PFMessage.error(error); return }
        guard authorization == .authorized || authorization == .limited else {
            statusMessage = M("Acesso ao Fotos não autorizado. Libere Ponte Fotos em Ajustes do Sistema → Privacidade e Segurança → Fotos."); return
        }
        if folderScoped { scopedFolder?.stopAccessingSecurityScopedResource(); folderScoped = false }
        sourceName = nil; externalItems = []
        connected = true
        albums = [AlbumItem(id: "all", title: "", collection: nil, fallback: M("Todas as fotos"))]
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            self.albums.append(AlbumItem(id: collection.localIdentifier, title: collection.localizedTitle ?? "", collection: collection, fallback: collection.localizedTitle == nil ? M("Álbum") : nil))
        }
        loadAlbum()
    }
    func loadAlbum() {
        guard sourceName == nil, connected else { return }
        selection = []; items = []; offset = 0
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let collection = albums.first(where: { $0.id == album })?.collection {
            fetched = PHAsset.fetchAssets(in: collection, options: options)
        } else { fetched = PHAsset.fetchAssets(with: options) }
        restoreUploadFollowDestination()
        if activeUploadFollow != nil {
            fetched = nil
            statusMessage = M("Consulte as novidades do álbum acompanhado antes de enviar.")
        } else { loadMore() }
    }
    func loadMore() {
        if sourceName != nil {
            let end = min(offset + 100, externalItems.count)
            if end > offset { items.append(contentsOf: externalItems[offset..<end]) }
            offset = end; statusMessage = M("\(items.count) de \(externalItems.count) arquivos carregados.")
            return
        }
        guard let fetched else { return }
        let end = min(offset + 100, fetched.count)
        for index in offset..<end {
            let a = fetched.object(at: index)
            items.append(PhotoItem(asset: a, resources: PHAssetResource.assetResources(for: a).filter { [.photo, .video, .pairedVideo, .alternatePhoto].contains($0.type) }, metadata: CaptureMetadata(date: a.creationDate, latitude: a.location?.coordinate.latitude, longitude: a.location?.coordinate.longitude, favorite: a.isFavorite)))
        }
        offset = end; statusMessage = M("\(items.count) de \(fetched.count) itens carregados. Selecione um lote pequeno para o primeiro teste.")
    }
    @discardableResult func prepareManagementSession() -> IMWorkspaceModel? {
        guard !busy else { return nil }
        let readyModel = managementSession.prepare(address: address, primaryKey: apiKey, profileID: profile.id, ready: serverReady, onBusyChanged: { [weak self] active in
            self?.managementBusy = active; self?.busy = active
        })
        managementModel = managementSession.current
        readyModel?.load()
        return readyModel
    }
    func openManagement() {
        guard prepareManagementSession() != nil else { return }
        showManagement = true
    }
    func connectionSettingsChanged(previous: ConnectionProfile) {
        guard !busy else { return }
        resetConnection()
        if previous.mode != profile.mode, !apiKey.isEmpty { Task { await testConnection() } }
    }
    private func networkChanged() {
        guard !apiKey.isEmpty || !selectedTransferAccountID.isEmpty else { return }
        if busy {
            pendingNetworkChange = true
            networkRevision += 1
            if uploading { stopRequested = true; connectionLabelMessage = M("Rede mudou · pausa após este item") }
            return
        }
        networkRevision += 1
        resetConnection()
        connectionLabelMessage = M("Rede mudou · verificando conexão…")
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            if self.busy { self.pendingNetworkChange = true; return }
            if !self.apiKey.isEmpty { await self.testConnection() }
            if !self.selectedTransferAccountID.isEmpty && !self.transferReady { await self.testTransferConnection() }
        }
    }
    func testConnection() async {
        guard !busy else { return }
        busy = true; resetConnection(); connectionLabelMessage = M("Verificando conexão…")
        defer { busy = false }
        do {
            let resolution = try await ConnectionResolver.resolve(profile: profile, key: apiKey, expectedUserID: verifiedUserID)
            address = resolution.candidate.address
            verifiedUserID = resolution.identity.userID
            verifiedConnection = address + "\n" + apiKey
            serverReady = true
            connectionLabelMessage = resolution.reason
            connectionIndicatorMessage = M(resolution.candidate.kind == "Local" ? "URL local" : "URL remota")
            statusMessage = M("Conexão com \(resolution.identity.serverVersion) OK.")
            if connectionSaved {
                try ConnectionStore.save(address: address, key: apiKey, profile: profile, userID: resolution.identity.userID)
            }
            reloadTransferAccounts()
            struct NamedUser: Decodable { let id: String; let name: String? }
            let primary = IMCredential(account: IMAccount(id: resolution.identity.userID, name: ""), key: apiKey)
            if let data = try? await IMClient(address: address, credential: primary).data("users/me", timeout: 5),
               let user = try? JSONDecoder().decode(NamedUser.self, from: data),
               user.id.lowercased() == resolution.identity.userID {
                primaryAccountName = user.name ?? ""
            }
            do {
                if selectedTransferAccountID.isEmpty {
                    // Reuse the identity probe just completed for the primary connection.
                    let credential = IMCredential(account: IMAccount(id: resolution.identity.userID, name: primaryAccountName), key: apiKey)
                    transferConnection = PFTransferConnection(profile: profile, credential: credential, resolution: resolution)
                    transferStatusMessage = resolution.reason
                } else {
                    try await validateTransfer(requiredPermissions: [])
                }
                await refreshAlbums(timeout: 5)
            } catch { resetTransferConnection(); transferStatusMessage = PFMessage.error(error) }
        } catch {
            resetConnection(); connectionLabelMessage = M("Sem conexão verificada"); statusMessage = PFMessage.error(error)
        }
    }
    func exportResource(_ resource: PHAssetResource, to url: URL) async throws {
        let exportID = UUID(), name = resource.originalFilename
        activeExportID = exportID
        activeExportProgress = 0
        statusMessage = M("Exportando original do Fotos: \(name)…")
        let cloud = allowCloud
        let task = Task { [weak self] in
            try await TransferFileIO.exportPhotosResource(resource, to: url, allowCloud: cloud) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.activeExportID == exportID, fraction > self.activeExportProgress else { return }
                    self.activeExportProgress = fraction
                    self.statusMessage = M("Baixando do iCloud: \(name) · \(Int(fraction * 100))%")
                }
            }
        }
        photosExportTask = task
        defer {
            if activeExportID == exportID { activeExportID = nil; photosExportTask = nil }
        }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    func prepare(_ item: PhotoItem, root: URL) async throws -> [(Int, ResourceDescriptor, URL, URL)] {
        guard item.metadata.date != nil else { throw BridgeError(message: M("Sem data de captura: preencha na revisão antes de enviar.")) }
        if let external = item.external {
            let folder = root.appendingPathComponent(item.id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if external.pairedVideo != nil { try ExternalReader.validateSidecars(external) }
            let sources = [(external.url, external.isVideo ? PHAssetResourceType.video : .photo, external.sidecar)] +
                (external.pairedVideo.map { [($0, PHAssetResourceType.pairedVideo, external.pairedSidecar)] } ?? [])
            var files: [(Int, ResourceDescriptor, URL, URL)] = []
            for (index, source) in sources.enumerated() {
                let resourceFolder = folder.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: resourceFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = resourceFolder.appendingPathComponent(source.0.lastPathComponent)
                try await TransferFileIO.copyOriginal(from: source.0, to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let xmp = file.appendingPathExtension("xmp")
                try ExternalReader.mergedXMP(item.metadata, sidecar: source.2).write(to: xmp, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: xmp.path)
                files.append((index, ResourceDescriptor(type: source.1, originalFilename: source.0.lastPathComponent), file, xmp))
            }
            if external.pairedVideo != nil {
                try ExternalReader.validateSidecars(external)
                try await ExternalReader.validateStagedPair(image: files[0].2, video: files[1].2, identifier: external.liveIdentifier, imageChecksum: external.contentChecksum, videoChecksum: external.pairedChecksum)
            }
            return files
        }
        guard !item.resources.isEmpty else { throw BridgeError(message: M("Nenhum recurso original disponível.")) }
        if item.live && !item.resources.contains(where: { $0.type == .pairedVideo }) { throw BridgeError(message: M("Live Photo sem vídeo original disponível. Envio interrompido.")) }
        let folder = root.appendingPathComponent(item.id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var files: [(Int, ResourceDescriptor, URL, URL)] = []
        for (index, resource) in item.resources.enumerated() {
            let resourceFolder = folder.appendingPathComponent(String(index), isDirectory: true)
            try FileManager.default.createDirectory(at: resourceFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = URL(fileURLWithPath: resource.originalFilename).lastPathComponent
            let file = resourceFolder.appendingPathComponent(name)
            statusMessage = M("Preparando \(name)…")
            try await exportResource(resource, to: file)
            let xmp = file.appendingPathExtension("xmp")
            try Data(item.metadata.xmp().utf8).write(to: xmp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: xmp.path)
            files.append((index, ResourceDescriptor(type: resource.type, originalFilename: resource.originalFilename), file, xmp))
        }
        try JSONEncoder().encode(item.metadata).write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
        return files
    }
    func exportSelected() async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = L("Exportar aqui")
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let root = parent.appendingPathComponent("Ponte-Fotos-\(UUID().uuidString.prefix(8))")
        busy = true; stopRequested = false; progress = 0; defer { busy = false }
        let batch = chosen
        for (index, item) in batch.enumerated() {
            if stopRequested { break }
            do { _ = try await prepare(item, root: root); resultsMessages[item.id] = M("Exportado com XMP") }
            catch { resultsMessages[item.id] = PFMessage.error(error) }
            progress = Double(index + 1) / Double(batch.count)
        }
        statusMessage = M("Exportação finalizada. Arquivos em \(root.path)")
        NSWorkspace.shared.open(root)
    }
    func sendSelected() async {
        guard canSend, transferReady else { statusMessage = M("Teste a conexão antes de enviar."); return }
        let followContext = uploadFollowReview
        busy = true; uploading = true; progress = 0; stopRequested = false
        uploadMetrics = PFUploadMetrics()
        defer { uploading = false; busy = false }
        do {
            let permissions = PFTransferConnection.uploadPermissions(addingToAlbum: destination != .timeline, creatingAlbum: destination == .new, applyingReview: chosen.contains { edits[$0.id]?.hasChanges == true })
            try await validateTransfer(requiredPermissions: permissions)
            guard let resolved = transferConnection else { throw BridgeError(message: M("Valide a conta para transferir.")) }
            try validateUploadFollowBeforeSend(followContext)
            // Freeze endpoint, account and key through every resource in this batch.
            let client = try uploadClientFactory(resolved.address, resolved.credential.key)
            let userID = resolved.userID
            let transferProfile = profile
            var targetAlbumID: String?
            if destination == .existing {
                guard remoteAlbums.contains(where: { $0.id == remoteAlbumID }) else { throw BridgeError(message: M("Atualize e selecione um álbum de destino.")) }
                targetAlbumID = remoteAlbumID
            } else if destination == .new {
                let album = try await client.createAlbum(newAlbumName)
                remoteAlbums.append(album); remoteAlbumID = album.id
                destination = .existing; targetAlbumID = album.id
            }
            let staging = workspace.appendingPathComponent("staging", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            let history = workspace.appendingPathComponent("history", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Only this batch's staging is owned here. Never remove older staging or originals.
            defer { try? FileManager.default.removeItem(at: staging) }
            var scheduledIDs: Set<String> = []
            let batch = chosen.filter { scheduledIDs.insert($0.id).inserted }
            var nextPosition = 0
            while nextPosition < batch.count && !stopRequested {
                var window: [PFPreparedUploadItem] = []
                var windowBytes: Int64 = 0
                // At most 8 complete media items and 128 MiB before the last item.
                // A single large media item is never split merely to meet the window target.
                while nextPosition < batch.count && window.count < 8 && windowBytes < 128 * 1024 * 1024 && !stopRequested {
                    let position = nextPosition
                    let item = batch[position]
                    resultsMessages[item.id] = M("Preparando…")
                    let started = ProcessInfo.processInfo.systemUptime
                    do {
                        _ = try PFUploadFileIO.checkCapacity(fileSizes: [], availableBytes: PFUploadFileIO.availableCapacity(at: staging))
                        let files = try await prepare(item, root: staging)
                        var resources: [PFPreparedUploadResource] = []
                        for (index, resource, file, sidecar) in files {
                            statusMessage = M("Calculando hash de \(resource.originalFilename)…")
                            let checksum = try await TransferFileIO.checksum(file)
                            let bytes = try PFUploadFileIO.size(of: file)
                            let (sum, overflow) = windowBytes.addingReportingOverflow(bytes)
                            guard !overflow else { throw BridgeError(message: M("O tamanho dos arquivos excede o limite suportado.")) }
                            windowBytes = sum
                            resources.append(PFPreparedUploadResource(index: index, resource: resource, file: file, sidecar: sidecar, checksum: checksum, bytes: bytes, token: "\(position):\(index)"))
                        }
                        var multipartBytes: Int64 = 0
                        for resource in resources {
                            for size in [resource.bytes, try PFUploadFileIO.size(of: resource.sidecar), 65_536] {
                                let sum = multipartBytes.addingReportingOverflow(size)
                                guard !sum.overflow else { throw BridgeError(message: M("O tamanho dos arquivos excede o limite suportado.")) }
                                multipartBytes = sum.partialValue
                            }
                        }
                        window.append(PFPreparedUploadItem(position: position, item: item, resources: resources, folder: staging.appendingPathComponent(item.id.replacingOccurrences(of: "/", with: "_")), multipartBytes: multipartBytes))
                        uploadMetrics?.preparationSeconds += ProcessInfo.processInfo.systemUptime - started
                        nextPosition += 1
                        // Start sending a ready video/Live unit immediately instead of
                        // waiting for the remaining preparation window (and iCloud).
                        if item.live || item.external?.isVideo == true || item.resources.contains(where: { $0.type == .video }) { break }
                    } catch {
                        if stopRequested && error is CancellationError {
                            resultsMessages[item.id] = M("Preparação pausada. O original não foi enviado.")
                            break
                        }
                        resultsMessages[item.id] = M("Falha: \(PFMessage.error(error))")
                        stopRequested = true
                    }
                }
                uploadMetrics?.preparedBytes += windowBytes
                if stopRequested { break }
                let candidates = window.filter { !$0.item.live }.flatMap { $0.resources }.filter { $0.resource.type == .photo }.map { PFUploadCheckInput(token: $0.token, checksum: $0.checksum) }
                statusMessage = M("Consultando arquivos existentes por hash…")
                let lookupStarted = ProcessInfo.processInfo.systemUptime
                let duplicates = try await client.bulkUploadCheck(candidates)
                uploadMetrics?.lookupSeconds += ProcessInfo.processInfo.systemUptime - lookupStarted
                uploadMetrics?.lookupRequests += (candidates.count + 199) / 200
                let windowKeys = Set(window.flatMap { $0.resources.map(\.checksum) })
                await PFBoundedUploadScheduler.run(items: window, limit: uploadConcurrency,
                    resourceKeys: { prepared in
                        // Large multipart units run alone. Two small units stay within the
                        // existing temporary-space reserve; originals are never split.
                        prepared.multipartBytes > 16 * 1024 * 1024 ? windowKeys : Set(prepared.resources.map(\.checksum))
                    }, shouldPause: { self.stopRequested }, operation: { prepared in
                        await self.uploadPreparedItem(prepared, client: client, userID: userID,
                            transferProfile: transferProfile, resolvedAddress: resolved.address,
                            history: history, targetAlbumID: targetAlbumID, duplicates: duplicates, followContext: followContext)
                    }, onComplete: { _ in
                        self.uploadMetrics?.processedItems += 1
                        withAnimation { self.progress = Double(self.uploadMetrics?.processedItems ?? 0) / Double(batch.count) }
                    })
            }
            statusMessage = stopRequested ? M("Pausado entre itens. Selecione o lote e envie para retomar.") : M("Lote finalizado. Confira os resultados de cada foto.")
        } catch { statusMessage = PFMessage.error(error) }
    }
    private func uploadPreparedItem(_ prepared: PFPreparedUploadItem, client: ImmichClient,
        userID: String, transferProfile: ConnectionProfile, resolvedAddress: String,
        history: URL, targetAlbumID: String?, duplicates: [String: PFUploadCheckCandidate]?, followContext: PFUploadFollowContext?) async {
        let item = prepared.item, folder = prepared.folder
        do {
            let recordURL = ConnectionHistory.recordURL(directory: history, profileID: transferProfile.id, userID: userID, itemID: item.id)
            let legacy = ConnectionHistory.legacyURLs(directory: history, addresses: [transferProfile.localAddress, transferProfile.remoteAddress, resolvedAddress], itemID: item.id)
            var records = ConnectionHistory.load([recordURL] + legacy)
            var videoID: String?
            var allVerified = true
            var albumAssetIDs: [String] = []
            // The paired video must exist before associating the still image.
            let ordered = prepared.resources.sorted { ($0.resource.type == .pairedVideo ? 0 : 1) < ($1.resource.type == .pairedVideo ? 0 : 1) }
            for preparedResource in ordered {
                let index = preparedResource.index, resource = preparedResource.resource
                let file = preparedResource.file, xmp = preparedResource.sidecar, checksum = preparedResource.checksum
                if duplicates?[preparedResource.token]?.isTrashed == true { throw PFUploadCheckError.rejectedResource }
                var result: UploadResult
                if let previous = records.first(where: { $0.resourceIndex == index && $0.checksum == checksum }), try await client.matchesHistory(assetID: previous.result.id, checksum: checksum, userID: userID, liveVideoID: resource.type == .photo ? videoID : nil) {
                    result = previous.result
                    try ConnectionHistory.save(records, to: recordURL)
                    uploadMetrics?.reusedResources += 1
                } else if !item.live && resource.type == .photo, let candidate = duplicates?[preparedResource.token],
                          try await client.verifyUploadCandidate(candidate, checksum: checksum, userID: userID) {
                    result = UploadResult(id: candidate.assetID, status: "duplicate")
                    records.removeAll { $0.resourceIndex == index }
                    records.append(TransferRecord(resourceIndex: index, checksum: checksum, result: result))
                    try ConnectionHistory.save(records, to: recordURL)
                    uploadMetrics?.reusedResources += 1
                } else {
                    statusMessage = M("Enviando \(resource.originalFilename)…")
                    let started = ProcessInfo.processInfo.systemUptime
                    result = try await client.upload(file: file, sidecar: xmp, metadata: item.metadata, liveVideoID: resource.type == .photo ? videoID : nil, checksum: checksum, isLiveMotion: resource.type == .pairedVideo)
                    uploadMetrics?.transferSeconds += ProcessInfo.processInfo.systemUptime - started
                    if result.status == "duplicate" {
                        guard try await client.matchesHistory(assetID: result.id, checksum: checksum, userID: userID, liveVideoID: resource.type == .photo ? videoID : nil) else {
                            throw BridgeError(message: M("O arquivo existente está na lixeira ou indisponível no Immich. Revise antes de continuar."))
                        }
                    }
                    if result.status == "duplicate" { uploadMetrics?.reusedResources += 1 }
                    else { uploadMetrics?.uploadedResources += 1; uploadMetrics?.uploadedBytes += preparedResource.bytes }
                    records.removeAll { $0.resourceIndex == index }
                    records.append(TransferRecord(resourceIndex: index, checksum: checksum, result: result))
                    try JSONEncoder().encode(records).write(to: recordURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
                }
                if let edit = edits[item.id], edit.hasChanges {
                    statusMessage = M("Aplicando sua revisão no Immich…")
                    try await client.applyReview(edit, to: result.id)
                }
                if resource.type != .pairedVideo { albumAssetIDs.append(result.id) }
                if resource.type == .pairedVideo { videoID = result.id }
                statusMessage = M("Conferindo data, localização e associação…")
                var verified = false
                let verificationStarted = ProcessInfo.processInfo.systemUptime
                for attempt in 0..<6 {
                    let remote = try await client.info(result.id)
                    if item.metadata.verify(remote, liveVideoID: resource.type == .photo ? videoID : nil, isLiveMotion: resource.type == .pairedVideo) { verified = true; break }
                    if attempt < 5 { try await Task.sleep(nanoseconds: 2_000_000_000) }
                }
                uploadMetrics?.verificationSeconds += ProcessInfo.processInfo.systemUptime - verificationStarted
                if !verified { allVerified = false }
            }
            if let targetAlbumID {
                statusMessage = M("Adicionando ao álbum…")
                try await client.addToAlbum(targetAlbumID, assetIDs: albumAssetIDs)
            }
            let checked = M("Data conferida") + (item.metadata.latitude != nil ? M(" · GPS conferido") : M(" · sem GPS informado")) + (item.live ? M(" · Live conferido") : "")
            if allVerified {
                try completeUploadFollow(item, context: followContext, targetAlbumID: targetAlbumID)
                uploadMetrics?.completedItems += 1
            }
            resultsMessages[item.id] = (allVerified ? checked : M("Enviado/existente · conferência pendente ou divergente")) + (targetAlbumID != nil ? M(" · no álbum") : "")
        } catch {
            resultsMessages[item.id] = M("Falha: \(PFMessage.error(error))")
            // A failed resource may already exist remotely; pause rather than replay blindly.
            stopRequested = true; pendingNetworkChange = true
        }
        try? FileManager.default.removeItem(at: folder)
    }

}

@MainActor final class ThumbnailModel: ObservableObject { @Published var image: NSImage? }
struct PhotoThumbnail: View {
    @ObservedObject private var localization = PFLocalization.shared
    let item: PhotoItem
    @StateObject private var thumbnail = ThumbnailModel()
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
            if let image = thumbnail.image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.frame(width: 68, height: 68).clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: item.id) {
            if let external = item.external {
                if external.isVideo {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: external.url)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 136, height: 136)
                    if let result = try? await generator.image(at: .zero) { thumbnail.image = NSImage(cgImage: result.image, size: .zero) }
                } else if let source = CGImageSourceCreateWithURL(external.url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 136, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) { thumbnail.image = NSImage(cgImage: image, size: .zero) }
                return
            }
            guard let asset = item.asset else { return }
            let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 136, height: 136), contentMode: .aspectFill, options: options) { image, _ in
                Task { @MainActor in thumbnail.image = image }
            }
        }
    }
}
enum AppBrand {
    static let logo: NSImage = {
        if let url = Bundle.main.url(forResource: "AppLogoDisplay", withExtension: "png"),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            // Keep the full-resolution bitmap; logical points must not become pixels.
            return NSImage(cgImage: bitmap, size: NSSize(width: 38, height: 38))
        }
        return NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Ponte Fotos")!
    }()
}
extension Notification.Name { static let pfOpenSettings = Notification.Name("PonteFotos.openSettings") }
@MainActor final class PFNavigationState: ObservableObject {
    @Published var settings = false
    @Published var reverse = false
    @Published var showingUploadFollow = false
}

struct ContentView: View {
    @ObservedObject private var localization = PFLocalization.shared
    @StateObject private var model = LibraryModel()
    @StateObject private var volumes = VolumeMonitor()
    @StateObject private var navigation = PFNavigationState()
    @StateObject private var reverseImport = PFReverseImportModel()
    @AppStorage(PFAppearance.themeKey) private var themeRaw = PFColorTheme.system.rawValue
    @AppStorage(PFAppearance.glassKey) private var glassEnabled = true
    private var selectedTheme: PFColorTheme { PFColorTheme(rawValue: themeRaw) ?? .system }
    private var workspace: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                pageHeader.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
                if navigation.settings {
                    PFSettingsView(model: model, themeRaw: $themeRaw, glassEnabled: $glassEnabled)
                } else if navigation.reverse {
                    PFReverseImportView(model: reverseImport, connection: model, configure: { navigation.settings = true })
                } else {
                    HStack(alignment: .top, spacing: 16) { sourcePanel; destinationPanel }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24).padding(.bottom, 18)
                    libraryPanel.padding(.horizontal, 24).padding(.bottom, 16)
                    footer
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var body: some View {
        workspace
        .background(PFTheme.background).tint(PFTheme.accent)
        .environment(\.pfGlassEnabled, glassEnabled)
        .environment(\.locale, PFLocalization.locale)
        .onAppear { PFAppearanceController.apply(selectedTheme) }
        .onChange(of: themeRaw) { _, _ in PFAppearanceController.apply(selectedTheme) }
        .frame(minWidth: 900, minHeight: 650)
        .onChange(of: model.profile) { previous, _ in reverseImport.invalidate(); model.connectionSettingsChanged(previous: previous); model.prepareManagementSession() }
        .onChange(of: model.selectedTransferAccountID) { _, _ in reverseImport.invalidate(); model.transferAccountChanged() }
        .onChange(of: model.networkRevision) { _, _ in reverseImport.requestPauseAfterItem() }
        .onChange(of: model.apiKey) { _, _ in reverseImport.invalidate(); model.prepareManagementSession() }
        .onChange(of: model.address) { _, _ in reverseImport.invalidate(); model.prepareManagementSession() }
        .onChange(of: model.serverReady) { _, ready in if !ready { reverseImport.invalidate() }; model.prepareManagementSession() }
        .onChange(of: model.busy) { _, busy in if !busy { model.prepareManagementSession(); model.reloadTransferAccounts() } }
        .onChange(of: reverseImport.busy || reverseImport.importing) { _, active in model.busy = active }
        .onChange(of: navigation.settings) { _, open in
            if open { navigation.reverse = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pfOpenSettings)) { _ in
            if !model.busy { navigation.settings = true }
        }
        .sheet(item: $model.inspectingMedia) { item in
            PFMediaDiagnosticsView(item: item, model: model)
        }
        .sheet(item: $model.editing) { item in
            ReviewEditor(item: item, metadata: model.metadata(for: item), save: { try model.saveReview($0, id: item.id) }, restore: { try model.saveReview(nil, id: item.id) }, dismiss: { model.editing = nil })
                .environment(\.pfGlassEnabled, glassEnabled)
        .environment(\.locale, PFLocalization.locale)
        }
        .sheet(isPresented: $model.showManagement, onDismiss: { model.managementModel?.endReview() }) {
            if let workspace = model.managementModel {
                ImmichWorkspaceView(model: workspace, address: model.address, connectionReady: model.serverReady)
                    .disabled(model.busy && !model.managementBusy)
                    .interactiveDismissDisabled(model.managementBusy)
                        .environment(\.pfGlassEnabled, glassEnabled)
        .environment(\.locale, PFLocalization.locale)
            }
        }
        .confirmationDialog(L("Enviar \(model.selection.count) itens para o Immich?"), isPresented: $model.showUpload, titleVisibility: .visible) {
            Button(L("Enviar com originais e XMP")) { Task { await model.sendSelected() } }
        } message: {
            Text(L("Destino: \(model.transferAddress) · \(model.transferAccountLabel) → \(model.destinationLabel). Live Photos incluem vídeo; RAW inclui os recursos originais disponíveis. Revisões manuais salvas serão aplicadas também às fotos já existentes no Immich. A prévia mostra horários no fuso deste Mac; o fuso histórico da captura ainda precisa de validação."))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: AppBrand.logo).resizable().interpolation(.high).scaledToFit().frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ponte Fotos").font(.system(size: 16, weight: .semibold))
                    Text(L("Sua biblioteca, conectada.")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 28)
            Text(L("BIBLIOTECA")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
            sidebarAction(L("Fotos da Apple"), icon: "photo.stack", selected: !navigation.settings && !navigation.reverse && model.connected && model.sourceName == nil) { navigation.settings = false; navigation.reverse = false; Task { await model.connectLibrary() } }.disabled(model.busy)
            sidebarAction(L("Discos e pastas"), icon: "folder", selected: !navigation.settings && !navigation.reverse && model.sourceName != nil) { navigation.settings = false; navigation.reverse = false; Task { await model.chooseFolder() } }.disabled(model.busy)
            Divider().padding(.vertical, 18)
            Text("IMMICH").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
            sidebarAction(L("Immich → Fotos"), icon: "square.and.arrow.down", selected: navigation.reverse && !navigation.settings) {
                navigation.settings = false; navigation.reverse = true
            }.disabled(model.busy)
                .help(L("Trazer originais do Immich para a biblioteca do Fotos da Apple"))
            sidebarAction(L("Gerenciar biblioteca"), icon: "square.grid.2x2") { model.openManagement() }
                .disabled(model.busy || !model.serverReady)
                .help(model.serverReady ? L("Duplicatas, álbuns, pessoas e histórico") : L("Teste a conexão para gerenciar o Immich"))
            HStack {
                Text(L("DISPOSITIVOS")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { volumes.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help(L("Atualizar dispositivos")).accessibilityLabel(L("Atualizar dispositivos"))
            }.padding(.horizontal, 10).padding(.top, 28).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if volumes.volumes.isEmpty {
                        Text(L("Os discos conectados\naparecem aqui.")).font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(volumes.volumes) { volume in
                        sidebarAction(volume.name, icon: "externaldrive") { navigation.settings = false; navigation.reverse = false; Task { await model.chooseFolder(on: volume) } }.disabled(model.busy)
                    }
                }
            }
            Spacer(minLength: 16)
            sidebarAction(L("Configurações"), icon: "gearshape", selected: navigation.settings) { navigation.settings = true }.disabled(model.busy)
            PFTransferAccountPicker(model: model).padding(.top, 6)
            Divider().padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 8) {
                Label(L("Originais preservados"), systemImage: "checkmark.shield").font(.caption.weight(.medium))
                Text(L("Live Photos, RAW e metadados\nacompanham suas memórias.")).font(.caption).foregroundStyle(.secondary)
                Text("Ponte Fotos " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.7")).font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }.padding(18).frame(width: 220).frame(maxHeight: .infinity).modifier(PFNavigationSurface())
    }
    private func sidebarAction(_ title: String, icon: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).frame(width: 20)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }.foregroundStyle(selected ? PFTheme.accent : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 10).contentShape(RoundedRectangle(cornerRadius: 9))
                .background(selected ? PFTheme.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(navigation.settings ? L("Configurações") : navigation.reverse ? L("Importar para o Fotos") : L("Sua biblioteca")).font(.system(size: 27, weight: .semibold))
                Text(navigation.settings ? L("Conexão, contas e aparência em um só lugar.") : navigation.reverse ? L("Do Immich para a biblioteca da Apple, com os originais.") : L("Escolha, revise e envie suas fotos para o Immich.")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if navigation.settings {
                Button(L("Voltar às fotos"), systemImage: "arrow.left") { navigation.settings = false }.controlSize(.large).disabled(model.busy)
            } else {
                Button { navigation.settings = true } label: {
                    Label(model.serverReady ? model.connectionIndicatorMessage.text : L("Configurar conexão"), systemImage: model.serverReady ? "checkmark.icloud" : "network")
                        .lineLimit(1)
                }.disabled(model.busy).help(L("Abrir configurações de conexão"))
            }
        }
    }
    private var sourcePanel: some View {
        PFCard {
            VStack(alignment: .leading, spacing: 12) {
                PFSectionHeading(L("Origem"), systemImage: model.sourceName == nil ? "photo.stack" : "folder")
                if let source = model.sourceName { Text(source).font(.callout.weight(.medium)).lineLimit(2) }
                else {
                    Picker(L("Álbum do Fotos"), selection: $model.album) { ForEach(model.albums) { Text($0.displayTitle).tag($0.id) } }.id(PFLocalization.languageCode).labelsHidden().frame(maxWidth: .infinity).controlSize(.large)
                }
                Toggle(L("Baixar originais do iCloud"), isOn: $model.allowCloud).font(.caption).disabled(model.sourceName != nil)
                if model.sourceName == nil {
                    HStack(spacing: 8) {
                        if model.activeUploadFollow != nil {
                            Button(L("Consultar novidades")) { Task { await model.checkUploadFollow() } }
                                .disabled(!model.transferReady)
                            Button { navigation.showingUploadFollow = true } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                                .help(L("Acompanhamento assistido"))
                                .accessibilityLabel(L("Acompanhamento assistido"))
                        } else {
                            Button(L("Acompanhar este álbum")) { navigation.showingUploadFollow = true }
                                .disabled(!model.canStartUploadFollow)
                                .help(L("Escolha um álbum do Fotos e um álbum existente no Immich para acompanhar."))
                        }
                    }
                    .popover(isPresented: $navigation.showingUploadFollow, arrowEdge: .bottom) { uploadFollowSettings }
                }
            }
        }.disabled(model.busy).onChange(of: model.album) { model.loadAlbum() }
    }
    private var uploadFollowSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L("Acompanhamento assistido"), systemImage: "arrow.triangle.2.circlepath").font(.headline)
                Spacer()
                Button(L("Concluir")) { navigation.showingUploadFollow = false }
            }
            Text(L("Fotos → Immich")).font(.callout.weight(.semibold))
            Text(L("Destino: \(model.activeUploadFollow?.destinationTitle ?? model.destinationLabel)"))
                .font(.callout).textSelection(.enabled)
            Text(L("A consulta revisa todo o álbum do Fotos e monta uma fila manual. Selecione os itens e confirme o envio. Nada é enviado automaticamente."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let follow = model.activeUploadFollow {
                if let date = follow.lastChecked {
                    Text(L("Última consulta: \(PFLocalization.formatDate(date, date: .abbreviated, time: .shortened))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(L("Parar acompanhamento")) { model.stopUploadFollowing(); navigation.showingUploadFollow = false }
                    .disabled(model.busy)
            } else {
                Button(L("Acompanhar este álbum")) { model.startUploadFollowing(); navigation.showingUploadFollow = false }
                    .disabled(model.busy || !model.canStartUploadFollow)
            }
        }.padding(20).frame(width: 440).environment(\.locale, PFLocalization.locale)
    }

    private var destinationPanel: some View {
        PFCard {
            VStack(alignment: .leading, spacing: 12) {
                PFSectionHeading(L("Destino"), systemImage: "externaldrive.badge.icloud")
                Picker(L("Destino no Immich"), selection: $model.destination) { ForEach(UploadDestination.allCases) { Text($0.label).tag($0) } }.id(PFLocalization.languageCode).labelsHidden().controlSize(.large).disabled(model.activeUploadFollow != nil)
                if model.destination == .existing {
                    HStack {
                        Picker(L("Álbum de destino"), selection: $model.remoteAlbumID) {
                            if model.remoteAlbums.isEmpty { Text(L("Nenhum álbum")).tag("") }
                            ForEach(model.remoteAlbums) { Text($0.albumName + ($0.shared == true ? L(" · compartilhado") : "")).tag($0.id) }
                        }.id(PFLocalization.languageCode).labelsHidden().disabled(model.activeUploadFollow != nil)
                        Button { Task { await model.refreshAlbums() } } label: { Image(systemName: "arrow.clockwise") }.help(L("Atualizar álbuns")).accessibilityLabel(L("Atualizar álbuns")).disabled(!model.transferReady)
                    }
                    Text(model.albumStatus).font(.caption).foregroundStyle(.secondary)
                }
                if model.destination == .new { TextField(L("Nome do novo álbum"), text: $model.newAlbumName).textFieldStyle(.roundedBorder) }
                if model.destination == .timeline { Text(L("Na linha do tempo, preservando os álbuns existentes.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }.disabled(model.busy)
    }
    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Fotos e vídeos")).font(.headline)
                PFBadge(L("\(model.selection.count) selecionados"))
                Spacer()
                Button(L("Revisar"), systemImage: "slider.horizontal.3") { model.reviewSelection() }.disabled(model.busy || model.selection.isEmpty)
            }
            List(model.items, selection: $model.selection) { item in
                photoRow(item).tag(item.id).contextMenu { Button(L("Revisar data e localização")) { model.editing = item } }
            }.listStyle(.inset).scrollContentBackground(.hidden)
                .background(PFTheme.surface, in: RoundedRectangle(cornerRadius: PFTheme.corner))
                .overlay(RoundedRectangle(cornerRadius: PFTheme.corner).strokeBorder(PFTheme.separator, lineWidth: 0.5))
                .overlay {
                    if model.items.isEmpty {
                        PFEmptyState(model.sourceName != nil ? L("Nenhuma mídia encontrada") : model.connected ? L("Nenhuma foto neste álbum") : L("Suas memórias começam aqui"), detail: model.sourceName != nil ? L("Escolha outra pasta ou confira o acesso ao disco.") : model.connected ? L("Escolha outro álbum para continuar.") : L("Abra a biblioteca do Fotos ou escolha uma pasta na barra lateral."), systemImage: "photo.on.rectangle.angled").allowsHitTesting(false)
                    }
                }.frame(minHeight: 180).disabled(model.busy)
            HStack(spacing: 14) {
                Button(L("Carregar mais")) { model.loadMore() }.disabled((!model.connected && model.sourceName == nil) || model.busy || model.activeUploadFollow != nil)
                Button(L("Selecionar visíveis")) { model.selection = Set(model.items.map(\.id)) }.disabled(model.busy)
                Spacer()
                Text(L("\(model.items.count) itens carregados")).font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.borderless)
        }
    }
    private func photoRow(_ item: PhotoItem) -> some View {
        let metadata = model.metadata(for: item)
        return HStack(spacing: 14) {
            PhotoThumbnail(item: item)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if item.live { PFBadge("Live", systemImage: "livephoto") }
                    if item.raw { PFBadge("RAW", color: .orange) }
                }
                Text(metadata.date.map { PFLocalization.formatDate($0, date: .abbreviated, time: .shortened) } ?? L("Complete a data de captura")).font(.caption).foregroundStyle(metadata.date == nil ? Color.orange : Color.secondary)
                Text(item.fileNames).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if let external = item.external, !external.displayNote.isEmpty { Text(external.displayNote).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                if let lat = metadata.latitude, let lon = metadata.longitude { Label(String(format: "%.4f, %.4f", lat, lon), systemImage: "location").font(.caption.monospaced()).foregroundStyle(.secondary) }
                else { Label(L("Sem localização"), systemImage: "location.slash").font(.caption).foregroundStyle(.orange) }
                Text(model.results[item.id] ?? L("Pronto para revisar")).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 170, alignment: .trailing)
            }
            Button { model.inspectingMedia = item } label: { Image(systemName: "info.circle") }.buttonStyle(.borderless).help(L("Diagnóstico de mídia")).accessibilityLabel(L("Diagnóstico de mídia"))
            Button { model.editing = item } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help(L("Revisar data e localização")).accessibilityLabel(L("Revisar \(item.title)"))
        }.padding(.vertical, 8)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.busy { ProgressView(value: model.progress).tint(PFTheme.accent) }
            if let message = model.uploadMetricsMessage { Text(message.text).font(.caption).foregroundStyle(.secondary) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { status; Spacer(minLength: 20); footerActions }
                VStack(alignment: .leading, spacing: 12) { status; HStack { Spacer(); footerActions } }
            }
        }.padding(.horizontal, 24).padding(.vertical, 16).modifier(PFNavigationSurface())
            .overlay(alignment: .top) { Rectangle().fill(PFTheme.separator).frame(height: 0.5) }
    }
    private var status: some View {
        HStack(alignment: .top, spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true) }
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
        }
    }
    private var footerActions: some View {
        HStack(spacing: 10) {
            if model.busy {
                Button(model.scanning ? L("Parar análise") : L("Pausar após itens em andamento")) { model.stopRequested = true; model.cancelScan() }
            } else {
                Button(L("Exportar XMP…"), systemImage: "square.and.arrow.up") { Task { await model.exportSelected() } }.disabled(model.selection.isEmpty)
                Button(L("Enviar selecionados"), systemImage: "arrow.up") { model.showUpload = true }.buttonStyle(.bordered).disabled(!model.canSend)
            }
        }.controlSize(.large)
    }
}
@main struct PonteFotosApp: App {
    @ObservedObject private var localization = PFLocalization.shared
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene { WindowGroup { ContentView().environment(\.locale, PFLocalization.locale) }.defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("Configurações…")) { NotificationCenter.default.post(name: .pfOpenSettings, object: nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        } }
}
