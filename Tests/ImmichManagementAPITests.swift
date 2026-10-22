import Foundation
final class IMAlbumFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let key = request.value(forHTTPHeaderField: "x-api-key")!
        let owned = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems?.contains { $0.name == "isOwned" && $0.value == "true" } == true
        let first: [String:Any] = ["id":"one","albumName":"Álbum de teste","shared":true,"assetCount":2]
        let second: [String:Any] = ["id":"two","albumName":"Viagens","shared":true,"assetCount":3,"albumUsers":[["user":["id":"a"],"role":"editor"]]]
        let object: Any
        if url.path.hasSuffix("/albums") {
            object = owned ? (key == "a-key" ? [first] : [second]) : [first,second]
        } else {
            object = ["id":"photo","ownerId":"b","owner":["name":"Usuário B"],"originalFileName":"IMG.HEIC","checksum":"same","type":"IMAGE","fileCreatedAt":"2020-01-01T00:00:00Z","fileSize":1234,"width":800,"height":600]
        }
        let bytes = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct ImmichManagementAPITests {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IMAlbumFixture.self]
        let transport = URLSession(configuration: config)
        let a = IMCredential(account:IMAccount(id:"a",name:"Usuário A"),key:"a-key")
        let b = IMCredential(account:IMAccount(id:"b",name:"Usuário B"),key:"b-key")
        let client = IMClient(address:"http://fixture",credential:a,session:transport)
        let albums = try await client.albums()
        precondition(albums.first { $0.id == "one" }!.ownerID == "a")
        precondition(albums.first { $0.id == "two" }!.ownerID == "")
        precondition(albums.first { $0.id == "two" }!.writerIDs == ["a"])
        let session = IMSession(address:"http://fixture",profileID:"fixture",credentials:[a,b],session:transport)
        let merged = try await session.albums()
        precondition(merged.count == 2)
        precondition(merged.first { $0.id == "two" }!.ownerID == "b")
        precondition(Set(merged.first { $0.id == "two" }!.writerIDs) == ["a","b"])
        precondition(Set(merged.first { $0.id == "one" }!.readerIDs) == ["a","b"])
        let asset = try await client.asset("photo")
        precondition(asset.ownerName == "Usuário B" && asset.fileSize == 1234 && asset.width == 800)
        print("Management API: ownership via isOwned, editor access, shared union and real asset response shape passed (memory HTTP only).")
    }
}
