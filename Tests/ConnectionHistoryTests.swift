import Foundation
@main struct ConnectionHistoryTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = ConnectionHistory.recordURL(directory: dir, profileID: "home", userID: "user-a", itemID: "photo")
        precondition(a == ConnectionHistory.recordURL(directory: dir, profileID: "home", userID: "user-a", itemID: "photo"))
        precondition(a != ConnectionHistory.recordURL(directory: dir, profileID: "home", userID: "user-b", itemID: "photo"))
        precondition(a != ConnectionHistory.recordURL(directory: dir, profileID: "other", userID: "user-a", itemID: "photo"))
        let legacy = ConnectionHistory.legacyURLs(directory: dir, addresses: ["http://local:2283", "http://remote:2283", "http://local:2283/api", ""], itemID: "photo")
        precondition(legacy.count == 2)
        let record = TransferRecord(resourceIndex: 0, checksum: "same", result: UploadResult(id: "old", status: "created"))
        try ConnectionHistory.save([record], to: legacy[0])
        let records = ConnectionHistory.load([a] + legacy)
        precondition(records.count == 1 && records[0].result.id == "old")
        try ConnectionHistory.save(records, to: a)
        precondition(ConnectionHistory.load([a]).count == 1)
        precondition(FileManager.default.fileExists(atPath: legacy[0].path))
        let mode = try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue & 0o777 == 0o600)
        let data = Data(#"{"address":"http://old:2283","key":"fixture-only"}"#.utf8)
        let old = try JSONDecoder().decode(ConnectionStore.Connection.self, from: data)
        precondition(old.profile == nil && old.userID == nil)
        let profile = ConnectionProfile(id: "home", localAddress: "http://local:2283", remoteAddress: "http://remote:2283", homeSSID: "MinhaRedeDeTeste", mode: .automatic)
        precondition(profile.recognizes(address: "http://remote:2283/"))
        precondition(profile.recognizes(address: "http://local:2283/api"))
        precondition(!profile.recognizes(address: "http://different:2283"))
        let saved = ConnectionStore.Connection(address: "http://local:2283", key: "fixture-only", profile: profile, userID: "user-a")
        let restored = try JSONDecoder().decode(ConnectionStore.Connection.self, from: JSONEncoder().encode(saved))
        precondition(restored.profile == profile && restored.userID == "user-a")
        print("Histórico por perfil/conta, caminhos legados, migração sem remover origem, permissão 0600 e compatibilidade da conexão salva passaram.")
    }
}
