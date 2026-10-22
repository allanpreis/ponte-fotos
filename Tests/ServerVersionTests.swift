import Foundation
@main struct ServerVersionTests {
    static func main() throws {
        let cases = [
            #"{"major":3,"minor":3,"patch":0,"prerelease":null}"#,
            #"{"major":3,"minor":3,"patch":0,"prerelease":"beta","extra":true}"#,
            #"{"major":3,"minor":3,"patch":0}"#
        ]
        for json in cases {
            let version = try JSONDecoder().decode(ServerVersion.self, from: Data(json.utf8))
            precondition(version.major == 3 && version.label == "Immich 3.3.0")
        }
        do {
            _ = try JSONDecoder().decode(ServerVersion.self, from: Data(#"{"message":"unauthorized"}"#.utf8))
            fatalError("Resposta inválida aceita")
        } catch is DecodingError { }
        let client = try ImmichClient(address: "http://photos.example.com:2283/", key: "test-only")
        precondition(client.base.absoluteString == "http://photos.example.com:2283/api")
        print("5 verificações passaram: resposta real com null, campos extras, versão simples, inválida e URL.")
    }
}
