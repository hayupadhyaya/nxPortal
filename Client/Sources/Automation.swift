#if DEBUG
import Foundation
import os
import PortalClientCore
import PortalKit
import PortalPlayer

/// Debug-only scripted run for the simulator and the device console; uses only the model's public interface.
/// Arguments: -autoHost <name> -autoCode <code> -autoLaunch <titleID> -autoSeconds <n> -autoPress <button>@<s>
/// -autoPacing smooth|immediate, -autoBitrate <Mbit/s> (this run only, not saved)
/// (`-autoSeconds` and `-autoPress` count from the first picture displayed)
/// Prints `stalled t=<s> on|off` at every change of `stalled` (`t` counts from the first picture).
/// -autoStayOnPairing: with -autoHost, stop at the pairing sheet (screenshots).
/// -autoEmptyStore: start with an empty in-memory store (the Keychain is neither read nor written; screenshots of first run).
/// -autoSecondHost <name> -autoSecondCode <code>: after the first Mac, pair a second one; -autoSwitchTo <name> [-autoSwitchAfter <s>]:
/// then switch to that Mac (a Mac that refuses shows its library unreachable).
/// -autoShowMacs: the library opens with the Macs sheet shown; -autoPairFromMacs <name>: the Macs list chooses that unpaired Mac. -autoTab <games|macs|settings>: Apple TV's tab (screenshots).
/// -autoDeviceName <name>: this device's name for the run (saved with the next settings edit, as the other flags are).
/// -autoStats off|fps|compact|full: the numbers level for this run (not saved); -autoMenu <s>: the in-play menu opens <s> seconds
/// after play begins; -autoSettings: the library opens with Settings shown (screenshots).
/// -autoStayInPlay: stay in play after it begins, taking no samples (screenshots of connection trouble).
/// -autoBackToGames <s>: leave <s> seconds after play begins and stay at the library (the tile of a preparing game).
/// -autoControls: keep the on-screen controls although a controller is reported (screenshots).
/// -autoGear <s>: the gear's action runs <s> seconds after play begins (iOS); -autoTouchLayout 2d|3d: the on-screen layout for the run.
/// -autoSetOption <env>=<value>: with -autoGamePage, that change is made before anything else.
/// -autoGamePage <titleID>: the library opens that game's page (screenshots of the per-game options).
/// -autoLookSheet [-autoLookPage 2] shows the look component sheet. -> .claude/client.md § app
@MainActor enum Automation {
    private static let logger = Logger(subsystem: "nxportal", category: "auto")

    private struct Failed: Error { let step: String }

    /// True when `-autoPress` is valid: the play view then leaves the controller input off.
    static var drivesInput = false

    /// `-autoLookSheet`: the root view shows the component sheet instead of the screens (`LookSheet`).
    static let showsLookSheet = CommandLine.arguments.contains("-autoLookSheet")

    /// `-autoMenu <s>`: the play view opens its menu this many seconds after it appears.
    static let menuAfter: Double? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-autoMenu"), i + 1 < args.count else { return nil }
        return Double(args[i + 1])
    }()

    /// `-autoGear <s>`: the play view runs the on-screen gear's action (a tap on it) this many seconds after it appears (iOS).
    static let gearAfter: Double? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-autoGear"), i + 1 < args.count else { return nil }
        return Double(args[i + 1])
    }()

    /// `-autoControls`: the on-screen controls stay shown although a game controller is reported (a simulator may report one).
    static let keepsControls = CommandLine.arguments.contains("-autoControls")

    /// `-autoTouchLayout <2d|3d>`: the on-screen layout for this run (not saved).
    static let touchLayout: TouchLayout? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-autoTouchLayout"), i + 1 < args.count else { return nil }
        return TouchLayout(rawValue: args[i + 1])
    }()

    /// `-autoMenuPage <0|1>`: a phone's menu starts on that page (0 Now, 1 Connection, 2 Next start).
    static let menuPage: Int = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-autoMenuPage"), i + 1 < args.count else { return 0 }
        return Int(args[i + 1]) ?? 0
    }()

    /// `-autoSettingsScroll <controller|about>`: Settings scrolls to that group when it appears.
    static let settingsScroll: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-autoSettingsScroll"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// `-autoGamePage <titleID>`: the library opens that game's page at once (screenshots of the per-game options).
    static let gamePage: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-autoGamePage"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    #if os(tvOS)
    /// `-autoTab <games|macs|settings>`: Apple TV's shell opens on that tab (screenshots).
    static let tvTab: TVRootView.Tab = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-autoTab"), i + 1 < args.count else { return showsSettings ? .settings : .games }
        return TVRootView.Tab(rawValue: args[i + 1]) ?? .games
    }()
    #endif

    /// `-autoFocusTile <titleID>`: Apple TV's library focuses that tile when it appears (screenshots).
    static let focusTile: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-autoFocusTile"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// `-autoPairFromMacs <name>`: the Macs list chooses the unpaired Mac of that name once it is listed, as a tap on its "Pair"
    /// row would (with `-autoShowMacs`: pairing from the iPhone's Macs sheet).
    static let pairFromMacs: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-autoPairFromMacs"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// `-autoSettings`: the library shell shows Settings at once.
    static let showsSettings = CommandLine.arguments.contains("-autoSettings")

    /// The store's secrets: in memory with `-autoEmptyStore`, else the Keychain.
    static func secrets() -> any SecretStoring {
        CommandLine.arguments.contains("-autoEmptyStore") ? MemorySecrets() : KeychainSecrets()
    }

    static func begin(_ model: ClientModel) {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let host = value("-autoHost") else { return }
        let code = value("-autoCode"), titleID = value("-autoLaunch")
        if let name = value("-autoDeviceName") { model.settings.deviceName = name }  // set in memory; the next settings edit saves it, like the other flags
        var seconds = 20.0
        if args.contains("-autoSeconds") {
            guard let n = value("-autoSeconds").flatMap(Double.init), n >= 0 else { finish("auto failed: bad argument -autoSeconds", code: 1) }
            seconds = n
        }
        if args.contains("-autoPacing") {
            guard let mode = value("-autoPacing").flatMap(PicturePacing.init(rawValue:)) else {
                finish("auto failed: bad argument -autoPacing", code: 1)
            }
            model.settings.picturePacing = mode  // not saved: only the views' own toggles write the settings
        }
        if args.contains("-autoStats") {
            guard let level = value("-autoStats").flatMap(PanelLevel.init(rawValue:)) else { finish("auto failed: bad argument -autoStats", code: 1) }
            model.settings.statsLevel = level  // not saved
        }
        if args.contains("-autoBitrate") {
            guard let n = value("-autoBitrate").flatMap(Int.init), n >= 1, n <= 1000 else {
                finish("auto failed: bad argument -autoBitrate", code: 1)
            }
            model.settings.bitrateMbps = n  // not saved
        }
        var press: (buttons: PadButtons, at: Double)?
        if args.contains("-autoPress") {
            guard let p = value("-autoPress").flatMap(parsePress) else { finish("auto failed: bad argument -autoPress", code: 1) }
            press = p
            drivesInput = true
        }
        Task {
            do {
                try await run(model, host: host, code: code, titleID: titleID, seconds: seconds, press: press)
            } catch let failure as Failed {
                finish("auto failed: \(failure.step)", code: 1)  // the step only: the model's text may name a device
            } catch {
                finish("auto failed: interrupted", code: 1)
            }
        }
    }

    /// `-autoSecondHost` / `-autoSwitchTo`: a second Mac paired, then a switch (screenshots of a refused switch).
    private static func more(_ model: ClientModel) async throws {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let second = value("-autoSecondHost"), let code = value("-autoSecondCode") {
            let mac = try await wait("the second Mac to appear") { model.found.first { $0.name == second } }
            await model.choose(mac)
            await model.pair(code: code)
            _ = try await wait("the second Mac's library") { model.screen == .library && model.hostName == second ? true : nil }
        }
        if let name = value("-autoSwitchTo") {
            try await sleep(untilNs: uptimeNs() + ns(Double(value("-autoSwitchAfter") ?? "0") ?? 0))
            let row = try await wait("the Mac in the list") { model.macRows.first { $0.name == name } }
            let listed = model.found.contains { ($0.id ?? $0.name) == row.id }
            await model.switchMac(row)
            // What decided the screen (no names): was the Mac in the browse result, and how did the switch end.
            report("switch: browse lists \(model.found.count), target listed \(listed), state \(model.macState), problem \(String(describing: model.problem))")
        }
    }

    private static func parsePress(_ text: String) -> (buttons: PadButtons, at: Double)? {
        let parts = text.split(separator: "@")
        guard parts.count == 2, let at = Double(parts[1]), let b = PadButtons(name: String(parts[0])) else { return nil }
        return (b, at)
    }

    private static func run(_ model: ClientModel, host: String, code: String?, titleID: String?,
                            seconds: Double, press: (buttons: PadButtons, at: Double)?) async throws {
        let mac = try await wait("the Mac to appear") { model.found.first { $0.name == host } }
        await model.choose(mac)
        if case .pairing = model.screen {
            if CommandLine.arguments.contains("-autoStayOnPairing") { return }  // screenshots: the sheet stays open
            guard let code else { throw Failed(step: "pairing needs -autoCode") }
            await model.pair(code: code)
        }
        _ = try await wait("the library") { model.screen == .library || model.screen == .playing ? true : nil }
        try await more(model)
        // -autoSetOption <env>=<value>: that change to -autoGamePage's game before anything else (screenshots of "Changed")
        if let i = CommandLine.arguments.firstIndex(of: "-autoSetOption"), i + 1 < CommandLine.arguments.count,
           let page = gamePage {
            let pair = CommandLine.arguments[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            await model.loadOptions(titleID: page)
            if pair.count == 2 { await model.setOption(titleID: page, env: pair[0], value: pair[1]) }
        }
        guard let titleID else { return }  // stays at the library

        let game = try await wait("the game in the library") { model.games.first { $0.titleID == titleID } }
        await model.launch(game)
        _ = try await wait("playing") { model.screen == .playing ? true : nil }
        // Screenshots of the library tile of a game that is still preparing: leave this long after play begins, then stay.
        if let i = CommandLine.arguments.firstIndex(of: "-autoBackToGames"), i + 1 < CommandLine.arguments.count,
           let after = Double(CommandLine.arguments[i + 1]) {
            try await Task.sleep(nanoseconds: UInt64(after * 1e9))
            await model.leave()
            try await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            return
        }
        // Screenshots of connection trouble: the app stays in play (no samples, so the Host can be stopped under it).
        if CommandLine.arguments.contains("-autoStayInPlay") {
            try await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            return
        }
        // The clock starts at the first picture displayed; a game's first start after a change can take minutes.
        let first = try await waitAsync("the first picture", limit: firstPictureLimit) { () async -> (n: Int, ns: UInt64)? in
            guard let s = await model.sampleStats(), s.framesDisplayed > 0 else { return nil }
            return (s.framesDisplayed, uptimeNs())
        }
        let startNs = first.ns
        let pressTask = press.map { press in
            Task { @MainActor in
                try? await sleep(untilNs: startNs + ns(press.at))
                send(model, press.buttons)
                try? await Task.sleep(nanoseconds: 200_000_000)
                send(model, [])
            }
        }
        // One line per change of `stalled` (the link went quiet for a second, or came back).
        let stallTask = Task { @MainActor in
            var was = model.stalled
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard model.stalled != was else { continue }
                was = model.stalled
                report(String(format: "stalled t=%.1f %@", Double(uptimeNs() - startNs) / 1e9, was ? "on" : "off"))
            }
        }
        defer { stallTask.cancel() }
        // One sample a second; the last one at `seconds`.
        var samples: [(n: Int, ns: UInt64)] = [first]
        var last: SessionStats?
        var shownRates: [Double] = []
        var videoRates: [Double] = []
        var rateSeq = 0
        let endNs = startNs + ns(seconds)
        var k = 1.0
        while true {
            let at = min(startNs + ns(k), endNs)
            try await sleep(untilNs: at)
            guard let s = await model.sampleStats() else { throw Failed(step: "playing ended") }
            samples.append((s.framesDisplayed, uptimeNs()))
            last = s
            // One line per change of the rate, with what the controller saw -> `RateChange.line`.
            for c in s.rateChanges where c.seq > rateSeq { report(c.line); rateSeq = c.seq }
            if let p = model.playStats { report(statLine(t: samples.count - 1, p)); if p.rateMbps > 0 { videoRates.append(p.rateMbps) } }
            // The view reports once a second; 0 means none yet.
            if let shown = model.playStats?.shownFps, shown > 0 || !shownRates.isEmpty { shownRates.append(shown) }
            if at >= endNs { break }
            k += 1
        }
        await pressTask?.value

        guard let s = last, s.framesDisplayed > 0 else { finish("auto failed: no picture displayed", code: 1) }
        report(line(s, samples, model, shownRates: shownRates, videoRates: videoRates))
        await model.quitGame()
        _ = try? await wait("the library after quitting", limit: 8) { model.screen == .library ? true : nil }
        exit(0)
    }

    /// `shown_med`: median of the per-second `shownFps` the view reported; `late`: pictures that never got a refresh.
    /// `fps_avg`: pictures displayed since the first one / seconds since it. `fps_min`: the lowest one-second
    /// sample, the first second and a last partial second left out (all of the run when that leaves none).
    /// `fps_med`: the median of the same samples (a game's own loading seconds lower `fps_min` and `fps_avg`, not this).
    /// `rate_min`, `rate_med`: the per-second video rate (Mbit/s, what the Host applied); `cuts`: the rate controller's.
    static func line(_ s: SessionStats, _ samples: [(n: Int, ns: UInt64)], _ model: ClientModel,
                     shownRates: [Double] = [], videoRates: [Double] = []) -> String {
        func rate(_ a: (n: Int, ns: UInt64), _ b: (n: Int, ns: UInt64)) -> Double {
            b.ns > a.ns ? Double(b.n - a.n) / (Double(b.ns - a.ns) / 1e9) : 0
        }
        let first = samples[0], end = samples[samples.count - 1]
        let avg = rate(first, end)
        var intervals = Array(zip(samples, samples.dropFirst())).dropFirst()
        if let tail = intervals.last, Double(tail.1.ns - tail.0.ns) < 0.9e9 { intervals = intervals.dropLast() }
        let rates = intervals.map { rate($0.0, $0.1) }.sorted()
        let minimum = rates.first ?? avg
        let median = rates.isEmpty ? avg : rates[rates.count / 2]
        func f(_ x: Double) -> String { String(format: "%.1f", x) }
        return "auto frames=\(s.framesShown) displayed=\(s.framesDisplayed) fps=\(f(s.fps)) fps_avg=\(f(avg)) fps_min=\(f(minimum)) fps_med=\(f(median))"
            + " p95_ms=\(f(s.p95DelayMs)) p95_display_ms=\(f(s.p95DisplayMs)) skipped=\(s.framesSkipped)"
            + " audio_lost=\(model.soundLost) underruns=\(model.soundUnderruns)"
            + " shown_med=\(f(shownRates.isEmpty ? 0 : shownRates.sorted()[shownRates.count / 2])) late=\(model.latePictures)"
            + " gaps=\(s.sourceGaps)"
            + " nacks=\(s.nacksSent) asked=\(s.fragmentsAsked) recovered=\(s.fragmentsRecovered) repaired=\(s.framesRepaired) given_up=\(s.framesGivenUp) refreshes=\(s.refreshes) keys=\(s.keys) escalations=\(s.escalations) late_frags=\(s.fragmentsLate)"
            + " rate_min=\(f(videoRates.min() ?? 0)) rate_med=\(f(videoRates.isEmpty ? 0 : videoRates.sorted()[videoRates.count / 2])) cuts=\(s.rateCuts)"
    }

    /// One line a second while the clock runs: where the stutter comes from (`mac` and `gaps` are the Mac's side,
    /// `delay`, `gap95`, `rtt` the network's, `shown`, `late`, `decode` this device's).
    static func statLine(t: Int, _ p: ClientModel.PlayStats) -> String {
        func f(_ x: Double) -> String { String(format: "%.1f", x) }
        return "stat t=\(t) mac=\(f(p.macFps)) shown=\(f(p.shownFps)) late=\(f(p.late)) gaps=\(p.sourceGaps)"
            + " delay=\(f(p.delayMs)) p95=\(f(p.delayP95Ms)) rtt=\(f(p.rttMs)) gap95=\(f(p.gapP95Ms)) gapmax=\(f(p.gapMaxMs))"
            + " skipped=\(p.skipped) key=\(p.keyRequests) mbit=\(f(p.bitrateMbps)) decode=\(f(p.decodeMs))"
            + " buf=\(p.soundBufferMs) under=\(p.soundUnderruns) rate=\(f(p.rateMbps)) ceil=\(f(p.ceilingMbps)) why=\(p.rateWhy.isEmpty ? "-" : p.rateWhy)"
            + " queue=\(p.queueTarget) asked=\(p.fragmentsAsked) recovered=\(p.fragmentsRecovered) repaired=\(p.framesRepaired)"
            + " given_up=\(p.framesGivenUp) repairs=\(p.repairRequests) esc=\(p.escalations) keys=\(p.keys)"
            + (p.host.map { " host=\($0.framesSent)/\($0.framesFromGame) hdrop=\($0.framesDropped) hresent=\($0.resent) hrate=\(f(Double($0.rateBps) / 1e6)) hlate=\(f(Double($0.sendLateMaxUs) / 1000))" } ?? "")
    }

    private static func send(_ model: ClientModel, _ buttons: PadButtons) {
        model.send(InputState(seq: 0, player: 0, buttons: buttons.rawValue, lx: 0, ly: 0, rx: 0, ry: 0, motion: nil))
    }

    static let stepLimit = 60.0, firstPictureLimit = 660.0

    /// Polls every 100 ms until `condition` gives a value; `auto failed: <step> timed out` after `limit` seconds.
    private static func wait<T>(_ step: String, limit: Double = stepLimit, _ condition: () -> T?) async throws -> T {
        try await waitAsync(step, limit: limit) { condition() }
    }

    private static func waitAsync<T>(_ step: String, limit: Double, _ condition: () async -> T?) async throws -> T {
        let deadline = uptimeNs() + ns(limit)
        while true {
            if let value = await condition() { return value }
            if uptimeNs() >= deadline { throw Failed(step: "\(step) timed out") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func ns(_ seconds: Double) -> UInt64 { UInt64(max(0, seconds) * 1e9) }

    /// Sleeps until local uptime `target` (the clock of the display marks).
    private static func sleep(untilNs target: UInt64) async throws {
        let now = uptimeNs()
        if target > now { try await Task.sleep(nanoseconds: target - now) }
    }

    /// To the terminal (`simctl launch --console-pty`) and to the unified log (the device console).
    private static func report(_ line: String) {
        print(line)
        fflush(stdout)
        logger.notice("\(line, privacy: .public)")
    }

    private static func finish(_ line: String, code: Int32) -> Never {
        report(line)
        exit(code)
    }
}
#endif
