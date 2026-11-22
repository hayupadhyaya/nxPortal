import PortalKit
import PortalPlayer
import SwiftUI

/// A game's own options (`§ screen-game-page`, `§ screen-play`): what the Mac lists, drawn by kind. The app knows kinds
/// (choice, range, toggle) and never an option: every label, value and note is the Host's, cleaned in PortalPlayer.
/// A change goes to the Mac at once and shows at once (`ClientModel.setOption`).

/// "Changed" on the person's own choice, "Default" on a row at its tested default beside changed ones: text with an outline
/// in its own colour, no fill (tested at 4.5:1 on every surface it sits on).
struct OptionChip: View {
    let chip: OptionText.Chip
    private var p: LookPalette { Theme.palette }
    private var color: Color { Theme.color(chip == .changed ? p.accentText : p.secondaryText) }

    var body: some View {
        Text(Strings.optionChip(chip)).font(.tiny.weight(.semibold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: Theme.radii.chip, style: .continuous).stroke(color, lineWidth: 1))
            .foregroundStyle(color)
            .accessibilityHidden(true)  // said in the row's value
    }
}

/// The width a row has (`OptionLayout.rowForm` decides from it).
private struct RowWidth: ViewModifier {
    @Binding var width: CGFloat
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { width = g.size.width }
                .onChange(of: g.size.width) { _, w in width = w }
        })
    }
}

/// A row's frame: the label (two lines at most, never cut to a hyphen), its note, the chip, the control, and a hairline. The
/// chip never wraps: it sits beside the control while the row is wide, under the label when it is narrower, and the label
/// goes above the value when it is narrower still or the text is at its largest. The control keeps its width.
struct OptionRowShell<Control: View, Below: View>: View {
    let label: String
    let note: String
    let chip: OptionText.Chip?
    @ViewBuilder var control: Control
    @ViewBuilder var below: Below
    @State private var width: CGFloat = 600
    @Environment(\.dynamicTypeSize) private var typeSize
    private var p: LookPalette { Theme.palette }
    private var form: OptionLayout.RowForm {
        OptionLayout.rowForm(width: Double(width), accessibilitySize: typeSize.isAccessibilitySize, hasChip: chip != nil)
    }

    private var title: some View {
        Text(label).foregroundStyle(Theme.color(p.text)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)  // the control carries the label
    }

    private var noteText: some View {
        Text(note).font(.small).foregroundStyle(Theme.color(p.secondaryText)).fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch form {
            case .inline:
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) { title; if !note.isEmpty { noteText } }
                    Spacer(minLength: 8)
                    if let chip { OptionChip(chip: chip) }
                    control.layoutPriority(1).fixedSize(horizontal: true, vertical: false)
                }
            case .chipBelow:
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        title
                        if let chip { OptionChip(chip: chip) }
                        if !note.isEmpty { noteText }
                    }
                    Spacer(minLength: 8)
                    control.layoutPriority(1).fixedSize(horizontal: true, vertical: false)
                }
            case .stacked:
                VStack(alignment: .leading, spacing: 6) {
                    title
                    if !note.isEmpty { noteText }
                    HStack(spacing: 10) {
                        if let chip { OptionChip(chip: chip) }
                        Spacer(minLength: 8)
                        control.layoutPriority(1).fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            below
        }
        .modifier(RowWidth(width: $width))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.color(p.separator)).frame(height: 1).padding(.leading, 16) }
    }
}

extension OptionRowShell where Below == EmptyView {
    init(label: String, note: String, chip: OptionText.Chip?, @ViewBuilder control: () -> Control) {
        self.init(label: label, note: note, chip: chip, control: control, below: { EmptyView() })
    }
}

/// One setting, by its editor.
struct OptionRowView: View {
    let model: ClientModel
    let titleID: String
    let row: OptionRow
    let chip: OptionText.Chip?
    private var p: LookPalette { Theme.palette }
    private var s: OptionSetting { row.setting }

    private func set(_ value: String) { Task { await model.setOption(titleID: titleID, env: s.env, value: value) } }

    var body: some View {
        switch row.editor {
        case let .choice(list): choice(list)
        case let .toggle(on, off): toggle(on: on, off: off)
        case let .range(lo, hi, step, _): range(lo, hi, step)
        case .readOnly: readOnly
        }
    }

    private var spoken: String { OptionText.accessibilityValue(value: OptionRows.valueText(row), chip: chip) }

    private func choice(_ list: [OptionChoice]) -> some View {
        let offered = list.contains { $0.value == s.current }
        return OptionRowShell(label: s.label, note: s.note, chip: chip) {
            Picker(s.label, selection: Binding(get: { s.current }, set: set)) {
                ForEach(list, id: \.value) { Text($0.label).tag($0.value) }
                if !offered { Text(s.current).tag(s.current).disabled(true) }  // a value the list does not offer: shown, not pickable
            }
            .labelsHidden().pickerStyle(.menu)
            .tint(Theme.color(p.accentText))
            .accessibilityLabel(s.label).accessibilityValue(spoken)
        }
    }

    private func toggle(on: String, off: String) -> some View {
        OptionRowShell(label: s.label, note: s.note, chip: chip) {
            Toggle(s.label, isOn: Binding(get: { s.current == on }, set: { set($0 ? on : off) }))
                .labelsHidden()
                .tint(Theme.color(p.switchTint(overPicture: true)))  // over the picture: see LookPalette.switchTint
                .accessibilityValue(spoken)
        }
    }

    @ViewBuilder private func range(_ lo: Double, _ hi: Double, _ step: Double) -> some View {
        #if os(tvOS)
        // no slider on Apple TV: the positions as a menu, each with its number (and size)
        OptionRowShell(label: s.label, note: s.note, chip: chip) {
            Picker(s.label, selection: Binding(get: { OptionRows.nearestPosition(row) }, set: set)) {
                ForEach(row.editor.positions, id: \.self) { Text(Self.text(row, $0)).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).tint(Theme.color(p.accentText))
        }
        #else
        RangeSlider(row: row, chip: chip, lo: lo, hi: hi, step: step, spoken: spoken,
                    pending: model.optionsPending(titleID: titleID), commit: set)
        #endif
    }

    /// The position text of a range row standing at `position`.
    static func text(_ row: OptionRow, _ position: String) -> String {
        var r = row
        r.setting.current = position
        return OptionRows.valueText(r)
    }

    private var readOnly: some View {
        OptionRowShell(label: s.label, note: [s.note, Strings.optionCannotChange].filter { !$0.isEmpty }.joined(separator: "\n"), chip: nil) {
            Text(OptionRows.valueText(row)).foregroundStyle(Theme.color(p.secondaryText)).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.label)
        .accessibilityValue("\(OptionRows.valueText(row)). \(Strings.optionCannotChange)")
    }
}

#if !os(tvOS)
/// A range: label, number (with the size when the row has a base) and a slider. The Mac is told when the finger lifts, after
/// a short idle when the value moved some other way (a keyboard), and at each step of an accessibility adjust; the number
/// keeps the moved value until the Mac's answer is in (no flicker back to the old one).
private struct RangeSlider: View {
    let row: OptionRow
    let chip: OptionText.Chip?
    let lo: Double, hi: Double, step: Double
    let spoken: String
    let pending: Bool
    let commit: (String) -> Void
    @State private var dragging: Double?
    @State private var editing = false
    @State private var committing = false
    @State private var idle: Task<Void, Never>?
    private var p: LookPalette { Theme.palette }
    static let idleCommit: UInt64 = 600_000_000, giveUp: UInt64 = 3_000_000_000

    private var shown: OptionRow {
        guard let dragging else { return row }
        var r = row
        r.setting.current = OptionRows.format(dragging, min: lo, step: step)
        return r
    }

    private var position: Double { dragging ?? OptionRows.rangeValue(row) ?? lo }

    private func send(_ value: Double) {
        idle?.cancel()
        let text = OptionRows.format(value, min: lo, step: step)
        dragging = value
        committing = true
        commit(text)
        idle = Task { [giveUp = Self.giveUp] in
            try? await Task.sleep(nanoseconds: giveUp)
            if !Task.isCancelled { dragging = nil; committing = false }  // the answer never came: the Mac's value shows
        }
    }

    var body: some View {
        OptionRowShell(label: row.label, note: row.setting.note, chip: chip) {
            Text(OptionRows.valueText(shown)).monospacedDigit().foregroundStyle(Theme.color(p.text)).lineLimit(1)
        } below: {
            Slider(value: Binding(get: { position }, set: { v in
                dragging = v
                if !editing {  // a keyboard moved it: sent after a short idle
                    idle?.cancel()
                    idle = Task { [wait = Self.idleCommit] in
                        try? await Task.sleep(nanoseconds: wait)
                        if !Task.isCancelled { send(v) }
                    }
                }
            }), in: lo...hi, step: step) { began in
                editing = began
                guard !began, let v = dragging else { return }
                send(v)
            }
            .tint(Theme.color(p.accentText))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.label).accessibilityValue(spoken)
            .accessibilityAdjustableAction { direction in
                guard let next = OptionRows.step(shown, direction: direction == .increment ? 1 : -1), let v = Double(next) else { return }
                send(v)
            }
        }
        .onChange(of: pending) { _, now in
            guard !now, committing else { return }
            idle?.cancel()
            dragging = nil
            committing = false
        }
    }
}
#endif

/// The game page's right column: sections of rows, "More", Reset and the footer.
struct OptionsColumn: View {
    let model: ClientModel
    let titleID: String
    @State private var expanded = false
    private var p: LookPalette { Theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(Strings.optionsTitle).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(Strings.optionsCaption).font(.small).foregroundStyle(Theme.color(p.secondaryText))
            }
            content
        }
        .foregroundStyle(Theme.color(p.text))
        .task(id: "\(titleID)-\(model.macState)") { await model.loadOptions(titleID: titleID) }
    }

    @ViewBuilder private var content: some View {
        switch model.optionsState(for: titleID) {
        case .loaded:
            if let o = model.options(for: titleID) {
                if o.settings.isEmpty { note(Strings.noGameOptions) } else { list(o) }
            }
        case .loading: note(Strings.optionsLoading)
        case .unavailable: note(Strings.optionsCouldNotLoad)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.body).foregroundStyle(Theme.color(p.secondaryText))
    }

    private func list(_ o: GameOptions) -> some View {
        let rows = OptionRows(o), values = OptionRows.values(o)
        func shown(_ list: [OptionRow]) -> [OptionRow] { list.filter { rows.visible($0, values: values) } }
        let hiddenCount = rows.sections.reduce(0) { $0 + shown($1.more).count }
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(rows.sections, id: \.title) { section in
                let visible = shown(section.basic) + (expanded ? shown(section.more) : [])
                if !visible.isEmpty {
                    FormGroup(title: section.title) {
                        ForEach(visible) { row in
                            OptionRowView(model: model, titleID: titleID, row: row, chip: OptionRows.chip(for: row, in: section))
                        }
                    }
                }
            }
            if hiddenCount > 0 {
                Button { withAnimation { expanded.toggle() } } label: {
                    HStack {
                        Text(expanded ? Strings.optionsShowFewer : Strings.optionsMore(count: hiddenCount)).font(.headline)
                        Spacer(minLength: 8)
                        Image(systemName: expanded ? "chevron.up" : "chevron.right").font(.small.weight(.semibold))
                    }
                    .rowTone(.accent)  // accent text at rest, the platter's own colour while focused (tested)
                    .padding(.horizontal, 16).frame(minHeight: 52)
                }
                .buttonStyle(.portal(.row, fill: p.fill))
            }
            VStack(alignment: .leading, spacing: 10) {
                Button { Task { await model.resetOptions(titleID: titleID) } } label: {
                    Label(Strings.optionsReset, systemImage: "arrow.counterclockwise").font(.headline)
                        .padding(.horizontal, 20).frame(minHeight: 44)
                }
                .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
                .disabled(!o.settings.contains { $0.chosen })
                Text(Strings.optionsFooter).font(.small).foregroundStyle(Theme.color(p.secondaryText))
            }
        }
    }
}

/// The in-play menu's "Next start of this game": the render scale and a few basic rows, and "All game options".
struct NextStartGroup: View {
    let model: ClientModel
    let titleID: String
    let gameName: String
    let onAll: () -> Void
    private var p: LookPalette { Theme.palette }

    var body: some View {
        Group {
            if model.optionsState(for: titleID) == .loaded, let o = model.options(for: titleID), !o.settings.isEmpty {
                let rows = OptionRows(o)
                FormGroup(title: Strings.nextStartTitle, caption: Strings.nextStartCaption,
                          footer: Strings.nextStartNote(game: gameName)) {
                    ForEach(rows.menuRows(values: OptionRows.values(o))) { row in
                        let section = rows.sections.first { ($0.basic + $0.more).contains { $0.id == row.id } }
                        OptionRowView(model: model, titleID: titleID, row: row, chip: section.flatMap { OptionRows.chip(for: row, in: $0) })
                    }
                    Button(action: onAll) {
                        HStack {
                            Text(Strings.allGameOptions).font(.headline)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.small.weight(.semibold))
                        }
                        .padding(.horizontal, 16).frame(minHeight: 52)
                    }
                    .buttonStyle(.portal(.row))
                }
            }
        }
        .task(id: "\(titleID)-\(model.macState)") { await model.loadOptions(titleID: titleID) }
    }
}
