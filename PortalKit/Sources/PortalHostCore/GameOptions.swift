#if os(macOS)
import Foundation
import PortalKit

/// One row of a game's `launcher.json`, as the Host keeps it. `kind` is the launcher's text; a kind this build does not
/// know stays as it is and can never be set.
struct LauncherSetting: Equatable, Sendable {
    var env: String, kind: String, section: String, label: String, note: String, defaultValue: String
    var options: [[String]]?
    var min: Double?, max: Double?, step: Double?
    var on: String?, off: String?
    var base: OptionBase?
    var level: String?, needs: String?
}

/// Reads a game's own settings list and judges a value for one of its rows. The list is the game's, a value comes from a
/// device: only a row the list has (minus `HiddenOptions` and the Host's own variables) can be set, only to a value the row
/// offers, and no value can be long or carry a control character -> .claude/host.md § options
struct GameOptionsReader {
    static let fileName = "Contents/Resources/dm/launcher.json"
    /// The file the reader takes; the rows, values, names and texts are `OptionLimits`, the one definition the decoder of `options`
    /// uses too, so what is read here is always under what is sent (a list answer stays small because the file is at most 256 KiB, not because of the row limits).
    static let maxFileBytes = 256 * 1024
    static let maxSettings = OptionLimits.maxSettings, maxValue = OptionLimits.maxValueBytes, maxOptions = OptionLimits.maxChoices

    /// The rows of the app's list, nil when it has none, is not a regular file, is over `maxFileBytes` or is not a list.
    static func read(bundle: URL, allowing: (String) -> Bool = PlayerOptions.isSettable) -> [LauncherSetting]? {
        // Opened without blocking and checked on the descriptor: a pipe in its place must not stop the Host.
        let fd = open(bundle.appendingPathComponent(fileName).path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxFileBytes else { return nil }
        var data = Data(), chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maxFileBytes {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        return data.count <= maxFileBytes ? parse(data, allowing: allowing) : nil
    }

    /// `allowing`: which variables may have a row (the service gives its `HostConfig.settableOption`; a row of any other is dropped).
    static func parse(_ data: Data, allowing: (String) -> Bool = PlayerOptions.isSettable) -> [LauncherSetting]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let rows = root["settings"] as? [Any] else { return nil }
        var seen = Set<String>(), out: [LauncherSetting] = []
        for case let row as [String: Any] in rows {
            if out.count == maxSettings { break }
            guard let setting = setting(from: row, allowing: allowing), seen.insert(setting.env).inserted else { continue }
            out.append(setting)
        }
        return out
    }

    private static func setting(from row: [String: Any], allowing: (String) -> Bool) -> LauncherSetting? {
        guard let env = row["env"] as? String, isEnvName(env), allowing(env), !HiddenOptions.names.contains(env),
              !HostService.reservedGameVariables.contains(env), !ReservedVariables.isReserved(env),
              let kind = row["kind"] as? String, !kind.isEmpty, kind.utf8.count <= OptionLimits.maxKindBytes, OptionLimits.isPlainText(kind),
              let defaultValue = text(row["default"]), isPlainValue(defaultValue) else { return nil }
        var options: [[String]]?
        if let pairs = row["options"] as? [Any] {
            var kept: [[String]] = []
            for case let pair as [Any] in pairs.prefix(maxOptions * 2) where pair.count >= 2 {
                guard kept.count < maxOptions, let value = pair[0] as? String, isPlainValue(value), !kept.contains(where: { $0[0] == value }) else { continue }
                let label = clip((pair[1] as? String) ?? value)
                kept.append([value, label.isEmpty ? value : label])
            }
            options = kept
        }
        var base: OptionBase?
        if let b = row["base"] as? [String: Any], let docked = size(b["docked"]), let handheld = size(b["handheld"]) {
            base = OptionBase(docked: docked, handheld: handheld)
        }
        func plain(_ any: Any?) -> String? { text(any).flatMap { isPlainValue($0) ? $0 : nil } }
        // A range the wire decoder would refuse (min over max, a step of 0 or less) loses its numbers: the row stays, read-only.
        var lo = number(row["min"]), hi = number(row["max"]), step = number(row["step"])
        if let l = lo, let h = hi, l > h { lo = nil; hi = nil; step = nil }
        if let st = step, st <= 0 { lo = nil; hi = nil; step = nil }
        let needs = (row["needs"] as? String).flatMap { $0.utf8.count <= OptionLimits.maxNeedsBytes && isNeeds($0) ? $0 : nil }
        return LauncherSetting(env: env, kind: kind, section: clip(text(row["section"]) ?? ""), label: clip(text(row["label"]) ?? env),
                               note: clip(text(row["note"]) ?? ""), defaultValue: defaultValue, options: options,
                               min: lo, max: hi, step: step,
                               on: plain(row["on"]), off: plain(row["off"]), base: base,
                               level: (row["level"] as? String).flatMap { $0.utf8.count <= OptionLimits.maxKindBytes && OptionLimits.isPlainText($0) ? $0 : nil }, needs: needs)
    }

    // MARK: validating

    /// The value as the game should get it, or nil when the row does not offer it: a choice takes one of its values, a
    /// toggle its `on` or `off`, a range a plain decimal inside its bounds, snapped to the nearest step; any other kind
    /// takes nothing.
    static func validate(_ value: String, for setting: LauncherSetting) -> String? {
        guard isPlainValue(value) else { return nil }
        switch setting.kind {
        case "choice": return setting.options?.contains { $0.first == value } == true ? value : nil
        case "toggle": return value == setting.on || value == setting.off ? value : nil
        case "range":
            guard let lo = setting.min, let hi = setting.max, let step = setting.step, step > 0, lo <= hi,
                  let x = plainDecimal(value), x >= lo - 1e-9, x <= hi + 1e-9 else { return nil }
            var n = ((x - lo) / step).rounded()
            if lo + n * step > hi + 1e-9 { n -= 1 }
            let snapped = Swift.min(Swift.max(lo + n * step, lo), hi)
            return format(snapped, decimals: Swift.max(decimals(lo), decimals(step)))
        default: return nil
        }
    }

    /// `value` in the form `validate` gives, or as it is when the row does not take it (a default the game wrote its own way).
    static func canonical(_ value: String, for setting: LauncherSetting) -> String { validate(value, for: setting) ?? value }

    // MARK: pieces

    /// `OptionLimits.isEnvName`: `DM_` and 1 to 61 of `A-Z 0-9 _`.
    static func isEnvName(_ name: String) -> Bool { OptionLimits.isEnvName(name) }

    /// `OptionLimits.isPlainValue`: short, no control character, nothing that is a line break.
    static func isPlainValue(_ s: String) -> Bool { OptionLimits.isPlainValue(s) }

    private static func isNeeds(_ s: String) -> Bool {
        guard let eq = s.firstIndex(of: "=") else { return false }
        let name = String(s[..<eq]), value = s[s.index(after: eq)...]
        return isEnvName(name) && !value.isEmpty && !value.contains("=") && !value.contains(";") && isPlainValue(String(value))
    }

    /// A display text as the decoder takes it: control characters out (line breaks become spaces), at most 512 characters.
    private static func clip(_ s: String) -> String { OptionLimits.cleanText(s) }

    /// A string, or a number written as the schema's text would be; nothing else (a boolean is neither).
    private static func text(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        let d = n.doubleValue
        return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : "\(d)"
    }

    private static func number(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func size(_ any: Any?) -> OptionBase.Size? {
        guard let a = any as? [Any], a.count == 2, let w = (a[0] as? NSNumber)?.intValue, let h = (a[1] as? NSNumber)?.intValue,
              (1...100_000).contains(w), (1...100_000).contains(h) else { return nil }
        return OptionBase.Size(width: w, height: h)
    }

    /// `-`? digits (`.` digits)?, ASCII only: no sign other than minus, no exponent, no `nan`, no spaces.
    private static func plainDecimal(_ s: String) -> Double? {
        var u = Array(s.utf8)
        if u.first == 0x2D { u.removeFirst() }
        let parts = u.split(separator: 0x2E, omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }) else { return nil }
        return Double(s)
    }

    private static func decimals(_ d: Double) -> Int {
        var t = String(format: "%.6f", d)
        while t.hasSuffix("0") { t.removeLast() }
        return t.hasSuffix(".") ? 0 : t.count - (t.firstIndex(of: ".").map { t.distance(from: t.startIndex, to: $0) + 1 } ?? t.count)
    }

    private static func format(_ v: Double, decimals: Int) -> String {
        var t = String(format: "%.\(decimals)f", v)
        if t.contains(".") {
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
        }
        return t == "-0" ? "0" : t
    }
}
#endif
