import Foundation

/// The name a device goes by: one clean-up, used by the device before it sends and by the Host before it stores or shows
/// -> .claude/portalkit.md § wire-network
public enum DeviceName {
    public static let maxCharacters = 40
    public static let maxBytes = 120
    /// What a device with no usable name is called.
    public static let fallback = "Device"

    /// Control and format characters removed (U+200C and U+200D stay: they join emoji and some scripts), every run of white
    /// space one space, trimmed, cut at a character boundary to `maxCharacters` and `maxBytes` (a space the cut leaves at the
    /// end is trimmed); nil when nothing is left or nothing a person can see (only joiners, fillers, a Braille blank, private-use or
    /// unassigned scalars). `clean(clean(x)) == clean(x)`.
    public static func clean(_ raw: String) -> String? {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                if scalar.value != 0x200C && scalar.value != 0x200D { continue }
            default: break
            }
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
        }
        // The visible check runs on the text that is kept: a cut can leave only blanks.
        let cut = cut(String(out), characters: maxCharacters, bytes: maxBytes)
        return cut.unicodeScalars.contains(where: isVisible) ? cut : nil
    }

    /// A scalar a person can see: a letter, number, mark, symbol or punctuation mark, not a joiner, a filler or a blank.
    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200C, 0x200D, 0x2800, 0x115F, 0x1160, 0x3164, 0xFFA0: return false
        default: break
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default: return false
        }
    }

    /// `base` with " <n>" after it, the whole still within the limits (the base gives way).
    public static func numbered(_ base: String, _ n: Int) -> String {
        let suffix = " \(n)"
        let head = cut(base, characters: maxCharacters - suffix.count, bytes: maxBytes - suffix.utf8.count)
        return head + suffix
    }

    /// `raw` cut to `maxCharacters` and `maxBytes` at a character boundary, nothing else changed (the wire's bound on a name
    /// before anyone cleans it).
    public static func clip(_ raw: String) -> String {
        var out = "", count = 0, size = 0
        for ch in raw {
            let n = String(ch).utf8.count
            if count + 1 > maxCharacters || size + n > maxBytes { break }
            out.append(ch); count += 1; size += n
        }
        return out
    }

    /// The longest start of `s` that fits, at a character boundary, without a space at its end.
    private static func cut(_ s: String, characters: Int, bytes: Int) -> String {
        var out = "", count = 0, size = 0
        for ch in s {
            let n = String(ch).utf8.count
            if count + 1 > characters || size + n > bytes { break }
            out.append(ch); count += 1; size += n
        }
        while out.last == " " { out.removeLast() }
        return out
    }
}
