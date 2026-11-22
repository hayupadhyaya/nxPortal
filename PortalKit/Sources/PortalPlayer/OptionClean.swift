import Foundation
import PortalKit

/// What the app lets through from a Host's `options`: bounded and clean before anything is shown or sent back. A row whose
/// variable name or values are not plain is dropped; texts lose control characters and are cut; lists are capped.
public enum OptionClean {
    public static let maxSettings = OptionLimits.maxSettings, maxChoices = OptionLimits.maxChoices, maxEnv = OptionLimits.maxEnvBytes
    public static let maxValueBytes = OptionLimits.maxValueBytes
    public static let maxLabel = 80, maxNote = 240, maxSection = 40, maxKind = 32
    /// A range with more positions than this is not offered as a slider.
    public static let maxSteps = 10_000.0
    /// A character of a label is at most this many scalars (a stack of combining marks is cut).
    public static let maxScalarsPerCharacter = 8
    public static let maxSize = OptionLimits.maxSize

    /// `options` for `titleID`, or nil when it names another title or this is not a title ID.
    public static func cleaned(_ o: GameOptions) -> GameOptions? {
        guard TitleID.isWellFormed(o.titleID) else { return nil }
        var seen = Set<String>(), out: [OptionSetting] = []
        for s in o.settings {
            if out.count == maxSettings { break }
            guard let c = setting(s), seen.insert(c.env).inserted else { continue }
            out.append(c)
        }
        return GameOptions(titleID: o.titleID, settings: out, rejected: o.rejected.flatMap { isEnv($0) ? $0 : nil }, full: o.full == true ? true : nil)
    }

    /// `DM_` and 1 to 61 of `A-Z 0-9 _`, as the Host takes a variable.
    public static func isEnv(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count >= 4, u.count <= maxEnv, u.starts(with: Array("DM_".utf8)) else { return false }
        return u.dropFirst(3).allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
    }

    /// A value that can go back to the Host unchanged: short, nothing that is control, format or a line break.
    public static func isPlain(_ s: String) -> Bool {
        s.utf8.count <= maxValueBytes && !s.unicodeScalars.contains { isUnwanted($0) }
    }

    /// For display: no control, format (bidi overrides, zero width) or line-break characters; trimmed; at most `limit` characters.
    /// The joiners real scripts need (U+200C, U+200D) stay; a character keeps at most `maxScalarsPerCharacter` scalars.
    public static func text(_ s: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for character in String(String.UnicodeScalarView(s.unicodeScalars.filter { !isUnwanted($0, keepingJoiners: true) })) {
            scalars.append(contentsOf: character.unicodeScalars.prefix(maxScalarsPerCharacter))
        }
        let kept = String(scalars)
        let trimmed = kept.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) : trimmed
    }

    private static func isUnwanted(_ u: Unicode.Scalar, keepingJoiners: Bool = false) -> Bool {
        if keepingJoiners, u.value == 0x200C || u.value == 0x200D { return false }
        switch u.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: return true
        default: return false
        }
    }

    private static func finite(_ d: Double?) -> Double? { d.flatMap { $0.isFinite ? $0 : nil } }

    private static func size(_ s: OptionBase.Size) -> Bool { (1...maxSize).contains(s.width) && (1...maxSize).contains(s.height) }

    private static func setting(_ s: OptionSetting) -> OptionSetting? {
        guard isEnv(s.env), s.kind.utf8.count <= maxKind, !s.kind.isEmpty, isPlain(s.defaultValue), isPlain(s.current) else { return nil }
        var out = s
        out.kind = text(s.kind, limit: maxKind)
        out.section = text(s.section, limit: maxSection)
        out.label = text(s.label, limit: maxLabel)
        if out.label.isEmpty { out.label = s.env }
        out.note = text(s.note, limit: maxNote)
        out.options = s.options.map { pairs in
            var kept: [[String]] = []
            for p in pairs.prefix(maxChoices * 2) where p.count >= 2 && isPlain(p[0]) && !kept.contains(where: { $0[0] == p[0] }) {
                if kept.count == maxChoices { break }
                let label = text(p[1], limit: maxLabel)
                kept.append([p[0], label.isEmpty ? p[0] : label])
            }
            return kept
        }
        out.min = finite(s.min); out.max = finite(s.max); out.step = finite(s.step)
        out.on = s.on.flatMap { isPlain($0) ? $0 : nil }
        out.off = s.off.flatMap { isPlain($0) ? $0 : nil }
        out.base = s.base.flatMap { size($0.docked) && size($0.handheld) ? $0 : nil }
        out.level = s.level.flatMap { $0.utf8.count <= maxKind ? text($0, limit: maxKind) : nil }
        out.needs = s.needs.flatMap(needs)
        return out
    }

    /// `VAR=value`: a variable and a plain value, no second `=`.
    private static func needs(_ s: String) -> String? {
        guard isPlain(s), let eq = s.firstIndex(of: "=") else { return nil }
        let value = s[s.index(after: eq)...]
        return isEnv(String(s[..<eq])) && !value.isEmpty && !value.contains("=") ? s : nil
    }
}
