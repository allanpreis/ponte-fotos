import SwiftUI
import Photos
import Combine

/// An in-memory operation snapshot; credentials never enter the preparation cache.
@MainActor final class PFBackgroundPreparation: ObservableObject {
    typealias Files = [(Int, ResourceDescriptor, URL, URL)]
    let items: [PhotoItem]
    let originals: [PhotoItem]
    let fingerprints: [String: String]
    let profile: ConnectionProfile
    let accountLabel: String
    let accountID: String
    let destination: UploadDestination
    let albumID: String
    let newAlbumName: String
    let destinationLabel: String
    let sourceAlbum: String
    let sourceAlbums: [AlbumItem]
    let targetAlbums: [ImmichAlbum]
    let root: URL
    @Published var status = M("Preparando originais…")
    @Published var completed = 0
    @Published var bytes: Int64 = 0
    @Published var ready = false
    @Published var failed = false
    private var prepared: [String: Files] = [:]
    private var signatures: [URL: FileSignature] = [:]
    private var observation: AnyCancellable?
    private struct FileSignature: Equatable {
        let size: UInt64
        let modified: Date
        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.size = size.uint64Value; self.modified = modified
        }
    }
    init(items: [PhotoItem], originals: [PhotoItem], fingerprints: [String: String], profile: ConnectionProfile, accountID: String, accountLabel: String = "",
         destination: UploadDestination, albumID: String, newAlbumName: String, destinationLabel: String,
         sourceAlbum: String, sourceAlbums: [AlbumItem], targetAlbums: [ImmichAlbum], root: URL) {
        self.items = items; self.originals = originals; self.fingerprints = fingerprints; self.profile = profile; self.accountID = accountID; self.accountLabel = accountLabel
        self.destination = destination; self.albumID = albumID; self.newAlbumName = newAlbumName; self.destinationLabel = destinationLabel
        self.sourceAlbum = sourceAlbum; self.sourceAlbums = sourceAlbums; self.targetAlbums = targetAlbums; self.root = root
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func observe(_ worker: LibraryModel) {
        observation = worker.$statusMessage.sink { [weak self] in self?.status = $0 }
    }
    func stopObserving() { observation = nil }
    func store(item: PhotoItem, files: Files) throws {
        for (_, _, file, sidecar) in files {
            signatures[file] = try FileSignature(file); signatures[sidecar] = try FileSignature(sidecar)
            bytes += try PFUploadFileIO.size(of: file) + PFUploadFileIO.size(of: sidecar)
        }
        prepared[item.id] = files; completed += 1
    }
    func validateSources() throws {
        for item in items {
            guard let original = item.asset,
                  let current = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject,
                  current.modificationDate == original.modificationDate,
                  current.creationDate == original.creationDate,
                  current.mediaSubtypes == original.mediaSubtypes else { throw stale() }
            let resources = PHAssetResource.assetResources(for: current).filter { [.photo, .video, .pairedVideo, .alternatePhoto].contains($0.type) }
            func descriptors(_ values: [PHAssetResource]) -> [String] {
                values.map { "\($0.type.rawValue):\($0.originalFilename):\($0.uniformTypeIdentifier)" }
            }
            guard descriptors(resources) == descriptors(item.resources) else { throw stale() }
        }
        for (url, expected) in signatures {
            guard try FileSignature(url) == expected else { throw stale() }
        }
    }
    func take(item: PhotoItem, into staging: URL) throws -> Files {
        guard let files = prepared[item.id], let first = files.first else { throw stale() }
        for (_, _, file, sidecar) in files {
            guard let fileSignature = signatures[file], let sidecarSignature = signatures[sidecar],
                  try FileSignature(file) == fileSignature, try FileSignature(sidecar) == sidecarSignature else { throw stale() }
        }
        let source = first.2.deletingLastPathComponent().deletingLastPathComponent()
        let target = staging.appendingPathComponent(item.id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try FileManager.default.moveItem(at: source, to: target)
        prepared[item.id] = nil
        for (_, _, file, sidecar) in files { signatures[file] = nil; signatures[sidecar] = nil }
        return files.map { index, descriptor, file, sidecar in
            let resourceFolder = target.appendingPathComponent(String(index), isDirectory: true)
            return (index, descriptor, resourceFolder.appendingPathComponent(file.lastPathComponent), resourceFolder.appendingPathComponent(sidecar.lastPathComponent))
        }
    }
    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
        prepared = [:]; signatures = [:]
    }
    private func stale() -> BridgeError { BridgeError(message: M("Um original ou arquivo preparado mudou. Descarte o preparo e prepare novamente.")) }
}

struct PFPreparationBanner: View {
    @ObservedObject var job: PFBackgroundPreparation
    @Binding var showing: Bool
    let busy: Bool
    let cancel: () -> Void
    let resume: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            if !job.ready && !job.failed { ProgressView().controlSize(.small) }
            Text(job.ready ? L("Originais prontos para enviar") : L("Preparação em segundo plano")).font(.callout)
            Spacer()
            Button(L("Ver preparo")) { showing = true }
                .popover(isPresented: $showing) { panel.padding(20).frame(width: 420) }
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Preparação em segundo plano")).font(.headline)
                Spacer()
                Button(L("Fechar")) { showing = false }
            }
            Text(job.status.text).textSelection(.enabled)
            ProgressView(value: Double(job.completed), total: Double(max(1, job.items.count)))
            Text(L("\(job.completed) de \(job.items.count) itens preparados")).font(.caption)
            Text(ByteCountFormatter.string(fromByteCount: job.bytes, countStyle: .file) + " · " + L("espaço dos itens preparados")).font(.caption).foregroundStyle(.secondary)
            Text(job.accountLabel).font(.caption)
            Text(L("Destino: \(job.destinationLabel)")).font(.caption)
            Text(L("Você pode fechar este painel e usar o app. Mantenha o app aberto. O envio só começa após sua confirmação.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(job.ready || job.failed ? L("Descartar preparo") : L("Cancelar preparo"), role: .destructive, action: cancel)
                Spacer()
                if job.ready { Button(L("Voltar ao envio"), action: resume).disabled(busy) }
            }
        }
    }
}
