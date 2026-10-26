import SwiftUI
import AppKit

@MainActor
final class IMWorkspaceModel: ObservableObject {
    @Published var credentials: [IMCredential] = []
    @Published var scopes: [String: Set<String>] = [:]
    @Published var albums: [IMAlbum] = []
    @Published var people: [IMPerson] = []
    @Published var history: [IMHistoryEntry] = []
    @Published var busy = false
    @Published var canCancel = false
    private var operationTask: Task<Void, Never>?
    @Published var progressMessage: PFMessage = ""
    var progress: String { get { progressMessage.text } set { progressMessage = .verbatim(newValue) } }
    @Published var errorMessage: PFMessage?
    var error: String? { get { errorMessage?.text } set { errorMessage = newValue.map(PFMessage.verbatim) } }
    @Published var duplicates: IMDuplicateAnalysis?
    @Published var comparison: IMComparisonAnalysis?
    @Published var age: IMAgeAnalysis?
    @Published var duplicateChoices: [String: String] = [:]
    @Published var comparisonChoices: [String: String] = [:]
    @Published var ageChoices: Set<String> = []
    @Published var address: String
    let primaryKey: String
    let profileID: String
    @Published var connectionReady: Bool
    let onBusyChanged: (Bool) -> Void
    private var cache: [String: NSImage] = [:]
    private var loaded = false
    fileprivate let ui = IMWorkspaceUIState()

    init(address: String, primaryKey: String, profileID: String, connectionReady: Bool, onBusyChanged: @escaping (Bool) -> Void) {
        self.address = address; self.primaryKey = primaryKey; self.profileID = profileID
        self.connectionReady = connectionReady; self.onBusyChanged = onBusyChanged
    }
    func updateConnection(address: String, ready: Bool) {
        guard !busy else { return }
        if self.address != address {
            self.address = address
            albums = []; people = []; duplicates = nil; comparison = nil; age = nil
            duplicateChoices = [:]; comparisonChoices = [:]; ageChoices = []; cache.removeAll()
            errorMessage = M("O endereço de conexão mudou. Atualize os álbuns e faça uma nova consulta.")
        }
        connectionReady = ready
    }
    func endReview() {
        guard !busy else { return }
        duplicates = nil; comparison = nil; age = nil
        duplicateChoices = [:]; comparisonChoices = [:]; ageChoices = []
        ui.reviewKind = nil; ui.reviewAccepted = false; error = nil
    }
    var session: IMSession { IMSession(address: address, profileID: profileID, credentials: credentials) }
    func name(_ id: String) -> String {
        if let account = credentials.first(where: { $0.account.id == id }) { return account.account.displayName }
        func knownName(_ assets: [IMAsset]) -> String? {
            assets.first(where: { $0.ownerId == id && !($0.ownerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.ownerName
        }
        for group in duplicates?.groups ?? [] { if let name = knownName(group.assets) { return name } }
        for suggestion in duplicates?.suggestions ?? [] { if let name = knownName(suggestion.assets) { return name } }
        for group in comparison?.groups ?? [] { if let name = knownName(group.assets) { return name } }
        if let name = knownName(age?.assets ?? []) { return name }
        for entry in history { if let name = knownName(entry.assets) { return name } }
        return L("Conta não conectada")
    }
    func load() {
        guard !loaded else { return }; loaded = true
        do {
            credentials = try IMManagementStore.credentials(profileID: profileID)
            history = try IMManagementStore.history(profileID: profileID)
            var changed = false
            for i in history.indices where history[i].status == "running" { history[i].status = "interrupted"; changed = true }
            if changed { try persistHistory() }
        } catch { self.errorMessage = .error(error) }
    }
    func run(_ message: PFMessage, cancellable: Bool = true, operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        guard connectionReady else { errorMessage = M("A conexão mudou ou ainda não foi validada. Feche esta janela e teste a conexão antes de consultar ou alterar o Immich."); return }
        busy = true; error = nil; progressMessage = message; canCancel = cancellable; onBusyChanged(true)
        operationTask = Task { @MainActor in
            defer { busy = false; canCancel = false; operationTask = nil; onBusyChanged(false); progressMessage = "" }
            do { try await operation() } catch is CancellationError { } catch { self.errorMessage = .error(error) }
        }
    }
    func cancelQuery() { guard canCancel else { return }; canCancel = false; progressMessage = M("Cancelando consulta…"); operationTask?.cancel() }
    func updateProgress(_ text: PFMessage, _ current: Int, _ total: Int) {
        progressMessage = total > 0 ? M("\(text) · \(current)/\(total)") : text
    }
    func connect(key: String, persist: Bool) {
        run(M("Verificando conta e permissões…")) {
            let credential = try await IMManagementStore.verify(address: self.address, key: key)
            let permissions = try await IMClient(address: self.address, credential: credential).permissions()
            let minimum: Set<String> = ["asset.read", "album.read"]
            let missing = minimum.subtracting(permissions)
            guard permissions.contains("all") || missing.isEmpty else {
                throw BridgeError(message: M("A chave de \(credential.account.displayMessage) precisa destas permissões para gerenciar fotos: \(missing.sorted().joined(separator: ", ")). Ajuste a chave no Immich e conecte novamente."))
            }
            if persist { try IMManagementStore.saveCredential(credential, profileID: self.profileID) }
            self.credentials.removeAll { $0.account.id == credential.account.id }
            self.credentials.append(credential); self.scopes[credential.account.id] = permissions
        }
    }
    func disconnect(_ id: String) {
        guard !busy else { return }
        do {
            try IMManagementStore.removeCredential(accountID: id, profileID: profileID)
            credentials.removeAll { $0.account.id == id }; scopes.removeValue(forKey: id); cache.removeAll()
            albums = []; people = []; duplicates = nil; comparison = nil; age = nil
        } catch { self.errorMessage = .error(error) }
    }
    func refresh() {
        run(M("Atualizando álbuns e pessoas…")) {
            let snapshot = self.session
            self.albums = try await snapshot.albums()
            self.people = try await snapshot.people()
        }
    }
    func scanDuplicates(_ selected: Set<String>) {
        let chosen = albums.filter { selected.contains($0.id) }
        run(M("Procurando cópias idênticas…")) {
            let result = try await IMDuplicates.scan(session: self.session, albums: chosen, progress: self.updateProgress)
            self.duplicates = result
            self.duplicateChoices = Dictionary(uniqueKeysWithValues: result.groups.filter { $0.unavailableOwnerIDs.isEmpty }.map { ($0.id, $0.keepID) })
        }
    }
    func scanComparison(_ selected: Set<String>) {
        let chosen = albums.filter { selected.contains($0.id) }
        run(M("Comparando álbuns…")) {
            self.comparison = try await IMOrganization.compare(session: self.session, albums: chosen, progress: self.updateProgress)
            self.comparisonChoices = [:]
        }
    }
    func searchAge(personKey: String, sourceID: String, destinationID: String, min: Int, max: Int) {
        guard let person = people.first(where: { $0.key == personKey }), let destination = albums.first(where: { $0.id == destinationID }) else { return }
        let source = albums.first { $0.id == sourceID }
        run(M("Buscando fotos por idade…")) {
            let result = try await IMOrganization.ageSearch(session: self.session, person: person, source: source, destination: destination, minAge: min, maxAge: max, progress: self.updateProgress)
            self.age = result; self.ageChoices = Set(result.assets.map(\.id))
        }
    }
    var unsafeLiveRemoval: Bool {
        guard let duplicates else { return false }
        return duplicates.groups.contains { group in
            guard let keeper = duplicateChoices[group.id] else { return false }
            return group.assets.contains { $0.id != keeper && $0.isLive }
        }
    }
    func persistHistory() throws {
        try IMManagementStore.saveHistory(Array(history.prefix(20)), profileID: profileID)
    }
    func record(_ value: IMActionRecord, entryID: String) throws {
        guard let i = history.firstIndex(where: { $0.id == entryID }) else { throw BridgeError(message: M("Histórico indisponível. Operação interrompida antes de continuar.")) }
        if let j = history[i].records.firstIndex(where: { $0.id == value.id }) { history[i].records[j] = value }
        else { history[i].records.append(value) }
        try persistHistory()
    }
    func execute(_ kind: String) {
        guard !busy else { return }
        let snapshot = session
        let assets: [IMAsset]
        let title: String
        if kind == "duplicates", let duplicates {
            guard !unsafeLiveRemoval else { errorMessage = M("Uma Live Photo seria enviada à lixeira. Escolha manter a Live Photo ou desmarque o grupo."); return }
            assets = duplicates.groups.filter { duplicateChoices[$0.id] != nil }.flatMap(\.assets); title = "Revisão de duplicatas"
        } else if kind == "comparison", let comparison {
            assets = comparison.groups.filter { comparisonChoices[$0.id] != nil }.flatMap(\.assets); title = "Organização de álbuns"
        } else if kind == "age", let age {
            assets = age.assets.filter { ageChoices.contains($0.id) }; title = "Organização por idade"
        } else { return }
        let entry = IMHistoryEntry(title: title, kind: kind, assets: assets)
        run(M("Preparando operação…"), cancellable: false) {
            self.history.insert(entry, at: 0); self.history = Array(self.history.prefix(20))
            do {
                try self.persistHistory() // Fail closed before any server change.
                let report: IMReport = { try self.record($0, entryID: entry.id) }
                if kind == "duplicates", let analysis = self.duplicates {
                    try await IMDuplicates.trash(session: snapshot, analysis: analysis, selections: self.duplicateChoices, progress: self.updateProgress, report: report)
                    self.duplicates = nil; self.duplicateChoices = [:]
                } else if kind == "comparison", let analysis = self.comparison {
                    try await IMOrganization.organize(session: snapshot, analysis: analysis, selections: self.comparisonChoices, progress: self.updateProgress, report: report)
                    self.comparison = nil; self.comparisonChoices = [:]
                } else if kind == "age", let analysis = self.age {
                    try await IMOrganization.ageMove(session: snapshot, analysis: analysis, selectedIDs: self.ageChoices, progress: self.updateProgress, report: report)
                    self.age = nil; self.ageChoices = []
                }
                if let i = self.history.firstIndex(where: { $0.id == entry.id }) { self.history[i].status = "completed" }
                try self.persistHistory()
            } catch {
                if let i = self.history.firstIndex(where: { $0.id == entry.id }) { self.history[i].status = "failed" }
                do { try self.persistHistory() } catch { throw BridgeError(message: M("Não foi possível salvar o histórico. A operação foi interrompida; confira o Immich antes de repetir qualquer ação.")) }
                throw error
            }
        }
    }
    func thumbnail(_ asset: IMAsset) async -> NSImage? {
        if let image = cache[asset.id] { return image }
        guard let client = try? session.owner(asset.ownerId), let data = try? await client.thumbnail(asset.id), let image = NSImage(data: data) else { return nil }
        if cache.count >= 120 { cache.removeAll() }; cache[asset.id] = image; return image
    }
}

@MainActor
fileprivate final class IMWorkspaceUIState: ObservableObject {
    @Published var tab = "Álbuns"
    @Published var albumSearch = ""
    @Published var owner = ""
    @Published var selectedAlbums: Set<String> = []
    @Published var allComparison = false
    @Published var duplicatePage = 0
    @Published var comparisonPage = 0
    @Published var agePage = 0
    @Published var accountKey = ""
    @Published var ageAccount = ""
    @Published var personKey = ""
    @Published var sourceID = ""
    @Published var destinationID = ""
    @Published var minAge = 0
    @Published var maxAge = 1
    @Published var reviewKind: String?
    @Published var reviewAccepted = false
    @Published var reviewPage = 0
    @Published var suggestionPage = 0
}

struct ImmichWorkspaceView: View {
    @ObservedObject private var localization = PFLocalization.shared
    @StateObject private var model: IMWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ui: IMWorkspaceUIState
    private let currentAddress: String
    private let currentReady: Bool
    private let pageSize = 8

    init(address: String, primaryKey: String, profileID: String, connectionReady: Bool, onBusyChanged: @escaping (Bool) -> Void) {
        self.init(model: IMWorkspaceModel(address: address, primaryKey: primaryKey, profileID: profileID, connectionReady: connectionReady, onBusyChanged: onBusyChanged), address: address, connectionReady: connectionReady)
    }
    init(model: IMWorkspaceModel, address: String, connectionReady: Bool) {
        _model = StateObject(wrappedValue: model)
        _ui = ObservedObject(wrappedValue: model.ui)
        currentAddress = address; currentReady = connectionReady
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Picker(L("Área"), selection: $ui.tab) {
                ForEach(["Álbuns", "Comparar álbuns", "Pessoa e idade", "Contas e API", "Histórico"], id: \.self) { Text(LV($0)).tag($0) }
            }.id(PFLocalization.languageCode).pickerStyle(.segmented).controlSize(.large).disabled(model.busy)
            if model.busy { HStack { ProgressView().controlSize(.small); Text(model.progress).font(.callout); Spacer(); if model.canCancel { Button(L("Cancelar consulta")) { model.cancelQuery() } } } }
            if let error = model.error {
                HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle.fill"); Text(error).textSelection(.enabled); Spacer(); Button(L("Dispensar")) { model.error = nil } }.foregroundStyle(.red).padding(12).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch ui.tab {
                    case "Contas e API": accountsView
                    case "Histórico": historyView
                    case "Pessoa e idade": ageView
                    default: albumSelector; if ui.tab == "Álbuns" { duplicatesView } else { comparisonView }
                    }
                }.padding(.bottom, 20).padding(.horizontal, 2)
            }.disabled(model.busy)
        }
        .padding(24).frame(minWidth: 760, idealWidth: 1060, minHeight: 660, idealHeight: 820)
        .background(PFTheme.background).tint(PFTheme.accent)
        .onAppear { model.updateConnection(address: currentAddress, ready: currentReady); model.load() }
        .onChange(of: currentAddress) { _, value in model.updateConnection(address: value, ready: currentReady) }
        .onChange(of: currentReady) { _, value in model.updateConnection(address: currentAddress, ready: value) }
        .interactiveDismissDisabled(model.busy)
        .sheet(isPresented: Binding(get: { ui.reviewKind != nil }, set: { if !$0 { ui.reviewKind = nil } })) { reviewView.environment(\.locale, PFLocalization.locale) }
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 25, weight: .medium)).foregroundStyle(PFTheme.accent)
                .frame(width: 52, height: 52).background(PFTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Gerenciar Immich")).font(.system(size: 26, weight: .bold))
                Text(L("Suas memórias, organizadas com cuidado.")).foregroundStyle(.secondary)
                Label(model.address, systemImage: model.connectionReady ? "checkmark.circle.fill" : "network")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(L("Concluir")) { dismiss() }.controlSize(.large).disabled(model.busy)
        }
    }
    private var filteredAlbums: [IMAlbum] {
        model.albums.filter { (ui.owner.isEmpty || $0.ownerID == ui.owner) && (ui.albumSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(ui.albumSearch)) }
    }
    private var albumSelector: some View {
        PFCard {
            VStack(alignment: .leading, spacing: 16) {
                PFSectionHeading(L("Seus álbuns"), subtitle: L("Escolha os álbuns que deseja revisar."), systemImage: "rectangle.stack")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { albumSearch; ownerPicker; refreshAlbums }
                    VStack(alignment: .leading, spacing: 12) { albumSearch; HStack { ownerPicker; Spacer(); refreshAlbums } }
                }
                if model.credentials.isEmpty {
                    Label(L("Conecte as contas em Contas e API para comparar suas cópias."), systemImage: "person.crop.circle.badge.plus").font(.callout).foregroundStyle(.secondary)
                }
                if !filteredAlbums.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredAlbums) { album in
                                Toggle(isOn: Binding(get: { ui.selectedAlbums.contains(album.id) }, set: { if $0 { ui.selectedAlbums.insert(album.id) } else { ui.selectedAlbums.remove(album.id) } })) {
                                    HStack(spacing: 12) {
                                        Image(systemName: album.shared ? "person.2.crop.square.stack" : "rectangle.stack").foregroundStyle(PFTheme.accent).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(album.name).fontWeight(.semibold)
                                            Text(L("\(model.name(album.ownerID)) · \(album.count) itens")).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 4)
                                        if album.shared { PFBadge(L("Compartilhado"), systemImage: "person.2") }
                                    }.padding(.vertical, 10)
                                }.toggleStyle(.checkbox)
                                if album.id != filteredAlbums.last?.id { Divider() }
                            }
                        }
                    }.frame(height: min(CGFloat(filteredAlbums.count) * 66, 240))
                }
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { albumSelectionButtons; Spacer(minLength: 12); scanAlbumsButton }
                    VStack(alignment: .leading, spacing: 12) { albumSelectionButtons; scanAlbumsButton }
                }
                Text(ui.tab == "Álbuns" ? L("Arquivos idênticos por checksum, entre todas as contas conectadas. Live Photos são identificadas e protegidas.") : L("Selecione exatamente dois álbuns. A organização altera apenas os vínculos com os álbuns; os arquivos permanecem na biblioteca.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var albumSearch: some View {
        HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField(L("Buscar álbum"), text: $ui.albumSearch).textFieldStyle(.plain) }
            .padding(9).background(PFTheme.background, in: RoundedRectangle(cornerRadius: 9)).frame(minWidth: 180)
    }
    private var ownerPicker: some View {
        Picker(L("Proprietário"), selection: $ui.owner) {
            Text(L("Todos")).tag("")
            ForEach(model.credentials.map(\.account)) { Text($0.name).tag($0.id) }
        }.frame(maxWidth: 270)
    }
    private var refreshAlbums: some View {
        Button { model.refresh() } label: { Label(L("Atualizar álbuns"), systemImage: "arrow.clockwise") }.disabled(model.credentials.isEmpty || !model.connectionReady)
    }
    private var albumSelectionButtons: some View {
        HStack(spacing: 12) {
            Button(L("Selecionar visíveis")) { ui.selectedAlbums.formUnion(filteredAlbums.map(\.id)) }
            Button(L("Limpar seleção")) { ui.selectedAlbums = [] }.foregroundStyle(.secondary)
        }
    }
    private var scanAlbumsButton: some View {
        Button {
            ui.duplicatePage = 0; ui.comparisonPage = 0; ui.suggestionPage = 0
            if ui.tab == "Álbuns" { model.scanDuplicates(ui.selectedAlbums) } else { model.scanComparison(ui.selectedAlbums) }
        } label: {
            Label(ui.tab == "Álbuns" ? L("Consultar duplicatas · \(ui.selectedAlbums.count) álbuns") : L("Comparar seleção"), systemImage: ui.tab == "Álbuns" ? "square.on.square" : "rectangle.on.rectangle")
        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.connectionReady || ui.selectedAlbums.isEmpty || (ui.tab != "Álbuns" && ui.selectedAlbums.count != 2))
    }
    private var duplicatesView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result = model.duplicates {
                Text(L("Cópias exatas por hash")).font(.title3.bold())
                Text(L("\(result.groups.count) grupos · \(result.skipped) itens fora da análise")).font(.headline)
                Text(L("A Live Photo é sugerida para manter. Cada cópia mostra sua conta, formato e álbuns atuais.")).foregroundStyle(.secondary)
                HStack {
                    Button(L("Selecionar todos")) { model.duplicateChoices = Dictionary(uniqueKeysWithValues: result.groups.filter { $0.unavailableOwnerIDs.isEmpty }.map { ($0.id, $0.keepID) }) }
                    Button(L("Desmarcar todos")) { model.duplicateChoices = [:] }
                    Spacer()
                    Button(L("Revisar envio à lixeira")) { openReview("duplicates") }.disabled(!model.connectionReady || model.duplicateChoices.isEmpty || model.unsafeLiveRemoval)
                }
                if model.unsafeLiveRemoval { Text(L("Uma escolha removeria uma Live Photo. Mantenha a versão com movimento ou desmarque esse grupo.")).foregroundStyle(.orange) }
                ForEach(page(result.groups, ui.duplicatePage)) { group in duplicateGroup(group) }
                pager(count: result.groups.count, index: $ui.duplicatePage)
                if result.groups.isEmpty { empty(L("Nenhuma cópia idêntica encontrada.")) }
                Divider()
                suggestionResults(result.suggestions ?? [])
            } else { empty(L("Selecione os álbuns e consulte as duplicatas para começar.")) }
        }
    }
    private func suggestionResults(_ suggestions: [IMDuplicateSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Possíveis duplicatas · \(suggestions.count)")).font(.headline)
            Text(L("Complemento por metadados: mesmo nome, dimensões e captura com até 1 segundo de diferença. Os arquivos têm hashes diferentes; compare as imagens antes de decidir. As sugestões não entram no envio à lixeira.")).foregroundStyle(.secondary)
            Text(L("A análise compara até dez vizinhos por item. Em conjuntos muito repetitivos, outros pares podem não aparecer.")).font(.caption).foregroundStyle(.secondary)
            if suggestions.count == 500 { Text(L("Limite de 500 sugestões atingido. Analise menos álbuns para conferir os demais pares.")).foregroundStyle(.orange) }
            ForEach(page(suggestions, ui.suggestionPage)) { suggestion in
                PFCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L("Revisão visual necessária"), systemImage: "photo.on.rectangle.angled").font(.headline)
                        if suggestion.assets.contains(where: { asset in !model.credentials.contains(where: { $0.account.id == asset.ownerId }) }) {
                            Text(L("Conecte a conta proprietária em Contas e API para carregar a prévia.")).font(.caption).foregroundStyle(.orange)
                        }
                        if suggestion.assets.contains(where: \.isLive) {
                            Text(L("Este par inclui uma Live Photo. Preserve a versão com movimento ao revisar.")).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .top)], alignment: .leading, spacing: 12) {
                            ForEach(suggestion.assets) { asset in assetCard(asset) }
                        }
                    }
                }
            }
            pager(count: suggestions.count, index: $ui.suggestionPage)
            if suggestions.isEmpty { Text(L("Nenhuma sugestão por metadados encontrada. Isso não garante ausência de fotos semelhantes.")).foregroundStyle(.secondary) }
        }
    }
    private func duplicateGroup(_ group: IMDuplicateGroup) -> some View {
        PFCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L("Revisar grupo · \(group.assets.count) cópias"), isOn: Binding(get: { model.duplicateChoices[group.id] != nil }, set: { model.duplicateChoices[group.id] = $0 ? group.keepID : nil })).font(.headline).disabled(!group.unavailableOwnerIDs.isEmpty)
                if !group.unavailableOwnerIDs.isEmpty { Text(L("Conecte em Contas e API: ") + group.unavailableOwnerIDs.map { model.name($0) }.joined(separator: ", ") + L(". Depois, refaça a consulta para alterar este grupo.")).font(.caption).foregroundStyle(.orange) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(group.assets) { asset in
                        VStack(alignment: .leading, spacing: 10) {
                            assetCard(asset)
                            Button {
                                model.duplicateChoices[group.id] = asset.id
                            } label: { Label(model.duplicateChoices[group.id] == asset.id ? L("Manter esta cópia") : L("Escolher para manter"), systemImage: model.duplicateChoices[group.id] == asset.id ? "largecircle.fill.circle" : "circle") }
                        }.disabled(!group.unavailableOwnerIDs.isEmpty).padding(10)
                            .background(model.duplicateChoices[group.id] == asset.id ? PFTheme.accent.opacity(0.05) : PFTheme.background, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(model.duplicateChoices[group.id] == asset.id ? PFTheme.accent : PFTheme.separator, lineWidth: model.duplicateChoices[group.id] == asset.id ? 2 : 1))
                    }
                }
            }
        }
    }
    private var comparisonGroups: [IMComparisonGroup] { model.comparison?.groups.filter { ui.allComparison || $0.common } ?? [] }
    private var comparisonView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result = model.comparison {
                Toggle(L("Mostrar também itens exclusivos"), isOn: $ui.allComparison).onChange(of: ui.allComparison) { ui.comparisonPage = 0; model.comparisonChoices = [:] }
                Text(L("\(comparisonGroups.count) grupos visíveis · \(result.skipped) itens fora da análise")).font(.headline)
                Text(L("Cada grupo começa sem alteração. Escolha um destino para reunir as cópias nesse álbum ou manter nos dois. Live Photos, pilhas, arquivos offline e editados ficam fora da análise.")).foregroundStyle(.secondary)
                ForEach(page(comparisonGroups, ui.comparisonPage)) { group in
                    PFCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.common ? L("Presente nos dois álbuns") : L("Item exclusivo")).font(.headline)
                            Picker(L("Ação"), selection: Binding(get: { model.comparisonChoices[group.id] ?? "" }, set: { model.comparisonChoices[group.id] = $0.isEmpty ? nil : $0 })) {
                                Text(L("Sem alteração")).tag(""); Text(L("Manter nos dois álbuns")).tag("both")
                                ForEach(result.albums) { Text(L("Reunir em \($0.name)")).tag($0.id) }
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250))]) { ForEach(group.assets) { assetCard($0) } }
                        }
                    }
                }
                pager(count: comparisonGroups.count, index: $ui.comparisonPage)
                Button(L("Revisar organização")) { openReview("comparison") }.disabled(!model.connectionReady || model.comparisonChoices.isEmpty)
            } else { empty(L("Compare dois álbuns para revisar suas fotos em comum. Live Photos, pilhas, arquivos offline e editados ficam fora desta análise.")) }
        }
    }
    private var ageView: some View {
        VStack(alignment: .leading, spacing: 16) {
            PFSectionHeading(L("Pessoa e idade"), subtitle: L("Reúna cada fase da vida em um álbum."), systemImage: "person.crop.rectangle")
            Text(L("A idade considera a data da captura e o aniversário registrado no Immich. Os limites são inclusivos. Live Photos, pilhas, arquivos offline e editados ficam fora da análise.")).foregroundStyle(.secondary)
            Button(L("Atualizar álbuns e pessoas")) { model.refresh() }.disabled(model.credentials.isEmpty || !model.connectionReady)
            PFCard {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                GridRow { Text(L("Conta")); Picker(L("Conta"), selection: $ui.ageAccount) { Text(L("Todas as contas")).tag(""); ForEach(model.credentials.map(\.account)) { Text($0.name).tag($0.id) } }.id(PFLocalization.languageCode).labelsHidden().onChange(of: ui.ageAccount) { ui.personKey = "" } }
                GridRow { Text(L("Pessoa")); Picker(L("Pessoa"), selection: $ui.personKey) { Text(L("Selecione uma pessoa")).tag(""); ForEach(model.people.filter { ui.ageAccount.isEmpty || $0.accountID == ui.ageAccount }, id: \.key) { Text("\($0.displayName) · \(model.name($0.accountID))").tag($0.key) } }.id(PFLocalization.languageCode).labelsHidden() }
                GridRow { Text(L("Aniversário")); Text(model.people.first { $0.key == ui.personKey }?.birthDate ?? L("Cadastre a data de nascimento no Immich.")).foregroundStyle(.secondary) }
                GridRow { Text(L("Origem")); Picker(L("Origem"), selection: $ui.sourceID) { Text(L("Todos os álbuns acessíveis")).tag(""); ForEach(model.albums) { Text($0.name).tag($0.id) } }.id(PFLocalization.languageCode).labelsHidden() }
                GridRow { Text(L("Destino")); Picker(L("Destino"), selection: $ui.destinationID) { Text(L("Selecione um álbum")).tag(""); ForEach(model.albums) { Text($0.name).tag($0.id) } }.id(PFLocalization.languageCode).labelsHidden() }
                GridRow { Text(L("Idade em anos")); HStack { Stepper(L("De \(ui.minAge)"), value: $ui.minAge, in: 0...150).frame(maxWidth: 180); Spacer(minLength: 20); Stepper(L("Até \(ui.maxAge)"), value: $ui.maxAge, in: 0...150).frame(maxWidth: 180) } }
            }
            }
            Button(L("Buscar fotos")) { ui.agePage = 0; model.searchAge(personKey: ui.personKey, sourceID: ui.sourceID, destinationID: ui.destinationID, min: ui.minAge, max: ui.maxAge) }.buttonStyle(.borderedProminent).disabled(!model.connectionReady || ui.personKey.isEmpty || ui.destinationID.isEmpty || ui.sourceID == ui.destinationID || ui.minAge > ui.maxAge || model.people.first { $0.key == ui.personKey }?.birthDate == nil)
            if let result = model.age {
                Text(L("\(result.assets.count) fotos · \(result.skipped) itens fora da análise · destino: \(result.destination.name)")).font(.headline)
                HStack { Button(L("Selecionar todas")) { model.ageChoices = Set(result.assets.map(\.id)) }; Button(L("Desmarcar todas")) { model.ageChoices = [] }; Spacer(); Button(L("Revisar movimentação")) { openReview("age") }.disabled(!model.connectionReady || model.ageChoices.isEmpty) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250))]) {
                    ForEach(page(result.assets, ui.agePage)) { asset in VStack(alignment: .leading) { Toggle(L("Mover para \(result.destination.name)"), isOn: Binding(get: { model.ageChoices.contains(asset.id) }, set: { if $0 { model.ageChoices.insert(asset.id) } else { model.ageChoices.remove(asset.id) } })); assetCard(asset) } }
                }
                pager(count: result.assets.count, index: $ui.agePage)
            }
        }
    }
    private var accountsView: some View { IMAccountSettingsView(model: model) }
    private var historyView: some View {
        VStack(alignment: .leading, spacing: 14) {
            PFSectionHeading(L("Histórico de organização"), subtitle: L("Acompanhe as últimas 20 operações deste perfil."), systemImage: "clock.arrow.circlepath")
            Text(L("Operações interrompidas ou incertas exigem conferência no Immich. Nenhuma operação é repetida automaticamente.")).foregroundStyle(.secondary)
            if model.history.isEmpty { empty(L("Nenhuma operação executada neste perfil.")) }
            ForEach(model.history) { entry in
                PFCard {
                DisclosureGroup {
                    ForEach(entry.records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(actionName(record.action)) · \(record.name)").fontWeight(.medium)
                            Text("\(statusName(record.status)) · \(model.name(record.ownerID))\(record.albumName.map { " · " + $0 } ?? "")").font(.caption).foregroundStyle(record.status == "uncertain" ? Color.orange : Color.secondary)
                            if let keepID = record.keepID, let keeper = entry.assets.first(where: { $0.id == keepID }) { Text(L("Cópia mantida: \(keeper.originalFileName) · \(model.name(keeper.ownerId))")).font(.caption).foregroundStyle(.green) }
                            if let message = record.displayMessage { Text(message).font(.caption).textSelection(.enabled) }
                        }.padding(.vertical, 5)
                    }
                    DisclosureGroup(L("Prévia dos arquivos revisados (\(entry.assets.count))")) { IMHistoryPreviews(assets: entry.assets, model: model) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(LV(entry.title)).font(.headline)
                            HStack(spacing: 6) { Text(entry.date, style: .date); Text(entry.date, style: .time) }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        PFBadge(statusName(entry.status), systemImage: entry.status == "completed" ? "checkmark.circle" : "clock", color: entry.status == "completed" ? .green : .orange)
                    }
                }
                }
            }
        }
    }
    private func openReview(_ kind: String) { ui.reviewPage = 0; ui.reviewAccepted = false; ui.reviewKind = kind }
    private var reviewItems: [ReviewItem] {
        if ui.reviewKind == "duplicates", let analysis = model.duplicates {
            return analysis.groups.compactMap { group in
                guard let keep = model.duplicateChoices[group.id] else { return nil }
                return ReviewItem(id: group.id, title: L("Manter a cópia de \(model.name(group.assets.first { $0.id == keep }?.ownerId ?? ""))"), note: L("As demais cópias vão para a lixeira. Os vínculos de álbuns serão preservados na cópia mantida."), assets: group.assets, keepID: keep)
            }
        }
        if ui.reviewKind == "comparison", let analysis = model.comparison {
            return analysis.groups.compactMap { group in
                guard let choice = model.comparisonChoices[group.id] else { return nil }
                let title = choice == "both" ? L("Manter nos dois álbuns") : L("Reunir em \(analysis.albums.first { $0.id == choice }?.name ?? choice)")
                return ReviewItem(id: group.id, title: title, note: L("Os arquivos permanecem na biblioteca. Somente os vínculos dos dois álbuns comparados serão alterados."), assets: group.assets, keepID: nil)
            }
        }
        if ui.reviewKind == "age", let analysis = model.age {
            return analysis.assets.filter { model.ageChoices.contains($0.id) }.map { ReviewItem(id: $0.id, title: L("Mover para \(analysis.destination.name)"), note: L("Adicionar ao destino e remover dos álbuns de origem incluídos na análise."), assets: [$0], keepID: nil) }
        }
        return []
    }
    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 16) {
            PFSectionHeading(L("Revisar alterações"), subtitle: L("Confira cada cópia e destino antes de continuar."), systemImage: "checklist")
            Text(L("\(reviewItems.count) grupos ou fotos selecionados. Revise todas as páginas antes de confirmar.")).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(page(reviewItems, ui.reviewPage)) { item in
                        PFCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(item.title).font(.headline); Text(item.note).font(.caption).foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250))]) {
                                    ForEach(item.assets) { asset in VStack(alignment: .leading, spacing: 8) { if let keep = item.keepID { PFBadge(keep == asset.id ? L("Manter esta cópia") : L("Enviar à lixeira"), systemImage: keep == asset.id ? "checkmark.circle.fill" : "trash", color: keep == asset.id ? .green : .orange) }; assetCard(asset) } }
                                }
                            }.padding(8)
                        }
                    }
                }
            }
            pager(count: reviewItems.count, index: $ui.reviewPage)
            Divider()
            Toggle(L("Conferi as cópias, os destinos e os álbuns envolvidos e autorizo estas alterações."), isOn: $ui.reviewAccepted).toggleStyle(.checkbox).fixedSize(horizontal: false, vertical: true)
            HStack { Button(L("Cancelar")) { ui.reviewKind = nil }; Spacer(); Button(L("Confirmar alterações")) { guard let kind = ui.reviewKind else { return }; ui.reviewKind = nil; model.execute(kind) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!ui.reviewAccepted || reviewItems.isEmpty || (ui.reviewKind == "duplicates" && model.unsafeLiveRemoval)) }
        }.padding(24).frame(minWidth: 760, idealWidth: 940, minHeight: 620, idealHeight: 780).background(PFTheme.background).tint(PFTheme.accent)
    }
    private func assetCard(_ asset: IMAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IMAssetThumbnail(asset: asset, model: model).frame(height: 180).frame(maxWidth: .infinity).background(PFTheme.background, in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10))
            Text(model.name(asset.ownerId)).font(.headline)
            Text(asset.originalFileName).font(.callout).textSelection(.enabled).lineLimit(2)
            PFBadge(mediaLabel(asset), systemImage: asset.isLive ? "livephoto" : asset.type.uppercased() == "VIDEO" ? "video" : "photo", color: asset.isLive ? PFTheme.accent : .secondary).fixedSize(horizontal: false, vertical: true)
            if let w = asset.width, let h = asset.height { Text("\(w) × \(h)\(asset.fileSize.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")").font(.caption).foregroundStyle(.secondary) }
            Text(L("Captura: \(asset.localDateTime ?? asset.fileCreatedAt)")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(L("Enviada: \(asset.createdAt)")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(L("Álbuns: ") + (asset.albums.isEmpty ? L("nenhum") : asset.albums.map(\.name).joined(separator: ", "))).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
    private func mediaLabel(_ asset: IMAsset) -> String { asset.type.uppercased() == "VIDEO" ? L("Vídeo") : asset.isLive ? L("Live Photo · com movimento") : L("Foto estática") }
    private func actionName(_ value: String) -> String { ["add": L("Adicionar ao álbum"), "unlink": L("Remover do álbum"), "trash": L("Enviar à lixeira")][value] ?? value }
    private func statusName(_ value: String) -> String { ["running": L("Em andamento"), "completed": L("Concluída"), "failed": L("Interrompida por erro"), "interrupted": L("Interrompida"), "confirmed": L("Confirmado"), "uncertain": L("Resultado incerto — confira o Immich"), "preparing": L("Preparado — resultado a conferir")][value] ?? value }
    private func empty(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: ui.tab == "Histórico" ? "clock" : "photo.on.rectangle.angled").font(.system(size: 32, weight: .light)).foregroundStyle(PFTheme.accent.opacity(0.85))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
        }.frame(maxWidth: .infinity, minHeight: 160).padding(20).background(PFTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
    private func page<T>(_ items: [T], _ index: Int) -> [T] { let start = min(max(0, index) * pageSize, items.count); return Array(items[start..<min(start + pageSize, items.count)]) }
    private func pager(count: Int, index: Binding<Int>) -> some View {
        HStack { Button(L("Anterior")) { index.wrappedValue -= 1 }.disabled(index.wrappedValue <= 0); Text(L("Página \(min(index.wrappedValue + 1, max(1, (count + pageSize - 1) / pageSize))) de \(max(1, (count + pageSize - 1) / pageSize))")).font(.caption).foregroundStyle(.secondary); Button(L("Próxima")) { index.wrappedValue += 1 }.disabled((index.wrappedValue + 1) * pageSize >= count); Spacer() }
    }
    private struct ReviewItem: Identifiable { let id: String; let title: String; let note: String; let assets: [IMAsset]; let keepID: String? }
}

private struct IMAssetThumbnail: View {
    @ObservedObject private var localization = PFLocalization.shared
    let asset: IMAsset
    @ObservedObject var model: IMWorkspaceModel
    @StateObject private var thumbnail = IMWorkspaceThumbnailState()
    var body: some View {
        Group {
            if let image = thumbnail.image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: asset.id) { thumbnail.image = await model.thumbnail(asset) }
    }
}

@MainActor
private final class IMWorkspaceThumbnailState: ObservableObject { @Published var image: NSImage? }

@MainActor
private final class IMHistoryPreviewState: ObservableObject { @Published var page = 0 }
private struct IMHistoryPreviews: View {
    @ObservedObject private var localization = PFLocalization.shared
    let assets: [IMAsset]
    @ObservedObject var model: IMWorkspaceModel
    @StateObject private var state = IMHistoryPreviewState()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))]) {
                ForEach(Array(assets.dropFirst(state.page * 8).prefix(8))) { asset in
                    VStack(alignment: .leading, spacing: 8) {
                        IMAssetThumbnail(asset: asset, model: model).frame(height: 100)
                        Text(asset.originalFileName).lineLimit(2)
                        Text(model.name(asset.ownerId)).foregroundStyle(.secondary)
                        Text(asset.isLive ? L("Live Photo · com movimento") : asset.type == "VIDEO" ? L("Vídeo") : L("Foto estática")).fontWeight(.medium)
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button(L("Anterior")) { state.page -= 1 }.disabled(state.page == 0)
                Text(L("Página \(state.page + 1)")).font(.caption)
                Button(L("Próxima")) { state.page += 1 }.disabled((state.page + 1) * 8 >= assets.count)
            }
        }.padding(.vertical, 10)
    }
}

/// Shared account editor, available both in Settings and in the management window.
struct IMAccountSettingsView: View {
    @ObservedObject private var localization = PFLocalization.shared
    @ObservedObject var model: IMWorkspaceModel
    @ObservedObject private var ui: IMWorkspaceUIState
    init(model: IMWorkspaceModel) { self.model = model; _ui = ObservedObject(wrappedValue: model.ui) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PFSectionHeading(L("Contas conectadas"), subtitle: L("Acesso seguro para cada biblioteca."), systemImage: "person.2.crop.square.stack")
            Text(L("As chaves adicionais ficam no Chaves do macOS. Conecte cada proprietário para analisar suas fotos e executar ações em sua conta.")).foregroundStyle(.secondary)
            Button(L("Usar conta da conexão atual")) { model.connect(key: model.primaryKey, persist: false) }.disabled(!model.connectionReady || model.primaryKey.isEmpty)
            Text(L("A conta atual é verificada e usada apenas nesta sessão. Use o campo abaixo para salvar uma conta neste perfil.")).font(.caption).foregroundStyle(.secondary)
            ForEach(model.credentials.map(\.account)) { account in
                PFCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 32)).foregroundStyle(PFTheme.accent)
                            Text(account.displayName).font(.headline)
                            Spacer()
                            Button(L("Desconectar")) { model.disconnect(account.id) }.foregroundStyle(.secondary)
                        }
                        if let scopes = model.scopes[account.id] { Text(L("Permissões: ") + scopes.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        else { Text(L("Conta salva. As permissões são verificadas novamente antes das ações.")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            PFCard {
                VStack(alignment: .leading, spacing: 14) {
                    PFSectionHeading(L("Adicionar conta"), subtitle: L("A chave é protegida pelo Chaves do macOS."), systemImage: "key.fill")
                    SecureField(L("Chave de API do Immich"), text: $ui.accountKey).textFieldStyle(.roundedBorder).controlSize(.large)
                    Button(L("Verificar e salvar conta")) { let key = ui.accountKey; ui.accountKey = ""; model.connect(key: key, persist: true) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.connectionReady || ui.accountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text(L("Permissões: user.read, album.read, asset.read e asset.view para consultar; person.read para pessoas; albumAsset.create e albumAsset.delete para organizar; asset.delete para enviar duplicatas à lixeira. Permissões ausentes bloqueiam a ação e são informadas antes de alterações.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Shares verified in-memory accounts across Settings and management without persisting the primary key.
@MainActor final class IMWorkspaceSessionCache {
    private(set) var current: IMWorkspaceModel?
    func prepare(address: String, primaryKey: String, profileID: String, ready: Bool, onBusyChanged: @escaping (Bool) -> Void) -> IMWorkspaceModel? {
        guard current?.busy != true else { return nil }
        if let existing = current, existing.primaryKey != primaryKey || existing.profileID != profileID { current = nil }
        if let existing = current {
            existing.updateConnection(address: address, ready: ready)
            return ready ? existing : nil
        }
        guard ready else { return nil }
        let model = IMWorkspaceModel(address: address, primaryKey: primaryKey, profileID: profileID, connectionReady: ready, onBusyChanged: onBusyChanged)
        current = model
        return model
    }
}
