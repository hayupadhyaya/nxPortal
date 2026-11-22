import XCTest
import AVFoundation
import PortalClientCore
@testable import PortalPlayer

final class AudioOutputTests: XCTestCase {
    private func requireOutputDevice() throws {
        // The engine must outlive the query: its output node does not retain it.
        let probe = AVAudioEngine()
        let channels = probe.outputNode.outputFormat(forBus: 0).channelCount
        withExtendedLifetime(probe) {}
        if channels == 0 { throw XCTSkip("no audio output device") }
    }

    private func startOrSkip(_ output: AudioOutput) throws {
        do { try output.start() } catch { throw XCTSkip("audio output cannot start: \(error)") }
    }

    private func block(_ seq: UInt32) -> AudioBlock {
        var pcm = Data()
        let le = Int16(1000).littleEndian
        for _ in 0..<480 { withUnsafeBytes(of: le) { pcm.append(contentsOf: $0) } }
        return AudioBlock(seq: seq, captureNs: 0, pcm: pcm)
    }

    private func push(_ output: AudioOutput, _ seqs: Range<UInt32>) async throws {
        for seq in seqs {
            output.push(block(seq))
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// The buffer's maximum is the target plus 50 ms, never under 100 ms.
    /// A stall drops the queued sound (no looping, no stale burst) and keeps the counters.
    func testFlushDropsTheQueuedSound() {
        let output = AudioOutput(bufferMs: 25)
        let pcm = Data(repeating: 1, count: 960)
        for seq in 1...5 { output.push(AudioBlock(seq: UInt32(seq), captureNs: 0, pcm: pcm)) }
        XCTAssertEqual(output.bufferedFrames, 1200)
        output.flush()
        XCTAssertEqual(output.bufferedFrames, 0)
        output.push(AudioBlock(seq: 900, captureNs: 0, pcm: pcm))  // any seq after a stall
        XCTAssertEqual(output.bufferedFrames, 240)
    }

    func testMaximumFollowsTarget() {
        XCTAssertEqual(AudioOutput(bufferMs: 25).maxFrames, 4800)
        XCTAssertEqual(AudioOutput(bufferMs: 75).maxFrames, 6000)
        XCTAssertEqual(AudioOutput(bufferMs: 100).maxFrames, 7200)
    }

    /// Automatic: starts at 50 ms, maximum sized for 100 ms, follows the arrivals (time passed in), repeats are not arrivals.
    func testAutomaticTargetFollowsTheArrivals() {
        let output = AudioOutput(automatic: true)
        XCTAssertEqual(output.targetMs, 50)
        XCTAssertEqual(output.maxFrames, 7200)
        var now: UInt64 = 1_000_000_000
        for seq in 0..<600 as Range<UInt32> {     // 3 s of 5 ms blocks, each one twice
            output.push(block(seq), atNs: now)
            output.push(block(seq), atNs: now + 10_000)
            now += 5_000_000
        }
        XCTAssertEqual(output.targetMs, 20, "repeats must not count as zero-length gaps or arrivals")
        output.stop()
        XCTAssertEqual(output.targetMs, 50, "a new stream starts at 50 ms again")
    }

    func testManualTargetDoesNotMove() {
        let output = AudioOutput(bufferMs: 25)
        var now: UInt64 = 1_000_000_000
        for seq in 0..<600 as Range<UInt32> { output.push(block(seq), atNs: now); now += 5_000_000 }
        XCTAssertEqual(output.targetMs, 25)
    }

    func testOutputStartsAndStops() async throws {
        try requireOutputDevice()
        let output = AudioOutput()
        try startOrSkip(output)
        try await push(output, 0..<50)
        output.stop()
        XCTAssertEqual(output.lostBlocks, 0)
        XCTAssertGreaterThan(output.pulledFrames, 0)
    }

    func testRecoversAfterConfigurationChange() async throws {
        try requireOutputDevice()
        let output = AudioOutput()
        try startOrSkip(output)
        defer { output.stop() }
        try await push(output, 0..<20)
        output.simulateEngineStopForTesting()
        XCTAssertFalse(output.engine.isRunning)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: output.engine)
        try await waitUntil(1) { output.engine.isRunning }
        XCTAssertTrue(output.engine.isRunning)
        let before = output.pulledFrames
        try await push(output, 20..<70)
        XCTAssertGreaterThan(output.pulledFrames, before)
    }

    func testStartAfterEngineStoppedRestarts() async throws {
        try requireOutputDevice()
        let output = AudioOutput()
        try startOrSkip(output)
        defer { output.stop() }
        try await push(output, 0..<20)
        output.simulateEngineStopForTesting()
        try output.start()
        XCTAssertTrue(output.engine.isRunning)
        let before = output.pulledFrames
        try await push(output, 20..<70)
        XCTAssertGreaterThan(output.pulledFrames, before)
    }

    func testStartTwiceAndStopWithoutStartAreHarmless() throws {
        try requireOutputDevice()
        let output = AudioOutput()
        output.stop()
        try startOrSkip(output)
        try output.start()
        XCTAssertTrue(output.engine.isRunning)
        output.stop()
        output.stop()
        XCTAssertFalse(output.engine.isRunning)
    }

    func testRestartAcceptsNewStream() async throws {
        try requireOutputDevice()
        let output = AudioOutput()
        try startOrSkip(output)
        try await push(output, 1000..<1050)
        output.stop()
        try output.start()
        defer { output.stop() }
        XCTAssertEqual(output.bufferedFrames, 0)
        for seq in UInt32(1)..<11 { output.push(block(seq)) }
        XCTAssertGreaterThan(output.bufferedFrames, 0)   // the new stream was accepted, not dropped as old
        let before = output.pulledFrames
        try await push(output, 11..<51)
        XCTAssertGreaterThan(output.pulledFrames, before)
        XCTAssertEqual(output.lostBlocks, 0)
        XCTAssertGreaterThan(output.pulledFrames, 0)
    }

    /// A start that fails keeps its observers: the next configuration change or interruption end brings the output up.
    func testFailedStartRetriesAfterInterruption() async throws {
        try requireOutputDevice()
        let output = AudioOutput()
        output.failNextStartForTesting = true
        XCTAssertThrowsError(try output.start())
        XCTAssertFalse(output.engine.isRunning)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: output.engine)
        try await waitUntil(3) { output.engine.isRunning }
        XCTAssertTrue(output.engine.isRunning, "the failed start was not retried")
        output.stop()
    }
}
