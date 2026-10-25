import SwiftUI
import AppKit
import ImageIO
import CryptoKit

/// Created only from a validated transfer. No credential appears in a URL, label or disk cache.
struct PFAccountAvatarContext {
    let profileID: String
    let address: String
    let userID: String
    let key: String

    var cacheKey: String {
        SHA256.hash(data: Data([profileID, address, userID, key].joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    func request() throws -> URLRequest {
        guard let id = UUID(uuidString: userID)?.uuidString.lowercased() else { throw URLError(.badURL) }
        var request = try ImmichClient(address: address, key: key).request("users/\(id)/profile-image")
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }
}

enum PFAccountAvatar {
    static let maximumBytes = 2 * 1024 * 1024
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        guard let first = words.first?.first else { return "" }
        let last = words.count > 1 ? words.last?.first : nil
        return (String(first) + (last.map(String.init) ?? "")).uppercased()
    }
    static func decode(_ data: Data) -> NSImage? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 56,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    static func fetch(_ context: PFAccountAvatarContext) async throws -> NSImage? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 5
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // Refuse every redirect, including same-host redirects, before forwarding any header.
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = try context.request()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == request.url,
              response.expectedContentLength <= Int64(maximumBytes) else { return nil }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { return nil }
            data.append(byte)
        }
        try Task.checkCancellation()
        return decode(data)
    }
}

@MainActor final class PFAccountAvatarLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var contextKey: String?
    private struct Cached {
        let image: NSImage?
        let expires: Date
    }
    private static var cache: [String: Cached] = [:]
    private let fetch: (PFAccountAvatarContext) async throws -> NSImage?
    init(fetch: @escaping (PFAccountAvatarContext) async throws -> NSImage? = PFAccountAvatar.fetch) { self.fetch = fetch }

    func load(_ context: PFAccountAvatarContext?) async {
        let key = context?.cacheKey
        contextKey = key; image = nil
        guard let context, let key else { return }
        let now = Date()
        Self.cache = Self.cache.filter { $0.value.expires > now }
        if let cached = Self.cache[key] { image = cached.image; return }
        do {
            let result = try await fetch(context)
            try Task.checkCancellation()
            guard contextKey == key else { return }
            image = result
            if Self.cache.count >= 16, let oldest = Self.cache.min(by: { $0.value.expires < $1.value.expires })?.key {
                Self.cache.removeValue(forKey: oldest)
            }
            Self.cache[key] = Cached(image: result, expires: now.addingTimeInterval(result == nil ? 30 : 300))
        } catch {
            // Missing profile image/permission/network is cosmetic; keep the initials.
            if contextKey == key { image = nil }
        }
    }
}

// A native Menu extracts an NSImage and a title from its label. Render the
// initials into the image so they cannot be mistaken for the account title.
extension PFAccountAvatar {
    @MainActor static func sidebarImage(name: String, image: NSImage?) -> NSImage {
        let avatar = NSImage(size: NSSize(width: 20, height: 20))
        avatar.lockFocus()
        defer { avatar.unlockFocus() }
        let circle = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 20, height: 20))
        circle.addClip()
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = max(20 / image.size.width, 20 / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: (20 - size.width) / 2, y: (20 - size.height) / 2, width: size.width, height: size.height))
        } else {
            NSColor.systemBlue.withAlphaComponent(0.12).setFill(); circle.fill()
            let text = NSAttributedString(string: initials(name), attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .semibold), .foregroundColor: NSColor.systemBlue
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: (20 - size.width) / 2, y: (20 - size.height) / 2))
        }
        avatar.isTemplate = false
        return avatar
    }
}
