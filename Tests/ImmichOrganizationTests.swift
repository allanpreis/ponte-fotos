import Foundation

// All mutations below are intercepted in memory. No real server is contacted.
final class OrganizationProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Any))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler(request)
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class OrganizationFixture {
    var assets: [String: IMAsset] = [:]
    var albums: [IMAlbum] = []
    var links: [String: Set<String>] = [:]
    var events: [String] = []
    var permissions = ["all"]
    var accountPermissions: [String: [String]] = [:]
    var hiddenAssets: [String: Set<String>] = [:]
    var mutationAccounts: [String] = []
    var birthday = "2000-02-29"
    var associated = true
    var failAdd = 0
    var failedVerification = false
    var failUnlinkVerification = false
    var changeBirthdayAfterAdd = false
    var addCalls = 0
    var personRequests = 0
    var searchBodies: [[String: Any]] = []
    let person = IMPerson(id: "person", name: "Pessoa", birthDate: "2000-02-29", accountID: "p")

    init() {
        albums = [IMAlbum(id: "A", name: "Origem", ownerID: "p", readerIDs: ["p"], writerIDs: ["p"]),
                  IMAlbum(id: "B", name: "Destino", ownerID: "q", shared: true, readerIDs: ["p", "q"], writerIDs: ["p", "q"]),
                  IMAlbum(id: "E", name: "Privado de outra conta", ownerID: "q", readerIDs: ["q"], writerIDs: ["q"])]
        for (id, owner, checksum) in [("a", "p", "common"), ("b", "q", "common"), ("c", "p", "unique-c"), ("d", "q", "unique-d"), ("live", "p", "live")] {
            var asset = IMAsset(id: id, ownerId: owner, originalFileName: id + ".heic", checksum: checksum)
            asset.createdAt = "2020-01-01T00:00:00Z"; asset.fileCreatedAt = "2020-02-29T01:00:00Z"
            asset.localDateTime = "2020-02-29T23:59:00-03:00"; asset.people = ["person"]
            if id == "live" { asset.livePhotoVideoId = "video" }
            assets[id] = asset
        }
        links = ["A": ["a", "c", "live"], "B": ["b", "d"], "E": ["a", "c"]]
    }

    func raw(_ asset: IMAsset) -> [String: Any] {
        var object: [String: Any] = ["id": asset.id, "ownerId": asset.ownerId, "originalFileName": asset.originalFileName, "checksum": asset.checksum, "type": asset.type, "createdAt": asset.createdAt, "fileCreatedAt": asset.fileCreatedAt, "isEdited": asset.isEdited, "isOffline": asset.isOffline, "isTrashed": asset.isTrashed, "people": asset.people.map { ["id": $0] }]
        if let local = asset.localDateTime { object["localDateTime"] = local }
        if let live = asset.livePhotoVideoId { object["livePhotoVideoId"] = live }
        if asset.stacked { object["stack"] = ["id": "stack"] }
        return object
    }
    func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
    func response(_ request: URLRequest) throws -> (Int, Any) {
        let path = request.url!.path.replacingOccurrences(of: "/api/", with: "")
        let method = request.httpMethod ?? "GET"
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let account = request.value(forHTTPHeaderField: "x-api-key") ?? ""
        let visible = albums.filter { $0.readerIDs.contains(account) || $0.ownerID == account }
        func albumJSON(_ album: IMAlbum) -> [String: Any] {
            ["id": album.id, "albumName": album.name, "ownerId": album.ownerID, "shared": album.shared, "assetCount": links[album.id, default: []].count, "albumUsers": album.writerIDs.map { ["user": ["id": $0], "role": "editor"] }]
        }
        if path == "albums", method == "GET" {
            return (200, visible.filter { query["assetId"] == nil || links[$0.id, default: []].contains(query["assetId"]!) }.map(albumJSON))
        }
        if path == "api-keys/me" { return (200, ["permissions": accountPermissions[account] ?? permissions]) }
        if path == "people/person" { personRequests += 1; return (200, ["id": "person", "name": "Pessoa", "birthDate": birthday]) }
        if path.hasPrefix("assets/"), hiddenAssets[account, default: []].contains(String(path.dropFirst(7))) { return (403, ["error": "forbidden"]) }
        if path.hasPrefix("assets/"), method == "GET", let asset = assets[String(path.dropFirst(7))] { return (200, raw(asset)) }
        if path == "timeline/buckets" { return (200, [["timeBucket": "2020-01-01"]]) }
        if path == "timeline/bucket" { return (200, ["id": Array(links[query["albumId"] ?? "", default: []]).sorted()]) }
        if path == "search/metadata" {
            let body = try JSONSerialization.jsonObject(with: bodyData(request)) as! [String: Any]
            searchBodies.append(body)
            let filter = body["filter"] as! [String: Any]
            let target = (filter["id"] as? [String: String])?["eq"]
            let albumIDs = (filter["albumIds"] as? [String: [String]])?["any"] ?? []
            let matches = assets.values.filter { asset in
                associated && asset.people.contains("person") && (target == nil || target == asset.id) && (albumIDs.isEmpty || albumIDs.contains { links[$0, default: []].contains(asset.id) })
            }.sorted { $0.id < $1.id }
            return (200, ["assets": ["items": matches.map(raw), "nextCursor": NSNull()]])
        }
        if path.hasPrefix("albums/"), path.hasSuffix("/assets"), method == "PUT" || method == "DELETE" {
            let body = try JSONSerialization.jsonObject(with: bodyData(request)) as! [String: [String]]
            let ids = body["ids"]!
            let albumID = String(path.split(separator: "/")[1])
            mutationAccounts.append(account)
            events.append("\(method):\(albumID):\(ids.joined(separator: ","))")
            if method == "PUT" {
                addCalls += 1
                if addCalls == failAdd { return (503, ["error": "uncertain"]) }
                if !failedVerification { links[albumID, default: []].formUnion(ids) }
                if changeBirthdayAfterAdd { birthday = "2000-03-01" }
            } else if !failUnlinkVerification { links[albumID, default: []].subtract(ids) }
            return (200, ids.map { ["id": $0, "success": true] as [String: Any] })
        }
        preconditionFailure("Unexpected request \(method) \(path)")
    }
    func session(accounts: [String] = ["p", "q"]) -> IMSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrganizationProtocol.self]
        OrganizationProtocol.handler = { try self.response($0) }
        return IMSession(address: "http://organization.invalid", profileID: "profile", credentials: accounts.map { IMCredential(account: IMAccount(id: $0, name: $0), key: $0) }, session: URLSession(configuration: configuration))
    }
}

@main struct ImmichOrganizationTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool) { precondition(condition()); checks += 1 }
        func blocked(_ work: () async throws -> Void) async {
            do { try await work(); preconditionFailure("Expected operation to be blocked") } catch { checks += 1 }
        }
        let dates: [(String, String, Int?)] = [
            ("2000-02-29", "2021-02-28", 20), ("2000-02-29", "2021-03-01", 21),
            ("2000-02-29", "2024-02-28", 23), ("2000-02-29", "2024-02-29", 24),
            ("2000-10-01", "2020-09-30", 19), ("2000-10-01", "2020-10-01", 20),
            ("2000-10-01", "1999-10-01", nil), ("2000-02-29", "2100-02-28", 99),
            ("2000-02-29", "2100-03-01", 100)
        ]
        for (birthday, captured, age) in dates {
            var asset = IMAsset(id: "test", ownerId: "p", originalFileName: "same.jpg", checksum: "x")
            asset.localDateTime = captured + "T23:59:59-03:00"
            asset.fileCreatedAt = "2026-10-21T00:00:00Z"
            check(IMOrganization.capturedAge(asset, birthday: birthday) == age)
        }
        for invalid in ["2021-02-29", "2020-13-01", "2020-00-10", "2020-01-00", "2020-01-01junk", "20-01-01", "", "2020/01/01"] { check(IMOrganization.day(invalid) == nil) }
        var fallback = IMAsset(id: "date", ownerId: "p", originalFileName: "x", checksum: "x")
        fallback.localDateTime = "invalid"; fallback.fileCreatedAt = "2021-03-01T00:30:00Z"
        check(IMOrganization.capturedAge(fallback, birthday: "2000-02-29") == 21)
        for range in [(-1, 1), (5, 4), (0, 151)] { await blocked { try IMOrganization.validateRange(range.0, range.1) } }
        try IMOrganization.validateRange(0, 150)

        do {
            let fixture = OrganizationFixture(), session = fixture.session()
            let analysis = try await IMOrganization.compare(session: session, albums: Array(fixture.albums.prefix(2)), progress: { _, _, _ in })
            check(analysis.total == 5 && analysis.skipped == 1)
            check(analysis.groups.count == 3 && analysis.groups.filter(\.common).count == 1)
            check(analysis.groups.first { $0.common }!.assets.count == 2)
            check(analysis.groups.flatMap(\.assets).first { $0.id == "c" }!.albums.contains { $0.id == "E" })
            let same = IMOrganization.comparisonGroups(assets: [fixture.assets["a"]!], albums: Array(fixture.albums.prefix(2)), memberships: ["A": ["a"], "B": ["a"]])
            check(same.count == 1 && same[0].common)
            var excluded = fixture.assets["c"]!
            excluded.isEdited = true
            check(IMOrganization.comparisonGroups(assets: [excluded], albums: fixture.albums, memberships: [:]).isEmpty)
            excluded.isEdited = false; excluded.stacked = true
            check(IMOrganization.comparisonGroups(assets: [excluded], albums: fixture.albums, memberships: [:]).isEmpty)
            excluded.stacked = false; excluded.isOffline = true
            check(IMOrganization.comparisonGroups(assets: [excluded], albums: fixture.albums, memberships: [:]).isEmpty)
            let selections = Dictionary(uniqueKeysWithValues: analysis.groups.map { ($0.id, $0.assets.contains { $0.id == "d" } ? "A" : "B") })
            var records: [IMActionRecord] = []
            try await IMOrganization.organize(session: session, analysis: analysis, selections: selections, progress: { _, _, _ in }, report: { records.append($0) })
            check(fixture.events.filter { $0.hasPrefix("PUT") }.count == 2)
            check(fixture.events.prefix(2).allSatisfy { $0.hasPrefix("PUT") })
            check(fixture.events.dropFirst(2).allSatisfy { $0.hasPrefix("DELETE") })
            check(fixture.links["E"] == ["a", "c"])
            check(fixture.links["B"]!.contains("c") && !fixture.links["A"]!.contains("c"))
            check(fixture.links["A"]!.contains("d") && !fixture.links["B"]!.contains("d"))
            check(records.filter { $0.status == "preparing" }.count == fixture.events.count)
            check(records.filter { $0.status == "confirmed" }.count == fixture.events.count)
            check(!fixture.events.contains { $0.contains("assets/") })
        }
        do {
            let fixture = OrganizationFixture(), session = fixture.session()
            let analysis = try await IMOrganization.compare(session: session, albums: Array(fixture.albums.prefix(2)), progress: { _, _, _ in })
            let group = analysis.groups.first { $0.assets.contains { $0.id == "c" } }!
            try await IMOrganization.organize(session: session, analysis: analysis, selections: [group.id: "both"], progress: { _, _, _ in }, report: { _ in })
            check(fixture.events == ["PUT:B:c"] && fixture.links["A"]!.contains("c") && fixture.links["B"]!.contains("c"))
        }
        do {
            let fixture = OrganizationFixture(), session = fixture.session()
            fixture.accountPermissions = ["q": ["album.read", "asset.read"], "p": ["all"]]
            let analysis = try await IMOrganization.compare(session: session, albums: Array(fixture.albums.prefix(2)), progress: { _, _, _ in })
            let group = analysis.groups.first { $0.assets.contains { $0.id == "c" } }!
            try await IMOrganization.organize(session: session, analysis: analysis, selections: [group.id: "both"], progress: { _, _, _ in }, report: { _ in })
            check(fixture.events == ["PUT:B:c"])
            check(fixture.mutationAccounts == ["p"])
        }
        // B needs both adding c and removing d: split scopes across keys cannot
        // authorize a transaction, and no changes may precede this preflight.
        for scopes in [["albumAsset.create"], ["albumAsset.delete"], ["albumAsset.create", "albumAsset.delete"]] {
            let fixture = OrganizationFixture()
            fixture.albums[0].ownerID = "r"
            fixture.albums[0].readerIDs.append("r")
            fixture.albums[0].writerIDs = ["r"]
            let session = fixture.session(accounts: ["p", "q", "r"])
            let analysis = try await IMOrganization.compare(session: session, albums: Array(fixture.albums.prefix(2)), progress: { _, _, _ in })
            let c = analysis.groups.first { $0.assets.contains { $0.id == "c" } }!
            let d = analysis.groups.first { $0.assets.contains { $0.id == "d" } }!
            fixture.accountPermissions = ["q": scopes, "p": ["albumAsset.create"]]
            if scopes.count == 2 {
                try await IMOrganization.organize(session: session, analysis: analysis, selections: [c.id: "B", d.id: "A"], progress: { _, _, _ in }, report: { _ in })
                check(fixture.events.filter { $0.contains(":B:") }.count == 2)
            } else {
                await blocked {
                    try await IMOrganization.organize(session: session, analysis: analysis, selections: [c.id: "B", d.id: "A"], progress: { _, _, _ in }, report: { _ in })
                }
                check(fixture.events.isEmpty)
            }
        }
        do {
            let fixture = OrganizationFixture(), session = fixture.session()
            let analysis = try await IMOrganization.compare(session: session, albums: Array(fixture.albums.prefix(2)), progress: { _, _, _ in })
            let group = analysis.groups.first { $0.assets.contains { $0.id == "c" } }!
            fixture.hiddenAssets = ["q": ["c"]]
            try await IMOrganization.organize(session: session, analysis: analysis, selections: [group.id: "both"], progress: { _, _, _ in }, report: { _ in })
            check(fixture.mutationAccounts == ["p"])
        }
        for status in [401, 403, 404] {
            let fixture = OrganizationFixture(), session = fixture.session()
            let analysis = try await IMOrganization.compare(session: session, albums: Array(fixture.albums.prefix(2)), progress: { _, _, _ in })
            let group = analysis.groups.first { $0.assets.contains { $0.id == "c" } }!
            OrganizationProtocol.handler = { request in
                if request.url!.path.hasSuffix("api-keys/me"), request.value(forHTTPHeaderField: "x-api-key") == "q" {
                    return (status, ["error": "access"])
                }
                return try fixture.response(request)
            }
            try await IMOrganization.organize(session: session, analysis: analysis, selections: [group.id: "both"], progress: { _, _, _ in }, report: { _ in })
            check(fixture.mutationAccounts == ["p"])
        }
        for failure in ["timeout", "server", "decode", "cancelled"] {
            let fixture = OrganizationFixture(), session = fixture.session()
            let analysis = try await IMOrganization.compare(session: session, albums: Array(fixture.albums.prefix(2)), progress: { _, _, _ in })
            let group = analysis.groups.first { $0.assets.contains { $0.id == "c" } }!
            var permissionAccounts: [String] = []
            OrganizationProtocol.handler = { request in
                if request.url!.path.hasSuffix("api-keys/me") {
                    permissionAccounts.append(request.value(forHTTPHeaderField: "x-api-key") ?? "")
                    switch failure {
                    case "timeout": throw URLError(.timedOut)
                    case "cancelled": throw URLError(.cancelled)
                    case "server": return (503, ["error": "unavailable"])
                    default: return (200, ["permissions": "invalid-response"])
                    }
                }
                return try fixture.response(request)
            }
            do {
                try await IMOrganization.organize(session: session, analysis: analysis, selections: [group.id: "both"], progress: { _, _, _ in }, report: { _ in })
                preconditionFailure("Preflight failure must propagate")
            } catch {
                check((error is CancellationError) == (failure == "cancelled"))
                if failure != "cancelled" {
                    let message = error.localizedDescription
                    switch failure {
                    case "timeout": check(message.contains("consulta ao Immich não foi confirmada"))
                    case "server": check(message.contains("HTTP 503"))
                    default: check(message.contains("incompatível"))
                    }
                }
            }
            check(permissionAccounts == ["q"])
            check(fixture.events.isEmpty)
        }
        for failure in ["permission", "checksum", "live", "membership", "persistence", "profile", "expired", "selection", "unverified-add", "second-add"] {
            let fixture = OrganizationFixture(), session = fixture.session()
            var analysis = try await IMOrganization.compare(session: session, albums: Array(fixture.albums.prefix(2)), progress: { _, _, _ in })
            let group = analysis.groups.first { $0.assets.contains { $0.id == "c" } }!
            var selection = [group.id: "B"]
            switch failure {
            case "permission": fixture.permissions = ["album.read"]
            case "checksum": fixture.assets["c"]!.checksum = "changed"
            case "live": fixture.assets["c"]!.livePhotoVideoId = "new-motion"
            case "membership": fixture.links["A"]!.remove("c")
            case "profile": analysis.profileID = "other"
            case "expired": analysis.createdAt = Date().addingTimeInterval(-86401)
            case "selection": selection = ["invented": "B"]
            case "unverified-add": fixture.failedVerification = true
            case "second-add":
                fixture.failAdd = 2
                let other = analysis.groups.first { $0.assets.contains { $0.id == "d" } }!
                selection[other.id] = "A"
            default: break
            }
            var records: [IMActionRecord] = []
            await blocked {
                try await IMOrganization.organize(session: session, analysis: analysis, selections: selection, progress: { _, _, _ in }, report: { record in
                    if failure == "persistence" { throw BridgeError(message: "No durable history") }
                    records.append(record)
                })
            }
            check(!fixture.events.contains { $0.hasPrefix("DELETE") })
            if failure == "second-add" { check(fixture.events.count == 2 && records.last?.status == "uncertain") }
            else if failure == "unverified-add" { check(fixture.events.count == 1 && records.last?.status == "uncertain") }
            else { check(fixture.events.isEmpty) }
        }
        do {
            let fixture = OrganizationFixture(), session = fixture.session()
            let analysis = try await IMOrganization.ageSearch(session: session, person: fixture.person, source: nil, destination: fixture.albums[1], minAge: 20, maxAge: 20, progress: { _, _, _ in })
            check(analysis.sourceAlbums.map(\.id) == ["A"])
            check(Set(analysis.assets.map(\.id)) == ["a", "c"])
            let filters = fixture.searchBodies[0]["filter"] as! [String: Any]
            check((filters["albumIds"] as! [String: [String]])["any"] == ["A"])
            try await IMOrganization.ageMove(session: session, analysis: analysis, selectedIDs: ["c"], progress: { _, _, _ in }, report: { _ in })
            check(fixture.events == ["PUT:B:c", "DELETE:A:c"])
            check(fixture.links["E"] == ["a", "c"] && fixture.links["B"]!.contains("c"))
        }
        for failure in ["birthday", "association", "capture", "content", "selection", "permission", "uncertain", "birthday-after-add"] {
            let fixture = OrganizationFixture(), session = fixture.session()
            let analysis = try await IMOrganization.ageSearch(session: session, person: fixture.person, source: fixture.albums[0], destination: fixture.albums[1], minAge: 20, maxAge: 20, progress: { _, _, _ in })
            switch failure {
            case "birthday": fixture.birthday = "2000-03-01"
            case "association": fixture.associated = false
            case "capture": fixture.assets["c"]!.localDateTime = "2020-03-01T00:00:00Z"
            case "content": fixture.assets["c"]!.checksum = "changed"
            case "permission": fixture.permissions = []
            case "uncertain": fixture.failAdd = 1
            case "birthday-after-add": fixture.changeBirthdayAfterAdd = true
            default: break
            }
            await blocked {
                try await IMOrganization.ageMove(session: session, analysis: analysis, selectedIDs: [failure == "selection" ? "invented" : "c"], progress: { _, _, _ in }, report: { _ in })
            }
            check(!fixture.events.contains { $0.hasPrefix("DELETE") })
            if failure != "uncertain" && failure != "birthday-after-add" { check(fixture.events.isEmpty) }
            if failure == "birthday-after-add" { check(fixture.events == ["PUT:B:c"]) }
        }
        do {
            let fixture = OrganizationFixture(), session = fixture.session()
            let analysis = try await IMOrganization.compare(session: session, albums: Array(fixture.albums.prefix(2)), progress: { _, _, _ in })
            let group = analysis.groups.first { $0.common }!
            fixture.failUnlinkVerification = true
            var records: [IMActionRecord] = []
            await blocked {
                try await IMOrganization.organize(session: session, analysis: analysis, selections: [group.id: "A"], progress: { _, _, _ in }, report: { records.append($0) })
            }
            check(fixture.events == ["DELETE:B:b"] && records.last?.status == "uncertain")
            check(records.count == 2 && records[0].id == records[1].id)
        }
        do {
            let fixture = OrganizationFixture(), session = fixture.session()
            fixture.links["A"] = ["a"]
            fixture.links["B"] = Set((0..<30000).map { "large-\($0)" })
            await blocked {
                _ = try await IMOrganization.compare(session: session, albums: Array(fixture.albums.prefix(2)), progress: { _, _, _ in })
            }
            check(fixture.events.isEmpty)
        }
        for count in [0, 101] {
            let fixture = OrganizationFixture()
            let destination = fixture.albums[1]
            fixture.albums = [destination] + (0..<count).map { IMAlbum(id: "source-\($0)", name: "Source", ownerID: "p", readerIDs: ["p"], writerIDs: ["p"]) }
            let session = fixture.session()
            await blocked {
                _ = try await IMOrganization.ageSearch(session: session, person: fixture.person, source: nil, destination: destination, minAge: 20, maxAge: 20, progress: { _, _, _ in })
            }
            check(fixture.searchBodies.isEmpty && fixture.events.isEmpty)
        }
        print("Immich organization: \(checks) calendar, grouping, selection and transaction assertions passed; memory fixture only.")
    }
}
