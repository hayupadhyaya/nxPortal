import PortalPlayer
import SwiftUI

/// Asks for the six digits shown on the Mac; sends on the sixth. A wrong code keeps the sheet open, boxes in Destructive.
struct PairSheet: View {
    let model: ClientModel
    let host: FoundHost
    @State private var code = ""
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.verticalSizeClass) private var height
    #if !os(tvOS)
    @FocusState private var typing: Bool
    #endif
    private var p: LookPalette { Theme.palette }
    /// 10-foot sizes on Apple TV (`§ look-space`): the sheet, the code boxes.
    private static let sheetWidth: CGFloat = {
        #if os(tvOS)
        1100
        #else
        540
        #endif
    }()
    private static let boxSize: CGSize = {
        #if os(tvOS)
        CGSize(width: 96, height: 116)
        #else
        CGSize(width: 44, height: 56)
        #endif
    }()
    private static let caretHeight: CGFloat = {
        #if os(tvOS)
        54
        #else
        26
        #endif
    }()
    /// The boxes are red for a wrong code only; any refusal's sentence clears with the next edit of the code.
    private var rejected: Bool { model.pairingRejected }
    private var refused: Bool { model.message != nil }
    private var wide: Bool { height == .compact }  // iPhone landscape: text left, keypad right

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(Strings.pairTitle(mac: host.name)).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { model.cancelPairing() } label: { Image(systemName: "xmark").padding(6) }
                    .buttonStyle(.portal(.button, fill: p.fill2)).accessibilityLabel(Strings.close)
            }
            // the header (with its close button) stays put; the code and the keypad scroll when large text needs more room
            ScrollView {
                if wide { HStack(alignment: .top, spacing: 28) { entry; keypad } } else { VStack(spacing: 16) { entry; keypad } }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(24)
        .foregroundStyle(Theme.color(p.text))
        .frame(maxWidth: Self.sheetWidth).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.color(p.groupedSurface).ignoresSafeArea())
        .presentationBackground(Theme.color(p.groupedSurface))
        #if !os(tvOS)
        .focusable().focused($typing).focusEffectDisabled()
        .onKeyPress(characters: .decimalDigits) { press in
            if let d = press.characters.first?.wholeNumberValue { add(d) }
            return .handled
        }
        .onKeyPress(.delete) { removeLast(); return .handled }
        .onAppear { typing = true }
        #endif
    }

    private var entry: some View {
        VStack(spacing: 14) {
            Text(Strings.pairText(mac: host.name)).foregroundStyle(Theme.color(p.secondaryText)).multilineTextAlignment(.center)
            boxes
            if let text = model.message {
                VStack(spacing: 4) {
                    Text(text).foregroundStyle(Theme.color(p.destructive)).fontWeight(.semibold)
                    if let again = Messages.pairRetry(model.pairingResult, mac: host.name) {
                        Text(again).font(.small).foregroundStyle(Theme.color(p.secondaryText))
                    }
                }
                .multilineTextAlignment(.center)
            } else {
                Text(Strings.pairNote).font(.small).foregroundStyle(Theme.color(p.secondaryText))
            }
        }
    }

    private var keypad: some View {
        KeypadView(enabled: !model.busy, digit: add, delete: removeLast)
    }

    private var boxes: some View {
        HStack(spacing: 18) {
            ForEach(0..<2, id: \.self) { group in
                HStack(spacing: 8) { ForEach(0..<3, id: \.self) { box(group * 3 + $0) } }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.codeLabel(code.count))
    }

    private func box(_ i: Int) -> some View {
        let digits = Array(code)
        let current = i == digits.count && !rejected
        return Text(i < digits.count ? String(digits[i]) : "")
            .font(.title.monospacedDigit().weight(.semibold))
            .frame(width: Self.boxSize.width, height: Self.boxSize.height)
            .foregroundStyle(Theme.color(rejected ? p.destructive : p.text))
            .glass(radius: Theme.radii.row, tint: rejected ? p.destructive.withAlpha(LookTokens.wrongCodeTint) : nil)
            .overlay(alignment: .center) {
                if current { Rectangle().fill(Theme.color(p.accentText)).frame(width: 2, height: Self.caretHeight) }  // the caret
            }
    }

    private func add(_ d: Int) {
        guard !model.busy else { return }
        if refused { code = ""; model.codeEdited() }
        guard code.count < 6 else { return }
        code.append(String(d))
        if code.count == 6 {
            let sent = code
            Task { await model.pair(code: sent) }
        }
    }

    private func removeLast() {
        guard !model.busy else { return }
        if refused { code = ""; model.codeEdited() } else { code = String(code.dropLast()) }
    }
}

private extension RGBA {
    func withAlpha(_ a: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a) }
}
