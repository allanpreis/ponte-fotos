import SwiftUI
import AppKit

/// Downloads are read-only; creating Photos assets always requires a separate confirmation.
@MainActor private final class PFReverseUIState: ObservableObject {
    @Published var confirmingImport = false
    @Published var configuring = false
}

struct PFReverseImportView: View {
    @ObservedObject private var localization = PFLocalization.shared
    @ObservedObject var model: PFReverseImportModel
    @ObservedObject var connection: LibraryModel
    private var connectionReady: Bool { connection.transferReady }
    var configure: () -> Void = {}
    @StateObject private var ui = PFReverseUIState()

    private var working: Bool { model.busy || model.importing }
    private var eligibleSelection: [PFReverseItem] {
        model.items.filter { model.selection.contains($0.id) && $0.selectable }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !connectionReady {
                PFCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L("Valide a conexão com o Immich"), systemImage: "network").font(.headline)
                        Text(L("Abra as configurações para testar o endereço e a chave de API antes de consultar os álbuns."))
                            .font(.callout).foregroundStyle(.secondary)
                        Button(L("Abrir configurações"), action: configure)
                    }
                }
            }
            sourceControls
            selectionHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.items.isEmpty {
                        PFEmptyState(working ? L("Consultando o Immich…") : L("Escolha suas memórias"),
                                     detail: model.activeFollow == nil ? L("Atualize a lista de álbuns, escolha uma origem e consulte os itens para revisar a importação.") : L("Consulte as novidades. Itens concluídos neste acompanhamento ficam fora da fila; falhas e resultados pendentes continuam para revisão."),
                                     systemImage: "photo.on.rectangle.angled")
                    } else {
                        ForEach(model.items) { item in itemRow(item) }
                    }
                }.padding(.bottom, 8)
            }.frame(minHeight: 220, maxHeight: .infinity)
            footer
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
        .alert(L("Importar para o Fotos da Apple?"), isPresented: $ui.confirmingImport) {
            Button(L("Cancelar"), role: .cancel) {}
            Button(eligibleSelection.count == 1 ? L("Importar 1 item") : L("Importar \(eligibleSelection.count) itens")) {
                Task { await model.importSelected(preflight: validateSource) }
            }
        } message: {
            Text(L("Origem: \(connection.transferAccountLabel) · \(connection.transferAddress).") + "\n\n" + L("Seleção: \(eligibleSelection.count) \(eligibleSelection.count == 1 ? L("item") : L("itens")). Destino: “\(model.destinationLabel)” no Fotos deste Mac. Itens já importados pelo app serão adicionados ao álbum sem criar novas cópias. O macOS poderá pedir permissão. O iCloud segue os ajustes do Fotos. Os originais continuam no Immich."))
        }
    }

    private var sourceControls: some View {
        PFCard {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 12) { albumPicker; sourceActions }
                    VStack(alignment: .leading, spacing: 8) { albumPicker; sourceActions }
                }
                HStack(spacing: 8) {
                    Image(systemName: model.activeFollow == nil ? "photo.on.rectangle" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                    Text(L("Destino: \(model.activeFollow?.destinationTitle ?? model.destinationLabel)"))
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                if model.verifyOriginalBytes {
                    Label(L("Conferência dos originais por hash ativada"), systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(L("Destino e acompanhamento"), systemImage: "slider.horizontal.3") { ui.configuring = true }
                    .disabled(working)
                    .popover(isPresented: $ui.configuring, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text(L("Destino e acompanhamento")).font(.headline)
                                Spacer()
                                Button(L("Concluir")) { ui.configuring = false }
                            }
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text(L("Origem: \(connection.transferAccountLabel) · \(connection.transferAddress)."))
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    destinationControls
                                    followControls
                                    originalVerificationControls
                                    Text(L("Originais, data de captura e localização disponível serão preservados. Live Photos precisam de um par compatível; itens sem data válida ou com recursos indisponíveis ficam bloqueados."))
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    Text(L("O histórico evita repetir importações feitas pelo Ponte Fotos. Ele não compara toda a biblioteca existente do Fotos. Pessoas reconhecidas e histórico de edições não são transferidos."))
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(20).frame(width: 540, height: 480)
                            .environment(\.locale, PFLocalization.locale)
                    }
            }
        }
        .onChange(of: model.items.count) { _, count in if count > 0 { ui.configuring = false } }
    }

    private var originalVerificationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("Conferir originais por hash após importar"), isOn: $model.verifyOriginalBytes)
                .disabled(working)
            Text(L("Reexporta temporariamente o original armazenado no Fotos e compara com o Immich. Live Photos conferem imagem e vídeo. Pode baixar originais do iCloud e levar mais tempo. Falhas ficam pendentes; nada é apagado. Não verifica reprodução HDR nem aparência de edições."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var followControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let link = model.activeFollow {
                Label(L("Acompanhamento assistido"), systemImage: "arrow.triangle.2.circlepath").font(.headline)
                Text(link.destinationTitle).font(.callout)
                if let date = link.lastChecked {
                    Text(L("Última consulta: \(PFLocalization.formatDate(date, date: .abbreviated, time: .shortened))")).font(.caption).foregroundStyle(.secondary)
                }
                Button(L("Parar acompanhamento")) { model.stopFollowing() }.disabled(working)
            } else {
                Button(L("Acompanhar este álbum")) { model.startFollowing() }
                    .disabled(working || !connectionReady || model.albumID.isEmpty || model.destinationMode != .existing || !model.isDestinationValid)
            }
            Text(L("Vincule um álbum existente do Fotos. A consulta é manual; todos os itens ainda não concluídos entram na revisão, inclusive os já existentes na primeira consulta. Nada é importado automaticamente."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var destinationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Destino no Fotos da Apple")).font(.caption).foregroundStyle(.secondary)
            Picker(L("Tipo de destino no Fotos"), selection: $model.destinationMode) {
                Text(L("Álbum existente")).tag(PFPhotosDestinationMode.existing)
                Text(L("Criar novo álbum")).tag(PFPhotosDestinationMode.new)
            }.id(PFLocalization.languageCode).pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420).disabled(working || model.activeFollow != nil)
            if model.destinationMode == .existing {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { photosAlbumPicker; refreshPhotosAlbums }
                    VStack(alignment: .leading, spacing: 10) { photosAlbumPicker; refreshPhotosAlbums }
                }
                Text(model.photosAlbums.isEmpty
                     ? L("Atualize os álbuns para escolher um destino. O macOS poderá pedir acesso ao Fotos; esta consulta não cria nem altera itens.")
                     : L("Somente álbuns que permitem adicionar fotos são listados. Álbuns com nomes iguais são diferenciados na lista."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField(L("Nome do novo álbum"), text: $model.destinationAlbumName)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 420).disabled(working || model.activeFollow != nil)
                    .accessibilityLabel(L("Nome do novo álbum no Fotos"))
                Text(L("Um novo álbum será criado somente ao confirmar a importação, mesmo se já existir outro com o mesmo nome."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var photosAlbumPicker: some View {
        Picker(L("Álbum de destino no Fotos"), selection: $model.destinationAlbumID) {
            Text(L("Selecione um álbum do Fotos")).tag("")
            ForEach(model.photosAlbums) { album in Text(album.displayLabel).tag(album.id) }
        }.id(PFLocalization.languageCode).labelsHidden().frame(minWidth: 200, maxWidth: .infinity)
            .disabled(working || model.photosAlbums.isEmpty || model.activeFollow != nil)
    }

    private var refreshPhotosAlbums: some View {
        Button(L("Atualizar álbuns do Fotos")) { Task { await model.loadPhotosAlbums() } }
            .disabled(working)
    }

    private var albumPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Álbum de origem no Immich")).font(.caption).foregroundStyle(.secondary)
            Picker(L("Álbum de origem no Immich"), selection: $model.albumID) {
                Text(L("Selecione um álbum")).tag("")
                ForEach(model.albums) { album in
                    Text(L("\(album.name) · \(album.count) itens")).tag(album.id)
                }
            }.id(PFLocalization.languageCode).labelsHidden().frame(minWidth: 200, maxWidth: .infinity)
                .disabled(working || !connectionReady || model.albums.isEmpty)
        }
    }

    private var sourceActions: some View {
        HStack(spacing: 10) {
            Button(L("Atualizar álbuns")) { Task {
                await model.load(address: connection.transferAddress, key: connection.transferKey, profileID: connection.profile.id, expectedUserID: connection.transferAccountID, preflight: validateSource)
            } }
                .disabled(working || !connectionReady)
            Button(model.activeFollow == nil ? L("Consultar itens") : L("Consultar novidades")) { Task { await model.loadAlbum(preflight: validateSource) } }
                .disabled(working || !connectionReady || model.albumID.isEmpty)
        }
    }

    private var selectionHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { selectionCount; Spacer(minLength: 8); selectionActions }
            VStack(alignment: .leading, spacing: 10) { selectionCount; selectionActions }
        }
    }

    private var selectionCount: some View {
        HStack(spacing: 10) {
            Text(L("Fotos e vídeos")).font(.headline)
            PFBadge(eligibleSelection.count == 1 ? L("1 selecionado") : L("\(eligibleSelection.count) selecionados"))
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 12) {
            Button(L("Selecionar disponíveis")) { model.selection = Set(model.items.filter(\.selectable).map(\.id)) }
                .disabled(working || !connectionReady || !model.items.contains(where: \.selectable))
            Button(L("Desmarcar")) { model.selection = [] }.disabled(working || model.selection.isEmpty)
        }
    }

    private func itemRow(_ item: PFReverseItem) -> some View {
        PFCard {
            HStack(alignment: .top, spacing: 14) {
                Toggle(isOn: Binding(get: { model.selection.contains(item.id) }, set: { selected in
                    if selected { model.selection.insert(item.id) } else { model.selection.remove(item.id) }
                })) { Text(L("Selecionar \(item.name)")) }
                    .labelsHidden().toggleStyle(.checkbox)
                    .disabled(working || !connectionReady || !item.selectable)
                    .accessibilityLabel(L("Selecionar \(item.name)"))
                PFReverseThumbnail(model: model, item: item, connectionReady: connectionReady)
                VStack(alignment: .leading, spacing: 9) {
                    Text(item.name).font(.headline).lineLimit(2).textSelection(.enabled)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { mediaBadge(item); importBadge(item) }
                        VStack(alignment: .leading, spacing: 6) { mediaBadge(item); importBadge(item) }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        if let date = item.captureDate {
                            Label(L("Captura: \(PFLocalization.formatDate(date, date: .abbreviated, time: .standard))"), systemImage: "calendar")
                        } else {
                            Label(L("Data de captura indisponível"), systemImage: "calendar.badge.exclamationmark")
                        }
                        if let latitude = item.latitude, let longitude = item.longitude {
                            Label("GPS: \(latitude.formatted(.number.precision(.fractionLength(5)).locale(PFLocalization.locale))) · \(longitude.formatted(.number.precision(.fractionLength(5)).locale(PFLocalization.locale)))", systemImage: "location")
                        } else {
                            Label(L("Sem localização disponível"), systemImage: "location.slash")
                        }
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if item.canRecheck {
                        Button(L("Conferir novamente no Fotos")) { Task { await model.recheck(id: item.id, preflight: validateSource) } }
                            .disabled(working || !connectionReady)
                    }
                    if let verification = item.verification {
                        Label(verification.summary.text, systemImage: verification.isVerified ? "checkmark.shield" : "exclamationmark.shield")
                            .font(.caption).foregroundStyle(verification.isVerified ? Color.green : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let issue = item.displayIssue, !issue.isEmpty {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func mediaBadge(_ item: PFReverseItem) -> some View {
        PFBadge(item.isLive ? L("Live Photo · com movimento") : item.displayTypeLabel,
                systemImage: item.isLive ? "livephoto" : "photo.on.rectangle", color: item.isLive ? .teal : PFTheme.accent)
    }

    @ViewBuilder private func importBadge(_ item: PFReverseItem) -> some View {
        if item.isImported {
            PFBadge(L("Já no Fotos · sem nova cópia"), systemImage: "checkmark.circle", color: .green)
        } else if !item.selectable {
            PFBadge(L("Indisponível"), systemImage: "exclamationmark.circle", color: .orange)
        }
    }

    private func validateSource(_ expected: [String]) async throws {
        try await connection.validateTransfer(requiredPermissions: ["asset.read", "asset.download", "album.read"])
        guard expected == [connection.transferAddress, connection.transferKey, connection.profile.id] else {
            throw BridgeError(message: M("A conta ou o endereço mudou. Atualize os álbuns e revise a seleção antes de importar."))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.status.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    if working { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout).textSelection(.enabled)
                }.accessibilityElement(children: .combine)
            }
            if model.importing && model.total > 0 {
                ProgressView(L("\(model.done) de \(model.total) itens concluídos"), value: Double(model.done), total: Double(model.total))
            }
            HStack {
                if working {
                    Button(L("Cancelar operação")) { model.cancel() }
                }
                Spacer()
                Button {
                    ui.confirmingImport = true
                } label: {
                    Label(L("Importar para o Fotos…"), systemImage: "square.and.arrow.down")
                }.buttonStyle(.bordered).controlSize(.large)
                    .disabled(working || !connectionReady || eligibleSelection.isEmpty || !model.isDestinationValid)
            }
        }
    }
}

@MainActor private final class PFReverseThumbnailState: ObservableObject {
    @Published var image: NSImage?
}

private struct PFReverseThumbnail: View {
    @ObservedObject private var localization = PFLocalization.shared
    @ObservedObject var model: PFReverseImportModel
    let item: PFReverseItem
    let connectionReady: Bool
    @StateObject private var state = PFReverseThumbnailState()
    var body: some View {
        Group {
            if let image = state.image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: item.isLive ? "livephoto" : "photo.on.rectangle")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 88)
        .background(PFTheme.background, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(L("Prévia de \(item.name)"))
        .task(id: connectionReady) {
            guard connectionReady else { state.image = nil; return }
            let image = await model.thumbnail(id: item.id)
            guard !Task.isCancelled else { return }
            state.image = image
        }
    }
}
