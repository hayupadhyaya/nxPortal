import PortalPlayer
import SwiftUI

/// The pairing keypad: digits 1–9, 0 and delete as buttons, so a controller or the remote can type. Digit keys keep
/// a fixed size (Dynamic Type does not scale them).
struct KeypadView: View {
    let enabled: Bool
    let digit: (Int) -> Void
    let delete: () -> Void
    @FocusState private var focus: Int?
    /// Key size (`§ look-space`): Apple TV 120 x 90, elsewhere square.
    private let keyWidth: CGFloat = {
        #if os(tvOS)
        120
        #else
        58
        #endif
    }()
    private let keyHeight: CGFloat = {
        #if os(tvOS)
        90
        #else
        58
        #endif
    }()

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(0..<3, id: \.self) { row in
                GridRow { ForEach(1...3, id: \.self) { key(row * 3 + $0) } }
            }
            GridRow {
                Color.clear.frame(width: keyWidth, height: keyHeight)
                key(0)
                Button(action: delete) {
                    Image(systemName: "delete.left").frame(width: keyWidth, height: keyHeight)
                }
                .buttonStyle(.portal(.button, fill: Theme.palette.fill2))
                .accessibilityLabel(Strings.deleteDigit)
                .disabled(!enabled)
            }
        }
        .defaultFocus($focus, 1)
    }

    private func key(_ d: Int) -> some View {
        Button { digit(d) } label: {
            Text("\(d)").font(.title.monospacedDigit().weight(.semibold)).frame(width: keyWidth, height: keyHeight)
        }
        .buttonStyle(.portal(.button, fill: Theme.palette.fill2))
        .focused($focus, equals: d)
        .accessibilityLabel("\(d)")
        .disabled(!enabled)
    }
}
