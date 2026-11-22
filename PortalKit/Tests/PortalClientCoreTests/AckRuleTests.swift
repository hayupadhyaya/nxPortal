import Foundation
import XCTest
@testable import PortalClientCore
import PortalKit

/// `ack(frame)` for decoded frames: at most one every 33 ms, plus one for every key and repair frame -> .claude/client.md § repair
final class AckRuleTests: XCTestCase {
    private func frame(_ n: UInt32, key: Bool = false, repair: Bool = false) -> AssembledFrame {
        AssembledFrame(frame: n, key: key, repair: repair, captureNs: UInt64(n), width: 64, height: 64, data: Data([0]))
    }

    /// Ten frames decoded inside 33 ms give one `ack`; a key frame and a repair frame among them give one more each.
    func testTenFramesInside33msGiveOneAckPlusOneForAKeyAndOneForARepairFrame() async throws {
        let s = ClientSession(identity: Identity(), name: "Test Client", kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                              replyTimeout: 5)
        let start = Date()
        for n in UInt32(1)...10 { await s.frameDecoded(frame(n)) }
        let plain = await s.stats().acksSent
        await s.frameDecoded(frame(11, key: true))
        await s.frameDecoded(frame(12, repair: true))
        let all = await s.stats().acksSent
        let took = Date().timeIntervalSince(start)
        try XCTSkipIf(took >= 0.033, "the 12 calls took \(took) s")  // the rule is about 33 ms; a slow machine proves nothing
        XCTAssertEqual(plain, 1, "ten frames inside 33 ms")
        XCTAssertEqual(all, 3, "the key frame and the repair frame are always acknowledged")
    }
}
