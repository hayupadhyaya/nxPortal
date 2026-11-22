import Foundation
import PortalKit

/// The numbers panel's text at each level; the app's `Strings` only forwards here -> .claude/client.md § stats
public enum PanelText {
    static let dash = "–"

    /// What the client knows about the game when the Mac sends no frame numbers: it is paused or still starting.
    public enum GameNote: Equatable, Sendable { case paused, starting }
    static let labelWidth = 9

    /// One string per line: nothing for `off`; `fps` one line; `compact` two; `full` the header, seven lines and the Mac and Game blocks (five). `stats` nil
    /// (no snapshot yet) gives dashes. `pacing` is the picture mode in use.
    public static func lines(level: PanelLevel, stats p: ClientModel.PlayStats?, pacing: PicturePacing, note: GameNote? = nil) -> [String] {
        func n(_ x: Double?) -> String { x.map { String(format: "%.0f", $0) } ?? dash }
        func one(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? dash }
        func i(_ x: Int?) -> String { x.map(String.init) ?? dash }
        func label(_ s: String) -> String { s.padding(toLength: labelWidth, withPad: " ", startingAt: 0) }
        let word = pacing == .smooth ? "Smooth" : "Immediate"
        let header = "\(n(p?.macFps)) fps  \(p.map { "\($0.width) x \($0.height)" } ?? dash)"
        switch level {
        case .off:
            return []
        case .fps:
            return [header]
        case .compact:
            return ["Mac \(n(p?.macFps)) fps  Shown \(n(p?.shownFps))  Late \(n(p?.late))/s  \(word)",
                    "Delay \(n(p?.delayMs)) ms  Rate \(n(p?.rateMbps)) / \(n(p?.ceilingMbps)) Mbit/s"]
        case .full:
            return [
                header,
                label("Mac") + "\(n(p?.macFps)) fps · gaps \(i(p?.sourceGaps)) · \(p.map { "\($0.width) x \($0.height)" } ?? dash) · \(one(p?.bitrateMbps)) Mbit/s",
                label("Shown") + "\(n(p?.shownFps)) fps · late \(n(p?.late))/s · \(word.lowercased())",
                label("Delay") + "\(n(p?.delayMs)) ms · p95 \(n(p?.delayP95Ms)) ms",
                label("Network") + "round trip \(n(p?.rttMs)) ms · gap p95 \(n(p?.gapP95Ms)) ms · max \(n(p?.gapMaxMs)) ms · lost \(i(p?.skipped))",
                label("Rate") + "\(n(p?.rateMbps)) / \(n(p?.ceilingMbps)) Mbit/s · cuts \(i(p?.rateCuts))",
                label("Decode") + "\(one(p?.decodeMs)) ms",
                label("Sound") + "buffer \(i(p?.soundBufferMs)) ms\(p?.soundAuto == true ? " auto" : "") · underruns \(i(p?.soundUnderruns)) · lost \(i(p?.soundLost))",
            ] + loadLines(p?.load, note: note, label: label)
        }
    }

    /// A share (tenths of a percent) as eight cells, rounded to the nearest, clamped to 0...1000.
    public static func bar(tenths: Int) -> String {
        let filled = Int((Double(min(max(tenths, 0), 1000)) / 125).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: 8 - filled)
    }

    /// Why the game sends no frames, from what the Mac said about it: preparing or starting, or paused.
    public static func note(preparing: Bool, run: GameRunState?) -> GameNote? {
        if preparing || run == .starting { return .starting }
        return run == .paused ? .paused : nil
    }

    /// The Mac and Game blocks (`§ screen-play`): five lines, dashes while no load is known (or the game is not running).
    /// Nothing in a `load` datagram is trusted: shares are clamped to 0...100 %, a memory size that cannot be (zero or
    /// absurd total, used above total) is dashes, an unknown pressure or heat is "?", never the best state. The game's CPU
    /// is "of one core" (100 % = one core busy), so it may pass 100; only an impossible value (over 256 cores) is dashes.
    static func loadLines(_ l: HostLoad?, note: GameNote?, label: (String) -> String) -> [String] {
        // Rounded to the nearest, as the decimals are (999 tenths is 100 %).
        func pct(_ tenths: UInt16?) -> String { tenths.map { String(Int((Double(min($0, 1000)) / 10).rounded())) } ?? dash }
        func fmtGB(_ mib: UInt32) -> String {
            let v = String(format: "%.1f", Double(mib) / 1024)
            return v.hasSuffix(".0") ? String(v.dropLast(2)) : v
        }
        func deci(_ x: UInt16?) -> String { x.map { String(format: "%.1f", Double($0) / 10) } ?? dash }
        let maxMemMiB: UInt32 = 16_777_216  // 16 TiB: more is not a Mac
        let memOK = l.map { $0.memTotalMiB > 0 && $0.memTotalMiB <= maxMemMiB && $0.memUsedMiB <= $0.memTotalMiB } ?? false
        let pressure = l.map { ["ok", "warning", "critical"][safe: Int($0.pressure)] ?? "?" } ?? dash
        let heat = l.map { ["nominal", "fair", "serious", "critical"][safe: Int($0.thermal)] ?? "?" } ?? dash
        let gpu = l.map { $0.gpuPresent && $0.gpu != HostLoad.gpuNotAvailable ? "GPU \(pct($0.gpu)) % \(bar(tenths: Int(min($0.gpu, 1000))))" : "GPU n/a" } ?? "GPU \(dash)"
        let cpu = l.map { "CPU \(pct($0.cpuTotal)) % \(bar(tenths: Int(min($0.cpuTotal, 1000))))" } ?? "CPU \(dash)"
        let g = l.flatMap { $0.gameAlive ? $0 : nil }
        let cpuGame = g.flatMap { $0.gameCpuCentiCores <= 25_600 ? String($0.gameCpuCentiCores) : nil } ?? dash
        // The game's memory in whole MB under a gibibyte (a small process reads "0 GB" otherwise); more than the Mac has is dashes.
        let memGame: String = {
            guard let g, !memOK || g.gameMemMiB <= (l?.memTotalMiB ?? 0), g.gameMemMiB <= maxMemMiB else { return dash }
            return g.gameMemMiB < 1024 ? "\(g.gameMemMiB) MB" : "\(fmtGB(g.gameMemMiB)) GB"
        }()
        let framesOK = g.map { $0.gameFpsDeci > 0 && $0.gameFpsDeci <= 10_000 } ?? false
        let fpsText: String = {
            guard let g else { return "\(dash) fps" }
            if g.gameFpsDeci > 10_000 { return "\(dash) fps" }
            if g.gameFpsDeci > 0 { return "\(deci(g.gameFpsDeci)) fps" }
            switch note { case .paused: return "paused"; case .starting: return "starting"; case nil: return "no frames" }
        }()
        return [
            label("MAC") + "\(cpu)  \(gpu)",
            label("") + "performance \(pct(l?.cpuPerf)) % · efficiency \(pct(l?.cpuEff)) %",
            label("") + "memory \(memOK ? fmtGB(l!.memUsedMiB) : dash) / \(memOK ? fmtGB(l!.memTotalMiB) : dash) GB · \(pressure) · heat \(heat)",
            label("GAME") + "CPU \(cpuGame) % · memory \(memGame) · \(fpsText)",
            label("") + "frame \(deci(framesOK ? g?.frameMeanDeciMs : nil)) ms · p95 \(deci(framesOK ? g?.frameP95DeciMs : nil)) ms · max \(deci(framesOK ? g?.frameMaxDeciMs : nil)) ms",
        ]
    }

    /// The in-play menu's second line: "On Den Mac · 1920 x 1080 · 60 fps" (the stream part only once it is known).
    public static func menuSubtitle(mac: String?, width: Int, height: Int, fps: Int) -> String {
        var parts = [Messages.onMac(mac ?? Messages.theMac)]
        if width > 0, height > 0 { parts.append("\(width) x \(height)") }
        if fps > 0 { parts.append("\(fps) fps") }
        return parts.joined(separator: " · ")
    }

    /// The level as the Numbers row names it.
    public static func name(_ level: PanelLevel) -> String {
        switch level {
        case .off: "Off"
        case .fps: "FPS"
        case .compact: "Compact"
        case .full: "Full"
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
