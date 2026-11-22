#if os(macOS)
import XCTest
import Foundation
import PortalKit
@testable import PortalHostCore

/// What a device may set is the runtime's player settings only (`PlayerOptions`, an allow-list)
final class PlayerOptionsTests: XCTestCase {
    /// Variables of the runtime that are not for a device although the old deny-list let them through (saves, test kills, the
    /// control file, dumps, captures, logs, test executables).
    static let notForADevice: [String] = ["DM_SAVE_SYNC", "DM_SAVE_SYNC_CHOICE", "DM_TEST_KILL_AT", "DM_TEST_FS_FAIL", "DM_TEST_FS_FAILAT", "DM_SAVED_CHOICES", "DM_CTL", "DM_GAME_ENV", "DM_GAME", "DM_RELAUNCH", "DM_PROGRAM", "DM_PROGRAM_ID", "DM_AUDIO_DUMP", "DM_AUDIO_CAPTURE", "DM_AUDIO_LIVE_PCM", "DM_FSLOG", "DM_HLECOUNT", "DM_MEMSTAT", "DM_THRCPU", "DM_REGIONS", "DM_REC", "DM_NVN_CAPTURE", "DM_NVN_CBDUMP", "DM_NVN_SHDUMP", "DM_NVN_SHOT", "DM_NVN_TEXDUMP", "DM_NVN_TSV", "DM_NVN_PASSGPU", "DM_NVN_REGLUM", "DM_NVN_T2T_TRACE", "DM_NVN_ZBLOCK", "DM_PROBE_DUMP", "DM_JIT_MISS_DUMP", "DM_NRO_CAPTURE", "DM_HOME_QUIT_CAPTURE", "DM_WATCH_SAMPLE", "DM_TEST_BORDER", "DM_TEST_GEOMETRY", "DM_TEST_GEOMETRY_PRIMITIVE_ID", "DM_TEST_TESS", "DM_TEST_TRANSFORM_FEEDBACK"]

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxportal-player-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// The folder of the nxnative clone holds `docs/env_switches.tsv` on the owner's machine only: search upward for it.
    private func nxnativeFile(_ relative: String) -> URL? {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = url.appendingPathComponent("nxnative/\(relative)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private func rows(_ url: URL, class wanted: String? = nil) throws -> [[String]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [[String]] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("name\t") {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if let wanted { guard cells.count > 1, cells[1] == wanted else { continue } }
            out.append(cells)
        }
        return out
    }

    func testTheListIsASubsetOfTheTablesPlayerClass() throws {
        guard let table = nxnativeFile("docs/env_switches.tsv") else { throw XCTSkip("the nxnative clone is not on this machine") }
        let player = Set(try rows(table, class: "player").map { $0[0] })
        XCTAssertFalse(player.isEmpty)
        XCTAssertTrue(PlayerOptions.names.isSubset(of: player), "not in the table's player class: \(PlayerOptions.names.subtracting(player).sorted())")
    }

    func testEveryRowARealSettingsListCanEmitStaysSettable() throws {
        guard let file = nxnativeFile("dm/games/settings.tsv") else { throw XCTSkip("the nxnative clone is not on this machine") }
        let names = try rows(file).map { $0[0] }.filter { $0.hasPrefix("DM_") }
        XCTAssertGreaterThanOrEqual(names.count, 20)
        for n in names { XCTAssertTrue(PlayerOptions.names.contains(n), "\(n) is a row the runtime's list emits") }
        let shown = names.filter { !HiddenOptions.names.contains($0) }
        for n in shown { XCTAssertTrue(PlayerOptions.isSettable(n), n) }
    }

    func testTheNamesOfTheRealListAreSettableWithoutTheTable() {
        for n in ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_LANG", "DM_UPSCALER", "DM_OPMODE", "DM_FPS_HOLD", "DM_RUMBLE_GAIN", "DM_PSO_MTL4"] {
            XCTAssertTrue(PlayerOptions.isSettable(n), n)
        }
        for n in HiddenOptions.names { XCTAssertFalse(PlayerOptions.isSettable(n), "\(n) does nothing while streaming") }
        XCTAssertFalse(PlayerOptions.isSettable("DM_SAVE_SYNC"), "a folder, not a row")
    }

    func testNothingTheRuntimeKeepsForItselfIsSettableOrReadAsARowOrLaunched() throws {
        for n in Self.notForADevice {
            XCTAssertFalse(PlayerOptions.isSettable(n), n)
            let json = OptionsFixture.json([["env": n, "kind": "toggle", "section": "x", "label": "x", "note": "", "default": "0", "on": "1", "off": "0"]] + OptionsFixture.five)
            XCTAssertEqual(GameOptionsReader.parse(json)?.map(\.env), ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_FPS_HOLD"], n)
            XCTAssertEqual(HostService.launchEnvironment(file: [:], choices: [n: "1", "DM_FPS_TARGET": "30"]), ["DM_FPS_TARGET": "30"], n)
        }
    }

    /// The runtime's rotation lock is for a game on a phone or tablet itself: known to the Host, hidden from devices, never launched.
    func testTheRotationSettingIsKnownButHiddenFromDevices() {
        XCTAssertTrue(PlayerOptions.names.contains("DM_ROTATION"))
        XCTAssertTrue(HiddenOptions.names.contains("DM_ROTATION"))
        XCTAssertFalse(PlayerOptions.isSettable("DM_ROTATION"))
        XCTAssertEqual(HostService.launchEnvironment(file: [:], choices: ["DM_ROTATION": "portrait", "DM_FPS_TARGET": "30"]), ["DM_FPS_TARGET": "30"])
    }

    /// A streamed game never opens the Mac's microphone: the runtime's microphone rows are known to the Host and hidden from devices.
    func testTheMicrophoneSettingsAreKnownButHiddenFromDevices() {
        for n in ["DM_MIC", "DM_MIC_GAIN"] {
            XCTAssertTrue(PlayerOptions.names.contains(n), n)
            XCTAssertTrue(HiddenOptions.names.contains(n), n)
            XCTAssertFalse(PlayerOptions.isSettable(n), n)
        }
        let rows: [[String: Any]] = [
            ["env": "DM_MIC", "kind": "toggle", "section": "x", "label": "x", "note": "", "default": "0", "on": "1", "off": "0"],
            ["env": "DM_MIC_GAIN", "kind": "range", "section": "x", "label": "x", "note": "", "default": "4", "min": 1, "max": 8, "step": 0.5, "needs": "DM_MIC=1"],
        ]
        XCTAssertEqual(GameOptionsReader.parse(OptionsFixture.json(rows + OptionsFixture.five))?.map(\.env), ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_FPS_HOLD"])
        XCTAssertEqual(HostService.launchEnvironment(file: [:], choices: ["DM_MIC": "1", "DM_MIC_GAIN": "8", "DM_FPS_TARGET": "30"]), ["DM_FPS_TARGET": "30"])
    }

    /// Whatever a hostile `launcher.json` makes the reader produce, the wire decoder takes it.
    func testWhatTheReaderProducesAlwaysRoundTripsThroughTheDecoder() throws {
        let big = String(repeating: "L", count: 900_000), controls = "a\u{0}b\nc\u{1b}[0m\u{85}d\u{2028}e"
        let pairs = (0..<500).map { ["v\($0)", big] }
        var rows: [[String: Any]] = [
            ["env": "DM_RENDER_SCALE", "kind": "range", "section": big, "label": big, "note": big, "default": "1", "min": 5, "max": 1, "step": 0.1],
            ["env": "DM_FPS_TARGET", "kind": "range", "section": "s", "label": controls, "note": controls, "default": "1", "min": 0, "max": 1, "step": 0],
            ["env": "DM_LANG", "kind": "range", "section": "s", "label": "x", "note": "", "default": "1", "min": 0, "max": 1, "step": -1],
            ["env": "DM_UPSCALER", "kind": "choice", "section": "s", "label": "x", "note": "", "default": "a", "options": pairs],
            ["env": "DM_OPMODE", "kind": "toggle", "section": "s", "label": "x", "note": "", "default": "0", "on": controls, "off": big],
            ["env": "DM_FPS_HOLD", "kind": "toggle", "section": "s", "label": "x", "note": "", "default": "0", "on": "1", "off": "0",
             "base": ["docked": [0, 5], "handheld": [200_000, 5]], "needs": "DM_LANG=" + big, "level": big],
            ["env": "DM_PSO_MTL4", "kind": big, "section": "s", "label": "x", "note": "", "default": "0"],
        ]
        for i in 0..<300 { rows.append(["env": "DM_PSO_PREBUILD", "kind": "toggle", "section": "s", "label": "x\(i)", "note": "", "default": "0", "on": "1", "off": "0"]) }
        let read = try XCTUnwrap(GameOptionsReader.parse(OptionsFixture.json(rows)))
        XCTAssertFalse(read.isEmpty)
        let settings = read.map { r in
            OptionSetting(env: r.env, kind: r.kind, section: r.section, label: r.label, note: r.note, defaultValue: r.defaultValue,
                          current: r.defaultValue, chosen: false, options: r.options, min: r.min, max: r.max, step: r.step, on: r.on,
                          off: r.off, base: r.base, level: r.level, needs: r.needs)
        }
        let data = try ControlMessage.options(GameOptions(titleID: "FAKE000000000000", settings: settings)).encoded()
        XCTAssertNoThrow(try ControlMessage(decoding: data), "\(data.count) bytes")
        XCTAssertLessThan(data.count, 1 << 20)
        // A reversed or stepless range loses its numbers (the row stays, read-only).
        let range = try XCTUnwrap(read.first { $0.env == "DM_RENDER_SCALE" })
        XCTAssertNil(range.min); XCTAssertNil(range.max); XCTAssertNil(range.step)
    }
}
#endif
