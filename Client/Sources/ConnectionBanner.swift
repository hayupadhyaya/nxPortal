import PortalPlayer
import SwiftUI

/// The Mac cannot be reached: what happened, that the games shown are the last known, and Retry (`§ screen-errors`).
struct ConnectionBanner: View {
    let text: String
    let busy: Bool
    let onRetry: () -> Void
    private var p: LookPalette { Theme.palette }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle().fill(Theme.color(p.warning)).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(Theme.color(p.text)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onRetry) { Text(Strings.retry).font(.headline).padding(.horizontal, 20).frame(minHeight: 44) }
                .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
                .disabled(busy)
        }
        .padding(16)
        .glass(.thick, radius: Theme.radii.banner)
    }
}
