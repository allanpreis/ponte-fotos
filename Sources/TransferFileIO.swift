import Foundation

/// File preparation runs outside the UI actor. Originals are never modified.
enum TransferFileIO {
    static func checksum(_ url: URL) async throws -> String {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try ImmichClient.checksum(url)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    static func copyOriginal(from source: URL, to destination: URL) async throws {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".ponte-copy-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            let temporary = staging.appendingPathComponent("original")
            try FileManager.default.copyItem(at: source, to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try Task.checkCancellation()
            // moveItem fails if the destination exists; neither original is overwritten.
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
