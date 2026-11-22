#if os(macOS)
import XCTest
import CoreMedia
import CoreVideo
import PortalKit
@testable import PortalPlayer
@testable import PortalTestSupport

final class VideoDecoderTests: XCTestCase {
    private static let white: UInt32 = 0xFFFF_FFFF
    private static let black: UInt32 = 0xFF00_0000

    /// Frames as the client session would deliver them: one `FakeEncoder`, `(color, key)` per frame.
    private func makeFrames(width: Int = 1280, height: Int = 720, _ plan: [(UInt32, Bool)], firstFrame: UInt32 = 0) -> [AssembledFrame] {
        let lock = NSLock()
        nonisolated(unsafe) var out: [(UInt64, Bool, Data)] = []
        guard let enc = FakeEncoder(width: width, height: height, fps: 60, bitrate: 4_000_000, sink: { o in
            lock.lock(); out.append((o.captureNs, o.key, o.data ?? Data())); lock.unlock()
        }) else { XCTFail("encoder"); return [] }
        for (i, p) in plan.enumerated() { enc.encode(color: p.0, request: .init(key: p.1), captureNs: 1_000 + UInt64(i) * 16_000) }
        enc.finish()
        lock.lock(); defer { lock.unlock() }
        return out.enumerated().map { i, f in
            AssembledFrame(frame: firstFrame + UInt32(i), key: f.1, captureNs: f.0,
                           width: UInt16(width), height: UInt16(height), data: f.2)
        }
    }

    private func centreLuma(_ pb: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        return Int(base[CVPixelBufferGetHeightOfPlane(pb, 0) / 2 * stride + CVPixelBufferGetWidthOfPlane(pb, 0) / 2])
    }

    func testDecodesKeyThenDeltas() {
        let plan: [(UInt32, Bool)] = (0..<20).map { ($0 < 10 ? Self.white : Self.black, $0 == 0) }
        let frames = makeFrames(plan)
        XCTAssertEqual(frames.count, 20)
        XCTAssertTrue(frames[0].key)
        let dec = VideoDecoder()
        var out: [DecodedFrame] = []
        for f in frames {
            guard let d = dec.decode(f) else { XCTFail("frame \(f.frame) not decoded"); return }
            XCTAssertEqual(d.frame, f.frame); XCTAssertEqual(d.captureNs, f.captureNs)
            XCTAssertEqual(CVPixelBufferGetWidth(d.pixelBuffer), 1280)
            XCTAssertEqual(CVPixelBufferGetHeight(d.pixelBuffer), 720)
            out.append(d)
        }
        XCTAssertEqual(out.count, 20)
        XCTAssertEqual(Double(centreLuma(out[9].pixelBuffer)), 235, accuracy: 6)
        XCTAssertEqual(Double(centreLuma(out[19].pixelBuffer)), 16, accuracy: 6)
    }

    /// The padded fake game appends a filler-data NAL unit to every frame; the decoder must not mind.
    func testFillerNALUnitsAreIgnored() {
        let plan: [(UInt32, Bool)] = (0..<10).map { ($0 < 5 ? Self.white : Self.black, $0 == 0) }
        let frames = makeFrames(plan).map { f -> AssembledFrame in
            var g = f
            g.data.append(FakeGame.fillerNAL(room: f.key ? 20_000 : 5_000))
            return g
        }
        let dec = VideoDecoder()
        for f in frames { XCTAssertNotNil(dec.decode(f), "frame \(f.frame) with filler not decoded") }
        XCTAssertGreaterThan(frames[3].data.count, 5_000)
    }

    func testDeltaBeforeKeyReturnsNil() {
        let frames = makeFrames([(Self.white, true), (Self.white, false)])
        XCTAssertNil(VideoDecoder().decode(frames[1]))
    }

    func testSizeChange() {
        let big = makeFrames([(Self.white, true), (Self.white, false)])
        let small = makeFrames(width: 640, height: 360, [(Self.black, true)], firstFrame: 10)
        let dec = VideoDecoder()
        for f in big { XCTAssertNotNil(dec.decode(f)) }
        guard let d = dec.decode(small[0]) else { return XCTFail("small key not decoded") }
        XCTAssertEqual(CVPixelBufferGetWidth(d.pixelBuffer), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(d.pixelBuffer), 360)
    }

    /// Well-formed framing (length prefix, NAL header) around a random payload: only VideoToolbox can reject it.
    private func corrupted(_ f: AssembledFrame) -> AssembledFrame {
        var data = f.data
        for i in 6..<data.count { data[i] = UInt8.random(in: 0...255) }
        return AssembledFrame(frame: f.frame, key: false, captureNs: f.captureNs, width: f.width, height: f.height, data: data)
    }

    func testGarbageThenRecovery() {
        let frames = makeFrames([(Self.white, true), (Self.white, false), (Self.black, false), (Self.black, true)])
        let dec = VideoDecoder()
        XCTAssertNotNil(dec.decode(frames[0]))
        XCTAssertNotNil(HEVC.nalUnits(corrupted(frames[1]).data), "framing must stay valid")
        XCTAssertNil(dec.decode(corrupted(frames[1])))
        XCTAssertNil(dec.decode(frames[2]))
        XCTAssertNotNil(dec.decode(frames[3]))
    }

    func testEmptyNalUnitReturnsNil() {
        let frames = makeFrames([(Self.white, true), (Self.white, false), (Self.black, false), (Self.black, true)])
        let unit = HEVC.nalUnits(frames[1].data)!.first!
        var bad = Data([0, 0, 0, 0])
        bad.append(contentsOf: withUnsafeBytes(of: UInt32(unit.count).bigEndian, Array.init))
        bad.append(unit)
        func frame(key: Bool) -> AssembledFrame {
            AssembledFrame(frame: 60, key: key, captureNs: 7, width: 1280, height: 720, data: bad)
        }
        let dec = VideoDecoder()
        XCTAssertNotNil(dec.decode(frames[0]))
        XCTAssertNil(dec.decode(frame(key: false)))
        XCTAssertNil(dec.decode(frames[2]))
        XCTAssertNotNil(dec.decode(frames[3]))
        XCTAssertNil(dec.decode(frame(key: true)))
    }

    /// 60 frames with long-term references on, each frame acknowledging the newest token of the frames before it
    /// (as acks flow); frames 30...33 never reach the decoder; frame 34 is encoded with `ltrRefresh` (or not, for the
    /// control). With the refresh, 34 is not a key frame and every frame from it on decodes; without, they do not.
    private func lostFramesThenRefresh(refresh: Bool) -> (decodedAfter: Int, failedAfter: Int, refreshWasKey: Bool) {
        let lock = NSLock()
        nonisolated(unsafe) var outs: [FakeEncoder.Output] = []
        guard let enc = FakeEncoder(width: 1280, height: 720, fps: 60, bitrate: 4_000_000, sink: { o in
            lock.withLock { outs.append(o) }
        }) else { XCTFail("encoder"); return (0, 0, false) }
        XCTAssertTrue(enc.ltr, "EnableLTR refused")
        for i in 0..<60 {
            var r = FakeEncoder.Request(key: i == 0)
            if i < 30, i > 0, let t = lock.withLock({ outs.last { $0.token >= 0 }?.token }) { r.acks = [t] }
            if i == 34 { r.refresh = refresh; r.ltrRefresh = refresh }
            enc.encode(color: i % 20 < 10 ? Self.white : Self.black, request: r, captureNs: 1_000 + UInt64(i) * 16_000)
            usleep(2_000)  // the encoder's output comes before the next frame's acknowledgement is chosen, as in a stream
        }
        enc.finish()
        let frames = lock.withLock { outs }.enumerated().map { i, o in
            AssembledFrame(frame: UInt32(i), key: o.key, captureNs: o.captureNs, width: 1280, height: 720, data: o.data ?? Data())
        }
        XCTAssertEqual(frames.count, 60)
        let dec = VideoDecoder()
        var decoded = 0, failed = 0
        for f in frames where !(30...33).contains(f.frame) {
            let ok = dec.decode(f) != nil
            if f.frame >= 34 { if ok { decoded += 1 } else { failed += 1 } } else { XCTAssertTrue(ok, "frame \(f.frame)") }
        }
        return (decoded, failed, frames.count > 34 && frames[34].key)
    }

    /// The brief's decode test: a repair frame predicted from an acknowledged frame decodes on a decoder that never got
    /// the frames lost before it, and so does every frame after it -> .claude/client.md § repair
    func testARepairFrameDecodesAfterLostFramesWithoutError() {
        let r = lostFramesThenRefresh(refresh: true)
        XCTAssertFalse(r.refreshWasKey, "the repair frame is a key frame")
        XCTAssertEqual(r.decodedAfter, 26)
        XCTAssertEqual(r.failedAfter, 0)
        let control = lostFramesThenRefresh(refresh: false)
        XCTAssertGreaterThan(control.failedAfter, 0, "without the refresh the frames after the loss decoded: the test proves nothing")
    }

    func testDisplaySampleIsImmediate() throws {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [String: String]()] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        let sample = try XCTUnwrap(DisplaySample.make(buffer))
        XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === buffer)
        let atts = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])
        let flag = atts.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool
        XCTAssertEqual(flag, true)
    }
}
#endif
