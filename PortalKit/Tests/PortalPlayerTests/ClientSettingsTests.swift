import XCTest
import PortalKit
@testable import PortalPlayer

final class ClientSettingsTests: XCTestCase {
    func testDefaults() {
        let s = ClientSettings()
        XCTAssertEqual(s.picturePacing, .smooth)
        XCTAssertEqual(s.statsLevel, .fps)
        XCTAssertTrue(s.playSound)
    }

    /// The device's own name: empty by default (the model's name), kept through a round trip, absent in an old file.
    func testTheDeviceNameIsEmptyByDefaultAndAnAbsentKeyDecodesToIt() throws {
        XCTAssertEqual(ClientSettings().deviceName, "")
        let old = try JSONDecoder().decode(ClientSettings.self, from: Data(#"{"maxWidth":1280}"#.utf8))
        XCTAssertEqual(old.deviceName, "")
        var s = ClientSettings()
        s.deviceName = "Den iPad"
        let back = try JSONDecoder().decode(ClientSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.deviceName, "Den iPad")
        let wrong = try JSONDecoder().decode(ClientSettings.self, from: Data(#"{"deviceName":5}"#.utf8))
        XCTAssertEqual(wrong.deviceName, "", "a value of another type is the default")
    }

    /// The stored name is bounded on decode and on entry (200 characters); it is cleaned where it is used.
    func testTheStoredDeviceNameIsBounded() throws {
        let long = String(repeating: "a", count: 5_000)
        let decoded = try JSONDecoder().decode(ClientSettings.self, from: JSONSerialization.data(withJSONObject: ["deviceName": long]))
        XCTAssertEqual(decoded.deviceName.count, ClientSettings.maxDeviceNameCharacters)
        var s = ClientSettings()
        s.deviceName = long
        XCTAssertEqual(s.deviceName.count, 200)
        s.deviceName = "Den iPad "
        XCTAssertEqual(s.deviceName, "Den iPad ", "typing keeps a trailing space")
    }

    /// The sound buffer follows the link unless a fixed value was chosen.
    func testAutomaticSoundBufferIsTheDefaultAndAnAbsentKeyDecodesToIt() throws {
        XCTAssertTrue(ClientSettings().audioBufferAuto)
        let old = #"{"maxWidth":1280,"audioBufferMs":50}"#
        let s = try JSONDecoder().decode(ClientSettings.self, from: Data(old.utf8))
        XCTAssertTrue(s.audioBufferAuto)
        XCTAssertEqual(s.audioBufferMs, 50)
        let v2 = #"{"settingsVersion":2,"picturePacing":"immediate","audioBufferMs":75}"#
        let t = try JSONDecoder().decode(ClientSettings.self, from: Data(v2.utf8))
        XCTAssertTrue(t.audioBufferAuto, "a version 2 value without the key is automatic")
        XCTAssertEqual(t.settingsVersion, 2)
        XCTAssertEqual(t.picturePacing, .immediate)
    }

    func testAFixedSoundBufferSurvivesARoundTrip() throws {
        var s = ClientSettings()
        s.audioBufferAuto = false
        s.audioBufferMs = 75
        let back = try JSONDecoder().decode(ClientSettings.self, from: JSONEncoder().encode(s))
        XCTAssertFalse(back.audioBufferAuto)
        XCTAssertEqual(back.audioBufferMs, 75)
    }

    /// Settings saved before the pacing fields existed still load, with the defaults for the new ones.
    func testOldSavedSettingsStillDecode() throws {
        let old = #"{"maxWidth":1280,"maxHeight":720,"maxFps":30,"audioBufferMs":50,"padLayout":"byLabel","deviceMotion":"never"}"#
        let s = try JSONDecoder().decode(ClientSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.maxWidth, 1280); XCTAssertEqual(s.audioBufferMs, 50); XCTAssertEqual(s.padLayout, .byLabel)
        XCTAssertEqual(s.picturePacing, .smooth, "an absent key takes the default")
        XCTAssertEqual(s.statsLevel, .fps)
    }

    /// Version 1 (no key) wrote `immediate` as the old default: it moves to `smooth` once.
    func testVersionOneImmediateMovesToSmooth() throws {
        let old = #"{"maxWidth":1280,"picturePacing":"immediate"}"#
        let s = try JSONDecoder().decode(ClientSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.picturePacing, .smooth)
        XCTAssertEqual(s.settingsVersion, 2)
    }

    /// An `immediate` chosen after the update (version 2) is kept.
    func testVersionTwoImmediateIsKept() throws {
        let json = #"{"settingsVersion":2,"picturePacing":"immediate"}"#
        let s = try JSONDecoder().decode(ClientSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.picturePacing, .immediate)
        XCTAssertEqual(s.settingsVersion, 2)
        let later = try JSONDecoder().decode(ClientSettings.self, from: Data(#"{"settingsVersion":5,"picturePacing":"immediate"}"#.utf8))
        XCTAssertEqual(later.picturePacing, .immediate)
        XCTAssertEqual(later.settingsVersion, 5, "a higher version is kept as it is")
    }

    func testImmediateRoundTripKeepsVersion() throws {
        var s = ClientSettings(); s.picturePacing = .immediate
        let back = try JSONDecoder().decode(ClientSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.picturePacing, .immediate)
        XCTAssertEqual(back.settingsVersion, 2)
    }

    func testMigrationKeepsTheOtherFields() throws {
        let old = #"{"maxWidth":1280,"maxHeight":720,"maxFps":30,"audioBufferMs":50,"padLayout":"byLabel","deviceMotion":"never","bitrateMbps":80,"picturePacing":"immediate","showStats":false}"#
        let s = try JSONDecoder().decode(ClientSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.picturePacing, .smooth)
        XCTAssertEqual(s.maxWidth, 1280); XCTAssertEqual(s.maxHeight, 720); XCTAssertEqual(s.maxFps, 30)
        XCTAssertEqual(s.audioBufferMs, 50); XCTAssertEqual(s.padLayout, .byLabel); XCTAssertEqual(s.deviceMotion, .never)
        XCTAssertEqual(s.bitrateMbps, 80); XCTAssertEqual(s.statsLevel, .off)
    }

    func testRoundTrip() throws {
        var s = ClientSettings(); s.picturePacing = .smooth; s.statsLevel = .off
        let back = try JSONDecoder().decode(ClientSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testBitrateDefaultAndRoundTrip() throws {
        XCTAssertEqual(ClientSettings().bitrateMbps, 50)
        var s = ClientSettings()
        s.bitrateMbps = 150
        let back = try JSONDecoder().decode(ClientSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.bitrateMbps, 150)
        XCTAssertEqual(try JSONDecoder().decode(ClientSettings.self, from: Data("{}".utf8)).bitrateMbps, 50)
    }

    func testBitrateIsClampedOnLoad() throws {
        func load(_ v: String) throws -> Int {
            try JSONDecoder().decode(ClientSettings.self, from: Data(#"{"bitrateMbps":\#(v)}"#.utf8)).bitrateMbps
        }
        XCTAssertEqual(try load("9000000000000000000"), 1000)
        XCTAssertEqual(try load("-5"), 1)
        XCTAssertEqual(try load("0"), 1)
        XCTAssertEqual(try load("150"), 150)
    }

    /// A value a later build wrote and this one does not know falls back for that key only.
    func testUnknownEnumValueFallsBackPerKey() throws {
        let json = #"{"maxWidth":1280,"picturePacing":"turbo","padLayout":"sideways","audioBufferMs":75}"#
        let s = try JSONDecoder().decode(ClientSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.picturePacing, .smooth)
        XCTAssertEqual(s.padLayout, .auto)
        XCTAssertEqual(s.maxWidth, 1280); XCTAssertEqual(s.audioBufferMs, 75)
    }

    func testMenuChordDefaultsAndRoundTrips() throws {
        XCTAssertEqual(ClientSettings().menuChord, .plusMinus)
        let old = try JSONDecoder().decode(ClientSettings.self, from: Data(#"{"settingsVersion":2,"maxWidth":1280}"#.utf8))
        XCTAssertEqual(old.menuChord, .plusMinus, "an absent key is the default")
        let bad = try JSONDecoder().decode(ClientSettings.self, from: Data(#"{"settingsVersion":2,"menuChord":"triple"}"#.utf8))
        XCTAssertEqual(bad.menuChord, .plusMinus, "an unknown value is the default")
        var off = ClientSettings(); off.menuChord = .off
        let back = try JSONDecoder().decode(ClientSettings.self, from: JSONEncoder().encode(off))
        XCTAssertEqual(back.menuChord, .off)
    }

    // MARK: numbers panel level and sound (network 4 plan, Task 4)

    private func load(_ json: String) throws -> ClientSettings {
        try JSONDecoder().decode(ClientSettings.self, from: Data(json.utf8))
    }

    /// `showStats` is a legacy input: it decides `statsLevel` only when that key is absent.
    func testTheLegacyShowStatsKeyBecomesALevel() throws {
        XCTAssertEqual(try load(#"{"showStats": true}"#).statsLevel, .compact)
        XCTAssertEqual(try load(#"{"showStats": false}"#).statsLevel, .off)
        XCTAssertEqual(try load("{}").statsLevel, .fps)
        XCTAssertEqual(try load(#"{"statsLevel":"full","showStats":false}"#).statsLevel, .full, "the new key wins")
        XCTAssertEqual(try load(#"{"statsLevel":"nonsense","showStats":true}"#).statsLevel, .compact, "an unknown level falls back to the legacy key")
    }

    func testAStatsLevelSurvivesSaveAndLoadAndShowStatsIsNeverWritten() throws {
        for level in PanelLevel.allCases {
            var s = ClientSettings(); s.statsLevel = level
            let data = try JSONEncoder().encode(s)
            XCTAssertEqual(try JSONDecoder().decode(ClientSettings.self, from: data).statsLevel, level)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("showStats"))
        }
    }

    func testPlaySoundDefaultsToOnAndSurvivesARoundTrip() throws {
        XCTAssertTrue(try load("{}").playSound)
        var s = ClientSettings(); s.playSound = false
        XCTAssertFalse(try JSONDecoder().decode(ClientSettings.self, from: JSONEncoder().encode(s)).playSound)
    }

    func testTouchSettingsDefaultAndDecodeFromOlderFiles() throws {
        XCTAssertTrue(ClientSettings().touchHaptics)
        XCTAssertEqual(ClientSettings().touchLayoutDefault, .flat)
        let old = try JSONDecoder().decode(ClientSettings.self, from: Data(#"{"maxWidth":1280}"#.utf8))
        XCTAssertTrue(old.touchHaptics); XCTAssertEqual(old.touchLayoutDefault, .flat)
        var s = ClientSettings(); s.touchHaptics = false; s.touchLayoutDefault = .full
        let back = try JSONDecoder().decode(ClientSettings.self, from: JSONEncoder().encode(s))
        XCTAssertFalse(back.touchHaptics); XCTAssertEqual(back.touchLayoutDefault, .full)
        let bad = try JSONDecoder().decode(ClientSettings.self, from: Data(#"{"touchLayoutDefault":"4d"}"#.utf8))
        XCTAssertEqual(bad.touchLayoutDefault, .flat)
    }
}
