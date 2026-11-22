import PortalKit

/// The Settings row for this device's name -> .claude/client.md § settings
public enum DeviceNameText {
    public static let group = "This device"
    public static let title = "This device's name"
    public static let footer = "Macs on your network show this name. A Mac that renamed this device keeps its own name."
    /// What the field shows while empty: the name that is sent then.
    public static func placeholder() -> String { DeviceModelName.current() }
}
