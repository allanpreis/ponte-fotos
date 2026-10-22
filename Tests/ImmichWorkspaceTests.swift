import Foundation

@main struct ImmichWorkspaceTests {
    @MainActor static func main() async {
        let model = IMWorkspaceModel(address: "http://localhost:1", primaryKey: "", profileID: "test", connectionReady: true, onBusyChanged: { _ in })
        var live = IMAsset(id: "live", ownerId: "a", originalFileName: "IMG.heic", checksum: "same")
        live.livePhotoVideoId = "motion"
        var still = IMAsset(id: "still", ownerId: "b", originalFileName: "IMG.HEIC", checksum: "same")
        still.ownerName = "Usuário B"
        let group = IMDuplicateGroup(id: "group", keepID: live.id, assets: [live, still])
        model.duplicates = IMDuplicateAnalysis(id: "analysis", profileID: "test", albums: [], createdAt: Date(), groups: [group], total: 2, skipped: 0)
        precondition(model.name("b") == "Usuário B", "Shared asset metadata must identify an owner without a saved key")
        model.credentials = [IMCredential(account: IMAccount(id: "b", name: "Usuário B conectada"), key: "test")]
        precondition(model.name("b") == "Usuário B conectada", "Connected account names take priority over metadata")
        model.credentials = []
        model.duplicateChoices = [group.id: live.id]
        precondition(!model.unsafeLiveRemoval, "Keeping motion copy must be allowed")
        model.duplicateChoices = [group.id: still.id]
        precondition(model.unsafeLiveRemoval, "Removing motion must be blocked")
        model.execute("duplicates")
        precondition(!model.busy && model.error != nil && model.history.isEmpty, "Unsafe selection must fail before durable history or requests")
        model.duplicateChoices = [:]
        precondition(!model.unsafeLiveRemoval, "Deselected groups must not block")
        var secondLive = live; secondLive.id = "live2"
        model.duplicates?.groups[0].assets.append(secondLive)
        model.duplicateChoices = [group.id: live.id]
        precondition(model.unsafeLiveRemoval, "Two motion copies cannot be trashed implicitly")
        let image = await model.thumbnail(still)
        precondition(image == nil, "Unavailable owner must not request another account's thumbnail")
        model.run("Consulta simulada") { try await Task.sleep(nanoseconds: 2_000_000_000) }
        precondition(model.busy && model.canCancel)
        model.cancelQuery()
        for _ in 0..<100 where model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil, "Read cancellation must restore controls without an error")
        model.run("Ação simulada", cancellable: false) { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(model.busy && !model.canCancel, "Mutation operations must not expose cancellation")
        for _ in 0..<100 where model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        let offline = IMWorkspaceModel(address: "http://localhost:1", primaryKey: "", profileID: "test", connectionReady: false, onBusyChanged: { _ in })
        var invoked = false
        offline.run("Must not run") { invoked = true }
        precondition(!invoked && !offline.busy && offline.error != nil, "Unvalidated connection must block every operation before requests")
        model.credentials = [IMCredential(account: IMAccount(id: "a", name: "Usuário A"), key: "fixture-only")]
        model.updateConnection(address: "http://localhost:1", ready: false)
        precondition(!model.connectionReady && model.credentials.count == 1 && model.duplicates != nil, "Transient revalidation must preserve workspace state and credentials")
        model.updateConnection(address: "http://localhost:1", ready: true)
        precondition(model.connectionReady && model.credentials.count == 1, "Same endpoint revalidation must restore readiness without recreating workspace")
        model.updateConnection(address: "http://localhost:2", ready: true)
        precondition(model.address == "http://localhost:2" && model.duplicates == nil && model.credentials.count == 1, "Endpoint switch invalidates analyses and preserves profile accounts")
        model.busy = true
        model.updateConnection(address: "http://localhost:3", ready: false)
        precondition(model.address == "http://localhost:2", "An active operation must pin the address")
        model.busy = false
        print("ImmichWorkspaceTests: 15 protection checks passed (no media requests)")
    }
}
