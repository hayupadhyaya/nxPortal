import AppKit
import SwiftUI

@main
struct NxPortalHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var controller: HostController

    init() {
        let environment = HostEnvironment.current()
        // Before anything is opened: a second launch leaves the first one's files and network name alone.
        if environment.singleInstance && SingleInstance.shouldExit() { exit(0) }
        let controller = HostController(environment: environment)
        AppDelegate.controller = controller
        _controller = State(initialValue: controller)
        controller.begin()
    }

    var body: some Scene {
        MenuBarExtra(Strings.windowTitle, systemImage: "gamecontroller") {
            MenuView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Quit, in the menu or by a signal: the Host stops (and its game with it) before the process ends.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var controller: HostController?
    @MainActor private static var replying = false

    /// Every request waits for the same stop (a second Quit or a signal joins it), and AppKit is answered exactly once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = Self.controller else { return .terminateNow }
        guard !Self.replying else { return .terminateLater }
        Self.replying = true
        Task { @MainActor in
            await controller.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
