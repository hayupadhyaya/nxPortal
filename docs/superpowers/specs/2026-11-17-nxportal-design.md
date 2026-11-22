# nxPortal design

Date: 2026-11-17. Status: approved by the owner on 2026-11-17. Working rules: `CLAUDE.md`.

Lines marked **(decided)** are the owner's decisions. Lines marked **(call)** are choices made while writing this and are open to correction.

## Intent

A game built with [nxnative](https://github.com/seedds/nxnative) runs invisibly on an Apple silicon Mac. Its picture and sound go to an Apple TV, iPad or iPhone, and that device's controllers drive it. The Mac stays fully usable meanwhile.

Why: the Mac is the only machine that runs these games well. A TV is the obvious place to play them, and many iPhones and iPads cannot run them natively (nxnative needs an A17 Pro iPhone or an M1 iPad).

## Decisions already made

- **(decided)** The name is nxPortal. It is open source under MIT and meant for anyone who uses nxnative.
- **(decided)** The owner distributes the apps signed with their own developer identity.
- **(decided)** Apple TV is a first-class client, alongside iPhone and iPad.
- **(decided)** Pushes, releases, TestFlight / App Store uploads, notarized builds and upstream pull requests are the maintainer's. The work could later be offered to nxnative.
- **(decided, from the earlier spec)**
  - Stream the game only, never the whole screen, and never through ScreenCaptureKit.
  - The Mac's display can be off or locked.
  - Game audio plays only on the device.
  - The Mac's mouse, keyboard and controllers never reach the game, and nothing takes focus.
  - The game runs in its own background process, with no VM.
  - No new entitlements.

## Goals

1. From the couch: open nxPortal on the Apple TV, pick a game, play it with a controller. Nobody touches the Mac after the one-time pairing.
2. The same on iPhone and iPad, with gyro aiming.
3. It feels local: 60 fps delivered, and p95 capture-to-display delay of 40 ms or less on home Wi-Fi.
4. Another nxnative user can install it without reading code: one signed Mac app, one client app, and games built with the tap.

## Non-goals (first release)

- Play away from home (remote play over the internet).
- HDR, 120 fps, surround sound.
- More than one device watching or playing the same game at once.
- Packing or building games. Other front ends do that.

## Anti-goals

- A window, Dock icon or sound appearing on the Mac while streaming.
- A game left running unattended after the connection drops (the player's character standing still in a fight).
- Needing to walk to the Mac for each session.
- Anything from Nintendo or a game publisher in the repository or in the apps: no names, art, keys or game data. Game names and icons come from the user's own Mac at run time.
- A large, hard-to-rebase patch on nxnative.

## Constraints

- **Platforms:** Mac host on macOS 26.6 or later (nxnative's minimum), Apple silicon. Clients: **(call)** the lowest iOS and tvOS version that needs no extra code, aiming for 17; tested on the owner's devices (Apple TV 4K 3rd generation, iPad mini 6, iPhones).
- **Dependencies:** Apple frameworks only, no third-party code.
- **Entitlements:** none new. Local network access uses Info.plist keys (`NSLocalNetworkUsageDescription`, `NSBonjourServices`).
- **nxnative's rules:** front ends are separate projects that pin an nxnative commit. Upstream takes only a small pull request for the piece a front end needs, and wants an issue first for anything near 1,000 lines.
- **Secrets:** the signing team and the bundle ID prefix come from the environment. `prod.keys` is only ever a path. No personal information in the repository, logs or commits (`.claude/conventions.md § public-repo`).
- **Working rules (decided):** `CLAUDE.md` and `.claude/conventions.md`: worktrees off `main`, root cause before any fix, a failing test before each fix, protocol versions bumped with every wire change.
- **Commits:** local only, under the owner's own git identity. **(call)** The `seedds` commit line in nxnative's `AGENTS.md` is the upstream maintainer's and is not used here.

## Approaches

| | A. Companion app plus a small tap | B. Fork does everything | C. Plugin library |
|---|---|---|---|
| Where streaming code lives | nxPortal repo; nxnative gets a small tap | Inside nxnative's game process | A library loaded into the game |
| nxnative patch | Small, upstreamable | Large, in fast-moving files | Small hook, but loads outside code |
| Streaming fix needs a game rebuild | Rarely (only tap changes) | Always | No |
| Game library, launch, one-time pairing | In the companion app | No natural home | Still needs a companion app |
| Processes on the Mac | Two | One | One, plus the companion |

**Chosen: A (decided).** It fits both "local for now" and "could integrate into nxnative": the tap is the piece that can be offered upstream, and until then nxPortal carries it as a small patch on a pinned commit. B is what the old plan did; it was rejected because every user would build games from a fork and there is nowhere to put the couch features. C was rejected because upstream is unlikely to accept loading outside code.

## The parts

```
Apple TV / iPad / iPhone          Mac
┌──────────────┐  Wi-Fi   ┌───────────────────┐  local   ┌──────────────────┐
│ nxPortal app │◄────────►│ nxPortal Host     │◄────────►│ game (nxnative)  │
│ decode, play,│  video,  │ pairing, library, │  socket  │ no window; tap:  │
│ controllers  │  sound,  │ launch, network   │          │ encode, sound    │
└──────────────┘  input   └───────────────────┘          │ out, input in    │
                                                         └──────────────────┘
```

### 1. The tap (a patch to nxnative)

One switch, `DM_STREAM=<socket path>`, set by the Host when it starts a game. With it:

- The Mac launcher shows no settings window and does not set `DM_WINDOW` or `DM_AUDIO`. Today `dm/mac/launcher.c` always sets `DM_WINDOW=1`, so the old plan would still have opened a window.
- The host runs headless, opens no audio device, and connects to the socket. If it cannot connect it exits with a `[RED]` line. If the socket later closes it quits cleanly, so no invisible game is orphaned.
- **Video:** in `present_now` (`dm/gfx/nvn/nvn_mtl.m`), before the window layer is looked up. This one place serves the NVN, Vulkan and OpenGL games. The frame is copied into a small pool of IOSurface-backed textures with the tap's own Metal 4 command buffer (the present path has none at that point), then compressed with VideoToolbox: HEVC, low-latency rate control, no frame reordering.
- **Size (call):** the game's own picture size, capped by what the client asks for. The client scales and letterboxes. The old plan upscaled to the device's screen size on the Mac, which spends bitrate on pixels that carry no detail. The encoder is recreated only when the picture size changes.
- **Bitrate (call):** a client setting (10 to 200 Mbit/s, default 50), sent in the network `hello` (network protocol 2). The Host's default when the client asks for none is 20 Mbit/s; the Host's own maximum (default 200 Mbit/s, `portal-hostd --max-bitrate`) caps what a client may ask for.
- **Keyframes (call):** at start and on request only. The old plan's keyframe every 2 seconds causes a bitrate spike every 2 seconds.
- **Sound:** the silent sink's PCM (48 kHz), sent uncompressed with its channel count. nxnative runs one sink thread per open audio output (2, 6 or 8 channels), so the tap mixes the outputs into one stereo stream, using the stereo fold where the sink carries one.
- **Input:** buttons and sticks for up to four players (`dm_pad_set_player`, `dm_pad_players`), motion (`dm_motion_set` for a controller's sensor, `dm_motion_set_switch` for a phone's), and later touch (`dm_touch_set`).
- **Pause:** the tap can run nxnative's existing background sequence (focus lost, audio suspended, guest clock frozen, graphics suspended) and its reverse. Today that sequence is a private test helper in `dm/host/hle_oe.c`; the tap exposes it.
- **Messages on the socket.**
  - Game to Host: hello (protocol version, title ID, name), video frame (each carries its number, capture time, picture size and key flag), audio block. A picture-size change shows in the next frame, which is a key frame; the game exiting is the socket closing.
  - Host to game: settings (size cap, frame-rate cap, bitrate), keyframe request, input, motion, players, pause, quit.
- **A marker:** `pack_app.py` writes `DMStream` into the app's Info.plist, so the Host can tell a tap-enabled game from one that would open a window.
- **Size budget:** new files `dm/host/stream.h`, `stream_mac.c` and `stream_video_mac.m` (nxnative keeps Mac-only files out of the iOS app by the `_mac` name), about 700 lines. Hooks in existing files stay under about 80 lines in total: `nvn_mtl.m`, `hle_audio.c`, `hle_oe.c`, `front_mac.m`, `launcher.c`, `pack_app.py`, the Makefiles, `docs/env_switches.tsv`, `docs/frontends.md`.
- **Where:** a git worktree of the local clone at `nxPortal/nxnative`, branch `stream-tap`, off today's `main` (`e4b0d9b7`). The nxPortal repo ignores that folder.

### 2. nxPortal Host (Mac app)

A menu-bar app with no Dock icon, written in Swift, signed with Developer ID and notarized. It is not sandboxed, because it starts other apps.

- **Library:** finds nxnative game apps in `/Applications`, `~/Applications` and folders the user adds, by the `DMTitleID` key in their Info.plist. Games without `DMStream` are listed as "rebuild needed".
- **Launch:** runs the app's `Contents/MacOS/nxnative` with `DM_STREAM` and `DM_LAUNCHER=0` in its environment. The game's saved settings apply as usual.
- **One game and one device at a time.** A second device is told which device is playing.
- **Pairing:** once per device (below). The menu lists paired devices and can remove them.
- **Network:** advertises itself with Bonjour, relays the tap's video and sound to the device and the device's input to the tap.
- **Power:** keeps the Mac awake while a game runs; the display may sleep.

### 3. nxPortal client (one app for Apple TV, iPad, iPhone)

SwiftUI, one codebase, two targets (iOS and tvOS).

- **Screens:** Macs found on the network, pairing, the game library, playing. An in-play menu offers stats, disconnect and quit game.
- **Video:** hardware HEVC decode, shown as soon as decoded, or paced to the display refresh through a one-frame buffer (a setting).
- **Sound:** a short jitter buffer (20 to 30 ms); a lost packet is faded, not played as a click.
- **Controllers:** up to four through GameController, mapped to the Switch layout the way nxnative's own `pad_apple.h` maps them.
- **Gyro:** a controller's motion sensor when it has one; on iPhone and iPad the device's own sensors for player 1, using the axis mapping in nxnative's `dm/ios/Sources/DmGamepad.m`.
- **Apple TV:** the Siri Remote drives the menus; playing needs a game controller.

### 4. PortalKit (shared Swift package)

The wire format, encryption, pairing, frame splitting and reassembly, and session rules, used by both the Host and the client and tested with `swift test` on the Mac. This replaces the old plan's C header shared through a bridging header and its hand-written SHA-256.

It also builds two command-line tools **(call)**:

- `portal-fakegame`: speaks the tap's socket protocol with a moving test pattern and a tone, so the Host and client can be built and tested with no game.
- `portal-fakeclient`: pairs, records the stream to files, sends scripted input, prints stats.

## Network and security

- **Discovery:** Bonjour, service type `_nxportal._tcp`, named after the Mac.
- **Two flows (call):** a TCP connection for things that must arrive (pairing, the game list and icons, launch, quit, settings) and a UDP flow for things that must be fresh (video, sound, input, loss reports, pings). The old plan put everything on one UDP flow, which would have needed its own delivery guarantees for the game list.
- **Pairing, once per device (call):** both sides exchange public keys (X25519, CryptoKit). The Mac shows a 6-digit code in its menu-bar window and a notification; the user types it on the device. The code is single-use, expires after 2 minutes and allows 3 tries. Each side then stores the other's key. The old plan showed a new code at every start, which defeats "the Mac's display can be off".
- **Every session is encrypted (call):** keys are derived per session from the stored keys, and every packet in both directions is sealed (ChaCha20-Poly1305) with a counter, so recorded packets cannot be replayed. In the old plan one sniffed packet was enough to work out the code offline, and picture and sound were sent in the clear.
- **Known limit:** someone already on the home network who actively intercepts the 2-minute pairing exchange could guess the code. A stronger exchange is possible later without changing anything else.
- **Video packets:** 1,200 bytes of payload at most. A frame missing any piece is never shown. The client asks for the missing pieces again and the Host resends them (network protocol 3); a frame still incomplete after a short wait (about 25–50 ms) is given up, and the client keeps the last good frame and asks for a keyframe -> `2026-11-18-wifi-transport-design.md` § 2.
- **Sound (call):** uncompressed 16-bit stereo, 5 ms per packet (about 1.5 Mbit/s). On a home network this removes the audio codec, its delay and its risk. Opus arrives with remote play.
- **Input:** the full state of each player on every change, and at least every 8 ms while something moves; numbered, with stale packets ignored.

## Behaviour in the awkward cases

1. **Wi-Fi drops, or the client app goes to the background:** after 500 ms without input the controllers go neutral. After 10 s without any packet the game is paused (3 s until the Wi-Fi transport work: `2026-11-18-wifi-transport-design.md § 7`); after 1 s the app says "Reconnecting…". A paused game waits until the user resumes or quits it **(call: no automatic quit)**.
   - **Resume (decided):** the same device reconnecting resumes at once with a fresh keyframe. Any other paired device sees "Resume <game>" at the top of its library and may take the paused game over; merely connecting does not unpause it. A game with a live session cannot be taken over.
   - **Power (decided):** the Mac is kept awake while a device is connected and for 10 minutes after the last one leaves. Then it may sleep; the game stays paused in memory. Waking the Mac from the device is phase 2.
2. **Packet loss:** no damaged frame is ever shown.
3. **A second device connects:** refused, and the first session is unaffected.
4. **The Mac is used normally** (mouse, keyboard, a controller plugged into it, display asleep, screen locked): the game sees none of it, and no window or Dock icon appears.
5. **The game changes picture size or shape** (an in-game movie): the picture stays in proportion.
6. **The Host quits or crashes:** the game quits cleanly.
7. **The game crashes or quits:** the client returns to the library and says why.

## Known gaps in headless play

nxnative answers these with "cancelled" when there is no window: the on-screen keyboard, the account picker and the "more players wanted" prompt. A game that needs one of them cannot get past it until phase 3 forwards them to the device.

## Phases

Each phase ends with something that works. Phase 1 has two plans: A, the Mac side, proven with command-line tools (done 2026-11-17; results in `.claude/tap.md § first-light`); B, the apps and the devices, written from A's measurements.

1. **First light.** The tap, PortalKit, the two test tools, a minimal Host (pairing, a text list of games, launch, quit) and a minimal client on iPhone, iPad and Apple TV: find the Mac, pair, pick a game, play it with one controller and gyro, with sound. All seven awkward cases above hold.
2. **Couch.** Four players, a library grid with icons, the in-play menu and stats, bitrate and size settings, waking a sleeping Mac, starting the Host at login.
3. **Completeness.** Touch on iPhone and iPad, rumble, the keyboard, account and player prompts forwarded to the device, cheaper loss recovery, per-game settings on the device.

Later: HDR, 120 fps, surround, remote play, the upstream pull request for the tap, TestFlight or App Store, a notarized Host release.

## How it is checked

- **PortalKit:** unit tests for packet round trips, tamper and replay rejection, pairing (right code, wrong code, lockout, expiry), reassembly under loss and reordering, and the input timeout.
- **Tap:** tests in nxnative's own style (`dm/host/tests`). A synthetic frame sequence is encoded, decoded again and checked for colour, size and frame count; input reaches the pad functions; a closed socket ends the game.
- **Host and client without a game:** `portal-fakegame` and `portal-fakeclient` over loopback.
- **End to end:** The test game (`0400486024DEC000`) on the Apple TV, the iPad mini and an iPhone for 10 minutes each, recording delivered frame rate, p95 delay, damaged frames and audio-to-video sync. Then each awkward case by hand.
- **Phase 1 pass marks (call):**
  - Damaged frames shown: zero, on any link.
  - 59 fps or more delivered and p95 delay of 40 ms or less, on a clean link (Ethernet, or 5 GHz Wi-Fi with under 0.1 % loss).
  - "Delay" runs from the tap's capture time to the moment the client hands the decoded frame to the display layer, measured in the app with the ping clock offset. Panel delay is not measured.
  - Freezes from lost packets are counted and recorded, not gated. Phase 1 recovered only by keyframe request; lost pieces are now asked for again first (`2026-11-18-wifi-transport-design.md` § 2). If the count exceeds one a minute on the owner's Wi-Fi, cheaper recovery moves from phase 3 to phase 2.
  - The network packet header reserves a recovery-group field from version 1, so adding repair packets later is not a format break.
- **On-device steps (decided):** the agent may sign the client (development signing, team from the environment) and install it on the owner's Apple TV, iPad and iPhones from the development Mac. nxnative's own rule against installing on the owner's devices covers game builds and does not apply to the nxPortal client.

## Open risks, each checked by a short experiment before it is relied on

1. **Frame pacing with no window.** nxnative paces a headless game on its own clock rather than the display's. The tap must deliver a steady 60 fps from that.
2. **Decode delay on Apple TV.** The simple display path may add delay; a lower-level decode path is the fallback.
3. **The Mac's own controllers.** The headless host must not read them. This is believed true and has to be confirmed.
4. **App review.** Apple TV apps ship only through TestFlight or the App Store. The client is a neutral streaming receiver; review is still the main distribution risk.
5. **Upstream.** If nxnative does not take the tap, nxPortal keeps carrying the patch and users build games from a pinned, patched commit.

## Left to the builder

- Exact message layouts and field sizes on both the socket and the network.
- The decode and display path on the client, chosen by measured delay.
- The Host's and client's visual design. The first phase needs only plain, working screens.
- The controller chord or gesture that opens the in-play menu.
- **(call)** Bundle IDs are `<prefix>.nxportal` (client) and `<prefix>.nxportal.host`, with the prefix read from the environment at build time, so no personal identifier is in the repository. The old plan hard-coded one.

## Repository layout (local for now)

```
nxPortal/
  CLAUDE.md          working rules (AGENTS.md and GEMINI.md link to it)
  .claude/           topic docs: conventions, build; worktrees/ (ignored by git)
  LICENSE            MIT
  README.md
  todo.md            focus list
  docs/superpowers/specs/   this document
  PortalKit/         Swift package: protocol, crypto, tests, the two test tools
  Host/              the Mac menu-bar app
  Client/            the iOS and tvOS app
  scripts/           preflight gate, git hook installer
  nxnative/          worktree of the local nxnative clone, branch stream-tap (ignored by git)
```
