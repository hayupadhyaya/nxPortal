import XCTest
@testable import PortalKit

final class VideoTests: XCTestCase {
    private func bytes(_ n: Int, seed: UInt8 = 7) -> Data {
        Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    func testSplitSizes() {
        let frags = FrameSplitter.split(frame: 5, key: true, captureNs: 1, width: 640, height: 360, data: bytes(50_000))
        XCTAssertEqual(frags.count, 44)
        for (i, f) in frags.enumerated() {
            XCTAssertEqual(Int(f.index), i)
            XCTAssertEqual(f.count, 44)
            XCTAssertLessThanOrEqual(f.payload.count, Wire.maxVideoPayload)
            if i < 43 { XCTAssertEqual(f.payload.count, Wire.maxVideoPayload) }
            XCTAssertEqual(f.frame, 5)
            XCTAssertTrue(f.key)
        }
        XCTAssertEqual(frags.reduce(0) { $0 + $1.payload.count }, 50_000)
    }

    func testEmptyFrameIsOneFragment() {
        let frags = FrameSplitter.split(frame: 1, key: false, captureNs: 1, width: 2, height: 2, data: Data())
        XCTAssertEqual(frags.count, 1)
        XCTAssertEqual(frags[0].count, 1)
        XCTAssertTrue(frags[0].payload.isEmpty)
    }

    private func nal(_ type: UInt8, _ body: [UInt8]) -> Data {
        let n = [type << 1, 1] + body
        var d = Data([0, 0, 0, UInt8(n.count)])
        d.append(contentsOf: n)
        return d
    }

    func testHEVC() {
        let parts = [nal(32, [1, 2]), nal(33, [3]), nal(34, [4, 5, 6]), nal(19, [9, 9, 9, 9])]
        let buf = parts.reduce(Data(), +)
        XCTAssertEqual(HEVC.nalUnits(buf)?.count, 4)
        let ps = HEVC.parameterSets(buf)
        XCTAssertEqual(ps?.vps, parts[0].dropFirst(4))
        XCTAssertEqual(ps?.sps, parts[1].dropFirst(4))
        XCTAssertEqual(ps?.pps, parts[2].dropFirst(4))
        var expected = Data()
        for p in parts { expected.append(contentsOf: [0, 0, 0, 1]); expected.append(p.dropFirst(4)) }
        XCTAssertEqual(HEVC.annexB(buf), expected)

        var bad = buf; bad.append(contentsOf: [0, 0, 0, 50, 1])
        XCTAssertNil(HEVC.nalUnits(bad))
        XCTAssertNil(HEVC.parameterSets(bad))
        XCTAssertTrue(HEVC.annexB(bad).isEmpty)
        XCTAssertNil(HEVC.nalUnits(Data([0, 0, 1])))
        XCTAssertEqual(HEVC.nalUnits(Data()), [])
        XCTAssertNil(HEVC.parameterSets(parts[0] + parts[3]))
    }
}
