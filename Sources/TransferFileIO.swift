import Foundation
import Photos

/// File preparation runs outside the UI actor. Originals are never modified.
enum TransferFileIO {
    static func exportPhotosResource(_ resource: PHAssetResource, to destination: URL, allowCloud: Bool,
                                     progress: @escaping @Sendable (Double) -> Void,
                                     waiting: @escaping @Sendable () -> Void = {}) async throws {
        try await exportStream(to: destination, progress: progress, waiting: waiting) { receive, reportProgress, finish in
            let manager = PHAssetResourceManager.default()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = allowCloud
            options.progressHandler = reportProgress
            let requestID = manager.requestData(for: resource, options: options, dataReceivedHandler: receive, completionHandler: finish)
            return { manager.cancelDataRequest(requestID) }
        }
    }

    // Injectable callbacks exercise stream/cancel/timeout races without a Photos library.
    static func exportStream(to destination: URL, inactivityTimeout: TimeInterval = 900, warningAfter: TimeInterval = 120,
                             progress: @escaping @Sendable (Double) -> Void,
                             waiting: @escaping @Sendable () -> Void = {},
                             start: (@escaping @Sendable (Data) -> Void,
                                     @escaping @Sendable (Double) -> Void,
                                     @escaping @Sendable (Error?) -> Void) -> @Sendable () -> Void) async throws {
        try Task.checkCancellation()
        let gate = try PFPhotosExportGate(destination: destination, inactivityTimeout: inactivityTimeout, warningAfter: warningAfter, progress: progress, waiting: waiting)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard gate.begin(continuation) else { return }
                let cancel = start({ gate.receive($0) }, { gate.reportProgress($0) }, { gate.finish($0) })
                gate.installCancellation(cancel)
            }
        }, onCancel: { gate.cancel() })
    }

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
            try PFUploadFileIO.checkCapacity(fileSizes: [try PFUploadFileIO.size(of: source)], availableBytes: PFUploadFileIO.availableCapacity(at: destination.deletingLastPathComponent()))
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

// PhotoKit delivers chunks on an arbitrary serial queue. This gate also
// serializes timeout/cancellation so late callbacks cannot write a closed file.
private final class PFPhotosExportGate: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let temporary: URL
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let waiting: @Sendable () -> Void
    private var didWarn = false
    private var capacityBytes: Int64 = 0
    private let inactivityTimeout: TimeInterval
    private let warningAfter: TimeInterval
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var terminal: Result<Void, Error>?
    private var cancellation: (@Sendable () -> Void)?
    private var cancellationRequired = false
    private var timer: DispatchSourceTimer?
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var lastProgress = 0.0
    private var receivedData = false

    init(destination: URL, inactivityTimeout: TimeInterval, warningAfter: TimeInterval, progress: @escaping @Sendable (Double) -> Void, waiting: @escaping @Sendable () -> Void) throws {
        guard inactivityTimeout.isFinite && inactivityTimeout > 0 && warningAfter.isFinite && warningAfter > 0 else { throw CocoaError(.fileWriteUnknown) }
        self.destination = destination
        self.inactivityTimeout = inactivityTimeout
        self.warningAfter = warningAfter
        self.progress = progress
        self.waiting = waiting
        directory = destination.deletingLastPathComponent().appendingPathComponent(".ponte-photos-" + UUID().uuidString, isDirectory: true)
        temporary = directory.appendingPathComponent("original")
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forWritingTo: temporary)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func begin(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        if let terminal {
            lock.unlock(); continuation.resume(with: terminal); return false
        }
        self.continuation = continuation
        lastActivity = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let interval = min(1, min(inactivityTimeout, warningAfter) / 2)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.checkInactivity() }
        self.timer = timer
        timer.resume()
        lock.unlock()
        return true
    }

    func installCancellation(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let cancelNow = cancellationRequired
        if terminal == nil { cancellation = action }
        lock.unlock()
        if cancelNow { action() }
    }

    func receive(_ data: Data) {
        lock.lock()
        guard terminal == nil, let handle else { lock.unlock(); return }
        do {
            if !data.isEmpty && (capacityBytes == 0 || capacityBytes >= 64 * 1024 * 1024) {
                try PFUploadFileIO.checkCapacity(fileSizes: [Int64(data.count)], availableBytes: PFUploadFileIO.availableCapacity(at: directory))
                capacityBytes = 0
            }
            try handle.write(contentsOf: data)
            if !data.isEmpty {
                capacityBytes += Int64(data.count)
                receivedData = true
                lastActivity = ProcessInfo.processInfo.systemUptime
                didWarn = false
            }
            lock.unlock()
        } catch {
            completeLocked(.failure(error), cancelRequest: true)
        }
    }

    func reportProgress(_ value: Double) {
        lock.lock()
        guard terminal == nil, value.isFinite else { lock.unlock(); return }
        let next = min(1, max(0, value))
        guard next > lastProgress else { lock.unlock(); return }
        lastProgress = next
        lastActivity = ProcessInfo.processInfo.systemUptime
        didWarn = false
        lock.unlock()
        progress(next)
    }

    func finish(_ error: Error?) {
        lock.lock()
        completeLocked(error.map { .failure($0) } ?? .success(()), cancelRequest: false)
    }

    func cancel() {
        lock.lock()
        completeLocked(.failure(CancellationError()), cancelRequest: true)
    }

    private func checkInactivity() {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastActivity
        if elapsed >= inactivityTimeout {
            completeLocked(.failure(BridgeError(message: M("O Fotos ficou 15 minutos sem entregar dados nem progresso. A preparação foi interrompida; confira o original no Fotos e tente novamente."))), cancelRequest: true)
        } else if elapsed >= warningAfter && !didWarn {
            didWarn = true
            lock.unlock()
            waiting()
        } else { lock.unlock() }
    }

    // Caller owns the lock. Finish all file work before resuming or cancelling
    // PhotoKit; its callbacks may run synchronously and must never deadlock here.
    private func completeLocked(_ result: Result<Void, Error>, cancelRequest: Bool) {
        guard terminal == nil else { lock.unlock(); return }
        var outcome = result
        do {
            try handle?.close()
            handle = nil
            if case .success = outcome {
                guard receivedData else { throw BridgeError(message: M("O Fotos retornou um original vazio. A preparação foi interrompida.")) }
                // moveItem refuses to overwrite an existing destination.
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch { outcome = .failure(error) }
        handle = nil
        terminal = outcome
        cancellationRequired = cancelRequest
        let continuation = self.continuation
        self.continuation = nil
        let cancellation = cancelRequest ? self.cancellation : nil
        self.cancellation = nil
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        try? FileManager.default.removeItem(at: directory)
        lock.unlock()
        cancellation?()
        continuation?.resume(with: outcome)
    }
}
