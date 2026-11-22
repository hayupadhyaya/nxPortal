import XCTest
import PortalClientCore
import PortalKit
@testable import PortalPlayer

final class SessionRecorderTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    // MARK: phase

    func testPhaseIsArrivalMinusPreviousRefresh() {
        var m = ArrivalMeter()
        m.refresh(atNs: 1000 * ms, intervalMs: 16.7)
        m.arrival(atNs: 1004 * ms)
        m.arrival(atNs: 1012 * ms)
        m.refresh(atNs: 1017 * ms, intervalMs: 16.7)
        m.arrival(atNs: 1020 * ms)
        let s = m.take()
        XCTAssertEqual(s?.arrivals, 3)
        XCTAssertEqual(s?.phaseMinMs ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(s?.phaseMaxMs ?? -1, 12, accuracy: 0.001)
        XCTAssertEqual(s?.phaseMeanMs ?? -1, (4 + 12 + 3) / 3.0, accuracy: 0.001)
        XCTAssertEqual(s?.refreshMs ?? -1, 16.7, accuracy: 0.001)
    }

    func testArrivalBeforeAnyRefreshHasNoPhase() {
        var m = ArrivalMeter()
        m.arrival(atNs: 5 * ms)
        let s = m.take()
        XCTAssertEqual(s?.arrivals, 1)
        XCTAssertNil(s?.phaseMeanMs)
        XCTAssertNil(s?.intervalMeanMs, "one arrival has no interval")
    }

    func testIntervalsMeanP95MaxAndTakeResets() {
        var m = ArrivalMeter()
        m.refresh(atNs: 0, intervalMs: 16.7)
        var t: UInt64 = 0
        for gap in [10, 10, 10, 10, 10, 10, 10, 10, 10, 50] as [UInt64] { t += gap * ms; m.arrival(atNs: t) }
        let s = m.take()!
        XCTAssertEqual(s.intervalMaxMs ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(s.intervalMeanMs ?? -1, 130.0 / 9, accuracy: 0.001)  // 9 gaps: the first arrival has none
        XCTAssertEqual(s.intervalP95Ms ?? -1, 50, accuracy: 0.001)
        XCTAssertNil(m.take(), "taken: nothing until the next arrival")
        m.arrival(atNs: t + 20 * ms)
        XCTAssertEqual(m.take()?.intervalMaxMs ?? -1, 20, accuracy: 0.001, "the gap spans the take")
    }

    // MARK: line

    func testLineOrderOmitsUnknownAndHasNoUnitsInValues() {
        var s = SessionSample()
        s.put("t_s", 12)
        s.put("shown", 58)
        s.put("rtt_floor_ms", nil as Double?)
        s.put("phase_mean_ms", 7.26, digits: 1)
        s.put("bad_ms", Double.nan, digits: 1)
        s.put("rate_why", "queue")
        XCTAssertEqual(s.line, "t_s=12 shown=58 phase_mean_ms=7.3 rate_why=queue")
    }

    func testSampleFromNumbers() {
        var stats = SessionStats()
        stats.fps = 59.6; stats.framesSkipped = 3; stats.rttMs = 4.25; stats.rttFloorMs = 2.5
        stats.fragmentsAsked = 9; stats.fragmentsRecovered = 8; stats.framesGivenUp = 1; stats.keyRequests = 2; stats.refreshes = 1
        stats.repairRequests = 6; stats.escalations = 1; stats.keys = 2; stats.framesRepaired = 5; stats.decodeErrors = 3
        stats.rateBps = 40_000_000; stats.rateCeilingBps = 50_000_000
        stats.rateChanges = [RateChange(seq: 1, atSeconds: 3, fromBps: 50_000_000, toBps: 40_000_000, why: .queue)]
        stats.host = HostStats(framesFromGame: 60, framesSent: 59, framesDropped: 1, resent: 4, rateBps: 40_000_000, sendLateMaxUs: 1200)
        var play = ClientModel.PlayStats()
        play.soundBufferMs = 60; play.soundUnderruns = 2; play.soundLost = 1; play.decodeMs = 3
        var display = DisplayReport()
        display.shown = 58; display.late = 2; display.empty = 1; display.pending = 1
        var meter = ArrivalMeter()
        meter.refresh(atNs: 0, intervalMs: 16.7); meter.arrival(atNs: 5 * ms)
        display.phase = meter.take()
        let line = SessionSample.make(seconds: 12.4, stats: stats, play: play, display: display, soundLevelMs: 48,
                                      decode: (meanMs: 3.1, maxMs: 6.0), thermal: 1, lowPower: false,
                                      maxima: SecondMaxima(netGapMaxMs: 104.6, rttMaxMs: 38.26)).line
        let keys = line.split(separator: " ").map { $0.split(separator: "=")[0] }
        XCTAssertEqual(keys.prefix(8).map(String.init), ["t_s", "arrived", "shown", "late", "empty", "queue", "queue_target", "phase_mean_ms"])
        for k in ["rate_mbps", "rate_ceiling_mbps", "rate_why", "rtt_floor_ms", "rtt_ms", "asked", "recovered", "given_up",
                  "sound_target_ms", "sound_level_ms", "underruns", "blocks_lost", "host_sent", "host_late_us", "thermal", "low_power"] {
            XCTAssertTrue(keys.contains { $0 == k }, "missing \(k) in \(line)")
        }
        XCTAssertTrue(line.contains("t_s=12 "), line)
        XCTAssertTrue(line.contains("rate_why=queue"), line)
        XCTAssertTrue(line.hasSuffix("thermal=1 low_power=0 net_gap_max_ms=104.6 rtt_max_ms=38.3 "
                        + "repair_requests=6 escalations=1 keys=2 frames_repaired=5 decode_errors=3"), "new keys last, in order: \(line)")
        XCTAssertFalse(line.contains("gap_mean_ms"), "one arrival: no interval, so no key: \(line)")
    }

    func testSampleWithoutDisplayReportLeavesPacerKeysOut() {
        let line = SessionSample.make(seconds: 1, stats: SessionStats(), play: ClientModel.PlayStats(), display: nil, soundLevelMs: nil,
                                      decode: nil, thermal: 0, lowPower: true).line
        XCTAssertFalse(line.contains("shown="), line)
        XCTAssertFalse(line.contains("phase_"), line)
        XCTAssertFalse(line.contains("host_"), line)
        XCTAssertFalse(line.contains("rtt_floor_ms"), line)
        XCTAssertTrue(line.hasSuffix("low_power=1 repair_requests=0 escalations=0 keys=0 frames_repaired=0 decode_errors=0"),
                      "no sample: both maxima left out, the totals stay: \(line)")
        XCTAssertFalse(line.contains("net_gap_max_ms") || line.contains("rtt_max_ms"), line)
    }

    func testHeaderHasNoPersonalFieldsAndOmitsUnknown() {
        var h = SessionHeader(app: "1.2", build: "34", os: "18.1", platform: "ios", model: "iPad14,3", displayMaxHz: 120,
                              titleID: "FAKE000000000000", width: 1920, height: 1080, fpsCap: 60, bitrateMbps: 50,
                              smooth: true, soundBuffer: "auto")
        XCTAssertEqual(h.line, "session v=1 app=1.2 build=34 platform=ios os=18.1 model=iPad14,3 display_max_hz=120 title=FAKE000000000000 size=1920x1080 fps_cap=60 bitrate_cap_mbps=50 smooth=1 sound_buffer=auto")
        h.displayMaxHz = nil; h.titleID = nil
        XCTAssertFalse(h.line.contains("display_max_hz")); XCTAssertFalse(h.line.contains("title="))
    }

    // MARK: housekeeping

    private func file(_ n: Int, bytes: Int = 1000) -> LogFile {
        LogFile(name: "f\(n).log", bytes: bytes, modified: Date(timeIntervalSince1970: Double(n)))
    }

    func testKeepsNewestThirty() {
        let files = (1...35).map { file($0) }.shuffled()
        XCTAssertEqual(Set(SessionLogs.removals(files)), Set((1...5).map { "f\($0).log" }))
    }

    func testRemovesOldestBeyondTwentyMegabytes() {
        let files = (1...10).map { file($0, bytes: 3_000_000) }  // 30 MB: the newest six fit in 20 MB
        let gone = SessionLogs.removals(files)
        XCTAssertEqual(Set(gone), Set((1...4).map { "f\($0).log" }))
    }

    func testNothingRemovedWhenSmall() {
        XCTAssertTrue(SessionLogs.removals((1...30).map { file($0) }).isEmpty)
        XCTAssertTrue(SessionLogs.removals([]).isEmpty)
    }

    func testOnceOneIsRemovedEveryOlderOneIs() {
        // newest is huge: it alone exceeds the limit, so nothing older may be kept after a removal at that point
        let files = [file(3, bytes: 1000), file(2, bytes: 25_000_000), file(1, bytes: 10)]
        XCTAssertEqual(Set(SessionLogs.removals(files)), ["f2.log", "f1.log"])
    }

    // MARK: file

    func testRecorderWritesHeaderAndLinesAndPrunes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in 1...30 { try Data("x".utf8).write(to: dir.appendingPathComponent(String(format: "20230101-0000%02d.log", n))) ; try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(n))], ofItemAtPath: dir.appendingPathComponent(String(format: "20230101-0000%02d.log", n)).path) }
        let rec = SessionRecorder(directory: dir)
        await rec.begin(header: "session v=1", now: Date(timeIntervalSince1970: 1_700_000_000))
        await rec.append("t_s=1")
        await rec.append("t_s=2")
        await rec.end()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names.count, 30)
        XCTAssertFalse(names.contains("20230101-000001.log"))
        XCTAssertTrue(names.contains("20231114-221320.log"), "\(names)")
        let text = try String(contentsOf: dir.appendingPathComponent("20231114-221320.log"), encoding: .utf8)
        XCTAssertEqual(text, "session v=1\nt_s=1\nt_s=2\n")
    }

    func testFailedWriteTurnsRecorderOffAndCounts() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notadir-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)  // a file where the folder should be: nothing can be created
        defer { try? FileManager.default.removeItem(at: file) }
        let rec = SessionRecorder(directory: file)
        await rec.begin(header: "h")
        await rec.append("t_s=1")
        let on = await rec.isOn, failed = await rec.failures
        XCTAssertFalse(on)
        XCTAssertEqual(failed, 1)
    }

    func testPruneLeavesFilesItDidNotWrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("x.log"), withIntermediateDirectories: true)
        try Data("n".utf8).write(to: dir.appendingPathComponent("notes.log"))
        for n in 1...31 { try Data("x".utf8).write(to: dir.appendingPathComponent(String(format: "20230101-0000%02d.log", n))) }
        let rec = SessionRecorder(directory: dir)
        await rec.begin(header: "h", now: Date(timeIntervalSince1970: 1_700_000_000))
        await rec.end()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertTrue(names.contains("x.log")); XCTAssertTrue(names.contains("notes.log"))
        XCTAssertEqual(names.filter { $0.hasPrefix("2023") }.count, 30)
    }

    func testPausedLinkGivesNoPhaseUntilNextRefresh() {
        var m = ArrivalMeter()
        m.refresh(atNs: 0, intervalMs: 16.7)
        m.linkPaused()
        m.arrival(atNs: 900 * ms)
        XCTAssertNil(m.take()?.phaseMeanMs)
    }

    func testSettingDefaultsOnAndOldSettingsLoad() throws {
        XCTAssertTrue(ClientSettings().recordSessions)
        let old = try JSONDecoder().decode(ClientSettings.self, from: Data(#"{"maxFps":30}"#.utf8))
        XCTAssertTrue(old.recordSessions)
        XCTAssertEqual(old.maxFps, 30)
    }
}
