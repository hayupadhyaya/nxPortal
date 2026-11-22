#if os(macOS)
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// One HEVC `VTCompressionSession` with long-term references (as the tap's), driven from a single thread; every
/// encode gets exactly one `sink` call, on VideoToolbox's thread (or at once when the encode is refused).
/// `@unchecked`: the session and `index` are touched only from the one encoding thread (`FakeGame`'s video loop).
final class FakeEncoder: @unchecked Sendable {
    /// What a frame was asked to be: a key frame, the answer to a refresh, predicted from an acknowledged frame
    /// (`ForceLTRRefresh`), carrying these acknowledged encoder tokens.
    struct Request: Sendable { var key = false, refresh = false, ltrRefresh = false, acks: [Int32] = [] }
    /// `status` non-zero: the encode failed; `data` nil with status 0: dropped. `token`: the encoder's, -1 = none.
    struct Output: Sendable {
        var request: Request, captureNs: UInt64, status: OSStatus, key: Bool, token: Int32, data: Data?
    }
    typealias Sink = @Sendable (Output) -> Void

    let width: Int
    let height: Int
    /// `EnableLTR` was accepted for this session.
    let ltr: Bool
    private let fps: Int
    private let session: VTCompressionSession
    private let sink: Sink
    private var index: Int64 = 0

    init?(width: Int, height: Int, fps: Int, bitrate: Int, ltr wantLTR: Bool = true, sink: @escaping Sink) {
        var s: VTCompressionSession?
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        let rc = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard rc == noErr, let s else { return nil }
        session = s
        self.width = width; self.height = height; self.fps = fps; self.sink = sink
        let props: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int32.max)),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel),
        ]
        for (k, v) in props { VTSessionSetProperty(s, key: k, value: v) }
        ltr = wantLTR && VTSessionSetProperty(s, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue) == noErr
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    /// A BGRA buffer of one colour (0xAARRGGBB).
    func encode(color: UInt32, request: Request, captureNs: UInt64) {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [String: String]()] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let pb else { return sink(Output(request: request, captureNs: captureNs, status: -1, key: false, token: -1, data: nil)) }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let stride = CVPixelBufferGetBytesPerRow(pb)
            var pattern = color
            for y in 0..<height { memset_pattern4(base + y * stride, &pattern, width * 4) }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let pts = CMTime(value: index, timescale: Int32(fps))
        index += 1
        var props: [CFString: Any] = [:]
        if request.key { props[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        if !request.acks.isEmpty { props[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = request.acks.map { NSNumber(value: $0) } }
        if request.ltrRefresh { props[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true }
        let sink = self.sink
        let rc = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props.isEmpty ? nil : props as CFDictionary, infoFlagsOut: nil
        ) { status, flags, sample in
            var out = Output(request: request, captureNs: captureNs, status: status, key: false, token: -1, data: nil)
            if status == noErr, !flags.contains(.frameDropped), let sample, let wire = Self.wireData(sample) {
                out.key = wire.key; out.token = wire.token; out.data = wire.bytes
            }
            sink(out)
        }
        if rc != noErr { sink(Output(request: request, captureNs: captureNs, status: rc, key: false, token: -1, data: nil)) }
    }

    func finish() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    /// Length-prefixed NAL units; a key frame starts with VPS, SPS, PPS. The token: the frame's long-term-reference
    /// acknowledgement token, -1 when it has none.
    private static func wireData(_ sample: CMSampleBuffer) -> (key: Bool, token: Int32, bytes: Data)? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var key = true, token: Int32 = -1
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first {
            if first[kCMSampleAttachmentKey_NotSync] as? Bool == true { key = false }
            if let t = (first[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? NSNumber)?.int32Value, t >= 0 { token = t }
        }
        var out = Data()
        if key, let fd = CMSampleBufferGetFormatDescription(sample) {
            for i in 0..<3 {
                var p: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fd, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p else { return nil }
                out.append(contentsOf: withUnsafeBytes(of: UInt32(size).bigEndian, Array.init))
                out.append(p, count: size)
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var body = Data(count: length)
        let rc = body.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard rc == kCMBlockBufferNoErr else { return nil }
        out.append(body)
        return (key, token, out)
    }
}
#endif
