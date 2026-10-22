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
    @Published var progress = ""
    @Published var error: String?
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
            error = "O endereço de conexão mudou. Atualize os álbuns e faça uma nova consulta."
        }
        connectionReady = ready
    }
    var session: IMSession { IMSession(address: address, profileID: profileID, credentials: credentials) }
    func name(_ id: String) -> String {
        if let account = credentials.first(where: { $0.account.id == id }) { return account.account.name }
        func knownName(_ assets: [IMAsset]) -> String? {
            assets.first(where: { $0.ownerId == id && !($0.ownerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.ownerName
        }
        for group in duplicates?.groups ?? [] { if let name = knownName(group.assets) { return name } }
        for group in comparison?.groups ?? [] { if let name = knownName(group.assets) { return name } }
        if let name = knownName(age?.assets ?? []) { return name }
        for entry in history { if let name = knownName(entry.assets) { return name } }
        return "Conta não conectada"
    }
    func load() {
        guard !loaded else { return }; loaded = true
        do {
            credentials = try IMManagementStore.credentials(profileID: profileID)
            history = try IMManagementStore.history(profileID: profileID)
            var changed = false
            for i in history.indices where history[i].status == "running" { history[i].status = "interrupted"; changed = true }
            if changed { try persistHistory() }
        } catch { self.error = error.localizedDescription }
    }
    func run(_ message: String, cancellable: Bool = true, operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        guard connectionReady else { error = "A conexão mudou ou ainda não foi validada. Feche esta janela e teste a conexão antes de consultar ou alterar o Immich."; return }
        busy = true; error = nil; progress = message; canCancel = cancellable; onBusyChanged(true)
        operationTask = Task { @MainActor in
            defer { busy = false; canCancel = false; operationTask = nil; onBusyChanged(false); progress = "" }
            do { try await operation() } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
    func cancelQuery() { guard canCancel else { return }; canCancel = false; progress = "Cancelando consulta…"; operationTask?.cancel() }
    func updateProgress(_ text: String, _ current: Int, _ total: Int) {
        progress = total > 0 ? "\(text) · \(current)/\(total)" : text
    }
    func connect(key: String, persist: Bool) {
        run("Verificando conta e permissões…") {
            let credential = try await IMManagementStore.verify(address: self.address, key: key)
            let permissions = try await IMClient(address: self.address, credential: credential).permissions()
            let minimum: Set<String> = ["asset.read", "album.read"]
            let missing = minimum.subtracting(permissions)
            guard permissions.contains("all") || missing.isEmpty else {
                throw BridgeError(message: "A chave de \(credential.account.name) precisa destas permissões para gerenciar fotos: \(missing.sorted().joined(separator: ", ")). Ajuste a chave no Immich e conecte novamente.")
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
        } catch { self.error = error.localizedDescription }
    }
    func refresh() {
        run("Atualizando álbuns e pessoas…") {
            let snapshot = self.session
            self.albums = try await snapshot.albums()
            self.people = try await snapshot.people()
        }
    }
    func scanDuplicates(_ selected: Set<String>) {
        let chosen = albums.filter { selected.contains($0.id) }
        run("Procurando cópias idênticas…") {
            let result = try await IMDuplicates.scan(session: self.session, albums: chosen, progress: self.updateProgress)
            self.duplicates = result
            self.duplicateChoices = Dictionary(uniqueKeysWithValues: result.groups.filter { $0.unavailableOwnerIDs.isEmpty }.map { ($0.id, $0.keepID) })
        }
    }
    func scanComparison(_ selected: Set<String>) {
        let chosen = albums.filter { selected.contains($0.id) }
        run("Comparando álbuns…") {
            self.comparison = try await IMOrganization.compare(session: self.session, albums: chosen, progress: self.updateProgress)
            self.comparisonChoices = [:]
        }
    }
    func searchAge(personKey: String, sourceID: String, destinationID: String, min: Int, max: Int) {
        guard let person = people.first(where: { $0.key == personKey }), let destination = albums.first(where: { $0.id == destinationID }) else { return }
        let source = albums.first { $0.id == sourceID }
        run("Buscando fotos por idade…") {
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
        guard let i = history.firstIndex(where: { $0.id == entryID }) else { throw BridgeError(message: "Histórico indisponível. Operação interrompida antes de continuar.") }
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
            guard !unsafeLiveRemoval else { error = "Uma Live Photo seria enviada à lixeira. Escolha manter a Live Photo ou desmarque o grupo."; return }
            assets = duplicates.groups.filter { duplicateChoices[$0.id] != nil }.flatMap(\.assets); title = "Revisão de duplicatas"
        } else if kind == "comparison", let comparison {
            assets = comparison.groups.filter { comparisonChoices[$0.id] != nil }.flatMap(\.assets); title = "Organização de álbuns"
        } else if kind == "age", let age {
            assets = age.assets.filter { ageChoices.contains($0.id) }; title = "Organização por idade"
        } else { return }
        let entry = IMHistoryEntry(title: title, kind: kind, assets: assets)
        run("Preparando operação…", cancellable: false) {
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
                do { try self.persistHistory() } catch { throw BridgeError(message: "Não foi possível salvar o histórico. A operação foi interrompida; confira o Immich antes de repetir qualquer ação.") }
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
}

struct ImmichWorkspaceView: View {
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
        VStack(alignment: .leading, spacing: 16) {
            header
            Picker("Área", selection: $ui.tab) {
                ForEach(["Álbuns", "Comparar álbuns", "Pessoa e idade", "Contas e API", "Histórico"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).disabled(model.busy)
            if model.busy { HStack { ProgressView().controlSize(.small); Text(model.progress).font(.callout); Spacer(); if model.canCancel { Button("Cancelar consulta") { model.cancelQuery() } } } }
            if let error = model.error {
                HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle.fill"); Text(error).textSelection(.enabled); Spacer(); Button("Dispensar") { model.error = nil } }.foregroundStyle(.red).padding(12).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch ui.tab {
                    case "Contas e API": accountsView
                    case "Histórico": historyView
                    case "Pessoa e idade": ageView
                    default: albumSelector; if ui.tab == "Álbuns" { duplicatesView } else { comparisonView }
                    }
                }.padding(.bottom, 12)
            }.disabled(model.busy)
        }
        .padding(24).frame(minWidth: 820, idealWidth: 1060, minHeight: 660, idealHeight: 820)
        .onAppear { model.updateConnection(address: currentAddress, ready: currentReady); model.load() }
        .onChange(of: currentAddress) { _, value in model.updateConnection(address: value, ready: currentReady) }
        .onChange(of: currentReady) { _, value in model.updateConnection(address: currentAddress, ready: value) }
        .interactiveDismissDisabled(model.busy)
        .sheet(isPresented: Binding(get: { ui.reviewKind != nil }, set: { if !$0 { ui.reviewKind = nil } })) { reviewView }
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Gerenciar Immich").font(.title2.bold())
                Text("Revise suas fotos, preserve os originais e organize seus álbuns.").foregroundStyle(.secondary)
                Text(model.address).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Concluir") { dismiss() }.disabled(model.busy)
        }
    }
    private var filteredAlbums: [IMAlbum] {
        model.albums.filter { (ui.owner.isEmpty || $0.ownerID == ui.owner) && (ui.albumSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(ui.albumSearch)) }
    }
    private var albumSelector: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Buscar álbum", text: $ui.albumSearch)
                    Picker("Proprietário", selection: $ui.owner) {
                        Text("Todos").tag("")
                        ForEach(model.credentials.map(\.account)) { Text($0.name).tag($0.id) }
                    }.frame(maxWidth: 270)
                    Button("Atualizar álbuns") { model.refresh() }.disabled(model.credentials.isEmpty || !model.connectionReady)
                }
                if model.credentials.isEmpty { Text("Conecte as contas proprietárias em Contas e API para comparar suas cópias.").foregroundStyle(.secondary) }
                ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(filteredAlbums) { album in
                    Toggle(isOn: Binding(get: { ui.selectedAlbums.contains(album.id) }, set: { if $0 { ui.selectedAlbums.insert(album.id) } else { ui.selectedAlbums.remove(album.id) } })) {
                        HStack { Text(album.name).bold(); Text("\(model.name(album.ownerID)) · \(album.count) itens").foregroundStyle(.secondary); Spacer(); if album.shared { Text("Compartilhado").font(.caption) } }
                    }
                }
                }
                }.frame(maxHeight: 250)
                HStack {
                    Button("Selecionar visíveis") { ui.selectedAlbums.formUnion(filteredAlbums.map(\.id)) }
                    Button("Limpar seleção") { ui.selectedAlbums = [] }
                    Spacer()
                    Button(ui.tab == "Álbuns" ? "Consultar duplicatas · \(ui.selectedAlbums.count) álbuns" : "Comparar seleção") {
                        ui.duplicatePage = 0; ui.comparisonPage = 0
                        if ui.tab == "Álbuns" { model.scanDuplicates(ui.selectedAlbums) } else { model.scanComparison(ui.selectedAlbums) }
                    }.buttonStyle(.borderedProminent).disabled(!model.connectionReady || ui.selectedAlbums.isEmpty || (ui.tab != "Álbuns" && ui.selectedAlbums.count != 2))
                }
                Text(ui.tab == "Álbuns" ? "Arquivos idênticos por checksum, entre todas as contas conectadas. Live Photos são identificadas e protegidas." : "Selecione exatamente dois álbuns. A organização altera apenas os vínculos com os álbuns; os arquivos permanecem na biblioteca.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
    private var duplicatesView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result = model.duplicates {
                Text("\(result.groups.count) grupos · \(result.skipped) itens fora da análise").font(.headline)
                Text("A Live Photo é sugerida para manter. Cada cópia mostra sua conta, formato e álbuns atuais.").foregroundStyle(.secondary)
                HStack {
                    Button("Selecionar todos") { model.duplicateChoices = Dictionary(uniqueKeysWithValues: result.groups.filter { $0.unavailableOwnerIDs.isEmpty }.map { ($0.id, $0.keepID) }) }
                    Button("Desmarcar todos") { model.duplicateChoices = [:] }
                    Spacer()
                    Button("Revisar envio à lixeira") { openReview("duplicates") }.disabled(!model.connectionReady || model.duplicateChoices.isEmpty || model.unsafeLiveRemoval)
                }
                if model.unsafeLiveRemoval { Text("Uma escolha removeria uma Live Photo. Mantenha a versão com movimento ou desmarque esse grupo.").foregroundStyle(.orange) }
                ForEach(page(result.groups, ui.duplicatePage)) { group in duplicateGroup(group) }
                pager(count: result.groups.count, index: $ui.duplicatePage)
                if result.groups.isEmpty { empty("Nenhuma cópia idêntica encontrada.") }
            } else { empty("Selecione os álbuns e consulte as duplicatas para começar.") }
        }
    }
    private func duplicateGroup(_ group: IMDuplicateGroup) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Revisar grupo · \(group.assets.count) cópias", isOn: Binding(get: { model.duplicateChoices[group.id] != nil }, set: { model.duplicateChoices[group.id] = $0 ? group.keepID : nil })).font(.headline).disabled(!group.unavailableOwnerIDs.isEmpty)
                if !group.unavailableOwnerIDs.isEmpty { Text("Conecte em Contas e API: " + group.unavailableOwnerIDs.map { model.name($0) }.joined(separator: ", ") + ". Depois, refaça a consulta para alterar este grupo.").font(.caption).foregroundStyle(.orange) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(group.assets) { asset in
                        VStack(alignment: .leading, spacing: 10) {
                            assetCard(asset)
                            Button {
                                model.duplicateChoices[group.id] = asset.id
                            } label: { Label(model.duplicateChoices[group.id] == asset.id ? "Manter esta cópia" : "Escolher para manter", systemImage: model.duplicateChoices[group.id] == asset.id ? "largecircle.fill.circle" : "circle") }
                        }.disabled(!group.unavailableOwnerIDs.isEmpty).padding(10).background(RoundedRectangle(cornerRadius: 10).stroke(model.duplicateChoices[group.id] == asset.id ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1))
                    }
                }
            }.padding(8)
        }
    }
    private var comparisonGroups: [IMComparisonGroup] { model.comparison?.groups.filter { ui.allComparison || $0.common } ?? [] }
    private var comparisonView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result = model.comparison {
                Toggle("Mostrar também itens exclusivos", isOn: $ui.allComparison).onChange(of: ui.allComparison) { ui.comparisonPage = 0; model.comparisonChoices = [:] }
                Text("\(comparisonGroups.count) grupos visíveis · \(result.skipped) itens fora da análise").font(.headline)
                Text("Cada grupo começa sem alteração. Escolha um destino para reunir as cópias nesse álbum ou manter nos dois. Live Photos, pilhas, arquivos offline e editados ficam fora da análise.").foregroundStyle(.secondary)
                ForEach(page(comparisonGroups, ui.comparisonPage)) { group in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.common ? "Presente nos dois álbuns" : "Item exclusivo").font(.headline)
                            Picker("Ação", selection: Binding(get: { model.comparisonChoices[group.id] ?? "" }, set: { model.comparisonChoices[group.id] = $0.isEmpty ? nil : $0 })) {
                                Text("Sem alteração").tag(""); Text("Manter nos dois álbuns").tag("both")
                                ForEach(result.albums) { Text("Reunir em \($0.name)").tag($0.id) }
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))]) { ForEach(group.assets) { assetCard($0) } }
                        }.padding(8)
                    }
                }
                pager(count: comparisonGroups.count, index: $ui.comparisonPage)
                Button("Revisar organização") { openReview("comparison") }.disabled(!model.connectionReady || model.comparisonChoices.isEmpty)
            } else { empty("Compare dois álbuns para revisar suas fotos em comum. Live Photos, pilhas, arquivos offline e editados ficam fora desta análise.") }
        }
    }
    private var ageView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Organizar por pessoa e idade").font(.headline)
            Text("A idade considera a data da captura e o aniversário registrado no Immich. Os limites são inclusivos. Live Photos, pilhas, arquivos offline e editados ficam fora da análise.").foregroundStyle(.secondary)
            Button("Atualizar álbuns e pessoas") { model.refresh() }.disabled(model.credentials.isEmpty || !model.connectionReady)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow { Text("Conta"); Picker("Conta", selection: $ui.ageAccount) { Text("Todas as contas").tag(""); ForEach(model.credentials.map(\.account)) { Text($0.name).tag($0.id) } }.labelsHidden().onChange(of: ui.ageAccount) { ui.personKey = "" } }
                GridRow { Text("Pessoa"); Picker("Pessoa", selection: $ui.personKey) { Text("Selecione uma pessoa").tag(""); ForEach(model.people.filter { ui.ageAccount.isEmpty || $0.accountID == ui.ageAccount }, id: \.key) { Text("\($0.name) · \(model.name($0.accountID))").tag($0.key) } }.labelsHidden() }
                GridRow { Text("Aniversário"); Text(model.people.first { $0.key == ui.personKey }?.birthDate ?? "Cadastre a data de nascimento no Immich.").foregroundStyle(.secondary) }
                GridRow { Text("Origem"); Picker("Origem", selection: $ui.sourceID) { Text("Todos os álbuns acessíveis").tag(""); ForEach(model.albums) { Text($0.name).tag($0.id) } }.labelsHidden() }
                GridRow { Text("Destino"); Picker("Destino", selection: $ui.destinationID) { Text("Selecione um álbum").tag(""); ForEach(model.albums) { Text($0.name).tag($0.id) } }.labelsHidden() }
                GridRow { Text("Idade em anos"); HStack { Stepper("De \(ui.minAge)", value: $ui.minAge, in: 0...150); Stepper("Até \(ui.maxAge)", value: $ui.maxAge, in: 0...150) } }
            }
            Button("Buscar fotos") { ui.agePage = 0; model.searchAge(personKey: ui.personKey, sourceID: ui.sourceID, destinationID: ui.destinationID, min: ui.minAge, max: ui.maxAge) }.buttonStyle(.borderedProminent).disabled(!model.connectionReady || ui.personKey.isEmpty || ui.destinationID.isEmpty || ui.sourceID == ui.destinationID || ui.minAge > ui.maxAge || model.people.first { $0.key == ui.personKey }?.birthDate == nil)
            if let result = model.age {
                Text("\(result.assets.count) fotos · \(result.skipped) itens fora da análise · destino: \(result.destination.name)").font(.headline)
                HStack { Button("Selecionar todas") { model.ageChoices = Set(result.assets.map(\.id)) }; Button("Desmarcar todas") { model.ageChoices = [] }; Spacer(); Button("Revisar movimentação") { openReview("age") }.disabled(!model.connectionReady || model.ageChoices.isEmpty) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))]) {
                    ForEach(page(result.assets, ui.agePage)) { asset in VStack(alignment: .leading) { Toggle("Mover para \(result.destination.name)", isOn: Binding(get: { model.ageChoices.contains(asset.id) }, set: { if $0 { model.ageChoices.insert(asset.id) } else { model.ageChoices.remove(asset.id) } })); assetCard(asset) } }
                }
                pager(count: result.assets.count, index: $ui.agePage)
            }
        }
    }
    private var accountsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Contas conectadas a este servidor").font(.headline)
            Text("As chaves adicionais ficam no Chaves do macOS. Conecte cada proprietário para analisar suas fotos e executar ações em sua conta.").foregroundStyle(.secondary)
            Button("Usar conta da conexão atual") { model.connect(key: model.primaryKey, persist: false) }.disabled(!model.connectionReady || model.primaryKey.isEmpty)
            Text("A conta atual é verificada e usada apenas nesta sessão. Use o campo abaixo para salvar uma conta neste perfil.").font(.caption).foregroundStyle(.secondary)
            ForEach(model.credentials.map(\.account)) { account in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Label(account.name, systemImage: "person.crop.circle").font(.headline); Spacer(); Button("Desconectar") { model.disconnect(account.id) } }
                        if let scopes = model.scopes[account.id] { Text("Permissões: " + scopes.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        else { Text("Conta salva. As permissões são verificadas novamente antes das ações.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(8)
                }
            }
            Divider()
            SecureField("Chave de API do Immich", text: $ui.accountKey).textFieldStyle(.roundedBorder)
            Button("Verificar e salvar conta") { let key = ui.accountKey; ui.accountKey = ""; model.connect(key: key, persist: true) }.disabled(!model.connectionReady || ui.accountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Permissões: user.read, album.read, asset.read e asset.view para consultar; person.read para pessoas; albumAsset.create e albumAsset.delete para organizar; asset.delete para enviar duplicatas à lixeira. Permissões ausentes bloqueiam a ação e são informadas antes de alterações.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var historyView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Últimas 20 operações").font(.headline)
            Text("Operações interrompidas ou incertas exigem conferência no Immich. Nenhuma operação é repetida automaticamente.").foregroundStyle(.secondary)
            if model.history.isEmpty { empty("Nenhuma operação executada neste perfil.") }
            ForEach(model.history) { entry in
                DisclosureGroup {
                    ForEach(entry.records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(actionName(record.action)) · \(record.name)").fontWeight(.medium)
                            Text("\(statusName(record.status)) · \(model.name(record.ownerID))\(record.albumName.map { " · " + $0 } ?? "")").font(.caption).foregroundStyle(record.status == "uncertain" ? Color.orange : Color.secondary)
                            if let keepID = record.keepID, let keeper = entry.assets.first(where: { $0.id == keepID }) { Text("Cópia mantida: \(keeper.originalFileName) · \(model.name(keeper.ownerId))").font(.caption).foregroundStyle(.green) }
                            if let message = record.message { Text(message).font(.caption).textSelection(.enabled) }
                        }.padding(.vertical, 5)
                    }
                    DisclosureGroup("Prévia dos arquivos revisados (\(entry.assets.count))") { IMHistoryPreviews(assets: entry.assets, model: model) }
                } label: { HStack { Text(entry.title).bold(); Spacer(); Text(entry.date, style: .date); Text(entry.date, style: .time); Text(statusName(entry.status)).foregroundStyle(.secondary) } }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private func openReview(_ kind: String) { ui.reviewPage = 0; ui.reviewAccepted = false; ui.reviewKind = kind }
    private var reviewItems: [ReviewItem] {
        if ui.reviewKind == "duplicates", let analysis = model.duplicates {
            return analysis.groups.compactMap { group in
                guard let keep = model.duplicateChoices[group.id] else { return nil }
                return ReviewItem(id: group.id, title: "Manter a cópia de \(model.name(group.assets.first { $0.id == keep }?.ownerId ?? ""))", note: "As demais cópias vão para a lixeira. Os vínculos de álbuns serão preservados na cópia mantida.", assets: group.assets, keepID: keep)
            }
        }
        if ui.reviewKind == "comparison", let analysis = model.comparison {
            return analysis.groups.compactMap { group in
                guard let choice = model.comparisonChoices[group.id] else { return nil }
                let title = choice == "both" ? "Manter nos dois álbuns" : "Reunir em \(analysis.albums.first { $0.id == choice }?.name ?? choice)"
                return ReviewItem(id: group.id, title: title, note: "Os arquivos permanecem na biblioteca. Somente os vínculos dos dois álbuns comparados serão alterados.", assets: group.assets, keepID: nil)
            }
        }
        if ui.reviewKind == "age", let analysis = model.age {
            return analysis.assets.filter { model.ageChoices.contains($0.id) }.map { ReviewItem(id: $0.id, title: "Mover para \(analysis.destination.name)", note: "Adicionar ao destino e remover dos álbuns de origem incluídos na análise.", assets: [$0], keepID: nil) }
        }
        return []
    }
    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirmar alterações").font(.title2.bold())
            Text("\(reviewItems.count) grupos ou fotos selecionados. Revise todas as páginas antes de confirmar.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(page(reviewItems, ui.reviewPage)) { item in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(item.title).font(.headline); Text(item.note).font(.caption).foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260))]) {
                                    ForEach(item.assets) { asset in VStack(alignment: .leading, spacing: 8) { if let keep = item.keepID { Text(keep == asset.id ? "MANTER" : "ENVIAR À LIXEIRA").font(.caption.bold()).foregroundStyle(keep == asset.id ? Color.green : Color.orange) }; assetCard(asset) } }
                                }
                            }.padding(8)
                        }
                    }
                }
            }
            pager(count: reviewItems.count, index: $ui.reviewPage)
            Toggle("Conferi as cópias, os destinos e os álbuns envolvidos e autorizo estas alterações.", isOn: $ui.reviewAccepted)
            HStack { Button("Cancelar") { ui.reviewKind = nil }; Spacer(); Button("Confirmar alterações") { guard let kind = ui.reviewKind else { return }; ui.reviewKind = nil; model.execute(kind) }.buttonStyle(.borderedProminent).disabled(!ui.reviewAccepted || reviewItems.isEmpty || (ui.reviewKind == "duplicates" && model.unsafeLiveRemoval)) }
        }.padding(24).frame(minWidth: 760, idealWidth: 940, minHeight: 620, idealHeight: 780)
    }
    private func assetCard(_ asset: IMAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IMAssetThumbnail(asset: asset, model: model).frame(height: 155).frame(maxWidth: .infinity).background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Text(model.name(asset.ownerId)).font(.headline)
            Text(asset.originalFileName).font(.callout).textSelection(.enabled).lineLimit(2)
            Text(mediaLabel(asset)).font(.caption.bold()).padding(.horizontal, 9).padding(.vertical, 5).background(asset.isLive ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.1), in: Capsule()).fixedSize(horizontal: false, vertical: true)
            if let w = asset.width, let h = asset.height { Text("\(w) × \(h)\(asset.fileSize.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")").font(.caption).foregroundStyle(.secondary) }
            Text("Captura: \(asset.localDateTime ?? asset.fileCreatedAt)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text("Enviada: \(asset.createdAt)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text("Álbuns: " + (asset.albums.isEmpty ? "nenhum" : asset.albums.map(\.name).joined(separator: ", "))).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
    private func mediaLabel(_ asset: IMAsset) -> String { asset.type.uppercased() == "VIDEO" ? "Vídeo" : asset.isLive ? "◉ Live Photo · com movimento" : "Foto estática" }
    private func actionName(_ value: String) -> String { ["add": "Adicionar ao álbum", "unlink": "Remover do álbum", "trash": "Enviar à lixeira"][value] ?? value }
    private func statusName(_ value: String) -> String { ["running": "Em andamento", "completed": "Concluída", "failed": "Interrompida por erro", "interrupted": "Interrompida", "confirmed": "Confirmado", "uncertain": "Resultado incerto — confira o Immich", "preparing": "Preparado — resultado a conferir"][value] ?? value }
    private func empty(_ text: String) -> some View { Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)) }
    private func page<T>(_ items: [T], _ index: Int) -> [T] { let start = min(max(0, index) * pageSize, items.count); return Array(items[start..<min(start + pageSize, items.count)]) }
    private func pager(count: Int, index: Binding<Int>) -> some View {
        HStack { Button("Anterior") { index.wrappedValue -= 1 }.disabled(index.wrappedValue <= 0); Text("Página \(min(index.wrappedValue + 1, max(1, (count + pageSize - 1) / pageSize))) de \(max(1, (count + pageSize - 1) / pageSize))").font(.caption).foregroundStyle(.secondary); Button("Próxima") { index.wrappedValue += 1 }.disabled((index.wrappedValue + 1) * pageSize >= count); Spacer() }
    }
    private struct ReviewItem: Identifiable { let id: String; let title: String; let note: String; let assets: [IMAsset]; let keepID: String? }
}

private struct IMAssetThumbnail: View {
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
                        Text(asset.isLive ? "Live Photo · com movimento" : asset.type == "VIDEO" ? "Vídeo" : "Foto estática").fontWeight(.medium)
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button("Anterior") { state.page -= 1 }.disabled(state.page == 0)
                Text("Página \(state.page + 1)").font(.caption)
                Button("Próxima") { state.page += 1 }.disabled((state.page + 1) * 8 >= assets.count)
            }
        }.padding(.vertical, 10)
    }
}
