import PortalPlayer
import SwiftUI

/// "How to set up a Mac" and "Pair a Mac…": what is needed, the steps, what to try.
struct SetupHelpView: View {
    @Environment(\.dismiss) private var dismiss
    private var p: LookPalette { Theme.palette }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(Strings.helpNeeds, Strings.helpNeedsItems, numbered: false)
                    section(Strings.helpSteps, Strings.helpStepItems, numbered: true)
                    section(Strings.helpStill, Strings.helpStillItems, numbered: false)
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Theme.color(p.text))
            .background(Theme.color(p.groupedSurface).ignoresSafeArea())
            .navigationTitle(Strings.howToSetUp)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(Strings.done) { dismiss() } } }
        }
    }

    private func section(_ title: String, _ items: [String], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Text(numbered ? "\(i + 1).  \(item)" : "•  \(item)").foregroundStyle(Theme.color(p.secondaryText))
            }
        }
    }
}
