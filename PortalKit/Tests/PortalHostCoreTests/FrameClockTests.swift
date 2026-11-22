#if os(macOS)
import XCTest
@testable import PortalHostCore

final class FrameClockTests: XCTestCase {
    private let gap: UInt64 = 16_666_667

    private func clock(pushes n: Int, spacing: UInt64? = nil, slowAt: Int? = nil, slow: UInt64 = 41_000_000) -> FrameClock {
        var c = FrameClock()
        var t: UInt64 = 1_000_000_000
        for i in 0..<n {
            c.push(captureNs: t)
            t += (i == slowAt) ? slow : (spacing ?? gap)
        }
        return c
    }

    func testSixtyEvenFramesAreSixtyFps() throws {
        var c = clock(pushes: 60)
        let r = try XCTUnwrap(c.take())
        XCTAssertEqual(r.fps, 60, accuracy: 0.5)
        XCTAssertEqual(r.meanMs, 16.7, accuracy: 0.1)
        XCTAssertEqual(r.p95Ms, 16.7, accuracy: 0.1)
        XCTAssertEqual(r.maxMs, 16.7, accuracy: 0.1)
    }

    func testOneLongGapShowsInTheMaxNotInTheP95() throws {
        var c = clock(pushes: 60, slowAt: 30)
        let r = try XCTUnwrap(c.take())
        XCTAssertEqual(r.maxMs, 41, accuracy: 0.1)
        XCTAssertLessThan(r.p95Ms, 20)
    }

    func testOnePushIsNoMeasurement() {
        var c = clock(pushes: 1)
        XCTAssertNil(c.take())
        var none = FrameClock()
        XCTAssertNil(none.take())
    }

    func testTakeResetsTheGapsNotTheLastFrame() throws {
        var c = clock(pushes: 60)
        XCTAssertNotNil(c.take())
        XCTAssertNil(c.take(), "a second take without new frames has nothing")
        c.push(captureNs: 5)
        XCTAssertNil(c.take(), "a time that does not advance is ignored")
    }

    /// A stall that crosses a reading is kept: the gap from the last frame before it to the first after it is the max.
    func testAStallLongerThanASecondShowsAsALargeMaxNotAsNothing() throws {
        var c = clock(pushes: 60)
        _ = c.take()
        let last: UInt64 = 1_000_000_000 + 59 * gap
        c.push(captureNs: last + 2_500_000_000)  // the next frame after a 2.5 s stall
        c.push(captureNs: last + 2_500_000_000 + gap)
        let r = try XCTUnwrap(c.take())
        XCTAssertEqual(r.maxMs, 2500, accuracy: 1)
        XCTAssertLessThan(r.fps, 2, "two frames in 2.5 s")
    }

    func testRestartForgetsTheLastFrameSoAPauseIsNotAGap() throws {
        var c = clock(pushes: 60)
        _ = c.take()
        c.restart()
        c.push(captureNs: 90_000_000_000)
        c.push(captureNs: 90_000_000_000 + gap)
        let r = try XCTUnwrap(c.take())
        XCTAssertEqual(r.maxMs, 16.7, accuracy: 0.1)
    }

    func testAFrameThatGoesBackwardsOrRepeatsIsIgnored() throws {
        var c = FrameClock()
        for t: UInt64 in [100_000_000, 116_666_667, 116_666_667, 50_000_000, 133_333_334] { c.push(captureNs: t) }
        let r = try XCTUnwrap(c.take())
        XCTAssertEqual(r.maxMs, 16.7, accuracy: 0.1)
    }

    func testMemoryIsBoundedWhateverTheFrameCount() {
        var c = FrameClock()
        for i in 0..<1_000_000 { c.push(captureNs: UInt64(i) * 1_000_000) }
        XCTAssertLessThanOrEqual(c.retained, FrameClock.capacity)
        XCTAssertNotNil(c.take())
    }
}
#endif
