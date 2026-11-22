#if os(iOS)
import PortalPlayer
import SwiftUI

/// The notices of what the app builds on (`Resources/Acknowledgements.txt`), on a sheet from Settings.
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    private var p: LookPalette { Theme.palette }

    private var text: String {
        Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    var body: some View {
        ZStack {
            Theme.color(p.background).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text(Strings.acknowledgements).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { dismiss() } label: { Text(Strings.done).font(.headline).padding(.horizontal, 20).frame(minHeight: 44) }
                        .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
                ScrollView {
                    Text(text).font(.small).foregroundStyle(Theme.color(p.secondaryText))
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(.horizontal, 24).padding(.bottom, 32)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(Theme.color(p.text))
    }
}
#endif
