import Foundation

@main struct WorkspaceSessionTests {
    @MainActor static func main() {
        let cache = IMWorkspaceSessionCache()
        func prepare(_ key: String = "fixture", _ profile: String = "profile", _ address: String = "http://localhost:1", ready: Bool = true) -> IMWorkspaceModel? {
            cache.prepare(address: address, primaryKey: key, profileID: profile, ready: ready, onBusyChanged: { _ in })
        }
        precondition(prepare(ready: false) == nil && cache.current == nil)
        let settings = prepare()!
        settings.credentials = [IMCredential(account: IMAccount(id: "a", name: "Fixture"), key: "in-memory-only")]
        settings.endReview()
        let management = prepare()!
        precondition(settings === management && management.credentials.count == 1, "In-memory account must survive navigation between Settings and management")
        precondition(prepare(ready: false) == nil && cache.current === settings && !settings.connectionReady)
        precondition(prepare() === settings && settings.connectionReady)
        precondition(prepare("fixture", "profile", "http://localhost:2") === settings && settings.credentials.count == 1)
        let changedKey = prepare("other-key")!
        precondition(changedKey !== settings && changedKey.credentials.isEmpty)
        let changedProfile = prepare("other-key", "other-profile")!
        precondition(changedProfile !== changedKey && changedProfile.credentials.isEmpty)
        changedProfile.busy = true
        precondition(prepare("third-key") == nil && cache.current === changedProfile, "An active operation cannot replace its session")
        changedProfile.busy = false
        let reconnected = prepare("other-key", "other-profile", "http://localhost:3")!
        precondition(reconnected === changedProfile && reconnected.connectionReady && reconnected.address == "http://localhost:3", "Synchronization must succeed once the active operation finishes")
        print("Workspace session: account continuity, offline state, endpoint changes, key/profile invalidation and busy protection passed.")
    }
}
