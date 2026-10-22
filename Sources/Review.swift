import SwiftUI

enum UploadDestination: String, CaseIterable, Identifiable {
    case timeline, existing, new
    var id: String { rawValue }
    var label: String {
        switch self { case .timeline: return "Rolo da câmera · sem álbum"; case .existing: return "Álbum existente"; case .new: return "Criar álbum" }
    }
}
@MainActor final class ReviewDraft: ObservableObject {
    @Published var setDate: Bool
    @Published var date: Date
    @Published var setLocation: Bool
    @Published var latitude: String
    @Published var longitude: String
    @Published var error = ""
    init(metadata: CaptureMetadata) {
        setDate = metadata.date != nil; date = metadata.date ?? Date()
        setLocation = metadata.latitude != nil
        latitude = metadata.latitude.map { String($0) } ?? ""
        longitude = metadata.longitude.map { String($0) } ?? ""
    }
}
struct ReviewEditor: View {
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
        VStack(alignment: .leading, spacing: 20) {
            Text("Revisar informações").font(.title.bold())
            HStack { PhotoThumbnail(item: item); Text(item.title).font(.headline).textSelection(.enabled) }
            Text("Ajustes usados na exportação e no envio. Os arquivos de origem permanecem intactos.").foregroundStyle(.secondary)
            Toggle("Definir data e hora", isOn: $draft.setDate)
            if draft.setDate { DatePicker("Captura", selection: $draft.date).datePickerStyle(.field) }
            Text("Fuso desta edição: \(TimeZone.current.identifier). Informe a hora equivalente nesse fuso.").font(.caption).foregroundStyle(.secondary)
            Toggle("Definir localização", isOn: $draft.setLocation)
            if draft.setLocation {
                HStack { TextField("Latitude, ex.: −23,55052", text: $draft.latitude); TextField("Longitude, ex.: −46,63331", text: $draft.longitude) }.textFieldStyle(.roundedBorder)
            }
            Text("Desmarcar mantém os dados da origem. Sem data disponível, o envio continua bloqueado. Os ajustes salvos também serão aplicados se a foto já existir no Immich.").font(.caption).foregroundStyle(.secondary)
            if !draft.error.isEmpty { Text(draft.error).foregroundStyle(.red) }
            HStack {
                Button("Restaurar dados da origem") { do { try restore(); dismiss() } catch { draft.error = error.localizedDescription } }
                Spacer()
                Button("Cancelar", action: dismiss)
                Button("Salvar revisão") {
                    do {
                        var edit = MetadataOverride()
                        if draft.setDate, item.metadata.date == nil || abs(draft.date.timeIntervalSince(item.metadata.date!)) > 0.001 { edit.date = draft.date }
                        if draft.setLocation {
                            let (lat, lon) = try MetadataOverride.coordinates(draft.latitude, draft.longitude)
                            if lat != item.metadata.latitude || lon != item.metadata.longitude { edit.latitude = lat; edit.longitude = lon }
                        }
                        try save(edit); dismiss()
                    } catch { draft.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(.teal)
            }
        }.padding(28).frame(width: 620)
    }
}
