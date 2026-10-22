import Foundation
import CryptoKit

struct TransferRecord: Codable {
    let resourceIndex: Int
    let checksum: String
    let result: UploadResult
}

enum ConnectionHistory {
    static func recordURL(directory: URL, profileID: String, userID: String, itemID: String) -> URL {
        // URLs may change; the configured server profile and Immich account remain stable.
        let identity = [profileID, userID, itemID].joined(separator: "\n")
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("profile-" + name + ".json")
    }
    static func legacyURLs(directory: URL, addresses: [String], itemID: String) -> [URL] {
        var urls: [URL] = []
        for address in addresses {
            guard let client = try? ImmichClient(address: address, key: "history-path-only") else { continue }
            let name = Data((client.base.absoluteString + "|" + itemID).utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            let url = directory.appendingPathComponent(name + ".json")
            if !urls.contains(url) { urls.append(url) }
        }
        return urls
    }
    static func load(_ urls: [URL]) -> [TransferRecord] {
        for url in urls {
            if let data = try? Data(contentsOf: url), let records = try? JSONDecoder().decode([TransferRecord].self, from: data), !records.isEmpty { return records }
        }
        return []
    }
    static func save(_ records: [TransferRecord], to url: URL) throws {
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
