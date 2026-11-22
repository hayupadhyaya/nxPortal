import XCTest
import PortalKit
@testable import PortalPlayer

/// The rows of a game's options as the page draws them, the cleaning of what a Host sends, and the sentences. The lists are
/// made up here: our own variables, labels and values, nothing of a real game.
final class OptionRowsTests: XCTestCase {
    static func choice(_ env: String, _ label: String, section: String = "Game", level: String? = nil, current: String = "a",
                       chosen: Bool = false, needs: String? = nil) -> OptionSetting {
        OptionSetting(env: env, kind: "choice", section: section, label: label, note: "", defaultValue: "a", current: current,
                      chosen: chosen, options: [["a", "Alpha"], ["b", "Beta"]], level: level, needs: needs)
    }
    static func toggle(_ env: String, _ label: String, section: String, level: String? = nil, current: String = "off",
                       chosen: Bool = false, needs: String? = nil) -> OptionSetting {
        OptionSetting(env: env, kind: "toggle", section: section, label: label, note: "", defaultValue: "off", current: current,
                      chosen: chosen, on: "on", off: "off", level: level, needs: needs)
    }
    static func scale(_ label: String = "Picture scale", current: String = "1.0", chosen: Bool = false) -> OptionSetting {
        OptionSetting(env: "DM_SCALE", kind: "range", section: "Game", label: label, note: "", defaultValue: "1.0", current: current,
                      chosen: chosen, min: 0.5, max: 1.0, step: 0.05,
                      base: OptionBase(docked: .init(width: 1600, height: 900), handheld: .init(width: 1280, height: 720)),
                      level: "basic")
    }
    static let dial = OptionSetting(env: "DM_DIAL", kind: "dial", section: "Performance", label: "Dial", note: "", defaultValue: "x",
                                    current: "x", chosen: false)

    /// Two sections; the first row of "Performance" comes before the last row of "Game".
    static var list: GameOptions {
        GameOptions(titleID: "TITLE01", settings: [
            choice("DM_LANG", "Language", level: "basic"),
            scale(),
            toggle("DM_BUFFER", "Buffering", section: "Performance", level: "basic"),
            toggle("DM_HOLD", "Hold frames", section: "Performance", current: "off"),
            OptionSetting(env: "DM_FLOOR", kind: "range", section: "Performance", label: "Lowest rate", note: "", defaultValue: "30",
                          current: "30", chosen: false, min: 10, max: 60, step: 5, needs: "DM_HOLD=on"),
            dial,
            choice("DM_UPSCALE", "Upscaling", section: "Game"),
        ])
    }

    // MARK: rows

    func testSectionsComeInTheOrderOfTheirFirstRowsAndLaterRowsJoinThem() {
        let rows = OptionRows(Self.list)
        XCTAssertEqual(rows.sections.map(\.title), ["Game", "Performance"])
        XCTAssertEqual(rows.sections[0].basic.map(\.id) + rows.sections[0].more.map(\.id), ["DM_LANG", "DM_SCALE", "DM_UPSCALE"])
    }

    func testBasicRowsComeFirstAndTheRestAreMore() {
        let rows = OptionRows(Self.list)
        XCTAssertEqual(rows.sections[0].basic.map(\.id), ["DM_LANG", "DM_SCALE"])
        XCTAssertEqual(rows.sections[0].more.map(\.id), ["DM_UPSCALE"])
        XCTAssertEqual(rows.sections[1].basic.map(\.id), ["DM_BUFFER"])
        XCTAssertEqual(rows.sections[1].more.map(\.id), ["DM_HOLD", "DM_FLOOR", "DM_DIAL"])
    }

    func testAListWithNoBasicRowFoldsNothingAway() {
        let l = GameOptions(titleID: "T", settings: [Self.choice("DM_ONE", "One"), Self.choice("DM_TWO", "Two")])
        let s = OptionRows(l).sections
        XCTAssertEqual(s.map(\.basic.count), [2])
        XCTAssertEqual(s.map(\.more.count), [0])
    }

    func testARowWithNoSectionGetsTheDefaultTitle() {
        let l = GameOptions(titleID: "T", settings: [Self.choice("DM_ONE", "One", section: "")])
        XCTAssertEqual(OptionRows(l).sections.map(\.title), [OptionText.untitledSection])
    }

    func testANeedsRowIsHiddenWhileItsParentHasAnotherValueAndShownWhileItHasThat() throws {
        let rows = OptionRows(Self.list)
        let floor = try XCTUnwrap(rows.all.first { $0.id == "DM_FLOOR" })
        XCTAssertFalse(rows.visible(floor, values: ["DM_HOLD": "off"]))
        XCTAssertTrue(rows.visible(floor, values: ["DM_HOLD": "on"]))
        XCTAssertTrue(rows.visible(floor, values: [:]), "a variable no row sets keeps the row visible")
        let plain = try XCTUnwrap(rows.all.first { $0.id == "DM_LANG" })
        XCTAssertTrue(rows.visible(plain, values: ["DM_HOLD": "off"]))
    }

    func testValuesAreTheEffectiveOnes() {
        XCTAssertEqual(OptionRows.values(Self.list)["DM_HOLD"], "off")
        XCTAssertEqual(OptionRows.values(Self.list)["DM_SCALE"], "1.0")
    }

    func testAnUnknownKindIsAReadOnlyRowAndStillThere() throws {
        let dial = try XCTUnwrap(OptionRows(Self.list).all.first { $0.id == "DM_DIAL" })
        XCTAssertEqual(dial.editor, .readOnly)
        XCTAssertEqual(OptionRows.valueText(dial), "x")
        XCTAssertEqual(OptionText.cannotChange, "This app cannot change it")
    }

    func testKnownKindsWithUnusableListsAreReadOnlyToo() {
        var noChoices = Self.choice("DM_A", "A"); noChoices.options = []
        var flat = Self.scale(); flat.step = 0
        var backwards = Self.scale(); backwards.min = 1; backwards.max = 0.5
        var huge = Self.scale(); huge.min = 0; huge.max = 1e9; huge.step = 1
        var noOn = Self.toggle("DM_B", "B", section: "S"); noOn.on = nil
        var same = Self.toggle("DM_C", "C", section: "S"); same.off = "on"
        for s in [noChoices, flat, backwards, huge, noOn, same] {
            XCTAssertEqual(OptionRows(GameOptions(titleID: "T", settings: [s])).all.first?.editor, .readOnly, s.env)
        }
    }

    func testTheScaleRangeHasElevenStepsAndKeepsItsBase() throws {
        let row = try XCTUnwrap(OptionRows(Self.list).all.first { $0.id == "DM_SCALE" })
        guard case let .range(lo, hi, step, base) = row.editor else { return XCTFail("not a range: \(row.editor)") }
        XCTAssertEqual([lo, hi, step], [0.5, 1.0, 0.05])
        XCTAssertEqual(row.editor.steps, 11)
        XCTAssertEqual(base?.docked, .init(width: 1600, height: 900))
    }

    func testARangeListsItsPositionsAsTheHostTakesThem() throws {
        let row = try XCTUnwrap(OptionRows(Self.list).all.first { $0.id == "DM_SCALE" })
        let p = row.editor.positions
        XCTAssertEqual(p.count, 11)
        XCTAssertEqual(Array(p.prefix(3)), ["0.5", "0.55", "0.6"])
        XCTAssertEqual(p.last, "1")
        XCTAssertEqual(OptionEditor.choice([]).positions, [])
        XCTAssertEqual(OptionEditor.readOnly.positions, [])
        let floor = try XCTUnwrap(OptionRows(Self.list).all.first { $0.id == "DM_FLOOR" })
        XCTAssertEqual(floor.editor.positions, ["10", "15", "20", "25", "30", "35", "40", "45", "50", "55", "60"])
    }

    /// The slider's tint is the one control edge the options draw (3:1), the chips and notes are text: accent and secondary,
    /// 4.5:1; on the page's group (over the background, grouped surface) and in the in-play menu: its card over the scrim over
    /// a black, grey and white picture, and a row of glass on that card (the options sit in the menu's rows).
    func testTheOptionControlsAndChipsOnTheirSurfaces() {
        let pictures = [("black", RGBA(0x000000)), ("grey", RGBA(0x808080)), ("white", RGBA(0xFFFFFF))]
        for (pn, p) in [("dark", LookTokens.dark), ("light", LookTokens.light)] {
            var surfaces: [(String, RGBA)] = [("page group", p.glass.over(p.background)), ("grouped", p.glass.over(p.groupedSurface))]
            for (name, pic) in pictures {
                let card = p.thickGlass.over(p.scrim.over(pic))
                surfaces += [("card over \(name)", card), ("row on card over \(name)", p.glass.over(card))]
            }
            for (sn, s) in surfaces {
                XCTAssertGreaterThanOrEqual(Contrast.ratio(p.accentText, s), 4.5, "Changed chip, More row: \(pn), \(sn)")
                XCTAssertGreaterThanOrEqual(Contrast.ratio(p.secondaryText, s), 4.5, "Default chip, notes: \(pn), \(sn)")
                XCTAssertGreaterThanOrEqual(Contrast.ratio(p.text, s), 4.5, "labels and values: \(pn), \(sn)")
                XCTAssertGreaterThanOrEqual(Contrast.ratio(p.accentText, s), 3, "slider tint: \(pn), \(sn)")
                XCTAssertGreaterThanOrEqual(Contrast.ratio(p.text, p.fill2.over(s)), 4.5, "Reset on its button: \(pn), \(sn)")
            }
        }
    }

    /// Every switch drawn over the game picture (the options', the menu's "Smooth picture") takes `switchTint(overPicture: true)`;
    /// Settings' switches sit on an opaque surface and keep the fill. The accent fill is what failed over a white picture.
    func testEverySwitchTrackHoldsThreeToOneOnTheSurfaceItIsDrawnOn() {
        let pictures = [("black", RGBA(0x000000)), ("grey", RGBA(0x808080)), ("white", RGBA(0xFFFFFF))]
        for (pn, p) in [("dark", LookTokens.dark), ("light", LookTokens.light)] {
            for (name, pic) in pictures {
                let card = p.thickGlass.over(p.scrim.over(pic))
                for (sn, s) in [("menu card over \(name)", card), ("row on card over \(name)", p.glass.over(card))] {
                    let track = p.switchTint(overPicture: true)
                    XCTAssertGreaterThanOrEqual(Contrast.ratio(track, s), 3, "\(pn), \(sn)")
                }
            }
            for (sn, s) in [("page group", p.glass.over(p.background)), ("grouped", p.glass.over(p.groupedSurface))] {
                XCTAssertGreaterThanOrEqual(Contrast.ratio(p.switchTint(overPicture: false), s), 3, "Settings: \(pn), \(sn)")
            }
        }
        XCTAssertEqual(LookTokens.dark.switchTint(overPicture: true), LookTokens.dark.accentText)
        XCTAssertEqual(LookTokens.dark.switchTint(overPicture: false), LookTokens.dark.accentFill)
        let white = LookTokens.dark.thickGlass.over(LookTokens.dark.scrim.over(RGBA(0xFFFFFF)))
        XCTAssertLessThan(Contrast.ratio(LookTokens.dark.accentFill, white), 3, "the pair that failed: why the rule exists")
    }

    func testTheNearestPositionReadsTheValueThroughTheRangeHelper() throws {
        let row = try scaleRow(current: "0.7")
        XCTAssertEqual(OptionRows.nearestPosition(row), "0.7")
        for bad in ["1e30", "nan", "inf", "", "0x10", "-5"] {
            XCTAssertEqual(OptionRows.nearestPosition(try scaleRow(current: bad)), row.editor.positions.first, bad)
        }
        XCTAssertEqual(OptionRows.nearestPosition(try scaleRow(current: "0.72")), "0.7")
    }

    // MARK: hostile range values

    private func scaleRow(current: String, base: Bool = true) throws -> OptionRow {
        var s = Self.scale(current: current)
        if !base { s.base = nil }
        return try XCTUnwrap(OptionRows(GameOptions(titleID: "T", settings: [s])).all.first)
    }

    func testARangeValueThatIsNotANumberInsideTheRangeIsShownAsTextAndNeverCrashes() throws {
        for current in ["1e30", "nan", "inf", "-inf", "-5", "", "1e308", "0.49", "1.01", "-0", "0x10"] {
            for withBase in [true, false] {
                let row = try scaleRow(current: current, base: withBase)
                XCTAssertNil(OptionRows.rangeValue(row), "\(current)")
                XCTAssertEqual(OptionRows.valueText(row), current, "the text as it is, no size: \(current)")
            }
        }
        for (current, shown) in [("0.5", "0.5 = 800 x 450"), ("1.0", "1 = 1600 x 900"), ("0.75", "0.75 = 1200 x 675")] {
            let row = try scaleRow(current: current)
            XCTAssertEqual(OptionRows.rangeValue(row), Double(current))
            XCTAssertEqual(OptionRows.valueText(row), shown)
        }
        XCTAssertEqual(OptionRows.valueText(try scaleRow(current: "0.75", base: false)), "0.75")
    }

    func testSizeLabelClampsBeforeItConverts() {
        let huge = OptionBase.Size(width: Int.max, height: Int.max)
        XCTAssertFalse(OptionRows.sizeLabel(scale: 1e30, base: .init(width: 1600, height: 900)).isEmpty)
        XCTAssertFalse(OptionRows.sizeLabel(scale: .nan, base: .init(width: 1600, height: 900)).isEmpty)
        XCTAssertFalse(OptionRows.sizeLabel(scale: .infinity, base: huge).isEmpty)
        XCTAssertFalse(OptionRows.sizeLabel(scale: -3, base: huge).isEmpty)
        XCTAssertEqual(OptionRows.sizeLabel(scale: 0.75, base: huge).split(separator: " ").count, 3, "two numbers and the x")
        XCTAssertEqual(OptionRows.sizeLabel(scale: 0.75, base: .init(width: 1600, height: 900)), "1200 x 675", "a good value is unchanged")
    }

    func testAnAdjustStepsOneAndStopsAtTheEnds() throws {
        let row = try scaleRow(current: "0.75")
        XCTAssertEqual(OptionRows.step(row, direction: 1), "0.8")
        XCTAssertEqual(OptionRows.step(row, direction: -1), "0.7")
        XCTAssertNil(OptionRows.step(try scaleRow(current: "1.0"), direction: 1))
        XCTAssertNil(OptionRows.step(try scaleRow(current: "0.5"), direction: -1))
        XCTAssertEqual(OptionRows.step(try scaleRow(current: "nan"), direction: 1), "0.55", "a value that is not a number steps from the lower end")
        XCTAssertNil(OptionRows.step(try scaleRow(current: "1e30"), direction: 0))
        let choice = try XCTUnwrap(OptionRows(Self.list).all.first { $0.id == "DM_LANG" })
        XCTAssertNil(OptionRows.step(choice, direction: 1), "only a range steps")
    }

    func testJoinersOfRealScriptsStayAndStackedMarksAreCapped() throws {
        let label = "\u{0645}\u{200C}\u{0647}  \u{1F468}\u{200D}\u{1F469}  a\u{200B}b"
        XCTAssertEqual(OptionClean.text(label, limit: 80), "\u{0645}\u{200C}\u{0647}  \u{1F468}\u{200D}\u{1F469}  ab")
        let zalgo = "e" + String(repeating: "\u{0301}", count: 60) + "x"
        let cleaned = OptionClean.text(zalgo, limit: 80)
        XCTAssertLessThanOrEqual(cleaned.unicodeScalars.count, OptionClean.maxScalarsPerCharacter + 1)
        XCTAssertTrue(cleaned.hasSuffix("x"))
        XCTAssertFalse(OptionClean.isPlain("a\u{200D}b"), "a value that goes back to the Host stays strict")
    }

    func testSizeLabelRoundsTheBaseTimesTheScale() {
        XCTAssertEqual(OptionRows.sizeLabel(scale: 0.75, base: .init(width: 1600, height: 900)), "1200 x 675")
        XCTAssertEqual(OptionRows.sizeLabel(scale: 0.55, base: .init(width: 1920, height: 1080)), "1056 x 594")
        XCTAssertEqual(OptionRows.sizeLabel(scale: 1, base: .init(width: 1280, height: 720)), "1280 x 720")
    }

    func testTheRenderScaleRowIsFoundByItsBaseNeverByItsName() throws {
        XCTAssertEqual(OptionRows(Self.list).renderScale?.id, "DM_SCALE")
        var renamed = Self.list
        renamed.settings[1].label = "Quality"; renamed.settings[1].env = "DM_OTHER"
        XCTAssertEqual(OptionRows(renamed).renderScale?.label, "Quality")
        var none = Self.list
        none.settings[1].base = nil
        XCTAssertNil(OptionRows(none).renderScale, "a range without a base is not the render scale")
    }

    func testTheSizeHintNamesTheScaleRowByItsOwnLabelOrIsAbsent() {
        XCTAssertEqual(OptionRows.sizeHint(Self.list), "A larger picture needs a higher Picture scale.")
        var renamed = Self.list
        renamed.settings[1].label = "Quality"
        XCTAssertEqual(OptionRows.sizeHint(renamed), "A larger picture needs a higher Quality.")
        var none = Self.list
        none.settings[1].base = nil
        XCTAssertNil(OptionRows.sizeHint(none))
        XCTAssertNil(OptionRows.sizeHint(nil))
    }

    func testValueTextShowsTheLabelTheNumberAndTheSize() throws {
        let rows = OptionRows(GameOptions(titleID: "T", settings: [
            Self.choice("DM_A", "Offered", current: "b"), Self.choice("DM_B", "Unoffered", current: "zz"),
            Self.scale("Part", current: "0.75"), Self.scale("Whole", current: "1.0")]))
        func text(_ label: String) throws -> String { OptionRows.valueText(try XCTUnwrap(rows.all.first { $0.label == label }, label)) }
        XCTAssertEqual(try text("Offered"), "Beta")
        XCTAssertEqual(try text("Unoffered"), "zz", "a value the list does not offer shows as it is")
        XCTAssertEqual(try text("Part"), "0.75 = 1200 x 675")
        XCTAssertEqual(try text("Whole"), "1 = 1600 x 900")
    }

    func testRangeValuesAreWrittenAsTheHostTakesThem() {
        XCTAssertEqual(OptionRows.format(0.75, min: 0.5, step: 0.05), "0.75")
        XCTAssertEqual(OptionRows.format(1.0, min: 0.5, step: 0.05), "1")
        XCTAssertEqual(OptionRows.format(0.6000000001, min: 0.5, step: 0.1), "0.6")
        XCTAssertEqual(OptionRows.format(35, min: 10, step: 5), "35")
        XCTAssertEqual(OptionRows.format(-0.0, min: -1, step: 1), "0")
    }

    func testChips() throws {
        var l = Self.list
        l.settings[0].chosen = true; l.settings[0].current = "b"
        let rows = OptionRows(l)
        XCTAssertEqual(OptionRows.chip(for: rows.sections[0].basic[0], in: rows.sections[0]), .changed)
        XCTAssertEqual(OptionRows.chip(for: rows.sections[0].basic[1], in: rows.sections[0]), .atDefault, "the section has a changed row")
        XCTAssertNil(OptionRows.chip(for: rows.sections[1].basic[0], in: rows.sections[1]), "no changed row in this section")
        XCTAssertEqual(OptionText.Chip.changed.text, "Changed")
        XCTAssertEqual(OptionText.Chip.atDefault.text, "Default")
    }

    func testTheMenuTakesTheScaleThenBasicRowsItCanChangeAndSkipsHiddenOnes() throws {
        var l = Self.list
        l.settings[2].level = "basic"; l.settings[2].current = "on"  // DM_BUFFER on
        l.settings.append(Self.toggle("DM_X", "X", section: "Performance", level: "basic", needs: "DM_BUFFER=off"))
        let rows = OptionRows(l)
        let ids = rows.menuRows(values: OptionRows.values(l)).map(\.id)
        XCTAssertEqual(ids, ["DM_SCALE", "DM_LANG", "DM_BUFFER"], "scale first, the hidden DM_X left out, three at most")
        XCTAssertEqual(rows.menuRows(values: OptionRows.values(l), limit: 1).map(\.id), ["DM_SCALE"])
    }

    // MARK: cleaning

    func testTextsLoseControlCharactersAndAreCut() throws {
        var s = Self.choice("DM_A", "  La\u{0000}bel\n\u{202E}x\u{200B} ")
        s.note = String(repeating: "n", count: 1000)
        s.section = "Sec\u{0007}tion"
        let c = try XCTUnwrap(OptionClean.cleaned(GameOptions(titleID: "T", settings: [s]))).settings[0]
        XCTAssertEqual(c.label, "Labelx")
        XCTAssertEqual(c.note.count, OptionClean.maxNote)
        XCTAssertEqual(c.section, "Section")
        var long = Self.choice("DM_B", String(repeating: "L", count: 500))
        long.options = [["a", String(repeating: "O", count: 500)]]
        let d = try XCTUnwrap(OptionClean.cleaned(GameOptions(titleID: "T", settings: [long]))).settings[0]
        XCTAssertEqual(d.label.count, OptionClean.maxLabel)
        XCTAssertEqual(d.options?[0][1].count, OptionClean.maxLabel)
    }

    func testAnEmptyLabelFallsBackToTheVariable() throws {
        let c = try XCTUnwrap(OptionClean.cleaned(GameOptions(titleID: "T", settings: [Self.choice("DM_A", "\u{0001}")]))).settings[0]
        XCTAssertEqual(c.label, "DM_A")
    }

    func testRowsWithABadVariableOrValueAreDroppedAndDuplicatesKeepTheFirst() throws {
        var badValue = Self.choice("DM_V", "V"); badValue.current = "a\nb"
        var longDefault = Self.choice("DM_L", "L"); longDefault.defaultValue = String(repeating: "x", count: 129)
        let list = GameOptions(titleID: "T", settings: [
            Self.choice("dm_lower", "x"), Self.choice("DM_", "x"), Self.choice("NOT_DM", "x"), Self.choice("DM_BAD;X", "x"),
            Self.choice("DM_" + String(repeating: "A", count: 70), "x"), badValue, longDefault,
            Self.choice("DM_OK", "First"), Self.choice("DM_OK", "Second"),
        ])
        let c = try XCTUnwrap(OptionClean.cleaned(list))
        XCTAssertEqual(c.settings.map(\.label), ["First"])
    }

    func testListsAreCapped() throws {
        let many = (0..<500).map { Self.choice("DM_N\($0)", "n") }
        XCTAssertEqual(OptionClean.cleaned(GameOptions(titleID: "T", settings: many))?.settings.count, OptionClean.maxSettings)
        var s = Self.choice("DM_C", "C")
        s.options = (0..<300).map { ["v\($0)", "label \($0)"] }
        XCTAssertEqual(OptionClean.cleaned(GameOptions(titleID: "T", settings: [s]))?.settings[0].options?.count, OptionClean.maxChoices)
    }

    func testChoicesNeedAPlainValueAndAPairAndAreUnique() throws {
        var s = Self.choice("DM_C", "C")
        s.options = [["a", "Alpha"], ["a", "Again"], ["b\u{0000}", "Bad"], ["lonely"], ["c", ""], [String(repeating: "v", count: 200), "Long"]]
        let c = try XCTUnwrap(OptionClean.cleaned(GameOptions(titleID: "T", settings: [s]))).settings[0]
        XCTAssertEqual(c.options, [["a", "Alpha"], ["c", "c"]])
    }

    func testNumbersSizesAndNeedsAreChecked() throws {
        var r = Self.scale()
        r.min = .nan; r.max = .infinity
        r.base = OptionBase(docked: .init(width: 0, height: 900), handheld: .init(width: 1280, height: 720))
        r.needs = "DM_A=b=c"
        var n2 = Self.toggle("DM_T", "T", section: "S"); n2.needs = "DM_A=on"
        var n3 = Self.toggle("DM_U", "U", section: "S"); n3.needs = "lower=on"
        let c = try XCTUnwrap(OptionClean.cleaned(GameOptions(titleID: "T", settings: [r, n2, n3]))).settings
        XCTAssertNil(c[0].min); XCTAssertNil(c[0].max)
        XCTAssertNil(c[0].base, "a size of 0 is not a size")
        XCTAssertNil(c[0].needs)
        XCTAssertEqual(c[1].needs, "DM_A=on")
        XCTAssertNil(c[2].needs)
        XCTAssertEqual(OptionRows(GameOptions(titleID: "T", settings: [c[0]])).all[0].editor, .readOnly, "no bounds: no slider")
    }

    func testATitleThatIsNotATitleIDAndARejectedThatIsNotAVariableAreNotKept() throws {
        XCTAssertNil(OptionClean.cleaned(GameOptions(titleID: "../x", settings: [])))
        XCTAssertNil(OptionClean.cleaned(GameOptions(titleID: "", settings: [])))
        let c = try XCTUnwrap(OptionClean.cleaned(GameOptions(titleID: "T", settings: [], rejected: "not a variable\n")))
        XCTAssertNil(c.rejected)
        XCTAssertEqual(OptionClean.cleaned(GameOptions(titleID: "T", settings: [], rejected: "DM_A"))?.rejected, "DM_A")
    }

    /// A focused row is the platter: its secondary text (the More row, notes) is drawn with `onPlatterSecondary`.
    func testTheFocusedRowsTextOnThePlatter() {
        for (pn, p) in [("dark", LookTokens.dark), ("light", LookTokens.light)] {
            XCTAssertGreaterThanOrEqual(Contrast.ratio(p.onPlatterSecondary.over(p.platter), p.platter), 4.5, "secondary on the platter: \(pn)")
            XCTAssertGreaterThanOrEqual(Contrast.ratio(p.onPlatter, p.platter), 4.5, "text on the platter: \(pn)")
        }
    }

    // MARK: sentences

    func testSentences() {
        XCTAssertEqual(OptionText.noOptions, "This game has no options to set here.")
        XCTAssertEqual(OptionText.reset, "Reset to tested defaults")
        XCTAssertEqual(OptionText.footer, "Changes apply at the next start.")
        XCTAssertEqual(OptionText.nextStartTitle, "Next start of this game")
        XCTAssertEqual(OptionText.allOptions, "All game options")
        XCTAssertEqual(OptionText.nextStartTab, "Next start", "the phone menu's page name (the group title is too long for a segment)")
        XCTAssertEqual(OptionText.moreRow(count: 6), "6 more options")
        XCTAssertEqual(OptionText.moreRow(count: 1), "1 more option")
        XCTAssertEqual(OptionText.nextStartNote(game: "Lantern"), "These apply the next time Lantern starts.")
        XCTAssertEqual(OptionText.rejected(label: "Picture scale"), "Picture scale was not changed: the Mac did not accept that value.")
        XCTAssertEqual(OptionText.notSent(label: "Picture scale"), "Picture scale was not changed. The Mac is not answering.")
        XCTAssertEqual(OptionText.sizeHint(label: "Picture scale"), "A larger picture needs a higher Picture scale.")
        XCTAssertEqual(OptionText.accessibilityValue(value: "Beta", chip: .changed), "Beta, Changed")
        XCTAssertEqual(OptionText.accessibilityValue(value: "Beta", chip: nil), "Beta")
    }
}
