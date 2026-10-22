import Foundation

@main struct ImmichDuplicatesTests {
    @MainActor static func main() async throws {
        func asset(_ id: String, owner: String = "owner", checksum: String = "same", live: Bool = false) -> IMAsset {
            var value = IMAsset(id: id, ownerId: owner, originalFileName: "IMG_6414.HEIC", checksum: checksum, type: "IMAGE")
            value.createdAt = id
            value.fileCreatedAt = "2026-03-04T18:30:08.000Z"
            value.livePhotoVideoId = live ? "motion" : nil
            return value
        }
        let early = asset("1-static"), live = asset("2-live", owner: "second", live: true)
        var edited = asset("edited"); edited.isEdited = true
        var offline = asset("offline"); offline.isOffline = true
        var stacked = asset("stacked"); stacked.stacked = true
        var trashed = asset("trashed"); trashed.isTrashed = true
        let different = asset("different", checksum: "different")
        let groups = IMDuplicates.groups([live, early, edited, offline, stacked, trashed, different], availableOwners: ["owner", "second"])
        precondition(groups.count == 1 && groups[0].assets.count == 2)
        precondition(groups[0].keepID == live.id && groups[0].assets.first?.id == early.id)
        precondition(IMDuplicates.groups([early, different], availableOwners: ["owner"]).isEmpty, "Names cannot identify duplicates")
        let statics = IMDuplicates.groups([asset("b"), asset("a")], availableOwners: ["owner"])
        precondition(statics[0].keepID == "a", "Earliest upload wins without Live")
        let unavailable = IMDuplicates.groups([early, live], availableOwners: ["owner"])
        precondition(unavailable[0].unavailableOwnerIDs == ["second"])
        var analysis = IMDuplicateAnalysis(id: "analysis", profileID: "profile", albums: [], createdAt: Date(), groups: groups, total: 7, skipped: 4)
        let pairs = try IMDuplicates.pairs(analysis: analysis, selections: [groups[0].id: live.id])
        precondition(pairs.count == 1 && pairs[0].drop.id == early.id)
        try blocked { _ = try IMDuplicates.pairs(analysis: analysis, selections: [groups[0].id: early.id]) }
        try blocked { _ = try IMDuplicates.pairs(analysis: analysis, selections: [:]) }
        try blocked { _ = try IMDuplicates.pairs(analysis: analysis, selections: ["unknown": live.id]) }
        try blocked { _ = try IMDuplicates.pairs(analysis: analysis, selections: [groups[0].id: "unknown"]) }
        analysis.groups = unavailable
        try blocked { _ = try IMDuplicates.pairs(analysis: analysis, selections: [unavailable[0].id: live.id]) }
        analysis.groups = groups
        let date = Date()
        analysis.createdAt = date.addingTimeInterval(-86_400)
        try IMDuplicates.validateAnalysis(analysis, profileID: "profile", now: date)
        try blocked { try IMDuplicates.validateAnalysis(analysis, profileID: "other", now: date) }
        try blocked { try IMDuplicates.validateAnalysis(analysis, profileID: "profile", now: date.addingTimeInterval(1)) }
        analysis.createdAt = date.addingTimeInterval(1)
        try blocked { try IMDuplicates.validateAnalysis(analysis, profileID: "profile", now: date) }
        try IMDuplicates.unchanged(early, early)
        for key in ["owner", "checksum", "live", "type", "edited", "offline", "stacked", "trashed"] {
            var changed = early
            switch key {
            case "owner": changed.ownerId = "other"
            case "checksum": changed.checksum = "changed"
            case "live": changed.livePhotoVideoId = "new-motion"
            case "type": changed.type = "VIDEO"
            case "edited": changed.isEdited = true
            case "offline": changed.isOffline = true
            case "stacked": changed.stacked = true
            default: changed.isTrashed = true
            }
            try blocked { try IMDuplicates.unchanged(early, changed) }
        }
        var twoLive = live; twoLive.id = "3-live"
        analysis.groups = IMDuplicates.groups([early, live, twoLive], availableOwners: ["owner", "second"])
        try blocked { _ = try IMDuplicates.pairs(analysis: analysis, selections: [analysis.groups[0].id: live.id]) }
        try await fixtureTests()
        print("PASS native duplicate grouping, Live keeper/protection, missing owners, profile/expiry, stale content, fixture preflight and mutation safety")
    }

    static func blocked(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw BridgeError(message: "Expected safety rejection")
    }

    @MainActor static func fixtureTests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DuplicateURLFixture.self]
        let http = URLSession(configuration: config)
        defer { http.invalidateAndCancel() }
        let owner = IMCredential(account: IMAccount(id: DuplicateServer.a, name: "Static account"), key: "static-key")
        let liveOwner = IMCredential(account: IMAccount(id: DuplicateServer.b, name: "Live account"), key: "live-key")
        let session = IMSession(address: "https://duplicates.invalid", profileID: "fixture", credentials: [owner, liveOwner], session: http)
        let album = IMAlbum(id: DuplicateServer.origin, name: "Source", ownerID: DuplicateServer.a,
            shared: true, count: 2, readerIDs: [DuplicateServer.a, DuplicateServer.b], writerIDs: [DuplicateServer.a, DuplicateServer.b])
        func setup() -> DuplicateServer {
            let state = DuplicateServer()
            DuplicateURLFixture.handler = { try state.handle($0) }
            return state
        }
        func scan() async throws -> IMDuplicateAnalysis { try await IMDuplicates.scan(session: session, albums: [album], progress: { _,_,_ in }) }
        func execute(_ analysis: IMDuplicateAnalysis, report: @escaping IMReport = { _ in }) async throws {
            try await IMDuplicates.trash(session: session, analysis: analysis,
                selections: [analysis.groups[0].id: DuplicateServer.liveID], progress: { _,_,_ in }, report: report)
        }
        func rejected(_ operation: () async throws -> Void) async throws {
            do { try await operation() } catch { return }
            throw BridgeError(message: "Expected fixture safety rejection")
        }
        var state = setup()
        var analysis = try await scan()
        precondition(analysis.groups.count == 1 && analysis.groups[0].keepID == DuplicateServer.liveID)
        precondition(analysis.groups[0].assets.first(where: { $0.id == DuplicateServer.staticID })!.albums.count == 2)
        var records: [IMActionRecord] = []
        try await execute(analysis) { records.append($0) }
        precondition(state.mutations == ["add", "trash"] && state.trashed)
        precondition(records.map(\.status) == ["preparing", "confirmed", "preparing", "confirmed"])
        precondition(records[0].id == records[1].id && records[2].id == records[3].id)
        precondition(state.links[DuplicateServer.external]!.contains(DuplicateServer.liveID), "Preserve albums outside the scan")

        state = setup(); analysis = try await scan(); state.denyStaticLiveRead = true
        try await execute(analysis)
        precondition(state.mutations == ["add", "trash"] && state.addKey == "live-key", "An editor can preserve an album when its owner cannot read the keeper")
        state = setup(); analysis = try await scan(); state.noDelete = true
        try await rejected { try await execute(analysis) }; precondition(state.mutations.isEmpty)
        state = setup(); analysis = try await scan(); state.changed = true
        try await rejected { try await execute(analysis) }; precondition(state.mutations.isEmpty)
        state = setup(); analysis = try await scan(); state.failAddReadback = true; records = []
        try await rejected { try await execute(analysis) { records.append($0) } }
        precondition(state.mutations == ["add"] && records.map(\.status) == ["preparing", "uncertain"])
        precondition(records[0].id == records[1].id)
        state = setup(); analysis = try await scan(); state.failTrash = true; records = []
        try await rejected { try await execute(analysis) { records.append($0) } }
        precondition(state.mutations == ["add", "trash"] && records.last?.status == "uncertain")
        state = setup(); analysis = try await scan()
        try await rejected { try await execute(analysis) { _ in throw BridgeError(message: "Fixture persistence failed") } }
        precondition(state.mutations.isEmpty, "Persist preparing before the first HTTP write")
        state = setup()
        let incomplete = IMSession(address: "https://duplicates.invalid", profileID: "fixture", credentials: [owner], session: http)
        let missing = try await IMDuplicates.scan(session: incomplete, albums: [album], progress: { _,_,_ in })
        precondition(missing.groups[0].unavailableOwnerIDs == [DuplicateServer.b])
        try await rejected {
            try await IMDuplicates.trash(session: incomplete, analysis: missing,
                selections: [missing.groups[0].id: DuplicateServer.liveID], progress: { _,_,_ in }, report: { _ in })
        }
        precondition(state.mutations.isEmpty)
    }
}


private final class DuplicateURLFixture: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class DuplicateServer {
    static let a = "11111111-1111-4111-8111-111111111111"
    static let b = "22222222-2222-4222-8222-222222222222"
    static let origin = "33333333-3333-4333-8333-333333333333"
    static let external = "44444444-4444-4444-8444-444444444444"
    static let staticID = "55555555-5555-4555-8555-555555555555"
    static let liveID = "66666666-6666-4666-8666-666666666666"
    static let motion = "77777777-7777-4777-8777-777777777777"
    var links: [String:Set<String>] = [origin: [staticID, liveID], external: [staticID]]
    var mutations: [String] = []
    var trashed = false, noDelete = false, changed = false, failAddReadback = false, failTrash = false, denyStaticLiveRead = false
    var addKey: String?
    func handle(_ request: URLRequest) throws -> (Int, Data) {
        let url = request.url!, path = url.path, method = request.httpMethod ?? "GET"
        func response(_ value: Any) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value)) }
        func album(_ id: String) -> [String:Any] {
            ["id":id,"albumName":id == Self.origin ? "Source":"Outside scan", "ownerId":Self.a,
             "owner":["id":Self.a,"name":"Static account"], "shared":true,"assetCount":links[id]!.count,
             "albumUsers":[["user":["id":Self.b],"role":"editor"]]]
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if path == "/api/api-keys/me" {
            return try response(["permissions":noDelete ? ["asset.read","album.read","albumAsset.create"]:["all"]])
        }
        if path == "/api/albums" {
            let assetID = query.first(where: { $0.name == "assetId" })?.value
            return try response([Self.origin,Self.external].filter { assetID == nil || links[$0]!.contains(assetID!) }.map(album))
        }
        if path == "/api/timeline/buckets" { return try response([["timeBucket":"2026-03-01T00:00:00Z","count":2]]) }
        if path == "/api/timeline/bucket" {
            let id = query.first(where: { $0.name == "albumId" })!.value!
            var ids = links[id]!
            if failAddReadback && id == Self.external { ids.remove(Self.liveID) }
            return try response(["id":ids.sorted(),"ownerId":ids.sorted().map { $0 == Self.staticID ? Self.a:Self.b }])
        }
        if path.hasPrefix("/api/assets/") && method == "GET" {
            let id = url.lastPathComponent, live = id == Self.liveID
            if live && denyStaticLiveRead && request.value(forHTTPHeaderField: "x-api-key") == "static-key" { return (403, Data("{}".utf8)) }
            return try response(["id":id,"ownerId":live ? Self.b:Self.a,"originalFileName":"IMG_6414.HEIC",
                "checksum":changed && !live ? "changed":"identical","type":"IMAGE",
                "createdAt":live ? "2026-03-05T00:00:00Z":"2026-03-04T00:00:00Z",
                "fileCreatedAt":"2026-03-04T18:30:08Z","isTrashed":!live && trashed,
                "isOffline":false,"isEdited":false,"isFavorite":false,
                "livePhotoVideoId":live ? Self.motion as Any : NSNull()])
        }
        if path.hasPrefix("/api/albums/") && method == "PUT" {
            mutations.append("add")
            addKey = request.value(forHTTPHeaderField: "x-api-key")
            let id = url.pathComponents[url.pathComponents.count - 2]
            links[id]!.insert(Self.liveID)
            return try response([["id":Self.liveID,"success":true]])
        }
        if path == "/api/assets" && method == "DELETE" {
            mutations.append("trash")
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 1024), result = Data()
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; result.append(contentsOf: bytes.prefix(count)) }
                data = result
            }
            let body = try JSONSerialization.jsonObject(with: data!) as! [String:Any]
            precondition(body["force"] as? Bool == false && body["ids"] as? [String] == [Self.staticID])
            if failTrash { throw URLError(.timedOut) }
            trashed = true
            return try response([:])
        }
        throw BridgeError(message: "Unexpected fixture route \(method) \(path)")
    }
}
