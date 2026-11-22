import Foundation

/// A title ID as a device or a Host may send it: 1 to 32 letters and digits (the artwork cache's file names, the stored render
/// sizes' keys and the options messages all rely on it).
public enum TitleID {
    public static func isWellFormed(_ id: String) -> Bool {
        (1...32).contains(id.utf8.count) && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }
    }
}

/// The one definition of what a per-game option message may carry. The Host's reader of a game's `launcher.json` clips to it,
/// the decoder of `options`, `optionsRequest`, `setOption` and `resetOptions` (on both sides) refuses what is over it, and the
/// app's cleaning starts from the same numbers -> .claude/portalkit.md § wire-network
public enum OptionLimits {
    /// Rows in a list, `[value, label]` pairs in a choice.
    public static let maxSettings = 200, maxChoices = 64
    /// Bytes: a variable name, a value (also a `rejected` echo's variable), a kind or level, a `needs`, a display text
    /// (section, label, note, a choice's label; at most `maxTextCharacters` characters).
    public static let maxEnvBytes = 64, maxValueBytes = 128, maxKindBytes = 32, maxNeedsBytes = 200, maxTextBytes = 2_048
    public static let maxTextCharacters = 512
    /// A render size's side.
    public static let maxSize = 100_000

    /// `DM_` and 1 to 61 of `A-Z 0-9 _` (at most `maxEnvBytes` in all): nothing else is ever a variable the Host sets.
    public static func isEnvName(_ name: String) -> Bool {
        let u = Array(name.utf8)
        guard u.count >= 4, u.count <= maxEnvBytes, u.starts(with: Array("DM_".utf8)) else { return false }
        return u.dropFirst(3).allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
    }

    /// A value that can go in an environment as text: at most `maxValueBytes`, no control character (line breaks and NUL
    /// included), none of the C1 range or the Unicode line and paragraph separators.
    public static func isPlainValue(_ s: String) -> Bool { s.utf8.count <= maxValueBytes && !hasControl(s) }

    /// A display text the decoder takes: at most `maxTextBytes`, no control character.
    public static func isPlainText(_ s: String) -> Bool { s.utf8.count <= maxTextBytes && !hasControl(s) }

    /// `s` as a display text: line breaks and tabs become spaces, other control characters go, at most `maxTextCharacters`
    /// scalars and `maxTextBytes` bytes (so what it returns always passes `isPlainText`).
    public static func cleanText(_ s: String) -> String {
        var out = String.UnicodeScalarView(), bytes = 0, count = 0
        for u in s.unicodeScalars {
            let scalar: Unicode.Scalar
            if u == "\n" || u == "\r" || u == "\t" || u.value == 0x2028 || u.value == 0x2029 { scalar = " " } else if isControl(u) { continue } else { scalar = u }
            let width = String(scalar).utf8.count
            guard count < maxTextCharacters, bytes + width <= maxTextBytes else { break }
            out.append(scalar); count += 1; bytes += width
        }
        return String(out)
    }

    private static func isControl(_ u: Unicode.Scalar) -> Bool {
        u.value < 0x20 || u.value == 0x7F || (0x80...0x9F).contains(u.value) || u.value == 0x2028 || u.value == 0x2029
    }

    private static func hasControl(_ s: String) -> Bool { s.unicodeScalars.contains(where: isControl) }
}

/// Thrown by the option types' decoders for what is over a limit; `ControlMessage.init(decoding:)` turns it into
/// `WireError.refused`.
struct OptionRefusal: Error {}
