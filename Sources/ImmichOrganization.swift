import Foundation

struct IMComparisonGroup: Codable, Identifiable {
    var id: String
    var assets: [IMAsset]
    var common: Bool
}
struct IMComparisonAnalysis: Codable, Identifiable {
    var id: String
    var profileID: String
    var albums: [IMAlbum]
    var createdAt: Date
    var groups: [IMComparisonGroup]
    var total: Int
    var skipped: Int
}
// This is a query grouping only; remote people and face records are never merged.
struct IMPersonGroup: Identifiable {
    let id: String
    let name: String
    let birthDate: String?
    let people: [IMPerson]
    static func normalizedName(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    @MainActor static func options(_ people: [IMPerson], accountID: String = "") -> [IMPersonGroup] {
        let named = people.filter { (accountID.isEmpty || $0.accountID == accountID) && !normalizedName($0.name).isEmpty }
        let buckets = Dictionary(grouping: named) { person in
            if let birth = person.birthDate, birth.count == 10, IMOrganization.day(birth) != nil {
                return "group:" + Data((normalizedName(person.name) + "\n" + birth).utf8).base64EncodedString()
            }
            return "person:" + person.key
        }
        return buckets.map { key, members in
            let sorted = members.sorted { $0.key < $1.key }
            return IMPersonGroup(id: key, name: sorted[0].name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "),
                                 birthDate: sorted[0].birthDate, people: sorted)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.birthDate != $1.birthDate { return ($0.birthDate ?? "") < ($1.birthDate ?? "") }
            return $0.id < $1.id
        }
    }
}
struct IMAgePersonScope: Codable {
    var person: IMPerson
    var sourceAlbums: [IMAlbum]
    var assetIDs: Set<String>
}
struct IMAgeAnalysis: Codable, Identifiable {
    var id: String
    var profileID: String
    var accountID: String
    var person: IMPerson
    var source: IMAlbum?
    var destination: IMAlbum
    var minAge: Int
    var maxAge: Int
    var createdAt: Date
    var assets: [IMAsset]
    var skipped: Int
    // Sources visible to the person's account at analysis time. Other accounts'
    // private albums must never become implicit removal sources.
    var sourceAlbums: [IMAlbum] = []
    var peopleScopes: [IMAgePersonScope]? = nil
}

@MainActor enum IMOrganization {
    private struct LinkChange {
        var asset: IMAsset
        var album: IMAlbum
    }
    private struct Preservation {
        var asset: IMAsset
        var album: IMAlbum
    }

    static func compare(session: IMSession, albums: [IMAlbum], progress: @escaping IMProgress) async throws -> IMComparisonAnalysis {
        guard albums.count == 2, albums[0].id != albums[1].id else {
            throw failure(M("Selecione dois álbuns diferentes para comparar."))
        }
        var assets: [String: IMAsset] = [:]
        var albumSets: [String: Set<String>] = [:]
        for (index, album) in albums.enumerated() {
            progress(M("Lendo \(album.name)"), index, albums.count)
            let client = try session.reader(album)
            let ids = try await client.albumIDs(album.id)
            let union = Set(assets.keys).union(ids)
            guard union.count <= 30000 else { throw failure(M("Limite de 30 mil itens por comparação. Escolha álbuns menores.")) }
            albumSets[album.id] = ids
            for id in ids.sorted() where assets[id] == nil {
                var asset = try await client.asset(id)
                asset.albums = try await session.memberships(id)
                assets[id] = asset
            }
        }
        let eligible = assets.values.filter { $0.eligible(allowLive: false) }
        let groups = comparisonGroups(assets: Array(eligible), albums: albums, memberships: albumSets)
        progress(M("Comparação pronta"), assets.count, assets.count)
        return IMComparisonAnalysis(id: UUID().uuidString, profileID: session.profileID, albums: albums, createdAt: Date(), groups: groups, total: assets.count, skipped: assets.count - eligible.count)
    }

    // Separate pure grouping/calendar functions also make the safety policy testable
    // without a connection to a real Immich server.
    static func comparisonGroups(assets: [IMAsset], albums: [IMAlbum], memberships: [String: Set<String>]) -> [IMComparisonGroup] {
        let eligible = assets.filter { $0.eligible(allowLive: false) }
        let buckets = Dictionary(grouping: eligible, by: { $0.type + ":" + $0.checksum })
        return buckets.keys.sorted().map { key in
            let copies = buckets[key]!.sorted(by: order)
            let common = albums.allSatisfy { album in
                copies.contains { memberships[album.id, default: []].contains($0.id) }
            }
            return IMComparisonGroup(id: key, assets: copies, common: common)
        }
    }

    static func organize(session: IMSession, analysis: IMComparisonAnalysis, selections: [String: String], progress: @escaping IMProgress, report: @escaping IMReport) async throws {
        try validate(profileID: analysis.profileID, createdAt: analysis.createdAt, session: session)
        guard analysis.albums.count == 2, Set(analysis.albums.map(\.id)).count == 2 else { throw failure(M("Comparação inválida; consulte novamente.")) }
        let groupMap = Dictionary(uniqueKeysWithValues: analysis.groups.map { ($0.id, $0) })
        let albumIDs = Set(analysis.albums.map(\.id))
        guard selections.allSatisfy({ groupMap[$0.key] != nil && ($0.value == "both" || albumIDs.contains($0.value)) }) else { throw failure(M("A seleção não pertence a esta comparação.")) }
        var additions: [LinkChange] = [], removals: [LinkChange] = [], keep: [Preservation] = []
        var snapshots: [IMAsset] = []
        for key in selections.keys.sorted() {
            let group = groupMap[key]!
            guard !group.assets.isEmpty else { throw failure(M("Grupo vazio; consulte novamente.")) }
            let destinationIDs: Set<String> = selections[key] == "both" ? albumIDs : [selections[key]!]
            let copies = group.assets.sorted(by: order)
            for asset in copies {
                guard asset.eligible(allowLive: false), asset.checksum == copies[0].checksum, asset.type == copies[0].type else { throw failure(M("O grupo contém itens incompatíveis; consulte novamente.")) }
            }
            snapshots.append(contentsOf: copies)
            for album in analysis.albums {
                let present = copies.filter { asset in asset.albums.contains { $0.id == album.id } }
                if destinationIDs.contains(album.id) {
                    let retained = present.first ?? copies[0]
                    keep.append(Preservation(asset: retained, album: album))
                    if present.isEmpty { additions.append(LinkChange(asset: retained, album: album)) }
                } else {
                    removals.append(contentsOf: present.map { LinkChange(asset: $0, album: album) })
                }
            }
        }
        let uniqueSnapshots = try distinct(snapshots)
        try await validateSnapshots(session: session, assets: uniqueSnapshots, relevantAlbums: albumIDs)
        try await apply(session: session, additions: additions, removals: removals, preserved: keep, progress: progress, report: report) {
            try await validateSnapshots(session: session, assets: uniqueSnapshots, relevantAlbums: [])
        }
    }

    static func ageSearch(session: IMSession, person: IMPerson, source: IMAlbum?, destination: IMAlbum, minAge: Int, maxAge: Int, progress: @escaping IMProgress) async throws -> IMAgeAnalysis {
        try await ageSearch(session: session, people: [person], source: source, destination: destination,
                            minAge: minAge, maxAge: maxAge, progress: progress, restrictDestinationAccess: true)
    }
    static func ageSearch(session: IMSession, people: [IMPerson], source: IMAlbum?, destination: IMAlbum, minAge: Int, maxAge: Int, progress: @escaping IMProgress, restrictDestinationAccess: Bool = false) async throws -> IMAgeAnalysis {
        try validateRange(minAge, maxAge)
        guard source?.id != destination.id else { throw failure(M("Origem e destino precisam ser diferentes.")) }
        guard let first = people.first, let birthday = first.birthDate, birthday.count == 10, day(birthday) != nil,
              !IMPersonGroup.normalizedName(first.name).isEmpty,
              Set(people.map(\.key)).count == people.count,
              people.allSatisfy({ IMPersonGroup.normalizedName($0.name) == IMPersonGroup.normalizedName(first.name) && $0.birthDate == birthday }) else {
            throw failure(M("Confira o nome e a data de nascimento da pessoa no Immich e consulte novamente."))
        }
        _ = try session.reader(destination)
        var matches: [String: IMAsset] = [:], scopes: [IMAgePersonScope] = []
        var sourcesByID: [String: IMAlbum] = [:], skippedIDs = Set<String>(), queriedIDs = Set<String>()
        for person in people.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let client = try session.owner(person.accountID)
            let current = try await client.person(person.id)
            guard current.birthDate == person.birthDate, IMPersonGroup.normalizedName(current.name) == IMPersonGroup.normalizedName(person.name) else {
                throw failure(M("O nome ou nascimento da pessoa mudou; consulte novamente."))
            }
            let accessible = try await client.albums()
            if restrictDestinationAccess {
                guard accessible.contains(where: { $0.id == destination.id }), source == nil || accessible.contains(where: { $0.id == source!.id }) else {
                    throw failure(M("A conta da pessoa precisa ter acesso aos álbuns escolhidos."))
                }
            }
            let sources = source.map { selected in accessible.filter { $0.id == selected.id } } ?? accessible.filter { $0.id != destination.id }
            for album in sources { sourcesByID[album.id] = album }
            guard sourcesByID.count <= 100, (!restrictDestinationAccess || !sources.isEmpty) else {
                throw failure(M("Selecione uma origem; a busca permite de 1 a 100 álbuns de origem."))
            }
            let sourceIDs = Set(sources.map(\.id))
            var scope = IMAgePersonScope(person: person, sourceAlbums: sources, assetIDs: [])
            if !sources.isEmpty {
                progress(M("Buscando fotos da pessoa"), scopes.count, people.count)
                let results = try await client.search(personID: person.id, albumIDs: sourceIDs.sorted())
                queriedIDs.formUnion(results.map(\.id))
                guard queriedIDs.count <= 30000 else { throw failure(M("Limite de 30 mil arquivos por busca.")) }
                for var asset in results {
                    guard asset.eligible(allowLive: false), let age = capturedAge(asset, birthday: birthday), (minAge...maxAge).contains(age) else { skippedIDs.insert(asset.id); continue }
                    if let previous = matches[asset.id] {
                        try validateContent(previous, asset)
                        guard previous.fileCreatedAt == asset.fileCreatedAt, previous.localDateTime == asset.localDateTime else { throw failure(M("Há itens inconsistentes na seleção; consulte novamente.")) }
                        asset.albums = previous.albums
                    } else { asset.albums = try await session.memberships(asset.id) }
                    guard asset.albums.contains(where: { sourceIDs.contains($0.id) }) else { skippedIDs.insert(asset.id); continue }
                    scope.assetIDs.insert(asset.id); matches[asset.id] = asset
                    guard matches.count <= 30000 else { throw failure(M("Limite de 30 mil arquivos por busca.")) }
                }
            }
            scopes.append(scope)
        }
        guard !sourcesByID.isEmpty else { throw failure(M("Selecione uma origem; a busca permite de 1 a 100 álbuns de origem.")) }
        return IMAgeAnalysis(id: UUID().uuidString, profileID: session.profileID, accountID: first.accountID, person: first,
            source: source, destination: destination, minAge: minAge, maxAge: maxAge, createdAt: Date(),
            assets: matches.values.sorted(by: order), skipped: skippedIDs.subtracting(matches.keys).count,
            sourceAlbums: sourcesByID.values.sorted { $0.id < $1.id }, peopleScopes: scopes)
    }

    static func ageMove(session: IMSession, analysis: IMAgeAnalysis, selectedIDs: Set<String>, progress: @escaping IMProgress, report: @escaping IMReport) async throws {
        try validate(profileID: analysis.profileID, createdAt: analysis.createdAt, session: session)
        try validateRange(analysis.minAge, analysis.maxAge)
        guard analysis.accountID == analysis.person.accountID, analysis.source?.id != analysis.destination.id else { throw failure(M("Análise de idade inválida; consulte novamente.")) }
        let byID = Dictionary(uniqueKeysWithValues: analysis.assets.map { ($0.id, $0) })
        guard selectedIDs.isSubset(of: Set(byID.keys)) else { throw failure(M("A seleção não pertence a esta busca.")) }
        let scopes = analysis.peopleScopes ?? [IMAgePersonScope(person: analysis.person, sourceAlbums: analysis.source.map { [$0] } ?? analysis.sourceAlbums, assetIDs: Set(byID.keys))]
        guard !scopes.isEmpty, Set(scopes.map { $0.person.key }).count == scopes.count,
              scopes.allSatisfy({ $0.person.birthDate == analysis.person.birthDate && IMPersonGroup.normalizedName($0.person.name) == IMPersonGroup.normalizedName(analysis.person.name) }),
              selectedIDs.isSubset(of: scopes.reduce(into: Set<String>()) { $0.formUnion($1.assetIDs) }) else { throw failure(M("Análise de idade inválida; consulte novamente.")) }
        var sourcesByAsset: [String: Set<String>] = [:], relevant = Set<String>()
        for scope in scopes {
            let client = try session.owner(scope.person.accountID)
            let accessible = Set(try await client.albums().map(\.id))
            let sourceIDs = Set(scope.sourceAlbums.map(\.id))
            guard !sourceIDs.contains(analysis.destination.id), sourceIDs.isSubset(of: accessible),
                  analysis.source == nil || sourceIDs.isSubset(of: [analysis.source!.id]) else { throw failure(M("O acesso aos álbuns mudou; consulte novamente.")) }
            relevant.formUnion(sourceIDs)
            for id in scope.assetIDs.intersection(selectedIDs) { sourcesByAsset[id, default: []].formUnion(sourceIDs) }
        }
        _ = try session.reader(analysis.destination)
        let snapshots = selectedIDs.sorted().map { byID[$0]! }
        let revalidate = {
            // Every original person/account remains part of this reviewed identity.
            for scope in scopes {
                let client = try session.owner(scope.person.accountID)
                let person = try await client.person(scope.person.id)
                guard person.birthDate == scope.person.birthDate, IMPersonGroup.normalizedName(person.name) == IMPersonGroup.normalizedName(scope.person.name),
                      let birthday = person.birthDate, day(birthday) != nil else { throw failure(M("O nome ou nascimento da pessoa mudou; consulte novamente.")) }
                for id in scope.assetIDs.intersection(selectedIDs).sorted() {
                    let snapshot = byID[id]!
                    let current = try await session.asset(snapshot)
                    let associated = try await client.matchesPerson(personID: scope.person.id, assetID: snapshot.id, albumIDs: [])
                    try validateContent(snapshot, current)
                    guard associated, captureDay(current) == captureDay(snapshot), current.localDateTime == snapshot.localDateTime,
                          current.fileCreatedAt == snapshot.fileCreatedAt, let age = capturedAge(current, birthday: birthday),
                          (analysis.minAge...analysis.maxAge).contains(age) else { throw failure(M("Pessoa ou data da foto mudou; consulte novamente.")) }
                }
            }
        }
        try await revalidate()
        try await validateSnapshots(session: session, assets: snapshots, relevantAlbums: relevant.union([analysis.destination.id]))
        var additions: [LinkChange] = [], removals: [LinkChange] = [], keep: [Preservation] = []
        for asset in snapshots {
            let linkedSources = asset.albums.filter { sourcesByAsset[asset.id, default: []].contains($0.id) }
            guard !linkedSources.isEmpty else { throw failure(M("A foto não está na origem; consulte novamente.")) }
            keep.append(Preservation(asset: asset, album: analysis.destination))
            if !asset.albums.contains(where: { $0.id == analysis.destination.id }) { additions.append(LinkChange(asset: asset, album: analysis.destination)) }
            removals.append(contentsOf: linkedSources.map { LinkChange(asset: asset, album: $0) })
        }
        try await apply(session: session, additions: additions, removals: removals, preserved: keep, progress: progress, report: report, revalidate: revalidate)
    }

    static func validate(profileID: String, createdAt: Date, session: IMSession, now: Date = Date()) throws {
        guard profileID == session.profileID, createdAt <= now.addingTimeInterval(60), now.timeIntervalSince(createdAt) <= 24 * 60 * 60 else { throw failure(M("A análise expirou ou pertence a outra conexão. Consulte novamente.")) }
    }

    static func validateRange(_ minimum: Int, _ maximum: Int) throws {
        guard minimum >= 0, maximum >= minimum, maximum <= 150 else { throw failure(M("Informe idades inteiras entre 0 e 150, com mínimo menor ou igual ao máximo.")) }
    }

    private static func distinct(_ assets: [IMAsset]) throws -> [IMAsset] {
        var byID: [String: IMAsset] = [:]
        for asset in assets {
            if let previous = byID[asset.id] {
                guard previous.checksum == asset.checksum, previous.ownerId == asset.ownerId, previous.type == asset.type else { throw failure(M("Há itens inconsistentes na seleção; consulte novamente.")) }
            }
            byID[asset.id] = asset
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private static func validateContent(_ old: IMAsset, _ current: IMAsset) throws {
        guard current.id == old.id, current.ownerId == old.ownerId, current.type == old.type, current.checksum == old.checksum, !old.checksum.isEmpty, old.eligible(allowLive: false), current.eligible(allowLive: false) else { throw failure(M("Conteúdo, proprietário ou estado da foto mudou; consulte novamente.")) }
    }

    private static func validateSnapshots(session: IMSession, assets: [IMAsset], relevantAlbums: Set<String>) async throws {
        for snapshot in assets {
            let current = try await session.asset(snapshot)
            try validateContent(snapshot, current)
            if !relevantAlbums.isEmpty {
                let memberships = try await session.memberships(snapshot.id)
                let old = Set(snapshot.albums.map(\.id)).intersection(relevantAlbums)
                let new = Set(memberships.map(\.id)).intersection(relevantAlbums)
                guard old == new else { throw failure(M("Os vínculos dos álbuns mudaram; consulte novamente.")) }
            }
        }
    }

    private static func apply(session: IMSession, additions: [LinkChange], removals: [LinkChange], preserved: [Preservation], progress: @escaping IMProgress, report: @escaping IMReport, revalidate: () async throws -> Void) async throws {
        guard !additions.isEmpty || !removals.isEmpty else { return }
        let currentAlbums = try await session.albums()
        let byID = Dictionary(uniqueKeysWithValues: currentAlbums.map { ($0.id, $0) })
        var writers: [String: IMClient] = [:]
        for change in additions + removals {
            guard let album = byID[change.album.id], album.ownerID == change.album.ownerID else { throw failure(M("O álbum ou seu proprietário mudou; consulte novamente.")) }
            if writers[album.id] != nil { continue }
            let toAdd = additions.filter { $0.album.id == album.id }
            var permissions = Set<String>()
            if !toAdd.isEmpty { permissions.insert("albumAsset.create") }
            if removals.contains(where: { $0.album.id == album.id }) { permissions.insert("albumAsset.delete") }
            let client = try await session.writer(album, requiring: permissions, adding: toAdd.map(\.asset))
            writers[album.id] = client
        }
        // Confirm every destination before the first unlink, including unchanged
        // destination copies belonging to another owner.
        func checkPreserved() async throws {
            for keep in preserved {
                guard let album = byID[keep.album.id], album.ownerID == keep.album.ownerID else { throw failure(M("O álbum de destino mudou.")) }
                let current = try await session.asset(keep.asset)
                try validateContent(keep.asset, current)
                let ids = try await session.reader(album).albumIDs(album.id)
                guard ids.contains(keep.asset.id) else { throw failure(M("A presença da foto no destino não foi confirmada; nenhuma outra remoção será feita.")) }
            }
        }
        var completed = 0
        let total = additions.count + removals.count
        for change in additions {
            try await revalidate()
            guard let client = writers[change.album.id] else { throw failure(M("Conta de destino indisponível.")) }
            var record = IMActionRecord(action: "add", asset: change.asset, album: change.album, status: "preparing")
            try report(record)
            do {
                try await client.add([change.asset.id], to: change.album.id)
                let ids = try await client.albumIDs(change.album.id)
                guard ids.contains(change.asset.id) else { throw failure(M("Inclusão não confirmada no destino.")) }
                record.status = "confirmed"
                try report(record)
            } catch {
                record.status = "uncertain"
                record.setMessage(.error(error))
                try report(record)
                throw error
            }
            completed += 1
            progress(M("Incluindo no destino"), completed, total)
        }
        try await revalidate()
        try await checkPreserved()
        for change in removals {
            try await revalidate()
            try await checkPreserved()
            guard let client = writers[change.album.id] else { throw failure(M("Conta de origem indisponível.")) }
            let current = try await session.asset(change.asset)
            try validateContent(change.asset, current)
            let ids = try await client.albumIDs(change.album.id)
            guard ids.contains(change.asset.id) else { throw failure(M("O vínculo de origem mudou; consulte novamente.")) }
            var record = IMActionRecord(action: "unlink", asset: change.asset, album: change.album, status: "preparing")
            try report(record)
            do {
                try await client.unlink([change.asset.id], from: change.album.id)
                let remaining = try await client.albumIDs(change.album.id)
                guard !remaining.contains(change.asset.id) else { throw failure(M("A remoção do vínculo não foi confirmada.")) }
                try await checkPreserved()
                record.status = "confirmed"
                try report(record)
            } catch {
                record.status = "uncertain"
                record.setMessage(.error(error))
                try report(record)
                throw error
            }
            completed += 1
            progress(M("Removendo somente vínculos da origem"), completed, total)
        }
    }

    private static func order(_ left: IMAsset, _ right: IMAsset) -> Bool {
        left.createdAt == right.createdAt ? left.id < right.id : left.createdAt < right.createdAt
    }
    private static func failure(_ message: PFMessage) -> BridgeError { BridgeError(message: message) }

    // Calendar-only calculations deliberately avoid UTC conversions of the local
    // capture day, which would move photos near midnight into another age.
    static func captureDay(_ asset: IMAsset) -> DateComponents? {
        if let local = asset.localDateTime, let parsed = day(local) { return parsed }
        return day(asset.fileCreatedAt)
    }
    static func capturedAge(_ asset: IMAsset, birthday: String) -> Int? {
        guard let birth = day(birthday), let capture = captureDay(asset) else { return nil }
        return age(birthday: birth, on: capture)
    }
    static func day(_ text: String) -> DateComponents? {
        let prefix = String(text.prefix(10))
        guard prefix.count == 10 else { return nil }
        if text.count > 10 {
            let separator = text[text.index(text.startIndex, offsetBy: 10)]
            guard separator == "T" || separator == " " else { return nil }
        }
        let pieces = prefix.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2, let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]), year > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return components
    }
    static func age(birthday: DateComponents, on capture: DateComponents) -> Int? {
        guard let by = birthday.year, let bm = birthday.month, let bd = birthday.day, let cy = capture.year, let cm = capture.month, let cd = capture.day else { return nil }
        var month = bm, day = bd
        let leap = cy % 4 == 0 && (cy % 100 != 0 || cy % 400 == 0)
        if bm == 2 && bd == 29 && !leap { month = 3; day = 1 }
        let age = cy - by - ((cm < month || (cm == month && cd < day)) ? 1 : 0)
        return age >= 0 ? age : nil
    }
}
