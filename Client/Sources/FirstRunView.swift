import PortalPlayer
import SwiftUI

/// What a person sees with no paired Mac: the app, its one requirement, the Macs found -> `docs/…/app-polish-design.md § screen-first-run`
struct FirstRunView: View {
    let model: ClientModel
    @State private var showHelp = false
    @State private var showSettings = false
    @FocusState private var focus: String?
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.verticalSizeClass) private var height
    private var p: LookPalette { Theme.palette }
    /// Apple TV (`§ screen-first-run`): the same column at 10-foot size.
    private static let columnWidth: CGFloat = {
        #if os(tvOS)
        1000
        #else
        560
        #endif
    }()
    private static let markScale: CGFloat = {
        #if os(tvOS)
        1.8
        #else
        1
        #endif
    }()

    /// The iPad collapses the intro to "Choose your Mac" once a Mac is found.
    private var collapsed: Bool { width == .regular && !model.found.isEmpty }
    /// iPhone landscape: the intro on the left, the Macs on the right, so the list is not below the fold.
    private var sideBySide: Bool { height == .compact }

    var body: some View {
        ZStack {
            background
            ScrollView {
                Group {
                    if sideBySide {
                        HStack(alignment: .center, spacing: 36) {
                            VStack(spacing: 14) { mark; intro }.frame(maxWidth: .infinity)
                            VStack(spacing: 14) { macs; extras }.frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 22) {
                            mark
                            if collapsed {
                                Text(Strings.chooseYourMac).font(.title.bold()).accessibilityAddTraits(.isHeader)
                                Text(Strings.chooseYourMacText).foregroundStyle(Theme.color(p.secondaryText))
                            } else {
                                intro
                            }
                            macs
                            if collapsed {
                                Text(Strings.firstRunFooter).font(.small).foregroundStyle(Theme.color(p.secondaryText))
                                    .multilineTextAlignment(.center)
                            }
                            extras
                        }
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.color(p.text))
                .frame(maxWidth: sideBySide ? 820 : Self.columnWidth)
                .padding(.horizontal, 24).padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .topTrailing) {
                Button { showSettings = true } label: { Label(Strings.settings, systemImage: "gearshape").labelStyle(.iconOnly) }
                    .buttonStyle(.portal(.button)).padding()
            }
        }
        .sheet(isPresented: $showHelp) { SetupHelpView() }
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
        .defaultFocus($focus, model.found.first.map(Self.key))
    }

    /// The message, the Forget button when the store failed, and the setup help.
    @ViewBuilder private var extras: some View {
        if let text = model.message {
            Text(text).foregroundStyle(Theme.color(p.destructive)).multilineTextAlignment(.center)
        }
        if model.storeFailed {
            Button(Strings.forgetPairedMacs, role: .destructive) { Task { await model.resetStore() } }
                .buttonStyle(.portal(.button)).disabled(model.busy)
        }
        Button(Strings.howToSetUp) { showHelp = true }
            .buttonStyle(.portal(.button, fill: p.fill2))
            .padding(.top, 6)
    }

    private static func key(_ host: FoundHost) -> String { host.id ?? host.name }

    private var background: some View {
        ZStack {
            Theme.color(p.background)
            GeometryReader { geo in
                RadialGradient(colors: [Theme.color(p.accentGlow), .clear], center: .center, startRadius: 0,
                               endRadius: max(geo.size.width, geo.size.height) / 2)
            }
        }
        .ignoresSafeArea().accessibilityHidden(true)
    }

    private var mark: some View {
        Image(systemName: "gamecontroller.fill")
            .font(.system(size: (width == .regular ? 44 : 56) * Self.markScale))
            .foregroundStyle(Theme.color(p.onAccent))
            .frame(width: (width == .regular ? 88 : 110) * Self.markScale, height: (width == .regular ? 88 : 110) * Self.markScale)
            .background(Theme.color(p.accentFill), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .accessibilityHidden(true)
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Text(Strings.firstRunTitle).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(Strings.firstRunText).foregroundStyle(Theme.color(p.secondaryText))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Strings.firstRunSteps.enumerated()), id: \.offset) { i, step in
                    Text("\(i + 1).  \(step)").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var macs: some View {
        if model.found.isEmpty {
            looking
        } else {
            VStack(spacing: 10) {
                ForEach(model.found, id: \.self) { host in
                    Button { Task { await model.choose(host) } } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "desktopcomputer").accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name).font(.headline)
                                Text(Strings.readyToPair).font(.subheadline).rowTone(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }
                        .padding(14).contentShape(Rectangle())
                    }
                    .buttonStyle(.portal(.row, fill: p.fill))
                    .focused($focus, equals: Self.key(host))
                    .disabled(model.busy)
                }
            }
            .padding(10).glass(radius: Theme.radii.group)
        }
    }

    @ViewBuilder private var looking: some View {
        VStack(spacing: 12) {
            if let refused = model.discoveryMessage {
                Text(refused).foregroundStyle(Theme.color(p.warning))
                #if os(iOS)
                Button(Strings.openSettings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.portal(.button, fill: p.fill2))
                #endif
            } else {
                HStack(spacing: 10) { ProgressView(); Text(Strings.lookingForMacs).foregroundStyle(Theme.color(p.secondaryText)) }
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if LibraryText.showsStillLooking(since: model.lookingSince, now: context.date) {
                        Text(Strings.stillLooking).font(.subheadline).foregroundStyle(Theme.color(p.secondaryText))
                    }
                }
            }
        }
    }
}
