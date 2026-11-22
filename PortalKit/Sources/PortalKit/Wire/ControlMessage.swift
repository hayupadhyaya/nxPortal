import Foundation

public enum DeviceKind: String, Codable, Sendable { case phone, tablet, tv, tool }
public enum GameRunState: String, Codable, Sendable { case idle, starting, running, paused }

public struct PairStart: Codable, Equatable, Sendable {
    public var clientKey: Data, clientEphemeral: Data, name: String
    public init(clientKey: Data, clientEphemeral: Data, name: String) {
        self.clientKey = clientKey; self.clientEphemeral = clientEphemeral; self.name = name
    }
}
public struct PairChallenge: Codable, Equatable, Sendable {
    public var hostKey: Data, hostEphemeral: Data, salt: Data, hostName: String
    public init(hostKey: Data, hostEphemeral: Data, salt: Data, hostName: String) {
        self.hostKey = hostKey; self.hostEphemeral = hostEphemeral; self.salt = salt; self.hostName = hostName
    }
}
public enum PairResult: Codable, Equatable, Sendable { case ok(hostProof: Data), wrongCode(triesLeft: Int), locked, expired }
public struct Hello: Codable, Equatable, Sendable {
    public var version: UInt16, clientKey: Data, ephemeral: Data, kind: DeviceKind, maxWidth: UInt16, maxHeight: UInt16, maxFps: UInt8
    /// Wished video bitrate in bit/s; absent = the Host's default.
    public var bitrate: UInt32?
    /// false: a library session (admission never resumes the game); absent or true: a device that paused the game resumes it
    /// by being admitted -> .claude/portalkit.md § session-rules
    public var resume: Bool?
    /// The video rate the device starts at, bit/s (its first `rate`, known at admission; the Host clamps it as a `rate`);
    /// absent = none until the first `rate` -> .claude/portalkit.md § wire-network
    public var startBps: UInt32?
    /// The device's cleaned name (`DeviceName.clean`, at most 120 bytes); absent = the Host keeps the name it has. The Host
    /// cleans it again -> .claude/portalkit.md § wire-network
    public var name: String?
    public init(version: UInt16, clientKey: Data, ephemeral: Data, kind: DeviceKind, maxWidth: UInt16, maxHeight: UInt16, maxFps: UInt8,
                bitrate: UInt32? = nil, resume: Bool? = nil, startBps: UInt32? = nil, name: String? = nil) {
        self.version = version; self.clientKey = clientKey; self.ephemeral = ephemeral; self.kind = kind
        self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.maxFps = maxFps
        self.bitrate = bitrate
        self.resume = resume
        self.startBps = startBps
        self.name = name
    }
}
public struct Welcome: Codable, Equatable, Sendable {
    public var ephemeral: Data, udpPort: UInt16, sessionID: UInt32
    public init(ephemeral: Data, udpPort: UInt16, sessionID: UInt32) {
        self.ephemeral = ephemeral; self.udpPort = udpPort; self.sessionID = sessionID
    }
}
public enum Refusal: Codable, Equatable, Sendable { case unpaired, busy(device: String), version(host: UInt16) }
/// A game's icon as the Host lists it: SHA-256 of the PNG (64 lowercase hex) and its size -> .claude/portalkit.md § wire-network
public struct ArtRef: Codable, Equatable, Sendable {
    public var hash: String
    public var bytes: UInt32
    public init(hash: String, bytes: UInt32) { self.hash = hash; self.bytes = bytes }
}

/// How an icon travels in `art` messages: raw chunks of at most `chunkBytes`, in order; at most `maxBytes` in all.
public enum ArtChunking {
    public static let chunkBytes = 48 * 1024
    public static let maxBytes = 512 * 1024
    /// Chunks of `bytes` (ceil(bytes / chunkBytes)); 0 for none.
    public static func count(bytes: Int) -> Int { bytes <= 0 ? 0 : (bytes + chunkBytes - 1) / chunkBytes }
}

/// How much the numbers panel shows on the device -> .claude/client.md § stats
public enum PanelLevel: String, Codable, Sendable, CaseIterable { case off, fps, compact, full }

/// What the Host can apply while a session runs, each part optional (absent = unchanged): the video bitrate ceiling
/// (bit/s; the Host clamps it like a `rate`, 0 is ignored) and the numbers panel level (`full` also asks the Host to
/// sample) -> .claude/portalkit.md § wire-network
public struct LiveSettings: Codable, Equatable, Sendable {
    public var ceilingBps: UInt32?
    public var panel: PanelLevel?
    public init(ceilingBps: UInt32? = nil, panel: PanelLevel? = nil) { self.ceilingBps = ceilingBps; self.panel = panel }
}

/// The 3D views' size a render scale multiplies, docked and handheld (the launcher's own `base`).
public struct OptionBase: Codable, Equatable, Sendable {
    /// `[width, height]` on the wire, as in `launcher.json`.
    public struct Size: Codable, Equatable, Sendable {
        public var width: Int, height: Int
        public init(width: Int, height: Int) { self.width = width; self.height = height }
        public init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            width = try c.decode(Int.self)
            height = try c.decode(Int.self)
            guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "a size is two numbers") }
            guard (1...OptionLimits.maxSize).contains(width), (1...OptionLimits.maxSize).contains(height) else { throw OptionRefusal() }
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(width)
            try c.encode(height)
        }
    }
    public var docked: Size, handheld: Size
    public init(docked: Size, handheld: Size) { self.docked = docked; self.handheld = handheld }
}

/// One setting of a game's own list (`launcher.json`) with its effective value. `kind` is the launcher's text (`choice`,
/// `range`, `toggle`); one this build does not know stays as it is (a read-only row, never dropped). `current` is the
/// app's choice, else the app's saved choice, else `defaultValue`; `chosen` = the app has a choice.
public struct OptionSetting: Codable, Equatable, Sendable {
    public var env: String, kind: String, section: String, label: String, note: String, defaultValue: String, current: String
    public var chosen: Bool
    /// choice: `[value, label]` pairs.
    public var options: [[String]]?
    public var min: Double?, max: Double?, step: Double?
    public var on: String?, off: String?
    public var base: OptionBase?
    public var level: String?
    /// `<VAR>=<value>`: drawn only while the row that sets `<VAR>` has that value.
    public var needs: String?
    private enum CodingKeys: String, CodingKey {
        case env, kind, section, label, note, defaultValue, current, chosen, options, min, max, step, on, off, base, level, needs
    }

    /// Bounded on the way in, on the Host and on a device alike (`OptionLimits`): a name, a value, a kind, a level or a `needs` over
    /// its byte limit, a control character in any text, more than `maxChoices` pairs (each exactly `[value, label]`), a range that
    /// is not finite, ordered and stepped, or a size outside 1...100 000 makes the whole message refused (`WireError.refused`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ k: CodingKeys) throws -> String {
            let s = try c.decode(String.self, forKey: k)
            guard OptionLimits.isPlainValue(s) else { throw OptionRefusal() }
            return s
        }
        func optionalValue(_ k: CodingKeys) throws -> String? { try c.contains(k) ? value(k) : nil }
        func text(_ k: CodingKeys) throws -> String {
            let s = try c.decode(String.self, forKey: k)
            guard OptionLimits.isPlainText(s) else { throw OptionRefusal() }
            return s
        }
        func short(_ k: CodingKeys, bytes: Int) throws -> String? {
            guard c.contains(k) else { return nil }
            let s = try c.decode(String.self, forKey: k)
            guard s.utf8.count <= bytes, OptionLimits.isPlainText(s) else { throw OptionRefusal() }
            return s
        }
        env = try c.decode(String.self, forKey: .env)
        guard OptionLimits.isEnvName(env) else { throw OptionRefusal() }
        kind = try short(.kind, bytes: OptionLimits.maxKindBytes) ?? ""
        section = try text(.section); label = try text(.label); note = try text(.note)
        defaultValue = try value(.defaultValue); current = try value(.current)
        chosen = try c.decode(Bool.self, forKey: .chosen)
        if c.contains(.options) {
            var list = try c.nestedUnkeyedContainer(forKey: .options)
            var pairs: [[String]] = []
            while !list.isAtEnd {
                guard pairs.count < OptionLimits.maxChoices else { throw OptionRefusal() }
                let pair = try list.decode([String].self)
                guard pair.count == 2, OptionLimits.isPlainValue(pair[0]), OptionLimits.isPlainText(pair[1]) else { throw OptionRefusal() }
                pairs.append(pair)
            }
            options = pairs
        } else { options = nil }
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
        step = try c.decodeIfPresent(Double.self, forKey: .step)
        for n in [min, max, step] { if let n, !n.isFinite { throw OptionRefusal() } }
        if let min, let max, min > max { throw OptionRefusal() }
        if let step, step <= 0 { throw OptionRefusal() }
        on = try optionalValue(.on); off = try optionalValue(.off)
        base = try c.decodeIfPresent(OptionBase.self, forKey: .base)
        level = try short(.level, bytes: OptionLimits.maxKindBytes)
        needs = try short(.needs, bytes: OptionLimits.maxNeedsBytes)
    }

    public init(env: String, kind: String, section: String, label: String, note: String, defaultValue: String, current: String,
                chosen: Bool, options: [[String]]? = nil, min: Double? = nil, max: Double? = nil, step: Double? = nil,
                on: String? = nil, off: String? = nil, base: OptionBase? = nil, level: String? = nil, needs: String? = nil) {
        self.env = env; self.kind = kind; self.section = section; self.label = label; self.note = note
        self.defaultValue = defaultValue; self.current = current; self.chosen = chosen; self.options = options
        self.min = min; self.max = max; self.step = step; self.on = on; self.off = off; self.base = base
        self.level = level; self.needs = needs
    }
}

/// A game's settings in the order the launcher lists them; `rejected` = the variable a `setOption` refused (absent otherwise).
public struct GameOptions: Codable, Equatable, Sendable {
    public var titleID: String, settings: [OptionSetting]
    public var rejected: String?
    /// Present (true) when a `setOption` was refused because the Mac keeps choices for as many games as it can and this game has
    /// none yet; absent otherwise (optional key inside protocol 4).
    public var full: Bool?
    private enum CodingKeys: String, CodingKey { case titleID, settings, rejected, full }

    /// At most `maxSettings` rows, a well-formed title ID, a `rejected` of at most `maxEnvBytes` plain bytes; each row bounded by
    /// `OptionSetting.init(from:)`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titleID = try c.decode(String.self, forKey: .titleID)
        guard TitleID.isWellFormed(titleID) else { throw OptionRefusal() }
        var list = try c.nestedUnkeyedContainer(forKey: .settings)
        var rows: [OptionSetting] = []
        while !list.isAtEnd {
            guard rows.count < OptionLimits.maxSettings else { throw OptionRefusal() }
            rows.append(try list.decode(OptionSetting.self))
        }
        settings = rows
        rejected = try c.decodeIfPresent(String.self, forKey: .rejected)
        if let rejected, rejected.utf8.count > OptionLimits.maxEnvBytes || !OptionLimits.isPlainText(rejected) { throw OptionRefusal() }
        full = try c.decodeIfPresent(Bool.self, forKey: .full)
    }

    public init(titleID: String, settings: [OptionSetting], rejected: String? = nil, full: Bool? = nil) {
        self.titleID = titleID; self.settings = settings; self.rejected = rejected; self.full = full
    }
}

public struct GameEntry: Codable, Equatable, Sendable {
    public var titleID: String, name: String, streamable: Bool, state: GameRunState
    /// Absent: the game has no icon (or the Host speaks without art).
    public var art: ArtRef?
    public init(titleID: String, name: String, streamable: Bool, state: GameRunState, art: ArtRef? = nil) {
        self.titleID = titleID; self.name = name; self.streamable = streamable; self.state = state; self.art = art
    }
}
/// The game's graphics preparation, the tap's own numbers: `phase` as the runtime numbers it (1 pipelines, 2 shader pairs,
/// others generic), `done` of `total` in that phase. `total` 0 = preparing with nothing to count (waiting for the game).
/// -> .claude/portalkit.md § wire-network
public struct Preparing: Codable, Equatable, Sendable {
    public var phase: UInt8, done: UInt32, total: UInt32
    public init(phase: UInt8, done: UInt32, total: UInt32) { self.phase = phase; self.done = done; self.total = total }
    /// Preparing with no progress to show.
    public static let waiting = Preparing(phase: 0, done: 0, total: 0)

    /// 0...1; never above the whole.
    public var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    /// "Preparing N %" wherever it is shown (the device and the Mac's menu): rounded, 100 only when it is done.
    public var percent: Int {
        guard total > 0 else { return 0 }
        return done >= total ? 100 : min(Int((fraction * 100).rounded()), 99)
    }
}

/// The size of the pictures the running game makes (what the Host's tap hands over, after the device's size cap).
/// `exact`: the game renders no more than this (the picture is under the cap on both sides); false = a side reaches the cap,
/// so the cap may have scaled the game down and it may render more -> .claude/portalkit.md § wire-network
public struct RenderSize: Codable, Equatable, Sendable {
    public var width: UInt16, height: UInt16, exact: Bool
    public init(width: UInt16, height: UInt16, exact: Bool) { self.width = width; self.height = height; self.exact = exact }

    /// The tap's fitted picture, rounded down to even sizes, can sit this far under a side that the cap held.
    public static let fitSlack: UInt16 = 2

    /// What the tap's picture of `width` x `height` under the cap says about the game: its own size (`exact`) only when
    /// NEITHER side reaches the cap (within `fitSlack`); else the cap may have scaled it down, a lower bound.
    public static func fitted(width: UInt16, height: UInt16, capWidth: UInt16, capHeight: UInt16) -> RenderSize {
        let reaches = { (side: UInt16, cap: UInt16) in side &+ fitSlack >= cap }
        return RenderSize(width: width, height: height, exact: !reaches(width, capWidth) && !reaches(height, capHeight))
    }
}

public struct GameState: Codable, Equatable, Sendable {
    public var titleID: String?, run: GameRunState, reason: String?
    /// Present while the game prepares before its first picture (or has made none for 2 s); never for a paused game.
    public var preparing: Preparing?
    /// Present from the game's first picture until it ends or a new game starts; absent before.
    public var render: RenderSize?
    public init(titleID: String?, run: GameRunState, reason: String?, preparing: Preparing? = nil, render: RenderSize? = nil) {
        self.titleID = titleID; self.run = run; self.reason = reason; self.preparing = preparing; self.render = render
    }
}

/// TCP control, each message framed by `ControlFramer` -> .claude/portalkit.md § wire-network
public enum ControlMessage: Codable, Equatable, Sendable {
    case pairStart(PairStart), pairChallenge(PairChallenge), pairProof(Data), pairResult(PairResult)
    case hello(Hello), welcome(Welcome), refuse(Refusal), ready
    case listRequest, list([GameEntry]), launch(titleID: String), resume, quitGame, gameState(GameState)
    /// Either side ends the session. Host to device, `takenBy`: the Mac is now in use on that device (a library session
    /// gave way to it, `portalkit.md § session-rules`); absent otherwise.
    case bye(takenBy: String? = nil)
    /// Device to Host: the icon `hash` of `titleID`. Answered by `art` chunks `0..<count` in order; `count` 0 = no such art.
    case artRequest(titleID: String, hash: String)
    case art(titleID: String, hash: String, index: UInt16, count: UInt16, bytes: Data)
    /// Device to Host, admitted phase only: the ceiling and the panel level -> .claude/portalkit.md § wire-network
    case liveSettings(LiveSettings)
    /// Per-game options, admitted phase, library or playing session -> .claude/portalkit.md § wire-network.
    /// Device to Host: the options of `titleID`; answered by `options`.
    case optionsRequest(titleID: String)
    /// Host to device: a game's own settings with the effective value of each. Also the answer to `setOption` and
    /// `resetOptions` (the new state; `rejected` names the variable a `setOption` refused).
    case options(GameOptions)
    /// Device to Host: set `env` of `titleID` for its next start to `value`, or remove the choice (`value` absent).
    case setOption(titleID: String, env: String, value: String?)
    /// Device to Host: remove every choice for `titleID`; answered by `options`.
    case resetOptions(titleID: String)

    /// The only JSON coder configuration in the package.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    /// A public or ephemeral key's length (Curve25519, raw).
    public static let keyBytes = 32

    /// `WireError.refused`: an options message over the limits of `OptionLimits` (a title that is not a title ID, a name over 64
    /// bytes, a value over 128 bytes, a list over its bounds), or a `launch` whose title is not a title ID: whoever reads it
    /// ignores it and the session goes on. `WireError.malformed`: anything else that does not decode, and a `hello` /
    /// `pairStart` key longer than `keyBytes`. Clipped, never refused: a `hello` / `pairStart` name, cut to `DeviceName`'s
    /// limits -> .claude/portalkit.md § wire-network
    public init(decoding data: Data) throws {
        let decoded: ControlMessage
        do { decoded = try JSONDecoder().decode(ControlMessage.self, from: data) } catch is OptionRefusal { throw WireError.refused } catch { throw WireError.malformed }
        switch decoded {
        case var .hello(h):
            guard h.clientKey.count <= Self.keyBytes, h.ephemeral.count <= Self.keyBytes else { throw WireError.malformed }
            h.name = h.name.map { DeviceName.clip($0) }
            self = .hello(h)
            return
        case var .pairStart(p):
            guard p.clientKey.count <= Self.keyBytes, p.clientEphemeral.count <= Self.keyBytes else { throw WireError.malformed }
            p.name = DeviceName.clip(p.name)
            self = .pairStart(p)
            return
        case let .launch(titleID):
            guard TitleID.isWellFormed(titleID) else { throw WireError.refused }
        case let .optionsRequest(titleID), let .resetOptions(titleID):
            guard TitleID.isWellFormed(titleID) else { throw WireError.refused }
        case let .setOption(titleID, env, value):
            guard TitleID.isWellFormed(titleID), env.utf8.count <= OptionLimits.maxEnvBytes,
                  (value?.utf8.count ?? 0) <= OptionLimits.maxValueBytes else { throw WireError.refused }
        default: break
        }
        self = decoded
    }
}

public struct ControlFramer: Sendable {
    private var buffer: LengthPrefixedBuffer

    /// The longest message a reader accepts (1 MiB); `framed` refuses to send more.
    public static let maxMessage = 1 << 20

    public init(maxMessage: Int = ControlFramer.maxMessage) { buffer = LengthPrefixedBuffer(maxMessage: maxMessage) }

    public mutating func push(_ bytes: Data) throws -> [Data] { try buffer.push(bytes) }
    public static func frame(_ payload: Data) -> Data { LengthPrefixedBuffer.frame(payload) }

    /// `frame`, but throws `WireError.tooLarge` for a payload the reader would refuse (over `maxMessage`).
    public static func framed(_ payload: Data) throws -> Data {
        guard payload.count <= maxMessage else { throw WireError.tooLarge }
        return LengthPrefixedBuffer.frame(payload)
    }
}
