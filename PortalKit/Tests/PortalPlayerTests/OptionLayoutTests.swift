import XCTest
@testable import PortalPlayer

/// Where the options go and how rows are laid out: sizes in, layout out.
final class OptionLayoutTests: XCTestCase {
    func testOnAPhoneTheNextStartOptionsAreAThirdPageNeverAHalfWidthColumn() {
        for accessibility in [false, true] {
            XCTAssertEqual(OptionLayout.nextStart(.phone, accessibilitySize: accessibility), .page)
        }
        XCTAssertEqual(OptionLayout.nextStart(.tablet, accessibilitySize: false), .column)
        XCTAssertEqual(OptionLayout.nextStart(.tv, accessibilitySize: false), .inline)
    }

    func testThePagePickerGetsTheThirdPageOnlyOnAPhoneWithOptions() {
        XCTAssertEqual(OptionLayout.menuPages(.phone, hasOptions: true), [.now, .newConnection, .nextStart])
        XCTAssertEqual(OptionLayout.menuPages(.phone, hasOptions: false), [.now, .newConnection])
        XCTAssertEqual(OptionLayout.menuPages(.tablet, hasOptions: true), [.now, .newConnection])
        XCTAssertEqual(OptionLayout.menuPages(.tv, hasOptions: true), [.now, .newConnection])
    }

    func testTheMenuTabsReadConnectionWhenThereAreThreeAndNewConnectionWhenThereAreTwo() {
        let three = OptionLayout.menuPages(.phone, hasOptions: true)
        XCTAssertEqual(three.map { OptionLayout.tabLabel($0, among: three) }, ["Now", "Connection", "Next start"])
        let two = OptionLayout.menuPages(.phone, hasOptions: false)
        XCTAssertEqual(two.map { OptionLayout.tabLabel($0, among: two) }, ["Now", "New connection"])
    }

    func testARowKeepsItsChipBesideItWhenWideAndMovesItUnderTheLabelWhenNarrow() {
        XCTAssertEqual(OptionLayout.rowForm(width: 600, accessibilitySize: false, hasChip: true), .inline)
        XCTAssertEqual(OptionLayout.rowForm(width: 400, accessibilitySize: false, hasChip: true), .chipBelow)
        XCTAssertEqual(OptionLayout.rowForm(width: 400, accessibilitySize: false, hasChip: false), .inline, "no chip: nothing to move")
        XCTAssertEqual(OptionLayout.rowForm(width: 260, accessibilitySize: false, hasChip: true), .stacked)
        XCTAssertEqual(OptionLayout.rowForm(width: 260, accessibilitySize: false, hasChip: false), .stacked)
        XCTAssertEqual(OptionLayout.rowForm(width: 900, accessibilitySize: true, hasChip: true), .stacked, "the largest text: one column")
    }

    func testTheGamePageHasTwoColumnsWhereTheyFitAndOneAtLargeTextOrWhenNarrow() {
        guard case let .two(phoneLeft) = OptionLayout.pageColumns(width: 800, idiom: .phone, accessibilitySize: false) else {
            return XCTFail("a landscape phone has two columns")
        }
        XCTAssertTrue((240...300).contains(phoneLeft), "\(phoneLeft)")
        XCTAssertEqual(OptionLayout.pageColumns(width: 400, idiom: .phone, accessibilitySize: false), .single)
        XCTAssertEqual(OptionLayout.pageColumns(width: 800, idiom: .phone, accessibilitySize: true), .single)
        XCTAssertEqual(OptionLayout.pageColumns(width: 1000, idiom: .tablet, accessibilitySize: true), .single)
        guard case let .two(padLeft) = OptionLayout.pageColumns(width: 1100, idiom: .tablet, accessibilitySize: false) else {
            return XCTFail("an iPad has two columns")
        }
        XCTAssertTrue((300...400).contains(padLeft), "\(padLeft)")
        XCTAssertEqual(OptionLayout.pageColumns(width: 1920, idiom: .tv, accessibilitySize: false), .two(left: 640))
    }
}
