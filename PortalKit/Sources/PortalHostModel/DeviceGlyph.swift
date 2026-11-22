#if os(macOS)
import PortalKit

/// The symbol a device row shows for its kind -> .claude/host.md § app
public enum DeviceGlyph {
    /// The phone's until the device's first `hello` says what it is.
    public static func symbol(for kind: DeviceKind?) -> String {
        switch kind {
        case .tablet: "ipad"
        case .tv: "appletv"
        case .tool: "terminal"
        case .phone, nil: "iphone"
        }
    }
}
#endif
