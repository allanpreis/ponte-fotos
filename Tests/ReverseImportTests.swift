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
    func create(asset: PFReverseAsset, original: URL, paired: URL?, album: String) async throws -> String {
        receivedPair = paired != nil
        receivedDistinctResources = paired.map { $0 != original && FileManager.default.fileExists(atPath: $0.path) && FileManager.default.fileExists(atPath: original.path) } ?? false
        calls += 1; if fail { throw BridgeError(message: "uncertain") }; existing.insert("photos-1"); return "photos-1"
    }
}
final class FakeRemote: PFReverseRemote {
    let scope = String(repeating: "a", count: 64)
    var value: PFReverseAsset; var related: [String: PFReverseAsset] = [:]; var downloads = 0; var onDownload: (() async -> Void)?
    init(_ value: PFReverseAsset) { self.value = value }
    func albums() async throws -> [IMAlbum] { [] }
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
        expect(photos.calls == 1 && remote.downloads == 1, "existing id skips download/import")
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
        let credential = IMCredential(account: IMAccount(id: "account", name: "Example"), key: "synthetic")
        let local = PFReverseHTTP(client: IMClient(address: "http://127.0.0.1:1234", credential: credential), profileID: "profile")
        let distant = PFReverseHTTP(client: IMClient(address: "https://photos.example.com", credential: credential), profileID: "profile")
        let other = PFReverseHTTP(client: IMClient(address: "https://photos.example.com", credential: credential), profileID: "other")
        expect(local.scope == distant.scope && local.scope != other.scope, "stable profile across endpoint changes")
        model.invalidateConnection(); expect(model.items.isEmpty && model.selection.isEmpty, "invalidated session clears")
        print("Reverse import: \(checks) synthetic checks passed; no network or real Photos writes.")
    }
}
