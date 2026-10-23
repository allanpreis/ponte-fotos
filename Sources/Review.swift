import SwiftUI

enum UploadDestination: String, CaseIterable, Identifiable {
    case timeline, existing, new
    var id: String { rawValue }
    var label: String {
        switch self { case .timeline: return L("Rolo da câmera · sem álbum"); case .existing: return L("Álbum existente"); case .new: return L("Criar álbum") }
    }
}
@MainActor final class ReviewDraft: ObservableObject {
    @Published var setDate: Bool
    @Published var date: Date
    @Published var setLocation: Bool
    @Published var latitude: String
    @Published var longitude: String
    @Published var errorMessage: PFMessage = ""
    var error: String { get { errorMessage.text } set { errorMessage = .verbatim(newValue) } }
    init(metadata: CaptureMetadata) {
        setDate = metadata.date != nil; date = metadata.date ?? Date()
        setLocation = metadata.latitude != nil
        latitude = metadata.latitude.map { String($0) } ?? ""
        longitude = metadata.longitude.map { String($0) } ?? ""
    }
}
struct ReviewEditor: View {
    @ObservedObject private var localization = PFLocalization.shared
    let item: PhotoItem
    let save: (MetadataOverride) throws -> Void
    let restore: () throws -> Void
    let dismiss: () -> Void
    @StateObject private var draft: ReviewDraft
    init(item: PhotoItem, metadata: CaptureMetadata, save: @escaping (MetadataOverride) throws -> Void, restore: @escaping () throws -> Void, dismiss: @escaping () -> Void) {
        self.item = item; self.save = save; self.restore = restore; self.dismiss = dismiss
        _draft = StateObject(wrappedValue: ReviewDraft(metadata: metadata))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 48, height: 48)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Revisar informações")).font(.title2.bold())
                    Text(L("Complete a história desta foto antes de enviar."))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center, spacing: 14) {
                        PhotoThumbnail(item: item)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Label(L("Original preservado"), systemImage: "checkmark.shield")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(L("Os ajustes serão usados na exportação e no envio. Os arquivos de origem permanecem intactos."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle(L("Definir data e hora"), isOn: $draft.setDate)
                            if draft.setDate {
                                DatePicker(L("Captura"), selection: $draft.date).datePickerStyle(.field)
                            }
                            Text(L("Fuso desta edição: \(TimeZone.current.identifier). Informe a hora equivalente nesse fuso."))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label(L("Data e hora"), systemImage: "calendar").font(.headline)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle(L("Definir localização"), isOn: $draft.setLocation)
                            if draft.setLocation {
                                HStack(alignment: .top, spacing: 12) {
                                    coordinateField(L("Latitude"), placeholder: L("Ex.: −23,55052"), text: $draft.latitude)
                                    coordinateField(L("Longitude"), placeholder: L("Ex.: −46,63331"), text: $draft.longitude)
                                }
                            }
                            Text(L("Desmarcar mantém os dados da origem."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label(L("Localização"), systemImage: "mappin.and.ellipse").font(.headline)
                    }
                    Label {
                        Text(L("Sem data disponível, o envio continua bloqueado. Os ajustes salvos também serão aplicados se a foto já existir no Immich."))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if !draft.error.isEmpty {
                        Label(draft.error, systemImage: "exclamationmark.circle.fill")
                            .font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(24)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    restoreButton
                    Spacer(minLength: 16)
                    actionButtons
                }
                VStack(alignment: .trailing, spacing: 12) {
                    restoreButton
                    actionButtons
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            .background(.bar)
        }
        .tint(.blue)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 720)
        .frame(height: 650)
    }

    private func coordinateField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LV(title)).font(.caption).foregroundStyle(.secondary)
            TextField(LV(placeholder), text: text).textFieldStyle(.roundedBorder)
                .accessibilityLabel(LV(title))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var restoreButton: some View {
        Button(L("Restaurar dados da origem")) { do { try restore(); dismiss() } catch { draft.errorMessage = .error(error) } }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(L("Cancelar"), action: dismiss).keyboardShortcut(.cancelAction)
            Button(L("Salvar revisão")) {
                do {
                    var edit = MetadataOverride()
                    if draft.setDate, item.metadata.date == nil || abs(draft.date.timeIntervalSince(item.metadata.date!)) > 0.001 { edit.date = draft.date }
                    if draft.setLocation {
                        let (lat, lon) = try MetadataOverride.coordinates(draft.latitude, draft.longitude)
                        if lat != item.metadata.latitude || lon != item.metadata.longitude { edit.latitude = lat; edit.longitude = lon }
                    }
                    try save(edit); dismiss()
                } catch { draft.errorMessage = .error(error) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}
