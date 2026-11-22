#if os(macOS)
import XCTest
import PortalKit
@testable import PortalHostCore

final class ResendStoreTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    private func frags(_ frame: UInt32, _ n: Int = 5, payload: Int = 100) -> [VideoFragment] {
        (0..<n).map { VideoFragment(frame: frame, index: UInt16($0), count: UInt16(n), key: false, captureNs: UInt64(frame),
                                    width: 64, height: 64, payload: Data(repeating: UInt8(truncatingIfNeeded: $0), count: payload)) }
    }

    private func store(_ s: inout ResendStore, _ fs: [VideoFragment], at now: UInt64) { for f in fs { s.keep(f, nowNs: now) } }

    func testReturnsOnlyTheAskedIndices() {
        var s = ResendStore()
        store(&s, frags(7), at: 0)
        XCTAssertEqual(s.fragments(frame: 7, indices: [3, 1]), [frags(7)[3], frags(7)[1]])
        XCTAssertEqual(s.fragments(frame: 7, indices: []), frags(7), "none = the whole frame")
        XCTAssertEqual(s.fragments(frame: 7, indices: [5, 900]), [], "indices past the frame")
        XCTAssertEqual(s.fragments(frame: 8, indices: [0]), [], "unknown frame")
    }

    func testHoldsHalfASecond() {
        var s = ResendStore()
        store(&s, frags(1), at: 0)
        store(&s, frags(2), at: 490 * ms)
        XCTAssertEqual(s.fragments(frame: 1, indices: [0]).count, 1)
        store(&s, frags(3), at: 501 * ms)
        XCTAssertEqual(s.fragments(frame: 1, indices: [0]), [], "older than 0.5 s")
        XCTAssertEqual(s.fragments(frame: 2, indices: [0]).count, 1)
        XCTAssertEqual(s.resend(frame: 2, indices: [0], nowNs: 991 * ms), [], "expired at the time of the ask")
    }

    func testBoundedBySize() {
        var s = ResendStore(maxBytes: 10_000)
        for n in UInt32(0)..<30 { store(&s, frags(n, payload: 1000), at: UInt64(n) * ms) }
        XCTAssertLessThanOrEqual(s.bytes, 10_000)
        XCTAssertEqual(s.fragments(frame: 29, indices: []).count, 5, "the newest stays")
        XCTAssertEqual(s.fragments(frame: 0, indices: []), [], "the oldest went")
    }

    func testOneResendOfAFragmentPer4ms() {
        var s = ResendStore()
        store(&s, frags(1), at: 0)
        XCTAssertEqual(s.resend(frame: 1, indices: [0, 1], nowNs: 10 * ms).count, 2)
        XCTAssertEqual(s.resend(frame: 1, indices: [0, 1, 2], nowNs: 13 * ms), [frags(1)[2]])
        XCTAssertEqual(s.resend(frame: 1, indices: [0, 0, 0], nowNs: 14 * ms), [frags(1)[0]], "a repeated index once")
        XCTAssertEqual(s.refused.tooSoon, 4)
    }

    func testHostileAsksAreBoundedAndCounted() {
        var s = ResendStore()
        store(&s, frags(1, 1000, payload: 10), at: 0)
        XCTAssertEqual(s.resend(frame: 1, indices: [], nowNs: ms).count, ResendStore.maxPerNack)
        XCTAssertEqual(s.refused.overLimit, 1)
        XCTAssertEqual(s.resend(frame: 1, indices: [1000, 65_535], nowNs: 10 * ms), [])
        XCTAssertEqual(s.refused.badIndex, 2)
        XCTAssertEqual(s.resend(frame: 99, indices: [0], nowNs: 10 * ms), [])
        XCTAssertEqual(s.refused.unknownFrame, 1)
    }

    func testResendsStayWithinTheBudget() {
        let rate: UInt32 = 8_000_000  // 1 MB/s, depth 0.2 MB
        var s = ResendStore(bitsPerSecond: rate)
        for n in UInt32(0)..<30 { store(&s, frags(n, 37, payload: 1000), at: 0) }
        var sent = 0
        var now: UInt64 = ms
        while now <= 400 * ms {
            for n in UInt32(0)..<30 { sent += s.resend(frame: n, indices: [], nowNs: now).reduce(0) { $0 + $1.payload.count } }
            now += 4 * ms
        }
        let bound = 1_000_000 * 0.4 + 200_000
        XCTAssertLessThanOrEqual(Double(sent), bound)
        XCTAssertGreaterThan(Double(sent), 0.8 * bound, "the budget is spent, not refused outright")
        XCTAssertGreaterThan(s.refused.overBudget, 0)
    }

    func testClear() {
        var s = ResendStore()
        store(&s, frags(1), at: 0)
        s.clear()
        XCTAssertEqual(s.fragments(frame: 1, indices: []), [])
        XCTAssertEqual(s.bytes, 0)
    }

    func testAFrameNumberSeenAgainReplacesTheOldFrame() {
        var s = ResendStore()
        store(&s, frags(1, 5), at: 0)
        store(&s, frags(1, 2, payload: 7), at: ms)
        XCTAssertEqual(s.fragments(frame: 1, indices: []), frags(1, 2, payload: 7))
        XCTAssertEqual(s.bytes, 14)
    }

    /// A frame the sender dropped unsent is gone from the store: a `nack` for it finds nothing.
    func testADiscardedFrameIsNotHeld() {
        var store = ResendStore()
        for f in frags(7) { store.keep(f, nowNs: ms) }
        store.discard(frame: 7)
        XCTAssertEqual(store.resend(frame: 7, indices: [0], nowNs: 2 * ms), [])
        XCTAssertEqual(store.refused.unknownFrame, 1)
        XCTAssertEqual(store.bytes, 0)
    }
}
#endif
