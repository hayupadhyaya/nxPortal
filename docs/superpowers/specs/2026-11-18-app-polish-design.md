# App polish and redesign — design

Extends `2026-11-17-nxportal-design.md § 3` (the client) and `§ 2` (the Host).
Source: the owner's first hands-on session (`todo.md`, Open item 4, item 3 sub-item 1, the "second Mac" line under item 6), the owner's request of 2026-11-19 ("start with app polish (a complete redesign)"), the device-names request (`todo.md`, "Device names that tell devices apart"), the redesign mockups sent to the owner on 2026-11-19 (kept outside the repository), and the store-testing audit of the same day.
Status: draft, waiting for the owner's read; nothing in it is built.
"Owner" marks what the owner asked for. "Controller's call" marks a decision made while planning; "builder's call" marks a detail settled here so a builder need not ask. The owner can reverse any of them.

> **Assumed until the owner picks**
> - Library direction: **B "Grid"** (designer's and controller's recommendation). Only `§ screen-library` and Task 3's view step depend on it; `§ screen-library` ends with what changes if A "Shelf" is picked.
> - App icon: **concept 1 "Doorway"**. Only item l and Task 15 depend on it.

## Intent and why

- The app works, but it is a test rig: it asks which Mac every start, shows games as a text list, closes its menu on a timer, cannot change a setting without stopping the stream, says nothing while a game prepares graphics, and shows nothing of the Mac.
- This work makes it something a person opens, picks a game in and plays, without learning how it works, and that looks finished on a store-testing build (owner: "a complete redesign": every screen, not only the listed items).
- The game runtime already knows each game's options and tested defaults; the app shows those, not its own.
- A store reviewer has no Mac with the Host: the first screen must say what the app is, what it needs, and how to get there.

## Goals / Non-goals / Anti-goals

**Goals**
- One look across iPhone, iPad and Apple TV: dark, lit by the game's own icon, one focus look (`§ Look`).
- A first-run screen that explains the app and its one requirement, with a way forward (`§ screen-first-run`).
- Open the app and see the last Mac's games; change Mac from a sidebar (a).
- Tiles with the game's own artwork, in sections (b).
- An in-play menu that opens and closes at once; settings that can change live, do (c).
- No stream size above what the game renders (d).
- The Mac's load on the numbers panel (e).
- Per-game options from the runtime's own list, kept on the Mac and applied at the game's start (f).
- Landscape only (g); a visible "preparing" state with progress (h).
- The runtime's own on-screen controller, so a phone without a game controller can play (i).
- Device names that tell two devices of one model apart (j, owner).
- An app icon and Apple TV icon layers and Top Shelf image (l).

**Non-goals**
- Sound, the transport, two games at once.
- A demo mode or sample content for reviewers: the app shows only the user's own Mac; reviewers get notes and a recording (store-testing audit).
- A dynamic Top Shelf (recent games): needs an extension; later.
- A light appearance in 1.0 (builder's call: tokens carry light values for later; the app forces dark).
- The runtime's "Tap" layout (every touch goes to the game's touch screen) and per-game pointer behaviours: the stream carries controller input only today. A later item would add a touch-point message (finger slot, x and y normalised on the game's picture, down / move / up) to the network protocol, and the Host would pass it to the tap as `touch` input; not here.
- Choosing a stream size from the device's screen automatically.
- Editing a game's cloud-save folder, cheats or other files the runtime keeps.
- Redesigning the Game Mode and game-controller declarations (already made on the release-prep branch, k).
- Changing the version number: the apps stay at 1.0 until the store release; only the build number changes (owner).

**Anti-goals**
- No option name, label or value list hard-coded in the app: it renders what the Host lists.
- No game art, name or publisher text in the repository, in logs or on the wire beyond the user's own Host and device. Mockup games are invented placeholders.
- No device name in logs or in the repository (`conventions.md § public-repo`).
- No private interface that can break a build: GPU utilisation is the one soft-failing exception (item e). No entitlement that needs Apple's approval (j).
- No setting that must be tuned to get a good picture: defaults stay adaptive (`CLAUDE.md`).
- No hero images, screenshots or logos: a game has a square icon and a name, nothing else.

## Look

Direction: **a dark room lit by the game.**
- The game's square icon is the only light source: drawn huge and blurred behind the screen (the ambient glow); panels are tinted glass that pick it up.
- System type (SF), Dynamic Type styles; plain sentence-case words.
- Capsule buttons; large continuous-corner rectangles.
- ONE focus look everywhere: tiles and buttons lift and get a white ring; rows become a white platter with dark text.
- Dark only in 1.0; every screen outside play works by touch, by a game controller and by the TV remote.

#### look-colour

Named roles (asset-catalogue colours, `Color("Background")` etc.; light values kept for later, not shipped):

| Role | Dark (1.0) | Light (later) | Use |
|---|---|---|---|
| Background | `#08090D` | `#EEF0F5` | every screen |
| Grouped surface | `#14161C` | `#FFFFFF` | glass fallback (Reduce Transparency) |
| Glass fill | `rgba(40,42,56,.50)` | `rgba(255,255,255,.58)` | rows, groups, sidebar, cards |
| Thick glass fill | `rgba(30,32,42,.78)` | `rgba(255,255,255,.84)` | sheets, menus, banners, the in-play menu |
| Glass edge | `rgba(255,255,255,.16)`, 1 pt inner top line | `#FFFFFF` | on every glass shape |
| Separator | `rgba(255,255,255,.09)` | `rgba(0,0,0,.08)` | between rows, inset 18 pt |
| Fill | `rgba(255,255,255,.07)` | `rgba(0,0,0,.045)` | destructive button, code boxes |
| Fill 2 | `rgba(255,255,255,.13)` | `rgba(0,0,0,.085)` | glass buttons, tracks, segmented control |
| Text | `#F5F6FA` | `#0B0C10` | primary |
| Secondary text | `#AEB4C2` (9.6:1 on Background) | `#4A5060` | subtitles, values |
| Tertiary text | `#8D93A3` (6.4:1) | `#5B6172` | hints, "Not found" |
| Accent fill | `#3F66F2` (`#FFFFFF` text 4.78:1) | same | rarely: selected state in the Host menu |
| Accent text | `#8FA8FF` (8.4:1) | `#2A4FD0` | links, "Pair a Mac…", checkmarks |
| Positive | `#30D158` | `#24A148` | connected dot, toggles on |
| Warning | `#FFB547` | same | "Cannot reach", weak connection |
| Destructive | `#FF6B6B` | `#D92D20` | Quit game, Forget, wrong code |
| Platter | `#F5F6FA` | `#0B0C10` | focused row, primary button |
| On platter | `#0B0C10` | `#FFFFFF` | text on the platter |
| Focus ring | `#FFFFFF` | `#0B0C10` | ring on tiles and buttons |
| Slate | `#3D414E` to `#23262F`, 160° | same | no-icon tile; initials in `#DADEE8` |

#### look-type

The rule (controller's decision): the system's text styles by name; Dynamic Type sizes them on iPhone and iPad, tvOS gives its own sizes for the same names. Point sizes appear only where a size is fixed on purpose, marked **fixed**.

| Style | Weight | Use |
|---|---|---|
| Large Title | bold | screen titles ("Den Mac", "Settings"), the game page's name, the Apple TV focus caption's name |
| Title 1 | bold | first-run headline |
| Title 2 | bold | Continue game name (iPhone: Headline), "Preparing graphics…" |
| Title 3 | semibold | "The session ended" |
| Headline | semibold | row titles, sheet titles |
| Body | regular | rows |
| Subheadline | regular | tile names, notes |
| Footnote | regular (semibold for group headers) | footers, group headers |
| Caption 1 | regular | tile names on iPhone, hints |
- **Fixed**: the numbers panel (11 pt monospaced digits, its first line 13 pt semibold); the pairing code digits (30 pt iPad, 24 pt iPhone, monospaced); the in-play menu on Apple TV (rows 29 pt, group headers 29 pt semibold: the television's text floor), so the panel's height is known over the picture.
- Numbers that change (counts, fps, times, codes): `.monospacedDigit()`.

#### look-space

- Scale (pt): 4, 8, 12, 16, 20, 24, 32, 44.
- Screen margins: iPad 36 to 40; iPhone the safe area (62 beside the island in landscape); Apple TV 90 (the system's safe area).
- Tile gaps: iPad 20 across, 22 down; iPhone 10 across, 14 down; Apple TV 44.
- Tile icon sides: iPad 108 (cell 116 wide), iPhone 68 (cell 84), Apple TV 230 (cell 250); grids are adaptive (`LazyVGrid(.adaptive(minimum: cell))`), not fixed columns.
- Rows: at least 50 pt tall (iPhone 44 in sheets), 18 pt side padding; Apple TV 84 pt, 28 pt padding.
- Buttons: 44 pt tall (small 34, large 54; Apple TV 76), 20 pt side padding.

#### look-shape

- All corners `RoundedRectangle(cornerRadius:style: .continuous)`.
- Radii (pt): chip 8, row 16, group 24, banner 18, Continue card 26 (iPhone 22, TV 40), sidebar 30, sheet 36 (iPhone 32, top corners only), in-play menu 38 (TV 48), icon 22.5 % of its side, buttons and segmented controls capsule.
- Elevation, three steps only: glass rows `0 10 30 black .30`; focused `0 22 44 black .55`; sheets `0 24 60 black .45` with the screen behind dimmed to 45 % (`black .45`; the iPhone sheet .50).
- Glass: `blur 30 pt, saturation 180 %` (thick: 40 pt) over the screen, the fill colour, the 1 pt edge line. Builder's call: one `GlassBackground` modifier; on systems with the system glass effect (`if #available(iOS 26, tvOS 26, *)`) it uses `glassEffect(.regular.tint(...))`, else `.ultraThinMaterial` plus the fill and edge tokens. The deployment target stays iOS 17 / tvOS 17.

#### look-focus

One modifier, `PortalFocus`, on every focusable thing outside play:
- Tiles: scale 1.10 and lift 3 % of the side; a 3 pt white ring outside a 3 pt gap of Background; a second faint ring `white .16` 8 pt out; shadow `0 22 44 black .55`; a sheen (linear, top-left `white .38` to clear at 42 %). Name below turns bold.
- Buttons: scale 1.06, the same ring and gap, shadow `0 14 30 black .45`; a glass button turns into the platter.
- Rows: the platter (`#F5F6FA`) with On-platter text, scale 1.025, shadow `0 14 34 black .45`; secondary text and values at 68 % of the text colour; separators next to it hidden.
- Exactly one focused element per screen. Touch never shows the focus look; a touch press scales to 0.96 for 100 ms (builder's call).
- Apple TV uses the same modifier (builder's call: not the system card style), so the three platforms match.
- iPhone and iPad: the focus look appears with a hardware keyboard or a game controller that drives focus. Builder's call: rely on the system focus engine (`focusable()`, `@FocusState`) and the existing `GCSupportsControllerUserInteraction`; whether a controller moves focus on iPhone and iPad is checked once on a device (UNVERIFIED) and written in `.claude/client.md § app`. Touch remains the path there.

#### look-glow

`ArtPalette` (pure, in PortalKit; computed once per icon, cached with it):
1. Draw the icon at 8 x 8 pixels.
2. Drop near-white (lightness > 0.9), near-black (< 0.08) and grey (saturation < 0.25) pixels.
3. **Vivid**: the most frequent hue bucket (12 buckets of 30°), its pixels averaged; HSL lightness clamped to at most 0.55.
4. **Deep**: the darkest kept pixel with saturation at least 0.35.
5. Nothing kept (no icon, or a grey one): Vivid = Deep = Slate, and no ambient layer is drawn.

Ambient layer (`AmbientBackground`):
- The icon itself, drawn large behind everything, blurred, saturation 1.6, then a shade: a vertical gradient from clear to Background.
- Sizes, blur, opacity, shade per screen (from the mockups):

| Screen | Whose icon | Side | Blur | Opacity | Shade |
|---|---|---|---|---|---|
| Library, iPad | Continue game | 900 | 120 | .38 | clear to Background .80 at 60 % |
| Library, iPhone | Continue game | 640 | 90 | .30 | clear to .85 at 70 % |
| Library, Apple TV | focused tile | 1300 | 140 | .70 | clear, .35 at 45 %, .90 |
| Game page | that game | 700 | 100 | .70 | horizontal: clear to Background at 52 % |
| Preparing / waiting | that game | 560 | 90 | .75 / .55 | radial, .25 centre to .85 / .35 to .90 |
| In-play menu, errors | (the picture, blurred 14 to 18 pt, brightness .4 to .55) | | | | |
| First run, pairing, settings | none: a radial accent `rgba(110,139,255,.30)` to clear | | | | |
- Builder's call: the blur is rendered once per icon into a small bitmap (128 px, Gaussian), drawn scaled; no live blur of a large layer.
- Vivid tints: the Continue card (`linear 100°: Vivid .33, Deep .15 at 55 %, glass`), progress bars (Vivid to a 20° hue shift), the preparing icon's glow (`0 0 60 Vivid .45`).
- The icon's own edges fade to clear with an eased (smoothstep) ramp over `blur x 2.5` pt, at least a quarter of its side (the bottom of a library glow, the sides of every glow), so the .80 last stop never meets a hard edge and no end of a glow reads as an edge on a 1920-wide screen.
- With no ambient (no art), the screen is plain Background; nothing else changes.

#### look-motion

| What | Duration and curve |
|---|---|
| Focus move (lift, ring) | 180 ms, spring (response 0.35, damping 0.8) |
| Ambient colour change (TV focus, Continue changes) | 450 ms cross-fade, ease-in-out |
| Sheet in / out | 350 ms, spring (0.4, 0.86) |
| In-play menu open / close | 220 ms, spring (0.3, 0.9); never on a timer |
| Banner in | 260 ms ease-out, slides 8 pt |
| Progress | linear, updated at most twice a second |
| Touch control pressed | 60 ms in, 140 ms out |
| "Controller connected" note | fades out after 3 s |
- Reduce Motion: cross-fades only (150 ms); no lift, scale or slide; the focus ring still shows.

#### look-access

- Contrast: text at least 4.5:1 on what is behind it, including tinted glass over the glow. On tinted surfaces (Continue card, preparing, game page over its glow) all text is Text `#F5F6FA` at full opacity; hierarchy by size and weight, not grey. A test checks white on the worst composite (Vivid at its clamp, at the card's alpha, over glass over Background) for the 12 hue buckets.
- Text never sits on the bare glow: always over the shade or glass.
- Reduce Transparency: glass becomes Grouped surface (thick glass `#1E2029`), the ambient layer stays. Increase Contrast: edge line `white .35`, Secondary text `#C8CDD8`.
- Dynamic Type (iPhone, iPad): up to `.accessibility2` (builder's call: landscape heights do not hold larger). Tile icons grow with `@ScaledMetric(relativeTo: .body)` up to 1.5 x; tile names one line, two at accessibility sizes; rows wrap; every panel scrolls. Fixed size: the numbers panel, the on-screen controller, the pairing keypad digits. The on-screen controller is exempt from the contrast rule: its look is the runtime's. Apple TV: no Dynamic Type; Bold Text honoured.
- VoiceOver labels:
  - Tile: label = game name; value = state ("Paused", "Preparing, 36 percent", "Needs a rebuild on the Mac", "Mac not reachable"); hint "Plays the game."; custom actions "Options" and, when running, "Quit game". A greyed tile is disabled, not hidden.
  - Continue card: one element "Continue, Skyline Drift, paused 12 minutes ago" plus its Resume button.
  - Ambient layer and decorative icons: hidden.
  - Pairing: code boxes are one element "Code, 4 of 6 digits"; keys by digit; delete "Delete digit".
  - The gear: "Menu". The in-play menu is modal (`.isModal`): opening moves VoiceOver to its title; the escape gesture closes it; group titles are headers ("Now, changes at once").
  - Numbers panel: one element, the visible text, updates frequently, not announced.
  - On-screen controller: allows direct interaction (touches pass through with VoiceOver on); only the gear is an element.
  - Preparing: "Preparing graphics, 36 percent"; announced every 25 % (builder's call).
- Focus order on Apple TV (and on iPhone / iPad with a keyboard or controller):
  - Library: tab bar → Continue's Resume → the grid row by row. Default: Resume, else the first tile. Back from play: the tile that was played.
  - iPad: sidebar, then content; default focus is in the content.
  - Sheets and the in-play menu: the first row (pairing: key 1); closing returns focus to what opened it.
  - Errors: the primary button (Retry, Reconnect).

#### look-details

Builder's calls (from the builder check), so nothing in `§ Look` needs inventing:
- Glow placement: library: the icon centred horizontally, its top at the screen's top (it bleeds off the top); game page: centred on the left third; preparing and waiting: centred on the screen.
- Shade stops: linear top to bottom; the last stated stop holds to the end. Radial shades and the first-run accent: centre of the screen, radius half the long side.
- Blur units: the table's blur is in screen points; the bitmap blur = table blur / side x 128 px (library iPad 17.1, iPhone 18.0, TV 13.8; game page 18.3; preparing 20.6).
- Icon pixels: drawn into a transparent context; pixels with alpha under 0.5 ignored; colours un-premultiplied before HSL.
- `ArtPalette`: grey is judged by HSL saturation; averaging in sRGB; a tie between hue buckets takes the lower hue; no pixel with saturation >= 0.35: Deep = Vivid at HSL lightness 0.2.
- Glass numbers (blur 30, saturation 180 %) describe the look; SwiftUI materials cannot be set to them. The fallback is `.ultraThinMaterial` (thick: `.thinMaterial`) plus the fill and edge tokens.
- Glass edge: a 1 pt stroke all round at `white .16`, plus a 1 pt inner line along the top only at `white .30`.
- Focus ring: corner radius = the shape's radius + 3 (gap) + 3 (ring); the faint ring's 8 pt are measured from the white ring's outer edge; the sheen runs top-left to bottom-right; a tile's name sits outside the scaled frame (it does not scale). On tvOS the system effect is off (`.buttonStyle(.plain)` and `.focusEffectDisabled()`).
- Component sizes: pairing keys iPad 64 x 52, iPhone 40 x 34, Apple TV 120 x 90; code boxes iPad 58 x 70, iPhone 44 x 54, Apple TV 96 x 116; chip 22 tall; progress bar 6 tall on Fill 2; status dot 8; segmented control 34 tall (Apple TV 60); toggles tinted Positive; slider track 4 on Fill 2, thumb 26; sidebar rows 58; Mac glyph in rows 22 (sheets 20, first-run list 26); Continue card 128 tall (iPhone 72, Apple TV 220); the trouble pill 36 tall.
- Contrast pairs tested (Task 1): Secondary and Tertiary text, Accent text, Warning and Destructive, each on Background, on glass over Background and on thick glass over Background; Text on the tint for every hue bucket.

## What exists today

Client (`Client/Sources/`, logic in `PortalKit/Sources/PortalPlayer/ClientModel*.swift`):
- `NxPortalApp.swift`: `ClientModel.start()` begins browsing; `screen` starts at `.hosts` every launch. `RootView` switches on `.hosts / .pairing / .library / .playing`. The device name is `UIDevice.current.name`, which current iOS gives apps as the generic "iPad" or "iPhone".
- `HostsView.swift`: the Macs found on the network, "Looking for Macs running nxPortal…"; never says what the Host is. One tap runs `choose(host)`.
- `PairView.swift`: the code, a digit grid on tvOS. `LibraryView.swift`: a plain `List` of names, "Resume", "rebuild needed", a toolbar "Macs" button.
- `PlayView.swift`: picture on black; one tap shows the menu panel, a `Task.sleep` of 4 s hides it again. Menu rows: disconnect, quit, controller name, smooth picture, stats. The stats panel is seven text lines (`Strings.statsLines`).
- `SettingsView.swift`: sizes 720 / 1080 / 1440, frame rate, bitrate ceiling, sound, controls; all apply "the next time you connect".
- `Info-iOS.plist`: all four orientations and `UIRequiresFullScreen`.

Branches not yet on `main` that this design builds on:
- Wi-Fi transport: network 3, tap 2, "Reconnecting…" after 1 s of silence, sessions end after 10 s, `ClientSettings.picturePacing` default `smooth`.
  - Datagrams `nack` 0x26, `rate` 0x27, `ack` 0x28, `hostStats` 0x29, `repair` 0x2A; 0x2B is free.
  - Tap `prepare` (0x04): `phase u8, done u32, total u32`; phase 1 = pipelines, 2 = shader pairs, other values may come (shown generically). Sent when a phase starts, at most 4 a second, once with done == total at its end; a phase with nothing to do is one 0-of-0 message. No video or audio before the last `prepare`; the first video after it is a key frame. The Host decodes it into `GamePrepare` (`HostService.gamePrepare`) and logs it; it is not forwarded to the device.
- Host app (`Host/Sources/MenuView.swift`, strings in `Host/Sources/Strings.swift`): status line, "Pair a Device" (the code, grouped 3 + 3, with its time left, "Cancel"), "Devices" (name, "connected", "Remove", the question "Remove <name>? It will have to pair again."), "Games" (tags "playing", "paused", "starting…", "rebuild needed", "Quit Game", "Refresh"), "Name" ("Rename"), "Game Folders…", "Quit nxPortal Host". The menu-bar item is the system symbol `gamecontroller` (`Host/Sources/NxPortalHostApp.swift`).
  - `HostService.devices() -> [PairedDevice]` sorted by name, then key; `removeDevice(_:)`; `HostModel.devices` (`PortalKit/Sources/PortalHostModel/HostModel.swift`) holds them for the menu.
  - `PairingStore.add` removes a peer with the same key and appends the new one (a re-pair moves to the end of the file).
  - `GameLaunching.launch(titleID:socketPath:environment:)`; the Host app reads a Host-wide `environment.json` (one object of text values) into `HostConfig.gameEnvironment`; `HostService.reservedGameVariables` (`DM_STREAM`, `DM_LAUNCHER`) can never be replaced.
- Release prep: privacy manifest, tvOS asset catalogue `Client/Resources/Assets-tvOS.xcassets` with placeholder layered icon and Top Shelf images drawn by `scripts/make_placeholder_icons.swift`, `GCSupportedGameControllers` and `GCSupportsGameMode`, archive and export in `scripts/client.sh`, version 1.0.
- Recorder: `ClientSettings.recordSessions` ("Keep session numbers on this device", a small numbers file per session).

PortalKit:
- Control messages (`Wire/ControlMessage.swift`): JSON, sealed after `welcome`, framed up to 1 MiB. `pairStart` carries `clientKey`, `clientEphemeral`, `name: String`. `hello` carries version, key, ephemeral, `kind`, size, fps, `bitrate?`; no name. `list([GameEntry])`: titleID, name, streamable, state. `gameState(GameState)`: titleID, run, reason.
- `PairedPeer { key: Data, name: String }` is what both sides store (`PairingStore` on the Host, `ClientStore` on the device). The Host shows the name the device sent at pairing; it never changes afterwards.
- Datagrams (`Wire/Datagram.swift`) on `main`: 0x20 to 0x25 (video, audio, input, keyRequest, ping, pong). The rest come with the Wi-Fi branch (above).
- `GameLibrary.scan()` reads `Info.plist` only; no icon. `GameLaunching.launch(titleID:socketPath:)` sets `DM_STREAM` and `DM_LAUNCHER=0` (the Host app branch adds the `environment:` form, above). `RunningGame` has no process ID (`terminate`, `waitForExit` only).
- The tap `video` message carries the encoded width and height; the tap never scales up and fits into the `config` cap (`.claude/tap.md § size`).
- Input: `ControllerInput` feeds an `InputMixer` (`PadMapping.swift`) and calls `send`, which `PlayView` points at `ClientModel.send(_ input: InputState)`. No touch input.
- The Host ends a session by pausing the game.
- `ProtocolVersion` on `main`: network 2, tap 1 (the Wi-Fi branch: 3 and 2).

Game runtime (in the runtime's repository: `docs/frontends.md`, `settings.md`, `launcher.schema.json`):
- A Mac app carries `Contents/Resources/dm/launcher.json`: settings with `env`, `kind` (`choice`, `range`, `toggle`), `section`, `label`, `note`, `default`, optional `options`, `min / max / step`, `on / off`, `base`, `level`, `needs`. Schema 1 grows by optional fields only.
- Precedence at a start: launch environment, the player's `env.txt`, the bundle's `dm/env.txt`, saved choices (`launcher.<env>` in the bundle ID's domain), tested defaults.

## Approaches

### Library direction (b, look)
1. **A "Shelf".** One large focused game (250 pt icon, 52 pt name, Resume / Options) with the others in one row; the whole screen glows the focused game. Made for a controller; it feels like a console home. Costs: a 50-game library is a long sideways scroll; the spec's two sections become one row; on a 402 pt tall phone the row is icons only.
2. **B "Grid".** A calm grid of tiles on glass under a wide Continue card tinted by its game. Made for touch: everything visible, one tap away; holds a large library; the spec's Continue and All games sections map one to one; the same layout works with focus.
- Pick B (designer's and controller's recommendation; ASSUMED until the owner picks). On Apple TV the grid keeps a Shelf trait: the focused tile lights the room and its name shows large.

### Focus look
1. **Each platform's system focus** (tvOS card lift, iPadOS halo). Free, but three looks, and the iPad halo is faint on glass.
2. **One custom modifier everywhere.** One look a person learns once; testable; costs the tvOS parallax.
- Pick 2 (controller's call).

### Glow rendering
1. **Live blur of the icon layer.** Simple; a full-screen 120 pt blur every frame of a scroll costs battery on older iPhones.
2. **Pre-blurred small bitmap, scaled.** Once per icon; looks the same at this blur radius.
- Pick 2 (builder's call).

### Mac switching (a)
1. **A whole Macs screen as today, with a "remember" checkbox.** The owner asked against it.
2. **A sidebar on iPad, a sheet on iPhone, a tab on Apple TV, shared rows.** The library is always the home.
3. **A Mac switcher inside Settings.** Hidden; no.
- Pick 2 (controller's call).

### Artwork transport (b)
1. **Icons inside `list` as base64.** `list` is re-sent on every refresh; tens of MB for a large library; the 1 MiB frame limit breaks first.
2. **A reference in `list` (hash and size), then a request and chunked answer on the control connection.** Sent once per new icon.
3. **Pictures as UDP datagrams.** Own loss repair for a one-off transfer. No.
- Pick 2 (controller's call). Cache key: title ID plus content hash.

### Live settings (c)
1. **Every setting reconnects.** The owner called this the problem.
2. **A control message for what the Host can apply now (ceiling, panel level); the rest reconnects.**
3. **Everything live, including size.** Encoder rebuild and key frame; later.
- Pick 2 (controller's call).

### Performance data transport (e)
1. **Extend `hostStats`.** Grows every session's datagram whether or not anyone looks.
2. **A new datagram `load`, sent only while the panel is at "full".**
3. **A control message.** A stalled TCP delivers old numbers late.
- Pick 2 (controller's call).

### Per-game options (f)
1. **The Host writes the runtime's saved choices.** Overwrites the person's own choices; hard to undo.
2. **The Host keeps its own per-game choices and passes them as launch environment variables.** Temporary by the runtime's rule; "reset" deletes a key.
3. **Edit the runtime's `env.txt`.** No.
- Pick 2 (controller's call).

### Device names (j)
1. **The user-assigned device name ("Kitchen iPad").** Best for the person, but current iOS gives it to an app only with a managed entitlement that Apple grants on request for specific uses; the app would depend on that approval. Not now; an open door if the owner applies later.
2. **The model name by default, editable on the device, renamable on the Host.** No entitlement; "iPad mini" already tells an iPad mini from an iPad Pro; two of one model get a number until renamed.
3. **The Host asks for a name at pairing.** One more step at the Mac for every device; the device itself still says "iPad" in its own settings.
4. **A generated friendly name ("Blue Otter").** Tells devices apart but means nothing.
- Pick 2 (controller's call, from the owner's request).

## The design per item

### a) Start-up and Macs
- The app remembers the last Mac (a key, not secret) and, on launch, opens the library with that Mac's last known games, greyed, while it looks for the Mac and connects in the background.
- Not found or not answering after 5 s: the library stays, with the "Cannot reach <Mac>" banner and Retry (`§ screen-errors`). Retry restarts discovery and connects.
- No paired Mac (first run, or all forgotten): the first-run screen (`§ screen-first-run`). It is shown whenever no paired Mac exists, and never while one does.
- Pairing opens as a sheet over the library (or over first run); a wrong code leaves the sheet open.
- Rows: paired Macs (current marked, "Not found" when discovery does not list it, "Playing <game>" while one plays), Macs found but not paired ("Pair"), "Pair a Mac…" (opens a sheet: open nxPortal Host's menu on the Mac, choose "Pair a Device", then choose the Mac here and type the code). Choosing a Mac while a game plays asks first: the game pauses on the old Mac.
- Controller's call: "Forget this Mac" is not added; "Forget paired Macs" stays in Settings.

### b) Library
- Two sections: **Continue** (the running or paused game, else the last played on this Mac from this device; one card with Resume) and **All games** (by name). Look and layout: `§ screen-library`.
- A game without an icon: a Slate tile with the first letters of its first two words ("MM"). Not streamable: greyed (saturation 0, opacity .42), "Rebuild needed", not playable. Preparing: a ring over the icon and "Preparing 36 %".
- Long press, the ⋯ button, or the controller's Y on a tile: the game's page (Play, Options, Quit game when it is the running one).
- Artwork: the Host reads the icon named by `CFBundleIconFile`, makes a PNG of at most 512 pixels on a side and at most 512 KiB, hashes it (SHA-256, hex), and lists `art: {hash, bytes}` in `GameEntry`. The device asks for each icon it does not have, keeps it in its caches directory as `<titleID>-<hash>.png`, removes older files of the same title, and computes the `ArtPalette` once per file.
- Never stored in the repository; an icon exists only on the user's Mac and the user's own devices.

### c) The in-play menu
- Opens, on iPhone and iPad, by the gear at the top centre of the on-screen controller (item i); with touch controls a plain tap no longer opens it. The gear stays when a game controller hides the other controls. On Apple TV: the remote's Back (Menu) button.
- Closes by: its close button, a tap outside it, the controller's B, the gear again, and on Apple TV Back. No timer.
- While open, the controller does not reach the game (pads go neutral once) and the menu takes focus; closing restores input.
- Three groups, each saying when it applies: **Now** (changes at once), **Needs a new connection** (the game keeps going), **Next start of this game** (from the game's options). Look: `§ screen-play`.
- Live now: bitrate ceiling (`liveSettings`; the Host clamps as for `rate`), smooth picture, numbers panel level ("full" also tells the Host to sample), touch layout.
- New connection: stream size, frame rate limit. "Apply and reconnect" ends the session and reopens it to the same Mac and game; pending changes show a dot on the button.
- Next start: the game's options (item f), a few rows and "All game options" (the game's page).
- The touch layout row shows only on iPhone and iPad with no game controller; it persists per game (title ID) on the device.
- Numbers panel levels (controller's call on content):

```
Off:      (nothing)
FPS:      60 fps  1920 x 1080
Compact:  Mac 60 fps  Shown 60  Late 0/s  Smooth
          Delay 28 ms  Rate 50 / 50 Mbit/s
Full:     60 fps  1920 x 1080
          Mac      60 fps · gaps 0 · 1920 x 1080 · 48.6 Mbit/s
          Shown    60 fps · late 0/s · smooth
          Delay    28 ms · p95 34 ms
          Network  round trip 4 ms · gap p95 9 ms · max 21 ms · lost 0
          Rate     50 / 50 Mbit/s · cuts 0
          Decode   3.1 ms
          Sound    buffer 40 ms auto · underruns 0 · lost 0
          MAC      CPU 41 % [bar]  GPU 78 % [bar]
                   performance 55 % · efficiency 12 %
                   memory 17.9 / 32 GB · ok · heat fair
          GAME     CPU 160 % · memory 6.1 GB · 60.0 fps
                   frame 16.7 ms · p95 19 · max 41
```
- "Smooth" / "Immediate" is the picture pacing mode in use (item k). "GPU n/a" when the Mac does not give it. The level persists in `ClientSettings.statsLevel` (replaces `showStats`; saved `true` loads as Compact, `false` as Off; new default FPS).

### d) The size tells the truth
- The Host reports the game's size in `GameState.render` (width, height, `exact`). Below the cap the size is exact; at the cap a lower bound.
- The app keeps the last report per title ID. The size picker marks sizes above an exact value "Above what this game renders" and does not offer them; with a lower bound it offers sizes up to the next step above it.
- The menu, the game page and Settings state the effective size: "1920 x 1080, this game's own size".
- A larger picture needs the game's own render-scale option (item f), named beside the size when the game has one.

### e) The Mac's load
- The Host samples once a second, only while a session has the panel at "full": CPU total and per cluster, memory used and total, memory pressure, thermal state, GPU utilisation, the game process's CPU and memory, the game's frame rate and frame time (from the tap video frames' capture times).
- Public interfaces only (`host_processor_info`, `host_statistics64`, `sysctl` perflevel and memory-pressure keys, `ProcessInfo.thermalState`, `proc_pid_rusage`), each checked against the SDK headers before use.
- GPU utilisation: one function, `GPUUtilisation.read() -> Double?`, reads the accelerator's `PerformanceStatistics` from the I/O registry; nil shows "n/a"; deleting that file removes the feature.
- Not sent: temperatures, watts, frequencies, battery.

### f) Per-game options
- The Host reads the game's `launcher.json` on request, checks it against the schema's three kinds, adds the effective value and the app's choice, and sends it.
- The app renders it as the runtime does: sections in order, rows in order, `needs` sub-rows only while their parent has the value, `level: basic` rows first, the rest under "More".
  - choice: a picker of the option labels; range: a slider with the number shown (with `base`, the size too: "0.75 = 1200 x 675"); toggle: a switch.
  - An unknown `kind`: a read-only row with label and value, and "This app cannot change it". Never dropped.
  - "Changed" chip on the person's own choices; "Default" chip on a row at its tested default when the section has changed rows (builder's call).
  - "Reset to tested defaults" removes the app's choices for the game.
- Where: the game's page, and the "Next start" group of the in-play menu.
- The Host keeps the choices in `options.json` beside its pairing file, per title ID, only values that differ from the default, and starts the game with them as environment variables. A value is accepted only if the game's own list offers it.
- Combining with the Host-wide `environment.json` (controller's decision): the file's variables first, the person's per-game choices over them for the same variable; the reserved variables (`DM_STREAM`, `DM_LAUNCHER`) are set by the Host last and can never be set by either. The launch path exists on the Host app branch (`launch(titleID:socketPath:environment:)`); this work adds the per-game layer.
- Controller's call: the Host hides a short list of switches that do nothing when streaming (window, performance HUD, picture fit), by env name, in one Host file.

### g) Landscape only
- Landscape left and right only, on iPhone and iPad. `UIRequiresFullScreen` stays true: an iPad app that lists only landscape without it fails upload validation (store-testing audit, item 9). Task 2 does it.

### h) Preparing graphics
- The Host reports "preparing" in `gameState` from game launch until the first picture, and whenever the game is alive, not paused and has produced no picture for 2 s.
- The runtime's tap `prepare` message (phase number, done, total; already decoded by the Host on the Wi-Fi branch as `GamePrepare`) gives the progress; the Host passes the newest on, at most twice a second, phase as the number.
- Phases: the bar shows the current phase only and may restart once (phase 1 pipelines, then phase 2 shader pairs); the count shows that phase's own numbers; no phase text is shown, so an unknown phase number shows the same way. "Never backward" holds within a phase.
- The 2 s no-picture rule stays for games that send no `prepare`; a game that does sends no picture before its last `prepare`.
- No progress for 5 s, or total 0: "Waiting for the game" with a spinner and the elapsed time (the Host cannot tell a compile from a stall).
- The library tile shows "Preparing 36 %"; a device that connects meanwhile sees it at once.
- Leaving does not stop it: a session that ends while the game prepares does not pause the game; the pause is sent when the first picture comes after the session is gone (Open question 4).
- Look: `§ screen-starting`.

### i) On-screen controller
- The runtime's own touch controls (`dm/ios/Sources/DmGamepad.m`, layout constants `K_*`, MIT), ported: same controls, positions and sizes relative to the screen and safe area, 2D and 3D layouts. The owner: "no need to have a custom controller layout".
- Controller's calls:
  - Ported, not redesigned, including the colours (idle white .14, pressed .45, outline .38 at 1.5 pt, ring fill .06, label .6). The redesign changes nothing on the controls; the gear uses the same style. Builder's call: no blur under the controls (cost over video).
  - In 3D the right stick is not drawn: a touch in the right third on no control holds it.
  - The gear opens the in-play menu (item c). The 2D / 3D choice lives in the menu's "Now" group and persists per game; new games start in the layout set in Settings ("Layout for new games", default 2D).
  - A light haptic on a press (`ClientSettings.touchHaptics`, on by default).
  - A connected game controller hides every control but the gear; a glass note "Controller connected · touch controls hidden" shows for 3 s.
  - Touch becomes the same controller state a physical controller makes; one player; no wire change.
  - iPhone and iPad, landscape; not Apple TV.
- Left out: the "Tap" layout, portrait and half-folded layouts, the runtime's shake and gyro code, picture fit.

```
2D (landscape, 1 unit = 430 points of screen height, at most 1.3)
 (ZL)                    [ - ]  (gear)  [ + ]                    (ZR)
 (L)                                                              (R)

                                                                   (X)
                                                               (Y)     (A)
    .-----.                                                        (B)
   ( stick )  <- fixed ring, tilt from its centre
    '-----'

3D (everything in 2D, plus)
 (ZL) (L3)               [ - ]  (gear)  [ + ]               (R3) (ZR)
 (L)                                                              (R)
                                  +---------------------------+
                                  |  right third: no drawing; |
                                  |  a touch here is the      |
                                  |  camera stick (no button) |
        ^                         |                           |
      <   >   D-pad    ( stick )  +---------------------------+   diamond X Y A B
        v
```
- Teardrops (ZL, L, ZR, R) have their tip toward the near top corner; − and + are pills either side of the gear; the stick is a ring with a knob; the diamond keys are circles.
- Rules, from the runtime:
  - A touch is owned by the control it lands on; two fingers hold two controls; a second finger on a held key keeps it held until both lift.
  - The shoulders, − / +, L3 / R3 keep the key they landed on. A finger on the diamond switches keys as it slides; the D-pad changes direction as it slides.
  - Stick: dead zone 10 % of the ring radius, full tilt at 80 %, linear between.
  - Opening the menu, changing the layout or the screen's geometry, and a game controller appearing release every touch.
- Testable without a screen: hit testing, stick maths, the camera, ownership and sliding are a pure type in `PortalPlayer`.

### j) Device names
Owner's request: every device pairs as "iPad" or "iPhone"; owners with several devices of one model need to tell them apart.

What each platform gives without a special entitlement:
- iOS / iPadOS (current): `UIDevice.current.name` is the generic "iPhone" / "iPad"; the user-assigned name needs a managed entitlement (Approaches). `UIDevice.current.model` is the family only. The hardware identifier (`utsname.machine` from `uname`, for example "iPad14,1"; in the simulator the `SIMULATOR_MODEL_IDENTIFIER` environment value) is available without UIKit.
- tvOS: the identifier, as on iOS. Whether `UIDevice.current.name` returns the user's name on tvOS is UNVERIFIED; builder's call: use the model name there too, so the rule is one.
- So the default is the **model name** from a table in PortalKit mapping identifiers to Apple's short model names ("iPad mini", "iPad Pro 13-inch", "iPhone 16 Pro", "Apple TV 4K"), without the generation. An identifier not in the table: the family taken from the identifier's prefix ("iPad", "iPhone", "AppleTV" -> "Apple TV"). `DeviceModelName` needs no UIKit (identifier through `uname`, the table in PortalKit), so it is tested on the Mac.

Rules:
- The device's name = the person's own name from Settings ("This device's name", empty by default), else the model name.
- Clean-up, the same function on both sides (`DeviceName.clean`), in this order (controller's decision):
  1. Remove control characters and format characters, except U+200C and U+200D (they join emoji and some scripts); bidirectional controls are removed.
  2. Collapse every run of white space (newlines included) to one space.
  3. Trim white space at both ends.
  4. Cut to at most 40 characters (grapheme clusters) and 120 bytes of UTF-8 at a character boundary; a space the cut leaves at the end is trimmed.
  5. Empty = no name (the device falls back to the model name; the Host keeps the old one).
- `clean` is idempotent (`clean(clean(x)) == clean(x)`); the Host cleans again and stores its own result, so two systems that count a new emoji sequence differently cannot store an uncut name.

| Input | `clean` result |
|---|---|
| `"\u{0007} iPad   mini \n"` | `"iPad mini"` |
| `"Den\u{202E} iPad"` | `"Den iPad"` |
| 39 x `"a"` + `" b"` (41 characters) | 39 x `"a"` (the cut leaves a space, trimmed) |
| `" \n "` | nil |
- Sent at pairing in `pairStart.name` (exists today; the content changes, not the layout; it carries the setting as it is at pairing) and in every `hello` as a new optional `name` (so existing pairings get a name at their next connection, and a rename on the device reaches every Mac it connects to).
- The Host stores two names per device: the device's own (`name`, updated from each `hello`) and the Host's rename (`alias`, set only in the Host's menu). Shown name on the Host = `alias`, else `name`. The Host's name wins on the Host; the device never learns it.
- Equal names (controller's decision on order; builder's call on the rest): devices are ordered by the stored pairing date `added`; a device without `added` (an older store) comes first, in the store's order. The first keeps its name; each later one whose shown name is already taken gets " 2", then " 3" and so on until it is unique among the shown names, aliased or not ("iPad mini", "iPad mini 2"; a device really named "iPad mini 2" pushes the computed one to "iPad mini 3"). Comparison is exact string equality. Computed before the menu's sort by name, never stored, never sent.
- Pairing again with a key the Host has keeps that device's `added` and `alias` (`PairingStore.add` keeps them instead of appending a fresh peer), so a re-pair does not reorder the numbers.
- Where the shown name appears on the Host: the menu's status line ("Streaming to iPad mini 2"), the devices list, the remove question, and the `busy(device:)` refusal another device sees ("Den Mac is playing on iPad mini 2.").
- Renaming on the Host: in the devices list, "Rename…" opens an inline field (as the Mac's own rename does); empty after clean-up removes the alias. Allowed while the device is connected; nothing is sent.
- Existing pairings (a store written before this change): `alias`, `kind` and `added` absent, `name` "iPad"; they show "iPad", "iPad 2", "iPad 3" in store order until each reconnects; the next `hello` with a name replaces `name`, once that device has proved its key (its first sealed frame opened; the unsealed `hello` alone changes nothing). An older device that sends no name in `hello` keeps its stored name. `kind` is unknown until the next `hello` (the menu shows the phone glyph meanwhile).
- After "Forget paired Macs" or a reinstall the device has a new key, so the Host lists the old row too ("iPad mini" and "iPad mini 2") until the Host's owner removes it (Open question 10).
- Logs never carry a device name: the Host logs a device as the first 8 hex characters of its key's hash (as today for keys).
- Client Settings row: "This device's name", placeholder = the model name, footnote "Macs on your network show this name. A Mac that renamed this device keeps its own name."; applies at the next connection or pairing.
- The name travels unsealed: `pairStart` and `hello` go before the session is sealed, and `refuse(.busy(device:))` carries another device's shown name to the device that asked (`§ Privacy`).

Wire: `hello.name` is a new optional key: a layout change, so it is part of this plan's one network version bump (`§ Wire changes`). `PairedPeer` gains optional `alias: String?`, `kind: DeviceKind?` (from `hello`, for the device icon in the menu) and `added: Date?` (pairing order); these are stored files, not wire formats, decoded leniently (absent = nil; for order, file order).

### k) Small items from testing
- **Pacing mode on the panel.** The Compact and Full levels show the picture pacing in use ("smooth" / "immediate") on the "Shown" line, so a field report says which mode it was taken with.
- **Keep session numbers on this device.** The recorder branch's switch (a small numbers file per session, on by default there) sits in Settings › Numbers, under the panel level, with its note "A small text file per session; it stays on this device." If the recorder branch is not merged when Task 4 runs, the row is added when it merges.
- **Game Mode and controller declarations.** Done on the release-prep branch (`GCSupportedGameControllers` extended gamepad on both apps, `GCSupportsGameMode` on iOS); this design does not change them.
- **Version.** Settings › About shows "Version 1.0 (<build>)" from the bundle; only the build number changes until the store release.

### l) App icon (concept 1 "Doorway", ASSUMED)
- The idea: an arch of light opening in a coloured pane; the Mac's screen becomes a door the game comes through. Reads at 16 pt as a bright arch. No controller or console shapes.
- Recipe (256 units, from the mockup): field `linear 135°: #6E8BFF, #7B4DFF at 55 %, #1A1240`; arch shadow (outer arch 100 wide, 50 radius top, bottom at 214) `#0E0B2A` at 55 %; lit arch (76 wide, 38 radius top) `linear 180°: #FFFFFF to #BFD0FF`; floor glow (ellipse 172 x 36 at the arch's foot) `radial #9DB4FF .9 to clear`; light spill (a trapezoid from the arch foot to the bottom edge) `#DDE5FF` at 28 %.
- iOS: one 1024 x 1024 PNG, opaque, square corners (the system masks), sRGB. Builder's call: dark and tinted variants (iOS 18) are optional for 1.0; if made, dark = the field darkened to `#1A1240 → #0E0B2A`, tinted = the arch in greys on black.
- tvOS layered icon, three layers (back opaque):
  - Back: the field gradient, full bleed.
  - Middle: the arch shadow, floor glow and spill.
  - Front: the lit arch.
  - The lit arch (Front) within the centre 60 % of the width; the Middle layer's shadow, glow and spill within the centre 80 % (the focus parallax crops edges).
  - Sizes: App Icon 400 x 240 (@1x) and 800 x 480 (@2x); App Store icon 1280 x 768; each with the same three layers.
- Top Shelf (static, in the app): Top Shelf Image 1920 x 720 / 3840 x 1440 and Wide 2320 x 720 / 4640 x 1440. A dark field (`#08090D` to `#1A1240`, left to right), the lit arch small at the centre with its floor glow spreading wide; no text (the system shows the app's name), no game art.
- Mac Host: the same icon at the macOS sizes (16 to 1024). The menu-bar item stays the system symbol it has today (`gamecontroller`; controller's decision; the "no controller shapes" rule is for the app icon).
- Builder's call: the art is drawn by a script (CoreGraphics), replacing `scripts/make_placeholder_icons.swift`'s placeholder, so every size is generated from one recipe and no design file is needed.

## Screens

Sketches show the dark look at the default text size. Focus marks (`[[ ]]` = focused button or tile, `>> <<` = focused row) show the default focus. Device sizes in points: iPhone 874 x 402 (landscape), iPad 1180 x 820, Apple TV 1920 x 1080.

#### screen-first-run

What a person (and a store reviewer) sees with no paired Mac. It explains the app, the one requirement, and offers a way forward.

```
iPhone
+--------------------------------------------------------------------+
|                 Play the games on your Mac                         |
|   .------.      nxPortal shows your Mac's games here and streams   |
|   | /^^\ |      them over your home network.                       |
|   | |  | |      (1) Open nxPortal Host on your Mac                 |
|   '------'      (2) Choose the Mac when it shows up below          |
|  app mark       (3) Type the code from the Mac's menu              |
|  180 pt         (spinner) Looking for Macs on this network…        |
|                 [[ How to set up a Mac ]]                          |
+--------------------------------------------------------------------+
  A Mac found: the "Looking" line becomes rows (Mac icon, name, "Ready to pair", >)
  and the first row takes focus; the column scrolls.

iPad                                        Apple TV
+----------------------------------------+  +---------------------------------------------+
|            (app mark 88 pt)            |  |  (mark 300)   Play the games on your Mac      |
|          Choose your Mac               |  |               (same text and steps)           |
| These Macs on your network have        |  |               >> Den Mac      Ready to pair << |
| nxPortal Host open.                    |  |                  Studio Mac   Ready to pair    |
| +------------------------------------+ |  |                  (spinner) Still looking…      |
| |>> [mac] Den Mac  Ready to pair   > <<| |  |               [ How to set up a Mac ]         |
| |   [mac] Studio Mac Ready to pair > | |  +---------------------------------------------+
| |   (spinner) Still looking…         | |
| +------------------------------------+ |
| Don't see your Mac? Check that it is   |
| on the same Wi-Fi network and that     |
| nxPortal Host is open on it.           |
+----------------------------------------+
  Before any Mac is found the iPad shows the iPhone's text and steps above the list.
```
- Background: the radial accent glow; the app mark is the only artwork.
- "How to set up a Mac" opens a sheet (builder's text, in `Strings`): what is needed (an Apple silicon Mac with macOS 14 or later, nxPortal Host open on it, a game on that Mac that supports streaming, both on the same network); the steps, naming the Host's own menu items ("Pair a Device" shows the code); "Still nothing?" (Local Network allowed for nxPortal, same Wi-Fi, the Mac awake). No web link in 1.0 (Open question 3).
- iPad (builder's call): "How to set up a Mac" is a text link under the footer. Before any Mac is found the iPad shows the iPhone's headline, text and steps above the list; when the first Mac appears they collapse to "Choose your Mac" and its one line, as sketched.
- Local Network refused: the "Looking" line becomes "nxPortal can't look for Macs. Allow Local Network for nxPortal in Settings." with [[ Open Settings ]] (`UIApplication.openSettingsURLString`).
- After 30 s with nothing found: "Still looking. Is nxPortal Host open on your Mac?" under the spinner (builder's call).

#### screen-pairing

A sheet over first run or the library. Typed with the on-screen keypad (so a controller or the remote can type); a hardware keyboard's digits also work.

```
iPad (sheet 540 wide, centred)              iPhone (sheet from the bottom, two columns)
+----------------------------------+       +-----------------------------------------------+
|        Pair with Den Mac     (x) |       | Pair with Den Mac                         (x) |
| Type the six-digit code shown in |       | Type the six-digit code shown in  [1][2][3]   |
| the nxPortal menu on Den Mac.    |       | the nxPortal menu on Den Mac.     [4][5][6]   |
|  [4][8][2]  [9][|][ ]            |       | [4][8][2] [9][1][7]  (red)        [7][8][9]   |
| The code works for two minutes.  |       | ! That code didn't match.         [ ][0][<x]  |
| You only pair once.              |       | Check the code on Den Mac and type it again.  |
|     [[1]] [2] [3]                |       | A new code appears if the old one ran out.    |
|      [4]  [5] [6]                |       +-----------------------------------------------+
|      [7]  [8] [9]                |
|           [0] [<x]               |
+----------------------------------+
```
- Six boxes in two groups of three; the current box has an accent caret. Sending happens on the sixth digit.
- Wrong code: boxes and text in Destructive; with `triesLeft` ≤ 2 add "2 tries left". Locked: "Too many wrong codes. Show a new code on Den Mac and try again." Expired: "The code ran out. Show a new code on Den Mac."
- Apple TV: the same sheet at 10-foot size; key 1 has focus.

#### screen-macs

```
iPad sidebar (glass column, 300 wide)        iPhone sheet (from the "Den Mac v" button)
+-----------------------------+              +--------------------------------------------+
| (mark) nxPortal      (gear) |              | Macs                                  Done |
| Your Macs                   |              | Your Macs                                  |
|  [mac] Den Mac           ✓  |              |  [mac] Den Mac       ● Connected       ✓   |
|        ● Connected          |              |  [mac] Studio Mac      Not found           |
|  [mac] Studio Mac           |              | Nearby                                     |
|        Not found            |              |>> [mac] Guest Mac                 Pair   <<|
| Nearby                      |              |  (+) Pair a Mac…                           |
|  [mac] Guest Mac      Pair  |              +--------------------------------------------+
| (+) Pair a Mac…             |
| A Mac shows up here when    |
| nxPortal Host is open on it.|
+-----------------------------+
```
- The current Mac's row has the selected fill (Fill 2) and a check; status dot Positive ("Connected"), Warning ("Not answering"), none ("Not found", Tertiary).
- Switching while a game plays: an alert "Switch to Studio Mac?" / "Lantern is playing on Den Mac. It pauses there and waits for you." [Cancel] [[Switch]].
- Apple TV: the "Macs" tab shows the same rows as a centred list (1000 wide).

#### screen-library

ASSUMED: B "Grid". This section is the only one that changes if A is picked.

```
iPad
+-------------------+------------------------------------------------------------+
| (mark) nxPortal ⚙ |  Den Mac                                       [ Refresh ] |
| (sidebar, above)  |  10 games                                                  |
|                   | +--------------------------------------------------------+ |
|                   | | [icon 96] Continue                   [[▶ Resume]] [⋯]   | |
|                   | |           Skyline Drift                                | |
|                   | |           Paused 12 min ago    (tinted by its icon)    | |
|                   | +--------------------------------------------------------+ |
|                   |  All games                                                 |
|                   |  [ic] [ic] [MM] [ic] [ic◔] [ic]      108 pt icons          |
|                   |  name name name name name  name      ◔ = preparing ring    |
|                   |  [ic] [ic~] [ic] [ic]                ~ = greyed            |
|                   |  name Rebuild needed ...                                   |
+-------------------+------------------------------------------------------------+

iPhone
+----------------------------------------------------------------------+
| [ (mac) Den Mac v ]               Games                        (⚙)   |
| +------------------------------------------------------------------+ |
| | [ic 52] Continue · Skyline Drift · Paused 12 min ago [[▶ Resume]] | |
| +------------------------------------------------------------------+ |
| All games                                                            |
| [ic][ic][ic][ic][ic][ic][ic][ic]   68 pt, adaptive; scrolls under   |
| name ...                           the top bar                       |
+----------------------------------------------------------------------+

Apple TV
+--------------------------------------------------------------------------------+
| (mac) Den Mac              (  Games  |  Macs  |  Settings  )                     |
| +---------------------------------------------------+    Focused               |
| | [icon 160] Continue                 [▶ Resume]    |    Tidepool (Large Title) |
| |            Skyline Drift (Title 2)                |    Last played 3 days ago |
| |            Paused 12 min ago                      |    · press and hold for   |
| +---------------------------------------------------+      options             |
| All games                                                                      |
| [[tile 230]]  [tile]  [tile]  [tile◔]  [tile~]  [MM]                           |
|  Tidepool     name    name    Preparing 36 %  Rebuild needed                   |
+--------------------------------------------------------------------------------+
  The focused tile's icon lights the room (ambient, 450 ms cross-fade on focus change).
```
- The Continue card: glass with the Vivid tint; icon, "Continue" (footnote, semibold), the name (Title 2; iPhone Headline), the state ("Paused 12 min ago", "Playing", "Last played yesterday"), Resume (primary capsule; "Play" when nothing runs), ⋯ (the menu of `§ screen-details`). No Continue game: no card.
- Empty library (Mac reached, no games): "No games on Den Mac yet. Games that support streaming show up here when they are in the Mac's game folders." (builder's text).
- Refresh (iPad; pull to refresh on iPhone) asks the Host for the list again.
- Mac unreachable: `§ screen-errors`.

If A "Shelf" is picked instead:
- iPad: the focused game is a hero (icon 250, name 52 pt heavy, state, Resume / Options / ⋯) and the others are one horizontal row of 150 pt tiles below; controller hints at the bottom ("A Resume · Y Options · B Macs").
- iPhone: hero icon 150 and name 34 pt; the row is icons only (64 pt); the preparing state is a line at the bottom right ("Orbit 9 · preparing 36 %").
- The ambient layer follows the focused game on every platform (opacity .75 to .80, blur 80 to 110), not the Continue game.
- Changes: this section, `LibraryGrid` becomes `LibraryShelf` in Task 3, the ambient table row. Tiles, states, the Continue data, art and everything else stay.

#### screen-game-page

```
iPad
+------------------------------------------------------------------------------------+
| [< Games]                        |  Options               Tested defaults from the game |
|                                  |  Game                                              |
|   [ icon 196 ]                   |   Frame rate                  [Default]  60 fps ⇕  |
|   (glow of its icon, left)       |  >> Render scale   0.75 = 1200 x 675             << |
|   Lantern                        |  >>  0.5 ---------o------------------------ 1.0  << |
|   On Den Mac · last played       |   Upscaling                            Standard ⇕  |
|   yesterday                      |   Language                 [Changed] English (US) ⇕|
|   [[ ▶ Play ]]  [⋯]              |  Performance                                       |
|   Picture 1920 x 1080, this      |   Frame buffering                          (on)    |
|   game's own size. A larger      |    Smoother motion, a little more delay            |
|   picture needs a higher render  |   Hold frames                  [Changed]   (off)   |
|   scale.                         |   Shadow detail   This app cannot change it   High |
|                                  |   More                          6 more options  >  |
|                                  |  [↺ Reset to tested defaults]  Changes apply at   |
|                                  |                               the next start.     |
+------------------------------------------------------------------------------------+
```
- iPhone: the same two columns, icon 96, the left column fixed, the right scrolls. Apple TV: icon 300 in the left column; rows at 84 pt; Play has default focus.
- Opened by long press, ⋯, or Y on a tile. The ⋯ menu holds "Quit game" when the game runs.
- Without a `launcher.json`: "This game has no options to set here."

#### screen-starting

```
Preparing (iPhone)                                  Waiting (no progress for 5 s)
+--------------------------------------------------+ +-------------------------------------------+
| [ic] Lantern on Den Mac                          | | [ic] Lantern on Den Mac                   |
|                 [ icon 84, glow ]                | |               (spinner 44)                |
|        Preparing graphics for this Mac           | |           Waiting for the game            |
|  The first start on a Mac takes a few minutes.   | |                  0:42                     |
|            Later starts are quick.               | |  Lantern is starting on Den Mac. Nothing  |
|  [##########-------------------------]           | |  has come back from it yet; this can take |
|  12,400 of 34,649              3 min 12 s so far | |  a minute.                                |
|              [[ Back to games ]]                 | |  [[ Back to games ]]  [ Quit game ]       |
|          You can leave: this goes on.            | +-------------------------------------------+
+--------------------------------------------------+
```
- The bar is the game's Vivid gradient; the count updates at most twice a second; the phase text from the runtime is not shown (builder's call: it is jargon); the elapsed time counts from `preparingSince`.
- iPad and Apple TV: the same centred column (480 wide; TV 900), larger type.
- Back to games keeps the game preparing (item h); its tile shows the ring.

#### screen-play

```
Touch, 2D (iPhone)                              Game controller connected
+----------------------------------------------+ +----------------------------------------------+
|(ZL)          [-] (gear) [+]            (ZR)  | | [pad] Controller connected · touch controls  |
|(L)                                      (R)  | |       hidden            (gear)   (fades, 3 s)|
|                 (the picture,                | |                                              |
|                  full screen)          (X)   | |              (the picture)                   |
|                                     (Y)   (A)| |                                              |
|   ( stick )                            (B)   | |                                              |
+----------------------------------------------+ +----------------------------------------------+
```
- The picture fills the screen (aspect fit on black); status bar and home indicator hidden.
- Numbers panel: top left on a dark glass chip (`rgba(10,12,18,.55 to .66)`, radius 15 / 14 / 16 by level), caption monospaced digits, never over the gear; Full is 336 pt wide with small bars for CPU and GPU (Positive, Warning).

In-play menu (iPad; opened by the gear, which shows lit while it is open):
```
+--------------------------------------------------------------------------------+
| [ic] Lantern                                                              (x) |
|      On Den Mac · 1920 x 1080 · 60 fps                                         |
| NOW  Changes at once                    | NEXT START OF THIS GAME  From the     |
|  Bitrate ceiling           50 Mbit/s ⇕  |                     game's options    |
|>> Smooth picture               (on)  << |  Render scale       0.75 = 1200 x 675 |
|    Even frame pacing                    |  Frame rate                    60 fps |
|  Numbers     ( Off |[FPS]| Compact | Full )  Language              English (US) |
|  Touch layout       ( [2D] | 3D )      |  All game options                   > |
|    For this game                        | These apply the next time Lantern     |
| NEEDS A NEW CONNECTION  The game keeps  | starts.                               |
|                                going   | [ Disconnect ]   [ Quit game ]         |
|  Stream size          1920 x 1080 ⇕    | Disconnect pauses the game on the     |
|    The game's own size                  | Mac. Quit ends it.                    |
|  Frame rate                  60 fps ⇕   |                                       |
|  [ Apply and reconnect • ]              |                                       |
|  Close with (x) · a tap outside · B on a controller · the gear again           |
+--------------------------------------------------------------------------------+
```
- Thick glass, radius 38, inset 90 left and right, the picture behind dimmed (`black .42`).
- iPhone: the same panel, insets 62 / 16, two columns, each scrolls. The left column is two pages under a segmented control, "Now" / "Connection" ("New connection" where there are two; with the game's options a third page, "Next start") (the group titles do not fit a short landscape screen side by side, and both stay in view); its bottom edge fades so a cut row reads as "more below". At accessibility text sizes the phone menu is one column that scrolls as a whole, the page control at its top.
- "Quit game" is drawn as text on the Fill token (Disconnect on Fill 2) with a ring in the Destructive colour: it is told apart by ring, fill step and word, not by text colour alone; the ring is a control edge, tested at 3:1 on the menu card.
- Apple TV: a trailing panel (760 wide, inset 60, radius 48) sliding in from the right; the three groups as rows; no touch layout row; "Back closes the menu" bottom left.

#### screen-errors

```
Mac unreachable (library, iPhone)
+----------------------------------------------------------------------+
| [ (mac) Den Mac v ]               Games                        (⚙)   |
| +------------------------------------------------------------------+ |
| | ! Cannot reach Den Mac. Showing the last known games. Check that | |
| |   the Mac is awake and on this network.            [[↺ Retry]]   | |
| +------------------------------------------------------------------+ |
|  (Continue card and tiles greyed, not playable)                       |
+----------------------------------------------------------------------+
```
- Banner: thick glass with a Warning tint from the left (`linear 90°: Warning .22 to glass at 40 %`), radius 18; on iPad above the grid; on Apple TV under the tab bar. Retry has focus.

Connection trouble while playing (timing from the Wi-Fi transport design: input neutral after 1 s of silence, session ends at 10 s):
```
1 s: frozen picture, a pill     3 s: blurred picture             10 s: the session ended
 ( wifi Reconnecting… )          (spinner)                        +--------------------------+
                                 Reconnecting to Den Mac          | [ic 56]                  |
                                 Lantern is paused until you're   | The session ended        |
                                 back. Try moving closer to the   | Den Mac stopped          |
                                 Wi-Fi router.                    | answering. Lantern is    |
                                 [[ Stop and go to games ]]       | paused there and waits.  |
                                                                  | [Back to games]          |
                                                                  | [[↺ Reconnect]]          |
                                                                  +--------------------------+
```
- The pill: thick glass, 36 tall, Warning Wi-Fi glyph, centred 66 pt from the top. At 3 s the picture blurs 14 pt at brightness .55. At the end: blur 18, brightness .40, a glass card.
- Other errors, one sentence and one next step each (on the library's banner with Retry, or the pairing sheet: they arise while connecting, where there is no play screen, so they are not in the ended card): version mismatch ("Den Mac has a different version of nxPortal Host (protocol 4, this app 5). Update the older one."), busy ("Den Mac is playing on iPad mini 2."), not paired anymore ("Den Mac no longer knows this device. Pair again." [Pair]).

#### screen-settings

```
iPad (two columns of grouped glass)
+--------------------------------------------------------------------------------+
| Settings                                                              [ Done ] |
| Picture                                 | Controls                              |
|  Largest stream size     1920 x 1080 ⇕ |  Button layout              Automatic ⇕|
|    Never above what a game renders     |  Motion                   This device ⇕|
|  Frame rate limit            60 fps ⇕  |  Haptics on touch controls       (on)  |
|>> Bitrate ceiling        50 Mbit/s ⇕ <<|  Layout for new games     ([2D] | 3D)   |
|    The stream adapts below this         | This device                           |
|  Smooth picture                  (on)  |  This device's name   [ iPad mini   ]   |
| Size and frame rate apply the next     | Macs show this name. A Mac that       |
| time you connect.                      | renamed this device keeps its own.    |
| Numbers                                | Macs                                  |
|  ( Off | [FPS] | Compact | Full )      |  Forget paired Macs     (Destructive) |
|  Keep session numbers on this device (on)| You will have to pair with each Mac  |
|    A small text file per session; it    | again.                                |
|    stays on this device.                | About                                 |
| Sound                                  |  Acknowledgements                   >  |
|  Play sound                      (on)  |  Version                   1.0 (42)    |
|  Sound buffer             Automatic ⇕  |                                       |
+--------------------------------------------------------------------------------+
```
- Opened from the gear in the sidebar (iPad), the top bar (iPhone) or the Settings tab (Apple TV).
- iPhone: one column, 560 wide, centred, scrolls. Apple TV: one column, 1000 wide, no Haptics or touch layout rows; the name field uses the system's text entry.
- Each group's footer says when its changes apply. Device-wide choices only; per-game options live on the game's page.

#### screen-details

Builder's calls (from the builder check):
- Game page, iPhone: left column 300 pt fixed (icon 96, name, Play, ⋯), right column scrolls. Apple TV: left 560, right the rest.
- In-play menu, iPhone: Now and Needs a new connection in the left column, Next start and Disconnect / Quit in the right; each scrolls.
- "⋯" means one thing everywhere: a menu with "Options" (the game page; absent on the page itself) and, when the game runs, "Quit game".
- Pairing sheet, iPhone: the sketched layout; the 44 x 54 code boxes sit left of the keypad; the wrong-code text wraps under them.
- The Macs sheet on iPhone, with no Mac nearby, ends with the sidebar's line "A Mac shows up here when nxPortal Host is open on it."
- Settings rows that later tasks own appear when their task lands; Task 4 builds the groups.

#### screen-host-menu

The Mac menu-bar menu (Host), native menu material and 13 pt type. Today's strings stay ("Pair a Device", "Devices", "Games", "Quit Game", "Refresh", "Name", "Game Folders…", "Quit nxPortal Host"); the menu changes only where a task says so:
- Task 13: device rows with the shown name (j), kind glyph, "Rename" inline.
- Task 14 (Open question 9, default in): the two-line status, game rows with the Host's own 20 pt icon and the tag "preparing 36 %", the code card's time bar.
- The menu-bar symbol stays `gamecontroller`.

```
+--------------------------------------------------+
| ● Playing Lantern on iPad mini 2                 |   (today's status line)
|   Den Mac · 60 fps · 48 Mbit/s       (Task 14)   |
|--------------------------------------------------|
| Pair a Device                                    |
|  Pairing code                                    |
|   482 913          (today's code, 3 + 3)         |
|   1:48                               [Cancel]    |
|   [=========-------]  time bar       (Task 14)   |
|--------------------------------------------------|
| Devices                                          |
|  [phone]  iPhone 16 Pro            connected     |   (Task 13)
|  [tablet] iPad mini                              |
|  [tablet] iPad mini 2         [Rename] [Remove]  |
|  [tv]     Apple TV 4K                            |
|--------------------------------------------------|
| Games                                [Refresh]   |
|  [ic] Lantern                     playing        |   (icons: Task 14)
|  [ic] Orbit 9                     preparing 36 % |   (Task 14)
|  [ic] Skyline Drift               paused         |
|  [ic] Old Cartography             rebuild needed |
|  [Quit Game]                                     |
|--------------------------------------------------|
| Name: Den Mac                        [Rename]    |
| Game Folders…                                    |
| Quit nxPortal Host                               |
+--------------------------------------------------+
```
- Device rows: kind glyph from the stored `kind` (unknown = phone), the shown name, "connected"; "Rename" edits inline (Return saves, Escape cancels; empty removes the alias); "Remove" asks as today.
- Group order is today's; only the marked parts are new.

## Wire changes

Network protocol: **one bump for this whole plan**, from the version `main` has when the first wire task starts (3, once the Wi-Fi branch is merged) to the next (4 expected), by that task, with a `CHANGELOG-protocol.md` entry; later tasks add to it before it ships. A peer with another version is refused as today. Tap: the runtime's `prepare` message belongs to the runtime task; `ProtocolVersion.tap` follows the runtime's value.

| Message | Direction | Fields | Size | When |
|---|---|---|---|---|
| `Hello.name` (new optional key) | device to Host | `name: String?` (cleaned, at most 120 bytes) | under 140 bytes | every `hello` |
| `liveSettings` (control, new) | device to Host | `ceilingBps: UInt32?`, `panel: PanelLevel?` (`off / fps / compact / full`) | under 100 bytes | menu change; once after `ready` |
| `GameEntry.art` (new optional key) | Host to device | `art: {hash: String (64 hex), bytes: UInt32}` | 90 bytes per game with art | in every `list` |
| `artRequest` (control, new) | device to Host | `titleID`, `hash` | under 100 bytes | art not in the device cache |
| `art` (control, new) | Host to device | `titleID`, `hash`, `index: UInt16`, `count: UInt16`, `bytes: Data` (at most 48 KiB per chunk); `count` 0 = no such art | about 66 KiB as sealed JSON | answer, chunks in order |
| `GameState.render` (new optional key) | Host to device | `{width, height: UInt16, exact: Bool}` | 40 bytes | first picture; on a size change |
| `GameState.preparing` (new optional key) | Host to device | `{phase: UInt8, done: UInt32, total: UInt32}` (the tap's numbers), absent when not preparing | under 80 bytes | on change, at most 2 a second |
| `Hello.resume` (new optional key) | device to Host | `resume: Bool?`; `false` = a library session (admission never resumes the game, no media until it plays), absent = resuming as before | under 20 bytes | every `hello`: `false` at launch, on choosing a Mac, after pairing and after leaving play; absent when play is picked up again (reconnect, return from the background, Apply and reconnect) |
| `optionsRequest` (control, new) | device to Host | `titleID` | under 80 bytes | game page or menu opens |
| `options` (control, new) | Host to device | `titleID`, `settings: [OptionSetting]`, `rejected: String?` | 10 to 20 KB | answer; after every change |
| `setOption` (control, new) | device to Host | `titleID`, `env`, `value: String?` (nil removes the choice) | under 150 bytes | a row changes |
| `resetOptions` (control, new) | device to Host | `titleID` | under 80 bytes | "Reset to tested defaults" |
| `load` (datagram, new) | Host to device | below | 35 bytes | once a second while the panel is "full" |

- `pairStart.name` keeps its layout; its content becomes the cleaned device name (j).
- `load`'s datagram code: the next free code on `main` when Task 9 starts (0x2A is the Wi-Fi branch's `repair`; 0x2B is free there).
- `OptionSetting`: `env, kind: String, section, label, note, defaultValue, current: String`, `chosen: Bool`, optional `options: [[String]]`, `min, max, step: Double`, `on, off: String`, `base`, `level`, `needs`. `kind` is a String so an unknown one still decodes.
- `load` body, little-endian, in order: `flags u8` (bit 0 = GPU value present, bit 1 = game process alive), `thermal u8` (0 nominal ... 3 critical), `pressure u8` (0 normal, 1 warning, 2 critical), `cpuTotal u16`, `cpuPerf u16`, `cpuEff u16`, `gpu u16` (tenths of a percent, 0xFFFF = n/a), `memUsedMiB u32`, `memTotalMiB u32`, `gameCpuCentiCores u32`, `gameMemMiB u32`, `gameFpsDeci u16`, `frameMeanDeciMs u16`, `frameP95DeciMs u16`, `frameMaxDeciMs u16`. 35 bytes. Sent on a single newest-only slot of the Host's sender that leaves only when no urgent, resend or video datagram waits; at most one a second; never retransmitted (a lost one is replaced by the next). It never goes ahead of the picture or the sound.
- Host rules: `liveSettings` clamped like `rate`; an unknown art hash gets `count` 0; `setOption` validated against the game's list; a `hello.name` is cleaned and an empty one ignored; none of these touches a running game's process.

## Privacy and public-repo notes

- Game artwork and names come from the user's Mac at run time and live only there and on the user's own devices (caches directory; never in logs, the repository or fixtures: tests use generated images).
- Device names are stored in the Host's pairing file and the device's settings; never in logs (a key hash stands in), the repository or test fixtures (tests use "Test iPad", "iPad mini").
- On the wire the name is readable: `pairStart` and `hello` travel before the session is sealed, and `refuse(.busy(device:))` (also unsealed) shows another device's name to the device that asked. Default (Open question 8): accepted; it is the model name unless the person typed one, and it stays on the person's own network. The alternative: send only the model name in `pairStart` and `hello` and the typed name in a new sealed message after `ready`; it costs a message, a name that arrives after admission (the Host shows the model name until then), and a busy refusal that names the model only.
- The model-name table holds Apple's public model identifiers and names only.
- Per-game choices: the Host's application-support folder.
- Load numbers carry no process names, paths or addresses.
- Tests use the fake game (`FAKE000000000000`) and generated `launcher.json` files.
- The on-screen controller is ported from the game runtime (MIT): the ported files keep its notice; Settings › Acknowledgements and `README.md` repeat it.
- Mockup games, Macs and devices in this document are invented placeholders. Docs and strings name no other product, company or game.

## Left to the builder

- Exact strings beyond those quoted here (all in `Strings.swift`, sentence case, plain words).
- Animation curves within the motion table's durations; the press-scale value.
- SF Symbols for each glyph (gear, Mac, phone, tablet, TV, folder, retry, warning, Wi-Fi, controller) where the system has one; the portal mark is drawn.
- The order of rows inside a Settings group; where a picker opens as a menu or a pushed list (iPhone: menu; Apple TV: pushed list).
- Whether a controller drives focus on iPhone and iPad (check on a device, record it).
- The full model-name table (the current identifiers for iPhone, iPad, Apple TV), kept in one file.
- Tile name truncation and the initials rule for one-word names (first two letters).

## Open questions for the owner

Each has the default the plan uses if unanswered.
1. **Library: A "Shelf" or B "Grid"?** Default B.
2. **App icon: concept 1, 2 or 3?** Default 1 "Doorway".
3. **A web page for the Host?** The first-run sheet and the store notes could link to a download page; nothing is published until you say. Default: no link in 1.0, the sheet explains in the app.
4. **Does pausing a game stop its graphics preparation?** Default: the Host never pauses while preparing; checked once on the second Mac.
5. **The game's own size at a low cap.** Default: exact below the cap, a lower bound at it; the game's size added to the tap's `video` message in the next tap change.
6. **Options hidden when streaming.** Default: a short Host-side list (window, performance HUD, picture fit), checked against a real `launcher.json`.
7. **Does the controller's Home button open the menu?** Default: yes when the controller has one (Task 4); the gear always.
8. **A typed device name travels unsealed** (`§ Privacy`). Default: accepted on the person's own network; the alternative is a sealed name message after `ready`.
9. **The Host menu's restyle** (two-line status, game icons, preparing tag, time bar) **in this plan?** Default: yes, Task 14; device names and rename are in Task 13 either way.
10. **Old rows after a device's reinstall** (a new key leaves "iPad mini" next to "iPad mini 2"). Default: leave it in 1.0; the Host's owner removes the old row.
11. **Apply for the user-assigned device-name entitlement** (most useful for Apple TVs, which share one model name)? Default: no application in 1.0; whether it applies on tvOS is UNVERIFIED.
12. **Numbers panel default.** Default: new installs at FPS, a saved "on" becomes Compact, "off" stays Off; Full never the default.
