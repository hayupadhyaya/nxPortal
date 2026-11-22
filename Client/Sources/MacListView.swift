import PortalPlayer
import SwiftUI

/// The Macs: paired ones with their status, Macs found and not paired, "Pair a Mac…" -> `§ screen-macs`.
/// `onDone` is set in the iPhone sheet (a Done button); the iPad sidebar has none.
struct MacListView: View {
    let model: ClientModel
    var onDone: (() -> Void)?
    /// Set in the iPhone sheet: an unpaired Mac is handed over here, so the sheet closes before the pairing sheet opens (a
    /// sheet's parent cannot present another sheet while this one is up).
    var onPair: ((MacRow) -> Void)?
    /// Set while this list has a sheet or an alert open over it (the sidebar's help sheet, the switch question): the library
    /// beside it is not the frontmost thing then.
    @Binding var overlaid: Bool
    @State private var pending: MacRow?
    @State private var showHelp = false
    @FocusState private var focus: String?
    #if DEBUG
    @State private var autoPaired = false
    #endif
    private var p: LookPalette { Theme.palette }

    private var rows: [MacRow] { model.macRows }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header(Strings.yourMacs)
                ForEach(rows.filter(\.paired)) { row in rowButton(row) }
                if rows.contains(where: { !$0.paired }) {
                    header(Strings.nearby)
                    ForEach(rows.filter { !$0.paired }) { row in rowButton(row) }
                }
                Button { showHelp = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle").accessibilityHidden(true)
                        Text(Strings.pairAMac)
                        Spacer()
                    }
                    .padding(12).contentShape(Rectangle())
                }
                .buttonStyle(.portal(.row))
                Text(Strings.macsFooter).font(.small).foregroundStyle(Theme.color(p.secondaryText)).padding(.horizontal, 12).padding(.top, 6)
            }
            .padding(12)
        }
        .foregroundStyle(Theme.color(p.text))
        .defaultFocus($focus, rows.first { !$0.paired && !$0.current }?.id)
        .sheet(isPresented: $showHelp) { SetupHelpView() }
        .onChange(of: showHelp || pending != nil, initial: true) { _, now in overlaid = now }
        #if DEBUG
        .onChange(of: rows, initial: true) { _, now in
            // screenshots: as a tap on the unpaired Mac's row, once it is listed
            guard let name = Automation.pairFromMacs, !autoPaired, let row = now.first(where: { $0.name == name && !$0.paired }) else { return }
            autoPaired = true
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); choose(row) }
        }
        #endif
        .alert(pending.map { Strings.switchTitle($0.name) } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { row in
            Button(Strings.cancel, role: .cancel) {}
            Button(Strings.switchAction) { go(row) }
        } message: { row in
            Text(Strings.switchMessage(game: rows.first(where: \.current)?.playing ?? "", mac: rows.first(where: \.current)?.name ?? ""))
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.small.weight(.semibold)).foregroundStyle(Theme.color(p.secondaryText))
            .padding(.horizontal, 12).padding(.top, 8).accessibilityAddTraits(.isHeader)
    }

    private func status(_ row: MacRow) -> (text: String, dot: RGBA?) {
        let s = row.status(state: model.macState)
        return (s.text, s.dot.map { $0 == .positive ? p.positive : p.warning })
    }

    private func rowButton(_ row: MacRow) -> some View {
        let s = status(row)
        return Button { choose(row) } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer").frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.headline)
                    HStack(spacing: 6) {
                        if let dot = s.dot { Circle().fill(Theme.color(dot)).frame(width: 8, height: 8).accessibilityHidden(true) }
                        Text(s.text).font(.subheadline)
                            .rowTone(row.paired && !row.reachable && !row.current ? .tertiary : .secondary)
                    }
                }
                Spacer()
                if row.current { Image(systemName: "checkmark").rowTone(.accent).accessibilityHidden(true) }
            }
            .padding(12).contentShape(Rectangle())
        }
        .buttonStyle(.portal(.row, fill: row.current ? p.fill2 : nil))
        .focused($focus, equals: row.id)
        .disabled(model.busy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue(row.accessibilityValue(state: model.macState))
        .accessibilityAddTraits(row.current ? .isSelected : [])
    }

    private func choose(_ row: MacRow) {
        if row.current { onDone?(); return }
        if rows.first(where: \.current)?.playing != nil { pending = row } else { go(row) }
    }

    private func go(_ row: MacRow) {
        if !row.paired, let onPair { return onPair(row) }
        Task { await model.switchMac(row); if model.screen == .library { onDone?() } }
    }
}
