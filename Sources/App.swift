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
    var title: String { external?.url.lastPathComponent ?? resources.first(where: { $0.type == .photo || $0.type == .video })?.originalFilename ?? "Sem nome" }
    var live: Bool { asset?.mediaSubtypes.contains(.photoLive) ?? false }
    var raw: Bool { external.map { UTType(filenameExtension: $0.url.pathExtension)?.conforms(to: .rawImage) == true } ?? resources.contains { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true } }
    var fileNames: String { external?.url.path ?? resources.map(\.originalFilename).joined(separator: " + ") }
}
struct ResourceDescriptor { let type: PHAssetResourceType; let originalFilename: String }
struct AlbumItem: Identifiable { let id: String; let title: String; let collection: PHAssetCollection? }
@MainActor final class LibraryModel: ObservableObject {
    @Published var items: [PhotoItem] = []
    @Published var albums: [AlbumItem] = []
    @Published var album = "all"
    @Published var selection = Set<String>()
    @Published var status = "Conecte sua biblioteca para começar."
    @Published var showUpload = false
    @Published var showManagement = false
    @Published var managementBusy = false
    @Published var managementModel: IMWorkspaceModel?
    @Published var busy = false {
        didSet {
            if !busy && pendingNetworkChange {
                pendingNetworkChange = false
                networkChanged()
            }
        }
    }
    @Published var progress = 0.0
    @Published var results: [String: String] = [:]
    @Published var address = ""
    @Published var apiKey = "" {
        didSet { if apiKey != oldValue { verifiedUserID = nil; resetConnection() } }
    }
    @Published var profile = ConnectionProfile()
    @Published var wifiName: String?
    @Published var wifiStatus = "Identificação de Wi-Fi não autorizada"
    @Published var connectionLabel = "Conexão não testada"
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
    @Published var albumStatus = ""
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
                connectionSaved = true; status = "Conexão salva carregada. Verificando a rede…"
            }
        } catch { status = error.localizedDescription }
        edits = (try? JSONDecoder().decode([String: MetadataOverride].self, from: Data(contentsOf: url))) ?? [:]
        network.onChange = { [weak self] in self?.networkChanged() }
        network.start()
        showConnectionSettings = apiKey.isEmpty
        if connectionSaved && profile.mode != .automatic { Task { await testConnection() } }
    }
    func saveConnection() {
        do {
            try profile.validate()
            try ConnectionStore.save(address: address, key: apiKey, profile: profile, userID: verifiedUserID)
            connectionSaved = true; status = "URLs, rede e chave salvas no Chaves do macOS."
            Task { await testConnection() }
        }
        catch { status = error.localizedDescription }
    }
    func forgetConnection() {
        do { try ConnectionStore.remove(); connectionSaved = false; verifiedUserID = nil; profile.id = UUID().uuidString; resetConnection(); status = "Conexão salva removida do Chaves. Os campos atuais permanecem até fechar." }
        catch { status = error.localizedDescription }
    }
    func reviewSelection() {
        guard let item = items.first(where: { selection.contains($0.id) }) else { status = "Selecione uma foto para revisar."; return }
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
        edits = updated; results[id] = "Revisão salva · pronta para enviar"
    }
    func resetConnection() {
        serverReady = false; verifiedConnection = ""; remoteAlbums = []; remoteAlbumID = ""; albumStatus = ""; connectionLabel = "Conexão não testada"
    }
    var destinationLabel: String {
        switch destination {
        case .timeline: return "Rolo da câmera, sem adicionar a álbum"
        case .existing: return remoteAlbums.first(where: { $0.id == remoteAlbumID })?.albumName ?? "Escolha um álbum"
        case .new: return "Novo álbum: \(newAlbumName)"
        }
    }
    var canSend: Bool {
        !selection.isEmpty && chosen.allSatisfy { $0.metadata.date != nil } && serverReady && (destination == .timeline || destination == .existing && !remoteAlbumID.isEmpty || destination == .new && !newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    func refreshAlbums(timeout: TimeInterval = 15) async {
        do {
            remoteAlbums = try await ImmichClient(address: address, key: apiKey).albums(timeout: timeout)
            if !remoteAlbums.contains(where: { $0.id == remoteAlbumID }) { remoteAlbumID = remoteAlbums.first?.id ?? "" }
            albumStatus = remoteAlbums.isEmpty ? "Nenhum álbum disponível. Você pode criar um." : "\(remoteAlbums.count) álbuns disponíveis"
        } catch { remoteAlbums = []; remoteAlbumID = ""; albumStatus = "Não foi possível listar álbuns: \(error.localizedDescription)" }
    }
    func cancelScan() { scanTask?.cancel() }
    func chooseFolder(on volume: ExternalVolume? = nil) async {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Ler fotos e vídeos"; panel.message = "Escolha a pasta a analisar. Os arquivos de origem não serão alterados."
        panel.directoryURL = volume?.url
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        busy = true; stopRequested = false; progress = 0; status = "Analisando arquivos e metadados de \(folder.lastPathComponent)…"
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
        status = "\(externalItems.count) arquivos encontrados · \(missing) sem data de captura · \(result.issues) arquivos/pastas não lidos. Revise antes de enviar."
    }
    func connectLibrary() async {
        busy = true; status = "Abrindo biblioteca do Fotos…"; defer { busy = false }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            status = "Acesso ao Fotos não autorizado. Libere Ponte Fotos em Ajustes do Sistema → Privacidade e Segurança → Fotos."; return
        }
        if folderScoped { scopedFolder?.stopAccessingSecurityScopedResource(); folderScoped = false }
        sourceName = nil; externalItems = []
        connected = true
        albums = [AlbumItem(id: "all", title: "Todas as fotos", collection: nil)]
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            self.albums.append(AlbumItem(id: collection.localIdentifier, title: collection.localizedTitle ?? "Álbum", collection: collection))
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
            offset = end; status = "\(items.count) de \(externalItems.count) arquivos carregados."
            return
        }
        guard let fetched else { return }
        let end = min(offset + 100, fetched.count)
        for index in offset..<end {
            let a = fetched.object(at: index)
            items.append(PhotoItem(asset: a, resources: PHAssetResource.assetResources(for: a).filter { [.photo, .video, .pairedVideo, .alternatePhoto].contains($0.type) }, metadata: CaptureMetadata(date: a.creationDate, latitude: a.location?.coordinate.latitude, longitude: a.location?.coordinate.longitude, favorite: a.isFavorite)))
        }
        offset = end; status = "\(items.count) de \(fetched.count) itens carregados. Selecione um lote pequeno para o primeiro teste."
    }
    func openManagement() {
        guard serverReady, !busy else { return }
        managementModel = IMWorkspaceModel(address: address, primaryKey: apiKey, profileID: profile.id, connectionReady: serverReady, onBusyChanged: { [weak self] active in
            self?.managementBusy = active; self?.busy = active
        })
        showManagement = true
    }
    func requestWifiPermission() { network.requestLocationPermission() }
    func connectionSettingsChanged(previous: ConnectionProfile) {
        guard !busy else { return }
        resetConnection()
        if previous.mode != profile.mode, !apiKey.isEmpty { Task { await testConnection() } }
    }
    private func networkChanged() {
        wifiName = network.ssid; wifiStatus = network.locationStatus
        guard profile.mode == .automatic, !apiKey.isEmpty else { return }
        if busy {
            pendingNetworkChange = true
            if uploading { stopRequested = true; connectionLabel = "Rede mudou · pausa após este item" }
            return
        }
        resetConnection()
        connectionLabel = "Rede mudou · verificando conexão…"
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
        busy = true; resetConnection(); connectionLabel = "Verificando conexão…"
        defer { busy = false }
        do {
            let resolution = try await ConnectionResolver.resolve(profile: profile, ssid: wifiName, key: apiKey, expectedUserID: verifiedUserID)
            address = resolution.candidate.address
            verifiedUserID = resolution.identity.userID
            verifiedConnection = address + "\n" + apiKey
            serverReady = true
            connectionLabel = "Conexão " + resolution.candidate.kind.lowercased()
            status = "Conexão com \(resolution.identity.serverVersion) OK."
            if connectionSaved {
                try ConnectionStore.save(address: address, key: apiKey, profile: profile, userID: resolution.identity.userID)
            }
            await refreshAlbums(timeout: 5)
        } catch {
            resetConnection(); connectionLabel = "Sem conexão verificada"; status = error.localizedDescription
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
        guard item.metadata.date != nil else { throw BridgeError(message: "Sem data de captura: preencha na revisão antes de enviar.") }
        if let external = item.external {
            let folder = root.appendingPathComponent(item.id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(external.url.lastPathComponent)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try FileManager.default.copyItem(at: external.url, to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let xmp = file.appendingPathExtension("xmp")
            try ExternalReader.mergedXMP(item.metadata, sidecar: external.sidecar).write(to: xmp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: xmp.path)
            return [(0, ResourceDescriptor(type: external.isVideo ? .video : .photo, originalFilename: external.url.lastPathComponent), file, xmp)]
        }
        guard !item.resources.isEmpty else { throw BridgeError(message: "Nenhum recurso original disponível.") }
        if item.live && !item.resources.contains(where: { $0.type == .pairedVideo }) { throw BridgeError(message: "Live Photo sem vídeo original disponível. Envio interrompido.") }
        let folder = root.appendingPathComponent(item.id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var files: [(Int, ResourceDescriptor, URL, URL)] = []
        for (index, resource) in item.resources.enumerated() {
            let resourceFolder = folder.appendingPathComponent(String(index), isDirectory: true)
            try FileManager.default.createDirectory(at: resourceFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = URL(fileURLWithPath: resource.originalFilename).lastPathComponent
            let file = resourceFolder.appendingPathComponent(name)
            status = "Preparando \(name)…"
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
        panel.prompt = "Exportar aqui"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let root = parent.appendingPathComponent("Ponte-Fotos-\(UUID().uuidString.prefix(8))")
        busy = true; stopRequested = false; progress = 0; defer { busy = false }
        let batch = chosen
        for (index, item) in batch.enumerated() {
            if stopRequested { break }
            do { _ = try await prepare(item, root: root); results[item.id] = "Exportado com XMP" }
            catch { results[item.id] = error.localizedDescription }
            progress = Double(index + 1) / Double(batch.count)
        }
        status = "Exportação finalizada. Arquivos em \(root.path)"
        NSWorkspace.shared.open(root)
    }
    func sendSelected() async {
        guard canSend, verifiedConnection == address + "\n" + apiKey else { status = "Teste a conexão antes de enviar."; return }
        busy = true; uploading = true; progress = 0; stopRequested = false
        defer { uploading = false; busy = false }
        do {
            let client = try ImmichClient(address: address, key: apiKey)
            guard let userID = verifiedUserID else { throw BridgeError(message: "Teste a conexão antes de enviar.") }
            let transferProfile = profile
            var targetAlbumID: String?
            if destination == .existing {
                guard remoteAlbums.contains(where: { $0.id == remoteAlbumID }) else { throw BridgeError(message: "Atualize e selecione um álbum de destino.") }
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
                results[item.id] = "Preparando…"
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
                        let checksum = try ImmichClient.checksum(file)
                        var result: UploadResult
                        if let previous = records.first(where: { $0.resourceIndex == index && $0.checksum == checksum }), (try? await client.matchesHistory(assetID: previous.result.id, checksum: checksum, userID: userID)) == true {
                            result = previous.result
                            try ConnectionHistory.save(records, to: recordURL)
                        } else {
                            status = "Enviando \(resource.originalFilename)…"
                            result = try await client.upload(file: file, sidecar: xmp, metadata: item.metadata, liveVideoID: resource.type == .photo ? videoID : nil)
                            records.removeAll { $0.resourceIndex == index }
                            records.append(TransferRecord(resourceIndex: index, checksum: checksum, result: result))
                            try JSONEncoder().encode(records).write(to: recordURL, options: .atomic)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
                        }
                        if let edit = edits[item.id], edit.hasChanges {
                            status = "Aplicando sua revisão no Immich…"
                            try await client.applyReview(edit, to: result.id)
                        }
                        if resource.type != .pairedVideo { albumAssetIDs.append(result.id) }
                        if resource.type == .pairedVideo { videoID = result.id }
                        status = "Conferindo data, localização e associação…"
                        var verified = false
                        for attempt in 0..<6 {
                            let remote = try await client.info(result.id)
                            if item.metadata.verify(remote, liveVideoID: resource.type == .photo ? videoID : nil) { verified = true; break }
                            if attempt < 5 { try await Task.sleep(nanoseconds: 2_000_000_000) }
                        }
                        if !verified { allVerified = false }
                    }
                    if let targetAlbumID {
                        status = "Adicionando ao álbum…"
                        try await client.addToAlbum(targetAlbumID, assetIDs: albumAssetIDs)
                    }
                    let checked = "Data conferida" + (item.metadata.latitude != nil ? " · GPS conferido" : " · sem GPS informado") + (item.live ? " · Live conferido" : "")
                    results[item.id] = (allVerified ? checked : "Enviado/existente · conferência pendente ou divergente") + (targetAlbumID != nil ? " · no álbum" : "")
                } catch { results[item.id] = "Falha: \(error.localizedDescription)" }
                try? FileManager.default.removeItem(at: folder)
                withAnimation { progress = Double(position + 1) / Double(batch.count) }
            }
            status = stopRequested ? "Pausado entre itens. Selecione o lote e envie para retomar." : "Lote finalizado. Confira os resultados de cada foto."
        } catch { status = error.localizedDescription }
    }
}

@MainActor final class ThumbnailModel: ObservableObject { @Published var image: NSImage? }
struct PhotoThumbnail: View {
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
    static var logo: NSImage {
        if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Ponte Fotos")!
    }
}
struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @StateObject private var volumes = VolumeMonitor()
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) { Image(nsImage: AppBrand.logo).resizable().scaledToFit().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12)); Text("Ponte Fotos").font(.title2.bold()) }
                Text("Suas memórias, com a história inteira.").font(.title3).foregroundStyle(.secondary)
                Divider()
                Button { model.openManagement() } label: { Label("Gerenciar Immich", systemImage: "photo.on.rectangle.angled") }.buttonStyle(.plain).disabled(model.busy || !model.serverReady)
                Button { Task { await model.connectLibrary() } } label: { Label("Biblioteca Apple", systemImage: "photo.stack") }.buttonStyle(.plain).disabled(model.busy)
                Divider()
                HStack { Text("DISCOS E PASTAS").font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Button { volumes.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain) }
                if volumes.volumes.isEmpty { Text("Nenhum disco externo conectado").font(.caption).foregroundStyle(.secondary) }
                ForEach(volumes.volumes) { volume in
                    Button { Task { await model.chooseFolder(on: volume) } } label: { Label(volume.name, systemImage: "externaldrive.fill").lineLimit(1) }.buttonStyle(.plain).disabled(model.busy)
                }
                Button("Escolher pasta…", systemImage: "folder") { Task { await model.chooseFolder() } }.disabled(model.busy)
                if let source = model.sourceName { Text("Origem: \(source)").font(.caption).foregroundStyle(.teal).lineLimit(2) }
                Label("2  Originais + metadados", systemImage: "doc.badge.gearshape")
                Label("3  Immich", systemImage: "externaldrive.badge.checkmark")
                Spacer()
                Text("Originais preservados\nLive Photos e RAW\nXMP com data e GPS").font(.callout).foregroundStyle(.secondary)
                Text("Versão 0.5 · gestão Immich").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(width: 260).frame(maxHeight: .infinity).background(.regularMaterial)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Suas fotos para o Immich").font(.largeTitle.bold())
                        Text("Escolha, revise e acompanhe cada envio.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Abrir biblioteca", systemImage: "photo") { Task { await model.connectLibrary() } }.disabled(model.busy)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Picker("Conexão", selection: $model.profile.mode) {
                                ForEach(ConnectionMode.allCases) { Text($0.label).tag($0) }
                            }.frame(maxWidth: 320)
                            Label(model.connectionLabel, systemImage: "network").font(.callout)
                            Spacer()
                            Button("Testar conexão") { Task { await model.testConnection() } }
                        }
                        VStack(alignment: .leading) {
                            Picker("Conexão", selection: $model.profile.mode) {
                                ForEach(ConnectionMode.allCases) { Text($0.label).tag($0) }
                            }
                            Label(model.connectionLabel, systemImage: "network").font(.callout)
                            Button("Testar conexão") { Task { await model.testConnection() } }
                        }
                    }.disabled(model.busy)
                    Text(model.serverReady ? "Endereço em uso: \(model.address)" : "Escolha o modo e teste a conexão.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    DisclosureGroup("Configurar URLs, Wi-Fi e chave", isExpanded: $model.showConnectionSettings) {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("URL local") { TextField("http://immich.local:2283", text: $model.profile.localAddress) }
                            LabeledContent("URL remota") { TextField("http://servidor:porta", text: $model.profile.remoteAddress) }
                            LabeledContent("Wi-Fi de casa") { TextField("Nome exato da rede", text: $model.profile.homeSSID) }
                            HStack {
                                Text(model.wifiName.map { "Wi-Fi atual: \($0)" } ?? model.wifiStatus).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Permitir identificar Wi-Fi") { model.requestWifiPermission() }
                            }
                            Text("No Automático, o Wi-Fi de casa usa a URL local e recorre à remota se ela não responder. Em outras redes ou sem identificar o Wi-Fi, usa a remota. Uma mudança durante o envio pausa o lote após o item atual.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            LabeledContent("Chave de API") { SecureField("Chave da sua conta Immich", text: $model.apiKey) }
                            ViewThatFits(in: .horizontal) {
                                HStack {
                                    Button("Salvar configuração", systemImage: "key.fill") { model.saveConnection() }.disabled(model.apiKey.isEmpty)
                                    if model.connectionSaved { Button("Esquecer conexão salva") { model.forgetConnection() } }
                                    Text("Protegida pelo Chaves do macOS").font(.caption).foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading) {
                                    Button("Salvar configuração", systemImage: "key.fill") { model.saveConnection() }.disabled(model.apiKey.isEmpty)
                                    if model.connectionSaved { Button("Esquecer conexão salva") { model.forgetConnection() } }
                                }
                            }
                        }.padding(.top, 8).textFieldStyle(.roundedBorder).disabled(model.busy)
                    }
                }
                .onChange(of: model.profile) { previous, _ in model.connectionSettingsChanged(previous: previous) }
                HStack {
                    if let source = model.sourceName { Label(source, systemImage: "externaldrive").lineLimit(1) }
                    else { Picker("Origem · Fotos", selection: $model.album) { ForEach(model.albums) { Text($0.title).tag($0.id) } }.frame(maxWidth: 340) }
                    Toggle("Baixar originais do iCloud", isOn: $model.allowCloud).disabled(model.sourceName != nil)
                    Spacer()
                    Text("\(model.selection.count) selecionados").monospacedDigit()
                }.disabled(model.busy).onChange(of: model.album) { model.loadAlbum() }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Destino · Immich", selection: $model.destination) {
                            ForEach(UploadDestination.allCases) { Text($0.label).tag($0) }
                        }.frame(maxWidth: 360)
                        if model.destination == .existing {
                            Picker("Álbum", selection: $model.remoteAlbumID) {
                                if model.remoteAlbums.isEmpty { Text("Nenhum álbum").tag("") }
                                ForEach(model.remoteAlbums) { Text($0.albumName + ($0.shared == true ? " · compartilhado" : "")).tag($0.id) }
                            }
                            Button("Atualizar", systemImage: "arrow.clockwise") { Task { await model.refreshAlbums() } }.disabled(!model.serverReady)
                        }
                        if model.destination == .new { TextField("Nome do novo álbum", text: $model.newAlbumName).textFieldStyle(.roundedBorder) }
                    }
                    if model.destination == .existing { Text(model.albumStatus).font(.caption).foregroundStyle(.secondary) }
                    if model.destination == .timeline { Text("Os itens ficam na linha do tempo. Vínculos existentes com outros álbuns são mantidos.").font(.caption).foregroundStyle(.secondary) }
                }.disabled(model.busy)
                HStack {
                    Text("Selecione uma foto para completar data e localização.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revisar selecionada", systemImage: "pencil") { model.reviewSelection() }.disabled(model.busy || model.selection.isEmpty)
                }
                List(model.items, selection: $model.selection) { item in
                    let metadata = model.metadata(for: item)
                    HStack(spacing: 14) {
                        PhotoThumbnail(item: item)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.title).fontWeight(.semibold).lineLimit(1)
                                if item.live { Text("LIVE").font(.caption.bold()).foregroundStyle(.teal) }
                                if item.raw { Text("RAW").font(.caption.bold()).foregroundStyle(.orange) }
                            }
                            Text(metadata.date?.formatted(date: .abbreviated, time: .standard) ?? "SEM DATA DE CAPTURA · preencha na revisão").font(.callout).foregroundStyle(metadata.date == nil ? Color.orange : Color.primary)
                            if metadata.date == nil && metadata.latitude == nil { Text("Sem data/GPS de captura detectáveis").font(.caption.bold()).foregroundStyle(.orange) }
                            if let external = item.external, !external.note.isEmpty { Text(external.note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Text(item.fileNames).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            if let lat = metadata.latitude, let lon = metadata.longitude {
                                Text(String(format: "%.5f, %.5f", lat, lon)).font(.caption.monospaced())
                            } else { Text("Adicionar localização").font(.caption).foregroundStyle(.orange) }
                            Text(model.results[item.id] ?? "Pronto para revisar").font(.caption).foregroundStyle(.secondary).frame(maxWidth: 240, alignment: .trailing)
                        }
                        Button("Revisar", systemImage: "pencil") { model.editing = item }.buttonStyle(.bordered).help("Preencher data, hora e localização")
                    }.padding(.vertical, 5).tag(item.id)
                    .contextMenu { Button("Revisar data e localização") { model.editing = item } }
                }.overlay {
                    if model.items.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.stack").font(.system(size: 38)).foregroundStyle(.teal)
                            Text(model.sourceName != nil ? "Nenhuma mídia encontrada" : model.connected ? "Nenhuma foto neste álbum" : "Escolha sua origem").font(.title2.bold())
                            Text(model.sourceName != nil ? "Escolha outra pasta ou confira as permissões do disco." : model.connected ? "Escolha outro álbum para continuar." : "Abra o Fotos ou escolha um disco/pasta na lateral.").foregroundStyle(.secondary)
                        }.allowsHitTesting(false)
                    }
                }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 14)).disabled(model.busy)
                if model.busy { ProgressView(value: model.progress).tint(.teal); HStack { ProgressView().controlSize(.small); Text(model.status).font(.callout) } }
                else { Text(model.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Button("Carregar mais") { model.loadMore() }.disabled((!model.connected && model.sourceName == nil) || model.busy)
                    Button("Selecionar visíveis") { model.selection = Set(model.items.map(\.id)) }.disabled(model.busy)
                    Spacer()
                    if model.busy {
                        Button(model.scanning ? "Parar análise" : "Pausar após este item") { model.stopRequested = true; model.cancelScan() }
                    } else {
                        Button("Exportar com XMP…") { Task { await model.exportSelected() } }.disabled(model.selection.isEmpty)
                        Button("Enviar selecionados", systemImage: "arrow.up.circle.fill") { model.showUpload = true }.buttonStyle(.borderedProminent).tint(.teal).disabled(!model.canSend)
                    }
                }
            }.padding(28).frame(minWidth: 720)
        }.frame(minWidth: 1050, minHeight: 700)
        .sheet(item: $model.editing) { item in
            ReviewEditor(item: item, metadata: model.metadata(for: item), save: { try model.saveReview($0, id: item.id) }, restore: { try model.saveReview(nil, id: item.id) }, dismiss: { model.editing = nil })
        }
        .sheet(isPresented: $model.showManagement, onDismiss: { model.managementModel = nil }) {
            if let workspace = model.managementModel {
                ImmichWorkspaceView(model: workspace, address: model.address, connectionReady: model.serverReady)
                    .disabled(model.busy && !model.managementBusy)
                    .interactiveDismissDisabled(model.managementBusy)
            }
        }
        .confirmationDialog("Enviar \(model.selection.count) itens para o Immich?", isPresented: $model.showUpload, titleVisibility: .visible) {
            Button("Enviar com originais e XMP") { Task { await model.sendSelected() } }
        } message: {
            Text("Destino: \(model.address) → \(model.destinationLabel). Live Photos incluem vídeo; RAW inclui os recursos originais disponíveis. Revisões manuais salvas serão aplicadas também às fotos já existentes no Immich. A prévia mostra horários no fuso deste Mac; o fuso histórico da captura ainda precisa de validação.")
        }
    }
}
@main struct PonteFotosApp: App {
    init() { NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.applicationIconImage = AppBrand.logo }
    var body: some Scene { WindowGroup { ContentView() }.defaultSize(width: 1150, height: 780) }
}
