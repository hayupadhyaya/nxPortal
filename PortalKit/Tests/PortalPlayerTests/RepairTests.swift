#if os(macOS)
import XCTest
import PortalKit
import PortalHostCore
import PortalClientCore
import PortalTestSupport
@testable import PortalPlayer

/// The player's decoder for a scenario: the real `VideoDecoder`, one per run.
enum ScenarioDecoding {
    static let real: @Sendable () -> @Sendable (AssembledFrame) -> Bool = {
        let d = VideoDecoder()
        return { d.decode($0) != nil }
    }
}

/// Lock-guarded state for a `dropVideo` predicate.
final class DropPlan: @unchecked Sendable {
    private let lock = NSLock()  // guards every var below
    private let from: UInt32
    private var lost: UInt32?
    private var repairsLeft: Int
    private var dropped: Set<UInt32> = []
    private var firstRepairDropNs: UInt64?
    private var repairsDropped = 0

    /// Every fragment of the first frame numbered `from` or later (resends too: it is given up), and every fragment of
    /// the next `repairs` repair frames after it.
    init(from: UInt32, repairs: Int) { self.from = from; repairsLeft = repairs }

    func drop(_ f: VideoFragment) -> Bool {
        lock.withLock {
            if lost == nil, f.frame >= from { lost = f.frame }
            guard let lost, f.frame >= lost else { return false }
            if f.frame == lost || dropped.contains(f.frame) { return true }
            if f.repair, repairsLeft > 0 {
                repairsLeft -= 1
                if dropped.insert(f.frame).inserted { repairsDropped += 1 }
                if firstRepairDropNs == nil { firstRepairDropNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
                return true
            }
            return false
        }
    }

    var lostFrame: UInt32? { lock.withLock { lost } }
    var repairDroppedAtNs: UInt64? { lock.withLock { firstRepairDropNs } }
    /// Distinct repair frames dropped.
    var repairFramesDropped: Int { lock.withLock { repairsDropped } }
}

/// A frame given up is repaired from a long-term reference, end to end with the real decoder -> .claude/client.md § repair
final class RepairTests: XCTestCase {
    /// One frame lost for good on a clean link: one repair frame restarts the picture, no key frame after the first,
    /// nothing escalated, nothing the decoder refused; acknowledgements flow at most 30 a second (plus key and repair
    /// frames).
    func testALostFrameIsRepairedWithoutAKeyFrame() async throws {
        let plan = DropPlan(from: 150, repairs: 0)
        let r = try await StreamScenario.run(decoder: ScenarioDecoding.real, profile: .clean, seconds: 4,
                                             dropVideo: { plan.drop($0) })
        print(r.line("one lost frame") + " refreshes=\(r.stats.refreshes) waited=\(r.stats.framesWaited) acks=\(r.ltrAcks) "
              + "bytes=\(r.medianBytes) log=\(r.hostLog.filter { !$0.hasPrefix("config") })")
        XCTAssertNotNil(plan.lostFrame)
        XCTAssertEqual(r.keyFrames, 1, r.line("one lost frame"))
        XCTAssertGreaterThanOrEqual(r.repairFrames, 1)
        XCTAssertEqual(r.stats.refreshes, 1, "restarts at a repair frame")
        XCTAssertEqual(r.stats.escalations, 0)
        XCTAssertEqual(r.decodeErrors, 0)
        XCTAssertTrue(r.hostLog.contains("refresh"), "\(r.hostLog)")
        XCTAssertFalse(r.hostLog.contains("keyframe"), "\(r.hostLog)")
        XCTAssertLessThan(r.longestGapMs, 150)
        XCTAssertGreaterThan(r.ltrAcks, 0)
        XCTAssertLessThanOrEqual(Double(r.ltrAcks), 31 * 5.5, "more than 30 acknowledgements a second")
        XCTAssertTrue(r.inOrder)
    }

    /// The fake client's decode loop (`portal-fakeclient --decode`) is a player to the game: it acknowledges decoded
    /// frames, so a lost frame is repaired with a repair frame, not a key frame.
    func testTheFakeClientsDecodeLoopGetsAcknowledgementsAndARepairFrame() async throws {
        let plan = DropPlan(from: 150, repairs: 0)
        let r = try await StreamScenario.run(profile: .clean, seconds: 4, dropVideo: { plan.drop($0) },
                                             consume: { session, frames in
            await DecodeReport.run(frames: frames, session: session, decoder: VideoDecoder())
        })
        print(r.line("fakeclient decode") + " acks=\(r.ltrAcks)")
        XCTAssertNotNil(plan.lostFrame)
        XCTAssertGreaterThan(r.ltrAcks, 0, "the game was never acknowledged a frame")
        XCTAssertGreaterThanOrEqual(r.repairFrames, 1, r.line("fakeclient decode"))
        XCTAssertEqual(r.keyFrames, 1, "only the first key frame: a second means a repair was answered with a key frame")
        XCTAssertFalse(r.hostLog.contains("keyframe"), "\(r.hostLog)")
        XCTAssertEqual(r.stats.escalations, 0)
    }

    /// Every repair frame lost: `repair` is asked again every 35 ms, each one answered with a repair frame (none swallowed
    /// on the way), and only 1 s after the first with no restart point does the client ask for a key frame (the safety
    /// net), which restarts the picture.
    func testRepairFramesThatNeverArriveAreAskedAgainThenAKeyFrameAfterOneSecond() async throws {
        let plan = DropPlan(from: 150, repairs: 1000)
        let r = try await StreamScenario.run(decoder: ScenarioDecoding.real, profile: .clean, seconds: 5,
                                             dropVideo: { plan.drop($0) })
        let refreshes = r.hostLog.filter { $0 == "refresh" }.count
        print(r.line("repairs lost") + " keyRequests=\(r.stats.keyRequests) repairs=\(r.stats.repairRequests)"
              + " refreshes=\(refreshes) repairFramesLost=\(plan.repairFramesDropped)")
        XCTAssertEqual(r.stats.escalations, 1)
        // The escalation's key frame; the encoder may also answer one of some 25 refreshes in a row with no new
        // acknowledgement with a key frame (the game's guard then forces one more) -> .claude/client.md § repair
        XCTAssertTrue((2...3).contains(r.keyFrames), r.line("repairs lost"))
        // 1 s at one `repair` every 35 ms: 28 or so (the timer's 8 ms steps make it 35...43 ms).
        XCTAssertTrue((22...30).contains(r.stats.repairRequests), "repairs sent before the escalation: \(r.stats.repairRequests)")
        XCTAssertEqual(refreshes, r.stats.repairRequests, "a repair the Host did not pass on")
        // Every refresh is answered by a new repair frame or served by one already due (the game counts the second kind);
        // the repair frames dropped are the first kind, up to the one or two still on their way when the run is read.
        let answered = r.stats.repairRequests - r.refreshesCoalesced
        XCTAssertTrue((plan.repairFramesDropped...plan.repairFramesDropped + 2).contains(answered),
                      "refreshes \(r.stats.repairRequests), coalesced \(r.refreshesCoalesced), repair frames dropped \(plan.repairFramesDropped)")
        XCTAssertTrue(r.hostLog.contains("keyframe"))
        XCTAssertEqual(r.decodeErrors, 0)
        XCTAssertGreaterThanOrEqual(r.longestGapMs, 1000, "a key frame before the 1 s safety net")
        XCTAssertLessThan(r.longestGapMs, 1400, "the safety net at 1 s, then the key frame")
    }

    /// A game whose encoder has no long-term references answers the refresh with a key frame: the picture restarts
    /// there, nothing escalated.
    func testAGameWithoutLongTermReferencesRestartsAtAKeyFrame() async throws {
        let plan = DropPlan(from: 150, repairs: 0)
        let r = try await StreamScenario.run(decoder: ScenarioDecoding.real, profile: .clean, seconds: 4,
                                             dropVideo: { plan.drop($0) }, longTermReferences: false)
        print(r.line("no LTR"))
        XCTAssertEqual(r.repairFrames, 0)
        XCTAssertEqual(r.keyFrames, 2)
        XCTAssertEqual(r.stats.escalations, 0)
        XCTAssertEqual(r.stats.keys, 1, "key frames decoded after the first")
        XCTAssertEqual(r.decodeErrors, 0)
    }

    /// A repair frame the decoder refuses: a key frame is asked for at once, and the picture restarts at it; the refused
    /// frame is never acknowledged (its token never reaches the game).
    func testARepairFrameThatFailsToDecodeAsksForAKeyFrame() async throws {
        let plan = DropPlan(from: 150, repairs: 0)
        let refused = Refused()
        let decoder: @Sendable () -> @Sendable (AssembledFrame) -> Bool = {
            let real = ScenarioDecoding.real()
            return { f in
                if f.repair, refused.take(f.frame) { return false }
                return real(f)
            }
        }
        let r = try await StreamScenario.run(decoder: decoder, profile: .clean, seconds: 4, dropVideo: { plan.drop($0) })
        print(r.line("repair refused") + " keyRequests=\(r.stats.keyRequests)")
        XCTAssertEqual(r.decodeErrors, 1)
        XCTAssertEqual(r.stats.decodeErrors, 1)
        XCTAssertEqual(r.keyFrames, 2)
        XCTAssertGreaterThanOrEqual(r.stats.keyRequests, 1)
        XCTAssertEqual(r.stats.escalations, 0)
        let frame = try XCTUnwrap(refused.frame, "no repair frame was refused")
        let token = try XCTUnwrap(r.tokens[frame], "the game kept no token for frame \(frame)")
        XCTAssertGreaterThanOrEqual(token, 0, "the refused repair frame had no token")
        XCTAssertFalse(r.ackedTokens.contains(token), "the refused repair frame \(frame) (token \(token)) was acknowledged")
        XCTAssertFalse(r.ackedTokens.isEmpty, "nothing was acknowledged at all")
    }
}

/// The first repair frame a scenario's decoder refuses (lock-guarded: the decoder runs on the consumer task).
final class Refused: @unchecked Sendable {
    private let lock = NSLock()  // guards first
    private var first: UInt32?
    /// True for the first frame offered (it is refused), false after.
    func take(_ frame: UInt32) -> Bool { lock.withLock { guard first == nil else { return false }; first = frame; return true } }
    var frame: UInt32? { lock.withLock { first } }
}

#endif
