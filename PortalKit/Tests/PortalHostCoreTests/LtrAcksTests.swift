#if os(macOS)
import XCTest
import PortalKit
@testable import PortalHostCore

/// Which `ack(frame)` becomes an `ltrAck` -> .claude/host.md § ltr
final class LtrAcksTests: XCTestCase {
    private let s: UInt64 = 1_000_000_000

    private func filled(_ frames: ClosedRange<UInt32>, token: (UInt32) -> Int32, width: UInt16 = 1280) -> LtrAcks {
        var a = LtrAcks()
        for f in frames { a.frame(f, token: token(f), width: width, height: 720, nowNs: UInt64(f) * 16_000_000) }
        return a
    }

    /// The acknowledged frame's token, unchanged (epoch in the high bits); only a frame newer than the last acknowledged.
    func testAnAckOfAFrameWithATokenGivesThatToken() {
        var a = filled(0...20) { 0x0100_0000 | Int32($0) }
        XCTAssertEqual(a.ack(10, nowNs: s), 0x0100_000A)
        XCTAssertNil(a.ack(10, nowNs: s), "the same frame again")
        XCTAssertNil(a.ack(9, nowNs: s), "older than the last acknowledged")
        XCTAssertEqual(a.ack(12, nowNs: s), 0x0100_000C)
        XCTAssertEqual(a.lastAcked, 12)
    }

    /// A frame without a token (-1) or unknown gives nothing and does not move the last acknowledged frame.
    func testAFrameWithoutATokenIsNotAcknowledged() {
        var a = filled(0...20) { $0 % 14 == 0 ? Int32($0) : -1 }
        XCTAssertNil(a.ack(5, nowNs: s))
        XCTAssertNil(a.lastAcked)
        XCTAssertEqual(a.ack(14, nowNs: s), 14)
        XCTAssertNil(a.ack(300, nowNs: s), "never sent")
    }

    /// Kept 2 s: an ack of an older frame is ignored.
    func testAFrameOlderThanTwoSecondsIsForgotten() {
        var a = filled(0...20) { Int32($0) }
        XCTAssertNil(a.ack(1, nowNs: 16_000_000 + 2 * s + 1))
        XCTAssertEqual(a.ack(2, nowNs: 32_000_000 + 2 * s), 2)
    }

    /// Once a frame of a new picture size was seen, no frame of the earlier size is acknowledged.
    func testNoFrameOfAnEarlierSizeAfterTheNewSize() {
        var a = filled(0...10) { Int32($0) }
        a.frame(11, token: 0x0200_0000, width: 640, height: 720, nowNs: 11 * 16_000_000)
        XCTAssertNil(a.ack(10, nowNs: s))
        XCTAssertEqual(a.ack(11, nowNs: s), 0x0200_0000)
    }

    func testClearForgetsEverything() {
        var a = filled(0...10) { Int32($0) }
        XCTAssertEqual(a.ack(5, nowNs: s), 5)
        a.clear()
        XCTAssertNil(a.ack(6, nowNs: s))
        XCTAssertNil(a.lastAcked)
    }

    func testFrameSizeMedians() {
        var f = FrameSizes()
        for b in [10, 30, 20] { f.add(b, mark: .none) }
        f.add(40, mark: .key)
        XCTAssertEqual(f.median(.none), 20)
        XCTAssertEqual(f.median(.key), 40)
        XCTAssertEqual(f.median(.repair), 0)
        XCTAssertEqual(f.counts, [3, 1, 0])
    }
}
#endif
