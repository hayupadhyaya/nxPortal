import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import PortalKit

public struct DecodedFrame: @unchecked Sendable {
    public let frame: UInt32, captureNs: UInt64, pixelBuffer: CVPixelBuffer
}

/// HEVC frames (length-prefixed NAL units) to pixel buffers -> .claude/client.md § decode
public final class VideoDecoder: @unchecked Sendable {
    private struct Format: Equatable {
        var vps: Data, sps: Data, pps: Data, width: UInt16, height: UInt16
    }
    /// Receives the picture from the output handler, which runs before `decode` returns.
    private final class DecodeResult: @unchecked Sendable {
        var status: OSStatus = 0
        var pixelBuffer: CVPixelBuffer?
    }

    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: Format?
    private var formatDescription: CMVideoFormatDescription?
    private var _lastDecodeNs: UInt64 = 0

    public init() {}

    /// How long the newest `decode` that produced a picture took (nanoseconds, session setup included).
    public var lastDecodeNs: UInt64 { lock.withLock { _lastDecodeNs } }

    deinit { teardown() }

    /// Decodes synchronously, in call order. nil: not decodable (the caller requests a key frame).
    public func decode(_ frame: AssembledFrame) -> DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        let began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard let nals = HEVC.nalUnits(frame.data), !nals.isEmpty, !nals.contains(where: \.isEmpty) else { fail(); return nil }
        if frame.key {
            guard let sets = HEVC.parameterSets(frame.data) else { fail(); return nil }
            let wanted = Format(vps: sets.vps, sps: sets.sps, pps: sets.pps, width: frame.width, height: frame.height)
            if session == nil || format != wanted {
                teardown()
                guard makeSession(wanted) else { return nil }
            }
        }
        guard let session, let formatDescription else { return nil }

        // Parameter sets live in the format description; the sample carries the picture NAL units only.
        var body = Data(capacity: frame.data.count)
        for n in nals {
            let type = (n[n.startIndex] >> 1) & 0x3F
            if (32...34).contains(type) { continue }
            body.append(contentsOf: withUnsafeBytes(of: UInt32(n.count).bigEndian, Array.init))
            body.append(n)
        }
        guard !body.isEmpty, let sample = makeSample(body, formatDescription) else { fail(); return nil }

        let result = DecodeResult()
        let rc = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { status, _, image, _, _ in
            result.status = status
            result.pixelBuffer = image
        }
        guard rc == noErr, result.status == noErr, let pb = result.pixelBuffer else { fail(); return nil }
        _lastDecodeNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- began
        return DecodedFrame(frame: frame.frame, captureNs: frame.captureNs, pixelBuffer: pb)
    }

    /// Drops the session; the next key frame starts a new one.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        teardown()
    }

    // MARK: - Private (lock held)

    private func fail() { teardown() }

    private func teardown() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; formatDescription = nil
    }

    private func makeSession(_ f: Format) -> Bool {
        var desc: CMVideoFormatDescription?
        let rc = f.vps.withUnsafeBytes { v in f.sps.withUnsafeBytes { s in f.pps.withUnsafeBytes { p in
            let ptrs = [v, s, p].map { $0.bindMemory(to: UInt8.self).baseAddress! }
            let sizes = [f.vps.count, f.sps.count, f.pps.count]
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: 3, parameterSetPointers: ptrs, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
        } } }
        guard rc == noErr, let desc else { return false }
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        guard dims.width == Int32(f.width), dims.height == Int32(f.height) else { return false }

        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [String: String](),
        ]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
            allocator: nil, formatDescription: desc, decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s) == noErr,
              let s else { return false }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s; format = f; formatDescription = desc
        return true
    }

    private func makeSample(_ body: Data, _ desc: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: body.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: body.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = body.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: body.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = body.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: desc, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
