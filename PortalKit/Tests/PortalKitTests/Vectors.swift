import Foundation

/// Wire vectors, written by hand from the output at network 3 / tap 1 and committed. A renamed case, label or field, a changed
/// byte order or a changed key derivation fails `VectorTests` before it reaches a device -> .claude/portalkit.md § wire-network
/// Changing a vector is a wire change: bump the version and add a `CHANGELOG-protocol.md` entry.
enum Vectors {
    /// Control messages: JSON with sorted keys, by `Samples.control` name.
    static let control: [String: String] = [
        "pairStart": #"{"pairStart":{"_0":{"clientEphemeral":"AQIDBA==","clientKey":"AQIDBA==","name":"iPad"}}}"#,
        "pairChallenge": #"{"pairChallenge":{"_0":{"hostEphemeral":"AQIDBA==","hostKey":"AQIDBA==","hostName":"Mac","salt":"AQIDBA=="}}}"#,
        "pairProof": #"{"pairProof":{"_0":"AQIDBA=="}}"#,
        "pairResult.ok": #"{"pairResult":{"_0":{"ok":{"hostProof":"AQIDBA=="}}}}"#,
        "pairResult.wrongCode": #"{"pairResult":{"_0":{"wrongCode":{"triesLeft":2}}}}"#,
        "pairResult.locked": #"{"pairResult":{"_0":{"locked":{}}}}"#,
        "pairResult.expired": #"{"pairResult":{"_0":{"expired":{}}}}"#,
        "hello": #"{"hello":{"_0":{"clientKey":"AQIDBA==","ephemeral":"AQIDBA==","kind":"tv","maxFps":60,"maxHeight":2160,"maxWidth":3840,"version":4}}}"#,
        "hello.bitrate": #"{"hello":{"_0":{"bitrate":30000000,"clientKey":"AQIDBA==","ephemeral":"AQIDBA==","kind":"tablet","maxFps":60,"maxHeight":1080,"maxWidth":1920,"version":4}}}"#,
        "hello.library": #"{"hello":{"_0":{"clientKey":"AQIDBA==","ephemeral":"AQIDBA==","kind":"phone","maxFps":60,"maxHeight":1080,"maxWidth":1920,"resume":false,"version":4}}}"#,
        "hello.start": #"{"hello":{"_0":{"bitrate":20000000,"clientKey":"AQIDBA==","ephemeral":"AQIDBA==","kind":"phone","maxFps":60,"maxHeight":1080,"maxWidth":1920,"startBps":10000000,"version":4}}}"#,
        "hello.name": #"{"hello":{"_0":{"clientKey":"AQIDBA==","ephemeral":"AQIDBA==","kind":"tablet","maxFps":60,"maxHeight":1080,"maxWidth":1920,"name":"iPad mini","version":4}}}"#,
        "welcome": #"{"welcome":{"_0":{"ephemeral":"AQIDBA==","sessionID":9,"udpPort":5000}}}"#,
        "refuse.unpaired": #"{"refuse":{"_0":{"unpaired":{}}}}"#,
        "refuse.busy": #"{"refuse":{"_0":{"busy":{"device":"TV"}}}}"#,
        "refuse.version": #"{"refuse":{"_0":{"version":{"host":4}}}}"#,
        "ready": #"{"ready":{}}"#,
        "listRequest": #"{"listRequest":{}}"#,
        "list": #"{"list":{"_0":[{"name":"G","state":"idle","streamable":true,"titleID":"0400486024DEC000"}]}}"#,
        "launch": #"{"launch":{"titleID":"0400486024DEC000"}}"#,
        "resume": #"{"resume":{}}"#,
        "quitGame": #"{"quitGame":{}}"#,
        "gameState": #"{"gameState":{"_0":{"run":"running","titleID":"0400486024DEC000"}}}"#,
        "gameState.paused": #"{"gameState":{"_0":{"reason":"x","run":"paused"}}}"#,
        "gameState.preparing": #"{"gameState":{"_0":{"preparing":{"done":12400,"phase":2,"total":34649},"run":"running","titleID":"0400486024DEC000"}}}"#,
        "gameState.render": #"{"gameState":{"_0":{"render":{"exact":true,"height":1080,"width":1920},"run":"running","titleID":"0400486024DEC000"}}}"#,
        "gameState.waiting": #"{"gameState":{"_0":{"preparing":{"done":0,"phase":0,"total":0},"run":"starting","titleID":"0400486024DEC000"}}}"#,
        "bye": #"{"bye":{}}"#,
        "bye.takenBy": #"{"bye":{"takenBy":"TV"}}"#,
        "list.art": #"{"list":{"_0":[{"art":{"bytes":1234,"hash":"ab"},"name":"G","state":"idle","streamable":true,"titleID":"0400486024DEC000"}]}}"#,
        "artRequest": #"{"artRequest":{"hash":"ab","titleID":"0400486024DEC000"}}"#,
        "art": #"{"art":{"bytes":"AQIDBA==","count":2,"hash":"ab","index":1,"titleID":"0400486024DEC000"}}"#,
        "art.none": #"{"art":{"bytes":"","count":0,"hash":"ab","index":0,"titleID":"0400486024DEC000"}}"#,
        "liveSettings": #"{"liveSettings":{"_0":{"ceilingBps":80000000,"panel":"full"}}}"#,
        "liveSettings.empty": #"{"liveSettings":{"_0":{}}}"#,
        "optionsRequest": #"{"optionsRequest":{"titleID":"0400486024DEC000"}}"#,
        "options": #"{"options":{"_0":{"settings":[{"base":{"docked":[1920,1080],"handheld":[1280,720]},"chosen":true,"current":"0.75","defaultValue":"1.0","env":"DM_RENDER_SCALE","kind":"range","label":"Render scale","level":"basic","max":1,"min":0.5,"note":"","section":"Graphics","step":0.05}],"titleID":"0400486024DEC000"}}}"#,
        "options.rejected": #"{"options":{"_0":{"rejected":"DM_STREAM","settings":[],"titleID":"0400486024DEC000"}}}"#,
        "options.full": #"{"options":{"_0":{"full":true,"rejected":"DM_RENDER_SCALE","settings":[],"titleID":"0400486024DEC000"}}}"#,
        "setOption": #"{"setOption":{"env":"DM_RENDER_SCALE","titleID":"0400486024DEC000","value":"0.75"}}"#,
        "setOption.remove": #"{"setOption":{"env":"DM_RENDER_SCALE","titleID":"0400486024DEC000"}}"#,
        "resetOptions": #"{"resetOptions":{"titleID":"0400486024DEC000"}}"#,
    ]

    /// UDP bodies (after the 16-byte header): type byte and body hex, by `Samples.datagrams` name.
    static let datagrams: [String: (type: UInt8, body: String)] = [
        "input": (0x22, "01000000000180000000000000ffffffff02000000fdffffff0400000000"),
        "input.motion": (0x22, "020000000103000000000000000000000000000000000000000000000001000000803f0000004000004040000080bf000000c0000040c0"),
        "keyRequest": (0x23, "2a000000"),
        "ping": (0x24, "0807060504030201"),
        "pong": (0x25, "01000000000000000200000000000000"),
        "nack": (0x26, "d0c0b0a00300000100ffff"),
        "nack.all": (0x26, "0700000000"),
        "rate": (0x27, "a0acb903"),
        "hostStats": (0x29, "0100000002000000030000000400000000e1f505d2040000"),
    ]

    /// Tap messages, framed (u32 length, type, payload), hex, by `Samples.tap` name.
    static let tap: [String: String] = [
        "audio": "0e0000000363000000000000000201020304",
        "config": "0a00000010000f70083c002d3101",
        "keyframe": "0100000011",
        "pad": "1a000000120101020000000000000180ffffff7f000005000000fbffffff",
        "motion": "1b0000001300010000000000000000000080bf0000003f000080be00000040",
        "motion.controller": "1b0000001302000000803f0000004000004040000080bf000000c0000040c0",
        "players": "050000001405000000",
        "pause.on": "020000001501",
        "pause.off": "020000001500",
        "quit": "0100000016",
        "motionClear": "020000001703",
    ]

    /// `Samples.bytes(from: 200)` as the key, session 0x0A0B0C0D, a `ping` body, counters 0 and 1: the whole datagram.
    static let sealedPing: [String] = [
        "240000000d0c0b0a00000000000000002cb304fe190e404ca69be7d5dad441bcdcd80da30234c0db",
        "240000000d0c0b0a010000000000000086eb4f42d9d782fd9217a0a5371e8ea38dd910914618e2f4",
    ]

    /// `SessionKeys.derive(role: .client ...)` from the fixed identities and ephemerals in `Samples`.
    static let sessionKeys: [String: String] = [
        "c2hctl": "64723233decde98c7bf04c08ceb172ca260f308eb88288d0856ef2c351da79b6",
        "h2cctl": "187bbe1047b30678d25867c273e9c52077380f7c5065f3e3af2f8c6ee95c94f2",
        "c2hmedia": "c40a36d2efd92948f50a7ace8e5413b2a6413d22c203c8fbbaafb7fca7530070",
        "h2cmedia": "6c560c6ae4bd3644ea07b5a8cd3c632b09d8a637b9bc263963a69801796300df",
    ]

    /// X25519 public keys of `Samples.clientStatic` and `Samples.hostStatic`.
    static let clientPublic = "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c"
    static let hostPublic = "5869aff450549732cbaaed5e5df9b30a6da31cb0e5742bad5ad4a1a768f1a67b"

    /// The pairing exchange from the fixed keys, salt and code in `Samples`: the client's proof and the Host's proof.
    static let pairingClientProof = "a246c32ef44f96b5c2150e116ed2d90c390021655ca91ebb1bde33afe2dce7a1"
    static let pairingHostProof = "df89aa8ccee08ecc529597f46ec9e5674e2ac165116f0141b0ffe49468ba70fb"
}
