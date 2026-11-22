import AppKit
import ImageIO
import PortalHostCore
import PortalHostModel
import PortalKit
import SwiftUI

/// The menu bar window. It reads the model and calls the controller; it decides nothing.
struct MenuView: View {
    let controller: HostController
    /// false for the automation's picture of the menu (an AppKit helper view draws as a placeholder there).
    var watchesWindow = true
    private var model: HostModel { controller.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.statusLine).font(.headline)
                if let detail = model.statusDetail {
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)  // plain text: it holds a device's name
                }
            }
            if let message = controller.shownMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            pairing
            Divider()
            devices
            Divider()
            games
            Divider()
            name
            Divider()
            HStack {
                Button(Strings.gameFolders) { controller.showFolders() }
                Spacer()
                Button(Strings.quit) { controller.quit() }
            }
        }
        .padding(16)
        .frame(width: 340)
        .background { if watchesWindow { WindowLifetime(opened: { controller.menuOpened() }, closed: { controller.menuClosed() }) } }
        // every refresh this view draws says the menu is still open: the model's backstop for a close it never heard
        .onChange(of: model.menuRefreshes) { controller.menuStillOpen() }
    }

    @ViewBuilder private var pairing: some View {
        if case let .pairing(code, until) = model.status {
            VStack(alignment: .leading, spacing: 6) {
                Text(Strings.pairingCodeLabel).font(.caption).foregroundStyle(.secondary)
                Text(Strings.grouped(code: code)).font(.system(size: 40, weight: .semibold, design: .monospaced))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        TimeBar(fraction: HostMessages.codeTimeLeft(until: until, now: context.date))
                        Text(Strings.timeLeft(seconds: Int(until.timeIntervalSince(context.date).rounded(.up))))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button(Strings.cancel) { controller.cancelPairing() }
                }
            }
        } else {
            Button(Strings.pairDevice) { controller.pair() }.disabled(!controller.isRunning)
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.devices).font(.subheadline.weight(.semibold))
            if model.devices.isEmpty { Text(Strings.noDevices).foregroundStyle(.secondary) }
            ForEach(model.devices) { device in
                if controller.removalAsked?.id == device.id {
                    Text(Strings.removeQuestion(device.shownName)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(Strings.remove) { controller.confirmRemove() }
                        Button(Strings.keep) { controller.keepDevice() }
                    }
                } else if controller.deviceRenaming == device.id {
                    HStack {
                        Image(systemName: DeviceGlyph.symbol(for: device.kind)).foregroundStyle(.secondary)
                        TextField(Strings.deviceNamePlaceholder, text: Binding(get: { controller.deviceNameDraft },
                                                                               set: { controller.deviceNameDraft = $0 }))
                            .labelsHidden().onSubmit { controller.saveDeviceName() }
                        Button(Strings.saveName) { controller.saveDeviceName() }
                        Button(Strings.cancel) { controller.cancelRenameDevice() }
                    }
                } else {
                    HStack {
                        Image(systemName: DeviceGlyph.symbol(for: device.kind)).foregroundStyle(.secondary)
                        Text(verbatim: device.shownName)  // plain text: a device's name is its own input
                        if device.live { Text(Strings.connectedTag).foregroundStyle(.secondary) }
                        Spacer()
                        Button(Strings.renameDevice) { controller.beginRenameDevice(device) }
                        Button(Strings.remove) { controller.askRemove(device) }
                    }
                }
            }
        }
    }

    private var games: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.games).font(.subheadline.weight(.semibold))
            if model.games.isEmpty { Text(Strings.noGames).foregroundStyle(.secondary) }
            ForEach(model.games, id: \.titleID) { game in
                HStack {
                    if let icon = GameIcons.shared.image(titleID: game.titleID, hash: game.art?.hash, png: { model.gameIcon(titleID: game.titleID) }) {
                        Image(nsImage: icon).resizable().frame(width: GameIcons.points, height: GameIcons.points)
                            .clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityHidden(true)
                    }
                    Text(game.name)
                    if !game.streamable { Text(Strings.rebuildNeeded).foregroundStyle(.secondary) }
                    if let progress = model.preparing(titleID: game.titleID) {
                        Text(Strings.preparingTag(progress)).foregroundStyle(.secondary)
                    } else if let tag = Strings.gameTag(game.state) { Text(tag).foregroundStyle(.secondary) }
                }
            }
            HStack {
                if controller.gameCanQuit { Button(Strings.quitGame) { controller.quitGame() } }
                Spacer()
                Button(Strings.refresh) { controller.refresh() }
            }
        }
    }

    @ViewBuilder private var name: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.name).font(.subheadline.weight(.semibold))
            if controller.renameAsked != nil {
                Text(Strings.renameEndsGame).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(Strings.renameAnyway) { controller.confirmRename() }
                    Button(Strings.cancel) { controller.keepName() }
                }
            } else {
                HStack {
                    TextField(Strings.name, text: Binding(get: { controller.nameDraft }, set: { controller.nameDraft = $0 })).labelsHidden()
                    Button(Strings.rename) { controller.askRename() }.disabled(!controller.nameCanChange)
                }
            }
        }
    }
}

/// The game icons of the menu, decoded once each at 20 pt (40 px) from the PNG the service keeps; the PNG is looked at again only
/// when its hash changed. A game's icon is the publisher's material: it is drawn in this menu only, never written, logged or sent.
@MainActor
final class GameIcons {
    static let shared = GameIcons()
    static let points: CGFloat = 20
    private var kept: [String: (hash: String, image: NSImage)] = [:]

    func image(titleID: String, hash: String?, png: () -> Data?) -> NSImage? {
        guard let hash else { kept[titleID] = nil; return nil }
        if let known = kept[titleID], known.hash == hash { return known.image }
        guard let data = png(), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(Self.points * 2)] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: Self.points, height: Self.points))
        kept[titleID] = (hash, image)
        return image
    }
}

/// Tells when the menu's own window is on screen: shown (visible, or becoming key) = open; closing or hiding (no longer visible) = closed. The window
/// is the one this view sits in (not the app's key window: the Game Folders window or a panel never counts).
private struct WindowLifetime: NSViewRepresentable {
    let opened: () -> Void
    let closed: () -> Void

    func makeNSView(context: Context) -> LifetimeView { LifetimeView(opened: opened, closed: closed) }
    func updateNSView(_ view: LifetimeView, context: Context) { view.opened = opened; view.closed = closed }

    final class LifetimeView: NSView {
        var opened: () -> Void, closed: () -> Void
        private var observers: [NSObjectProtocol] = []
        private var isOpen = false
        private func open() { guard !isOpen else { return }; isOpen = true; opened() }
        private func close() { guard isOpen else { return }; isOpen = false; closed() }

        init(opened: @escaping () -> Void, closed: @escaping () -> Void) {
            self.opened = opened; self.closed = closed
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers = []
            guard let window else { close(); return }
            func watch(_ name: Notification.Name, _ body: @escaping @MainActor (LifetimeView, NSWindow) -> Void) {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated { if let self, let window { body(self, window) } }
                })
            }
            // The window's own signals (not the app's key window): an update while it is on screen = open; ordering off, closing or
            // being covered completely = closed. Ordering off is posted even while the app is not active (an automated run).
            watch(NSWindow.didUpdateNotification) { view, window in if window.isVisible { view.open() } }
            watch(NSWindow.didBecomeKeyNotification) { view, _ in view.open() }
            watch(NSWindow.willCloseNotification) { view, _ in view.close() }
            watch(Notification.Name("NSWindowWillOrderOffScreenNotification")) { view, _ in view.close() }
            watch(NSWindow.didChangeOcclusionStateNotification) { view, window in
                if window.occlusionState.contains(.visible) { view.open() } else { view.close() }
            }
            if window.isVisible { open() }
        }
    }
}

/// A thin bar that runs down: `fraction` 0...1 of its width is filled. Plain shapes, so it also draws in the automation snapshot.
private struct TimeBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor).frame(width: box.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)  // the time left is the text beside it
    }
}
