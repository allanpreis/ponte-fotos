import Foundation
import CryptoKit

@main struct TransferFileIOTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.bin"), destination = root.appendingPathComponent("copy.bin")
        let bytes = Data(repeating: 42, count: 16 * 1024 * 1024)
        try bytes.write(to: source)
        try await TransferFileIO.copyOriginal(from: source, to: destination)
        let original = try Data(contentsOf: source); precondition(original == bytes)
        precondition((try? Data(contentsOf: destination)) == bytes)
        let actual = try await TransferFileIO.checksum(destination)
        precondition(actual == Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString())
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        do { try await TransferFileIO.copyOriginal(from: source, to: destination); fatalError("existing destination overwritten") } catch {}
        precondition((try? Data(contentsOf: destination)) == bytes)
        let missing = root.appendingPathComponent("missing")
        do { try await TransferFileIO.copyOriginal(from: missing, to: root.appendingPathComponent("failed")); fatalError("missing accepted") } catch {}
        precondition(FileManager.default.fileExists(atPath: source.path))
        let cancelled = Task { try await TransferFileIO.checksum(source) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancellation ignored") }
        catch is CancellationError {}
        precondition((try? Data(contentsOf: source)) == bytes)
        print("Transfer file I/O: copy/hash integrity, private permissions, original preservation and errors passed; synthetic files only.")
    }
}
