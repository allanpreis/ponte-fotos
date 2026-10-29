import Foundation
import Photos
import CryptoKit

/// Original-byte identity, independent of transfer receipts or filenames.
struct PFPhotoOriginalIdentity: Codable, Equatable {
    enum Kind: String, Codable { case image, video, live }
    let photosID: String
    let kind: Kind
    let checksum: String
    let pairedChecksum: String?
    let sourceStamp: String

    static func normalizedChecksum(_ value: String) -> String? {
        if value.count == 40, value.allSatisfy({ $0.isHexDigit }) {
            var bytes = Data(); var index = value.startIndex
            while index < value.endIndex {
                let next = value.index(index, offsetBy: 2)
                guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
                bytes.append(byte); index = next
            }
            return bytes.base64EncodedString()
        }
        guard let bytes = Data(base64Encoded: value), bytes.count == 20,
              bytes.base64EncodedString() == value else { return nil }
        return value
    }
    func matches(kind: Kind, checksum: String, pairedChecksum: String?) -> Bool {
        guard self.kind == kind,
              let expected = Self.normalizedChecksum(self.checksum),
              expected == Self.normalizedChecksum(checksum) else { return false }
        if kind == .live {
            guard let ownPair = self.pairedChecksum.flatMap(Self.normalizedChecksum),
                  ownPair == pairedChecksum.flatMap(Self.normalizedChecksum) else { return false }
        } else if self.pairedChecksum != nil || pairedChecksum != nil { return false }
        return true
    }
}

/// Cache contains hashes and PhotoKit identities only. Each export is removed
/// before the next resource, so inventory does not retain an album of originals.
@MainActor enum PFPhotoAlbumInventory {
    struct Source {
        let photosID: String
        let kind: PFPhotoOriginalIdentity.Kind
        let sourceStamp: String
        // Missing modification dates cannot support persistent hash reuse.
        var cacheable = true
    }
    private struct Cache: Codable {
        var version = 1
        var entries: [String: PFPhotoOriginalIdentity] = [:]
    }
    private struct AlbumSource {
        let source: Source
        let resources: [PHAssetResource]
    }
    typealias Progress = (PFMessage, Int, Int) -> Void
    @MainActor private final class Feedback {
        var requestID: UUID?
        let progress: Progress
        init(_ progress: @escaping Progress) { self.progress = progress }
    }

    static func scan(albumID: String, allowCloud: Bool, root: URL,
                     progress: @escaping Progress = { _, _, _ in }) async throws -> [PFPhotoOriginalIdentity] {
        let feedback = Feedback(progress)
        defer { feedback.requestID = nil }
        let snapshots = try readAlbum(albumID)
        let sources = snapshots.map(\.source)
        let resources = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.source.photosID, $0.resources) })
        let key = SHA256.hash(data: Data(albumID.utf8)).map { String(format: "%02x", $0) }.joined()
        return try await scanSources(sources, cacheURL: root.appendingPathComponent(key + ".json"),
                                     temporaryRoot: root.appendingPathComponent("temporary"), progress: progress,
                                     export: { source, index, url in
            guard let resource = resources[source.photosID]?[index] else { throw stale() }
            let requestID = UUID(), name = resource.originalFilename
            feedback.requestID = requestID
            defer { feedback.requestID = nil }
            try await TransferFileIO.exportPhotosResource(resource, to: url, allowCloud: allowCloud, progress: { fraction in
                Task { @MainActor in
                    guard feedback.requestID == requestID else { return }
                    feedback.progress(M("Conferindo original do Fotos: \(name) · \(Int(fraction * 100))%"), 0, sources.count)
                }
            })
        }, validate: {
            let current = try readAlbum(albumID).map(\.source)
            guard stamps(current) == stamps(sources) else { throw stale() }
        })
    }

    /// Recheck before using inventory as evidence for an album mutation.
    static func validate(albumID: String, identities: [PFPhotoOriginalIdentity]) throws {
        let current = try readAlbum(albumID).map(\.source)
        guard current.count == identities.count, Set(identities.map(\.photosID)).count == identities.count,
              Dictionary(uniqueKeysWithValues: current.map { ($0.photosID, $0.sourceStamp) }) ==
                Dictionary(uniqueKeysWithValues: identities.map { ($0.photosID, $0.sourceStamp) }) else { throw stale() }
    }

    // A bounded seam used by the PhotoKit adapter and deterministic private tests.
    static func scanSources(_ sources: [Source], cacheURL: URL, temporaryRoot: URL,
                            progress: Progress = { _, _, _ in },
                            export: (Source, Int, URL) async throws -> Void,
                            validate: () throws -> Void = {}) async throws -> [PFPhotoOriginalIdentity] {
        try Task.checkCancellation()
        guard Set(sources.map(\.photosID)).count == sources.count,
              sources.allSatisfy({ !$0.photosID.isEmpty && !$0.sourceStamp.isEmpty }) else { throw stale() }
        let manager = FileManager.default
        let parent = cacheURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        var cache: Cache
        do { cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { cache = Cache() }
        guard cache.version == 1 else { throw stale() }
        let sourceIDs = Set(sources.map(\.photosID))
        let retained = cache.entries.filter { sourceIDs.contains($0.key) }
        var cacheChanged = retained != cache.entries
        cache.entries = retained
        func saveCache() throws {
            guard cacheChanged else { return }
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            cacheChanged = false
        }
        // Checkpoint completed hashes on cancellation/error too. Do not serialize
        // the whole album after every row (quadratic I/O on large albums).
        defer { try? saveCache() }
        try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        var identities: [PFPhotoOriginalIdentity] = []
        for (position, source) in sources.enumerated() {
            try Task.checkCancellation()
            let value: PFPhotoOriginalIdentity
            if source.cacheable, let previous = cache.entries[source.photosID],
               previous.photosID == source.photosID, previous.sourceStamp == source.sourceStamp,
               previous.kind == source.kind, previous.matches(kind: source.kind, checksum: previous.checksum, pairedChecksum: previous.pairedChecksum) {
                value = previous
            } else {
                var checksums: [String] = []
                for index in 0..<(source.kind == .live ? 2 : 1) {
                    try Task.checkCancellation()
                    let file = staging.appendingPathComponent("original")
                    // This scope releases the first Live Photo resource before exporting its companion.
                    do {
                        defer { try? manager.removeItem(at: file) }
                        try await export(source, index, file)
                        try Task.checkCancellation()
                        let attributes = try manager.attributesOfItem(atPath: file.path)
                        guard attributes[.type] as? FileAttributeType == .typeRegular,
                              try PFUploadFileIO.size(of: file) > 0 else { throw stale() }
                        checksums.append(try await TransferFileIO.checksum(file))
                    }
                }
                value = PFPhotoOriginalIdentity(photosID: source.photosID, kind: source.kind, checksum: checksums[0],
                                               pairedChecksum: source.kind == .live ? checksums[1] : nil, sourceStamp: source.sourceStamp)
            }
            try Task.checkCancellation()
            identities.append(value)
            let cachedValue = source.cacheable ? value : nil
            if cache.entries[source.photosID] != cachedValue {
                cache.entries[source.photosID] = cachedValue
                cacheChanged = true
            }
            progress(M("Conferindo álbum do Fotos: \(position + 1) de \(sources.count)…"), position + 1, sources.count)
        }
        try validate()
        try saveCache()
        return identities
    }

    private static func stamps(_ sources: [Source]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0.photosID, $0.sourceStamp) })
    }
    private static func readAlbum(_ id: String) throws -> [AlbumSource] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw BridgeError(message: M("O álbum do Fotos está indisponível para comparar os originais."))
        }
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var result: [AlbumSource] = []; var failure: Error?
        assets.enumerateObjects { asset, _, stop in
            do {
                result.append(try readAsset(asset))
            } catch { failure = error; stop.pointee = true }
        }
        if let failure { throw failure }
        return result
    }
    /// Validate one previously matched member without re-reading every album original.
    static func validateCandidate(albumID: String, identity: PFPhotoOriginalIdentity) throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identity.photosID], options: nil).firstObject else { throw stale() }
        var member = false
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).enumerateObjects { album, _, stop in
            if album.localIdentifier == albumID { member = true; stop.pointee = true }
        }
        guard member else { throw stale() }
        let current = try readAsset(asset).source
        guard current.photosID == identity.photosID, current.kind == identity.kind,
              current.sourceStamp == identity.sourceStamp else { throw stale() }
    }
    private static func readAsset(_ asset: PHAsset) throws -> AlbumSource {
        let originals = PHAssetResource.assetResources(for: asset).filter { [.photo, .video, .pairedVideo, .alternatePhoto].contains($0.type) }
        let live = asset.mediaSubtypes.contains(.photoLive)
        let resources: [PHAssetResource]
        let kind: PFPhotoOriginalIdentity.Kind
        if asset.mediaType == .image && live,
           originals.count == 2, let still = originals.first(where: { $0.type == .photo }),
           let motion = originals.first(where: { $0.type == .pairedVideo }) {
            resources = [still, motion]; kind = .live
        } else if asset.mediaType == .image && !live && originals.count == 1 && originals[0].type == .photo {
            resources = originals; kind = .image
        } else if asset.mediaType == .video && originals.count == 1 && originals[0].type == .video {
            resources = originals; kind = .video
        } else {
            throw BridgeError(message: M("O álbum contém originais ambíguos ou incompletos. A comparação por hash não foi concluída."))
        }
        let fields = [asset.localIdentifier, String(asset.mediaType.rawValue), String(asset.mediaSubtypes.rawValue),
                      String(asset.pixelWidth), String(asset.pixelHeight), asset.creationDate.map { String($0.timeIntervalSince1970) } ?? "",
                      asset.modificationDate.map { String($0.timeIntervalSince1970) } ?? ""] +
            resources.map { "\($0.type.rawValue):\($0.originalFilename):\($0.uniformTypeIdentifier)" }
        let stamp = SHA256.hash(data: Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
        return AlbumSource(source: Source(photosID: asset.localIdentifier, kind: kind, sourceStamp: stamp,
                                               cacheable: asset.modificationDate != nil), resources: resources)
    }
    private static func stale() -> BridgeError {
        BridgeError(message: M("O álbum ou os originais do Fotos mudaram durante a comparação. Consulte novamente."))
    }
}
