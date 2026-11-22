# Tap (nxnative patch)

Branch `stream-tap` in `<nxnative worktree>`, on the pin (`conventions.md § tap-pin`).
Style, logs (`[RED] `), switches and tests follow nxnative's own `AGENTS.md`.

#### video

- Switch: `DM_STREAM` set (Mac only; `docs/env_switches.tsv` row). `stream_on()` in
  `dm/host/stream.h` reads it once.
- Hook: `present_now` (`dm/gfx/nvn/nvn_mtl.m`), after the `g_gpu_lost` check, before
  `front_metal_layer()` is read → `stream_present(src, crop, ticket)`. Returns 1 after a commit: the commit counts
  in `g_pq_inflight` and its feedback marks the ticket done and retires released external textures, as a display
  present's does (a Vulkan or GL image released meanwhile would leave the residency set under the running pass).
  Returns 0 when nothing was committed (no slot, the cap, a failure): the present thread releases the ticket as
  for a windowless run. The present thread never waits for the encoder: no free slot still drops the frame.
- `stream_present`:
  - asks `stream_video_surface(shape w, h, &slot)` (shape from `present_shape`); NULL → frame dropped.
  - per slot: a BGRA8 render-target texture over the slot's IOSurface (remade when
    the surface changes), its own allocator, command buffer, crop buffer.
  - texture `res_add` + `res_commit` before the command buffer: an unresident target
    page-faults and macOS ignores every later command buffer of the process.
  - `present_encode_m4(cb, src, tex, crop, uv, NULL)`, `cb_end(cb, nil)`, commit; the
    feedback handler calls `stream_video_submit(slot, capture_ns)` or `stream_video_abort`.
  - `capture_ns`: `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` at entry.
- Weak no-op defaults for `stream_video_surface` / `_submit` / `_abort` in `nvn_mtl.m`:
  graphics unit tests link without the encoder. Strong ones in `dm/host/stream_video_mac.m`.
- Surface size reads `IOSurface.width/height` by message (`IOSurfaceObjC.h`): the
  graphics unit tests do not link the IOSurface framework.
- Slots (3, `stream_video_mac.m`):
  - busy from `stream_video_surface` until the encoder's output callback, an abort, or
    an out-of-order drop. A slot is never reused before its commit feedback ran, so
    its allocator is idle at `reset`.
  - none free → frame dropped; the present thread never waits.
- Frame-rate cap: a schedule, not the last arrival. `per = 1/max_fps`; refused when
  `now + per/4 < due`; on accept `due = now < due + per ? due + per : now` (the first frame: `now + per`). A game at the
  cap's rate keeps every frame through its jitter.
  - A frame a period or more late leaves the next one due at once: the frames after a long
    one, back on the game's rhythm, are kept (`5ef3f16f`; before it a 60 Hz game lost one
    frame after each long frame: 132 of 21000 in a six-minute session). The rate over any
    two periods stays within the cap plus one frame.
- Counters: frames refused by the cap and for want of a free slot; one line
  `stream: <n> presents, <a> over the cap, <b> no free slot` per 600 presents, only when
  `a` or `b` is non-zero.
- Order: a submit older than the newest frame already sent is dropped.
- Scale: fit into the config's max, aspect kept, never up, even dimensions.
- Encoder: `VTCompressionSession` HEVC Main AutoLevel, `EnableLowLatencyRateControl`,
  `RealTime`, no reordering, `MaxKeyFrameInterval` `INT32_MAX`, `EnableLTR`; bitrate and expected
  frame rate from the config. Made again only on a size change (first frame key; LTR state cleared,
  epoch +1). Every `VTSessionSetProperty` status checked (`[RED] ` line; `EnableLTR` refused -> LTR
  off for that session: tokens -1, refresh = key frame). PTS = `capture_ns` / 1e9. Log per session:
  `stream: long-term references on`.
- Key frames: start, `stream_video_keyframe()`, size change, a refresh when the encoder holds no
  acknowledgement since the last key frame. A bitrate change alone keeps the session (tested).
- Sink: `(data, n, flags, token, w, h, capture_ns)`, called on the encoder's thread; flags = `STREAM_FRAME_KEY` (1)
  or `STREAM_FRAME_REPAIR` (2: encoded with `ForceLTRRefresh`, came out non-key; never with key, 3 is never sent), else 0.
  The repair mark is per slot (`g_slot[].repair`, set at submit, read in `enc_out`); a refresh answered with a key frame is
  flags 1. data = the sample's 4-byte BE length-prefixed NAL units, a key frame led by VPS, SPS, PPS (4-byte lengths
  each); token = wire token (`#### ltr`), -1 for none.
- Frame options built only when there is something to pass (key, acks, refresh).
- Locks: `g_enc_mu` (session) before `g_mu` (slots, config), never inside it.

#### ltr

- Encoder tokens: frame index in the session; only some frames carry one (frame 0, then ~1 in 14
  without acks; every frame once acks flow); restart at 0 each session.
- Wire token = `(epoch << 24) | encoder token`; epoch 7 bits, +1 per session (first = 1). Opaque
  to the Host, returned unchanged. Encoder token > 0xFFFFFF -> sent as -1 (`[RED]` once).
- `stream_video_ltr_ack`: dropped unless current epoch, issued since the last key frame (newest 64)
  and not already pending; newest 32 pending; passed (low 24 bits) with the next frame in
  `AcknowledgedLTRTokens`.
- "Acked" = a frame carrying acks came out of the encoder since the last key frame, or the frame
  being encoded carries some. A frame whose encode fails or whose output is dropped puts its acks
  back ahead of the pending ones (per-slot copy).
- `stream_video_refresh`: next frame `ForceLTRRefresh` when acked, else `ForceKeyFrame` (decided in
  the tap). Ignored while a key frame or refresh is in flight (`g_fix_wait`): that frame repairs
  every loss reported before its output. Lost refresh -> asked again.
- Encoder facts (probes + `t_stream_present`): refresh with an acked frame = non-key, decodes
  without the lost frames; ack + refresh in one frame works; refresh with nothing usable acked = key
  frame whose next frames fail (-12909) until a `ForceKeyFrame` key frame; unknown token ignored.
- Guard: refresh answered with a key frame -> `[RED]` + another key frame.
- Key frame handed to the encoder -> issued/acked cleared; outputs before its own add no token.
- Counters: the 600-present line adds `, <p> refreshes as non-key frames`, `, <k> refreshes as
  key frames` when non-zero.
- Test hook `stream_video_fault`: `STREAM_FAULT_ENCODE` (next encode fails, -12902),
  `STREAM_FAULT_NO_LTR` (new sessions as if `EnableLTR` refused).
- The Host's side (acks, refresh, the mark in the fragments): `host.md § ltr`.

#### prepare

- Stream mode prepares before the first frame like a windowed start: `prepare_on()` (nvn_mtl.m) is on when the tap's
  `stream_prepare_wanted()` says so (connected, not quit, `DM_STREAM_PREPARE` != `0`). Prewarm lists, then, when not done
  for this game version (`prebuilt.tsv`), every shader pair; all cores, user-initiated QoS.
- `DM_STREAM_PREPARE=0`: the old background path (prewarm on a serial queue, prebuild on half the P cores at utility QoS).
  `DM_PSO_PREPARE` and `DM_PSO_PREBUILD` keep their meaning.
- Tap side (`stream_mac.c`): `stream_prepare_begin` / `stream_prepare(phase, done, total)` / `stream_prepare_end`;
  between begin and end video frames are dropped (no frame number used; a key frame is asked for at the end) and audio is
  dropped. Rate limit in the tap: phase start, then >= 250 ms apart, end (done == total) once.
- Message `prepare` 0x04, game -> Host: `phase u8, done u32, total u32` (protocol 2, no bump: unshipped). Order: hello ->
  prepare phase 1 ... -> [phase 2 ...] -> audio / video. Phase 2 only when this start builds pairs; a phase with nothing
  to do sends one 0/0. Phase 2 ends when every pair is handed out (a few compiles finish behind the game).
- Quit during the preparation: the graceful exit gives the archive `DM_QUIT_PREPARE_MS` (1.5 s; hard deadline 2 s)
  instead of 10 s. Files written so far stay (written whole, renamed); the flush period under way is rebuilt next start.
- Measured (test game, cold archive, 12 cores, no bundled archive): prepare 818 s (lists 184 s, pairs 634 s), first video
  4.9 s after the last prepare, 0 pipeline stalls in the next 60 s. Start with the lists already in the archive: archive
  open 0.09-0.23 s, lists 0.64-0.69 s (the first warm start after a cold one also pays a one-time compaction, ~13.6 s).
- Quit in the shader-pair phase, measured 3 times: process gone 1.54-1.55 s after the quit, exit code 0, no `.tmp` left;
  the next start reads the archive with no red line and goes on. The bases of the period under way (43 to 1,562 in the
  runs) are built again: a Host that quits again and again in the first seconds of phase 2 makes little progress.
- The Host decodes, keeps and logs it (`host.md § service`); it is not forwarded to the device yet.

#### socket

- `DM_STREAM=<unix socket path>`; `stream_start(titleID, name)` (`dm/host/stream_mac.c`, Mac `SRC` only) from `front_run` before `guest()`; failure -> `[RED]` line, `exit(1)`.
- Framing and layouts: `portalkit.md § wire-tap`; `STREAM_TAP_VERSION 2` in `stream.h` (bump with the Swift side).
  v2: `video` gains `token i32` after `flags` (header 21 bytes, frame limit `MAX_MSG - 22`); the byte at offset 16 is a
  flags byte (bit 0 key frame, bit 1 repair frame, other bits 0); `ltrAck` 0x18
  (`count u8` 1..16 + count x i32) and `refresh` 0x19 (empty) -> `stream_video_ltr_ack` / `_refresh`.
  Wrong size (count 0 or > 16, length != 1 + 4 x count, refresh with payload) ends the stream.
  Reader buffer 72 bytes (largest legal message 66).
- `AF_UNIX` stream, `SO_NOSIGPIPE`, 4 MiB send buffer; blocking whole-message writes (`writev`) under one mutex (encoder thread, sound threads).
- `stream_start` fails (one `[RED]` line) on a path too long for `sun_path`, a failed connect or hello.
- End of stream, once per `stream_start`: `quit`, EOF, read/write error, unknown type, length 0 or > 8 MiB, wrong fixed size -> `stream_quit_hook()`.
- Default hook: `kill(getpid(), SIGTERM)` (process-directed: reaches the GCD signal source from any thread).
- Host SIGTERM: `dm_term_install` (`hle_lifecycle.c`, from `main.c`) -> `dm_host_shutdown`: counters and cheats flushed, audio suspended, graphics drained, pipeline archive written within `DM_QUIT_ARCH_MS`, then `_exit(0)`; 1.5 s/deadline fallbacks, so a save is not cut mid-write.
- Evidence lines, once per process: connected, first config, first non-zero pad, paused/resumed.
- Video: sink registered in `stream_start`; one `video` message per frame, numbers from 0.
  A frame over the message limit uses its number (the front end sees a gap) and asks for a key frame.
- A Host that stays connected but stops reading freezes the game (blocking writes under the write lock; present drops frames without waiting, but a size change would block it): the game never runs unseen.
- Lost key frame (dropped, parameter sets unreadable): `stream_video_mac.m` asks again (`g_key`).
- Encoder output not copied out (no memory, unreadable data): a key frame is asked for.

#### sound

- Hook: `null_sink` (`hle_audio.c`) calls `stream_audio_pcm(scratch, bytes, a->ch, a->sink_pcm, a)` after each `pull`; `real_audio()` is 0 under `stream_on()`.
- Layout seen: a block is 240 frames x `a->ch` int16, interleaved. Host sinks (`sink_pcm`, `ch` = `DM_AUDIO_SINK_CHANNELS` 8): 6 channels (FL FR C LFE SL SR) then the pre-clamped stereo fold; `pull` applies the output volume. Game outputs: 2 or 6 channels, no fold.
- Mix (`stream_audio_pcm`): to stereo (fold -> its 2 channels; 2 as is; 6 and 8 at 0.7071 with LFE dropped; 1 doubled), then:
  - first source to push is the clock; each clock push emits one audio message (2 ch, 240 frames) = its block + the latest queued block of each other source (consumed once); sum saturates to int16.
  - a source silent for 100 ms is forgotten; if it was the clock, the next to push is.
  - 16 sources at most (more are dropped); `captureNs` = `CLOCK_UPTIME_RAW` at the clock's push.
- Known limit: a non-clock source that pushes twice between two clock pushes loses its first block (a 5 ms gap).
- A source is forgotten only if `last < now` (sink threads read the clock before the lock); `stream_audio_pcm_at` takes the time for `t_stream`.
- Weak no-op `stream_audio_pcm` in `hle_audio.c` (unit tests that include it do not link `stream_mac.c`).

#### input

- Reader thread maps: `pad` p0 -> `dm_pad_set`, p1..7 -> `dm_pad_set_player`; `motion` frame 1 -> `dm_motion_set_switch` (player 0 only), frame 0 -> `dm_motion_set`; `motionClear`; `players` -> `dm_pad_players`; `config`, `keyframe`, `ltrAck`, `refresh` -> `stream_video_*`.
- Player >= 8 and unknown motion frames are ignored; a wrong size ends the stream.

#### pause

- `pause` -> `dm_background(on)` (`hle_oe.c`, Mac only) = `script_bg`: focus 2, 3, audio and clock freeze, graphics suspend (reverse on resume).
- Callers: `oe_script` (`DM_OE_SCRIPT bg=`), a detached plain host thread holding no lock (`front_ios.m` calls the same calls from the main thread). The reader is a plain thread too -> same way, no hook beyond the wrapper.
- A repeat of the current state is ignored (reader-owned flag).
- Pause does not stop the sound messages: with no audio device `dm_audio_suspend` does nothing, so the silent sinks keep sending (game sound, or silence once the game stops filling) while paused.

#### start

- `front_run`: `stream_on()` takes the windowless branch even with `DM_WINDOW`; title ID is `DM_GAME_ID` (`game_profile.h`), name `DM_GAME_NAME`.
- `launcher.c`: `DM_STREAM` -> no settings window, `DM_WINDOW` and `DM_AUDIO` not set. `pack_app.py`: `DMStream` in Info.plist.
- `stream_on()` reads the environment once into an `_Atomic int`.

#### archive-timer

- Upstream defers the pipeline archive's timed write while a game plays in a window (it holds the Metal serialization gate; a pipeline the game needs meanwhile waits: frames over a second), telling play from a headless run by `mtl_has_window()` (a layer). A stream has no layer, so its timer wrote during play.
- Tap (`nvn_mtl.m`, `arch_hand_over`): `windowed_timer = TIMER && (mtl_has_window() || (stream_on() && !warm_due))`. A stream's timed write waits until the game has presented nothing for ten seconds and no compile is under way, and retries until then. Full periods, the Host's pause, quit and the prepare step's flushes are unchanged (`ARCH_FLUSH_NOW` is never windowed; `g_warm_running` already holds the timer back during the prepare step).
- Exception (`warm_due`): with `DM_STREAM_PREPARE=0` the background prewarm runs through play and its own due writes (60 s, doubling to 16 min) still happen, so a crash does not lose what it built. A window reaches a background prewarm only with `DM_PSO_PREPARE=0` (a diagnostic) and keeps upstream's rule.
- Test: `t_pso_archive --stream-flush` (17 checks): no write while the stream presents, the retry after ten idle seconds writes; and the prewarm case (a due write while presenting is written). Failed before each change (3 of 9; then the two new write checks).
- Docs: `frontends.md` (Streaming front ends), `docs/reference/rendering.md` (the timed write's entry).
- VERIFIED by tests only. OWED: its effect on frame times in a stream's play (the stall was measured upstream in a window, not in a stream). In the real run (`§ real-run`) no archive write happened during play at all.

#### microphone

- Upstream's Mac microphone input (`DM_MIC`) runs in the launcher on the no-window path too: a saved `DM_MIC=1` would have let a streamed game capture the Mac's microphone where nobody plays, and an undecided permission would have held the start on a consent alert nobody sees (the host never started).
- Tap: a streamed game never opens the microphone and never asks for consent.
  - `launcher.c`: with `DM_STREAM`, `DM_MIC` is forced to `0` after the env files and saved choices and before `microphone_at_launch()`; one `[RED] launcher: DM_STREAM: the microphone stays off (DM_MIC=1 was asked for)` line when a 1 was asked for.
  - `audio_input.c`: `dm_audio_input_available()` is 0 under `stream_on()` with one `[RED] audio input: DM_STREAM: …` line, so `dm_audio_input_open` opens nothing (a host started without the launcher).
  - The game is told what it is told for `DM_MIC=0`: no input devices, `OpenInputStream` fails.
- Docs: the `DM_STREAM` row of `docs/env_switches.tsv`, `frontends.md`. The Host hides the names (`host.md § options`).
- Tests: `t_audio_input --stream` (`DM_STREAM`, `DM_MIC=1`: no input available; aborted at its first check before the change); `test_nsp_mac_app` `test_stream_turns_the_microphone_off` (the packed launcher hands the host `DM_MIC=0`, no `DM_WINDOW` / `DM_AUDIO`, logs the line). Limit: its fixture app has no microphone usage key, so `DM_MIC` was already 0 there; the consent path itself cannot be driven in a test, and the order (forced off before the call) is read from straight-line code (reviewed).
- VERIFIED: the tests; the real run with `DM_MIC=1`, 40 s: 2037 frames, 59.9 fps, the log line above, no log line about opening an input device. OWED: the menu-bar microphone indicator could not be observed.

#### task-role

- Upstream gives a windowless run the default application task role (`DM_WINDOWLESS_ROLE`, `front_run`; its measured gain upstream: base priority 31 to 46, audio underruns 53 to 0) and one latency-critical activity.
- A stream is a windowless start (`stream_on() || !getenv("DM_WINDOW")` is the tap's branch condition), so it gets both: the tap's `stream_start` comes first in that branch, then upstream's role, then `guest()`. Before the move a stream ran with the unspecified role. The commit only states it in the `DM_WINDOWLESS_ROLE` row of `docs/env_switches.tsv` (checked by `test_env_switches`, `test_docs`); the behaviour is upstream's.
- Measured (real run, 60 s into a play, one sample each): new copy `dmhost` 107 threads, priority 97 x3, 47 x3, 46 x94, 31 x7; old copy 97 x2, 47 x3, 31 x100; the launcher priority 31 in both. So the role took effect (46 where the old copy had 31). The mix differs by one sample each; not examined further.
- A system assertion `PreventUserIdleSystemSleep` ("game") was held by `dmhost` in both copies.
- OWED: App Nap state (not readable without sudo); a launch from a low-QoS context would keep priority at 20 even with the role set (reviewer's reading of upstream; not seen).

#### upstream-meets

What a headless stream meets in the upstream changes since `e4b0d9b7` (244 commits; read in the rebase and its review; tests run on the rebased head):

- Present path: the display-link code (pacing modes, rescue, tick holding, acquire lateness) never runs, as a stream has no layer (`g_link` nil, `link_on()` 0, the tick waits return 0 at once). A present waits for an external producer's event first (`ev_val`, `present_main` before `present_now`), so a Vulkan or GL frame is still encoded after its producer. A suspended (paused) present returns before the tap's hook: nothing is encoded while paused. The tap's `present_now` hook, the cap and "frames after a long one" are unchanged; `t_stream_present` 32 checks. The tap's test call gains the new `ev_val` argument (0).
- Pause: the Host's pause (`dm_background` to `dm_gfx_suspend(1)`) now closes admission, drops queued presents and returns within 3 s on the tap's reader thread, so a GPU or compiler stall cannot hold the reader.
- Pipelines: the timed archive write (`§ archive-timer`); autorelease pools in background builds, run-time stage translation, library mappings released, a missing function rejected: the prepare step's counters and progress calls are unchanged (`t_stream_prepare` 12, 7, 2 checks).
- Sound: a stream's sinks are silent (`real_audio()` 0): no audio unit, no route watchdog, so route recovery never runs; the short-tail staging is on the device path only; the tap's 5 ms blocks reach `stream_audio_pcm` as before; `t_stream` 94 checks. The audio renderer's producer gets a real-time policy (a gain for the clock). Paced renders after a stall: after a hitch under 100 ms the null sink's catch-up spaces fresh renders at least 4.5 ms apart; the spacing of the tap's audio messages after a hitch is not measured.
- Front end and launcher: the task role and the activity (`§ task-role`); the launcher's microphone step (`§ microphone`) and run-time compiler environment sit beside the tap's two lines; `pack_app.py` keeps `DMStream`.
- Input: the tap's pad calls are unchanged upstream; sticks past the Switch radius are projected for socket pads too, and a whole pad can show as one Joy-Con where a game takes only those.
- VERIFIED by reading and the rebased head's tests; the run is `§ real-run`. Not examined: a Vulkan or GL game in a stream.

The second move the same day, `c8d312c0` to `184847c5` (61 commits; two conflicts, both in the first commit's `nvn_mtl.m`: the tap's once-only log key is now 178 of 179, upstream took 175 to 177; `present_shape` takes the crop):

- Prepare: upstream freezes the guest clock and parks guest clock reads during the prepare step and the archive open. The tap's prepare runs inside that freeze; its progress messages come from a host thread and are not held; a quit still ends by the hard deadline; pause and resume compose with the freeze (a bitmask, no early thaw).
- Present path: 30 fps pacing and the presentation history are display-link code a stream never runs; the cap and "keep the frames that follow a long one" are still on every presented frame's path. A game whose crop matches a screen-aspect setting now streams the crop's shape; the size travels in each video message.
- Memory: the memory-pressure trims and the idle eviction do not touch a presented texture; the release race the first review parked is closed by the tap's own commit (`§ video`, `t_stream_present` 41 checks).
- Settings: one new player row, `DM_ROTATION` (a phone's orientation lock): known to the Host and hidden (`.claude/host.md`).
- A new pack is a full one: the shader translation chain changed.
- VERIFIED by reading (a second reader) and the tests (`.claude/build.md § nxnative-baseline`); the run is `§ real-run`. Not examined: a Vulkan or GL game in a stream, the crop shape in a stream.

#### real-run

A packed game through the test Host to `portal-fakeclient`, 2026-11-22, title `0400486024DEC000`; scratch `HOME`, loopback, the Host's test tools; 720p (the fake client's fixed cap), 60 fps, 20 Mbit/s. Copies: head = packed at the pin with tap head `c5e00741`; before = the same pin without the tap's last commit (the in-flight count, `§ video`); the copy at the previous pin (`c8d312c0`) as measured that morning.

| | head, start 2 (180 s, twice) | before, start 2 (180 s) | previous pin, start 2 |
|---|---|---|---|
| frames, fps, p95 interval | 10599 and 10602, 60.0, 22.7 and 22.2 ms | 10394, 60.0, 23.2 ms | 10608, 60.0, 21.7 ms |
| skipped, sound lost, given up, repairs, decode errors | 0 | 0 | 0 |
| longest gap | 189 and 195 ms | 211 ms | 108 ms |
| live to prepare done | 2.5 s (prepare 0.7 s) | 5.7 s (1.7 s) | 2.4 s to first picture |
| long frames (count; worst) | 7 and 15; 174.9 and 162.0 ms | 6; 178.5 ms | 3; 62.8 ms |
| first 600 presents: over the cap, no free slot | 3, 6 | 3, 8 | not read |
| sender late p95 | 50 us | 50 us | 50 us |
| `[RED]` lines in the game log | 0 | 0 | 0 |
| quit to exit | under 0.5 s; graceful exit 0.001 to 0.002 s | under 0.5 s; 0.005 s | under 0.5 s; 0.008 s |

- VERIFIED: the head copy streams as before on this Mac: 60 fps, no skipped frame, no lost sound, no red line, a graceful quit. The in-flight count costs nothing measurable (same rate, same dropped presents).
- First start of a new copy (120 s): 59.9 fps, 0 lost, live to prepare done 6.5 s (the bundle scan before it took about 150 s once; the archive was found for this chip, 0 compiled, no write at quit).
- New at this pin, in both copies with and without the last commit: one long frame of 160 to 200 ms at about frame 87, 5 to 9 s into each stream (the previous pin's worst was 63 to 111 ms). No new pipelines named. Cause not looked for -> `todo.md` Backlog.
- With `DM_MIC=1` the microphone stays shut and the start is not delayed (`§ microphone`); with `DM_ROTATION=portrait` the game's picture stays 1920x1080.
- OWED (not measured; the run could not):
  - a Vulkan or GL game in a stream (the path the in-flight count protects), and a game whose crop matches a screen-aspect setting;
  - App Nap state of the launcher and `dmhost` (not readable without sudo; only the power assertion was);
  - the menu-bar microphone indicator;
  - gameplay past the title sequence (button presses were sent; whether the game left its title sequence was not looked at);
  - a second Mac with another graphics chip (this run is one chip, `applegpu_g18g`);
  - a quit during the prepare step and the Host's pause timing inside upstream's clock freeze (read, not run);
  - the audio messages' spacing after a hitch.

#### size

From `git diff --stat 184847c5` at head `c5e00741` (lines changed per file):

| File | Lines |
|------|-------|
| `dm/host/stream_mac.c`, `stream_video_mac.m`, `stream.h` (new) | 227, 208, 43 |
| `dm/host/tests/t_stream.c`, `dm/gfx/tests/t_stream_present.m` (new, tests) | 359, 301 |
| `dm/gfx/tests/t_stream_prepare.m`, `t_stream_prepare_tap.c` (new, tests) | 58, 12 |
| `dm/gfx/nvn/nvn_mtl.m` (hooks) | +93 -10 |
| `dm/host/hle_audio.c`, `audio_input.c`, `launcher.c` | +13 -1, +11 -1, +8 -2 |
| `dm/host/hle_lifecycle.c`, `front_mac.m`, `hle_oe.c`, `dm.h`, `Makefile`, `hle.h`, `hle_nvn.c`, `nvn_mtl.h`, `pack_app.py` | +6 -5, +3 -1, +3, +4, +2 -2, +1, +1, +1, +1 -1 |
| tests (`t_pso_archive.m`, `t_audio_input.c`, `test_nsp_mac_app.py`, three Makefiles) | 33, 17, 11, 14, 8, 4 |
| docs (`env_switches.tsv`, `frontends.md`, `rendering.md`, `development.md`, `memory.md`) | 4, 28, 2, 2, 4 |

- Hooks in existing files (non-test, non-doc): 147 lines added (70 at the first pin: the rest is the prepare step, the timer, the microphone, the quit budget and the in-flight count).

#### tests

From `<nxnative worktree>`, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

```bash
make -C dm/gfx/tests GAME=0400486024DEC000 check_t_stream_present   # 41 checks (LTR decode proof + control, failed encode, epochs, LTR refused, the repair mark, a present in flight until its commit completes), MTL_DEBUG_LAYER=1
make -C dm/gfx/tests GAME=0400486024DEC000 check_t_present_alloc    # 13 checks
make -C dm/host dmhost GAME=0400486024DEC000
make -C dm/host/tests GAME=0400486024DEC000 run                     # every "checks, 0 failed" (t_stream: 94 checks, ~1 s)
```

- t_stream_prepare (dm/gfx/tests, nvn_mtl.m included, the tap's calls faked in t_stream_prepare_tap.c): prepare step on
  in stream mode, begin / end around it, `dm_gfx_quit_ms()` 1500 during it and 10000 otherwise, off with
  `DM_STREAM_PREPARE=0`. 21 checks.
- t_stream 94 checks (24 for prepare: bytes, hello first, no media before the last prepare, rate limit, end once,
  0/0 phase, key frame after, quit while preparing, the switch). `no_message()` now sees messages of any size.
- Protocol 2 commits on `stream-tap` (SHAs from before the pin moves; the same commits, messages unchanged, replayed): `298f5d71` (protocol 2), `c6995efb` (LTR), `2430f8e5` (acks survive a lost frame,
  epoch), `f9e08bc0` (the repair mark), `7a6ef43e` + `6bff7521` (prepare).

- The gfx tests Makefile stops without `GAME`.
- `t_stream_present` presents at absolute times (asleep until 8 ms before, then spinning):
  a plain sleep overruns by several ms in a command-line process.
- Seven gfx test programs fail to build at the pin too (`t_geometry*` ×5,
  `t_atomic_return`, `t_global_memory`): not the tap's.

#### first-light

A real game through `portal-hostd` to `portal-fakeclient` on the development
Mac (Apple M6, macOS 27.2.1), loopback, 2026-11-17. Test subject: title
`0400486024DEC000`, packed from the tap worktree (`.claude/build.md § real-game`).
Tap `2b558771`, tools at `ed58cf2`. Each run: 60 s, button A at 20 s, fresh save.

| Run | frames | fps | p95 delay | skipped | sound lost |
|-----|--------|-----|-----------|---------|------------|
| display on | 3487 | 60.0 | 18.7 ms | 0 | 0 |
| display asleep | 3485 | 60.0 | 20.1 ms | 0 | 0 |
| tap before the cap fix (`70001c80`), display asleep | 3433 | 59.5 | 19.9 ms | 0 | 0 |

- VERIFIED: HEVC Main 1280x720, every frame decodes; stills show the title
  screen and, after the button, the intro (input end to end). Sound after
  10 s: mean -29 dB, max -10 dB. 0 `[RED]` lines in the game's log.
- VERIFIED: no window (0 windows for the launcher and the host), neither is a
  registered app (no Dock icon, no menu bar), no audio or power assertion
  created for the game. Design risk 1 (pacing with no window) holds, display
  on or off.
- The delay is capture to arrival at the test client; decode and display on a
  device come on top (plan B measures them).
- The game's log shows `stream: connected`, `first config`, `HEVC <w>x<h>`,
  `first pad input`, `paused` / `resumed`; a line
  `stream: 600 presents, <a> over the cap, <b> no free slot` appears only for a
  window that dropped frames (seen once per run, at start-up).
- Under heavy machine load (builds running) the same run gave 54-57 fps: the
  encoder shares the CPU and GPU with everything else.

Awkward cases, all VERIFIED on the real game:

- client process killed: Host `paused` and the game's `stream: paused` within 0.1 s; reconnect resumes, 59-60 fps;
- client frozen (no packets, connection open): paused after 2.99 s;
- client gone while the game is still booting: paused during boot, later resume plays;
- a second paired device while the first plays: refused `busy`;
- connect while paused, then quit: resumed, `exited (0)` in 1.1 s, graceful exit in the log;
- game killed (`kill -9`): the client is told `exited (137)`, the Host keeps serving;
- Host stopped while the game runs or is paused: the game is gone within 1 s, graceful exit.

Owed (needs the owner or hardware): mouse and keyboard use and a locked
screen during a stream; a controller connected to the Mac not reaching the game.


#### wifi

The real game through the link shaper with the real decoder, at `ff8071d` (2026-11-20). Title `0400486024DEC000`, game copy with tap protocol 2.

- How: `portal-hostd --library <streaming build of the title> --pair --port 0 --shape <profile>` and `portal-fakeclient --host 127.0.0.1:<port> --pair <code> --launch <title ID> --seconds 90 --decode [--bitrate <ceiling>]`; Release tools, loopback on the build Mac, one run per row. `--decode`: acknowledgements flow, so a repair is answered with a repair frame (`client.md § fakeclient`). Profiles: `portalkit.md § test-network`.

| profile | ceiling Mbit/s | frames | fps | p95 interval ms | given up | repair requests | repair frames | keys after first | escalations | decode errors | fragments asked / recovered | sound blocks lost | longest gap ms | rate start / low / end | cuts |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| clean | default (20) | 4966 | 59.5 | 24.7 | 0 | 0 | 0 | 0 | 0 | 0 | 15 / 15 | 0 | 177 | 20.0 / 20.0 / 20.0 | 0 |
| lossy | default (20) | 5151 | 60.0 | 31.5 | 0 | 0 | 0 | 0 | 0 | 0 | 1658 / 1602 | 155 | 81 | 20.0 / 20.0 / 20.0 | 0 |
| bursty | default (20) | 5121 | 59.5 | 30.6 | 5 | 22 | 5 | 0 | 0 | 0 | 3759 / 3548 | 356 | 325 | 20.0 / 20.0 / 20.0 | 0 |
| stalls | default (20) | 5179 | 60.0 | 59.8 | 0 | 0 | 0 | 0 | 0 | 0 | 97 / 97 | 0 | 104 | 20.0 / 20.0 / 20.0 | 0 |
| narrow (25 Mbit/s link) | default (20) | 5174 | 60.0 | 35.9 | 3 | 5 | 3 | 0 | 0 | 0 | 677 / 234 | 12 | 195 | 20.0 / 20.0 / 20.0 | 0 |
| lossy | 40 | 5194 | 60.0 | 31.3 | 0 | 0 | 0 | 0 | 0 | 0 | 1859 / 1779 | 173 | 82 | 20.0 / 14.0 / 32.3 | 1 |
| bursty | 50 | 5129 | 59.5 | 31.4 | 6 | 25 | 6 | 0 | 0 | 0 | 7014 / 6493 | 377 | 288 | 25.0 / 25.0 / 50.0 | 0 |
| narrow (25 Mbit/s link) | 50 | 5170 | 60.0 | 29.1 | 4 | 6 | 3 | 0 | 0 | 0 | 942 / 170 | 14 | 229 | 25.0 / 10.8 / 11.5 | 2 |
| narrow (25 Mbit/s link), 300 s | 50 | 17788 | 60.0 | - | 2 | 3 | 2 | 0 | 0 | 0 | 1029 / 354 | 180 | - | 25.0 / 12.5 / 16.1 | 2 |

After the rate controller's last change (`ea941d3`; unchanged since), same method:

| profile | ceiling | seconds | frames | skipped | given up | repair requests / frames | keys after first | decode errors | longest gap ms | rate start / low / end | cuts |
|---|---|---|---|---|---|---|---|---|---|---|---|
| narrow (25 Mbit/s link) | 50 | 300 | 17533 | 37 | 6 | 7 / 6 | 0 | 0 | 184 | 25.0 / 11.8 / 20.1 | 6 |
| narrow (25 Mbit/s link) | 50 | 300 | 17630 | 38 | 6 | 8 / 6 | 0 | 0 | 198 | 25.0 / 11.2 / 19.8 | 6 |
| lossy | 40 | 90 | 5104 | 0 | 0 | 0 / 0 | 0 | 0 | 310 | 20.0 / 20.0 / 40.0 | 0 |
| bursty | 50 | 90 | 5087 | 75 | 7 | 29 / 6 | 0 | 0 | 303 | 25.0 / 25.0 / 45.0 | 1 |
| clean | default (20) | 90 | 5186 | 0 | 0 | 0 / 0 | 0 | 0 | 81 | 20.0 / 20.0 / 20.0 | 0 |

- On the narrow link the rate now ends near 20 of 25 Mbit/s; the cuts (6 in 300 s) land at the game's own bursts of heavy picture, at the same moments in every run (`todo.md`).
- Host side, same runs: send failures 0; paced sender late p95 50 us, max 97...158 us; median frame 39.8...40.0 KB at the default ceiling, 56...58 KB at 40 / 50, 23.6 KB on the narrow link at 50 (after the cuts); repair frame median 45...139 KB; one key frame a run (the first).
- Shows: every frame given up was answered by a repair frame; no second key frame, no escalation, no decode error in any run; the rate controller cuts on the narrow link and does not fall a second time in 90 s or in 300 s.
- Does not show: any device or radio (loopback, a simulated link); a spread (one run per row); whether the 300 s narrow run's slow climb (16.1 of 25 Mbit/s after 5 min) is right: UNVERIFIED, recorded in `todo.md`.
- Open: `longest gap` 177 ms on a clean link (the stream's start or the game's own long frame: not examined); repair requests exceed repair frames on `bursty` (22 for 5, 25 for 6: asks repeat every 35 ms until a restart point comes, or wasted: not examined); `lossy` at 40: one cut (20 -> 14) on 1 % random loss, then a climb to 32.3.

#### patch-file

- The tap is published as `tap/stream-tap.patch`: `git diff --binary --full-index <pin>..stream-tap` of the clone, one file, no commit messages or authors.
- `scripts/apply_tap.sh [<folder> [<nxnative URL or clone>]]`: clone (default `<repo>/nxnative`), branch `stream-tap` at the pinned commit (`PIN` at the top of the script, the full hash of `conventions.md § tap-pin`), `git apply --index`, one commit. Refuses a dirty clone, an existing `stream-tap`, a patch that does not apply (the branch is removed again).
- The gate keeps the file true: with a clone that has `stream-tap`, `scripts/preflight.sh` compares the clone's diff with the file and the script's `PIN` with `TAP_PIN` (exit 3).
- After any tap commit or a pin move: `git -C <repo>/nxnative diff --binary --full-index <pin>..stream-tap > tap/stream-tap.patch`, same commit as the docs.
- VERIFIED 2026-11-22: a fresh clone patched by the script has the same tree as `stream-tap`; a patch with a changed context line is refused and leaves no branch.
