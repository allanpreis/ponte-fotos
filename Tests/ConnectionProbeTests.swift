import Foundation

private final class ProbeFixture: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main struct ConnectionProbeTests {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProbeFixture.self]
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let client = try ImmichClient(address: "https://fixture.invalid", key: "fixture-key")
        let userID = "A7FA817C-3C03-4C78-8D78-C2B9A0631B86"
        let version = #"{"major":3,"minor":3,"patch":0}"#
        var paths: [String] = []
        ProbeFixture.handler = { request in
            precondition(request.timeoutInterval == 2)
            let path = request.url!.path
            paths.append(path)
            if path == "/api/server/version" {
                precondition(request.value(forHTTPHeaderField: "x-api-key") == nil)
                return (200, version)
            }
            precondition(path == "/api/users/me")
            precondition(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
            return (200, "{\"id\":\"\(userID)\"}")
        }
        let identity = try await client.probe(timeout: 2, session: session)
        precondition(identity.userID == userID.lowercased() && identity.serverVersion == "Immich 3.3.0")
        precondition(paths == ["/api/server/version", "/api/users/me"])
        precondition(client.request("assets").timeoutInterval == 300)
        func fails(fallback: Bool) async throws {
            do {
                _ = try await client.probe(timeout: 2, session: session)
                fatalError("Invalid connection accepted")
            } catch let error as ConnectionProbeError { precondition(error.canFallback == fallback) }
        }
        for status in [401, 403, 404, 302] {
            ProbeFixture.handler = { _ in (status, "{}") }
            try await fails(fallback: false)
        }
        for status in [500, 503] {
            ProbeFixture.handler = { _ in (status, "{}") }
            try await fails(fallback: true)
        }
        ProbeFixture.handler = { _ in throw URLError(.timedOut) }
        try await fails(fallback: true)
        ProbeFixture.handler = { _ in throw URLError(.serverCertificateUntrusted) }
        try await fails(fallback: false)
        for body in ["<html>Login</html>", #"{"major":2,"minor":9,"patch":0}"#, #"{"major":3}"#] {
            ProbeFixture.handler = { _ in (200, body) }
            try await fails(fallback: false)
        }
        for body in [#"{"id":""}"#, #"{"id":"not-a-uuid"}"#, #"{"name":"Usuário A"}"#] {
            ProbeFixture.handler = { request in (200, request.url!.path.hasSuffix("version") ? version : body) }
            try await fails(fallback: false)
        }
        ProbeFixture.handler = { request in
            precondition(request.url!.path == "/api/assets/fixture-asset")
            precondition(request.timeoutInterval == 5 && request.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
            return (200, "{\"checksum\":\"fixture-checksum\",\"ownerId\":\"\(userID.lowercased())\"}")
        }
        let historyMatch = try await client.matchesHistory(assetID: "fixture-asset", checksum: "fixture-checksum", userID: userID.lowercased(), session: session)
        let wrongChecksum = try await client.matchesHistory(assetID: "fixture-asset", checksum: "different", userID: userID.lowercased(), session: session)
        let wrongOwner = try await client.matchesHistory(assetID: "fixture-asset", checksum: "fixture-checksum", userID: UUID().uuidString, session: session)
        precondition(historyMatch && !wrongChecksum && !wrongOwner)
        print("Connection probe passed: request order, anonymous version, authenticated identity, short timeout, unchanged uploads, HTTP/transport classification, invalid server/user rejection.")
    }
}
