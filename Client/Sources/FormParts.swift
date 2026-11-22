import PortalKit
import PortalPlayer
import SwiftUI

/// A titled group of rows on regular glass with an optional footer: the Settings screen and the in-play menu. Group
/// titles are headers for VoiceOver. -> `§ screen-settings`
struct FormGroup<Content: View>: View {
    let title: String
    var caption: String?
    var footer: String?
    @ViewBuilder var content: Content
    private var p: LookPalette { Theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title.uppercased()).font(.small.weight(.semibold)).foregroundStyle(Theme.color(p.secondaryText))
                if let caption { Text(caption).font(.small).foregroundStyle(Theme.color(p.secondaryText)) }
            }
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(caption.map { "\(title), \($0.lowercased())" } ?? title)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }.glass(radius: Theme.radii.group)
            if let footer {
                Text(footer).font(.small).foregroundStyle(Theme.color(p.secondaryText)).padding(.horizontal, 6)
            }
        }
    }
}

/// One row: a label (with a note under it) and a control; a hairline under it.
struct FormRow<Control: View>: View {
    let label: String
    var note: String?
    @ViewBuilder var control: Control
    private var p: LookPalette { Theme.palette }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(Theme.color(p.text))
                if let note { Text(note).font(.small).foregroundStyle(Theme.color(p.secondaryText)) }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.color(p.separator)).frame(height: 1).padding(.leading, 16) }
    }
}

/// A row with an on / off switch (the label is the switch's own, so VoiceOver reads one control).
struct SwitchRow: View {
    let label: String
    var note: String?
    /// Drawn over the game picture (the in-play menu): the track takes the colour that holds 3:1 over any picture.
    var overPicture = false
    @Binding var isOn: Bool
    private var p: LookPalette { Theme.palette }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(Theme.color(p.text))
                if let note { Text(note).font(.small).foregroundStyle(Theme.color(p.secondaryText)) }
            }
        }
        .tint(Theme.color(p.switchTint(overPicture: overPicture)))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.color(p.separator)).frame(height: 1).padding(.leading, 16) }
    }
}

/// A row with a text field on the right (the person's own text; the field shows `placeholder` while empty).
struct TextRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    private var p: LookPalette { Theme.palette }

    var body: some View {
        FormRow(label: label) {
            TextField(label, text: $text, prompt: Text(placeholder).foregroundStyle(Theme.color(p.secondaryText)))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Theme.color(p.text))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .frame(maxWidth: 260)
        }
    }
}

/// A row whose control is a menu of choices (the current one shows on the right).
struct ChoiceRow<Value: Hashable>: View {
    let label: String
    var note: String?
    @Binding var selection: Value
    let choices: [(value: Value, name: String)]
    /// Choices shown but not selectable.
    var disabled: Set<Value> = []
    private var p: LookPalette { Theme.palette }

    var body: some View {
        FormRow(label: label, note: note) {
            Picker(label, selection: $selection) {
                ForEach(choices, id: \.value) { Text($0.name).tag($0.value).disabled(disabled.contains($0.value)) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.color(p.accentText))
            .fixedSize(horizontal: true, vertical: false)  // a value never wraps ("1920 × 1080"); the label gives way
        }
    }
}

/// The numbers panel's level as a segmented choice.
struct LevelRow: View {
    @Binding var level: PanelLevel
    private var picker: some View {
        Picker(Strings.numbers, selection: $level) {
            ForEach(PanelLevel.allCases, id: \.self) { Text(Strings.levelName($0)).tag($0).lineLimit(1) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }
    var body: some View {
        #if os(tvOS)
        // Apple TV: a menu of the four levels, each in full (a segmented control cuts "Compact" at this size)
        ChoiceRow(label: Strings.numbers, selection: $level, choices: PanelLevel.allCases.map { ($0, Strings.levelName($0)) })
        #else
        // wide: label and picker on one line; narrow (a phone's menu): the picker under the label, never a cut word
        ViewThatFits(in: .horizontal) {
            FormRow(label: Strings.numbers) { picker.frame(width: 340) }
            VStack(alignment: .leading, spacing: 8) {
                Text(Strings.numbers).foregroundStyle(Theme.color(Theme.palette.text))
                picker
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.color(Theme.palette.separator)).frame(height: 1).padding(.leading, 16) }
        }
        #endif
    }
}

/// Names for the value lists `SettingsChoices` (PortalPlayer) holds.
enum Choices {
    typealias Size = SettingsChoices.Size

    static func name(_ s: Size) -> String { "\(s.width) × \(s.height)" }

    static func sizeChoices(_ settings: ClientSettings) -> [(value: Size, name: String)] {
        SettingsChoices.sizes(for: settings).map { ($0, name($0)) }
    }
    /// The sizes not offered for the game `titleID` (its render size is known to be below them).
    @MainActor static func sizesOff(_ model: ClientModel, for titleID: String?) -> Set<Size> {
        Set(model.sizeOffers(for: titleID).filter { !$0.enabled }.map(\.size))
    }
    static func rateChoices(_ settings: ClientSettings) -> [(value: UInt8, name: String)] {
        SettingsChoices.rates(for: settings).map { ($0, Strings.fpsOption(Int($0))) }
    }
    static func bitrateChoices(_ settings: ClientSettings) -> [(value: Int, name: String)] {
        SettingsChoices.bitrates(for: settings).map { ($0, Strings.mbitOption($0)) }
    }
    static func bufferChoices(_ settings: ClientSettings) -> [(value: Int, name: String)] {
        SettingsChoices.buffers(for: settings).map { ($0, Strings.msOption($0)) }
    }
}

extension Binding where Value == ClientSettings {
    var size: Binding<Choices.Size> {
        Binding<Choices.Size>(get: { Choices.Size(width: wrappedValue.maxWidth, height: wrappedValue.maxHeight) },
                              set: { wrappedValue.maxWidth = $0.width; wrappedValue.maxHeight = $0.height })
    }
    var smooth: Binding<Bool> {
        Binding<Bool>(get: { wrappedValue.picturePacing == .smooth },
                      set: { wrappedValue.picturePacing = $0 ? .smooth : .immediate })
    }
}
