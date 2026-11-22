#if os(macOS)
import Foundation

/// The only variables a paired device can ever set: the runtime's `player` class (`docs/env_switches.tsv`, copied here as
/// `HiddenOptions` copies its names), minus what does nothing while streaming (`HiddenOptions.names`) and minus
/// `DM_SAVE_SYNC` (a folder the save is synced through, not a row of a settings list). An ALLOW-list: a variable the
/// runtime adds later is not settable until it is listed here. Checked where a game's list is read (other rows are dropped),
/// when a choice is set and when a game is launched; `ReservedVariables` stays as a second filter at launch
/// -> .claude/host.md § options
public enum PlayerOptions {
    /// The table's `player` class, 28 names (`PlayerOptionsTests.testTheListIsASubsetOfTheTablesPlayerClass` reads the table where it exists).
    public static let names: Set<String> = [
        "DM_DYNAMIC_RESOLUTION", "DM_FPS_HOLD", "DM_FPS_TARGET", "DM_FULLSCREEN", "DM_HOME_QUIT", "DM_LANG", "DM_METAL_HUD",
        "DM_MIC", "DM_MIC_GAIN", "DM_NVN_ENC_THREAD", "DM_OPMODE", "DM_PAD_PRESS_TO_JOIN", "DM_PICTURE_FIT", "DM_PRESENT_SNAP", "DM_PRESENT_UPSCALE",
        "DM_PSO_MTL4", "DM_PSO_PREBUILD", "DM_RENDER_SCALE", "DM_ROTATION", "DM_RUMBLE", "DM_RUMBLE_GAIN", "DM_RUMBLE_MIN", "DM_SAVE_SYNC",
        "DM_SCREEN_ASPECT", "DM_SHOW_FPS", "DM_SW2", "DM_TOUCH_HAPTICS", "DM_UPSCALER",
    ]
    /// In the class but not for a device.
    public static let notForADevice: Set<String> = ["DM_SAVE_SYNC"]

    public static func isSettable(_ env: String) -> Bool {
        names.contains(env) && !HiddenOptions.names.contains(env) && !notForADevice.contains(env)
    }
}
#endif
