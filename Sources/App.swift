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
        return "file-" + SHA256.hash(data: Data((external?.url.standardizedFileURL.path ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var title: String { external?.url.lastPathComponent ?? resources.first(where: { $0.type == .photo || $0.type == .video })?.originalFilename ?? L("Sem nome") }
    var live: Bool { asset?.mediaSubtypes.contains(.photoLive) ?? false }
    var raw: Bool { external.map { UTType(filenameExtension: $0.url.pathExtension)?.conforms(to: .rawImage) == true } ?? resources.contains { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true } }
    var fileNames: String { external?.url.path ?? resources.map(\.originalFilename).joined(separator: " + ") }
}
struct ResourceDescriptor { let type: PHAssetResourceType; let originalFilename: String }
struct AlbumItem: Identifiable {
    let id: String; let title: String; let collection: PHAssetCollection?
    var fallback: PFMessage? = nil
    var displayTitle: String { fallback?.text ?? title }
}
@MainActor final class LibraryModel: ObservableObject {
    @Published var items: [PhotoItem] = []
    @Published var albums: [AlbumItem] = []
    @Published var album = "all"
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
        didSet { if apiKey != oldValue { verifiedUserID = nil; resetConnection() } }
    }
    @Published var profile = ConnectionProfile()
    @Published var wifiName: String?
    var wifiStatus: String { get { wifiStatusMessage.text } set { wifiStatusMessage = .verbatim(newValue) } }
    @Published var wifiStatusMessage = M("Identificação de Wi-Fi não autorizada")
    var connectionLabel: String { get { connectionLabelMessage.text } set { connectionLabelMessage = .verbatim(newValue) } }
    @Published var connectionLabelMessage = M("Conexão não testada")
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
    @Published var stopRequested = false
    @Published var scanning = false
    private var scanTask: Task<ExternalScanResult, Never>?
    @Published var sourceName: String?
    private var externalItems: [PhotoItem] = []
    private var scopedFolder: URL?
    private var folderScoped = false
    private var offset = 0
    private var fetched: PHFetchResult<PHAsset>?
    private var verifiedConnection = ""
    private var workspace: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PonteFotos", isDirectory: true)
    }
    @Published var edits: [String: MetadataOverride] = [:]
    @Published var editing: PhotoItem?
    @Published var destination: UploadDestination = .timeline
    @Published var remoteAlbums: [ImmichAlbum] = []
    @Published var remoteAlbumID = ""
    @Published var newAlbumName = ""
    var albumStatus: String { get { albumStatusMessage.text } set { albumStatusMessage = .verbatim(newValue) } }
    @Published var albumStatusMessage: PFMessage = ""
    init() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PonteFotos/reviews.json")
        do {
            if let connection = try ConnectionStore.load() {
                address = connection.address; apiKey = connection.key
                if let savedProfile = connection.profile { profile = savedProfile }
                else if !profile.recognizes(address: connection.address) {
                    profile.localAddress = connection.address; profile.mode = .local
                }
                verifiedUserID = connection.userID
                connectionSaved = true; statusMessage = M("Conexão salva carregada. Verificando a rede…")
            }
        } catch { statusMessage = PFMessage.error(error) }
        edits = (try? JSONDecoder().decode([String: MetadataOverride].self, from: Data(contentsOf: url))) ?? [:]
        network.onStatusChange = { [weak self] in
            guard let self else { return }
            self.wifiName = self.network.ssid; self.wifiStatusMessage = self.network.locationStatusMessage
        }
        network.onChange = { [weak self] in self?.networkChanged() }
        network.start()
        showConnectionSettings = apiKey.isEmpty
        if connectionSaved && profile.mode != .automatic { Task { await testConnection() } }
    }
    func saveConnection() {
        do {
            try profile.validate()
            try ConnectionStore.save(address: address, key: apiKey, profile: profile, userID: verifiedUserID)
            connectionSaved = true; statusMessage = M("URLs, rede e chave salvas no Chaves do macOS.")
            Task { await testConnection() }
        }
        catch { statusMessage = PFMessage.error(error) }
    }
    func forgetConnection() {
        do { try ConnectionStore.remove(); connectionSaved = false; verifiedUserID = nil; profile.id = UUID().uuidString; resetConnection(); statusMessage = M("Conexão salva removida do Chaves. Os campos atuais permanecem até fechar.") }
        catch { statusMessage = PFMessage.error(error) }
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
        !selection.isEmpty && chosen.allSatisfy { $0.metadata.date != nil } && serverReady && (destination == .timeline || destination == .existing && !remoteAlbumID.isEmpty || destination == .new && !newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    func refreshAlbums(timeout: TimeInterval = 15) async {
        do {
            remoteAlbums = try await ImmichClient(address: address, key: apiKey).albums(timeout: timeout)
            if !remoteAlbums.contains(where: { $0.id == remoteAlbumID }) { remoteAlbumID = remoteAlbums.first?.id ?? "" }
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
        externalItems = result.media.map { PhotoItem(asset: nil, resources: [], metadata: $0.metadata, external: $0) }
        loadMore()
        let missing = externalItems.filter { $0.metadata.date == nil }.count
        statusMessage = M("\(externalItems.count) arquivos encontrados · \(missing) sem data de captura · \(result.issues) arquivos/pastas não lidos. Revise antes de enviar.")
    }
    func connectLibrary() async {
        busy = true; statusMessage = M("Abrindo biblioteca do Fotos…"); defer { busy = false }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
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
        loadMore()
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
    func requestWifiPermission() { network.requestLocationPermission() }
    func connectionSettingsChanged(previous: ConnectionProfile) {
        guard !busy else { return }
        resetConnection()
        if previous.mode != profile.mode, !apiKey.isEmpty { Task { await testConnection() } }
    }
    private func networkChanged() {
        wifiName = network.ssid; wifiStatusMessage = network.locationStatusMessage
        guard profile.mode == .automatic, !apiKey.isEmpty else { return }
        if busy {
            pendingNetworkChange = true
            if uploading { stopRequested = true; connectionLabelMessage = M("Rede mudou · pausa após este item") }
            return
        }
        resetConnection()
        connectionLabelMessage = M("Rede mudou · verificando conexão…")
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            if self.busy { self.pendingNetworkChange = true; return }
            await self.testConnection()
        }
    }
    func testConnection() async {
        guard !busy else { return }
        busy = true; resetConnection(); connectionLabelMessage = M("Verificando conexão…")
        defer { busy = false }
        do {
            let resolution = try await ConnectionResolver.resolve(profile: profile, ssid: wifiName, key: apiKey, expectedUserID: verifiedUserID)
            address = resolution.candidate.address
            verifiedUserID = resolution.identity.userID
            verifiedConnection = address + "\n" + apiKey
            serverReady = true
            connectionLabelMessage = M("Conexão: \(MV(resolution.candidate.kind))")
            statusMessage = M("Conexão com \(resolution.identity.serverVersion) OK.")
            if connectionSaved {
                try ConnectionStore.save(address: address, key: apiKey, profile: profile, userID: resolution.identity.userID)
            }
            await refreshAlbums(timeout: 5)
        } catch {
            resetConnection(); connectionLabelMessage = M("Sem conexão verificada"); statusMessage = PFMessage.error(error)
        }
    }
    func exportResource(_ resource: PHAssetResource, to url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = allowCloud
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func prepare(_ item: PhotoItem, root: URL) async throws -> [(Int, ResourceDescriptor, URL, URL)] {
        guard item.metadata.date != nil else { throw BridgeError(message: M("Sem data de captura: preencha na revisão antes de enviar.")) }
        if let external = item.external {
            let folder = root.appendingPathComponent(item.id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(external.url.lastPathComponent)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try await TransferFileIO.copyOriginal(from: external.url, to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let xmp = file.appendingPathExtension("xmp")
            try ExternalReader.mergedXMP(item.metadata, sidecar: external.sidecar).write(to: xmp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: xmp.path)
            return [(0, ResourceDescriptor(type: external.isVideo ? .video : .photo, originalFilename: external.url.lastPathComponent), file, xmp)]
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
        guard canSend, verifiedConnection == address + "\n" + apiKey else { statusMessage = M("Teste a conexão antes de enviar."); return }
        busy = true; uploading = true; progress = 0; stopRequested = false
        defer { uploading = false; busy = false }
        do {
            let client = try ImmichClient(address: address, key: apiKey)
            guard let userID = verifiedUserID else { throw BridgeError(message: M("Teste a conexão antes de enviar.")) }
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
            let staging = workspace.appendingPathComponent("staging", isDirectory: true)
            let history = workspace.appendingPathComponent("history", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let batch = chosen
            for (position, item) in batch.enumerated() {
                if stopRequested { break }
                resultsMessages[item.id] = M("Preparando…")
                let folder = staging.appendingPathComponent(item.id.replacingOccurrences(of: "/", with: "_"))
                do {
                    let files = try await prepare(item, root: staging)
                    let recordURL = ConnectionHistory.recordURL(directory: history, profileID: transferProfile.id, userID: userID, itemID: item.id)
                    let legacy = ConnectionHistory.legacyURLs(directory: history, addresses: [transferProfile.localAddress, transferProfile.remoteAddress, address], itemID: item.id)
                    var records = ConnectionHistory.load([recordURL] + legacy)
                    var videoID: String?
                    var allVerified = true
                    var albumAssetIDs: [String] = []
                    // The paired video must exist before associating the still image.
                    let ordered = files.sorted { ($0.1.type == .pairedVideo ? 0 : 1) < ($1.1.type == .pairedVideo ? 0 : 1) }
                    for (index, resource, file, xmp) in ordered {
                        let checksum = try await TransferFileIO.checksum(file)
                        var result: UploadResult
                        if let previous = records.first(where: { $0.resourceIndex == index && $0.checksum == checksum }), (try? await client.matchesHistory(assetID: previous.result.id, checksum: checksum, userID: userID)) == true {
                            result = previous.result
                            try ConnectionHistory.save(records, to: recordURL)
                        } else {
                            statusMessage = M("Enviando \(resource.originalFilename)…")
                            result = try await client.upload(file: file, sidecar: xmp, metadata: item.metadata, liveVideoID: resource.type == .photo ? videoID : nil)
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
                        for attempt in 0..<6 {
                            let remote = try await client.info(result.id)
                            if item.metadata.verify(remote, liveVideoID: resource.type == .photo ? videoID : nil) { verified = true; break }
                            if attempt < 5 { try await Task.sleep(nanoseconds: 2_000_000_000) }
                        }
                        if !verified { allVerified = false }
                    }
                    if let targetAlbumID {
                        statusMessage = M("Adicionando ao álbum…")
                        try await client.addToAlbum(targetAlbumID, assetIDs: albumAssetIDs)
                    }
                    let checked = M("Data conferida") + (item.metadata.latitude != nil ? M(" · GPS conferido") : M(" · sem GPS informado")) + (item.live ? M(" · Live conferido") : "")
                    resultsMessages[item.id] = (allVerified ? checked : M("Enviado/existente · conferência pendente ou divergente")) + (targetAlbumID != nil ? M(" · no álbum") : "")
                } catch { resultsMessages[item.id] = M("Falha: \(PFMessage.error(error))") }
                try? FileManager.default.removeItem(at: folder)
                withAnimation { progress = Double(position + 1) / Double(batch.count) }
            }
            statusMessage = stopRequested ? M("Pausado entre itens. Selecione o lote e envie para retomar.") : M("Lote finalizado. Confira os resultados de cada foto.")
        } catch { statusMessage = PFMessage.error(error) }
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
                    PFReverseImportView(model: reverseImport, address: model.address, key: model.apiKey, profileID: model.profile.id, connectionReady: model.serverReady, configure: { navigation.settings = true })
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
        .onChange(of: model.apiKey) { _, _ in reverseImport.invalidate(); model.prepareManagementSession() }
        .onChange(of: model.address) { _, _ in reverseImport.invalidate(); model.prepareManagementSession() }
        .onChange(of: model.serverReady) { _, ready in if !ready { reverseImport.invalidate() }; model.prepareManagementSession() }
        .onChange(of: model.busy) { _, busy in if !busy { model.prepareManagementSession() } }
        .onChange(of: reverseImport.busy || reverseImport.importing) { _, active in model.busy = active }
        .onChange(of: navigation.settings) { _, open in
            if open { navigation.reverse = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pfOpenSettings)) { _ in
            if !model.busy { navigation.settings = true }
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
            Text(L("Destino: \(model.address) → \(model.destinationLabel). Live Photos incluem vídeo; RAW inclui os recursos originais disponíveis. Revisões manuais salvas serão aplicadas também às fotos já existentes no Immich. A prévia mostra horários no fuso deste Mac; o fuso histórico da captura ainda precisa de validação."))
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
            Divider().padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 8) {
                Label(L("Originais preservados"), systemImage: "checkmark.shield").font(.caption.weight(.medium))
                Text(L("Live Photos, RAW e metadados\nacompanham suas memórias.")).font(.caption).foregroundStyle(.secondary)
                Text("Ponte Fotos 0.9.5").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4)
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
                    Label(model.serverReady ? model.connectionLabel : L("Configurar conexão"), systemImage: model.serverReady ? "checkmark.icloud" : "network")
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
            }
        }.disabled(model.busy).onChange(of: model.album) { model.loadAlbum() }
    }
    private var destinationPanel: some View {
        PFCard {
            VStack(alignment: .leading, spacing: 12) {
                PFSectionHeading(L("Destino"), systemImage: "externaldrive.badge.icloud")
                Picker(L("Destino no Immich"), selection: $model.destination) { ForEach(UploadDestination.allCases) { Text($0.label).tag($0) } }.id(PFLocalization.languageCode).labelsHidden().controlSize(.large)
                if model.destination == .existing {
                    HStack {
                        Picker(L("Álbum de destino"), selection: $model.remoteAlbumID) {
                            if model.remoteAlbums.isEmpty { Text(L("Nenhum álbum")).tag("") }
                            ForEach(model.remoteAlbums) { Text($0.albumName + ($0.shared == true ? L(" · compartilhado") : "")).tag($0.id) }
                        }.id(PFLocalization.languageCode).labelsHidden()
                        Button { Task { await model.refreshAlbums() } } label: { Image(systemName: "arrow.clockwise") }.help(L("Atualizar álbuns")).accessibilityLabel(L("Atualizar álbuns")).disabled(!model.serverReady)
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
                Button(L("Carregar mais")) { model.loadMore() }.disabled((!model.connected && model.sourceName == nil) || model.busy)
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
                if let external = item.external, !external.displayNote.isEmpty { Text(external.displayNote).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                if let lat = metadata.latitude, let lon = metadata.longitude { Label(String(format: "%.4f, %.4f", lat, lon), systemImage: "location").font(.caption.monospaced()).foregroundStyle(.secondary) }
                else { Label(L("Sem localização"), systemImage: "location.slash").font(.caption).foregroundStyle(.orange) }
                Text(model.results[item.id] ?? L("Pronto para revisar")).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 170, alignment: .trailing)
            }
            Button { model.editing = item } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help(L("Revisar data e localização")).accessibilityLabel(L("Revisar \(item.title)"))
        }.padding(.vertical, 8)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.busy { ProgressView(value: model.progress).tint(PFTheme.accent) }
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
                Button(model.scanning ? L("Parar análise") : L("Pausar após este item")) { model.stopRequested = true; model.cancelScan() }
            } else {
                Button(L("Exportar XMP…"), systemImage: "square.and.arrow.up") { Task { await model.exportSelected() } }.disabled(model.selection.isEmpty)
                Button(L("Enviar selecionados"), systemImage: "arrow.up") { model.showUpload = true }.buttonStyle(.borderedProminent).disabled(!model.canSend)
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
