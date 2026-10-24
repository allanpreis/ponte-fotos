import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

/// Local observations, not a promise of Photos import or round-trip compatibility.
struct PFMediaDiagnosticsResult: Sendable, Equatable {
    enum Preview: Sendable { case available, unavailable }
    enum HDR: Sendable { case pq, hlg, unknown }
    let fileExtension: String
    let declaredTypeIdentifier: String?
    let detectedTypeIdentifier: String?
    let preview: Preview
    let colorModel: String?
    let bitDepth: Int?
    let colorProfile: String?
    let transferFunction: String?
    let colorPrimaries: String?
    let hdr: HDR
    let failureReason: String?

    var formatLabel: String {
        if let detectedTypeIdentifier {
            return UTType(detectedTypeIdentifier)?.preferredFilenameExtension?.uppercased() ?? detectedTypeIdentifier.uppercased()
        }
        return L("Não determinado")
    }

    var messages: [PFMessage] {
        var messages: [PFMessage] = [M("Formato: \(formatLabel)")]
        if !fileExtension.isEmpty { messages.append(M("Extensão do nome: \(fileExtension.uppercased())")) }
        if let failureReason { messages.append(M("Inspeção incompleta: \(failureReason)")) }
        messages.append(preview == .available
            ? M("Prévia local disponível; importação no Fotos ainda não verificada.")
            : M("Prévia local indisponível; isso não determina se o Fotos aceita o original."))
        if let colorModel { messages.append(M("Modelo de cor: \(colorModel)")) }
        if let bitDepth { messages.append(M("Profundidade declarada: \(bitDepth) bits")) }
        if let colorProfile { messages.append(M("Perfil de cor: \(colorProfile)")) }
        if let transferFunction { messages.append(M("Função de transferência: \(transferFunction)")) }
        if let colorPrimaries { messages.append(M("Primárias de cor: \(colorPrimaries)")) }
        switch hdr {
        case .pq: messages.append(M("Sinalização HDR PQ detectada; reprodução e preservação no Fotos não verificadas."))
        case .hlg: messages.append(M("Sinalização HDR HLG detectada; reprodução e preservação no Fotos não verificadas."))
        case .unknown: messages.append(M("HDR não determinado por esta inspeção; ausência de sinalização não comprova SDR."))
        }
        messages.append(M("Dolby Vision e câmera lenta: compatibilidade não verificada."))
        return messages
    }
}

enum PFMediaDiagnostics {
    /// Reads only local files. Thumbnail decoding is bounded and never rewrites the original.
    static func inspect(url: URL, isVideo: Bool) async -> PFMediaDiagnosticsResult {
        guard url.isFileURL else { return result(url: url, failure: L("A inspeção aceita somente arquivos locais.")) }
        if isVideo { return await inspectVideo(url) }
        return await Task.detached(priority: .utility) { inspectImage(url) }.value
    }

    private static func result(url: URL, detectedType: String? = nil,
                               preview: PFMediaDiagnosticsResult.Preview = .unavailable,
                               colorModel: String? = nil, depth: Int? = nil, profile: String? = nil,
                               transfer: String? = nil, primaries: String? = nil, failure: String? = nil) -> PFMediaDiagnosticsResult {
        let ext = url.pathExtension.lowercased()
        // UTType recognizes a declared extension, not the bytes or decoder capability.
        let declared = ext.isEmpty ? nil : UTType(filenameExtension: ext)?.identifier
        return PFMediaDiagnosticsResult(fileExtension: ext, declaredTypeIdentifier: declared,
            detectedTypeIdentifier: detectedType, preview: preview, colorModel: colorModel,
            bitDepth: depth, colorProfile: profile, transferFunction: transfer, colorPrimaries: primaries,
            hdr: hdr(transferFunction: transfer), failureReason: failure)
    }

    static func hdr(transferFunction: String?) -> PFMediaDiagnosticsResult.HDR {
        if transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return .pq }
        if transferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { return .hlg }
        return .unknown
    }

    private static func inspectImage(_ url: URL) -> PFMediaDiagnosticsResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return result(url: url, failure: L("O original não pôde ser lido pelo decodificador de imagens deste Mac.")) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
        return result(url: url, detectedType: CGImageSourceGetType(source) as String?,
            preview: thumbnail == nil ? .unavailable : .available,
            colorModel: properties[kCGImagePropertyColorModel] as? String,
            depth: (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue,
            profile: properties[kCGImagePropertyProfileName] as? String,
            failure: thumbnail == nil ? L("A prévia não pôde ser decodificada neste Mac.") : nil)
    }

    private static func inspectVideo(_ url: URL) async -> PFMediaDiagnosticsResult {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return result(url: url, failure: L("Nenhuma faixa de vídeo legível foi encontrada.")) }
            let descriptions = try await track.load(.formatDescriptions)
            let description = descriptions.first
            let extensions = description.flatMap { CMFormatDescriptionGetExtensions($0) } as NSDictionary?
            let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction] as? String
            let primaries = extensions?[kCMFormatDescriptionExtension_ColorPrimaries] as? String
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 256, height: 256)
            generator.appliesPreferredTrackTransform = true
            let preview: PFMediaDiagnosticsResult.Preview
            var previewFailure: String?
            do { _ = try await generator.image(at: .zero); preview = .available }
            catch { preview = .unavailable; previewFailure = error.localizedDescription }
            let codec = description.map { CMFormatDescriptionGetMediaSubType($0) }
            let label = codec.map { value -> String in
                let bytes = [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
                return String(bytes: bytes, encoding: .ascii) ?? String(value)
            }
            return result(url: url, detectedType: label, preview: preview, transfer: transfer, primaries: primaries, failure: previewFailure)
        } catch { return result(url: url, failure: error.localizedDescription) }
    }
}
