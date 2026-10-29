import SwiftUI
import Combine

// Job preferences contain album IDs and options only. Credentials are resolved
// from the currently validated account for each execution and are never saved here.
enum PFAlbumSyncDirection: String, Codable, CaseIterable, Identifiable {
    case upload, download, both
    var id: String { rawValue }
    var title: String { switch self {
    case .upload: return L("Fotos → Immich")
    case .download: return L("Immich → Fotos")
    case .both: return L("Nos dois sentidos")
    } }
}
struct PFAlbumSyncLink: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var photosID: String
    var photosTitle: String
    var immichID: String
    var immichTitle: String
    var direction: PFAlbumSyncDirection
    var automatic = false
    var lastChecked: Date?
}

@MainActor final class PFAlbumSyncCoordinator: ObservableObject {
    @Published private(set) var links: [PFAlbumSyncLink] = []
    @Published var selected = Set<String>()
    @Published private(set) var running = false
    @Published private(set) var outcomes: [String: PFMessage] = [:]
    @Published private(set) var status = M("Escolha álbuns do Fotos e seus destinos no Immich.")
    @Published var showing = false
    @Published var attention: PFMessage?
    private var scope = ""
    private var task: Task<Void, Never>?
    private var automaticTask: Task<Void, Never>?
    private var worker: LibraryModel?
    private var reverse: PFReverseImportModel?
    private var observation: AnyCancellable?
    private var pauseRequested = false
    private let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PonteFotos/album-jobs")) {
        self.directory = directory
    }
    private func accountScope(_ model: LibraryModel) -> String? {
        guard let account = model.preferenceTransferAccountID else { return nil }
        return PFUploadFollowIdentity.scope(profileID: model.profile.id, userID: account)
    }
    func reload(_ model: LibraryModel) {
        guard !running else { return }
        guard let current = accountScope(model) else { scope = ""; links = []; selected = []; return }
        guard current != scope else { return }
        do {
            let file = directory.appendingPathComponent(current + ".json")
            let data: Data
            do { data = try Data(contentsOf: file) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { data = Data("[]".utf8) }
            var loaded = try JSONDecoder().decode([PFAlbumSyncLink].self, from: data)
            // Import existing assisted links once, with automatic transfer off.
            if !FileManager.default.fileExists(atPath: file.path) { loaded = try model.legacyAlbumSyncLinks() }
            guard Set(loaded.map(\.id)).count == loaded.count else { throw CocoaError(.fileReadCorruptFile) }
            links = loaded; selected = []; scope = current
            if !loaded.isEmpty && !FileManager.default.fileExists(atPath: file.path) { try save(loaded) }
        } catch { scope = ""; links = []; selected = []; status = PFMessage.error(error) }
    }
    private func save(_ values: [PFAlbumSyncLink], scope explicitScope: String? = nil) throws {
        let targetScope = explicitScope ?? scope
        guard targetScope.count == 64, targetScope.allSatisfy(\.isHexDigit) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent(targetScope + ".json")
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if explicitScope == nil || explicitScope == scope { links = values }
    }
    func disablePair(scope requestedScope: String, photosID: String, immichID: String) {
        guard !running, requestedScope.count == 64, requestedScope.allSatisfy(\.isHexDigit) else { return }
        do {
            let file = directory.appendingPathComponent(requestedScope + ".json")
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            var values = try JSONDecoder().decode([PFAlbumSyncLink].self, from: Data(contentsOf: file))
            for index in values.indices where values[index].photosID == photosID && values[index].immichID == immichID { values[index].automatic = false }
            try save(values, scope: requestedScope)
        } catch { status = PFMessage.error(error) }
    }
    func add(photos: [AlbumItem], immich: ImmichAlbum, direction: PFAlbumSyncDirection) {
        guard !running else { return }
        do {
            var updated = links
            for photo in photos where photo.id != "all" {
                if let index = updated.firstIndex(where: { $0.photosID == photo.id && $0.immichID == immich.id }) {
                    updated[index].direction = direction
                } else { updated.append(PFAlbumSyncLink(photosID: photo.id, photosTitle: photo.displayTitle, immichID: immich.id, immichTitle: immich.albumName, direction: direction)) }
            }
            try save(updated)
        } catch { status = PFMessage.error(error) }
    }
    func setAutomatic(_ enabled: Bool, id: String) {
        guard !running, let index = links.firstIndex(where: { $0.id == id }) else { return }
        do { var updated = links; updated[index].automatic = enabled; try save(updated) }
        catch { status = PFMessage.error(error) }
    }
    func remove(_ id: String) {
        guard !running else { return }
        do { try save(links.filter { $0.id != id }); selected.remove(id) }
        catch { status = PFMessage.error(error) }
    }
    func pause() {
        pauseRequested = true
        do { var paused = links; for index in paused.indices { paused[index].automatic = false }; if !scope.isEmpty { try save(paused) } }
        catch { status = PFMessage.error(error) }
        worker?.stopRequested = true; reverse?.requestPauseAfterItem()
        status = M("Pausa solicitada. Envios param entre mídias; preparos locais podem ser cancelados.")
    }
    func pauseIfRunning() { if running { pause() } }
    func shutdown() { pauseIfRunning(); task?.cancel(); automaticTask?.cancel(); automaticTask = nil }
    func startAutomatic(model: LibraryModel) {
        guard automaticTask == nil else { return }
        automaticTask = Task { [weak self, model] in await self?.automaticLoop(model: model) }
    }
    private func acquire(_ model: LibraryModel) -> Bool {
        guard !running, !model.busy, !model.automationRunning, !model.showManagement, !model.managementBusy,
              model.editing == nil, model.inspectingMedia == nil,
              model.backgroundPreparation == nil, !model.hasPreparedFiles, model.transferReady else {
            status = M("Conclua ou pause a outra transferência e valide a conta antes de acompanhar álbuns."); return false
        }
        running = true; pauseRequested = false; attention = nil; model.automationRunning = true
        return true
    }
    func sendSelection(_ model: LibraryModel) {
        guard model.sourceName == nil, !model.chosen.isEmpty, model.canSend else { return }
        let batch = model.items.filter { model.selection.contains($0.id) }
        let expectedProfile = model.profile, expectedScope = accountScope(model)
        let sourceAlbum = model.album, destination = model.destination, albumID = model.remoteAlbumID
        let albumName = model.newAlbumName, targetAlbums = model.remoteAlbums
        guard acquire(model) else { return }
        task = Task { [self, model] in
            defer { release(model) }
            do {
                guard !pauseRequested, !Task.isCancelled, model.profile == expectedProfile, accountScope(model) == expectedScope else { throw CancellationError() }
                let sender = try model.isolatedTransferWorker(); worker = sender
                sender.disableFollowForManualBatch()
                sender.items = batch; sender.selection = Set(batch.map(\.id)); sender.album = sourceAlbum
                sender.destination = destination; sender.remoteAlbumID = albumID
                sender.newAlbumName = albumName; sender.remoteAlbums = targetAlbums
                observation = sender.$statusMessage.sink { [weak self] in self?.status = $0 }
                try await sender.validateTransfer(requiredPermissions: [])
                guard !pauseRequested, !Task.isCancelled, model.profile == expectedProfile, accountScope(model) == expectedScope else { throw CancellationError() }
                await sender.sendSelected()
                status = sender.statusMessage
            } catch { status = PFMessage.error(error) }
        }
    }
    private func release(_ model: LibraryModel) {
        observation = nil; worker = nil; reverse = nil; task = nil
        running = false; model.finishBackgroundTransfers()
    }
    func run(_ ids: Set<String>, model: LibraryModel, transfer: Bool) {
        reload(model)
        let jobs = links.filter { ids.contains($0.id) }
        guard !jobs.isEmpty, accountScope(model) == scope, acquire(model) else { return }
        let expectedScope = scope, expectedProfile = model.profile
        task = Task { [self, model] in
            defer { release(model) }
            for job in jobs {
                if pauseRequested || Task.isCancelled { break }
                do {
                    guard model.profile == expectedProfile, accountScope(model) == expectedScope else {
                        throw BridgeError(message: M("A conexão ou conta mudou. O acompanhamento foi pausado."))
                    }
                    if transfer, let index = links.firstIndex(where: { $0.id == job.id }) {
                        var updated = links; updated[index].automatic = false; try save(updated)
                    }
                    status = M("Consultando o par de álbuns: \(job.photosTitle) ↔ \(job.immichTitle)…")
                    let sender = try model.isolatedTransferWorker(); worker = sender
                    observation = sender.$statusMessage.sink { [weak self] in self?.status = $0 }
                    try await sender.configureBackgroundFollow(photosAlbumID: job.photosID, immichAlbumID: job.immichID, createsFollow: job.direction != .download)
                    if pauseRequested || Task.isCancelled { break }
                    if job.direction != .download {
                        await sender.checkUploadFollow()
                        guard sender.uploadFollowQuerySucceeded else { throw BridgeError(message: sender.statusMessage) }
                        if transfer && !sender.items.isEmpty {
                            if pauseRequested { break }
                            sender.selection = Set(sender.items.map(\.id))
                            await sender.sendSelected()
                            guard !sender.stopRequested, sender.uploadMetrics?.completedItems == sender.items.count else {
                                throw BridgeError(message: M("Há itens com falha ou conferência pendente. O automático deste par foi pausado para revisão."))
                            }
                        }
                    }
                    // Re-read the destination after upload before the other direction;
                    // originals are compared by role/hash rather than an upload receipt.
                    if job.direction != .upload {
                        if pauseRequested { break }
                        guard let connection = sender.transferConnection else { throw BridgeError(message: M("Valide a conta para transferir.")) }
                        let importer = PFReverseImportModel(); reverse = importer
                        importer.verifyOriginalBytes = true
                        observation = importer.$statusMessage.sink { [weak self] in self?.status = $0 }
                        let preflight: ([String]) async throws -> Void = { expected in
                            guard model.profile == expectedProfile, self.accountScope(model) == expectedScope, !self.pauseRequested else { throw CancellationError() }
                            try await sender.validateTransfer(requiredPermissions: PFTransferConnection.importPermissions)
                            guard !self.pauseRequested, model.profile == expectedProfile, self.accountScope(model) == expectedScope,
                                  expected == [sender.transferAddress, sender.transferKey, sender.profile.id] else { throw CancellationError() }
                        }
                        await importer.load(address: connection.address, key: connection.credential.key, profileID: expectedProfile.id, expectedUserID: connection.userID, preflight: preflight)
                        guard importer.albums.contains(where: { $0.id == job.immichID }), !pauseRequested else { throw BridgeError(message: importer.statusMessage) }
                        await importer.loadPhotosAlbums()
                        try importer.configureBackgroundFollow(immichAlbumID: job.immichID, photosAlbumID: job.photosID)
                        await importer.loadAlbum(preflight: preflight)
                        guard importer.albumQuerySucceeded else { throw BridgeError(message: importer.statusMessage) }
                        guard !importer.items.contains(where: { !$0.selectable }) else {
                            throw BridgeError(message: M("Há itens bloqueados no álbum. Confira a comparação antes de ativar o automático."))
                        }
                        if transfer && !importer.items.isEmpty {
                            importer.selection = Set(importer.items.filter(\.selectable).map(\.id))
                            await importer.importSelected(preflight: preflight)
                            guard importer.lastImportSucceeded else {
                                throw BridgeError(message: M("Há itens com falha ou conferência pendente. O automático deste par foi pausado para revisão."))
                            }
                        }
                    }
                    if pauseRequested { break }
                    if let index = links.firstIndex(where: { $0.id == job.id }) {
                        var updated = links; updated[index].lastChecked = Date()
                        if transfer { updated[index].automatic = job.automatic && !pauseRequested }
                        try save(updated)
                    }
                    status = transfer ? M("Par de álbuns concluído: \(job.photosTitle).") : M("Consulta concluída: \(job.photosTitle). Nenhuma mídia transferida.")
                    outcomes[job.id] = status
                } catch {
                    // Do not replay a partially committed or ambiguous operation on a timer.
                    if let index = links.firstIndex(where: { $0.id == job.id }) {
                        var updated = links; updated[index].automatic = false
                        do { try save(updated) } catch { status = PFMessage.error(error); break }
                    }
                    status = PFMessage.error(error); outcomes[job.id] = status; attention = status
                    if pauseRequested || Task.isCancelled { break }
                }
                observation = nil; worker = nil; reverse = nil
            }
        }
    }
    func automaticLoop(model: LibraryModel) async {
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
            reload(model)
            let enabled = Set(links.filter(\.automatic).map(\.id))
            if !enabled.isEmpty && !running && !model.busy { run(enabled, model: model, transfer: true) }
        }
    }
}

@MainActor private final class PFAlbumSyncUI: ObservableObject {
    @Published var photos = Set<String>()
    @Published var target = ""
    @Published var direction = PFAlbumSyncDirection.upload
    @Published var confirming = false
    @Published var confirmedIDs = Set<String>()
}
struct PFAlbumSyncView: View {
    @ObservedObject var coordinator: PFAlbumSyncCoordinator
    @ObservedObject var model: LibraryModel
    @StateObject private var ui = PFAlbumSyncUI()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(L("Álbuns acompanhados")).font(.title2.bold()); Spacer(); Button(L("Concluir")) { coordinator.showing = false } }
            Text(L("Escolha os álbuns do Fotos, o destino no Immich e o sentido. O automático transfere os itens ausentes a cada 5 minutos, enquanto o app estiver aberto. Não propaga exclusões."))
                .font(.callout).foregroundStyle(.secondary)
            Text(model.transferAccountLabel).font(.headline)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(model.albums.filter { $0.id != "all" }) { album in
                            Toggle(album.displayTitle, isOn: Binding(get: { ui.photos.contains(album.id) }, set: { if $0 { ui.photos.insert(album.id) } else { ui.photos.remove(album.id) } }))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 150)
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L("Destino no Immich"), selection: $ui.target) {
                        Text(L("Selecione um álbum")).tag("")
                        ForEach(model.remoteAlbums) { Text($0.albumName).tag($0.id) }
                    }
                    Picker(L("Sentido"), selection: $ui.direction) { ForEach(PFAlbumSyncDirection.allCases) { Text($0.title).tag($0) } }
                    Button(L("Adicionar álbuns selecionados")) {
                        if let destination = model.remoteAlbums.first(where: { $0.id == ui.target }) {
                            coordinator.add(photos: model.albums.filter { ui.photos.contains($0.id) }, immich: destination, direction: ui.direction)
                            ui.photos = []
                        }
                    }.disabled(ui.photos.isEmpty || ui.target.isEmpty)
                }.frame(width: 310)
            }.disabled(coordinator.running)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(coordinator.links) { link in
                        HStack(alignment: .top) {
                            Toggle(isOn: Binding(get: { coordinator.selected.contains(link.id) }, set: { if $0 { coordinator.selected.insert(link.id) } else { coordinator.selected.remove(link.id) } })) { EmptyView() }.labelsHidden()
                            VStack(alignment: .leading, spacing: 4) {
                                Text(link.photosTitle + " ↔ " + link.immichTitle).font(.headline)
                                Text(link.direction.title).font(.caption).foregroundStyle(.secondary)
                                if let result = coordinator.outcomes[link.id] { Text(result.text).font(.caption).foregroundStyle(.secondary) }
                                if let date = link.lastChecked { Text(PFLocalization.formatDate(date, date: .abbreviated, time: .shortened)).font(.caption) }
                            }
                            Spacer()
                            Toggle(L("Automático"), isOn: Binding(get: { link.automatic }, set: { coordinator.setAutomatic($0, id: link.id) }))
                            Button(L("Executar")) { ui.confirmedIDs = [link.id]; ui.confirming = true }
                            Button(L("Remover")) { coordinator.remove(link.id) }
                        }.disabled(coordinator.running)
                    }
                }
            }.frame(minHeight: 100, maxHeight: 210)
            Text(coordinator.status.text).font(.caption).textSelection(.enabled)
            HStack {
                if coordinator.running { ProgressView().controlSize(.small); Button(L("Pausar após a mídia atual")) { coordinator.pause() } }
                else {
                    Button(L("Consultar selecionados")) { coordinator.run(coordinator.selected, model: model, transfer: false) }.disabled(coordinator.selected.isEmpty)
                    Button(L("Executar selecionados")) { ui.confirmedIDs = coordinator.selected; ui.confirming = true }.disabled(coordinator.selected.isEmpty)
                    Button(L("Executar todos")) { ui.confirmedIDs = Set(coordinator.links.map(\.id)); ui.confirming = true }.disabled(coordinator.links.isEmpty)
                }
            }
            Text(L("Uma mídia completa por vez. Ainda é necessário espaço para os originais da mídia atual e seu envio. O Fotos pode manter seus próprios downloads do iCloud. Cópias iguais são comparadas por hash; divergências ficam para revisão."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 820, height: 660)
        .task { coordinator.reload(model); await model.refreshAlbums() }
        .confirmationDialog(L("Executar os acompanhamentos selecionados?"), isPresented: $ui.confirming, titleVisibility: .visible) {
            Button(L("Transferir itens ausentes")) { coordinator.run(ui.confirmedIDs, model: model, transfer: true) }
        } message: { Text(L("As mídias ausentes serão enviadas ou importadas somente nos pares e sentidos selecionados. Os originais serão preservados. Resultados pendentes interrompem o automático desse par.")) }
    }
}
