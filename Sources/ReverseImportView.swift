import SwiftUI
import AppKit

/// Downloads are read-only; creating Photos assets always requires a separate confirmation.
@MainActor private final class PFReverseUIState: ObservableObject {
    @Published var confirmingImport = false
}

struct PFReverseImportView: View {
    @ObservedObject var model: PFReverseImportModel
    let address: String
    let key: String
    let profileID: String
    let connectionReady: Bool
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
                        Label("Valide a conexão com o Immich", systemImage: "network").font(.headline)
                        Text("Abra as configurações para testar o endereço e a chave de API antes de consultar os álbuns.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Abrir configurações", action: configure)
                    }
                }
            }
            sourceControls
            selectionHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.items.isEmpty {
                        PFEmptyState(working ? "Consultando o Immich…" : "Escolha suas memórias",
                                     detail: "Atualize a lista de álbuns, escolha uma origem e consulte os itens para revisar a importação.",
                                     systemImage: "photo.on.rectangle.angled")
                    } else {
                        ForEach(model.items) { item in itemRow(item) }
                    }
                }.padding(.bottom, 8)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
        .alert("Importar para o Fotos da Apple?", isPresented: $ui.confirmingImport) {
            Button("Cancelar", role: .cancel) {}
            Button("Importar \(eligibleSelection.count) itens") {
                Task { await model.importSelected() }
            }
        } message: {
            Text("Serão criados \(eligibleSelection.count) itens no álbum “\(model.destinationAlbumName.trimmingCharacters(in: .whitespacesAndNewlines))” da biblioteca do Fotos deste Mac. O macOS poderá pedir permissão. A sincronização com o iCloud segue os ajustes do Fotos. Os originais continuam no Immich.")
        }
    }

    private var sourceControls: some View {
        PFCard {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 12) { albumPicker; sourceActions }
                    VStack(alignment: .leading, spacing: 12) { albumPicker; sourceActions }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Álbum de destino no Fotos").font(.caption).foregroundStyle(.secondary)
                    TextField("Importadas do Immich", text: $model.destinationAlbumName)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                        .disabled(working)
                    Text("Cria um álbum com esse nome ou usa o existente na biblioteca deste Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Originais, data de captura e localização disponível serão preservados. Live Photos precisam de um par compatível; itens sem data válida ou com recursos indisponíveis ficam bloqueados.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var albumPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Álbum de origem no Immich").font(.caption).foregroundStyle(.secondary)
            Picker("Álbum de origem no Immich", selection: $model.albumID) {
                Text("Selecione um álbum").tag("")
                ForEach(model.albums) { album in
                    Text("\(album.name) · \(album.count) itens").tag(album.id)
                }
            }.labelsHidden().frame(minWidth: 200, maxWidth: .infinity)
                .disabled(working || !connectionReady || model.albums.isEmpty)
        }
    }

    private var sourceActions: some View {
        HStack(spacing: 10) {
            Button("Atualizar álbuns") { Task { await model.load(address: address, key: key, profileID: profileID) } }
                .disabled(working || !connectionReady)
            Button("Consultar itens") { Task { await model.loadAlbum() } }
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
            Text("Fotos e vídeos").font(.headline)
            PFBadge("\(eligibleSelection.count) selecionados")
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 12) {
            Button("Selecionar disponíveis") { model.selection = Set(model.items.filter(\.selectable).map(\.id)) }
                .disabled(working || !connectionReady || !model.items.contains(where: \.selectable))
            Button("Desmarcar") { model.selection = [] }.disabled(working || model.selection.isEmpty)
        }
    }

    private func itemRow(_ item: PFReverseItem) -> some View {
        PFCard {
            HStack(alignment: .top, spacing: 14) {
                Toggle(isOn: Binding(get: { model.selection.contains(item.id) }, set: { selected in
                    if selected { model.selection.insert(item.id) } else { model.selection.remove(item.id) }
                })) { Text("Selecionar \(item.name)") }
                    .labelsHidden().toggleStyle(.checkbox)
                    .disabled(working || !connectionReady || !item.selectable)
                    .accessibilityLabel("Selecionar \(item.name)")
                PFReverseThumbnail(model: model, item: item, connectionReady: connectionReady)
                VStack(alignment: .leading, spacing: 9) {
                    Text(item.name).font(.headline).lineLimit(2).textSelection(.enabled)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { mediaBadge(item); importBadge(item) }
                        VStack(alignment: .leading, spacing: 6) { mediaBadge(item); importBadge(item) }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        if let date = item.captureDate {
                            Label("Captura: \(date.formatted(date: .abbreviated, time: .standard))", systemImage: "calendar")
                        } else {
                            Label("Data de captura indisponível", systemImage: "calendar.badge.exclamationmark")
                        }
                        if let latitude = item.latitude, let longitude = item.longitude {
                            Label("GPS: \(latitude.formatted(.number.precision(.fractionLength(5)))) · \(longitude.formatted(.number.precision(.fractionLength(5))))", systemImage: "location")
                        } else {
                            Label("Sem localização disponível", systemImage: "location.slash")
                        }
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let issue = item.issue, !issue.isEmpty {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func mediaBadge(_ item: PFReverseItem) -> some View {
        PFBadge(item.isLive ? "Live Photo · com movimento" : item.typeLabel,
                systemImage: item.isLive ? "livephoto" : "photo.on.rectangle", color: item.isLive ? .teal : PFTheme.accent)
    }

    @ViewBuilder private func importBadge(_ item: PFReverseItem) -> some View {
        if item.isImported {
            PFBadge("Já importado por este app", systemImage: "checkmark.circle", color: .green)
        } else if !item.selectable {
            PFBadge("Indisponível", systemImage: "exclamationmark.circle", color: .orange)
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
                ProgressView("\(model.done) de \(model.total) itens concluídos", value: Double(model.done), total: Double(model.total))
            }
            Text("O histórico evita repetir importações feitas pelo Ponte Fotos. Ele não compara toda a biblioteca existente do Fotos. Pessoas reconhecidas e histórico de edições não são transferidos.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if working {
                    Button("Cancelar operação") { model.cancel() }
                }
                Spacer()
                Button {
                    ui.confirmingImport = true
                } label: {
                    Label("Importar para o Fotos…", systemImage: "square.and.arrow.down")
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(working || !connectionReady || eligibleSelection.isEmpty || model.destinationAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

@MainActor private final class PFReverseThumbnailState: ObservableObject {
    @Published var image: NSImage?
}

private struct PFReverseThumbnail: View {
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
        .accessibilityLabel("Prévia de \(item.name)")
        .task(id: connectionReady) {
            guard connectionReady else { state.image = nil; return }
            let image = await model.thumbnail(id: item.id)
            guard !Task.isCancelled else { return }
            state.image = image
        }
    }
}
