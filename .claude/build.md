# Build, test, toolchain

Only what exists today. Add a command here in the same commit that makes it real.

#### toolchain

VERIFIED 2026-11-17 on the development Mac (Apple M6, macOS 27.2.1):

- The active Xcode stays as it is (never `xcode-select`); every nxnative
  command uses `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  (Xcode 27.2). Swift package commands for nxPortal use the active toolchain.
- `xcodegen` and `ffprobe` are installed (Homebrew).
- macOS SDK has `kAudioFormatOpus`, `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`
  and `kVTCompressionPropertyKey_EnableLTR`. Presence in headers only; behaviour is UNVERIFIED.

#### preflight

```bash
swift test --package-path PortalKit          # PortalKit unit tests
bash scripts/preflight.sh [--quick] [--strict]   # the gate, inside a worktree
bash scripts/install_git_hooks.sh [--remove]     # commit-msg hook, once per clone
```

- Exit: 0 green, 1 dirty tree / not `worktree-*`, 2 not rebased on `main`,
  3 test failure, 4 doc warning (`--strict`), 5 banned word.
- The tests are the whole `swift test` run, `ScenarioTests` included (Host, session, shaper and the real decoder in one process; run them alone, they are timing-sensitive). One whole-stack scenario per profile: `ScenarioTests.testBaselineForEveryProfile` (`clean`, `lossy`, `bursty`, `stalls`, `narrow`, 4 s each; `stalls` is asserted only for order and survival there, its bounds are in `testPausesAreNotCut`, `testASessionSurvivesAFourSecondStall` and `testRepairedLossDoesNotCutTheRate`); longer runs per profile in `testRepairedLossDoesNotCutTheRate` (`lossy`, `bursty`, `stalls`) and the narrow-link tests.
- `--quick` skips tests. Tap tests (`dm/gfx/tests`, `dm/host/tests`) run only
  once `nxnative/` has commits past the pin.
- Tap tests run with `DEVELOPER_DIR=$NX_DEVELOPER_DIR` (`local.env`, surrounding
  quotes stripped; default `/Applications/Xcode.app/Contents/Developer`) -> `§ toolchain`.
- App builds: after the tests, `scripts/client.sh build-sim` (both targets) and `scripts/host.sh build` when anything under `Client/`, `Host/`, `PortalKit/Sources` or `PortalKit/Package.swift` changed against `main`; skipped with `--quick`, and skipped with a line saying so when `xcodegen` is not installed.
- Doc mapping: `scripts/doc_map.sh`, shared by the gate and the hook.
- Banned words: `<git common dir>/info/banned-words`, one per line, untracked.
- Machine values: `.claude/local.env` in the main checkout (keys in
  `.claude/local.env.example`), git-ignored.

#### host

```bash
swift test --package-path PortalKit --filter 'HostServiceTests|GameLibraryTests|PairingStoreTests|TapServerTests'   # Host core (~30 s)
swift run --package-path PortalKit portal-hostd --fake --pair                    # Host with the fake game -> host.md § hostd
swift run --package-path PortalKit portal-hostd --library <games dir> --pair     # Host with real game apps
```

#### client

```bash
swift test --package-path PortalKit --filter LoopbackTests    # client against a real Host on loopback (~10 s)
swift run --package-path PortalKit portal-hostd --fake --pair # shell 1: prints the port and the code
swift run --package-path PortalKit portal-fakeclient --host 127.0.0.1:<port> --pair <code> \
  --launch FAKE000000000000 --seconds 5 --out <dir>           # shell 2: <dir>/out.hevc, out.wav
#   add --shape <clean|lossy|bursty|stalls|narrow|random> [--seed <n>] for a simulated bad network between client and Host (portalkit.md § test-network)
#   add --decode to decode and acknowledge every picture (the game then repairs with repair frames; client.md § fakeclient)
ffprobe <dir>/out.hevc                                        # hevc, 1280x720
```

#### shaped-host

A device (or any client) over real Wi-Fi gets the same seeded bad networks as the loopback scenarios:

```bash
swift run --package-path PortalKit portal-hostd --fake --pair --shape <profile> [--seed <n>]   # or --library <dir> with a real game
# prints: shaper: profile=<name> seed=<n>   (always; `random` draws a fresh seed unless --seed is given)
# at exit: shaper: forwarded=<n> dropped=<n>
```

- Pair and play from the device as usual: the Host's `welcome` advertises the shaper's UDP port, so the media goes device -> shaper -> Host (loopback) -> shaper -> device. Control (TCP) is not shaped.
- Profiles: `portalkit.md § test-network`. `random` is the one for "what happens in situations nobody scripted"; a bad run is replayed by its printed seed (`--seed <n>`): the same events at the same offsets for the same traffic (real time still varies the rest).
- The shaper adds its own latency (a few ms) and its Host to client rate limit applies to the media only. Stop it with SIGINT (by PID, never `pkill`). Development only: no menu-bar setting.

#### host-app

```bash
bash scripts/host.sh gen                        # xcodegen: Host/project.yml -> Host/NxPortalHost.xcodeproj (git-ignored)
bash scripts/host.sh build                      # Debug; CONFIGURATION=Release for Release. Team-signed when local.env has DEVELOPMENT_TEAM, ad hoc otherwise
bash scripts/host.sh path                       # the built app's binary (<repo>/build/host/derived/Build/Products/<config>/nxPortal Host.app/Contents/MacOS/nxPortal Host)
bash scripts/host.sh package                    # builds Release itself (whatever was built before), then <repo>/build/host/nxPortal-Host.zip (ditto, keeps the signature); one line: "packaged the Release build: <zip>"
```

- Version: the Host app stays at `1.0` until the store release of the client (owner, 2026-11-19); builds are told apart by commit.

- Machine values from `local.env` as `client.sh` reads them (`DEVELOPMENT_TEAM`, `PORTAL_BUNDLE_PREFIX` — `local.dev` when empty —, `NX_DEVELOPER_DIR`); the script prints none.
- Proof run with the fake game (loopback, nothing of the account's is touched; stop it by its PID, it advertises on the network while it runs):

```bash
swift build --package-path PortalKit
"$(bash scripts/host.sh path)" -autoStore <tmp>/store -autoName "nxPortal Test Host" \
    -autoFakeGame PortalKit/.build/debug/portal-fakegame -autoPair      # prints: listening on port <n>, status: …, pairing code: <code>
portal-fakeclient --host 127.0.0.1:<port> --pair <code> --launch FAKE000000000000 --seconds 10 --out <tmp>/out --store <tmp>/client.json
kill -TERM <pid>                                                        # exits 0 once the Host has stopped (a game with it)
# -autoWindow shows the menu in an ordinary window; -autoSnapshot <png> (with it) writes the menu's picture 2 s later (`-autoSnapshotDelay <s>` changes the wait; `-autoWindowClose <s>` closes the window then, and the echo shows "menu opened", "menu read <n>", "menu closed")
```

- Start the app by its binary path in unattended runs, never with `open`. `-auto…` arguments exist in Debug builds only (`strings` on a Release binary finds none) -> `host.md § app`.

#### client-app

```bash
bash scripts/client.sh gen                         # xcodegen: Client/project.yml -> Client/NxPortal.xcodeproj (git-ignored)
bash scripts/client.sh build-sim                   # NxPortal (iOS Simulator) and NxPortalTV (tvOS Simulator)
bash scripts/client.sh run-sim [--sim "nxPortal <name>" | --tv] [app arguments]   # build, boot the simulator if needed (default "nxPortal iPhone"; --tv = "nxPortal Apple TV" with the tvOS app; the name must begin with "nxPortal " and exist: never created), install, launch with --console-pty
bash scripts/client.sh build-device                # signed NxPortal for iOS, -allowProvisioningUpdates
bash scripts/client.sh build-device <model substring>   # the same, built for that device; registers a device the team profile does not know yet
bash scripts/client.sh build-device --tv [<model substring>]   # the same for the Apple TV app (NxPortalTV, tvOS); `install --tv`, `launch --tv`, `logs --tv` look for an Apple TV
bash scripts/client.sh install <model substring>   # one connected device whose model name contains it
bash scripts/client.sh launch <model substring> [app arguments]   # --console
bash scripts/client.sh logs <model substring> [<dir>]   # copies the app's `sessions` folder (`client.md § recorder`) to build/client/sessions/<UTC time>/ or <dir>
bash scripts/client.sh archive <ios|tvos> <build number>   # Release xcarchive, generic device, CURRENT_PROJECT_VERSION=<n>, in <repo>/build/client/archives/
bash scripts/client.sh export <ios|tvos> [upload]   # newest archive of that platform -> upload package under <repo>/build/client/export/; `upload` sends it to App Store Connect
```

- Version: the apps stay at `1.0` until the store release (owner, 2026-11-19): no `1.0.1` or other version change before it. Each upload differs only in its build number (`archive <ios|tvos> <n>`, `n` higher than the last upload).
- Reads `<repo>/.claude/local.env`: `NX_DEVELOPER_DIR` (every xcodebuild / xcrun / devicectl call), `PORTAL_BUNDLE_PREFIX`, `DEVELOPMENT_TEAM`. Bundle ID `<prefix>.nxportal`; both reach xcodebuild as build settings, never `project.yml`.
- Simulator builds: empty prefix -> `local.dev`; ad-hoc signed (`CODE_SIGN_IDENTITY=-`), no team. Unsigned binaries get no keychain entitlement and the paired-Mac store fails (`storeFailed`). Device builds stop when the team or prefix is empty.
- Products and logs: `<repo>/build/client/` (`derived/`, `<scheme>-<config>.log`). `CONFIGURATION=Release` builds without the automation.
- `build-device <model>`: the device is found as for `install` (the lookup gives the CoreDevice identifier; `xcodebuild` is given the hardware UDID, `hardwareProperties.udid`) and the build adds `-allowProvisioningDeviceRegistration`. A build log with `No Accounts` stops with `client.sh: Xcode has no signed-in account (Xcode → Settings → Accounts); a new device cannot be registered`. The identifier is never printed (the build line says "the connected device").
- `archive`: refuses a build number that is not a positive integer or one already archived; team and prefix as `build-device` takes them, never echoed (errors print `<team>` / `<prefix>`); log `<scheme>-archive.log`. The binary of a Release archive has no `-auto…` argument names (`Automation.swift` is `#if DEBUG`).
- `export`: writes `build/client/ExportOptions-<platform>.plist` (git-ignored, mode 600; `app-store-connect`, automatic signing, the team, `destination` = `export` or `upload`, symbols on) and runs `xcodebuild -exportArchive -allowProvisioningUpdates`; prints paths only, never the plist or the team.
- Uploading, and the first export (it creates a distribution certificate in the account), are the owner's steps.
- `install` / `launch` print the device model only, never its name or identifier.
- Simulator proof (VERIFIED 2026-11-18, fake game):

```bash
swift build --package-path PortalKit
PortalKit/.build/debug/portal-hostd --fake --pair --name "nxPortal Test Host" --store <tmp>/host.json --library <empty dir>   # prints the code
bash scripts/client.sh run-sim -autoHost "nxPortal Test Host" -autoCode <code> -autoLaunch FAKE000000000000 -autoSeconds 20 -autoPress A@5 [-autoPacing smooth|immediate] [-autoBitrate <Mbit/s>]
# stat t=3 mac=60.0 shown=60.0 late=0.0 gaps=0 delay=7.1 p95=9.0 rtt=1.2 gap95=17.0 gapmax=21.0 skipped=0 key=0 mbit=2.4 decode=3.0 buf=25 under=0   (once a second)
# auto frames=1210 displayed=1210 fps=60.0 fps_avg=60.0 fps_min=58.3 fps_med=60.0 p95_ms=6.4 p95_display_ms=7.8 skipped=0 audio_lost=0 underruns=1 shown_med=60.0 late=0 gaps=0
```

- The lines -> `client.md § app`. Reading it:
  - `stat` lines tell where a stutter starts: `gaps` rising = the Mac sent no frame (game or rate cap); `gap95` / `gapmax` high with `gaps` flat = the network; `late` / `shown` below `mac` = this device's pacing; `decode` near 16 ms = the decoder;
  - `shown_med` / `late`: pictures a second that got a display refresh of their own (median) and pictures that never did (total); `-autoPacing immediate` against `smooth` shows what the pacer changes; on a real network `shown_med` well under `fps_med` with `late` high is bunching;
  - the stream is whole when `displayed == frames` and `skipped=0`;
  - `fps_med` (median of the one-second samples of pictures displayed) is the pass mark for 59 fps: a real game presents fewer frames in its own loading seconds, which lowers `fps_min` and `fps_avg` but not the median;
  - with the fake game (steady 60) `fps_min` is the stricter check: at least 55 in the simulator.
- Real game in the simulator (same Mac, 60 s from the first picture, 2026-11-19): `displayed=3195` of `frames=3195`, `skipped=0`, `p95_display_ms=22.6`, `fps_avg=53.2`. The same game to `portal-fakeclient` in the same hour: 3,477 frames, 59.5 fps. The simulator decodes HEVC in software on the Mac that also runs the game, so the game itself presents fewer frames: a simulator run measures the path, not the pass mark (VERIFIED by the two runs).
- A second run on the same `--store` needs no code (the simulator's keychain keeps the pairing). Screenshots: `xcrun simctl io <UDID> screenshot <file>`.
- The fake game's colour changes every second (red, green, blue). A button press shows on the Host as `fake game input: buttons=0x00000001` (A) and, about 200 ms later, `buttons=0x00000000`.

#### icons
- `swift scripts/make_icons.swift <repo root>` redraws every app icon from one recipe (spec item l): iOS 1024 (opaque), the tvOS brand asset (Back / Middle / Front per icon size, Top Shelf 1920x720 and 2320x720, @1x / @2x), the Host's 16...1024.
- `swift scripts/make_icons.swift --check <repo root>` draws into a temporary folder and exits non-zero when any committed image or `Contents.json` differs from what the recipe draws (nothing in the repository is written); `scripts/preflight.sh` runs it with the tests.
- Deterministic (same bytes every run; rerun leaves the tree clean); refuses a path outside the repository (symbolic links resolved first, also in sub-paths that exist); exits non-zero if a size, the iOS alpha, a Back / Top Shelf opacity, or the Front (centre 60 %) / Middle (centre 80 %) bounds fail.
- Check the catalogue: `xcrun assetutil --info <NxPortal.app>/Assets.car` lists `App Icon/{Back,Middle,Front}/Content`.
- The Host's menu-bar symbol is a system symbol, not drawn here. No dark / tinted iOS variants for 1.0.

#### package-on-devices

```bash
cd PortalKit && DEVELOPER_DIR="$NX_DEVELOPER_DIR" xcodebuild -scheme PortalPlayer \
  -destination 'generic/platform=iOS' -derivedDataPath .build/xcode build    # and generic/platform=tvOS
```

- `NX_DEVELOPER_DIR` from `local.env` -> `§ toolchain`. Expect `** BUILD SUCCEEDED **`, no warning.
- SwiftPM exposes one scheme per library product (`xcodebuild -list`); `.build/` is git-ignored.
- Use it for any target that must build off the Mac (`PortalPlayer`, `PortalClientCore`).

#### nxnative-baseline

VERIFIED 2026-11-22 at pin `184847c5` (upstream alone, a scratch worktree of
that commit, removed afterwards) and with the tap on it (`stream-tap`, head
`c5e00741`, 16 commits), from the tap worktree (`nxnative/`), Xcode 27.2
selected per command (`§ toolchain`):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
make -C dm/host dmhost GAME=0400486024DEC000
make -C dm/gfx/tests GAME=0400486024DEC000 check_t_stream_present check_t_present_alloc
make -C dm/host/tests GAME=0400486024DEC000 run
(cd dm/tools/tests && python3 -m unittest test_docs test_env_switches test_player_env)   # test_nsp_mac_app too when the launcher or the packer changed
```

| | upstream alone | with the tap |
|---|---|---|
| `dmhost` | exit 0, 66 warnings (19 distinct sites) | exit 0, the same sites, none in `stream*`, `audio_input` |
| host tests `run` | exit 0, 56 `checks, 0 failed` lines | exit 0, 57: the same 56 and `t_stream` 94 checks; `t_audio_input --stream` passes |
| `t_stream_present`, `t_present_alloc` | (`t_stream_present` is the tap's) 13 | 41, 13 |
| `t_stream_prepare` | (the tap's) | 12, 7 and 2 checks |
| `t_pso_archive` | 433, active flush 24 | the same, `--stream-flush` 17 |
| python | docs 6, env switches 1, player env 1: OK | the same; `test_nsp_mac_app` 90 tests OK |

- Pre-existing failures: `t_rt_recycle` (a gfx test the gate does not run) fails 1 of 40 at the pin itself, the same with the tap. Output lines such as `DM_TEST_FS_FAIL=…` are
  the tests' fault-injection switches, not failures.
- Builds and tests touch only `dm/host/gen/` and `dm/host/tests/build/` in the
  tap worktree; no game files are needed.
- Compare later runs against this: 57 `checks, 0 failed` lines in the host tests.
- Make targets the gate calls (`dmhost`, `run`, `check_t_stream_present`) exist unchanged at the pin (the target names did not change upstream across the move).
- The numbers are read from the rebase report's runs; a pin move runs them again and replaces this block.

#### simulators

nxPortal's own, found by name (UDIDs are per machine and stay out of the repo):

```bash
xcrun simctl list devices available | grep 'nxPortal '
```

- `nxPortal Apple TV` — tvOS
- `nxPortal iPhone` — iOS

Pass the UDID that command prints as `-destination 'platform=…,id=<UDID>'`
-> `conventions.md § simulators`.

#### real-game

Streaming a real game with the test tools. VERIFIED 2026-11-17; packed again at the pin `184847c5` and run 2026-11-22 (`.claude/tap.md § real-run`).

- **Never in the owner's folders** (`conventions.md § owner-data`): the app is
  packed into `<repo>/build/` (git-ignored), its work folder too, and the game
  runs with a scratch `HOME` so the owner's saves, logs and cloud-save choices
  are never opened.
- An app packed by an older nxnative cannot be reused by swapping binaries:
  the shader library is tied to the packing commit. A pin move
  is such a change: a copy packed at the old base needs a new pack (or the
  new copy, prepared on that Mac), not a new `dmhost` in it.
- The launcher has no make target: the packer builds it (`build_launcher`),
  so a launcher change means packing again. A host-only change is still the swap below.
- Steps of the pack at the new base (VERIFIED, `<repo>/build/pack-h.log`; title `0400486024DEC000`, a first pack at that base, extraction reused): unpack 0:10 (image checked), rewrite 0:44, shader split 0:31, Mac shaders 25:32, Mac host 0:06, pipeline archive 17:11, prewarm 2:49, Mac app 2:11; about 50 min in all.
- A second pack straight after (`pack-i.log`, nothing but the host and launcher changed) reuses the shaders, the split, the rewrite and the archive: each reads 0:00 or 0:01 "reused (inputs unchanged)"; prewarm 2:25 and the Mac app 2:09 still run; under 5 min in all.
- nxnative's packing script needs its own Python modules (`lz4`, `capstone`,
  `fonttools`, `zbic`); use the Python environment nxnative builds use on this Mac.

```bash
# pack (from the tap worktree; ~50 min for the test game at the new base, most of it shaders and the pipeline archive; ~5 min for a second pack)
cd <repo>/nxnative
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer <python with nxnative's modules> \
  scripts/build_ipa_from_nsp.py "<game file or folder>" --platform mac-app \
  -o <repo>/build/<name>/game.app --work-dir <repo>/build/work/<title ID> \
  --bundle-id local.nxportal.streamtest
# reuse an earlier extraction: cp -c -R <existing work folder>/extract <repo>/build/work/<title ID>/ first

# only the host changed: swap it into a clone and sign again (under a second: the game data sits in signed bundles)
cp -c -R <repo>/build/<name>/game.app <repo>/build/<name2>/game.app
cp -X dm/host/dmhost <repo>/build/<name2>/game.app/Contents/MacOS/dmhost
codesign --force --sign - <repo>/build/<name2>/game.app/Contents/MacOS/dmhost
codesign --force --sign - <repo>/build/<name2>/game.app

# run
HOME=<repo>/build/stream-home DM_SAVE_SYNC=0 portal-hostd --library <repo>/build/<name> --pair --port 0
portal-fakeclient --host 127.0.0.1:<port> --pair <code> --launch <title ID> --seconds 60 --out <dir> --press A@20 --quit
```

- **First launch of a new or changed bundle:** macOS scans it before the
  launcher's first instruction, about 150 s for the 34 GB test game, again
  after every change to the bundle. Start it once by hand first
  (`DM_STREAM=/nonexistent DM_LAUNCHER=0 HOME=<scratch> game.app/Contents/MacOS/nxnative`
  exits with one `[RED]` line when the scan is done), or rely on the Host's
  600 s start timeout.
- The game's log: `<scratch HOME>/Library/Logs/nxnative/<title ID>.log`
  (the launcher keeps one earlier log as `.prev.log`).
- Results and the awkward cases -> `.claude/tap.md § first-light`.

#### owed-device-checks

Nothing has run on a real device yet (2026-11-19): the first launch needs a person (unlock, the Local Network prompt). Plan B1 Task 8, in order:

1. iPad unlocked and awake; `bash scripts/client.sh build-device`, then `install "<model>"` (a model text that matches one real device: two of the same family need the longer text, for example the part in brackets; simulators are never matched, they share model names with devices).
2. Host: `portal-hostd --library <folder with the game app> --pair` (`.claude/host.md § hostd`); the code lasts 120 s.
3. On the iPad: open nxPortal, allow Local Network, pick the Mac, type the code, pick the game.
4. Automated numbers once paired: `launch "<model>" -autoHost <name> -autoLaunch <title ID> -autoSeconds 60 -autoPress A@20`; pass marks -> `§ client-app` (reading the line).
5. By hand: a controller (buttons, sticks, the disconnect and reconnect of it), gyro, sound by ear with the overlay's `underruns` (the sound buffer is in Settings), 10 minutes of play, Wi-Fi off and on, the app to the background and back, quit a game and start another without leaving, a second device refused while the iPad plays.
6. What to watch (from the final review): the Local Network prompt under a "cannot search" message on the first launch; a black first picture with key requests climbing (decoder); sound over Bluetooth; freezes after a lost packet on Wi-Fi (key frames are large; v1 recovers only by key frame).


#### wifi-device-table

Device numbers for the Wi-Fi transport: the automation's `stat` / `auto` lines (`client.md § app`), real Wi-Fi, a real game, 60 s unless noted. "Before" = sessions measured by hand-started or automated runs before the work they name; every figure VERIFIED in the session record (the ledger of the plan), none re-measured at the head. "After" = OWED: no device has run the final head.

| Run (before) | Shown fps | Late / s | Sound underruns | Delay p50 ms | Round trip ms | Notes |
|---|---|---|---|---|---|---|
| Phone, `smooth` (one-picture queue), 20 Mbit/s fixed | 59.9 | - | - | 45.6 | 1.0 | 0 skipped, 0 key frames, 4 gaps in 60 s, arrival gap p95 19 ms |
| Phone, `smooth`, 100 Mbit/s setting (the rate did not yet follow the link) | - | - | - | 45.6 | - | stream 64 median / 90 peak Mbit/s, 0 skipped, 0 key frames |
| Tablet, `immediate`, 20 Mbit/s fixed (first run) | "nearer 30 than 60" (owner) | - | 17 | - | - | p95 display 75.8 ms, 3 session drops at game start |
| 60 Hz tablet, 200 ceiling, pacing mode not recorded, 25 ms sound buffer, 79 s | 49 median (min 38) | 7...22 every second | about 2 a second (167 in 78 s) | - | 5.3 | Mac sent 60 fps, 0 lost, arrival gap p95 19.6 ms, rise to 37...45 ms about every 10 s |
| same, `-autoPacing smooth` (one-picture queue), sound buffer 100 ms, 157 s | 51 | 9 | 6 in 157 s | 50...58 | - | one loss cut 200 -> 140 at 64 s |
| same, 451 s | - | 8...9 | 11 | - | - | 17 frames lost, rate 200 |

| Run (after) | Status |
|---|---|
| Tablet at a 50 Mbit/s ceiling, final head | OWED |
| Tablet at a 100 Mbit/s ceiling, final head | OWED |
| Tablet at a 150 Mbit/s ceiling, final head | OWED |

- OWED, in this order: (1) the Host and the game copy on the second Mac updated together (the game copy must carry tap protocol 2 from the tap's branch head; a Host at tap protocol 1 cannot use it), the Mac on a wire; (2) the app at the final head on the tablet (Release for hands-on; the automation flags are Debug-only, so measured runs stay Debug); (3) three runs of 60 s: `-autoBitrate 50`, `100`, `150`, `-autoPacing smooth`, the line pairs `stat` / `auto` kept; (4) compare against the rows above. Pass marks: `late` under 1 a second over 2 minutes (the pacer), `underruns` near 0 (the automatic sound buffer), `escalations=0` and `refreshes` > 0 with `given_up` > 0 (the repair path), `cuts` few and no second fall (the rate).
- The recorder build on the tablets writes one file per session: pull it with `scripts/client.sh logs "<model>"` (a branch outside this plan; `todo.md`).
