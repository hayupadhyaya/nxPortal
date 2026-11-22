import PortalPlayer
import SwiftUI

/// The numbers panel: `lines` (`PanelText`) on the dark glass chip, top left, never over the gear, never takes a touch.
/// VoiceOver: one element, the visible text; it updates often and is never announced. -> `§ screen-play`
struct NumbersPanel: View {
    let lines: [String]
    let full: Bool
    /// Reports the size as drawn: the placement (`TouchPanel`) uses the measured size, never a constant.
    var onSize: (CGSize) -> Void = { _ in }
    private var p: LookPalette { Theme.palette }
    private var tv: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }
    private var size: (points: Double, padX: Double, padY: Double) { LookTokens.numbersPanel(tv: tv) }

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).lineLimit(tv ? 2 : 1).minimumScaleFactor(tv ? 1 : 0.6)  // never under the television's floor
                }
            }
            .font(.system(size: size.points, weight: .regular, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Theme.color(LookTokens.panelText))
            .padding(.horizontal, size.padX).padding(.vertical, size.padY)
            .frame(minWidth: full && !tv ? 336 : nil, alignment: .leading)
            .background(Theme.color(p.panelBacking), in: RoundedRectangle(cornerRadius: tv ? 22 : full ? 16 : 14, style: .continuous))
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) { _, size in onSize(size) }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lines.joined(separator: ", "))
            .accessibilityAddTraits(.updatesFrequently)
            .allowsHitTesting(false)
        }
    }
}
