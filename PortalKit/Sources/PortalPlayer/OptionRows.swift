import Foundation
import PortalKit

/// A value of a choice row: what goes to the Host and what the person reads.
public struct OptionChoice: Equatable, Sendable {
    public var value: String, label: String
    public init(value: String, label: String) { self.value = value; self.label = label }
}

/// How a row is edited. The app knows kinds, never options: `readOnly` is every kind it does not know and every known
/// kind whose list is not usable (no choices, a range without sensible bounds, a toggle without its two values).
public enum OptionEditor: Equatable, Sendable {
    case choice([OptionChoice])
    case range(min: Double, max: Double, step: Double, base: OptionBase?)
    case toggle(on: String, off: String)
    case readOnly

    /// Where a range can stand, each as the Host takes it ("0.5", "0.55" … "1"): what a control without a slider (the remote)
    /// picks from; empty for the other editors.
    public var positions: [String] {
        guard case let .range(lo, _, step, _) = self else { return [] }
        return (0..<steps).map { OptionRows.format(lo + Double($0) * step, min: lo, step: step) }
    }

    /// A range's positions from `min` to `max` (11 for 0.5 to 1.0 by 0.05); 0 for the others.
    public var steps: Int {
        guard case let .range(lo, hi, step, _) = self else { return 0 }
        return Int(((hi - lo) / step).rounded()) + 1
    }
}

/// One setting with how it is edited. The setting is the cleaned one (`OptionClean`).
public struct OptionRow: Equatable, Identifiable, Sendable {
    public var setting: OptionSetting
    public var editor: OptionEditor
    public var id: String { setting.env }
    public var label: String { setting.label }
    public init(setting: OptionSetting, editor: OptionEditor) { self.setting = setting; self.editor = editor }
}

public struct OptionSection: Equatable, Sendable {
    public var title: String
    public var basic: [OptionRow], more: [OptionRow]
    public init(title: String, basic: [OptionRow], more: [OptionRow]) { self.title = title; self.basic = basic; self.more = more }
}

/// A game's settings as the page draws them (`§ screen-game-page`): sections in the order of their first rows, a section's
/// `level: basic` rows first and the rest under "More"; with no basic row in the whole list nothing is folded away.
/// Everything shown is the Host's list, cleaned and bounded; no option is named here -> .claude/client.md § app
public struct OptionRows: Equatable, Sendable {
    public let sections: [OptionSection]

    public init(_ options: GameOptions) {
        let rows = options.settings.map { OptionRow(setting: $0, editor: Self.editor(for: $0)) }
        let anyBasic = rows.contains { $0.setting.level == "basic" }
        var order: [String] = [], basic: [String: [OptionRow]] = [:], more: [String: [OptionRow]] = [:]
        for row in rows {
            let title = row.setting.section.isEmpty ? OptionText.untitledSection : row.setting.section
            if basic[title] == nil { order.append(title); basic[title] = []; more[title] = [] }
            if !anyBasic || row.setting.level == "basic" { basic[title]?.append(row) } else { more[title]?.append(row) }
        }
        sections = order.map { OptionSection(title: $0, basic: basic[$0] ?? [], more: more[$0] ?? []) }
    }

    /// The editor a row's kind and fields allow.
    static func editor(for s: OptionSetting) -> OptionEditor {
        switch s.kind {
        case "choice":
            let list = (s.options ?? []).compactMap { $0.count >= 2 ? OptionChoice(value: $0[0], label: $0[1]) : nil }
            return list.isEmpty ? .readOnly : .choice(list)
        case "range":
            guard let lo = s.min, let hi = s.max, let step = s.step, lo.isFinite, hi.isFinite, step.isFinite, step > 0, lo < hi,
                  (hi - lo) / step <= OptionClean.maxSteps else { return .readOnly }
            return .range(min: lo, max: hi, step: step, base: s.base)
        case "toggle":
            guard let on = s.on, let off = s.off, on != off else { return .readOnly }
            return .toggle(on: on, off: off)
        default: return .readOnly
        }
    }

    /// Every row in drawing order.
    public var all: [OptionRow] { sections.flatMap { $0.basic + $0.more } }

    /// `values`: each row's effective value by variable. A row naming `VAR=value` shows only while the row that sets `VAR`
    /// has that value; a variable no row sets keeps it visible.
    public func visible(_ row: OptionRow, values: [String: String]) -> Bool {
        guard let needs = row.setting.needs, let eq = needs.firstIndex(of: "=") else { return true }
        let name = String(needs[..<eq]), wanted = String(needs[needs.index(after: eq)...])
        guard let have = values[name] else { return true }
        return have == wanted
    }

    /// The effective values of a list, by variable.
    public static func values(_ options: GameOptions) -> [String: String] {
        Dictionary(options.settings.map { ($0.env, $0.current) }, uniquingKeysWith: { first, _ in first })
    }

    /// The row that scales the picture: the first range with a `base` (found by that, never by its name).
    public var renderScale: OptionRow? {
        all.first { if case let .range(_, _, _, base) = $0.editor, base != nil { true } else { false } }
    }

    /// The few rows of the in-play menu: the render scale first, then the basic rows in order, only visible rows this app can
    /// change; at most `limit`.
    public func menuRows(values: [String: String], limit: Int = 3) -> [OptionRow] {
        var out: [OptionRow] = []
        let scale = renderScale
        if let scale, visible(scale, values: values) { out.append(scale) }
        for row in sections.flatMap(\.basic) where row.editor != .readOnly && row.id != scale?.id && visible(row, values: values) {
            out.append(row)
        }
        return Array(out.prefix(limit))
    }

    /// The page's sentence about a larger picture, naming the game's own render-scale row by its label; nil when the game
    /// has no such row (or its options are not known).
    public static func sizeHint(_ options: GameOptions?) -> String? {
        options.flatMap { OptionRows($0).renderScale }.map { OptionText.sizeHint(label: $0.label) }
    }

    /// "1200 x 675": the base size times the scale, rounded.
    public static func sizeLabel(scale: Double, base: OptionBase.Size) -> String {
        // clamped before it is converted: a Double outside Int's range traps
        let k = scale.isFinite ? Swift.min(Swift.max(scale, 0), 1000) : 0
        func side(_ n: Int) -> Int { Int(Swift.min(Swift.max((Double(n) * k).rounded(), 0), Double(OptionClean.maxSize))) }
        return "\(side(base.width)) x \(side(base.height))"
    }

    /// A range row's value as a number: only when it is finite and inside the range (a hostile or broken value is not a number
    /// here; the row shows its text).
    public static func rangeValue(_ row: OptionRow) -> Double? {
        guard case let .range(lo, hi, _, _) = row.editor, let x = plainDecimal(row.setting.current),
              x >= lo - 1e-9, x <= hi + 1e-9 else { return nil }
        return Swift.min(Swift.max(x, lo), hi)
    }

    /// The position a control without a slider selects for the row's value (the one nearest; the first when the value is no
    /// plain number inside the range).
    public static func nearestPosition(_ row: OptionRow) -> String {
        let positions = row.editor.positions
        guard let x = rangeValue(row) else { return positions.first ?? row.setting.current }
        return positions.min { abs((Double($0) ?? 0) - x) < abs((Double($1) ?? 0) - x) } ?? row.setting.current
    }

    /// `-`? digits (`.` digits)?, ASCII only and finite: no exponent, no `nan`, no `inf`, no hex.
    static func plainDecimal(_ s: String) -> Double? {
        var u = Array(s.utf8)
        if u.first == 0x2D { u.removeFirst() }
        let parts = u.split(separator: 0x2E, omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }),
              let x = Double(s), x.isFinite else { return nil }
        return x
    }

    /// The value one step up (`direction` > 0) or down from the row's own, as the Host takes it; nil at the end or for a row
    /// that is not a range. A value that is not a number steps from the lower end.
    public static func step(_ row: OptionRow, direction: Int) -> String? {
        guard case let .range(lo, hi, step, _) = row.editor, direction != 0 else { return nil }
        let n = ((rangeValue(row) ?? lo) - lo) / step
        let next = lo + (n.rounded() + (direction > 0 ? 1 : -1)) * step
        guard next >= lo - 1e-9, next <= hi + 1e-9 else { return nil }
        return format(Swift.min(Swift.max(next, lo), hi), min: lo, step: step)
    }

    /// A range value as the Host takes it: as many decimals as the bound and the step have, none trailing ("0.75", "1").
    public static func format(_ v: Double, min lo: Double, step: Double) -> String {
        func decimals(_ d: Double) -> Int {
            var t = String(format: "%.6f", d)
            while t.hasSuffix("0") { t.removeLast() }
            guard let dot = t.firstIndex(of: ".") else { return 0 }
            return t.distance(from: dot, to: t.endIndex) - 1
        }
        var t = String(format: "%.\(Swift.max(decimals(lo), decimals(step)))f", v)
        if t.contains(".") {
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
        }
        return t == "-0" ? "0" : t
    }

    /// What a row shows as its value: a choice's label (the raw value when the list does not offer it), "on" / "off" are the
    /// switch, a range its number with the size when it has a `base`, anything else its raw value.
    public static func valueText(_ row: OptionRow) -> String {
        let s = row.setting
        switch row.editor {
        case let .choice(list): return list.first { $0.value == s.current }?.label ?? s.current
        case .toggle: return s.current
        case let .range(lo, _, step, base):
            guard let x = rangeValue(row) else { return s.current }
            let number = format(x, min: lo, step: step)
            guard let base else { return number }
            return "\(number) = \(sizeLabel(scale: x, base: base.docked))"
        case .readOnly: return s.current
        }
    }

    /// "Changed" on the person's own choices; "Default" on a row at its tested default when its section has changed rows.
    public static func chip(for row: OptionRow, in section: OptionSection) -> OptionText.Chip? {
        if row.setting.chosen { return .changed }
        return (section.basic + section.more).contains { $0.setting.chosen } ? .atDefault : nil
    }
}
