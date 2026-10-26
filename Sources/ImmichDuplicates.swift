import Foundation

struct IMDuplicateGroup: Codable, Identifiable {
    var id: String
    var keepID: String
    var assets: [IMAsset]
    var unavailableOwnerIDs: [String] = []
}

/// Metadata candidates are deliberately separate from exact groups and are never accepted by the trash plan.
struct IMDuplicateSuggestion: Codable, Identifiable {
    var id: String
    var keepID: String
    var assets: [IMAsset]
    var evidence: [String]
}

struct IMDuplicateAnalysis: Codable, Identifiable {
    var id: String
    var profileID: String
    var albums: [IMAlbum]
    var createdAt: Date
    var groups: [IMDuplicateGroup]
    var total: Int
    var skipped: Int
    var suggestions: [IMDuplicateSuggestion]? = nil
}

@MainActor enum IMDuplicates {
    struct Pair { var keep: IMAsset; var drop: IMAsset }
    struct Addition { var keep: IMAsset; var album: IMAlbum; var writer: IMClient }

    static func groups(_ assets: [IMAsset], availableOwners: Set<String>) -> [IMDuplicateGroup] {
        Dictionary(grouping: assets.filter { $0.eligible(allowLive: true) }, by: \.checksum)
            .values.filter { $0.count > 1 }.map { values in
                let sorted = values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
                return IMDuplicateGroup(id: UUID().uuidString, keepID: (sorted.first(where: \.isLive) ?? sorted[0]).id,
                    assets: sorted, unavailableOwnerIDs: Set(sorted.map(\.ownerId)).subtracting(availableOwners).sorted())
            }.sorted { ($0.assets[0].createdAt, $0.assets[0].id) < ($1.assets[0].createdAt, $1.assets[0].id) }
    }

    /// A bounded, conservative complement to the byte-identical checksum scan.
    /// Pair suggestions avoid joining a burst transitively; at most ten nearby records per item are compared.
    static func suggestions(_ assets: [IMAsset]) -> [IMDuplicateSuggestion] {
        struct Candidate { let asset: IMAsset; let date: Date }
        struct Key: Hashable { let name: String; let width: Int; let height: Int }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        func date(_ text: String?) -> Date? {
            guard let text else { return nil }
            return fractional.date(from: text) ?? whole.date(from: text)
        }
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
        }
        func compatible(_ first: String?, _ second: String?) -> Bool {
            guard let first, let second, !normalized(first).isEmpty, !normalized(second).isEmpty else { return true }
            return normalized(first) == normalized(second)
        }
        var buckets: [Key: [Candidate]] = [:]
        var seen = Set<String>()
        for asset in assets.sorted(by: { $0.id < $1.id }) {
            guard seen.insert(asset.id).inserted, asset.type == "IMAGE", asset.eligible(allowLive: true),
                  let width = asset.width, let height = asset.height, width > 0, height > 0,
                  let captured = date(asset.captureDateTime) ?? date(asset.fileCreatedAt) else { continue }
            let name = normalized(asset.originalFileName)
            guard !name.isEmpty else { continue }
            buckets[Key(name: name, width: width, height: height), default: []].append(Candidate(asset: asset, date: captured))
        }
        let keys = buckets.keys.sorted { ($0.name, $0.width, $0.height) < ($1.name, $1.width, $1.height) }
        var result: [IMDuplicateSuggestion] = []
        for key in keys {
            let values = buckets[key]!.sorted { ($0.date, $0.asset.id) < ($1.date, $1.asset.id) }
            for index in values.indices {
                let first = values[index]
                for next in (index + 1)..<min(values.count, index + 11) {
                    let second = values[next]
                    guard second.date.timeIntervalSince(first.date) <= 1 else { break }
                    guard first.asset.checksum != second.asset.checksum,
                          compatible(first.asset.cameraMake, second.asset.cameraMake),
                          compatible(first.asset.cameraModel, second.asset.cameraModel) else { continue }
                    let pair = [first.asset, second.asset]
                    let ids = pair.map(\.id).sorted()
                    result.append(IMDuplicateSuggestion(id: "metadata:" + ids.joined(separator: ":"),
                        keepID: (pair.first(where: \.isLive) ?? pair[0]).id, assets: pair,
                        evidence: ["Mesmo nome de arquivo e dimensões", "Capturas com diferença de até 1 segundo", "Arquivos com hashes diferentes"]))
                    if result.count == 500 { return result }
                }
            }
        }
        return result
    }

    static func validateAnalysis(_ analysis: IMDuplicateAnalysis, profileID: String, now: Date = Date()) throws {
        let age = now.timeIntervalSince(analysis.createdAt)
        guard analysis.profileID == profileID, age >= 0, age <= 24 * 60 * 60 else {
            throw BridgeError(message: M("Esta análise expirou ou pertence a outra conexão. Consulte novamente."))
        }
    }

    static func pairs(analysis: IMDuplicateAnalysis, selections: [String:String]) throws -> [Pair] {
        guard !selections.isEmpty, selections.keys.allSatisfy({ id in analysis.groups.contains { $0.id == id } }) else {
            throw BridgeError(message: M("Selecione pelo menos um grupo válido."))
        }
        var result: [Pair] = [], used = Set<String>()
        for group in analysis.groups where selections[group.id] != nil {
            guard group.unavailableOwnerIDs.isEmpty,
                  let keep = group.assets.first(where: { $0.id == selections[group.id] }), group.assets.count > 1 else {
                throw BridgeError(message: M("Conecte as contas proprietárias e escolha a cópia para manter. Consulte novamente."))
            }
            for asset in group.assets {
                guard used.insert(asset.id).inserted, asset.eligible(allowLive: true), asset.checksum == keep.checksum,
                      asset.type == keep.type else { throw BridgeError(message: M("Grupo de duplicatas inválido. Consulte novamente.")) }
                if asset.id != keep.id {
                    guard !asset.isLive, asset.livePhotoVideoId == nil else {
                        throw BridgeError(message: M("A Live Photo está protegida para preservar o movimento. Mantenha a Live Photo ou desmarque o grupo."))
                    }
                    result.append(Pair(keep: keep, drop: asset))
                }
            }
        }
        return result
    }

    static func unchanged(_ old: IMAsset, _ fresh: IMAsset) throws {
        guard fresh.id == old.id, fresh.ownerId == old.ownerId, fresh.checksum == old.checksum,
              fresh.type == old.type, fresh.livePhotoVideoId == old.livePhotoVideoId, fresh.eligible(allowLive: true) else {
            throw BridgeError(message: M("Uma cópia mudou desde a análise. Consulte novamente."))
        }
    }

    static func require(_ required: Set<String>, client: IMClient, permissions: [String:Set<String>]) throws {
        let allowed = permissions[client.credential.account.id] ?? []
        guard allowed.contains("all") || required.isSubset(of: allowed) else {
            throw BridgeError(message: M("A chave de \(client.credential.account.name) precisa de: \(required.sorted().joined(separator: ", "))."))
        }
    }

    static func scan(session: IMSession, albums: [IMAlbum], progress: @escaping IMProgress) async throws -> IMDuplicateAnalysis {
        guard !albums.isEmpty, albums.count <= 100, Set(albums.map(\.id)).count == albums.count else { throw BridgeError(message: M("Selecione álbuns válidos.")) }
        var permissions: [String:Set<String>] = [:]
        for client in session.clients {
            permissions[client.credential.account.id] = try await client.permissions()
            try require(["asset.read", "album.read"], client: client, permissions: permissions)
        }
        // Refresh album access instead of trusting a persisted catalog.
        let catalog = try await session.albums()
        var readers: [String:IMClient] = [:], origins: [String:[IMAlbum]] = [:]
        for (index, selection) in albums.enumerated() {
            try Task.checkCancellation()
            guard let album = catalog.first(where: { $0.id == selection.id }) else { throw BridgeError(message: M("Um álbum não está mais disponível.")) }
            let reader = try session.reader(album)
            for id in try await reader.albumIDs(album.id) {
                readers[id] = readers[id] ?? reader
                origins[id, default: []].append(album)
            }
            guard readers.count <= 30_000 else { throw BridgeError(message: M("Limite de 30 mil itens por análise. Selecione menos álbuns.")) }
            progress(M("Listando itens dos álbuns"), index + 1, albums.count)
        }
        var assets: [IMAsset] = [], skipped = 0
        for (index, id) in readers.keys.sorted().enumerated() {
            try Task.checkCancellation()
            var asset = try await readers[id]!.asset(id)
            if asset.eligible(allowLive: true) { asset.albums = origins[id] ?? []; assets.append(asset) }
            else { skipped += 1 }
            progress(M("Comparando arquivos idênticos"), index + 1, readers.count)
        }
        var found = groups(assets, availableOwners: Set(session.clients.map { $0.credential.account.id }))
        for groupIndex in found.indices {
            for assetIndex in found[groupIndex].assets.indices {
                try Task.checkCancellation()
                let old = found[groupIndex].assets[assetIndex]
                // Shared album readers can reveal missing-owner copies, but may not see their private albums.
                if let owner = try? session.owner(old.ownerId) {
                    var fresh = try await owner.asset(old.id)
                    try unchanged(old, fresh)
                    fresh.albums = try await session.memberships(old.id)
                    guard Set(old.albums.map(\.id)).isSubset(of: Set(fresh.albums.map(\.id))) else {
                        throw BridgeError(message: M("Uma cópia saiu do álbum durante a análise. Consulte novamente."))
                    }
                    found[groupIndex].assets[assetIndex] = fresh
                }
            }
            progress(M("Conferindo álbuns das cópias"), groupIndex + 1, found.count)
        }
        return IMDuplicateAnalysis(id: UUID().uuidString, profileID: session.profileID, albums: albums,
            createdAt: Date(), groups: found, total: readers.count, skipped: skipped, suggestions: suggestions(assets))
    }

    static func fresh(_ old: IMAsset, session: IMSession) async throws -> IMAsset {
        var asset = try await session.owner(old.ownerId).asset(old.id)
        try unchanged(old, asset)
        asset.albums = try await session.memberships(old.id)
        // Every observed album, including private albums outside the scan, must still exist.
        guard Set(old.albums.map(\.id)).isSubset(of: Set(asset.albums.map(\.id))) else {
            throw BridgeError(message: M("Uma cópia saiu de um álbum. Consulte novamente."))
        }
        for album in asset.albums {
            let ids = try await session.reader(album).albumIDs(album.id)
            guard ids.contains(asset.id) else { throw BridgeError(message: M("O vínculo de uma cópia não foi confirmado. Consulte novamente.")) }
        }
        return asset
    }

    static func coverage(_ pair: Pair, session: IMSession) async throws {
        let keep = try await fresh(pair.keep, session: session)
        let drop = try await fresh(pair.drop, session: session)
        guard Set(drop.albums.map(\.id)).isSubset(of: Set(keep.albums.map(\.id))) else {
            throw BridgeError(message: M("Há um álbum sem a cópia mantida. A exclusão foi bloqueada; consulte novamente."))
        }
    }

    static func trash(session: IMSession, analysis: IMDuplicateAnalysis, selections: [String:String], progress: @escaping IMProgress, report: @escaping IMReport) async throws {
        try validateAnalysis(analysis, profileID: session.profileID)
        let plan = try pairs(analysis: analysis, selections: selections)
        var permissions: [String:Set<String>] = [:]
        for client in session.clients {
            permissions[client.credential.account.id] = try await client.permissions()
            try require(["asset.read", "album.read"], client: client, permissions: permissions)
        }
        // Resolve every owner and all write scopes before the first mutation.
        for pair in plan {
            _ = try session.owner(pair.keep.ownerId)
            try require(["asset.delete"], client: session.owner(pair.drop.ownerId), permissions: permissions)
        }
        let catalog = try await session.albums()
        var additions: [Addition] = [], additionIDs = Set<String>()
        var validated: [Pair] = []
        for (index, pair) in plan.enumerated() {
            try Task.checkCancellation()
            let current = Pair(keep: try await fresh(pair.keep, session: session), drop: try await fresh(pair.drop, session: session))
            validated.append(current)
            let keepAlbums = Set(current.keep.albums.map(\.id))
            for album in current.drop.albums where !keepAlbums.contains(album.id) {
                guard let target = catalog.first(where: { $0.id == album.id }) else { throw BridgeError(message: M("Um álbum de destino não está disponível.")) }
                let candidates = session.clients.filter {
                    $0.credential.account.id == target.ownerID || target.writerIDs.contains($0.credential.account.id)
                }.sorted { ($0.credential.account.id == target.ownerID ? 0 : 1) < ($1.credential.account.id == target.ownerID ? 0 : 1) }
                var selectedWriter: IMClient?
                for candidate in candidates {
                    do {
                        try Task.checkCancellation()
                        try require(["asset.read", "album.read", "albumAsset.create"], client: candidate, permissions: permissions)
                        try unchanged(current.keep, await candidate.asset(current.keep.id))
                        selectedWriter = candidate
                        break
                    } catch is CancellationError { throw CancellationError() }
                    catch { continue } // Read-only probes: an editor may have visibility the owner lacks.
                }
                guard let writer = selectedWriter else {
                    throw BridgeError(message: M("Nenhuma conta editora pode ler a cópia mantida e adicionar ao álbum \(target.name). Confira albumAsset.create e os acessos."))
                }
                if additionIDs.insert(target.id + ":" + current.keep.id).inserted {
                    additions.append(Addition(keep: current.keep, album: target, writer: writer))
                }
            }
            progress(M("Conferindo cópias e permissões"), index + 1, plan.count)
        }
        for (index, addition) in additions.enumerated() {
            try Task.checkCancellation()
            try unchanged(addition.keep, await addition.writer.asset(addition.keep.id))
            var record = IMActionRecord(action: "add", asset: addition.keep, album: addition.album, status: "preparing")
            try report(record)
            do {
                try await addition.writer.add([addition.keep.id], to: addition.album.id)
                guard try await addition.writer.albumIDs(addition.album.id).contains(addition.keep.id) else {
                    throw BridgeError(message: M("O Immich não confirmou a cópia mantida no álbum. Exclusões bloqueadas."))
                }
            } catch { record.status = "uncertain"; record.setMessage(M("Adição sem confirmação; confira o Immich antes de repetir.")); try report(record); throw error }
            record.status = "confirmed"; try report(record)
            progress(M("Preservando álbuns das cópias"), index + 1, additions.count)
        }
        // All additions, including their read-back, finish before the first trash request.
        for pair in validated { try Task.checkCancellation(); try await coverage(pair, session: session) }
        for (index, pair) in validated.enumerated() {
            try Task.checkCancellation()
            try await coverage(pair, session: session)
            let owner = try session.owner(pair.drop.ownerId)
            var record = IMActionRecord(action: "trash", asset: pair.drop, keepID: pair.keep.id, status: "preparing")
            try report(record)
            do {
                try await owner.trash([pair.drop.id])
                let result = try await owner.asset(pair.drop.id)
                guard result.id == pair.drop.id, result.ownerId == pair.drop.ownerId, result.checksum == pair.drop.checksum, result.isTrashed else { throw BridgeError(message: M("A lixeira não foi confirmada. Confira o Immich antes de repetir.")) }
            } catch { record.status = "uncertain"; record.setMessage(M("Lixeira sem confirmação; confira o Immich antes de repetir.")); try report(record); throw error }
            record.status = "confirmed"; try report(record)
            progress(M("Enviando cópias estáticas à lixeira"), index + 1, validated.count)
        }
    }
}
