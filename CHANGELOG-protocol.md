# Protocol changelog

Versions -> `.claude/conventions.md § protocol-versioning`.

- 2026-11-17 — tap 1, network 1: first version.
  Includes the 16-byte clear UDP header layout (`§ wire-network`).
- 2026-11-18 — network 2: `hello` gains an optional `bitrate` (UInt32, bit/s; key absent = the Host's default).
  The Host sends the tap `min(bitrate ?? default, maximum)`, never under 1 Mbit/s. Tap unchanged (still 1).
  A version 1 client or Host is refused by the version check (`refuse(.version(host:))`).
- 2026-11-18 — network 3: datagram `nack` (0x26, client to Host): `frame u32, count u8 (0...64), index u16 x count`;
  count 0 = every fragment of the frame. The Host resends the named video fragments, sealed afresh. Later work of the
  same plan adds `rate` (0x27), `ack` (0x28), `hostStats` (0x29) to version 3
  before it ships (a previous block in the sound datagram was planned and is not part of it). A version 2 client or Host is refused by the version check.
  Version 3 (not shipped, so no further bump): datagram `hostStats` (0x29, Host to client, once a second):
  `framesFromGame u32, framesSent u32, framesDropped u32, resent u32, rateBps u32, sendLateMaxUs u32` (little-endian as every field, 24 bytes; the worst us a sending slice left late in the last second; counts since
  the session began). No change to a datagram already in version 3.
  Version 3 (not shipped, so no further bump): datagram `rate` (0x27, client to Host): `bitsPerSecond u32` (4 bytes):
  the video rate the client's rate controller wants now. The Host clamps it to `[1 Mbit/s, min(hello bitrate wish
  ?? default, its maximum)]` (the wish stays the ceiling), sends the tap a `config` with the same size and frame rate
  and the new bitrate (at most one per 250 ms, newest wins), and paces and budgets resends at it; `hostStats.rateBps`
  reports what it applied. A client repeats its newest `rate` once a second. Tap unchanged.
- 2026-11-19 — tap 2 (nxnative stream-tap 298f5d71, c6995efb, 2430f8e5, f9e08bc0, 7a6ef43e, 6bff7521); network 3
  unshipped, so no network bump for what it gains here.
  - hello: version 2.
  - video (0x02): `flags u8` (was `key`) and `token i32`: `frame u32, captureNs u64, width u16, height u16, flags u8, token i32, data…`.
    flags: bit 0 = key frame; bit 1 = repair frame (encoded with ForceLTRRefresh, not a key frame; never set with bit 0); other bits 0.
    After a refresh, restart decoding only at a frame with bit 0 or bit 1 set: ordinary frames still in flight depend on the lost frame.
    The token is the frame's long-term-reference token, -1 for none. Opaque: `(session epoch << 24) | encoder token`;
    return it unchanged. Not every frame carries one (about 1 in 14 until the Host acknowledges; every
    frame once it does).
  - ltrAck (0x18, Host -> game): `count u8` (1…16), then `count` x `token i32`: frames the device decoded.
    Tokens of an earlier session or from before the last key frame, and repeats, are ignored.
  - refresh (0x19, Host -> game, no payload): a frame was lost. The next frame is predicted only from an
    acknowledged frame (non-key), or is a key frame when none was acknowledged since the last key frame.
    A refresh while a repair frame is still being encoded is served by it.
  - keyframe (0x11) unchanged. A wrong size for any known type ends the stream; unknown types as before on the game
    side. The Host now skips a message of an unknown type by its length and counts it (one log line for the first of
    each type); a malformed known message still ends the connection.
  - prepare (0x04), game -> Host, new: `phase u8, done u32, total u32`. Phase 1 = the prewarm lists' pipelines,
    2 = the shader pairs' prebuild; other values may come (show them generically). Sent when a phase starts, at most
    4 a second while it runs, and once with done == total when it ends; a phase with nothing to do is one 0-of-0 message;
    phase 2 only on a start that builds the pairs. The hello comes first; no video or audio before the last prepare; the
    first video after it is a key frame. A quit meanwhile ends the game within 2 s (measured 1.54-1.55 s). Added to protocol 2 without a bump:
    no Host spoke protocol 2 yet. The Host keeps and logs it; it is not forwarded to the device (network 4).
  - Breaking: a protocol-1 front end misreads every video message (4 more header bytes); the Host refuses a tap-1 game.
  - Network 3 (unshipped, no bump): the video fragment's `key` byte is a flags byte (bit 0 key, bit 1 repair; 3 and
    other bits malformed), copied from the tap's mark into every fragment of the frame; datagram `ack` (0x28, client to
    Host): `frame u32`, the newest frame the device decoded (at most 30 a second, always for a key or repair frame);
    datagram `repair` (0x2A, client to Host): `lastGoodFrame u32`, a frame was given up and a restart point is wanted
    (the Host passes the tap `refresh`; `keyRequest` 0x23 keeps its meaning, a real key frame).
- 2026-11-19 — discovery (no version bump): the Bonjour `_nxportal._tcp` TXT record carries `id=<16 lower-case hex digits>`, the first 8 bytes of SHA-256 of the Host's public key. Control and datagram layouts unchanged.
- 2026-11-20 to 2026-11-21 — network 4 (not shipped; one version for everything below, so no further bump). A version 3 peer is
  refused by the version check (`refuse(.version(host: 4))`). Tap unchanged (2). No change to a message, key or datagram that
  exists in 3. Each addition, in the order it was added:
  - Art: `GameEntry.art` (optional key `{hash: 64 lower-case hex SHA-256 of the PNG, bytes: UInt32}`; absent = no icon); control
    `artRequest {titleID, hash}` (device to Host) answered by `art {titleID, hash, index: UInt16, count: UInt16, bytes: Data}`
    chunks `0..<count` in order, at most 48 KiB raw each, `count = ceil(bytes / 49152)`, `count` 0 = no such art (unknown title or
    hash); an `artRequest` whose `titleID` is over 64 bytes of UTF-8 or whose `hash` is not exactly 64 bytes is dropped with no
    reply; an icon is at most 512 KiB.
  - `liveSettings(LiveSettings)` (device to Host, admitted phase only; before admission the connection is closed):
    `{"liveSettings":{"_0":{"ceilingBps":<UInt32>,"panel":"off|fps|compact|full"}}}`, each key optional (absent = unchanged;
    under 100 bytes). The Host clamps `ceilingBps` to `[1 Mbit/s, maxBitrate]` (0 is ignored); it replaces the hello's wish as
    the ceiling of `rate` and of the next tap `config`. `panel` is kept for the Host's sampler. A new session starts with neither.
  - `GameState.render` (optional key, Host to device, absent before the game's first picture and after it ends):
    `{"render":{"width":<UInt16>,"height":<UInt16>,"exact":<Bool>}}`, the size of the game's newest picture as the tap delivers
    it under the device's cap; `exact` = under the cap on both sides (the game renders no more), false = a side reaches the cap,
    within the tap's even rounding of 2. Sent with the first picture and on a change. Pinned `gameState.render`. Under 100 bytes.
  - `GameState.preparing` (optional key, Host to device, absent when not preparing):
    `{"preparing":{"phase":<UInt8>,"done":<UInt32>,"total":<UInt32>}}`, the tap's numbers (phase 1 pipelines, 2 shader pairs,
    another value shown the same way). Present from game launch until the first picture and again while the game is alive, not
    paused and has shown no picture for 2 s; never for a paused game. `total` 0 (with `phase` 0 when the Host has no progress)
    = preparing with nothing to count, also sent when no progress came for 5 s. The Host clamps `done` to a non-zero `total`
    and never lowers it within a phase. Sent on a change, a progress change at most twice a second; a device admitted meanwhile
    gets it in its first `gameState`. Under 80 bytes.
  - `Hello.resume` (optional key, device to Host): `"resume":false` opens a library session: admission never resumes the game,
    the session gets `gameState` as it is and no video or sound until it sends `resume` or `launch` (of the starting or
    preparing game: the same as `resume`). Absent (or true) = as before: a device that paused the game resumes it by being
    admitted. A preparing game's owed pause goes out at its first picture unless a playing session is live. Under 20 bytes.
  - A library session gives way: another paired device's `hello` is refused `busy` only while the live session plays; a live
    library session is ended at the newcomer's admission with a sealed `bye(takenBy: <the newcomer's shown name>)` (optional
    key: `{"bye":{"takenBy":"TV"}}`; `{"bye":{}}` unchanged). `input`, `keyRequest` and `repair` from a session that does not
    play are dropped; `resume` with no game plays nothing (the idle state is the answer).
  - Datagram `load` (0x2B, Host to device): the Mac's load while the device's numbers panel is at "full". 35 bytes,
    little-endian: `flags u8` (bit 0 = GPU value present, bit 1 = game process alive; other bits malformed), `thermal u8`
    (0 nominal ... 3 critical), `pressure u8` (0 normal, 1 warning, 2 critical), `cpuTotal u16`, `cpuPerf u16`, `cpuEff u16`,
    `gpu u16` (tenths of a percent, 0xFFFF = n/a), `memUsedMiB u32`, `memTotalMiB u32`, `gameCpuCentiCores u32`, `gameMemMiB u32`,
    `gameFpsDeci u16`, `frameMeanDeciMs u16`, `frameP95DeciMs u16`, `frameMaxDeciMs u16`. Numbers only. About once a second to a
    playing session whose `liveSettings.panel` is `full`; never retransmitted, behind every video and resend datagram. Pinned by
    `testLoadBytesAreThePinnedVector`. A device that does not know the type drops it.
  - `Hello.startBps` (optional key, device to Host, UInt32 bit/s): the rate the device starts at (its first `rate`). The Host
    clamps it as a `rate` and uses it as the session's rate from admission: the game's first `config` carries it whatever reaches
    the Host first. The first `rate` still goes out and replaces it. Pinned `hello.start`. Under 25 bytes.
  - Options, four control messages. Device to Host: `optionsRequest{titleID}`, `setOption{titleID, env, value?}` (`value` absent
    removes the choice), `resetOptions{titleID}`; Host to device: `options{GameOptions}` (the game's settings with the effective
    value of each; `rejected` = the variable of a refused `setOption`; also the answer to `setOption` and `resetOptions`).
    `GameOptions.full` (optional Bool, absent = false): a `setOption` was refused because the Mac keeps choices for as many games
    as it can (pinned `options.full`). `OptionSetting` fields: `env`, `kind`, `section`, `label`, `note`, `defaultValue`,
    `current`, `chosen`, optional `options` (`[value, label]` pairs), `min`, `max`, `step`, `on`, `off`, `base` (`docked` and
    `handheld` as `[width, height]`), `level`, `needs`. Admitted phase only, library or playing session. Bounded on decode on both
    sides (`OptionLimits`): an over-limit message is ignored (`WireError.refused`), not an ended session. Pinned
    `optionsRequest`, `options`, `options.rejected`, `setOption`, `setOption.remove`, `resetOptions`.
  - `Hello.name` (optional key, device to Host): the cleaned device name, at most 40 characters and 120 bytes
    (`DeviceName.clean`); `pairStart.name` carries the same cleaned name. The Host cleans it again and keeps its own result; an
    old device that sends none keeps its stored name. Names the Host sends in `refuse(.busy(device:))` and `bye(takenBy:)` are
    the shown name, cleaned and bounded the same way. Pinned `hello.name`.
  - Bounds on decode (no new key): a `hello` / `pairStart` key (`clientKey`, `ephemeral`, `clientEphemeral`) over 32 bytes is
    malformed (the connection ends); their `name` is cut to 40 characters and 120 bytes at a character boundary (clipped, never
    refused); a `launch` whose `titleID` is not a title ID is refused (ignored, the session goes on).
