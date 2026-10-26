import Foundation

struct PFAlbumFollowLink: Codable, Equatable {
    let albumID: String
    var destinationID: String
    var destinationTitle: String
    var completed: [String: String]
    var lastChecked: Date?
}

protocol PFAlbumFollowStore {
    func load(scope: String) throws -> [PFAlbumFollowLink]
    func save(_ links: [PFAlbumFollowLink], scope: String) throws
}

/// Contains album identifiers and completion receipts only; never credentials.
struct PFAlbumFollowDiskStore: PFAlbumFollowStore {
    private let root: URL

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PonteFotos/album-follow", isDirectory: true)) {
        self.root = root
    }

    private func url(scope: String) throws -> URL {
        guard scope.count == 64, scope.allSatisfy({ $0.isHexDigit }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return root.appendingPathComponent(scope + ".json")
    }

    func load(scope: String) throws -> [PFAlbumFollowLink] {
        let file = try url(scope: scope)
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        }
        return try JSONDecoder().decode([PFAlbumFollowLink].self, from: data)
    }

    func save(_ links: [PFAlbumFollowLink], scope: String) throws {
        let file = try url(scope: scope)
        let data = try JSONEncoder().encode(links)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        // The enclosing private directory protects the replacement while its mode is tightened.
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
