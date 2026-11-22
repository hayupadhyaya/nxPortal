import XCTest
import PortalKit
@testable import PortalPlayer

/// The numbers panel's text at each level -> .claude/client.md § stats
final class PanelTextTests: XCTestCase {
    private func stats() -> ClientModel.PlayStats {
        var p = ClientModel.PlayStats()
        p.macFps = 60; p.shownFps = 59.6; p.late = 0; p.width = 1920; p.height = 1080; p.bitrateMbps = 48.6
        p.delayMs = 28; p.delayP95Ms = 34; p.rttMs = 4; p.gapP95Ms = 9; p.gapMaxMs = 21
        p.decodeMs = 3.1; p.soundBufferMs = 40; p.soundAuto = true
        p.rateMbps = 50; p.ceilingMbps = 50
        return p
    }

    func testOffIsEmpty() {
        XCTAssertEqual(PanelText.lines(level: .off, stats: stats(), pacing: .smooth), [])
        XCTAssertEqual(PanelText.lines(level: .off, stats: nil, pacing: .smooth), [])
    }

    func testFpsIsOneLine() {
        XCTAssertEqual(PanelText.lines(level: .fps, stats: stats(), pacing: .smooth), ["60 fps  1920 x 1080"])
    }

    func testCompactIsTwoLinesAndNamesThePacing() {
        let smooth = PanelText.lines(level: .compact, stats: stats(), pacing: .smooth)
        guard smooth.count == 2 else { return XCTFail("\(smooth.count) lines") }
        XCTAssertTrue(smooth[0].contains("Smooth"), smooth[0])
        XCTAssertTrue(smooth[0].contains("Shown 60"), "the pacing word sits with the Shown part: \(smooth[0])")
        XCTAssertTrue(smooth[1].contains("Delay 28 ms") && smooth[1].contains("Rate 50 / 50 Mbit/s"), smooth[1])
        let immediate = PanelText.lines(level: .compact, stats: stats(), pacing: .immediate)
        guard immediate.count == 2 else { return XCTFail("\(immediate.count) lines") }
        XCTAssertTrue(immediate[0].contains("Immediate"), immediate[0])
        XCTAssertFalse(immediate[0].contains("Smooth"))
    }

    func testFullIsTheHeaderSevenLinesAndTheMacAndGameBlocks() {
        let full = PanelText.lines(level: .full, stats: stats(), pacing: .immediate)
        guard full.count == 13 else { return XCTFail("\(full.count) lines") }
        XCTAssertEqual(full[0], "60 fps  1920 x 1080")
        XCTAssertEqual(full.dropFirst().prefix(7).map { String($0.prefix(7)).trimmingCharacters(in: .whitespaces) },
                       ["Mac", "Shown", "Delay", "Network", "Rate", "Decode", "Sound"])
        XCTAssertEqual(full.dropFirst(8).map { String($0.prefix(9)).trimmingCharacters(in: .whitespaces) },
                       ["MAC", "", "", "GAME", ""])
        XCTAssertTrue(full[2].contains("immediate"), full[2])
        XCTAssertTrue(full[1].contains("48.6 Mbit/s"), full[1])
        XCTAssertTrue(full[4].contains("round trip 4 ms") && full[4].contains("gap p95 9 ms"), full[4])
        XCTAssertTrue(full[7].contains("buffer 40 ms auto"), full[7])
    }

    func testNoNumbersYetShowsDashesNotZeros() {
        XCTAssertEqual(PanelText.lines(level: .fps, stats: nil, pacing: .smooth), ["– fps  –"])
        XCTAssertEqual(PanelText.lines(level: .compact, stats: nil, pacing: .smooth).count, 2)
        XCTAssertEqual(PanelText.lines(level: .full, stats: nil, pacing: .smooth).count, 13)
        for line in PanelText.lines(level: .full, stats: nil, pacing: .smooth) { XCTAssertFalse(line.contains("0 fps"), line) }
    }

    private func loaded(gpu: Bool = true, alive: Bool = true) -> ClientModel.PlayStats {
        var p = stats()
        p.load = HostLoad(gpuPresent: gpu, gameAlive: alive, thermal: 1, pressure: 0, cpuTotal: 412, cpuPerf: 551, cpuEff: 120, gpu: gpu ? 783 : 0,
                          memUsedMiB: 18_330, memTotalMiB: 32_768, gameCpuCentiCores: 160, gameMemMiB: 6_250, gameFpsDeci: 600,
                          frameMeanDeciMs: 167, frameP95DeciMs: 190, frameMaxDeciMs: 410)
        return p
    }

    func testTheMacAndGameBlocksShowTheHostsNumbers() {
        let l = PanelText.lines(level: .full, stats: loaded(), pacing: .smooth)
        XCTAssertTrue(l[8].hasPrefix("MAC      CPU 41 % "), l[8])
        XCTAssertTrue(l[8].contains("GPU 78 %"), l[8])
        XCTAssertEqual(l[9].trimmingCharacters(in: .whitespaces), "performance 55 % · efficiency 12 %")
        XCTAssertEqual(l[10].trimmingCharacters(in: .whitespaces), "memory 17.9 / 32 GB · ok · heat fair")
        XCTAssertTrue(l[11].hasPrefix("GAME     "), l[11])
        XCTAssertEqual(l[11].dropFirst(9), "CPU 160 % · memory 6.1 GB · 60.0 fps")
        XCTAssertEqual(l[12].trimmingCharacters(in: .whitespaces), "frame 16.7 ms · p95 19.0 ms · max 41.0 ms")
        XCTAssertLessThanOrEqual(l[8...].map(\.count).max() ?? 0, 52, "the new lines fit the panel's width: \(l[8...].map(\.count))")
    }

    func testASmallGameReadsInMegabytes() {
        var p = loaded(); p.load?.gameMemMiB = 240
        XCTAssertEqual(PanelText.lines(level: .full, stats: p, pacing: .smooth)[11].dropFirst(9), "CPU 160 % · memory 240 MB · 60.0 fps")
    }

    func testNoGPUReadingSaysNotAvailable() {
        let l = PanelText.lines(level: .full, stats: loaded(gpu: false), pacing: .smooth)
        XCTAssertTrue(l[8].contains("GPU n/a"), l[8])
        XCTAssertFalse(l[8].contains("GPU 0"), l[8])
    }

    func testNoLoadYetShowsDashesOnTheMacAndGameLines() {
        for p in [stats(), nil] as [ClientModel.PlayStats?] {
            let l = PanelText.lines(level: .full, stats: p, pacing: .smooth)
            XCTAssertTrue(l[8].contains("CPU –") && l[8].contains("GPU –"), l[8])
            XCTAssertEqual(l[9].trimmingCharacters(in: .whitespaces), "performance – % · efficiency – %")
            XCTAssertEqual(l[10].trimmingCharacters(in: .whitespaces), "memory – / – GB · – · heat –")
            XCTAssertEqual(l[11].dropFirst(9), "CPU – % · memory – · – fps")
            XCTAssertEqual(l[12].trimmingCharacters(in: .whitespaces), "frame – ms · p95 – ms · max – ms")
        }
    }

    func testAGameThatIsNotRunningShowsDashesButTheMacStays() {
        let l = PanelText.lines(level: .full, stats: loaded(alive: false), pacing: .smooth)
        XCTAssertTrue(l[8].contains("CPU 41 %"), l[8])
        XCTAssertEqual(l[11].dropFirst(9), "CPU – % · memory – · – fps")
    }

    func testTheWordsForPressureAndHeat() {
        func line(_ thermal: UInt8, _ pressure: UInt8) -> String {
            var p = loaded(); p.load?.thermal = thermal; p.load?.pressure = pressure
            return PanelText.lines(level: .full, stats: p, pacing: .smooth)[10].trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(line(0, 1), "memory 17.9 / 32 GB · warning · heat nominal")
        XCTAssertEqual(line(2, 2), "memory 17.9 / 32 GB · critical · heat serious")
        XCTAssertEqual(line(3, 0), "memory 17.9 / 32 GB · ok · heat critical")
        XCTAssertEqual(line(9, 9), "memory 17.9 / 32 GB · ? · heat ?", "an unknown value is unknown, never a state")
    }

    func testTheBarsFillWithTheShareAndStayInRange() {
        XCTAssertEqual(PanelText.bar(tenths: 0), "░░░░░░░░")
        XCTAssertEqual(PanelText.bar(tenths: 1000), "████████")
        XCTAssertEqual(PanelText.bar(tenths: 412), "███░░░░░")
        XCTAssertEqual(PanelText.bar(tenths: 783), "██████░░")
        XCTAssertEqual(PanelText.bar(tenths: 5000), "████████", "clamped")
    }

    // MARK: nothing from the wire is trusted

    /// A datagram body with the given fields, decoded as the app does, then shown.
    private func shown(flags: UInt8 = 3, thermal: UInt8 = 0, pressure: UInt8 = 0, fill: UInt8? = nil, note: PanelText.GameNote? = nil) throws -> [String] {
        var body = Data([flags, thermal, pressure])
        body.append(Data(repeating: fill ?? 0, count: 32))
        guard case let .load(h) = try Datagram(type: 0x2B, body: body) else { throw WireError.malformed }
        var p = stats(); p.load = h
        return PanelText.lines(level: .full, stats: p, pacing: .smooth, note: note)
    }

    func testEveryFieldAtItsMaximumShowsClampedOrDashes() throws {
        let l = try shown(thermal: 255, pressure: 255, fill: 0xFF)
        XCTAssertTrue(l[8].contains("CPU 100 %") && l[8].contains("GPU n/a"), "no 6554 %, and the wire's own n/a is n/a: \(l[8])")
        XCTAssertEqual(l[9].trimmingCharacters(in: .whitespaces), "performance 100 % · efficiency 100 %")
        XCTAssertEqual(l[10].trimmingCharacters(in: .whitespaces), "memory – / – GB · ? · heat ?", "absurd memory is dashes, unknown enums are ?")
        XCTAssertEqual(l[11].dropFirst(9), "CPU – % · memory – · – fps", "billions of centi-cores, memory and 6553 fps are dashes")
        XCTAssertEqual(l[12].trimmingCharacters(in: .whitespaces), "frame – ms · p95 – ms · max – ms")
        for line in l { XCTAssertFalse(line.contains("655"), line); XCTAssertFalse(line.contains("429496"), line) }
    }

    func testAllZeroShowsZerosNotDashesForTheMachineAndNoFramesForTheGame() throws {
        let l = try shown()
        XCTAssertTrue(l[8].contains("CPU 0 %"), l[8])
        XCTAssertEqual(l[10].trimmingCharacters(in: .whitespaces), "memory – / – GB · ok · heat nominal", "a zero total is not a memory size")
        XCTAssertEqual(l[11].dropFirst(9), "CPU 0 % · memory 0 MB · no frames")
    }

    func testUsedMemoryAboveTheTotalIsDashes() {
        var p = loaded(); p.load?.memUsedMiB = 40_000
        XCTAssertEqual(PanelText.lines(level: .full, stats: p, pacing: .smooth)[10].trimmingCharacters(in: .whitespaces), "memory – / – GB · ok · heat fair")
        p.load?.memUsedMiB = 18_330; p.load?.gameMemMiB = 60_000
        XCTAssertTrue(PanelText.lines(level: .full, stats: p, pacing: .smooth)[11].contains("memory –"), "a game larger than the Mac")
    }

    func testAnUnknownPressureOrHeatIsAQuestionMarkNeverTheBestState() {
        func line(_ thermal: UInt8, _ pressure: UInt8) -> String {
            var p = loaded(); p.load?.thermal = thermal; p.load?.pressure = pressure
            return PanelText.lines(level: .full, stats: p, pacing: .smooth)[10].trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(line(4, 3), "memory 17.9 / 32 GB · ? · heat ?")
        XCTAssertEqual(line(255, 0), "memory 17.9 / 32 GB · ok · heat ?")
    }

    func testAShortOrLongDatagramIsIgnored() {
        for n in [0, 1, 34, 36, 100] {
            XCTAssertThrowsError(try Datagram(type: 0x2B, body: Data(count: n)), "\(n) bytes")
        }
        XCTAssertThrowsError(try Datagram(type: 0x2B, body: Data([0xFF]) + Data(count: 34)), "flag bits that mean nothing")
    }

    func testAGPUValueAboveAHundredPercentIsClamped() {
        var p = loaded(); p.load?.gpu = 4000
        XCTAssertTrue(PanelText.lines(level: .full, stats: p, pacing: .smooth)[8].contains("GPU 100 %"))
    }

    func testTheWiresNotAvailableValueWithTheFlagSetIsNotAvailableNotAFullGPU() {
        var p = loaded(); p.load?.gpu = HostLoad.gpuNotAvailable
        let line = PanelText.lines(level: .full, stats: p, pacing: .smooth)[8]
        XCTAssertTrue(line.contains("GPU n/a"), line)
        XCTAssertFalse(line.contains("GPU 100"), line)
    }

    /// Every figure rounds to the nearest, as the decimals do (999 tenths is 100 %, not 99).
    func testPercentagesRoundToTheNearest() {
        func first(_ cpu: UInt16, perf: UInt16 = 0, eff: UInt16 = 0) -> [String] {
            var p = loaded(); p.load?.cpuTotal = cpu; p.load?.cpuPerf = perf; p.load?.cpuEff = eff
            return PanelText.lines(level: .full, stats: p, pacing: .smooth)
        }
        XCTAssertTrue(first(999)[8].contains("CPU 100 %"), first(999)[8])
        XCTAssertTrue(first(996)[8].contains("CPU 100 %"))
        XCTAssertTrue(first(994)[8].contains("CPU 99 %"))
        XCTAssertTrue(first(5)[8].contains("CPU 1 %"), "0.5 rounds up, as the decimals do")
        XCTAssertTrue(first(4)[8].contains("CPU 0 %"))
        XCTAssertEqual(first(0, perf: 999, eff: 449)[9].trimmingCharacters(in: .whitespaces), "performance 100 % · efficiency 45 %")
    }

    // MARK: the game's lines say why there are no frames

    func testAPausedOrStartingGameIsNotAStalledOne() {
        func line(_ note: PanelText.GameNote?) -> String {
            var p = loaded(); p.load?.gameFpsDeci = 0
            return String(PanelText.lines(level: .full, stats: p, pacing: .smooth, note: note)[11].dropFirst(9))
        }
        XCTAssertEqual(line(.paused), "CPU 160 % · memory 6.1 GB · paused")
        XCTAssertEqual(line(.starting), "CPU 160 % · memory 6.1 GB · starting")
        XCTAssertEqual(line(nil), "CPU 160 % · memory 6.1 GB · no frames", "a running game with no frames is stalled")
    }

    func testTheNoteFollowsWhatTheMacSaidAboutTheGame() {
        XCTAssertEqual(PanelText.note(preparing: true, run: .running), .starting)
        XCTAssertEqual(PanelText.note(preparing: false, run: .starting), .starting)
        XCTAssertEqual(PanelText.note(preparing: false, run: .paused), .paused)
        XCTAssertNil(PanelText.note(preparing: false, run: .running), "running with no frames is a stall")
        XCTAssertNil(PanelText.note(preparing: false, run: nil))
    }

    func testAStallThatEndedShowsItsLargeMax() {
        var p = loaded(); p.load?.gameFpsDeci = 8; p.load?.frameMaxDeciMs = 25_000
        let l = PanelText.lines(level: .full, stats: p, pacing: .smooth)
        XCTAssertTrue(l[11].hasSuffix("0.8 fps"), l[11])
        XCTAssertTrue(l[12].contains("max 2500.0 ms"), l[12])
    }

    func testTheMenuSubtitleNamesTheMacAndTheStream() {
        XCTAssertEqual(PanelText.menuSubtitle(mac: "Den Mac", width: 1920, height: 1080, fps: 60), "On Den Mac · 1920 x 1080 · 60 fps")
        XCTAssertEqual(PanelText.menuSubtitle(mac: "Den Mac", width: 0, height: 0, fps: 0), "On Den Mac", "no stream numbers yet")
        XCTAssertEqual(PanelText.menuSubtitle(mac: nil, width: 1280, height: 720, fps: 30), "On the Mac · 1280 x 720 · 30 fps")
    }

    func testLevelNames() {
        XCTAssertEqual(PanelLevel.allCases.map(PanelText.name), ["Off", "FPS", "Compact", "Full"])
    }
}
