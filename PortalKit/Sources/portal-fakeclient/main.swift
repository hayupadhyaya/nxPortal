#if os(macOS)
import Foundation
import Network
import PortalClientCore
import PortalPlayer
import PortalKit
import PortalTestSupport

/// portal-fakeclient -> .claude/client.md § fakeclient. Output carries no addresses and no key material.
let usage = """
usage: portal-fakeclient --host <host:port | Bonjour name> [--pair <code>] [--list] [--launch <titleID>] [--resume] [--quit]
       [--seconds <n>] [--out <dir>] [--press <button>@<seconds>,...] [--store <file>] [--name <name>] [--host-name <name>] [--bitrate <Mbit/s>]
       [--decode]
       [--shape <profile>] [--seed <n>]   (a simulated bad network between this client and the Host: \(LinkProfile.names.joined(separator: ", ")); `random` draws a fresh seed unless --seed is given, and prints it)

"""

func fail(_ text: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data(text.utf8))
    exit(code)
}

func say(_ line: String) { print(line); fflush(stdout) }

struct Store: Codable {
    var identity: Data
    var hosts: [PairedPeer]
}

var host: String?, pairCode: String?, launchID: String?, outDir: String?, hostName: String?
var list = false, resume = false, quit = false, decode = false
var seconds = 10.0
var presses: [(at: Double, buttons: PadButtons)] = []
var storePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/nxportal/fakeclient.json").path
var clientName = "fakeclient"
var bitrateWish: UInt32?
var shapeProfile: LinkProfile?
var shapeName = ""
var shapeSeed: UInt64?

var args = CommandLine.arguments.dropFirst()
@MainActor func value() -> String { guard let v = args.popFirst() else { fail(usage) }; return v }
while let arg = args.popFirst() {
    switch arg {
    case "--host": host = value()
    case "--pair": pairCode = value()
    case "--list": list = true
    case "--launch": launchID = value()
    case "--resume": resume = true
    case "--quit": quit = true
    case "--decode": decode = true
    case "--seconds": guard let n = Double(value()), n >= 0 else { fail(usage) }; seconds = n
    case "--out": outDir = value()
    case "--store": storePath = value()
    case "--name": clientName = value()
    case "--host-name": hostName = value()
    case "--bitrate": guard let n = UInt32(value()), n >= 1, n <= 1000 else { fail(usage) }; bitrateWish = n * 1_000_000
    case "--shape":
        let name = value()
        guard let p = LinkProfile.named(name) else {
            FileHandle.standardError.write(Data("unknown --shape profile; valid: \(LinkProfile.names.joined(separator: ", "))\n".utf8))
            exit(64)
        }
        shapeProfile = p
        shapeName = name
    case "--seed": guard let n = UInt64(value()) else { fail(usage) }; shapeSeed = n
    case "--press":
        for item in value().split(separator: ",") {
            let parts = item.split(separator: "@")
            guard parts.count == 2, let t = Double(parts[1]), let b = PadButtons(name: String(parts[0])) else {
                fail("unknown button or bad time in --press\n")
            }
            presses.append((t, b))
        }
    default: fail(usage)
    }
}
guard let host else { fail(usage) }
if shapeProfile != nil, !(host.hasPrefix("127.0.0.1:") || host.hasPrefix("localhost:")) {
    fail("--shape relays over loopback: use --host 127.0.0.1:<port> (a Host on this Mac)\n")
}
presses.sort { $0.at < $1.at }

// MARK: store

@MainActor func loadStore() -> (Identity, [PairedPeer]) {
    if let data = FileManager.default.contents(atPath: storePath),
       let s = try? JSONDecoder().decode(Store.self, from: data), let id = try? Identity(rawPrivateKey: s.identity) {
        return (id, s.hosts)
    }
    return (Identity(), [])
}

@MainActor func saveStore(_ identity: Identity, _ hosts: [PairedPeer]) {
    let url = URL(fileURLWithPath: storePath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    guard let data = try? JSONEncoder().encode(Store(identity: identity.rawPrivateKey, hosts: hosts)) else { return }
    let tmp = url.appendingPathExtension("tmp")
    guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]),
          (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) != nil else {
        fail("cannot write the store\n", code: 1)
    }
}

// MARK: outputs

func littleEndian32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
func littleEndian16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

/// 48 kHz, 16-bit, stereo; the sizes are patched in when the file is finished.
final class WavFile {
    private let handle: FileHandle
    private var bytes: UInt32 = 0

    init?(path: String) {
        guard FileManager.default.createFile(atPath: path, contents: nil), let h = FileHandle(forWritingAtPath: path) else { return nil }
        handle = h
        write(header())
    }

    private func write(_ d: Data) { try? handle.write(contentsOf: d) }

    private func header() -> Data {
        var d = Data("RIFF".utf8) + littleEndian32(36 + bytes) + Data("WAVEfmt ".utf8)
        d += littleEndian32(16) + littleEndian16(1) + littleEndian16(2) + littleEndian32(48_000)
        d += littleEndian32(48_000 * 4) + littleEndian16(4) + littleEndian16(16)
        return d + Data("data".utf8) + littleEndian32(bytes)
    }

    func append(_ pcm: Data) { write(pcm); bytes += UInt32(pcm.count) }

    func finish() {
        try? handle.seek(toOffset: 0)
        write(header())
        try? handle.close()
    }
}

// MARK: run

/// The longest time between two pictures over the run (the first one is the start, not a gap), and the rate over the run.
final class GapTracker: @unchecked Sendable {
    private let lock = NSLock()  // guards last, longest
    private var first: UInt64?, last: UInt64?
    private var count = 0
    private var longest: UInt64 = 0
    func frame() {
        let now = uptimeNs()
        lock.withLock { if let last { longest = max(longest, now &- last) } else { first = now }; last = now; count += 1 }
    }
    /// Pictures a second from the first to the last (a window that survives the game leaving); nil under two pictures.
    var runFps: Double? {
        lock.withLock {
            guard let first, let last, count > 1, last > first else { return nil }
            return Double(count - 1) / (Double(last - first) / 1e9)
        }
    }
    var longestMs: Double { Double(lock.withLock { longest }) / 1e6 }
}

/// The newest game state seen, and whether an `idle` arrived since `--quit` was sent.
var lastRun: GameRunState?
var idleSinceQuit = false

@MainActor func endpoint(for host: String) -> NWEndpoint {
    if let i = host.lastIndex(of: ":"), let port = UInt16(host[host.index(after: i)...]), let p = NWEndpoint.Port(rawValue: port) {
        return .hostPort(host: NWEndpoint.Host(String(host[..<i])), port: p)
    }
    return .service(name: host, type: "_nxportal._tcp", domain: "local", interface: nil)
}

@MainActor func run() async -> Int32 {
    var (identity, hosts) = loadStore()
    // --shape: a LinkShaper in this process carries the media; it learns the Host's media port from the `welcome`.
    let seed = LinkProfile.seed(for: shapeName, given: shapeSeed)
    let shaper = shapeProfile.map { LinkShaper(profile: $0, seed: seed, to: ("127.0.0.1", 0)) }
    if let shaper { say("shaper: profile=\(shapeName) seed=\(shaper.seed)") }
    var via: (host: String, port: UInt16)?
    var learnPort: (@Sendable (UInt16) -> Void)?
    if let shaper {
        guard let port = try? shaper.start() else { fail("cannot start the shaper\n", code: 1) }
        via = ("127.0.0.1", port)
        learnPort = { shaper.setHostPort($0) }
    }
    defer { shaper?.stop() }
    let session = ClientSession(identity: identity, name: clientName, kind: .tool, maxWidth: 1280, maxHeight: 720, maxFps: 60,
                                bitrate: bitrateWish, mediaVia: via, mediaPortKnown: learnPort)
    var ok = true
    func step(_ what: String, _ body: () async throws -> Void) async -> Bool {
        do { try await body(); return true } catch { say("\(what) failed: \(error)"); ok = false; return false }
    }

    var out: FileHandle?, wav: WavFile?
    if let outDir {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let hevc = outDir + "/out.hevc"
        FileManager.default.createFile(atPath: hevc, contents: nil)
        out = FileHandle(forWritingAtPath: hevc)
        wav = WavFile(path: outDir + "/out.wav")
    }
    // --decode: every picture goes through the product's decoder and the session hears the result, as from the player.
    let (forwarded, forward) = AsyncStream.makeStream(of: AssembledFrame.self, bufferingPolicy: .unbounded)
    let decodeTask = decode ? Task { await DecodeReport.run(frames: forwarded, session: session, decoder: VideoDecoder()) } : nil
    let gaps = GapTracker()
    let frameTask = Task { [out] in
        defer { forward.finish() }
        for await f in session.frames {
            gaps.frame()
            try? out?.write(contentsOf: HEVC.annexB(f.data))
            if decode { forward.yield(f) }
        }
    }
    let audioTask = Task { [wav] in for await a in session.audio { wav?.append(a.pcm) } }
    let stateTask = Task { for await s in session.states {
            lastRun = s.run
            if s.run == .idle { idleSinceQuit = true }
            say("state: \(s.run.rawValue) \(s.reason ?? "")")
        }
    }

    guard await step("connect", { try await session.connect(to: endpoint(for: host)) }) else { return 1 }
    if let pairCode {
        guard await step("pair", {
            let peer = try await session.pair(code: pairCode)
            hosts.removeAll { $0.key == peer.key }
            hosts.append(peer)
            saveStore(identity, hosts)
        }) else { return 1 }
    }
    let chosen: PairedPeer?
    if let hostName { chosen = hosts.first { $0.name == hostName } } else { chosen = hosts.count == 1 ? hosts.first : nil }
    guard let chosen else {
        say("no paired Host to open (use --pair, or --host-name when several are stored)")
        return 2
    }
    guard await step("open", { try await session.open(host: chosen) }) else { return 1 }
    let opened = Date()
    if list {
        _ = await step("list") {
            for g in try await session.list() { say("\(g.titleID)\t\(g.name)\t\(g.streamable)\t\(g.state.rawValue)") }
        }
    }
    if resume { _ = await step("resume") { try await session.resume() } }
    if let launchID { _ = await step("launch") { try await session.launch(titleID: launchID) } }

    let pressTask = Task {
        for p in presses {
            try? await Task.sleep(nanoseconds: UInt64(max(0, p.at - Date().timeIntervalSince(opened)) * 1e9))
            await session.send(InputState(seq: 0, player: 0, buttons: p.buttons.rawValue, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil))
            try? await Task.sleep(nanoseconds: 200_000_000)
            await session.send(InputState(seq: 0, player: 0, buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil))
        }
    }
    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds - Date().timeIntervalSince(opened)) * 1e9))
    pressTask.cancel()

    if quit && lastRun != nil && lastRun != .idle {
        idleSinceQuit = false
        if await step("quit", { try await session.quitGame() }) {
            // The Host may take 5 s to end a game that ignores `quit`; `bye` right after would only pause it.
            let deadline = Date().addingTimeInterval(6)
            while !idleSinceQuit && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            if !idleSinceQuit { say("quit: no confirmation"); ok = false }
        }
    }
    await session.close()
    _ = await (frameTask.value, audioTask.value, stateTask.value)
    await decodeTask?.value
    // One moment for every number in the last line: the run is over, the decode backlog drained (`frameDecoded` is a no-op
    // once closed, so the acks are final), and the gap is read here too.
    let stats = await session.stats()
    let longestGapMs = gaps.longestMs, runFps = gaps.runFps
    try? out?.close()
    wav?.finish()
    say(stats.runLine(longestGapMs: longestGapMs, runFps: runFps))
    if let shaper {
        let c = shaper.counts
        say("shaper: forwarded=\(c.forwarded) dropped=\(c.dropped)")
    }
    if (launchID != nil || resume) && stats.framesShown == 0 { return 1 }
    return ok ? 0 : 1
}

exit(await run())
#endif
