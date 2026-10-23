import Foundation
import CryptoKit

final class MemoryHistory: PFReverseHistory {
    var values: [PFReverseRecord] = []; var saves = 0; var failAt = 0
    func load(scope: String) throws -> [PFReverseRecord] { values }
    func save(_ records: [PFReverseRecord], scope: String) throws { saves += 1; if saves == failAt { throw BridgeError(message: "disk failed") }; values = records }
}
@MainActor final class FakePhotos: PFReversePhotos {
    var calls = 0; var authorized = false; var existing = Set<String>(); var fail = false; var deny = false; var invalidPair = false
    var receivedPair = false; var receivedDistinctResources = false
    var canRead: Bool { authorized }
    func authorize() async throws { authorized = true; if deny { throw BridgeError(message: "denied") } }
    func exists(_ id: String) -> Bool { existing.contains(id) }
    func validate(asset: PFReverseAsset, original: URL, paired: URL?) async throws { if invalidPair { throw BridgeError(message: "invalid pair") } }
    var albumRows = [PFPhotosAlbum(id: "album-1", title: "Viagens")]
    var albumCreations = 0; var links = 0; var lastAlbumID: String?; var readOnlyIDs = Set<String>()
    var onList: (() -> Void)?
    func listAlbums() async throws -> [PFPhotosAlbum] { try await authorize(); onList?(); return PFPhotosAlbum.labeled(albumRows.filter { !readOnlyIDs.contains($0.id) }) }
    func prepareDestination(_ destination: PFPhotosDestination) throws {
        guard destination.isValid else { throw BridgeError(message: "empty destination") }
        if case .existing(let id, _) = destination {
            guard albumRows.contains(where: { $0.id == id }), !readOnlyIDs.contains(id) else { throw BridgeError(message: "missing or readonly") }
        }
    }
    func resolve(_ destination: PFPhotosDestination) throws -> String {
        try prepareDestination(destination)
        switch destination {
        case .existing(let id, _): lastAlbumID = id; return id
        case .new(let name):
            albumCreations += 1
            let id = "created-album-\(albumCreations)"; albumRows.append(PFPhotosAlbum(id: id, title: name)); lastAlbumID = id; return id
        }
    }
    func addExisting(id: String, destination: PFPhotosDestination) async throws -> String {
        guard existing.contains(id) else { throw BridgeError(message: "missing photo") }
        links += 1; return try resolve(destination)
    }
    func create(asset: PFReverseAsset, original: URL, paired: URL?, destination: PFPhotosDestination) async throws -> PFPhotosImportResult {
        receivedPair = paired != nil
        receivedDistinctResources = paired.map { $0 != original && FileManager.default.fileExists(atPath: $0.path) && FileManager.default.fileExists(atPath: original.path) } ?? false
        calls += 1; if fail { throw BridgeError(message: "uncertain") }
        let albumID = try resolve(destination)
        let id = "photos-\(calls)"; existing.insert(id); return PFPhotosImportResult(assetID: id, albumID: albumID)
    }
}
final class FakeRemote: PFReverseRemote {
    let scope = String(repeating: "a", count: 64)
    var value: PFReverseAsset; var related: [String: PFReverseAsset] = [:]; var downloads = 0; var onDownload: (() async -> Void)?
    init(_ value: PFReverseAsset) { self.value = value }
    var albumRows: [IMAlbum] = []
    func albums() async throws -> [IMAlbum] { albumRows }
    func ids(album: String) async throws -> [String] { [value.id] }
    func asset(_ id: String) async throws -> PFReverseAsset { related[id] ?? value }
    func download(_ asset: PFReverseAsset, directory: URL) async throws -> URL {
        downloads += 1; await onDownload?(); let url = directory.appendingPathComponent(asset.id + ".original"); try Data("synthetic".utf8).write(to: url); return url
    }
}
@main struct ReverseImportTests {
    static func asset(date: String = "2026-10-22T10:00:00.000Z", gps: String = "\"latitude\":-23.5,\"longitude\":-46.6", checksum: String? = nil) throws -> PFReverseAsset {
        let sum = checksum ?? Data(Insecure.SHA1.hash(data: Data("synthetic".utf8))).base64EncodedString()
        return try JSONDecoder().decode(PFReverseAsset.self, from: Data("""
        {"id":"00000000-0000-0000-0000-000000000001","ownerId":"owner","originalFileName":"../../foto.jpg","checksum":"\(sum)","type":"IMAGE","fileCreatedAt":"\(date)","exifInfo":{\(gps)}}
        """.utf8))
    }
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        let labelModel = PFReverseImportModel(history: MemoryHistory(), photos: FakePhotos())
        labelModel.destinationMode = .new; labelModel.destinationAlbumName = "  Memórias  "
        expect(labelModel.destinationLabel == "Novo álbum: Memórias", "confirmation identifies new album and trims name")
        let value = try asset()
        expect(value.item.selectable, "valid date/GPS")
        expect(value.item.name == "foto.jpg", "basename traversal")
        expect(PFReverseAsset.safeName("..\\nested\\x.mov") == "x.mov", "windows traversal")
        expect(PFReverseAsset.safeName("../..") == "original", "dot basename")
        expect(try asset(date: "2026-10-22T10:00:00").item.issue != nil, "zone missing blocks")
        expect(try asset(date: "invalid").item.issue != nil, "invalid date blocks")
        expect(try asset(gps: "\"latitude\":91,\"longitude\":0").item.issue != nil, "range blocks")
        expect(try asset(gps: "\"latitude\":10").item.issue != nil, "partial gps blocks")
        expect(try asset(gps: "").item.selectable, "absent gps accepted")
        expect(try asset(checksum: "bad").item.issue != nil, "checksum required")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("synthetic".utf8).write(to: temp); defer { try? FileManager.default.removeItem(at: temp) }
        try PFReverseAsset.verify(temp, checksum: value.checksum)
        do { try PFReverseAsset.verify(temp, checksum: String(repeating: "0", count: 40)); fatalError("mismatch accepted") } catch { checks += 1 }
        let store = MemoryHistory(), photos = FakePhotos(), remote = FakeRemote(value)
        let model = PFReverseImportModel(history: store, photos: photos)
        model.use(remote: remote, assets: [value]); model.selection = [value.id]
        expect(!photos.authorized, "no permission while browsing")
        await model.importSelected()
        expect(photos.authorized && photos.calls == 1 && model.done == 1, "one explicit import")
        expect(store.values.first?.pending == false && store.values.first?.photosID == "photos-1", "confirmed history")
        model.use(remote: remote, assets: [value]); model.selection = [value.id]; await model.importSelected()
        expect(photos.calls == 1 && remote.downloads == 1 && photos.links == 1, "existing id links without download/import")
        photos.existing.removeAll(); model.use(remote: remote, assets: [value]); model.selection = [value.id]; await model.importSelected()
        expect(photos.calls == 2, "deleted photos id permits reimport")
        let pending = MemoryHistory(); pending.values = [PFReverseRecord(assetID: value.id, checksum: value.checksum, photosID: nil, pending: true)]
        let pendingPhotos = FakePhotos(), pendingModel = PFReverseImportModel(history: pending, photos: pendingPhotos)
        pendingModel.use(remote: remote, assets: [value]); pendingModel.selection = [value.id]; await pendingModel.importSelected()
        expect(pendingPhotos.calls == 0, "ambiguous history blocks retry")
        let failedStore = MemoryHistory(); failedStore.failAt = 1
        let failedPhotos = FakePhotos(), failed = PFReverseImportModel(history: failedStore, photos: failedPhotos)
        failed.use(remote: remote, assets: [value]); failed.selection = [value.id]; await failed.importSelected()
        expect(failedPhotos.calls == 0, "cannot persist intent prevents mutation")
        let ambiguousStore = MemoryHistory(); ambiguousStore.failAt = 2
        let ambiguousPhotos = FakePhotos(), ambiguous = PFReverseImportModel(history: ambiguousStore, photos: ambiguousPhotos)
        ambiguous.use(remote: remote, assets: [value]); ambiguous.selection = [value.id]; await ambiguous.importSelected()
        expect(ambiguousStore.values.first?.pending == true && ambiguousPhotos.calls == 1, "final history failure retains intent")
        ambiguous.use(remote: remote, assets: [value]); ambiguous.selection = [value.id]; await ambiguous.importSelected()
        expect(ambiguousPhotos.calls == 1, "final write failure blocks retry")
        let denyPhotos = FakePhotos(); denyPhotos.deny = true
        let denyStore = MemoryHistory(), denied = PFReverseImportModel(history: denyStore, photos: denyPhotos)
        denied.use(remote: remote, assets: [value]); denied.selection = [value.id]; await denied.importSelected()
        expect(denyPhotos.calls == 0 && denyStore.saves == 0, "denied access never mutates")
        let cancelPhotos = FakePhotos(), cancelStore = MemoryHistory(), cancelRemote = FakeRemote(value)
        let cancelModel = PFReverseImportModel(history: cancelStore, photos: cancelPhotos)
        cancelRemote.onDownload = { cancelModel.cancel() }
        cancelModel.use(remote: cancelRemote, assets: [value]); cancelModel.selection = [value.id]; await cancelModel.importSelected()
        expect(cancelPhotos.calls == 0 && cancelStore.saves == 0, "cancellation before commit")
        let invalidPhotos = FakePhotos(); invalidPhotos.invalidPair = true
        let invalidStore = MemoryHistory(), invalid = PFReverseImportModel(history: invalidStore, photos: invalidPhotos)
        invalid.use(remote: remote, assets: [value]); invalid.selection = [value.id]; await invalid.importSelected()
        expect(invalidPhotos.calls == 0 && invalidStore.saves == 0, "incompatible resource fails before intent")
        let metadataPhotos = FakePhotos(), metadataStore = MemoryHistory(), changedRemote = FakeRemote(try asset(date: "2026-10-23T10:00:00Z"))
        let changed = PFReverseImportModel(history: metadataStore, photos: metadataPhotos)
        changed.use(remote: changedRemote, assets: [value]); changed.selection = [value.id]; await changed.importSelected()
        expect(metadataPhotos.calls == 0 && metadataStore.saves == 0, "metadata changed requires review")
        let liveJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","ownerId":"owner","originalFileName":"live.heic","checksum":"\(value.checksum)","type":"IMAGE","fileCreatedAt":"2026-10-22T10:00:00Z","livePhotoVideoId":"00000000-0000-0000-0000-000000000002"}
        """
        let videoJSON = """
        {"id":"00000000-0000-0000-0000-000000000002","ownerId":"owner","originalFileName":"live.mov","checksum":"\(value.checksum)","type":"VIDEO","fileCreatedAt":"2026-10-22T10:00:00Z"}
        """
        let liveAsset = try JSONDecoder().decode(PFReverseAsset.self, from: Data(liveJSON.utf8))
        let videoAsset = try JSONDecoder().decode(PFReverseAsset.self, from: Data(videoJSON.utf8))
        let liveRemote = FakeRemote(liveAsset); liveRemote.related[videoAsset.id] = videoAsset
        let livePhotos = FakePhotos(), liveStore = MemoryHistory(), liveModel = PFReverseImportModel(history: liveStore, photos: livePhotos)
        liveModel.use(remote: liveRemote, assets: [liveAsset]); liveModel.selection = [liveAsset.id]; await liveModel.importSelected()
        expect(liveRemote.downloads == 2 && livePhotos.calls == 1 && livePhotos.receivedPair && livePhotos.receivedDistinctResources, "Live pair downloaded and passed together exactly once")
        expect(liveModel.done == 1 && liveStore.values.first?.pending == false, "Live pair one successful history item")
        let unavailableJSON = videoJSON.dropLast() + ",\"isOffline\":true}"
        let unavailableRemote = FakeRemote(liveAsset)
        unavailableRemote.related[videoAsset.id] = try JSONDecoder().decode(PFReverseAsset.self, from: Data(unavailableJSON.utf8))
        let unavailablePhotos = FakePhotos(), unavailableStore = MemoryHistory(), unavailableModel = PFReverseImportModel(history: unavailableStore, photos: unavailablePhotos)
        unavailableModel.use(remote: unavailableRemote, assets: [liveAsset]); unavailableModel.selection = [liveAsset.id]; await unavailableModel.importSelected()
        expect(unavailablePhotos.calls == 0 && unavailableStore.saves == 0 && unavailableRemote.downloads == 1, "unavailable paired video prevents any Photos creation")
        let badPairPhotos = FakePhotos(); badPairPhotos.invalidPair = true
        let badPairStore = MemoryHistory(), badPairModel = PFReverseImportModel(history: badPairStore, photos: badPairPhotos)
        badPairModel.use(remote: liveRemote, assets: [liveAsset]); badPairModel.selection = [liveAsset.id]; await badPairModel.importSelected()
        expect(badPairPhotos.calls == 0 && badPairStore.saves == 0, "invalid Live pairing fails before history intent")
        let staleRemote = FakeRemote(value), stalePhotos = FakePhotos(), staleStore = MemoryHistory()
        let staleModel = PFReverseImportModel(history: staleStore, photos: stalePhotos)
        staleRemote.onDownload = { staleModel.invalidateConnection() }
        staleModel.use(remote: staleRemote, assets: [value]); staleModel.selection = [value.id]; await staleModel.importSelected()
        expect(stalePhotos.calls == 0 && staleStore.saves == 0 && staleModel.items.isEmpty && staleModel.selection.isEmpty, "connection invalidation during download prevents creation and clears snapshot")
        let switched = PFReverseImportModel(history: MemoryHistory(), photos: FakePhotos())
        switched.use(remote: remote, assets: [value]); switched.selection = [value.id]; switched.albumID = "different-album"
        expect(switched.selection.isEmpty && switched.items.isEmpty, "album switch clears previous items and selection")
        let collidingLabels = PFPhotosAlbum.labeled([PFPhotosAlbum(id: "12345678-A", title: "Mesmo"), PFPhotosAlbum(id: "12345678-B", title: "Mesmo")])
        expect(Set(collidingLabels.map(\.label)).count == 2, "same-prefix duplicate album names remain distinguishable")
        let destinationPhotos = FakePhotos(), destinationStore = MemoryHistory(), destinationRemote = FakeRemote(value)
        destinationPhotos.albumRows = [PFPhotosAlbum(id: "same-aaa1", title: "Viagens"), PFPhotosAlbum(id: "same-bbb2", title: "Viagens"), PFPhotosAlbum(id: "readonly", title: "Compartilhado")]
        destinationPhotos.readOnlyIDs = ["readonly"]
        let destinations = PFReverseImportModel(history: destinationStore, photos: destinationPhotos)
        destinations.use(remote: destinationRemote, assets: [value])
        destinationPhotos.onList = { expect(destinations.busy && destinations.loadingDestinations, "listing blocks concurrent operations") }
        await destinations.loadPhotosAlbums()
        expect(destinationPhotos.calls == 0 && destinationPhotos.links == 0 && destinationPhotos.albumCreations == 0 && destinationStore.saves == 0 && destinationRemote.downloads == 0, "listing authorizes but never mutates or downloads")
        expect(destinations.destinationAlbumID.isEmpty, "listing does not silently choose a destination")
        expect(destinations.photosAlbums.count == 2 && Set(destinations.photosAlbums.map(\.label)).count == 2, "editable albums and duplicate title labels")
        destinations.destinationMode = .existing; destinations.destinationAlbumID = "same-bbb2"; destinations.selection = [value.id]
        expect(destinations.destinationLabel == destinations.photosAlbums.first(where: { $0.id == "same-bbb2" })?.label, "confirmation distinguishes duplicate destination names")
        await destinations.importSelected()
        expect(destinationPhotos.lastAlbumID == "same-bbb2" && destinationPhotos.albumCreations == 0, "exact identifier wins over duplicate album title")
        // Already-imported rows remain selectable and can be linked to another album.
        expect(destinations.items.first?.isImported == true && destinations.items.first?.selectable == true, "known imported row remains selectable")
        destinations.destinationAlbumID = "same-aaa1"; destinations.selection = [value.id]
        await destinations.importSelected()
        expect(destinationPhotos.lastAlbumID == "same-aaa1" && destinationPhotos.calls == 1 && destinationPhotos.links == 1 && destinationRemote.downloads == 1 && destinationStore.saves == 2, "known photos link to second album with unchanged history and original")
        let blockedPhotos = FakePhotos(), blockedStore = MemoryHistory(), blockedRemote = FakeRemote(value)
        let blocked = PFReverseImportModel(history: blockedStore, photos: blockedPhotos)
        blocked.use(remote: blockedRemote, assets: [value]); await blocked.loadPhotosAlbums()
        blocked.destinationMode = .existing; blocked.destinationAlbumID = "album-1"; blocked.selection = [value.id]
        blockedPhotos.albumRows = []
        await blocked.importSelected()
        expect(blockedPhotos.calls == 0 && blockedRemote.downloads == 0 && blockedStore.saves == 0, "deleted destination rejected before download or intent")
        blockedPhotos.albumRows = [PFPhotosAlbum(id: "album-1", title: "Viagens")]; blockedPhotos.readOnlyIDs = ["album-1"]
        await blocked.importSelected()
        expect(blockedPhotos.calls == 0 && blockedRemote.downloads == 0 && blockedStore.saves == 0, "read-only destination rejected before download or intent")
        blocked.destinationMode = .new; blocked.destinationAlbumName = "   \n "; await blocked.importSelected()
        expect(!blocked.isDestinationValid && blockedPhotos.calls == 0, "whitespace-only new name blocked")
        let batchPhotos = FakePhotos(), batchStore = MemoryHistory(), batchRemote = FakeRemote(value)
        let secondJSON = """
        {"id":"00000000-0000-0000-0000-000000000003","ownerId":"owner","originalFileName":"second.jpg","checksum":"\(value.checksum)","type":"IMAGE","fileCreatedAt":"2026-10-22T10:00:00Z"}
        """
        let second = try JSONDecoder().decode(PFReverseAsset.self, from: Data(secondJSON.utf8)); batchRemote.related[second.id] = second
        let batch = PFReverseImportModel(history: batchStore, photos: batchPhotos)
        batch.destinationMode = .new; batch.destinationAlbumName = " Viagens "
        batch.use(remote: batchRemote, assets: [value, second]); batch.selection = [value.id, second.id]
        await batch.importSelected()
        expect(batchPhotos.calls == 2 && batchPhotos.albumCreations == 1 && batch.done == 2, "new destination creates exactly one album per batch even if title already exists")
        expect(batchPhotos.albumRows.last?.title == "Viagens", "new album title trimmed")
        expect(batch.destinationMode == .existing && batch.destinationAlbumID == "created-album-1" && batch.photosAlbums.contains(where: { $0.id == "created-album-1" }), "created album becomes selected for subsequent batches")
        batch.selection = [value.id]; await batch.importSelected()
        expect(batchPhotos.albumCreations == 1 && batchPhotos.calls == 2 && batchPhotos.links == 1, "subsequent batch reuses new album without recreating original")
        let snapshotPhotos = FakePhotos(), snapshotStore = MemoryHistory(), snapshotRemote = FakeRemote(value)
        let snapshot = PFReverseImportModel(history: snapshotStore, photos: snapshotPhotos)
        snapshot.destinationMode = .new; snapshot.destinationAlbumName = "Revisado"
        snapshotRemote.onDownload = { snapshot.destinationAlbumName = "Alterado" }
        snapshot.use(remote: snapshotRemote, assets: [value]); snapshot.selection = [value.id]; await snapshot.importSelected()
        expect(snapshotPhotos.albumRows.last?.title == "Revisado", "destination snapshot is immutable while downloading")
        let linkedPhotos = FakePhotos(), linkedStore = MemoryHistory(), linkedRemote = FakeRemote(value)
        linkedPhotos.existing = ["previous-photo"]; linkedStore.values = [PFReverseRecord(assetID: value.id, checksum: value.checksum, photosID: "previous-photo", pending: false)]
        let linked = PFReverseImportModel(history: linkedStore, photos: linkedPhotos)
        linked.use(remote: linkedRemote, assets: [value]); linked.selection = [value.id]; linked.destinationAlbumName = "Novo destino"
        await linked.importSelected()
        expect(linkedPhotos.albumCreations == 1 && linkedPhotos.calls == 0 && linkedRemote.downloads == 0 && linkedStore.saves == 0 && linked.destinationMode == .existing, "new album may link known photo without history changes or recreation")
        let credential = IMCredential(account: IMAccount(id: "account", name: "Example"), key: "synthetic")
        let local = PFReverseHTTP(client: IMClient(address: "http://127.0.0.1:1234", credential: credential), profileID: "profile")
        let distant = PFReverseHTTP(client: IMClient(address: "https://photos.example.com", credential: credential), profileID: "profile")
        let other = PFReverseHTTP(client: IMClient(address: "https://photos.example.com", credential: credential), profileID: "other")
        expect(local.scope == distant.scope && local.scope != other.scope, "stable profile across endpoint changes")
        model.invalidateConnection(); expect(model.items.isEmpty && model.selection.isEmpty, "invalidated session clears")
        let refreshRemote = FakeRemote(value)
        refreshRemote.albumRows = [IMAlbum(id: "a", name: "A", ownerID: "owner"), IMAlbum(id: "b", name: "B", ownerID: "owner")]
        let refresh = PFReverseImportModel(history: MemoryHistory(), photos: FakePhotos(), connect: { _, _, _ in refreshRemote })
        let profile = UUID().uuidString
        await refresh.load(address: "https://photos.example.com", key: "synthetic", profileID: profile)
        refresh.albumID = "b"
        await refresh.loadAlbum()
        await refresh.load(address: "https://photos.example.com", key: "synthetic", profileID: profile)
        expect(refresh.albumID == "b" && refresh.albums.count == 2, "refresh retains selected source by ID")
        refreshRemote.albumRows.removeAll { $0.id == "b" }
        await refresh.load(address: "https://photos.example.com", key: "synthetic", profileID: profile)
        expect(refresh.albumID.isEmpty, "removed source is not silently replaced")
        refresh.albumID = "b"
        await refresh.load(address: "https://other.example.com", key: "other", profileID: profile)
        expect(refresh.albumID == "a", "changed connection discards old source context")
        refresh.invalidateConnection()
        expect(refresh.albums.isEmpty && refresh.items.isEmpty && refresh.selection.isEmpty, "real invalidation still clears source and review")
        print("Reverse import: \(checks) synthetic checks passed; no network or real Photos writes.")
    }
}
