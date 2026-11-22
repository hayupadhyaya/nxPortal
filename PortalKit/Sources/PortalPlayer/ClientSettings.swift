import Foundation
import PortalKit

/// The in-play menu's controller trigger: Menu and Options held together for 0.5 s, or none -> .claude/client.md § input
public enum MenuChord: String, Codable, Sendable { case plusMinus, off }

/// User-adjustable client settings -> .claude/client.md § settings
public struct ClientSettings: Codable, Equatable, Sendable {
    public enum PadLayout: String, Codable, Sendable { case auto, byLabel, byPosition }
    public enum DeviceMotion: String, Codable, Sendable { case auto, always, never }

    public var maxWidth: UInt16 = 1920
    public var maxHeight: UInt16 = 1080
    public var maxFps: UInt8 = 60
    /// 10...100; the sound output clamps it.
    public var audioBufferMs = 25
    /// The sound buffer follows the link (`SoundBufferTarget`); `audioBufferMs` is the fixed value when false.
    public var audioBufferAuto = true
    public var padLayout = PadLayout.auto
    public var deviceMotion = DeviceMotion.auto

    /// Wished stream bitrate in Mbit/s (the Host caps it); applies to the next connection.
    public var bitrateMbps = 50
    public var picturePacing = PicturePacing.smooth
    /// The numbers panel: off / fps / compact / full. A saved legacy `showStats` (read, never written) is `compact` / `off`.
    public var statsLevel = PanelLevel.fps
    /// Off: the session plays no sound (applies to a running session too -> .claude/client.md § settings).
    public var playSound = true
    public var menuChord = MenuChord.plusMinus
    /// A light tap when an on-screen control is pressed (iPhone and iPad).
    public var touchHaptics = true
    /// The on-screen layout of a game never given its own (`TouchLayoutStore`).
    public var touchLayoutDefault = TouchLayout.flat
    /// Each session writes a small numbers file on this device -> .claude/client.md § recorder
    public var recordSessions = true
    /// What this device calls itself to a Mac; empty = the model's name -> .claude/client.md § settings
    public static let maxDeviceNameCharacters = 200
    /// Bounded to `maxDeviceNameCharacters` on entry and on decode; cleaned where it is used (typing keeps its spaces).
    public var deviceName = "" {
        didSet { if deviceName.count > Self.maxDeviceNameCharacters { deviceName = String(deviceName.prefix(Self.maxDeviceNameCharacters)) } }
    }
    /// 2: `picturePacing` defaults to `smooth`; a saved version 1 (key absent) is moved to it once on decoding.
    public var settingsVersion = 2

    public init() {}

    /// `showStats` is decoded only (the pre-level on / off); `encode(to:)` never writes it.
    private enum CodingKeys: String, CodingKey {
        case maxWidth, maxHeight, maxFps, audioBufferMs, audioBufferAuto, padLayout, deviceMotion, bitrateMbps, picturePacing
        case statsLevel, playSound, showStats, menuChord, recordSessions, settingsVersion, touchHaptics, touchLayoutDefault, deviceName
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxWidth, forKey: .maxWidth); try c.encode(maxHeight, forKey: .maxHeight); try c.encode(maxFps, forKey: .maxFps)
        try c.encode(audioBufferMs, forKey: .audioBufferMs); try c.encode(audioBufferAuto, forKey: .audioBufferAuto)
        try c.encode(padLayout, forKey: .padLayout); try c.encode(deviceMotion, forKey: .deviceMotion)
        try c.encode(bitrateMbps, forKey: .bitrateMbps); try c.encode(picturePacing, forKey: .picturePacing)
        try c.encode(statsLevel, forKey: .statsLevel); try c.encode(playSound, forKey: .playSound)
        try c.encode(menuChord, forKey: .menuChord); try c.encode(recordSessions, forKey: .recordSessions)
        try c.encode(settingsVersion, forKey: .settingsVersion)
        try c.encode(touchHaptics, forKey: .touchHaptics); try c.encode(touchLayoutDefault, forKey: .touchLayoutDefault)
        try c.encode(deviceName, forKey: .deviceName)
    }

    /// Every key optional: settings saved by an older build (without the newer keys) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClientSettings()
        maxWidth = try c.decodeIfPresent(UInt16.self, forKey: .maxWidth) ?? d.maxWidth
        maxHeight = try c.decodeIfPresent(UInt16.self, forKey: .maxHeight) ?? d.maxHeight
        maxFps = try c.decodeIfPresent(UInt8.self, forKey: .maxFps) ?? d.maxFps
        audioBufferMs = try c.decodeIfPresent(Int.self, forKey: .audioBufferMs) ?? d.audioBufferMs
        audioBufferAuto = try c.decodeIfPresent(Bool.self, forKey: .audioBufferAuto) ?? d.audioBufferAuto
        padLayout = (try? c.decodeIfPresent(PadLayout.self, forKey: .padLayout)) ?? d.padLayout
        deviceMotion = (try? c.decodeIfPresent(DeviceMotion.self, forKey: .deviceMotion)) ?? d.deviceMotion
        let version = (try? c.decodeIfPresent(Int.self, forKey: .settingsVersion)) ?? 1
        if version < 2 {
            picturePacing = d.picturePacing   // the saved `immediate` was the old default, not a choice
            settingsVersion = d.settingsVersion
        } else {
            picturePacing = (try? c.decodeIfPresent(PicturePacing.self, forKey: .picturePacing)) ?? d.picturePacing
            settingsVersion = version
        }
        bitrateMbps = min(max((try? c.decodeIfPresent(Int.self, forKey: .bitrateMbps)) ?? d.bitrateMbps, 1), 1000)
        if let level = (try? c.decodeIfPresent(PanelLevel.self, forKey: .statsLevel)) {
            statsLevel = level
        } else if let legacy = (try? c.decodeIfPresent(Bool.self, forKey: .showStats)) {
            statsLevel = legacy ? .compact : .off
        }
        playSound = (try? c.decodeIfPresent(Bool.self, forKey: .playSound)) ?? d.playSound
        recordSessions = try c.decodeIfPresent(Bool.self, forKey: .recordSessions) ?? d.recordSessions
        menuChord = (try? c.decodeIfPresent(MenuChord.self, forKey: .menuChord)) ?? d.menuChord
        touchHaptics = (try? c.decodeIfPresent(Bool.self, forKey: .touchHaptics)) ?? d.touchHaptics
        touchLayoutDefault = (try? c.decodeIfPresent(TouchLayout.self, forKey: .touchLayoutDefault)) ?? d.touchLayoutDefault
        deviceName = String(((try? c.decodeIfPresent(String.self, forKey: .deviceName)) ?? d.deviceName).prefix(Self.maxDeviceNameCharacters))
    }
}
