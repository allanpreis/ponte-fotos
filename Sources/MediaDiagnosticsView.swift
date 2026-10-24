import SwiftUI
import Photos

@MainActor private final class PFMediaDiagnosticsUIState: ObservableObject {
    @Published var messages: [PFMessage] = []
    @Published var inspecting = false
    @Published var inspected = false
}

/// Explicit inspection only: no uploads and no creation of Photos assets.
struct PFMediaDiagnosticsView: View {
    @ObservedObject private var localization = PFLocalization.shared
    let item: PhotoItem
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ui = PFMediaDiagnosticsUIState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Diagnóstico de mídia")).font(.title2.bold())
            Text(item.title).font(.headline).textSelection(.enabled)
            Text(L("A inspeção lê o original sem alterar a biblioteca. Para itens do Fotos, uma cópia temporária poderá ser baixada do iCloud conforme a opção de acesso aos originais."))
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(ui.messages.enumerated()), id: \.offset) { _, message in
                        Text(message.text).font(.callout).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 120, maxHeight: 320)
            if ui.inspecting { ProgressView(L("Inspecionando o original…")) }
            Text(L("Reconhecer o formato ou abrir uma prévia não comprova compatibilidade de importação, reprodução HDR, Dolby Vision ou edições de câmera lenta. Os arquivos são transferidos sem conversão."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Inspecionar original")) { Task { await inspect() } }
                    .disabled(ui.inspecting || ui.inspected || model.busy)
                Spacer()
                Button(L("Fechar")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(ui.inspecting)
            }
        }.padding(24).frame(width: 580)
            .interactiveDismissDisabled(ui.inspecting)
            .environment(\.locale, PFLocalization.locale)
    }

    @MainActor private func inspect() async {
        guard !ui.inspecting && !model.busy else { return }
        ui.inspecting = true; model.busy = true
        defer { ui.inspecting = false; ui.inspected = true; model.busy = false }
        if let external = item.external {
            let result = await PFMediaDiagnostics.inspect(url: external.url, isVideo: external.isVideo)
            ui.messages = result.messages
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ponte-diagnostics-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard !item.resources.isEmpty else { ui.messages = [M("Original indisponível para inspeção.")]; return }
            var results: [PFMessage] = []
            for resource in item.resources {
                let safeName = URL(fileURLWithPath: resource.originalFilename).lastPathComponent
                let file = directory.appendingPathComponent(UUID().uuidString + "-" + safeName)
                try await model.exportResource(resource, to: file)
                let result = await PFMediaDiagnostics.inspect(url: file, isVideo: resource.type == .video || resource.type == .pairedVideo)
                results.append(.verbatim(resource.originalFilename))
                results.append(contentsOf: result.messages)
                try? FileManager.default.removeItem(at: file)
            }
            ui.messages = results
        } catch { ui.messages = [M("Não foi possível inspecionar o original: \(PFMessage.error(error))")] }
    }
}
