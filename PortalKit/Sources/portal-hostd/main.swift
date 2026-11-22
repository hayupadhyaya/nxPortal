#if os(macOS)
import Foundation
import PortalHostCore
import PortalTestSupport
import SystemConfiguration

/// portal-hostd -> .claude/host.md § hostd. Output carries no addresses and no key material.
let usage = "usage: portal-hostd --library <dir>... [--store <file>] [--name <name>] [--port <n>] [--pair] [--fake [--fake-shelf] [--fake-options] [--fake-prepare <s>] [--fake-white]] [--max-bitrate <Mbit/s>] [--pace-ms <ms> (default 4)] [--pace-peak <x>]\n       [--shape <profile> [--seed <n>]]   (development: a simulated bad network in front of the media port; profiles: \(LinkProfile.names.joined(separator: ", ")))\n"

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data(text.utf8))
    exit(2)
}

func say(_ line: String) { print(line); fflush(stdout) }

let home = FileManager.default.homeDirectoryForCurrentUser
var roots: [URL] = []
var store = home.appendingPathComponent("Library/Application Support/nxPortal/host.json")
var name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
var port: UInt16 = 0
var pair = false
var fake = false
var fakeShelf = false
var fakeOptions = false
var fakePrepare: Double = 0
var fakeWhite = false
var maxBitrate = HostDefaults.maxBitrate
var paceMs = HostConfig.defaultPaceMs
var pacePeak = 3.0
var shapeName: String?
var shapeSeed: UInt64?

var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--library":
        guard let first = args.popFirst() else { fail(usage) }
        roots.append(URL(fileURLWithPath: first))
        while let next = args.first, !next.hasPrefix("--") { roots.append(URL(fileURLWithPath: next)); args.removeFirst() }
    case "--store":
        guard let v = args.popFirst() else { fail(usage) }
        store = URL(fileURLWithPath: v)
    case "--name":
        guard let v = args.popFirst() else { fail(usage) }
        name = v
    case "--port":
        guard let v = args.popFirst().flatMap({ UInt16($0) }) else { fail(usage) }
        port = v
    case "--pair": pair = true
    case "--fake": fake = true
    case "--fake-shelf": fakeShelf = true
    case "--fake-options": fakeOptions = true
    case "--fake-white": fakeWhite = true
    case "--fake-prepare":
        guard let v = args.popFirst().flatMap({ Double($0) }), v > 0, v <= 3600 else { fail(usage) }
        fakePrepare = v
    case "--max-bitrate":
        guard let v = args.popFirst().flatMap({ UInt32($0) }), v >= 1, v <= 1000 else { fail(usage) }
        maxBitrate = v * 1_000_000
    case "--shape":
        guard let v = args.popFirst() else { fail(usage) }
        guard LinkProfile.named(v) != nil else {
            FileHandle.standardError.write(Data("unknown --shape profile; valid: \(LinkProfile.names.joined(separator: ", "))\n".utf8))
            exit(64)
        }
        shapeName = v
    case "--seed":
        guard let v = args.popFirst().flatMap({ UInt64($0) }) else { fail(usage) }
        shapeSeed = v
    case "--pace-peak":
        guard let v = args.popFirst().flatMap({ Double($0) }), v >= 1, v <= 20 else { fail(usage) }
        pacePeak = v
    case "--pace-ms":
        guard let v = args.popFirst().flatMap({ Double($0) }), v >= 0, v <= 16 else { fail(usage) }
        paceMs = v
    default: fail(usage)
    }
}
if roots.isEmpty && !fake { fail(usage) }

let library = GameLibrary(roots: roots)
// --fake-white: every picture is white (screenshots of the trouble screens over the worst picture)
// --fake-prepare <s>: the fake game prepares for that long (three progress messages spread over it) before its first picture
let fakeLauncher = FakeLauncher(stall: fakePrepare, solidColor: fakeWhite ? 0xFFFF_FFFF : nil)
// Fake game only: one line per change of player 0's buttons, so a test can see a press arrive.
fakeLauncher.onButtons = { say(String(format: "fake game input: buttons=0x%08x", UInt32(truncatingIfNeeded: $0))) }
let launcher: any GameLaunching = fake ? fakeLauncher : AppLauncher(
    apps: { id in library.scan().first { $0.titleID == id }?.url },
    logDirectory: home.appendingPathComponent("Library/Logs/nxPortal"))
// --fake: the fake game's icon, and with --fake-shelf more placeholder games, are drawn in code into a temporary
// folder that goes at exit; no artwork from anywhere else -> .claude/host.md § hostd
let artFolder = FileManager.default.temporaryDirectory.appendingPathComponent("portal-hostd-art-" + UUID().uuidString)
func fakeGames(shelf withShelf: Bool, options withOptions: Bool) -> [GameApp] {
    var shelf: [(id: String, name: String, streamable: Bool, paint: FakeArt.Paint?)] =
        [("FAKE000000000000", "Fake Game", true, .gradient(0x3F66F2, 0xFF6B6B))]
    if withShelf {
        shelf += [("FAKE000000000001", "Sample Orbit", true, .gradient(0x30D158, 0x0A3D62)),
                  ("FAKE000000000002", "Sample Lantern", true, .gradient(0xFFB547, 0xB23A48)),
                  ("FAKE000000000003", "Sample Tide", true, .flat(0x1E90C8)),
                  ("FAKE000000000004", "Sample Moss", false, .gradient(0x6FBF4A, 0x1F3B1A)),
                  ("FAKE000000000005", "Sample Plain", true, nil),
                  ("FAKE000000000006", "Sample Ember", true, .gradient(0xFF6B6B, 0x3A0D2E))]
    }
    return shelf.map { g in
        let url = (try? FakeArt.makeApp(in: artFolder, titleID: g.id, name: g.name, streamable: g.streamable, paint: g.paint,
                                      options: withOptions && g.id == "FAKE000000000000" ? FakeArt.sampleOptions : nil))
            ?? URL(fileURLWithPath: "/dev/null")
        return GameApp(titleID: g.id, name: g.name, url: url, streamable: g.streamable)
    }
}
let extra = fake ? fakeGames(shelf: fakeShelf, options: fakeOptions) : []

// --shape: a LinkShaper listens on every interface in the Host's place; `welcome` tells the client its port, and the
// shaper forwards to the media socket on loopback (it learns the client's address from the first datagram).
var shaper: LinkShaper?
var shaperPort: UInt16?
if let shapeName, let profile = LinkProfile.named(shapeName) {
    let seed = LinkProfile.seed(for: shapeName, given: shapeSeed)
    let s = LinkShaper(profile: profile, seed: seed, to: ("127.0.0.1", 0), listenOnAllInterfaces: true)
    do { shaperPort = try s.start() } catch {
        FileHandle.standardError.write(Data("portal-hostd: cannot start the shaper: \(error)\n".utf8))
        exit(1)
    }
    shaper = s
    say("shaper: profile=\(shapeName) seed=\(s.seed)")
}

let service: HostService
do {
    var config = HostConfig(name: name, storeURL: store, libraryRoots: roots, launcher: launcher,
                            power: SystemPowerHold(), advertise: true, port: port, extraGames: extra, maxBitrate: maxBitrate)
    config.paceMs = paceMs
    config.pacePeak = pacePeak
    config.advertisedMediaPort = shaperPort
    service = try HostService(config: config)
} catch {
    FileHandle.standardError.write(Data("portal-hostd: cannot open the store: \(error)\n".utf8))
    exit(1)
}

let statusPrinter = Task {
    for await s in service.status {
        say(s.logText(showCode: true))
        if case .failed = s { exit(1) }
    }
}

// Why each live session ended -> .claude/host.md § session-end
let sessionEndPrinter = Task {
    for await r in service.sessionEnds { say(r.line) }
}
// The game's preparation phases, unknown tap messages -> .claude/host.md § service
let notePrinter = Task {
    for await line in service.notes { say(line) }
}

do {
    let bound = try await service.start()
    shaper?.setHostPort(await service.mediaPort)
    say("listening on port \(bound)")
} catch {
    FileHandle.standardError.write(Data("portal-hostd: cannot start: \(error)\n".utf8))
    exit(1)
}
if pair {
    let code = try await service.beginPairing()
    say("pairing code: \(code)")
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
// Handlers run on the main queue: the top-level code's own isolation.
let signals = [SIGINT, SIGTERM].map { DispatchSource.makeSignalSource(signal: $0, queue: .main) }
await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
    var resumed = false
    for s in signals {
        s.setEventHandler {
            if !resumed { resumed = true; done.resume() }
        }
        s.resume()
    }
}
let senderLate = await service.senderLateness
let sizes = await service.frameSizeMedians
await service.stop()
say("sender: slices=\(senderLate.slices) late_p95_us=\(senderLate.p95Us) late_max_us=\(senderLate.maxUs)")
// A repair frame should cost about a normal frame, not a key frame -> .claude/host.md § ltr
say("frames: median_bytes=\(sizes.ordinary) repair_median_bytes=\(sizes.repair) repairs=\(sizes.repairs) key_median_bytes=\(sizes.key) keys=\(sizes.keys)")
if let shaper {
    shaper.stop()
    let c = shaper.counts
    say("shaper: forwarded=\(c.forwarded) dropped=\(c.dropped)")
}
_ = await statusPrinter.value
_ = await sessionEndPrinter.value
_ = await notePrinter.value
try? FileManager.default.removeItem(at: artFolder)
say("stopped")
#endif
