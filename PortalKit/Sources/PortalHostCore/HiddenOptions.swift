#if os(macOS)
import Foundation

/// Switches of a game's own list that do nothing while it streams: they act on the Mac's window, its performance HUD or an
/// iPhone's screen, none of which a streamed game has, or open a device of the Mac that must stay shut (the runtime's `player` switches that need a window or a screen,
/// `docs/env_switches.tsv`). One place; `GameOptionsReader` drops these rows and `HostService` never accepts them
/// -> .claude/host.md § options
public enum HiddenOptions {
    public static let names: Set<String> = [
        "DM_FULLSCREEN",       // the Mac window's mode
        "DM_METAL_HUD",        // Apple's performance HUD over the window
        "DM_PICTURE_FIT",      // fit or fill on a device's screen
        "DM_PRESENT_UPSCALE",  // scales the picture to the window's rectangle
        "DM_SHOW_FPS",         // a counter on an iPhone's screen
        "DM_HOME_QUIT",        // the Home button of a controller on the Mac
        "DM_TOUCH_HAPTICS",    // a haptic tap for a touch control on an iPhone
        "DM_SW2",              // Bluetooth controllers on the Mac
        "DM_MIC",              // the Mac's microphone: its consent prompt would appear where nobody sits
        "DM_MIC_GAIN",         // the gain of that microphone
        "DM_ROTATION",         // the orientation lock of a game on a phone or tablet itself
    ]
}
#endif
