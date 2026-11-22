# A stream that holds up on Wi-Fi — design

Date: 2026-11-18. Extends `2026-11-17-nxportal-design.md § 3` (network). Status: built and proven over
loopback and with the real game through the link shaper (`tap.md § wifi`); the device proof is OWED
(`build.md § wifi-device-table`, `todo.md`).
Every choice below that the owner might have made differently is
listed under **Calls made**.

## Why

First hands-on session, iPad on Wi-Fi, Mac wired: controls and gyro are good; the picture
stutters, looks nearer 30 fps than 60, and is visibly compressed. The owner: it has to be
great on Wi-Fi; a wired iPad is a comparison, not the answer; on a local network the bitrate
should go past 100 Mbit/s.

What the code does today, and what each costs on Wi-Fi:

| Today | On Wi-Fi |
|---|---|
| A frame is 20–300 datagrams sent in one burst | The access point's queue takes the burst; overflow is loss in runs |
| The assembler holds one frame; a fragment of the next frame abandons it | One late or lost datagram loses the frame |
| A lost frame asks for a key frame | The key frame is the largest burst of all, and loses more |
| Fixed bitrate | A link that cannot carry it queues, then drops |
| Pictures shown on arrival, or through a fixed one-picture buffer | Two pictures in one refresh, none in the next |
| Either side ends the session after 3 s of silence | A radio stall during a game's start ends the session |
| Sound: raw PCM, one datagram per block, fixed buffer | A lost datagram is a click; jitter is an underrun |
| The Mac's rate cap refused the frame after a long one | Fixed in the tap (one repeated picture per game hitch) |

## Goals

- On the owner's Wi-Fi, a 60 fps game at 1080p–1440p plays without visible stutter beyond the
  game's own, at 50–150 Mbit/s when the link carries it, and degrades to a softer picture
  rather than a jerky one when it does not.
- Isolated loss, loss in runs, reordering and a stall of up to 200 ms each cost at most a
  few late pictures, never a frozen second, never a session.
- Every mechanism is proven in a simulated bad network before a device run, and its effect is
  visible in the stats panel and the automation's lines.

## Non-goals

- Streaming over the internet (round trips over ~30 ms, NAT, relays).
- A deep buffer: added delay stays within about two refreshes on a clean link.
- Changing the codec or the picture format.
- Controlling the device's radio: an app cannot. `README.md` says what a user can do
  (5 GHz / 6 GHz, a router channel the device's peer-to-peer discovery already uses).

## Anti-goals

- Hiding trouble by adding delay until play feels detached.
- A setting the user must tune to get a good picture: defaults adapt; settings are ceilings.

## Approaches considered

1. **Recover by retransmission, pace the sender, adapt the rate (chosen).** The round trip on a
   local network is 2–10 ms, so one request-and-resend fits inside a frame period; it repairs a
   run of losses as well as a single one, and costs bandwidth only when something was lost.
2. **Forward error correction first** (parity per frame, 15–25 %). No round trip, but a run of
   losses takes the parity with the data, the overhead is paid always, and it is the larger
   build (an erasure code). Kept as the next step if device numbers show many frames repaired
   late: the retransmission path and the statistics it needs are the same.
3. **A larger buffer and nothing else.** Smooths jitter, repairs nothing, and costs delay always.

## Design

### 1. A bad network in the test tools
`LinkShaper` (in `PortalTestSupport`): a UDP relay between a client and the Host, seeded and
repeatable, each direction with: loss (independent, and in runs), delay with jitter,
reordering, a stall (nothing passes for n ms, then everything at once), and a bottleneck
(a byte rate with a bounded queue that drops its tail — the access point). `ClientSession`
takes an optional media endpoint override so tests and `portal-fakeclient --via` can route
through it. Named profiles (`clean`, `lossy`, `bursty`, `stalls`, `narrow`) are the
vocabulary of every test below and of `portal-fakeclient --shape`.

### 2. Lost datagrams are asked for again
- The assembler keeps a window of frames (the newest 8) and puts frames out in order. A frame
  is complete when all fragments are in; a missing fragment is known when a later fragment of
  the same frame, or any fragment of a later frame, has arrived, or when no fragment of a
  partly received frame has arrived for 4 ms (its tail was lost: the Host sends a frame back to back;
  the give-up clock for such a tail starts only when a later frame arrives, so a stall gives nothing up).
- The client asks: `nack(frame, indices)` (at most 64 indices a datagram); a hole inside a
  frame 1 ms after it was seen (the settle: a swap of two datagrams heals by itself), a hole
  shown by a later frame or by the quiet tail at once (only while some Host datagram has arrived 4 ms or more after the frame's last fragment: a radio stall asks for nothing); again after `max(2 × round trip, 8 ms)`,
  three times at most.
- The Host keeps the last 0.5 s of video fragments (unsealed: a resend is sealed afresh, the
  receiver refuses a replayed counter) and resends what is asked, ahead of new video.
- A frame still incomplete `settle + 2 × retry + round trip + 5 ms` (at most 50 ms; retry =
  `max(2 × round trip, 8 ms)`) after it was first seen missing is given up, so every one of the
  three asks can be answered before it (until the cap): the client asks for a refresh (below) and shows nothing until it comes.
- The client's repair timer is one task that sleeps to the earliest deadline; a deadline earlier than the one it
  sleeps to (a hole seen after its frame's first ask) replaces it, so every hole gets its three asks before the
  give-up (`RepairTimerTests`).
- Sound and input are not retransmitted (too late to matter); see 6.

### 3. The sender paces
The Host sends each frame's datagrams spread over part of the frame period (default 4 ms of
16.7; none for a frame of 8 datagrams or fewer), never faster than three times the video rate, so
a large frame takes longer and the frames behind it wait, from one sending thread with three queues:
replies and sound first, resends second, new video third. A frame not fully sent when the next
arrives keeps its place; if more than 100 ms of data waits behind the frame now leaving, the oldest
unsent frame (never a key or repair frame) is dropped whole and counted (the client will ask for a refresh).
A key frame drops the unsent frames before it. `portal-hostd --pace-ms`.

### 4. A lost frame is repaired without a key frame, where the encoder can
The encoder's long-term-reference mode: it marks frames with a token; the client acknowledges
frames it decoded; on a refresh request the encoder predicts the next frame from the newest
acknowledged one, a normal-sized frame (a "repair frame") instead of a key frame. This needs the
tap (encoder options, a token and a flags byte on each video message, acknowledgement and refresh
messages: tap protocol 2). The HEVC encoder on the owner's macOS accepts it (the tap's probes).
- The client acknowledges (`ack`, at most 30 a second, always a key or repair frame) only frames
  its decoder reported decoded. The Host keeps each frame's token for 2 s and passes the token of
  an acknowledged frame to the game (only a frame newer than the last acknowledged, never one of
  an earlier picture size).
- A frame given up: the client asks for a restart point (`repair`; the Host passes `refresh`);
  the tap decides: a repair frame when an acknowledged frame reached the encoder since the last
  key frame, else a key frame. The tap marks the frame (key or repair) and the Host copies the
  mark into every fragment; the Host never guesses which frame answers (frames encoded before the
  tap read the request are still in flight and depend on the lost frame).
- The client's output restarts at the first complete key or repair frame; the frames in between
  are dropped, not decoded. The `repair` is asked again every 35 ms until a restart point comes
  out (held while fragments of one are arriving); with none 1 s after the first `repair` it asks
  for a key frame instead (escalation, a safety net: a key frame is the worst thing to ask of a
  link that just lost frames, and the cases that need one get one at once). It asks for a key frame straight away, and takes
  no repair frame as a restart point, until a key frame has decoded: at session start, after its
  decoder failed or was made again, after a recovery from a stall.

### 5. The rate follows the link
The user's bitrate setting becomes a ceiling ("Bitrate, up to"); the client steers the Host's rate below it. In order
of importance: never leave the stream above what the link carries for more than a few hundred ms; find the ceiling
quickly on a good link; a steady link gives a steady rate, not a cut every few seconds.
- The client decides (a pure controller, time and samples from the session), every 200 ms and at once when a frame is
  given up, from a sliding window: frames given up, fragments asked for again against fragments received, the delivered
  rate over the last 300 ms, what the encoder produced (frame sizes from their fragments, over 300 ms and 1 s), and the
  ping floor (the lowest round trip of the last 300 ms; pings go 10 a second) against its 30 s minimum. Pongs held by a
  radio pause arrive together, each carrying the pause: after a gap of over 150 ms between arrivals, only pongs sent
  after it count (a queue delays pongs but keeps their cadence).
- Loss trouble: 2 frames given up in a second (a give-up counts 150 ms after it, unless a fragment of the frame arrived
  late meanwhile: a delayed burst is not a shortage; none in a stream's first second); over 10 % asked again in a second, or over 20 % in one sample. Queue
  trouble: the ping floor more than `max(15 ms, 2 x minimum)` above its minimum. Frame delay is no signal: a busy
  picture raises it with no queue anywhere. A constant high round trip, a radio pause, one late pong, repaired loss
  (1 % independent, 2.3 % in runs) and a single given-up frame are not trouble.
- The cut: `0.7 x rate`, never under `0.7 x` what the encoder produced in the last second, floor 2 Mbit/s. Only when
  loss trouble shows the link is the limit (the encoder produced at least half the rate in the window and the link
  delivered under 90 % of it) does the delivered rate count: `min(0.7 x rate, 0.85 x delivered)`. A quiet picture
  delivers little on a good link, and must not set the cut, the remembered rate or a measured cut.
- No further cut until the last has had time to show (`max(400 ms, 4 x round trip)` after the Host could apply it),
  unless, 200 ms after it, the link (link-limited as above) delivered under half the rate since the cut, or the picture
  has not come back (frames still given up, none completed); no increase for 5 s.
- A session starts at half the ceiling (not under 10 Mbit/s) and climbs + 25 % per clean second until the first trouble.
  A clean second counts for an increase only when the encoder produced at least half the rate in it. After trouble: back
  to 90 % of the remembered rate within 4 clean seconds, held; probes of + 5 % after 30 clean seconds; 60 full, clean
  seconds above the memory (a second where the encoder fills under 0.9 of the rate pauses the count; trouble resets
  it) and the fast climb is allowed again.
- The memory is the last rate that ran clean for a second with demand (an episode is trouble after at least 1 s
  clean; cuts inside it change nothing). A rate that never did (the start, a climb step, a probe) is no memory and
  never raises one: trouble at an unproven probe above an existing memory leaves the memory, and a sample of the
  episode that shows the link (link-limited) lowers it to what the link delivered; with no memory, it is what the
  link delivered, else the rate the episode began at. Trouble below the memory lowers it to the rate, or to what the
  link delivered when link-limited; a loss with no link evidence and no queue under a *measured* memory (one that ran
  clean or came from the link's delivered rate, not the episode's starting rate) cuts but leaves it. A *guessed*
  memory (the episode's starting rate) is lowered once by such a loss, to the rate then; it is measured from then on,
  so a further loss-only episode leaves it. The return climb
  aims at 0.9 x the memory, rounded to a whole bit/s so the rate reaches it (`RateControllerTests`).
- A rate counts as having run clean, a probe goes above the memory, and the memory fades only while the encoder fills
  at least 0.9 of the rate: a quiet picture proves nothing about the link.
- Every change is logged with its reason and evidence (`rate t=… why=start|climb|probe|queue|loss|givenUp|measured|frozen
  rtt_min= rtt_floor= delivered= produced=`).
- The client sends `rate(bitsPerSecond)` on a change, once a second, and after a stall; the Host clamps it to
  `[1 Mbit/s, min(the wish, its maximum)]`, passes it to the tap in a `config` of the same size (the encoder changes
  its rate without a new session or key frame) at most 4 times a second (plus one forced before each key or repair request, so that frame is sized by the newest rate), newest wins, before a pending key frame, and
  paces and budgets resends at it.
- Targets over loopback (`ScenarioTests`, 10 s runs; runs = repeats alone on the build Mac; a target not met every
  run is kept as a non-strict expected failure beside a hard regression bound, `todo.md`):

| Target | Result | Hard bound |
|---|---|---|
| Scripted dip 40 -> 8 Mbit/s, gap under 400 ms | NOT MET: 1 of 10 runs (394...581 ms, escalations 0) | 800 ms |
| `bursty` at 40 Mbit/s, gap under 100 ms | NOT MET: 3 of 10 runs (36...150 ms) | 200 ms |
| `bursty` at 40 Mbit/s, 98 % of frames out | NOT MET: 7 of 10 runs (97.0 % at worst) | 96 % |
| `bursty` at 50 Mbit/s fixed and the baseline's `bursty`, 98 % out | NOT MET in about 1 run of 20 (about 19 of 20 met) | 96 % |
| `lossy` at 40 Mbit/s, gap under 60 ms | met: 10 of 10 runs; 130 runs with the repair timer re-arm, worst gap 45 ms (hard assertion) | 60 ms |
| `bursty` at 50 Mbit/s, one key frame (every repair a repair frame) | met: 10 of 10 | hard assertion |
| `lossy` / `stalls`, escalations 0 | met: 10 of 10 | hard assertion |
| A lost repair frame replaced | met: 10 of 10, 39...72 ms | hard assertion |
| `narrow` (25 Mbit/s link), low 12.0 Mbit/s, no second fall | met: 10 of 10 (4 cuts; 5 seen in 3 of 20 runs, bound `cuts <= 5`) | `cuts <= 5` |
| Quiet-then-busy picture on `narrow`, last 6 s 359...361 of 360 frames, gap 20...23 ms | met: 10 of 10 (hard assertion; 117 ms once in a 5-cut run, bound 150 ms) | 150 ms |
| Dip return (the rate back after the dip) | 4.4...4.8 s (4.5...4.7 s after the last memory rule) | none |

- The dip: each repair frame (4) given up is asked for again at once, but those made before the cut to a rate that
  fits (about 0.2 s after the first give-up) are normal frames of the old rate, larger than the bottleneck's 30 ms
  queue, and are lost with the frames around them; after the cut the queue drains for another 0.1...0.2 s before a
  whole repair frame gets through. The rest is the rate's to win, not the repair's.
- `bursty` at 40: each give-up costs the give-up timer and the repair's restart (38...88 ms after it; the larger half
  is the give-up to the restart, median 83 ms against 47 ms before the give-up).
- A give-up time that learns from late arrivals (1.25 x the longest hole-to-arrival time of the last 5 s, at most
  50 ms) was tried and left out: it held the loss gates but gave the dip 4-6 key frames (gate 3) and `lossy` at
  40 Mbit/s a second key frame and a 90 ms gap in 2 of 5 runs.
- With the real game through the shaper (one 90 s run per profile, `tap.md § wifi`): every frame given up was
  answered by a repair frame, no second key frame, no escalation, no decode error.

### 6. Pictures and sound on the device
- **Pictures:** the paced mode is the default (a saved `immediate` is migrated once: it was the old default, not a
  choice). The queue target is fixed at 1 with a slack: after the oldest is taken, more than `target` stored counts
  the refresh as over, and after 6 in a row the surplus is dropped; more than `target + 2` stored is dropped at once.
  Two pictures between two refreshes followed by none (a few ms of arrival jitter near the refresh edge) then costs no
  picture. "Show on arrival" stays as the lowest-delay choice (`client.md § pacing`). A target that follows the arrival
  gap (1 to 3 pictures) was not built: with the measured gap p95 of 1.2 periods its rule picks 0, which drops the
  cushion every 6 refreshes and brings the fault back. A target that follows empty refreshes is an open item.
- **Sound:** the buffer target has an automatic mode (default) between 20 and 100 ms: the larger of the 99th
  percentile of the gaps between sound arrivals over 5 s + 10 ms and the second-largest gap of 30 s + 5 ms; an
  underrun adds 10 ms, held for 30 s; up at once, down at most 5 ms a second; a gap over 500 ms starts it over
  (`client.md § sound`). The previous block in the next datagram (and every block sent twice) was NOT built: the
  block and its copy do not fit one datagram, and the repeat as a datagram of its own cost a narrow link a rate cut
  and did not deliver in `lossy`; a lost sound datagram stays a 5 ms dropout (`todo.md`).

### 7. Sessions survive a stall
Both sides end a session after 10 s of silence, not 3. After 1 s without anything from the
Host the app says so over the frozen picture ("Reconnecting…") and input goes neutral (the Host
already does this after 0.5 s without input). Pings go from one a second to ten (the rate's ping floor, 5).

A Mac may have several addresses on the device's network (two interfaces in one subnet, a temporary IPv6
address); the device's media link drops an answer from any address but the one it sent to, so the Host answers
each device from the address it reached (packet info on every datagram). Each live session's end prints one
line on the Host: who ended it, datagrams in and out, send failures, how long the first datagram took, and
whether media and control reached the same address (no addresses). A session whose media path never opens
(nothing from the Host 2 s after the media started, while control works) ends at once instead of waiting for
the silence limit; after three in a row the app says the Mac's video cannot reach the device.

### 8. What is shown
The panel and the automation's lines gain: datagrams asked for again and how many came, frames
repaired late, frames given up, refreshes and key frames, the current rate against its ceiling,
the picture queue's target, and from the Host once a second its own count of frames received
from the game, sent, and dropped by the sender (a `hostStats` datagram).

## Wire changes
- Network protocol 3: datagrams `nack`, `rate`, `ack` (frames decoded, for 4), `hostStats`. The sound datagram's
  layout is unchanged. Protocol 2 (the bitrate wish in the hello) lands just before this work.
- Network protocol 3 also carries `repair` (a restart point wanted; `keyRequest` stays a real key frame) and the
  video fragment's flags byte (key, repair).
- Tap protocol 2: a flags byte and a token on `video`, `ltrAck`, `refresh`; `prepare` (the game prepares before its
  first frame: decoded, kept and logged by the Host, not yet shown).

## Proof
- Each of 2–7 has loopback tests through `LinkShaper` with the fake game, stating the profile
  and the outcome in numbers (frames shown of frames sent, longest gap, refreshes).
- One scenario test per profile for the whole stack, kept as the regression gate.
- Device: the automation's per-second lines on the owner's iPad over Wi-Fi, before and after,
  at 50, 100 and 150 Mbit/s; then the owner's hands.

## Calls made (the owner may reverse any)
- Retransmission before parity (approach 1 over 2).
- The bitrate setting is a ceiling and the rate adapts below it; a session starts at half.
- The rate rules depart from the plan's first sketch where the test network showed they had to: repaired loss in runs
  (2.3 %) and one given-up frame are not trouble; a cut can follow inside its hold when the link delivers under half
  the rate or the picture has not come back; the remembered rate is the one a trouble episode began at.
- The queue signal is the ping floor, not frame delay (a busy picture raised frame delay on a good link and the rate
  was cut to a fraction of the ceiling); the delivered rate sets a cut only when loss trouble shows the link is the
  limit; a quiet picture does not raise the rate.
- The paced picture mode is the default (about one refresh more delay than "on arrival"), with a fixed target of 1
  and a slack of 6 refreshes, not a target that follows the arrival gap.
- No repeat of sound blocks: a lost sound datagram stays a dropout (see 6).
- 10 s silence limit.
- The Host answers from the arrival address per datagram (packet info) with one IPv4 and one IPv6 socket on one
  port, not a socket per session bound to the control connection's address: the port in `welcome` keeps its meaning
  and a development shaper in front of the port keeps working.
- A media path that never opens ends the session after 2 s (`mediaPathSilent`); the third such end in a row stops the
  retry loop with a plain message rather than retrying for ever.
- The tap, not the Host, decides between a repair frame and a key frame, and marks the frame; the client, which alone
  knows its decoder, decides between asking for a repair (`repair`) and a key frame (`keyRequest`), and escalates.
- Plan B2 (the Mac menu-bar app, the Apple TV) waits behind this work.
- The Mac's own render numbers on the panel wait too.

## Left to the builder
Queue sizes and timer granularity within the limits above; the shaper's internals; the exact
arithmetic of the delay trend, provided the tests' profiles pass.
