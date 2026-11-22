#if os(macOS)
import XCTest
import Foundation
import PortalKit
@testable import PortalHostCore

/// The generated lists the options tests use: our own names and labels, never a real game's.
enum OptionsFixture {
    static var fps: [String: Any] { ["env": "DM_FPS_TARGET", "kind": "choice", "section": "Performance", "label": "Frame rate", "note": "",
                                       "default": "60", "options": [["30", "30 fps"], ["60", "60 fps"]], "level": "basic"] }
    static var scale: [String: Any] { ["env": "DM_RENDER_SCALE", "kind": "range", "section": "Graphics", "label": "Render scale", "note": "",
                                         "default": "1.0", "min": 0.5, "max": 1.0, "step": 0.05,
                                         "base": ["docked": [1920, 1080], "handheld": [1280, 720]]] }
    static var hold: [String: Any] { ["env": "DM_FPS_HOLD", "kind": "toggle", "section": "Performance", "label": "Hold the frame rate", "note": "",
                                        "default": "on", "on": "on", "off": "off"] }
    static var dial: [String: Any] { ["env": "DM_DIAL", "kind": "dial", "section": "Other", "label": "A dial", "note": "", "default": "x"] }
    static var floor: [String: Any] { ["env": "DM_FPS_FLOOR", "kind": "range", "section": "Performance", "label": "Lowest rate", "note": "",
                                         "default": "30", "min": 10, "max": 60, "step": 5, "needs": "DM_FPS_HOLD=on"] }
    /// Five rows, in this order.
    static var five: [[String: Any]] { [fps, scale, hold, dial, floor] }

    static func json(_ rows: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["schema": 1, "game": "FAKE000000000000", "settings": rows])
    }

    /// A made-up app folder holding `rows` as its `launcher.json`.
    static func bundle(in dir: URL, name: String = "Fake.app", rows: [[String: Any]]? = five, raw: Data? = nil) throws -> URL {
        let app = dir.appendingPathComponent(name)
        let resources = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if let data = raw ?? rows.map(json) { try data.write(to: resources.appendingPathComponent("launcher.json")) }
        return app
    }
}

final class GameOptionsTests: XCTestCase {
    /// These tests use made-up variables: any name may have a row here; the allow-list is `PlayerOptionsTests`.
    private let any: (String) -> Bool = { _ in true }
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxportal-options-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func five() throws -> [LauncherSetting] {
        try XCTUnwrap(GameOptionsReader.read(bundle: try OptionsFixture.bundle(in: dir), allowing: any))
    }

    private func row(_ env: String) throws -> LauncherSetting { try XCTUnwrap(five().first { $0.env == env }, env) }

    // MARK: reading

    func testFiveRowsComeInTheirOrderWithTheirFields() throws {
        let rows = try five()
        XCTAssertEqual(rows.map(\.env), ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_FPS_HOLD", "DM_DIAL", "DM_FPS_FLOOR"])
        XCTAssertEqual(rows[0].options, [["30", "30 fps"], ["60", "60 fps"]])
        XCTAssertEqual(rows[0].level, "basic")
        XCTAssertEqual(rows[1].defaultValue, "1.0")
        XCTAssertEqual([rows[1].min, rows[1].max, rows[1].step], [0.5, 1.0, 0.05])
        XCTAssertEqual(rows[1].base, OptionBase(docked: .init(width: 1920, height: 1080), handheld: .init(width: 1280, height: 720)))
        XCTAssertEqual([rows[2].on, rows[2].off], ["on", "off"])
        XCTAssertEqual(rows[3].kind, "dial")
        XCTAssertEqual(rows[4].needs, "DM_FPS_HOLD=on")
    }

    func testBadJSONOrNoFileIsNil() throws {
        XCTAssertNil(GameOptionsReader.read(bundle: try OptionsFixture.bundle(in: dir, name: "Bad.app", raw: Data("{not json".utf8))))
        XCTAssertNil(GameOptionsReader.read(bundle: try OptionsFixture.bundle(in: dir, name: "None.app", rows: nil)))
        XCTAssertNil(GameOptionsReader.read(bundle: dir.appendingPathComponent("Missing.app")))
        XCTAssertNil(GameOptionsReader.parse(Data(#"{"settings":"no"}"#.utf8)))
        XCTAssertNil(GameOptionsReader.parse(Data(#"[1,2]"#.utf8)))
    }

    func testAHiddenOrReservedNameIsDropped() throws {
        var rows = OptionsFixture.five
        rows.append(["env": "DM_FULLSCREEN", "kind": "choice", "section": "Display", "label": "Window", "note": "", "default": "0",
                     "options": [["0", "Window"], ["1", "Fullscreen"]]])
        for reserved in HostService.reservedGameVariables.sorted() {
            rows.append(["env": reserved, "kind": "toggle", "section": "x", "label": "x", "note": "", "default": "0", "on": "1", "off": "0"])
        }
        let read = try XCTUnwrap(GameOptionsReader.read(bundle: try OptionsFixture.bundle(in: dir, rows: rows), allowing: any))
        XCTAssertEqual(read.map(\.env), OptionsFixture.five.map { $0["env"] as! String })
        XCTAssertTrue(HiddenOptions.names.contains("DM_FULLSCREEN"))
    }

    // MARK: the runtime's and the Host's own variables

    private func toggle(_ env: String) -> [String: Any] {
        ["env": env, "kind": "toggle", "section": "x", "label": "x", "note": "", "default": "0", "on": "1", "off": "0"]
    }

    /// A game's list that names one of these gets no row for it (dropped like a hidden one, not shown as unsettable: the
    /// person has nothing to choose there), whatever else it lists.
    func testEveryFamilyOfTheHostsAndTheRuntimesOwnVariablesIsReserved() throws {
        let families: [(String, [String])] = [
            ("what the Host sets", ["DM_STREAM", "DM_LAUNCHER"]),
            ("the stream family (prefix)", ["DM_STREAM_PREPARE", "DM_STREAM_ANYTHING_NEW"]),
            ("the launcher family (prefix)", ["DM_LAUNCH_PARAM", "DM_LAUNCHER_X", "DM_LAUNCH"]),
            ("the environment-override family (prefix)", ["DM_ENV_FILE", "DM_ENV_FILE_KEYS", "DM_ENV_LAUNCH_KEYS", "DM_ENV_NEW"]),
            ("scripted input (prefix)", ["DM_KEYS", "DM_KEYS_DIR"]),
            ("the games folders (prefix)", ["DM_GAMES_DIR", "DM_GAMES_FIRST"]),
            ("the capture family (prefix)", ["DM_GPU_CAPTURE", "DM_GPU_CAPTURE_DIR", "DM_GPU_CAPTURE_KEEP"]),
            ("path-class names (explicit)", ["DM_EXEC_OUT", "DM_ROOT", "DM_SAVE", "DM_TEMP", "DM_ROMFS", "DM_PSO_ARCHIVE", "DM_SYSTEM_DIR"]),
            ("a path by its ending (rule)", ["DM_SOMETHING_DIR", "DM_SOMETHING_FILE", "DM_SOMETHING_PATH", "DM_SOMETHING_OUT"]),
        ]
        for (family, names) in families {
            for name in names {
                XCTAssertTrue(ReservedVariables.isReserved(name), "\(family): \(name)")
                let rows = OptionsFixture.five + [toggle(name)]
                let read = try XCTUnwrap(GameOptionsReader.read(bundle: try OptionsFixture.bundle(in: dir, name: "R\(name).app", rows: rows), allowing: any))
                XCTAssertEqual(read.count, 5, "\(family): \(name) is not a row")
            }
        }
        for ordinary in ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_FPS_HOLD", "DM_LANG", "DM_RUMBLE_GAIN", "DM_PSO_MTL4", "DM_STREAMING", "DM_UPSCALER"] {
            // `DM_STREAMING` starts with the stream prefix and is reserved by the rule: the rule is a prefix, on purpose.
            XCTAssertEqual(ReservedVariables.isReserved(ordinary), ordinary == "DM_STREAMING", ordinary)
        }
    }

    func testTextsLoseControlCharactersAndAreCut() throws {
        let rows: [[String: Any]] = [["env": "DM_T", "kind": "toggle", "section": "Sec\ttion", "label": "A\nB\u{0}C\u{1b}", "note": "one\r\ntwo",
                                      "default": "0", "on": "1", "off": "0"]]
        let read = try XCTUnwrap(GameOptionsReader.parse(OptionsFixture.json(rows), allowing: any)).first
        XCTAssertEqual(read?.label, "A BC")
        XCTAssertEqual(read?.section, "Sec tion")
        XCTAssertEqual(read?.note, "one  two")
        XCTAssertEqual(GameOptionsReader.maxSettings, OptionLimits.maxSettings, "one definition")
        XCTAssertEqual(GameOptionsReader.maxValue, OptionLimits.maxValueBytes)
    }

    func testARowThatCouldNotBeAVariableOrRepeatsOneIsDropped() throws {
        func toggle(_ env: String) -> [String: Any] {
            ["env": env, "kind": "toggle", "section": "x", "label": "x", "note": "", "default": "0", "on": "1", "off": "0"]
        }
        let rows = [toggle("DM_OK"), toggle("DM_OK"), toggle("PATH"), toggle("DM_A=B"), toggle("DM_X\nY"), toggle("dm_low"), toggle(""),
                    toggle("DM_" + String(repeating: "A", count: 100))]
        let read = try XCTUnwrap(GameOptionsReader.parse(OptionsFixture.json(rows), allowing: any))
        XCTAssertEqual(read.map(\.env), ["DM_OK"], "one row, first of its name; no name outside DM_[A-Z0-9_]{1,61}")
    }

    func testANumberWhereTheSchemaSaysTextIsTakenAsItsText() throws {
        let rows: [[String: Any]] = [["env": "DM_N", "kind": "choice", "section": "x", "label": "x", "note": "", "default": 60,
                                      "options": [[30, "a"], ["60", "b"]]]]
        let read = try XCTUnwrap(GameOptionsReader.parse(OptionsFixture.json(rows), allowing: any))
        XCTAssertEqual(read.first?.defaultValue, "60")
        XCTAssertEqual(read.first?.options, [["60", "b"]], "a pair whose value is not text is dropped, the rest stay")
    }

    func testTheReaderIsBounded() throws {
        let many = (0..<500).map { ["env": "DM_ROW_\($0)", "kind": "toggle", "section": "x", "label": "x", "note": "", "default": "0", "on": "1", "off": "0"] as [String: Any] }
        XCTAssertEqual(try XCTUnwrap(GameOptionsReader.parse(OptionsFixture.json(many), allowing: any)).count, GameOptionsReader.maxSettings)
        let huge = Data(count: GameOptionsReader.maxFileBytes + 1)
        XCTAssertNil(GameOptionsReader.read(bundle: try OptionsFixture.bundle(in: dir, name: "Huge.app", raw: huge)))
        let long = String(repeating: "x", count: 5_000)
        let rows: [[String: Any]] = [["env": "DM_L", "kind": "choice", "section": long, "label": long, "note": long, "default": "a",
                                      "options": [["a", long], [long, "b"]]]]
        let read = try XCTUnwrap(GameOptionsReader.parse(OptionsFixture.json(rows), allowing: any)).first
        XCTAssertEqual(read?.label.count, OptionLimits.maxTextCharacters)
        XCTAssertEqual(read?.options?.map { $0[0] }, ["a"], "a value over the limit is not offered")
    }

    func testANonFileIsNotRead() throws {
        let app = try OptionsFixture.bundle(in: dir, name: "Pipe.app", rows: nil)
        let path = app.appendingPathComponent("Contents/Resources/dm/launcher.json").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        XCTAssertNil(GameOptionsReader.read(bundle: app), "a pipe would block the Host")
        let folder = try OptionsFixture.bundle(in: dir, name: "Dir.app", rows: nil)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Contents/Resources/dm/launcher.json"), withIntermediateDirectories: true)
        XCTAssertNil(GameOptionsReader.read(bundle: folder))
    }

    // MARK: validating

    func testAChoiceTakesOnlyWhatTheGameOffers() throws {
        let fps = try row("DM_FPS_TARGET")
        XCTAssertEqual(GameOptionsReader.validate("30", for: fps), "30")
        XCTAssertNil(GameOptionsReader.validate("45", for: fps))
        XCTAssertNil(GameOptionsReader.validate("", for: fps))
        XCTAssertNil(GameOptionsReader.validate("30 ", for: fps))
        XCTAssertNil(GameOptionsReader.validate("30 fps", for: fps), "the label is not the value")
    }

    func testARangeIsSnappedToItsStepAndKeptInItsBounds() throws {
        let scale = try row("DM_RENDER_SCALE")
        XCTAssertEqual(GameOptionsReader.validate("0.75", for: scale), "0.75")
        XCTAssertEqual(GameOptionsReader.validate("0.76", for: scale), "0.75")
        XCTAssertEqual(GameOptionsReader.validate("1", for: scale), "1")
        XCTAssertEqual(GameOptionsReader.validate("1.0", for: scale), "1")
        XCTAssertEqual(GameOptionsReader.validate("0.5", for: scale), "0.5")
        XCTAssertNil(GameOptionsReader.validate("1.5", for: scale))
        XCTAssertNil(GameOptionsReader.validate("0.4", for: scale))
        XCTAssertNil(GameOptionsReader.validate("-0.75", for: scale))
        let floor = try row("DM_FPS_FLOOR")
        XCTAssertEqual(GameOptionsReader.validate("33", for: floor), "35")
        XCTAssertEqual(GameOptionsReader.validate("60", for: floor), "60")
    }

    func testARangeTakesPlainDecimalsOnly() throws {
        let scale = try row("DM_RENDER_SCALE")
        for bad in ["nan", "inf", "-inf", "1e0", "0x1", "+0.75", " 0.75", "0.75 ", "0,75", ".", "0.", ".75", "0.75.1", "٠.٧٥", "0.75\n", "1" + String(repeating: "0", count: 400)] {
            XCTAssertNil(GameOptionsReader.validate(bad, for: scale), "\"\(bad)\"")
        }
    }

    func testAToggleTakesItsTwoValues() throws {
        let hold = try row("DM_FPS_HOLD")
        XCTAssertEqual(GameOptionsReader.validate("off", for: hold), "off")
        XCTAssertEqual(GameOptionsReader.validate("on", for: hold), "on")
        XCTAssertNil(GameOptionsReader.validate("yes", for: hold))
        XCTAssertNil(GameOptionsReader.validate("ON", for: hold))
    }

    func testAKindWeDoNotKnowTakesNothing() throws {
        XCTAssertNil(GameOptionsReader.validate("x", for: try row("DM_DIAL")), "the row's own default too")
        XCTAssertNil(GameOptionsReader.validate("", for: try row("DM_DIAL")))
    }

    /// Nothing that reaches a game's environment can carry a line break, a NUL or another control character, or be long.
    func testNoValueCarriesAControlCharacterOrIsLong() throws {
        let rows: [[String: Any]] = [["env": "DM_C", "kind": "choice", "section": "x", "label": "x", "note": "", "default": "a",
                                      "options": [["a", "A"], ["b\nc", "B"], ["d\u{0}e", "C"], ["f\tg", "D"], ["h\u{7f}", "E"]]],
                                     ["env": "DM_T", "kind": "toggle", "section": "x", "label": "x", "note": "", "default": "a", "on": "a\n", "off": "b"]]
        let read = try XCTUnwrap(GameOptionsReader.parse(OptionsFixture.json(rows), allowing: any))
        XCTAssertEqual(read[0].options, [["a", "A"]], "the game's own list cannot offer one either")
        for v in ["b\nc", "d\u{0}e", "a\n", "a\r", "a\u{0}", "\u{1b}[0m"] {
            for r in read + (try five()) { XCTAssertNil(GameOptionsReader.validate(v, for: r), "\(r.env) \(v.debugDescription)") }
        }
        let scale = try row("DM_RENDER_SCALE"), fps = try row("DM_FPS_TARGET")
        XCTAssertNil(GameOptionsReader.validate("0.75\n", for: scale))
        XCTAssertNil(GameOptionsReader.validate("30\n", for: fps))
        XCTAssertNil(GameOptionsReader.validate(String(repeating: "3", count: GameOptionsReader.maxValue + 1), for: fps))
    }
}
#endif
