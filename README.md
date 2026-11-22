# nxPortal

Stream a game built with [nxnative](https://github.com/seedds/nxnative) from an
Apple silicon Mac to an Apple TV, iPad or iPhone, with controllers and motion.
The game runs on the Mac with no window; the device shows the picture, plays
the sound and sends input back.

nxPortal is not affiliated with Nintendo or any game publisher. It contains no
game data, keys or artwork. You bring games you own, packed with nxnative.

## Status

Early, and playable: a game runs on the Mac with no window and plays on an iPad, iPhone or
Apple TV over home Wi-Fi at 1080p and 60 frames a second, with controllers, motion and touch
controls. Most of the hands-on play so far was on tablets; the phone and Apple TV apps run and
have had little play. Nothing is notarized or in a store: you build the apps yourself.
What is open is in `todo.md`.

| Part | State |
|------|-------|
| **Tap**: a small patch to nxnative (no window, HEVC video and sound out, input in) | works; shipped as one patch file for a pinned nxnative commit (`tap/stream-tap.patch`, applied by `scripts/apply_tap.sh`) |
| **PortalKit**: Swift package (protocol, pairing, session rules, Host and client cores) | works, tested |
| **Test tools**: `portal-hostd`, `portal-fakeclient`, `portal-fakegame` | work |
| **Host**: Mac menu-bar app | menu, pairing, devices (Rename), games with their icons and a "Preparing N %" tag, folders, a status line with the stream's rate, a time bar under the pairing code; proven with the fake game over loopback |
| **Client**: one app for iOS and tvOS | game library with icons, in-play menu, per-game options, settings; builds for both; proven in the iPhone, iPad and Apple TV simulators. On Apple TV a game controller plays and the remote's Menu or Play/Pause opens the in-play menu (not yet tried on a real Apple TV) |

## Try it (no game needed)

Requires macOS 14 or later and Xcode's command-line tools.

```bash
swift build --package-path PortalKit
swift test  --package-path PortalKit

# terminal 1: a Host with a built-in fake game; prints a port and a pairing code
PortalKit/.build/debug/portal-hostd --fake --pair --port 0 --store /tmp/portal-try-host.json

# terminal 2: pair, launch the fake game, record 5 seconds
PortalKit/.build/debug/portal-fakeclient --host 127.0.0.1:<port> --pair <code> \
    --launch FAKE000000000000 --seconds 5 --out /tmp/portal-out --quit --store /tmp/portal-try-client.json
```

The client's last line reports frames, frame rate and delay; `out.hevc` and
`out.wav` hold what it received. `--store` keeps this try's pairing apart from a real Host's
(`~/Library/Application Support/nxPortal/host.json`).

## Get a game ready

A game is packed with nxnative as a Mac app, from an nxnative that carries the stream tap.
The tap is a patch on one nxnative commit; one command makes the patched clone:

```bash
bash scripts/apply_tap.sh            # clones nxnative into <repo>/nxnative, checks out the pinned commit, applies tap/stream-tap.patch
```

By hand it is three steps: clone nxnative, `git checkout` the commit named at the top of
`scripts/apply_tap.sh`, `git apply <repo>/tap/stream-tap.patch`. Then pack your game from that
clone as nxnative's own README says, with `--platform mac-app`, and put the app where the Host
looks (below). A game packed from an unpatched nxnative shows in the Host's list and cannot
be streamed.

## Run the Host

The Host is a menu-bar app (no Dock icon). Build it on a Mac with Xcode and `xcodegen`
(machine values as for the client, below); with no signing team in `.claude/local.env` it is signed ad hoc.

```bash
bash scripts/host.sh build      # <repo>/build/host/...; CONFIGURATION=Release for a Release build
bash scripts/host.sh package    # builds Release itself, then <repo>/build/host/nxPortal-Host.zip, to copy to another Mac
```

- Copy the zip with `scp` or a USB stick (not AirDrop or a download: the app is not notarized, and macOS blocks a
  quarantined copy; `xattr -dr com.apple.quarantine "nxPortal Host.app"` lifts it). Open the app: a game controller
  icon appears in the menu bar. Allow the "local network" question the first time.
- "Pair a Device" shows a six-digit code for two minutes; type it on the device. The menu lists paired devices and
  games (an nxnative-packed `.app` in `/Applications`, `~/Applications` or a folder added with "Game Folders…").
  Each game shows its icon; a game preparing its graphics shows "Preparing N %". While a device plays, a second line
  under the status gives the stream's rate. The pairing code has a bar showing the time left. "Quit Game" ends a game; the name can be changed there too (that restarts the Host and ends a running game).
  Each device shows under its model's name ("iPad mini"); two of one model are numbered ("iPad mini 2"). Rename a device
  in that list with "Rename"; a device's own name is set in its Settings under "This device".
- The pairing store lives in `~/Library/Application Support/nxPortal/` (readable by you only); the log in
  `~/Library/Logs/nxPortal/host.log`, game logs beside it.
- The first start of a game on a Mac prepares its graphics (minutes). The app shows "Preparing graphics for this Mac" with a bar, or "Waiting for the game" when the Mac has said nothing for a while; you can go back to the games meanwhile: it carries on, its tile shows how far it is ("Preparing 36 %"), and once it
is ready it pauses until you choose it again.
- A game keeps its saves and prepared graphics under the `HOME` it is started with. To start every game with
  your own, put a file `~/Library/Application Support/nxPortal/environment.json` next to the store: one object of
  text values, for example `{"HOME": "/Users/you/portal-home"}`, plus a save-sync folder variable if your games use one.
  The file is read when the app starts.

## Build and run the client

Needs Xcode and `xcodegen` (`brew install xcodegen`). Machine values (signing team,
bundle ID prefix, Xcode location) go in `.claude/local.env`, see `.claude/local.env.example`.

```bash
bash scripts/client.sh build-sim      # iOS and tvOS simulator builds, no signing team needed
bash scripts/client.sh run-sim        # install and start the app in the simulator named "nxPortal iPhone"
bash scripts/client.sh build-device   # signed iPhone / iPad build (needs the team and prefix)
bash scripts/client.sh install iPad   # install on the connected device whose model contains "iPad"
```

In the simulator, start the test Host first (above); the app finds it by name.

First run: with no paired Mac the app explains itself and lists the Macs it finds ("How to set up a Mac" has the steps);
choose one and type the six-digit code from the Mac's menu (a sheet; a wrong code leaves it open). After that the app
opens on the last Mac's games (the last known list, greyed, until it connects); the sidebar (iPad) or the Mac button
(iPhone) changes Mac. The app runs in landscape.
The library shows each game as a tile with its own icon (sent by your Mac, kept only in the app's cache on your
device), the game you were playing (or played last) in a Continue card at the top, and lights the screen with that
game's colours. A game paused on the Mac waits there ("Paused") until you choose it: opening the app or a Mac never
drops you into play. A game without an icon shows its initials; one that needs a rebuild on the Mac is greyed. Touch and
hold a tile for its page. Pull down (iPhone) or Refresh (iPad) asks the Mac for the list again. `portal-hostd --fake
--fake-shelf` adds placeholder games with icons drawn by the tool.
Details: `.claude/build.md`.

While playing, a small panel at the top left shows live numbers. Its level is a setting
(Settings > Numbers, or the in-play menu): Off; FPS (the default: `60 fps  1920 x 1080`);
Compact (two lines: the Mac's and the screen's frame rate, late pictures, the picture mode,
delay, the rate against its ceiling); Full (the network round trip and gaps, the rate with its cuts,
decode time and the sound buffer; "Automatic" sound buffer follows what the Wi-Fi does and shows "auto"; and
the Mac's load: CPU and GPU with small bars, performance and efficiency cores, memory, memory pressure and heat, and the
game's own CPU, memory, frame rate and frame times). The Mac measures its load only while a device shows the Full
level, once a second, and sends numbers only (no names or paths); "GPU n/a" when the Mac gives no GPU reading.

**On-screen controller (iPhone and iPad).** With no game controller connected the screen carries
the controls of a game console in the layout the game runtime uses itself: shoulders and triggers in
the top corners, the left stick bottom left, A / B / X / Y bottom right (slide a finger between keys),
Minus and Plus at the top. "Simple (2D)" is that; "Full (3D)" adds the D-pad, the two stick clicks and
a camera stick on the right third of the screen (touch there and drag). The gear at the top centre
opens the in-play menu, where "Touch layout" is chosen per game (Settings > "Layout for new games"
sets the first choice). A light tap answers each press (Settings > "Haptics on touch controls").
Connecting a game controller hides the controls (the gear stays) and says "Controller connected · touch controls hidden";
the numbers panel sits under the top row while the controls are shown, and the touch layout row shows only with no controller.
Opening the menu, a controller connecting or the screen turning lets every control go.
The layout is a port of the runtime's virtual gamepad (MIT, Copyright (c) 2026 seedds); the notice is
in Settings > Acknowledgements and `Client/Resources/Acknowledgements.txt`.

**In-play menu.** Open it with the gear at the top centre. It shows what changes at once: the bitrate
ceiling (the stream adapts below it), "Smooth picture" (on by default: one picture per
display refresh keeps the motion even when frames arrive in bunches; costs about one refresh
of delay, a little more for a moment after a hiccup; off for the least possible delay) and the
numbers level. Stream size and frame rate need a new connection (sizes above what the game renders are greyed, with the size the game really streams at shown under the choice): change them, then "Apply and
reconnect" (the game keeps running on the Mac). Disconnect pauses the game and shows the Mac's games (choose it to go
on); Quit ends it. While you are only looking at the games, another device can connect to the Mac: the app then
says "<Mac> is now in use on <device>." and waits; Retry takes the Mac back unless that device is playing.
A game that lists its own options (render scale, frame rate and the like) shows them on its page, opened by a long press or the
⋯ button on its tile, and under "Next start of this game" in the menu: change one and it applies the next time the game
starts on the Mac; "Reset to tested defaults" removes your choices. A row this app cannot change is shown, not hidden.
Close the menu with its button, a tap outside it, B or the Home button on a controller (the
game gets no input while it is open and no button is left pressed). Holding the controller's Menu and
Options buttons together for half a second opens and closes it too (the game still sees both
buttons).
Settings > Controller > "Menu + Options opens the in-play menu" turns it off. A Mac that is
renamed on the network (for example a "(2)" suffix) is still recognised: no new code is asked for.

**If the picture freezes.** The app says so in three calm steps. After a second without word
from the Mac (usually a Wi-Fi hiccup) a small "Reconnecting…" pill shows over the frozen picture;
your controls go neutral so nothing stays pressed, and the picture comes back by itself when the
connection does. After 3 seconds the picture blurs and says "Reconnecting to <Mac>" with "Stop and
go to games". After 10 seconds without any contact the session ends: a card says "The session
ended" and that the game is paused on the Mac and waits. "Reconnect" tries again at once and picks
the game up where it was; "Back to games" shows the library of the same Mac, live. The app keeps
trying to reconnect behind the card, and a Mac that stays silent for 5 minutes ends up as an
unreachable library. A game that is starting or preparing is never shown as trouble.

If the Mac answers but no picture or sound ever arrives (a session that never got going),
the app gives up on that session after 2 seconds and tries again; after three such tries it
says "The Mac answers, but its video cannot reach this device. Check that both are on the
same network." On the Mac, `portal-hostd` prints one `session end:` line per session saying
why it ended.

A game built for streaming is still an ordinary game: opened by hand on the Mac, it plays there with its picture and sound.

**On Wi-Fi.** Use the 5 GHz or 6 GHz band for the device, and put the Mac on a cable
where you can: the stream is the heavy part, and the Mac's side of the link is the one
you control. When the picture stutters, the panel says where to look:

| Panel line | What it says | What to try |
|---|---|---|
| `Network` `lost`, `gap p95` | Pictures were lost or arrived in bunches | Move closer or off 2.4 GHz; the loss repair counts (asked, repaired, given up, key frames) are in the session numbers file below |
| `Rate` `cuts` | The stream lowered its rate because the link could not carry it (a softer picture, by design) | A lower "Bitrate ceiling" if it cuts often; a better link if the rate stays low |
| `Shown` `late` | Pictures that did not get a screen refresh of their own | Keep "Smooth picture" on; high `late` with `Network gap p95` high is the link, with it low is the device |
| `Sound` `underruns`, `buffer` (Full level) | The sound buffer ran dry; in Automatic it grows by itself | Leave it on Automatic; a fixed larger buffer in Settings trades delay for fewer dropouts |
| `Mac` `gaps` | The Mac sent no picture (the game itself hitched) | Not the network |
| A hitch about once a second for the first minute or so after a device wakes | Apple devices near each other look for one another on a shared radio channel, and the Wi-Fi radio leaves the router's channel to do it | Set the router's 5 GHz band to channel 149 (44 in Europe), the channel that search uses; or turn off pointer-and-keyboard sharing between the Mac and the tablet (Mac: Displays → Advanced) |

Settings > Sound > "Play sound" turns the sound off for every session, also a running one. Settings has "Keep session numbers on this device" (on by default): each session writes one text file of per-second numbers to the app's folder on the device; nothing is sent anywhere. A developer copies them off with `scripts/client.sh logs <model>` (`.claude/client.md § recorder`).

Settings → Picture has "Bitrate ceiling" (10 to 200 Mbit/s, default 50), also in the in-play menu: a ceiling, not a
fixed rate. A session starts at half of it and the stream's rate follows what your network
carries below it: when the link cannot keep up, the rate drops within a fraction of a second
(a softer picture instead of a frozen one) and climbs back when the link is good again. A
still picture (a menu) uses little and does not raise the rate; it climbs once the picture is busy.
A higher ceiling allows a sharper picture on a strong Wi-Fi or wired network. A change applies
at once, while you play (a lower ceiling cuts the rate now; a higher one lets it climb), and the Mac caps it (`portal-hostd --max-bitrate <Mbit/s>`, default 200).

Streaming a real game needs nxnative with the tap and a game packed by it:
`.claude/build.md` and `.claude/tap.md`.

## How it works

- The game connects to the Host over a local socket (`DM_STREAM`), sends
  encoded frames and PCM sound, and takes input, pause and quit.
- Host and client pair once with a 6-digit code; after that every session is
  authenticated and encrypted with keys both sides hold.
- Control messages travel over TCP, video, sound and input over UDP.
- When the client goes away the game pauses; any paired device can resume it.

Design: `docs/superpowers/specs/2026-11-17-nxportal-design.md`.
Agent and contributor rules: `CLAUDE.md`.

## License

MIT, see `LICENSE`. The on-screen controller's layout is a port of the runtime's virtual gamepad, also MIT
(Copyright (c) 2026 seedds): notice in `Client/Resources/Acknowledgements.txt`.
