import Foundation

/// Where the options go and how a row is laid out, decided from sizes (the views only draw the answer).
public enum OptionLayout {
    public enum Idiom: Sendable { case phone, tablet, tv }
    public enum NextStart: Equatable, Sendable { case page, column, inline }
    public enum MenuPage: Equatable, Sendable { case now, newConnection, nextStart }
    public enum RowForm: Equatable, Sendable { case inline, chipBelow, stacked }
    public enum Columns: Equatable, Sendable { case two(left: Double), single }

    /// A phone: a third page beside "Now" and "Connection" (a half-width column cannot hold a slider row); an iPad: a
    /// column beside them; Apple TV: rows in the one list. The text size does not change the place.
    public static func nextStart(_ idiom: Idiom, accessibilitySize: Bool) -> NextStart {
        switch idiom {
        case .phone: .page
        case .tablet: .column
        case .tv: .inline
        }
    }
    /// The pages of the phone menu's picker (the others show the groups together).
    public static func menuPages(_ idiom: Idiom, hasOptions: Bool) -> [MenuPage] {
        [.now, .newConnection] + (idiom == .phone && hasOptions ? [.nextStart] : [])
    }
    /// A tab's name: "Connection" when the picker has three pages (the segments are narrow), else "New connection". The page's
    /// own heading is always "Needs a new connection".
    public static func tabLabel(_ page: MenuPage, among pages: [MenuPage]) -> String {
        switch page {
        case .now: OptionText.nowTab
        case .newConnection: pages.count > 2 ? OptionText.newConnectionShortTab : OptionText.newConnectionTab
        case .nextStart: OptionText.nextStartTab
        }
    }
    /// `width`: what the row has. Wide: the chip beside the value; narrower: the chip under the label; narrower still (or the
    /// largest text): the label, then the value.
    public static func rowForm(width: Double, accessibilitySize: Bool, hasChip: Bool) -> RowForm {
        if accessibilitySize || width < 300 { return .stacked }
        return width < 460 && hasChip ? .chipBelow : .inline
    }
    /// The game page: two columns where both fit, else one (the largest text, a narrow screen).
    public static func pageColumns(width: Double, idiom: Idiom, accessibilitySize: Bool) -> Columns {
        guard !accessibilitySize, width >= 600 else { return .single }
        return idiom == .tv ? .two(left: 640) : .two(left: Swift.min(400, Swift.max(240, width * 0.34)))
    }
}
