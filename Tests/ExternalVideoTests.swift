import Foundation
import AVFoundation
import CoreVideo
@main struct ExternalVideoTests {
 static func main() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ponte-video-test-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let date = AVMutableMetadataItem(); date.identifier = .quickTimeMetadataCreationDate; date.value = "2020-04-05T15:30:00Z" as NSString; date.dataType = "com.apple.metadata.datatype.UTF-8"
    let gps = AVMutableMetadataItem(); gps.identifier = .quickTimeMetadataLocationISO6709; gps.value = "-23.5000-046.5000/" as NSString; gps.dataType = "com.apple.metadata.datatype.UTF-8"
    writer.metadata = [date,gps]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:16,kCVPixelBufferHeightKey as String:16])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault,16,16,kCVPixelFormatType_32ARGB,nil,&buffer) == kCVReturnSuccess)
    CVPixelBufferLockBaseAddress(buffer!,[])
    memset(CVPixelBufferGetBaseAddress(buffer!),0,CVPixelBufferGetDataSize(buffer!))
    CVPixelBufferUnlockBaseAddress(buffer!,[])
    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(adaptor.append(buffer!, withPresentationTime: .zero))
    writer.endSession(atSourceTime: CMTime(value:1,timescale:1)); input.markAsFinished()
    await writer.finishWriting()
    if let error = writer.error { throw error }
    let read = try await ExternalReader.read(url)
    precondition(read.metadata.date == CaptureMetadata.parse("2020-04-05T15:30:00Z"))
    precondition(read.metadata.latitude == -23.5 && read.metadata.longitude == -46.5)
    print("Vídeo MOV sintético: data QuickTime e GPS ISO6709 lidos corretamente.")
 }
}
